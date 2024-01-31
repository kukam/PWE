package Libs::Services;

use strict;
use Class::Inspector;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

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

sub loadServices {
    my $self = shift;
    foreach my $service ($self->findServices()) {
        $LOG->delay("service_name_$service");
        $self->loadService($service);
        $LOG->delay("service_name_$service", "Loaded service $service");
    }
}

sub registerServices {
    my $self = shift;
    foreach my $service (@{$self->getLoadServicesList()}) {
        $LOG->delay("service_register_$service");
        $self->registerService($service);
        $LOG->delay("service_register_$service", "Registring dependency for service : $service");
    }
}

sub autostarts {
    my $self = shift;
    foreach my $service (@{$self->getLoadServicesList()}) {
        $LOG->delay("service_autostart_$service");
        $self->autostart($service);
        $LOG->delay("service_autostart_$service", "Autostarting $service is completed");
    }
}

sub newRequest {
    my $self = shift;
    foreach my $service (@{$self->getLoadServicesList()}) {
        next unless ($self->isExistServiceMethod($service, 'newRequest'));
        $self->callServiceMethod($service, 'newRequest', undef);
    }
}

sub flush {
    my $self = shift;
    foreach my $service (@{$self->getLoadServicesList()}) {
        next unless ($self->isExistServiceMethod($service, 'flush'));
        $self->callServiceMethod($service, 'flush', undef);
    }
}

sub findServices {
    my $self = shift;
    my @services;
    my $dir = $self->getServicesDir();
    opendir(PDH, $dir);
    foreach my $service (readdir(PDH)) {
        next if ($service =~ /^\./);
        next unless (-d "$dir/$service");
        next unless (-f "$dir/$service/$service.pm");
        push(@services, $service);
    }
    closedir(PDH);
    @services = sort { $a cmp $b } @services;
    return @services;
}

sub loadService {
    my ($self, $service) = @_;

    eval "\$SIG{__DIE__}='DEFAULT'; require Services::${service}::${service};";

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

    eval "\$SIG{__DIE__}='DEFAULT'; \$self->{'services'}->{\$service} = new Services::${service}::${service}(\$conf,\$log,\$validate,\$dbi,\$entities,\$user,\$web);";
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

sub callServiceMethod {
    my ($self, $service, $method, $value) = @_;

    my $return = undef;

    return (0, undef) if (!$self->isExistService($service));
    return (0, undef) if (!$self->isExistServiceMethod($service, $method));

    $LOG->delay("service_namemethod_$service");
    eval "\$SIG{__DIE__}='DEFAULT'; \$return = \$self->{'services'}->{\$service}->\$method(\$value);";
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

sub unloadService {
    my ($self, $service) = @_;

    eval "no Services::${service}::${service};";

    delete $self->{'services'}->{$service};
    delete $self->{'methods'}->{$service};

    $LOG->info("Unloading service: $service [ OK ]");
}

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

    eval "\$SIG{__DIE__}='DEFAULT'; \$result = \$SERVICE->\$method(\@args);";

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

sub getLoadServicesList {
    my $self   = shift;
    my $result = [];
    foreach (keys %{$self->{'services'}}) { push(@{$result}, $_); }
    return $result;
}

sub getServicesDir {
    my $self = shift;
    return $CONF->getValue("pwe", "home", undef) . $CONF->getValue("pwe", "services_dir", undef);
}

sub getServiceObject {
    my ($self, $service) = @_;
    if ($self->isExistService($service)) {
        return $self->{'services'}->{$service};
    } else {
        $LOG->error("Unknown service $service !");
    }
}

sub isExistService {
    my ($self, $service) = @_;
    return 1 if (defined($self->{'services'}->{$service}));
    return 0;
}

sub isExistServiceMethod {
    my ($self, $service, $method) = @_;
    return 0 if (!$self->isExistService($service));
    return 0 if (!defined($self->{'methods'}->{$service}));
    return 0 if (!defined($self->{'methods'}->{$service}->{$method}));
    return 1;
}

1;
