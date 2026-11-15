package Sites::Default::Default;

=head1 NAME

Sites::Default::Default - vychozi vzhled enginu, tenka fasada nad Libs::Web (webapp si dodava vlastni)

=cut

use strict;

our ($AUTOLOAD);

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

=head2 B<[Public] new($conf,$log,$validate,$dbi,$entities,$user,$web)>

    Vychozi vzhled enginu - tenka fasada nad Libs::Web, nic nemeni. Kazdy webapp si typicky
    dodava vlastni Sites/Default s layouty a vychozimi promennymi sablon (viz webapps/*/Sites/Default).
    Do stranek se injektuje metodou Site_Default.

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

    my $self = {};

    bless $self, $class;
    return $self;
}

=head2 B<[Public] existMessenger()>

    Deleguje na Libs::Web::existMessenger (je nastavena flash zprava?).

=cut

sub existMessenger        { my $self = shift; return $WEB->existMessenger(@_); }

=head2 B<[Public] genTmpl($src,%tmpl)>

    Deleguje na Libs::Web::genTmpl (render sablony do retezce).

=cut

sub genTmpl               { my $self = shift; return $WEB->genTmpl(@_); }

=head2 B<[Public] getScriptName()>

    Deleguje na Libs::Web::getScriptName (nazev skriptu, napr. pwe.fcgi).

=cut

sub getScriptName         { my $self = shift; return $WEB->getScriptName(@_); }

=head2 B<[Public] printHtmlLayout(%tmpl)>

    Deleguje na Libs::Web::printHtmlLayout (telo stranky).

=cut

sub printHtmlLayout       { my $self = shift; return $WEB->printHtmlLayout(@_); }

=head2 B<[Public] printHtmlHeader(%tmpl)>

    Deleguje na Libs::Web::printHtmlHeader (hlavicka HTML dokumentu).

=cut

sub printHtmlHeader       { my $self = shift; return $WEB->printHtmlHeader(@_); }

=head2 B<[Public] renderReplaceJSON()>

    Deleguje na Libs::Web::renderReplaceJSON (JSON pro AJAX).

=cut

sub renderReplaceJSON     { my $self = shift; return $WEB->renderReplaceJSON(@_); }

=head2 B<[Public] printAjaxLayout(%tmpl)>

    Deleguje na Libs::Web::printAjaxLayout (AJAX odpoved).

=cut

sub printAjaxLayout       { my $self = shift; return $WEB->printAjaxLayout(@_); }

=head2 B<[Public] printHttpHeader(%tmpl)>

    Deleguje na Libs::Web::printHttpHeader (HTTP hlavicka).

=cut

sub printHttpHeader       { my $self = shift; return $WEB->printHttpHeader(@_); }

=head2 B<[Public] getIDP()>

    Deleguje na Libs::Web::getIDP (id stranky).

=cut

sub getIDP                { my $self = shift; return $WEB->getIDP(@_); }

=head2 B<[Public] convertToRewrite($value)>

    Deleguje na Libs::Web::convertToRewrite (URL slug).

=cut

sub convertToRewrite      { my $self = shift; return $WEB->convertToRewrite(@_); }

=head2 B<[Public] getResourceBundleList($page,$lang)>

    Deleguje na Libs::Web::getResourceBundleList.

=cut

sub getResourceBundleList { my $self = shift; return $WEB->getResourceBundleList(@_); }

=head2 B<[Public] setIDP($idp)>

    Deleguje na Libs::Web::setIDP (id stranky pro sablony a rb).

=cut

sub setIDP                { my $self = shift; return $WEB->setIDP(@_); }

=head2 B<[Public] findResourceBundles(...)>

    Deleguje na Libs::Web (metoda findResourceBundles v Libs::Web aktualne neexistuje -
    volani skonci chybou; ponechano kvuli kompatibilite generovanych vzhledu).

=cut

sub findResourceBundles   { my $self = shift; return $WEB->findResourceBundles(@_); }

=head2 B<[Public] setAjax($id,$html)>

    Deleguje na Libs::Web::setAjax (pridani polozky do AJAX odpovedi).

=cut

sub setAjax               { my $self = shift; return $WEB->setAjax(@_); }

=head2 B<[Public] setMessenger($tmpl,%tmpl)>

    Deleguje na Libs::Web::setMessenger (flash zprava ulozena v opts uzivatele).

=cut

sub setMessenger          { my $self = shift; return $WEB->setMessenger(@_); }

=head2 B<[Public] getValue($key,$def)>

    Deleguje na Libs::Web::getValue.

=cut

sub getValue              { my $self = shift; return $WEB->getValue(@_); }

=head2 B<[Private] AUTOLOAD(...)>

    Vse ostatni deleguje na Libs::Web - vzhled ma automaticky cele API render vrstvy.

=cut

sub AUTOLOAD {
    my $self = shift;
    my $name = $AUTOLOAD;
    $name =~ s/.*://;
    return if ($name =~ /^DESTROY$/);
    return $WEB->$name(@_);
}

=head2 B<[Private] KOMODO()>

    Mrtvy kod pro IDE (Komodo/VS Code), aby umelo doplnit typy globalnich promennych.
    Nikdy se nevola - prvni prikaz je return.

=cut

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
