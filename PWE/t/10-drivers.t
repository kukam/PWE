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

done_testing();
