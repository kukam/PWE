#!/usr/bin/env perl
# Loadery (Pages/Sites/Services/Entities), DI, routing, pristupova prava, validace vstupu, samoleceni po padu.
use strict;
use warnings;
use Test::More;
use FindBin;
use JSON;
use lib "$FindBin::Bin/lib";
use PWE::TestEnv;

my $E = PWE::TestEnv->boot();
my ($P, $S, $ST, $EN, $U, $W) = @{$E}{qw(PAGES SERVICES SITES ENTITIES USER WEB)};
my $APP = PWE::TestEnv::app();

# Uspesny vysledek callPageFunc je undef/'' NEBO 200 (metoda stranky konci print() -> 1 -> 200).
sub is_ok_result { my ($r, $name) = @_; ok((!$r or $r eq '200'), $name) or diag("navratova hodnota: " . (defined($r) ? $r : 'undef')); }

# --- loadery -----------------------------------------------------------------
ok($P->isExistPage('tPage'), 'stranka tPage nactena');
is_deeply($P->getLoadPagesList(), ['tPage'], 'getLoadPagesList');
ok(!$P->isExistPage('nope'), 'neexistujici stranka');
ok($S->isExistService('tService'), 'sluzba tService nactena');
ok($ST->isExistSite('Default'), 'site Default nacten');
is_deeply($EN->getLoadEntitiesList(), [], 'zadne entity (bez DB)');

my $PG = $P->getPageObject('tPage');
isa_ok($PG, 'Pages::tPage::tPage');
is($PG->{'autostarted'}, 1, 'autostart stranky zavolan');
is_deeply($PG->{'services_list'}, ['tService'], 'services_list predan do stranky');
is_deeply($PG->{'sites_list'}, ['Default'], 'sites_list predan do stranky');
is_deeply($PG->{'entities_list'}, [], 'entities_list predan do stranky');
my $SV = $S->getServiceObject('tService');
is($SV->{'autostarted'}, 1, 'autostart sluzby zavolan');

ok($P->isExistPageMethod('tPage', 'default'), 'isExistPageMethod');
ok($P->isExistPageMethod('tPage', 'is_code'), 'isExistPageMethod pomocna metoda');
ok(!$P->isExistPageMethod('tPage', 'nope'), 'isExistPageMethod neexistujici');
ok($P->isExistPageFunc('tPage', 'default'), 'isExistPageFunc');
ok(!$P->isExistPageFunc('tPage', 'is_code'), 'metoda mimo func neni volatelna');
ok($P->isExistPageAtribute('tPage', 'defined', 'form'), 'isExistPageAtribute');
ok(!$P->isExistPageAtribute('tPage', 'defined', 'default'), 'isExistPageAtribute jina func');
ok($P->isExistPageAtribute('tPage', 'rules'), 'isExistPageAtribute bez hodnoty');
is_deeply($P->getPageAtribute('tPage', 'defined', 'form', {})->{'parameters'}, ['email', 'name||nick', 'if[kind="P"]person'], 'getPageAtribute');
is($P->getPageAtribute('tPage', 'nope', 'x', 'd'), 'd', 'getPageAtribute default');
is_deeply([$P->getPnameCname('par#col')], ['par', 'col'], 'getPnameCname par#col');
is_deeply([$P->getPnameCname('same')], ['same', 'same'], 'getPnameCname bez # (regrese $_)');

ok($S->isExistServiceMethod('tService', 'is_adult'), 'isExistServiceMethod');
ok(!$S->isExistServiceMethod('tService', 'nope'), 'isExistServiceMethod neexistujici');
ok($ST->isExistSiteMethod('Default', 'getIDP'), 'isExistSiteMethod');
is_deeply([$ST->callSiteMethod('Default', 'getIDP', undef)], [1, 'unknownidp'], 'callSiteMethod');
is_deeply([$ST->callSiteMethod('Nope', 'x')], [0, undef], 'callSiteMethod neexistujici site');
is_deeply([$S->callServiceMethod('tService', 'is_adult', 20)], [1, 20], 'callServiceMethod');
is_deeply([$S->callServiceMethod('tService', 'nope')], [0, undef], 'callServiceMethod neexistujici metoda');

# --- zivotni cyklus requestu (newRequest/flush do sluzeb) -------------------
PWE::TestEnv::request($E, page => 'tPage');
is($SV->{'requests'}, 1, 'SERVICES->newRequest propagovan do sluzby');
PWE::TestEnv::finish($E);
is($SV->{'flushed'}, 1, 'SERVICES->flush propagovan do sluzby');

# --- vykresleni default ------------------------------------------------------
PWE::TestEnv::request($E, page => 'tPage', func => 'default');
my ($out, $ret) = PWE::TestEnv::capture(sub { $P->callPageFunc('tPage', 'default') });
is_ok_result($ret, 'callPageFunc default -> bez chyboveho kodu');
like($out, qr/^Content-Type: text\/html/m, 'HTTP hlavicka');
like($out, qr/<title>TPAGE TITLE<\/title>/, 'HTML hlavicka');
like($out, qr/Testovaci stranka/, 'rb text');
like($out, qr/id="hello">world/, 'promenna layoutu');
like($out, qr/id="idp">tpage/, 'idp');
like($out, qr/id="svc">SLUZBA/, 'rb sluzby');

