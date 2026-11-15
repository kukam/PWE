package Libs::MyDBI;

=head1 NAME

Libs::MyDBI - databazova vrstva: pool spojeni, drivery (MySQL/MariaDB, PostgreSQL), migrace dbversion, DAO mapa

=head1 POPIS

    Nizkourovnove API: select/insert/update/delete/command/commit/rollback($dbid, ...), kazdy SQL se
    oznaci komentarem s mistem volani. Objektovy pristup: getDAO (viz Libs::MyDBI::DAO) a entity.

=cut

use strict;
use Libs::MyDBI::DAO;

my ($CONF, $LOG, $VALIDATE);

=head2 B<[Public] new($conf,$log,$validate)>

    Konstruktor databazove vrstvy. Pro kazde dbid v sekci 'dbi' (conf/database.conf) vytvori
    db_pool+1 spojeni (pool 0 je sdileny/zamceny pro primo volane select/insert/..., ostatni
    si pujcuji DAO objekty), pri neuspechu to zkousi trayconnect-krat a pak die. Pote spusti
    migrace (checkDbversion, pokud existuje dbversion_file) a nacte DAO mapu struktury tabulek
    (z daomap_file, jinak z information_schema pres getDaoMetaData). Bez sekce 'dbi' bezi
    engine bez databaze (static weby).

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
                sleep(1) if ($delay < 1);
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
    dbversion. Tabulku dbversion (dbversion int, lockid int) metoda pri prvnim spusteni sama zalozi
    (existenci zjistuje z information_schema - u MySQL podle 'database', u Postgres podle 'schema';
    jiny driver -> die). Proti soubezne migraci z vice procesu se chrani zamkem lockid (nahodne
    cislo): dokud zamek drzi jiny proces, ceka v cyklu po 1 s. Po kazdem uspesnem prikazu zapise
    novou verzi a commitne; pri chybe SQL provede rollback, uvolni zamek a die.
    Vola se z konstruktoru, pokud dbversion_file existuje.

=cut

sub checkDbversion {
    my ($self, $dbid, $dbconf) = @_;

    my $SQL = undef;

    # DAO V TUTO CHVILI JESTE NEJDE POUZIT PRO ZJISTENI EXISTENCE TABULKY, DBI SE ZAKLADA PRED DAO!
    if (($dbconf->{'dbdriver'} eq "mysql") or ($dbconf->{'dbdriver'} eq "mariadb")) {
        $SQL = $self->select($dbid, "1 FROM information_schema.tables WHERE table_name = ? AND table_schema = ? LIMIT 1", ["dbversion", $dbconf->{'database'}]);
    } elsif ($dbconf->{'dbdriver'} eq "postgres") {
        $SQL = $self->select($dbid, "1 FROM information_schema.tables WHERE table_name = ? AND table_schema = ?", ["dbversion", (defined($dbconf->{'schema'}) ? $dbconf->{'schema'} : "public")]);
    } else {
        die "Unknown dbdriver: $dbconf->{'dbdriver'}\n";
    }

    unless ($SQL->fetchrow_array()) {
        $self->command($dbid, "CREATE TABLE dbversion (dbversion int, lockid int)");
        $self->insert($dbid, "INTO dbversion (dbversion,lockid) VALUES(?,?)", [0, 0]);
        $self->commit($dbid);
    }
    $SQL->finish();

    my $mylockid = int(rand(999999999));

    my %dbversion_conf = %{do($dbconf->{'homepath'} . "/" . $dbconf->{'dbversion_file'})};

  WHILE: while (1) {

        my $SQL1 = $self->select($dbid, "dbversion,lockid FROM dbversion", []);
        my ($dbversion, $lockid) = $SQL1->fetchrow_array();
        $SQL1->finish();

        # AKTUALIZACI PROVADI JINY PROCES, POCKAME NA AKTUALIZACI DB
        if (($lockid ne 0) and ($lockid ne $mylockid)) {
            $LOG->error("Dbversion is locked by lockid:$lockid");
            sleep 1;
            next;
        }

        foreach my $id (sort { $a <=> $b } keys %dbversion_conf) {

            # PROCHAZIME DBVERSION OD NEJNIZSSI VERZE
            # AKCI SPUSTIME AZ VE CHVILI KDY VERZE V CONFU
            # JE VYSSI NEZ V DATABAZI!
            next if ($id <= $dbversion);

            # AKTUALIZACE NENI ZAMCENA JINYM PROCESEM,
            # NASTAVIME ZAMEK A PROVEDEME KONTROLU ZDALI ZAMEK JE NAS!
            # MUZE SE STAT ZE NAS PREDBEHNE DRUHY PROCES SPUSTENY PARALERNE
            if ($lockid == 0) {
                $self->update($dbid, "dbversion SET lockid = ? WHERE lockid = ?", [$mylockid, 0]);
                $self->commit($dbid);
                next WHILE;
            }

            # PROVEDEME AKTUALIZACI DATABAZE
            my $cmd = $dbversion_conf{$id};
            $self->command($dbid, $cmd);
            if ($self->error($dbid)) {
                my $errormsg = $self->getErrorMsg($dbid);
                $LOG->error($cmd);
                $self->rollback($dbid);
                $self->update($dbid, "dbversion SET lockid = ? WHERE lockid = ?", [0, $mylockid]);
                $self->commit($dbid);
                die "Dbversion fail id:$id : $errormsg \n $cmd\n";
                exit -1;
            } else {
                $LOG->info("Dbversion update to id $id");
                $self->update($dbid, "dbversion SET dbversion = ?", [$id]);
                $self->commit($dbid);
            }
        }
        if ($lockid eq $mylockid) {
            $self->update($dbid, "dbversion SET lockid = ? WHERE lockid = ?", [0, $mylockid]);
            $self->commit($dbid);
        }
        last;
    }
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
