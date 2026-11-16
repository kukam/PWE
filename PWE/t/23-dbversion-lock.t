#!/usr/bin/env perl
# Libs::MyDBI::checkDbversion - zamek migrace databaze: zamek spojeni (sessionLock ovladace), prevzeti
# opusteneho zamku lockid, uvolneni zamku na vsech cestach ven, preruseni startu (requestStop).
# Bez skutecne databaze: falesna databaze v pameti (FakeDB) a falesna spojeni (FakeDrv) s rozhranim
# Libs::MyDBI::DRIVER::*.
#
# Regrese: kdyz proces skoncil uprostred migrace (SIGKILL, OOM, vymena podu), zustal v tabulce dbversion
# nastaveny lockid a kazdy dalsi start enginu cekal donekonecna ("Dbversion is locked by lockid:N").
#
# Regrese 2 (soubeh se starsi verzi enginu): proces se zamkem spojeni povazoval kazdy cizi lockid za
# opusteny a prevzal ho hned - i zamek ziveho procesu, ktery zamek spojeni nezna (starsi verze enginu,
# dbversion_session_lock => 0), a kroky migrace pak probehly dvakrat. Nove: proces se zamkem spojeni
# zapisuje lockid ZAPORNY, proces bez nej KLADNY; cizi zaporny se prebira hned, na cizi kladny se ceka,
# dokud se meni dvojice (dbversion, lockid), a prebira se az po dbversion_legacy_lock_wait sekundach
# beze zmeny (0 = nikdy).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PWE::TestEnv;
use File::Temp qw(tempdir);
use Time::HiRes ();

# ---------------------------------------------------------------------------
# Falesna databaze sdilena vsemi spojenimi: tabulka dbversion, provedene kroky, zamek spojeni.
# ---------------------------------------------------------------------------
package FakeDB;

sub new {
    my ($c, %a) = @_;
    return bless {
        table   => 0,                          # tabulka dbversion existuje
        hidden  => 0,                          # tabulka existuje, ale kontrola existence (information_schema) ji nevidi
        rows    => [],                         # potvrzene radky tabulky dbversion: [dbversion, lockid]
        created => 0,                          # kolikrat probehl CREATE TABLE dbversion
        steps   => [],                         # provedene kroky migrace (SQL) v poradi
        holder  => undef,                      # jmeno spojeni, ktere drzi zamek spojeni
        fail    => {},                         # SQL kroku => text chyby
        ops     => [],                         # vsechny operace vsech spojeni v poradi
        known   => {12345 => 1, 777 => 1, -12345 => 1, -777 => 1},    # cizi hodnoty lockid (ostatni nenulove = zamek testovaneho procesu)
        %a,
    }, $c;
}

# Hodnota lockid pro zaznam operaci: 0, NULL, znama cizi hodnota, nebo nahodne cislo testovaneho procesu:
# "M" kladne (proces bez zamku spojeni), "-M" zaporne (proces se zamkem spojeni).
sub tag {
    my ($s, $v) = @_;
    return 'NULL' unless (defined($v));
    return 0 if ($v == 0);
    return $v if ($s->{'known'}->{$v});
    return (($v < 0) ? '-M' : 'M');
}
sub op { push(@{$_[0]->{'ops'}}, $_[1]); }
sub count { my ($s, $re) = @_; return scalar(grep { $_ =~ $re } @{$s->{'ops'}}); }

package FakeSth;
sub new { my ($c, @rows) = @_; return bless {rows => [@rows]}, $c; }
sub fetchrow_array { my $r = shift(@{$_[0]->{'rows'}}); return ($r ? @{$r} : ()); }
sub finish { 1 }

# ---------------------------------------------------------------------------
# Falesne spojeni BEZ zamku spojeni (ovladac, ktery sessionLock/sessionUnlock nema).
# Zapisy do tabulky dbversion jsou transakcni (plati az po commit), CREATE TABLE a kroky migrace
# se provedou hned (DDL v MySQL/MariaDB) - prisnejsi z obou chovani.
# ---------------------------------------------------------------------------
package FakeDrvBase;

sub new {
    my ($c, $db, %a) = @_;
    return bless {db => $db, name => 'me', tx => [], err => undef, errstr => undef, reads => 0, polls => 0, on => {}, fail_sql => undef, %a}, $c;
}
sub ok { $_[0]->{'err'} = $_[0]->{'errstr'} = undef; }
sub bad { my ($s, $err, $str) = @_; $s->{'err'} = $err; $s->{'errstr'} = $str; }
sub error { return (defined($_[0]->{'err'}) ? 1 : 0); }
sub getError { return {err => $_[0]->{'err'}, errstr => $_[0]->{'errstr'}, state => undef}; }
sub setPoolLock { $_[0]->{'pool_lock'} = ($_[1] ? 1 : 0); }
sub getPoolLock { return $_[0]->{'pool_lock'}; }
sub disconnect { 1 }

# Vynucena chyba: fail_sql = regularni vyraz, kteremu odpovida text prikazu.
sub forced { my ($s, $sql) = @_; return ($s->{'fail_sql'} and ($sql =~ $s->{'fail_sql'})) ? 1 : 0; }

sub select {
    my ($s, $sql, $bind) = @_;
    my $db = $s->{'db'};
    $s->ok;
    if ($sql =~ /information_schema\.tables/) {
        $db->op('SELECT schema');
        return FakeSth->new(($db->{'table'} and !$db->{'hidden'}) ? ([1]) : ());
    }
    if ($sql =~ /dbversion,lockid FROM dbversion/) {
        $s->{'reads'}++;
        $s->{'on'}->{'read'}->($s, $s->{'reads'}) if ($s->{'on'}->{'read'});
        $db->op('SELECT dbversion');
        if ($s->forced($sql) or !$db->{'table'}) {
            $s->bad(1146, "Table 'testdb.dbversion' doesn't exist");
            return FakeSth->new();
        }
        return FakeSth->new(map { [@{$_}] } @{$db->{'rows'}});
    }
    die "FakeDrv: neocekavany SELECT: $sql";
}

sub insert {
    my ($s, $sql, $bind) = @_;
    my $db = $s->{'db'};
    $s->ok;
    die "FakeDrv: neocekavany INSERT: $sql" unless ($sql =~ /INTO dbversion \(dbversion,lockid\)/);
    $db->op("INSERT " . join(',', @{$bind}));
    return $s->bad(1142, "INSERT command denied") if ($s->forced($sql));
    my @row = @{$bind};
    push(@{$s->{'tx'}}, sub { push(@{$db->{'rows'}}, [@row]); });
    return;
}

sub update {
    my ($s, $sql, $bind) = @_;
    my $db = $s->{'db'};
    $s->ok;
    if ($sql =~ /dbversion SET lockid = \? WHERE lockid (= \?|IS NULL)(?: AND dbversion (= \?|IS NULL))?\s*$/) {
        my $null = ($1 eq 'IS NULL') ? 1 : 0;
        my $cas  = $2;                                # podminene prevzeti: jen kdyz sedi i verze
        my @b    = @{$bind};
        my $new  = shift(@b);
        my $old  = ($null ? undef : shift(@b));
        my $ver  = ((defined($cas) and ($cas eq '= ?')) ? shift(@b) : undef);
        die "FakeDrv: pocet bind hodnot neodpovida prikazu: $sql" if (@b);
        $s->{'on'}->{'takeover'}->($s) if (defined($cas) and $s->{'on'}->{'takeover'});
        $db->op("LOCKID " . $db->tag($old) . ">" . $db->tag($new) . (defined($cas) ? " IF VERSION " . (defined($ver) ? $ver : 'NULL') : ""));
        if ($s->forced($sql)) { $s->bad(1142, "UPDATE command denied"); return undef; }
        return "0E0" if ($s->{'lost_updates'});    # zapis, ktery se tise neprovede
        my @hit = grep { $null ? !defined($_->[1]) : (defined($_->[1]) and $_->[1] == $old) } @{$db->{'rows'}};
        @hit = grep { defined($ver) ? (defined($_->[0]) and $_->[0] == $ver) : !defined($_->[0]) } @hit if (defined($cas));
        push(@{$s->{'tx'}}, sub { $_->[1] = $new foreach (@hit); });
        return (scalar(@hit) || "0E0");
    }
    if ($sql =~ /dbversion SET dbversion = \?/) {
        $db->op("VERSION $bind->[0]");
        if ($s->forced($sql)) { $s->bad(1205, "Lock wait timeout exceeded"); return undef; }
        my $v = $bind->[0];
        push(@{$s->{'tx'}}, sub { $_->[0] = $v foreach (@{$db->{'rows'}}); });
        return (scalar(@{$db->{'rows'}}) || "0E0");
    }
    die "FakeDrv: neocekavany UPDATE: $sql";
}

sub command {
    my ($s, $sql) = @_;
    my $db = $s->{'db'};
    $s->ok;
    if ($sql =~ /CREATE TABLE dbversion/) {
        $db->op('CREATE');
        return $s->bad(1142, "CREATE command denied") if ($s->forced($sql));
        return $s->bad(1050, "Table 'dbversion' already exists") if ($db->{'table'});
        $db->{'table'} = 1;
        $db->{'created'}++;
        return 1;
    }
    (my $step = $sql) =~ s{^/\*.*?\*/\s*}{};
    $db->op($step);
    $s->{'on'}->{'step'}->($s, $step) if ($s->{'on'}->{'step'});
    return $s->bad(1064, $db->{'fail'}->{$step}) if (exists($db->{'fail'}->{$step}));
    push(@{$db->{'steps'}}, $step);
    return 1;
}

sub commit {
    my $s = shift;
    $s->ok;
    $s->{'db'}->op('COMMIT');
    $_->() foreach (@{$s->{'tx'}});
    $s->{'tx'} = [];
    return 1;
}

sub rollback {
    my $s = shift;
    $s->ok;
    $s->{'db'}->op('ROLLBACK');
    $s->{'tx'} = [];
    return 1;
}

# ---------------------------------------------------------------------------
# Falesne spojeni se zamkem spojeni (sessionLock/sessionUnlock jako ovladace MySQL a Postgre).
# ---------------------------------------------------------------------------
package FakeDrv;
our @ISA = ('FakeDrvBase');

sub sessionLock {
    my ($s, $name, $timeout) = @_;
    my $db = $s->{'db'};
    $s->ok;
    $s->{'polls'}++;
    $s->{'lock_args'} = [$name, $timeout];
    if ($s->{'lock_broken'}) {
        $db->op("LOCK $name = undef");
        $s->bad(1317, "Query execution was interrupted");
        return undef;
    }
    $s->{'on'}->{'lock'}->($s, $s->{'polls'}) if ($s->{'on'}->{'lock'});
    if (!defined($db->{'holder'}) or ($db->{'holder'} eq $s->{'name'})) {
        $db->{'holder'} = $s->{'name'};
        $db->op("LOCK $name");
        return 1;
    }
    $db->op("LOCK $name = 0");
    return 0;
}

sub sessionUnlock {
    my ($s, $name) = @_;
    my $db = $s->{'db'};
    $s->ok;
    $db->op("UNLOCK $name");
    return 0 if ($s->{'unlock_broken'});    # dotaz na uvolneni selze, zamek zustava drzeny
    return 0 unless (defined($db->{'holder'}) and ($db->{'holder'} eq $s->{'name'}));
    $db->{'holder'} = undef;
    return 1;
}

# Zanik spojeni: server uvolni zamek spojeni a zahodi nepotvrzenou transakci.
sub disconnect {
    my $s  = shift;
    my $db = $s->{'db'};
    $db->op('DISCONNECT');
    $db->{'holder'} = undef if (defined($db->{'holder'}) and ($db->{'holder'} eq $s->{'name'}));
    $s->{'tx'} = [];
    return 1;
}

sub reconnect {
    my $s = shift;
    $s->disconnect();
    $s->{'db'}->op('CONNECT');
    return ($s->{'reconnect_broken'} ? 0 : 1);
}

# ---------------------------------------------------------------------------
package MockLog;
sub new { my ($c, %a) = @_; return bless {error => [], warning => [], info => [], debug => [], delay => 2, level => 1, %a}, $c; }
sub error   { push(@{$_[0]->{'error'}},   $_[1]); }
sub warning { push(@{$_[0]->{'warning'}}, $_[1]); }
sub info    { push(@{$_[0]->{'info'}},    $_[1]); }
sub debug   { push(@{$_[0]->{'debug'}},   $_[1]); }
sub delay { return $_[0]->{'delay'}; }       # 2 = "pokus trval 2 s", konstruktor pak mezi pokusy neceka
sub getLogLevel { return $_[0]->{'level'}; }
sub find { my ($s, $level, $re) = @_; return grep { $_ =~ $re } @{$s->{$level}}; }

package MockConf;
sub new { my ($c, $h) = @_; return bless {%{$h || {}}}, $c; }
sub getValue {
    my ($s, $key, $subkey, $def) = @_;
    return $def unless (exists($s->{$key}));
    return $s->{$key} unless ($subkey);
    return (defined($s->{$key}->{$subkey}) ? $s->{$key}->{$subkey} : $def);
}

package main;

PWE::TestEnv::clean_env();
require Libs::MyDBI;

my $STOP = "Startup interrupted by termination request\n";
my $TMP  = tempdir(CLEANUP => 1);

sub write_steps {
    my ($name, $content) = @_;
    open(my $fh, '>', "$TMP/$name") or die "$TMP/$name: $!";
    print $fh $content;
    close($fh);
    return $name;
}
write_steps('steps.dbversion', qq|{ 1 => "STEP 1", 3 => "STEP 3", 2 => "STEP 2" }\n|);
write_steps('six.dbversion',   qq|{ 1 => "STEP 1", 2 => "STEP 2", 3 => "STEP 3", 4 => "STEP 4", 5 => "STEP 5", 6 => "STEP 6" }\n|);

sub dbconf { return {dbdriver => 'mysql', database => 'testdb', homepath => $TMP, dbversion_file => 'steps.dbversion', @_}; }

# Libs::MyDBI bez konfigurace databaze + podstrcene spojeni pool 0.
sub mydbi {
    my ($drv, %log) = @_;
    my $log = MockLog->new(%log);
    my $M   = Libs::MyDBI->new(MockConf->new({}), $log, undef);
    $M->{'DBC'}->{'db1'}      = {0 => $drv};
    $M->{'dbdriver'}->{'db1'} = 'mysql';
    return ($M, $log);
}

# Spusti checkDbversion s hlidacem: nekonecne cekani na zamek (puvodni chyba) nesmi zablokovat celou sadu.
# Vraci text chyby (die), nebo undef.
sub check {
    my ($M, $dbconf) = @_;
    my $err;
    local $SIG{ALRM} = sub { die "TIMEOUT: checkDbversion nedobehl do 10 s (nekonecne cekani na zamek?)\n" };
    alarm(10);
    eval { $M->checkDbversion('db1', $dbconf); 1 } or $err = $@;
    alarm(0);
    return $err;
}

