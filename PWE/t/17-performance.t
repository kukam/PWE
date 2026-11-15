#!/usr/bin/env perl
# Regresni testy vykonnostnich a architektonickych oprav (2026-11-08, 6. kolo):
# cache Template objektu, MIME typy statiky, ping DB jen jednou za interval, session bez druheho SELECTu,
# atomicky zapis opts, omezeni chybovych reportu, SQL komentar jen pri loglevel >= 3, local $SIG{__DIE__}.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PWE::TestEnv;

my $ROOT = PWE::TestEnv::root();
my $APP2 = PWE::TestEnv::app2();
plan skip_all => 'chybi Template' unless (eval { require Template; 1 });

my $E = PWE::TestEnv->boot(app => $APP2, core => $ROOT);
my ($C, $W, $P, $U, $LOG) = @{$E}{qw(CONF WEB PAGES USER LOG)};
PWE::TestEnv::request($E, page => 'tPage2', func => 'default');

# --- 1a. cache Template objektu -----------------------------------------------------------------------
{
    my $t1 = $W->genTemplateObject();
    my $t2 = $W->genTemplateObject();
    is("$t1", "$t2", 'genTemplateObject vraci stejny objekt pro stejne volby (cache)');
    my $t3 = $W->genTemplateObject('postchomp' => 1, 'prechomp' => 1, 'trim' => 1);
    isnt("$t3", "$t1", 'jine volby = jiny objekt');
    is("$t3", "" . $W->genTemplateObject('trim' => 1, 'prechomp' => 1, 'postchomp' => 1), 'klic cache nezavisi na poradi voleb');
    $W->flush();
    is("$t1", "" . $W->genTemplateObject(), 'cache prezije flush()');
    like($W->genTmpl('templates/messenger.html', msg_error => ['x'], msg => {x => 'Y'}), qr/<li>Y<\/li>/, 'render pres cachovany objekt funguje');

    # regrese 2.1.0: cache objektu Template + templates/DumpData.tmpl mazal z ziveho stashe _PARENT -> promenne
    # zustavaly ve sdilenem stashi a pretekaly do dalsich requestu (i jinych uzivatelu)
    like($W->genTmpl('templates/DumpData.tmpl', tajne => 'UNIKAT123'), qr/UNIKAT123/, 'DumpData vypise promenne aktualniho renderu');
    is($W->genTmpl('x[% tajne %]x'), 'xx', 'po DumpData dalsi render promennou nevidi (lokalizace zustala)');
    $W->genTmpl('[% PERL %] delete $stash->{_PARENT}; [% END %][% tajne2 %]', tajne2 => 'UNIKAT456');
    is($W->genTmpl('y[% tajne2 %]y'), 'yy', 'pojistka resetTemplateStash: ani sablona mazajici _PARENT nepropusti promenne dal');
}

# --- 1b. MIME typy statiky (systemPage::file) ---------------------------------------------------------------
sub serve {
    my ($path) = @_;
    PWE::TestEnv::request($E, page => 'systemPage', func => 'file', env => {SCRIPT_FILENAME => $path});
    my ($out, $rc) = PWE::TestEnv::capture(sub { $P->callPageFunc('systemPage', 'file') });
    PWE::TestEnv::finish($E);
    my ($head, $body) = split(/\n\n/, $out, 2);
    return ($head || '', $body, $rc);
}
{
    my ($h, $b) = serve('/static/images/dot.png');
    like($h, qr/^Content-Type: image\/png$/m, 'png -> image/png (drive octet-stream priloha)');
    unlike($h, qr/Content-disposition/i, 'png: bez Content-disposition');
    unlike($h, qr/Set-Cookie/, 'statika bez session cookie');
    like($h, qr/^Cache-Control: max-age=/m, 'statika ma cache hlavicku');
    open(my $fh, '<', "${APP2}static/images/dot.png") or die $!; binmode($fh); local $/; my $png = <$fh>; close($fh);
    is(length($b), length($png), 'binarni obsah neporusen (delka)');
    ok($b eq $png, 'binarni obsah neporusen (bajty)');

    ($h) = serve('/assets/images/ajax-loader.gif');
    like($h, qr/^Content-Type: image\/gif$/m, 'gif z enginu -> image/gif');
    ($h) = serve('/assets/javascript/pwe.js');
    like($h, qr/^Content-Type: application\/javascript/m, 'js -> application/javascript');
    ($h) = serve('/static/css/site.css');
    like($h, qr/^Content-Type: text\/css/m, 'css -> text/css');
    ($h) = serve('/assets/css/fontawesome-free-6.4.2/all.min.css');
    like($h, qr/^Content-Type: text\/css/m, 'css enginu -> text/css');
    ($h) = serve('/static/test.bin');
    like($h, qr/^Content-Type: application\/octet-stream$/m, 'neznama pripona -> octet-stream (bez stredniku)');
    like($h, qr/^Content-disposition: attachment; filename=test\.bin/m, 'neznama pripona -> priloha');
    my (undef, undef, $rc) = serve('/static/neexistuje.png');
    is($rc, 404, 'neexistujici soubor -> 404');
}

