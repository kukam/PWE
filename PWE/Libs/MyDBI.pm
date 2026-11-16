package Libs::MyDBI;

=head1 NAME

Libs::MyDBI - databazova vrstva: pool spojeni, drivery (MySQL/MariaDB, PostgreSQL), migrace dbversion, DAO mapa

=head1 POPIS

    Nizkourovnove API: select/insert/update/delete/command/commit/rollback($dbid, ...), kazdy SQL se
    oznaci komentarem s mistem volani. Objektovy pristup: getDAO (viz Libs::MyDBI::DAO) a entity.

    Ukonceni behem startu: requestStop() nastavi priznak, ktery konstruktor a checkDbversion
    kontroluji na bezpecnych mistech (mezi pokusy o pripojeni, pri cekani na zamek migrace, mezi
    kroky migrace) a po uklidu skonci pres die "Startup interrupted by termination request".

    Zamek migrace (checkDbversion): zamek spojeni ovladace a sloupec dbversion.lockid - zaporne
    cislo zapisuje proces se zamkem spojeni, kladne proces bez nej (i starsi verze enginu).
    Konfigurace v conf dbi.<dbid>: dbversion_session_lock (0 = bez zamku spojeni)
    a dbversion_legacy_lock_wait (po kolika sekundach beze zmeny se prevezme kladny cizi zamek,
    vychozi 300, 0 = nikdy).

=cut

use strict;
use Libs::MyDBI::DAO;

my ($CONF, $LOG, $VALIDATE);

# Priznak "engine ma pri startu skoncit" (requestStop/stopRequested). Promenna paketu jen proto,
# aby ji testy mohly lokalizovat; jinak se nastavuje vyhradne pres requestStop().
our $STOP_REQUESTED = 0;

# Text, se kterym start po zadosti o ukonceni konci (kontrakt s pwe.fcgi - nemenit).
our $STOP_MESSAGE = "Startup interrupted by termination request\n";

# Zamek migrace (checkDbversion). Promenne paketu kvuli testum:
#   DBVERSION_LOCK         - logicke jmeno zamku spojeni (ovladac k nemu prida databazi/schema)
#   DBVERSION_POLL         - delka jednoho cekani na zamek v sekundach
#   DBVERSION_LOG_INTERVAL - po kolika sekundach se opakuje hlaska o cekani na zamek
#   DBVERSION_MAX_TRIES    - pojistka: kolikrat nejvys se zapise zamek lockid (prevzeti, nastaveni,
#                            doplneni radku), nez metoda skonci chybou misto nekonecne smycky
#   DBVERSION_LEGACY_WAIT  - vychozi hodnota conf dbi.<dbid>.dbversion_legacy_lock_wait: po kolika
#                            sekundach beze zmeny se prevezme zamek lockid procesu bez zamku spojeni
#   DBVERSION_CLOCK        - jen pro testy: odkaz na funkci, ktera vraci cas v sekundach misto
#                            hodin procesu (viz dbversionNow)
our $DBVERSION_LOCK         = "dbversion";
our $DBVERSION_POLL         = 1;
our $DBVERSION_LOG_INTERVAL = 30;
our $DBVERSION_MAX_TRIES    = 20;
our $DBVERSION_LEGACY_WAIT  = 300;
our $DBVERSION_CLOCK        = undef;

# 1/0 = monotonni hodiny procesu (CLOCK_MONOTONIC) jsou/nejsou k dispozici; zjisti dbversionNow.
my $DBVERSION_MONOTONIC = undef;

=head2 B<[Public] requestStop()>

    Nastavi priznak "engine ma pri startu skoncit". Funkce paketu: lze ji volat jako
    Libs::MyDBI::requestStop() i Libs::MyDBI->requestStop() (argumenty ignoruje). Jen nastavi
    promennou, takze ji smi volat handler signalu - pwe.fcgi ji vola z handleru SIGTERM behem
    startu. Rozbehnuty krok migrace ani pokus o pripojeni neprerusi; priznak se kontroluje az na
    bezpecnych mistech (viz stopRequested). Vraci 1.

=cut

sub requestStop {
    $STOP_REQUESTED = 1;
    return 1;
}

=head2 B<[Public] stopRequested()>

    Vraci 1, pokud bylo zavolano requestStop(), jinak 0. Konstruktor priznak kontroluje pred
    kazdym pokusem o pripojeni, checkDbversion pri cekani na zamek migrace a pred kazdym krokem
    migrace (nikdy uprostred kroku). Je-li nastaven, uvolni se zamky migrace a start skonci pres
    die "Startup interrupted by termination request\n".

=cut

sub stopRequested {
    return ($STOP_REQUESTED ? 1 : 0);
}

=head2 B<[Public] new($conf,$log,$validate)>

    Konstruktor databazove vrstvy. Pro kazde dbid v sekci 'dbi' (conf/database.conf) vytvori
    db_pool+1 spojeni (pool 0 je sdileny/zamceny pro primo volane select/insert/..., ostatni
    si pujcuji DAO objekty), pri neuspechu to zkousi trayconnect-krat a pak die. Pote spusti
    migrace (checkDbversion, pokud existuje dbversion_file) a nacte DAO mapu struktury tabulek
    (z daomap_file, jinak z information_schema pres getDaoMetaData). Bez sekce 'dbi' bezi
    engine bez databaze (static weby).

    Pred kazdym pokusem o pripojeni (i opakovanym) kontroluje stopRequested(): po zadosti
    o ukonceni (SIGTERM behem startu) dalsi spojeni neotevira, mezi pokusy neceka a konci pres
    die "Startup interrupted by termination request\n".

=cut

sub new {
    my ($class, $conf, $log, $validate) = @_;

    $LOG      = $log;
    $CONF     = $conf;
    $VALIDATE = $validate;

    my $self = {
        'DBC'      => {},    # DBC OBJECTS
        'maps'     => {},    # MAPS OF DB STRUCTURE
        'dbdriver' => {},    # DBDRIVERS
    };

    bless $self, $class;

    my $tray_connet = 1;

    # Connect to Databases + Gen MAPS structure
    foreach my $dbid (keys %{$CONF->getValue("dbi", undef, {})}) {

        my $dbconf = $CONF->getValue("dbi", $dbid, {});
        $dbconf->{'homepath'} = $CONF->getValue("pwe", "home", "");

        $self->{'dbdriver'}->{$dbid} = $dbconf->{'dbdriver'};

        # IS CONNECT OK?
        for (my $dbidpool = 0; $dbidpool <= (($dbconf->{'db_pool'} =~ /^\d+$/) ? $dbconf->{'db_pool'} : 1); $dbidpool++) {

            # Zadost o ukonceni behem startu (SIGTERM): dalsi spojeni uz neotevirame.
            die $STOP_MESSAGE if (stopRequested());

            $LOG->delay("tray_connect_to_db_" . $dbid . "_" . $dbidpool);
            if ($self->createConnection($dbid, $dbidpool, $dbconf)) {
                $self->DBC->{$dbid}->{$dbidpool}->setPoolLock(1) if ($dbidpool == 0);
            } elsif ($tray_connet > ((exists($dbconf->{'trayconnect'}) ? $dbconf->{'trayconnect'} : 0) - 1)) {

                # Unable to connect
                die "Unable connect to $dbid, poolid $dbidpool bye...\n";
            } else {

                # Tray connect
                $tray_connet++;
                $dbidpool--;
                my $delay = $LOG->delay("tray_connect_to_db_" . $dbid . "_" . $dbidpool, "Tray connect to db $dbid dbidpool $dbidpool");

                # Po zadosti o ukonceni uz necekame - smycka skonci hned na svem zacatku.
                sleep(1) if ($delay < 1 and !stopRequested());
                next;
            }
        }

        if ((defined($dbconf->{'dbversion_file'})) and (-f $dbconf->{'homepath'} . "/" . $dbconf->{'dbversion_file'})) {
            $self->checkDbversion($dbid, $dbconf);
        }

        # GET Maps structure
        if ($dbconf->{'dao'}) {
            my $map         = {};
            my $daomap_file = $dbconf->{'homepath'} . $dbconf->{'daomap_file'};
            if (-f $daomap_file) {
                $self->{'maps'}->{$dbid} = do($daomap_file);
            } else {
                $self->{'maps'}->{$dbid} = $self->getDaoMetaData($dbid);
            }
        }
    }

    return $self;
}

=head2 B<[Public] createConnection($dbid,$dbidpool,$dbconf)>

    Vytvori objekt driveru podle dbdriver daneho dbid ("mysql"/"mariadb" -> Libs::MyDBI::DRIVER::MySQL,
    "postgres" -> Libs::MyDBI::DRIVER::Postgre, jinak die),
    ulozi ho do poolu jako $self->DBC->{$dbid}->{$dbidpool} a zavola jeho connect($dbconf).
    Vraci navratovou hodnotu connect (1 = pripojeno, 0 = chyba) a vysledek zaloguje (debug/error);
    k neuspechu pripise chybu DBI z getError() driveru ("... connect_status:0 error:<kod> <text>").
    Vola se z konstruktoru pro kazdy index poolu 0..db_pool; opakovani neuspesnych pokusu resi konstruktor.

=cut

