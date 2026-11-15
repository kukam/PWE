#!/usr/bin/env perl
# Libs::MyDBI::DAO - DAO nad mock spojenim: validace sloupcu, unikatnost, generovani SQL, flush, pool lock.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PWE::TestEnv;

# ---------------------------------------------------------------------------
# Mock DB spojeni (rozhrani Libs::MyDBI::DRIVER::*) a mock statement handle.
# ---------------------------------------------------------------------------
package MockSTH;
sub new { my ($c, $rows) = @_; return bless {rows => [@{$rows || []}]}, $c; }
sub fetchrow_array { my $r = shift @{$_[0]->{'rows'}}; return () unless ($r); return (ref($r) eq 'ARRAY' ? @{$r} : %{$r}); }
sub fetchall_hashref { my ($s, $key) = @_; my %h; foreach my $r (@{$s->{'rows'}}) { $h{$r->{$key}} = $r if (ref($r) eq 'HASH'); } return \%h; }
sub finish { 1 }

package MockDBC;
sub new { return bless {lock => 0, calls => [], rows => [], err => undef, errstr => undef, last_id => 42, update_rv => 1}, shift; }
sub setPoolLock { $_[0]->{'lock'} = ($_[1] ? 1 : 0); }
sub getPoolLock { $_[0]->{'lock'} }
sub select { my ($s, $q, $v) = @_; push(@{$s->{'calls'}}, ['SELECT', $q, [@{$v || []}]]); return MockSTH->new($s->{'rows'}); }
sub insert { my ($s, $q, $v) = @_; push(@{$s->{'calls'}}, ['INSERT', $q, [@{$v}]]); }
sub update { my ($s, $q, $v) = @_; push(@{$s->{'calls'}}, ['UPDATE', $q, [@{$v}]]); return $s->{'update_rv'}; }
sub delete { my ($s, $q, $v) = @_; push(@{$s->{'calls'}}, ['DELETE', $q, [@{$v}]]); }
sub command { my ($s, $q) = @_; push(@{$s->{'calls'}}, ['COMMAND', $q]); }
sub lastInsertID { $_[0]->{'last_id'} }
sub error { defined($_[0]->{'err'}) ? 1 : 0 }
sub getError { return {err => $_[0]->{'err'}, errstr => $_[0]->{'errstr'}, state => undef}; }
sub commit { push(@{$_[0]->{'calls'}}, ['COMMIT']); 1 }
sub rollback { push(@{$_[0]->{'calls'}}, ['ROLLBACK']); 1 }
sub disconnect { 1 }
sub last_call { $_[0]->{'calls'}->[-1] }
sub calls_of { my ($s, $t) = @_; return grep { $_->[0] eq $t } @{$s->{'calls'}}; }

package main;

my $E = PWE::TestEnv->core();
my ($LOG, $V) = @{$E}{qw(LOG VALIDATE)};
require Libs::MyDBI::DAO;

