#!/usr/bin/env perl

=desc


fswebcam --quiet --jpeg 95 --no-banner --frames 10 --loop 10 '/var/timelapse/photo/tl-%Y-%m-%''dT%H-%M-%''S.jpg'


info:
ffmpeg -f video4linux2 -list_formats all -i /dev/video0
v4l2-ctl --list-formats-ext

v4l2-ctl -d /dev/video0 --list-ctrls
v4l2-ctl --get-ctrl=focus_auto
v4l2-ctl --get-ctrl=focus_absolute
v4l2-ctl --set-ctrl=focus_auto=0
v4l2-ctl --set-ctrl=focus_absolute=0

fswebcam --list-controls

fswebcam --set "Restore Factory Settings"
fswebcam --set brightness=100%

night mode:
fswebcam --set "brightness=50%" --set "Exposure (Absolute)=100%" --set "Backlight Compensation=100%" --set "Exposure, Auto=Manual Mode"
fswebcam --set "Sharpness=100%" --set "Exposure (Absolute)=60%" --set "Backlight Compensation=50%" --set "Exposure, Auto=Aperture Priority Mode"
--set "Focus (absolute)=0%" --set "Focus, Auto=False"


=cut

use 5.20.0;
no if $] >= 5.017011, warnings => 'experimental::smartmatch';
use File::Copy;
use File::Path;
use Time::Local;
use POSIX;

