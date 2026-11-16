#!/usr/bin/env perl
# Libs::MyDBI::DRIVER::MySQL / Postgre - stavove chovani bez skutecne databaze (mock DBI handle).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PWE::TestEnv;

package MockDBH;
sub new { my ($c, %a) = @_; return bless {rolled => 0, %a}, $c; }
sub err { $_[0]->{'err'} }
sub errstr { $_[0]->{'errstr'} }
sub state { $_[0]->{'state'} }
sub rollback { $_[0]->{'rolled'}++; 1 }
sub commit { 'committed' }
sub ping { $_[0]->{'pinged'}++; return (exists($_[0]->{'alive'}) ? $_[0]->{'alive'} : 1); }
sub prepare_cached { my ($s, $sql) = @_; $s->{'prepared'}++; $s->{'last_sql'} = $sql; return MockSTH2->new($s); }
sub do { my ($s, $sql) = @_; push(@{$s->{'did'}}, $sql); 1 }
sub trace { 1 }
sub disconnect { $_[0]->{'disconnected'}++; 1 }

package MockSTH2;
sub new { my ($c, $dbh) = @_; return bless {dbh => $dbh}, $c; }
sub execute { $_[0]->{'dbh'}->{'executed'}++; 1 }
sub fetchrow_array { return (1); }
sub finish { 1 }
sub err { undef }
sub errstr { undef }
sub state { undef }
sub disconnect { 1 }

package main;

PWE::TestEnv::clean_env();
require Libs::MyDBI::DRIVER::MySQL;
require Libs::MyDBI::DRIVER::Postgre;

# --- MySQL -----------------------------------------------------------------------
{
    my $d = Libs::MyDBI::DRIVER::MySQL->new;
    ok(!$d->error(), 'novy driver bez chyby');
    is($d->getPoolLock(), 0, 'pool lock vychozi 0');
    $d->setPoolLock(1);
    is($d->getPoolLock(), 1, 'setPoolLock(1)');
    $d->setPoolLock(0);
    is($d->getPoolLock(), 0, 'setPoolLock(0)');

    $d->{'DBI_R'} = MockDBH->new();
    $d->{'DBI_W'} = MockDBH->new(err => 1062, errstr => 'Duplicate', state => '23000');
    $d->setError();
    ok($d->error(), 'setError() prevezme chybu z W handle');
    is_deeply($d->getError(), {err => 1062, errstr => 'Duplicate', state => '23000'}, 'getError');

    $d->{'DBI_W'} = MockDBH->new();
    $d->setError();
    ok(!$d->error(), 'setError() bez chyby na handlech smaze predchozi chybu (regrese: chyba visela)');

    $d->{'DBI_R'} = MockDBH->new(err => 2006, errstr => 'gone');
    $d->setError();
    is($d->getError()->{'err'}, 2006, 'chyba z R handle');
    $d->{'DBI_R'} = MockDBH->new();

    $d->setError(MockDBH->new(err => 1, errstr => 'q'));
    ok($d->error(), 'setError($query) s chybou');
    $d->setError(MockDBH->new());
    ok(!$d->error(), 'setError($query) bez chyby smaze stav');

    my @w;
    {
        local $SIG{__WARN__} = sub { push(@w, @_) };
        my $x = Libs::MyDBI::DRIVER::MySQL->new;
        undef $x;
    }
    is(scalar(@w), 0, 'DESTROY nepripojeneho driveru nevaruje (regrese)') or diag(@w);

    my $w = MockDBH->new;
    {
        my $x = Libs::MyDBI::DRIVER::MySQL->new;
        $x->{'DBI_W'} = $w;
        $x->{'DBI_R'} = MockDBH->new;
    }
    is($w->{'rolled'}, 1, 'DESTROY pripojeneho driveru vola rollback');
}

# --- Postgre ---------------------------------------------------------------------
{
    my $d = Libs::MyDBI::DRIVER::Postgre->new;
    ok(!$d->error(), 'novy driver bez chyby');
    $d->{'DBI'} = MockDBH->new(err => 7, errstr => 'pg err', state => 'XX000');
    $d->setError();
    ok($d->error(), 'setError() z handle');
    is($d->getError()->{'errstr'}, 'pg err', 'getError errstr');
    $d->{'DBI'} = MockDBH->new();
    $d->setError();
    ok(!$d->error(), 'setError() bez chyby smaze stav (regrese)');

    my @w;
    {
        local $SIG{__WARN__} = sub { push(@w, @_) };
        my $x = Libs::MyDBI::DRIVER::Postgre->new;
        undef $x;
    }
    is(scalar(@w), 0, 'DESTROY nepripojeneho Postgre driveru nevaruje') or diag(@w);
}

# --- commit/rollback vraci vysledek DBI (regrese: vracel se stav ze setError) ---
{
    my $d = Libs::MyDBI::DRIVER::MySQL->new;
    $d->{'DBI_R'} = MockDBH->new();
    $d->{'DBI_W'} = MockDBH->new();
    is($d->commit(),   'committed', 'MySQL commit vraci vysledek DBI');
    is($d->rollback(), 1,           'MySQL rollback vraci vysledek DBI');
    ok(!$d->error(), 'po commitu bez chyby');
    my $p = Libs::MyDBI::DRIVER::Postgre->new;
    $p->{'DBI'} = MockDBH->new();
    is($p->commit(),   'committed', 'Postgre commit vraci vysledek DBI');
    is($p->rollback(), 1,           'Postgre rollback vraci vysledek DBI');
}

