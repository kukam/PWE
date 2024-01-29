package Libs::MyDBI::DRIVER::Postgre;

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
    
    POSTGRES DATA TYPE:
    http://www.tutorialspoint.com/postgresql/postgresql_data_types.htm

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
    $self->{'logfile'} = ($config->{'logfile'}    ? (($homepath !~ /^\//) ? $homepath : "") . $config->{'logfile'} : $self->{'logfile'});
    $self->{'schema'}  = ($config->{'schema'}     ? $config->{'schema'}                                            : $self->{'schema'});
    $self->{'acommit'} = ($config->{'autocommit'} ? $config->{'autocommit'}                                        : $self->{'acommit'});

    # CREATE CONNECTIONS
    my $dbi = DBI->connect(
        "dbi:Pg:dbname=$self->{'database'};host=$self->{'host'};port=$self->{'port'}",
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
    $self->{'DBI'}->disconnect;
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
    foreach (@values) { utf8::decode($_); }
    my $query = $self->{'DBI'}->prepare("SELECT $select");
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
    foreach (@values) { utf8::decode($_); }
    my $query = $self->{'DBI'}->prepare("INSERT $insert");
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
    foreach (@values) { utf8::decode($_); }
    my $query = $self->{'DBI'}->prepare("UPDATE $update");
    my $rv    = $query->execute(@values);
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
    foreach (@values) { utf8::decode($_); }
    my $query = $self->{'DBI'}->prepare("DELETE $delete");
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
        $self->{'DBI'}->{'AutoCommit'} = 1;
    } else {
        $self->{'DBI'}->{'AutoCommit'} = 0;
    }
}

=head2 B<commit()>

    Metoda provede commit.

=cut

sub commit {
    my $self = shift;
    $self->{'DBI'}->commit;
    $self->setError();
}

=head2 B<rollback()>

    Metoda provede rollback.
    
=cut

sub rollback {
    my $self = shift;
    $self->{'DBI'}->rollback;
    $self->setError();
}

=head2 B<command($command)>

    Metoda provede jakykoliv prikaz v db.
    $command - "COKOLIV"

    metoda vraci strnig, v pripade ze je hodnat undef, tak doslo k chybe

=cut

sub command {
    my ($self, $command) = @_;
    my $result = $self->{'DBI'}->do($command);
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
    return $self->{'DBI'}->last_insert_id(undef, undef, $table, undef);
}

=head2 B<ping()>

    Metoda vraci informaci zdali existuje spojeni s db (1/0)

=cut

sub ping {
    my $self = shift;

    return 1 if ($self->{'DBI'}->ping());
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
    } elsif ($self->{'DBI'}->err) {
        $self->{'err'}    = $self->{'DBI'}->err;
        $self->{'errstr'} = $self->{'DBI'}->errstr;
        $self->{'state'}  = $self->{'DBI'}->state;
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