# Starsi verze enginu (protokol puvodniho checkDbversion: jen sloupec lockid, zadny zamek spojeni) nad
# falesnou databazi - jeden pruchod jeji smycky. $me je jeji (kladne) cislo zamku, @steps cisla kroku.
# Vraci 'locked' (cizi nenulovy lockid: pockala by 1 s a zkusila to znovu), 'lock' (nastavila svuj zamek),
# 'step N' (provedla krok N a zapsala verzi), 'done' (neni co delat, svuj zamek uvolnila).
sub old_engine_pass {
    my ($db, $me, @steps) = @_;
    my ($dbversion, $lockid) = @{$db->{'rows'}->[0]};
    return 'locked' if (($lockid ne 0) and ($lockid ne $me));    # puvodni podminka vcetne retezcoveho porovnani
    foreach my $id (sort { $a <=> $b } @steps) {
        next if ($id <= $dbversion);
        if ($lockid == 0) {
            $db->{'rows'}->[0]->[1] = $me;
            return 'lock';
        }
        push(@{$db->{'steps'}}, "STEP $id");
        $db->{'rows'}->[0]->[0] = $id;
        return "step $id";
    }
    $db->{'rows'}->[0]->[1] = 0 if ($lockid eq $me);
    return 'done';
}

# Jeden scenar = cisty priznak ukonceni, cekani bez prodlev. Vyjimka ve scenari shodi jen tento scenar,
# ostatni se provedou (pri regresi je videt, co vsechno prestalo fungovat).
sub scenario {
    my ($name, $code) = @_;
    no warnings 'once';
    local $Libs::MyDBI::STOP_REQUESTED         = 0;
    local $Libs::MyDBI::DBVERSION_POLL         = 0;
    local $Libs::MyDBI::DBVERSION_LOG_INTERVAL = 30;
    local $Libs::MyDBI::DBVERSION_MAX_TRIES    = 20;
    local $Libs::MyDBI::DBVERSION_LEGACY_WAIT  = 300;
    local $Libs::MyDBI::DBVERSION_CLOCK        = undef;
    subtest(
        $name => sub {
            eval { $code->(); 1 } or fail("scenar skoncil vyjimkou: $@");
            alarm(0);
        }
    );
}

# --- requestStop / stopRequested ----------------------------------------------------------------------
scenario 'requestStop a stopRequested' => sub {
    ok(Libs::MyDBI->can('requestStop') && Libs::MyDBI->can('stopRequested'), 'funkce existuji (kontrakt s pwe.fcgi)');
    is(Libs::MyDBI::stopRequested(), 0, 'vychozi stav: 0');
    is(Libs::MyDBI::requestStop(),   1, 'requestStop() jako funkce vraci 1');
    is(Libs::MyDBI::stopRequested(), 1, 'stopRequested() = 1');
    $Libs::MyDBI::STOP_REQUESTED = 0;
    Libs::MyDBI->requestStop();
    is(Libs::MyDBI->stopRequested(), 1, 'volani jako metoda tridy');
    $Libs::MyDBI::STOP_REQUESTED = 0;
    my ($M) = mydbi(FakeDrv->new(FakeDB->new));
    $M->requestStop();
    is($M->stopRequested(), 1, 'volani na objektu');
};

# --- cista databaze -----------------------------------------------------------------------------------
scenario 'cista databaze: zamek spojeni, zalozeni tabulky, kroky ve spravnem poradi' => sub {
    my $db  = FakeDB->new;
    my $drv = FakeDrv->new($db);
    my ($M, $log) = mydbi($drv);
    is(check($M, dbconf()), undef, 'migrace dobehla bez chyby');
    is_deeply(
        $db->{'ops'},
        [
            'LOCK dbversion', 'ROLLBACK',                     # a) nejdriv zamek spojeni; konec transakce, ve ktere se o nej zadalo
            'SELECT schema', 'CREATE', 'COMMIT',              # b) tabulka az pod zamkem; radek se nevklada hned
            'SELECT dbversion', 'ROLLBACK',                   #    prazdna tabulka: poprve jen cekani (radek muze vkladat starsi verze enginu)
            'SELECT dbversion', 'INSERT 0,0', 'COMMIT',       #    porad bez radku: doplnime ho
            'SELECT dbversion', 'LOCKID 0>-M', 'COMMIT',      # d) zamek lockid kvuli starsim verzim enginu (zaporny = drzime zamek spojeni)
            'SELECT dbversion',                               # overeni, ze lockid je nas
            'STEP 1', 'VERSION 1', 'COMMIT',
            'STEP 2', 'VERSION 2', 'COMMIT',
            'STEP 3', 'VERSION 3', 'COMMIT',
            'LOCKID -M>0', 'COMMIT',
            'UNLOCK dbversion',
        ],
        'presne poradi operaci'
    );
    is_deeply($db->{'steps'}, ['STEP 1', 'STEP 2', 'STEP 3'], 'kroky vzestupne podle cisla verze');
    is_deeply($db->{'rows'}, [[3, 0]], 'jeden radek, verze 3, lockid 0');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');
    is_deeply($drv->{'lock_args'}, ['dbversion', 0], 'sessionLock dostava logicke jmeno zamku a DBVERSION_POLL');
    is(scalar(@{$log->{'error'}}), 0, 'zadny zaznam error') or diag(explain($log->{'error'}));
    is(scalar($log->find('debug', qr/tabulka dbversion \(dbid:db1\) zalozena, vkladam radek s verzi 0/)), 1, 'radek do vlastni nove tabulky: jen debug, zadna hlaska o nedokoncenem zalozeni');
    is(scalar($log->find('info', qr/^Dbversion update to id [123]$/)), 3, 'info o kazdem kroku');

    # druhy start nad touz databazi: nic k migraci
    @{$db->{'ops'}} = ();
    is(check($M, dbconf()), undef, 'druhy start bez chyby');
    is_deeply($db->{'ops'}, ['LOCK dbversion', 'ROLLBACK', 'SELECT schema', 'SELECT dbversion', 'UNLOCK dbversion'], 'nic k migraci: zadny zapis lockid, zadny krok, zadny commit');
    is_deeply($db->{'steps'}, ['STEP 1', 'STEP 2', 'STEP 3'], 'kroky se neopakuji');
};

scenario 'nic k migraci: zadny zapis do sloupce lockid' => sub {
    foreach my $version (3, 7) {
        my $db = FakeDB->new(table => 1, rows => [[$version, 0]]);
        my ($M, $log) = mydbi(FakeDrv->new($db));
        is(check($M, dbconf()), undef, "verze $version: bez chyby");
        is($db->count(qr/^(LOCKID|VERSION|INSERT|CREATE|COMMIT|STEP)/), 0, "verze $version: zadny zapis");
        is_deeply($db->{'rows'}, [[$version, 0]], "verze $version: radek beze zmeny");
        is($db->{'holder'}, undef, "verze $version: zamek spojeni uvolnen");
    }
    my $db = FakeDB->new(table => 1, rows => [[0, 0]]);
    write_steps('empty.dbversion', "{}\n");
    my ($M) = mydbi(FakeDrv->new($db));
    is(check($M, dbconf(dbversion_file => 'empty.dbversion')), undef, 'prazdny soubor migraci: bez chyby');
    is($db->count(qr/^(LOCKID|VERSION|COMMIT)/), 0, 'prazdny soubor migraci: zadny zapis');
};

# --- opusteny zamek lockid ----------------------------------------------------------------------------
scenario 'opusteny (zaporny) lockid se pod zamkem spojeni prevezme hned a migrace dobehne (regrese: nekonecne cekani)' => sub {
    my $db = FakeDB->new(table => 1, rows => [[1, -12345]]);
    my ($M, $log) = mydbi(FakeDrv->new($db));
    is(check($M, dbconf()), undef, 'start se zotavi sam');
    is_deeply(
        $db->{'ops'},
        [
            'LOCK dbversion', 'ROLLBACK', 'SELECT schema',
            'SELECT dbversion', 'LOCKID -12345>-M', 'COMMIT',    # c2) prevzeti hned: UPDATE ... WHERE lockid = <cizi>, commit
            'SELECT dbversion',
            'STEP 2', 'VERSION 2', 'COMMIT',
            'STEP 3', 'VERSION 3', 'COMMIT',
            'LOCKID -M>0', 'COMMIT',
            'UNLOCK dbversion',
        ],
        'prevzeti zamku a dokonceni migrace'
    );
    is_deeply($db->{'rows'}, [[3, 0]], 'verze 3, lockid skoncil 0');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');
    my @e = @{$log->{'error'}};
    is(scalar(@e), 1, 'jeden zaznam error o prevzeti') or diag(explain(\@e));
    like($e[0], qr/lockid:-12345 /,                'hlaska jmenuje cizi lockid');
    like($e[0], qr/opusteny/,                      'hlaska rika, ze zamek byl opusteny');
    like($e[0], qr/po verzi 1\) mohl zustat nedokonceny/, 'hlaska rika, ze posledni krok mohl zustat nedokonceny');
};

scenario 'opusteny lockid bez cekajicich kroku se jen uklidi' => sub {
    my $db = FakeDB->new(table => 1, rows => [[3, -12345]]);
    my ($M, $log) = mydbi(FakeDrv->new($db));
    is(check($M, dbconf()), undef, 'bez chyby');
    is_deeply($db->{'ops'}, ['LOCK dbversion', 'ROLLBACK', 'SELECT schema', 'SELECT dbversion', 'LOCKID -12345>-M', 'COMMIT', 'SELECT dbversion', 'LOCKID -M>0', 'COMMIT', 'UNLOCK dbversion'], 'prevzeti a uvolneni, zadny krok');
    is_deeply($db->{'rows'}, [[3, 0]], 'lockid 0 (starsi verze enginu uz necekaji)');
    is(scalar($log->find('error', qr/opusteny/)), 1, 'prevzeti zalogovano');
};

scenario 'lockid NULL (rucni zasah do tabulky) se pod zamkem spojeni prevezme' => sub {
    my $db = FakeDB->new(table => 1, rows => [[2, undef]]);
    my ($M, $log) = mydbi(FakeDrv->new($db));
    is(check($M, dbconf()), undef, 'bez chyby');
    is($db->{'ops'}->[4], 'LOCKID NULL>-M', 'prevzeti pres WHERE lockid IS NULL');
    is_deeply($db->{'rows'}, [[3, 0]], 'verze 3, lockid 0');
};

scenario 'po prevzeti opusteneho zamku selze hned prvni krok: hlaska upozorni na castecne provedeny krok' => sub {
    my $db = FakeDB->new(table => 1, rows => [[1, -12345]], fail => {'STEP 2' => "Table 'x' already exists"});
    my ($M, $log) = mydbi(FakeDrv->new($db));
    my $err = check($M, dbconf());
    like($err, qr/^Dbversion fail id:2 : DB ERROR:1064, Table 'x' already exists \n STEP 2\n/, 'puvodni text chyby zustava');
    like($err, qr/krok 2 mohl byt uz driv castecne proveden/, 'h) upozorneni na castecne provedeny krok');
    like($err, qr/DDL v MySQL\/MariaDB neni transakcni/,      'h) duvod');
    like($err, qr/Zkontroluj schema databaze rucne/,          'h) co s tim');
    like($err, qr/UPDATE dbversion SET dbversion = 2\n\z/,   'h) jak krok oznacit za hotovy');
    is_deeply($db->{'rows'}, [[1, 0]], 'verze beze zmeny, lockid uvolnen');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');
    is(scalar($log->find('error', qr/castecne proveden/)), 1, 'upozorneni je i v logu');

    # kdyz po prevzeti prvni krok projde a selze az dalsi, upozorneni se neprida
    $db = FakeDB->new(table => 1, rows => [[1, -12345]], fail => {'STEP 3' => "boom"});
    ($M, $log) = mydbi(FakeDrv->new($db));
    $err = check($M, dbconf());
    is($err, "Dbversion fail id:3 : DB ERROR:1064, boom \n STEP 3\n", 'dalsi krok: jen puvodni text chyby');
    is_deeply($db->{'rows'}, [[2, 0]], 'krok 2 zapsan, lockid uvolnen');
};

