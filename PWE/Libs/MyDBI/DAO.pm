package Libs::MyDBI::DAO;

=head1 NAME

Libs::MyDBI::DAO - objektova obalka jednoho radku tabulky (dynamicke metody sloupcu, validace, INSERT/UPDATE/DELETE)

=head1 POPIS

    Vytvari se pres Libs::MyDBI::getDAO nebo entity. Sloupce jsou dostupne jako metody ($DAO->nazev / $DAO->nazev($v)),
    setter validuje podle typu z DAO mapy. flush() zapise zmeny (INSERT bez PK, UPDATE s PK), pote commit/rollback.

=cut

use strict;
use Class::Inspector;

my ($LOG, $VALIDATE);
our $AUTOLOAD;    # it's a package global

=head2 B<[Public] new($dbdriver,$dbc,$log,$validate,$tablename,$columns,$rewrite,$is_share_dbpool)>

    Konstruktor DAO (objektova obalka jednoho radku tabulky). $columns je popis sloupcu z DAO mapy
    (COLUMN_TYPE, COLUMN_SIZE, COLUMN_NULLABLE, COLUMN_DEF, COLUMN_UNSIGNED, COLUMN_UNIQUE,
    COLUMN_PRIMARY, COLUMN_ENUM_VALUE). Pro kazdy sloupec vznikne dynamicka metoda (AUTOLOAD)
    getter/setter a hodnota se nastavi na COLUMN_DEF. Sloupec se nesmi jmenovat jako interni
    metoda DAO (flush, error, commit, ...) - jinak die. $rewrite = 0 pro VIEW (jen cteni).
    Nesdileny objekt si zamkne sve spojeni v poolu (setPoolLock), uvolni ho DESTROY.
    Primo se nevytvari - pouzivejte $DBI->getDAO nebo entity ($ENTITIES->createEntityObject).

=cut

sub new {
    my ($class, $dbdriver, $dbi, $log, $validate, $tablename, $columns, $rewrite, $is_share_dbpool) = @_;

    $LOG      = $log;
    $VALIDATE = $validate;

    # SET GLOBAL VALUES
    my $self = {
        'DB'              => $dbi,                                  # db connection
        'DAO'             => {},
        'dbdriver'        => $dbdriver,
        'tablenane'       => $tablename,
        'rewrite'         => $rewrite,                              # Zapisovatelny objekt, nebo jen objekt pro cteni? (table/view)
        'db_run_method'   => undef,                                 # Jmeno metody ktera provedla zapis do db (insert/update/delete)
        'unique_check'    => 1,                                     # 1/undef  Zapinadlo kontroly unikatnosti na zapis ci zmenu sloupce v db
        'who_calling_me'  => undef,
        'primarycolumn'   => undef,
        'primaryvalue'    => undef,
        'methodlist'      => [],                                    # ziskame seznam zapisovatelnych metod
        'changelist'      => {},
        'errorlist'       => {},
        'sql_string'      => ((($dbdriver eq "mysql") or ($dbdriver eq "mariadb")) ? "`" : ""),
        'is_share_dbpool' => ($is_share_dbpool ? 1 : 0)             # Informace o sdilenem/nesdilenem connection poolu
    };

    bless $self, $class;

    unless ($is_share_dbpool) {

        # Zapneme pool lock.
        # Tento objet si vyhrazuje pravo na samostanou transakci v ramci jednoho spojeni s db.
        $self->DB->setPoolLock(1);
    }

    while (my ($name, $options) = each(%{$columns})) {

        if ($self->existsInternalMethodName($name)) {
            $LOG->error("JMENO SLOUPCE '$tablename.$name' SE NESMI SHODOVAT S INTERNIMI NAZVY METOD, PREJMENUJTE NAZEV SLOUPCE V DB!!!!");
            $self->rollback;
            $self->DB->disconnect;
            die 'DAO ERROR! (Read the log).';
        }

        my $prim   = $options->{'COLUMN_PRIMARY'};
        my $type   = $options->{'COLUMN_TYPE'};
        my $size   = $options->{'COLUMN_SIZE'};
        my $null   = $options->{'COLUMN_NULLABLE'};
        my $def    = $options->{'COLUMN_DEF'};
        my $unsig  = $options->{'COLUMN_UNSIGNED'};
        my $unique = $options->{'COLUMN_UNIQUE'};
        my $enumv  = (($type eq "ENUM") ? $options->{'COLUMN_ENUM_VALUE'} : undef);

        if ($prim) {

            # SET PRIMARY COLUMN NAME
            $self->setPrimaryColumnName($name);

            # SET PRIMARY COLUMN AS UNIQUE
            $unique = 1;
        }

        $self->DAO->{$name} = {};

        $self->DAO->{$name}->{'size'}   = $size;
        $self->DAO->{$name}->{'null'}   = $null;
        $self->DAO->{$name}->{'type'}   = $type;
        $self->DAO->{$name}->{'def'}    = $def;
        $self->DAO->{$name}->{'unsig'}  = $unsig;
        $self->DAO->{$name}->{'unique'} = $unique;
        $self->DAO->{$name}->{'enumv'}  = $enumv if ($enumv);

        $self->setValue($name, $def);

        push(@{$self->{'methodlist'}}, $name);
    }

    return $self;
}

=head2 B<[Public] flush()>

    Zapise zmenene sloupce do DB: bez primarniho klice INSERT (vraci nove id a nastavi ho
    jako primarni hodnotu), s primarnim klicem UPDATE (vraci primarni hodnotu). Pred zapisem
    zkontroluje unikatnost zmenenych UNIQUE sloupcu (CheckUniqueValue) - pri duplicite vraci
    undef a nastavi chybu. Bez zmen vraci primarni hodnotu. U VIEW vraci undef.
    Po flush je potreba zavolat commit (nebo rollback pri error()).

