package Sites::Error::Error;
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
        'web_site'      => "error",
        'web_index'     => "/error",
        'layout_header' => "Sites/Error/layout_header.html",
        'layout_body'   => "Sites/Error/layout_body.html",
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

sub AUTOLOAD {
    my $self = shift;
    my $name = $AUTOLOAD;
    $name =~ s/.*://;
    return if ($name =~ /^DESTROY$/);
    return $WEB->$name(@_);
}

1;