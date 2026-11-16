package Pages::tPage2::tPage2;

# Testovaci stranka fixture webu app2 (web mimo engine): pouziva vzhled Default a sablony z enginu.

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

sub new {
    my ($class, $self, $conf, $log, $validate, $dbi, $entities, $user, $web) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $CONF     = $conf;
    $USER     = $user;
    $WEB      = $web;
    $VALIDATE = $validate;
    $ENTITIES = $entities;

    $self->{'func'}->{'default'} = [];
    $self->{'func'}->{'roots'}   = [];
    $self->{'func'}->{'slow'}    = [];
    $self->{'func'}->{'plen'}    = [];

    bless $self, $class;
    return $self;
}

sub Site_Default {
    my ($self, $input) = @_;
    $WEB = $input;
}

# KOMODO-IDE/KOMODO-EDIT
sub KOMODO {
    return;
    require Libs::Config;
    require Libs::Log;
    require Libs::Validate;
    require Libs::DBI;
    require Libs::Entities;
    require Libs::User;
    require Sites::Default::Default;
    $CONF     = new Libs::Config;
    $LOG      = new Libs::Log;
    $VALIDATE = new Libs::Validate;
    $DBI      = new Libs::DBI;
    $ENTITIES = new Libs::Entities;
    $USER     = new Libs::User;
    $WEB      = new Sites::Default::Default;
}

sub default {
    my $self = shift;
    $WEB->setIDP("tpage2");
    $WEB->printHttpHeader();
    $WEB->printHtmlHeader();
    $WEB->printHtmlLayout(html_main => "Pages/tPage2/main.html");
}

# Vypise koreny enginu (pro testy).
sub roots {
    my $self = shift;
    $WEB->printHttpHeader('type' => 'plain');
    print "HOME=" . $CONF->getHome() . "\nCORE=" . $CONF->getCore() . "\n";
}

# Pomaly request pro testy ukoncovani enginu (t/24-shutdown.t). Parametry:
#   mark = nazev adresare se znackami pod ramdisk/ (zaklada ho test)
#   sec  = jak dlouho nejdele cekat (vychozi 20 s)
#   size = velikost tela odpovedi v kB (vychozi 0)
# Zalozi znacku ramdisk/<mark>/slow.started a ceka, az test zalozi ramdisk/<mark>/slow.release (signal
# cekani neukonci). Pak vypise, zda se dockal, stav databazovych spojeni (ping) a telo dane velikosti
# zakoncene radkem SLOW-END - test podle nej pozna, ze dostal celou odpoved.
sub slow {
    my $self = shift;
    my $mark = $USER->getParam('mark', 0, '');
    my $sec  = $USER->getParam('sec',  0, 20);
    my $size = $USER->getParam('size', 0, 0);
    return 400 unless ($mark =~ /^[\w-]+$/ and $sec =~ /^\d+$/ and $size =~ /^\d+$/);

    my $dir = $CONF->getHome() . "ramdisk/$mark";
    open(my $fh, '>>', "$dir/slow.started") or return 400;
    close($fh);

    my $end      = time + $sec;
    my $released = 0;
    until ($released = (-e "$dir/slow.release") ? 1 : 0) {
        last if (time > $end);
        select(undef, undef, undef, 0.02);
    }

    $WEB->printHttpHeader('type' => 'plain');
    print "SLOW released=$released\n";
    print "DB " . join(',', map { "$_=" . ($DBI->ping($_, 0) ? 1 : 0) } sort @{$DBI->getDbidList()}) . "\n";
    for (1 .. $size) { print(('x' x 1023) . "\n"); }
    print "SLOW-END\n";
}

# Vypise delku parametru data a hodnotu parametru tail (t/24-shutdown.t: telo POST, ktere dorazi
# az po signalu TERM, musi stranka dostat cele).
sub plen {
    my $self = shift;
    $WEB->printHttpHeader('type' => 'plain');
    print "PLEN len=" . length($USER->getParam('data', 0, '')) . " tail=" . $USER->getParam('tail', 0, '') . "\n";
}

1;