=cut

sub flush {
    my $self = shift;

    unless ($self->getRewrite) {
        $LOG->error("REWRITE options is disabled (VIEW)");
        return undef;
    }

    return $self->getPrimaryValue() if (@{$self->getChangeList()} == 0);

    my $who = $self->getWhoCallingMe();
    $who = ($who ? $who : sprintf("%s line %d", (caller)[1, 2]));

    foreach my $name (@{$self->getChangeList()}) {
        return unless ($self->CheckUniqueValue($name, $who, $self->getValue($name, 'value')));
    }

    if ($self->getPrimaryValue()) {
        my ($query, $value) = $self->createUpdateQuery($who);
        my $change_count = $self->update($query, $value);
        return $self->getPrimaryValue();
    } else {
        my ($query, $value) = $self->createInsertQuery($who);
        my $last_id = $self->insert($query, $value);
        
        # Zapiseme insertnute id do objekt,
        # aby v dalsich krocich po flushi jsme mohli pracovat s novym ID.
        $self->setPrimaryValue($last_id);
        return $last_id;
    }
}

=head2 B<[Public] logit($add_string)>

    Zapise do logu standardni zaznam o tom, co objekt zmenil/pridal/smazal, aby se log nemusel
    sestavovat rucne. Pokud je na objektu chyba (error), zaloguje misto toho texty z errorlistu
    jako error. Jinak, pokud existuji zmenene sloupce, zaloguje na info (a na debug i s volajicim)
    radek "<add_string> <INSERT|UPDATE|DELETE> DATA table:<tabulka> <pk>:<hodnota> <sloupec>:<hodnota>(<TYP>) ...".
    Binarni typy (BLOB, BYTEA) se vypisi jako [<binaryData>], TEXT se zkrati na 50 znaku.
    Volat po flush (seznam zmen zustava az do refreshTABLE/rollback/clearAllMethod).

        $DAO->flush;
        $DAO->logit;                 # nebo $DAO->logit("new value");

    Vystup:
        "new value UPDATE DATA table:users uid:5 fullname:Jan Novak(VARCHAR) "

=cut

sub logit {
    my ($self, $add_string) = @_;

    my $who = $self->getWhoCallingMe();
    my $tab = $self->getTableName();
    my $run = $self->getRunDBMethod();
    my $prn = $self->getPrimaryColumnName();
    my $prv = $self->getPrimaryValue();
    my $txt = ($prv ? "$prn:$prv " : "");
    my $add = ($add_string ? "$add_string " : "");

    if ($self->error) {
        foreach my $errtxt (@{$self->getErrorList()}) { $LOG->error($errtxt); }
    } elsif (@{$self->getChangeList()} > 0) {
        foreach my $method (@{$self->getChangeList()}) {
            my $value = $self->getValue($method, "value");
            my $type = uc($self->getValue($method, "type"));
            if($type eq "BYTEA" or $type eq "BLOB" or $type eq "TINYBLOB" or $type eq "MEDIUMBLOB" or $type eq "LONGBLOB") {
                $value = "[<binaryData>]";
            } elsif ($type eq "TEXT") {
                if(length($value) > 50) {
                    $value = "[".substr($value,0,50)."....]";    
                } else {
                    $value = "[$value]";
                }
            }
            $txt .= "$method:$value($type) ";
        }
        $LOG->debug("$add$run DATA who: $who table:$tab $txt");
        $LOG->info("$add$run DATA table:$tab $txt");
    }
}

=head2 B<[Public] DELETE_ROW()>

    Smaze radek podle primarniho klice (DELETE FROM tabulka WHERE pk = ?). Bez nastaveneho
    primarniho klice nic neudela a zaloguje chybu. U VIEW vraci undef.

=cut

sub DELETE_ROW {
    my $self = shift;

    unless ($self->getRewrite) {
        $LOG->error("REWRITE options is disabled (VIEW)");
        return undef;
    }

    my $who = $self->getWhoCallingMe();
    $who = ($who ? $who : sprintf("%s line %d", (caller)[1, 2]));

    if ($self->getPrimaryValue()) {
        my ($query, $value) = $self->createDeleteQuery($who);
        $self->delete($query, $value);
    } else {
        $LOG->error("DELETE_ROW primary key was not set!");
    }
}

=head2 B<[Public] refreshTABLE($where,$conds)>

    Nacte do objektu prvni radek odpovidajici podmince (SELECT * FROM tabulka WHERE $where,
    bind hodnoty $conds), nastavi primarni hodnotu a vycisti seznam zmen. Pokud radek neexistuje,
    objekt zustane prazdny (loguje se info) - lze ho pak pouzit pro INSERT ("nacti nebo zaloz").

=cut