# --- zamek spojeni drzi jiny proces -------------------------------------------------------------------
scenario 'zamek spojeni drzi jiny proces: ceka a po uvolneni pokracuje' => sub {

    # jiny proces migraci dokonci -> nase kroky se neopakuji
    my $db  = FakeDB->new(table => 1, rows => [[1, -777]], holder => 'other');
    my $drv = FakeDrv->new($db);
    $drv->{'on'}->{'lock'} = sub {
        my ($s, $n) = @_;
        return unless ($n == 4);
        $db->{'rows'}   = [[3, 0]];
        $db->{'holder'} = undef;
    };
    my ($M, $log) = mydbi($drv);
    is(check($M, dbconf()), undef, 'bez chyby');
    is($drv->{'polls'}, 4, 'tri neuspesne pokusy o zamek, ctvrty uspesny');
    is($db->count(qr/^(STEP|LOCKID|VERSION)/), 0, 'migraci dokoncil jiny proces: zadny krok ani zapis');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');
    is(scalar($log->find('info', qr/migraci databaze dbid:db1 provadi jiny proces, cekam na zamek spojeni/)), 1, 'cekani zalogovano jen poprve (dalsi az po 30 s)');
    is(scalar(@{$log->{'error'}}), 0, 'cekani na zivy proces neni chyba') or diag(explain($log->{'error'}));

    # jiny proces skonci uprostred migrace (zamek spojeni uvolni server, lockid zustane) -> prevezmeme a dokoncime
    $db  = FakeDB->new(table => 1, rows => [[1, -777]], holder => 'other');
    $drv = FakeDrv->new($db);
    $drv->{'on'}->{'lock'} = sub { $db->{'holder'} = undef if ($_[1] == 3); };
    ($M, $log) = mydbi($drv);
    {
        local $Libs::MyDBI::DBVERSION_LOG_INTERVAL = 0;
        is(check($M, dbconf()), undef, 'bez chyby');
    }
    is($drv->{'polls'}, 3, 'dva neuspesne pokusy o zamek, treti uspesny');
    is_deeply($db->{'steps'}, ['STEP 2', 'STEP 3'], 'zbyle kroky provedeny');
    is_deeply($db->{'rows'}, [[3, 0]], 'verze 3, lockid 0');
    is($db->count(qr/^LOCKID -777>-M$/), 1, 'lockid mrtveho procesu prevzat');
    is(scalar($log->find('info',  qr/provadi jiny proces, cekam na zamek spojeni/)), 1, 'interval 0: prvni hlaska o cekani na urovni info');
    is(scalar($log->find('error', qr/provadi jiny proces, cekam na zamek spojeni/)), 1, 'interval 0: opakovana hlaska na urovni error (dlouhe cekani je videt i pri urovni logu 1)');
    is(scalar($log->find('error', qr/PgBouncer/)), 0, 'MySQL/MariaDB: bez napovedy o pooleru');

    # PostgreSQL: opakovana hlaska radi, co s zamkem, ktery zustal viset na serverovem spojeni pooleru
    # (transaction pooling) - cekani tam jinak vypada jako cizi migrace, i kdyz zadny proces nemigruje.
    my $dbp  = FakeDB->new(table => 1, rows => [[1, -777]], holder => 'other');
    my $drvp = FakeDrv->new($dbp);
    $drvp->{'on'}->{'lock'} = sub { $dbp->{'holder'} = undef if ($_[1] == 3); };
    my ($MP, $logp) = mydbi($drvp);
    {
        local $Libs::MyDBI::DBVERSION_LOG_INTERVAL = 0;
        is(check($MP, dbconf(dbdriver => 'postgres')), undef, 'postgres: bez chyby');
    }
    unlike(($logp->find('info', qr/cekam na zamek spojeni/))[0], qr/PgBouncer/, 'postgres: prvni hlaska (info) bez napovedy');
    like(($logp->find('error', qr/cekam na zamek spojeni/))[0], qr/zamek mohl zustat na serverovem spojeni pooleru \(PgBouncer, transaction pooling\) .* nastav dbi\.db1\.dbversion_session_lock => 0/, 'postgres: opakovana hlaska (error) radi vypnout zamek spojeni za poolerem');

    # chyba cteni behem cekani: rollback (PostgreSQL by jinak dalsi prikazy odmital) a ceka se dal
    my $db2  = FakeDB->new(table => 1, rows => [[1, -777]], holder => 'other');
    my $drv2 = FakeDrv->new($db2, fail_sql => qr/FROM dbversion/);
    $drv2->{'on'}->{'lock'} = sub { if ($_[1] == 3) { $db2->{'holder'} = undef; $_[0]->{'fail_sql'} = undef; } };
    my ($M2) = mydbi($drv2);
    is(check($M2, dbconf()), undef, 'chyba cteni behem cekani: po uvolneni zamku bez chyby');
    is_deeply([@{$db2->{'ops'}}[0 .. 3]], ['LOCK dbversion = 0', 'SELECT schema', 'SELECT dbversion', 'ROLLBACK'], 'po chybe cteni rollback');
    is($drv2->{'polls'}, 3, 'ceka se dal');
    is_deeply($db2->{'rows'}, [[3, 0]], 'migrace dobehla');

    # zamek se nezacne brat driv, nez ho ziskame: zadny zapis behem cekani
    my @before = grep { $_ !~ /^(LOCK|SELECT)/ } @{$db->{'ops'}}[0 .. 5];
    is(scalar(@before), 0, 'behem cekani na zamek spojeni se jen cte');
};

scenario 'zamek spojeni drzi jiny proces a pro nas neni co migrovat: necekame' => sub {
    my $db  = FakeDB->new(table => 1, rows => [[3, -777]], holder => 'other');
    my $drv = FakeDrv->new($db);
    my ($M, $log) = mydbi($drv);
    is(check($M, dbconf()), undef, 'bez chyby');
    is($drv->{'polls'}, 1, 'jediny pokus o zamek');
    is_deeply($db->{'ops'}, ['LOCK dbversion = 0', 'SELECT schema', 'SELECT dbversion'], 'jen cteni: zadny zapis, zadne uvolnovani ciziho zamku');
    is($db->{'holder'}, 'other', 'zamek zustava jinemu procesu');
    is_deeply($db->{'rows'}, [[3, -777]], 'lockid ziveho procesu se neprebira');
};

# Regrese: proces, ktery cekal na zamek spojeni, cetl po jeho ziskani ze stareho snimku transakce (cele
# cekani bezelo v jedne transakci; PostgreSQL s izolaci REPEATABLE READ) a start skoncil chybou
# "could not serialize access" s matouci hlaskou o opustenem zamku.
scenario 'po cekani na zamek spojeni se transakce cekani ukonci (rollback pred ctenim pod zamkem)' => sub {
    my $db  = FakeDB->new(table => 1, rows => [[1, -777]], holder => 'other');
    my $drv = FakeDrv->new($db);
    $drv->{'on'}->{'lock'} = sub { if ($_[1] == 3) { $db->{'rows'} = [[3, 0]]; $db->{'holder'} = undef; } };
    my ($M, $log) = mydbi($drv);
    is(check($M, dbconf()), undef, 'bez chyby');
    is_deeply(
        $db->{'ops'},
        [
            'LOCK dbversion = 0', 'SELECT schema', 'SELECT dbversion',    # cekani: jen cteni
            'LOCK dbversion = 0', 'SELECT schema', 'SELECT dbversion',
            'LOCK dbversion', 'ROLLBACK',                                 # zamek ziskan: konec transakce, ve ktere se cekalo
            'SELECT schema', 'SELECT dbversion',                          # cteni pod zamkem uz v nove transakci
            'UNLOCK dbversion',
        ],
        'vypnuty autocommit: po ziskani zamku rollback, teprve pak cteni tabulky'
    );
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');

    # zapnuty autocommit: zadna transakce cekani neni
    $db  = FakeDB->new(table => 1, rows => [[1, -777]], holder => 'other');
    $drv = FakeDrv->new($db);
    $drv->{'on'}->{'lock'} = sub { if ($_[1] == 2) { $db->{'rows'} = [[3, 0]]; $db->{'holder'} = undef; } };
    ($M) = mydbi($drv);
    is(check($M, dbconf(autocommit => 1)), undef, 'zapnuty autocommit: bez chyby');
    is($db->count(qr/^ROLLBACK$/), 0, 'zapnuty autocommit: zadny rollback');

    # Regrese (PostgreSQL, REPEATABLE READ): zamek ziskany uz prvnim volanim sessionLock - ovladac v nem ale mohl
    # cekat az DBVERSION_POLL sekund a transakce (snimek) zacala jeho prvnim pokusem. Bez rollbacku cetl proces
    # stav z doby pred uvolnenim zamku a start skoncil chybou "could not serialize access due to concurrent update".
    $db = FakeDB->new(table => 1, rows => [[3, 0]]);
    ($M) = mydbi(FakeDrv->new($db));
    is(check($M, dbconf()), undef, 'zamek na prvni volani: bez chyby');
    is_deeply($db->{'ops'}, ['LOCK dbversion', 'ROLLBACK', 'SELECT schema', 'SELECT dbversion', 'UNLOCK dbversion'], 'zamek na prvni volani: i tak rollback pred prvnim ctenim pod zamkem');

    # zapnuty autocommit a zamek na prvni volani: zadny rollback
    $db = FakeDB->new(table => 1, rows => [[3, 0]]);
    ($M) = mydbi(FakeDrv->new($db));
    is(check($M, dbconf(autocommit => 1)), undef, 'zamek na prvni volani, autocommit: bez chyby');
    is($db->count(qr/^ROLLBACK$/), 0, 'zamek na prvni volani, autocommit: zadny rollback');
};

# Proces, ktery nema co migrovat, na cizi migraci neceka - s vyjimkou procesu, ktery si po migraci nacte
# strukturu tabulek z databaze (dao zapnute, daomap_file neexistuje): ten by si jinak nacetl schema
# rozpracovane vicekrokove migrace a zustal s nim do restartu (starsi verze enginu cekala vzdy).
scenario 'zamek spojeni drzi jiny proces, neni co migrovat, ale mapa DAO se cte z databaze: ceka' => sub {
    my $db  = FakeDB->new(table => 1, rows => [[3, -777]], holder => 'other');
    my $drv = FakeDrv->new($db);
    $drv->{'on'}->{'lock'} = sub { if ($_[1] == 4) { $db->{'rows'} = [[5, 0]]; $db->{'holder'} = undef; } };
    my ($M, $log) = mydbi($drv);
    is(check($M, dbconf(dao => 1, daomap_file => 'neexistuje_daomap.dump')), undef, 'bez chyby');
    is($drv->{'polls'}, 4, 'tri neuspesne pokusy o zamek, ctvrty uspesny (ceka na konec cizi migrace)');
    is($db->count(qr/^(STEP|LOCKID|VERSION|INSERT|CREATE|COMMIT)/), 0, 'jen cekani: zadny krok ani zapis');
    is_deeply($db->{'rows'}, [[5, 0]], 'tabulka beze zmeny');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');
    my @info = $log->find('info', qr/provadi jiny proces, cekam na zamek spojeni/);
    is(scalar(@info), 1, 'cekani zalogovano');
    like($info[0], qr/pro tento proces neni co migrovat, cekam kvuli nacteni struktury tabulek \(dao\)/, 'hlaska rika, proc se ceka');

    # dao zapnute bez klice daomap_file: mapa se cte z databaze -> ceka
    $db  = FakeDB->new(table => 1, rows => [[3, -777]], holder => 'other');
    $drv = FakeDrv->new($db);
    $drv->{'on'}->{'lock'} = sub { $db->{'holder'} = undef if ($_[1] == 2); };
    ($M) = mydbi($drv);
    is(check($M, dbconf(dao => 1)), undef, 'dao bez daomap_file: bez chyby');
    is($drv->{'polls'}, 2, 'dao bez daomap_file: ceka');

    # mapa DAO ze souboru: struktura tabulek se z databaze necte -> neceka
    open(my $fh, '>', "$TMP/daomap.dump") or die "$TMP/daomap.dump: $!";
    print $fh "{}\n";
    close($fh);
    $db  = FakeDB->new(table => 1, rows => [[3, -777]], holder => 'other');
    $drv = FakeDrv->new($db);
    ($M) = mydbi($drv);
    is(check($M, dbconf(dao => 1, homepath => "$TMP/", daomap_file => 'daomap.dump')), undef, 'mapa DAO ze souboru: bez chyby');
    is($drv->{'polls'}, 1, 'mapa DAO ze souboru: neceka');
    is($db->{'holder'}, 'other', 'mapa DAO ze souboru: zamek zustava jinemu procesu');

    # dao vypnute: neceka (jako scenar vyse)
    $db  = FakeDB->new(table => 1, rows => [[3, -777]], holder => 'other');
    $drv = FakeDrv->new($db);
    ($M) = mydbi($drv);
    is(check($M, dbconf(dao => 0, daomap_file => 'neexistuje_daomap.dump')), undef, 'dao vypnute: bez chyby');
    is($drv->{'polls'}, 1, 'dao vypnute: neceka');

    is(Libs::MyDBI->dbversionDaoFromDb({dao => 1, homepath => "$TMP/", daomap_file => 'daomap.dump'}), 0, 'dbversionDaoFromDb: soubor mapy existuje -> 0');
    is(Libs::MyDBI->dbversionDaoFromDb({dao => 1, homepath => "$TMP/", daomap_file => 'jiny.dump'}),   1, 'dbversionDaoFromDb: soubor mapy neexistuje -> 1');
    is(Libs::MyDBI->dbversionDaoFromDb({dao => 1, homepath => "$TMP/"}),                               1, 'dbversionDaoFromDb: bez klice daomap_file -> 1');
    is(Libs::MyDBI->dbversionDaoFromDb({homepath => "$TMP/", daomap_file => 'jiny.dump'}),            0, 'dbversionDaoFromDb: dao vypnute -> 0');

    # Cesta k souboru mapy je stejna jako v konstruktoru: homepath . daomap_file BEZ pridaneho lomitka (pwe.home
    # konci lomitkem). S homepath bez lomitka konstruktor soubor "$TMP/daomap.dump" nenajde a mapu cte z databaze.
    is(Libs::MyDBI->dbversionDaoFromDb({dao => 1, homepath => $TMP, daomap_file => 'daomap.dump'}),  1, 'dbversionDaoFromDb: homepath bez lomitka na konci - soubor se (jako v konstruktoru) nenajde -> 1');
    is(Libs::MyDBI->dbversionDaoFromDb({dao => 1, homepath => $TMP, daomap_file => '/daomap.dump'}), 0, 'dbversionDaoFromDb: homepath bez lomitka + daomap_file s lomitkem -> soubor nalezen -> 0');
};

scenario 'zadost o ukonceni behem cekani na zamek spojeni' => sub {
    my $db  = FakeDB->new(table => 1, rows => [[1, -777]], holder => 'other');
    my $drv = FakeDrv->new($db);
    $drv->{'on'}->{'lock'} = sub { Libs::MyDBI::requestStop() if ($_[1] == 2); };
    my ($M) = mydbi($drv);
    is(check($M, dbconf()), $STOP, 'die podle kontraktu');
    is($drv->{'polls'}, 2, 'po zadosti uz zadny dalsi pokus o zamek');
    is($db->count(qr/^(STEP|LOCKID|VERSION|UNLOCK|COMMIT)/), 0, 'zadny zapis, cizi zamek se neuvolnuje');
    is($db->{'holder'}, 'other', 'zamek zustava jinemu procesu');

    # priznak nastaveny uz pred migraci: zamek se ani nezkousi
    $db  = FakeDB->new;
    $drv = FakeDrv->new($db);
    ($M) = mydbi($drv);
    is(check($M, dbconf()), $STOP, 'priznak nastaveny predem: die podle kontraktu');
    is_deeply($db->{'ops'}, [], 'zadna operace nad databazi');
};

# --- chyba kroku ----------------------------------------------------------------------------------------
scenario 'chyba kroku: rollback, oba zamky uvolnene, die s textem' => sub {
    my $db = FakeDB->new(table => 1, rows => [[1, 0]], fail => {'STEP 2' => 'You have an error in your SQL syntax'});
    my ($M, $log) = mydbi(FakeDrv->new($db));
    my $err = check($M, dbconf());
    is($err, "Dbversion fail id:2 : DB ERROR:1064, You have an error in your SQL syntax \n STEP 2\n", 'text chyby jako driv, bez upozorneni na prevzaty zamek');
    is_deeply(
        $db->{'ops'},
        ['LOCK dbversion', 'ROLLBACK', 'SELECT schema', 'SELECT dbversion', 'LOCKID 0>-M', 'COMMIT', 'SELECT dbversion', 'STEP 2', 'ROLLBACK', 'LOCKID -M>0', 'COMMIT', 'UNLOCK dbversion'],
        'rollback, uvolneni lockid, commit, uvolneni zamku spojeni'
    );
    is_deeply($db->{'steps'}, [], 'dalsi krok se nespustil');
    is_deeply($db->{'rows'}, [[1, 0]], 'verze beze zmeny, lockid 0');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');
    is(scalar($log->find('error', qr/^STEP 2$/)), 1, 'chybny prikaz je v logu');
};

