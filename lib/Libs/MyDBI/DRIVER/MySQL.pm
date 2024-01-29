package Libs::MyDBI::DRIVER::MySQL;

use strict;
use DBI;

=head2 B<new()>
    Trace levels are as follows:

    0 - Trace disabled.
    1 - Trace DBI method calls returning with results or errors.
        2 - Trace method entry with parameters and returning with results.
        3 - As above, adding some high-level information from the driver
        and some internal information from the DBI.
    4 - As above, adding more detailed information from the driver.
    5 - and above - As above but with more and more obscure information.

    http://perltraining.com.au/talks/dbi-trick.pdf

    #######################################################################################################################################
    TODO : Docela zajimava buga/vlastnost? :)
    pokud nam pod apachem bezi vice nez dva fastcgi servry 
    a zaroven mame vyply autocommit, zacne se projeovat buga zrejme v DBI::MySQL drivru.
    Pri jakekoliv zmene (insert,update,delete) chvili trva (1-3s) nez ostatni spojeni se dozvi ze doslo ke zmene!
    Tudis se nam vraci stara data (zrejme nejaka cache). Obesel jsem to tak, ze selecty maji sve solo spojeni kde je autocommit vyply.
    #######################################################################################################################################

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
    };
    bless $self, $class;
    return $self;
}