sub refreshTABLE {
    my ($self, $where, $conds) = @_;

    my $who = $self->getWhoCallingMe();
    $who = ($who ? $who : sprintf("%s line %d", (caller)[1, 2]));

    my $table = $self->getTableName();
    my $prim  = $self->getPrimaryColumnName();
    my $SQL   = $self->select("/* DAO:refreshTABLE:$table $who */ * FROM $table WHERE $where", $conds);

    my $data = {};

    my $c          = 0;
    my $resultdata = $SQL->fetchall_hashref($prim);
    while (my ($pv, $hash) = each(%{$resultdata})) {
        if ($c > 0) {
            $LOG->warning("DAO Refrest Table: data is duplicated $table:$prim:$pv !!!");
        } else {
            $LOG->debug("DAO Refresh Table: refreshing data $table:$prim:$pv");
        }
        $data = $hash;
        $c++;
    }

    $SQL->finish;

    if ($c > 0) {
        while (my ($key, $value) = each(%{$data})) {

            # SETUJEME DATA A IGNORUJEME VOLBU REWRIRE. HODNOTU REWRITE KONTROLUJEME AZ PRI FLUSHI
            $self->setValue($key, $value);
            $self->setChangeList({});
            if ($key eq $prim) {
                $self->setPrimaryValue($value);
            }
        }
    } else {
        # Bezny stav pri "nacti nebo zaloz" (session, dbtable) - proto jen info, ne warning.
        $LOG->info("Couldn't load any row (CREATE NEW EMPTY ROW) DAO:$table who:$who SELECT * FROM $table WHERE $where, [@{$conds}]");
    }
}

=head2 B<[Public] select($select,$value)>

    Provede SELECT nad spojenim tohoto DAO objektu. $select je dotaz bez uvodniho slova SELECT,
    $value je reference na pole bind hodnot. Vraci DBI statement handle (volajici si data vybere
    a zavola finish); chybu loguje a lze ji overit pres error(). Interne pouziva refreshTABLE
    a CheckUniqueValue.

=cut

sub select {
    my ($self, $select, $value) = @_;
    $LOG->delay("selectdb");
    my $SQL = $self->DB->select($select, $value);
    $LOG->debug("SELECT $select,[@{$value}]") if (!$self->error());
    $LOG->error("SELECT $select,[@{$value}]") if ($self->error());
    $LOG->error("SELECT error: " . join("\n\t", @{$self->getErrorList()})) if ($self->error());
    $LOG->error($self->getError->{'errstr'}) if ($self->DB->error());
    $LOG->delay("selectdb", "SELECT $select");
    return $SQL;
}

=head2 B<[Public] insert($insert,$value)>

    Provede INSERT nad spojenim tohoto DAO objektu ($insert je cast prikazu za slovem INSERT,
    $value reference na pole bind hodnot), nastavi RunDBMethod na "INSERT" a zjisti nove id pres
    getLastInsertID (pokud ho DB nevrati, pouzije aktualni hodnotu primarniho sloupce - PK zadany
    rucne). Toto id ulozi jako primarni hodnotu objektu a vrati ho; pri chybe DB vraci undef.
    Vola se z flush() - primo se bezne nepouziva, hodnoty se nastavuji settery sloupcu a flush.

=cut

sub insert {
    my ($self, $insert, $value) = @_;
    $LOG->delay("insertdb");
    $self->setRunDBMethod("INSERT");
    $self->DB->insert($insert, $value);
    my $lid = $self->getLastInsertID();

    unless(defined($lid)) {
       $lid = $self->getValue($self->getPrimaryColumnName(),'value');
    }

    my $log_newid = (defined($lid) ? "[NEWID: $lid]" : "");
    $LOG->debug("INSERT $insert,[@{$value}] $log_newid") if (!$self->error());
    $LOG->error("INSERT $insert,[@{$value}] $log_newid") if ($self->error());
    $LOG->error("INSERT error: " . join("\n\t", @{$self->getErrorList()})) if ($self->error());
    $LOG->error($self->getError->{'errstr'}) if ($self->DB->error());
    $LOG->delay("insertdb", "INSERT $insert");
    
    $self->setPrimaryValue($lid);
    ($self->DB->error() ? undef : $lid);
}

=head2 B<[Public] update($update,$value)>

    Provede UPDATE nad spojenim tohoto DAO objektu ($update je cast prikazu za slovem UPDATE,
    $value reference na pole bind hodnot) a nastavi RunDBMethod na "UPDATE". Vraci pocet
    ovlivnenych radku (z DBI execute; undef pri chybe). Vola se z flush().

=cut

sub update {
    my ($self, $update, $value) = @_;
    $LOG->delay("updatedb");
    $self->setRunDBMethod("UPDATE");
    my $count = $self->DB->update($update, $value);
    $LOG->debug("UPDATE $update,[@{$value}]") if (!$self->error());
    $LOG->error("UPDATE $update,[@{$value}]") if ($self->error());
    $LOG->error("UPDATE error: " . join("\n\t", @{$self->getErrorList()})) if ($self->error());
    $LOG->error($self->getError->{'errstr'}) if ($self->DB->error());
    $LOG->delay("updatedb", "UPDATE $update");
    return $count;
}

=head2 B<[Public] delete($remove,$value)>

    Provede DELETE nad spojenim tohoto DAO objektu ($remove je cast prikazu za slovem DELETE,
    $value reference na pole bind hodnot) a nastavi RunDBMethod na "DELETE". Nic nevraci; chybu
    overte pres error(). Vola se z DELETE_ROW().

=cut

sub delete {
    my ($self, $remove, $value) = @_;
    $LOG->delay("deletedb");
    $self->setRunDBMethod("DELETE");
    $self->DB->delete($remove, $value);
    $LOG->info("DELETE $remove,[@{$value}]")  if (!$self->error());
    $LOG->error("DELETE $remove,[@{$value}]") if ($self->error());
    $LOG->error("DELETE error: " . join("\n\t", @{$self->getErrorList()})) if ($self->error());
    $LOG->error($self->getError->{'errstr'}) if ($self->DB->error());
    $LOG->delay("deletedb", "DELETE $remove");
}

=head2 B<[Public] commit()>

    Potvrdi transakci na spojeni objektu (a zaloguje, pokud byly zmeny). Potvrzene zmeny
    vyprazdni ze seznamu zmen (getChangeList), takze dalsi flush() na tomtez objektu uz je
    znovu nezapise - objekt lze drzet pres cely request (viz Services::Session).

