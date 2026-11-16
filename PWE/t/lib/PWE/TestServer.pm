package PWE::TestServer;

=head1 NAME

PWE::TestServer - pomocny modul testu: skutecny FastCGI server enginu a vestaveny klient FastCGI

=head1 POPIS

    Spusti vstupni skript enginu (pwe.fcgi, debug.cgi) jako samostatny proces se socketem
    z FCGI_SOCKET_PATH a posila mu requesty protokolem FastCGI stejne jako nginx (role RESPONDER).
    Pouzivaji ho testy, ktere potrebuji bezici server: t/20-debug-entry.t (signal INT pod
    debuggerem) a t/24-shutdown.t (ukoncovani signalem TERM, prava a adresa socketu).

    use lib "$FindBin::Bin/lib";
    use PWE::TestServer qw(free_port port_open wait_for start_server alive exit_status fcgi_get);
    my $port = free_port();
    my $pid  = start_server(script => "$ROOT/pwe.fcgi", cwd => $APP2, err => "$TMP/server.err",
        env => { %ENV_BASE, 'FCGI_SOCKET_PATH' => ":$port" });
    wait_for(sub { port_open($port) }, 20) or die "server nenastartoval";
    my ($done, $out) = fcgi_get($port, 'page=tPage2&func=default');
    kill('TERM', $pid);
    wait_for(sub { !alive($pid) }, 10);
    my $st = exit_status($pid);                   # { code => 0, signal => 0 }

    Cil requestu ($target) je cislo portu (127.0.0.1), "host:port", nebo cesta k unix socketu.
    Testy nesmi cekat pevnou dobu: na udalost (port posloucha, proces skoncil, soubor vznikl) se
    ceka pres wait_for.

=cut

use strict;
use warnings;
use Exporter qw(import);
use IO::Socket::INET;
use IO::Socket::UNIX;
use IO::Select;
use POSIX qw(:sys_wait_h);

our @EXPORT_OK = qw(free_port port_open wait_for start_server alive exit_status fcgi_send fcgi_read fcgi_get);

# navratove stavy ($?) uz ukoncenych serveru podle PID (alive() proces sklidi, stav by se jinak ztratil)
my %STATUS;

=head2 B<[Public] free_port()>

    Vraci cislo volneho TCP portu na 127.0.0.1 (system ho prideli a funkce ho hned uvolni),
    nebo undef, kdyz lokalni port otevrit nejde.

=cut

