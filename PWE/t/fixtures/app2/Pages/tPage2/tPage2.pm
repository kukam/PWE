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

1;