# --- ping pres DBI->ping a prepare_cached (regrese: 2x SELECT 1 na pool, prepare pri kazdem dotazu) ---
{
    my $d = Libs::MyDBI::DRIVER::MySQL->new;
    my ($r, $w) = (MockDBH->new(), MockDBH->new());
    $d->{'DBI_R'} = $r;
    $d->{'DBI_W'} = $w;
    is($d->ping(), 1, 'MySQL ping = DBI ping obou handle');
    is($r->{'pinged'} + $w->{'pinged'}, 2, 'dva pingy, zadny SELECT 1');
    $w->{'alive'} = 0;
    is($d->ping(), 0, 'mrtve zapisove spojeni -> 0');
    my $sth = $d->select('1 FROM t', []);
    is($r->{'prepared'}, 1, 'select pouziva prepare_cached na ctecim spojeni');
    is($r->{'last_sql'}, 'SELECT 1 FROM t', 'SQL slozene se SELECT');
    $d->insert('INTO t (a) VALUES (?)', [1]);
    is($w->{'prepared'}, 1, 'insert pouziva prepare_cached na zapisovem spojeni');
    my $p = Libs::MyDBI::DRIVER::Postgre->new;
    my $h = MockDBH->new();
    $p->{'DBI'} = $h;
    $p->select('1 FROM t', []);
    is($h->{'prepared'}, 1, 'Postgre select pouziva prepare_cached');
}