sub createConnection {
    my ($self, $dbid, $dbidpool, $dbconf) = @_;

    $LOG->delay("connect_db");

    $self->DBC->{$dbid}->{$dbidpool} = {};

    if (($self->getDbDriver($dbid) eq "mysql") or ($self->getDbDriver($dbid) eq "mariadb")) {
        require Libs::MyDBI::DRIVER::MySQL;
        $self->DBC->{$dbid}->{$dbidpool} = new Libs::MyDBI::DRIVER::MySQL();
    } elsif ($self->getDbDriver($dbid) eq "postgres") {
        require Libs::MyDBI::DRIVER::Postgre;
        $self->DBC->{$dbid}->{$dbidpool} = new Libs::MyDBI::DRIVER::Postgre();
    } else {
        die "Unknown dbtype name ('" . $self->getDbDriver($dbid) . "')\n";
    }

    # CONNECT DB
    my $connect = $self->DBC->{$dbid}->{$dbidpool}->connect($dbconf);

    my $text = "Connect to $dbconf->{'dbdriver'} dbid:$dbid connect_status:$connect";

    # Pri neuspechu doplnime chybu DBI z driveru (kod a text na jednom radku; heslo ani DSN v ni
    # nejsou) - bez ni neni z logu poznat, proc se engine nepripojil.
    unless ($connect) {
        my $error = $self->DBC->{$dbid}->{$dbidpool}->getError();
        (my $errstr = (defined($error->{'errstr'}) ? $error->{'errstr'} : "")) =~ s/\s+/ /g;
        $text .= " error:" . (defined($error->{'err'}) ? $error->{'err'} : "") . " $errstr" if (length($errstr));
    }

    ($connect ? $LOG->debug($text) : $LOG->error($text));

    $LOG->delay("connect_db", "Connected database " . $self->getDbDriver($dbid));

    return $connect;
}

=head2 B<[Public] reconnect($dbid)>

    Znovu pripoji vsechna spojeni v poolu daneho dbid: pro kazdy dbidpool zavola reconnect driveru
    a overi ho pres ping(). Neuspesny pokus opakuje po 1 s, nejvyse trayconnect-krat (klic
    'trayconnect' v conf 'dbi'); pote die "Unable reconnect ..." a FastCGI proces se restartuje.
    Vola se z testConnection() pri vypadku spojeni.

=cut

sub reconnect {
    my ($self, $dbid) = @_;
    my $dbconf = $CONF->getValue("dbi", $dbid, {});
    foreach my $dbidpool (keys %{$self->DBC->{$dbid}}) {
        my $trayconnect = 0;
        while (1) {
            $trayconnect++;
            $LOG->error("Reconnecting database $dbid dbidpool:$dbidpool");
            $LOG->delay("tray_reconnect_to_db_" . $dbid . "_" . $dbidpool);
            $self->DBC->{$dbid}->{$dbidpool}->reconnect;
            my $delay = $LOG->delay("tray_reconnect_to_db_" . $dbid . "_" . $dbidpool, "Tray reconnect to db $dbid dbidpool $dbidpool");
            last if ($self->ping($dbid, $dbidpool));
            my $max = ((exists($dbconf->{'trayconnect'}) and $dbconf->{'trayconnect'}) ? $dbconf->{'trayconnect'} : 1);
            die "Unable reconnect to $dbid, poolid $dbidpool bye...\n" if ($trayconnect >= $max);
            sleep(1) if ($delay < 1);

        }
    }
}

=head2 B<[Private] checkDbversion($dbid,$dbconf)>

    Migrace databaze podle souboru $dbconf->{'dbversion_file'} (cesta relativne k pwe.home).
    Soubor vraci hash { cislo_verze => "SQL prikaz", ... }; prikazy se spousteji pres command()
    vzestupne podle cisla verze, a to jen ty, jejichz cislo je vyssi nez hodnota ulozena v tabulce
    dbversion (dbversion int, lockid int). Po kazdem uspesnem prikazu zapise novou verzi a commitne.
    Vola se z konstruktoru, pokud dbversion_file existuje. Neznamy driver -> die.

    Proti soubezne migraci z vice procesu se chrani dvema zamky:

    1. Zamek spojeni (sessionLock ovladace nad spojenim pool 0: MySQL/MariaDB GET_LOCK, PostgreSQL
       pg_try_advisory_lock). Server ho uvolni sam, kdyz spojeni zanikne - po padu procesu
       (SIGKILL, OOM, vymena podu) proto zadny zamek nezustane viset. Metoda ho ziska jako prvni:
       dokud ho drzi jiny proces, ceka (zaloguje to poprve na urovni info a pak kazdych cca 30 s
       na urovni error) a kontroluje stopRequested(). Kdyz behem cekani zjisti, ze pro tento
       proces neni co migrovat (verze v tabulce >= nejvyssi cislo v souboru), neceka a vrati se -
       s vyjimkou procesu, ktery cte mapu DAO z databaze (dao zapnute, daomap_file neexistuje):
       ten pocka na konec cizi migrace, aby strukturu tabulek necetl z rozpracovaneho schematu.
       Vypnuti: conf dbi.<dbid>.dbversion_session_lock => 0 (vychozi zapnuto). PostgreSQL za
       poolerem v rezimu transaction pooling (PgBouncer pool_mode = transaction) zamek spojeni
       spolehlive drzet neumi - tam ho vypni u vsech procesu; ovladac takovy stav pozna jen jako
       pojistku (sessionLock vrati undef a plati rezim bez zamku spojeni).
    2. Sloupec dbversion.lockid (nahodne cislo procesu, 0 = odemceno) - zapisuje se a uvolnuje
       jako driv kvuli starsim verzim enginu, ktere zamek spojeni neznaji (ty na nej pockaji).
       Zapisuje se jen tehdy, kdyz je co migrovat nebo co uklidit. Znamenko cisla rika, jak je
       jeho majitel chranen: proces, ktery drzi zamek spojeni, zapisuje ZAPORNE cislo; proces
       bez zamku spojeni (starsi verze enginu, dbversion_session_lock => 0, ovladac bez
       podpory) KLADNE jako driv. Starsi verze enginu porovnavaji jen "nenulovy a neni muj",
       zaporne cislo pro ne znamena totez co kladne.

    Pod zamkem spojeni metoda:
    - overi a pripadne zalozi tabulku dbversion (dva soucasne startujici procesy ji nezalozi
      dvakrat). Radek do tabulky bez radku (prave zalozene, nebo po padu mezi CREATE TABLE
      a INSERT) doplni az tehdy, kdyz je bez radku i po jednom dalsim cteni (cca 1 s): radek
      muze soucasne vkladat starsi verze enginu, ktera zamek spojeni nezna, a v tabulce by
      zustaly dva. Prvni start nad cistou databazi proto trva o cca 1 s dele. Kdyz CREATE
      TABLE selze, ale tabulku lze precist (PostgreSQL: tabulka lezi v jinem schematu podle
      search_path, nez je conf schema), pouzije ji a zaloguje to na urovni error,
    - cizi ZAPORNY lockid (a lockid NULL) povazuje za pozustatek po procesu, ktery skoncil
      uprostred migrace (zivy majitel by drzel zamek spojeni, ktery ted drzime my): prevezme ho
      hned a zaloguje to na urovni error, protoze posledni krok migrace mohl zustat nedokonceny,
    - cizi KLADNY lockid patri procesu bez zamku spojeni, ktery muze zit a migrovat (typicky
      starsi verze enginu behem postupne vymeny). Kdyz pro tento proces neni co migrovat a mapu
      DAO necte z databaze, neceka a zamku se nedotkne. Jinak ceka, dokud migrace postupuje
      (proces, ktery jen cte mapu DAO z databaze, opusteny zamek po uplynuti doby prevezme
      a hned uvolni): sleduje dvojici (dbversion,
      lockid) a zamek prevezme, az kdyz se dvojice nezmenila po dobu conf
      dbi.<dbid>.dbversion_legacy_lock_wait sekund (vychozi 300; 0 = neprevzit nikdy a cekat,
      dokud zamek nekdo neuvolni). Prevzeti je podminene obema hodnotami (UPDATE ... WHERE
      lockid = ? AND dbversion = ?) a loguje se na urovni error; cekani se loguje poprve a pak
      kazdych cca 30 s (info, pri hodnote 0 error s radou, jak zamek uvolnit rucne). Krok, ktery
      starsi verzi enginu trva dele nez nastavena doba, se od opusteneho zamku rozlisit neda -
      doba proto musi byt delsi nez nejdelsi krok migrace,
    - selze-li po prevzeti zamku hned prvni krok, hlaska chyby na to upozorni (DDL
      v MySQL/MariaDB neni transakcni, krok mohl byt castecne proveden).

    Bez zamku spojeni (vypnuty, ovladac ho nepodporuje nebo vrati chybu) se metoda chova jako
    drivejsi verze: tabulku zalozi bez zamku a na cizi lockid (kladny i zaporny) ceka v cyklu
    po 1 s. Hlasku "Dbversion is locked by lockid:N" s radou, jak zamek rucne uvolnit (UPDATE
    dbversion SET lockid = 0), loguje na urovni error poprve a pak kazdych cca 30 s; kontroluje
    stopRequested().

    Preruseni startu: pred kazdym krokem migrace kontroluje stopRequested(). Rozbehnuty krok se
    vzdy dokonci a zapise (verze + commit), dalsi se uz nespusti.

    Zamky (lockid i zamek spojeni) se uvolni na vsech cestach ven. Kdyz zamek spojeni nejde
    uvolnit dotazem, spojeni pool 0 se zavre (zamek pak uvolni server) a pri uspesnem startu
    znovu otevre. Metoda die:
    - "Dbversion fail id:N : <chyba> ..." pri chybe SQL kroku (transakce se vrati rollbackem)
      a take tehdy, kdyz se po provedenem kroku nepodari zapsat jeho verzi,
    - "Startup interrupted by termination request" po zadosti o ukonceni,
    - "Dbversion: ..." kdyz nejde nacist soubor migraci, precist nebo zalozit tabulku dbversion,
      zapsat zamek lockid nebo znovu otevrit spojeni zavrene kvuli neuvolnenemu zamku.

=cut

