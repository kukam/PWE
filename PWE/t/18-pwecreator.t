#!/usr/bin/env perl
# Pages::pweCreator: generator kodu z prohlizece zapisuje soubory jen pri pwe.development (jinak 401)
# a jen s bezpecnymi nazvy (rules: identifikator, max. 64 znaku) - nazvy jsou soucasti cest k souborum.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Path qw(remove_tree);
use lib "$FindBin::Bin/lib";
use PWE::TestEnv;

my $ROOT = PWE::TestEnv::root();
my $APP2 = PWE::TestEnv::app2();
plan skip_all => 'chybi Template'   unless (eval { require Template;   1 });
plan skip_all => 'chybi Class::MOP' unless (eval { require Class::MOP; 1 });

# Vygenerovane moduly v fixture webu - uklid pred testem i po nem (i pri padu testu).
my @GEN = map { "${APP2}$_" } qw(Pages/tGenPage Services/tGenService Sites/tGenSite Entities/tGenEntity Pages/evil Pages/evil-name Pages/1abc evil);
sub cleanup { remove_tree($_) for (@GEN); }
cleanup();
END { cleanup(); }

# Fixture app2 ma pweCreator v core_pages zamerne vypnuty -> pro tento test ho povolime.
my $E = PWE::TestEnv->boot(app => $APP2, core => $ROOT, conf => {pwe => {core_pages => ['css', 'errorPage', 'systemPage', 'pweCreator']}});
my ($C, $P, $U) = @{$E}{qw(CONF PAGES USER)};
ok($P->isExistPage('pweCreator'), 'pweCreator nacten z enginu (core_pages)');
is($C->getValue('pwe', 'development', 0), 0, 'fixture: pwe.development = 0');

# Request jako admin: vraci (navratovy kod callPageFunc, vystup).
sub call {
    my ($func, %params) = @_;
    PWE::TestEnv::request($E, page => 'pweCreator', func => $func, params => {%params});
    $U->addGroup('admin');
    my ($out, $rc) = PWE::TestEnv::capture(sub { $P->callPageFunc('pweCreator', $func) });
    PWE::TestEnv::finish($E);
    return ($rc, $out);
}

sub slurp {
    my $file = shift;
    open(my $fh, '<', $file) or return undef;
    local $/;
    my $txt = <$fh>;
    close($fh);
    return $txt;
}

# --- mimo vyvojovy rezim: 401 a zadny soubor (regrese: admin produkcniho webu mohl zapisovat kod) ---
foreach my $t (['cpage', pagename => 'tGenPage'], ['cservice', servicename => 'tGenService'], ['csite', sitename => 'tGenSite'], ['centity', entityname => 'tGenEntity', dbtable => 'session']) {
    my ($func, %p) = @{$t};
    my ($rc) = call($func, %p);
    is($rc, 401, "$func mimo pwe.development -> 401");
}
ok(!-e "${APP2}Pages/tGenPage" && !-e "${APP2}Services/tGenService" && !-e "${APP2}Sites/tGenSite" && !-e "${APP2}Entities/tGenEntity", 'mimo pwe.development se nic nevytvorilo');

# --- bez skupiny admin 401 i ve vyvojovem rezimu (access) ---
{
    local $C->{'pwe'}->{'development'} = 1;
    PWE::TestEnv::request($E, page => 'pweCreator', func => 'cpage', params => {pagename => ['tGenPage']});
    my (undef, $rc) = PWE::TestEnv::capture(sub { $P->callPageFunc('pweCreator', 'cpage') });
    PWE::TestEnv::finish($E);
    is($rc, 401, 'bez skupiny admin 401 i pri pwe.development');
    ok(!-e "${APP2}Pages/tGenPage", 'nic se nevytvorilo');
}

