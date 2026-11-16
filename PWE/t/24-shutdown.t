#!/usr/bin/env perl
# Ukoncovani enginu a naslouchani na socketu (pwe.fcgi) - skutecny FastCGI server nad fixture webem app2:
#   - jednorazove CGI (bez FCGI_SOCKET_PATH) funguje beze zmeny, i kdyz behem requestu prijde TERM
#   - TERM v necinnosti: konec s kodem 0 (hned po odpovedi, bez jedineho spojeni, po prazdnem spojeni,
#     dvakrat po sobe); USR1 = TERM
#   - TERM uprostred requestu (regrese: handler odpojil databazi pod rozpracovanym requestem a proces
#     po nem neskoncil): request dobehne s pripojenou databazi, klient dostane celou odpoved, dalsi
#     spojeni uz engine neprijme, pak kod 0; druhy TERM nic nezmeni
#   - TERM tesne pred cekanim na dalsi request (regrese: signal cekani neprerusil a engine zustal viset)
#   - TERM behem startu (regrese: "Can't call method getDbidList on an undefined value"): start dobehne
#     a engine skonci pred otevrenim socketu, nebo ho Libs::MyDBI prerusi vyjimkou - v obou pripadech kod 0
#     (vyjimku nejdriv napodobi PWE::ShutdownHooks, pak ji vyhodi skutecna Libs::MyDBI cekajici na
#     nedostupnou databazi - jen v image s ovladacem DBD::mysql)
#   - spojeni drzene webserverem (keep_conn), pomaly odesilatel requestu, prazdna spojeni mezi requesty,
#     jiny signal nez TERM (handler webu) cekajici engine neukonci
#   - FCGI_SOCKET_PATH=127.0.0.1:<port> (regrese: "Couldn't chmod(127.0.0.1:...)"): jen loopback
#   - unix socket (regrese: prava 1402 misto 0770): vychozi 0770, FCGI_SOCKET_PERM osmickove, chybna hodnota
# Na udalosti se ceka (wait_for, znacky v ramdisk/), nikdy pevnou dobu. Zasahy do serveru jen pro tento
# test jsou v PWE::ShutdownHooks (t/lib), pomaly request je funkce slow fixture stranky tPage2.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use lib "$FindBin::Bin/../tools/lib";
use lib "$FindBin::Bin/..";
use File::Copy qw(copy);
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);
use IO::Socket::INET;
use Socket qw(inet_ntoa);
use Sys::Hostname qw(hostname);
use PWE::TestEnv;
use PWE::ToolEnv qw(run_cgi parse_response);
use PWE::TestServer qw(free_port port_open wait_for start_server alive exit_status fcgi_send fcgi_read fcgi_get);

plan skip_all => 'chybi Template / CGI::Fast' unless (eval { require Template; require CGI::Fast; 1 });
PWE::TestEnv::clean_env();

(my $ROOT = PWE::TestEnv::root()) =~ s{/+$}{};
(my $APP2 = PWE::TestEnv::app2()) =~ s{/+$}{};
my $MARK    = "shutdown-$$";                                             # adresare se znackami: ramdisk/shutdown-<pid>-<n>
my $SOCKDIR = tempdir('pwe-shutdown-XXXXXX', TMPDIR => 1, CLEANUP => 1);    # unix sockety mimo (pripadne mountovany) repozitar
make_path("$APP2/ramdisk/templates");

my %ENV_BASE = (
    'PATH'                  => ($ENV{'PATH'} || '/usr/bin:/bin'),
    'PWE_CONF_pwe_home'     => "$APP2/",
    'PWE_CONF_pwe_core'     => "$ROOT/",
    'PWE_CONF_log_loglevel' => 3,                                        # info: hlasky o socketu a o ukonceni
    'PWE_CONF_log_logout'   => 'STDERR',
    'REMOTE_ADDR'           => '127.0.0.1',
    'HTTP_HOST'             => 'localhost',
    'SERVER_NAME'           => 'localhost',
);
my %ENV_CGI = ('SCRIPT_FILENAME' => '/pwe.fcgi', 'REQUEST_METHOD' => 'GET');

my (@DIRS, @PIDS);
my $SEQ = 0;

