package Pages::ajaxExamples::ajaxExamples;

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

    $self->{'func'}->{'default'}                = [];
    $self->{'func'}->{'replaceHTMLSimple'}      = [];
    $self->{'func'}->{'replaceHTML'}            = [];
    $self->{'func'}->{'redirectAjax'}           = [];
    $self->{'func'}->{'redirectAjax2'}          = [];
    $self->{'func'}->{'replaceHTMLSimpleError'} = [];
    $self->{'func'}->{'replaceHTMLError'}       = [];

    bless $self, $class;
    return $self;
}

sub Site_NewBootstrap523 {
    my ($self, $input) = @_;
    $WEB = $input;
    return undef;
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

    my $idp = "ajaxExamples";

    # SET ID Page
    $WEB->setIDP($idp);
    $WEB->printHttpHeader();
    $WEB->printHtmlHeader();
    $WEB->printHtmlLayout(html_main => "Pages/ajaxExamples/main.html",);
}

sub replaceHTMLSimple {
    my $self = shift;

    $WEB->printHttpHeader();
    print $self->getRandomSpan();
}

sub replaceHTML {
    my $self = shift;

    $WEB->printHttpHeader('type' => 'ajax');
    $WEB->printAjaxLayout(
        ajax_id => ['replaceHTML_I', 'replaceHTML_II'],
        ajax_html => [$self->getRandomSpan(), $self->getRandomSpan(), $self->getRandomSpan(), $self->getRandomSpan()]
    );
}

sub redirectAjax {
    my $self = shift;
    $WEB->printHttpHeader('type' => 'ajax_redirect', 'redirect_link' => $WEB->getScriptName());
}

sub redirectAjax2 {
    my $self = shift;
    $WEB->setMessenger("Pages/ajaxExamples/msg.html", msg_allright => ['ok_redirect2']);
    $WEB->printHttpHeader('type' => 'ajax_redirect', 'redirect_link' => $WEB->getScriptName());
}

sub replaceHTMLSimpleError {
    my $self = shift;

    $WEB->setMessenger("Pages/ajaxExamples/msg.html", msg_error => ['error_replaceHtmlSimple']);

    return 500;
}

sub replaceHTMLError {
    my $self = shift;

    $WEB->setMessenger("Pages/ajaxExamples/msg.html", msg_error => ['error_replaceHtml']);

    return 500;
}

sub getRandomSpan {
    my $self = shift;
    my $map  = {
        1 => "label-default",
        2 => "label-primary",
        3 => "label-success",
        4 => "label-info",
        5 => "label-warning",
        6 => "label-danger"
    };
    return '<span class="label ' . $map->{(int(rand(6)) + 1)} . '">' . time() . '</span>';
}

1;
