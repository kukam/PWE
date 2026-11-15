package Libs::Services;

=head1 NAME

Libs::Services - loader sluzeb (Services), singletonu s business logikou

=head1 POPIS

    Sluzba = Services/<X>/<X>.pm. Do stranek a vzhledu se injektuje metodou Service_<X>; muze
    definovat hooky autostart(), newRequest() a flush(). Stejny model nacitani a samoleceni jako Libs::Pages.

=cut

use strict;
use Class::Inspector;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

=head2 B<[Public] new($conf,$log,$validate,$dbi,$user,$web,$entities)>

    Konstruktor loaderu sluzeb (Services). Nacte vsechny sluzby, injektuje mezi nimi zavislosti
    (Service_*) a zavola autostart(). Sluzby jsou singletony zijici po celou dobu procesu.

=cut

sub new {
    my ($class, $conf, $log, $validate, $dbi, $user, $web, $entities) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $WEB      = $web;
    $CONF     = $conf;
    $USER     = $user;
    $VALIDATE = $validate;
    $ENTITIES = $entities;

    my $self = {
        'services' => {},
        'methods'  => {},
    };

    bless $self, $class;
    $self->loadServices();
    $self->registerServices();
    $self->autostarts();
    return $self;
}

=head2 B<[Private] loadServices()>

    Nacte vsechny sluzby nalezene metodou findServices.

=cut

sub loadServices {
    my $self = shift;
    foreach my $service ($self->findServices()) {
        $LOG->delay("service_name_$service");
        $self->loadService($service);
        $LOG->delay("service_name_$service", "Loaded service $service");
    }
}

=head2 B<[Private] registerServices()>

    Pro kazdou nactenou sluzbu provede injektaz ostatnich sluzeb (registerService).
    Poradi nacitani je abecedni, injektaz probiha az po nacteni vsech - poradi tedy nehraje roli.

=cut

sub registerServices {
    my $self = shift;
    foreach my $service (@{$self->getLoadServicesList()}) {
        $LOG->delay("service_register_$service");
        $self->registerService($service);
        $LOG->delay("service_register_$service", "Registring dependency for service : $service");
    }
}

=head2 B<[Private] autostarts()>

    Zavola autostart() na vsech sluzbach, ktere tuto metodu maji.

=cut

sub autostarts {
    my $self = shift;
    foreach my $service (@{$self->getLoadServicesList()}) {
        $LOG->delay("service_autostart_$service");
        $self->autostart($service);
        $LOG->delay("service_autostart_$service", "Autostarting $service is completed");
    }
}

=head2 B<[Public] newRequest()>

    Na zacatku kazdeho requestu zavola newRequest() na vsech sluzbach, ktere ji definuji
    (napr. Services::UserAccount zde nacita session a nastavuje skupiny uzivatele).

=cut

sub newRequest {
    my $self = shift;
    foreach my $service (@{$self->getLoadServicesList()}) {
        next unless ($self->isExistServiceMethod($service, 'newRequest'));
        $self->callServiceMethod($service, 'newRequest', undef);
    }
}

=head2 B<[Public] flush()>

    Na konci kazdeho requestu zavola flush() na vsech sluzbach, ktere ji definuji
    (napr. Services::Session zde uklada session do DB).

=cut

sub flush {
    my $self = shift;
    foreach my $service (@{$self->getLoadServicesList()}) {
        next unless ($self->isExistServiceMethod($service, 'flush'));
        $self->callServiceMethod($service, 'flush', undef);
    }
}

=head2 B<[Private] findServices()>

    Vrati abecedne serazeny seznam adresaru s <Adresar>/<Adresar>.pm ze vsech korenu
    (Libs::Config::getModuleRoots: web, pak engine omezeny na pwe.core_services); web ma prednost.

=cut

sub findServices {
    my $self = shift;
    my (@services, %seen);
    foreach my $root ($CONF->getModuleRoots('services')) {
        opendir(my $dh, $root->{'dir'}) or next;
        foreach my $service (readdir($dh)) {
            next if ($service =~ /^\./ or $seen{$service});
            next unless (-d "$root->{'dir'}/$service" and -f "$root->{'dir'}/$service/$service.pm");
            next if ($root->{'allowed'} and !$root->{'allowed'}->{$service});
            $seen{$service} = 1;
            push(@services, $service);
        }
        closedir($dh);
    }
    @services = sort { $a cmp $b } @services;
    return @services;
}

=head2 B<[Private] loadService($service)>

    Nacte modul Services::<service>::<service>, zavola konstruktor se singletony enginu
    a ulozi seznam verejnych metod. Pri chybe sluzbu odregistruje a vrati 0, jinak 1.

=cut

