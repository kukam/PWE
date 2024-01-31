package Pages::errorPage::errorPage;

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

sub new {
    my ($class, $self, $conf, $log, $validate, $dbi, $entities, $user, $web) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $WEB      = $web;
    $CONF     = $conf;
    $USER     = $user;
    $VALIDATE = $validate;
    $ENTITIES = $entities;

    $self->{'func'}->{'e400'}      = [];
    $self->{'func'}->{'e401'}      = [];
    $self->{'func'}->{'e404'}      = [];
    $self->{'func'}->{'e500'}      = [];
    $self->{'func'}->{'cgi_error'} = [];

    bless $self, $class;
    return $self;
}

sub Site_Error {
    my ($self, $input) = @_;
    $WEB = $input;
}

sub e400 {
    my $self = shift;

    my $idp = "e400";

    # SET ID Page
    $WEB->setIDP($idp);

    unless ($WEB->existMessenger()) {
        $WEB->setMessenger($CONF->getValue('http', 'layout_error_msg', "Pages/errorPage/msg.html"), msg_error => ['error_bad_parameter']);
    }

    $WEB->printHttpHeader('type' => 'error', 'status' => 400);
    $WEB->printHtmlHeader('title' => '400 Bad parameter');
    $WEB->printHtmlLayout(html_main => "Pages/errorPage/main.html");
}

sub e401 {
    my $self = shift;

    my $idp = "e401";

    # SET ID Page
    $WEB->setIDP($idp);

    unless ($WEB->existMessenger()) {
        $WEB->setMessenger($CONF->getValue('http', 'layout_error_msg', "Pages/errorPage/msg.html"), msg_error => ['error_access_denied']);
    }

    $WEB->printHttpHeader('type' => 'error', 'status' => '401');
    $WEB->printHtmlHeader('title' => '401 Access denied');
    $WEB->printHtmlLayout(html_main => "Pages/errorPage/main.html");

}

sub e404 {
    my $self = shift;

    my $idp = "e404";

    # SET ID Page
    $WEB->setIDP($idp);

    unless ($WEB->existMessenger()) {
        $WEB->setMessenger($CONF->getValue('http', 'layout_error_msg', "Pages/errorPage/msg.html"), msg_error => ['error_page_not_found']);
    }

    $WEB->printHttpHeader('type' => 'error', 'status' => 404);
    $WEB->printHtmlHeader('title' => '404 Page not found');
    $WEB->printHtmlLayout(html_main => "Pages/errorPage/main.html");
}

sub e500 {
    my $self = shift;

    my $idp = "e500";

    # SET ID Page
    $WEB->setIDP($idp);

    unless ($WEB->existMessenger()) {
        $WEB->setMessenger($CONF->getValue('http', 'layout_error_msg', "Pages/errorPage/msg.html"), msg_error => ['error_hups']);
    }

    $WEB->printHttpHeader('type' => 'error', 'status' => '500');
    $WEB->printHtmlHeader('title' => '500 Internal error');
    $WEB->printHtmlLayout(html_main => "Pages/errorPage/main.html");

}

sub cgi_error {
    my $self = shift;

    my $idp = "cgi_error";

    # SET ID Page
    $WEB->setIDP($idp);

    my $error = $USER->getParam("cgi_error", 0, undef);

    unless ($WEB->existMessenger()) {
        $WEB->setMessenger($CONF->getValue('http', 'layout_error_msg', "Pages/errorPage/msg.html"), msg_error => ['error_cgi_error'], cgi_error => $error);
    }

    $error =~ s/^(\d+).*/$1/;

    $WEB->printHttpHeader('type' => 'error', 'status' => $error);
    $WEB->printHtmlHeader('title' => "$error CGI Error", 'status' => $error);
    $WEB->printHtmlLayout(html_main => "Pages/errorPage/main.html");

}

1;
