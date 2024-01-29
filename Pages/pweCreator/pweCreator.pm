package Pages::pweCreator::pweCreator;

use strict;
use Class::MOP;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

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

    bless $self, $class;
    return $self;
}

sub Site_NewBootstrap523 {
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

sub cpage {
    my $self = shift;

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

sub cservice {
    my $self = shift;

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

sub csite {
    my $self = shift;

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

sub centity {
    my $self = shift;

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