# novy scenar: adresar pro znacky a vystupy serveru; mark = jeho nazev pod ramdisk/ (parametr stranky slow)
sub scenario {
    my $mark = "$MARK-" . (++$SEQ);
    my $dir  = "$APP2/ramdisk/$mark";
    make_path($dir);
    push(@DIRS, $dir);
    return {'mark' => $mark, 'dir' => $dir, 'err' => "$dir/server.err", 'out' => "$dir/server.out"};
}

# spusti pwe.fcgi pro scenar; env = prostredi navic, hooks = 1 nacte PWE::ShutdownHooks
sub launch {
    my ($S, %o) = @_;
    $S->{'pid'} = start_server(
        script => "$ROOT/pwe.fcgi",
        cwd    => $APP2,
        out    => $S->{'out'},
        err    => $S->{'err'},
        perl   => ($o{'hooks'} ? ["-I$ROOT", "-I$ROOT/t/lib", '-MPWE::ShutdownHooks'] : []),
        env    => {%ENV_BASE, 'PWE_TEST_HOOK_DIR' => $S->{'dir'}, %{$o{'env'} || {}}},
    );
    push(@PIDS, $S->{'pid'});
    return $S;
}

sub slurp {
    my ($file) = @_;
    open(my $fh, '<', $file) or return '';
    local $/;
    my $text = <$fh>;
    close($fh);
    return (defined($text) ? $text : '');
}
sub srvlog { my ($S) = @_; return slurp($S->{'err'}); }

sub touch {
    my ($file) = @_;
    open(my $fh, '>>', $file) or die "$file: $!";
    close($fh);
}

# ceka, az server posloucha na cili (port, host:port, cesta k socketu); 0 = neposloucha nebo skoncil
sub listening {
    my ($S, $target) = @_;
    wait_for(sub { port_open($target) or !alive($S->{'pid'}) }, 20);
    return (alive($S->{'pid'}) and port_open($target)) ? 1 : 0;
}

# ceka na konec serveru; vraci popis, jak skoncil ("kod 0, signal 0")
sub stopped {
    my ($S, $sec) = @_;
    unless (wait_for(sub { !alive($S->{'pid'}) }, $sec)) {
        kill('KILL', $S->{'pid'});
        wait_for(sub { !alive($S->{'pid'}) }, 5);
        return "neskoncil do $sec s (zabit signalem KILL)";
    }
    my $st = exit_status($S->{'pid'});
    return "kod $st->{'code'}, signal $st->{'signal'}";
}

sub request_ok {
    my ($target, $name, %o) = @_;
    my ($done, $out) = fcgi_get($target, 'page=tPage2&func=default', %o);
    return ok(($done and $out =~ /Ahoj z app2/), $name);
}

