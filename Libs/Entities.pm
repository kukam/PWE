package Libs::Entities;

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB);

sub new {
    my ($class, $conf, $log, $validate, $dbi, $user, $web) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $CONF     = $conf;
    $USER     = $user;
    $WEB      = $web;
    $VALIDATE = $validate;

    my $self = {'entities' => {}};

    bless $self, $class;
    $self->loadEntities();
    return $self;
}

sub loadEntities {
    my $self = shift;
    foreach my $entity ($self->findEntities()) {
        $LOG->delay("entity_name_$entity");
        $self->loadEntity($entity);
        $LOG->delay("entity_name_$entity", "Loaded entity $entity");
    }
}

sub findEntities {
    my $self = shift;
    my @entities;
    my $dir = $self->getEntitiesDir();
    opendir(PDH, $dir);
    foreach my $entity (readdir(PDH)) {
        next if ($entity =~ /^\./);
        next unless (-d "$dir/$entity");
        next unless (-f "$dir/$entity/$entity.pm");
        push(@entities, $entity);
    }
    closedir(PDH);
    @entities = sort { $a cmp $b } @entities;
    return @entities;
}

sub loadEntity {
    my ($self, $entity) = @_;

    eval "\$SIG{__DIE__}='DEFAULT'; require Entities::${entity}::${entity};";

    if ($@) {
        chomp($@);
        $LOG->error("$@");
        $LOG->error("loading entity: failed to load $entity");
        return 0;
    }

    $self->{'entities'}->{$entity} = $self->createEntityObject($entity, {disable_db_pooler => 1});

    if ($self->isExistEntity($entity)) {
        $LOG->debug("Loading entity: $entity [ OK ]");
        return 1;
    }
    return 0;
}

sub createEntityObject {
    my ($self, $entity, $opts) = @_;

    my $ENTITY = undef;

    # BEZ TOHOTO SE NEDAJI PREDAT GLOBALNI PROMENE
    my $log      = $LOG;
    my $dbi      = $DBI;
    my $conf     = $CONF;
    my $user     = $USER;
    my $web      = $WEB;
    my $validate = $VALIDATE;

    $LOG->delay("create_entity_object_$entity");
    eval "\$SIG{__DIE__}='DEFAULT'; \$ENTITY = new Entities::${entity}::${entity}(\$conf,\$log,\$validate,\$dbi,\$user,\$web,\$opts);";
    if ($@ or !$ENTITY) {
        chomp($@);
        $LOG->error("$@");
        $LOG->error("loading entity: failed construction of $entity [ FAILED ]");
        $self->unloadEntity($entity);
        return undef;
    }
    $LOG->delay("create_entity_object_$entity", "Create entity : $entity");

    return $ENTITY;
}

sub unloadEntity {
    my ($self, $entity) = @_;

    eval "no Entities::${entity}::${entity};";

    delete $self->{'entities'}->{$entity};

    $LOG->info("Unloading entity: $entity [ OK ]");
}

sub validate {
    my $self = shift;
    my @args = (@{$_[0]});

    my ($root, $entity, $method, $primaryID) = split(/\:\:/, $args[0]);

    unless ($self->isExistEntity($entity)) {
        $LOG->error("Entities:$entity not exists!");
        return "Internal_error-entity_not_exist:$entity";
    }

    my $ENTITY = undef;

    if (!defined($primaryID)) {
        $ENTITY = $self->getEntityObject($entity);
        $ENTITY->clearAllMethod();
        $ENTITY->setUniqueCheckValue(0);
    } elsif ($primaryID > 0) {
        $ENTITY = $self->createEntityObject($entity, $primaryID);
    } elsif ($primaryID == 0) {
        $ENTITY = $self->createEntityObject($entity);
    } else {
        return "Internal_error-unknown-primaryID";
    }

    unless ($ENTITY->existsPublicMethodName($method)) {
        $LOG->error("Entities:$entity method:$method not exists!");
        return "Internal_error-entity`s_name_not_exist:$entity:$method";
    }

    my $error = $args[1];

    splice(@args, 0, 2);

    eval "\$SIG{__DIE__}='DEFAULT'; \$ENTITY->\$method(\@args);";

    if ($@) {
        chomp($@);
        my $error = $@;
        $LOG->error($error);
        $LOG->error("ENTITY : $entity [ CRASHED ]");
        $self->unloadEntity($entity);
        $LOG->sendErrorReport("ENTITY", $entity, $method, $error);
        die "Internal error, unknown method entity:$entity, method:$method";
        exit;
    }

    my $unique_error = $ENTITY->existsUniqueError();
    my $entity_error = $ENTITY->error();

    $ENTITY->clearAllMethod();

    return ($unique_error ? "error_validate_unique__" . $error : ($entity_error ? "error_validate__" . $error : undef));
}

sub getEntityObject {
    my ($self, $entity) = @_;
    if ($self->isExistEntity($entity)) {
        return $self->{'entities'}->{$entity};
    } else {
        $LOG->error("Unknown entity $entity !");
        return {};
    }
}

sub getLoadEntitiesList {
    my $self   = shift;
    my $result = [];
    foreach (keys %{$self->{'entities'}}) { push(@{$result}, $_); }
    return $result;
}

sub getEntitiesDir {
    my $self = shift;
    return $CONF->getValue("pwe", "home", undef) . $CONF->getValue("pwe", "entities_dir", undef);
}

sub getEntitiesResourceBundleDir {
    my $self    = shift;
    my $result  = [];
    my $ent_dir = $CONF->getValue("pwe", "entities_dir", undef);
    foreach my $ent_name (@{$self->getLoadEntitiesList()}) {
        push(@{$result}, "$ent_dir$ent_name/");
    }
    return $result;
}

sub isExistEntity {
    my ($self, $entity) = @_;
    return 1 if (defined($self->{'entities'}->{$entity}));
    return 0;
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
    $LOG      = new Libs::Log;
    $CONF     = new Libs::Config;
    $DBI      = new Libs::DBI;
    $USER     = new Libs::User;
    $WEB      = new Libs::Web;
    $VALIDATE = new Libs::Validate;
}

1;
