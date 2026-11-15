package Libs::Log;

=head1 NAME

Libs::Log - logovani s urovnemi, filtry podle paketu a merenim casu (delay)

=head1 POPIS

    Zaznam: "[cas] ip [E|W|I|D|d] Paket:radek :: text". Cil (STDOUT/STDERR/soubor) a uroven
    z conf sekce log. Metoda sendErrorReport posila e-mailem report o padu modulu (vyuziva Libs::Send
    a conf pwe.smtp_servers).

=cut

use strict;
use IO::Handle;
use Libs::Send;
use Time::HiRes;

my ($CONF);

=head2 B<[Public] new($conf)>

    Konstruktor logovaciho objektu. Cil zapisu (log.logout): "STDOUT", "STDERR", relativni
    cesta k souboru od pwe.home, nebo undef = /dev/null. Uroven log.loglevel:
    0=vypnuto, 1=error, 2=warning, 3=info, 4=debug. IP se doplnuje az v requestu (setIP).

=cut

sub new {
    my ($class, $conf) = @_;

    $CONF = $conf;

    my $self = {
        'logout' => ($CONF->getValue("log", "logout", undef) ? $CONF->getValue("pwe", "home", "") . $CONF->getValue("log", "logout", undef) : "/dev/null"),
        'loglevel'   => $CONF->getValue("log", "loglevel", 0),
        'delayqueue' => {},
        'ip'         => '127.0.0.1',
        'pid'        => $$,
        'output'     => undef,
    };
    bless $self, $class;
    return $self;
}

=head2 B<[Public] getLogLevel()>

    Metoda vraci aktualni uroven logovani (0-4).

=cut

sub getLogLevel {
    my $self = shift;
    return $self->{'loglevel'};
}

=head2 B<[Public] setLogLevel($level)>

    Metoda nastavi uroven logovani za behu (0-4). Necislo se ignoruje.
    Hodi se napr. pro docasne zapnuti debug vypisu v jedne strance.

=cut

sub setLogLevel {
    my ($self, $level) = @_;
    return if ($level !~ /^\d+$/);
    $self->{'loglevel'} = $level;
}

=head2 B<[Public] setIP($ip)>

    Metoda nastavi IP adresu klienta, ktera se vypisuje v kazdem radku logu.
    Vola ji Libs::User::newRequest na zacatku requestu.

=cut

sub setIP {
    my ($self, $ip) = @_;
    $self->{'ip'} = $ip;
}

=head2 B<[Public] error($msg)>

    Zapise zpravu s prefixem [E] (uroven >= 1). Do zaznamu se automaticky doplni
    paket a radek volajiciho (napr. "Pages::eshop::eshop:123 :: text").

=cut

sub error {
    my ($self, $msg) = @_;
    my $who = sprintf("%s:%d", (caller)[0, 2]);
    $self->write("[E]", "$who :: $msg") if ($self->getLogLevel() > 0 and $self->filterLog('error', $who));
}

=head2 B<[Public] warning($msg)>

    Zapise zpravu s prefixem [W] (uroven >= 2).

=cut

sub warning {
    my ($self, $msg) = @_;
    my $who = sprintf("%s:%d", (caller)[0, 2]);
    $self->write("[W]", "$who :: $msg") if ($self->getLogLevel() > 1 and $self->filterLog('warning', $who));
}

=head2 B<[Public] info($msg)>

    Zapise zpravu s prefixem [I] (uroven >= 3).

=cut

sub info {
    my ($self, $msg) = @_;
    my $who = sprintf("%s:%d", (caller)[0, 2]);
    $self->write("[I]", "$who :: $msg") if ($self->getLogLevel() > 2 and $self->filterLog('info', $who));
}

=head2 B<[Public] debug($msg)>

    Zapise zpravu s prefixem [D] (uroven >= 4).

=cut

sub debug {
    my ($self, $msg) = @_;
    my $who = sprintf("%s:%d", (caller)[0, 2]);
    $self->write("[D]", "$who :: $msg") if ($self->getLogLevel() > 3 and $self->filterLog('debug', $who));
}

=head2 B<[Private] filterLog($method,$who)>

    Rozhodne, zda se zaznam urovne $method (error/warning/info/debug/delay) od volajiciho
    $who ("Paket:radek") zapise: nejdrive excludeLog (blacklist), pak acceptLog (whitelist).

=cut

sub filterLog {
    my ($self, $method, $who) = @_;
    return 0 if (!$self->excludeLog($method, $who));
    return $self->acceptLog($method, $who);
}

=head2 B<[Private] acceptLog($method,$who)>

    Whitelist podle paketu volajiciho. Pokud je neprazdny conf log.<method>_filter_list,
    projde jen paket z nej; jinak pokud je neprazdny log.filter_list, projde jen paket z nej;
    jinak projde vse. Cislo radku se z $who pred porovnanim odstrani.

=cut

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

=head2 B<[Private] excludeLog($method,$who)>

    Blacklist podle paketu volajiciho: log.<method>_exclude_list ma prednost pred log.exclude_list.
    Vraci 0 (zahodit) nebo 1 (pokracovat).

=cut

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

=head2 B<[Public] delay($key,$text)>

    Mereni casu mezi dvema misty v kodu. Funguje jen pri zapnute volbe log.log_delay,
    jinak metoda nic nedela a vraci undef.

    Prvni volani s danym $key si zapamatuje aktualni cas a vraci 0. Druhe volani se stejnym
    $key spocita uplynuly cas v sekundach (5 desetinnych mist), zapise ho do logu s prefixem [d]
    ("Paket:radek :: $key :: $text [ delay : 0.01234/s ]"), mereni pro $key smaze a uplynuly cas
    vraci. Zaznam se zapise jen tehdy, kdyz je cas >= log.log_delay_minimum a projde
    filterLog('delay', ...).

    $LOG->delay("moje_mereni");
    ... mereny kod ...
    my $sec = $LOG->delay("moje_mereni", "popis mereneho useku");

