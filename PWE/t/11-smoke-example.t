#!/usr/bin/env perl
# Smoke test: vzorovy web webapps/example.web (bez DB) spusteny enginem z adresare PWE/ v CGI rezimu
# (dva koreny: pwe.home = <repo>/webapps/example.web, pwe.core = <repo>/PWE; v kontejneru /PWE/webapps/... a /PWE/PWE).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use lib "$FindBin::Bin/../tools/lib";
use PWE::TestEnv;
use PWE::ToolEnv qw(repo_root run_cgi parse_response);

my $app = repo_root() . "/webapps/example.web";    # repo_root() = koren repozitare (nadrazeny adresar enginu PWE/)

plan skip_all => "webapps/example.web neni k dispozici ($app)" unless (-f "$app/conf/web.conf");
plan skip_all => 'chybi Template / CGI::Fast' unless (eval { require Template; require CGI::Fast; 1 });
PWE::TestEnv::clean_env();

ok(!-e "$app/Libs" && !-e "$app/pwe.fcgi" && !-e "$app/templates", 'vzorovy web nema symlinky na engine');
ok(!-e "$app/Pages/errorPage" && !-e "$app/Pages/css", 'sdilene stranky nejsou ve webu (bere je z PWE/)');

my ($out, $err) = run_cgi($app, query => 'page=default&func=default');
my $r = parse_response($out);
is($r->{'status'}, 200, 'default: 200') or diag($err);
like($r->{'headers'}->{'content-type'} || '', qr{^text/html; charset=UTF-8}, 'default: HTML hlavicka');
like($r->{'headers'}->{'set-cookie'} || '', qr/^PWE-EXAMPLE-STATIC-PAGE=C0[0-9A-F]{32}/, 'default: session cookie');
like($r->{'body'}, qr/<!DOCTYPE html>/, 'default: doctype');
like($r->{'body'}, qr{</html>}, 'default: kompletni HTML');
unlike($err, qr/\[E\]/, 'default: engine nezalogoval chybu') or diag($err);

# regrese: ladici vstup PWE/debug.cgi (VS Code debugger + nginx location /debug.cgi). Engine bere request
# jako stranku jen pri shode SCRIPT_FILENAME s nazvem spusteneho skriptu - pwe.fcgi na /debug.cgi vraci 401
# (soubor mimo assets). Podrobne testy vstupu nad fixture app2 jsou v t/20-debug-entry.t.
($out, $err) = run_cgi($app, entry => 'debug.cgi', script => '/debug.cgi', query => 'page=default&func=default');
$r = parse_response($out);
is($r->{'status'}, 200, 'debug.cgi + SCRIPT_FILENAME=/debug.cgi: 200') or diag($err);
like($r->{'body'}, qr/debug\.cgi\?page=/, 'debug.cgi: odkazy na strance vedou zpet na debug.cgi (script_name)');
unlike($r->{'body'}, qr/pwe\.fcgi\?page=/, 'debug.cgi: zadny odkaz na pwe.fcgi');
unlike($err, qr/\[E\]/, 'debug.cgi: engine nezalogoval chybu') or diag($err);
($out) = run_cgi($app, script => '/debug.cgi', query => 'page=default&func=default');
$r = parse_response($out);
is($r->{'status'}, 401, 'pwe.fcgi + SCRIPT_FILENAME=/debug.cgi: 401 (jiny nazev skriptu = soubor mimo assets, stranka se nevola)');
unlike($r->{'body'}, qr/use strict|require \$engine/, 'zdrojovy kod debug.cgi se neserviruje');
($out) = run_cgi($app, entry => 'debug.cgi', script => '/pwe.fcgi', query => 'page=default&func=default');
$r = parse_response($out);
is($r->{'status'}, 401, 'debug.cgi + SCRIPT_FILENAME=/pwe.fcgi: 401');
unlike($r->{'body'}, qr/use strict|Libs::Config->new/, 'zdrojovy kod pwe.fcgi se neserviruje');
($out) = run_cgi($app, entry => 'debug.cgi', script => '/assets/javascript/pwe.js');
is(parse_response($out)->{'status'}, 200, 'debug.cgi: statika enginu se serviruje stejne jako u pwe.fcgi');

($out) = run_cgi($app, query => 'page=formExamples&func=default');
$r = parse_response($out);
is($r->{'status'}, 200, 'formExamples (z PWE/Pages pres pwe.core_pages): 200');
like($r->{'body'}, qr/<form/i, 'formExamples: obsahuje formular');

like($r->{'body'}, qr/assets\/css\/bootstrap-5\.3\.8\/bootstrap\.min\.css/, 'layout nacita Bootstrap 5.3.8 z enginu');
like($r->{'body'}, qr/assets\/javascript\/jquery-4\.0\.0\/jquery-4\.0\.0\.min\.js/, 'layout nacita jQuery 4.0.0 z enginu');
like($r->{'body'}, qr/data-bs-toggle="collapse"/, 'navbar pouziva Bootstrap 5 data-bs-* atributy');
unlike($r->{'body'}, qr/bootstrap-3|jquery-1|glyphicon|navbar-default|btn-default/, 'zadne zbytky Bootstrap 3');

($out) = run_cgi($app, script => '/assets/css/bootstrap-5.3.8/bootstrap.min.css');
$r = parse_response($out);
is($r->{'status'}, 200, 'bootstrap.min.css servirovan z enginu');
like($r->{'headers'}->{'content-type'} || '', qr{text/css}, 'bootstrap css: text/css');
like($r->{'body'}, qr/Bootstrap  v5\.3\.8/, 'obsah Bootstrap 5.3.8');

($out) = run_cgi($app, script => '/assets/javascript/jquery-4.0.0/jquery-4.0.0.min.js');
like(parse_response($out)->{'body'}, qr/jQuery v4\.0\.0/, 'jQuery 4.0.0 servirovan z enginu');

($out) = run_cgi($app, query => 'page=NewBootstrap523&func=default');
is(parse_response($out)->{'status'}, 404, 'NewBootstrap523 byl odstranen -> 404');

($out) = run_cgi($app, query => 'page=neexistujici&func=default');
is(parse_response($out)->{'status'}, 404, 'neznama stranka: 404');

($out) = run_cgi($app, query => 'page=pweCreator&func=default');
is(parse_response($out)->{'status'}, 200, 'pweCreator: vlastni UserAccount webu dava skupinu admin');

($out) = run_cgi($app, query => 'page=css&func=default');
like(parse_response($out)->{'headers'}->{'content-type'} || '', qr{^text/css}, 'css (z PWE/Pages): text/css hlavicka');

($out) = run_cgi($app, script => '/static/css/site.css');
$r = parse_response($out);
is($r->{'status'}, 200, 'vlastni static/css/site.css webu');
like($r->{'headers'}->{'content-type'} || '', qr{text/css}, 'site.css: text/css');

($out) = run_cgi($app, script => '/assets/javascript/pwe.js');
$r = parse_response($out);
is($r->{'status'}, 200, 'pwe.js z enginu -> 200');

($out) = run_cgi($app, script => '/templates/LayoutHeader.html');
is(parse_response($out)->{'status'}, 401, 'templates/ enginu nejsou v assets_dir -> 401');

done_testing();
