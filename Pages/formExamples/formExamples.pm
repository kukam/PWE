package Pages::formExamples::formExamples;

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
    $VALIDATE = $validate;
    $VALIDATE = $validate;
    $ENTITIES = $entities;

    $self->{'func'}->{'default'} = [];
    $self->{'func'}->{'form'}    = [];

    # Musi byt definovano!
    $self->{'defined'} = {form => {parameters => ['email', 'fullname'],},};

    $self->{'error'}->{'form'} = "error";

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

    my $idp = "formExamples";

    # SET ID Page
    $WEB->setIDP($idp);
    $WEB->printHttpHeader();
    $WEB->printHtmlHeader();
    $WEB->printHtmlLayout(html_main => "Pages/formExamples/main.html");
}

sub form {
    my $self = shift;

    my $email     = $USER->getParam("email",     0, undef);
    my $fullname  = $USER->getParam("fullname",  0, undef);
    my $checkbox  = $USER->getParam("checkbox",  0, 'N');
    my $selectbox = $USER->getParam("selectbox", 0, undef);
    my $button    = $USER->getParam("button1",   0, $USER->getParam("button2", 0, undef));

    my $all_right = ['correct_form', 'form_dump_email', 'form_dump_fullname', 'form_dump_checkbox', 'form_dump_selectbox', 'form_dump_button'];

    if ($USER->isdefinedParam('file_single') or $USER->isdefinedParam('file_multiple')) {

        my $home       = $CONF->getValue("pwe", "home",       "/tmp");
        my $upload_dir = $CONF->getValue("pwe", "upload_dir", "upload_dir/");

        unless (-d $upload_dir) {
            mkdir($upload_dir);
        }

        unless (-f $upload_dir . "/.htaccess") {
            open(HTACCESS, '>' . $upload_dir . "/.htaccess") or die "Failed: $!\n";
            print HTACCESS "Options +Indexes\n";
            print HTACCESS "Order Allow,Deny\n";
            print HTACCESS "Allow From All\n";
            close(HTACCESS);
        }

        # ULOZIME SOUBORY
        my ($is_single_file_error,   @filelist_singl)    = ($USER->isdefinedParam('file_single')   ? $USER->saveUploadFile('file_single',   $home, $upload_dir, 1) : undef);
        my ($is_multiple_file_error, @filelist_multiple) = ($USER->isdefinedParam('file_multiple') ? $USER->saveUploadFile('file_multiple', $home, $upload_dir, 1) : undef);

        # VZNIKLA CHYBA?
        if ($is_single_file_error or $is_multiple_file_error) {
            my $msg_error = [];
            push(@{$msg_error}, $is_single_file_error)   if (defined($is_single_file_error));
            push(@{$msg_error}, $is_multiple_file_error) if (defined($is_multiple_file_error));
            $WEB->setMessenger("Pages/formExamples/msg.html", msg_error => $msg_error);
        } else {
            push(@{$all_right}, 'form_dump_browse_files');
            my $browse_url = $CONF->getValue("pwe", "upload_dir", "upload_dir/");
            $WEB->setMessenger("Pages/formExamples/msg.html", msg_allright => $all_right, email => $email, fullname => $fullname, checkbox => $checkbox, selectbox => $selectbox, button => $button, browse_url => $browse_url);
        }
    } else {
        $WEB->setMessenger("Pages/formExamples/msg.html", msg_allright => $all_right, email => $email, fullname => $fullname, checkbox => $checkbox, selectbox => $selectbox, button => $button);
    }

    if ($USER->getParam("ajax_request", 0, undef)) {

        #code
        $WEB->printHttpHeader('type' => 'ajax');
        $WEB->printAjaxLayout();
    } else {
        $self->default();
    }
}

sub error {
    my ($self, $error) = @_;
    $WEB->setMessenger("Pages/formExamples/msg.html", msg_error => $error);
    if ($USER->getParam("ajax_request", 0, undef)) {
        return 400;
    } else {
        $self->default();
    }
}

1;