sub cols {
    return {
        id      => {COLUMN_PRIMARY => 1, COLUMN_TYPE => 'INT',       COLUMN_SIZE => 10,    COLUMN_NULLABLE => 0, COLUMN_DEF => undef,               COLUMN_UNSIGNED => 1, COLUMN_UNIQUE => 0},
        name    => {COLUMN_PRIMARY => 0, COLUMN_TYPE => 'VARCHAR',   COLUMN_SIZE => 5,     COLUMN_NULLABLE => 1, COLUMN_DEF => undef,               COLUMN_UNSIGNED => 0, COLUMN_UNIQUE => 1},
        active  => {COLUMN_PRIMARY => 0, COLUMN_TYPE => 'ENUM',      COLUMN_SIZE => 1,     COLUMN_NULLABLE => 0, COLUMN_DEF => 'f',                 COLUMN_UNSIGNED => 0, COLUMN_UNIQUE => 0, COLUMN_ENUM_VALUE => ['t', 'f']},
        flag    => {COLUMN_PRIMARY => 0, COLUMN_TYPE => 'TINYINT',   COLUMN_SIZE => 3,     COLUMN_NULLABLE => 1, COLUMN_DEF => '0',                 COLUMN_UNSIGNED => 1, COLUMN_UNIQUE => 0},
        price   => {COLUMN_PRIMARY => 0, COLUMN_TYPE => 'DECIMAL',   COLUMN_SIZE => 10,    COLUMN_NULLABLE => 1, COLUMN_DEF => undef,               COLUMN_UNSIGNED => 0, COLUMN_UNIQUE => 0},
        note    => {COLUMN_PRIMARY => 0, COLUMN_TYPE => 'TEXT',      COLUMN_SIZE => 65535, COLUMN_NULLABLE => 1, COLUMN_DEF => undef,               COLUMN_UNSIGNED => 0, COLUMN_UNIQUE => 0},
        isok    => {COLUMN_PRIMARY => 0, COLUMN_TYPE => 'boolean',   COLUMN_SIZE => 1,     COLUMN_NULLABLE => 1, COLUMN_DEF => undef,               COLUMN_UNSIGNED => 0, COLUMN_UNIQUE => 0},
        created => {COLUMN_PRIMARY => 0, COLUMN_TYPE => 'TIMESTAMP', COLUMN_SIZE => 19,    COLUMN_NULLABLE => 0, COLUMN_DEF => 'CURRENT_TIMESTAMP', COLUMN_UNSIGNED => 0, COLUMN_UNIQUE => 0},
        updated => {COLUMN_PRIMARY => 0, COLUMN_TYPE => 'TIMESTAMP', COLUMN_SIZE => 19,    COLUMN_NULLABLE => 1, COLUMN_DEF => undef,               COLUMN_UNSIGNED => 0, COLUMN_UNIQUE => 0},
    };
}

my $dbc = MockDBC->new;
my $D = Libs::MyDBI::DAO->new('mysql', $dbc, $LOG, $V, 'items', cols(), 1, 0);

is($dbc->getPoolLock(), 1, 'nesdileny DAO zamkne pool spojeni');
is($D->getTableName(), 'items', 'getTableName');
is($D->getPrimaryColumnName(), 'id', 'primarni sloupec detekovan');
is($D->getValue('id', 'unique'), 1, 'primarni sloupec je unique');
is_deeply([sort @{$D->getMethodList()}], [sort keys %{cols()}], 'getMethodList = sloupce');
ok($D->getRewrite(), 'TABLE je zapisovatelna');
ok($D->existsPublicMethodName('name'), 'existsPublicMethodName');
ok(!$D->existsPublicMethodName('nope'), 'existsPublicMethodName neexistujici');
ok($D->existsInternalMethodName('flush'), 'existsInternalMethodName detekuje interni metodu (regrese: spatny nazev paketu)');
ok(!$D->existsInternalMethodName('name'), 'existsInternalMethodName sloupec');
is($D->getValue('active', 'value'), 'f', 'vychozi hodnota z COLUMN_DEF');

{
    my $dbc2 = MockDBC->new;
    eval { Libs::MyDBI::DAO->new('mysql', $dbc2, $LOG, $V, 'bad', {flush => {COLUMN_TYPE => 'INT'}}, 1, 0) };
    like($@, qr/DAO ERROR/, 'sloupec pojmenovany jako interni metoda -> die');
}

# --- getter/setter pres AUTOLOAD + validace typu ------------------------------
$D->setChangeList({});
is($D->name('abc'), 'abc', 'setter vraci hodnotu');
is($D->name(), 'abc', 'getter');
is_deeply($D->getChangeList(), ['name'], 'changelist');
ok(!defined($D->name('toolong')), 'VARCHAR presah -> undef');
ok($D->error(), 'error() po neplatne hodnote');
like(join(' ', @{$D->getErrorList()}), qr/VARCHAR/, 'errorlist obsahuje typ');
is($D->name(), 'abc', 'puvodni hodnota zustala');
$D->setErrorList({});
ok(!$D->error(), 'setErrorList({}) vycisti chyby');

