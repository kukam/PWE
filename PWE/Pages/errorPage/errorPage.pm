package Pages::errorPage::errorPage;

=head1 NAME

Pages::errorPage::errorPage - systemova stranka chybovych odpovedi (400, 401, 404, 500, cgi_error)

=cut

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

=head2 B<[Public] new($self,$conf,$log,$validate,$dbi,$entities,$user,$web)>

    Systemova stranka chybovych odpovedi. Funkce e400, e401, e404, e500 a cgi_error vola
    pwe.fcgi podle navratove hodnoty callPageFunc (nebo chyby CGI). Stranka musi existovat
    v kazdem webappu (typicky symlink na enginovou).

=cut

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

=head2 B<[Private] Site_Default($site)>

    Injektaz vzhledu Default (vola loader).

=cut

sub Site_Default {
    my ($self, $input) = @_;
    $WEB = $input;
}

=head2 B<[Private] KOMODO()>

    Mrtvy kod pro IDE (Komodo/VS Code), aby umelo doplnit typy globalnich promennych.
    Nikdy se nevola - prvni prikaz je return.

=cut

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

=head2 B<[Public] e400()>

    Vykresli chybovou stranku 400 (spatny parametr) s messengerem error_bad_parameter,
    pokud uz stranka messenger nenastavila. Layouty z conf http.layout_error_header/body.

=cut

sub e400 {
    my $self = shift;

    my $idp = "e400";

    # SET ID Page
    $WEB->setIDP($idp);

    unless ($WEB->existMessenger()) {
        $WEB->setMessenger($CONF->getValue('http', 'layout_error_msg', "Pages/errorPage/msg.html"), msg_error => ['error_bad_parameter']);
    }

    $WEB->printHttpHeader('type' => 'error', 'status' => 400);
    $WEB->printHtmlHeader('title' => '400 Bad parameter', 'layout_header' => $CONF->getValue('http', 'layout_error_header', "templates/LayoutErrorHeader.html"));
    $WEB->printHtmlLayout('layout_body' => $CONF->getValue('http', 'layout_error_body', "templates/LayoutErrorBody.html"));
}

=head2 B<[Public] e401()>

    Vykresli chybovou stranku 401 (pristup odepren), messenger error_access_denied.

=cut

sub e401 {
    my $self = shift;

    my $idp = "e401";

    # SET ID Page
    $WEB->setIDP($idp);

    unless ($WEB->existMessenger()) {
        $WEB->setMessenger($CONF->getValue('http', 'layout_error_msg', "Pages/errorPage/msg.html"), msg_error => ['error_access_denied']);
    }

    $WEB->printHttpHeader('type' => 'error', 'status' => '401');
    $WEB->printHtmlHeader('title' => '401 Access denied', 'layout_header' => $CONF->getValue('http', 'layout_error_header', "templates/LayoutErrorHeader.html"));
    $WEB->printHtmlLayout('layout_body' => $CONF->getValue('http', 'layout_error_body', "templates/LayoutErrorBody.html"));

}

=head2 B<[Public] e404()>

    Vykresli chybovou stranku 404 (stranka nenalezena), messenger error_page_not_found.

=cut

sub e404 {
    my $self = shift;

    my $idp = "e404";

    # SET ID Page
    $WEB->setIDP($idp);

    unless ($WEB->existMessenger()) {
        $WEB->setMessenger($CONF->getValue('http', 'layout_error_msg', "Pages/errorPage/msg.html"), msg_error => ['error_page_not_found']);
    }

    $WEB->printHttpHeader('type' => 'error', 'status' => 404);
    $WEB->printHtmlHeader('title' => '404 Page not found', 'layout_header' => $CONF->getValue('http', 'layout_error_header', "templates/LayoutErrorHeader.html"));
    $WEB->printHtmlLayout('layout_body' => $CONF->getValue('http', 'layout_error_body', "templates/LayoutErrorBody.html"));
}

=head2 B<[Public] e500()>

    Vykresli chybovou stranku 500 (interni chyba/pad metody), messenger error_hups.

=cut

sub e500 {
    my $self = shift;

    my $idp = "e500";

    # SET ID Page
    $WEB->setIDP($idp);

    unless ($WEB->existMessenger()) {
        $WEB->setMessenger($CONF->getValue('http', 'layout_error_msg', "Pages/errorPage/msg.html"), msg_error => ['error_hups']);
    }

    $WEB->printHttpHeader('type' => 'error', 'status' => '500');
    $WEB->printHtmlHeader('title' => '500 Internal error', 'layout_header' => $CONF->getValue('http', 'layout_error_header', "templates/LayoutErrorHeader.html"));
    $WEB->printHtmlLayout('layout_body' => $CONF->getValue('http', 'layout_error_body', "templates/LayoutErrorBody.html"));

}

=head2 B<[Public] cgi_error()>

    Vykresli chybu z CGI (napr. "413 Request entity too large" pri prekroceni cgi_maxfilesize);
    status se vezme z cisla na zacatku textu chyby (parametr cgi_error).

=cut

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
    $WEB->printHtmlHeader('title' => "$error CGI Error", 'status' => $error, 'layout_header' => $CONF->getValue('http', 'layout_error_header', "templates/LayoutErrorHeader.html"));
    $WEB->printHtmlLayout('layout_body' => $CONF->getValue('http', 'layout_error_body', "templates/LayoutErrorBody.html"));

}

1;
