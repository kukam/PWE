package Libs::MyDBI;

use strict;
use lib 'lib';
use Libs::MyDBI::DAO;

my ($CONF, $LOG, $VALIDATE);

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

=head2 B<[Public] createConnection($dbid,'dbidpool',$dbconf)>

    Metoda pripoji objekt databaze k $DB kontejneru (pool)
    
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
    } elsif ($self->getDbDriver($dbid) eq "oracle") {
        require Libs::MyDBI::DRIVER::Oracle;
        $self->DBC->{$dbid}->{$dbidpool} = new Libs::MyDBI::DRIVER::Oracle();
    } else {
        die "Unknown dbtype name ('" . $self->getDbDriver($dbid) . "')\n";
    }

    # CONNECT DB
    my $connect = $self->DBC->{$dbid}->{$dbidpool}->connect($dbconf);

    my $text = "Connect to $dbconf->{'dbdriver'} dbid:$dbid connect_status:$connect";

    ($connect ? $LOG->debug($text) : $LOG->error($text));

    $LOG->delay("connect_db", "Connected database " . $self->getDbDriver($dbid));

    return $connect;
}

=head2 B<[Public] reconnect($dbid)>

    Metoda provede reconnect databaze.

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
            sleep(1) if ($delay < 1);
            die "Unable reconnect to $dbid, poolid $dbidpool bye...\n" if ($trayconnect > (exists($dbconf->{'trayconnect'}) ? $dbconf->{'trayconnect'} : 0));
            ($self->ping($dbid, $dbidpool) ? last : next);

        }
    }
}

=head2 B<checkDbversion($dbid,$dbconf)>

    Metoda provede aktualizaci databaze.

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

    Metoda provede select v def. databazi.

=cut

