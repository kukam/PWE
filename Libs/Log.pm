package Libs::Log;

use strict;
use Libs::Send;
use Time::HiRes;

my ($CONF);

sub new {
    my ($class, $conf) = @_;

    $CONF = $conf;

    my $self = {
        'logdir' => ($CONF->getValue("log", "logdir", undef) ? $CONF->getValue("pwe", "home", "") . $CONF->getValue("log", "logdir", undef) : "/dev/null"),
        'loglevel'   => $CONF->getValue("log", "loglevel", 0),
        'delayqueue' => {},
        'ip'         => '127.0.0.1',
        'pid'        => $$,
        'output'     => undef,
    };
    bless $self, $class;
    return $self;
}

sub getLogLevel {
    my $self = shift;
    return $self->{'loglevel'};
}

sub setLogLevel {
    my ($self, $level) = @_;
    return if ($level !~ /^\d+$/);
    $self->{'loglevel'} = $level;
}

sub setIP {
    my ($self, $ip) = @_;
    $self->{'ip'} = $ip;
}

sub error {
    my ($self, $msg) = @_;
    my $who = sprintf("%s:%d", (caller)[0, 2]);
    $self->write("[E]", "$who :: $msg") if ($self->getLogLevel() > 0 and $self->filterLog('error', $who));
}

sub warning {
    my ($self, $msg) = @_;
    my $who = sprintf("%s:%d", (caller)[0, 2]);
    $self->write("[W]", "$who :: $msg") if ($self->getLogLevel() > 1 and $self->filterLog('warning', $who));
}

sub info {
    my ($self, $msg) = @_;
    my $who = sprintf("%s:%d", (caller)[0, 2]);
    $self->write("[I]", "$who :: $msg") if ($self->getLogLevel() > 2 and $self->filterLog('info', $who));
}

sub debug {
    my ($self, $msg) = @_;
    my $who = sprintf("%s:%d", (caller)[0, 2]);
    $self->write("[D]", "$who :: $msg") if ($self->getLogLevel() > 3 and $self->filterLog('debug', $who));
}

sub force {
    my ($self, $msg) = @_;
    my $who = sprintf("%s:%d", (caller)[0, 2]);
    $self->write("[F]", "$who :: $msg") if ($self->getLogLevel() > 0);
}

sub filterLog {
    my ($self, $method, $who) = @_;
    return 0 if (!$self->excludeLog($method, $who));
    return $self->acceptLog($method, $who);
}

sub acceptLog {
    my ($self, $method, $who) = @_;

    $who =~ s/\:\d+$//;

    my @filter1 = @{$CONF->getValue("log", $method . "_filter_list", [])};
    my @filter2 = @{$CONF->getValue("log", "filter_list",            [])};

    if (@filter1 > 0) {
        foreach (@filter1) { return 1 if ($_ eq $who); }
        return 0;
    } elsif (@filter2 > 0) {
        foreach (@filter2) { return 1 if ($_ eq $who); }
        return 0;
    } else {
        return 1;
    }
}

sub excludeLog {
    my ($self, $method, $who) = @_;

    $who =~ s/\:\d+$//;

    my @filter1 = @{$CONF->getValue("log", $method . "_exclude_list", [])};
    my @filter2 = @{$CONF->getValue("log", "exclude_list",            [])};

    if (@filter1 > 0) {
        foreach (@filter1) { return 0 if ($_ eq $who); }
        return 1;
    } elsif (@filter2 > 0) {
        foreach (@filter2) { return 0 if ($_ eq $who); }
        return 1;
    } else {
        return 1;
    }
}

=head2 B<[Public] delay()>

    Metoda zapise do logu delay.
    
=cut

sub delay {
    my ($self, $key, $text) = @_;

    return unless ($CONF->getValue("log", "log_delay", 0));

    $text = "" unless ($text);

    unless (defined($self->{'delayqueue'}->{$key})) {
        $self->{'delayqueue'}->{$key} = Time::HiRes::time();
    } else {
        my $start = $self->{'delayqueue'}->{$key};
        my $stop  = Time::HiRes::time();
        my $delay = sprintf "%.5f", ($stop - $start);
        my $who   = sprintf("%s:%d", (caller)[0, 2]);
        $self->write("[d]", "$who :: $key :: $text [ delay : $delay/s ]") if ($delay >= $CONF->getValue("log", "log_delay_minimum", 0) and $self->filterLog('delay', $who));
        delete $self->{'delayqueue'}->{$key};
    }
}

sub write {
    my ($self, $who, $text) = @_;

    $text = "$who $text";
    $who =~ s/\s//g;

    my $ip     = $self->{'ip'};
    my $pid    = $self->{'pid'};
    my $logdir = $self->{'logdir'};
    my $output = $self->{'output'};
    my $logout = $logdir . "/webout.log";
    my $time   = scalar localtime(time);

    # PRINT webout.log
    if ($self->getLogLevel() > 4 and $self->filterLog('print', $who)) {
	print STDOUT "PRINT LOG: $text\n";
    } else {
	open($output, '>>', $logout) or die "Error Open log:'$logout'";
	print $output "[$time] $ip $text\n" or die "Error Write log:'$logout'";
	close($output) or die "Error Close log:'$logout'";
    }

    # ZAMCENI
    #flock($output,2) or die "Error Lock log:'$logout'";
    # ODEMCENI
    #flock($output,8) or die "Error Unlock log:'$logout'";
}

=head2 B<[Private] sendErrorReport($service,$func,$error)>

    metoda vytvori email s reportem o padu service.

=cut

sub sendErrorReport {
    my ($self, $name, $who, $method, $error) = @_;

    my $where = sprintf("%s:%d", (caller)[0, 2]);

    my $from = $CONF->getValue("web", "email_admin",    "root\@localhost");
    my $to   = $CONF->getValue("web", "email_admin",    "root\@localhost");
    my $sub  = $CONF->getValue("web", "email_subtitle", "") . ": PWE error report";
    my $date = scalar localtime(time);

    my $text = "\n\n";

    $text .= "+--- PWE DUMP -----------------\n";
    $text .= "| \n";
    $text .= "| $name : $who \n";
    $text .= "| METHOD : $method \n";
    $text .= "| WHERE : $where \n";
    $text .= "| DATE : $date \n";
    $text .= "| \n";
    $text .= "| ERROR  \n";
    $text .= "| ===== \n";

    foreach (split(/\n/, $error)) {
        $text .= "| $_ \n";
    }

    $text .= "| \n";
    $text .= "| SERVER INFO \n";
    $text .= "| =========== \n";

    while (my ($key, $value) = each(%ENV)) {
        $text .= "| $key : $value \n";
    }

    $text .= "+------------------------------\n";

    foreach my $smtp_server (@{$CONF->getValue("pwe", "smtp_servers", ["smtp_primary"])}) {

        my $config = $CONF->getValue($smtp_server, undef, undef);

        if (ref($config) ne "HASH") {
            $self->error("smtp server '$smtp_server' config is not defined");
            next;
        }

        my $send = new Libs::Send($config);

        $send->setFrom($from);
        $send->setTo($to);
        $send->setSubjectUTF8($sub);
        $send->setBodyPlainUTF8($text);

        my $result = $send->send();

        if ($result) {
            $self-->info("Traing send email to:$to FAIL, msg:$result");
        } else {
            $self->info("Send error report mail to:$to is completed.");
            last;
        }
    }
}

# KOMODO-IDE/KOMODO-EDIT
sub KOMODO {
    return;
    require Libs::Config;
    $CONF = new Libs::Config;
}

1;