scenario 'zapis verze po kroku selze: dalsi krok se nespusti' => sub {
    my $db  = FakeDB->new(table => 1, rows => [[1, 0]]);
    my $drv = FakeDrv->new($db, fail_sql => qr/SET dbversion = /);
    my ($M) = mydbi($drv);
    my $err = check($M, dbconf());
    like($err, qr/^Dbversion fail id:2 : krok probehl, ale jeho verzi se nepodarilo zapsat do tabulky dbversion: DB ERROR:1205, Lock wait timeout exceeded\n/, 'die s vysvetlenim');
    like($err, qr/UPDATE dbversion SET dbversion = 2/, 'rada, jak verzi zapsat rucne');
    is_deeply($db->{'steps'}, ['STEP 2'], 'krok 3 se nespustil');
    is($db->{'rows'}->[0]->[1], 0, 'lockid uvolnen');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');
};

scenario 'zamek spojeni nejde uvolnit dotazem: spojeni se zavre, aby zamek nezustal bezicimu procesu' => sub {

    # uspesna migrace: spojeni pool 0 se zavre a otevre znovu
    my $db = FakeDB->new(table => 1, rows => [[2, 0]]);
    my ($M, $log) = mydbi(FakeDrv->new($db, unlock_broken => 1));
    is(check($M, dbconf()), undef, 'migrace bez chyby');
    is_deeply([@{$db->{'ops'}}[-5 .. -1]], ['LOCKID -M>0', 'COMMIT', 'UNLOCK dbversion', 'DISCONNECT', 'CONNECT'], 'po neuspesnem uvolneni: odpojeni a nove pripojeni');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen (zanikem spojeni)');
    is_deeply($db->{'rows'}, [[3, 0]], 'verze 3, lockid 0');
    is(scalar($log->find('error', qr/zamek spojeni \(dbid:db1\) se nepodarilo uvolnit dotazem/)), 1, 'zalogovano');
    is(scalar($log->find('error', qr/PgBouncer/)), 0, 'MySQL/MariaDB: bez napovedy o pooleru');

    # PostgreSQL: za poolerem v rezimu transaction pooling zavreni spojeni zamek neuvolni - hlaska to rika
    $db = FakeDB->new(table => 1, rows => [[2, 0]]);
    ($M, $log) = mydbi(FakeDrv->new($db, unlock_broken => 1));
    is(check($M, dbconf(dbdriver => 'postgres')), undef, 'postgres: migrace bez chyby');
    like(($log->find('error', qr/se nepodarilo uvolnit dotazem/))[0], qr/za poolerem v rezimu transaction pooling \(PgBouncer\), zamek zustava na serverovem spojeni poolu.* nastav dbi\.db1\.dbversion_session_lock => 0/, 'postgres: hlaska upozornuje na pooler a radi vypnout zamek spojeni');

    # nove pripojeni se nepodari: start skonci chybou (pool 0 by nefungoval)
    $db = FakeDB->new(table => 1, rows => [[3, 0]]);
    ($M) = mydbi(FakeDrv->new($db, unlock_broken => 1, reconnect_broken => 1));
    is(check($M, dbconf()), "Dbversion: spojeni pool 0 (dbid:db1) se po uvolneni zamku migrace nepodarilo znovu pripojit\n", 'die');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');

    # chyba kroku: plati puvodni chyba, spojeni se jen zavre
    $db = FakeDB->new(table => 1, rows => [[1, 0]], fail => {'STEP 2' => 'boom'});
    ($M) = mydbi(FakeDrv->new($db, unlock_broken => 1));
    is(check($M, dbconf()), "Dbversion fail id:2 : DB ERROR:1064, boom \n STEP 2\n", 'die s puvodni chybou kroku');
    is_deeply([@{$db->{'ops'}}[-5 .. -1]], ['ROLLBACK', 'LOCKID -M>0', 'COMMIT', 'UNLOCK dbversion', 'DISCONNECT'], 'odpojeni bez noveho pripojeni');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');
    is_deeply($db->{'rows'}, [[1, 0]], 'lockid uvolnen');
};

# --- preruseni mezi kroky ---------------------------------------------------------------------------------
scenario 'stopRequested mezi kroky: rozbehnuty krok se dokonci a zapise, dalsi se nespusti' => sub {
    my $db  = FakeDB->new;
    my $drv = FakeDrv->new($db);
    $drv->{'on'}->{'step'} = sub { Libs::MyDBI::requestStop() if ($_[1] eq 'STEP 2'); };    # SIGTERM uprostred kroku 2
    my ($M, $log) = mydbi($drv);
    is(check($M, dbconf()), $STOP, 'die podle kontraktu');
    is_deeply($db->{'steps'}, ['STEP 1', 'STEP 2'], 'krok 2 dobehl, krok 3 se nespustil');
    is_deeply($db->{'rows'}, [[2, 0]], 'verze 2 zapsana (commit), lockid uvolnen');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');
    my @tail = @{$db->{'ops'}}[-6 .. -1];
    is_deeply(\@tail, ['STEP 2', 'VERSION 2', 'COMMIT', 'LOCKID -M>0', 'COMMIT', 'UNLOCK dbversion'], 'po dokoncenem kroku jen uklid (bez rollbacku)');
    is(scalar($log->find('info', qr/prerusena zadosti o ukonceni \(dokoncene kroky: 2\)/)), 1, 'preruseni zalogovano');

    # dalsi start (bez priznaku) migraci dokonci
    $Libs::MyDBI::STOP_REQUESTED = 0;
    $drv->{'on'} = {};
    is(check($M, dbconf()), undef, 'dalsi start bez chyby');
    is_deeply($db->{'steps'}, ['STEP 1', 'STEP 2', 'STEP 3'], 'zbyly krok proveden prave jednou');
    is_deeply($db->{'rows'}, [[3, 0]], 'verze 3');
};

# --- rezim bez zamku spojeni = puvodni chovani -----------------------------------------------------------
my %NOLOCK = (
    'vypnuty (dbversion_session_lock => 0)' => sub { return (FakeDrv->new($_[0]),     dbconf(dbversion_session_lock => 0)); },
    'ovladac ho nepodporuje'                 => sub { return (FakeDrvBase->new($_[0]), dbconf()); },
    'ovladac vrati undef'                    => sub { return (FakeDrv->new($_[0], lock_broken => 1), dbconf()); },
);
foreach my $mode (sort keys %NOLOCK) {
    scenario "bez zamku spojeni - $mode: puvodni chovani" => sub {

        # cista databaze
        my $db = FakeDB->new;
        my ($drv, $dbconf) = $NOLOCK{$mode}->($db);
        my ($M, $log) = mydbi($drv);
        is(check($M, $dbconf), undef, 'cista databaze: bez chyby');
        my @ops = grep { $_ ne 'LOCK dbversion = undef' } @{$db->{'ops'}};
        is_deeply(
            \@ops,
            [
                'SELECT schema', 'CREATE', 'INSERT 0,0', 'COMMIT',
                'SELECT dbversion', 'LOCKID 0>M', 'COMMIT', 'SELECT dbversion',
                'STEP 1', 'VERSION 1', 'COMMIT', 'STEP 2', 'VERSION 2', 'COMMIT', 'STEP 3', 'VERSION 3', 'COMMIT',
                'LOCKID M>0', 'COMMIT',
            ],
            'stejne operace jako puvodni verze, zadne uvolnovani zamku spojeni'
        );
        is($db->count(qr/^LOCK dbversion( = 0)?$/), 0, 'zamek spojeni se neziskava');
        is_deeply($db->{'rows'}, [[3, 0]], 'verze 3, lockid 0');
        if ($mode =~ /undef/) {
            is(scalar($log->find('error', qr/zamek spojeni neni k dispozici \(dbid:db1, DB ERROR:1317, Query execution was interrupted\)/)), 1, 'chyba zamku spojeni je v logu');
        } else {
            is(scalar(@{$log->{'error'}}), 0, 'zadny zaznam error') or diag(explain($log->{'error'}));
        }

        # Cizi lockid - kladny (proces bez zamku spojeni, starsi verze enginu) i zaporny (proces se zamkem
        # spojeni): bez zamku spojeni se jen ceka jako driv, zamek se NIKDY neprebira - ani kdyz se tabulka
        # dlouho nemeni (hodiny pro dbversion_legacy_lock_wait tu bezi o 100000 s na kazde cteni).
        foreach my $foreign (12345, -12345) {
            my $T = 0;
            local $Libs::MyDBI::DBVERSION_CLOCK = sub { return $T; };
            my $tick = sub { $T += 100000; };

            # ceka (neprebira), po uvolneni pokracuje
            $db = FakeDB->new(table => 1, rows => [[1, $foreign]]);
            ($drv, $dbconf) = $NOLOCK{$mode}->($db);
            $drv->{'on'}->{'read'} = sub { $tick->(); $db->{'rows'}->[0]->[1] = 0 if ($_[1] == 4); };    # jiny proces zamek uvolni
            ($M, $log) = mydbi($drv);
            is(check($M, $dbconf), undef, "cizi lockid $foreign: po uvolneni bez chyby");
            is($db->count(qr/^LOCKID \Q$foreign\E>/), 0, "cizi lockid $foreign se bez zamku spojeni NEPREBIRA");
            is($drv->{'reads'}, 5, "cizi lockid $foreign: tri cekani, pak ziskani zamku a overeni");
            is_deeply($db->{'steps'}, ['STEP 2', 'STEP 3'], "cizi lockid $foreign: po uvolneni zamku migrace dobehla");
            is_deeply($db->{'rows'}, [[3, 0]], "cizi lockid $foreign: verze 3, lockid 0");
            is($db->count(qr/^LOCKID 0>M$/), 1, "cizi lockid $foreign: vlastni zamek je kladny");
            my @locked = $log->find('error', qr/^Dbversion is locked by lockid:\Q$foreign\E /);
            is(scalar(@locked), 1, "cizi lockid $foreign: hlaska o cekani jen poprve (ne kazdou sekundu)");
            like($locked[0], qr/uvolni ho rucne: UPDATE dbversion SET lockid = 0/, "cizi lockid $foreign: hlaska radi, jak zamek rucne uvolnit");

            # hlaska se opakuje po uplynuti intervalu
            $db = FakeDB->new(table => 1, rows => [[1, $foreign]]);
            ($drv, $dbconf) = $NOLOCK{$mode}->($db);
            $drv->{'on'}->{'read'} = sub { $tick->(); $db->{'rows'}->[0]->[1] = 0 if ($_[1] == 4); };
            ($M, $log) = mydbi($drv);
            {
                local $Libs::MyDBI::DBVERSION_LOG_INTERVAL = 0;
                is(check($M, $dbconf), undef, "cizi lockid $foreign, interval 0: bez chyby");
            }
            is(scalar($log->find('error', qr/^Dbversion is locked by lockid:\Q$foreign\E /)), 3, "cizi lockid $foreign, interval 0: hlaska pri kazdem cekani");

            # nic k migraci a cizi lockid: ceka jako driv
            $db = FakeDB->new(table => 1, rows => [[3, $foreign]]);
            ($drv, $dbconf) = $NOLOCK{$mode}->($db);
            $drv->{'on'}->{'read'} = sub { $tick->(); $db->{'rows'}->[0]->[1] = 0 if ($_[1] == 3); };
            ($M, $log) = mydbi($drv);
            is(check($M, $dbconf), undef, "nic k migraci + cizi lockid $foreign: po uvolneni bez chyby");
            is($drv->{'reads'}, 3, "cizi lockid $foreign: ceka se i bez cekajicich kroku");
            is($db->count(qr/^(LOCKID|VERSION|STEP)/), 0, "cizi lockid $foreign: zadny zapis");

            # zadost o ukonceni behem cekani na cizi lockid
            $db = FakeDB->new(table => 1, rows => [[1, $foreign]]);
            ($drv, $dbconf) = $NOLOCK{$mode}->($db);
            $drv->{'on'}->{'read'} = sub { $tick->(); Libs::MyDBI::requestStop() if ($_[1] == 3); };
            ($M, $log) = mydbi($drv);
            is(check($M, $dbconf), $STOP, "cizi lockid $foreign, zadost o ukonceni behem cekani: die podle kontraktu");
            is($drv->{'reads'}, 3, "cizi lockid $foreign: po zadosti se uz neceka");
            is_deeply($db->{'rows'}, [[1, $foreign]], "cizi lockid $foreign beze zmeny");
            is($db->count(qr/^(LOCKID|VERSION|STEP|ROLLBACK)/), 0, "cizi lockid $foreign: zadny zapis");
            $Libs::MyDBI::STOP_REQUESTED = 0;
        }

        # priznak nastaveny pred migraci: zamek lockid se uz nezapisuje
        $db = FakeDB->new(table => 1, rows => [[1, 0]]);
        ($drv, $dbconf) = $NOLOCK{$mode}->($db);
        ($M, $log) = mydbi($drv);
        Libs::MyDBI::requestStop();
        is(check($M, $dbconf), $STOP, 'priznak nastaveny predem: die podle kontraktu');
        is($db->count(qr/^(LOCKID|VERSION|STEP|COMMIT)/), 0, 'priznak nastaveny predem: zadny zapis (ani zamek lockid)');
        $Libs::MyDBI::STOP_REQUESTED = 0;

        # chyba kroku: rollback a uvolneni lockid
        $db = FakeDB->new(table => 1, rows => [[1, 0]], fail => {'STEP 2' => 'boom'});
        ($drv, $dbconf) = $NOLOCK{$mode}->($db);
        ($M, $log) = mydbi($drv);
        is(check($M, $dbconf), "Dbversion fail id:2 : DB ERROR:1064, boom \n STEP 2\n", 'chyba kroku: stejny text jako driv');
        @ops = grep { $_ ne 'LOCK dbversion = undef' } @{$db->{'ops'}};
        is_deeply([@ops[-4 .. -1]], ['STEP 2', 'ROLLBACK', 'LOCKID M>0', 'COMMIT'], 'rollback, uvolneni lockid, commit');
        is_deeply($db->{'rows'}, [[1, 0]], 'lockid uvolnen');
    };
}