# --- 2a. ping DB jen jednou za pwe.db_ping_interval -------------------------------------------------------------
{
    package MockPingDriver;
    sub new { return bless {pings => 0, reconnects => 0}, shift; }
    sub ping { $_[0]->{'pings'}++; 1 }
    sub reconnect { $_[0]->{'reconnects'}++; 1 }
    sub disconnect { 1 }
    package main;

    require Libs::MyDBI;
    my $M = Libs::MyDBI->new($C, $LOG, $E->{'VALIDATE'});
    my $d = MockPingDriver->new;
    $M->{'DBC'}->{'dbx'} = {0 => $d};
    local $C->{'pwe'}->{'db_ping_interval'} = 60;
    $M->testConnection() for (1 .. 5);
    is($d->{'pings'}, 1, 'testConnection: 5 requestu za sebou = 1 ping (interval 60 s)');
    $M->{'last_ping'} = time() - 61;
    $M->testConnection();
    is($d->{'pings'}, 2, 'po uplynuti intervalu se pingne znovu');
    local $C->{'pwe'}->{'db_ping_interval'} = 0;
    $M->testConnection() for (1 .. 3);
    is($d->{'pings'}, 5, 'interval 0 = ping pri kazdem requestu (puvodni chovani)');
    delete $M->{'DBC'}->{'dbx'};
}

# --- 2b. Session: entita z newSession se pouzije ve flush, zadny druhy SELECT ----------------------------------
{
    package MockSessionDAO;
    our $AUTOLOAD;
    sub new { my ($c, %d) = @_; return bless {data => {%d}, changes => {}, calls => []}, $c; }
    sub getMirroredData { return {%{$_[0]->{'data'}}}; }
    sub getChangeList { return [sort keys %{$_[0]->{'changes'}}]; }
    # jako Libs::MyDBI::DAO: flush seznam zmen nemaze (logit po flush), maze ho az commit/rollback
    sub flush    { push(@{$_[0]->{"calls"}}, "flush") }
    sub logit    { push(@{$_[0]->{"calls"}}, "logit") }
    sub commit   { push(@{$_[0]->{"calls"}}, "commit"); $_[0]->{"changes"} = {}; }
    sub rollback { push(@{$_[0]->{"calls"}}, "rollback"); $_[0]->{"changes"} = {}; }
    sub DELETE_ROW { push(@{$_[0]->{'calls'}}, 'delete') }
    sub error { 0 }
    sub DESTROY { }
    sub AUTOLOAD {
        my $self = shift; (my $n = $AUTOLOAD) =~ s/.*://;
        if (@_) { my $v = shift; my $old = $self->{'data'}->{$n}; $self->{'changes'}->{$n} = 1 if ((defined($old) ? $old : '') ne (defined($v) ? $v : '')); $self->{'data'}->{$n} = $v; }
        return $self->{'data'}->{$n};
    }
    package MockSessionEntities;
    sub new { return bless {created => 0, row => {}}, shift; }
    sub createEntityObject { my ($s) = @_; $s->{'created'}++; return MockSessionDAO->new(%{$s->{'row'}}); }
    package main;

    require Services::Session::Session;
    my $EN = MockSessionEntities->new;
    $EN->{'row'} = {sid => $U->getSid(), expire => time() + 3600, ipaddres => '10.0.0.1', useragent => 'pwe-test', lang => 'CZE'};
    my $S = Services::Session::Session->new($C, $LOG, $E->{'VALIDATE'}, undef, $EN, $U, $W);
    PWE::TestEnv::request($E, page => 'tPage2', func => 'default', sid => $U->getSid());
    my $sess = $S->newSession();
    is($EN->{'created'}, 1, 'newSession: jeden SELECT (createEntityObject)');
    is($sess->{'ipaddres'}, '10.0.0.1', 'session data nactena');
    my $dao = $S->{'dao'};
    ok($dao, 'entita session je drzena do konce requestu');
    @{$dao->{"calls"}} = ();    # newSession sama zapsala ip/useragent, sledujeme jen flush()
    $S->flush();
    is($EN->{'created'}, 1, 'flush: zadny druhy SELECT (regrese: 2 SELECTy na request)');
    is_deeply($dao->{'calls'}, [], 'nic se nezmenilo -> zadny UPDATE ani commit');
    ok(!exists($S->{'dao'}), 'entita po flush uvolnena (pool spojeni)');

    $S->newSession();
    $S->setValue('lang', 'EN');
    $dao = $S->{'dao'};
    @{$dao->{"calls"}} = ();
    $S->flush();
    is_deeply($dao->{'calls'}, ['logit', 'flush', 'commit'], 'zmena hodnoty -> UPDATE + commit');
    is($EN->{'created'}, 2, 'dalsi request = dalsi jeden SELECT');

    $S->flush();
    is($EN->{'created'}, 2, 'flush bez newSession a bez dat nic nedela');
    PWE::TestEnv::finish($E);
}