=cut

sub commit {
    my $self = shift;
    $self->DB->commit();
    $LOG->debug("DB Commit " . $self->getTableName() . " " . ($self->getPrimaryValue ? $self->getPrimaryColumnName() . ":" . $self->getPrimaryValue() : "")) if(@{$self->getChangeList()} > 0);
    $self->setChangeList({});
}

=head2 B<[Public] rollback()>

    Vrati transakci zpet a vycisti objekt (clearAllMethod): hodnoty na defaulty, bez PK,
    bez chyb.

=cut

sub rollback {
    my $self = shift;
    $self->DB->rollback();
    $self->clearAllMethod();
    $LOG->debug("DB Rollback " . $self->getTableName() . " " . ($self->getPrimaryValue ? $self->getPrimaryColumnName() . ":" . $self->getPrimaryValue() : ""));
}

=head2 B<[Public] clearAllMethod()>

    Uvede objekt do vychoziho stavu: zmenene sloupce vrati na COLUMN_DEF, zrusi primarni
    hodnotu, zapne kontrolu unikatnosti, vycisti seznam zmen a chyb.

=cut

sub clearAllMethod {
    my $self = shift;

    foreach my $method (@{$self->getChangeList()}) {
        my $def = $self->getValue($method, 'def');
        $self->setValue($method, $def);
    }

    $self->setPrimaryValue(undef);
    $self->setRunDBMethod(undef);
    $self->setUniqueCheckValue(1);
    $self->setChangeList({});
    $self->setErrorList({});
}

=head2 B<[Public] error()>

    Vraci 1 pokud je chyba na DB spojeni nebo v errorlistu objektu (neplatna hodnota, duplicita), jinak 0.
    Typicky vzor: $E->flush; if ($E->error) { $E->rollback } else { $E->commit }.

=cut

# GETER/SETER
sub error {
    my $self = shift;
    return 1 if ($self->DB->error());
    return 1 if (@{$self->getErrorList()} > 0);
    return 0;
}

=head2 B<[Public] getError()>

    Vraci hash chyby spojeni { err, errstr, state } doplneny o klic <tabulka> => [chyby objektu].

=cut

sub getError {
    my $self   = shift;
    my $table  = $self->getTableName();
    my $result = $self->DB->getError();
    $result->{$table} = $self->getErrorList;
    return $result;
}

=head2 B<[Private] DB()>

    Vraci objekt driveru (spojeni), nad kterym DAO pracuje.

=cut

sub DB {
    my $self = shift;
    return $self->{'DB'};
}

=head2 B<[Private] DAO()>

    Vraci interni hash popisu sloupcu: { sloupec => { type, size, null, def, unsig, unique, enumv, value } }.

=cut

sub DAO {
    my $self = shift;
    return $self->{'DAO'};
}

=head2 B<[Public] getValue($column,$attribute)>

    Vraci atribut sloupce: 'value' (aktualni hodnota), 'type', 'size', 'null', 'def', 'unsig',
    'unique', 'enumv'. Pro aktualni hodnotu lze volat i primo $DAO->sloupec().

=cut

sub getValue {
    my ($self, $name, $atribute_name) = @_;
    return $self->DAO->{$name}->{$atribute_name};
}

=head2 B<[Public] getChangeList()>

    Vraci referenci na pole nazvu sloupcu zmenenych od posledniho nacteni (refreshTABLE), commit,
    rollback nebo clearAllMethod. Samotny flush() seznam nemaze, aby sel po nem zavolat logit().

=cut

sub getChangeList {
    my $self   = shift;
    my $result = [];
    foreach my $method (keys %{$self->{'changelist'}}) { push(@{$result}, $method); }
    return $result;
}

=head2 B<[Public] getRewrite()>

    Vraci 1 pro zapisovatelnou tabulku, 0 pro VIEW.

=cut

sub getRewrite {
    my $self = shift;
    return $self->{'rewrite'};
}

=head2 B<[Public] getTableName()>

    Vraci nazev tabulky (malymi pismeny).

=cut

sub getTableName {
    my $self = shift;
    return $self->{'tablenane'};
}

=head2 B<[Public] getMethodList()>

    Vraci referenci na pole nazvu vsech sloupcu (= dynamickych metod).

=cut

sub getMethodList {
    my $self = shift;
    return $self->{'methodlist'};
}

=head2 B<[Public] getErrorList()>

    Vraci referenci na pole textu chyb objektu (neplatne hodnoty, duplicity).

=cut

sub getErrorList {
    my $self   = shift;
    my $result = [];
    foreach my $msg (keys %{$self->{'errorlist'}}) { push(@{$result}, $msg); }
    return $result;
}

=head2 B<[Public] getPrimaryColumnName()>

    Vraci nazev primarniho sloupce (nebo undef, napr. u VIEW bez PK).

=cut

sub getPrimaryColumnName {
    my $self = shift;
    return $self->{'primarycolumn'};
}

=head2 B<[Public] getPrimaryValue()>

    Vraci hodnotu primarniho klice nacteneho/insertnuteho radku (undef = novy radek).

=cut

sub getPrimaryValue {
    my $self = shift;
    return $self->{'primaryvalue'};
}

=head2 B<[Public] getLastInsertID()>

    Vraci id posledniho INSERTu do tabulky objektu (lastInsertID driveru), nebo undef, pokud
    driver zadne id nevrati (0/undef).
    POZOR: u transakcnich spojeni je nutne volat PRED commitem, jinak driver vraci 0.

=cut