# --- cizi KLADNY lockid = proces bez zamku spojeni (starsi verze enginu) ----------------------------------
# Regrese 2: proces se zamkem spojeni prevzal kazdy cizi lockid hned, i zamek zive starsi verze enginu,
# a kroky migrace pak probehly dvakrat. Cas pro dbversion_legacy_lock_wait dodava test (DBVERSION_CLOCK),
# nikde se skutecne neceka.
scenario 'znamenko lockid: proces se zamkem spojeni zapisuje zaporne cislo, proces bez nej kladne' => sub {
    my %make = ('se zamkem spojeni' => sub { return (FakeDrv->new($_[0]), dbconf()); }, %NOLOCK);
    foreach my $mode (sort keys %make) {
        my (%ids, $changed, $errors);
        foreach my $run (1 .. 25) {
            my $db = FakeDB->new(table => 1, rows => [[0, 0]]);
            my ($drv, $dbconf) = $make{$mode}->($db);
            my @seen;
            $drv->{'on'}->{'step'} = sub { push(@seen, $db->{'rows'}->[0]->[1]); };
            my ($M) = mydbi($drv);
            $errors++ if (defined(check($M, $dbconf)) or (scalar(@seen) != 3) or ($db->{'rows'}->[0]->[1] != 0));
            $changed++ if (grep { $_ != $seen[0] } @seen);
            $ids{$seen[0]} = 1;
        }
        ok(!$errors,  "$mode: 25 migraci bez chyby, zamek nakonec uvolnen");
        ok(!$changed, "$mode: po celou migraci stejne cislo zamku");
        cmp_ok(scalar(keys %ids), '>', 1, "$mode: cislo zamku je nahodne");
        if ($mode eq 'se zamkem spojeni') {
            ok((!grep { $_ !~ /^-\d+$/ or $_ > -1 or $_ < -999999999 } keys %ids), "$mode: lockid je ZAPORNY (-999999999 .. -1)") or diag(explain([keys %ids]));
        } else {
            ok((!grep { $_ !~ /^\d+$/ or $_ < 1 or $_ > 999999999 } keys %ids), "$mode: lockid je KLADNY (1 .. 999999999) jako u starsich verzi enginu") or diag(explain([keys %ids]));
        }
    }
};

scenario 'cizi kladny lockid: dokud se meni verze, neprebira se (starsi verze enginu migruje) a kroky neprobehnou dvakrat' => sub {
    my $T = 0;
    local $Libs::MyDBI::DBVERSION_CLOCK = sub { return $T; };

    # starsi verze enginu drzi zamek 12345 a ma hotovy krok 1; kazdy dalsi krok ji trva 100 s
    my $db  = FakeDB->new(table => 1, rows => [[1, 12345]]);
    my $drv = FakeDrv->new($db);
    my @old;
    $drv->{'on'}->{'read'} = sub {
        my ($s, $n) = @_;
        return if ($n == 1);
        $T += 50;                                                             # mezi ctenimi ubehne 50 s, doba prevzeti je 60 s
        push(@old, old_engine_pass($db, 12345, 1 .. 6)) unless ($n % 2);      # kazde druhe cteni: dalsi krok je hotovy
    };
    my ($M, $log) = mydbi($drv);
    is(check($M, dbconf(dbversion_file => 'six.dbversion', dbversion_legacy_lock_wait => 60)), undef, 'bez chyby');
    is($T, 450, 'cekalo se 450 s - mnohem dele nez dbversion_legacy_lock_wait (60 s)');
    is_deeply(\@old, ['step 2', 'step 3', 'step 4', 'step 5', 'step 6'], 'starsi verze enginu mezitim provedla kroky 2-6');
    is($db->count(qr/^(LOCKID|VERSION|STEP|COMMIT|INSERT)/), 0, 'novy proces nic nezapsal: zadne prevzeti zamku, zadny krok');
    is($db->count(qr/^ROLLBACK$/), 10, 'po ziskani zamku spojeni a po kazdem cteni behem cekani konci cteci transakce (cekani nedrzi otevrenou transakci)');
    is_deeply($db->{'steps'}, ['STEP 2', 'STEP 3', 'STEP 4', 'STEP 5', 'STEP 6'], 'kazdy krok probehl prave jednou');
    is_deeply($db->{'rows'}, [[6, 12345]], 'zamek zive starsi verze enginu zustal nedotceny');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');
    is(scalar(@{$log->{'error'}}), 0, 'cekani na zivy proces neni chyba') or diag(explain($log->{'error'}));
    my @wait = $log->find('info', qr/nastavil proces bez zamku spojeni - migraci zrejme provadi starsi verze enginu/);
    is(scalar(@wait), 9, 'cekani zalogovano poprve a pak po kazdych >= 30 s (tady pri kazdem cteni)');
    like($wait[0], qr/lockid:12345 v tabulce dbversion \(dbid:db1\)/,                                    'hlaska jmenuje zamek a databazi');
    like($wait[0], qr/\(verze 1, cekam 0 s\); .* prevezmu ho za 60 s \(dbi\.db1\.dbversion_legacy_lock_wait => 60\)/, 'hlaska rika, za jak dlouho se zamek prevezme');
    like($wait[1], qr/\(verze 2, cekam 50 s\); .* prevezmu ho za 60 s/, 'po zmene verze bezi doba znovu od nuly');
    like($wait[2], qr/\(verze 2, cekam 100 s\); .* prevezmu ho za 10 s/, 'beze zmeny se zbyvajici doba krati');
    is(scalar($log->find('info', qr/pro tento proces neni co migrovat \(verze 6\), necekam a zamek ponechavam/)), 1, 'kdyz uz neni co migrovat, neceka se ani na uvolneni ciziho zamku');
    is(old_engine_pass($db, 12345, 1 .. 6), 'done', 'starsi verze enginu dokonci migraci bez zasahu');
    is_deeply($db->{'rows'}, [[6, 0]], 'a svuj zamek uvolni sama');

    # starsi verze enginu zna jen kroky 1-4: po jejim skonceni novy proces dokonci zbytek
    $T   = 0;
    @old = ();
    $db  = FakeDB->new(table => 1, rows => [[1, 12345]]);
    $drv = FakeDrv->new($db);
    $drv->{'on'}->{'read'} = sub {
        my ($s, $n) = @_;
        return if ($n == 1);
        $T += 50;
        push(@old, old_engine_pass($db, 12345, 1 .. 4)) unless ($n % 2);
    };
    ($M, $log) = mydbi($drv);
    is(check($M, dbconf(dbversion_file => 'six.dbversion', dbversion_legacy_lock_wait => 60)), undef, 'starsi verze s mene kroky: bez chyby');
    is_deeply(\@old, ['step 2', 'step 3', 'step 4', 'done'], 'starsi verze enginu provedla sve kroky a zamek uvolnila');
    is_deeply($db->{'steps'}, ['STEP 2', 'STEP 3', 'STEP 4', 'STEP 5', 'STEP 6'], 'zbyle kroky provedl novy proces, kazdy krok prave jednou');
    is($db->count(qr/IF VERSION/), 0, 'zadne prevzeti zamku');
    is($db->count(qr/^LOCKID 0>-M$/), 1, 'po uvolneni si novy proces zamek vzal obvyklou cestou');
    is_deeply($db->{'rows'}, [[6, 0]], 'verze 6, lockid 0');
    is(scalar(@{$log->{'error'}}), 0, 'zadny zaznam error') or diag(explain($log->{'error'}));
};

scenario 'cizi kladny lockid beze zmeny se prevezme az po dbversion_legacy_lock_wait' => sub {
    my $T = 1000;
    local $Libs::MyDBI::DBVERSION_CLOCK = sub { return $T; };

    # starsi verze enginu skoncila uprostred kroku 2 (SIGKILL): verze 1, zamek 12345, nic se nemeni
    my $db  = FakeDB->new(table => 1, rows => [[1, 12345]]);
    my $drv = FakeDrv->new($db);
    $drv->{'on'}->{'read'} = sub { $T += 10 if ($_[1] > 1); };
    my ($M, $log) = mydbi($drv);
    is(check($M, dbconf(dbversion_legacy_lock_wait => 60)), undef, 'start se zotavi sam');
    is_deeply(
        $db->{'ops'},
        [
            'LOCK dbversion', 'ROLLBACK', 'SELECT schema',
            ('SELECT dbversion', 'ROLLBACK') x 7,                   # 0, 10, ... 60 s beze zmeny; po cteni konec cteci transakce
            'LOCKID 12345>-M IF VERSION 1', 'COMMIT',               # c1) prevzeti podminene verzi
            'SELECT dbversion',
            'STEP 2', 'VERSION 2', 'COMMIT',
            'STEP 3', 'VERSION 3', 'COMMIT',
            'LOCKID -M>0', 'COMMIT',
            'UNLOCK dbversion',
        ],
        'do 60 s jen cteni, pak podminene prevzeti a dokonceni migrace'
    );
    is_deeply($db->{'rows'}, [[3, 0]], 'verze 3, lockid 0');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');
    my @wait = $log->find('info', qr/migraci zrejme provadi starsi verze enginu/);
    is(scalar(@wait), 2, 'cekani zalogovano poprve a po 30 s');
    like($wait[0], qr/prevezmu ho za 60 s/, 'prvni hlaska: zbyva 60 s');
    like($wait[1], qr/cekam 30 s\); .* prevezmu ho za 30 s/, 'druha hlaska: zbyva 30 s');
    my @e = @{$log->{'error'}};
    is(scalar(@e), 1, 'jeden zaznam error o prevzeti') or diag(explain(\@e));
    like($e[0], qr/zamek lockid:12345 v tabulce dbversion \(dbid:db1\) se 60 s nezmenil \(verze 1, dbi\.db1\.dbversion_legacy_lock_wait => 60\)/, 'hlaska: ktery zamek, jak dlouho, nastavena doba');
    like($e[0], qr/proces bez zamku spojeni, ktery ho nastavil \(zrejme starsi verze enginu\), uz nejspis nebezi/, 'hlaska: proc se prebira');
    like($e[0], qr/Prebiram ho; posledni krok migrace \(po verzi 1\) mohl zustat nedokonceny/, 'hlaska: posledni krok mohl zustat nedokonceny');

    # po prevzeti selze hned prvni krok: stejne upozorneni jako u zaporneho zamku
    $T   = 1000;
    $db  = FakeDB->new(table => 1, rows => [[1, 12345]], fail => {'STEP 2' => "Table 'x' already exists"});
    $drv = FakeDrv->new($db);
    $drv->{'on'}->{'read'} = sub { $T += 10 if ($_[1] > 1); };
    ($M, $log) = mydbi($drv);
    my $err = check($M, dbconf(dbversion_legacy_lock_wait => 60));
    like($err, qr/^Dbversion fail id:2 : /, 'prvni krok po prevzeti selze: die');
    like($err, qr/krok 2 mohl byt uz driv castecne proveden/, 'upozorneni na castecne provedeny krok');
    is_deeply($db->{'rows'}, [[1, 0]], 'verze beze zmeny, prevzaty zamek uvolnen');

    # vychozi doba 300 s (klic v konfiguraci chybi)
    $T   = 0;
    $db  = FakeDB->new(table => 1, rows => [[1, 12345]]);
    $drv = FakeDrv->new($db);
    $drv->{'on'}->{'read'} = sub { $T += 100 if ($_[1] > 1); };
    ($M, $log) = mydbi($drv);
    is(check($M, dbconf()), undef, 'vychozi doba: bez chyby');
    is($drv->{'reads'}, 5, 'vychozi doba: v 0, 100 a 200 s se ceka, ve 300 s prevzeti (+ overeni zamku)');
    is($db->count(qr/^LOCKID 12345>-M IF VERSION 1$/), 1, 'vychozi doba: jedno prevzeti');
    like(($log->find('info', qr/starsi verze enginu/))[0], qr/prevezmu ho za 300 s \(dbi\.db1\.dbversion_legacy_lock_wait => 300\)/, 'vychozi doba je 300 s');
    like($log->{'error'}->[0], qr/se 300 s nezmenil/, 'vychozi doba: prevzeti po 300 s');

    # neplatna hodnota: vychozi doba a zaznam error (preklep nesmi znamenat okamzite prevzeti)
    foreach my $bad ('abc', -5, '') {
        $T   = 0;
        $db  = FakeDB->new(table => 1, rows => [[1, 12345]]);
        $drv = FakeDrv->new($db);
        $drv->{'on'}->{'read'} = sub { $T += 100 if ($_[1] > 1); };
        ($M, $log) = mydbi($drv);
        is(check($M, dbconf(dbversion_legacy_lock_wait => $bad)), undef, "neplatna hodnota '$bad': bez chyby");
        is($drv->{'reads'}, 5, "neplatna hodnota '$bad': plati vychozi doba 300 s");
        is(scalar($log->find('error', qr/dbi\.db1\.dbversion_legacy_lock_wait => '\Q$bad\E' neni nezaporne cislo .* pouzivam vychozi 300/)), 1, "neplatna hodnota '$bad': zalogovana jednou");
    }

    # zapnuty autocommit: zadna transakce k ukonceni, tedy zadny rollback (DBI by na nej jen varovalo)
    $T   = 1000;
    $db  = FakeDB->new(table => 1, rows => [[1, 12345]]);
    $drv = FakeDrv->new($db);
    $drv->{'on'}->{'read'} = sub { $T += 10 if ($_[1] > 1); };
    ($M, $log) = mydbi($drv);
    is(check($M, dbconf(dbversion_legacy_lock_wait => 60, autocommit => 1)), undef, 'autocommit: bez chyby');
    is($db->count(qr/^ROLLBACK$/), 0, 'autocommit: behem cekani zadny rollback');
    is($db->count(qr/^LOCKID 12345>-M IF VERSION 1$/), 1, 'autocommit: zamek prevzat po uplynuti doby');
    is_deeply($db->{'rows'}, [[3, 0]], 'autocommit: migrace dobehla');

    # verze NULL (rucni zasah do tabulky): prevzeti podminene pres dbversion IS NULL
    $T   = 0;
    $db  = FakeDB->new(table => 1, rows => [[undef, 12345]]);
    $drv = FakeDrv->new($db);
    $drv->{'on'}->{'read'} = sub { $T += 100 if ($_[1] > 1); };
    ($M, $log) = mydbi($drv);
    is(check($M, dbconf(dbversion_legacy_lock_wait => 60)), undef, 'verze NULL: bez chyby');
    is($db->count(qr/^LOCKID 12345>-M IF VERSION NULL$/), 1, 'verze NULL: podminene prevzeti');
    is_deeply($db->{'steps'}, ['STEP 1', 'STEP 2', 'STEP 3'], 'verze NULL: kroky od zacatku');
    is_deeply($db->{'rows'}, [[3, 0]], 'verze NULL: verze 3, lockid 0');

    # desetinna hodnota a hodnota v retezci
    foreach my $value ('150', 150.5) {
        $T   = 0;
        $db  = FakeDB->new(table => 1, rows => [[1, 12345]]);
        $drv = FakeDrv->new($db);
        $drv->{'on'}->{'read'} = sub { $T += 100 if ($_[1] > 1); };
        ($M, $log) = mydbi($drv);
        is(check($M, dbconf(dbversion_legacy_lock_wait => $value)), undef, "hodnota $value: bez chyby");
        is($drv->{'reads'}, 4, "hodnota $value: ve 100 s se ceka, ve 200 s prevzeti");
    }
};