sub checkDbversion {
    my ($self, $dbid, $dbconf) = @_;

    my $driver = $dbconf->{'dbdriver'};
    die "Unknown dbdriver: $driver\n" unless (($driver eq "mysql") or ($driver eq "mariadb") or ($driver eq "postgres"));

    my $file  = $dbconf->{'homepath'} . "/" . $dbconf->{'dbversion_file'};
    my $steps = do($file);
    unless (ref($steps) eq "HASH") {
        my $why = $@ || (defined($steps) ? "" : $!) || "soubor nevraci hash";
        $why =~ s/\s+$//;
        die "Dbversion: $file: $why\n";
    }

    # a) Zamek spojeni: 1 = drzime ho, 0 = drzi ho jiny proces a pro nas neni co migrovat,
    #    undef = neni k dispozici (dal chrani jen sloupec lockid jako v drivejsich verzich).
    my $session = $self->dbversionSessionLock($dbid, $dbconf, $steps);
    return if (defined($session) and !$session);

    # Cislo zamku lockid tohoto procesu (0 znamena "odemceno"). Znamenko rika, jak je proces chranen:
    # ZAPORNE zapisuje jen proces, ktery drzi zamek spojeni, KLADNE proces bez nej (stejne jako
    # starsi verze enginu). Podle znamenka ciziho zamku se pozna, zda jeho majitel muze jeste zit.
    my $mylockid = 1 + int(rand(999999998));
    $mylockid = -$mylockid if ($session);

    my $state = {'wrote' => 0, 'taken' => 0, 'done' => 0, 'empty' => 0, 'created' => 0};    # viz dbversionMigrate

    my $ok  = eval { $self->dbversionMigrate($dbid, $dbconf, $steps, $mylockid, $session, $state); 1; };
    my $err = ($ok ? undef : ($@ || "Dbversion: neznama chyba\n"));

    # g) Uklid na vsech cestach ven (i pri die): nejdriv sloupec lockid, potom zamek spojeni.
    #    Chyba uklidu nesmi prekryt puvodni chybu, proto jen do logu.
    {
        local $@;
        eval {

            # Zadost o ukonceni prichazi jen mezi kroky - tam zadna transakce kroku otevrena neni.
            $self->rollback($dbid) if (defined($err) and ($err ne $STOP_MESSAGE));
            if ($state->{'wrote'}) {
                $self->update($dbid, "dbversion SET lockid = ? WHERE lockid = ?", [0, $mylockid]);
                $self->commit($dbid);
            }
            1;
        } or $LOG->error("Dbversion: uvolneni zamku lockid:$mylockid (dbid:$dbid) selhalo: $@");

        if ($session) {
            my $DBC      = $self->DBC->{$dbid}->{'0'};
            my $unlocked = eval { $DBC->sessionUnlock($DBVERSION_LOCK) };

            # Zamek se nepodarilo uvolnit dotazem. Bezici proces by ho drzel po celou dobu sveho
            # zivota a starty ostatnich procesu by na nej cekaly - proto spojeni pool 0 zavreme
            # (se zanikem spojeni zamek uvolni server) a pri uspesnem startu ho otevreme znovu.
            unless ($unlocked) {
                # Za poolerem v rezimu transaction pooling zavreni klientskeho spojeni zamek neuvolni.
                my $hint = (($dbconf->{'dbdriver'} eq "postgres") ? ". Je-li databaze za poolerem v rezimu transaction pooling (PgBouncer), zamek zustava na serverovem spojeni poolu, dokud ho pooler nezavre, a dalsi starty na nej cekaji - nastav dbi.$dbid.dbversion_session_lock => 0" : "");
                $LOG->error("Dbversion: zamek spojeni (dbid:$dbid) se nepodarilo uvolnit dotazem" . ($@ ? " ($@)" : "") . " - spojeni pool 0 se zavira, zamek uvolni server$hint");
                if (defined($err)) {
                    eval { $DBC->disconnect() };
                } elsif (!eval { $DBC->reconnect() }) {
                    $err = "Dbversion: spojeni pool 0 (dbid:$dbid) se po uvolneni zamku migrace nepodarilo znovu pripojit\n";
                }
            }
        }
    }

    if (defined($err)) {
        $LOG->info("Dbversion: migrace dbid:$dbid prerusena zadosti o ukonceni (dokoncene kroky: $state->{'done'}), zamky uvolneny") if ($err eq $STOP_MESSAGE);
        die $err;
    }
}

=head2 B<[Private] dbversionSessionLock($dbid,$dbconf,$steps)>

    Ziska pro checkDbversion zamek spojeni (sessionLock ovladace nad spojenim pool 0, logicke
    jmeno "dbversion"). Vraci:
    1     - zamek drzime (uvolnuje ho checkDbversion pres sessionUnlock),
    0     - zamek drzi jiny proces, pro tento proces neni co migrovat (dbversionPending) a mapu
            DAO z databaze necte (dbversionDaoFromDb),
    undef - zamek spojeni neni k dispozici: je vypnuty (conf dbversion_session_lock => 0),
            ovladac metody sessionLock/sessionUnlock nema, nebo sessionLock vratil undef (chybu
            zaloguje na urovni error).
    Dokud zamek drzi jiny proces a je co migrovat (nebo proces cte mapu DAO z databaze), ceka:
    sessionLock vola s casem DBVERSION_POLL (1 s), poprve a pak kazdych DBVERSION_LOG_INTERVAL
    (30) s zaloguje, ze migraci provadi jiny proces - poprve na urovni info, opakovane na urovni
    error (dlouhe cekani musi byt videt i pri urovni logu 1). Pred kazdym pokusem kontroluje
    stopRequested() a po zadosti o ukonceni konci pres die "Startup interrupted by termination
    request\n". Pri vypnutem autocommitu po ziskani zamku vzdy ukonci transakci, ve ktere se
    o zamek zadalo (rollback; zamek spojeni tim neuvolni): cteni pod zamkem vidi aktualni stav
    i pri izolaci REPEATABLE READ - i kdyz se na zamek cekalo jen uvnitr prvniho volani sessionLock.

=cut

sub dbversionSessionLock {
    my ($self, $dbid, $dbconf, $steps) = @_;

    if (defined($dbconf->{'dbversion_session_lock'}) and !$dbconf->{'dbversion_session_lock'}) {
        $LOG->debug("Dbversion: zamek spojeni je vypnuty (dbi.$dbid.dbversion_session_lock => 0)");
        return undef;
    }

    my $DBC = $self->DBC->{$dbid}->{'0'};
    unless ($DBC->can('sessionLock') and $DBC->can('sessionUnlock')) {
        $LOG->debug("Dbversion: ovladac dbid:$dbid zamek spojeni nepodporuje");
        return undef;
    }

    my ($start, $logged) = (time(), undef);

    while (1) {
        die $STOP_MESSAGE if (stopRequested());

        my $got = $DBC->sessionLock($DBVERSION_LOCK, $DBVERSION_POLL);
        if ($got) {

            # Pri vypnutem autocommitu ukoncime transakci, ve ktere se o zamek zadalo - vzdy, i kdyz
            # se zamek ziskal hned prvnim volanim: transakce zacala uz prvnim pokusem o zamek (ovladac
            # PostgreSQL ho uvnitr jednoho volani zkousi az DBVERSION_POLL sekund) a pri izolaci
            # REPEATABLE READ by cteni tabulky dbversion i zapis zamku lockid videly stav z jejiho
            # zacatku, ne stav po uvolneni zamku. Zamek spojeni rollback neuvolni.
            $self->rollback($dbid) unless ($dbconf->{'autocommit'});
            return 1;
        }

        unless (defined($got)) {
            $LOG->error("Dbversion: zamek spojeni neni k dispozici (dbid:$dbid, " . $self->getErrorMsg($dbid) . ") - soubezne migraci brani jen sloupec dbversion.lockid");
            return undef;
        }

        # Zamek drzi jiny proces, tedy prave migruje. Kdyz pro nas neni co migrovat, necekame na nej -
        # s vyjimkou procesu, ktery si po migraci nacte strukturu tabulek z databaze (mapa DAO):
        # ten pocka, aby ji necetl z rozpracovaneho schematu.
        my $pending = $self->dbversionPending($dbid, $dbconf, $steps);
        return 0 unless ($pending or $self->dbversionDaoFromDb($dbconf));

        # Prvni hlaska je bezna (info). Opakovana znamena, ze cekani trva uz DBVERSION_LOG_INTERVAL
        # sekund - musi byt videt i pri urovni logu 1 (uvazly drzitel zamku, pod bez radky v logu).
        if (!defined($logged) or ((time() - $logged) >= $DBVERSION_LOG_INTERVAL)) {
            my $first = (defined($logged) ? 0 : 1);
            $logged = time();
            my $text = "Dbversion: migraci databaze dbid:$dbid provadi jiny proces, cekam na zamek spojeni (" . ($logged - $start) . " s)";
            $text .= "; pro tento proces neni co migrovat, cekam kvuli nacteni struktury tabulek (dao)" unless ($pending);

            # PostgreSQL za poolerem v rezimu transaction pooling: zamek muze viset na serverovem
            # spojeni poolu, i kdyz zadny proces nemigruje - z logu to jinak neni poznat.
            $text .= ". Pokud zadny proces nemigruje, zamek mohl zustat na serverovem spojeni pooleru (PgBouncer, transaction pooling) a uvolni se, az ho pooler zavre - nastav dbi.$dbid.dbversion_session_lock => 0" if (!$first and ($dbconf->{'dbdriver'} eq "postgres"));
            if ($first) { $LOG->info($text); }
            else        { $LOG->error($text); }
        }
    }
}

=head2 B<[Private] dbversionDaoFromDb($dbconf)>

    Vraci 1, pokud si konstruktor po migraci nacte strukturu tabulek (mapu DAO) primo z databaze:
    conf dao je zapnute a soubor daomap_file neexistuje. Jinak 0 (DAO vypnute, nebo se mapa cte
    ze souboru). Proces, ktery mapu cte z databaze, ceka na dokonceni cizi migrace i tehdy, kdyz
    sam nema co migrovat - jinak by si nacetl schema rozpracovane vicekrokove migrace a zustal
    s nim do restartu (dbversionSessionLock).

=cut