=cut

sub delay {
    my ($self, $key, $text) = @_;

    return unless ($CONF->getValue("log", "log_delay", 0));

    $text = "" unless ($text);

    unless (defined($self->{'delayqueue'}->{$key})) {
        $self->{'delayqueue'}->{$key} = Time::HiRes::time();
        return 0;
    } else {
        my $start = $self->{'delayqueue'}->{$key};
        my $stop  = Time::HiRes::time();
        my $delay = sprintf "%.5f", ($stop - $start);
        my $who   = sprintf("%s:%d", (caller)[0, 2]);
        $self->write("[d]", "$who :: $key :: $text [ delay : $delay/s ]") if ($delay >= $CONF->getValue("log", "log_delay_minimum", 0) and $self->filterLog('delay', $who));
        delete $self->{'delayqueue'}->{$key};
        return $delay;
    }
}

=head2 B<[Private] write($who,$text)>

    Fyzicky zapis jednoho radku "[cas] ip [X] text" na STDOUT/STDERR nebo do souboru
    (soubor se pro kazdy zaznam otevre v rezimu append a zavre). Pri chybe zapisu die.

=cut

sub write {
    my ($self, $who, $text) = @_;

    $text = "$who $text";
    $who =~ s/\s//g;

    my $ip     = $self->{'ip'};
    my $pid    = $self->{'pid'};
    my $logout = $self->{'logout'};
    my $output = $self->{'output'};
    my $time   = scalar localtime(time);

    if ($logout eq $CONF->getValue("pwe", "home", "") . "STDOUT") {
        print STDOUT "[$time] $ip $text\n";
    } elsif ($logout eq $CONF->getValue("pwe", "home", "") . "STDERR") {
        print STDERR "[$time] $ip $text\n";
    } else {
        # soubor drzime otevreny (autoflush); kdyz zmizi (rotace logu), otevreme ho znovu
        my $fh = $self->{'fh'};
        unless ($fh and -e $logout) {
            close($fh) if ($fh);
            open($fh, '>>', $logout) or die "Error Open log:'$logout'";
            $fh->autoflush(1);
            $self->{'fh'} = $fh;
        }
        print $fh "[$time] $ip $text\n" or die "Error Write log:'$logout'";
    }
}

=head2 B<[Private] sendErrorReport($name,$who,$method,$error)>

    Metoda sestavi a odesle e-mailem report o padu modulu. Volaji ji loadery (Libs::Pages,
    Libs::Services, Libs::Sites, Libs::Entities, Libs::Validate, DAO) pri zachyceni die.
    $name je typ modulu ("PAGE", "SERVICE", "SITE", "ENTITY", "VALIDATE", "DAO"), $who nazev
    modulu (napr. nazev stranky), $method spadla metoda a $error text chyby.

    Report obsahuje $name : $who, METHOD, WHERE (paket:radek volajiciho), DATE, text chyby
    po radcich a vypis vsech promennych prostredi (SERVER INFO). Odesilatel i prijemce je
    web.email_admin (vychozi root@localhost), predmet web.email_subtitle + ": PWE error report".
    Zkousi postupne SMTP servery z pwe.smtp_servers (vychozi ["smtp_primary"]; kazdy nazev je
    sekce v conf) a skonci u prvniho, pres ktery se odeslani podari. Vysledek loguje pres info().


    Stejna chyba (kombinace $name:$who:$method) se posila nejvyse jednou za conf
    log.error_report_interval sekund (vychozi 300, 0 = vzdy); potlacene reporty se spocitaji a
    pocet se uvede v dalsim e-mailu. Vraci 1 (report se odeslal nebo se o to pokusil) nebo 0 (potlacen).
=cut

sub sendErrorReport {
    my ($self, $name, $who, $method, $error) = @_;

    my $where = sprintf("%s:%d", (caller)[0, 2]);

    # Stejna chyba se hlasi nejvyse jednou za conf log.error_report_interval sekund (vychozi 300),
    # jinak by rozbita stranka poslala e-mail pri kazdem requestu.
    my $key      = "$name:$who:$method";
    my $interval = $CONF->getValue("log", "error_report_interval", 300);
    my $now      = time();
    if ($interval > 0 and defined($self->{'report_sent'}->{$key}) and ($now - $self->{'report_sent'}->{$key}) < $interval) {
        $self->{'report_suppressed'}->{$key}++;
        $self->info("Error report '$key' suppressed (" . $self->{'report_suppressed'}->{$key} . "x in ${interval}s)");
        return 0;
    }
    my $suppressed = delete($self->{'report_suppressed'}->{$key}) || 0;
    $self->{'report_sent'}->{$key} = $now;

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
    $text .= "| SUPPRESSED : $suppressed same errors since last report \n" if ($suppressed);
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
            $self->info("Trying send email to:$to FAIL, msg:$result");
        } else {
            $self->info("Send error report mail to:$to is completed.");
            last;
        }
    }
    return 1;
}

=head2 B<[Private] KOMODO()>

    Mrtvy kod pro IDE (Komodo/VS Code), aby umelo doplnit typy globalnich promennych.
    Nikdy se nevola - prvni prikaz je return.

=cut

# KOMODO-IDE/KOMODO-EDIT
sub KOMODO {
    return;
    require Libs::Config;
    $CONF = new Libs::Config;
}

1;