# --- connect(): slozeni DSN, volby dsn_options, zalozni pokus pres TLS, chyba pripojeni ---
# Regrese: MySQL 8+ (caching_sha2_password) odmita plne overeni hesla po nesifrovanem spojeni chybou
# 2061 "Authentication requires secure connection" a engine se k nemu nepripojil; chybu DBI navic
# driver nikam neulozil, takze v logu zustalo jen "connect_status:0".
{
    # DBI->connect se nahrazuje funkci, ktera zaznamena argumenty a vrati dalsi polozku planu:
    # MockDBH = uspech, [err, errstr, state] = neuspech. Chyba se nastavi na skutecnem DBI handle
    # (driver Sponge je soucasti DBI), takze $DBI::err/$DBI::errstr/$DBI::state vraceji totez co
    # po neuspesnem DBI->connect.
    my (@CALLS, @PLAN);
    my $drh = DBI->install_driver('Sponge');
    no warnings qw(redefine once);
    local *DBI::connect = sub {
        my ($class, $dsn, $user, $pass, $attr) = @_;
        push(@CALLS, {dsn => $dsn, user => $user, pass => $pass, attr => $attr});
        my $r = shift(@PLAN);
        $drh->set_err(undef, undef);
        return $r if (ref($r) eq 'MockDBH');
        $drh->set_err(@{$r});
        return undef;
    };
    use warnings qw(redefine once);

    my $secure = [2061, "Authentication plugin 'caching_sha2_password' reported error: Authentication requires secure connection.", 'HY000'];
    my $base   = 'dbi:mysql:dbname=eshop;host=dbhost;port=3307';
    my %conf   = (host => 'dbhost', port => 3307, login => 'uzivatel', password => 'tajne-heslo', database => 'eshop', homepath => '/tmp/');
    my $try    = sub {
        my ($class, $plan, %extra) = @_;
        @CALLS = ();
        @PLAN  = @{$plan};
        my $d = $class->new;
        return ($d, $d->connect({%conf, %extra}));
    };
    my $dsns = sub { return [map { $_->{'dsn'} } @CALLS]; };

    # MySQL/MariaDB: bez dsn_options se nic nemeni
    my ($r, $w) = (MockDBH->new, MockDBH->new);
    my ($d, $ok) = $try->('Libs::MyDBI::DRIVER::MySQL', [$r, $w]);
    is($ok, 1, 'MySQL connect: uspech vraci 1');
    is_deeply($dsns->(), [$base, $base], 'MySQL DSN bez dsn_options je stejny jako driv (cteci i zapisove spojeni)');
    is_deeply([map { $_->{'attr'}->{'AutoCommit'} } @CALLS], [1, 0], 'cteci spojeni AutoCommit 1, zapisove podle autocommit');
    is_deeply([$CALLS[0]->{'user'}, $CALLS[0]->{'pass'}], ['uzivatel', 'tajne-heslo'], 'login a heslo jdou DBI zvlast');
    unlike(join(' ', @{$dsns->()}), qr/tajne-heslo/, 'heslo neni soucasti DSN');
    ok(($d->{'DBI_R'} == $r and $d->{'DBI_W'} == $w), 'handle ulozene jako DBI_R a DBI_W');
    is_deeply([$r->{'did'}, $w->{'did'}], [['SET NAMES utf8'], ['SET NAMES utf8']], 'SET NAMES na obou spojenich');
    ok(!$d->error(), 'po uspesnem connect bez chyby');

    # doplnkove volby DSN z konfigurace
    ($d, $ok) = $try->('Libs::MyDBI::DRIVER::MySQL', [MockDBH->new, MockDBH->new], dsn_options => 'mysql_ssl=1;mysql_ssl_ca_file=/etc/ssl/db-ca.pem');
    is_deeply($dsns->(), [("$base;mysql_ssl=1;mysql_ssl_ca_file=/etc/ssl/db-ca.pem") x 2], 'dsn_options se pripoji za DSN obou spojeni');
    ($d, $ok) = $try->('Libs::MyDBI::DRIVER::MySQL', [MockDBH->new, MockDBH->new], dsn_options => ' ;mysql_connect_timeout=5; ');
    is_deeply($dsns->(), [("$base;mysql_connect_timeout=5") x 2], 'stredniky a mezery na okrajich dsn_options se oriznou');
    ($d, $ok) = $try->('Libs::MyDBI::DRIVER::MySQL', [MockDBH->new, MockDBH->new], dsn_options => '');
    is_deeply($dsns->(), [$base, $base], 'prazdne dsn_options = puvodni DSN');

    # reconnect() pouzije ulozenou konfiguraci vcetne dsn_options
    ($d, $ok) = $try->('Libs::MyDBI::DRIVER::MySQL', [MockDBH->new, MockDBH->new], dsn_options => 'mysql_ssl=1');
    @CALLS = ();
    @PLAN  = (MockDBH->new, MockDBH->new);
    is($d->reconnect(), 1, 'reconnect vraci 1');
    is_deeply($dsns->(), [("$base;mysql_ssl=1") x 2], 'reconnect sklada stejny DSN vcetne dsn_options');

    # chyba 2061: zalozni pokus s mysql_ssl=1
    ($d, $ok) = $try->('Libs::MyDBI::DRIVER::MySQL', [$secure, MockDBH->new, MockDBH->new]);
    is($ok, 1, 'chyba 2061 (requires secure connection) -> pripojeni pres TLS uspeje (regrese)');
    is_deeply($dsns->(), [$base, "$base;mysql_ssl=1", $base], 'nejdriv puvodni DSN, po 2061 totez s mysql_ssl=1; dalsi spojeni zacina zase puvodnim DSN');
    ok(!$d->error(), 'uspesny zalozni pokus po sobe nenecha chybu 2061');
    ($d, $ok) = $try->('Libs::MyDBI::DRIVER::MySQL', [$secure, MockDBH->new, $secure, MockDBH->new]);
    is($ok, 1, 'zalozni pokus funguje i pro zapisove spojeni');
    is_deeply($dsns->(), [$base, "$base;mysql_ssl=1", $base, "$base;mysql_ssl=1"], 'cteci i zapisove spojeni: puvodni DSN, pak mysql_ssl=1');
    ($d, $ok) = $try->('Libs::MyDBI::DRIVER::MySQL', [$secure, MockDBH->new, MockDBH->new], dsn_options => 'mysql_connect_timeout=5');
    is($dsns->()->[1], "$base;mysql_connect_timeout=5;mysql_ssl=1", 'zalozni pokus zachova dsn_options a prida mysql_ssl=1');

    # TLS rizene konfiguraci: zadny zalozni pokus
    ($d, $ok) = $try->('Libs::MyDBI::DRIVER::MySQL', [$secure, MockDBH->new, MockDBH->new], dsn_options => 'mysql_ssl=0');
    is($ok, 0, 'dsn_options s mysql_ssl=0: chyba 2061 zustane chybou');
    is_deeply($dsns->(), ["$base;mysql_ssl=0"], 'mysql_ssl v dsn_options = jediny pokus, bez pridaneho mysql_ssl=1');
    is($d->getError()->{'err'}, 2061, 'getError vraci kod chyby pripojeni');
    like($d->getError()->{'errstr'}, qr/requires secure connection/, 'getError vraci text chyby pripojeni');
    is($d->getError()->{'state'}, 'HY000', 'getError vraci SQLSTATE chyby pripojeni');

    # jine chyby: bez zalozniho pokusu, zapisove spojeni se uz nezkousi
    ($d, $ok) = $try->('Libs::MyDBI::DRIVER::MySQL', [[2003, "Can't connect to MySQL server on 'dbhost:3307' (111)", 'HY000'], MockDBH->new]);
    is($ok, 0, 'nedostupny server -> 0');
    is_deeply($dsns->(), [$base], 'jina chyba nez 2061: jediny pokus, zadne TLS, zadne zapisove spojeni');
    ok($d->error(), 'neuspesny connect nastavi error()');
    is($d->getError()->{'err'}, 2003, 'chyba pripojeni dostupna pres getError (regrese: nebyla nikde)');

    # zalozni pokus take selze: plati chyba z nej
    ($d, $ok) = $try->('Libs::MyDBI::DRIVER::MySQL', [$secure, [1045, "Access denied for user 'uzivatel'\@'10.0.0.1' (using password: YES)", '28000']]);
    is($ok, 0, 'spatne heslo -> 0 i po zaloznim pokusu');
    is(scalar(@CALLS), 2, 'dva pokusy (puvodni DSN a mysql_ssl=1)');
    is($d->getError()->{'err'}, 1045, 'getError vraci chybu posledniho pokusu');
    unlike($d->getError()->{'errstr'}, qr/tajne-heslo/, 'text chyby neobsahuje heslo');

    # cteci spojeni ano, zapisove ne: cteci se odpoji
    $r = MockDBH->new;
    ($d, $ok) = $try->('Libs::MyDBI::DRIVER::MySQL', [$r, [1040, 'Too many connections', '08004']]);
    is($ok, 0, 'selhani zapisoveho spojeni -> 0');
    is($r->{'disconnected'}, 1, 'cteci spojeni se po selhani zapisoveho odpoji (jinak by zustalo otevrene)');
    is($d->getError()->{'err'}, 1040, 'getError vraci chybu zapisoveho spojeni');

    # uspesny connect smaze chybu predchoziho neuspesneho pokusu
    @CALLS = ();
    @PLAN  = (MockDBH->new, MockDBH->new);
    is($d->connect(), 1, 'dalsi connect bez konfigurace (ulozene hodnoty) uspeje');
    ok(!$d->error(), 'uspesny connect smaze chybu predchoziho pokusu');

    # Nove spojeni zadny zamek spojeni nedrzi: connect() zahodi hodnotu ticheho reconnectu, kterou si ulozil
    # sessionLock nad PUVODNIM spojenim - sessionUnlock ji pak nesmi "vratit" novemu handle.
    $d->{'session_lock_reconnect'} = 0;
    my $w2 = MockDBH->new(mysql_auto_reconnect => 1);
    @PLAN = (MockDBH->new, $w2);
    is($d->connect(), 1, 'MySQL: opakovany connect uspeje');
    ok(!exists($d->{'session_lock_reconnect'}), 'MySQL: connect() maze hodnotu mysql_auto_reconnect ulozenou v sessionLock (nove spojeni zamek nedrzi)');
    is($w2->{'mysql_auto_reconnect'}, 1, 'MySQL: nastaveni noveho spojeni DBI_W connect() nemeni');

    # Postgre
    my $pgbase = 'dbi:Pg:dbname=eshop;host=dbhost;port=3307';
    my $h = MockDBH->new;
    ($d, $ok) = $try->('Libs::MyDBI::DRIVER::Postgre', [$h]);
    is($ok, 1, 'Postgre connect: uspech vraci 1');
    is_deeply($dsns->(), [$pgbase], 'Postgre DSN bez dsn_options je stejny jako driv');
    is($CALLS[0]->{'pass'}, 'tajne-heslo', 'Postgre: heslo jde DBI zvlast');
    is($h->{'pg_enable_utf8'}, 0, 'Postgre: pg_enable_utf8 = 0');
    ($d, $ok) = $try->('Libs::MyDBI::DRIVER::Postgre', [MockDBH->new], dsn_options => 'sslmode=require;connect_timeout=5;');
    is_deeply($dsns->(), ["$pgbase;sslmode=require;connect_timeout=5"], 'Postgre: dsn_options se pripoji za DSN');
    ($d, $ok) = $try->('Libs::MyDBI::DRIVER::Postgre', [[6, "connection to server at \"dbhost\" (10.0.0.5), port 3307 failed: Connection refused\n\tIs the server running on that host and accepting TCP/IP connections?", '08006']]);
    is($ok, 0, 'Postgre: nedostupny server -> 0');
    is(scalar(@CALLS), 1, 'Postgre: jediny pokus');
    is($d->getError()->{'err'}, 6, 'Postgre: chyba pripojeni dostupna pres getError');
    like($d->getError()->{'errstr'}, qr/Connection refused/, 'Postgre: text chyby pripojeni');
    @CALLS = ();
    @PLAN  = (MockDBH->new);
    is($d->connect(), 1, 'Postgre: dalsi connect uspeje');
    ok(!$d->error(), 'Postgre: uspesny connect smaze chybu predchoziho pokusu');
    $d->{'session_locks'} = {'dbversion' => 1};
    @PLAN = (MockDBH->new);
    is($d->connect(), 1, 'Postgre: opakovany connect uspeje');
    is_deeply($d->{'session_locks'}, {}, 'Postgre: nove spojeni zadny zamek urovne session nedrzi (pocitadlo sessionLock se nuluje)');

    # Libs::MyDBI::createConnection: neuspech se loguje vcetne chyby DBI (jeden radek, bez hesla)
    {
        package MockDrvLog;
        sub new { return bless {error => [], debug => []}, $_[0]; }
        sub error { push(@{$_[0]->{'error'}}, $_[1]); }
        sub debug { push(@{$_[0]->{'debug'}}, $_[1]); }
        sub info  { 1 }
        sub delay { 0 }

        package MockDrvConf;
        sub new { return bless {}, $_[0]; }
        sub getValue { return $_[3]; }
    }
    require Libs::MyDBI;
    my $log = MockDrvLog->new;
    my $M   = Libs::MyDBI->new(MockDrvConf->new, $log, undef);
    $M->{'dbdriver'}->{'db1'} = 'mysql';
    @CALLS = ();
    @PLAN  = ($secure, [1045, "Access denied for user 'uzivatel'\@'10.0.0.1' (using password: YES)", '28000']);
    is($M->createConnection('db1', 0, {%conf, dbdriver => 'mysql'}), 0, 'createConnection: neuspesne pripojeni vraci 0');
    is(scalar(@{$log->{'error'}}), 1, 'createConnection: jeden zaznam error');
    is($log->{'error'}->[0], "Connect to mysql dbid:db1 connect_status:0 error:1045 Access denied for user 'uzivatel'\@'10.0.0.1' (using password: YES)", 'log obsahuje kod a text chyby DBI (regrese: jen connect_status:0)');
    unlike($log->{'error'}->[0], qr/tajne-heslo|dbi:mysql/, 'log neobsahuje heslo ani DSN');

    $M->{'dbdriver'}->{'db2'} = 'postgres';
    @PLAN = ([6, "connection to server at \"dbhost\" (10.0.0.5), port 3307 failed: Connection refused\n\tIs the server running on that host and accepting TCP/IP connections?", '08006']);
    $M->createConnection('db2', 0, {%conf, dbdriver => 'postgres'});
    is($log->{'error'}->[1], 'Connect to postgres dbid:db2 connect_status:0 error:6 connection to server at "dbhost" (10.0.0.5), port 3307 failed: Connection refused Is the server running on that host and accepting TCP/IP connections?', 'viceradkova chyba DBI je v logu na jednom radku');

    @PLAN = (MockDBH->new, MockDBH->new);
    is($M->createConnection('db1', 1, {%conf, dbdriver => 'mysql'}), 1, 'createConnection: uspesne pripojeni vraci 1');
    is($log->{'debug'}->[-1], 'Connect to mysql dbid:db1 connect_status:1', 'uspech se loguje beze zmeny (debug)');
    is(scalar(@{$log->{'error'}}), 2, 'uspech nepridava zaznam error');
}