sub dbversionDaoFromDb {
    my ($self, $dbconf) = @_;

    return 0 unless ($dbconf->{'dao'});
    return 1 unless (defined($dbconf->{'daomap_file'}) and length($dbconf->{'daomap_file'}));

    # stejna cesta jako v konstruktoru (homepath = pwe.home, konci lomitkem)
    return ((-f $dbconf->{'homepath'} . $dbconf->{'daomap_file'}) ? 0 : 1);
}

=head2 B<[Private] dbversionMigrate($dbid,$dbconf,$steps,$mylockid,$session,$state)>

    Vlastni migrace pro checkDbversion: zalozi tabulku dbversion, ziska zamek lockid a provede
    kroky z hashe $steps s cislem vyssim nez ulozena verze. $mylockid je cislo zamku tohoto
    procesu (zaporne, kdyz proces drzi zamek spojeni, jinak kladne), $session rika, zda proces
    drzi zamek spojeni (1), nebo ne (undef). Do hashe $state zapisuje, co je treba vedet pri
    uklidu: wrote = zapsali jsme do sloupce lockid sve cislo (checkDbversion ho pak uvolni),
    taken = prevzali jsme opusteny zamek, done = pocet dokoncenych kroku, empty = kolikrat jsme
    pod zamkem spojeni videli tabulku bez radku, created = tabulku jsme zalozili sami. Zamky
    neuvolnuje a pri chybe die - uklid dela checkDbversion.

    Cizi zamek lockid pod zamkem spojeni: zaporny (a NULL) prevezme hned, na kladny ceka pres
    dbversionLegacyWait a prevezme ho az po dobe dbversion_legacy_lock_wait beze zmeny (viz
    checkDbversion). Bez zamku spojeni na cizi zamek jen ceka.

=cut

sub dbversionMigrate {
    my ($self, $dbid, $dbconf, $steps, $mylockid, $session, $state) = @_;

    # b) Tabulka dbversion. Se zamkem spojeni ji v tuto chvili nemuze zakladat jiny proces;
    #    bez nej zustava puvodni chovani (soubezny start ji muze zalozit dvakrat).
    unless ($self->dbversionTableExists($dbid, $dbconf)) {
        $self->command($dbid, "CREATE TABLE dbversion (dbversion int, lockid int)");
        if ($session and $self->error($dbid)) {

            # Tabulka muze existovat jinde, nez kde ji hleda dbversionTableExists (PostgreSQL: jine
            # schema podle search_path, nez je conf 'schema'). Kdyz jde precist, pokracujeme s ni
            # jako drivejsi verze; chybou konci jen tabulka, ktera neexistuje a nejde zalozit.
            my $why = $self->getErrorMsg($dbid);
            $self->rollback($dbid);
            $self->dbversionRead($dbid);
            if ($self->error($dbid)) {
                $self->rollback($dbid);
                die "Dbversion: tabulku dbversion nelze zalozit: $why\n";
            }

            # Kontrola existence ji ted vidi: tabulku mezitim zalozil proces bez zamku spojeni (starsi
            # verze enginu pri soubeznem startu nad cistou databazi) - bezny soubeh, ne chyba konfigurace.
            if ($self->dbversionTableExists($dbid, $dbconf)) {
                $LOG->info("Dbversion: tabulku dbversion (dbid:$dbid) mezitim zalozil jiny proces (zrejme starsi verze enginu bez zamku spojeni) - pouzivam ji; CREATE TABLE selhal: $why");
            } else {
                $LOG->error("Dbversion: tabulka dbversion (dbid:$dbid) existuje, ale ne tam, kde ji hleda kontrola existence (conf dbi.$dbid.schema/database) - pouzivam ji; CREATE TABLE selhal: $why");
            }
        } elsif ($session) {

            # Tabulku jsme zalozili my. Radek do ni hned nevkladame: starsi verze enginu (bez zamku
            # spojeni), ktera existenci tabulky overila jeste pred nasim CREATE TABLE, chybu sveho
            # CREATE TABLE ignoruje a radek (0,0) vlozi sama - s nasim radkem by v tabulce byly dva.
            # Radek doplni smycka nize stejne jako u tabulky nalezene bez radku: az kdyz v ni neni
            # ani po jednom dalsim cteni (viz c2).
            $self->commit($dbid);
            $state->{'created'} = 1;
        } else {
            $self->insert($dbid, "INTO dbversion (dbversion,lockid) VALUES(?,?)", [0, 0]);
            $self->commit($dbid);
        }
    }

    my ($tries, $start, $logged) = (0, time(), undef);
    my $watch = {};    # sledovani ciziho kladneho zamku lockid (viz dbversionLegacyWait)

  WHILE: while (1) {

        my @row = $self->dbversionRead($dbid);
        die "Dbversion: tabulku dbversion nelze precist: " . $self->getErrorMsg($dbid) . "\n" if ($self->error($dbid));

        my ($dbversion, $lockid) = @row;
        my $free = ((@row and defined($lockid) and ($lockid == 0))         ? 1 : 0);
        my $mine = ((@row and defined($lockid) and ($lockid == $mylockid)) ? 1 : 0);

        # Zamek lockid ma jiny proces, nebo tabulka nema zadny radek.
        unless ($free or $mine) {

            # c1) Drzime zamek spojeni a cizi lockid je KLADNY: zapsal ho proces BEZ zamku spojeni
            #     (starsi verze enginu, dbversion_session_lock => 0, ovladac bez podpory). Ten muze
            #     zit a migrovat, i kdyz zamek spojeni drzime my - hned ho proto neprebirame.
            if ($session and @row and defined($lockid) and ($lockid > 0)) {

                # Pro tento proces neni co migrovat: zamek lockid nepotrebujeme, na cizi migraci
                # necekame a ciziho zamku se nedotkneme. Vyjimka je stejna jako u obsazeneho zamku
                # spojeni: proces, ktery si strukturu tabulek nacte z databaze (mapa DAO), ceka,
                # dokud cizi migrace postupuje - jinak by ji nacetl z rozpracovaneho schematu.
                # Opusteny zamek pak po dobe dbversion_legacy_lock_wait prevezme a hned uvolni.
                unless ((grep { $_ > $dbversion } keys %{$steps}) or $self->dbversionDaoFromDb($dbconf)) {
                    $LOG->info("Dbversion: zamek lockid:$lockid v tabulce dbversion (dbid:$dbid) nastavil proces bez zamku spojeni (zrejme starsi verze enginu); pro tento proces neni co migrovat (verze " . (defined($dbversion) ? $dbversion : "NULL") . "), necekam a zamek ponechavam");
                    last WHILE;
                }

                # Cekame, dokud migrace postupuje; 1 = dvojice (dbversion, lockid) se nezmenila po
                # celou dobu dbversion_legacy_lock_wait.
                next WHILE unless ($self->dbversionLegacyWait($dbid, $dbconf, $dbversion, $lockid, $watch));

                # Prevzeti je podminene obema hodnotami: kdyz majitel zamku mezitim dokoncil krok
                # nebo zamek uvolnil, UPDATE nic nezmeni a po dalsim cteni se casovac vynuluje.
                $self->dbversionCountTry($dbid, \$tries, $dbversion, $lockid);
                my $taken = undef;
                if (defined($dbversion)) {
                    $taken = $self->update($dbid, "dbversion SET lockid = ? WHERE lockid = ? AND dbversion = ?", [$mylockid, $lockid, $dbversion]);
                } else {
                    $taken = $self->update($dbid, "dbversion SET lockid = ? WHERE lockid = ? AND dbversion IS NULL", [$mylockid, $lockid]);
                }
                $state->{'wrote'} = 1;
                die "Dbversion: opusteny zamek migrace nelze prevzit: " . $self->getErrorMsg($dbid) . "\n" if ($self->error($dbid));
                $self->commit($dbid);
                if (defined($taken) and ($taken != 0)) {
                    $state->{'taken'} = 1;
                    $LOG->error("Dbversion: zamek lockid:$lockid v tabulce dbversion (dbid:$dbid) se " . int($watch->{'idle'}) . " s nezmenil (verze " . (defined($dbversion) ? $dbversion : "NULL") . ", dbi.$dbid.dbversion_legacy_lock_wait => $watch->{'limit'}) - proces bez zamku spojeni, ktery ho nastavil (zrejme starsi verze enginu), uz nejspis nebezi. Prebiram ho; posledni krok migrace (po verzi " . (defined($dbversion) ? $dbversion : 0) . ") mohl zustat nedokonceny.");
                }
                next WHILE;
            }

            if ($session) {

                # c2) Drzime zamek spojeni a cizi lockid je ZAPORNY (nebo NULL): jeho majitel by musel
                #     drzet zamek spojeni, ktery mame my - je to pozustatek po procesu, ktery skoncil
                #     uprostred migrace. Prazdna tabulka zbyla po procesu, ktery skoncil mezi CREATE
                #     TABLE a INSERT. Oboje opravime a pokracujeme.

                # Tabulku bez radku ale muze prave zakladat proces BEZ zamku spojeni (starsi verze
                # enginu mezi CREATE TABLE a INSERT) - soucasny INSERT by v ni nechal dva radky.
                # Poprve proto jen pockame a tabulku precteme znovu (v nove transakci, aby cteni
                # videlo aktualni stav); radek doplnime, az kdyz v ni neni ani potom.
                unless (@row or $state->{'empty'}++) {
                    die $STOP_MESSAGE if (stopRequested());
                    $self->rollback($dbid) unless ($dbconf->{'autocommit'});
                    sleep($DBVERSION_POLL) if ($DBVERSION_POLL > 0);

                    # Signal (SIGTERM) spanek prerusi: po zadosti o ukonceni radek uz nedoplnujeme.
                    die $STOP_MESSAGE if (stopRequested());
                    next WHILE;
                }

                $self->dbversionCountTry($dbid, \$tries, $dbversion, $lockid);
                if (@row) {
                    $LOG->error("Dbversion: zamek lockid:" . (defined($lockid) ? $lockid : "NULL") . " v tabulce dbversion (dbid:$dbid) je opusteny - proces, ktery ho nastavil, uz nebezi (zamek spojeni je volny). Prebiram ho; posledni krok migrace (po verzi " . (defined($dbversion) ? $dbversion : 0) . ") mohl zustat nedokonceny.");
                    if (defined($lockid)) {
                        $self->update($dbid, "dbversion SET lockid = ? WHERE lockid = ?", [$mylockid, $lockid]);
                    } else {
                        $self->update($dbid, "dbversion SET lockid = ? WHERE lockid IS NULL", [$mylockid]);
                    }
                    $state->{'wrote'} = 1;
                    $state->{'taken'} = 1;
                } else {

                    # Tabulku, kterou jsme prave zalozili sami, plnime bez hlasky error (bezny prvni start).
                    if ($state->{'created'}) {
                        $LOG->debug("Dbversion: tabulka dbversion (dbid:$dbid) zalozena, vkladam radek s verzi 0");
                    } else {
                        $LOG->error("Dbversion: tabulka dbversion (dbid:$dbid) nema zadny radek (nedokoncene zalozeni tabulky) - doplnuji radek s verzi 0");
                    }
                    $self->insert($dbid, "INTO dbversion (dbversion,lockid) VALUES(?,?)", [0, 0]);
                }
                die "Dbversion: opusteny zamek migrace nelze prevzit: " . $self->getErrorMsg($dbid) . "\n" if ($self->error($dbid));
                $self->commit($dbid);
                next WHILE;
            }

            # e) Bez zamku spojeni nejde poznat, jestli proces se zamkem lockid jeste bezi: cekame
            #    jako drivejsi verze, jen s hlaskou jednou za DBVERSION_LOG_INTERVAL sekund.
            die $STOP_MESSAGE if (stopRequested());
            if (!defined($logged) or ((time() - $logged) >= $DBVERSION_LOG_INTERVAL)) {
                $logged = time();
                my $waited = $logged - $start;
                if (@row) {
                    $LOG->error("Dbversion is locked by lockid:" . (defined($lockid) ? $lockid : "NULL") . " (dbid:$dbid) - migraci provadi jiny proces, cekam ($waited s). Pokud zadny proces nemigruje (zamek zustal po padu procesu), uvolni ho rucne: UPDATE dbversion SET lockid = 0");
                } else {
                    $LOG->error("Dbversion: tabulka dbversion (dbid:$dbid) nema zadny radek - zrejme ji prave zaklada jiny proces, cekam ($waited s). Pokud zadny jiny proces nestartuje, dopln radek rucne: INSERT INTO dbversion (dbversion,lockid) VALUES (0,0)");
                }
            }
            sleep($DBVERSION_POLL) if ($DBVERSION_POLL > 0);
            next WHILE;
        }

        # Zamek je volny nebo nas: sledovani ciziho kladneho zamku konci (pristi cizi zamek se meri znovu).
        delete($watch->{'pair'});

        # PROCHAZIME DBVERSION OD NEJNIZSSI VERZE, SPOUSTIME JEN KROKY S CISLEM VYSSIM NEZ V DATABAZI
        my @todo = grep { $_ > $dbversion } sort { $a <=> $b } keys %{$steps};

        # Nic k migraci: do sloupce lockid se vubec nezapisuje.
        last WHILE unless (@todo);

        # f) Zadost o ukonceni se vyrizuje jen na bezpecnych mistech: pred zapisem zamku lockid
        #    a pred kazdym krokem. Rozbehnuty krok se vzdy dokonci a zapise.
        die $STOP_MESSAGE if (stopRequested());

        # d) AKTUALIZACE NENI ZAMCENA JINYM PROCESEM, NASTAVIME ZAMEK A V DALSIM PRUCHODU OVERIME,
        #    ZE JE NAS - MUZE NAS PREDBEHNOUT PROCES SPUSTENY PARALELNE (starsi verze enginu nebo
        #    proces bez zamku spojeni).
        if ($free) {
            $self->dbversionCountTry($dbid, \$tries, $dbversion, $lockid);
            $self->update($dbid, "dbversion SET lockid = ? WHERE lockid = ?", [$mylockid, 0]);
            $state->{'wrote'} = 1;
            die "Dbversion: zamek lockid nelze nastavit: " . $self->getErrorMsg($dbid) . "\n" if ($self->error($dbid));
            $self->commit($dbid);
            next WHILE;
        }

        # PROVEDEME AKTUALIZACI DATABAZE
        foreach my $id (@todo) {

            # f) Mezi kroky: predchozi krok je dokonceny a zapsany, dalsi se uz nespusti.
            die $STOP_MESSAGE if (stopRequested());

            my $cmd = $steps->{$id};
            $self->command($dbid, $cmd);
            if ($self->error($dbid)) {
                my $errormsg = $self->getErrorMsg($dbid);
                $LOG->error($cmd);

                # h) Prvni krok po prevzeti opusteneho zamku: predchozi proces ho mohl zacit provadet.
                my $hint = "";
                if ($state->{'taken'} and !$state->{'done'}) {
                    $hint = "Dbversion: zamek migrace byl prevzat po procesu, ktery skoncil uprostred migrace - krok $id mohl byt uz driv castecne proveden (DDL v MySQL/MariaDB neni transakcni). Zkontroluj schema databaze rucne; je-li krok hotovy, zapis ho: UPDATE dbversion SET dbversion = $id";
                    $LOG->error($hint);
                }
                die "Dbversion fail id:$id : $errormsg \n $cmd\n" . (length($hint) ? "$hint\n" : "");
            }

            # Krok probehl: zapiseme verzi. Kdyz se to nepodari, nesmi se pokracovat dalsim krokem -
            # v PostgreSQL by se tento krok vratil s transakci a dalsi kroky by ho preskocily.
            $LOG->info("Dbversion update to id $id");
            $self->update($dbid, "dbversion SET dbversion = ?", [$id]);
            $self->commit($dbid) unless ($self->error($dbid));
            if ($self->error($dbid)) {
                die "Dbversion fail id:$id : krok probehl, ale jeho verzi se nepodarilo zapsat do tabulky dbversion: " . $self->getErrorMsg($dbid) . "\nV MySQL/MariaDB zustal krok proveden (DDL neni transakcni) - zkontroluj schema a zapis verzi rucne: UPDATE dbversion SET dbversion = $id; v PostgreSQL se krok vratil spolu s transakci.\n";
            }
            $state->{'done'}++;
        }
        last WHILE;
    }
}

