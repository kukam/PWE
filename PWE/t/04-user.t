#!/usr/bin/env perl
# Libs::User - session id, parametry, skupiny, opts (perzistence do souboru), messenger, upload.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Path qw(remove_tree);
use lib "$FindBin::Bin/lib";
use PWE::TestEnv;

my $E   = PWE::TestEnv->boot();
my $U   = $E->{'USER'};
my $APP = PWE::TestEnv::app();

# --- novy request bez cookie -------------------------------------------------
PWE::TestEnv::request($E, page => 'tPage', func => 'default');
my $sid = $U->getSid();
like($sid, qr/^C0[0-9A-F]{32}$/, 'vygenerovano nove sid C0 + md5hex (HTTP)');
is($U->getPage(), 'tPage', 'getPage');
is($U->getFunc(), 'default', 'getFunc');
is($U->getActivePage(), 'tPage', 'getActivePage');
ok($U->existGroup('guest'), 'vychozi skupina guest');
is($U->getIP(), '10.0.0.1', 'getIP z REMOTE_ADDR');
is($U->getUserAgent(), 'pwe-test', 'getUserAgent');
is($U->getEnv('HTTP_HOST'), 'test.local', 'getEnv');
is($U->getEnv('NOPE', 'd'), 'd', 'getEnv default');
is($U->getRequestMethod(), 'GET', 'getRequestMethod z env');
isa_ok($U->getCGI(), 'CGI', 'getCGI');

# --- parametry ---------------------------------------------------------------
$U->setParameter('a', ['1', '2']);
is($U->getParam('a'), '1', 'getParam bez pozice = prvni');
is($U->getParam('a', 1), '2', 'getParam pozice 1');
is($U->getParam('a', 5, 'd'), 'd', 'getParam mimo rozsah -> default');
is_deeply($U->getParam('a', 'all'), ['1', '2'], 'getParam all');
is($U->getParam('nope', 0, 'd'), 'd', 'getParam neexistujici -> default');
ok($U->existParam('a'), 'existParam');
ok(!$U->existParam('nope'), 'existParam neexistujici');
$U->setParameter('a', 'X', 1);
is_deeply($U->getParam('a', 'all'), ['1', 'X'], 'setParameter na pozici');
$U->setParameter('e', ['']);
ok(!$U->isdefinedParam('e'), 'isdefinedParam prazdny retezec = 0');
ok($U->isdefinedParam('a'), 'isdefinedParam');
ok(!$U->isdefinedParam('nope'), 'isdefinedParam neexistujici');
is_deeply([sort @{$U->getParamsList()}], ['a', 'e'], 'getParamsList');
is(ref($U->getParams()), 'HASH', 'getParams');

# --- skupiny -----------------------------------------------------------------
$U->addGroup('admin');
ok($U->existGroup('admin'), 'addGroup');
$U->deleteGroup('admin');
ok(!$U->existGroup('admin'), 'deleteGroup');
is(ref($U->getGroup()), 'HASH', 'getGroup');

# --- getValue ----------------------------------------------------------------
is($U->getValue('page'), 'tPage', 'getValue klic');
is($U->getValue('env', 'REMOTE_ADDR'), '10.0.0.1', 'getValue klic/podklic');
is($U->getValue('env', 'X', 'd'), 'd', 'getValue default podklic');
is($U->getValue('nope', undef, 'd'), 'd', 'getValue default klic');

# --- opts --------------------------------------------------------------------
$U->setOpts('v1', 'k1');
is($U->getOpts('k1'), 'v1', 'setOpts/getOpts');
ok($U->existOpts('k1'), 'existOpts');
$U->setOpts({x => 1}, 'k2', 'sub');
is_deeply($U->getOpts('k2', 'sub'), {x => 1}, 'setOpts s podklicem (dclone)');
ok($U->existOpts('k2', 'sub'), 'existOpts podklic');
ok(!$U->existOpts('k2', 'nope'), 'existOpts neexistujici podklic');
$U->delOpts('k2', 'sub');
ok(!$U->existOpts('k2', 'sub'), 'delOpts podklic');
$U->delOpts('k1');
ok(!$U->existOpts('k1'), 'delOpts');
is($U->getOpts('k1', undef, 'd'), 'd', 'getOpts default');

# --- messenger ---------------------------------------------------------------
ok(!$U->existMessenger(), 'messenger neexistuje');
$U->setMessenger('<p>hi</p>');
ok($U->existMessenger(), 'setMessenger');
is($U->getMessenger(), '<p>hi</p>', 'getMessenger');
ok(!$U->existMessenger(), 'getMessenger messenger smaze (flash)');

