package Libs::MyDBI::DRIVER::Postgre;

=head1 NAME

Libs::MyDBI::DRIVER::Postgre - driver pro PostgreSQL (DBD::Pg), jedno spojeni se schematem

=cut

use strict;
use DBI;

=head2 B<[Public] new()>

    Konstruktor driveru - jen vychozi hodnoty, pripojeni dela connect(). Vychozi konfigurace:
    host localhost, port 5432, login postgres, password sa, database postgres, encoding UTF8,
    schema public, loglevel 0, logfile /dev/null, autocommit vypnuty, pool lock 0, dsn_options
    prazdne.
    Driver drzi jedno DBI spojeni (DBI) pro cteni i zapis.

    'loglevel' je DBI trace level (viz http://perltraining.com.au/talks/dbi-trick.pdf):
    0 - vypnuto, 1 - volani DBI metod s vysledky/chybami, 2 - navic vstup do metod s parametry,
    3 - navic informace z driveru a DBI, 4 - podrobnejsi informace z driveru, 5 a vice - dalsi
    detaily. Vystup trace jde do 'logfile'.

    Datove typy Postgres: http://www.tutorialspoint.com/postgresql/postgresql_data_types.htm

=cut

sub new {
    my $class = shift;
    my $self  = {
        'DBI'          => {},            # DBI object
        'host'         => "localhost",
        'port'         => "5432",
        'login'        => "postgres",
        'password'     => "sa",
        'database'     => "postgres",
        'encoding'     => "UTF8",
        'schema'       => "public",
        'loglevel'     => 0,
        'logfile'      => "/dev/null",
        'pool_is_lock' => 0,             # Pouziva se pro zamek pri predavani connection z poolu
        'acommit'      => 0,
        'dsn_options'  => "",            # Doplnkove volby DSN (conf 'dsn_options'), napr. "sslmode=require"
    };
    bless $self, $class;
    return $self;
}

=head2 B<[Public] connect($config)>

    Pripoji se k databazi podle $config (klice host, port, login, password, database, encoding,
    schema, loglevel, logfile, autocommit, dsn_options, homepath; chybejici klic ponecha drive
    nastavenou/vychozi hodnotu). Relativni 'logfile' se doplni o homepath, absolutni (zacina /)
    zustane beze zmeny. Otevre jedno DBI spojeni dbi:Pg (AutoCommit podle 'autocommit', RaiseError/
    PrintError vypnute, InactiveDestroy, TaintIn/TaintOut), nastavi pg_enable_utf8 = 0 (data
    z DB se vraceji bez utf8 flagu; bind hodnoty se naopak pred provedenim utf8::decode-uji,
    viz select/insert/update/delete) a DBI trace(loglevel, logfile). 'schema' se pouziva jen
    pri cteni metadat (getMetaData), 'encoding' se zatim na spojeni neaplikuje. Vraci 1 pri
    uspechu, 0 pri chybe; chybu DBI z neuspesneho pokusu ($DBI::err, $DBI::errstr, $DBI::state)
    pak vraci getError() (heslo v ni neni), uspesne pripojeni ulozenou chybu smaze. Bez $config
    (volani z reconnect) pouzije hodnoty ulozene z predchoziho connect.

    'dsn_options' jsou volitelne doplnkove volby DSN ovladace DBD::Pg oddelene strednikem (viz
    getDsn), napr. "sslmode=require" nebo "connect_timeout=5". Bez nich je DSN stejny jako
    v drivejsich verzich.

=cut

sub connect {
    my ($self, $config) = @_;

    my $homepath = $config->{'homepath'};

    # GLOB PROPERTIES
    $self->{'host'}     = ($config->{'host'}     ? $config->{'host'}     : $self->{'host'});
    $self->{'port'}     = ($config->{'port'}     ? $config->{'port'}     : $self->{'port'});
    $self->{'login'}    = ($config->{'login'}    ? $config->{'login'}    : $self->{'login'});
    $self->{'password'} = ($config->{'password'} ? $config->{'password'} : $self->{'password'});
    $self->{'database'} = ($config->{'database'} ? $config->{'database'} : $self->{'database'});
    $self->{'encoding'} = ($config->{'encoding'} ? $config->{'encoding'} : $self->{'encoding'});
    $self->{'loglevel'} = ($config->{'loglevel'} ? $config->{'loglevel'} : $self->{'loglevel'});
    $self->{'logfile'} = ($config->{'logfile'}    ? (($config->{'logfile'} =~ /^\//) ? $config->{'logfile'} : $homepath . $config->{'logfile'}) : $self->{'logfile'});
    $self->{'schema'}  = ($config->{'schema'}     ? $config->{'schema'}                                            : $self->{'schema'});
    $self->{'acommit'} = ($config->{'autocommit'} ? $config->{'autocommit'}                                        : $self->{'acommit'});
    $self->{'dsn_options'} = $config->{'dsn_options'} if (defined($config->{'dsn_options'}));

    # CREATE CONNECTIONS
    my $dbi = DBI->connect(
        $self->getDsn(),
        $self->{'login'},
        $self->{'password'},
        {
            'RaiseError'          => 0,
            'PrintError'          => 0,
            'PrintWarn'           => 0,
            'AutoCommit'          => $self->{'acommit'},
            'InactiveDestroy'     => 1,
            'AutoInactiveDestroy' => 1,
            'TaintIn'             => 1,
            'TaintOut'            => 1,
        }
    );

    if ($dbi) {

        # SET FORCE DB ENCODING
        # README: http://blog.endpoint.com/2014/02/dbdpg-utf-8-perl-postgresql.html?m=1
        #
        # If this attribute is set to 0, then the internal C<utf8> flag will *never* be.
        # turned on for returned data, regardless of the current client_encoding..
        #
        # Diky zmene ve verzi 3.x v knihovne DBD:Pg se toho hodne zmenilo, vznikli problemy s ctenim a
        # zapisem utf8 stringu. Momentalne je objekt CGI nastavena tak, aby davala data z formularu/webu v
        # decode rezimu, my si ale musime pohlidat interni praci s v perlu a decodovat vse co jde do db.
        # Stejne tak, kdyz cteme data ze souboru a rveme je do dotabaze.
        $dbi->{'pg_enable_utf8'} = 0;

        # INCLUDE DBIOBJECT
        $self->{'DBI'} = $dbi;

        # SET LOGING/DEBUGING
        $self->{'DBI'}->trace($self->{'loglevel'}, $self->{'logfile'});

        $self->{'err'} = $self->{'errstr'} = $self->{'state'} = undef;

        return 1;
    }

    # Chyba pripojeni pro getError()/error() - Libs::MyDBI ji zapise do logu.
    $self->{'err'}    = $DBI::err;
    $self->{'errstr'} = $DBI::errstr;
    $self->{'state'}  = $DBI::state;

    return 0;
}

=head2 B<[Private] getDsn()>

    Slozi DSN pro DBI->connect: "dbi:Pg:dbname=<database>;host=<host>;port=<port>" a za nej
    volby z conf 'dsn_options' (oddelene strednikem, stredniky a mezery na okrajich se oriznou).
    Bez 'dsn_options' je DSN stejny jako v drivejsich verzich. Heslo v DSN neni, predava se DBI
    zvlast.

=cut

sub getDsn {
    my $self = shift;

    my $dsn = "dbi:Pg:dbname=$self->{'database'};host=$self->{'host'};port=$self->{'port'}";

    (my $options = (defined($self->{'dsn_options'}) ? $self->{'dsn_options'} : "")) =~ s/^[;\s]+|[;\s]+$//g;
    $dsn .= ";" . $options if (length($options));

    return $dsn;
}

=head2 B<[Public] reconnect()>

    Provede disconnect() a znovu connect() s drive ulozenou konfiguraci. Vraci vysledek connect (1/0).

=cut

sub reconnect {
    my $self = shift;
    $self->disconnect();
    $self->connect();
}

=head2 B<[Public] disconnect()>

    Odpoji DBI spojeni od databaze.

=cut

sub disconnect {
    my $self = shift;
    $self->{'DBI'}->disconnect;
}

=head2 B<[Public] select($select,$hodnoty)>

    Provede dotaz "SELECT $select" a vrati DBI statement handle, ze ktereho si volajici data
    vybere. Bind hodnoty pred provedenim utf8::decode-uje (na kopii, pole volajiciho se nemeni).
    Chybu statementu ulozi pres setError.

        my $SQL = $self->select("* FROM tabulka WHERE sloupec1 = ?", ["hodnota"]);
        while (my ($a, $b, $c) = $SQL->fetchrow_array()) { ... }
        $SQL->finish();

    $select  - dotaz bez slova SELECT, napr. "* FROM tabulka WHERE sloupec1 = ?"
    $hodnoty - reference na pole bind hodnot, napr. ["hodnota"]

=cut

sub select {
    my $self   = shift;
    my $select = shift;
    my @values = (@{$_[0]});
    foreach (@values) { utf8::decode($_); }
    my $query = $self->{'DBI'}->prepare_cached("SELECT $select", undef, 3);
    $query->execute(@values);
    $self->setError($query);
    return $query;
}

=head2 B<[Public] insert($insert,$hodnoty)>

    Provede "INSERT $insert", bind hodnoty pred provedenim utf8::decode-uje, chybu ulozi pres
    setError. Nic nevraci.
    $insert  - cast prikazu za slovem INSERT, napr. "INTO tabulka (login, text) VALUES (?, ?)"
    $hodnoty - reference na pole bind hodnot, napr. ["hodnota1","hodnota2"]

=cut

sub insert {
    my $self   = shift;
    my $insert = shift;
    my @values = (@{$_[0]});
    foreach (@values) { utf8::decode($_); }
    my $query = $self->{'DBI'}->prepare_cached("INSERT $insert", undef, 3);
    $query->execute(@values);
    $self->setError($query);
    $query->finish();
}

=head2 B<[Public] update($update,$hodnoty)>

    Provede "UPDATE $update", bind hodnoty pred provedenim utf8::decode-uje, chybu ulozi pres
    setError. Vraci pocet ovlivnenych radku z DBI execute ("0E0" pri nule, undef pri chybe).
    $update  - cast prikazu za slovem UPDATE, napr. "tabulka SET text = ? WHERE id = ? AND login = ?"
    $hodnoty - reference na pole bind hodnot, napr. ["hodnota1","hodnota2","hodnotaN"]

=cut

sub update {
    my $self   = shift;
    my $update = shift;
    my @values = (@{$_[0]});
    foreach (@values) { utf8::decode($_); }
    my $query = $self->{'DBI'}->prepare_cached("UPDATE $update", undef, 3);
    my $rv    = $query->execute(@values);
    $self->setError($query);
    $query->finish();
    return $rv;
}

=head2 B<[Public] delete($delete,$hodnoty)>

    Provede "DELETE $delete", bind hodnoty pred provedenim utf8::decode-uje, chybu ulozi pres
    setError. Nic nevraci.
    $delete  - cast prikazu za slovem DELETE, napr. "FROM tabulka WHERE id = ? AND login = ?"
    $hodnoty - reference na pole bind hodnot, napr. ["hodnota1","hodnotaN"]

=cut

sub delete {
    my $self   = shift;
    my $delete = shift;
    my @values = (@{$_[0]});
    foreach (@values) { utf8::decode($_); }
    my $query = $self->{'DBI'}->prepare_cached("DELETE $delete", undef, 3);
    $query->execute(@values);
    $self->setError($query);
    $query->finish();
}

=head2 B<[Public] autoCommit($value)>

    Zapne ($value pravdive) nebo vypne autocommit na spojeni (atribut DBI AutoCommit).

=cut

sub autoCommit {
    my ($self, $value) = @_;

    if ($value) {
        $self->{'DBI'}->{'AutoCommit'} = 1;
    } else {
        $self->{'DBI'}->{'AutoCommit'} = 0;
    }
}

=head2 B<[Public] commit()>

    Potvrdi transakci na spojeni a pres setError() prevezme pripadnou chybu z handle.
    Vysledek overte pres error().

=cut

sub commit {
    my $self   = shift;
    my $result = $self->{'DBI'}->commit;
    $self->setError();
    return $result;
}

=head2 B<[Public] rollback()>

    Vrati zpet transakci na spojeni a pres setError() prevezme pripadnou chybu z handle.
    Vysledek overte pres error().

=cut

sub rollback {
    my $self   = shift;
    my $result = $self->{'DBI'}->rollback;
    $self->setError();
    return $result;
}

=head2 B<[Public] command($command)>

    Provede libovolny cely SQL prikaz pres DBI do() (bez bind hodnot), chybu prevezme pres
    setError(). Vraci navratovou hodnotu do(): pocet ovlivnenych radku ("0E0" pri nule, -1 pokud
    neni znam), pri chybe undef.
    $command - cely prikaz, napr. "CREATE TABLE ..."

=cut

sub command {
    my ($self, $command) = @_;
    my $result = $self->{'DBI'}->do($command);
    $self->setError();
    return $result;
}

=head2 B<[Public] lastInsertID($table)>

    Vraci id posledniho INSERTu do tabulky $table pres DBI last_insert_id(undef, undef, $table, undef);
    DBD::Pg podle nazvu tabulky dohleda sekvenci (SERIAL) primarniho klice a vrati jeji aktualni
    hodnotu, proto je $table nutny.
    POZOR: u transakcnich spojeni je nutne volat PRED commitem, jinak vraci 0.

=cut

sub lastInsertID {
    my ($self, $table) = @_;
    return $self->{'DBI'}->last_insert_id(undef, undef, $table, undef);
}

=head2 B<[Public] ping()>

    Overi spojeni pres DBI ping(). Vraci 1 (spojeni zije) nebo 0.

=cut

sub ping {
    my $self = shift;

    return 1 if ($self->{'DBI'}->ping());
    return 0;
}

=head2 B<[Public] getMetaData()>

    Nacte z information_schema (tables, columns, constraint_column_usage, table_constraints)
    popis vsech tabulek v nastavenem 'schema' a 'database' a vrati hash - DAO mapu:
    { tabulka => { TABLE_NAME, TABLE_SCHEM, TABLE_TYPE ("BASE TABLE"/"VIEW"),
    TABLE_COLUMNS => { sloupec => { COLUMN_NAME, COLUMN_TYPE (data_type, napr. "integer",
    "character varying"), COLUMN_SIZE (character_maximum_length, jinak numeric_precision),
    COLUMN_NULLABLE, COLUMN_DEF, COLUMN_UNSIGNED (vzdy 0, Postgres unsigned nema),
    COLUMN_PRIMARY, COLUMN_UNIQUE } } } }.
    COLUMN_DEF: default nextval(...)::regclass (SERIAL) se vynecha, u retezcu se z
    'hodnota'::character varying vezme jen hodnota. Na rozdil od MySQL driveru chybi TABLE_ENGINE
    a COLUMN_ENUM_VALUE. Pouziva Libs::MyDBI::getDaoMetaData.

=cut

sub getMetaData {
    my $self = shift;

    my $meta = {};

    # TODO : Pokud PWE nepujde spusti a bude hlasit tuto chybu
    #        Can't call method "fetchrow_hashref" on an undefined value....
    #        pak je to proto, ze neni mozne ziskas schema z databaze (databaze je poskozena).
    #        Mel by se na toto misto dopsat die 'Error', ale zatim nevim jak z objektu DBI ziskat informaci o chybe.

    my $dbname = $self->{'database'};
    my $schema = $self->{'schema'};

    my $SQL = $self->{'DBI'}->prepare("SELECT * FROM information_schema.tables WHERE table_schema = '$schema' AND table_catalog = '$dbname'");
    $SQL->execute();

    while (my $t = $SQL->fetchrow_hashref) {

        $meta->{$t->{'table_name'}}->{'TABLE_TYPE'}  = $t->{'table_type'};
        $meta->{$t->{'table_name'}}->{'TABLE_NAME'}  = $t->{'table_name'};
        $meta->{$t->{'table_name'}}->{'TABLE_SCHEM'} = $t->{'table_schema'};

        my $SQL1 = $self->{'DBI'}->prepare("SELECT * FROM information_schema.columns WHERE table_schema = '$schema' AND table_catalog = '$dbname' AND table_name = '$t->{'table_name'}'");
        $SQL1->execute();

        while (my $h = $SQL1->fetchrow_hashref) {

            # SET TABLE INFO
            $meta->{$t->{'table_name'}}->{'TABLE_COLUMNS'}->{$h->{'column_name'}}->{'COLUMN_NAME'}     = $h->{'column_name'};
            $meta->{$t->{'table_name'}}->{'TABLE_COLUMNS'}->{$h->{'column_name'}}->{'COLUMN_NULLABLE'} = (($h->{'is_nullable'} eq "YES") ? 1 : 0);
            $meta->{$t->{'table_name'}}->{'TABLE_COLUMNS'}->{$h->{'column_name'}}->{'COLUMN_DEF'}      = $h->{'column_default'} if (($h->{'column_default'} !~ /::regclass/) and ($h->{'column_default'} !~ /::character/));
            $meta->{$t->{'table_name'}}->{'TABLE_COLUMNS'}->{$h->{'column_name'}}->{'COLUMN_DEF'}      = "$1" if ($h->{'column_default'} =~ /\'(.*)\'::character/);
            $meta->{$t->{'table_name'}}->{'TABLE_COLUMNS'}->{$h->{'column_name'}}->{'COLUMN_UNSIGNED'} = 0;                                                                                                                    # Postgreska nema unsigned integer

            $meta->{$t->{'table_name'}}->{'TABLE_COLUMNS'}->{$h->{'column_name'}}->{'COLUMN_TYPE'} = $h->{'data_type'};
            $meta->{$t->{'table_name'}}->{'TABLE_COLUMNS'}->{$h->{'column_name'}}->{'COLUMN_SIZE'} = (defined($h->{'character_maximum_length'}) ? $h->{'character_maximum_length'} : $h->{'numeric_precision'});

            my $SQL2 = $self->{'DBI'}->prepare("SELECT * FROM information_schema.constraint_column_usage WHERE table_schema = '$schema' and table_catalog = '$dbname' AND table_name = '$t->{'table_name'}' AND column_name = '$h->{'column_name'}'");
            $SQL2->execute();
            while (my $c = $SQL2->fetchrow_hashref) {

                my $SQL3 = $self->{'DBI'}->prepare("SELECT constraint_type FROM information_schema.table_constraints WHERE table_schema = '$schema' and table_catalog = '$dbname' AND table_name = '$t->{'table_name'}' AND constraint_name = '$c->{'constraint_name'}'");
                $SQL3->execute();
                my $constraint_type = $SQL3->fetchrow_array();
                $SQL3->finish();

                $meta->{$t->{'table_name'}}->{'TABLE_COLUMNS'}->{$h->{'column_name'}}->{'COLUMN_PRIMARY'} = (($constraint_type eq 'PRIMARY KEY') ? 1 : 0);
                $meta->{$t->{'table_name'}}->{'TABLE_COLUMNS'}->{$h->{'column_name'}}->{'COLUMN_UNIQUE'}  = (($constraint_type eq 'UNIQUE')      ? 1 : 0);
            }
            $SQL2->finish();
        }
        $SQL1->finish();
    }
    $SQL->finish();
    return $meta;
}

=head2 B<[Public] getError()>

    Vraci hash { err, errstr, state } s chybou posledni operace, tak jak ji ulozil setError,
    nebo s chybou neuspesneho connect() (bez chyby jsou hodnoty undef).

=cut

sub getError {
    my $self = shift;
    return {
        'err'    => $self->{'err'},
        'errstr' => $self->{'errstr'},
        'state'  => $self->{'state'}
    };
}

=head2 B<[Public] getPoolLock()>

    Vraci 1, pokud je spojeni zamcene (pool 0, nebo si ho vypujcil DAO objekt), jinak 0.
    Podle toho Libs::MyDBI::createDAO vybira volne spojeni z poolu.

=cut

sub getPoolLock {
    my $self = shift;
    return $self->{'pool_is_lock'};
}

=head2 B<[Public] error()>

    Vraci 1, pokud posledni operace skoncila chybou (setError ulozil definovany err), jinak 0.

=cut

sub error {
    my $self = shift;
    return 1 if (defined($self->{'err'}));
    return 0;
}

=head2 B<[Private] setError($sth)>

    Ulozi do objektu stav chyby (err, errstr, state) pro getError()/error(). Se statement handlem
    $sth prevezme hodnoty z nej (select/insert/update/delete); bez argumentu (commit/rollback/
    command) z databazoveho handle DBI. Pokud handle chybu nehlasi, predchozi chyba se smaze.

=cut

sub setError {
    my ($self, $query) = @_;

    if ($query) {
        $self->{'err'}    = $query->err;
        $self->{'errstr'} = $query->errstr;
        $self->{'state'}  = $query->state;
    } else {

        # Bez statementu prebirame stav z handle. Pokud handle chybu nehlasi,
        # predchozi chyba se smaze - jinak by "visela" az do dalsiho selectu.
        $self->{'err'}    = $self->{'DBI'}->err;
        $self->{'errstr'} = $self->{'DBI'}->errstr;
        $self->{'state'}  = $self->{'DBI'}->state;
    }
}

=head2 B<[Public] setPoolLock($value)>

    Nastavi pool lock spojeni na 1 ($value pravdive) nebo 0. Libs::MyDBI zamyka natrvalo pool 0,
    DAO objekt si zamkne vypujcene spojeni pri vytvoreni a v DESTROY ho zase uvolni.

=cut

sub setPoolLock {
    my ($self, $value) = @_;

    if ($value) {
        $self->{'pool_is_lock'} = 1;
    } else {
        $self->{'pool_is_lock'} = 0;
    }
}

=head2 B<[Private] DESTROY()>

    Pri zaniku pripojeneho objektu provede rollback nepotvrzene transakce. Nepripojeny
    objekt (bez DBI handle) se preskoci.

=cut

sub DESTROY {
    my $self = shift;

    # Nepripojeny objekt (DBI je jen prazdny hash) nema co rollbackovat.
    return unless (ref($self->{'DBI'}) and ref($self->{'DBI'}) ne "HASH");
    $self->rollback;
}

1;
