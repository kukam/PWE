package Libs::Sites;

=head1 NAME

Libs::Sites - loader vzhledu (Sites), fasad nad Libs::Web

=head1 POPIS

    Vzhled = Sites/<X>/<X>.pm. Do stranky se injektuje metodou Site_<X>; resi layouty, vychozi promenne
    sablon a ulozeni messengeru. Stejny model nacitani, injektaze a samoleceni jako Libs::Pages.

=cut

use strict;
use Class::Inspector;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB, $SERVICES);

=head2 B<[Public] new($conf,$log,$validate,$dbi,$user,$web,$entities,$services)>

    Konstruktor loaderu vzhledu (Sites). Nacte vsechny vzhledy, injektuje do nich sluzby
    (Service_*) a jine vzhledy (Site_*) a zavola autostart(). Vytvari se po Services, pred Pages.

=cut

sub new {
    my ($class, $conf, $log, $validate, $dbi, $user, $web, $entities, $services) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $WEB      = $web;
    $CONF     = $conf;
    $USER     = $user;
    $SERVICES = $services;
    $VALIDATE = $validate;
    $ENTITIES = $entities;

    my $self = {
        'sites'   => {},
        'methods' => {},
    };

    bless $self, $class;
    $self->loadSites();
    $self->registerServices();
    $self->registerSites();
    $self->autostarts();
    return $self;
}

=head2 B<[Private] loadSites()>

    Nacte vsechny vzhledy nalezene metodou findSites.

=cut

sub loadSites {
    my $self = shift;
    foreach my $site ($self->findSites()) {
        $LOG->delay("site_name_$site");
        $self->loadSite($site);
        $LOG->delay("site_name_$site", "Loaded site $site");
    }
}

=head2 B<[Private] registerServices()>

    Pro kazdy nacteny vzhled provede injektaz sluzeb (registerService).

=cut

sub registerServices {
    my $self = shift;
    foreach my $page (@{$self->getLoadSitesList()}) {
        $LOG->delay("page_service_register_$page");
        $self->registerService($page);
        $LOG->delay("page_service_register_$page", "Registring dependency for page : $page");
    }
}

=head2 B<[Private] registerSites()>

    Pro kazdy nacteny vzhled provede injektaz jinych vzhledu (registerSite) - vzhled muze
    rozsirovat jiny vzhled (napr. Sites::Shop pouziva Sites::Default).

=cut

sub registerSites {
    my $self = shift;
    foreach my $site (@{$self->getLoadSitesList()}) {
        $LOG->delay("site_register_$site");
        $self->registerSite($site);
        $LOG->delay("site_register_$site", "Registring dependency for site : $site");
    }
}

=head2 B<[Private] autostarts()>

    Zavola autostart() na vsech vzhledech, ktere tuto metodu maji.

=cut

sub autostarts {
    my $self = shift;
    foreach my $site (@{$self->getLoadSitesList()}) {
        $LOG->delay("site_autostart_$site");
        $self->autostart($site);
        $LOG->delay("site_autostart_$site", "Autostarting $site is completed");
    }
}

=head2 B<[Public] newRequest()>

    Na zacatku kazdeho requestu zavola newRequest() na vsech vzhledech, ktere ji definuji
    (vola pwe.fcgi po $USER->newRequest).

=cut

sub newRequest {
    my $self = shift;
    foreach my $site (@{$self->getLoadSitesList()}) {
        next unless ($self->isExistSiteMethod($site, 'newRequest'));
        $LOG->delay("site_newRequest_$site");
        $self->callSiteMethod($site, 'newRequest', undef);
        $LOG->delay("site_newRequest_$site", "Register new request $site is completed");
    }
}

=head2 B<[Public] flush()>

    Na konci kazdeho requestu zavola flush() na vsech vzhledech, ktere ji definuji
    (uklid stavu requestu).

=cut

sub flush {
    my $self = shift;
    foreach my $site (@{$self->getLoadSitesList()}) {
        next unless ($self->isExistSiteMethod($site, 'flush'));
        $LOG->delay("site_flush_$site");
        $self->callSiteMethod($site, 'flush', undef);
        $LOG->delay("site_flush_$site", "flush $site is completed");
    }
}

