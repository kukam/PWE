package Sites::Responsive::Responsive;

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
        'web_site'      => "responisve",
        'web_index'     => "/responisve ",
        'layout_header' => "Sites/Responsive/layout_header.html",
        'layout_body'   => "Sites/Responsive/layout_body.html",
    };

    bless $self, $class;
    return $self;
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

    $WEB->printHtmlLayout(%tmpl);
}

sub AUTOLOAD {
    my $self = shift;
    my $name = $AUTOLOAD;
    $name =~ s/.*://;
    return if ($name =~ /^DESTROY$/);
    return $WEB->$name(@_);
}

1;
