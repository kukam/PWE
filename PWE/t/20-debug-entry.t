#!/usr/bin/env perl
# Ladici vstup enginu debug.cgi (VS Code debugger + nginx location /debug.cgi) nad fixture webem app2
# (dva koreny, bez databaze) - nezavisle na vzorovych webech ve webapps/:
#   - CGI rezim: stejna stranka jako pres pwe.fcgi, shoda SCRIPT_FILENAME s nazvem skriptu
#   - spusteni relativni cestou (regrese: do FILE hledalo cestu v @INC a skript skoncil tise s kodem 0)
#   - chyba pri startu enginu se propise do navratoveho kodu stejne jako u pwe.fcgi
#   - FastCGI pod debuggerem (perl -d): signal INT, ktery VS Code posila pri zmene breakpointu a Pause,
#     nesmi ukoncit cekajici server (regrese); bez debuggeru INT server ukonci jako driv
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use lib "$FindBin::Bin/../tools/lib";
use File::Basename qw(dirname basename);
use File::Path qw(make_path remove_tree);
use PWE::TestEnv;
use PWE::ToolEnv qw(run_cgi parse_response);
use PWE::TestServer qw(free_port port_open wait_for alive);

plan skip_all => 'chybi Template / CGI::Fast' unless (eval { require Template; require CGI::Fast; 1 });
PWE::TestEnv::clean_env();

(my $ROOT = PWE::TestEnv::root()) =~ s{/+$}{};    # adresar enginu (odvozeny od umisteni testu, ne od nazvu)
(my $APP2 = PWE::TestEnv::app2()) =~ s{/+$}{};
my $TMP = "$APP2/ramdisk/debug-entry-$$";
make_path($TMP, "$APP2/ramdisk/templates");

my %ENV_BASE = (
    'PATH'                  => ($ENV{'PATH'} || '/usr/bin:/bin'),
    'PWE_CONF_pwe_home'     => "$APP2/",
    'PWE_CONF_pwe_core'     => "$ROOT/",
    'PWE_CONF_log_loglevel' => 1,
    'PWE_CONF_log_logout'   => 'STDERR',
    'REMOTE_ADDR'           => '127.0.0.1',
    'HTTP_HOST'             => 'localhost',
    'SERVER_NAME'           => 'localhost',
);
my %ENV_CGI = (%ENV_BASE, 'SCRIPT_FILENAME' => '/debug.cgi', 'REQUEST_METHOD' => 'GET', 'QUERY_STRING' => 'page=tPage2&func=default');

sub sq { my ($s) = @_; $s =~ s/'/'\\''/g; return "'$s'"; }

# jeden CGI request libovolnym prikazem z daneho adresare; vraci (stdout, navratovy kod, stderr)
sub run_raw {
    my ($cwd, $cmd, %env) = @_;
    my $errf = "$TMP/raw.err";
    my $out  = `cd ${\ sq($cwd)} && env -i ${\ join(' ', map { sq("$_=$env{$_}") } sort keys %env)} $cmd 2>${\ sq($errf)} </dev/null`;
    my $rc   = $? >> 8;
    my $err  = '';
    if (open(my $fh, '<', $errf)) { local $/; $err = <$fh>; close($fh); }
    return ($out, $rc, $err);
}

# ---------------------------------------------------------------------------------------------
# 1) CGI rezim nad app2
# ---------------------------------------------------------------------------------------------
my ($out, $err) = run_cgi($APP2, core => $ROOT, entry => 'debug.cgi', script => '/debug.cgi', query => 'page=tPage2&func=default');
my $r = parse_response($out);
is($r->{'status'}, 200, 'debug.cgi + SCRIPT_FILENAME=/debug.cgi: stranka 200') or diag($err);
like($r->{'body'}, qr/Ahoj z app2 \(tpage2\)/, 'debug.cgi: obsah stranky z webu');
unlike($err, qr/\[E\]/, 'debug.cgi: engine nezalogoval chybu') or diag($err);