scenario 'cizi kladny lockid: zmena verze dobu nuluje, prevzeti az po cele dobe od posledni zmeny' => sub {
    my $T = 0;
    local $Libs::MyDBI::DBVERSION_CLOCK = sub { return $T; };

    # starsi verze enginu dokonci krok 2 a pak skonci (SIGKILL)
    my $db  = FakeDB->new(table => 1, rows => [[1, 12345]]);
    my $drv = FakeDrv->new($db);
    $drv->{'on'}->{'read'} = sub {
        my ($s, $n) = @_;
        return if ($n == 1);
        $T += 50;
        old_engine_pass($db, 12345, 1 .. 3) if ($n == 2);
    };
    my ($M, $log) = mydbi($drv);
    is(check($M, dbconf(dbversion_legacy_lock_wait => 60)), undef, 'bez chyby');
    is($db->count(qr/IF VERSION/), 1, 'jedno prevzeti');
    is($db->count(qr/^LOCKID 12345>-M IF VERSION 2$/), 1, 'prevzeti az s verzi 2 (v 50 s se verze zmenila, v 100 s jeste neuplynula doba)');
    is($T, 200, 'prevzeti ve 150 s = 100 s po posledni zmene (+ overeni zamku)');
    like($log->{'error'}->[0], qr/se 100 s nezmenil \(verze 2,/, 'hlaska pocita dobu od posledni zmeny');
    is_deeply($db->{'steps'}, ['STEP 2', 'STEP 3'], 'krok 2 provedla starsi verze, krok 3 novy proces - kazdy jednou');
    is_deeply($db->{'rows'}, [[3, 0]], 'verze 3, lockid 0');

    # zamek mezitim ziska jiny proces bez zamku spojeni (jine cislo): doba bezi znovu
    $T   = 0;
    $db  = FakeDB->new(table => 1, rows => [[1, 12345]]);
    $drv = FakeDrv->new($db);
    $drv->{'on'}->{'read'} = sub {
        my ($s, $n) = @_;
        return if ($n == 1);
        $T += 50;
        $db->{'rows'}->[0]->[1] = 777 if ($n == 2);
    };
    ($M, $log) = mydbi($drv);
    is(check($M, dbconf(dbversion_legacy_lock_wait => 60)), undef, 'zmena cisla zamku: bez chyby');
    is($db->count(qr/^LOCKID 12345>/), 0, 'puvodni zamek se neprebira');
    is($db->count(qr/^LOCKID 777>-M IF VERSION 1$/), 1, 'prevzat az novy zamek po cele dobe');
    like($log->{'error'}->[0], qr/lockid:777 .* se 100 s nezmenil/, 'doba se pocita od zmeny cisla zamku');
};

scenario 'cizi kladny lockid: majitel dokonci krok tesne pred prevzetim - podminene prevzeti nic nezmeni' => sub {
    my $T = 0;
    local $Libs::MyDBI::DBVERSION_CLOCK = sub { return $T; };

    my $db  = FakeDB->new(table => 1, rows => [[1, 12345]]);
    my $drv = FakeDrv->new($db);
    $drv->{'on'}->{'read'} = sub {
        my ($s, $n) = @_;
        return if ($n == 1);
        $T += 30;
        if ($n == 6) { old_engine_pass($db, 12345, 1 .. 3); old_engine_pass($db, 12345, 1 .. 3); }    # krok 3 a uvolneni zamku
    };

    # mezi poslednim ctenim a UPDATE starsi verze enginu dokoncila krok 2 (zije, jen ji krok trval dlouho)
    $drv->{'on'}->{'takeover'} = sub { old_engine_pass($db, 12345, 1 .. 3); };
    my ($M, $log) = mydbi($drv);
    is(check($M, dbconf(dbversion_legacy_lock_wait => 60)), undef, 'bez chyby');
    is($db->count(qr/^LOCKID 12345>-M IF VERSION 1$/), 1, 'jeden pokus o prevzeti (v 60 s)');
    is($db->count(qr/IF VERSION/), 1, 'po zmene verze dalsi pokus neprisel (doba bezi znovu)');
    is(scalar($log->find('error', qr/Prebiram/)), 0, 'zamek ziveho procesu prevzat NEBYL');
    is($db->count(qr/^(STEP|VERSION)/), 0, 'novy proces neprovedl zadny krok');
    is_deeply($db->{'steps'}, ['STEP 2', 'STEP 3'], 'kazdy krok probehl prave jednou (provedla je starsi verze enginu)');
    is_deeply($db->{'rows'}, [[3, 0]], 'verze 3, lockid 0');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');
};

scenario 'dbversion_legacy_lock_wait => 0: cizi kladny lockid se neprevezme nikdy' => sub {
    my $T = 0;
    local $Libs::MyDBI::DBVERSION_CLOCK = sub { return $T; };

    my $db  = FakeDB->new(table => 1, rows => [[1, 12345]]);
    my $drv = FakeDrv->new($db);
    $drv->{'on'}->{'read'} = sub { $T += 100000 if ($_[1] > 1); $db->{'rows'}->[0]->[1] = 0 if ($_[1] == 5); };    # zamek uvolni spravce
    my ($M, $log) = mydbi($drv);
    is(check($M, dbconf(dbversion_legacy_lock_wait => 0)), undef, 'po uvolneni zamku bez chyby');
    is($db->count(qr/IF VERSION/),     0, 'zadny pokus o prevzeti ani po 300000 s');
    is($db->count(qr/^LOCKID 12345>/), 0, 'cizi zamek se neprebira');
    is($drv->{'reads'}, 6, 'ctyri cekani, po uvolneni ziskani zamku a overeni');
    is_deeply($db->{'steps'}, ['STEP 2', 'STEP 3'], 'po uvolneni zamku migrace dobehla');
    is_deeply($db->{'rows'}, [[3, 0]], 'verze 3, lockid 0');
    my @wait = $log->find('error', qr/migraci zrejme provadi starsi verze enginu/);
    is(scalar(@wait), 4, 'cekani bez konce se loguje na urovni error');
    like($wait[0], qr/zamek se neprebira \(dbi\.db1\.dbversion_legacy_lock_wait => 0\)/, 'hlaska: zamek se neprebira');
    like($wait[0], qr/uvolni ho rucne: UPDATE dbversion SET lockid = 0/,                 'hlaska radi, jak zamek rucne uvolnit');
    is(scalar($log->find('info', qr/prevezmu ho za/)), 0, 'zadny slib prevzeti');

    # zadost o ukonceni behem cekani
    $T   = 0;
    $db  = FakeDB->new(table => 1, rows => [[1, 12345]]);
    $drv = FakeDrv->new($db);
    $drv->{'on'}->{'read'} = sub { $T += 100000; Libs::MyDBI::requestStop() if ($_[1] == 3); };
    ($M, $log) = mydbi($drv);
    is(check($M, dbconf(dbversion_legacy_lock_wait => 0)), $STOP, 'zadost o ukonceni: die podle kontraktu');
    is($drv->{'reads'}, 3, 'po zadosti se uz neceka');
    is_deeply($db->{'rows'}, [[1, 12345]], 'cizi lockid beze zmeny');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');
};

scenario 'cizi kladny lockid a neni co migrovat: neceka se a zamek zustava' => sub {
    foreach my $version (3, 7) {
        my $db  = FakeDB->new(table => 1, rows => [[$version, 12345]]);
        my $drv = FakeDrv->new($db);
        my ($M, $log) = mydbi($drv);
        is(check($M, dbconf()), undef, "verze $version: bez chyby");
        is_deeply($db->{'ops'}, ['LOCK dbversion', 'ROLLBACK', 'SELECT schema', 'SELECT dbversion', 'UNLOCK dbversion'], "verze $version: jen cteni, zadne cekani ani zapis");
        is_deeply($db->{'rows'}, [[$version, 12345]], "verze $version: cizi zamek nedotcen (jeho majitel muze zit)");
        is($db->{'holder'}, undef, "verze $version: zamek spojeni uvolnen");
        is(scalar($log->find('info', qr/lockid:12345 .* pro tento proces neni co migrovat \(verze $version\), necekam a zamek ponechavam/)), 1, "verze $version: zalogovano (info)");
        is(scalar(@{$log->{'error'}}), 0, "verze $version: zadny zaznam error") or diag(explain($log->{'error'}));
    }
};

# Stejna vyjimka jako u obsazeneho zamku spojeni: proces, ktery nema co migrovat, ale strukturu tabulek cte
# z databaze (dao zapnute, daomap_file neexistuje), na cizi KLADNY lockid ceka - migrovat muze starsi verze
# enginu a mapa DAO by se nacetla z rozpracovaneho schematu (overeno na skutecnych databazich).
scenario 'cizi kladny lockid, neni co migrovat, ale mapa DAO se cte z databaze: ceka' => sub {
    my $T = 0;
    local $Libs::MyDBI::DBVERSION_CLOCK = sub { return $T; };

    # starsi verze enginu migruje dal (kroky 4-6) a zamek uvolni; nas proces zna jen kroky 1-3
    my @old = ();
    my $db  = FakeDB->new(table => 1, rows => [[3, 12345]]);
    my $drv = FakeDrv->new($db);
    $drv->{'on'}->{'read'} = sub {
        my ($s, $n) = @_;
        return if ($n == 1);
        $T += 10;
        push(@old, old_engine_pass($db, 12345, 1 .. 6));
    };
    my ($M, $log) = mydbi($drv);
    is(check($M, dbconf(dao => 1, dbversion_legacy_lock_wait => 60)), undef, 'bez chyby');
    is_deeply(\@old, ['step 4', 'step 5', 'step 6', 'done'], 'starsi verze enginu mezitim dokoncila migraci a zamek uvolnila');
    is($db->count(qr/^(LOCKID|VERSION|STEP|COMMIT|INSERT)/), 0, 'cekajici proces nic nezapsal');
    is_deeply($db->{'rows'}, [[6, 0]], 'tabulka: verze 6, lockid 0');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');
    is(scalar($log->find('info', qr/necekam a zamek ponechavam/)), 0, 'proces s mapou DAO z databaze nehlasi, ze neceka');
    cmp_ok(scalar($log->find('info', qr/Cekam, dokud migrace postupuje/)), '>=', 1, 'cekani zalogovano');
    is(scalar(@{$log->{'error'}}), 0, 'cekani na zivy proces neni chyba') or diag(explain($log->{'error'}));

    # opusteny kladny zamek: po dbversion_legacy_lock_wait ho proces prevezme a hned uvolni (nema co migrovat)
    $T   = 0;
    $db  = FakeDB->new(table => 1, rows => [[3, 12345]]);
    $drv = FakeDrv->new($db);
    $drv->{'on'}->{'read'} = sub { $T += 10 if ($_[1] > 1); };
    ($M, $log) = mydbi($drv);
    is(check($M, dbconf(dao => 1, dbversion_legacy_lock_wait => 60)), undef, 'opusteny zamek: bez chyby');
    is_deeply(
        $db->{'ops'},
        [
            'LOCK dbversion', 'ROLLBACK', 'SELECT schema',
            ('SELECT dbversion', 'ROLLBACK') x 7,
            'LOCKID 12345>-M IF VERSION 3', 'COMMIT',    # prevzeti po 60 s beze zmeny
            'SELECT dbversion',                          # zamek je nas, neni co migrovat
            'LOCKID -M>0', 'COMMIT',                     # uklid
            'UNLOCK dbversion',
        ],
        'opusteny zamek: cekani, podminene prevzeti, zadny krok, uvolneni'
    );
    is_deeply($db->{'rows'}, [[3, 0]], 'opusteny zamek: lockid 0 (starsi verze enginu uz necekaji)');
    is_deeply($db->{'steps'}, [], 'opusteny zamek: zadny krok');
    is(scalar($log->find('error', qr/Prebiram ho/)), 1, 'opusteny zamek: prevzeti zalogovano');

    # mapa DAO ze souboru: neceka (jako proces bez dao)
    open(my $fh, '>', "$TMP/daomap2.dump") or die "$TMP/daomap2.dump: $!";
    print $fh "{}\n";
    close($fh);
    $db = FakeDB->new(table => 1, rows => [[3, 12345]]);
    ($M, $log) = mydbi(FakeDrv->new($db));
    is(check($M, dbconf(dao => 1, homepath => "$TMP/", daomap_file => 'daomap2.dump')), undef, 'mapa DAO ze souboru: bez chyby');
    is_deeply($db->{'ops'}, ['LOCK dbversion', 'ROLLBACK', 'SELECT schema', 'SELECT dbversion', 'UNLOCK dbversion'], 'mapa DAO ze souboru: neceka');
    is_deeply($db->{'rows'}, [[3, 12345]], 'mapa DAO ze souboru: cizi zamek nedotcen');
};

scenario 'cizi kladny lockid: zadost o ukonceni behem cekani' => sub {
    my $T = 0;
    local $Libs::MyDBI::DBVERSION_CLOCK = sub { return $T; };

    my $db  = FakeDB->new(table => 1, rows => [[1, 12345]]);
    my $drv = FakeDrv->new($db);
    $drv->{'on'}->{'read'} = sub { $T += 10 if ($_[1] > 1); Libs::MyDBI::requestStop() if ($_[1] == 3); };
    my ($M, $log) = mydbi($drv);
    is(check($M, dbconf(dbversion_legacy_lock_wait => 60)), $STOP, 'die podle kontraktu');
    is($drv->{'reads'}, 3, 'po zadosti se uz neceka');
    is_deeply($db->{'ops'}, ['LOCK dbversion', 'ROLLBACK', 'SELECT schema', ('SELECT dbversion', 'ROLLBACK') x 2, 'SELECT dbversion', 'UNLOCK dbversion'], 'zadny zapis, zamek spojeni uvolnen');
    is_deeply($db->{'rows'}, [[1, 12345]], 'cizi lockid beze zmeny');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');
    is(scalar($log->find('info', qr/prerusena zadosti o ukonceni/)), 1, 'preruseni zalogovano');

    # zadost o ukonceni ma prednost pred prevzetim (doba uz uplynula)
    $T = 0;
    $Libs::MyDBI::STOP_REQUESTED = 0;
    $db  = FakeDB->new(table => 1, rows => [[1, 12345]]);
    $drv = FakeDrv->new($db);
    $drv->{'on'}->{'read'} = sub { if ($_[1] == 2) { $T += 1000; Libs::MyDBI::requestStop(); } };
    ($M, $log) = mydbi($drv);
    is(check($M, dbconf(dbversion_legacy_lock_wait => 60)), $STOP, 'doba uplynula a prisla zadost o ukonceni: die podle kontraktu');
    is($db->count(qr/^(LOCKID|STEP|VERSION|COMMIT)/), 0, 'zamek se uz neprebira');
    is_deeply($db->{'rows'}, [[1, 12345]], 'cizi lockid beze zmeny');
};

scenario 'starsi verze enginu a proces bez zamku spojeni pockaji na zaporny zamek ziveho procesu' => sub {
    my $db = FakeDB->new(table => 1, rows => [[0, 0]]);
    my $A  = FakeDrv->new($db, name => 'A');                      # novy proces se zamkem spojeni
    my $B  = FakeDrv->new($db, name => 'B');                      # novy proces s dbversion_session_lock => 0
    my ($MA, $logA) = mydbi($A);
    my ($MB, $logB) = mydbi($B);
    my (@old, $errB, $lockid);

    # uprostred kroku 2 procesu A startuje starsi verze enginu (trikrat se zepta) a proces B
    $A->{'on'}->{'step'} = sub {
        return unless ($_[1] eq 'STEP 2');
        $lockid = $db->{'rows'}->[0]->[1];
        push(@old, old_engine_pass($db, 4242, 1 .. 3)) foreach (1 .. 3);
        $B->{'on'}->{'read'} = sub { Libs::MyDBI::requestStop() if ($_[1] == 4); };    # B by cekal dal; test ho po 4 ctenich ukonci
        $errB = check($MB, dbconf(dbversion_session_lock => 0));
        $Libs::MyDBI::STOP_REQUESTED = 0;
    };
    is(check($MA, dbconf()), undef, 'proces A: migrace bez chyby');
    cmp_ok($lockid, '<', 0, 'proces A drzi zaporny lockid');
    is_deeply(\@old, ['locked', 'locked', 'locked'], 'starsi verze enginu vidi nenulovy cizi lockid a ceka (zaporne cislo ji nevadi)');
    is($errB, $STOP, 'proces B cekal az do ukonceni testem');
    is($B->{'reads'}, 4, 'proces B: ctyri cteni, zadne prevzeti');
    is($db->count(qr/>M$/), 0, 'proces B do sloupce lockid nezapsal');
    is(scalar($logB->find('error', qr/^Dbversion is locked by lockid:-\d+ \(dbid:db1\)/)), 1, 'proces B: hlaska o cekani na zaporny lockid');
    is_deeply($db->{'steps'}, ['STEP 1', 'STEP 2', 'STEP 3'], 'kazdy krok probehl prave jednou');
    is_deeply($db->{'rows'}, [[3, 0]], 'verze 3, lockid 0');
    is(old_engine_pass($db, 4242, 1 .. 3), 'done', 'po dokonceni migrace starsi verze enginu nema co delat');
    is_deeply($db->{'steps'}, ['STEP 1', 'STEP 2', 'STEP 3'], 'a zadny krok neopakuje');
};

scenario 'dbversionNow: hodiny pro dbversion_legacy_lock_wait' => sub {
    my $t1 = Libs::MyDBI->dbversionNow();
    like($t1, qr/^\d+(?:\.\d+)?(?:e[+-]?\d+)?$/i, 'vraci nezaporne cislo');
    Time::HiRes::sleep(0.05);
    my $t2 = Libs::MyDBI->dbversionNow();
    cmp_ok($t2, '>=', $t1, 'cas nejde zpet');
    cmp_ok($t2 - $t1, '<', 5, 'cas je v sekundach');
  SKIP: {
        skip('monotonni hodiny nejsou k dispozici', 1) unless (eval { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()); 1 });
        cmp_ok($t2 - $t1, '>=', 0.04, 'monotonni hodiny s rozlisenim lepsim nez 1 s');
    }
    {
        local $Libs::MyDBI::DBVERSION_CLOCK = sub { return 42; };
        is(Libs::MyDBI->dbversionNow(), 42, 'DBVERSION_CLOCK cas nahradi (testy)');
    }

    # skutecne hodiny a skutecne cekani: doba 1 s, cteni po 1 s
    local $Libs::MyDBI::DBVERSION_POLL = 1;
    my $db  = FakeDB->new(table => 1, rows => [[1, 12345]]);
    my $drv = FakeDrv->new($db);
    my ($M, $log) = mydbi($drv);
    my $t0 = Time::HiRes::time();
    is(check($M, dbconf(dbversion_legacy_lock_wait => 1)), undef, 'skutecne hodiny: bez chyby');
    my $took = Time::HiRes::time() - $t0;
    ok(($took >= 0.9 and $took < 6), 'skutecne hodiny: prevzeti az po nastavene dobe') or diag("trvalo $took s");
    is($db->count(qr/^LOCKID 12345>-M IF VERSION 1$/), 1, 'skutecne hodiny: zamek prevzat');
    is_deeply($db->{'rows'}, [[3, 0]], 'skutecne hodiny: migrace dobehla');
};

