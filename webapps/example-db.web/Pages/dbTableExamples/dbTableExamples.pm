package Pages::dbTableExamples::dbTableExamples;

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB, $TABLE, $ACCOUNT);

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
    $self->{'func'}->{'test'}    = [];

    $self->{'error'}->{'default'} = "error";
    $self->{'error'}->{'form'}    = "error";

    bless $self, $class;
    return $self;
}

sub Site_Default {
    my ($self, $input) = @_;
    $WEB = $input;
}

sub Service_DBTable {
    my ($self, $input) = @_;
    $TABLE = $input;
}

sub Service_Accounts {
    my ($self, $input) = @_;
    $ACCOUNT = $input;
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
    require Services::DBTable::DBTable;
    require Services::Accounts::Accounts;

    $CONF     = new Libs::Config;
    $LOG      = new Libs::Log;
    $VALIDATE = new Libs::Validate;
    $DBI      = new Libs::DBI;
    $ENTITIES = new Libs::Entities;
    $USER     = new Libs::User;
    $WEB      = new Sites::Default::Default;
    $TABLE    = new Services::DBTable::DBTable;
    $ACCOUNT  = new Services::Accounts::Accounts;
}

sub default {
    my $self = shift;

    my $idp = "dbTableExamples";

    my $table = $TABLE->genTable(
        name        => 'table-user-list',
        tmpl        => "Pages/dbTableExamples/accountTable.html",
        query       => "* FROM users",
        conditions  => [],
        ordercolumn => "uid",
        orderby     => "DESC",
        groupby     => "",
        maxrow      => 7,
    );

    # SET ID Page
    $WEB->setIDP($idp);
    if ($USER->getParam("ajax_request", 0, undef)) {
        $WEB->printHttpHeader('type' => 'ajax');
        $WEB->printAjaxLayout(
            ajax_id => [(defined($table->{'name'}) ? $table->{'name'} : $table->{'id'})],
            ajax_tmpl => [$table->{'tmpl'}],
            ajax_data => {table => $table,},
        );
    } else {
        $WEB->printHttpHeader();
        $WEB->printHtmlHeader();
        $WEB->printHtmlLayout(
            'html_main' => "Pages/dbTableExamples/main.html",
            'table'     => $table,
        );
    }
}

sub form {
    my $self = shift;

    my $uid = $USER->getParam('uid');
    my $act = $USER->getParam('active');

    my $result = $ACCOUNT->setAccount(
        fullname => $USER->getParam("fullname", 0, undef),
        active   => $act,
        uid      => $uid,
    );

    if ($uid) {
        if ($result and $act eq 't' ) {
            $WEB->setMessenger("Pages/formExamples/msg.html", msg_allright => ['enable_active_status'], disable_scrolltomessenger => 1 );
        } elsif ($result and $act eq 'f' ) {
            $WEB->setMessenger("Pages/formExamples/msg.html", msg_allright => ['disable_active_status'], disable_scrolltomessenger => 1 );
        } else {
            $WEB->setMessenger("Pages/ajaxExamples/msg.html", msg_error => ['error_active_status']);
        }

        # PRINT AJAX HTMLSimple
        $WEB->printHttpHeader('type' => 'ajax');
        $WEB->printAjaxLayout(
            ajax_id   => ["columnid-$uid"],
            ajax_tmpl => ["Pages/dbTableExamples/activebtn.html"],
            ajax_data => {
                active => $act,
                enable_ajax => 1,
                href   => $WEB->getScriptName() . '?page=dbTableExamples&func=form&uid=' . $uid . '&active='
            },
        );
    } else {
        $WEB->setMessenger("Pages/formExamples/msg.html", msg_allright => ['ok_account_created']);
        $WEB->printHttpHeader(type => 'ajax_redirect', 'redirect_link' => $WEB->getScriptName() . '?page=dbTableExamples&func=default');
    }
}

sub error {
    my ($self, $error) = @_;
    $WEB->setMessenger("Pages/dbTableExamples/msg.html", msg_error => $error);
    if ($USER->getParam("ajax_request", 0, undef)) {
        return 400;
    } else {
        $self->default();
    }
}

1;