=head2 B<connect($config)>

    Metoda provede connect do db.

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
    $self->{'logfile'} = ($config->{'logfile'} ? (($homepath !~ /^\//) ? "" : $homepath) . $config->{'logfile'} : $self->{'logfile'});
    $self->{'acommit'} = ($config->{'autocommit'} ? $config->{'autocommit'} : $self->{'acommit'});

    # CREATE CONNECTIONS
    my $dbi_r = DBI->connect("dbi:mysql:dbname=$self->{'database'};host=$self->{'host'};port=$self->{'port'}", $self->{'login'}, $self->{'password'}, {'RaiseError' => 0, 'PrintError' => 0, 'PrintWarn' => 0, 'AutoCommit' => 1, 'InactiveDestroy' => 1});

    my $dbi_w = DBI->connect("dbi:mysql:dbname=$self->{'database'};host=$self->{'host'};port=$self->{'port'}", $self->{'login'}, $self->{'password'}, {'RaiseError' => 0, 'PrintError' => 0, 'PrintWarn' => 0, 'AutoCommit' => $self->{'acommit'}, 'InactiveDestroy' => 1});

    if ($dbi_r and $dbi_w) {

        # INCLUDE DBIOBJECT
        $self->{'DBI_R'} = $dbi_r;
        $self->{'DBI_W'} = $dbi_w;

        # SET ENCODING
        $self->{'DBI_R'}->do("SET NAMES $self->{'encoding'}");
        $self->{'DBI_W'}->do("SET NAMES $self->{'encoding'}");

        # SET LOGING/DEBUGING
        $self->{'DBI_R'}->trace($self->{'loglevel'}, $self->{'logfile'});
        $self->{'DBI_W'}->trace($self->{'loglevel'}, $self->{'logfile'});

        return 1;
    }

    return 0;
}

=head2 B<reconnect()>

    Metoda provede reconect
    
=cut

sub reconnect {
    my $self = shift;
    $self->disconnect();
    $self->connect();
}

=head2 B<disconnect()>

    Metoda provede disconnect s databaze.

=cut

sub disconnect {
    my $self = shift;
    $self->{'DBI_R'}->disconnect;
    $self->{'DBI_W'}->disconnect;
}

=head2 B<select($select,@hodnoty)>

    Metoda provede pozadavany select, a vrati selectnuta data.

    my $select = $self->select($select,@hodnta);
    while (my($a,$b,$c) = $select->fetchrow());
    $select  - "* FROM tabulka where sloupec1 = ?"
    @hodnoty - ["hodnota"]
=cut

sub select {
    my $self   = shift;
    my $select = shift;
    my @values = (@{$_[0]});
    my $query  = $self->{'DBI_R'}->prepare("SELECT $select");
    $query->execute(@values);
    $self->setError($query);
    return $query;
}

=head2 B<insert($insert,@hodnoty)>

    Metoda provede pozadavany insert.
    $insert  - "INTO `tabulka` (`user`, `text`) VALUES (?, ?)"
    @hodnoty - ["hodnota1","hodnota2"]

=cut

sub insert {
    my $self   = shift;
    my $insert = shift;
    my @values = (@{$_[0]});
    my $query  = $self->{'DBI_W'}->prepare("INSERT $insert");
    $query->execute(@values);
    $self->setError($query);
    $query->finish();
}

=head2 B<update($update,@hodnoty)>

    Metoda provede pozadavany update a vrati pocet ovlivnenych radku
    $update  - "tabulka SET text = ? where id = ? and user = ?"
    @hodnoty - ["hodnota1","hodnota2","hodnotaN"]

=cut

sub update {
    my $self   = shift;
    my $update = shift;
    my @values = (@{$_[0]});
    my $query  = $self->{'DBI_W'}->prepare("UPDATE $update");
    my $rv     = $query->execute(@values);
    $self->setError($query);
    $query->finish();
    return $rv;
}

=head2 B<delete($delete,@hodnoty)>

    Metoda provede pozadavany delety v db.
    $delete  - "FROM tabulka where id = ? and user = ?"
    @hodnoty - ["hodnota1","hodnotaN"]

=cut

sub delete {
    my $self   = shift;
    my $delete = shift;
    my @values = (@{$_[0]});
    my $query  = $self->{'DBI_W'}->prepare("DELETE $delete");
    $query->execute(@values);
    $self->setError($query);
    $query->finish();
}

=head2 B<autoCommit()>

    Metoda provede zapnuti/vypnuti autocommitu

=cut

sub autoCommit {
    my ($self, $value) = @_;

    if ($value) {
        $self->{'DBI_W'}->{'AutoCommit'} = 1;
    } else {
        $self->{'DBI_W'}->{'AutoCommit'} = 0;
    }
}

=head2 B<commit()>

    Metoda provede commit.

=cut

sub commit {
    my $self = shift;
    $self->{'DBI_W'}->commit;
    $self->setError();
}

=head2 B<rollback()>

    Metoda provede rollback.
    
=cut

sub rollback {
    my $self = shift;
    $self->{'DBI_W'}->rollback;
    $self->setError();
}

=head2 B<command($command,@hodnoty)>

    Metoda provede jakykoliv prikaz v db.
    $command - "COKOLIV"

    metoda vraci strnig, v pripade ze je hodnat undef, tak doslo k chybe

=cut

sub command {
    my ($self, $command) = @_;
    my $result = $self->{'DBI_W'}->do($command);
    $self->setError();
    return $result;
}

=head2 B<lastInsertID()>

    Metoda vraci ID z posledniho insertu.
    POZOR! : metoda musi byt volana u transakcnich spojeni PRED commitem.
    V opacnem pripade vraci vzdy hodnotu 0.
    =======================================
=cut

sub lastInsertID {
    my ($self, $table) = @_;
    return $self->{'DBI_W'}->last_insert_id(undef, undef, $table, undef);
}

=head2 B<ping()>

    Metoda vraci informaci zdali existuje spojeni s db (1/0)

=cut

sub ping {
    my $self = shift;

    my $query1 = $self->{'DBI_R'}->prepare("SELECT 1");
    $query1->execute();
    my ($r1) = $query1->fetchrow_array();
    $query1->finish;

    my $query2 = $self->{'DBI_W'}->prepare("SELECT 1");
    $query2->execute();
    my ($r2) = $query2->fetchrow_array();
    $query2->finish;

    return 1 if ($r1 and $r2);
    return 0;
}

=head2 B<[Public] getMetaData()>

    Metoda vraci hash ktery popisuje strukturu databaze i vlastnosti sloupcu a tabulek.
    
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

=head2 B<getError()>

    Metoda vraci hlaseni o chybe predesle akce.

=cut

sub getError {
    my $self = shift;
    return {
        'err'    => $self->{'err'},
        'errstr' => $self->{'errstr'},
        'state'  => $self->{'state'}
    };
}

=head2 B<getPoolLock()>

    Metoda vraci infomraci o pool locku.

=cut

sub getPoolLock {
    my $self = shift;
    return $self->{'pool_is_lock'};
}

=head2 B<[Public] error($dbid)>

    Metoda vraci informaci o chybe 1/0 
    
=cut

sub error {
    my $self = shift;
    return 1 if (defined($self->{'err'}));
    return 0;
}

=head2 B<setError({} | undef)>

    Metoda zapise pripadne chyby do vlastniho logu.

=cut

sub setError {
    my ($self, $query) = @_;

    if ($query) {
        $self->{'err'}    = $query->err;
        $self->{'errstr'} = $query->errstr;
        $self->{'state'}  = $query->state;
    } elsif ($self->{'DBI_R'}->err) {
        $self->{'err'}    = $self->{'DBI_R'}->err;
        $self->{'errstr'} = $self->{'DBI_R'}->errstr;
        $self->{'state'}  = $self->{'DBI_R'}->state;
    } elsif ($self->{'DBI_W'}->err) {
        $self->{'err'}    = $self->{'DBI_W'}->err;
        $self->{'errstr'} = $self->{'DBI_W'}->errstr;
        $self->{'state'}  = $self->{'DBI_W'}->state;
    }
}

=head2 B<setPoolLock(1 | 0)>

    Metoda prepina pool lock do stavu 1/0

=cut

sub setPoolLock {
    my ($self, $value) = @_;

    if ($value) {
        $self->{'pool_is_lock'} = 1;
    } else {
        $self->{'pool_is_lock'} = 0;
    }
}

sub DESTROY {
    my $self = shift;
    $self->rollback;
}

1;