=head2 B<[Private] dbversionCountTry($dbid,$tries,$dbversion,$lockid)>

    Pojistka proti nekonecne smycce v dbversionMigrate: zvysi pocitadlo zapisu zamku lockid
    ($tries je reference na cislo) a po prekroceni DBVERSION_MAX_TRIES (20) die s popisem stavu
    tabulky dbversion. Za normalnich okolnosti se zamek zapisuje jednou az dvakrat; opakovane
    zapisy bez vysledku znamenaji, ze tabulka je v necekanem stavu (napr. vice radku s ruznym
    lockid) nebo ze zapis tise selhava.

=cut

sub dbversionCountTry {
    my ($self, $dbid, $tries, $dbversion, $lockid) = @_;

    ${$tries}++;
    return if (${$tries} <= $DBVERSION_MAX_TRIES);

    die "Dbversion: zamek lockid se nepodarilo ziskat ani na $DBVERSION_MAX_TRIES pokusu (dbid:$dbid, dbversion:" . (defined($dbversion) ? $dbversion : "NULL") . ", lockid:" . (defined($lockid) ? $lockid : "NULL") . ") - zkontroluj obsah tabulky dbversion (ma mit jeden radek)\n";
}

=head2 B<[Private] dbversionLegacyWait($dbid,$dbconf,$dbversion,$lockid,$watch)>

    Cekani procesu, ktery drzi zamek spojeni, na cizi KLADNY lockid - zamek procesu bez zamku
    spojeni (starsi verze enginu, dbversion_session_lock => 0), ktery muze zit a migrovat.
    Vola se z dbversionMigrate po kazdem cteni tabulky dbversion s prave prectenou dvojici
    ($dbversion, $lockid); stav mezi volanimi drzi hash $watch (pair = sledovana dvojice,
    since = cas jeji posledni zmeny, idle = jak dlouho se nemeni, limit = doba z konfigurace,
    start a logged = pro hlasky). Vraci:
    1 - dvojice se nezmenila po dobu dbversion_legacy_lock_wait sekund, zamek lze prevzit,
    0 - cekalo se (jedno DBVERSION_POLL), volajici ma tabulku precist znovu.
    Zmena dvojice (majitel dokoncil krok, zamek ziskal jiny proces) casovac vynuluje. S dobou 0
    nevraci 1 nikdy. Cas meri dbversionNow (monotonni hodiny - posun systemoveho casu zamek
    predcasne neprevezme). Poprve a pak kazdych DBVERSION_LOG_INTERVAL (30) s zaloguje, na co
    ceka a za jak dlouho zamek prevezme (info - cekani je omezene dobou a konci zaznamem error
    o prevzeti; s dobou 0 error s radou, jak zamek uvolnit rucne).
    Pri kazdem volani kontroluje stopRequested() a po zadosti o ukonceni konci pres
    die "Startup interrupted by termination request\n" (nic neprebira). Pri vypnutem autocommitu
    (conf autocommit) po kazdem cteni ukonci transakci rollbackem: cekani nedrzi otevrenou
    transakci a dalsi cteni vidi aktualni stav i pri izolaci REPEATABLE READ.

=cut

