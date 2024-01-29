package Libs::Sites;

use strict;
use Class::Inspector;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB, $SERVICES);

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

sub loadSites {
    my $self = shift;
    foreach my $site ($self->findSites()) {
        $LOG->delay("site_name_$site");
        $self->loadSite($site);
        $LOG->delay("site_name_$site", "Loaded site $site");
    }
}

sub registerServices {
    my $self = shift;
    foreach my $page (@{$self->getLoadSitesList()}) {
        $LOG->delay("page_service_register_$page");
        $self->registerService($page);
        $LOG->delay("page_service_register_$page", "Registring dependency for page : $page");
    }
}

sub registerSites {
    my $self = shift;
    foreach my $site (@{$self->getLoadSitesList()}) {
        $LOG->delay("site_register_$site");
        $self->registerSite($site);
        $LOG->delay("site_register_$site", "Registring dependency for site : $site");
    }
}

sub autostarts {
    my $self = shift;
    foreach my $site (@{$self->getLoadSitesList()}) {
        $LOG->delay("site_autostart_$site");
        $self->autostart($site);
        $LOG->delay("site_autostart_$site", "Autostarting $site is completed");
    }
}

sub newRequest {
    my $self = shift;
    foreach my $site (@{$self->getLoadSitesList()}) {
        next unless ($self->isExistSiteMethod($site, 'newRequest'));
        $LOG->delay("site_newRequest_$site");
        $self->callSiteMethod($site, 'newRequest', undef);
        $LOG->delay("site_newRequest_$site", "Register new request $site is completed");
    }
}

sub flush {
    my $self = shift;
    foreach my $site (@{$self->getLoadSitesList()}) {
        next unless ($self->isExistSiteMethod($site, 'flush'));
        $LOG->delay("site_flush_$site");
        $self->callSiteMethod($site, 'flush', undef);
        $LOG->delay("site_flush_$site", "flush $site is completed");
    }
}

sub findSites {
    my $self = shift;
    my @sites;
    my $dir = $self->getSitesDir();
    opendir(PDH, $dir);
    foreach my $site (readdir(PDH)) {
        next if ($site =~ /^\./);
        next unless (-d "$dir/$site");
        next unless (-f "$dir/$site/$site.pm");
        push(@sites, $site);
    }
    closedir(PDH);
    @sites = sort { $a cmp $b } @sites;
    return @sites;
}

sub loadSite {
    my ($self, $site) = @_;

    eval "\$SIG{__DIE__}='DEFAULT'; require Sites::${site}::${site};";

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

    eval "\$SIG{__DIE__}='DEFAULT'; \$self->{'sites'}->{\$site} = new Sites::${site}::${site}(\$conf,\$log,\$validate,\$dbi,\$entities,\$user,\$web);";
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

sub callSiteMethod {
    my ($self, $site, $method, $value) = @_;

    my $return = undef;

    return (0, undef) if (!$self->isExistSite($site));
    return (0, undef) if (!$self->isExistSiteMethod($site, $method));

    $LOG->delay("site_namemethod_$site");
    eval "\$SIG{__DIE__}='DEFAULT'; \$return = \$self->{'sites'}->{\$site}->\$method(\$value);";
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

sub unloadSite {
    my ($self, $site) = @_;

    eval "no Sites::${site}::${site};";

    delete $self->{'sites'}->{$site};
    delete $self->{'methods'}->{$site};

    $LOG->info("Unloading site: $site [ OK ]");
}

sub validate {
    my $self = shift;
    my @args = (@{$_[0]});

    my ($root, $site, $method) = split(/\:\:/, $args[0]);

    unless ($self->isExistSiteMethod($site, $method)) {
        $LOG->error("Method name:$method, site:$site not exists!");
        return "Internal_error-site`s_method_not_exist:$site:$method";
    }

    my $SITE   = $self->getSiteObject($site);
    my $error  = $args[1];
    my $result = undef;

    splice(@args, 0, 2);

    eval "\$SIG{__DIE__}='DEFAULT'; \$result = \$SITE->\$method(\@args);";

    if ($@) {
        chomp($@);
        my $error = $@;
        $LOG->error($error);
        $LOG->error("SITE : $site [ CRASHED ]");
        $self->unloadSite($site);
        $LOG->sendErrorReport("SITE", $site, $method, $error);
        die "Internal error, unknown method site:$site, method:$method";
        exit;
    }

    return $error unless (defined($result));
    return undef;
}

sub getLoadSitesList {
    my $self   = shift;
    my $result = [];
    foreach (keys %{$self->{'sites'}}) { push(@{$result}, $_); }
    return $result;
}

sub getSitesDir {
    my $self = shift;
    return $CONF->getValue("pwe", "home", undef) . $CONF->getValue("pwe", "sites_dir", undef);
}

sub getSiteObject {
    my ($self, $site) = @_;
    if ($self->isExistSite($site)) {
        return $self->{'sites'}->{$site};
    } else {
        $LOG->error("Unknown site $site !");
    }
}

sub isExistSite {
    my ($self, $site) = @_;
    return 1 if (defined($self->{'sites'}->{$site}));
    return 0;
}

sub isExistSiteMethod {
    my ($self, $site, $method) = @_;
    return 0 if (!$self->isExistSite($site));
    return 0 if (!defined($self->{'methods'}->{$site}));
    return 0 if (!defined($self->{'methods'}->{$site}->{$method}));
    return 1;
}

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