# --- jazyk, uid, page/func ---------------------------------------------------
is($U->getValue('language'), 'CZE', 'vychozi jazyk = prvni z conf');
$U->setLanguage('EN');
is($U->getValue('language'), 'EN', 'setLanguage platny');
$U->setLanguage('DE');
is($U->getValue('language'), 'EN', 'setLanguage neplatny ignorovan');
$U->setUid(7);
is($U->getUid(), 7, 'setUid/getUid');
$U->setPage('x');
$U->setFunc('y');
is($U->getPage(), 'x', 'setPage');
is($U->getFunc(), 'y', 'setFunc');

my $exp = $U->exportUserData();
is($exp->{'lastpage'}, 'x', 'exportUserData lastpage');
is($exp->{'language'}, 'EN', 'exportUserData language');
is_deeply($exp->{'lastparameters'}->{'a'}, ['1', 'X'], 'exportUserData lastparameters');

# --- flush: zapis opts (rekurzivni vytvoreni adresare) + vynulovani ----------
$U->setOpts('persist', 'k3');
remove_tree("${APP}ramdisk/opts");
PWE::TestEnv::finish($E);
my $optfile = "${APP}ramdisk/opts/" . substr($sid, 0, 3) . "/$sid.bin";
ok(-f $optfile, 'opts soubor zapsan, adresar vytvoren rekurzivne (regrese mkdir)');
ok(!defined($U->getSid()), 'flush vynuluje sid');
ok(!$U->existGroup('guest'), 'flush vynuluje skupiny');
is_deeply($U->getParams(), {}, 'flush vynuluje parametry');
is($U->getValue('language'), 'CZE', 'flush vrati vychozi jazyk');

# --- dalsi request se stejnym sid nacte opts ---------------------------------
PWE::TestEnv::request($E, page => 'tPage', func => 'form', sid => $sid);
is($U->getSid(), $sid, 'platne sid zustava');
is($U->getOpts('k3'), 'persist', 'opts nacteny ze souboru');
is($U->getValue('lastpage'), 'x', 'lastpage nacten');
is($U->getLastParam('a', 1), 'X', 'getLastParam');
is($U->getLastParam('nope', 0, 'd'), 'd', 'getLastParam default');
ok($U->existLastParam('a'), 'existLastParam');
ok($U->existLastParams(), 'existLastParams');
is($U->getLastEnv('REMOTE_ADDR'), '10.0.0.1', 'getLastEnv');
is($U->getValue('language'), 'EN', 'jazyk je perzistentni v opts');
PWE::TestEnv::finish($E);

# --- validace cookie ---------------------------------------------------------
PWE::TestEnv::request($E, sid => 'not-hex!');
like($U->getSid(), qr/^C0[0-9A-F]{32}$/, 'nehexove sid zahozeno, vygenerovano nove');
PWE::TestEnv::finish($E);

PWE::TestEnv::request($E, sid => $sid, env => {HTTPS => 'on'});
isnt($U->getSid(), $sid, 'C0 cookie pres HTTPS zahozena');
like($U->getSid(), qr/^C1[0-9A-F]{32}$/, 'pres HTTPS se generuje C1');
my $sid1 = $U->getSid();
PWE::TestEnv::finish($E);

PWE::TestEnv::request($E, sid => $sid1);
isnt($U->getSid(), $sid1, 'C1 cookie pres HTTP zahozena');
PWE::TestEnv::finish($E);

PWE::TestEnv::request($E, sid => ('A' x 34));
isnt($U->getSid(), ('A' x 34), 'hex bez prefixu C0/C1 zahozen');
PWE::TestEnv::finish($E);

PWE::TestEnv::request($E, sid => $sid, opt => 0);
is($U->getSid(), $sid, 'sid pri opt=0 zustava');
ok(!$U->existOpts('k3'), 'opt=0 nenacita opts');
PWE::TestEnv::finish($E);

# --- request_method z parametru (spusteni z prikazove radky) -----------------
PWE::TestEnv::request($E, env => {REQUEST_METHOD => undef}, params => {request_method => ['post']});
is($U->getRequestMethod(), 'POST', 'getRequestMethod z parametru request_method');
PWE::TestEnv::finish($E);

# --- saveUploadFile ----------------------------------------------------------
PWE::TestEnv::request($E);
my ($err, @files) = $U->saveUploadFile('file_single', $APP, 'ramdisk/upload/', 1);
is($err, 'error_parameter_is_empty', 'saveUploadFile bez parametru');
PWE::TestEnv::finish($E);