sub dbversionLegacyWait {
    my ($self, $dbid, $dbconf, $dbversion, $lockid, $watch) = @_;

    # Zadost o ukonceni: uz necekame ani neprebirame (zamky uvolni checkDbversion).
    die $STOP_MESSAGE if (stopRequested());

    # Pri vypnutem autocommitu ukoncime transakci, ve ktere se tabulka dbversion prave cetla (zadny
    # nas nepotvrzeny zapis v ni neni): cekani nedrzi otevrenou transakci a dalsi cteni i podminene
    # prevzeti vidi aktualni stav tabulky i pri izolaci REPEATABLE READ (PostgreSQL) - jinak by
    # proces postup cizi migrace nevidel. Zamek spojeni rollback neuvolni.
    $self->rollback($dbid) unless ($dbconf->{'autocommit'});

    $watch->{'limit'} = $self->dbversionLegacyLimit($dbid, $dbconf) unless (defined($watch->{'limit'}));

    my $limit = $watch->{'limit'};
    my $now   = $self->dbversionNow();
    my $pair  = (defined($dbversion) ? $dbversion : "NULL") . "/" . $lockid;

    $watch->{'start'} = $now unless (defined($watch->{'start'}));

    # Zmena dvojice = majitel zamku zije (dokoncil krok), nebo zamek ziskal jiny proces: merime znovu.
    if (!defined($watch->{'pair'}) or ($watch->{'pair'} ne $pair)) {
        $watch->{'pair'}  = $pair;
        $watch->{'since'} = $now;
    }

    $watch->{'idle'} = $now - $watch->{'since'};
    return 1 if (($limit > 0) and ($watch->{'idle'} >= $limit));

    if (!defined($watch->{'logged'}) or (($now - $watch->{'logged'}) >= $DBVERSION_LOG_INTERVAL)) {
        $watch->{'logged'} = $now;
        my $text = "Dbversion: zamek lockid:$lockid v tabulce dbversion (dbid:$dbid) nastavil proces bez zamku spojeni - migraci zrejme provadi starsi verze enginu (nebo proces s dbversion_session_lock => 0). Cekam, dokud migrace postupuje (verze " . (defined($dbversion) ? $dbversion : "NULL") . ", cekam " . int($now - $watch->{'start'}) . " s)";
        if ($limit > 0) {
            my $left = $limit - $watch->{'idle'};
            $left = ((int($left) < $left) ? int($left) + 1 : int($left));
            $LOG->info("$text; kdyz se verze ani zamek nezmeni, prevezmu ho za $left s (dbi.$dbid.dbversion_legacy_lock_wait => $limit)");
        } else {

            # Cekani bez konce musi byt videt i pri urovni logu 1 (stejne jako v rezimu bez zamku spojeni).
            $LOG->error("$text; zamek se neprebira (dbi.$dbid.dbversion_legacy_lock_wait => 0). Pokud zadny proces nemigruje (zamek zustal po padu procesu), uvolni ho rucne: UPDATE dbversion SET lockid = 0");
        }
    }

    sleep($DBVERSION_POLL) if ($DBVERSION_POLL > 0);

    return 0;
}

=head2 B<[Private] dbversionLegacyLimit($dbid,$dbconf)>

    Vraci dobu v sekundach, po ktere se prevezme cizi kladny zamek lockid, kdyz se tabulka
    dbversion nemeni: conf dbi.<dbid>.dbversion_legacy_lock_wait (nezaporne cislo, 0 = neprevzit
    nikdy), bez nej DBVERSION_LEGACY_WAIT (300). Neplatnou hodnotu zaloguje na urovni error
    a pouzije vychozi - preklep v konfiguraci nesmi znamenat okamzite prevzeti zamku.

=cut

sub dbversionLegacyLimit {
    my ($self, $dbid, $dbconf) = @_;

    my $value = $dbconf->{'dbversion_legacy_lock_wait'};
    return $DBVERSION_LEGACY_WAIT unless (defined($value));
    return $value + 0 if ($value =~ /^\d+(?:\.\d+)?$/);

    $LOG->error("Dbversion: dbi.$dbid.dbversion_legacy_lock_wait => '$value' neni nezaporne cislo (sekundy, 0 = zamek neprebirat), pouzivam vychozi $DBVERSION_LEGACY_WAIT");

    return $DBVERSION_LEGACY_WAIT;
}

=head2 B<[Private] dbversionNow()>

    Vraci cas v sekundach pro mereni doby v dbversionLegacyWait: monotonni hodiny procesu
    (Time::HiRes, CLOCK_MONOTONIC), ktere neovlivni posun systemoveho casu (NTP, rucni zmena) -
    skok hodin dopredu by jinak prevzal zamek ziveho procesu. Kde monotonni hodiny nejsou, vraci
    time(). Testy cas podstrkuji pres promennou DBVERSION_CLOCK (odkaz na funkci).

=cut

sub dbversionNow {
    return $DBVERSION_CLOCK->() if (ref($DBVERSION_CLOCK) eq "CODE");

    unless (defined($DBVERSION_MONOTONIC)) {
        local $@;
        $DBVERSION_MONOTONIC = (eval { require Time::HiRes; Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()); 1; } ? 1 : 0);
    }

    return ($DBVERSION_MONOTONIC ? Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) : time());
}

=head2 B<[Private] dbversionTableExists($dbid,$dbconf)>

    Vraci 1, pokud v databazi existuje tabulka dbversion, jinak 0. Zjistuje to z information_schema
    (u MySQL/MariaDB podle 'database', u Postgres podle 'schema', vychozi "public") - DAO v tu
    chvili jeste pouzit nejde, Libs::MyDBI se zaklada pred nim.

=cut

sub dbversionTableExists {
    my ($self, $dbid, $dbconf) = @_;

    my $SQL = undef;

    if ($dbconf->{'dbdriver'} eq "postgres") {
        $SQL = $self->select($dbid, "1 FROM information_schema.tables WHERE table_name = ? AND table_schema = ?", ["dbversion", (defined($dbconf->{'schema'}) ? $dbconf->{'schema'} : "public")]);
    } else {
        $SQL = $self->select($dbid, "1 FROM information_schema.tables WHERE table_name = ? AND table_schema = ? LIMIT 1", ["dbversion", $dbconf->{'database'}]);
    }

    my @row = $SQL->fetchrow_array();
    $SQL->finish();

    return (@row ? 1 : 0);
}

=head2 B<[Private] dbversionRead($dbid)>

    Precte radek tabulky dbversion a vrati seznam (dbversion, lockid); prazdny seznam, kdyz
    tabulka zadny radek nema nebo dotaz selhal (chybu lze overit pres error($dbid)).

=cut

sub dbversionRead {
    my ($self, $dbid) = @_;

    my $SQL = $self->select($dbid, "dbversion,lockid FROM dbversion", []);
    my @row = $SQL->fetchrow_array();
    $SQL->finish();

    return @row;
}

=head2 B<[Private] dbversionPending($dbid,$dbconf,$steps)>

    Vraci 1, pokud ma tento proces co migrovat: tabulka dbversion neexistuje, nema radek, nejde
    precist, nebo hash $steps obsahuje krok s cislem vyssim nez ulozena verze. Jinak 0. Jen cte,
    zadny zamek nepotrebuje - dbversionSessionLock podle ni rozhoduje, zda ma na migraci jineho
    procesu cekat. Po chybe cteni vrati transakci rollbackem (PostgreSQL by jinak dalsi prikazy
    odmital).

=cut

sub dbversionPending {
    my ($self, $dbid, $dbconf, $steps) = @_;

    return 1 unless ($self->dbversionTableExists($dbid, $dbconf));

    my @row = $self->dbversionRead($dbid);
    if ($self->error($dbid)) {
        $self->rollback($dbid);
        return 1;
    }
    return 1 unless (@row);

    foreach my $id (keys %{$steps}) {
        return 1 if ($id > $row[0]);
    }

    return 0;
}

=head2 B<[Public] select($dbid,$select,$value)>

    Provede SELECT nad spojenim pool 0 databaze $dbid. $select je dotaz BEZ uvodniho slova SELECT
    (doplni ho driver), $value je reference na pole bind hodnot (povinna, bez hodnot []).
    Pred dotaz vlozi SQL komentar /* DB:$dbid soubor line N */ s mistem volani. Vraci DBI statement
    handle, ze ktereho si volajici data vybere (fetchrow_array/fetchrow_hashref) a zavola finish.
    Uspech loguje na debug, chybu na error vcetne getErrorMsg; chybu lze overit pres error($dbid).

        my $SQL = $DBI->select("db1", "uid, fullname FROM users WHERE uid = ?", [$uid]);
        my ($id, $name) = $SQL->fetchrow_array();
        $SQL->finish();

=cut

sub select {
    my ($self, $dbid, $select, $value) = @_;
    my $line = sprintf("%s line %d", (caller)[1, 2]);
    $select = "/* DB:$dbid $line */ " . $select if ($LOG->getLogLevel() >= 3);    # komentar jen pri info/debug (cache dotazu)
    $LOG->delay("selectdb");
    my $SQL = $self->DBC->{$dbid}->{'0'}->select($select, $value);
    $select =~ s/\n/ /g;
    $LOG->debug("SELECT $select,[" . join(',', @{$value}) . "]") if (!$self->error($dbid));
    $LOG->error("SELECT $select,[" . join(',', @{$value}) . "]") if ($self->error($dbid));
    $LOG->error($self->getErrorMsg($dbid)) if ($self->error($dbid));
    $LOG->delay("selectdb", "SELECT $select");
    return $SQL;
}

=head2 B<[Public] insert($dbid,$insert,$value)>

    Provede INSERT nad zapisovym spojenim pool 0 databaze $dbid. $insert je cast prikazu za slovem
    INSERT (napr. "INTO users (fullname) VALUES (?)"), $value je reference na pole bind hodnot.
    Pred prikaz vlozi SQL komentar s mistem volani. Nic nevraci; chybu overte pres error($dbid),
    nove id ziskejte pres getLastInsertID($dbid,$table) jeste PRED commit($dbid).
    Uspech loguje na info, chybu na error.

=cut

