package Pages::default::default;

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

    $self->{'func'}->{'default'}     = [];
    $self->{'func'}->{'setlanguage'} = [];

    $self->{'rules'}->{'setlanguage'}->{'lang'} = [['is_language', 'error_language', 'parameter'],];

    bless $self, $class;
    return $self;
}

sub Site_Default {
    my ($self, $input) = @_;
    $WEB = $input;
}

sub Service_UserAccount {
    my ($self, $input) = @_;
    $USER = $input;
}

sub default {
    my $self = shift;

    my $idp = "default_page";

    # SET ID Page
    $WEB->setIDP($idp);
    $WEB->printHttpHeader();
    $WEB->printHtmlHeader();
    $WEB->printHtmlLayout(html_main => "Pages/default/main.html");
}

sub setlanguage {
    my ($self, $error) = @_;

    if ($error) {
        $WEB->setMessenger("Pages/default/msg.html", msg_error => $error);
    } else {
        my $lang = $USER->getParam("lang", 0, "CZE");
        $USER->setLanguage($lang);
    }

    $self->default();
}

1;
