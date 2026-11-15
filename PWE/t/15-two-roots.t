#!/usr/bin/env perl
# Dva koreny enginu: web (pwe.home) oddeleny od enginu (pwe.core = koren enginu, adresar PWE/ v repozitari,
# v kontejneru /PWE/PWE) - fixture t/fixtures/app2 bez symlinku. $ROOT je koren enginu odvozeny od umisteni testu.
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
my ($C, $P, $ST, $S, $EN, $W) = @{$E}{qw(CONF PAGES SITES SERVICES ENTITIES WEB)};

# --- Libs::Config: koreny ---------------------------------------------------------------------
is($C->getHome(), $APP2, 'getHome = adresar webu');
is($C->getCore(), "$ROOT/", 'getCore = adresar enginu (PWE_CONF_pwe_core)');
is_deeply([$C->getRoots()], [$APP2, "$ROOT/"], 'getRoots: web pred enginem');
ok(grep({ $_ eq "$ROOT/" } $C->getRoots()), 'engine je mezi koreny');

my @roots = $C->getModuleRoots('pages');
is(scalar(@roots), 2, 'getModuleRoots(pages): dva koreny');
is($roots[0]->{'dir'}, "${APP2}Pages/", 'prvni koren = web');
ok(!defined($roots[0]->{'allowed'}), 'web bez omezeni');
is($roots[1]->{'dir'}, "$ROOT/Pages/", 'druhy koren = engine');
is_deeply([sort keys %{$roots[1]->{'allowed'}}], ['css', 'errorPage', 'systemPage'], 'engine omezen na pwe.core_pages');
is_deeply([sort keys %{($C->getModuleRoots('sites'))[1]->{'allowed'}}], ['Default'], 'core_sites');
is_deeply([keys %{($C->getModuleRoots('services'))[1]->{'allowed'}}], [], 'core_services prazdne');
{
    local $C->{'pwe'}->{'core_services'} = '*';
    ok(!defined(($C->getModuleRoots('services'))[1]->{'allowed'}), 'core_services = "*" -> bez omezeni');
    local $C->{'pwe'}->{'core_services'} = 'Session, DBTable';
    is_deeply([sort keys %{($C->getModuleRoots('services'))[1]->{'allowed'}}], ['DBTable', 'Session'], 'core_services jako retezec s carkou');
}

# --- loadery: co se nacetlo ---------------------------------------------------------------------
is_deeply([sort @{$P->getLoadPagesList()}], ['css', 'errorPage', 'systemPage', 'tPage2'], 'stranky: vlastni + povolene z enginu');
ok(!$P->isExistPage('pweCreator'), 'pweCreator neni v core_pages -> nenacten');
ok(!$P->isExistPage('formExamples'), 'ukazkove stranky enginu se nenacitaji');
ok($ST->isExistSite('Default'), 'vzhled Default z enginu');
ok(!$ST->isExistSite('Responsive'), 'Responsive neni v core_sites');
is_deeply($S->getLoadServicesList(), [], 'zadne sluzby (web zadne nema, core_services prazdne)');
is_deeply($EN->getLoadEntitiesList(), [], 'zadne entity');

# --- vlastni stranka webu pouziva sablony a vzhled z enginu -----------------------------------------
PWE::TestEnv::request($E, page => 'tPage2', func => 'default');
my ($out) = PWE::TestEnv::capture(sub { $P->callPageFunc('tPage2', 'default') });
like($out, qr/^Content-Type: text\/html/m, 'tPage2: HTML hlavicka (templates/HttpHeaderStandart.tmpl z enginu)');
like($out, qr/<!DOCTYPE html>/, 'tPage2: layout z templates/ enginu');
like($out, qr/Ahoj z app2 \(tpage2\)/, 'tPage2: main.html a rb.tmpl z webu');
PWE::TestEnv::finish($E);

