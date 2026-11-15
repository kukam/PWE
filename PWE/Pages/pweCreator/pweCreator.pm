package Pages::pweCreator::pweCreator;

=head1 NAME

Pages::pweCreator::pweCreator - generator kostry nove stranky, sluzby, vzhledu a entity (jen admin, jen pwe.development)

=cut

use strict;
use Class::MOP;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

=head2 B<[Public] new($self,$conf,$log,$validate,$dbi,$entities,$user,$web)>

    Generator kostry noveho kodu (jen skupina 'admin'): stranky (cpage), sluzby (cservice),
    vzhledu (csite) a entity (centity) ze sablon Pages/pweCreator/*.tmpl. Vytvorene soubory
    se zapisuji primo do adresaru webappu (pwe.home); po vytvoreni je nutne restartovat server.

    Je to vyvojovy nastroj: akce zapisujici soubory (cpage, cservice, csite, centity) vraci 401,
    pokud neni pwe.development pravdive (isDevelopment) - admin produkcniho webu tak nemuze
    za behu zapisovat kod. Nazvy modulu, tabulky a vzhledu/sluzeb k pripojeni musi byt
    identifikatory (pismeno, pak pismena/cislice/podtrzitko, max. 64 znaku - rules), jinak
    by se z parametru skladala cesta k souboru.

=cut

sub new {
    my ($class, $self, $conf, $log, $validate, $dbi, $entities, $user, $web) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $CONF     = $conf;
    $USER     = $user;
    $WEB      = $web;
    $VALIDATE = $validate;
    $ENTITIES = $entities;

    $self->{'access'} = ['admin'];

    $self->{'def_service_variablename'} = ['$CONF', '$LOG', '$VALIDATE', '$DBI', '$ENTITIES', '$USER', '$WEB'];

    $self->{'func'}->{'default'}  = [];
    $self->{'func'}->{'cpage'}    = [];
    $self->{'func'}->{'cservice'} = [];
    $self->{'func'}->{'csite'}    = [];
    $self->{'func'}->{'centity'}  = [];

    # Musi byt definovano!
    $self->{'defined'} = {
        cpage    => {parameters => ['pagename'],},
        cservice => {parameters => ['servicename'],},
        csite    => {parameters => ['sitename'],},
        centity  => {parameters => ['entityname', 'dbtable'],},
    };

    $self->{'error'}->{'cpage'}    = "error";
    $self->{'error'}->{'cservice'} = "error";
    $self->{'error'}->{'csite'}    = "error";
    $self->{'error'}->{'centity'}  = "error";

    # Nazvy se stavaji soucasti cest k souborum a nazvu balicku -> jen identifikator
    # (pismeno, pak pismena/cislice/podtrzitko, max. 64 znaku).
    my $ident = qr/^[A-Za-z][A-Za-z0-9_]{0,63}$/;

    $self->{'rules'}->{'cpage'}->{'pagename'}           = [['is_regx', 'error_pagename',        'parameter', $ident]];
    $self->{'rules'}->{'cpage'}->{'default_site'}       = [['is_regx', 'error_default_site',    'parameter', $ident]];
    $self->{'rules'}->{'cpage'}->{'default_service'}    = [['is_regx', 'error_default_service', 'parameter', $ident]];
    $self->{'rules'}->{'cservice'}->{'servicename'}     = [['is_regx', 'error_servicename',     'parameter', $ident]];
    $self->{'rules'}->{'cservice'}->{'default_service'} = [['is_regx', 'error_default_service', 'parameter', $ident]];
    $self->{'rules'}->{'csite'}->{'sitename'}           = [['is_regx', 'error_sitename',        'parameter', $ident]];
    $self->{'rules'}->{'csite'}->{'default_site'}       = [['is_regx', 'error_default_site',    'parameter', $ident]];
    $self->{'rules'}->{'csite'}->{'default_service'}    = [['is_regx', 'error_default_service', 'parameter', $ident]];
    $self->{'rules'}->{'centity'}->{'entityname'}       = [['is_regx', 'error_entityname',      'parameter', $ident]];
    $self->{'rules'}->{'centity'}->{'dbtable'}          = [['is_regx', 'error_dbtable',         'parameter', $ident]];

    bless $self, $class;
    return $self;
}

=head2 B<[Private] isDevelopment()>

    Vraci 1, pokud je pwe.development pravdive, jinak 0. Akce zapisujici soubory (cpage, cservice,
    csite, centity) pri 0 vraci 401 - generator kodu nema v produkci co delat (nahrazuje ho
    make module, tj. skript tools/new-module.pl v adresari enginu PWE/).

=cut

sub isDevelopment {
    my $self = shift;
    return ($CONF->getValue('pwe', 'development', 0) ? 1 : 0);
}

=head2 B<[Private] Site_Default($site)>

    Injektaz vzhledu Default (vola loader).

=cut

sub Site_Default {
    my ($self, $input) = @_;
    $WEB = $input;
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
    require Sites::Default::Default;
    $CONF     = new Libs::Config;
    $LOG      = new Libs::Log;
    $VALIDATE = new Libs::Validate;
    $DBI      = new Libs::DBI;
    $ENTITIES = new Libs::Entities;
    $USER     = new Libs::User;
    $WEB      = new Sites::Default::Default;
}

=head2 B<[Public] default()>

    Vykresli formulare generatoru se seznamy dostupnych sluzeb, entit, vzhledu a DB tabulek.

=cut

sub default {
    my $self = shift;

    my $idp = "pweCreator";

    # SET ID Page
    $WEB->setIDP($idp);
    $WEB->printHttpHeader();
    $WEB->printHtmlHeader();
    $WEB->printHtmlLayout(
        html_main     => "Pages/pweCreator/main.html",
        services_list => $self->{'services_list'},
        entities_list => $self->{'entities_list'},
        sites_list    => $self->{'sites_list'},
        dbtables_list => $DBI->getDAOList('db1'),
    );
}

=head2 B<[Public] cpage()>

    Vytvori Pages/<pagename>/<pagename>.pm (ze sablony page.tmpl s injektazi zvoleneho vzhledu
    a sluzeb), prazdny main.html, msg.html a rb*.tmpl pro vsechny jazyky. Odpovi AJAXem.
    Mimo pwe.development vraci 401.

=cut

sub cpage {
    my $self = shift;

    return 401 unless ($self->isDevelopment());

    my $home = $CONF->getValue("pwe", "home", "/tmp");
    my $pagename    = $USER->getParam("pagename",     0, undef);
    my $defsitename = $USER->getParam("default_site", 0, undef);
    my $services = $USER->getParam("default_service", 'all', []);
    my $pagesdir    = $CONF->getValue('pwe', 'pages_dir',    "Pages/");
    my $sitesdir    = $CONF->getValue('pwe', 'sites_dir',    "Sites/");
    my $servicesdir = $CONF->getValue('pwe', 'services_dir', "Services/");

    $pagesdir =~ s/\///;
    $sitesdir =~ s/\///;
    $servicesdir =~ s/\///;

    my @variables  = @{$self->{'def_service_variablename'}};
    my $servicemap = $self->get_service_map($services);

    while (my ($key, $value) = each(%{$servicemap})) {
        push(@variables, $value);
    }

    $WEB->setMessenger("Pages/pweCreator/msg.html", msg_allright => ['cpage_created']);

    my $file = $WEB->genTmpl(
        "Pages/pweCreator/page.tmpl",
        servicemap   => $servicemap,
        pagename     => $pagename,
        defsitename  => $defsitename,
        services     => $services,
        variables    => join(",", @variables),
        pages_dir    => $pagesdir,
        sites_dir    => $sitesdir,
        services_dir => $servicesdir,
    );

    mkdir($home . $pagesdir . "/" . $pagename);
    open(PAGENAME, '>', $home . $pagesdir . "/" . $pagename . "/" . $pagename . ".pm");
    print PAGENAME $file;
    close(PAGENAME);

    open(MAIN, '>', $home . $pagesdir . "/" . $pagename . "/main.html");
    print MAIN "\n";
    close(MAIN);

    open(MSG, '>', $home . $pagesdir . "/" . $pagename . "/msg.html");
    print MSG "[% PROCESS templates/resource_bundle.tmpl %]\n";
    print MSG "\n";
    print MSG "[% INCLUDE templates/messenger.html %]\n";
    print MSG "\n";
    close(MSG);

    $self->create_resourcebundle($home . $pagesdir . "/" . $pagename . "/");

    $WEB->printHttpHeader('type' => 'ajax');
    $WEB->printAjaxLayout();
}

=head2 B<[Public] cservice()>

    Vytvori Services/<servicename>/<servicename>.pm ze sablony service.tmpl + rb*.tmpl
    a presmeruje zpet na generator. Mimo pwe.development vraci 401.

=cut

sub cservice {
    my $self = shift;

    return 401 unless ($self->isDevelopment());

    my $home = $CONF->getValue("pwe", "home", "/tmp");
    my $servicename = $USER->getParam("servicename", 0, undef);
    my $services = $USER->getParam("default_service", 'all', []);
    my $servicesdir = $CONF->getValue('pwe', 'services_dir', "Services/");

    $servicesdir =~ s/\///;

    my @variables  = @{$self->{'def_service_variablename'}};
    my $servicemap = $self->get_service_map($services);

    while (my ($key, $value) = each(%{$servicemap})) {
        push(@variables, $value);
    }

    $WEB->setMessenger("Pages/pweCreator/msg.html", msg_allright => ['cservice_created']);

    my $file = $WEB->genTmpl(
        "Pages/pweCreator/service.tmpl",
        servicemap   => $servicemap,
        servicename  => $servicename,
        services     => $services,
        variables    => join(",", @variables),
        services_dir => $servicesdir,
    );

    mkdir($home . $servicesdir . "/" . $servicename);
    open(PAGENAME, '>', $home . $servicesdir . "/" . $servicename . "/" . $servicename . ".pm");
    print PAGENAME $file;
    close(PAGENAME);

    $self->create_resourcebundle($home . $servicesdir . "/" . $servicename . "/");

    $WEB->printHttpHeader('type' => 'ajax_redirect', 'redirect_link' => $WEB->getScriptName() . '?page=pweCreator&func=default');
}

=head2 B<[Public] csite()>

    Vytvori Sites/<sitename>/<sitename>.pm ze sablony site.tmpl - proxy metody se vygeneruji
    podle metod zvoleneho rodicovskeho vzhledu (nebo Libs::Web) pres Class::MOP.
    Mimo pwe.development vraci 401.

=cut

sub csite {
    my $self = shift;

    return 401 unless ($self->isDevelopment());

    my $home = $CONF->getValue("pwe", "home", "/tmp");
    my $sitename    = $USER->getParam("sitename",     0, undef);
    my $defsitename = $USER->getParam("default_site", 0, undef);
    my $services = $USER->getParam("default_service", 'all', []);
    my $sitesdir    = $CONF->getValue('pwe', 'sites_dir',    "Sites/");
    my $servicesdir = $CONF->getValue('pwe', 'services_dir', "Services/");

    $sitesdir =~ s/\///;
    $servicesdir =~ s/\///;

    my @variables  = @{$self->{'def_service_variablename'}};
    my $servicemap = $self->get_service_map($services);

    while (my ($key, $value) = each(%{$servicemap})) {
        push(@variables, $value);
    }

    $WEB->setMessenger("Pages/pweCreator/msg.html", msg_allright => ['csite_created']);

    my $file = $WEB->genTmpl(
        "Pages/pweCreator/site.tmpl",
        sitename     => $sitename,
        defsitename  => $defsitename,
        services     => $services,
        servicemap   => $servicemap,
        services_dir => $servicesdir,
        variables    => join(",", @variables),
        sites_dir    => $sitesdir,
        methods      => $self->get_list_methods_for_class(($defsitename ? $sitesdir . "::" . $defsitename . "::" . $defsitename : 'Libs::Web')),
    );

    mkdir($home . $sitesdir . "/" . $sitename);
    open(PAGENAME, '>', $home . $sitesdir . "/" . $sitename . "/" . $sitename . ".pm");
    print PAGENAME $file;
    close(PAGENAME);

    $self->create_resourcebundle($home . $sitesdir . "/" . $sitename . "/");

    $WEB->printHttpHeader('type' => 'ajax_redirect', 'redirect_link' => $WEB->getScriptName() . '?page=pweCreator&func=default');
}

=head2 B<[Public] centity()>

    Vytvori Entities/<entityname>/<entityname>.pm ze sablony entity.tmpl nad zvolenou DB tabulkou.
    Mimo pwe.development vraci 401.

=cut

sub centity {
    my $self = shift;

    return 401 unless ($self->isDevelopment());

    my $home = $CONF->getValue("pwe", "home", "/tmp");
    my $entityname = $USER->getParam("entityname", 0, undef);
    my $dbtable    = $USER->getParam("dbtable",    0, undef);
    my $entitiesdir = $CONF->getValue('pwe', 'entities_dir', "Entites/");

    $entitiesdir =~ s/\///;

    $WEB->setMessenger("Pages/pweCreator/msg.html", msg_allright => ['centity_created']);

    my $file = $WEB->genTmpl(
        "Pages/pweCreator/entity.tmpl",
        entityname => $entityname,
        dbtable    => $dbtable,
    );

    mkdir($home . $entitiesdir . "/" . $entityname);
    open(ENTITYNAME, '>', $home . $entitiesdir . "/" . $entityname . "/" . $entityname . ".pm");
    print ENTITYNAME $file;
    close(ENTITYNAME);

    $self->create_resourcebundle($home . $entitiesdir . "/" . $entityname . "/");

    $WEB->printHttpHeader('type' => 'ajax_redirect', 'redirect_link' => $WEB->getScriptName() . '?page=pweCreator&func=default');
}

=head2 B<[Private] get_service_map(\@services)>

    Vraci mapu nazev sluzby -> nazev globalni promenne ('$SESSION', ...); koliduje-li s vychozimi
    promennymi ($CONF, $LOG, ...), prida prefix C.

=cut

sub get_service_map {
    my ($self, $services) = @_;

    my $servicemap = {};
    foreach my $service (@{$services}) {
        if (grep $_ =~ /^\Q$service\E$/, @{$self->{'def_service_variablename'}}) {
            $servicemap->{$service} = '$' . uc("C" . $service);
        } else {
            $servicemap->{$service} = '$' . uc($service);
        }
    }
    return $servicemap;
}

=head2 B<[Private] create_resourcebundle($path)>

    Vytvori v adresari prazdne rb.tmpl (prvni jazyk z http.languages) a rb_<LANG>.tmpl pro
    ostatni jazyky, vzdy ukoncene prazdnym radkem (znamy pozadavek parseru resource bundlu).

=cut

sub create_resourcebundle {
    my ($self, $path) = @_;

    my @languages = @{$CONF->getValue('http', 'languages', [])};
    foreach my $l (@languages) {
        my $fname = (($languages[0] eq $l) ? "rb.tmpl" : "rb_" . $l . ".tmpl");
        open(RB, '>', $path . $fname);
        print RB "[% # RESOURCE BUNDLE %]\n";
        print RB "\n";
        print RB "[% # POZOR soubor rb.tmpl musi koncit prazdnym radkem !!! (bug) %]\n";
        print RB "\n";
        close(RB);
    }
}

=head2 B<[Private] get_list_methods_for_class($class)>

    Vraci seznam verejnych metod tridy (Class::MOP) bez new, flush, KOMODO, AUTOLOAD, DESTROY
    a bez injektoru Site_*/Service_* - pouziva csite pro generovani proxy metod.

=cut

sub get_list_methods_for_class {
    my ($self, $class) = @_;

    my $methodlist = [];

    my $meta = Class::MOP::Class->initialize($class);

    for my $meth ($meta->get_all_methods()) {
        my $name = $meth->fully_qualified_name();
        next if ($name eq $class . "::new");
        next if ($name eq $class . "::flush");
        next if ($name eq $class . "::KOMODO");
        next if ($name eq $class . "::AUTOLOAD");
        next if ($name eq $class . "::DESTROY");
        next if ($name =~ /::Site_/);
        next if ($name =~ /::Service_/);
        if ($name =~ /^\Q$class\E::(.*)/) {
            push(@{$methodlist}, $1);
        }
    }

    return $methodlist;
}

=head2 B<[Public] error($error)>

    Chybova metoda validace: zobrazi klice chyb v messengeru; pri AJAX requestu vrati 400,
    jinak znovu vykresli generator.

=cut

sub error {
    my ($self, $error) = @_;
    $WEB->setMessenger("Pages/pweCreator/msg.html", msg_error => $error);
    if ($USER->getParam("ajax_request", 0, undef)) {
        return 400;
    } else {
        $self->default();
    }
}

1;