sub getLastInsertID {
    my $self = shift;
    my $lid  = $self->DB->lastInsertID($self->getTableName());
    return ($lid ? $lid : undef);
}

=head2 B<[Private] getWhoCallingMe()>

    Vraci popis volajiciho ("soubor line N") pro SQL komentare a logy; nastavuje Entities::Entity::AUTOLOAD.

=cut

sub getWhoCallingMe {
    my $self = shift;
    my $who  = $self->{'who_calling_me'};
    return $who;
}

=head2 B<[Public] getUniqueCheckValue()>

    Vraci 1 pokud je zapnuta kontrola unikatnosti pri flush, jinak undef.

=cut

sub getUniqueCheckValue {
    my $self = shift;
    return ($self->{'unique_check'} ? 1 : undef);
}

=head2 B<[Public] getRunDBMethod()>

    Vraci posledni provedenou DB operaci objektu: "INSERT", "UPDATE", "DELETE" nebo undef.

=cut

sub getRunDBMethod {
    my $self = shift;
    return $self->{'db_run_method'};
}

=head2 B<[Private] setValue($column,$value)>

    Nastavi hodnotu sloupce BEZ validace (validaci dela AUTOLOAD setter pres CheckValue).
    U sloupcu typu boolean prevede true/t/yes/y/on -> 1 a false/f/no/n/off -> 0. Zmena se
    eviduje v changelistu jen pokud se hodnota skutecne lisi (undef a '' jsou si rovny).

=cut

sub setValue {
    my ($self, $name, $value) = @_;

    if (lc($self->getValue($name, "type")) eq 'boolean') {
        $value = 1 if (lc($value) eq "true"  or lc($value) eq "t" or lc($value) eq "yes" or lc($value) eq "y" or lc($value) eq "on");
        $value = 0 if (lc($value) eq "false" or lc($value) eq "f" or lc($value) eq "no"  or lc($value) eq "n" or lc($value) eq "off");
    }

    if ($self->DAO->{$name}->{'value'} ne $value) {
        $self->setChangeList($name);
        $self->DAO->{$name}->{'value'} = $value;
    }

    return $value;
}

=head2 B<[Public] getMirroredData()>

    Vraci hash { sloupec => aktualni hodnota, ... } se vsemi sloupci objektu - zrcadlo dat 1:1
    (napr. pro predani do sablony nebo do JSON).

        my $data = $DAO->getMirroredData();   # { uid => 5, fullname => "Jan Novak", ... }

=cut

sub getMirroredData {
    my $self = shift;
    my $mirror;
    foreach my $m (@{$self->getMethodList()}) {
        $mirror->{$m} = $self->getValue($m, 'value');
    }
    return $mirror;
}

=head2 B<[Private] setChangeList($column|{})>

    Prida sloupec do seznamu zmen; s hashem {} seznam nahradi (vycisti).

=cut

sub setChangeList {
    my ($self, $value) = @_;
    if (ref($value) eq "HASH") {
        $self->{'changelist'} = $value;
    } else {
        $self->{'changelist'}->{$value} = 1;
    }
}

=head2 B<[Public] setErrorList($text|{})>

    Prida text chyby do errorlistu (pouzivaji i entity pri vlastni validaci sloupce); s hashem {}
    errorlist vycisti.

=cut

sub setErrorList {
    my ($self, $value) = @_;
    if (ref($value) eq "HASH") {
        $self->{'errorlist'} = $value;
    } else {
        $self->{'errorlist'}->{$value} = 1;
    }
}

=head2 B<[Private] setPrimaryColumnName($name)>

    Nastavi nazev primarniho sloupce (vola konstruktor podle COLUMN_PRIMARY).

=cut

sub setPrimaryColumnName {
    my ($self, $name) = @_;
    $self->{'primarycolumn'} = $name;
}

=head2 B<[Public] setPrimaryValue($value)>

    Nastavi hodnotu primarniho klice (a zaroven hodnotu primarniho sloupce). Rozhoduje o tom,
    zda flush provede INSERT (undef) nebo UPDATE.

=cut

sub setPrimaryValue {
    my ($self, $value) = @_;
    $self->{'primaryvalue'} = $value;
    if (defined($self->getPrimaryColumnName())) {
        $self->setValue($self->getPrimaryColumnName(), $value);
    }
}

=head2 B<[Private] setWhoCallingMe($who)>

    Nastavi popis volajiciho pro SQL komentare a logy.

=cut

sub setWhoCallingMe {
    my ($self, $who) = @_;
    $self->{'who_calling_me'} = $who;
}

=head2 B<[Public] setUniqueCheckValue(1|0)>

    Zapne/vypne kontrolu unikatnosti UNIQUE sloupcu pri flush (vypina se napr. pri validaci
    pres sdilenou entitu).

=cut

sub setUniqueCheckValue {
    my ($self, $value) = @_;
    $self->{'unique_check'} = ($value ? 1 : undef);
}

=head2 B<[Private] setRunDBMethod($value)>

    Ulozi nazev prave provedene DB operace (INSERT/UPDATE/DELETE) pro logit().

=cut

sub setRunDBMethod {
    my ($self, $value) = @_;
    $self->{'db_run_method'} = $value;
}

=head2 B<[Private] createInsertQuery($who)>

    Sestavi INSERT ze zmenenych sloupcu. Vraci ($query, \@bind), kde $query je cast za
    klicovym slovem INSERT ("INTO `t` (...) VALUES (...)"). Specialni hodnoty: 'NULL',
    undef a '' bez defaultu -> NULL; '' s defaultem -> default; 'NOW()', 'CURRENT_TIMESTAMP',
    'current_timestamp()' se vlozi jako SQL vyraz. Reference (hash/pole) zapsat nelze.