=head2 B<[Private] findSites()>

    Vrati abecedne serazeny seznam adresaru s <Adresar>/<Adresar>.pm ze vsech korenu
    (Libs::Config::getModuleRoots: web, pak engine omezeny na pwe.core_sites); web ma prednost.

=cut

sub findSites {
    my $self = shift;
    my (@sites, %seen);
    foreach my $root ($CONF->getModuleRoots('sites')) {
        opendir(my $dh, $root->{'dir'}) or next;
        foreach my $site (readdir($dh)) {
            next if ($site =~ /^\./ or $seen{$site});
            next unless (-d "$root->{'dir'}/$site" and -f "$root->{'dir'}/$site/$site.pm");
            next if ($root->{'allowed'} and !$root->{'allowed'}->{$site});
            $seen{$site} = 1;
            push(@sites, $site);
        }
        closedir($dh);
    }
    @sites = sort { $a cmp $b } @sites;
    return @sites;
}

=head2 B<[Private] loadSite($site)>

    Nacte modul Sites::<site>::<site>, zavola konstruktor se singletony enginu a ulozi seznam
    verejnych metod. Pri chybe vzhled odregistruje a vrati 0, jinak 1.

=cut

sub loadSite {
    my ($self, $site) = @_;

    eval "local \$SIG{__DIE__} = 'DEFAULT'; require Sites::${site}::${site};";

    if ($@) {
        chomp($@);
        $LOG->error("$@");
        $LOG->error("loading site: failed to load $site");
        return 0;
    }

    # BEZ TOHOTO SE NEDAJI PREDAT GLOBALNI PROMENE
    my $log      = $LOG;
    my $dbi      = $DBI;
    my $web      = $WEB;
    my $user     = $USER;
    my $conf     = $CONF;
    my $validate = $VALIDATE;
    my $entities = $ENTITIES;

    eval "local \$SIG{__DIE__} = 'DEFAULT'; \$self->{'sites'}->{\$site} = new Sites::${site}::${site}(\$conf,\$log,\$validate,\$dbi,\$entities,\$user,\$web);";
    if ($@ or !$self->isExistSite($site)) {
        chomp($@);
        $LOG->error("$@");
        $LOG->error("loading site: failed construction of $site [ FAILED ]");
        $self->unloadSite($site);
        return 0;
    }

    # SET METHOD LIST
    foreach my $method (@{Class::Inspector->methods("Sites::$site\:\:$site", 'full', 'public')}) {
        $method =~ s/.*\:\://;
        $self->{'methods'}->{$site}->{$method} = 1;
    }

    $LOG->debug("Loading site: $site [ OK ]");

    return 1;
}

=head2 B<[Private] registerService($site)>

    Pro kazdou metodu Service_<Nazev> vzhledu zavola tuto metodu s objektem sluzby.
    Neexistujici sluzba = vzhled se odregistruje (a s nim pak i stranky, ktere ho vyzaduji).

=cut

sub registerService {
    my ($self, $site) = @_;

    # REGISTR SERVICES OBJECTS
    foreach my $method (keys %{$self->{'methods'}->{$site}}) {
        if ($method =~ /^Service_(\S+)$/) {
            if ($SERVICES->isExistService($1)) {
                my $SERVICE = $SERVICES->getServiceObject($1);
                $self->callSiteMethod($site, "Service_$1", $SERVICE);
            } else {
                $LOG->error("Registred service object $1 not exist!");
                $self->unloadSite($site);
                return 0;
            }
        }
    }
}

=head2 B<[Private] registerSite($site)>

    Pro kazdou metodu Site_<Nazev> vzhledu zavola tuto metodu s objektem jineho vzhledu.

=cut

sub registerSite {
    my ($self, $site) = @_;

    # REGISTR SITES OBJECTS
    foreach my $method (keys %{$self->{'methods'}->{$site}}) {
        if ($method =~ /^Site_(\S+)$/) {
            if ($self->isExistSite($1)) {
                my $SITE = $self->getSiteObject($1);
                $self->callSiteMethod($site, "Site_$1", $SITE);
            } else {
                $LOG->error("Registred site object $1 not exist!");
                $self->unloadSite($site);
                return 0;
            }
        }
    }
}

