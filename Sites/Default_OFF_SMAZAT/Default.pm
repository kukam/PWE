package Sites::Default::Default;

use strict;

our ($AUTOLOAD);

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

sub new {
    my ($class, $conf, $log, $validate, $dbi, $entities, $user, $web) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $WEB      = $web;
    $CONF     = $conf;
    $USER     = $user;
    $VALIDATE = $validate;
    $ENTITIES = $entities;

    my $self = {};

    bless $self, $class;
    return $self;
}

sub existMessenger        { my $self = shift; return $WEB->existMessenger(@_); }
sub genTmpl               { my $self = shift; return $WEB->genTmpl(@_); }
sub getScriptName         { my $self = shift; return $WEB->getScriptName(@_); }
sub printHtmlLayout       { my $self = shift; return $WEB->printHtmlLayout(@_); }
sub printHtmlHeader       { my $self = shift; return $WEB->printHtmlHeader(@_); }
sub renderReplaceJSON     { my $self = shift; return $WEB->renderReplaceJSON(@_); }
sub printAjaxLayout       { my $self = shift; return $WEB->printAjaxLayout(@_); }
sub printHttpHeader       { my $self = shift; return $WEB->printHttpHeader(@_); }
sub getIDP                { my $self = shift; return $WEB->getIDP(@_); }
sub convertToRewrite      { my $self = shift; return $WEB->convertToRewrite(@_); }
sub getResourceBundleList { my $self = shift; return $WEB->getResourceBundleList(@_); }
sub setIDP                { my $self = shift; return $WEB->setIDP(@_); }
sub findResourceBundles   { my $self = shift; return $WEB->findResourceBundles(@_); }
sub setAjax               { my $self = shift; return $WEB->setAjax(@_); }
sub setMessenger          { my $self = shift; return $WEB->setMessenger(@_); }
sub getValue              { my $self = shift; return $WEB->getValue(@_); }

sub AUTOLOAD {
    my $self = shift;
    my $name = $AUTOLOAD;
    $name =~ s/.*://;
    return if ($name =~ /^DESTROY$/);
    return $WEB->$name(@_);
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
    require Libs::Web;

    $CONF     = new Libs::Config;
    $LOG      = new Libs::Log;
    $VALIDATE = new Libs::Validate;
    $DBI      = new Libs::DBI;
    $ENTITIES = new Libs::Entities;
    $USER     = new Libs::User;
    $WEB      = new Libs::Web;
}

1;
