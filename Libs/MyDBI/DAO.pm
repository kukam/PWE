package Libs::MyDBI::DAO;

use strict;
use Class::Inspector;

my ($LOG, $VALIDATE);
our $AUTOLOAD;    # it's a package global

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

    Pokud nam staci standartni zaznam do logu, kde chceme jen napsat co jseme zmenili/pridali/smazali,
    muzeme pouzit v kodu tuto metodu, ktera log vygeneruje. Diky tomu nemusime slozite sestrojovat log zaznam.
    
    Usage:
    $OBJECT->flush;
    $OBJECT->logit; or $OBJECT->logit("new value");
    
    Output:
    "new value UPDATE DATA primary_column:primary_value column_name:column_value, column_name2:column_value2, ...."
    
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

    if (ref($data) eq "HASH") {
        while (my ($key, $value) = each(%{$data})) {

            # SETUJEME DATA A IGNORUJEME VOLBU REWRIRE. HODNOTU REWRITE KONTROLUJEME AZ PRI FLUSHI
            $self->setValue($key, $value);
            $self->setChangeList({});
            if ($key eq $prim) {
                $self->setPrimaryValue($value);
            }
        }
    } else {
        $LOG->warning("Couldn't load anything row who:$who (CREATE NEW EMPTY ROW) DAO:$table $who */ * FROM $table WHERE $where LIMIT 1, [@{$conds}]");
    }
}

=head2 B<[Public] select($select,$value)>

    Metoda provede select v def. databazi.

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

    Metoda provede insert v def. databazi.
    
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

=head2 B<[Public] update($upadte,$value)>

    Metoda provede update v def. databazi.
    Metoda vraci pocet ovlivnenych radku.
    
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

    Metoda provede delete v def. databazi.
    
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

sub commit {
    my $self = shift;
    $self->DB->commit();
    $LOG->debug("DB Commit " . $self->getTableName() . " " . ($self->getPrimaryValue ? $self->getPrimaryColumnName() . ":" . $self->getPrimaryValue() : "")) if(@{$self->getChangeList()} > 0);
}

sub rollback {
    my $self = shift;
    $self->DB->rollback();
    $self->clearAllMethod();
    $LOG->debug("DB Rollback " . $self->getTableName() . " " . ($self->getPrimaryValue ? $self->getPrimaryColumnName() . ":" . $self->getPrimaryValue() : ""));
}

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

# GETER/SETER
sub error {
    my $self = shift;
    return 1 if ($self->DB->error());
    return 1 if (@{$self->getErrorList()} > 0);
    return 0;
}

sub getError {
    my $self   = shift;
    my $table  = $self->getTableName();
    my $result = $self->DB->getError();
    $result->{$table} = $self->getErrorList;
    return $result;
}

sub DB {
    my $self = shift;
    return $self->{'DB'};
}

sub DAO {
    my $self = shift;
    return $self->{'DAO'};
}

sub getValue {
    my ($self, $name, $atribute_name) = @_;
    return $self->DAO->{$name}->{$atribute_name};
}

sub getChangeList {
    my $self   = shift;
    my $result = [];
    foreach my $method (keys %{$self->{'changelist'}}) { push(@{$result}, $method); }
    return $result;
}

sub getRewrite {
    my $self = shift;
    return $self->{'rewrite'};
}

sub getTableName {
    my $self = shift;
    return $self->{'tablenane'};
}

sub getMethodList {
    my $self = shift;
    return $self->{'methodlist'};
}

sub getErrorList {
    my $self   = shift;
    my $result = [];
    foreach my $msg (keys %{$self->{'errorlist'}}) { push(@{$result}, $msg); }
    return $result;
}

sub getPrimaryColumnName {
    my $self = shift;
    return $self->{'primarycolumn'};
}

sub getPrimaryValue {
    my $self = shift;
    return $self->{'primaryvalue'};
}

=head2 B<[Public] getLastInsertID()>

    Metoda vrati posledni insertnute ID.
    POZOR! : metoda musi byt volana v otevrene transakci, PRED commitem!
    V opacnem pripade vraci vzdy hodnotu 0.
    =======================================
    
=cut

sub getLastInsertID {
    my $self = shift;
    my $lid  = $self->DB->lastInsertID($self->getTableName());
    return ($lid ? $lid : undef);
}

sub getWhoCallingMe {
    my $self = shift;
    my $who  = $self->{'who_calling_me'};
    return $who;
}

sub getUniqueCheckValue {
    my $self = shift;
    return ($self->{'unique_check'} ? 1 : undef);
}

sub getRunDBMethod {
    my $self = shift;
    return $self->{'db_run_method'};
}

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

    Metoda vraci hash dat ktera jsou v objektu ulozena.
    Jedna se o mirror dat 1:1
    
    return { key => value, key2 => value, ... } 
    
=cut

sub getMirroredData {
    my $self = shift;
    my $mirror;
    foreach my $m (@{$self->getMethodList()}) {
        $mirror->{$m} = $self->getValue($m, 'value');
    }
    return $mirror;
}

sub setChangeList {
    my ($self, $value) = @_;
    if (ref($value) eq "HASH") {
        $self->{'changelist'} = $value;
    } else {
        $self->{'changelist'}->{$value} = 1;
    }
}

sub setErrorList {
    my ($self, $value) = @_;
    if (ref($value) eq "HASH") {
        $self->{'errorlist'} = $value;
    } else {
        $self->{'errorlist'}->{$value} = 1;
    }
}

sub setPrimaryColumnName {
    my ($self, $name) = @_;
    $self->{'primarycolumn'} = $name;
}

sub setPrimaryValue {
    my ($self, $value) = @_;
    $self->{'primaryvalue'} = $value;
    if (defined($self->getPrimaryColumnName())) {
        $self->setValue($self->getPrimaryColumnName(), $value);
    }
}

sub setWhoCallingMe {
    my ($self, $who) = @_;
    $self->{'who_calling_me'} = $who;
}

sub setUniqueCheckValue {
    my ($self, $value) = @_;
    $self->{'unique_check'} = ($value ? 1 : undef);
}

sub setRunDBMethod {
    my ($self, $value) = @_;
    $self->{'db_run_method'} = $value;
}

# NOTE: V pripade ze je potreba zapis ktery je obaleny SQL funkci, pak je treba takovou hodnotu projet select a vysled pak setnout do DAO objektu.
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
                push(@set2, "current_timestamp");
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
        } elsif (!defined($VALIDATE->is_tinyint($dbdriver, $value, $unsig))) {
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

sub existsPublicMethodName {
    my ($self, $name) = @_;
    return ($self->DAO->{$name} ? 1 : 0);
}

sub existsInternalMethodName {
    my ($self, $name) = @_;
    return (Class::Inspector->function_exists('Libs::DAO', $name) ? 1 : 0);
}

sub existsUniqueError {
    my $self = shift;
    return 0 unless ($self->error);
    foreach my $msg (@{$self->getErrorList()}) {
        return 1 if ($msg =~ /.*invalid unique data.*/i);
    }
    return 0;
}

sub existsError {
    my $self = shift;
    return $self->error;
}

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

sub DESTROY {
    my $self = shift;

    # Po destroy se connection uvolni pro dalsi objekty.
    $self->DB->setPoolLock(0) unless ($self->{'is_share_dbpool'});
}

# KOMODO-IDE/KOMODO-EDIT
sub KOMODO {
    return;
    require Libs::Log;
    $LOG = new Libs::Log;
}

1;
