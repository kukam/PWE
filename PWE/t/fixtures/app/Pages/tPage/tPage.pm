package Pages::tPage::tPage;

# Testovaci stranka pro t/*.t - pokryva routing, DI, validaci, AJAX a pad metody.

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB, $TSERVICE);

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
    $self->{'func'}->{'form'}    = [];
    $self->{'func'}->{'secret'}  = ['admin'];
    $self->{'func'}->{'crash'}   = [];
    $self->{'func'}->{'status'}  = [];
    $self->{'func'}->{'ajax'}    = [];
    $self->{'func'}->{'msg'}     = [];

    $self->{'error'}->{'form'} = "error";

    $self->{'defined'} = {form => {parameters => ['email', 'name||nick', 'if[kind="P"]person']}};

    $self->{'rules'}->{'form'}->{'email'} = [['is_email', 'error_email', 'parameter']];
    $self->{'rules'}->{'form'}->{'age'}   = [['Services::tService::is_adult', 'error_age', 'parameter']];
    $self->{'rules'}->{'form'}->{'code'}  = [['Pages::tPage::is_code', 'error_code', 'parameter']];

    $self->{'replace'}->{'form'} = {'*ALL*' => ['escape_jsinjection']};

    # atribut validate bez klice entity -> engine vraci interni chybu (musi byt pole, regrese)
    $self->{'func'}->{'badvalidate'}     = [];
    $self->{'error'}->{'badvalidate'}    = "error";
    $self->{'validate'}->{'badvalidate'} = [{parameters => ['x']}];

    bless $self, $class;
    return $self;
}

sub Site_Default {
    my ($self, $input) = @_;
    $WEB = $input;
}

sub Service_tService {
    my ($self, $input) = @_;
    $TSERVICE = $input;
}

sub autostart {
    my $self = shift;
    $self->{'autostarted'} = 1;
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
    require Services::tService::tService;
    $CONF     = new Libs::Config;
    $LOG      = new Libs::Log;
    $VALIDATE = new Libs::Validate;
    $DBI      = new Libs::DBI;
    $ENTITIES = new Libs::Entities;
    $USER     = new Libs::User;
    $WEB      = new Sites::Default::Default;
    $TSERVICE = new Services::tService::tService;
}

sub default {
    my $self = shift;
    $WEB->setIDP("tpage");
    $WEB->printHttpHeader();
    $WEB->printHtmlHeader(title => 'TPAGE TITLE');
    $WEB->printHtmlLayout(html_main => "Pages/tPage/main.html", hello => 'world');
}

sub form {
    my ($self, $error) = @_;
    $self->{'last_form_error'} = $error;
    $WEB->printHttpHeader('type' => 'plain');
    print "FORM OK email=" . $USER->getParam('email', 0, '') . " adult=" . ($TSERVICE ? $TSERVICE->is_adult($USER->getParam('age', 0, 0)) || 0 : 'noservice');
}

sub error {
    my ($self, $error) = @_;
    $self->{'last_error'} = $error;
    $WEB->printHttpHeader('type' => 'plain');
    print "ERROR:" . join(',', sort @{$error});
}

sub secret {
    my $self = shift;
    $WEB->printHttpHeader('type' => 'plain');
    print "SECRET";
}

sub crash {
    my $self = shift;
    die "boom";
}

sub badvalidate {
    my $self = shift;
    $WEB->printHttpHeader('type' => 'plain');
    print "BADVALIDATE";
}

sub status {
    my $self = shift;
    return 404;
}

sub ajax {
    my $self = shift;
    $WEB->printHttpHeader('type' => 'ajax');
    $WEB->printAjaxLayout(ajax_id => ['a', 'b'], ajax_html => ['<b>A</b>', 'B']);
}

sub msg {
    my $self = shift;
    $WEB->setMessenger("Pages/tPage/msg.html", msg_allright => ['ok_saved']);
    $WEB->printHttpHeader('type' => 'ajax');
    $WEB->printAjaxLayout();
}

# Validacni metoda pouzivana z rules (Pages::tPage::is_code)
sub is_code {
    my ($self, $value) = @_;
    return (($value =~ /^[A-Z]{3}$/) ? $value : undef);
}

1;
