package Sites::Default::Default;

use strict;

our ($AUTOLOAD);

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB, $SESSION);

sub new {
    my ($class, $conf, $log, $validate, $dbi, $entities, $user, $web) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $WEB      = $web;
    $CONF     = $conf;
    $USER     = $user;
    $VALIDATE = $validate;
    $ENTITIES = $entities;

    my $self = {
        'web_site'      => "default",
        'web_index'     => "/default",
        'layout_header' => "Sites/Default/layout_header.html",
        'layout_body'   => "Sites/Default/layout_body.html",
    };

    bless $self, $class;
    return $self;
}

sub Service_Session {
    my ($self, $input) = @_;
    $SESSION = $input;
}

sub getDefaultTemplateValues {
    my $self = shift;

    my %hash;

    my $uid = $USER->getUid;
    my $sid = $USER->getSid;

    $hash{'web_site'}    = $self->{'web_site'};
    $hash{'web_index'}   = $self->{'web_index'};
    $hash{'layout_body'} = $self->{'layout_body'};

    return %hash;
}

sub printHtmlHeader {
    my ($self, %tmpl) = @_;

    $tmpl{'layout_header'} = $self->{'layout_header'} unless (exists($tmpl{'layout_header'}));
    $tmpl{'css'} = $CONF->getValue("css", "src_css", "static");

    $WEB->printHtmlHeader(%tmpl);
}

sub printHtmlLayout {
    my ($self, %tmpl) = @_;

    my %def = $self->getDefaultTemplateValues();

    # SET default vaules
    foreach my $key (keys %def) {
        $tmpl{$key} = $def{$key} unless (exists($tmpl{$key}));
    }

    if ($self->existMessenger()) {
        $tmpl{'messenger'} = $self->getMessenger();
    }

    $WEB->printHtmlLayout(%tmpl);
}

sub printAjaxLayout {
    my ($self, %tmpl) = @_;

    if ((ref($tmpl{'ajax_tmpl'}) eq "ARRAY") and (ref($tmpl{'ajax_id'}) eq "ARRAY")) {

        my %defvalue = $self->getDefaultTemplateValues();

        if (ref($tmpl{'ajax_data'}) ne "ARRAY") {
            if (ref($tmpl{'ajax_data'}) eq "HASH") {
                $tmpl{'ajax_data'} = [$tmpl{'ajax_data'}];
            } else {
                $LOG->error("Invalid set AjaxLayout data !");
                $tmpl{'ajax_data'} = [{}];
            }
        }

        my $i = 0;
        foreach (@{$tmpl{'ajax_data'}}) {
            my $hash = @{$tmpl{'ajax_data'}}[$i];
            foreach my $key (keys %defvalue) {
                $hash->{$key} = $defvalue{$key} unless (exists($hash->{$key}));
            }
            @{$tmpl{'ajax_data'}}[$i] = $hash;
            $i++;
        }
    }

    # SET messenger
    if ($self->existMessenger()) {
        $self->setAjax("messenger", $self->getMessenger());
    }

    $WEB->printAjaxLayout(%tmpl);
}

=head2 B<[Public] getMessenger()>

   Ziskame data pro messenger.
   Metoda premosti zapisy a cteni messengru z Libs::User na Service::UserAccount::UserAccount

=cut

sub getMessenger {
    my $self = shift;
    my $msg = $SESSION->getValue('messenger');
    $SESSION->setValue('messenger',undef);
    return $msg;
}

=head2 B<[Public] setMessenger($tmpl,%tmpl)>

    Zapiseme data (messenger) pro HTML
    Metoda premosti zapisy a cteni messengru z Libs::User na Service::UserAccount::UserAccount

=cut

sub setMessenger {
    my ($self, $msg, %tmpl) = @_;
    my $messenger = $WEB->genTmpl($msg, %tmpl);
    $SESSION->setValue('messenger',$messenger);
}

=head2 B<[Public] existMessenger()>

    Metoda vraci informaci o nasetovanem messengru (1/undef)
    Metoda premosti zapisy a cteni messengru z Libs::User na Service::UserAccount::UserAccount

=cut

sub existMessenger {
    my $self = shift;
    return $SESSION->existKeyValue('messenger');
}

sub getValue              { my $self = shift; return $WEB->getValue(@_); }
sub findResourceBundles   { my $self = shift; return $WEB->findResourceBundles(@_); }
sub getResourceBundleList { my $self = shift; return $WEB->getResourceBundleList(@_); }
sub genTmpl               { my $self = shift; return $WEB->genTmpl(@_); }
sub printHttpHeader       { my $self = shift; return $WEB->printHttpHeader(@_); }
sub convertToRewrite      { my $self = shift; return $WEB->convertToRewrite(@_); }
sub renderReplaceJSON     { my $self = shift; return $WEB->renderReplaceJSON(@_); }
sub setAjax               { my $self = shift; return $WEB->setAjax(@_); }
sub getScriptName         { my $self = shift; return $WEB->getScriptName(@_); }
sub setIDP                { my $self = shift; return $WEB->setIDP(@_); }

# KOMODO-IDE/KOMODO-EDIT
sub KOMODO {
    return;
    require Libs::Config;
    require Libs::Log;
    require Libs::Validate;
    require Libs::DBI;
    require Libs::Web;
    require Libs::Entities;
    require Services::Session::Session;

    $CONF     = new Libs::Config;
    $LOG      = new Libs::Log;
    $VALIDATE = new Libs::Validate;
    $ENTITIES = new Libs::Entities;
    $DBI      = new Libs::DBI;
    $WEB      = new Libs::Web;
    $SESSION  = new Services::Session::Session;
}

1;
