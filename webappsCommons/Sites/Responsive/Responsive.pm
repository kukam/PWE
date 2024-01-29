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
        'web_site'      => "responsive",
        'web_index'     => "/responsive",
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

1;