sub insert {
    my ($self, $dbid, $insert, $value) = @_;
    my $line = sprintf("%s line %d", (caller)[1, 2]);
    $insert = " /* DB:$dbid $line */ " . $insert if ($LOG->getLogLevel() >= 3);    # komentar jen pri info/debug (cache dotazu)
    $LOG->delay("insertdb");
    $self->DBC->{$dbid}->{'0'}->insert($insert, $value);
    $insert =~ s/\n/ /g;
    $LOG->info("INSERT $insert,[" . join(',', @{$value}) . "]") if (!$self->error($dbid));
    $LOG->error("INSERT $insert,[" . join(',', @{$value}) . "]") if ($self->error($dbid));
    $LOG->error($self->getErrorMsg($dbid)) if ($self->error($dbid));
    $LOG->delay("insertdb", "INSERT $insert");
}

=head2 B<[Public] update($dbid,$update,$value)>

    Provede UPDATE nad zapisovym spojenim pool 0 databaze $dbid. $update je cast prikazu za slovem
    UPDATE (napr. "users SET fullname = ? WHERE uid = ?"), $value je reference na pole bind hodnot.
    Pred prikaz vlozi SQL komentar s mistem volani. Vraci pocet ovlivnenych radku tak, jak ho vrati
    DBI execute ("0E0" pri nule, undef pri chybe). Zmenu je treba potvrdit pres commit($dbid).

=cut

sub update {
    my ($self, $dbid, $update, $value) = @_;
    my $line = sprintf("%s line %d", (caller)[1, 2]);
    $update = " /* DB:$dbid $line */ " . $update if ($LOG->getLogLevel() >= 3);    # komentar jen pri info/debug (cache dotazu)
    $LOG->delay("updatedb");
    my $count = $self->DBC->{$dbid}->{'0'}->update($update, $value);
    $update =~ s/\n/ /g;
    $LOG->info("UPDATE $update,[" . join(',', @{$value}) . "]") if (!$self->error($dbid));
    $LOG->error("UPDATE $update,[" . join(',', @{$value}) . "]") if ($self->error($dbid));
    $LOG->error($self->getErrorMsg($dbid)) if ($self->error($dbid));
    $LOG->delay("updatedb", "UPDATE $update");
    return $count;
}

=head2 B<[Public] delete($dbid,$remove,$value)>

    Provede DELETE nad zapisovym spojenim pool 0 databaze $dbid. $remove je cast prikazu za slovem
    DELETE (napr. "FROM users WHERE uid = ?"), $value je reference na pole bind hodnot. Pred prikaz
    vlozi SQL komentar s mistem volani. Nic nevraci; chybu overte pres error($dbid), zmenu potvrdte
    pres commit($dbid).

=cut

sub delete {
    my ($self, $dbid, $remove, $value) = @_;
    my $line = sprintf("%s line %d", (caller)[1, 2]);
    $remove = "/* DB:$dbid $line */ " . $remove if ($LOG->getLogLevel() >= 3);    # komentar jen pri info/debug (cache dotazu)
    $LOG->delay("deletedb");
    $self->DBC->{$dbid}->{'0'}->delete($remove, $value);
    $remove =~ s/\n/ /g;
    $LOG->info("DELETE $remove,[" . join(',', @{$value}) . "]") if (!$self->error($dbid));
    $LOG->error("DELETE $remove,[" . join(',', @{$value}) . "]") if ($self->error($dbid));
    $LOG->error($self->getErrorMsg($dbid)) if ($self->error($dbid));
    $LOG->delay("deletedb", "DELETE $remove");
}

=head2 B<[Public] command($dbid,$command)>

    Provede libovolny cely SQL prikaz (DDL, SET, ...) pres DBI do() nad zapisovym spojenim pool 0
    databaze $dbid. Na rozdil od select/insert/update/delete se $command predava cely vcetne
    klicoveho slova a bez bind hodnot. Nic nevraci; chybu overte pres error($dbid).
    Pouziva checkDbversion pro migrace.

        $DBI->command("db1", "CREATE TABLE dbversion (dbversion int, lockid int)");

=cut

sub command {
    my ($self, $dbid, $command) = @_;

    my $line = sprintf("%s line %d", (caller)[1, 2]);
    $command = "/* DB:$dbid $line */ " . $command if ($LOG->getLogLevel() >= 3);    # komentar jen pri info/debug (cache dotazu)
    $LOG->delay("commanddb");
    $self->DBC->{$dbid}->{'0'}->command($command);
    $LOG->debug("COMMAND $command")        if (!$self->error($dbid));
    $LOG->error("COMMAND $command")        if ($self->error($dbid));
    $LOG->error($self->getErrorMsg($dbid)) if ($self->error($dbid));
    $LOG->delay("commanddb", "$command");

}

=head2 B<[Public] getDaoMetaData($dbid)>

    Nacte z databaze (information_schema / DESCRIBE podle driveru) popis jeji struktury a vrati
    hash - tzv. DAO mapu, podle ktere se stavi DAO objekty:
    { tabulka => { TABLE_NAME, TABLE_SCHEM, TABLE_TYPE, TABLE_COLUMNS => { sloupec => { COLUMN_NAME,
    COLUMN_TYPE, COLUMN_SIZE, COLUMN_NULLABLE, COLUMN_DEF, COLUMN_UNSIGNED, COLUMN_UNIQUE,
    COLUMN_PRIMARY, COLUMN_ENUM_VALUE } } } }.
    Konstruktor ji pouziva, pokud neexistuje soubor daomap_file (ten obsahuje tentyz hash
    vydumpovany do souboru, aby se struktura nemusela cist z DB pri kazdem startu).

=cut

sub getDaoMetaData {
    my ($self, $dbid) = @_;
    $LOG->delay("getDaoMetaData");
    my $meta = $self->DBC->{$dbid}->{'0'}->getMetaData();
    $LOG->delay("getDaoMetaData", "Generating DAO MAP");
    return $meta;
}

=head2 B<[Public] getLastInsertID($dbid,$table)>

    Vraci id posledniho INSERTu (AUTO_INCREMENT / SERIAL) na zapisovem spojeni pool 0 databaze
    $dbid; $table je nazev tabulky (u Postgres nutny pro nalezeni sekvence).
    POZOR: u transakcnich spojeni je nutne volat PRED commitem, jinak vraci 0.

=cut

sub getLastInsertID {
    my ($self, $dbid, $table) = @_;
    return $self->DBC->{$dbid}->{'0'}->lastInsertID($table);
}

=head2 B<[Public] getDbDriver($dbid)>

    Vraci nazev driveru dbid ("mysql", "mariadb", "postgres"), nebo "unknown_dbid_dbdriver".
    Pouziva se pro vetveni SQL dialektu (napr. LIMIT/OFFSET v Services::DBTable).

=cut

sub getDbDriver {
    my ($self, $dbid) = @_;
    return $self->{'dbdriver'}->{$dbid} if (exists($self->{'dbdriver'}->{$dbid}));
    return "unknown_dbid_dbdriver";
}

=head2 B<[Public] getDBIObject($dbid,$dbidpool)>

    Vraci objekt driveru (Libs::MyDBI::DRIVER::*) pro dane spojeni z poolu, nebo {} pokud
    neexistuje. Umoznuje nizkourovnovy pristup (napr. autoCommit).

=cut

sub getDBIObject {
    my ($self, $dbid, $dbidpool) = @_;
    return {} unless (exists($self->{'DBC'}->{$dbid}));
    return {} unless (exists($self->{'DBC'}->{$dbid}->{$dbidpool}));
    return $self->{'DBC'}->{$dbid}->{$dbidpool};
}

=head2 B<[Public] ping($dbid,$dbidpool)>

    Overi spojeni $dbidpool databaze $dbid pres ping driveru. Vraci 1 (spojeni zije) nebo undef
    (spojeni padlo, zaloguje error). Pouziva testConnection() a reconnect().

=cut

sub ping {
    my ($self, $dbid, $dbidpool) = @_;
    my $line = sprintf("%s line %d", (caller)[1, 2]);
    $LOG->delay("pingdb_" . $dbid . "_pool" . "$dbidpool");
    if ($self->DBC->{$dbid}->{$dbidpool}->ping()) {
        $LOG->debug("Ping database:$dbid dbidpool:$dbidpool result:connected");
        $LOG->delay("pingdb_" . $dbid . "_pool" . "$dbidpool", "Ping dbid:$dbid dbidpool:$dbidpool OK");
        return 1;
    } else {
        $LOG->error("Ping database:$dbid dbidpool:$dbidpool result:disconnected");
        $LOG->delay("pingdb_" . $dbid . "_pool" . "$dbidpool", "Ping dbid:$dbid dbidpool:$dbidpool ERROR");
        return undef;
    }
}

=head2 B<[Public] commit($dbid)>

    Potvrdi transakci na zapisovem spojeni pool 0 databaze $dbid. Pri chybe zaloguje getErrorMsg;
    uspech overte pres error($dbid). Vraci navratovou hodnotu commit driveru.

=cut

sub commit {
    my ($self, $dbid) = @_;
    my $line = sprintf("%s line %d", (caller)[1, 2]);
    $LOG->delay("commitdb_$dbid");
    my $result = $self->DBC->{$dbid}->{'0'}->commit();
    $LOG->error("Commit $dbid, result:$result") if ($self->error($dbid));
    $LOG->error($self->getErrorMsg($dbid)) if ($self->error($dbid));
    $LOG->delay("commitdb_$dbid", "Commit $dbid");
    return $result;
}

=head2 B<[Public] rollback($dbid)>

    Vrati zpet transakci na zapisovem spojeni pool 0 databaze $dbid. Pri chybe zaloguje getErrorMsg;
    uspech overte pres error($dbid). Vraci navratovou hodnotu rollback driveru.

=cut

sub rollback {
    my ($self, $dbid) = @_;
    my $line = sprintf("%s line %d", (caller)[1, 2]);
    $LOG->delay("rollbackdb");
    my $result = $self->DBC->{$dbid}->{'0'}->rollback();
    $LOG->error("Rollback $dbid, result:$result") if ($self->error($dbid));
    $LOG->error($self->getErrorMsg($dbid)) if ($self->error($dbid));
    $LOG->delay("rollbackdb", "Rollback $dbid");
    return $result;
}