# --- zalozeni tabulky ---------------------------------------------------------------------------------------
scenario 'dva soucasne startujici procesy: tabulka se nezaklada dvakrat, kazdy krok prave jednou' => sub {
    my $db = FakeDB->new(holder => 'A');    # proces A uz drzi zamek spojeni, tabulku jeste nezalozil
    my $A  = FakeDrv->new($db, name => 'A');
    my $B  = FakeDrv->new($db, name => 'B');
    my ($MA) = mydbi($A);
    my ($MB, $log) = mydbi($B);

    # B ceka na zamek; behem jeho druheho pokusu probehne cela migrace procesu A
    $B->{'on'}->{'lock'} = sub {
        return unless ($_[1] == 2);
        $MA->checkDbversion('db1', dbconf());
    };
    is(check($MB, dbconf()), undef, 'proces B bez chyby');
    is($db->{'created'}, 1, 'CREATE TABLE dbversion probehl prave jednou');
    is($db->count(qr/^CREATE$/), 1, 'proces B tabulku znovu nezaklada');
    is($db->count(qr/^INSERT /), 1, 'jediny INSERT radku');
    is_deeply($db->{'rows'}, [[3, 0]], 'tabulka dbversion ma jeden radek');
    is_deeply($db->{'steps'}, ['STEP 1', 'STEP 2', 'STEP 3'], 'kazdy krok probehl prave jednou');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');

    # poradi: existence tabulky se pro zalozeni overuje az pod zamkem
    my @ops = @{$db->{'ops'}};
    my ($lock)   = grep { $ops[$_] eq 'LOCK dbversion' } 0 .. $#ops;
    my ($create) = grep { $ops[$_] eq 'CREATE' } 0 .. $#ops;
    ok($lock < $create, 'CREATE TABLE az po ziskani zamku spojeni');
};

scenario 'tabulka dbversion bez radku (pad mezi CREATE TABLE a INSERT)' => sub {
    my $db = FakeDB->new(table => 1, rows => []);
    my ($M, $log) = mydbi(FakeDrv->new($db));
    is(check($M, dbconf()), undef, 'se zamkem spojeni: bez chyby');
    is($db->count(qr/^INSERT 0,0$/), 1, 'radek doplnen');
    is_deeply($db->{'rows'}, [[3, 0]], 'jeden radek, migrace dobehla');
    is(scalar($log->find('error', qr/nema zadny radek \(nedokoncene zalozeni tabulky\)/)), 1, 'doplneni zalogovano');
    is_deeply(
        [@{$db->{'ops'}}[0 .. 7]],
        ['LOCK dbversion', 'ROLLBACK', 'SELECT schema', 'SELECT dbversion', 'ROLLBACK', 'SELECT dbversion', 'INSERT 0,0', 'COMMIT'],
        'radek se doplni az po druhem prazdnem cteni (mezi ctenimi konec transakce)'
    );

    # Regrese (soubeh se starsi verzi enginu nad cistou databazi): starsi verze je prave mezi CREATE TABLE
    # a INSERT; novy proces pod zamkem spojeni videl tabulku bez radku, vlozil svuj radek a v tabulce zustaly
    # dva. Nove pri prvnim prazdnem cteni jen pocka - radek mezitim vlozi starsi verze.
    $db = FakeDB->new(table => 1, rows => []);
    my $drv1 = FakeDrv->new($db);
    $drv1->{'on'}->{'read'} = sub { $db->{'rows'} = [[0, 0]] if ($_[1] == 2); };    # starsi verze vlozi radek pred druhym ctenim
    ($M, $log) = mydbi($drv1);
    is(check($M, dbconf()), undef, 'radek vlozi jiny proces: bez chyby');
    is($db->count(qr/^INSERT/), 0, 'radek vlozi jiny proces: vlastni INSERT se neprovede');
    is(scalar(@{$db->{'rows'}}), 1, 'radek vlozi jiny proces: v tabulce je jediny radek');
    is_deeply($db->{'rows'}, [[3, 0]], 'radek vlozi jiny proces: migrace dobehla');
    is(scalar($log->find('error', qr/nema zadny radek/)), 0, 'radek vlozi jiny proces: zadny zaznam error');

    # zadost o ukonceni behem cekani na radek
    $db = FakeDB->new(table => 1, rows => []);
    my $drv2 = FakeDrv->new($db);
    $drv2->{'on'}->{'read'} = sub { Libs::MyDBI::requestStop(); };
    ($M) = mydbi($drv2);
    is(check($M, dbconf()), $STOP, 'zadost o ukonceni pri prazdne tabulce: die podle kontraktu');
    is($db->count(qr/^INSERT/), 0, 'zadost o ukonceni pri prazdne tabulce: zadny INSERT');
    is($db->{'holder'}, undef, 'zadost o ukonceni pri prazdne tabulce: zamek spojeni uvolnen');
    $Libs::MyDBI::STOP_REQUESTED = 0;

    # bez zamku spojeni se ceka (radek mozna prave vklada jiny proces)
    $db = FakeDB->new(table => 1, rows => []);
    my $drv = FakeDrvBase->new($db);
    $drv->{'on'}->{'read'} = sub { $db->{'rows'} = [[0, 0]] if ($_[1] == 3); };
    ($M, $log) = mydbi($drv);
    is(check($M, dbconf()), undef, 'bez zamku spojeni: bez chyby');
    is($db->count(qr/^INSERT/), 0, 'bez zamku spojeni se radek nedoplnuje');
    is_deeply($db->{'rows'}, [[3, 0]], 'po vlozeni radku jinym procesem migrace dobehla');
    like(($log->find('error', qr/nema zadny radek/))[0], qr/INSERT INTO dbversion \(dbversion,lockid\) VALUES \(0,0\)/, 'hlaska radi, jak radek doplnit rucne');
};

# Falesna spojeni pro soubeh se starsi verzi enginu (bez zamku spojeni) nad cistou databazi.
{
    # Starsi verze overila existenci tabulky pred nasim CREATE TABLE, chybu sveho CREATE ignoruje a radek (0,0)
    # vlozi sama: jeji radek se v tabulce objevi behem naseho cekani (pred nasim druhym ctenim).
    package FakeDrvOldInserts;
    our @ISA = ('FakeDrv');
    sub select {
        my ($s, $sql, $bind) = @_;
        if (($sql =~ /dbversion,lockid FROM dbversion/) and (++$s->{'tblreads'} == 2)) {
            push(@{$s->{'db'}->{'rows'}}, [0, 0]);
        }
        return $s->SUPER::select($sql, $bind);
    }

    # Starsi verze zalozi tabulku i radek tesne pred nasim CREATE TABLE (nase kontrola existence ji jeste nevidela).
    package FakeDrvOldCreates;
    our @ISA = ('FakeDrv');
    sub command {
        my ($s, $sql) = @_;
        if (($sql =~ /CREATE TABLE dbversion/) and !$s->{'db'}->{'table'}) {
            $s->{'db'}->{'table'} = 1;
            $s->{'db'}->{'rows'}  = [[0, 0]];
        }
        return $s->SUPER::command($sql);
    }

    # Zadost o ukonceni prijde behem cekani nad prazdnou tabulkou (po N-tem rollbacku = behem spanku).
    package FakeDrvStopOnRollback;
    our @ISA = ('FakeDrv');
    sub rollback {
        my $s = shift;
        my $r = $s->SUPER::rollback(@_);
        Libs::MyDBI::requestStop() if (++$s->{'rollbacks'} == ($s->{'stop_at'} || 0));
        return $r;
    }

    package main;
}

# Regrese (overeno na skutecne MariaDB a MySQL): novy proces zalozil tabulku a hned vlozil radek, starsi verze
# enginu po neuspesnem CREATE TABLE vlozila svuj - v tabulce dbversion zustaly dva radky.
scenario 'cista databaze a soubezne startujici starsi verze enginu: v tabulce zustane jediny radek' => sub {
    my $db = FakeDB->new;
    my ($M, $log) = mydbi(FakeDrvOldInserts->new($db));
    is(check($M, dbconf()), undef, 'bez chyby');
    is($db->count(qr/^CREATE$/), 1, 'tabulku zalozil novy proces');
    is($db->count(qr/^INSERT/), 0, 'radek vlozila starsi verze: vlastni INSERT se neprovede');
    is(scalar(@{$db->{'rows'}}), 1, 'v tabulce je jediny radek');
    is_deeply($db->{'rows'}, [[3, 0]], 'migrace dobehla');
    is(scalar(@{$log->{'error'}}), 0, 'zadny zaznam error') or diag(explain($log->{'error'}));

    # opacne poradi: tabulku zalozi starsi verze tesne pred nasim CREATE TABLE
    $db = FakeDB->new;
    ($M, $log) = mydbi(FakeDrvOldCreates->new($db));
    is(check($M, dbconf()), undef, 'tabulku zalozi starsi verze: bez chyby');
    is($db->count(qr/^INSERT/), 0, 'tabulku zalozi starsi verze: zadny vlastni INSERT');
    is_deeply($db->{'rows'}, [[3, 0]], 'tabulku zalozi starsi verze: jediny radek, migrace dobehla');
    is(scalar($log->find('info', qr/tabulku dbversion \(dbid:db1\) mezitim zalozil jiny proces .* pouzivam ji; CREATE TABLE selhal: DB ERROR:1050/)), 1, 'tabulku zalozi starsi verze: zalogovano jako bezny soubeh (info)');
    is(scalar($log->find('error', qr/existuje, ale ne tam, kde ji hleda kontrola existence/)), 0, 'tabulku zalozi starsi verze: zadna hlaska o jinem schematu (neni to chyba konfigurace)');
    is(scalar($log->find('error', qr/nema zadny radek/)), 0, 'tabulku zalozi starsi verze: zadna hlaska o tabulce bez radku');

    # zadost o ukonceni behem cekani nad vlastni prazdnou tabulkou: radek se uz nedoplnuje
    $db = FakeDB->new;
    ($M) = mydbi(FakeDrvStopOnRollback->new($db, stop_at => 2));    # 1. rollback po ziskani zamku, 2. pred cekanim
    is(check($M, dbconf()), $STOP, 'zadost o ukonceni behem cekani: die podle kontraktu');
    is($db->count(qr/^INSERT/), 0, 'zadost o ukonceni behem cekani: radek se nedoplni');
    is($db->{'holder'}, undef, 'zadost o ukonceni behem cekani: zamek spojeni uvolnen');
    $Libs::MyDBI::STOP_REQUESTED = 0;
};