ok(!defined($D->active('x')), 'ENUM neplatna hodnota');
$D->setErrorList({});
is($D->active('t'), 't', 'ENUM platna hodnota');
ok(!defined($D->flag(300)), 'TINYINT 300 -> chyba (regrese is_sql_tinyint)');
$D->setErrorList({});
is($D->flag(5), 5, 'TINYINT 5 OK');
ok(!defined($D->price('abc')), 'DECIMAL text');
$D->setErrorList({});
is($D->price('12.50'), '12.50', 'DECIMAL OK');
is($D->isok('true'), 1, 'boolean true -> 1');
is($D->isok('f'), 0, 'boolean f -> 0');
ok(!defined($D->id('abc')), 'INT text');
$D->setErrorList({});
ok(!defined($D->id(-1)), 'INT unsigned zaporne');
$D->setErrorList({});
{
    my @w; local $SIG{__WARN__} = sub { push(@w, @_) };
    ok(!defined($D->nope('x')), 'neznamy sloupec -> undef');
}
is($D->name('NULL'), 'NULL', 'literal NULL projde');
ok(!defined($D->name(undef)), 'undef u nullable sloupce projde');
ok(!$D->error(), 'bez chyby');
is(ref($D->getMirroredData()), 'HASH', 'getMirroredData');
is($D->getMirroredData()->{'active'}, 't', 'getMirroredData hodnota');

