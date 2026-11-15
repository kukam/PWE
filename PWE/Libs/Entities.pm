package Libs::Entities;

=head1 NAME

Libs::Entities - loader entit (objektovych obalek DB tabulek) a jejich pouziti pri validaci

=head1 POPIS

    Entita = Entities/<X>/<X>.pm dedici z Entities::Entity. Loader drzi jednu sdilenou instanci
    kazde entity (pro validaci a metadata); pro praci s daty se vytvari nove instance pres
    createEntityObject. Bez databaze se zadna entita nenacte (weby bez DB).

=cut

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB);

=head2 B<[Public] new($conf,$log,$validate,$dbi,$user,$web)>

    Konstruktor loaderu entit. Nacte vsechny entity (Entities/<X>/<X>.pm) a pro kazdou vytvori
    jednu sdilenou instanci nad DB poolem 0 (disable_db_pooler), ktera slouzi k validaci
    a ke zjistovani metadat tabulky. Vytvari se pred Services.

=cut

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

=head2 B<[Private] loadEntities()>

    Nacte vsechny entity nalezene metodou findEntities.

=cut

sub loadEntities {
    my $self = shift;
    foreach my $entity ($self->findEntities()) {
        $LOG->delay("entity_name_$entity");
        $self->loadEntity($entity);
        $LOG->delay("entity_name_$entity", "Loaded entity $entity");
    }
}

=head2 B<[Private] findEntities()>

    Vrati abecedne serazeny seznam adresaru s <Adresar>/<Adresar>.pm ze vsech korenu
    (Libs::Config::getModuleRoots: web, pak engine omezeny na pwe.core_entities); web ma prednost.

=cut

sub findEntities {
    my $self = shift;
    my (@entities, %seen);
    foreach my $root ($CONF->getModuleRoots('entities')) {
        opendir(my $dh, $root->{'dir'}) or next;
        foreach my $entity (readdir($dh)) {
            next if ($entity =~ /^\./ or $seen{$entity});
            next unless (-d "$root->{'dir'}/$entity" and -f "$root->{'dir'}/$entity/$entity.pm");
            next if ($root->{'allowed'} and !$root->{'allowed'}->{$entity});
            $seen{$entity} = 1;
            push(@entities, $entity);
        }
        closedir($dh);
    }
    @entities = sort { $a cmp $b } @entities;
    return @entities;
}

=head2 B<[Private] loadEntity($entity)>

    Nacte modul Entities::<entity>::<entity> a vytvori sdilenou instanci (createEntityObject
    s {disable_db_pooler => 1}). Vraci 1/0. Bez databaze (nebo bez tabulky v DAO mape)
    konstruktor entity selze a entita se nenacte - zaloguje se chyba.

=cut

sub loadEntity {
    my ($self, $entity) = @_;

    eval "local \$SIG{__DIE__} = 'DEFAULT'; require Entities::${entity}::${entity};";

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

=head2 B<[Public] createEntityObject($entity,$opts)>

    Vytvori NOVOU instanci entity (DAO objekt nad vlastnim spojenim z poolu):

      createEntityObject('User')                                  - prazdny radek (pro INSERT)
      createEntityObject('User', $id)                             - nacte radek podle primarniho klice
      createEntityObject('User', {where => "sid = ?", conds => [$sid]}) - nacte radek podle podminky
      createEntityObject('User', {disable_db_pooler => 1})        - sdilene spojeni (pool 0)

    Pri chybe konstruktoru vraci undef a zaloguje chybu. Objekt se po skonceni (DESTROY)
    sam uvolni z poolu, drzte ho proto jen v lokalni promenne.

=cut

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
    eval "local \$SIG{__DIE__} = 'DEFAULT'; \$ENTITY = new Entities::${entity}::${entity}(\$conf,\$log,\$validate,\$dbi,\$user,\$web,\$opts);";
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

=head2 B<[Private] unloadEntity($entity)>

    Odregistruje entitu (smaze sdilenou instanci).

=cut

sub unloadEntity {
    my ($self, $entity) = @_;

    eval "no Entities::${entity}::${entity};";

    delete $self->{'entities'}->{$entity};

    $LOG->info("Unloading entity: $entity [ OK ]");
}

=head2 B<[Private] validate([ 'Entities::<entity>::<sloupec>[::<primaryID>]', $error_key, $value ])>

    Validace hodnoty sloupcem entity (pouziva Libs::Pages pro atributy 'validate', 'unique'
    a 'rules'). Bez primaryID pouzije sdilenou instanci s vypnutou kontrolou unikatnosti;
    s primaryID > 0 nacte dany radek (UPDATE), s primaryID = 0 vytvori prazdny (INSERT) -
    v obou pripadech se kontroluje i unikatnost. Vraci undef (OK), "error_validate_unique__<key>"
    pri duplicite, "error_validate__<key>" pri neplatne hodnote, nebo "Internal_error-...".

=cut

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

    eval { local $SIG{__DIE__} = 'DEFAULT'; $ENTITY->$method(@args); };

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

=head2 B<[Public] getEntityObject($entity)>

    Vraci SDILENOU instanci entity (pool 0). Nepouzivejte ji pro zapis - je spolecna pro
    cely proces; pro praci s daty pouzijte createEntityObject. Pri nezname entite vraci {}.

=cut

sub getEntityObject {
    my ($self, $entity) = @_;
    if ($self->isExistEntity($entity)) {
        return $self->{'entities'}->{$entity};
    } else {
        $LOG->error("Unknown entity $entity !");
        return {};
    }
}

=head2 B<[Public] getLoadEntitiesList()>

    Vraci referenci na pole nazvu nactenych entit.

=cut

sub getLoadEntitiesList {
    my $self   = shift;
    my $result = [];
    foreach (keys %{$self->{'entities'}}) { push(@{$result}, $_); }
    return $result;
}

=head2 B<[Private] getEntitiesResourceBundleDir()>

    Vraci referenci na pole relativnich cest adresaru vsech nactenych entit
    (napr. ['Entities/MailQueue/', ...]) - jejich rb*.tmpl se pridavaji do kazde stranky.

=cut

sub getEntitiesResourceBundleDir {
    my $self    = shift;
    my $result  = [];
    my $ent_dir = $CONF->getValue("pwe", "entities_dir", undef);
    foreach my $ent_name (@{$self->getLoadEntitiesList()}) {
        push(@{$result}, "$ent_dir$ent_name/");
    }
    return $result;
}

=head2 B<[Public] isExistEntity($entity)>

    Vraci 1/0 podle toho, zda je entita nactena.

=cut

sub isExistEntity {
    my ($self, $entity) = @_;
    return 1 if (defined($self->{'entities'}->{$entity}));
    return 0;
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
    $LOG      = new Libs::Log;
    $CONF     = new Libs::Config;
    $DBI      = new Libs::DBI;
    $USER     = new Libs::User;
    $WEB      = new Libs::Web;
    $VALIDATE = new Libs::Validate;
}

1;