=head2 B<[Private] autostart($site)>

    Pokud ma vzhled metodu autostart(), zavola ji. Vraci 1/0.

=cut

sub autostart {
    my ($self, $site) = @_;

    # AUTOSTART
    if ($self->isExistSiteMethod($site, "autostart")) {
        $LOG->info("autoexec site :$site method:autostart");
        $self->callSiteMethod($site, "autostart");
        return 1;
    }

    return 0;
}

=head2 B<[Private] callSiteMethod($site,$method,$value)>

    Bezpecne (eval) zavola metodu vzhledu s jednim argumentem. Vraci (1,$navrat) pri uspechu,
    (0,undef) pokud vzhled/metoda neexistuje, (2,undef) pri padu - vzhled se pak odregistruje,
    posle se e-mail report a vzhled se znovu nacte.

=cut

sub callSiteMethod {
    my ($self, $site, $method, $value) = @_;

    my $return = undef;

    return (0, undef) if (!$self->isExistSite($site));
    return (0, undef) if (!$self->isExistSiteMethod($site, $method));

    $LOG->delay("site_namemethod_$site");
    eval { local $SIG{__DIE__} = 'DEFAULT'; $return = $self->{'sites'}->{$site}->$method($value); };
    $LOG->delay("site_namemethod_$site", "Called site method, site:$site method: $method");

    if ($@) {
        chomp($@);
        my $error = $@;
        $LOG->error($error);
        $LOG->error("Loading site: $site [ CRASHED ]");
        $self->unloadSite($site);
        $LOG->sendErrorReport("SITE", $site, $method, $error);
        $self->loadSite($site);
        return (2, undef);
    }

    return (1, $return);
}

=head2 B<[Private] unloadSite($site)>

    Odregistruje vzhled (smaze objekt a seznam metod).

=cut

sub unloadSite {
    my ($self, $site) = @_;

    eval "no Sites::${site}::${site};";

    delete $self->{'sites'}->{$site};
    delete $self->{'methods'}->{$site};

    $LOG->info("Unloading site: $site [ OK ]");
}

=head2 B<[Public] getLoadSitesList()>

    Vraci referenci na pole nazvu nactenych vzhledu.

=cut

sub getLoadSitesList {
    my $self   = shift;
    my $result = [];
    foreach (keys %{$self->{'sites'}}) { push(@{$result}, $_); }
    return $result;
}

=head2 B<[Public] getSiteObject($site)>

    Vraci instanci vzhledu, nebo undef (a zaloguje chybu), pokud neni nacten.

=cut

sub getSiteObject {
    my ($self, $site) = @_;
    if ($self->isExistSite($site)) {
        return $self->{'sites'}->{$site};
    } else {
        $LOG->error("Unknown site $site !");
    }
}

=head2 B<[Public] isExistSite($site)>

    Vraci 1/0 podle toho, zda je vzhled nacten.

=cut

sub isExistSite {
    my ($self, $site) = @_;
    return 1 if (defined($self->{'sites'}->{$site}));
    return 0;
}

=head2 B<[Public] isExistSiteMethod($site,$method)>

    Vraci 1/0 podle toho, zda ma nacteny vzhled verejnou metodu $method.

=cut

sub isExistSiteMethod {
    my ($self, $site, $method) = @_;
    return 0 if (!$self->isExistSite($site));
    return 0 if (!defined($self->{'methods'}->{$site}));
    return 0 if (!defined($self->{'methods'}->{$site}->{$method}));
    return 1;
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
    require Libs::DBI;
    require Libs::User;
    require Libs::Web;
    require Libs::Validate;
    require Libs::Entities;
    require Libs::Services;
    $LOG      = new Libs::Log;
    $CONF     = new Libs::Config;
    $DBI      = new Libs::DBI;
    $USER     = new Libs::User;
    $WEB      = new Libs::Web;
    $SERVICES = new Libs::Services;
    $VALIDATE = new Libs::Validate;
    $ENTITIES = new Libs::Entities;
}

1;