sub select {
    my ($self, $dbid, $select, $value) = @_;
    my $line = sprintf("%s line %d", (caller)[1, 2]);
    $select = "/* DB:$dbid $line */ " . $select;
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

    Metoda provede insert v def. databazi.
    
=cut

sub insert {
    my ($self, $dbid, $insert, $value) = @_;
    my $line = sprintf("%s line %d", (caller)[1, 2]);
    $insert = " /* DB:$dbid $line */ " . $insert;
    $LOG->delay("insertdb");
    $self->DBC->{$dbid}->{'0'}->insert($insert, $value);
    $insert =~ s/\n/ /g;
    $LOG->info("INSERT $insert,[" . join(',', @{$value}) . "]") if (!$self->error($dbid));
    $LOG->error("INSERT $insert,[" . join(',', @{$value}) . "]") if ($self->error($dbid));
    $LOG->error($self->getErrorMsg($dbid)) if ($self->error($dbid));
    $LOG->delay("insertdb", "INSERT $insert");
}

=head2 B<[Public] update($dbid,$upadte,$value)>

    Metoda provede update v def. databazi.
    Metoda vraci pocet ovlivnenych radku.
    
=cut

sub update {
    my ($self, $dbid, $update, $value) = @_;
    my $line = sprintf("%s line %d", (caller)[1, 2]);
    $update = " /* DB:$dbid $line */ " . $update;
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

    Metoda provede delete v def. databazi.
    
=cut

sub delete {
    my ($self, $dbid, $remove, $value) = @_;
    my $line = sprintf("%s line %d", (caller)[1, 2]);
    $remove = "/* DB:$dbid $line */ " . $remove;
    $LOG->delay("deletedb");
    $self->DBC->{$dbid}->{'0'}->delete($remove, $value);
    $remove =~ s/\n/ /g;
    $LOG->info("DELETE $remove,[" . join(',', @{$value}) . "]") if (!$self->error($dbid));
    $LOG->error("DELETE $remove,[" . join(',', @{$value}) . "]") if ($self->error($dbid));
    $LOG->error($self->getErrorMsg($dbid)) if ($self->error($dbid));
    $LOG->delay("deletedb", "DELETE $remove");
}

=head2 B<[Public] command($dbid)>

    Metoda provede jakykoliv prikaz v db
    
=cut

sub command {
    my ($self, $dbid, $command) = @_;

    my $line = sprintf("%s line %d", (caller)[1, 2]);
    $command = "/* DB:$dbid $line */ " . $command;
    $LOG->delay("commanddb");
    $self->DBC->{$dbid}->{'0'}->command($command);
    $LOG->debug("COMMAND $command")        if (!$self->error($dbid));
    $LOG->error("COMMAND $command")        if ($self->error($dbid));
    $LOG->error($self->getErrorMsg($dbid)) if ($self->error($dbid));
    $LOG->delay("commanddb", "$command");

}

=head2 B<[Public] getDaoMetaData($dbid)>

    Metoda vraci hash ktery popisuje strukturu databaze i vlastnosti sloupcu a tabulek.
    
=cut

sub getDaoMetaData {
    my ($self, $dbid) = @_;
    $LOG->delay("getDaoMetaData");
    my $meta = $self->DBC->{$dbid}->{'0'}->getMetaData();
    $LOG->delay("getDaoMetaData", "Generating DAO MAP");
    return $meta;
}

=head2 B<[Public] getLastInsertID($dbid,$table)>

    Metoda vrati posledni insertnute ID.
    POZOR! : metoda musi byt volana u transakcnich spojeni PRED commitem.
    V opacnem pripade vraci vzdy hodnotu 0.
    =======================================
    
=cut

sub getLastInsertID {
    my ($self, $dbid, $table) = @_;
    return $self->DBC->{$dbid}->{'0'}->lastInsertID($table);
}

sub getDbDriver {
    my ($self, $dbid) = @_;
    return $self->{'dbdriver'}->{$dbid} if (exists($self->{'dbdriver'}->{$dbid}));
    return "unknown_dbid_dbdriver";
}

sub getDBIObject {
    my ($self, $dbid, $dbidpool) = @_;
    return {} unless (exists($self->{'DBC'}->{$dbid}));
    return {} unless (exists($self->{'DBC'}->{$dbid}->{$dbidpool}));
    return $self->{'DBC'}->{$dbid}->{$dbidpool};
}

=head2 B<[Public] ping($dbid,$dbidpool)>

    Metoda pingne DBC
    
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

=head2 B<[Public] commit()>

    Metoda provede commit
    
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

    Metoda provede rollback
    
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

    Metoda vraci error posledni akce. (hash)
    
=cut

sub getError {
    my ($self, $dbid) = @_;
    return $self->DBC->{$dbid}->{'0'}->getError();
}

=head2 B<[Public] getErrorMsg($dbid)>

    Metoda vraci error posledni akce. (text)
    
=cut

sub getErrorMsg {
    my ($self, $dbid) = @_;
    my $error   = $self->getError($dbid);
    my $status  = $error->{'err'};
    my $message = $error->{'errstr'};
    return "DB ERROR:$status, $message";
}

=head2 B<[Public] error($dbid)>

    Metoda vraci informaci o chybe 1/0 
    
=cut

sub error {
    my ($self, $dbid) = @_;
    return $self->DBC->{$dbid}->{'0'}->error();
}

=head2 B<[Public] disconnect()>

    Metoda odpoji objekt od DBC.
    
=cut

sub disconnect {
    my ($self, $dbid) = @_;
    foreach my $dbidpool (@{$self->getDbIdPoolList($dbid)}) {
        $self->DBC->{$dbid}->{$dbidpool}->disconnect;
    }
}

=head2 B<[Private] createDAO($dbid,$tname,$tvalue,$dispooler)>

    Metoda vraci DAO objekt.
    
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
        $LOG->error("Deny crareated DAO object. Unknown table type $ttype");
        next;
    }

    $LOG->delay("create_dao_$tname");
    my $DAO = new Libs::MyDBI::DAO($self->getDbDriver($dbid), $DBC, $LOG, $VALIDATE, $tname, $tvalue->{'TABLE_COLUMNS'}, $rewrite, $dispooler);
    $LOG->delay("create_dao_$tname", "Creating DAO $tname");
    return $DAO;
}

=head2 B<[Public] GetDAO($dbid,$table,$id|{ where = "column1 ? AND columne2,...", conds => [$val1,$val2,...]})>

    Metoda vraci objekt k tabulce
    
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
            $OBJ->refreshTABLE($opts->{'where'}, $opts->{'conds'});
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

sub getDbidList {
    my $self = shift;
    my $list = [];
    foreach my $dbid (keys %{$self->DBC}) {
        push(@{$list}, $dbid);
    }
    return $list;
}

sub getDbIdPoolList {
    my ($self, $dbid) = @_;
    my $list = [];
    foreach my $dbidpool (keys %{$self->DBC->{$dbid}}) {
        push(@{$list}, $dbidpool);
    }
    return $list;
}

sub getDAOList {
    my ($self, $dbid) = @_;
    my $result = [];
    foreach (keys %{$self->{'maps'}->{$dbid}}) { push(@{$result}, $_); }
    return $result;
}

sub existsDBC {
    my ($self, $dbid) = @_;
    return 0 unless ($self->DBC->{$dbid}->{'0'});
    return 1;
}

sub DBC {
    my $self = shift;
    return $self->{'DBC'};
}

sub testConnection {
    my $self = shift;
    $LOG->delay("test_connection_db_total");
    foreach my $dbid (@{$self->getDbidList()}) {
        foreach my $dbidpool (@{$self->getDbIdPoolList($dbid)}) {
            $self->reconnect($dbid) unless ($self->ping($dbid, $dbidpool));
        }
    }
    $LOG->delay("test_connection_db_total", "Test total connection finish");
}

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