sub mkdirp(;$$) {
    local $_ = shift // $_;
    $_ .= '/' unless m{/$};
    my @ret;
    while (m{/}g) {
        (push @ret, $`), (@_ ? mkdir $`, $_[0] : mkdir $`) if length $`;
    }
    @ret;
}

sub sy (@) {
    say 'Running: ', join ' ', @_;
    system @_;
}

sub file_rewrite(;$@) {
    local $_ = shift;
    return unless open my $fh, '>', $_;
    print $fh @_;
}

my $fscamd_params = [qw(device resolution frames skip loop jpeg delay)];

sub opt(;$$) {
    my ($opt, $argv) = @_;
    $opt ||= {map { s/^-+//; (undef, undef) = split /=/, $_, 2 } grep {/^-/} @$argv};
    $opt->{name}   //= '0';                     # '2';
    ($opt->{self} //= `realpath $0`) =~ s/\s+$//;
    ($opt->{self_dir} //= $opt->{self}) =~ s{[^/]+$}{};
    our $config = {};
    do $opt->{self_dir} . 'config.pl';
    $opt->{$_} = $config->{name}{$opt->{name}}{opt}{$_} for keys %{$config->{name}{$opt->{name}}{opt}};
    $opt->{root}   //= '/var/lib/timelapse/';
    $opt->{dir}    //= "$opt->{root}photo/";
    $opt->{video}  //= "$opt->{root}video/";
    $opt->{backup} //= "$opt->{root}backup";
    $opt->{hourly} //= "$opt->{root}hourly/";
    $opt->{prefix} //= "tl-$opt->{name}-";
    $opt->{ext}    //= '.jpg';
    $opt->{user}   //= $ENV{USER};
    $opt->{device} //= "/dev/video$opt->{name}";
    #$opt->{resolution} //= '1920x1080';
    $opt->{loop}   //= 10;                      #seconds
                                                #$opt->{frames} //= 10;
                                                #$opt->{skip} //= 5; # first five for auto-adjust
    $opt->{frames} //= 2; # 5;
    #$opt->{skip} //= 1; # first five for auto-adjust
    #$opt->{delay} //= 8;
    $opt->{jpeg} //= 95;
    $opt->{set} //= join ' ', q{--set "Focus (absolute)=0%"}, q{--set "Focus, Auto=False"},
      q{--set "Sharpness=100%"},
      #q{--set "Sharpness=50%"},
      q{--set "Backlight Compensation=50%"},
      q{--set "White Balance Temperature, Auto=False"},
      #q{--set "White Balance Temperature, Auto=True"},
      #q{--set "Exposure, Auto=Manual Mode" --set "Exposure (Absolute)=70%"},
      #q{--set "Exposure, Auto=Aperture Priority Mode"}, q{--set "Exposure (Absolute)=60%"}, # day
      ;

    #$opt->{night_exposure_absolute} = 5731; #21:30
    $opt->{night_exposure_absolute} = 6500;    #21:30

    $opt->{framerate} //= 25;
    $opt->{encoder}   //= 'libx264';           # 'libvpx-vp9'
    $opt->{preset}    //= 'faster';            # 'veryfast'; # ~2.712g  'fast' killed on 4g; # https://trac.ffmpeg.org/wiki/Encode/H.264

    return $opt;
}

sub make_video($$$) {
    my ($opt, $name, $result) = @_;
    return sy
qq{ffmpeg -y -framerate $opt->{framerate} -pattern_type glob -i '$name' -c:v $opt->{encoder} -preset $opt->{preset} -movflags +faststart $result};

# env DISPLAY=:0 ffplay -stats -fast -framedrop -fs -s 640x480 -i /dev/video1
}

sub process($) {
    my ($opt) = @_;
    install($opt) unless -d $opt->{dir};
    my $cur_date = POSIX::strftime("%Y-%m-%d", localtime time);
    my %dates;
    opendir(my $dh, $opt->{dir}) || return;

    while (defined(my $f = readdir($dh))) {
        next unless $f =~ /^$opt->{prefix}/;
        next unless $f =~ /\Q$opt->{ext}\E$/;
        $f =~ /(\d+-\d+-\d+)T/;
        my $full = "$opt->{dir}/$f";
        unlink $full unless -s $full;    # out of space result
        push @{$dates{$1}}, $full;
        print "$full $1\n";
    }
    for my $date (sort keys %dates) {
        my $result = "$opt->{video}vtl-$opt->{name}-${date}.mp4";
        #next if
        make_video($opt, "$opt->{dir}/$opt->{prefix}${date}T*$opt->{ext}", $result);

        if ($date ~~ $cur_date) {
            next;
        }
        sy "ln -fs $result $opt->{video}latest$opt->{name}.mp4";

        mkdirp "$opt->{backup}/$date";
        mkdirp $opt->{hourly};
        for my $file (@{$dates{$date}}) {
            File::Copy::copy $file, $opt->{hourly} if $file =~ /00-00$opt->{ext}$/;
            File::Copy::move $file, "$opt->{backup}/$date/";
        }
    }
}

sub hourly($) {
    my ($opt) = @_;
    local $opt->{framerate} = 10;
    for my $hour (map { sprintf "%02d", $_ } 0 .. 23) {
        my $result = "$opt->{video}vth-$opt->{name}-${hour}.mp4";
        make_video($opt, "$opt->{hourly}/$opt->{prefix}*T${hour}-*$opt->{ext}", $result);
    }
}

sub install ($) {
    my ($opt) = @_;

    my $params = join ' ', map {"--$_=$opt->{$_}"} grep { defined $opt->{$_} } qw(name), qw(resolution);    #@$fscamd_params;

    sy qq{sudo mkdir -p $opt->{root}};
    sy qq{sudo chown $opt->{user} $opt->{root}};
    #sy qq{sudo chmod -R a+rw $opt->{root}};
    #sy qq{sudo chmod a+x $opt->{root}};
    sy qq{mkdir -p $opt->{dir}};
    sy qq{mkdir -p $opt->{video}};

    sy qq{sudo apt install -y ffmpeg fswebcam nginx-full};
    sy qq{sudo usermod -a -G video $opt->{user}};
    sy qq{sudo ln -s `realpath timelapse-site` /etc/nginx/sites-enabled};
    #sy qq{sudo sh -c "echo \@reboot $opt->{user} `realpath timelapse.pl` start > /etc/cron.d/timelapse$opt->{name}"};
    sy qq{sudo sh -c "echo 10 0  \\* \\* \\* $opt->{user} `realpath timelapse.pl` process clean $params > /etc/cron.d/timelapse$opt->{name}"};
    if (length $opt->{night_exposure_absolute}) {
        sy
qq{sudo sh -c "echo 30 21 \\* \\* \\* $opt->{user} v4l2-ctl -d $opt->{device} --set-ctrl=exposure_auto=1 --set-ctrl=exposure_absolute=$opt->{night_exposure_absolute} >> /etc/cron.d/timelapse$opt->{name}"};
        sy
qq{sudo sh -c "echo 30 3  \\* \\* \\* $opt->{user} v4l2-ctl -d $opt->{device} --set-ctrl=exposure_auto=3 >> /etc/cron.d/timelapse$opt->{name}"};
    }

    file_rewrite 'tmp.service',
      qq{
[Unit]
Description=Timelapse recorder $opt->{name}
#Requires=network-online.target
#After=network-online.target

[Service]
Type=simple
User=$opt->{user}
#Group=
Restart=always
RestartSec=5
ExecStart=$opt->{self} service $params

[Install]
WantedBy=multi-user.target
};

    sy qq{sudo mv tmp.service /lib/systemd/system/timelapse$opt->{name}.service};
    sy 'sudo systemctl daemon-reload';
}

sub clean($) {
    my ($opt) = @_;
    my $dir = $opt->{backup};
    for my $file (<$dir/*>) {
       next unless -d $file;
        my ($year, $mon, $mday) = $file =~ m{(\d+)-(\d+)-(\d+)$};
        next unless $year and $mon and $mday;
        my $time = Time::Local::timelocal( 0, 0, 0, $mday, $mon-1, $year );
        next if !$time or $time > time-86400 * ($opt->{backup_days} // 3);
        say "removing $file = ",  File::Path::remove_tree($file);
    }
}

sub run(;$$) {
    my ($opt, $argv) = @_;
    $opt = opt($opt, $argv);
    if ('stop' ~~ $argv or 'deinstall' ~~ $argv) {
        sy "sudo service timelapse$opt->{name} stop";
        sy "sudo service timelapse$opt->{name} status";
    }
    if ('deinstall' ~~ $argv) {
        sy
qq{sudo rm /etc/cron.d/timelapse$opt->{name} /etc/nginx/sites-enabled/timelapse-site /lib/systemd/system/timelapse$opt->{name}.service   /etc/cron.d/timelapse /lib/systemd/system/timelapse};
    }

    if ('install' ~~ $argv) {
        install($opt);
    }
    if ('service' ~~ $argv) {
        warn("No video device $opt->{device}"), return unless -e $opt->{device};

        if (!$opt->{resolution} or 'resolution' ~~ $argv) {
            my ($max_sum, $max_r);
            for (qx{ffmpeg -f video4linux2 -list_formats all -i $opt->{device} 2>&1}) {
                next unless /\[video4linux2,v4l2/;
                /:\s*([^:]*)$/;
                for my $r (split /\s+/, $1) {
                    $r =~ /^(\d+)x(\d+)$/;
                    my $sum = $1 + $2;
                    next if $max_sum >= $sum;
                    $max_sum = $sum;
                    $max_r   = $r;
                }
            }
            say "Max resolution: ",
              $opt->{resolution} = $max_r if $max_r;
        }

        my $params = join ' ', map {"--$_ $opt->{$_}"} grep { length $opt->{$_} } @$fscamd_params;
        sy "fswebcam --quiet --no-banner $params $opt->{set} '$opt->{dir}$opt->{prefix}%Y-%m-%''dT%H-%M-%''S$opt->{ext}'";
    }
    if ('start' ~~ $argv) {
        sy "sudo service timelapse$opt->{name} start";
        sy "sudo service timelapse$opt->{name} status";
    }
    if ('restart' ~~ $argv) {
        sy "sudo service timelapse$opt->{name} restart";
        sy "sudo service timelapse$opt->{name} status";
    }
    if ('status' ~~ $argv) {
        sy "sudo service timelapse$opt->{name} status";
    }
    if ('process' ~~ $argv) {
        process($opt);
    }
    if ('hourly' ~~ $argv) {
        hourly($opt);
    }
    if ('clean' ~~ $argv) {
        clean($opt);
    }
}

run(undef, \@ARGV) unless (caller);