=cut

# NOTE: V pripade ze je potreba zapis ktery je obaleny SQL funkci, pak je treba takovou hodnotu projet selectem a vysled pak setnout do DAO objektu.
#	my $SQL = $DBI->select("db1","STR_TO_DATE(NOW(),'%Y-%m-%d')",[]);
#	my $date = $SQL->fetchrow_array();
#	$SQL->finish;
#	$DAO->datecolumn($date);
#	$DAO-flush;
#	$DAO-commit;
sub createInsertQuery {
    my ($self, $who) = @_;

    my $table = $self->getTableName();
    my $primv = $self->getPrimaryValue();
    my $primc = $self->getPrimaryColumnName();
    my $sqlst = $self->{'sql_string'};

    my (@set1, @set2);
    my $values = [];

    foreach my $method (@{$self->getChangeList()}) {

        my $value   = $self->getValue($method, "value");
        my $default = $self->getValue($method, "def");

        if (!ref($value)) {
            if ($value eq "NULL") {
                push(@set1, "$sqlst$method$sqlst");
                push(@set2, "NULL");
            } elsif (($value eq '') and (defined($default))) {
                push(@set1, "$sqlst$method$sqlst");
                push(@set2, $default);
            } elsif (!defined($value)) {
                push(@set1, "$sqlst$method$sqlst");
                push(@set2, "NULL");
            } elsif ($value eq '') {
                push(@set1, "$sqlst$method$sqlst");
                push(@set2, "NULL");
            } elsif ($value eq "NOW()") {
                push(@set1, "$sqlst$method$sqlst");
                push(@set2, "NOW()");
            } elsif ($value eq "CURRENT_TIMESTAMP") {
                push(@set1, "$sqlst$method$sqlst");
                push(@set2, "CURRENT_TIMESTAMP");
            } elsif ($value eq "current_timestamp()") {
                push(@set1, "$sqlst$method$sqlst");
                push(@set2, "current_timestamp()");
            } else {
                push(@set1,      "$sqlst$method$sqlst");
                push(@set2,      "?");
                push(@{$values}, $value);
            }
        } else {
            # TODO : DOPSAT PODPORU PRO ZAPIS BINARNICH DAT
            my $ref = ref($value);
            $LOG->error("TENTO TYP ref:'$ref' NENI DOPROGRAMOVAN PRO ZAPIS DO DOATABAZE. Metoda: createInsertQuery");
        }
    }

    my $query = "/* DAO:$table $who */ INTO $sqlst$table$sqlst (" . join(', ', @set1) . ") VALUES (" . join(', ', @set2) . ")";

    return $query, $values;
}

=head2 B<[Private] createUpdateQuery($who)>

    Sestavi UPDATE zmenenych sloupcu "WHERE pk = ?" (posledni bind hodnota je primarni klic).
    Stejna pravidla pro specialni hodnoty jako createInsertQuery.

=cut

sub createUpdateQuery {
    my ($self, $who) = @_;

    my $table = $self->getTableName();
    my $primv = $self->getPrimaryValue();
    my $primc = $self->getPrimaryColumnName();
    my $sqlst = $self->{'sql_string'};

    my @set;
    my $values = [];

    foreach my $method (@{$self->getChangeList()}) {

        my $value   = $self->getValue($method, "value");
        my $default = $self->getValue($method, "def");

        if (!ref($value)) {
            if ($value eq "NULL") {
                push(@set, "$sqlst$method$sqlst = NULL");
            } elsif (($value eq '') and (defined($default))) {
                push(@set,       "$sqlst$method$sqlst = ?");
                push(@{$values}, $default);
            } elsif ($value eq '') {
                push(@set, "$sqlst$method$sqlst = NULL");
            } elsif (!defined($value)) {
                push(@set, "$sqlst$method$sqlst = NULL");
            } elsif ($value eq "NOW()") {
                push(@set, "$sqlst$method$sqlst = NOW()");
            } elsif ($value eq "CURRENT_TIMESTAMP") {
                push(@set, "$sqlst$method$sqlst = CURRENT_TIMESTAMP");
            } elsif ($value eq "current_timestamp()") {
                push(@set, "$sqlst$method$sqlst = current_timestamp()");
            } else {
                push(@set,       "$sqlst$method$sqlst = ?");
                push(@{$values}, $value);
            }
        } else {

            # TODO : DOPSAT PODPORU PRO ZAPIS BINARNICH DAT
            my $ref = ref($value);
            $LOG->error("TENTO TYP ref:'$ref' NENI DOPROGRAMOVAN PRO ZAPIS DO DOATABAZE Metoda: createInsertQuery");
        }
    }

    push(@{$values}, $primv);
    my $query = "/* DAO:$table $who */ $sqlst$table$sqlst SET " . join(', ', @set) . " WHERE $sqlst$primc$sqlst = ?";

    return $query, $values;
}

=head2 B<[Private] createDeleteQuery($who)>

    Sestavi "FROM `t` WHERE `pk` = ?" s bind hodnotou primarniho klice.

=cut

sub createDeleteQuery {
    my ($self, $who) = @_;

    my $table  = $self->getTableName();
    my $primv  = $self->getPrimaryValue();
    my $primc  = $self->getPrimaryColumnName();
    my $sqlst  = $self->{'sql_string'};
    my $values = [];

    my $query = "/* DAO:$table $who */ FROM $sqlst$table$sqlst WHERE $sqlst$primc$sqlst = ?";
    push(@{$values}, $primv);

    return $query, $values;
}