# --- 3a. atomicky zapis opts souboru -----------------------------------------------------------------------------
{
    my $dir  = "${APP2}ramdisk/opts-test/";
    my $file = "${dir}test.bin";
    require File::Path; File::Path::make_path($dir);
    ok($U->writeFile({a => [1, 2], b => 'x'}, $file), 'writeFile vraci 1');
    ok(-f $file, 'soubor existuje');
    opendir(my $dh, $dir) or die $!;
    my @tmp = grep { /\.tmp$/ } readdir($dh);
    closedir($dh);
    is(scalar(@tmp), 0, 'zadny docasny soubor nezustal (rename)');
    is_deeply($U->readFile($file), {a => [1, 2], b => 'x'}, 'readFile precte zapsana data');
    ok(!$U->writeFile({x => 1}, "${APP2}ramdisk/neexistujici-adresar/x.bin"), 'zapis do neexistujiciho adresare vrati 0 (nespadne)');
    is($SIG{__DIE__}, undef, 'readFile nemeni globalni $SIG{__DIE__}');
}

# --- 3b. omezeni chybovych reportu ----------------------------------------------------------------------------------
{
    local $C->{'log'}->{'error_report_interval'} = 300;
    is($LOG->sendErrorReport('PAGE', 'tPage2', 'default', "boom\n"), 1, 'prvni report se posila');
    is($LOG->sendErrorReport('PAGE', 'tPage2', 'default', "boom\n"), 0, 'stejna chyba v intervalu je potlacena');
    is($LOG->sendErrorReport('PAGE', 'tPage2', 'default', "boom\n"), 0, 'a dalsi take');
    is($LOG->{'report_suppressed'}->{'PAGE:tPage2:default'}, 2, 'pocet potlacenych reportu');
    is($LOG->sendErrorReport('PAGE', 'tPage2', 'jina', "boom\n"), 1, 'jina metoda = jiny klic, posila se');
    $LOG->{'report_sent'}->{'PAGE:tPage2:default'} = time() - 301;
    is($LOG->sendErrorReport('PAGE', 'tPage2', 'default', "boom\n"), 1, 'po uplynuti intervalu se posila znovu');
    ok(!exists($LOG->{'report_suppressed'}->{'PAGE:tPage2:default'}), 'pocitadlo potlacenych se po odeslani vynuluje');
    local $C->{'log'}->{'error_report_interval'} = 0;
    is($LOG->sendErrorReport('PAGE', 'tPage2', 'default', "boom\n"), 1, 'interval 0 = vzdy (puvodni chovani)');
}

# --- 4b. SQL komentar s mistem volani jen pri loglevel >= 3 -------------------------------------------------------
{
    package MockSqlDriver;
    sub new { return bless {sql => []}, shift; }
    sub select { push(@{$_[0]->{'sql'}}, $_[1]); return bless {}, 'MockSth'; }
    sub insert { push(@{$_[0]->{'sql'}}, $_[1]); }
    sub error { 0 }
    sub getError { return {err => undef, errstr => undef, state => undef}; }
    sub disconnect { 1 }
    package MockSth; sub finish { 1 }
    package main;

    require Libs::MyDBI;
    my $M = Libs::MyDBI->new($C, $LOG, $E->{'VALIDATE'});
    my $d = MockSqlDriver->new;
    $M->{'DBC'}->{'dbx'} = {0 => $d};
    $M->{'dbdriver'}->{'dbx'} = 'mysql';
    my $level = $LOG->{'loglevel'};
    $LOG->{'loglevel'} = 1;
    $M->select('dbx', '1 FROM t WHERE a = ?', [1]);
    is($d->{'sql'}->[-1], '1 FROM t WHERE a = ?', 'loglevel 1: SQL bez komentare (stejny text = cache dotazu)');
    $M->insert('dbx', 'INTO t (a) VALUES (?)', [1]);
    is($d->{'sql'}->[-1], 'INTO t (a) VALUES (?)', 'insert bez komentare');
    $LOG->{'loglevel'} = 3;
    $M->select('dbx', '1 FROM t WHERE a = ?', [1]);
    like($d->{'sql'}->[-1], qr{^/\* DB:dbx .*17-performance\.t line \d+ \*/ 1 FROM t WHERE a = \?$}, 'loglevel 3: komentar s mistem volani');
    $LOG->{'loglevel'} = $level;
    delete $M->{'DBC'}->{'dbx'};
}

# --- 4a. pad stranky nenechava $SIG{__DIE__} prepsany --------------------------------------------------------------
{
    my $E1 = PWE::TestEnv->boot();
    my $P1 = $E1->{'PAGES'};
    PWE::TestEnv::request($E1, page => 'tPage', func => 'crash');
    my (undef, $rc) = PWE::TestEnv::capture(sub { $P1->callPageFunc('tPage', 'crash') });
    is($rc, 500, 'pad metody -> 500');
    is($SIG{__DIE__}, undef, '$SIG{__DIE__} je po padu stranky zase vychozi (local v eval)');
    ok($P1->isExistPage('tPage'), 'stranka po padu znovu nactena');
    PWE::TestEnv::finish($E1);
}

done_testing();