=head2 B<[Public] getError($dbid)>

    Vraci hash { err, errstr, state } s chybou posledni operace na spojeni pool 0 databaze $dbid
    (hodnoty DBI err/errstr/SQLSTATE; bez chyby jsou undef).

=cut

sub getError {
    my ($self, $dbid) = @_;
    return $self->DBC->{$dbid}->{'0'}->getError();
}

=head2 B<[Public] getErrorMsg($dbid)>

    Vraci chybu posledni operace jako text "DB ERROR:<err>, <errstr>" (vhodne do logu). Text vraci
    vzdy, i kdyz k chybe nedoslo - zda chyba nastala, overte pres error($dbid).

=cut

sub getErrorMsg {
    my ($self, $dbid) = @_;
    my $error   = $self->getError($dbid);
    my $status  = $error->{'err'};
    my $message = $error->{'errstr'};
    return "DB ERROR:$status, $message";
}

=head2 B<[Public] error($dbid)>

    Vraci 1, pokud posledni operace na spojeni pool 0 databaze $dbid skoncila chybou (DBI err je
    definovan), jinak 0.

=cut

sub error {
    my ($self, $dbid) = @_;
    return $self->DBC->{$dbid}->{'0'}->error();
}

=head2 B<[Public] disconnect($dbid)>

    Odpoji vsechna spojeni v poolu databaze $dbid (disconnect driveru). Vola pwe.fcgi pri ukonceni
    procesu.

=cut

sub disconnect {
    my ($self, $dbid) = @_;
    foreach my $dbidpool (@{$self->getDbIdPoolList($dbid)}) {
        $self->DBC->{$dbid}->{$dbidpool}->disconnect;
    }
}

=head2 B<[Private] createDAO($dbid,$tname,$tvalue,$dispooler)>

    Vytvori a vrati objekt Libs::MyDBI::DAO pro tabulku $tname databaze $dbid; $tvalue je zaznam
    tabulky z DAO mapy ({ TABLE_TYPE, TABLE_COLUMNS, ... }). Pri $dispooler = 1 dostane DAO sdilene
    spojeni pool 0, jinak prvni spojeni z poolu bez pool locku (DAO si ho v konstruktoru zamkne
    a v DESTROY uvolni); kdyz je cely pool zamceny, zaloguje warning a pouzije pool 0.
    Podle TABLE_TYPE nastavi rewrite: "TABLE"/"BASE TABLE" = zapisovatelna, "VIEW" = jen cteni;
    jiny typ zaloguje error a vraci undef. Pouziva getDAO().

=cut

sub createDAO {
    my ($self, $dbid, $tname, $tvalue, $dispooler) = @_;

    $tname = lc($tname);

    my $DBC = undef;

    if ($dispooler) {
        $DBC = $self->DBC->{$dbid}->{'0'};
    } else {
      LAST: while (1) {
            foreach my $dbidpool (keys %{$self->DBC->{$dbid}}) {
                unless ($self->DBC->{$dbid}->{$dbidpool}->getPoolLock()) {
                    $DBC = $self->DBC->{$dbid}->{$dbidpool};
                    $LOG->debug("SetPoolLock for dbid:$dbid dao_name:$tname");
                    last LAST;
                }
            }
            $LOG->warning("MyDBI POOL CONTEINER IS FULL dbid:$dbid dao_name:$tname (entity name)");
            $DBC = $self->DBC->{$dbid}->{'0'};
            $dispooler = 1;    # sdilene spojeni pool 0 nesmi DAO po svem zaniku odemknout
            last;
        }
    }

    my $rewrite = 0;
    my $ttype   = $tvalue->{'TABLE_TYPE'};

    if ($ttype eq "TABLE") {
        $rewrite = 1;
    } elsif ($ttype eq "BASE TABLE") {
        $rewrite = 1;
    } elsif ($ttype eq "VIEW") {
        $rewrite = 0;
    } else {
        $LOG->error("Deny created DAO object. Unknown table type $ttype");
        return undef;
    }

    $LOG->delay("create_dao_$tname");
    my $DAO = new Libs::MyDBI::DAO($self->getDbDriver($dbid), $DBC, $LOG, $VALIDATE, $tname, $tvalue->{'TABLE_COLUMNS'}, $rewrite, $dispooler);
    $LOG->delay("create_dao_$tname", "Creating DAO $tname");
    return $DAO;
}

=head2 B<[Public] getDAO($dbid,$table,$id|{where => "col1 = ? AND col2 = ?", conds => [...]}|{disable_db_pooler => 1})>

    Metoda vraci DAO objekt (Libs::MyDBI::DAO) k tabulce $table v databazi $dbid.

    - getDAO($dbid,$table)                 - prazdny objekt (pro INSERT)
    - getDAO($dbid,$table,$id)             - nacte radek podle primarniho klice
    - getDAO($dbid,$table,{where,conds})   - nacte radek podle podminky (bez 'where' nenacita nic)
    - getDAO($dbid,$table,{disable_db_pooler => 1}) - sdileny objekt nad poolem 0 (pouziva loader entit)

    Pri neznamem dbid nebo tabulce (chybi v DAO mape) metoda die.

=cut

sub getDAO {
    my ($self, $dbid, $table, $opts) = @_;

    ### dbid:$dbid, table:$table, id:$id

    unless ($self->existsDBC($dbid)) {
        $LOG->error("Unknown dbid:$dbid");
        die "Unknown dbid:$dbid";
    }

    unless (exists($self->{'maps'}->{$dbid}->{$table})) {
        $LOG->error("Unknown DAO MAP dbid:$dbid, table:$table");
        die "Unknown DAO MAP dbid:$dbid, table:$table";
    }

    if ($table and (ref($opts) eq "HASH")) {
        if (defined($opts->{'disable_db_pooler'})) {
            my $OBJ = $self->createDAO($dbid, $table, $self->{'maps'}->{$dbid}->{$table}, 1);
            return $OBJ;
        } else {
            my $OBJ = $self->createDAO($dbid, $table, $self->{'maps'}->{$dbid}->{$table});
            # Bez klice 'where' se zadny radek nenacita (prazdny objekt pro INSERT).
            $OBJ->refreshTABLE($opts->{'where'}, ($opts->{'conds'} || [])) if (defined($opts->{'where'}));
            return $OBJ;
        }
    } elsif ($table and $opts) {
        my $id = $opts;
        my $OBJ = $self->createDAO($dbid, $table, $self->{'maps'}->{$dbid}->{$table});
        $OBJ->refreshTABLE($OBJ->getPrimaryColumnName() . " = ?", [$id]);
        return $OBJ;
    } elsif ($table) {
        my $OBJ = $self->createDAO($dbid, $table, $self->{'maps'}->{$dbid}->{$table});
        return $OBJ;
    } else {
        die "METHOD:GetDAO : YOU MUST DEFINE DBDAO NAME!!!\n";
    }
}

=head2 B<[Public] getDbidList()>

    Vraci referenci na pole vsech dbid (napr. ['db1']).

=cut

sub getDbidList {
    my $self = shift;
    my $list = [];
    foreach my $dbid (keys %{$self->DBC}) {
        push(@{$list}, $dbid);
    }
    return $list;
}

=head2 B<[Public] getDbIdPoolList($dbid)>

    Vraci referenci na pole indexu spojeni v poolu daneho dbid (0..db_pool).

=cut

sub getDbIdPoolList {
    my ($self, $dbid) = @_;
    my $list = [];
    foreach my $dbidpool (keys %{$self->DBC->{$dbid}}) {
        push(@{$list}, $dbidpool);
    }
    return $list;
}

=head2 B<[Public] getDAOList($dbid)>

    Vraci referenci na pole nazvu tabulek/pohledu z DAO mapy (pouziva pweCreator pro nabidku tabulek).

=cut

sub getDAOList {
    my ($self, $dbid) = @_;
    my $result = [];
    foreach (keys %{$self->{'maps'}->{$dbid}}) { push(@{$result}, $_); }
    return $result;
}

=head2 B<[Private] existsDBC($dbid)>

    Vraci 1/0 podle toho, zda existuje spojeni pool 0 pro dane dbid.

=cut

sub existsDBC {
    my ($self, $dbid) = @_;
    return 0 unless ($self->DBC->{$dbid}->{'0'});
    return 1;
}

=head2 B<[Private] DBC()>

    Vraci hash vsech spojeni: { dbid => { poolid => driver_objekt } }.

=cut

sub DBC {
    my $self = shift;
    return $self->{'DBC'};
}

=head2 B<[Public] testConnection()>

    Overi vsechna spojeni (ping) a padla znovu pripoji (reconnect). Vola pwe.fcgi na zacatku kazdeho
    requestu, ale skutecny ping probehne nejvyse jednou za conf pwe.db_ping_interval sekund
    (vychozi 60; 0 = pri kazdem requestu). Chyba spojeni mezi pingy se projevi az chybou dotazu.

=cut

sub testConnection {
    my $self = shift;

    # Ping vsech spojeni stoji nekolik dotazu (MySQL 2 na pool); staci ho delat jednou za
    # pwe.db_ping_interval sekund (vychozi 60, 0 = kazdy request jako drive).
    my $interval = $CONF->getValue("pwe", "db_ping_interval", 60);
    my $now      = time();
    return if ($interval > 0 and defined($self->{'last_ping'}) and ($now - $self->{'last_ping'}) < $interval);
    $self->{'last_ping'} = $now;

    $LOG->delay("test_connection_db_total");
    foreach my $dbid (@{$self->getDbidList()}) {
        foreach my $dbidpool (@{$self->getDbIdPoolList($dbid)}) {
            $self->reconnect($dbid) unless ($self->ping($dbid, $dbidpool));
        }
    }
    $LOG->delay("test_connection_db_total", "Test total connection finish");
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
    $LOG      = new Libs::Log;
    $CONF     = new Libs::Config;
    $VALIDATE = new Libs::Validate;
}

1;
