package Pages::NewBootstrap523::NewBootstrap523;

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

    bless $self, $class;
    return $self;
}

sub Site_NewBootstrap523 {
    my ($self, $input) = @_;
    $WEB = $input;
}

sub default {
    my $self = shift;

    my $idp = "NewBootstrap523_page";

    # SET ID Page
    $WEB->setIDP($idp);
    $WEB->printHttpHeader();
    $WEB->printHtmlHeader();
    $WEB->printHtmlLayout(html_main => "Pages/NewBootstrap523/main.html",);
}

1;