# --- vyvojovy rezim: neplatne nazvy -> 400 (rules), nic se nezapise ---
{
    local $C->{'pwe'}->{'development'} = 1;
    foreach my $bad ('../evil', 'evil-name', '1abc', 'a b', 'x' x 65, 'Pages/evil', 'a;rm', '.hidden') {
        my ($rc) = call('cpage', pagename => $bad, ajax_request => 1);
        my $label = (length($bad) > 20 ? substr($bad, 0, 20) . '...' : $bad);
        is($rc, 400, "cpage: nazev '$label' odmitnut (400)");
    }
    ok(!-e "${APP2}evil" && !-e "${APP2}Pages/evil" && !-e "${APP2}Pages/evil-name" && !-e "${APP2}Pages/1abc", 'po odmitnuti nic nevzniklo');
    is((call('cservice', servicename => '../x',  ajax_request => 1))[0], 400, 'cservice: neplatny nazev 400');
    is((call('csite',    sitename    => 'Bad N', ajax_request => 1))[0], 400, 'csite: neplatny nazev 400');
    is((call('centity',  entityname  => 'Ok', dbtable => 'session; DROP TABLE x', ajax_request => 1))[0], 400, 'centity: neplatny nazev tabulky 400');
    is((call('centity',  entityname  => '../Ok', dbtable => 'session', ajax_request => 1))[0], 400, 'centity: neplatny nazev entity 400');
    is((call('cpage',    pagename    => 'tGenPage', default_site => '../Default', ajax_request => 1))[0], 400, 'cpage: neplatny default_site 400');
    is((call('cpage',    pagename    => 'tGenPage', default_service => ['Session', 'x/y'], ajax_request => 1))[0], 400, 'cpage: neplatny default_service (druha hodnota) 400');
    is((call('csite',    sitename    => 'tGenSite', default_site => 'Def ault', ajax_request => 1))[0], 400, 'csite: neplatny default_site 400');
    ok(!-e "${APP2}Pages/tGenPage" && !-e "${APP2}Sites/tGenSite", 'po odmitnuti parametru nic nevzniklo');
    is((call('cpage', ajax_request => 1))[0], 400, 'cpage bez pagename 400 (defined)');

    # chybove klice v rb (CZE i EN), oba soubory konci prazdnym radkem
    foreach my $rb ('rb.tmpl', 'rb_EN.tmpl') {
        my $txt = slurp("$ROOT/Pages/pweCreator/$rb");
        foreach my $k (qw(error_pagename error_servicename error_sitename error_entityname error_dbtable error_default_site error_default_service)) {
            like($txt, qr/rb\.msg\.\Q$k\E\s*=/, "$rb: klic $k");
        }
        like($txt, qr/\n\n\z/, "$rb: konci prazdnym radkem");
    }
}

# --- vyvojovy rezim + platne nazvy -> soubory vzniknou ---
{
    local $C->{'pwe'}->{'development'} = 1;

    my ($rc, $out) = call('cpage', pagename => 'tGenPage', default_site => 'Default');
    is($rc, 200, 'cpage s platnym nazvem -> 200');
    like($out, qr/Content-Type: text\/xml/, 'cpage odpovida AJAXem');
    ok(-f "${APP2}Pages/tGenPage/tGenPage.pm", 'Pages/tGenPage/tGenPage.pm vytvoren');
    my $pm = slurp("${APP2}Pages/tGenPage/tGenPage.pm") || '';
    like($pm, qr/^package Pages::tGenPage::tGenPage;/m, 'balicek stranky');
    like($pm, qr/sub Site_Default/, 'injektaz zvoleneho vzhledu');
    ok(-f "${APP2}Pages/tGenPage/$_", "Pages/tGenPage/$_ vytvoren") for (qw(main.html msg.html rb.tmpl rb_EN.tmpl));
    like(slurp("${APP2}Pages/tGenPage/rb.tmpl") || '', qr/\n\n\z/, 'vygenerovany rb.tmpl konci prazdnym radkem');

    ($rc, $out) = call('cservice', servicename => 'tGenService');
    is($rc, 200, 'cservice s platnym nazvem -> 200');
    like($out, qr/^AjaxRedirect: .*page=pweCreator/m, 'cservice presmeruje zpet na generator');
    like(slurp("${APP2}Services/tGenService/tGenService.pm") || '', qr/^package Services::tGenService::tGenService;/m, 'Services/tGenService vytvorena');

    ($rc) = call('centity', entityname => 'tGenEntity', dbtable => 'session');
    is($rc, 200, 'centity s platnymi nazvy -> 200');
    my $ent = slurp("${APP2}Entities/tGenEntity/tGenEntity.pm") || '';
    like($ent, qr/^package Entities::tGenEntity::tGenEntity;/m, 'Entities/tGenEntity vytvorena');
    like($ent, qr/"session"/, 'entita nad zvolenou tabulkou');

    ($rc) = call('csite', sitename => 'tGenSite', default_site => 'Default');
    is($rc, 200, 'csite s platnym nazvem -> 200');
    like(slurp("${APP2}Sites/tGenSite/tGenSite.pm") || '', qr/^package Sites::tGenSite::tGenSite;/m, 'Sites/tGenSite vytvoren');
}

cleanup();
done_testing();