=head2 B<[Private] CheckValue($column,$who,$value)>

    Validace hodnoty podle typu sloupce z DAO mapy pres Libs::Validate (is_sql_int, is_sql_tinyint,
    is_sql_varchar, is_sql_enum, is_sql_decimal, is_sql_boolen). NULL/''/undef se povoli podle
    COLUMN_NULLABLE a COLUMN_DEF. Reference zapsat nelze. Vraci 1 (OK) nebo 0 a zapise chybu
    do errorlistu. Ostatni typy (TEXT, TIMESTAMP, ...) se nevaliduji.

=cut

sub CheckValue {
    my ($self, $name, $who, $value) = @_;

    my $table  = $self->getTableName();
    my $def    = $self->getValue($name, "def");
    my $type   = $self->getValue($name, "type");
    my $size   = $self->getValue($name, "size");
    my $null   = $self->getValue($name, "null");
    my $unsig  = $self->getValue($name, "unsig");
    my $unique = $self->getValue($name, "unique");
    my $enumv  = $self->getValue($name, "enumv");

    my $dbdriver = $self->{'dbdriver'};

    # HASH, ARRAY DO DB ZAPSAT NEJDE
    if ((ref($value) eq "HASH") or (ref($value) eq "ARRAY")) {
        $LOG->sendErrorReport("DAO", $who, $table . $name, "Invalid write data to database. Array or Hash is not supported");
        $self->setErrorList("Invalid write data ARRAY OR HASH IS`NT SUPPORTED : (size:$size, unsig:$unsig, null:$null, unique:$unique), table:$table, column_name:$name, who:$who");
        return 0;
    }

    # ReadMe : http://programujte.com/?akce=clanek&cl=2007052903-prehled-datovych-typu-v-mysql
    # ReadMe : http://www.postgresql.org/docs/9.2/static/datatype.html
    if ((lc($type) eq "int") or (lc($type) eq "integer") or (lc($type) eq "int4")) {
        if (!defined($value) and $null == 1) {
            return 1;
        } elsif (($value eq '') and (defined($def))) {
            return 1;
        } elsif ($value eq '' and $null == 1) {
            return 1;
        } elsif ($value eq "NULL" and $null == 1) {
            return 1;
        } elsif (!defined($VALIDATE->is_sql_int($dbdriver, $value, $unsig))) {
            $self->setErrorList("Invalid write data : INT(size:$size, unsig:$unsig, null:$null, unique:$unique), table:$table, column_name:$name, value:$value, who:$who");
            return 0;
        }
    } elsif (lc($type) eq "tinyint") {
        if (!defined($value) and $null == 1) {
            return 1;
        } elsif (($value eq '') and (defined($def))) {
            return 1;
        } elsif ($value eq '' and $null == 1) {
            return 1;
        } elsif ($value eq "NULL" and $null == 1) {
            return 1;
        } elsif (!defined($VALIDATE->is_sql_tinyint($dbdriver, $value, $unsig))) {
            $self->setErrorList("Invalid write data : TINYINT(size:$size, unsig:$unsig, null:$null, unique:$unique), table:$table, column_name:$name, value:$value, who:$who");
            return 0;
        }
    } elsif ((lc($type) eq "varchar") or (lc($type) eq "character varying")) {
        if (!defined($value) and $null == 1) {
            return 1;
        } elsif (($value eq '') and (defined($def))) {
            return 1;
        } elsif ($value eq '' and $null == 1) {
            return 1;
        } elsif ($value eq "NULL" and $null == 1) {
            return 1;
        } elsif (!defined($VALIDATE->is_sql_varchar($dbdriver, $value, $size))) {
            $self->setErrorList("Invalid write data : VARCHAR(size:$size, null:$null), table:$table, column_name:$name, value:$value, who:$who");
            return 0;
        }
    } elsif (lc($type) eq "enum") {
        if (!defined($value) and $null == 1) {
            return 1;
        } elsif (($value eq '') and (defined($def))) {
            return 1;
        } elsif ($value eq '' and $null == 1) {
            return 1;
        } elsif ($value eq "NULL" and $null == 1) {
            return 1;
        } elsif (!defined($VALIDATE->is_sql_enum($dbdriver, $value, $enumv))) {
            $self->setErrorList("Invalid write data : ENUM(enum:@{$enumv}, null:$null), table:$table, column_name:$name, value:$value, who:$who");
            return 0;
        }
    } elsif ((lc($type) eq "decimal") or (lc($type) eq "numeric")) {
        if (!defined($value) and $null == 1) {
            return 1;
        } elsif (($value eq '') and (defined($def))) {
            return 1;
        } elsif ($value eq '' and $null == 1) {
            return 1;
        } elsif ($value eq "NULL" and $null == 1) {
            return 1;
        } elsif (!defined($VALIDATE->is_sql_decimal($dbdriver, $value, 65, 30, $unsig))) {
            $self->setErrorList("Invalid write data : " . uc($type) . "(unsign:$unsig, null:$null), table:$table, column_name:$name, value:$value, who:$who");
            return 0;
        }
    } elsif (lc($type) eq 'boolean') {
        if (!defined($VALIDATE->is_sql_boolen($dbdriver, $value))) {
            $self->setErrorList("Invalid write data : BOOLEN(unsign:$unsig, null:$null), table:$table, column_name:$name, value:$value, who:$who");
            return 0;
        }
    }

    return 1;
}

=head2 B<[Private] CheckUniqueValue($column,$who,$value)>

    Pokud je sloupec UNIQUE (nebo primarni) a kontrola zapnuta, overi SELECTem, ze hodnota
    v tabulce neni (pri UPDATE s vyjimkou vlastniho radku). Pri duplicite zapise chybu obsahujici
    text "invalid unique data" (podle nej existsUniqueError pozna duplicitu) a vrati 0.