# --- INSERT dotaz ---------------------------------------------------------------
$D->clearAllMethod();
$D->setChangeList({});
# note/created: hodnota se musi nejdrive zmenit, prazdny retezec nad undef ani default nad defaultem neni zmena
$D->name('ab'); $D->active('t'); $D->flag(''); $D->note('x'); $D->note(''); $D->updated('NOW()'); $D->created('x'); $D->created('CURRENT_TIMESTAMP'); $D->price('NULL');
my ($q, $vals) = $D->createInsertQuery('tester');
like($q, qr{^/\* DAO:items tester \*/ INTO `items` \(}, 'INSERT prefix + backticks (mysql)');
my ($cols, $ph) = $q =~ /\((.*?)\) VALUES \((.*)\)$/;
my %pair; @pair{split(/, /, $cols)} = split(/, /, $ph);
is($pair{'`name`'},    '?',                 'INSERT bezna hodnota -> placeholder');
is($pair{'`active`'},  '?',                 'INSERT enum -> placeholder');
is($pair{'`flag`'},    '0',                 'INSERT prazdna hodnota s defaultem -> default');
is($pair{'`note`'},    'NULL',              'INSERT prazdna hodnota bez defaultu -> NULL');
is($pair{'`price`'},   'NULL',              'INSERT literal NULL');
is($pair{'`updated`'}, 'NOW()',             'INSERT NOW()');
is($pair{'`created`'}, 'CURRENT_TIMESTAMP', 'INSERT CURRENT_TIMESTAMP');
is_deeply([sort @{$vals}], ['ab', 't'], 'INSERT bind hodnoty');

# --- UPDATE / DELETE dotaz ------------------------------------------------------
$D->setPrimaryValue(7);
($q, $vals) = $D->createUpdateQuery('tester');
like($q, qr{^/\* DAO:items tester \*/ `items` SET .* WHERE `id` = \?$}, 'UPDATE tvar');
is($vals->[-1], 7, 'UPDATE posledni bind = primarni klic');
like($q, qr/`updated` = NOW\(\)/, 'UPDATE NOW()');
like($q, qr/`note` = NULL/, 'UPDATE prazdna -> NULL');
like($q, qr/`flag` = \?/, 'UPDATE prazdna s defaultem -> placeholder');
($q, $vals) = $D->createDeleteQuery('t');
is($q, '/* DAO:items t */ FROM `items` WHERE `id` = ?', 'DELETE tvar');
is_deeply($vals, [7], 'DELETE bind');

{
    my $DP = Libs::MyDBI::DAO->new('postgres', MockDBC->new, $LOG, $V, 'items', cols(), 1, 1);
    $DP->setChangeList({});
    $DP->name('x');
    my ($qp) = $DP->createInsertQuery('t');
    like($qp, qr/INTO items \(name\) VALUES \(\?\)/, 'postgres bez backticku');
}

# --- flush: INSERT ---------------------------------------------------------------
$D->clearAllMethod();
$D->setChangeList({});
$dbc->{'calls'} = [];
$D->name('zz');
my $id = $D->flush();
is($id, 42, 'flush INSERT vraci lastInsertID');
is($D->getPrimaryValue(), 42, 'primarni hodnota nastavena po INSERTu');
is($D->getRunDBMethod(), 'INSERT', 'getRunDBMethod');
is(scalar($dbc->calls_of('INSERT')), 1, 'jeden INSERT');
my @sel = $dbc->calls_of('SELECT');
is(scalar(@sel), 1, 'unikatni kontrola name pres SELECT');
like($sel[0]->[1], qr/CHECK FOR UNIQUE VALUE/, 'SELECT je unikatni kontrola');
$D->setChangeList({});
is($D->flush(), 42, 'flush bez zmen vraci primarni klic');

# --- flush: UPDATE ---------------------------------------------------------------
$dbc->{'calls'} = [];
$D->name('yy');
is($D->flush(), 42, 'flush UPDATE vraci primarni klic');
my @upd = $dbc->calls_of('UPDATE');
is(scalar(@upd), 1, 'jeden UPDATE');
like($upd[0]->[1], qr/WHERE `id` = \?/, 'UPDATE podle PK');
is($upd[0]->[2]->[-1], 42, 'UPDATE bind PK');
@sel = $dbc->calls_of('SELECT');
like($sel[0]->[1], qr/AND `id` != \?/, 'unikatni kontrola pri UPDATE vylucuje vlastni radek');

# --- unikatnost ------------------------------------------------------------------
$dbc->{'rows'} = [[1]];
$dbc->{'calls'} = [];
$D->name('dup');
ok(!defined($D->flush()), 'flush pri duplicite vraci undef');
ok($D->existsUniqueError(), 'existsUniqueError');
is(scalar($dbc->calls_of('UPDATE')), 0, 'zadny UPDATE pri duplicite');
$dbc->{'rows'} = [];
$D->setErrorList({});
$D->setUniqueCheckValue(0);
ok(!defined($D->getUniqueCheckValue()), 'setUniqueCheckValue(0)');
$dbc->{'rows'} = [[1]];
$dbc->{'calls'} = [];
$D->name('dup2');
is($D->flush(), 42, 'bez unikatni kontroly flush projde');
is(scalar($dbc->calls_of('SELECT')), 0, 'bez unikatni kontroly zadny SELECT');
$D->setUniqueCheckValue(1);
$dbc->{'rows'} = [];

# --- DELETE_ROW --------------------------------------------------------------------
$dbc->{'calls'} = [];
$D->DELETE_ROW();
is($dbc->last_call()->[0], 'DELETE', 'DELETE_ROW');
is($D->getRunDBMethod(), 'DELETE', 'getRunDBMethod DELETE');
$D->setPrimaryValue(undef);
$dbc->{'calls'} = [];
$D->DELETE_ROW();
is(scalar(@{$dbc->{'calls'}}), 0, 'DELETE_ROW bez PK nic neprovede');

# --- refreshTABLE ------------------------------------------------------------------
$dbc->{'rows'} = [{id => 9, name => 'load', active => 't', flag => 1, price => undef, note => 'n', isok => 1, created => '2024-01-01 00:00:00', updated => undef}];
$D->refreshTABLE('id = ?', [9]);
is($D->getPrimaryValue(), 9, 'refreshTABLE nastavi PK');
is($D->name(), 'load', 'refreshTABLE nacte hodnoty');
is_deeply($D->getChangeList(), [], 'po nacteni je changelist prazdny');
$dbc->{'rows'} = [];
$D->clearAllMethod();
ok(!defined($D->getPrimaryValue()), 'clearAllMethod vynuluje PK');
eval { $D->refreshTABLE('id = ?', [999]) };
ok(!$@, 'refreshTABLE bez vysledku nespadne') or diag($@);

# --- VIEW (rewrite = 0) ------------------------------------------------------------
{
    my $DV = Libs::MyDBI::DAO->new('mysql', MockDBC->new, $LOG, $V, 'v_items', cols(), 0, 1);
    $DV->setChangeList({});
    $DV->name('x');
    ok(!defined($DV->flush()), 'VIEW: flush -> undef');
    ok(!defined($DV->DELETE_ROW()), 'VIEW: DELETE_ROW -> undef');
}

# --- commit / rollback / logit / chyby DB -------------------------------------------
$dbc->{'calls'} = [];
$D->name('c');
$D->commit();
is($dbc->last_call()->[0], 'COMMIT', 'commit');
is_deeply($D->getChangeList(), [], "commit vycisti seznam zmen (regrese: drzena entita by pri dalsim flush znovu UPDATEovala)");
$D->name("r");
is_deeply($D->getChangeList(), ["name"], "po commitu se nove zmeny eviduji znovu");
$D->rollback();
is($dbc->last_call()->[0], 'ROLLBACK', 'rollback');
is_deeply($D->getChangeList(), [], 'rollback vycisti zmeny');
$D->name('l');
eval { $D->logit('test') };
ok(!$@, 'logit nespadne') or diag($@);
$dbc->{'err'} = 1054; $dbc->{'errstr'} = 'Unknown column';
ok($D->error(), 'chyba spojeni se propaguje');
like($D->getError()->{'errstr'}, qr/Unknown column/, 'getError errstr');
is(ref($D->getError()->{'items'}), 'ARRAY', 'getError obsahuje errorlist tabulky');
$dbc->{'err'} = undef; $dbc->{'errstr'} = undef;

# --- DESTROY a pool lock -----------------------------------------------------------
undef $D;
is($dbc->getPoolLock(), 0, 'DESTROY nesdileneho DAO uvolni pool lock');
{
    my $dbc3 = MockDBC->new;
    $dbc3->setPoolLock(1);
    { my $DS = Libs::MyDBI::DAO->new('mysql', $dbc3, $LOG, $V, 'items', cols(), 1, 1); }
    is($dbc3->getPoolLock(), 1, 'sdileny DAO lock nemeni');
}

# --- createDAO: plny pool -> DAO dostane sdilene spojeni 0 a NESMI ho pri zaniku odemknout (regrese) ---
{
    require Libs::MyDBI;
    my $M = Libs::MyDBI->new($E->{'CONF'}, $LOG, $V);
    my $p0 = MockDBC->new; $p0->setPoolLock(1);
    my $p1 = MockDBC->new; $p1->setPoolLock(1);
    $M->{'DBC'}->{'dbx'} = {0 => $p0, 1 => $p1};
    $M->{'dbdriver'}->{'dbx'} = 'mysql';
    my $F = $M->createDAO('dbx', 'items', {TABLE_TYPE => 'TABLE', TABLE_COLUMNS => cols()}, 0);
    ok($F, 'createDAO pri plnem poolu vrati DAO');
    is($F->{'is_share_dbpool'}, 1, 'DAO nad poolem 0 je oznacen jako sdileny');
    undef $F;
    is($p0->getPoolLock(), 1, 'zamek sdileneho spojeni 0 zustal po DESTROY zamceny');
    is($p1->getPoolLock(), 1, 'ostatni pooly beze zmeny');
    ok(!$M->createDAO('dbx', 'v', {TABLE_TYPE => 'WEIRD', TABLE_COLUMNS => {}}, 1), 'neznamy typ tabulky -> undef');
}

done_testing();
