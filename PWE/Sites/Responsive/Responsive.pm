package Sites::Responsive::Responsive;

=head1 NAME

Sites::Responsive::Responsive - ukazkovy responzivni vzhled (Bootstrap 3) s vlastnimi layouty

=cut

use strict;

our ($AUTOLOAD);

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB, $SESSION);

=head2 B<[Public] new($conf,$log,$validate,$dbi,$entities,$user,$web)>

    Ukazkovy responzivni vzhled (Bootstrap 3) s vlastnimi layouty Sites/Responsive/layout_header.html
    a layout_body.html. Do stranek se injektuje metodou Site_Responsive.

=cut

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

=head2 B<[Public] getDefaultTemplateValues()>

    Vraci hash vychozich promennych sablon (web_site, web_index, layout_body), ktere se doplni
    do kazdeho printHtmlLayout, pokud je stranka sama nepreda.

=cut

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

=head2 B<[Public] printHtmlHeader(%tmpl)>

    Vytiskne hlavicku HTML s layoutem vzhledu (pokud stranka nepreda vlastni layout_header)
    a promennou css (conf css.src_css).

=cut

sub printHtmlHeader {
    my ($self, %tmpl) = @_;

    $tmpl{'layout_header'} = $self->{'layout_header'} unless (exists($tmpl{'layout_header'}));
    $tmpl{'css'} = $CONF->getValue("css", "src_css", "static");

    $WEB->printHtmlHeader(%tmpl);
}

=head2 B<[Public] printHtmlLayout(%tmpl)>

    Doplni vychozi promenne (getDefaultTemplateValues) a vytiskne telo pres Libs::Web.

=cut

sub printHtmlLayout {
    my ($self, %tmpl) = @_;

    my %def = $self->getDefaultTemplateValues();

    # SET default vaules
    foreach my $key (keys %def) {
        $tmpl{$key} = $def{$key} unless (exists($tmpl{$key}));
    }

    $WEB->printHtmlLayout(%tmpl);
}

=head2 B<[Public] getValue($key,$def)>

    Deleguje na Libs::Web::getValue.

=cut

sub getValue              { my $self = shift; return $WEB->getValue(@_); }

=head2 B<[Public] findResourceBundles(...)>

    Deleguje na Libs::Web (metoda v Libs::Web aktualne neexistuje, ponechano kvuli kompatibilite).

=cut

sub findResourceBundles   { my $self = shift; return $WEB->findResourceBundles(@_); }

=head2 B<[Public] getResourceBundleList($page,$lang)>

    Deleguje na Libs::Web::getResourceBundleList.

=cut

sub getResourceBundleList { my $self = shift; return $WEB->getResourceBundleList(@_); }

=head2 B<[Public] genTmpl($src,%tmpl)>

    Deleguje na Libs::Web::genTmpl.

=cut

sub genTmpl               { my $self = shift; return $WEB->genTmpl(@_); }

=head2 B<[Public] printHttpHeader(%tmpl)>

    Deleguje na Libs::Web::printHttpHeader.

=cut

sub printHttpHeader       { my $self = shift; return $WEB->printHttpHeader(@_); }

=head2 B<[Public] convertToRewrite($value)>

    Deleguje na Libs::Web::convertToRewrite.

=cut

sub convertToRewrite      { my $self = shift; return $WEB->convertToRewrite(@_); }

=head2 B<[Public] renderReplaceJSON()>

    Deleguje na Libs::Web::renderReplaceJSON.

=cut

sub renderReplaceJSON     { my $self = shift; return $WEB->renderReplaceJSON(@_); }

=head2 B<[Public] setAjax($id,$html)>

    Deleguje na Libs::Web::setAjax.

=cut

sub setAjax               { my $self = shift; return $WEB->setAjax(@_); }

=head2 B<[Public] getScriptName()>

    Deleguje na Libs::Web::getScriptName.

=cut

sub getScriptName         { my $self = shift; return $WEB->getScriptName(@_); }

=head2 B<[Public] setIDP($idp)>

    Deleguje na Libs::Web::setIDP.

=cut

sub setIDP                { my $self = shift; return $WEB->setIDP(@_); }

1;
