#!/usr/bin/env perl
# Libs::Web - sablony, resource bundle, HTTP hlavicky, layouty, AJAX, messenger.
use strict;
use warnings;
use Test::More;
use FindBin;
use JSON;
use lib "$FindBin::Bin/lib";
use PWE::TestEnv;

my $E = PWE::TestEnv->boot();
my ($W, $U, $C) = @{$E}{qw(WEB USER CONF)};

PWE::TestEnv::request($E, page => 'tPage');

is($W->getScriptName(), 'pwe.fcgi', 'getScriptName');
is($W->getValue('layout_header'), 'templates/LayoutHeader.html', 'getValue');
is($W->getValue('nope', 'd'), 'd', 'getValue default');
is($W->getIDP(), 'unknownidp', 'getIDP bez setIDP');
$W->setIDP('x');
is($W->getIDP(), 'x', 'setIDP/getIDP');

# --- genTmpl: inline sablona + automaticke promenne ---------------------------
$U->setParameter('q', ['v1', 'v2']);
my $out = $W->genTmpl("[% script_name %]|[% idp %]|[% use_language %]|[% def_language %]|[% cookie_name %]|[% parameters.q %]|[% http_host %]|[% script_page %]|[% name_page %]|[% full_url %]");
is($out, 'pwe.fcgi|x|CZE|CZE|PWE-TEST|v1|test.local|tPage|PWE TEST|http://test.local/', 'genTmpl automaticke promenne');
is_deeply($W->getParameters(), {q => 'v1'}, 'getParameters = prvni hodnoty parametru');

PWE::TestEnv::request($E, page => 'tPage', env => {HTTP_HOST => 'test.local:8080', HTTPS => 'on'});
is($W->genTmpl('[% http_host %]/[% http_host_full %]/[% http_https %]'), 'test.local/test.local:8080/https://', 'http_host bez portu, https');

# --- genTmpl: soubor + resource bundle --------------------------------------
PWE::TestEnv::request($E, page => 'tPage');
$out = $W->genTmpl('Pages/tPage/main.html', hello => 'svete');
like($out, qr/Testovaci stranka/, 'rb stranky (CZE)');
like($out, qr/svete/, 'predana promenna');
like($out, qr/SLUZBA/, 'rb sluzby injektovane do stranky je v rb_list');
$U->setLanguage('EN');
$out = $W->genTmpl('Pages/tPage/main.html');
like($out, qr/Test page/, 'rb stranky (EN)');
like($out, qr/SERVICE/, 'rb sluzby (EN)');
$U->setLanguage('CZE');

# --- rb mapa -----------------------------------------------------------------
is_deeply([sort @{$W->getResourceBundleList('tPage', 'CZE')}], [sort('Pages/tPage/rb.tmpl', 'Services/tService/rb.tmpl', 'Sites/Default/rb.tmpl')], 'rb_list CZE');
is_deeply([sort @{$W->getResourceBundleList('tPage', 'EN')}], [sort('Pages/tPage/rb_EN.tmpl', 'Services/tService/rb_EN.tmpl', 'Sites/Default/rb_EN.tmpl')], 'rb_list EN');
is_deeply($W->getResourceBundleList('nope', 'CZE'), [], 'rb_list neznama stranka');
$W->addResourceBundlePagePath('zz', 'CZE', 'x/rb.tmpl');
is_deeply($W->getResourceBundleList('zz', 'CZE'), ['x/rb.tmpl'], 'addResourceBundlePagePath');
$W->delResourceBundlePagePaths('zz');
is_deeply($W->getResourceBundleList('zz', 'CZE'), [], 'delResourceBundlePagePaths');

# --- printHttpHeader ---------------------------------------------------------
my $h = PWE::TestEnv::capture(sub { $W->printHttpHeader() });
like($h, qr/^Set-Cookie: PWE-TEST=C0[0-9A-F]{32}; domain=test\.local; path=\/; expires=\w{3}, \d{2}-\w{3}-\d{4} \d\d:\d\d:\d\d GMT/m, 'Set-Cookie');
like($h, qr/^Content-Type: text\/html; charset=UTF-8/m, 'standardni Content-Type');
like($h, qr/^Date: \w{3}, \d{2} \w{3} \d{4} \d\d:\d\d:\d\d GMT/m, 'Date');
like($h, qr/\n\n$/, 'hlavicka konci prazdnym radkem');
my $expday = sprintf('%02d', (gmtime(time() + 2 * 86400))[3]);
like($h, qr/expires=\w{3}, $expday-/, 'expirace cookie = http.cookie_expire_guest (2 dny)');

my %types = (
    css           => qr/^Content-Type: text\/css/m,
    plain         => qr/^Content-Type: text\/plain/m,
    js            => qr/^Content-Type: .*javascript/mi,
    ajax          => qr/^Content-Type: text\/xml/m,
    400           => qr/^Status: 400/m,
    401           => qr/^Status: 401/m,
    404           => qr/^Status: 404/m,
    500           => qr/^Status: 500/m,
);
foreach my $t (sort keys %types) {
    like(PWE::TestEnv::capture(sub { $W->printHttpHeader(type => $t) }), $types{$t}, "printHttpHeader type=$t");
}
like(PWE::TestEnv::capture(sub { $W->printHttpHeader(type => 'error', status => 503) }), qr/^Status: 503/m, 'type=error se status');
like(PWE::TestEnv::capture(sub { $W->printHttpHeader(type => 'redirect', redirect_link => '/x?y=1') }), qr/^Location: \/x\?y=1/m, 'type=redirect Location');
like(PWE::TestEnv::capture(sub { $W->printHttpHeader(type => 'ajax_redirect', redirect_link => '/z') }), qr/^AjaxRedirect: \/z/m, 'type=ajax_redirect');
like(PWE::TestEnv::capture(sub { $W->printHttpHeader(type => 'file', filename => 'a.bin') }), qr/a\.bin/, 'type=file obsahuje jmeno souboru');