sub free_port {
    my $s = IO::Socket::INET->new(Listen => 1, LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp') or return undef;
    my $p = $s->sockport;
    close($s);
    return $p;
}

=head2 B<[Private] connect_target($target,$timeout)>

    Otevre spojeni na cil: cislo portu (127.0.0.1), "host:port", nebo cesta k unix socketu
    (cokoli s lomitkem). Vraci socket, nebo undef (chyba je v $!).

=cut

sub connect_target {
    my ($target, $timeout) = @_;
    return undef unless (defined($target));
    $timeout = 5 unless (defined($timeout));
    return IO::Socket::UNIX->new(Peer => $target, Timeout => $timeout) if ($target =~ m{/});
    my ($host, $port) = ($target =~ /^(.*):(\d+)$/) ? ($1, $2) : ('127.0.0.1', $target);
    return IO::Socket::INET->new(PeerAddr => $host, PeerPort => $port, Proto => 'tcp', Timeout => $timeout);
}

=head2 B<[Public] port_open($target)>

    Vraci 1, kdyz se na cil (viz connect_target) da pripojit, jinak 0. Spojeni hned zavre -
    server ho vidi jako prazdne spojeni bez requestu.

=cut

sub port_open {
    my ($target) = @_;
    my $s = connect_target($target, 1) or return 0;
    close($s);
    return 1;
}

=head2 B<[Public] wait_for($podminka,$sekundy)>

    Ceka, az funkce $podminka vrati pravdu (zkousi ji po 50 ms), nejdele $sekundy.
    Vraci 1 = podminka splnena, 0 = cas vyprsel.

=cut

sub wait_for {
    my ($cond, $sec) = @_;
    my $end = time + $sec;
    while (1) {
        return 1 if ($cond->());
        return 0 if (time > $end);
        select(undef, undef, undef, 0.05);
    }
}

=head2 B<[Public] start_server(script => $cesta, cwd => $adresar, env => {...}, perl => [...], out => $soubor, err => $soubor)>

    Spusti skript enginu jako samostatny proces a vrati jeho PID. Proces dostane PRESNE prostredi
    env (nic se nededi), pracovni adresar cwd, STDIN z /dev/null a STDOUT/STDERR pripojene na konec
    souboru out/err (vychozi /dev/null). perl = volby interpretu pred skriptem (napr. ['-d'] nebo
    ['-MPWE::ShutdownHooks']).

=cut

sub start_server {
    my (%o) = @_;
    my $pid = fork();
    die "fork: $!" unless (defined($pid));
    if (!$pid) {
        chdir($o{'cwd'}) or POSIX::_exit(126);
        %ENV = %{$o{'env'} || {}};
        open(STDIN,  '<',  '/dev/null');
        open(STDOUT, '>>', ($o{'out'} || '/dev/null'));
        open(STDERR, '>>', ($o{'err'} || '/dev/null'));
        exec($^X, @{$o{'perl'} || []}, $o{'script'}) or POSIX::_exit(127);
    }
    return $pid;
}

=head2 B<[Public] alive($pid)>

    Vraci 1, kdyz proces spusteny pres start_server jeste bezi, jinak 0. Ukonceny proces
    sklidi (waitpid) a jeho navratovy stav si zapamatuje pro exit_status.

=cut

sub alive {
    my ($pid) = @_;
    return 0 if (exists($STATUS{$pid}));
    my $r = waitpid($pid, WNOHANG);
    return 1 if ($r == 0);
    $STATUS{$pid} = ($r == $pid) ? $? : -1;
    return 0;
}

=head2 B<[Public] exit_status($pid)>

    Vraci { code => navratovy kod, signal => cislo signalu, ktery proces ukoncil (0 = zadny) }
    serveru, ktery uz skoncil; undef, kdyz jeste bezi nebo jeho stav neni znam.

=cut

sub exit_status {
    my ($pid) = @_;
    return undef if (alive($pid) or $STATUS{$pid} < 0);
    return {'code' => ($STATUS{$pid} >> 8), 'signal' => ($STATUS{$pid} & 127)};
}

=head2 B<[Public] fcgi_send($target,$query,%volby)>

    Otevre spojeni na cil (viz connect_target) a posle jeden request (GET, s volbou body POST)
    v roli RESPONDER jako nginx. Na odpoved neceka - vraci socket pro fcgi_read (test mezitim
    muze serveru poslat signal), nebo undef, kdyz se pripojit nepodarilo. Volby:
      script    - SCRIPT_FILENAME (vychozi /pwe.fcgi)
      keep_conn - 1 = priznak FCGI_KEEP_CONN: server po odpovedi spojeni nezavre
      sock      - socket drive otevreneho spojeni (dalsi request po keep_conn); $target se nepouzije
      delay     - pauza v sekundach mezi zaznamem BEGIN_REQUEST a parametry (pomaly odesilatel:
                  server musi na zbytek requestu pockat)
      timeout   - sekundy na pripojeni
      body      - telo requestu: request je pak POST (application/x-www-form-urlencoded,
                  CONTENT_LENGTH podle tela)
      hold      - s body: kolik bajtu tela poslat hned. Zbytek requestu (ostatni zaznamy STDIN)
                  funkce neposle a v seznamovem kontextu ho vrati jako druhou hodnotu - test ho
                  posle pozdeji sam (print $socket $zbytek), napr. az po signalu

=cut

sub fcgi_send {
    my ($target, $query, %o) = @_;
    my $s = $o{'sock'} || connect_target($target, $o{'timeout'}) or return undef;
    my $rec = sub { my ($type, $body) = @_; return pack('CCnnCx', 1, $type, 1, length($body), 0) . $body; };
    my $nv  = sub { my ($n, $v) = @_; return join('', map { length($_) < 128 ? pack('C', length($_)) : pack('N', length($_) | 0x80000000) } ($n, $v)) . $n . $v; };
    my %p = ('SCRIPT_FILENAME' => ($o{'script'} || '/pwe.fcgi'), 'QUERY_STRING' => $query, 'REQUEST_METHOD' => 'GET', 'REMOTE_ADDR' => '127.0.0.1',
        'HTTP_HOST' => 'localhost', 'SERVER_NAME' => 'localhost', 'GATEWAY_INTERFACE' => 'CGI/1.1', 'CONTENT_LENGTH' => '', 'CONTENT_TYPE' => '');
    my $body = $o{'body'};
    @p{'REQUEST_METHOD', 'CONTENT_LENGTH', 'CONTENT_TYPE'} = ('POST', length($body), 'application/x-www-form-urlencoded') if (defined($body));
    print $s $rec->(1, pack('nCx5', 1, ($o{'keep_conn'} ? 1 : 0)));
    if ($o{'delay'}) {
        $s->flush;
        select(undef, undef, undef, $o{'delay'});
    }
    # Parametry a telo po zaznamech STDIN (nejvyse 32 kB): prvnich $now bajtu tela hned, zbytek podle
    # volby hold. Vse, co se posila hned, jde jednim zapisem (jako z nginx) - koncovy prazdny zaznam STDIN
    # poslany zvlast by server s keep_conn nemusel stihnout precist pred koncem requestu.
    my $held = defined($o{'hold'}) ? 1 : 0;
    my $head = $rec->(4, join('', map { $nv->($_, $p{$_}) } sort keys %p)) . $rec->(4, '');
    my $rest = '';
    if (defined($body)) {
        my $now = ($held and $o{'hold'} < length($body)) ? $o{'hold'} : length($body);
        for (my $i = 0; $i < $now; $i += 32768) { $head .= $rec->(5, substr($body, $i, ($now - $i < 32768) ? $now - $i : 32768)); }
        for (my $i = $now; $i < length($body); $i += 32768) { $rest .= $rec->(5, substr($body, $i, 32768)); }
    }
    $rest .= $rec->(5, '');
    print $s ($held ? $head : $head . $rest);
    $s->flush;
    return ($held and wantarray) ? ($s, $rest) : $s;
}

=head2 B<[Public] fcgi_read($socket,$sekundy,$nezavirat)>

    Docte odpoved na request poslany pres fcgi_send (ceka nejdele $sekundy, vychozi 20) a spojeni
    zavre (s $nezavirat ho necha otevrene - pro spojeni s priznakem keep_conn). Vraci
    (1|0 = prisel zaznam END_REQUEST, tedy cela odpoved; CGI vystup = hlavicky a telo).

=cut

sub fcgi_read {
    my ($s, $sec, $keep) = @_;
    return (0, "connect: $!") unless ($s);
    $sec = 20 unless (defined($sec));
    my ($outb, $buf, $done, $end) = ('', '', 0, time + $sec);
    my $sel = IO::Select->new($s);
    while (!$done and time <= $end) {
        next unless ($sel->can_read(0.5));
        my $n = sysread($s, $buf, 65536, length($buf));
        last unless ($n);
        while (length($buf) >= 8) {
            my ($v, $type, $id, $len, $pad) = unpack('CCnnC', $buf);
            last if (length($buf) < 8 + $len + $pad);
            my $body = substr($buf, 8, $len);
            substr($buf, 0, 8 + $len + $pad) = '';
            if    ($type == 6) { $outb .= $body; }
            elsif ($type == 3) { $done = 1; }
        }
    }
    close($s) unless ($keep);
    return ($done, $outb);
}

=head2 B<[Public] fcgi_get($target,$query,%volby)>

    Jeden cely request: fcgi_send + fcgi_read. Vraci (1|0 = cela odpoved, CGI vystup).

=cut

sub fcgi_get {
    my ($target, $query, %o) = @_;
    return fcgi_read(fcgi_send($target, $query, %o));
}

1;