# --- routing a prava ---------------------------------------------------------
is($P->callPageFunc('nope', 'default'), 404, 'neznama stranka -> 404');
is($P->callPageFunc('tPage', 'nope'), 404, 'neznama func -> 404');
is($P->callPageFunc('tPage', 'is_code'), 404, 'neregistrovana metoda -> 404');
is($P->callPageFunc('tPage', 'secret'), 401, 'func s pravy bez skupiny -> 401');
$U->addGroup('admin');
($out, $ret) = PWE::TestEnv::capture(sub { $P->callPageFunc('tPage', 'secret') });
is_ok_result($ret, 'func s pravy se skupinou admin');
like($out, qr/SECRET/, 'secret vykreslen');
$U->deleteGroup('admin');
{
    local $PG->{'access'} = ['admin'];
    is($P->callPageFunc('tPage', 'default'), 401, 'globalni access bez skupiny -> 401');
    $U->addGroup('admin');
    ($out, $ret) = PWE::TestEnv::capture(sub { $P->callPageFunc('tPage', 'default') });
    is_ok_result($ret, 'globalni access se skupinou');
    $U->deleteGroup('admin');
}
is($P->callPageFunc('tPage', 'status'), 404, 'numericky navrat funkce se propaguje');

# --- pad metody: 500, reload, zachovane rb -----------------------------------
is($P->callPageFunc('tPage', 'crash'), 500, 'die ve funkci -> 500');
ok($P->isExistPage('tPage'), 'stranka po padu znovu nactena');
ok(@{$W->getResourceBundleList('tPage', 'CZE')} > 0, 'resource bundle po reloadu zachovan (regrese)');
($out) = PWE::TestEnv::capture(sub { $P->callPageFunc('tPage', 'default') });
like($out, qr/Testovaci stranka/, 'i18n funguje i po padu a reloadu');
like($out, qr/id="svc">SLUZBA/, 'rb sluzby funguje i po reloadu');
$PG = $P->getPageObject('tPage');

# --- AJAX --------------------------------------------------------------------
($out) = PWE::TestEnv::capture(sub { $P->callPageFunc('tPage', 'ajax') });
like($out, qr/^Content-Type: text\/xml/m, 'ajax hlavicka');
my ($json) = $out =~ /(\{.*\})\s*$/s;
is_deeply(from_json($json)->{'REPLACE'}, [{ID => 'a', HTML => '<b>A</b>'}, {ID => 'b', HTML => 'B'}], 'ajax JSON');
$W->flush();
($out) = PWE::TestEnv::capture(sub { $P->callPageFunc('tPage', 'msg') });
($json) = $out =~ /(\{.*\})\s*$/s;
my $rep = from_json($json)->{'REPLACE'};
is($rep->[0]->{'ID'}, 'messenger', 'messenger v AJAX odpovedi');
like($rep->[0]->{'HTML'}, qr/Ulozeno/, 'messenger text z rb');
$W->flush();
PWE::TestEnv::finish($E);

# --- validace: defined -------------------------------------------------------
sub call_form {
    my (%params) = @_;
    PWE::TestEnv::request($E, page => 'tPage', func => 'form', params => \%params);
    my ($o, $r) = PWE::TestEnv::capture(sub { $P->callPageFunc('tPage', 'form') });
    my $pg = $P->getPageObject('tPage');
    my $err = $pg->{'last_error'};
    $pg->{'last_error'} = undef;
    return ($o, $r, $err);
}

my ($o, $r, $err) = call_form();
like($o, qr/^ERROR:/m, 'chybejici parametry -> volana error metoda');
is_deeply([sort @{$err}], ['error_exist__email', 'error_exist__name'], 'defined: email a name||nick (prvni z OR)');
PWE::TestEnv::finish($E);

($o, $r, $err) = call_form(email => 'foo', nick => 'n', kind => 'P');
is_deeply($err, ['error_exist__person'], 'defined: if[kind="P"]person');
PWE::TestEnv::finish($E);

($o, $r, $err) = call_form(email => 'foo', name => 'n', kind => 'X');
is_deeply($err, ['error_email'], 'rules: is_email (podminka kind!=P neplati)');
PWE::TestEnv::finish($E);

($o, $r, $err) = call_form(email => 'a@b.cz', name => 'n', age => '10');
is_deeply($err, ['error_age'], 'rules: Services::tService::is_adult');
PWE::TestEnv::finish($E);

($o, $r, $err) = call_form(email => 'a@b.cz', name => 'n', age => '20', code => 'abc');
is_deeply($err, ['error_code'], 'rules: Pages::tPage::is_code');
PWE::TestEnv::finish($E);

