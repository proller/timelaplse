#!/usr/bin/env perl

=desc


fswebcam --quiet --jpeg 95 --no-banner --frames 10 --loop 10 '/var/timelapse/photo/tl-%Y-%m-%''dT%H-%M-%''S.jpg'


info:
ffmpeg -f video4linux2 -list_formats all -i /dev/video0
v4l2-ctl --list-formats-ext



=cut

use 5.20.0;
no if $] >= 5.017011, warnings => 'experimental::smartmatch';
use File::Copy;
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

sub opt(;$$) {
    my ($opt, $argv) = @_;
    $opt ||= {map { s/^-+//; (undef, undef) = split /=/, $_, 2 } grep {/^-/} @$argv};
    $opt->{root}   //= '/var/lib/timelapse/';
    $opt->{dir}    //= "$opt->{root}photo/";
    $opt->{video}  //= "$opt->{root}video/";
    $opt->{backup} //= "$opt->{root}backup";
    $opt->{name}   //= '0';                     # '2';
    $opt->{prefix} //= "tl-$opt->{name}-";
    $opt->{ext}    //= '.jpg';
    $opt->{user}   //= $ENV{USER};
    ($opt->{self} //= `realpath $0`) =~ s/\s+$//;

    $opt->{device}     //= "/dev/video$opt->{name}";
    #$opt->{resolution} //= '1280x720';
    $opt->{loop}       //= 10;                         #seconds
    $opt->{frames}     //= 10;
    $opt->{jpeg}       //= 95;

    return $opt;
}

sub process {
    my ($opt) = @_;
    install($opt) unless -d $opt->{dir};
    my $cur_date = POSIX::strftime("%Y-%m-%d", localtime time);
    my %dates;
    opendir(my $dh, $opt->{dir}) || return;

    while (defined(my $f = readdir($dh))) {
        next unless $f =~ /^$opt->{prefix}/;
        next unless $f =~ /\Q$opt->{ext}\E$/;
        $f =~ /(\d+-\d+-\d+)T/;
        push @{$dates{$1}}, "$opt->{dir}/$f";
        print "$opt->{dir}/$f $1\n";
    }
    for my $date (sort keys %dates) {
        my $result = "$opt->{video}vtl-$opt->{name}-${date}.mp4";
        next if sy qq{ffmpeg -y -framerate 25 -pattern_type glob -i '$opt->{dir}/$opt->{prefix}${date}T*$opt->{ext}' -c:v libx264 $result};

        if ($date ~~ $cur_date) {
            next;
        }
        sy "ln -fs $result $opt->{video}latest$opt->{name}.mp4";

        mkdirp "$opt->{backup}/$date";
        for my $file (@{$dates{$date}}) {
            File::Copy::move $file, "$opt->{backup}/$date/";
        }
    }
}

sub install ($) {
    my ($opt) = @_;

    my $params = join ' ', map {"--$_=$opt->{$_}"} grep { defined $opt->{$_} } qw(name);

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
    sy qq{sudo sh -c "echo 10 0 \\* \\* \\* $opt->{user} `realpath timelapse.pl` process $params > /etc/cron.d/timelapse$opt->{name}"};

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
        my $params = join ' ', map {"--$_ $opt->{$_}"} grep { defined $opt->{$_} } qw(device resolution frames loop jpeg);
        sy "fswebcam --quiet  --no-banner $params '$opt->{dir}$opt->{prefix}%Y-%m-%''dT%H-%M-%''S$opt->{ext}'";
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
}

run(undef, \@ARGV) unless (caller);