# --- sessionLock/sessionUnlock: zamek vazany na spojeni (zamek migrace v Libs::MyDBI::checkDbversion) ---
# Regrese: zamek migrace byl jen sloupec dbversion.lockid, ktery po padu procesu zustal nastaveny navzdy.
{
    # DBI handle, ktery zaznamena volani selectrow_array a vraci dalsi polozku planu:
    # hodnota (i undef = SQL NULL) = vysledek dotazu, [err, errstr, state] = chyba dotazu.
    package MockLockDBH;
    sub new { my ($c, %a) = @_; return bless {calls => [], plan => [], rolled => 0, AutoCommit => 0, %a}, $c; }
    sub err    { $_[0]->{'err'} }
    sub errstr { $_[0]->{'errstr'} }
    sub state  { $_[0]->{'state'} }
    sub rollback { $_[0]->{'rolled'}++; $_[0]->{'err'} = $_[0]->{'errstr'} = $_[0]->{'state'} = undef; 1 }
    sub selectrow_array {
        my ($s, $sql, $attr, @bind) = @_;
        push(@{$s->{'calls'}}, [$sql, @bind]);
        $s->{'err'} = $s->{'errstr'} = $s->{'state'} = undef;
        my $r = shift(@{$s->{'plan'}});
        if (ref($r) eq 'ARRAY') {
            ($s->{'err'}, $s->{'errstr'}, $s->{'state'}) = @{$r};
            return ();
        }
        return ($r);
    }

    package main;
    require Digest::MD5;
    require Time::HiRes;

    # MySQL/MariaDB: GET_LOCK/RELEASE_LOCK nad zapisovym spojenim DBI_W
    my $d = Libs::MyDBI::DRIVER::MySQL->new;
    ok(($d->can('sessionLock') and $d->can('sessionUnlock')), 'MySQL: ovladac ma sessionLock a sessionUnlock');
    $d->{'database'} = 'eshop';
    is($d->sessionLockName('dbversion'), 'pwe.dbversion.eshop', 'MySQL: jmeno zamku obsahuje nazev databaze (jmena jsou spolecna pro cely server)');
    $d->{'database'} = 'x' x 50;
    is($d->sessionLockName('dbversion'), 'pwe.dbversion.' . ('x' x 50), 'MySQL: jmeno o 64 znacich se jeste nezkracuje');
    $d->{'database'} = 'x' x 51;
    my $long = $d->sessionLockName('dbversion');
    is($long, 'pwe.' . Digest::MD5::md5_hex('pwe.dbversion.' . ('x' x 51)), 'MySQL: delsi jmeno se nahradi otiskem');
    cmp_ok(length($long), '<=', 64, 'MySQL: otisk se vejde do 64 znaku');
    $d->{'database'} = 'y' x 51;
    isnt($d->sessionLockName('dbversion'), $long, 'MySQL: jina databaze = jiny otisk');
    $d->{'database'} = 'eshop';

    my ($r, $w) = (MockLockDBH->new, MockLockDBH->new(plan => [1, 0, undef, [2013, 'Lost connection to MySQL server during query', 'HY000'], 1]));
    $d->{'DBI_R'} = $r;
    $d->{'DBI_W'} = $w;
    is($d->sessionLock('dbversion', 5), 1, 'MySQL: GET_LOCK vrati 1 -> zamek ziskan');
    is_deeply($w->{'calls'}->[0], ['SELECT GET_LOCK(?, 5)', 'pwe.dbversion.eshop'], 'MySQL: GET_LOCK se jmenem zamku a casem cekani');
    ok(!$d->error(), 'MySQL: po ziskani zamku bez chyby');
    is($d->sessionLock('dbversion', 5), 0, 'MySQL: GET_LOCK vrati 0 -> zamek drzi jine spojeni');
    ok(!$d->error(), 'MySQL: obsazeny zamek neni chyba');
    is($d->sessionLock('dbversion', 5), undef, 'MySQL: GET_LOCK vrati NULL -> undef');
    ok($d->error(), 'MySQL: NULL z GET_LOCK je ulozena chyba');
    like($d->getError()->{'errstr'}, qr/GET_LOCK\('pwe\.dbversion\.eshop'\) returned NULL/, 'MySQL: text chyby pro NULL');
    is($d->sessionLock('dbversion', 5), undef, 'MySQL: chyba dotazu -> undef');
    is_deeply($d->getError(), {err => 2013, errstr => 'Lost connection to MySQL server during query', state => 'HY000'}, 'MySQL: chyba dotazu ulozena pres setError');
    is($d->sessionLock('dbversion', 'abc'), 1, 'MySQL: neplatny cas cekani -> jeden pokus');
    is($w->{'calls'}->[-1]->[0], 'SELECT GET_LOCK(?, 0)', 'MySQL: neplatny cas cekani = 0 (do SQL jde jen cele cislo)');
    ok(!$d->error(), 'MySQL: uspesne ziskani zamku smaze predchozi chybu');
    is($d->sessionLock('dbversion'), undef, 'MySQL: vycerpany plan (NULL) -> undef');
    is($w->{'calls'}->[-1]->[0], 'SELECT GET_LOCK(?, 0)', 'MySQL: bez casu cekani = 0');

    @{$w->{'calls'}} = ();
    @{$w->{'plan'}}  = (1, 0, undef, [2006, 'MySQL server has gone away', 'HY000']);
    is($d->sessionUnlock('dbversion'), 1, 'MySQL: RELEASE_LOCK vrati 1 -> uvolneno');
    is_deeply($w->{'calls'}->[0], ['SELECT RELEASE_LOCK(?)', 'pwe.dbversion.eshop'], 'MySQL: RELEASE_LOCK se stejnym jmenem');
    is($d->sessionUnlock('dbversion'), 0, 'MySQL: RELEASE_LOCK vrati 0 (zamek drzi jine spojeni) -> 0');
    is($d->sessionUnlock('dbversion'), 0, 'MySQL: RELEASE_LOCK vrati NULL (zamek neexistuje) -> 0');
    is($d->sessionUnlock('dbversion'), 0, 'MySQL: chyba dotazu -> 0');
    is($d->getError()->{'err'}, 2006, 'MySQL: chyba uvolneni ulozena pres setError');
    is(scalar(@{$r->{'calls'}}), 0, 'MySQL: zamek se bere i uvolnuje jen nad zapisovym spojenim DBI_W (stejny handle)');
    is($w->{'rolled'} + $r->{'rolled'}, 0, 'MySQL: zamek nesaha na transakci (zadny rollback)');

    # Regrese: tichy reconnect ovladace DBD::mysql (mysql_auto_reconnect; ovladac ho sam zapina pri AutoCommit 1
    # a promenne GATEWAY_INTERFACE v prostredi) po zaniku spojeni DBI_W spojeni obnovil BEZ zamku a migrace
    # pokracovala nechranena - soubezne startujici proces jeji lockid prevzal jako opusteny a kroky probehly
    # dvakrat. Po dobu drzeni zamku se proto tichy reconnect vypina a sessionUnlock ho vraci.
    $d->{'session_lock_reconnect'} = 0;    # pozustatek po predchozich blocich (uvolneni, ktere selhalo)
    delete($d->{'session_lock_reconnect'});
    ($r, $w) = (MockLockDBH->new(mysql_auto_reconnect => 1), MockLockDBH->new(plan => [0, 1, 1, 1, 0], mysql_auto_reconnect => 1));
    $d->{'DBI_R'} = $r;
    $d->{'DBI_W'} = $w;
    is($d->sessionLock('dbversion', 1), 0, 'MySQL: zamek drzi jine spojeni');
    is($w->{'mysql_auto_reconnect'}, 1, 'MySQL: bez ziskaneho zamku se tichy reconnect nemeni');
    is($d->sessionLock('dbversion', 1), 1, 'MySQL: zamek ziskan');
    is($w->{'mysql_auto_reconnect'}, 0, 'MySQL: po dobu drzeni zamku je tichy reconnect na DBI_W vypnuty');
    is($r->{'mysql_auto_reconnect'}, 1, 'MySQL: cteci spojeni DBI_R se nemeni');
    is($d->sessionLock('dbversion', 1), 1, 'MySQL: opakovane ziskani zamku');
    is($w->{'mysql_auto_reconnect'}, 0, 'MySQL: tichy reconnect zustava vypnuty');
    is($d->sessionUnlock('dbversion'), 1, 'MySQL: uvolneni zamku');
    is($w->{'mysql_auto_reconnect'}, 1, 'MySQL: sessionUnlock vraci puvodni hodnotu ticheho reconnectu');
    ok(!exists($d->{'session_lock_reconnect'}), 'MySQL: ulozena hodnota se po vraceni maze');
    is($d->sessionUnlock('dbversion'), 0, 'MySQL: dalsi uvolneni vrati 0');
    is($w->{'mysql_auto_reconnect'}, 1, 'MySQL: opakovane uvolneni hodnotu nemeni');

    # puvodne vypnuty tichy reconnect zustava po uvolneni vypnuty; uvolneni, ktere selze, hodnotu vraci take
    $w = MockLockDBH->new(plan => [1, [2006, 'MySQL server has gone away', 'HY000']], mysql_auto_reconnect => 0);
    $d->{'DBI_W'} = $w;
    is($d->sessionLock('dbversion'), 1, 'MySQL: zamek ziskan (tichy reconnect puvodne vypnuty)');
    is($w->{'mysql_auto_reconnect'}, 0, 'MySQL: tichy reconnect vypnuty');
    is($d->sessionUnlock('dbversion'), 0, 'MySQL: uvolneni selze (spojeni zaniklo)');
    is($w->{'mysql_auto_reconnect'}, 0, 'MySQL: puvodne vypnuty tichy reconnect zustava vypnuty');
    ok(!exists($d->{'session_lock_reconnect'}), 'MySQL: po neuspesnem uvolneni nezustava ulozena hodnota');

    # PostgreSQL: poradni zamek urovne session
    my $p = Libs::MyDBI::DRIVER::Postgre->new;
    ok(($p->can('sessionLock') and $p->can('sessionUnlock')), 'Postgre: ovladac ma sessionLock a sessionUnlock');
    my @key = $p->sessionLockKey('dbversion');
    is_deeply(\@key, [unpack('l> l>', Digest::MD5::md5('pwe.dbversion.public'))], 'Postgre: klic = prvnich 8 bajtu MD5 z "pwe.<jmeno>.<schema>"');
    is(scalar(@key), 2, 'Postgre: klic jsou dve cisla');
    ok((!grep { $_ !~ /^-?\d+$/ or $_ < -2147483648 or $_ > 2147483647 } @key), 'Postgre: obe cisla jsou int4 se znamenkem');
    is_deeply([$p->sessionLockKey('dbversion')], \@key, 'Postgre: klic je stabilni');
    $p->{'schema'} = 'eshop';
    isnt(join(',', $p->sessionLockKey('dbversion')), join(',', @key), 'Postgre: jine schema = jiny klic');
    $p->{'schema'} = 'public';
    # Prvni ziskani: dotaz nejdriv overi v pg_locks, ze zamek uz nedrzi samo serverove spojeni (hodnota 2).
    my $relock = "SELECT CASE WHEN pg_try_advisory_lock($key[0], $key[1]) THEN 1 ELSE 0 END";
    my $lock   = "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND classid = ($key[0])::oid AND objid = ($key[1])::oid AND objsubid = 2) THEN 2 WHEN pg_try_advisory_lock($key[0], $key[1]) THEN 1 ELSE 0 END";
    my $unlock = "SELECT CASE WHEN pg_advisory_unlock($key[0], $key[1]) THEN 1 ELSE 0 END";

    my $h = MockLockDBH->new(plan => [1, 1, 1, 1, 1, 1, 1, 0]);
    $p->{'DBI'} = $h;
    is($p->sessionLock('dbversion', 5), 1, 'Postgre: zamek ziskan na prvni pokus');
    is_deeply($h->{'calls'}, [[$lock]], 'Postgre: pg_try_advisory_lock (uroven session), ne pg_advisory_xact_lock; pred nim kontrola pg_locks');
    unlike($h->{'calls'}->[0]->[0], qr/xact/, 'Postgre: zadny transakcni zamek (ten by commit uvolnil)');

    # Opakovane ziskani tymz objektem (zamek je v ramci session opakovatelny) a pocitadlo vlastnich zamku
    is($p->sessionLock('dbversion', 5), 1, 'Postgre: tentyz objekt ziska zamek opakovane');
    is($h->{'calls'}->[1]->[0], $relock, 'Postgre: vlastni zamek se podruhe bere bez kontroly pg_locks');
    is($p->sessionUnlock('dbversion'), 1, 'Postgre: prvni uvolneni opakovane ziskaneho zamku');
    is($p->sessionLock('dbversion', 5), 1, 'Postgre: zamek stale drzime -> dalsi ziskani');
    is($h->{'calls'}->[3]->[0], $relock, 'Postgre: dokud objekt zamek drzi, kontrola pg_locks se nedela');
    is($p->sessionUnlock('dbversion'), 1, 'Postgre: druhe uvolneni');
    is($p->sessionUnlock('dbversion'), 1, 'Postgre: treti uvolneni - zamek je volny');
    is($p->sessionLock('dbversion', 5), 1, 'Postgre: nove ziskani po uplnem uvolneni');
    is($h->{'calls'}->[6]->[0], $lock, 'Postgre: po uplnem uvolneni se pg_locks kontroluje znovu');
    is($p->sessionUnlock('dbversion'), 0, 'Postgre: uvolneni vrati 0 - zamek toto serverove spojeni nedrzi');
    ok(!$p->{'session_locks'}->{'dbversion'}, 'Postgre: po neuspesnem uvolneni objekt zadny vlastni zamek neeviduje');

    # Regrese: za poolerem v rezimu transaction pooling (PgBouncer) dostal klient serverove spojeni, na
    # kterem zamek vzal JINY klient. pg_try_advisory_lock tam vrati true (zamek je v ramci session
    # opakovatelny), engine si myslel, ze zamek drzi, prevzal lockid ziveho procesu a kroky migrace
    # probehly dvakrat. Dotaz proto vraci 2 a sessionLock undef (migrace pak chrani jen sloupec lockid).
    foreach my $autocommit (0, 1) {
        $h = MockLockDBH->new(plan => [2, 1], AutoCommit => $autocommit);
        $p->{'DBI'} = $h;
        is($p->sessionLock('dbversion', 5), undef, "Postgre: zamek uz drzi serverove spojeni (cizi klient za poolerem) -> undef (AutoCommit $autocommit)");
        is_deeply($h->{'calls'}, [[$lock]], 'Postgre: zadny dalsi pokus, zamek se nebere');
        is_deeply($p->getError(), {err => -1, errstr => 'advisory lock is already held by this server connection (connection pooler in transaction mode?)', state => undef}, 'Postgre: chyba popisuje pricinu (getError)');
        ok($p->error(), 'Postgre: cizi zamek na serverovem spojeni je chyba (error)');
        is($h->{'rolled'}, 0, 'Postgre: transakce volajiciho se nevraci (zadny rollback)');
        ok(!$p->{'session_locks'}->{'dbversion'}, 'Postgre: objekt zamek neeviduje jako vlastni');
    }
    $h = MockLockDBH->new(plan => [0, 2]);
    $p->{'DBI'} = $h;
    is($p->sessionLock('dbversion', 5), undef, 'Postgre: cizi zamek na serverovem spojeni zjisteny az behem cekani -> undef');
    is(scalar(@{$h->{'calls'}}), 2, 'Postgre: cekani konci hned po zjisteni');
    $h = MockLockDBH->new(plan => [1]);
    $p->{'DBI'} = $h;
    is($p->sessionLock('dbversion'), 1, 'Postgre: dalsi pokus bez ciziho zamku uspeje');
    ok(!$p->error(), 'Postgre: uspesne ziskani smaze chybu');
    $p->{'session_locks'} = {};    # dalsi bloky zacinaji s novym handlem = spojenim bez vlastniho zamku

    $h = MockLockDBH->new(plan => [0, 0, 0]);
    $p->{'DBI'} = $h;
    is($p->sessionLock('dbversion', 0), 0, 'Postgre: obsazeny zamek a cas 0 -> 0');
    is(scalar(@{$h->{'calls'}}), 1, 'Postgre: cas 0 = jediny pokus');
    ok(!$p->error(), 'Postgre: obsazeny zamek neni chyba');
    is($p->sessionLock('dbversion'), 0, 'Postgre: bez casu = jediny pokus');
    is(scalar(@{$h->{'calls'}}), 2, 'Postgre: bez casu jediny dalsi pokus');

    $h = MockLockDBH->new(plan => [0, 0, 1]);
    $p->{'DBI'} = $h;
    my $t0 = Time::HiRes::time();
    is($p->sessionLock('dbversion', 5), 1, 'Postgre: zamek ziskan po uvolneni jinym spojenim');
    is(scalar(@{$h->{'calls'}}), 3, 'Postgre: pokusy v cyklu (dva neuspesne, treti uspesny)');
    cmp_ok(Time::HiRes::time() - $t0, '<', 2, 'Postgre: cyklus konci hned po ziskani zamku, ne az po vyprseni casu');

    $h = MockLockDBH->new(plan => [(0) x 50]);
    $p->{'DBI'} = $h;
    $t0 = Time::HiRes::time();
    is($p->sessionLock('dbversion', 0.5), 0, 'Postgre: zamek obsazeny po celou dobu -> 0');
    my $took = Time::HiRes::time() - $t0;
    ok(($took >= 0.45 and $took < 2), 'Postgre: cekani trva zadany cas') or diag("trvalo $took s");
    cmp_ok(scalar(@{$h->{'calls'}}), '>=', 3, 'Postgre: behem cekani se zamek zkousi opakovane');

    $h = MockLockDBH->new(plan => [[7, 'ERROR:  current transaction is aborted', '25P02']], AutoCommit => 0);
    $p->{'DBI'} = $h;
    is($p->sessionLock('dbversion', 5), undef, 'Postgre: chyba dotazu -> undef (bez dalsich pokusu)');
    is(scalar(@{$h->{'calls'}}), 1, 'Postgre: po chybe zadny dalsi pokus');
    is($p->getError()->{'state'}, '25P02', 'Postgre: chyba ulozena pres setError (zustava i po rollbacku)');
    is($h->{'rolled'}, 1, 'Postgre: vypnuty autocommit -> po chybe rollback (spojeni nezustane ve zrusene transakci)');
    $h = MockLockDBH->new(plan => [[7, 'ERROR:  function pg_try_advisory_lock does not exist', '42883']], AutoCommit => 1);
    $p->{'DBI'} = $h;
    is($p->sessionLock('dbversion', 5), undef, 'Postgre: chyba dotazu se zapnutym autocommitem -> undef');
    is($h->{'rolled'}, 0, 'Postgre: zapnuty autocommit -> zadny rollback');

    $h = MockLockDBH->new(plan => [1, 0]);
    $p->{'DBI'} = $h;
    is($p->sessionUnlock('dbversion'), 1, 'Postgre: pg_advisory_unlock vrati true -> 1');
    is_deeply($h->{'calls'}, [[$unlock]], 'Postgre: pg_advisory_unlock se stejnym klicem');
    is($p->sessionUnlock('dbversion'), 0, 'Postgre: zamek toto spojeni nedrzi -> 0');
    is($h->{'rolled'}, 0, 'Postgre: uvolneni bez chyby nesaha na transakci');

    $h = MockLockDBH->new(plan => [[7, 'ERROR:  current transaction is aborted, commands ignored until end of transaction block', '25P02'], 1]);
    $p->{'DBI'} = $h;
    is($p->sessionUnlock('dbversion'), 1, 'Postgre: zrusena transakce -> rollback a druhy pokus zamek uvolni');
    is($h->{'rolled'}, 1, 'Postgre: prave jeden rollback');
    is(scalar(@{$h->{'calls'}}), 2, 'Postgre: dva pokusy o uvolneni');
    ok(!$p->error(), 'Postgre: po uspesnem druhem pokusu bez chyby');

    $h = MockLockDBH->new(plan => [[7, 'ERROR:  current transaction is aborted', '25P02'], [7, 'ERROR:  current transaction is aborted', '25P02'], 1]);
    $p->{'DBI'} = $h;
    is($p->sessionUnlock('dbversion'), 0, 'Postgre: ani druhy pokus neuspel -> 0');
    is(scalar(@{$h->{'calls'}}), 2, 'Postgre: nejvys dva pokusy o uvolneni');

    $h = MockLockDBH->new(plan => [[7, 'server closed the connection unexpectedly', '08006'], 1]);
    $p->{'DBI'} = $h;
    is($p->sessionUnlock('dbversion'), 0, 'Postgre: jina chyba (ztracene spojeni) -> 0');
    is(scalar(@{$h->{'calls'}}), 1, 'Postgre: jina chyba se neopakuje');
    is($h->{'rolled'}, 0, 'Postgre: jina chyba bez rollbacku');
    is($p->getError()->{'state'}, '08006', 'Postgre: chyba uvolneni ulozena pres setError');

    # DESTROY ovladacu vola rollback nad handle - at po sobe test nenecha varovani
    $d->{'DBI_R'} = MockDBH->new;
    $d->{'DBI_W'} = MockDBH->new;
    $p->{'DBI'}   = MockDBH->new;
}

done_testing();