($o, $r, $err) = call_form(email => 'foo', name => 'n', age => '10');
is_deeply([sort @{$err}], ['error_age', 'error_email'], 'rules: vice chyb najednou');
PWE::TestEnv::finish($E);

# --- validace OK + replace (escape_jsinjection na *ALL*) ---------------------
PWE::TestEnv::request($E, page => 'tPage', func => 'form', params => {email => 'a@b.cz', name => '<b>x</b>', age => '20', code => 'ABC'});
($o, $r) = PWE::TestEnv::capture(sub { $P->callPageFunc('tPage', 'form') });
is_ok_result($r, 'validni formular bez chyby');
like($o, qr/FORM OK email=a\@b\.cz adult=20/, 'form zavolana se spravnymi parametry a sluzbou');
is($U->getParam('name'), '&lt;b&gt;x&lt;/b&gt;', 'replace escape_jsinjection upravil parametr');
ok(!defined($P->getPageObject('tPage')->{'last_error'}), 'error metoda nevolana');
PWE::TestEnv::finish($E);

PWE::TestEnv::request($E, page => 'tPage', func => 'form', params => {email => 'a@b.cz', name => ['<a>', '<b>'], age => '20'});
PWE::TestEnv::capture(sub { $P->callPageFunc('tPage', 'form') });
is_deeply($U->getParam('name', 'all'), ['&lt;a&gt;', '&lt;b&gt;'], 'replace nad vicehodnotovym parametrem');
PWE::TestEnv::finish($E);

# opakovany pruchod (regrese: iterator each() nad sdilenym hashem rules/replace)
for (1 .. 3) {
    ($o, $r, $err) = call_form(email => 'foo', name => 'n');
    is_deeply($err, ['error_email'], "opakovana validace #$_ dava stejny vysledek");
    PWE::TestEnv::finish($E);
}

# --- primy validate() loaderu ------------------------------------------------
ok(!defined($S->validate(['Services::tService::is_adult', 'error_age', 30])), 'SERVICES->validate OK');
is($S->validate(['Services::tService::is_adult', 'error_age', 3]), 'error_age', 'SERVICES->validate chyba');
like($S->validate(['Services::tService::nope', 'e', 1]), qr/^Internal_error/, 'SERVICES->validate neznama metoda');
is($P->validate(['Pages::tPage::is_code', 'error_code', 'xx']), 'error_code', 'PAGES->validate chyba');
ok(!defined($P->validate(['Pages::tPage::is_code', 'error_code', 'ABC'])), 'PAGES->validate OK');
like($P->validate(['Pages::tPage::nope', 'e', 1]), qr/^Internal_error/, 'PAGES->validate neznama metoda');

# --- pad sluzby --------------------------------------------------------------
is_deeply([$S->callServiceMethod('tService', 'crash')], [2, undef], 'pad sluzby -> (2, undef)');
ok($S->isExistService('tService'), 'sluzba po padu znovu nactena');

# --- entity loader bez entit -------------------------------------------------
ok(!$EN->isExistEntity('Nope'), 'isExistEntity');
ok(!defined($EN->createEntityObject('Nope')), 'createEntityObject neznama entita -> undef');
is_deeply($EN->getEntitiesResourceBundleDir(), [], 'getEntitiesResourceBundleDir');
like($EN->validate(['Entities::Nope::col', 'e', 1]), qr/^Internal_error/, 'ENTITIES->validate neznama entita');

# --- unload / reload ---------------------------------------------------------
$P->unloadPage('tPage');
ok(!$P->isExistPage('tPage'), 'unloadPage');
is_deeply($W->getResourceBundleList('tPage', 'CZE'), [], 'unloadPage smaze rb');
is($P->callPageFunc('tPage', 'default'), 404, 'odregistrovana stranka -> 404');
ok($P->reloadPage('tPage'), 'reloadPage');
ok(@{$W->getResourceBundleList('tPage', 'CZE')} > 0, 'reloadPage obnovi rb');
ok(!$P->reloadPage('nope'), 'reloadPage neznama stranka -> 0');

# --- validace: interni chyba atributu (regrese: vracel se retezec misto pole chyb) ---
PWE::TestEnv::request($E, page => 'tPage', func => 'badvalidate', params => {x => 'a'});
{
    my ($o2, $r2) = PWE::TestEnv::capture(sub { $P->callPageFunc('tPage', 'badvalidate') });
    my $pg = $P->getPageObject('tPage');
    is(ref($pg->{'last_error'}), 'ARRAY', 'interni chyba validace je predana jako pole');
    is_deeply($pg->{'last_error'}, ['Internal_Error_atribute_entity_not_defined'], 'klic interni chyby (chybi entity)');
    like($o2, qr/^ERROR:Internal_Error_atribute_entity_not_defined/m, 'error metoda stranky bezi (nespadla na retezci)');
}
PWE::TestEnv::finish($E);

done_testing();