# --- printHtmlHeader / printHtmlLayout ---------------------------------------
$h = PWE::TestEnv::capture(sub { $W->printHtmlHeader(title => 'Titulek') });
like($h, qr/<!DOCTYPE html>/, 'printHtmlHeader doctype');
like($h, qr/<title>Titulek<\/title>/, 'printHtmlHeader title');

$U->setMessenger('<div id="m">MSG</div>');
$h = PWE::TestEnv::capture(sub { $W->printHtmlLayout(html_main => 'Pages/tPage/main.html', hello => 'H') });
like($h, qr/<body>/, 'printHtmlLayout body');
like($h, qr/Testovaci stranka/, 'printHtmlLayout rb');
like($h, qr/id="hello">H</, 'printHtmlLayout promenna');
like($h, qr/MSG/, 'messenger z Libs::User predan do layoutu');
ok(!$U->existMessenger(), 'messenger po vykresleni smazan');
like($h, qr/<\/html>/, 'printHtmlLayout konec html');

{
    local $C->{'pwe'}->{'prettyhtml'} = 1;
    $h = PWE::TestEnv::capture(sub { $W->printHtmlLayout(html_main => 'Pages/tPage/main.html') });
    like($h, qr/<\/html>\n$/, 'prettyhtml pridava zalomeni za </html>');
}

# --- printAjaxLayout ---------------------------------------------------------
$h = PWE::TestEnv::capture(sub { $W->printAjaxLayout(ajax_id => ['a', 'b'], ajax_html => ['<b>A</b>', 'B']) });
is_deeply(from_json($h), {REPLACE => [{ID => 'a', HTML => '<b>A</b>'}, {ID => 'b', HTML => 'B'}]}, 'printAjaxLayout ajax_html');
$W->flush();
is($W->getIDP(), 'unknownidp', 'flush vynuluje idp');
is($W->renderReplaceJSON(), 'null', 'renderReplaceJSON bez dat');

$W->setIDP('p1');
$h = PWE::TestEnv::capture(sub { $W->printAjaxLayout(ajax_id => ['x', 'y'], ajax_tmpl => ['[% v %]-[% idp %]'], ajax_data => {v => 'V'}) });
is_deeply(from_json($h)->{'REPLACE'}, [{ID => 'x', HTML => 'V-p1'}, {ID => 'y', HTML => 'V-p1'}], 'printAjaxLayout jedna sablona + jeden hash pro vice id');
$W->flush();

$h = PWE::TestEnv::capture(sub { $W->printAjaxLayout(ajax_id => ['x', 'y'], ajax_tmpl => ['[% v %]', '[% w %]'], ajax_data => [{v => 1}, {w => 2}]) });
is_deeply(from_json($h)->{'REPLACE'}, [{ID => 'x', HTML => '1'}, {ID => 'y', HTML => '2'}], 'printAjaxLayout vice sablon a dat');
$W->flush();

$U->setMessenger('MM');
$h = PWE::TestEnv::capture(sub { $W->printAjaxLayout(ajax_id => ['a'], ajax_html => ['A']) });
my $r = from_json($h)->{'REPLACE'};
is($r->[1]->{'ID'}, 'messenger', 'messenger pripojen do AJAX odpovedi');
is($r->[1]->{'HTML'}, 'MM', 'messenger obsah');
$W->flush();

# --- setMessenger (sablona + rb) ---------------------------------------------
$W->setMessenger('[% IF msg_allright %]OK:[% msg_allright.0 %][% END %]', msg_allright => ['saved']);
is($U->getMessenger(), 'OK:saved', 'setMessenger inline sablona');
$W->setIDP('tpage');
$W->setMessenger('Pages/tPage/msg.html', msg_allright => ['ok_saved']);
my $m = $U->getMessenger();
like($m, qr/alert-success/, 'messenger allright');
like($m, qr/Ulozeno/, 'messenger text z rb.msg');
$W->setMessenger('Pages/tPage/msg.html', msg_error => ['error_email']);
$m = $U->getMessenger();
like($m, qr/alert-danger/, 'messenger error');
like($m, qr/Spatny email/, 'messenger error text z rb.msg');
$W->setMessenger('Pages/tPage/msg.html', msg_error => ['unknown_key']);
like($U->getMessenger(), qr/\[msg\.unknown_key\]/, 'neznamy klic se vypise jako [msg.klic]');

# --- convertToRewrite --------------------------------------------------------
is($W->convertToRewrite('Příliš žluťoučký kůň!'), 'prilis_zlutoucky_kun', 'convertToRewrite (cestina -> ascii, _)');
is($W->convertToRewrite('  A  B  '), 'a_b', 'convertToRewrite mezery');

PWE::TestEnv::finish($E);
done_testing();