# log bez chyb: zadna chyba enginu, zadna vyjimka z handleru signalu, zadne varovani perlu
sub clean_log {
    my ($S, $name) = @_;
    my $log = srvlog($S);
    return unlike($log, qr/\[E\]|Can't call method|Use of uninitialized| at \S+ line \d+/, $name) || diag($log);
}

# IPv4 adresa jineho rozhrani nez loopback (jmeno kontejneru, jinak rozhrani s vychozi cestou), nebo undef
sub other_address {
    my @cand;
    my @h = gethostbyname(hostname());
    push(@cand, map { inet_ntoa($_) } @h[4 .. $#h]) if (@h > 4);
    if (my $u = IO::Socket::INET->new(Proto => 'udp', PeerAddr => '192.0.2.1', PeerPort => 9)) {    # UDP: nic se neposila
        push(@cand, $u->sockhost);
        close($u);
    }
    foreach my $addr (@cand) { return $addr if (defined($addr) and $addr !~ /^(?:127\.|0\.0\.0\.0$)/); }
    return undef;
}

END {
    foreach my $pid (@PIDS) { kill('KILL', $pid) if (alive($pid)); }
    remove_tree(@DIRS) if (@DIRS);
}

# ---------------------------------------------------------------------------------------------
# 0) kontrakt s Libs::MyDBI (handler signalu TERM behem startu)
# ---------------------------------------------------------------------------------------------
SKIP: {
    skip('Libs::MyDBI nejde nacist', 1) unless (eval { require Libs::MyDBI; 1 });
    ok((Libs::MyDBI->can('requestStop') and Libs::MyDBI->can('stopRequested')), 'Libs::MyDBI ma requestStop() a stopRequested() (kontrakt s pwe.fcgi)');
}

# ---------------------------------------------------------------------------------------------
# 1) jednorazove CGI bez FCGI_SOCKET_PATH: beze zmeny
# ---------------------------------------------------------------------------------------------
{
    my ($out, $err) = run_cgi($APP2, core => $ROOT, loglevel => 3, query => 'page=tPage2&func=default');
    my $r = parse_response($out);
    is($r->{'status'}, 200, 'CGI: stranka 200') or diag($err);
    like($r->{'body'}, qr/Ahoj z app2 \(tpage2\)/, 'CGI: obsah stranky');
    unlike($err, qr/\[E\]/, 'CGI: engine nezalogoval chybu') or diag($err);
    unlike($err, qr/FastCGI socket|ukoncen signalem|prerusen signalem/, 'CGI: zadny socket ani hlaska o ukonceni');

    my $S = launch(scenario(), env => {%ENV_CGI, 'QUERY_STRING' => 'page=tPage2&func=roots'});
    is(stopped($S, 20), 'kod 0, signal 0', 'CGI: po jednom requestu konec s kodem 0');
    like(slurp($S->{'out'}), qr/^HOME=\Q$APP2\E\/$/m, 'CGI: odpoved na STDOUT');

    # TERM behem requestu: request dobehne, vystup je cely, kod 0
    $S = scenario();
    launch($S, env => {%ENV_CGI, 'QUERY_STRING' => "page=tPage2&func=slow&mark=$S->{'mark'}&size=20"});
    ok(wait_for(sub { -e "$S->{'dir'}/slow.started" }, 20), 'CGI + TERM: request bezi') or diag(srvlog($S));
    kill('TERM', $S->{'pid'});
    touch("$S->{'dir'}/slow.release");
    is(stopped($S, 20), 'kod 0, signal 0', 'CGI + TERM: request dobehl, kod 0');
    like(slurp($S->{'out'}), qr/^SLOW released=1\n.*^SLOW-END\n\z/ms, 'CGI + TERM: cela odpoved na STDOUT');
    clean_log($S, 'CGI + TERM: log bez chyb');
}

# ---------------------------------------------------------------------------------------------
# 2) TERM v necinnosti
# ---------------------------------------------------------------------------------------------
my $OTHER     = other_address();
my $REACHABLE = 0;                   # da se na $OTHER pripojit, kdyz engine posloucha na vsech rozhranich?
{
    # hned po odpovedi (klient zavre spojeni a test posle TERM - engine jeste nemusi cekat v accept)
    my $port = free_port();
    my $S    = launch(scenario(), env => {'FCGI_SOCKET_PATH' => ":$port"});
    ok(listening($S, $port), 'TERM po odpovedi: server posloucha') or diag(srvlog($S));
    like(srvlog($S), qr/FastCGI socket :$port: adresa TCP/, 'log: socket a jeho typ');
    $REACHABLE = ($OTHER and port_open("$OTHER:$port")) ? 1 : 0;

    # druhy engine na obsazenem portu skonci chybou (hlasi ji knihovna FastCGI), prvni bezi dal
    my $S2 = launch(scenario(), env => {'FCGI_SOCKET_PATH' => ":$port"});
    isnt(stopped($S2, 20), 'kod 0, signal 0', 'obsazeny port: druhy engine skonci chybou');
    like(srvlog($S2), qr/bind\/listen/, 'obsazeny port: duvod na STDERR');

    request_ok($port, 'TERM po odpovedi: request obslouzen');
    kill('TERM', $S->{'pid'});
    is(stopped($S, 10), 'kod 0, signal 0', 'TERM po odpovedi: konec s kodem 0');
    ok(!port_open($port), 'TERM po odpovedi: port je zavreny');
    like(srvlog($S), qr/PWE server ukoncen signalem TERM/, 'TERM po odpovedi: hlaska v logu');
    clean_log($S, 'TERM po odpovedi: log bez chyb');

    # bez jedineho spojeni (na socket se ceka podle logu, ne pokusnym spojenim)
    $port = free_port();
    $S    = launch(scenario(), env => {'FCGI_SOCKET_PATH' => ":$port"});
    ok(wait_for(sub { srvlog($S) =~ /FastCGI socket/ or !alive($S->{'pid'}) }, 20), 'TERM bez spojeni: server posloucha');
    kill('TERM', $S->{'pid'});
    is(stopped($S, 10), 'kod 0, signal 0', 'TERM bez spojeni: konec s kodem 0');

    # po prazdnem spojeni (TCP sonda), dva TERM tesne po sobe
    $port = free_port();
    $S    = launch(scenario(), env => {'FCGI_SOCKET_PATH' => ":$port"});
    ok(listening($S, $port), 'TERM po prazdnem spojeni: server posloucha');
    kill('TERM', $S->{'pid'});
    kill('TERM', $S->{'pid'});
    is(stopped($S, 10), 'kod 0, signal 0', 'dva TERM po prazdnem spojeni: konec s kodem 0');
    clean_log($S, 'dva TERM: log bez chyb');

    # USR1 (ukoncovaci signal knihovny FastCGI) = TERM
    $port = free_port();
    $S    = launch(scenario(), env => {'FCGI_SOCKET_PATH' => ":$port"});
    ok(listening($S, $port), 'USR1: server posloucha');
    request_ok($port, 'USR1: request obslouzen');
    kill('USR1', $S->{'pid'});
    is(stopped($S, 10), 'kod 0, signal 0', 'USR1: konec s kodem 0');
    like(srvlog($S), qr/PWE server ukoncen signalem USR1/, 'USR1: hlaska v logu');
}

# ---------------------------------------------------------------------------------------------
# 3) TERM uprostred requestu
# ---------------------------------------------------------------------------------------------
{
    my $port = free_port();
    my $S    = scenario();
    launch($S, hooks => 1, env => {'FCGI_SOCKET_PATH' => ":$port", 'PWE_TEST_FAKE_DB' => 1});
    ok(listening($S, $port), 'TERM v requestu: server posloucha') or diag(srvlog($S));

    my $kb = 300;
    my $c  = fcgi_send($port, "page=tPage2&func=slow&mark=$S->{'mark'}&size=$kb");
    ok(wait_for(sub { -e "$S->{'dir'}/slow.started" }, 20), 'TERM v requestu: request bezi') or diag(srvlog($S));
    kill('TERM', $S->{'pid'});
    # Port musi spojeni ODMITAT (zavreny socket), ne jen neodpovidat: pokusu je min, nez je delka fronty
    # cekajicich spojeni (FCGI_LISTEN_QUEUE, vychozi 100) - jinak by frontu zaplnil sam test a prosel by
    # i engine, ktery socket nezavrel.
    # Jina chyba spojeni nez "refused" (napr. vyprseni pri zatizenem stroji) pokus jen opakuje.
    my ($refused, $lasterr) = (0, '');
    for (1 .. 60) {
        my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 1);
        if ($s) { close($s); $lasterr = 'spojeni prijato'; select(undef, undef, undef, 0.05); next; }
        $lasterr = "$@";
        if ($lasterr =~ /refused/i) { $refused = 1; last; }
        select(undef, undef, undef, 0.05);
    }
    ok($refused, 'TERM v requestu: dalsi spojeni engine hned odmita (connection refused)')
      or diag("posledni vysledek pokusu o spojeni: $lasterr\n" . srvlog($S));
    kill('TERM', $S->{'pid'});
    ok(alive($S->{'pid'}), 'TERM v requestu: engine bezi, dokud request nedobehne');
    ok(!-e "$S->{'dir'}/db.disconnected", 'TERM v requestu: databaze zustava pripojena (regrese)');

    touch("$S->{'dir'}/slow.release");
    my ($done, $out) = fcgi_read($c);
    ok($done, 'TERM v requestu: klient dostal celou odpoved (END_REQUEST)');
    my $r = parse_response($out);
    is($r->{'status'}, 200, 'TERM v requestu: odpoved 200');
    like($r->{'body'}, qr/^SLOW released=1$/m, 'TERM v requestu: request se dockal sveho konce');
    like($r->{'body'}, qr/^DB tdb=1$/m,          'TERM v requestu: databaze na konci requestu funguje (regrese)');
    my $lines = () = $r->{'body'} =~ /^x{1023}$/mg;
    is($lines, $kb, "TERM v requestu: telo ma vsech $kb kB");
    like($r->{'body'}, qr/^SLOW-END\n\z/m, 'TERM v requestu: odpoved konci, jak ma');

    is(stopped($S, 10), 'kod 0, signal 0', 'TERM v requestu: po requestu konec s kodem 0 (regrese: proces neskoncil)');
    ok(-e "$S->{'dir'}/db.disconnected", 'TERM v requestu: databaze odpojena az pri ukonceni');
    ok(!port_open($port), 'TERM v requestu: port je zavreny');
    my $log = srvlog($S);
    is(scalar(() = $log =~ /Page printed/g), 1, 'TERM v requestu: obslouzen prave jeden request');
    like($log, qr/PWE server ukoncen signalem TERM/, 'TERM v requestu: hlaska v logu');
    clean_log($S, 'TERM v requestu: log bez chyb');
}

# ---------------------------------------------------------------------------------------------
# 3b) TERM ve chvili, kdy engine cte telo requestu nebo odesila odpoved (regrese: knihovna FastCGI
#     read()/write() prerusene signalem neopakuje a proud zavre - stranka dostala zkracene telo POST
#     a zalogovala 200, klient dostal jen cast odpovedi; po dobu requestu proto maji handlery SA_RESTART)
# ---------------------------------------------------------------------------------------------
SKIP: {
    skip('chybi /proc (stav procesu serveru)', 17) unless (-r "/proc/$$/status");
    local $SIG{'PIPE'} = 'IGNORE';    # engine bez opravy spojeni zavre driv, nez test doposle telo

    # server stoji v blokujicim systemovem volani (stav S) a signal TERM uz prevzal (neni mezi cekajicimi)
    my $blocked = sub {
        my ($S) = @_;
        return wait_for(sub {
            return 1 unless (alive($S->{'pid'}));
            my ($state) = slurp("/proc/$S->{'pid'}/stat") =~ /\)\s+(\S)/;
            my $pending = 0;
            foreach my $mask (slurp("/proc/$S->{'pid'}/status") =~ /^(?:SigPnd|ShdPnd):\s*([0-9a-f]+)/mg) { $pending |= hex(substr($mask, -8)); }
            return (defined($state) and $state eq 'S' and !($pending & (1 << 14))) ? 1 : 0;
        }, 20);
    };

    # telo POST dorazi az po signalu: stranka ho musi dostat cele
    my $port = free_port();
    my $S    = launch(scenario(), hooks => 1, env => {'FCGI_SOCKET_PATH' => ":$port", 'PWE_TEST_BODY_MARK' => 1});
    ok(listening($S, $port), 'TERM pri cteni tela: server posloucha') or diag(srvlog($S));
    my $len = 150000;
    my ($c, $rest) = fcgi_send($port, '', body => 'page=tPage2&func=plen&data=' . ('a' x $len) . '&tail=END', hold => 20000);
    ok(wait_for(sub { -e "$S->{'dir'}/body.reading" }, 20), 'TERM pri cteni tela: engine cte telo requestu') or diag(srvlog($S));
    ok($blocked->($S), 'TERM pri cteni tela: engine ceka na zbytek tela');
    kill('TERM', $S->{'pid'}) if (alive($S->{'pid'}));
    ok($blocked->($S), 'TERM pri cteni tela: signal dorucen');
    print $c $rest;
    $c->flush;
    my ($done, $out) = fcgi_read($c);
    ok($done, 'TERM pri cteni tela: klient dostal celou odpoved');
    like($out, qr/^PLEN len=$len tail=END$/m, 'TERM pri cteni tela: stranka dostala cele telo (regrese: zkracene telo a 200)');
    is(stopped($S, 10), 'kod 0, signal 0', 'TERM pri cteni tela: po requestu konec s kodem 0');
    like(srvlog($S), qr/PWE server ukoncen signalem TERM/, 'TERM pri cteni tela: hlaska v logu');
    clean_log($S, 'TERM pri cteni tela: log bez chyb');

    # odpoved, kterou klient necte (engine stoji ve write), a dva TERM: klient ji presto dostane celou
    my $sock = "$SOCKDIR/write.sock";
    $S = scenario();
    touch("$S->{'dir'}/slow.release");    # stranka neceka a hned odesila
    launch($S, env => {'FCGI_SOCKET_PATH' => $sock});
    ok(listening($S, $sock), 'TERM pri odesilani: server posloucha') or diag(srvlog($S));
    my $kb = 4096;
    $c = fcgi_send($sock, "page=tPage2&func=slow&mark=$S->{'mark'}&size=$kb");
    ok(wait_for(sub { -e "$S->{'dir'}/slow.started" }, 20), 'TERM pri odesilani: request bezi') or diag(srvlog($S));
    ok($blocked->($S), 'TERM pri odesilani: engine ceka, az klient zacne cist');
    unlike(srvlog($S), qr/Page printed/, 'TERM pri odesilani: odpoved se do bufferu spojeni nevesla');
    foreach (1, 2) {
        kill('TERM', $S->{'pid'}) if (alive($S->{'pid'}));
        $blocked->($S);
    }
    ($done, $out) = fcgi_read($c, 60);
    ok($done, 'TERM pri odesilani: klient dostal celou odpoved (END_REQUEST)');
    my $lines = () = $out =~ /^x{1023}$/mg;
    is($lines, $kb, "TERM pri odesilani: telo ma vsech $kb kB (regrese: jen cast odpovedi)");
    ok(($out =~ /^SLOW-END\n\z/m) ? 1 : 0, 'TERM pri odesilani: odpoved konci, jak ma');    # ne like(): pri chybe by vypsal cele telo
    is(stopped($S, 10), 'kod 0, signal 0', 'TERM pri odesilani: po requestu konec s kodem 0');
}

# ---------------------------------------------------------------------------------------------
# 4) TERM tesne pred cekanim na dalsi request (signal cekani neprerusi - prisel pred nim)
# ---------------------------------------------------------------------------------------------
{
    my $port = free_port();
    my $S    = launch(scenario(), hooks => 1, env => {'FCGI_SOCKET_PATH' => ":$port", 'PWE_TEST_TERM_BEFORE_ACCEPT' => 1});
    ok(listening($S, $port), 'TERM pred cekanim: server posloucha') or diag(srvlog($S));
    request_ok($port, 'TERM pred cekanim: request obslouzen');
    is(stopped($S, 10), 'kod 0, signal 0', 'TERM pred cekanim: konec s kodem 0 (regrese: engine zustal viset)');
    ok(-e "$S->{'dir'}/term.sent", 'TERM pred cekanim: signal odesel pred vstupem do cekani');
    clean_log($S, 'TERM pred cekanim: log bez chyb');
}

# ---------------------------------------------------------------------------------------------
# 5) TERM behem startu
# ---------------------------------------------------------------------------------------------
{
    # start dobehne (neni kde ho prerusit) a engine skonci pred otevrenim socketu
    my $port = free_port();
    my $S    = launch(scenario(), hooks => 1, env => {'FCGI_SOCKET_PATH' => ":$port", 'PWE_TEST_STARTUP' => 'wait'});
    ok(wait_for(sub { -e "$S->{'dir'}/startup.waiting" or !alive($S->{'pid'}) }, 20), 'TERM pri startu: engine startuje') or diag(srvlog($S));
    kill('TERM', $S->{'pid'});
    kill('TERM', $S->{'pid'});
    touch("$S->{'dir'}/startup.release");
    is(stopped($S, 20), 'kod 0, signal 0', 'TERM pri startu: konec s kodem 0 (regrese: pad handleru)');
    my $log = srvlog($S);
    like($log, qr/Start PWE serveru prerusen signalem TERM \(start dobehl/, 'TERM pri startu: hlaska v logu');
    unlike($log, qr/FastCGI socket|Page printed/, 'TERM pri startu: socket se neotevrel, zadny request');
    ok(!port_open($port), 'TERM pri startu: port je zavreny');
    clean_log($S, 'TERM pri startu: log bez chyb (regrese: Can\'t call method "getDbidList")');

    # Libs::MyDBI start prerusi vyjimkou (ceka na databazi a dozvi se o zadosti pres requestStop)
    $port = free_port();
    $S    = launch(scenario(), hooks => 1, env => {'FCGI_SOCKET_PATH' => ":$port", 'PWE_TEST_STARTUP' => 'stop'});
    ok(wait_for(sub { -e "$S->{'dir'}/startup.waiting" or !alive($S->{'pid'}) }, 20), 'TERM pri cekani na databazi: engine startuje') or diag(srvlog($S));
    kill('TERM', $S->{'pid'});
    is(stopped($S, 20), 'kod 0, signal 0', 'TERM pri cekani na databazi: start prerusen, kod 0');
    $log = srvlog($S);
    like($log, qr/Start PWE serveru prerusen signalem TERM$/m, 'TERM pri cekani na databazi: hlaska v logu');
    unlike($log, qr/FastCGI socket|Startup interrupted/, 'TERM pri cekani na databazi: start nepokracoval a vyjimka neni na STDERR');
    clean_log($S, 'TERM pri cekani na databazi: log bez chyb');

  SKIP: {
        # totez se skutecnou Libs::MyDBI: web s databazi, ktera neodpovida (port 1) - engine opakuje pokusy
        # o pripojeni (trayconnect) a po TERM je ma prerusit
        skip('chybi DBD::mysql (image bez databazovych ovladacu)', 4) unless (eval { require DBD::mysql; 1 });
        $port = free_port();
        $S    = scenario();
        my $web = "$S->{'dir'}/web";
        make_path("$web/conf", "$web/log", "$web/ramdisk/templates");
        copy("$APP2/conf/web.conf", "$web/conf/web.conf") or die "web.conf: $!";
        open(my $fh, '>', "$web/conf/database.conf") or die "database.conf: $!";
        print $fh qq|{ 'db1' => { dbdriver => "mariadb", login => "pwe", password => "pwe", database => "pwe", host => "127.0.0.1", port => 1,\n|
          . qq|    logfile => "log/mysql", loglevel => 0, dao => 0, db_pool => 1, trayconnect => 600 } };\n|;
        close($fh);
        launch($S, env => {'FCGI_SOCKET_PATH' => ":$port", 'PWE_CONF_pwe_home' => "$web/"});
        ok(wait_for(sub { srvlog($S) =~ /connect_status:0/ or !alive($S->{'pid'}) }, 20), 'TERM pri pripojovani k databazi: engine opakuje pokusy') or diag(srvlog($S));
        kill('TERM', $S->{'pid'});
        is(stopped($S, 20), 'kod 0, signal 0', 'TERM pri pripojovani k databazi: Libs::MyDBI start prerusi, kod 0');
        $log = srvlog($S);
        like($log, qr/Start PWE serveru prerusen signalem TERM$/m, 'TERM pri pripojovani k databazi: hlaska v logu');
        unlike($log, qr/FastCGI socket|Startup interrupted|Can't call method|Unable connect/, 'TERM pri pripojovani k databazi: zadny socket ani chyba startu');
    }
}

# ---------------------------------------------------------------------------------------------
# 6) spojeni drzene webserverem, pomaly odesilatel, prazdna spojeni mezi requesty
# ---------------------------------------------------------------------------------------------
{
    my $port = free_port();
    my $S    = launch(scenario(), hooks => 1, env => {'FCGI_SOCKET_PATH' => ":$port", 'PWE_TEST_USR2' => 1});
    ok(listening($S, $port), 'provoz: server posloucha') or diag(srvlog($S));

    # request, ktery neprijde cely najednou (regrese neblokujiciho socketu: prijate spojeni musi blokovat)
    request_ok($port, 'pomaly odesilatel: request obslouzen', delay => 0.3);
    ok(port_open($port), 'prazdne spojeni 1');
    ok(port_open($port), 'prazdne spojeni 2');
    request_ok($port, 'request po prazdnych spojenich');

    # signal s vlastnim handlerem (ne TERM) cekani na request jen prerusi (regrese: engine skoncil)
    kill('USR2', $S->{'pid'});
    ok(wait_for(sub { -e "$S->{'dir'}/usr2.handled" }, 10), 'jiny signal: handler probehl');
    request_ok($port, 'jiny signal: engine bezi dal a obslouzi dalsi request');

    # keep_conn: dalsi request prijde po stejnem spojeni, ne pres naslouchajici socket
    my $c = fcgi_send($port, 'page=tPage2&func=default', keep_conn => 1);
    my ($done, $out) = fcgi_read($c, 20, 1);
    ok(($done and $out =~ /Ahoj z app2/), 'keep_conn: prvni request');
    fcgi_send(undef, 'page=tPage2&func=roots', keep_conn => 1, sock => $c);
    ($done, $out) = fcgi_read($c, 20, 1);
    ok(($done and $out =~ /^HOME=/m), 'keep_conn: druhy request po temze spojeni');

    # engine ted ceka na dalsi request na drzenem spojeni; TERM ho ukonci
    kill('TERM', $S->{'pid'});
    is(stopped($S, 10), 'kod 0, signal 0', 'keep_conn: TERM v necinnosti ukonci engine s kodem 0');
    close($c) if ($c);
    is(scalar(() = srvlog($S) =~ /Page printed/g), 5, 'provoz: obslouzeno prave 5 requestu');
    clean_log($S, 'provoz: log bez chyb');
}

# ---------------------------------------------------------------------------------------------
# 7) FCGI_SOCKET_PATH=127.0.0.1:<port> - jen loopback
# ---------------------------------------------------------------------------------------------
{
    my $port = free_port();
    # FCGI_SOCKET_PERM se u adresy TCP nepouzije (regrese: chmod adresy host:port ukoncil start)
    my $S = launch(scenario(), env => {'FCGI_SOCKET_PATH' => "127.0.0.1:$port", 'FCGI_SOCKET_PERM' => '0660'});
    ok(listening($S, $port), 'host:port: server posloucha na 127.0.0.1 (regrese: Couldn\'t chmod)') or diag(srvlog($S));
    request_ok($port, 'host:port: request na loopbacku obslouzen');
    like(srvlog($S), qr/FastCGI socket 127\.0\.0\.1:$port: adresa TCP/, 'host:port: log');
  SKIP: {
        skip('kontejner nema jine rozhrani nez loopback', 1) unless ($OTHER);
        skip("na adresu $OTHER se neda pripojit ani k enginu na vsech rozhranich", 1) unless ($REACHABLE);
        ok(!port_open("$OTHER:$port"), "host:port: na adrese jineho rozhrani ($OTHER) engine neposloucha");
    }
    kill('TERM', $S->{'pid'});
    is(stopped($S, 10), 'kod 0, signal 0', 'host:port: TERM, konec s kodem 0');
    clean_log($S, 'host:port: log bez chyb');
}

# ---------------------------------------------------------------------------------------------
# 8) unix socket a jeho prava
# ---------------------------------------------------------------------------------------------
{
    my $perm = sub { return sprintf('%04o', (stat($_[0]))[2] & 07777); };

    # vychozi prava presne 0770, i kdyz maska procesu nic neubira (regrese: 1402)
    my $sock = "$SOCKDIR/pwe.sock";
    my $mask = umask(0);
    my $S    = launch(scenario(), env => {'FCGI_SOCKET_PATH' => $sock});
    umask($mask);
    ok(listening($S, $sock), 'unix socket: server posloucha') or diag(srvlog($S));
    is($perm->($sock), '0770', 'unix socket: vychozi prava 0770 (regrese: 1402)');
    request_ok($sock, 'unix socket: request obslouzen');
    like(srvlog($S), qr/FastCGI socket \Q$sock\E: unix socket s pravy 0770/, 'unix socket: log');
    kill('TERM', $S->{'pid'});
    is(stopped($S, 10), 'kod 0, signal 0', 'unix socket: TERM, konec s kodem 0');
    clean_log($S, 'unix socket: log bez chyb');

    # FCGI_SOCKET_PERM osmickove; cesta s dvojteckou, za kterou neni cislo portu, je porad unix socket;
    # prisna maska procesu prava nezmensi
    $sock = "$SOCKDIR/p:we.sock";
    $mask = umask(077);
    $S    = launch(scenario(), env => {'FCGI_SOCKET_PATH' => $sock, 'FCGI_SOCKET_PERM' => '0660'});
    umask($mask);
    ok(listening($S, $sock), 'FCGI_SOCKET_PERM=0660: server posloucha') or diag(srvlog($S));
    is($perm->($sock), '0660', 'FCGI_SOCKET_PERM=0660: prava 0660 (hodnota se cte osmickove)');
    request_ok($sock, 'FCGI_SOCKET_PERM=0660: request obslouzen');
    kill('TERM', $S->{'pid'});
    is(stopped($S, 10), 'kod 0, signal 0', 'FCGI_SOCKET_PERM=0660: TERM, konec s kodem 0');

    $sock = "$SOCKDIR/bad.sock";
    $S    = launch(scenario(), env => {'FCGI_SOCKET_PATH' => $sock, 'FCGI_SOCKET_PERM' => '0798'});
    isnt(stopped($S, 20), 'kod 0, signal 0', 'FCGI_SOCKET_PERM=0798: start skonci chybou');
    like(srvlog($S), qr/FCGI_SOCKET_PERM='0798' neni osmickovy zapis prav/, 'FCGI_SOCKET_PERM=0798: duvod na STDERR');
    ok(!-e $sock, 'FCGI_SOCKET_PERM=0798: socket nevznikl');
}

done_testing();