SKIP: {
    # Realny multipart upload pres CGI.pm: jmeno souboru s "../" musi byt ocisteno na basename.
    my $boundary = 'PWETESTBOUNDARY';
    my $body = join("\r\n",
        "--$boundary",
        'Content-Disposition: form-data; name="file_single"; filename="../../evil.txt"',
        'Content-Type: text/plain',
        '',
        'hello upload',
        "--$boundary--",
        '');
    local %ENV = (%ENV,
        'REQUEST_METHOD' => 'POST',
        'CONTENT_TYPE'   => "multipart/form-data; boundary=$boundary",
        'CONTENT_LENGTH' => length($body),
    );
    local *STDIN;
    open(STDIN, '<', \$body) or skip("nelze otevrit in-memory STDIN: $!", 4);
    binmode(STDIN);
    CGI::initialize_globals();
    my $cgi = CGI->new();
    my $fh  = $cgi->param('file_single');
    skip("CGI.pm multipart parsovani v tomto prostredi nefunguje", 4) unless (defined($fh) and ref($fh));

    $U->newRequest('tPage', 'form', undef, 1, {REMOTE_ADDR => '1.1.1.1', REQUEST_METHOD => 'POST'}, $cgi);
    $U->setParameter('file_single', [$fh]);
    remove_tree("${APP}ramdisk/upload");
    my ($e2, @f2) = $U->saveUploadFile('file_single', $APP, 'ramdisk/upload/', 1);
    ok(!defined($e2), 'saveUploadFile bez chyby') or diag($e2);
    is_deeply(\@f2, ['evil.txt'], 'nazev souboru ocisten na basename (ochrana proti ../)');
    ok(-f "${APP}ramdisk/upload/evil.txt", 'soubor ulozen do upload adresare');
    ok(!-f "${APP}evil.txt", 'soubor NEskoncil mimo upload adresar');
    my ($e3) = $U->saveUploadFile('file_single', $APP, 'ramdisk/upload/', 0);
    is($e3, 'error_file_is_exist', 'rewrite_enable=0 a existujici soubor -> chyba');
    $U->flush();
}

# --- regenerateSid: nove sid po prihlaseni (ochrana proti session fixation) -----------------
PWE::TestEnv::request($E, page => 'tPage', func => 'default');
my $before = $U->getSid();
my $regen  = $U->regenerateSid();
like($regen, qr/^C0[0-9A-F]{32}$/, 'regenerateSid: nove sid ma tvar C0 + md5hex (HTTP)');
isnt($regen, $before, 'regenerateSid: sid se zmenilo');
is($U->getSid(), $regen, 'regenerateSid: getSid vraci nove sid (cookie_id pro printHttpHeader)');
$U->setOpts('after', 'k4');
remove_tree("${APP}ramdisk/opts");
PWE::TestEnv::finish($E);
ok(-f "${APP}ramdisk/opts/" . substr($regen, 0, 3) . "/$regen.bin", 'opts se po regeneraci ulozi pod nove sid');
ok(!-f "${APP}ramdisk/opts/" . substr($before, 0, 3) . "/$before.bin", 'pod stare sid se uz nic nezapsalo');
PWE::TestEnv::request($E, sid => $regen);
is($U->getOpts('k4'), 'after', 'dalsi request s novym sid nacte opts');
PWE::TestEnv::finish($E);

PWE::TestEnv::request($E, env => {HTTPS => 'on'});
like($U->regenerateSid(), qr/^C1[0-9A-F]{32}$/, 'regenerateSid pres HTTPS generuje C1');
PWE::TestEnv::finish($E);

# --- prisny tvar cookie: presne C0/C1 + 32 hex znaku (regrese: is_md5hex pustilo C0ABC) ----
foreach my $bad ('C0ABC', 'C0' . ('A' x 31), 'C0' . ('A' x 33), 'C2' . ('A' x 32), 'c0' . ('A' x 32), 'C0' . ('G' x 32), 'C0' . ('A' x 31) . '-') {
    PWE::TestEnv::request($E, sid => $bad);
    isnt($U->getSid(), $bad, "cookie '$bad' zahozena");
    like($U->getSid(), qr/^C0[0-9A-F]{32}$/, "... misto '$bad' vygenerovano nove sid");
    PWE::TestEnv::finish($E);
}
PWE::TestEnv::request($E, sid => 'C0' . ('a' x 32));
is($U->getSid(), 'C0' . ('a' x 32), 'C0 + 32 hex znaku (male pismo) je platne sid');
PWE::TestEnv::finish($E);
PWE::TestEnv::request($E, sid => 'C1' . ('F' x 32), env => {HTTPS => 'on'});
is($U->getSid(), 'C1' . ('F' x 32), 'C1 + 32 hex znaku pres HTTPS je platne sid');
PWE::TestEnv::finish($E);

# --- getValue: undef atribut vraci default (regrese: getActivePage vracel undef) ---
{
    local $U->{'page'} = undef;
    is($U->getValue('page', undef, 'default'), 'default', 'getValue: undef atribut -> default');
    is($U->getActivePage(), 'default', 'getActivePage bez page -> default');
    local $U->{'zero'} = 0;
    is($U->getValue('zero', undef, 'd'), 0, 'getValue: hodnota 0 se vraci (ne default)');
    is($U->getValue('nope', undef, 'd'), 'd', 'getValue: neexistujici atribut -> default');
}

done_testing();