my ($out2) = run_cgi($APP2, core => $ROOT, query => 'page=tPage2&func=default');
my $r2 = parse_response($out2);
is($r->{'headers'}->{'content-type'}, $r2->{'headers'}->{'content-type'}, 'debug.cgi a pwe.fcgi: stejny Content-Type');
(my $b1 = $r->{'body'})  =~ s/debug\.cgi/pwe.fcgi/g;
is(length($b1), length($r2->{'body'}), 'debug.cgi a pwe.fcgi: stejne dlouha stranka (az na nazev skriptu)');

($out) = run_cgi($APP2, core => $ROOT, script => '/debug.cgi', query => 'page=tPage2&func=default');
$r = parse_response($out);
is($r->{'status'}, 401, 'pwe.fcgi + SCRIPT_FILENAME=/debug.cgi: 401 (jiny nazev skriptu se nebere jako stranka)');
unlike($r->{'body'}, qr/use strict|require \$engine/, 'zdrojovy kod debug.cgi se neserviruje');
($out) = run_cgi($APP2, core => $ROOT, entry => 'debug.cgi', script => '/pwe.fcgi', query => 'page=tPage2&func=default');
$r = parse_response($out);
is($r->{'status'}, 401, 'debug.cgi + SCRIPT_FILENAME=/pwe.fcgi: 401');
unlike($r->{'body'}, qr/use strict|Libs::Config->new/, 'zdrojovy kod pwe.fcgi se neserviruje');

# ---------------------------------------------------------------------------------------------
# 2) spusteni relativni cestou (regrese) - nazev adresare enginu se bere z disku, ne natvrdo
# ---------------------------------------------------------------------------------------------
my ($parent, $name) = (dirname($ROOT), basename($ROOT));
my $rc;
($out, $rc, $err) = run_raw($parent, sq($^X) . ' ' . sq("$name/debug.cgi"), %ENV_CGI);
is($rc, 0, "perl $name/debug.cgi z nadrazeneho adresare: navratovy kod 0") or diag($err);
is(parse_response($out)->{'status'}, 200, "perl $name/debug.cgi: stranka 200 (regrese: prazdny vystup)");
like($out, qr/Ahoj z app2/, "perl $name/debug.cgi: obsah stranky");
($out, $rc, $err) = run_raw($ROOT, sq($^X) . ' debug.cgi', %ENV_CGI);
like($out, qr/Ahoj z app2/, 'perl debug.cgi z adresare enginu: obsah stranky') or diag($err);
($out, $rc, $err) = run_raw($APP2, sq($^X) . ' ' . sq("$ROOT/debug.cgi"), %ENV_CGI);
like($out, qr/Ahoj z app2/, 'perl <absolutni cesta>/debug.cgi z adresare webu: obsah stranky') or diag($err);

# ---------------------------------------------------------------------------------------------
# 3) chyba pri startu enginu: stejny navratovy kod a hlaska jako u pwe.fcgi
# ---------------------------------------------------------------------------------------------
my $noconf = "$TMP/noconf.web";
make_path($noconf);
my %env_bad = (%ENV_CGI, 'PWE_CONF_pwe_home' => "$noconf/");
my ($o_dbg, $rc_dbg, $e_dbg) = run_raw($noconf, sq($^X) . ' ' . sq("$ROOT/debug.cgi"), %env_bad);
my ($o_pwe, $rc_pwe, $e_pwe) = run_raw($noconf, sq($^X) . ' ' . sq("$ROOT/pwe.fcgi"), %env_bad, 'SCRIPT_FILENAME' => '/pwe.fcgi');
isnt($rc_dbg, 0, 'web bez conf/web.conf: debug.cgi konci nenulovym kodem');
is($rc_dbg, $rc_pwe, 'web bez conf/web.conf: stejny navratovy kod jako pwe.fcgi');
like($e_dbg, qr/web\.conf/, 'web bez conf/web.conf: chyba je videt na STDERR') or diag($e_dbg);
is($o_dbg, '', 'web bez conf/web.conf: zadny vystup na STDOUT');