PWE::TestEnv::request($E, page => 'tPage2', func => 'roots');
($out) = PWE::TestEnv::capture(sub { $P->callPageFunc('tPage2', 'roots') });
like($out, qr/HOME=\Q$APP2\E/, 'stranka vidi pwe.home');
like($out, qr/CORE=\Q$ROOT\E\//, 'stranka vidi pwe.core');
PWE::TestEnv::finish($E);

# --- sdilena stranka enginu (errorPage) vcetne jejiho rb z enginu -----------------------------------
PWE::TestEnv::request($E, page => 'errorPage', func => 'e404', env => {REQUEST_URI => '/nic'});
($out) = PWE::TestEnv::capture(sub { $P->callPageFunc('errorPage', 'e404') });
like($out, qr/^Status: 404/m, 'errorPage z enginu: 404');
like($out, qr/Chyba 404/, 'rb.tmpl stranky errorPage nalezen v enginu');
like($out, qr/neexistuje/, 'text chyby z rb enginu');
PWE::TestEnv::finish($E);

# --- web prebiji modul enginu stejneho jmena ---------------------------------------------------------
PWE::TestEnv::request($E, page => 'css', func => 'default');
($out) = PWE::TestEnv::capture(sub { $P->callPageFunc('css', 'default') });
like($out, qr/CSS2: vlastni css stranka webu app2/, 'Pages/css webu ma prednost pred Pages/css enginu');
like($out, qr/^Content-Type: text\/css/m, 'css hlavicka');
PWE::TestEnv::finish($E);

# --- statika: resolveFile / resolveDir -------------------------------------------------------------------
is($C->resolveFile('/assets/javascript/pwe.js'), "$ROOT/", 'assets enginu se najdou bez symlinku ve webu');
is($C->resolveFile('/static/css/site.css'), $APP2, 'static webu');
is($C->resolveFile('/conf/web.conf'), $APP2, 'conf webu (o pristupu rozhoduje systemPage::checkassets)');
ok(!defined($C->resolveFile('/neexistuje.txt')), 'neexistujici soubor -> undef');
is($C->resolveDir('/static/'), $APP2, 'resolveDir web');
is($C->resolveDir('/templates/'), "$ROOT/", 'resolveDir engine');
ok(!defined($C->resolveDir('/nope/')), 'resolveDir neexistujici -> undef');

PWE::TestEnv::request($E, page => 'systemPage', func => 'file', env => {SCRIPT_FILENAME => '/assets/javascript/pwe.js'});
($out) = PWE::TestEnv::capture(sub { $P->callPageFunc('systemPage', 'file') });
like($out, qr/^Content-Type: application\/javascript/m, 'systemPage servíruje pwe.js z enginu');
like($out, qr/function|jQuery|\$\(/, 'obsah pwe.js');
PWE::TestEnv::finish($E);

PWE::TestEnv::request($E, page => 'systemPage', func => 'file', env => {SCRIPT_FILENAME => '/static/css/site.css'});
($out) = PWE::TestEnv::capture(sub { $P->callPageFunc('systemPage', 'file') });
like($out, qr/fixture app2/, 'systemPage servíruje static/ webu');
PWE::TestEnv::finish($E);

PWE::TestEnv::request($E, page => 'systemPage', func => 'file', env => {SCRIPT_FILENAME => '/conf/web.conf'});
my $rc;
(undef, $rc) = PWE::TestEnv::capture(sub { $P->callPageFunc('systemPage', 'file') });
is($rc, 401, 'conf/ neni v assets_dir -> 401');
PWE::TestEnv::finish($E);

PWE::TestEnv::request($E, page => 'systemPage', func => 'file', env => {SCRIPT_FILENAME => '/assets/neexistuje.js'});
(undef, $rc) = PWE::TestEnv::capture(sub { $P->callPageFunc('systemPage', 'file') });
is($rc, 404, 'povoleny adresar, ale soubor nikde -> 404');
PWE::TestEnv::finish($E);

# --- verze enginu ----------------------------------------------------------------------------------------
like($C->coreVersion(), qr/^\d+\.\d+\.\d+$/, 'coreVersion ze souboru VERSION');
ok(!defined($C->checkCoreVersion()), 'require_core >=1.0 splnen');
{
    local $C->{'pwe'}->{'require_core'} = '>=99.0';
    like($C->checkCoreVersion(), qr/vyzaduje engine PWE >=99\.0, k dispozici je/, 'prilis stary engine -> chyba');
    local $C->{'pwe'}->{'require_core'} = 'abc';
    like($C->checkCoreVersion(), qr/Neplatny format/, 'neplatny format pozadavku');
    local $C->{'pwe'}->{'require_core'} = '=' . $C->coreVersion();
    ok(!defined($C->checkCoreVersion()), '=presna verze');
    (my $major = $C->coreVersion()) =~ s/\..*//;
    local $C->{'pwe'}->{'require_core'} = "=$major";
    ok(!defined($C->checkCoreVersion()), '=major vyhovuje cele rade');
    local $C->{'pwe'}->{'require_core'} = ">$major.99";
    like($C->checkCoreVersion(), qr/vyzaduje/, '> vyssi minor -> chyba');
    local $C->{'pwe'}->{'require_core'} = undef;
    ok(!defined($C->checkCoreVersion()), 'bez pozadavku OK');
}
{
    local $C->{'pwe'}->{'core'} = "${APP2}";
    local $C->{'pwe'}->{'require_core'} = '>=1.0';
    like($C->checkCoreVersion(), qr/nema soubor VERSION/, 'engine bez VERSION a pozadavek -> chyba');
}

# --- puvodni rezim (jeden koren) zustava beze zmeny ---------------------------------------------------
my $E1 = PWE::TestEnv->boot();
my $C1 = $E1->{'CONF'};
is($C1->getCore(), $C1->getHome(), 'bez PWE_CONF_pwe_core: pwe.core = pwe.home');
is(scalar(my @r1 = $C1->getRoots()), 1, 'jeden koren');
is(scalar(my @m1 = $C1->getModuleRoots('pages')), 1, 'getModuleRoots: jen web');
ok($E1->{'PAGES'}->isExistPage('tPage'), 'fixture app (symlinky) funguje jako drive');

done_testing();