# Regrese: PostgreSQL s tabulkou dbversion v jinem schematu, nez kde ji hleda kontrola existence (conf schema
# vs. search_path) - kontrola ji nevidi, CREATE TABLE selze ("already exists") a engine pod zamkem spojeni
# spadl pri kazdem startu krome prvniho. Starsi verze enginu chybu CREATE jen zalogovala a pokracovala.
scenario 'CREATE TABLE selze, ale tabulku lze precist (jine schema): pouzije se' => sub {
    my $db = FakeDB->new(table => 1, hidden => 1, rows => [[1, 0]]);
    my ($M, $log) = mydbi(FakeDrv->new($db));
    is(check($M, dbconf()), undef, 'start bez chyby');
    is_deeply(
        [@{$db->{'ops'}}[0 .. 5]],
        ['LOCK dbversion', 'ROLLBACK', 'SELECT schema', 'CREATE', 'ROLLBACK', 'SELECT dbversion'],
        'po neuspesnem CREATE rollback (PostgreSQL by dalsi prikazy odmital) a pokus o cteni'
    );
    is($db->count(qr/^INSERT/), 0, 'zadny dalsi radek se nevklada');
    is_deeply($db->{'steps'}, ['STEP 2', 'STEP 3'], 'zbyle kroky provedeny');
    is_deeply($db->{'rows'}, [[3, 0]], 'jeden radek, verze 3, lockid 0');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');
    my @e = $log->find('error', qr/tabulka dbversion \(dbid:db1\) existuje, ale ne tam, kde ji hleda kontrola existence/);
    is(scalar(@e), 1, 'zalogovano na urovni error');
    like($e[0], qr/CREATE TABLE selhal: DB ERROR:1050, Table 'dbversion' already exists/, 'hlaska obsahuje puvodni chybu CREATE TABLE');

    # nic k migraci: jen cteni
    $db = FakeDB->new(table => 1, hidden => 1, rows => [[3, 0]]);
    ($M) = mydbi(FakeDrv->new($db));
    is(check($M, dbconf()), undef, 'nic k migraci: bez chyby');
    is($db->count(qr/^(INSERT|LOCKID|VERSION|STEP)/), 0, 'nic k migraci: zadny zapis');
};

scenario 'tabulku nelze zalozit nebo precist: die misto nekonecne smycky' => sub {
    my $db = FakeDB->new;
    my ($M) = mydbi(FakeDrv->new($db, fail_sql => qr/CREATE TABLE dbversion/));
    like(check($M, dbconf()), qr/^Dbversion: tabulku dbversion nelze zalozit: DB ERROR:1142, CREATE command denied\n\z/, 'CREATE TABLE selze: die');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');

    $db = FakeDB->new(table => 1, rows => [[1, 0]]);
    ($M) = mydbi(FakeDrv->new($db, fail_sql => qr/FROM dbversion/));
    like(check($M, dbconf()), qr/^Dbversion: tabulku dbversion nelze precist: DB ERROR:1146/, 'SELECT selze: die');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');
};

scenario 'pojistka: zapis zamku lockid se tise neprovadi' => sub {
    local $Libs::MyDBI::DBVERSION_MAX_TRIES = 3;
    my $db = FakeDB->new(table => 1, rows => [[1, -12345]]);
    my ($M) = mydbi(FakeDrv->new($db, lost_updates => 1));
    my $err = check($M, dbconf());
    like($err, qr/^Dbversion: zamek lockid se nepodarilo ziskat ani na 3 pokusu \(dbid:db1, dbversion:1, lockid:-12345\)/, 'die po vycerpani pokusu');
    is($db->count(qr/^LOCKID -12345>-M$/), 3, 'prave tri pokusy');
    is($db->{'holder'}, undef, 'zamek spojeni uvolnen');

    # totez pri podminenem prevzeti kladneho zamku: po uplynuti doby se zkousi hned znovu, ne po dalsi cele dobe
    my $T = 0;
    local $Libs::MyDBI::DBVERSION_CLOCK = sub { return $T; };
    $db = FakeDB->new(table => 1, rows => [[1, 12345]]);
    my $drv = FakeDrv->new($db, lost_updates => 1);
    $drv->{'on'}->{'read'} = sub { $T += 100 if ($_[1] == 2); };
    ($M) = mydbi($drv);
    $err = check($M, dbconf(dbversion_legacy_lock_wait => 60));
    like($err, qr/^Dbversion: zamek lockid se nepodarilo ziskat ani na 3 pokusu \(dbid:db1, dbversion:1, lockid:12345\)/, 'kladny zamek: die po vycerpani pokusu');
    is($db->count(qr/^LOCKID 12345>-M IF VERSION 1$/), 3, 'kladny zamek: prave tri pokusy');
    is($T, 100, 'kladny zamek: mezi pokusy se neceka dalsi cela doba');
    is($db->{'holder'}, undef, 'kladny zamek: zamek spojeni uvolnen');
};

# --- vstupy --------------------------------------------------------------------------------------------------
scenario 'soubor migraci a ovladac' => sub {
    my $db = FakeDB->new;
    my ($M) = mydbi(FakeDrv->new($db));
    write_steps('broken.dbversion', "{ 1 => 'STEP 1', \n");
    like(check($M, dbconf(dbversion_file => 'broken.dbversion')), qr/^Dbversion: \Q$TMP\E\/broken\.dbversion: .*syntax error/s, 'chyba syntaxe souboru migraci: die se jmenem souboru');
    write_steps('nohash.dbversion', "1;\n");
    is(check($M, dbconf(dbversion_file => 'nohash.dbversion')), "Dbversion: $TMP/nohash.dbversion: soubor nevraci hash\n", 'soubor nevraci hash: die');
    is(check($M, dbconf(dbdriver => 'oracle')), "Unknown dbdriver: oracle\n", 'neznamy ovladac: die jako driv');
    is_deeply($db->{'ops'}, [], 'pred chybou vstupu se na databazi nesaha (zadny zamek)');

    # postgres: existence tabulky podle schematu
    $db = FakeDB->new;
    ($M) = mydbi(FakeDrv->new($db));
    is(check($M, dbconf(dbdriver => 'postgres', schema => 'eshop')), undef, 'postgres: bez chyby');
    is_deeply($db->{'rows'}, [[3, 0]], 'postgres: migrace dobehla');
};

scenario 'SQL komentar s mistem volani (loglevel 3) migraci nerozbije' => sub {
    my $db = FakeDB->new(table => 1, rows => [[1, -12345]]);
    my ($M, $log) = mydbi(FakeDrv->new($db), level => 3);
    is(check($M, dbconf()), undef, 'bez chyby');
    is_deeply($db->{'steps'}, ['STEP 2', 'STEP 3'], 'kroky provedeny');
    is_deeply($db->{'rows'}, [[3, 0]], 'verze 3, lockid 0');
};

# --- konstruktor: opakovani pripojeni a requestStop ----------------------------------------------------------
{
    my %dbi = (db1 => {dbdriver => 'mysql', database => 'testdb', db_pool => 1, trayconnect => 5, dao => 0, dbversion_file => 'steps.dbversion'});
    my $conf = sub { return MockConf->new({pwe => {home => $TMP}, dbi => {db1 => {%{$dbi{'db1'}}, @_}}}); };
    my ($db, @attempts, $plan, %on);    # %on = hacky (viz FakeDrvBase) pro spojeni zalozena konstruktorem
    no warnings qw(redefine once);
    local *Libs::MyDBI::createConnection = sub {
        my ($self, $dbid, $dbidpool, $dbconf) = @_;
        push(@attempts, $dbidpool);
        my $ok = $plan->(scalar(@attempts));
        $self->DBC->{$dbid}->{$dbidpool} = FakeDrv->new($db, name => "pool$dbidpool", on => {%on}) if ($ok);
        return $ok;
    };
    use warnings qw(redefine once);
    my $new = sub {
        my ($log, %extra) = @_;
        my ($M, $err);
        eval { $M = Libs::MyDBI->new($conf->(%extra), $log, undef); 1 } or $err = $@;
        return ($M, $err);
    };

    scenario 'new(): opakovane pokusy o pripojeni a migrace' => sub {
        ($db, @attempts) = (FakeDB->new);
        $plan = sub { return ($_[0] >= 3) ? 1 : 0; };
        my ($M, $err) = $new->(MockLog->new);
        is($err, undef, 'konstruktor bez chyby');
        is_deeply(\@attempts, [0, 0, 0, 1], 'dva neuspesne pokusy o pool 0, pak pool 0 a pool 1');
        is($M->DBC->{'db1'}->{'0'}->getPoolLock(), 1, 'pool 0 zamcen');
        is_deeply($db->{'rows'}, [[3, 0]], 'migrace probehla z konstruktoru');
        is($db->{'holder'}, undef, 'zamek spojeni uvolnen');
    };

    scenario 'new(): dbversion_legacy_lock_wait z konfigurace dbi.<dbid>' => sub {
        my $T = 0;
        local $Libs::MyDBI::DBVERSION_CLOCK = sub { return $T; };
        $plan = sub { return 1; };
        %on   = (read => sub { $T += 10 if ($_[1] > 1); });
        ($db, @attempts) = (FakeDB->new(table => 1, rows => [[1, 12345]]));
        my $log = MockLog->new;
        local $SIG{ALRM} = sub { die "TIMEOUT: konstruktor nedobehl do 10 s\n" };
        alarm(10);
        my ($M, $err) = $new->($log, dbversion_legacy_lock_wait => 20);
        alarm(0);
        %on = ();
        is($err, undef, 'konstruktor bez chyby');
        is($db->count(qr/^SELECT dbversion$/), 4, 'cteni v 0 a 10 s, ve 20 s prevzeti (+ overeni zamku)');
        is($db->count(qr/^LOCKID 12345>-M IF VERSION 1$/), 1, 'zamek prevzat po dobe z konfigurace');
        is(scalar($log->find('error', qr/se 20 s nezmenil \(verze 1, dbi\.db1\.dbversion_legacy_lock_wait => 20\)/)), 1, 'prevzeti zalogovano');
        is_deeply($db->{'rows'}, [[3, 0]], 'migrace dobehla');
    };

    # dbversionDaoFromDb musi rozhodovat stejne jako konstruktor: mapu DAO cte konstruktor z databaze prave tehdy,
    # kdyz dbversionDaoFromDb vraci 1 (jinak proces bud zbytecne ceka, nebo cte rozpracovane schema).
    scenario 'new(): mapa DAO ze souboru/z databaze - konstruktor a dbversionDaoFromDb se shoduji' => sub {
        no warnings qw(redefine once);
        local *FakeDrvBase::getMetaData = sub { return {z_databaze => {}}; };
        $plan = sub { return 1; };
        open(my $fh, '>', "$TMP/daomap.dump") or die "$TMP/daomap.dump: $!";
        print $fh "{ ze_souboru => {} }\n";
        close($fh);

        # pwe.home je v tomto bloku $TMP BEZ lomitka na konci: 'daomap.dump' se hleda jako "${TMP}daomap.dump"
        foreach my $case (['daomap.dump', 'z_databaze'], ['/daomap.dump', 'ze_souboru'], ['neexistuje.dump', 'z_databaze']) {
            my ($file, $want) = @{$case};
            ($db, @attempts) = (FakeDB->new(table => 1, rows => [[3, 0]]));
            my ($M, $err) = $new->(MockLog->new, dao => 1, daomap_file => $file);
            is($err, undef, "daomap_file '$file': konstruktor bez chyby");
            is_deeply([keys %{$M->{'maps'}->{'db1'}}], [$want], "daomap_file '$file': mapa DAO $want");
            is(Libs::MyDBI->dbversionDaoFromDb({dao => 1, homepath => $TMP, daomap_file => $file}), (($want eq 'z_databaze') ? 1 : 0), "daomap_file '$file': dbversionDaoFromDb rozhoduje stejne jako konstruktor");
        }
    };

    scenario 'new(): requestStop behem opakovani pripojeni' => sub {
        ($db, @attempts) = (FakeDB->new);
        $plan = sub { Libs::MyDBI::requestStop() if ($_[0] == 2); return 0; };    # SIGTERM behem druheho pokusu
        my ($M, $err) = $new->(MockLog->new);
        is($err, $STOP, 'die podle kontraktu');
        is(scalar(@attempts), 2, 'po zadosti o ukonceni zadny dalsi pokus (trayconnect 5)');
        is_deeply($db->{'ops'}, [], 'na databazi se nesahlo');
    };

    scenario 'new(): signal behem cekani mezi pokusy' => sub {
        ($db, @attempts) = (FakeDB->new);
        $plan = sub { return 0; };
        local $SIG{ALRM} = sub { Libs::MyDBI::requestStop(); };    # jako handler SIGTERM v pwe.fcgi
        my $t0 = Time::HiRes::time();
        Time::HiRes::ualarm(150_000);
        my ($M, $err) = $new->(MockLog->new(delay => 0));          # delay 0 = pokus byl rychly, konstruktor ceka 1 s
        Time::HiRes::ualarm(0);
        is($err, $STOP, 'die podle kontraktu');
        is(scalar(@attempts), 1, 'signal prerusil cekani, dalsi pokus se nekona');
        cmp_ok(Time::HiRes::time() - $t0, '<', 0.9, 'cekani 1 s se nedokoncuje');
    };

    scenario 'new(): priznak nastaveny pred startem' => sub {
        ($db, @attempts) = (FakeDB->new);
        $plan = sub { return 1; };
        Libs::MyDBI::requestStop();
        my ($M, $err) = $new->(MockLog->new);
        is($err, $STOP, 'die podle kontraktu');
        is(scalar(@attempts), 0, 'zadny pokus o pripojeni');

        # web bez databaze: konstruktor priznak neresi (ukonceni je vec pwe.fcgi)
        my $M2 = eval { Libs::MyDBI->new(MockConf->new({}), MockLog->new, undef) };
        ok($M2, 'bez sekce dbi konstruktor dobehne i s nastavenym priznakem') or diag($@);
        is_deeply($M2->getDbidList(), [], 'zadna databaze');
    };

    scenario 'new(): vycerpane pokusy o pripojeni' => sub {
        ($db, @attempts) = (FakeDB->new);
        $plan = sub { return 0; };
        my ($M, $err) = $new->(MockLog->new);
        is($err, "Unable connect to db1, poolid 0 bye...\n", 'die jako driv');
        is(scalar(@attempts), 5, 'trayconnect pokusu');
    };
}

done_testing();