sub loadService {
    my ($self, $service) = @_;

    eval "local \$SIG{__DIE__} = 'DEFAULT'; require Services::${service}::${service};";

    if ($@) {
        chomp($@);
        $LOG->error("$@");
        $LOG->error("loading service: failed to load $service");
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

    eval "local \$SIG{__DIE__} = 'DEFAULT'; \$self->{'services'}->{\$service} = new Services::${service}::${service}(\$conf,\$log,\$validate,\$dbi,\$entities,\$user,\$web);";
    if ($@ or !$self->isExistService($service)) {
        chomp($@);
        $LOG->error("$@");
        $LOG->error("loading service: failed construction of $service [ FAILED ]");
        $self->unloadService($service);
        return 0;
    }

    # SET METHOD LIST
    foreach my $method (@{Class::Inspector->methods("Services::$service\:\:$service", 'full', 'public')}) {
        $method =~ s/.*\:\://;
        $self->{'methods'}->{$service}->{$method} = 1;
    }

    $LOG->debug("Loading service: $service [ OK ]");

    return 1;
}

=head2 B<[Private] registerService($service)>

    Pro kazdou metodu Service_<Nazev> sluzby zavola tuto metodu s objektem jine sluzby.
    Neexistujici zavislost = sluzba se odregistruje.

=cut

sub registerService {
    my ($self, $service) = @_;

    # REGISTR SERVICES OBJECTS
    foreach my $method (keys %{$self->{'methods'}->{$service}}) {
        if ($method =~ /^Service_(\S+)$/) {
            if ($self->isExistService($1)) {
                my $SERVICE = $self->getServiceObject($1);
                $self->callServiceMethod($service, "Service_$1", $SERVICE);
            } else {
                $LOG->error("Registred service object $1 not exist!");
                $self->unloadService($service);
                return 0;
            }
        }
    }
}

=head2 B<[Private] autostart($service)>

    Pokud ma sluzba metodu autostart(), zavola ji. Vraci 1/0.

=cut

sub autostart {
    my ($self, $service) = @_;

    # AUTOSTART
    if ($self->isExistServiceMethod($service, "autostart")) {
        $LOG->info("autoexec service :$service method:autostart");
        $self->callServiceMethod($service, "autostart");
        return 1;
    }

    return 0;
}

=head2 B<[Private] callServiceMethod($service,$method,$value)>

    Bezpecne (eval) zavola metodu sluzby s jednim argumentem. Vraci (1,$navrat) pri uspechu,
    (0,undef) pokud sluzba/metoda neexistuje, (2,undef) pri padu - sluzba se odregistruje,
    posle se e-mail report a sluzba se znovu nacte.

=cut

sub callServiceMethod {
    my ($self, $service, $method, $value) = @_;

    my $return = undef;

    return (0, undef) if (!$self->isExistService($service));
    return (0, undef) if (!$self->isExistServiceMethod($service, $method));

    $LOG->delay("service_namemethod_$service");
    eval { local $SIG{__DIE__} = 'DEFAULT'; $return = $self->{'services'}->{$service}->$method($value); };
    $LOG->delay("service_namemethod_$service", "Called service method, service:$service method: $method");

    if ($@) {
        chomp($@);
        my $error = $@;
        $LOG->error($error);
        $LOG->error("Loading service: $service [ CRASHED ]");
        $self->unloadService($service);
        $LOG->sendErrorReport("SERVICE", $service, $method, $error);
        $self->loadService($service);
        return (2, undef);
    }

    return (1, $return);
}

=head2 B<[Private] unloadService($service)>

    Odregistruje sluzbu (smaze objekt a seznam metod).

=cut

sub unloadService {
    my ($self, $service) = @_;

    eval "no Services::${service}::${service};";

    delete $self->{'services'}->{$service};
    delete $self->{'methods'}->{$service};

    $LOG->info("Unloading service: $service [ OK ]");
}

=head2 B<[Private] validate([ 'Services::<service>::<metoda>', $error_key, $value, @args ])>

    Zavola validacni metodu sluzby (z pravidel 'rules'). Definovany navrat = OK (undef),
    undef = chyba -> vraci $error_key. Pri padu metody sluzbu odregistruje a die.

=cut

sub validate {
    my $self = shift;
    my @args = (@{$_[0]});

    my ($root, $service, $method) = split(/\:\:/, $args[0]);

    unless ($self->isExistServiceMethod($service, $method)) {
        $LOG->error("Method name:$method, service:$service not exists!");
        return "Internal_error-service`s_method_not_exist:$service:$method";
    }

    my $SERVICE = $self->getServiceObject($service);
    my $error   = $args[1];
    my $result  = undef;

    splice(@args, 0, 2);

    eval { local $SIG{__DIE__} = 'DEFAULT'; $result = $SERVICE->$method(@args); };

    if ($@) {
        chomp($@);
        my $error = $@;
        $LOG->error($error);
        $LOG->error("SERVICE : $service [ CRASHED ]");
        $self->unloadService($service);
        $LOG->sendErrorReport("SERVICE", $service, $method, $error);
        die "Internal error, unknown method service:$service, method:$method";
        exit;
    }

    return $error unless (defined($result));
    return undef;
}

=head2 B<[Public] getLoadServicesList()>

    Vraci referenci na pole nazvu nactenych sluzeb.

=cut

sub getLoadServicesList {
    my $self   = shift;
    my $result = [];
    foreach (keys %{$self->{'services'}}) { push(@{$result}, $_); }
    return $result;
}

=head2 B<[Public] getServiceObject($service)>

    Vraci instanci sluzby, nebo undef (a zaloguje chybu), pokud neni nactena.

=cut

sub getServiceObject {
    my ($self, $service) = @_;
    if ($self->isExistService($service)) {
        return $self->{'services'}->{$service};
    } else {
        $LOG->error("Unknown service $service !");
    }
}

=head2 B<[Public] isExistService($service)>

    Vraci 1/0 podle toho, zda je sluzba nactena.

=cut

sub isExistService {
    my ($self, $service) = @_;
    return 1 if (defined($self->{'services'}->{$service}));
    return 0;
}

=head2 B<[Public] isExistServiceMethod($service,$method)>

    Vraci 1/0 podle toho, zda ma nactena sluzba verejnou metodu $method.

=cut

sub isExistServiceMethod {
    my ($self, $service, $method) = @_;
    return 0 if (!$self->isExistService($service));
    return 0 if (!defined($self->{'methods'}->{$service}));
    return 0 if (!defined($self->{'methods'}->{$service}->{$method}));
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
    $LOG      = new Libs::Log;
    $CONF     = new Libs::Config;
    $DBI      = new Libs::DBI;
    $USER     = new Libs::User;
    $WEB      = new Libs::Web;
    $VALIDATE = new Libs::Validate;
    $ENTITIES = new Libs::Entities;
}

1;