# ---------------------------------------------------------------------------------------------
# 4) FastCGI server a signal INT (pod debuggerem / bez nej)
# ---------------------------------------------------------------------------------------------
# FastCGI server a klient jsou v PWE::TestServer (t/lib); tady jen obaly pro debug.cgi nad app2.

# spusti debug.cgi jako FastCGI server na portu; $opts = volby perlu (napr. -d), %extra = dalsi prostredi
sub start_server {
    my ($port, $opts, %extra) = @_;
    return PWE::TestServer::start_server(
        script => "$ROOT/debug.cgi",
        cwd    => $APP2,
        perl   => $opts,
        out    => "$TMP/server.out",
        err    => "$TMP/server.err",
        env    => {%ENV_BASE, 'FCGI_SOCKET_PATH' => ":$port", %extra},
    );
}

# jeden FastCGI request na /debug.cgi; vraci (1|0 = prisel END_REQUEST, CGI vystup)
sub fcgi_get {
    my ($port, $query) = @_;
    return PWE::TestServer::fcgi_get($port, $query, script => '/debug.cgi');
}

SKIP: {
    my $port = free_port();
    skip('nelze otevrit lokalni TCP port', 9) unless ($port);

    # --- pod debuggerem: minimalni "debugger" misto perl5db.pl - nastavi handler INT stejne jako skutecny
    #     debugger (ten jim zastavuje beh a aktivuje breakpointy) a pocita, kolikrat byl zavolan
    my $marker = "$TMP/int.count";
    #     (cesta k souboru se cte uz v BEGIN - FastCGI behem requestu vymeni obsah %ENV)
    my $db     = 'BEGIN { my $m = $ENV{PWE_TEST_INT_MARKER}; $SIG{INT} = sub { open(my $f, q{>>}, $m) or return; print $f qq{x}; close($f); }; } sub DB::DB {}';
    my $pid    = start_server($port, ['-d'], 'PERL5DB' => $db, 'PWE_TEST_INT_MARKER' => $marker);
    ok(wait_for(sub { port_open($port) }, 20), 'pod debuggerem: FastCGI server posloucha') or diag(`cat ${\ sq("$TMP/server.err")} 2>/dev/null`);

    my ($done, $resp) = fcgi_get($port, 'page=tPage2&func=default');
    ok($done && $resp =~ /Ahoj z app2/, 'pod debuggerem: prvni request obslouzen');

    select(undef, undef, undef, 0.5);    # server uz zase ceka na dalsi request (accept)
    kill('INT', $pid);
    ok(wait_for(sub { -s $marker }, 10), 'pod debuggerem: INT dorazil do handleru debuggeru');
    select(undef, undef, undef, 0.5);
    ok(alive($pid), 'pod debuggerem: server po INT bezi dal (regrese: zmena breakpointu ukoncila ladeni)');
    ok(port_open($port), 'pod debuggerem: port po INT stale posloucha');
    ($done, $resp) = fcgi_get($port, 'page=tPage2&func=default');
    ok($done && $resp =~ /Ahoj z app2/, 'pod debuggerem: dalsi request po INT obslouzen');

    kill('TERM', $pid);
    ok(wait_for(sub { !alive($pid) }, 10), 'pod debuggerem: TERM server ukonci');
    kill('KILL', $pid) if (alive($pid));

    # --- bez debuggeru: obaleni se nepouzije, INT (Ctrl-C) server ukonci jako u pwe.fcgi
    my $port2 = free_port();
    my $pid2  = start_server($port2, []);
    ok(wait_for(sub { port_open($port2) }, 20), 'bez debuggeru: FastCGI server posloucha');
    select(undef, undef, undef, 0.3);
    kill('INT', $pid2);
    ok(wait_for(sub { !alive($pid2) }, 10), 'bez debuggeru: INT server ukonci (chovani beze zmeny)');
    kill('KILL', $pid2) if (alive($pid2));
}

remove_tree($TMP);
done_testing();
