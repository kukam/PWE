package Libs::MyDBI::DRIVER::MySQL;

=head1 NAME

Libs::MyDBI::DRIVER::MySQL - driver pro MySQL/MariaDB (DBD::mysql), oddelene spojeni pro cteni a zapis

=cut

use strict;
use DBI;
use Digest::MD5 ();

=head2 B<[Public] new()>

    Konstruktor driveru - jen vychozi hodnoty, pripojeni dela connect(). Vychozi konfigurace:
    host localhost, port 3306, login root, password root, database mysql, encoding utf8,
    loglevel 0, logfile /dev/null, autocommit vypnuty, pool lock 0, dsn_options prazdne.

    Driver drzi DVE spojeni: DBI_R pro SELECTy (AutoCommit = 1) a DBI_W pro zapisy a transakce
    (AutoCommit podle conf 'autocommit'). Duvod: pokud pod Apachem bezi vice FastCGI procesu
    s vypnutym autocommitem, trva po zmene (insert/update/delete) 1-3 s, nez ji ostatni spojeni
    uvidi, a selecty vraceji stara data (zrejme izolace otevrene transakce / cache driveru).
    Samostatne spojeni s autocommitem jen pro cteni to obchazi.

    'loglevel' je DBI trace level (viz http://perltraining.com.au/talks/dbi-trick.pdf):
    0 - vypnuto, 1 - volani DBI metod s vysledky/chybami, 2 - navic vstup do metod s parametry,
    3 - navic informace z driveru a DBI, 4 - podrobnejsi informace z driveru, 5 a vice - dalsi
    detaily. Vystup trace jde do 'logfile'.

=cut

sub new {
    my $class = shift;
    my $self  = {
        'DBI_W'        => {},            # DBI object (write)
        'DBI_R'        => {},            # DBI object (only ready) viz buga popsana vyse.
        'host'         => "localhost",
        'port'         => "3306",
        'login'        => "root",
        'password'     => "root",
        'database'     => "mysql",
        'encoding'     => "utf8",
        'loglevel'     => 0,
        'logfile'      => "/dev/null",
        'pool_is_lock' => 0,             # Pouziva se pro zamek pri predavani connection z poolu
        'acommit'      => 0,
        'dsn_options'  => "",            # Doplnkove volby DSN (conf 'dsn_options'), napr. "mysql_ssl=1"
    };
    bless $self, $class;
    return $self;
}

=head2 B<[Public] connect($config)>

    Pripoji se k databazi podle $config (klice host, port, login, password, database, encoding,
    loglevel, logfile, autocommit, dsn_options, homepath; chybejici klic ponecha drive nastavenou/
    vychozi hodnotu). Relativni 'logfile' se doplni o homepath, absolutni (zacina /) zustane beze
    zmeny. Otevre dve DBI spojeni dbi:mysql - DBI_R (AutoCommit = 1, pro select) a DBI_W (AutoCommit
    podle 'autocommit', pro zapis) - s vypnutym RaiseError/PrintError, na obou nastavi
    SET NAMES <encoding> a DBI trace(loglevel, logfile). Vraci 1 pri uspechu, 0 pokud se nektere
    ze spojeni nepodari; chybu DBI z neuspesneho pokusu pak vraci getError() (heslo v ni neni).
    Pokud se nepodari cteci spojeni, zapisove se uz nezkousi; pokud se nepodari jen zapisove,
    cteci se zase odpoji. Bez $config (volani z reconnect) pouzije hodnoty ulozene z predchoziho
    connect.

    'dsn_options' jsou volitelne doplnkove volby DSN ovladace DBD::mysql oddelene strednikem
    (viz getDsn), napr. "mysql_ssl=1;mysql_ssl_ca_file=/etc/ssl/db-ca.pem" nebo
    "mysql_connect_timeout=5". Bez nich je DSN stejny jako v drivejsich verzich a o sifrovani
    rozhoduje dbiConnect: MySQL 8+ (caching_sha2_password) se pripoji pres TLS az tehdy, kdyz
    server nesifrovane prihlaseni odmitne.

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
    $self->{'logfile'} = ($config->{'logfile'} ? (($config->{'logfile'} =~ /^\//) ? $config->{'logfile'} : $homepath . $config->{'logfile'}) : $self->{'logfile'});
    $self->{'acommit'} = ($config->{'autocommit'} ? $config->{'autocommit'} : $self->{'acommit'});
    $self->{'dsn_options'} = $config->{'dsn_options'} if (defined($config->{'dsn_options'}));

    # CREATE CONNECTIONS
    my $dbi_r = $self->dbiConnect(1);
    my $dbi_w = ($dbi_r ? $self->dbiConnect($self->{'acommit'}) : undef);

    if ($dbi_r and $dbi_w) {

        # INCLUDE DBIOBJECT
        $self->{'DBI_R'} = $dbi_r;
        $self->{'DBI_W'} = $dbi_w;

        # Nove spojeni zadny zamek spojeni nedrzi (viz sessionLock).
        delete($self->{'session_lock_reconnect'});

        # SET ENCODING
        $self->{'DBI_R'}->do("SET NAMES $self->{'encoding'}");
        $self->{'DBI_W'}->do("SET NAMES $self->{'encoding'}");

        # SET LOGING/DEBUGING
        $self->{'DBI_R'}->trace($self->{'loglevel'}, $self->{'logfile'});
        $self->{'DBI_W'}->trace($self->{'loglevel'}, $self->{'logfile'});

        return 1;
    }

    # Pripojilo se jen cteci spojeni: zavreme ho, jinak by (InactiveDestroy) zustalo otevrene
    # do konce procesu a kazdy dalsi pokus o pripojeni by pridal dalsi.
    $dbi_r->disconnect if ($dbi_r);

    return 0;
}

=head2 B<[Private] getDsn($extra)>

    Slozi DSN pro DBI->connect: "dbi:mysql:dbname=<database>;host=<host>;port=<port>", za nej
    volby z conf 'dsn_options' a nakonec $extra (casti se spojuji strednikem, stredniky a mezery
    na jejich okrajich se oriznou). Bez 'dsn_options' a bez $extra je DSN stejny jako v drivejsich
    verzich. Heslo v DSN neni, predava se DBI zvlast.

=cut

sub getDsn {
    my ($self, $extra) = @_;

    my $dsn = "dbi:mysql:dbname=$self->{'database'};host=$self->{'host'};port=$self->{'port'}";

    foreach my $options ($self->{'dsn_options'}, $extra) {
        next unless (defined($options));
        (my $part = $options) =~ s/^[;\s]+|[;\s]+$//g;
        $dsn .= ";" . $part if (length($part));
    }

    return $dsn;
}

=head2 B<[Private] dbiConnect($autocommit)>

    Otevre jedno DBI spojeni (RaiseError/PrintError vypnute, InactiveDestroy, AutoCommit podle
    $autocommit) a vrati DBI handle, pri neuspechu undef.

    Nejdriv zkusi DSN z getDsn(), tedy stejne (nesifrovane) spojeni jako drivejsi verze. MySQL 8+
    s vychozim pluginem caching_sha2_password ale plne overeni hesla po nesifrovanem spojeni
    odmitne - klientska knihovna vrati chybu 2061 (CR_AUTH_PLUGIN_ERR) "Authentication plugin
    'caching_sha2_password' reported error: Authentication requires secure connection." Po teto
    chybe se pokus zopakuje s volbou mysql_ssl=1 (TLS bez overeni certifikatu serveru). MariaDB
    a starsi MySQL (mysql_native_password) chybu 2061 nevraceji, pripojuji se tedy beze zmeny.
    Zalozni pokus se nedela, pokud TLS ridi uz 'dsn_options' (obsahuji mysql_ssl=...; hodnotou
    mysql_ssl=0 se tak da vypnout). Volbu mysql_get_server_pubkey (vymena verejneho klice serveru
    misto TLS) sestaveni DBD::mysql 4.053 z Ubuntu 26.04 nezna a tise ji ignoruje, proto TLS.

    Pozn.: server si overene heslo drzi v pameti, dalsi nesifrovana prihlaseni tehoz uctu pak
    projdou i bez TLS (do restartu serveru nebo FLUSH PRIVILEGES). Ktera spojeni poolu jsou
    sifrovana, proto neni dane predem; trvale TLS zajisti dsn_options => "mysql_ssl=1".

    Chybu neuspesneho pokusu ($DBI::err, $DBI::errstr, $DBI::state) ulozi pro getError()/error(),
    uspesne pripojeni ulozenou chybu smaze.

=cut

sub dbiConnect {
    my ($self, $autocommit) = @_;

    my @dsn = ($self->getDsn());
    push(@dsn, $self->getDsn("mysql_ssl=1")) unless ($dsn[0] =~ /mysql_ssl=/);

    foreach my $dsn (@dsn) {
        my $dbh = DBI->connect($dsn, $self->{'login'}, $self->{'password'}, {'RaiseError' => 0, 'PrintError' => 0, 'PrintWarn' => 0, 'AutoCommit' => $autocommit, 'InactiveDestroy' => 1});

        if ($dbh) {
            $self->{'err'} = $self->{'errstr'} = $self->{'state'} = undef;
            return $dbh;
        }

        $self->{'err'}    = $DBI::err;
        $self->{'errstr'} = $DBI::errstr;
        $self->{'state'}  = $DBI::state;

        # Dalsi (sifrovany) pokus jen po chybe "Authentication requires secure connection";
        # nedostupny server, spatne heslo apod. by dopadly stejne.
        last unless (defined($self->{'err'}) and ($self->{'err'} == 2061));
    }

    return undef;
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

    Odpoji obe DBI spojeni (DBI_R i DBI_W) od databaze.

=cut

sub disconnect {
    my $self = shift;
    $self->{'DBI_R'}->disconnect;
    $self->{'DBI_W'}->disconnect;
}

=head2 B<[Public] select($select,$hodnoty)>

    Provede dotaz "SELECT $select" nad ctecim spojenim DBI_R a vrati DBI statement handle,
    ze ktereho si volajici data vybere. Chybu statementu ulozi pres setError.

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
    my $query  = $self->{'DBI_R'}->prepare_cached("SELECT $select", undef, 3);
    $query->execute(@values);
    $self->setError($query);
    return $query;
}

=head2 B<[Public] insert($insert,$hodnoty)>

    Provede "INSERT $insert" nad zapisovym spojenim DBI_W, chybu ulozi pres setError. Nic nevraci.
    $insert  - cast prikazu za slovem INSERT, napr. "INTO `tabulka` (`user`, `text`) VALUES (?, ?)"
    $hodnoty - reference na pole bind hodnot, napr. ["hodnota1","hodnota2"]

=cut

sub insert {
    my $self   = shift;
    my $insert = shift;
    my @values = (@{$_[0]});
    my $query  = $self->{'DBI_W'}->prepare_cached("INSERT $insert", undef, 3);
    $query->execute(@values);
    $self->setError($query);
    $query->finish();
}

=head2 B<[Public] update($update,$hodnoty)>

    Provede "UPDATE $update" nad zapisovym spojenim DBI_W, chybu ulozi pres setError.
    Vraci pocet ovlivnenych radku z DBI execute ("0E0" pri nule, undef pri chybe).
    $update  - cast prikazu za slovem UPDATE, napr. "tabulka SET text = ? WHERE id = ? AND user = ?"
    $hodnoty - reference na pole bind hodnot, napr. ["hodnota1","hodnota2","hodnotaN"]

=cut

sub update {
    my $self   = shift;
    my $update = shift;
    my @values = (@{$_[0]});
    my $query  = $self->{'DBI_W'}->prepare_cached("UPDATE $update", undef, 3);
    my $rv     = $query->execute(@values);
    $self->setError($query);
    $query->finish();
    return $rv;
}

=head2 B<[Public] delete($delete,$hodnoty)>

    Provede "DELETE $delete" nad zapisovym spojenim DBI_W, chybu ulozi pres setError. Nic nevraci.
    $delete  - cast prikazu za slovem DELETE, napr. "FROM tabulka WHERE id = ? AND user = ?"
    $hodnoty - reference na pole bind hodnot, napr. ["hodnota1","hodnotaN"]

=cut

sub delete {
    my $self   = shift;
    my $delete = shift;
    my @values = (@{$_[0]});
    my $query  = $self->{'DBI_W'}->prepare_cached("DELETE $delete", undef, 3);
    $query->execute(@values);
    $self->setError($query);
    $query->finish();
}

=head2 B<[Public] autoCommit($value)>

    Zapne ($value pravdive) nebo vypne autocommit na zapisovem spojeni DBI_W (atribut DBI
    AutoCommit). Ctecimu spojeni DBI_R zustava autocommit vzdy zapnuty.

=cut

sub autoCommit {
    my ($self, $value) = @_;

    if ($value) {
        $self->{'DBI_W'}->{'AutoCommit'} = 1;
    } else {
        $self->{'DBI_W'}->{'AutoCommit'} = 0;
    }
}

=head2 B<[Public] commit()>

    Potvrdi transakci na zapisovem spojeni DBI_W a pres setError() prevezme pripadnou chybu z handle.
    Vysledek overte pres error().

=cut

sub commit {
    my $self   = shift;
    my $result = $self->{'DBI_W'}->commit;
    $self->setError();
    return $result;
}

=head2 B<[Public] rollback()>

    Vrati zpet transakci na zapisovem spojeni DBI_W a pres setError() prevezme pripadnou chybu z handle.
    Vysledek overte pres error().

=cut

sub rollback {
    my $self   = shift;
    my $result = $self->{'DBI_W'}->rollback;
    $self->setError();
    return $result;
}

=head2 B<[Public] command($command)>

    Provede libovolny cely SQL prikaz pres DBI do() nad zapisovym spojenim DBI_W (bez bind hodnot),
    chybu prevezme pres setError(). Vraci navratovou hodnotu do(): pocet ovlivnenych radku
    ("0E0" pri nule, -1 pokud neni znam), pri chybe undef.
    $command - cely prikaz, napr. "CREATE TABLE ..."

=cut

sub command {
    my ($self, $command) = @_;
    my $result = $self->{'DBI_W'}->do($command);
    $self->setError();
    return $result;
}

=head2 B<[Public] lastInsertID($table)>

    Vraci id posledniho INSERTu (AUTO_INCREMENT) na zapisovem spojeni DBI_W pres DBI
    last_insert_id(undef, undef, $table, undef).
    POZOR: u transakcnich spojeni je nutne volat PRED commitem, jinak vraci 0.

=cut

sub lastInsertID {
    my ($self, $table) = @_;
    return $self->{'DBI_W'}->last_insert_id(undef, undef, $table, undef);
}

=head2 B<[Public] ping()>

    Overi obe spojeni dotazem "SELECT 1". Vraci 1, pokud odpovi DBI_R i DBI_W, jinak 0.

=cut

sub ping {
    my $self = shift;

    # DBD::mysql ping = mysql_ping bez vysledkove sady (levnejsi nez SELECT 1)
    return 1 if ($self->{'DBI_R'}->ping and $self->{'DBI_W'}->ping);
    return 0;
}

=head2 B<[Public] sessionLock($name,$timeout)>

    Ziska zamek vazany na databazove spojeni (GET_LOCK) se jmenem odvozenym od $name a nazvu
    databaze (viz sessionLockName). Na zamek ceka nejvys $timeout sekund (cele cislo, vychozi 0 =
    jen jeden pokus bez cekani; ceka server, ne Perl). Vraci:
    1     - zamek ziskan,
    0     - do $timeout sekund ho drzi jine spojeni,
    undef - chyba (dotaz selhal nebo GET_LOCK vratil NULL); chyba je pak v getError()/error().

    Zamek se bere nad zapisovym spojenim DBI_W - tim, kterym Libs::MyDBI provadi kroky migrace
    a zapisuje tabulku dbversion: kdyz toto spojeni zanikne (pad procesu, SIGKILL, vypadek site),
    server zamek uvolni sam a migrace zaroven nemuze pokracovat. Zamek neni soucasti transakce,
    commit ani rollback ho neuvolni; uvolnuje ho sessionUnlock() nad stejnym spojenim, odpojeni
    (disconnect/reconnect) nebo konec procesu. Totez spojeni muze zamek ziskat opakovane, pak ho
    musi stejnekrat uvolnit.

    Po dobu drzeni zamku je na DBI_W vypnuty tichy reconnect ovladace (mysql_auto_reconnect):
    spojeni, ktere zaniklo, by se jinak samo obnovilo bez zamku a migrace by pokracovala
    nechranena. Puvodni hodnotu vraci prvni sessionUnlock().

    Pouziva Libs::MyDBI::checkDbversion jako zamek migrace.

=cut

sub sessionLock {
    my ($self, $name, $timeout) = @_;

    $timeout = ((defined($timeout) and ($timeout =~ /^\d+$/)) ? int($timeout) : 0);

    my ($got) = $self->{'DBI_W'}->selectrow_array("SELECT GET_LOCK(?, $timeout)", undef, $self->sessionLockName($name));
    $self->setError($self->{'DBI_W'});
    return undef if ($self->error());

    # NULL = zamek se nepodarilo ziskat z jineho duvodu nez vyprseni casu (napr. nedostatek pameti
    # serveru nebo zruseny dotaz); DBI to jako chybu nehlasi, ulozime ji sami.
    unless (defined($got)) {
        $self->{'err'}    = -1;
        $self->{'errstr'} = "GET_LOCK('" . $self->sessionLockName($name) . "') returned NULL";
        $self->{'state'}  = undef;
        return undef;
    }

    # Tichy reconnect ovladace DBD::mysql (mysql_auto_reconnect - ovladac ho sam zapina pri
    # AutoCommit 1 a promenne GATEWAY_INTERFACE v prostredi) by zamek ztratil bez povsimnuti:
    # nove spojeni zamek nema a migrace by pokracovala bez nej. Po dobu drzeni zamku ho vypneme,
    # ztracene spojeni pak skonci chybou dotazu; puvodni hodnotu vraci sessionUnlock.
    if ($got) {
        $self->{'session_lock_reconnect'} = $self->{'DBI_W'}->{'mysql_auto_reconnect'} unless (exists($self->{'session_lock_reconnect'}));
        $self->{'DBI_W'}->{'mysql_auto_reconnect'} = 0;
    }

    return ($got ? 1 : 0);
}

=head2 B<[Public] sessionUnlock($name)>

    Uvolni zamek ziskany pres sessionLock($name) - RELEASE_LOCK nad stejnym spojenim DBI_W.
    Vraci 1, pokud byl zamek uvolnen, jinak 0 (toto spojeni zamek nedrzi, zamek neexistuje nebo
    dotaz selhal; chyba dotazu je v getError()/error()). Vraci take puvodni nastaveni ticheho
    reconnectu ovladace (mysql_auto_reconnect), ktere sessionLock vypnul.

=cut

sub sessionUnlock {
    my ($self, $name) = @_;

    my ($released) = $self->{'DBI_W'}->selectrow_array("SELECT RELEASE_LOCK(?)", undef, $self->sessionLockName($name));
    $self->setError($self->{'DBI_W'});

    # Zamek uz nedrzime (nebo ho spojeni ztratilo): tichy reconnect ovladace se vraci do puvodniho stavu.
    $self->{'DBI_W'}->{'mysql_auto_reconnect'} = delete($self->{'session_lock_reconnect'}) if (exists($self->{'session_lock_reconnect'}));

    return ($released ? 1 : 0);
}

=head2 B<[Private] sessionLockName($name)>

    Vraci jmeno zamku pro GET_LOCK/RELEASE_LOCK: "pwe.<name>.<database>". Jmena zamku jsou v MySQL
    a MariaDB spolecna pro cely server, proto obsahuji nazev databaze - weby v ruznych databazich
    tehoz serveru se navzajem neblokuji. MySQL povoluje nejvys 64 znaku; delsi jmeno se nahradi
    otiskem "pwe.<md5 hex puvodniho jmena>" (36 znaku).

=cut

sub sessionLockName {
    my ($self, $name) = @_;

    my $lock = "pwe.$name.$self->{'database'}";

    if (length($lock) > 64) {
        my $bytes = $lock;
        utf8::encode($bytes) if (utf8::is_utf8($bytes));
        $lock = "pwe." . Digest::MD5::md5_hex($bytes);
    }

    return $lock;
}

=head2 B<[Public] getMetaData()>

    Nacte pres cteci spojeni DBI_R popis vsech tabulek aktualni databaze (DBI table_info,
    SHOW TABLE STATUS, DESCRIBE, DBI column_info) a vrati hash - DAO mapu:
    { tabulka => { TABLE_NAME, TABLE_SCHEM, TABLE_TYPE ("TABLE"/"VIEW"), TABLE_ENGINE,
    TABLE_COLUMNS => { sloupec => { COLUMN_NAME, COLUMN_TYPE, COLUMN_SIZE, COLUMN_PRIMARY,
    COLUMN_UNIQUE, COLUMN_NULLABLE, COLUMN_DEF, COLUMN_UNSIGNED, COLUMN_ENUM_VALUE } } } }.
    COLUMN_ENUM_VALUE je reference na pole povolenych hodnot (jen u typu ENUM, jinak undef).
    Pouziva Libs::MyDBI::getDaoMetaData.

=cut

sub getMetaData {
    my $self = shift;

    my $meta = {};

    # TODO : Pokud PWE nepujde spusti a bude hlasit tuto chybu
    #        Can't call method "fetchrow_hashref" on an undefined value....
    #        pak je to proto, ze neni mozne ziskas schema z databaze (databaze je poskozena).
    #        Mel by se na toto misto dopsat die 'Error', ale zatim nevim jak z objektu DBI ziskat informaci o chybe.

    my $SQL = $self->{'DBI_R'}->table_info();
    while (my $trow = $SQL->fetchrow_hashref) {

        my $SQL1 = $self->{'DBI_R'}->prepare("SHOW TABLE STATUS LIKE '$trow->{'TABLE_NAME'}'");
        $SQL1->execute();
        while (my $h = $SQL1->fetchrow_hashref) {

            # SET TABLE INFO
            $meta->{$trow->{'TABLE_NAME'}}->{'TABLE_NAME'}    = $trow->{'TABLE_NAME'};
            $meta->{$trow->{'TABLE_NAME'}}->{'TABLE_SCHEM'}   = $trow->{'TABLE_SCHEM'};
            $meta->{$trow->{'TABLE_NAME'}}->{'TABLE_TYPE'}    = $trow->{'TABLE_TYPE'};
            $meta->{$trow->{'TABLE_NAME'}}->{'TABLE_ENGINE'}  = $h->{'Engine'};
            $meta->{$trow->{'TABLE_NAME'}}->{'TABLE_COLUMNS'} = {};

            # SET COLUMN DESCRIBE
            my $SQL2 = $self->{'DBI_R'}->prepare("DESCRIBE $trow->{'TABLE_NAME'}");
            $SQL2->execute();
            while (my $h = $SQL2->fetchrow_hashref) {
                $meta->{$trow->{'TABLE_NAME'}}->{'TABLE_COLUMNS'}->{$h->{'Field'}}->{'COLUMN_NAME'}     = $h->{'Field'};
                $meta->{$trow->{'TABLE_NAME'}}->{'TABLE_COLUMNS'}->{$h->{'Field'}}->{'COLUMN_PRIMARY'}  = (($h->{'Key'} eq "PRI") ? 1 : 0);
                $meta->{$trow->{'TABLE_NAME'}}->{'TABLE_COLUMNS'}->{$h->{'Field'}}->{'COLUMN_UNIQUE'}   = (($h->{'Key'} eq "UNI") ? 1 : 0);
                $meta->{$trow->{'TABLE_NAME'}}->{'TABLE_COLUMNS'}->{$h->{'Field'}}->{'COLUMN_NULLABLE'} = (($h->{'Null'} eq "YES") ? 1 : 0);
                $meta->{$trow->{'TABLE_NAME'}}->{'TABLE_COLUMNS'}->{$h->{'Field'}}->{'COLUMN_DEF'}      = $h->{'Default'};
                $meta->{$trow->{'TABLE_NAME'}}->{'TABLE_COLUMNS'}->{$h->{'Field'}}->{'COLUMN_UNSIGNED'} = (($h->{'Type'} =~ /.*unsigned.*/) ? 1 : 0);
            }
            $SQL2->finish();

            # SET COLUMN INFO
            my $SQL3 = $self->{'DBI_R'}->column_info(undef, $trow->{'TABLE_SCHEM'}, $trow->{'TABLE_NAME'}, '');
            while (my $h = $SQL3->fetchrow_hashref) {
                $meta->{$trow->{'TABLE_NAME'}}->{'TABLE_COLUMNS'}->{$h->{'COLUMN_NAME'}}->{'COLUMN_TYPE'}       = $h->{'TYPE_NAME'};
                $meta->{$trow->{'TABLE_NAME'}}->{'TABLE_COLUMNS'}->{$h->{'COLUMN_NAME'}}->{'COLUMN_SIZE'}       = $h->{'COLUMN_SIZE'};
                $meta->{$trow->{'TABLE_NAME'}}->{'TABLE_COLUMNS'}->{$h->{'COLUMN_NAME'}}->{'COLUMN_ENUM_VALUE'} = (($h->{'TYPE_NAME'} eq "ENUM") ? $h->{'mysql_values'} : undef);
            }
            $SQL3->finish;
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
    command) z databazoveho handle - prednost ma zapisove DBI_W, jinak DBI_R. Pokud zadny handle
    chybu nehlasi, predchozi chyba se smaze.

=cut

sub setError {
    my ($self, $query) = @_;

    if ($query) {
        $self->{'err'}    = $query->err;
        $self->{'errstr'} = $query->errstr;
        $self->{'state'}  = $query->state;
    } else {

        # Bez statementu prebirame stav z handle (zapisovy ma prednost). Pokud zadny
        # handle chybu nehlasi, predchozi chyba se smaze - jinak by "visela" az do dalsiho selectu.
        my $dbh = ($self->{'DBI_W'}->err ? $self->{'DBI_W'} : $self->{'DBI_R'});
        $self->{'err'}    = $dbh->err;
        $self->{'errstr'} = $dbh->errstr;
        $self->{'state'}  = $dbh->state;
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

    # Nepripojeny objekt (DBI_W je jen prazdny hash) nema co rollbackovat.
    return unless (ref($self->{'DBI_W'}) and ref($self->{'DBI_W'}) ne "HASH");
    $self->rollback;
}

1;