=cut

sub CheckUniqueValue {
    my ($self, $name, $who, $value) = @_;

    my $table  = $self->getTableName();
    my $def    = $self->getValue($name, "def");
    my $type   = $self->getValue($name, "type");
    my $size   = $self->getValue($name, "size");
    my $null   = $self->getValue($name, "null");
    my $unsig  = $self->getValue($name, "unsig");
    my $unique = $self->getValue($name, "unique");
    my $enumv  = $self->getValue($name, "enumv");
    my $sqlst  = $self->{'sql_string'};

    return 1 unless ($self->getUniqueCheckValue());

    # CHECK FOR UNIQUE VALUE
    my $primv = $self->getPrimaryValue();
    my $primc = $self->getPrimaryColumnName();
    if ($unique and $primv) {

        # UPDATE
        my $SQL = $self->select("/* CHECK FOR UNIQUE VALUE */ 1 FROM $sqlst$table$sqlst WHERE $sqlst$name$sqlst = ? AND $sqlst$primc$sqlst != ?", [$value, $primv]);
        my $result = $SQL->fetchrow_array();
        $SQL->finish;
        if ($result) {

            # POZOR, HLASKU 'invalid unique data' v error zprave nikdy nemen !!!!
            $self->setErrorList("Update invalid unique data : INT(size:$size, unsig:$unsig, null:$null, unique:$unique), table:$table, column_name:$name, value:$value, who:$who prim:$primv");
            $LOG->error("Update invalid unique data : INT(size:$size, unsig:$unsig, null:$null, unique:$unique), table:$table, column_name:$name, value:$value, who:$who prim:$primv");
            return 0;
        }
    } elsif ($unique) {

        # INSERT
        my $SQL = $self->select("/* CHECK FOR UNIQUE VALUE */ 1 FROM $sqlst$table$sqlst WHERE $sqlst$name$sqlst = ?", [$value]);
        my $result = $SQL->fetchrow_array();
        $SQL->finish;
        if ($result) {

            # POZOR, HLASKU 'invalid unique data' v error zprave nikdy nemen !!!!
            $self->setErrorList("Insert invalid unique data : INT(size:$size, unsig:$unsig, null:$null, unique:$unique), table:$table, column_name:$name, value:$value, who:$who");
            $LOG->error("Insert invalid unique data : INT(size:$size, unsig:$unsig, null:$null, unique:$unique), table:$table, column_name:$name, value:$value, who:$who");
            return 0;
        }
    }
    return 1;
}

=head2 B<[Public] existsPublicMethodName($name)>

    Vraci 1/0 podle toho, zda tabulka ma sloupec $name (= existuje dynamicka metoda).

=cut

sub existsPublicMethodName {
    my ($self, $name) = @_;
    return ($self->DAO->{$name} ? 1 : 0);
}

=head2 B<[Private] existsInternalMethodName($name)>

    Vraci 1/0 podle toho, zda je $name interni metoda DAO (flush, error, ...). Takto se nesmi
    jmenovat zadny sloupec.

=cut

sub existsInternalMethodName {
    my ($self, $name) = @_;
    return (Class::Inspector->function_exists(__PACKAGE__, $name) ? 1 : 0);
}

=head2 B<[Public] existsUniqueError()>

    Vraci 1 pokud je v errorlistu chyba unikatnosti (duplicita), jinak 0.

=cut

sub existsUniqueError {
    my $self = shift;
    return 0 unless ($self->error);
    foreach my $msg (@{$self->getErrorList()}) {
        return 1 if ($msg =~ /.*invalid unique data.*/i);
    }
    return 0;
}

=head2 B<[Private] AUTOLOAD(...)>

    Dynamicke metody sloupcu: $DAO->sloupec() vraci hodnotu, $DAO->sloupec($v) hodnotu
    zvaliduje (CheckValue) a nastavi; pri neplatne hodnote vraci undef a zapise chybu.
    Neznamy sloupec zaloguje chybu a vraci undef.

=cut

sub AUTOLOAD {
    my $self = shift;
    my $name = $AUTOLOAD;
    $name =~ s/.*://;
    return if ($name =~ /^DESTROY$/);

    my $table = $self->getTableName();

    if ($self->existsPublicMethodName($name)) {
        if (@_) {
            my $who = $self->getWhoCallingMe();
            $who = ($who ? $who : sprintf("%s line %d", (caller)[1, 2]));
            if ($self->CheckValue($name, $who, @_)) {
                return $self->setValue($name, @_);
            } else {
                return undef;
            }
        } else {
            return $self->getValue($name, 'value');
        }
    } else {
        my $who = sprintf("%s:%d", (caller)[0, 2]);
        $LOG->error("Unknown column name:$name table:$table who:$who !");
        return undef;
    }
}

=head2 B<[Private] DESTROY()>

    Pri zaniku nesdileneho objektu uvolni zamek spojeni v poolu (setPoolLock(0)).

=cut

sub DESTROY {
    my $self = shift;

    # Po destroy se connection uvolni pro dalsi objekty.
    $self->DB->setPoolLock(0) unless ($self->{'is_share_dbpool'});
}

=head2 B<[Private] KOMODO()>

    Mrtvy kod pro IDE (Komodo/VS Code), aby umelo doplnit typy globalnich promennych.
    Nikdy se nevola - prvni prikaz je return.

=cut

# KOMODO-IDE/KOMODO-EDIT
sub KOMODO {
    return;
    require Libs::Log;
    $LOG = new Libs::Log;
}

1;
