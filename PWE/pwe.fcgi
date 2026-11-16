#!/usr/bin/env perl

use strict;
use warnings;

=head1 NAME

pwe.fcgi - vstupni bod enginu PWE (FastCGI server)

=head1 POPIS

    Engine ma dva koreny: pwe.home (web, adresar s conf/web.conf; z PWE_CONF_pwe_home) a pwe.core
    (engine, adresar tohoto skriptu; PWE_CONF_pwe_core). Moduly, sablony, resource bundly i statika
    se hledaji nejdrive ve webu, pak v enginu; bez PWE_CONF_pwe_home jsou oba koreny stejne
    (puvodni rezim webu slozeneho symlinky).

    Adresar enginu se v repozitari jmenuje PWE/ (v kontejnerech kukam/pwe-* je to /PWE/PWE, skript
    tedy /PWE/PWE/pwe.fcgi); "core" v nazvu klice pwe.core znamena koren enginu, ne nazev adresare.

    Postavi singletony enginu v poradi Config -> Log -> Validate -> MyDBI -> User -> Web
    -> Entities -> Services -> Sites -> Pages a pak v nekonecne smycce CGI::Fast obsluhuje
    requesty: precte page/func/opt a session cookie, zavola $USER->newRequest, $SITES/$SERVICES
    ->newRequest, zkopiruje CGI parametry do $USER a zavola $PAGES->callPageFunc. Ciselny
    vysledek (404/401/500/400) presmeruje na errorPage. Na konci flush vsech vrstev.

    Spusteni z prikazove radky (bez FastCGI socketu) funguje jako jednorazove CGI:
      SCRIPT_FILENAME=/pwe.fcgi REQUEST_METHOD=GET QUERY_STRING='page=default&func=default' perl pwe.fcgi

=head1 SOCKET

    FCGI_SOCKET_PATH urcuje, kde engine posloucha (socket otevira az po startu vsech singletonu,
    tedy az po pripojeni k databazi a migracich). Tvar hodnoty rozlisuje knihovna FastCGI:
    kdyz za PRVNI dvojteckou nasleduje nenulove cislo portu, jde o adresu TCP, jinak o cestu
    k unix socketu.

      :7779                 TCP port 7779 na vsech rozhranich
      127.0.0.1:7779        TCP port 7779 jen na danem rozhrani (cislo IPv4 nebo jmeno s jedinou
                            adresou); "*:7779" je totez co ":7779"
      /run/pwe/web.sock     unix socket (stary soubor na teze ceste se pred otevrenim smaze)

    Bez FCGI_SOCKET_PATH engine obslouzi jeden request z prostredi (CGI) a skonci; spusti-li ho
    webserver nebo spravce procesu FastCGI s naslouchajicim socketem na deskriptoru 0, obsluhuje
    requesty z nej.

    FCGI_SOCKET_PERM: prava unix socketu zapsana OSMICKOVE (0660, 660, 0777), vychozi 0770.
    Pripojit se k socketu smi ten, kdo do nej smi zapisovat - s 0770 tedy vlastnik a skupina
    procesu enginu. U adresy TCP se promenna nepouziva. Jina hodnota nez 3-4 osmickove cislice
    ukonci start chybou.

    FCGI_LISTEN_QUEUE: delka fronty cekajicich spojeni (vychozi 100).

=head1 UKONCENI

    Signal TERM ukonci engine poradane a s navratovym kodem 0:

      - necinny proces (ceka na request) skonci hned: odpoji databaze a skonci;
      - behem requestu: request dobehne s funkcni databazi a klient dostane celou odpoved, teprve
        pak se odpoji databaze a proces skonci. Plati to i pro signal, ktery prijde ve chvili,
        kdy engine cte telo requestu (POST) nebo odesila odpoved: po dobu requestu maji handlery
        TERM a USR1 priznak SA_RESTART (signal_restart), prerusene cteni a zapis se zopakuji.
        Naslouchajici socket se zavre hned po signalu (jakmile dobehne prave provadena operace
        perlu), takze dalsi spojeni uz engine neprijme (webserver dostane "connection refused"
        a muze request poslat jinemu procesu);
      - behem startu: handler nastavi priznak a zavola Libs::MyDBI::requestStop(). Start se bud
        prerusi na bezpecnem miste (mezi pokusy o pripojeni k databazi, mezi kroky migrace -
        Libs::MyDBI pak skonci vyjimkou "Startup interrupted by termination request"), nebo
        dobehne; v obou pripadech proces skonci, aniz otevre socket a prijme request;
      - dalsi TERM behem dobihani requestu nic nemeni.

    Do logu (uroven info) se pri tom zapise "PWE server ukoncen signalem TERM", pri ukonceni
    behem startu "Start PWE serveru prerusen signalem TERM".

    Signal USR1 ma stejny ucinek jako TERM (je to ukoncovaci signal knihovny FastCGI, posila ho
    mod_fastcgi); v hlaskach je pak USR1. Signal INT handler nema (Ctrl-C proces ukonci hned;
    pod debuggerem ho pouziva debug.cgi).

    Jak engine ceka na request (se socketem z FCGI_SOCKET_PATH, na Linuxu): naslouchajici socket
    je neblokujici, takze knihovna FastCGI v accept() nikdy nezustane viset - kdyz zadne spojeni
    neceka, vrati se a engine ceka sam (select, nejdele 1 s, pak znovu zkontroluje priznak
    ukonceni). Samotne preruseni accept() signalem nestaci: signal, ktery prijde tesne pred
    vstupem do accept() (typicky hned po odeslani odpovedi), cekani neprerusi, a knihovna se
    po prazdnem spojeni (TCP sonda) nebo po preruseni cteni vraci do accept() sama, aniz by
    handler dostal slovo. Na jinych systemech (prijate spojeni tam neblokujici rezim dedi)
    zustava socket blokujici a cekani ukoncuje jen preruseni accept() signalem. Socket zdedeny
    po webserveru (bez FCGI_SOCKET_PATH, deskriptor 0 pod spravcem procesu FastCGI) engine
    prebira stejnou cestou jako vlastni (use_socket), plati pro nej tedy totez.

    Omezeni dana knihovnou FastCGI: signal, ktery prijde ve chvili, kdy knihovna cte hlavicku
    prave prijateho requestu nebo ceka na dalsi request na spojeni drzenem webserverem
    (fastcgi_keep_conn on), cteni prerusi a spojeni zavre - engine skonci, tento request ale
    neobslouzi. Systemova volani, ktera signal prerusi vzdy (sleep, select), se v rozpracovanem
    requestu vrati driv.

    Knihovna FastCGI cteni a zapis prerusene signalem neopakuje - proud requestu zavre (stranka
    by dostala zkracene telo POST, klient jen cast odpovedi). Pred signaly TERM a USR1 request
    chrani priznak SA_RESTART jejich handleru; jiny signal s handlerem (handler webu, INT pod
    debuggerem) takovy request dal poskodi.

    Chyba cekani na request (jina nez "zadne spojeni neceka") ukonci engine s navratovym kodem
    1 a hlaskou "PWE server konci: cekani na request FastCGI selhalo (...)" v logu.

=cut

# use Cwd qw( abs_path realpath cwd );
use File::Basename qw( dirname basename );

my $dirname = ((dirname($0) =~ /^\//) ? dirname($0)."/" : ((dirname($0) =~ /^\./) ? dirname($0)."/" : "./".dirname($0)."./" ));
my $basename = basename($0); 

use lib dirname($0);

# Signal TERM/USR1, ktery prijde jeste pri kompilaci (nez se nize nastavi handler terminate). Handler se
# musi nastavit PRED nactenim FCGI: knihovna FastCGI si pri nacteni na SIGTERM a SIGUSR1 s vychozi akci
# povesi vlastni handler, ktery signal jen tise zapamatuje (engine by dostartoval a pak skoncil chybou).
my $EARLY_STOP;
BEGIN { $SIG{TERM} = sub { $EARLY_STOP ||= 'TERM' }; $SIG{USR1} = sub { $EARLY_STOP ||= 'USR1' }; }
use CGI::Fast;
use CGI qw/ :standard /;
use FCGI;
use Libs::Config;
use Libs::MyDBI;
use Libs::Log;
use Libs::Validate;
use Libs::Entities;
use Libs::Web;
use Libs::User;
use Libs::Services;
use Libs::Sites;
use Libs::Pages;
use IO::Handle;
use Errno qw(EAGAIN EWOULDBLOCK EINTR);

use POSIX qw(setsid);

# require 'syscall.ph';

# Stav ukoncovani (viz POD, oddil UKONCENI). Handler signalu TERM jen nastavuje priznaky - request,
# ktery prave bezi, se nesmi prerusit ani prijit o databazi.
my $STOP     = 0;        # jmeno signalu (TERM, USR1), ktery prisel: engine skonci, jakmile dobehne rozpracovany request
my $STARTING = 1;        # 1 = engine jeste startuje (zadost o ukonceni se predava i Libs::MyDBI)
my $DBI;                 # databazova vrstva; pred jejim vznikem a po odpojeni nema end() co delat

# Naslouchajici socket z FCGI_SOCKET_PATH (viz POD, oddil SOCKET, a listen_socket).
my $LISTEN;              # cislo deskriptoru (undef = socket neni otevreny nebo uz je zavreny)
my $LISTEN_FH;           # tentyz deskriptor jako filehandle (jen v neblokujicim rezimu)
my $NONBLOCK = 0;        # 1 = socket je neblokujici a na spojeni ceka engine sam (wait_connection)
my $ACCEPT   = 0;        # vysledek posledniho Accept knihovny FastCGI: 0 = request, zaporny = -errno
my $IN_REQUEST = 0;      # 1 = request je prijaty a jeste nedokonceny: handlery TERM/USR1 maji SA_RESTART (signal_restart)

# USR1 je ukoncovaci signal knihovny FastCGI (posila ho mod_fastcgi): jeji vlastni handler by jen
# trvale zakazal accept, coz smycka next_request nepozna - proto ma stejny handler jako TERM.
local $SIG{TERM} = \&terminate;
local $SIG{USR1} = \&terminate;
terminate($EARLY_STOP) if ($EARLY_STOP);

# Chybovy proud FastCGI se nepouziva (log enginu jde na STDERR procesu nebo do souboru), proto dostava
# vlastni handle misto STDERR.
my $FCGI_ERR = IO::Handle->new;
CGI::Fast->file_handles( { fcgi_error_file_handle => $FCGI_ERR } );

my $CONF = Libs::Config->new($dirname,$basename,'conf/web.conf','conf/database.conf');

# Web muze lezet mimo adresar enginu (pwe.home != pwe.core): jeho moduly musi byt v @INC pred enginem
# (i kdyz uz tam oba koreny jsou, napr. z PERL5LIB - zalezi na poradi).
foreach my $root ( reverse $CONF->getRoots() ) {
    ( my $inc = $root ) =~ s{/$}{};
    @INC = grep { $_ ne $inc } @INC;
    unshift( @INC, $inc );
}
my $LOG  = Libs::Log->new($CONF);
$LOG->info("Starting PWE server...");

if ( my $core_error = $CONF->checkCoreVersion() ) {
    $LOG->error($core_error);
    die "$core_error\n";
}

$LOG->delay("create_object_validate");
my $VALIDATE = Libs::Validate->new( $CONF, $LOG );
$LOG->delay( "create_object_validate", "Created object VALIDATE" );

$LOG->delay("create_object_dbi");
# Pripojeni k databazi a migrace: po signalu TERM je Libs::MyDBI na bezpecnem miste prerusi vyjimkou.
$DBI = eval { Libs::MyDBI->new( $CONF, $LOG, $VALIDATE ) } or startup_failed( $@, $! + 0 );
$LOG->delay( "create_object_dbi", "Created object DBI" );

$LOG->delay("create_object_user");
my $USER = Libs::User->new( $CONF, $LOG, $VALIDATE, $DBI );
$LOG->delay( "create_object_user", "Created object USER" );

$LOG->delay("create_object_web");
my $WEB = Libs::Web->new( $CONF, $LOG, $VALIDATE, $DBI, $USER );
$LOG->delay( "create_object_web", "Created object WEB" );

$LOG->delay("create_object_entities");
my $ENTITIES = Libs::Entities->new( $CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB );
$LOG->delay( "create_object_entities", "Created object ENTITIES" );

$LOG->delay("create_object_services");
my $SERVICES = Libs::Services->new( $CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB, $ENTITIES );
$LOG->delay( "create_object_services", "Created object SERVICES" );

$LOG->delay("create_object_sites");
my $SITES = Libs::Sites->new( $CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB, $ENTITIES, $SERVICES );
$LOG->delay( "create_object_sites", "Created object SITES" );

$LOG->delay("create_object_pages");
my $PAGES = Libs::Pages->new( $CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB, $ENTITIES, $SERVICES, $SITES );
$LOG->delay( "create_object_pages", "Created object PAGES" );

# UPLOUD LIMIT : http://stackoverflow.com/questions/23288560/how-to-set-in-perl-and-fcgi-the-post-max-limit
# Pri prekoreceni limitu, dojde v apachi k "Broken pipe: AH02651"
no warnings 'once';
$CGI::DISABLE_UPLOADS = $CONF->getValue( "pwe", "cgi_disableupload", 0 );
$CGI::POST_MAX = $CONF->getValue( "pwe", "cgi_maxfilesize", ( 5 * 1_048_576 ) );
$CGITempFile::MAXTRIES     = $CONF->getValue( "pwe", "cgi_maxopentries", 50 );
$CGITempFile::TMPDIRECTORY = $CONF->getValue( "pwe", "home", "/tmp/" )
  . $CONF->getValue( "pwe", "cgi_tmpdirectory", "cgitemp/" );
$CGI::LIST_CONTEXT_WARN = 0;
use warnings 'once';

# UNCOMENT FOR : stderr: CGI::param called in list context from package main line 89,
# this can lead to vulnerabilities. See the warning in "Fetching the value or values of a single named parameter"

#local $ENV{FCGI_SOCKET_PATH} = ":9999";
#local $ENV{FCGI_LISTEN_QUEUE} = 100;
#local $ENV{FCGI_DAEMONIZE} = 0;

# Konec startu. Signal TERM, ktery prisel behem nej a start neprerusil, ukonci engine jeste pred
# otevrenim socketu - zadny request se neprijme.
$STARTING = 0;
if ($STOP) {
    $LOG->info("Start PWE serveru prerusen signalem $STOP (start dobehl, socket se neotevira)");
    &end();
    exit(0);
}

if ( $ENV{FCGI_DAEMONIZE} ) { &daemonize; }

# Socket se otevira az tady (po startu a po odpojeni od terminalu). Bez FCGI_SOCKET_PATH engine prevezme
# socket zdedeny po webserveru (deskriptor 0 je naslouchajici socket = spravce procesu FastCGI), jinak si
# request zalozi CGI::Fast sam (jednorazove CGI).
if ( $ENV{FCGI_SOCKET_PATH} and !$STOP ) { listen_socket( $ENV{FCGI_SOCKET_PATH} ); }
elsif ( !$ENV{FCGI_SOCKET_PATH} and !$STOP and FCGI::Request()->IsFastCGI() ) { use_socket( 0, 'zdedeny socket (deskriptor 0)' ); }

=head2 B<[Private] daemonize()>

    Odpoji proces od terminalu (chdir /, fork, setsid, umask 0). Vola se jen kdyz je
    nastavena promenna prostredi FCGI_DAEMONIZE. V Dockeru/Kubernetes se nepouziva.

=cut

sub daemonize() {
    chdir '/'                 or die "Can't chdir to /: $!";
    defined( my $pid = fork ) or die "Can't fork: $!";
    exit if $pid;
    setsid or die "Can't start a new session: $!";
    umask 0;
}

while ( my $CGI = next_request() ) {

    $DBI->testConnection();

    $LOG->delay("generate_page");

    # SET CHARSET
    $CGI->charset('UTF8');

    # SET ENVS
    my $env = \%ENV;

    my $sid = $CGI->cookie(
        $CONF->getValue( "http", "cookie_name", "UNKNOWN_SESSION_NAME" ) );
    # page a func: z parametru requestu; pri POST bez nich v tele jeste z query stringu (CGI.pm ho pri POST
    # v param() nema) - callbacky platebnich bran a webhooky tak mohou mit cil v URL a data v tele.
    my $page = $CGI->param('page');
    $page = $CGI->url_param('page') unless ( defined($page) and length($page) );
    $page = $CONF->getValue( "pwe", "default_page", 'default' ) unless ( defined($page) and length($page) );
    my $func = $CGI->param('func');
    $func = $CGI->url_param('func') unless ( defined($func) and length($func) );
    $func = $CONF->getValue( "pwe", "default_func", 'default' ) unless ( defined($func) and length($func) );
    my $opt = (
        defined( $CGI->param('opt') )
        ? $CGI->param('opt')
        : $CONF->getValue( "pwe", "enable_opt", 0 )
    );

    $USER->newRequest( $page, $func, $sid, $opt, $env, $CGI );
    $SITES->newRequest();
    $SERVICES->newRequest();

    foreach my $p ( $CGI->param() ) {
        my @params;
        if ( exists(&CGI::multi_param) ) {
            @params = $CGI->multi_param($p);
        }
        else {
            @params = $CGI->param($p);
        }
        $USER->setParameter( $p, \@params );
    }

    my ( $result, $result_info );

    if ( $CGI->cgi_error() ) {
        my $error = $CGI->cgi_error();
        $result_info = $error;
        $USER->setPage('errorPage');
        $USER->setFunc('cgi_error');
        $USER->setParameter( 'cgi_error', [$error] );
        $result = $PAGES->callPageFunc( 'errorPage', 'cgi_error' );
    }
    elsif ( not defined( $env->{'SCRIPT_FILENAME'} ) ) {
        $result = $PAGES->callPageFunc( 'default', 'default' );
    }
    elsif ( $env->{'SCRIPT_FILENAME'} =~ /\.\./ ) {
        $result = 401;
    }
    elsif (( $basename eq $env->{'SCRIPT_FILENAME'} )
        or ( "/" . $basename eq $env->{'SCRIPT_FILENAME'} )
        or ( $basename eq "." . $env->{'SCRIPT_FILENAME'} )
        or ( $env->{'SCRIPT_FILENAME'} eq "/" )
        or ( !$env->{'SCRIPT_FILENAME'} ) )
    {
        $result = $PAGES->callPageFunc( $page, $func );
    }
    elsif ( defined( $CONF->resolveFile( $env->{'SCRIPT_FILENAME'} ) ) ) {
        $USER->setPage('systemPage');
        $USER->setFunc('file');
        $result = $PAGES->callPageFunc( 'systemPage', 'file' );
    }
    elsif ( defined( $CONF->resolveDir( $env->{'SCRIPT_FILENAME'} ) ) ) {
        $USER->setPage('systemPage');
        $USER->setFunc('folder');
        $result = $PAGES->callPageFunc( 'systemPage', 'folder' );
    }
    else {
        $result = 404;
    }

    if ( !$result ) {
        $result_info = "200, OK";
    }
    elsif ( $result eq 404 ) {
        $USER->setPage('errorPage');
        $USER->setFunc('e404');
        $PAGES->callPageFunc( 'errorPage', 'e404' );
        $result_info = "404, Page not found";
    }
    elsif ( $result eq 500 ) {
        $USER->setPage('errorPage');
        $USER->setFunc('e500');
        $PAGES->callPageFunc( 'errorPage', 'e500' );
        $result_info = "500, Error page";
    }
    elsif ( $result eq 401 ) {
        $USER->setPage('errorPage');
        $USER->setFunc('e401');
        $PAGES->callPageFunc( 'errorPage', 'e401' );
        $result_info = "401, No access";
    }
    elsif ( $result eq 400 ) {
        $USER->setPage('errorPage');
        $USER->setFunc('e400');
        $PAGES->callPageFunc( 'errorPage', 'e400' );
        $result_info = "400, Bad parameter";
    }
    else {
        $result_info = "200, OK";
    }

    $page = $USER->getPage();
    $func = $USER->getFunc();

    $SITES->flush();
    $SERVICES->flush();
    $WEB->flush();
    $USER->flush();

    my $script = $USER->getEnv('SCRIPT_FILENAME',$basename);
    $LOG->info("Page printed : PID:$$ page:$page func:$func result:'$result_info' script:'$script'");
    $LOG->debug("Fastcgi cycle ended");

    # CLEAR
    undef @CGI::QUERY_PARAM;

    $LOG->delay( "generate_page", "Generated page page:$page, func:$func" );
}

# Konec smycky: signal TERM, jednorazove CGI po svem jedinem requestu, nebo chyba cekani na request.
# Knihovna FastCGI dokoncuje request (posle zbytek odpovedi a zavre spojeni) az pri cekani na dalsi -
# po signalu TERM uz se neceka, proto se posledni request dokonci tady; klient tak dostane celou
# odpoved jeste pred odpojenim databaze. Bez rozpracovaneho requestu (i v rezimu CGI) Finish nic nedela.
$CGI::Fast::Ext_Request->Finish() if ( defined($CGI::Fast::Ext_Request) );

# Chyba cekani na request (ne signal TERM a ne konec rezimu CGI, kde $ACCEPT zustava 0): do logu
# a nenulovy navratovy kod, at je videt, ze engine neskoncil na pozadani.
my $accept_error = ( !$STOP and $ACCEPT < 0 ) ? do { local $! = -$ACCEPT; "$!" } : undef;

$LOG->info("PWE server ukoncen signalem $STOP") if ($STOP);
$LOG->error("PWE server konci: cekani na request FastCGI selhalo ($accept_error)") if ( defined($accept_error) );

&end();

exit(1) if ( defined($accept_error) );

=head2 B<[Private] terminate($signal)>

    Handler signalu TERM a USR1 (viz POD, oddil UKONCENI). Jen nastavi priznak $STOP (jmeno
    prvniho signalu, ktery prisel) a zajisti, ze engine uz neprijme dalsi request -
    rozpracovany request pobezi dal a hlavni smycka skonci az po nem. Behem startu preda zadost
    Libs::MyDBI::requestStop() (prerusi cekani na databazi a migrace na bezpecnem miste).
    Knihovne FastCGI zakaze dalsi accept (LastCall) a zavre naslouchajici socket: nova spojeni
    jsou odmitnuta hned a cekani na request, do ktereho engine vstoupi az po signalu (signal
    prisel mezi kontrolou $STOP v next_request a volanim knihovny), skonci okamzite.
    Je bezpecne volat ho opakovane a kdykoli, i pred vznikem $DBI.

=cut

sub terminate {
    $STOP ||= ( $_[0] || 'TERM' );
    Libs::MyDBI::requestStop() if ( $STARTING and Libs::MyDBI->can('requestStop') );
    $CGI::Fast::Ext_Request->LastCall() if ( defined($CGI::Fast::Ext_Request) );
    close_socket();
}

=head2 B<[Private] startup_failed($chyba,$errno)>

    Zpracuje vyjimku ze startu databazove vrstvy. Kdyz prisel signal TERM a Libs::MyDBI start
    prerusila (vyjimka "Startup interrupted by termination request"), zaloguje to a ukonci proces
    s kodem 0. Kazdou jinou chybu vyhodi znovu beze zmeny textu ($errno = hodnota $! v dobe chyby,
    aby se nezmenil ani navratovy kod procesu). Nevraci se.

=cut

sub startup_failed {
    my ( $error, $errno ) = @_;
    if ( $STOP and $error =~ /Startup interrupted by termination request/ ) {
        $LOG->info("Start PWE serveru prerusen signalem $STOP");
        exit(0);
    }
    $! = $errno;
    die $error;
}

=head2 B<[Private] socket_is_tcp($adresa)>

    Vraci 1, kdyz hodnotu FCGI_SOCKET_PATH knihovna FastCGI otevre jako adresu TCP, 0 = cesta
    k unix socketu. Pravidlo knihovny (OS_CreateLocalIpcFd): TCP = za PRVNI dvojteckou nasleduje
    nenulove cislo portu (prevedene pres atoi do 16 bitu) - ":7779", "127.0.0.1:7779", "*:7779".

=cut

sub socket_is_tcp {
    my ($path) = @_;
    return 0 unless ( $path =~ /^[^:]*:\s*([+-]?\d+)/ );
    return ( ( $1 % 65536 ) != 0 ) ? 1 : 0;
}

=head2 B<[Private] socket_perm($hodnota)>

    Prevede hodnotu FCGI_SOCKET_PERM (prava unix socketu zapsana osmickove, napr. "0660") na
    cislo pro chmod. Bez hodnoty vraci vychozi 0770. Neplatny zapis = die.

=cut

sub socket_perm {
    my ($perm) = @_;
    return 0770 unless ( defined($perm) and length($perm) );
    die "FCGI_SOCKET_PERM='$perm' neni osmickovy zapis prav unix socketu (napr. 0660 nebo 0777)\n"
      unless ( $perm =~ /^[0-7]{3,4}$/ );
    return oct($perm);
}

=head2 B<[Private] listen_socket($adresa)>

    Otevre naslouchajici socket podle FCGI_SOCKET_PATH (viz POD, oddil SOCKET) a zalozi nad nim
    request FastCGI, ktery pak pouziva CGI::Fast->new() - se stejnymi parametry, s jakymi by si
    ho CGI::Fast zalozil sam. Engine si socket otevira sam ze dvou duvodu:
      - prava: CGI::Fast bere FCGI_SOCKET_PERM i svuj parametr socket_perm jako desitkove cislo
        ("0770" = prava 1402) a chmod zkousi i u adresy host:port. Tady se prava nastavuji jen
        unix socketu a hodnota se cte osmickove; socket vznika s maskou 0177, takze do chmod
        neni pristupny nikomu dalsimu;
      - ukonceni: engine potrebuje deskriptor socketu, aby na spojeni mohl cekat sam
        (wait_connection) a aby ho handler signalu TERM mohl zavrit (close_socket).
    Na Linuxu socket prepne do neblokujiciho rezimu ($NONBLOCK, viz POD, oddil UKONCENI). Jinde
    ne: prijate spojeni tam rezim dedi a knihovna FastCGI by nedocetla request, ktery neprijde
    cely najednou.
    Kdyz adresu nejde otevrit (obsazeny port, neznamy host), knihovna FastCGI vypise duvod na
    STDERR a proces ukonci sama.

=cut

sub listen_socket {
    my ($path) = @_;
    my $tcp  = socket_is_tcp($path);
    my $perm = $tcp ? undef : socket_perm( $ENV{FCGI_SOCKET_PERM} );

    my $umask = umask(0177);
    my $fd    = FCGI::OpenSocket( $path, $ENV{FCGI_LISTEN_QUEUE} || 100 );
    umask($umask);
    die "FCGI_SOCKET_PATH='$path': socket se nepodarilo otevrit\n" unless ( defined($fd) and $fd >= 0 );

    unless ($tcp) {
        chmod( $perm, $path ) or die "FCGI_SOCKET_PATH='$path': chmod unix socketu selhal: $!\n";
    }

    use_socket( $fd, "$path: " . ( $tcp ? "adresa TCP" : sprintf( "unix socket s pravy %04o", $perm ) ) );
}

=head2 B<[Private] use_socket($fd,$popis)>

    Prevezme naslouchajici socket na deskriptoru $fd: na Linuxu ho prepne do neblokujiciho rezimu
    (na spojeni pak ceka engine sam, viz wait_connection) a zalozi nad nim request FastCGI tridy
    PWE::Request. $popis jde do logu a do chybove hlasky. Vola se z listen_socket (socket
    z FCGI_SOCKET_PATH) a pro socket zdedeny po webserveru (deskriptor 0).

=cut

sub use_socket {
    my ( $fd, $desc ) = @_;
    if ( $^O eq 'linux' ) {
        $LISTEN_FH = IO::Handle->new_from_fd( $fd, 'r' );
        die "FastCGI socket $desc: socket nejde prepnout do neblokujiciho rezimu: $!\n"
          unless ( $LISTEN_FH and defined( $LISTEN_FH->blocking(0) ) );
        $NONBLOCK = 1;
    }

    $LISTEN = $fd;
    $CGI::Fast::Ext_Request = bless(
        FCGI::Request( \*STDIN, \*STDOUT, $FCGI_ERR, \%ENV, $fd, FCGI::FAIL_ACCEPT_ON_INTR ),
        'PWE::Request'
    );
    $LOG->info("FastCGI socket $desc");
}

=head2 B<[Private] close_socket()>

    Zavre naslouchajici socket otevreny v listen_socket (jen jednou - cislo deskriptoru muze po
    zavreni dostat jiny soubor). Vola ho handler signalu TERM: nova spojeni jsou odmitnuta hned,
    ne az po dobehnuti rozpracovaneho requestu. Bez otevreneho socketu nedela nic.

=cut

sub close_socket {
    return unless ( defined($LISTEN) );
    my $fd = $LISTEN;
    $LISTEN = undef;
    if ( defined($LISTEN_FH) ) {
        close($LISTEN_FH);
        $LISTEN_FH = undef;
    }
    else {
        FCGI::CloseSocket($fd);
    }
}

=head2 B<[Private] wait_connection()>

    Ceka na spojeni na naslouchajicim socketu (neblokujici rezim), nejdele 1 sekundu. Signal
    cekani prerusi; casovy limit je pojistka pro signal, ktery prijde tesne pred vstupem do
    select() - volajici (next_request) pak priznak ukonceni zkontroluje nejpozdeji za sekundu.

=cut

sub wait_connection {
    my $fd = $LISTEN;
    return unless ( defined($fd) );
    my $rin = '';
    vec( $rin, $fd, 1 ) = 1;
    select( $rin, undef, undef, 1 );
}

=head2 B<[Private] next_request()>

    Pocka na dalsi request a vrati jeho objekt CGI (CGI::Fast->new), nebo undef = konec smycky:
    po signalu TERM (na dalsi request se uz neceka), v rezimu jednorazoveho CGI po prvnim
    requestu a pri chybe cekani.

    Se socketem enginu (listen_socket) se CGI::Fast->new() vraci s undef i tehdy, kdyz konec
    neni na miste, a zkousi se to znovu:
      - EINTR: cekani prerusil jiny signal nez TERM a USR1 (ty nastavi $STOP);
      - EAGAIN (jen neblokujici rezim, $NONBLOCK): zadne spojeni neceka - nejdriv se na nej
        pocka (wait_connection).
    CGI::Fast->new() se vola pred cekanim, ne po nem: jen tak se obslouzi dalsi request na
    spojeni, ktere si webserver drzi (fastcgi_keep_conn on) - ten na naslouchajici socket
    neprijde.

=cut

sub next_request {
    until ($STOP) {
        if ($IN_REQUEST) {
            # Predchozi request se dokonci (zbytek odpovedi odejde) jeste s SA_RESTART; cekani na dalsi
            # request uz signal prerusit musi.
            $CGI::Fast::Ext_Request->Finish();
            signal_restart(0);
            next;
        }
        my $cgi = CGI::Fast->new();
        return $cgi if ( defined($cgi) );
        if ( $ACCEPT == -EINTR() ) {
            next;
        }
        elsif ( $NONBLOCK and ( $ACCEPT == -EAGAIN() or $ACCEPT == -EWOULDBLOCK() ) ) {
            wait_connection();
        }
        else {
            last;
        }
    }
    return undef;
}

=head2 B<[Private] signal_restart($zapnout)>

    Prepne handlery signalu TERM a USR1 (terminate). 1 = po dobu requestu: systemova volani
    prerusena signalem se zopakuji (SA_RESTART) - signal tak neprerusi cteni tela requestu ani
    odesilani odpovedi (knihovna FastCGI preruseni neopakuje, proud zavre a request by dobehl
    se zkracenym telem nebo klient dostal jen cast odpovedi). 0 = pri cekani na request: volani
    se prerusi, aby cekani skoncilo. Handler zustava odlozeny ("safe signals"), bezi tedy az po
    navratu z prave provadene operace perlu. Vola se jen nad socketem enginu (PWE::Request).

=cut

sub signal_restart {
    my ($on) = @_;
    foreach my $sig ( POSIX::SIGTERM(), POSIX::SIGUSR1() ) {
        my $act = POSIX::SigAction->new( \&terminate, POSIX::SigSet->new(), ( $on ? POSIX::SA_RESTART() : 0 ) );
        $act->safe(1);
        POSIX::sigaction( $sig, $act ) or die "sigaction($sig) selhalo: $!\n";
    }
    $IN_REQUEST = $on ? 1 : 0;
}

=head2 B<[Private] end()>

    Ukonceni serveru: odpoji vsechna databazova spojeni (pro kazde dbid z $DBI->getDbidList).
    Vola se po skonceni FastCGI smycky a pri ukonceni behem startu. Je bezpecne volat ji
    opakovane i pred vznikem $DBI (pak nedela nic); chyba odpojeni se jen zaloguje, aby
    nezmenila navratovy kod ukoncovaneho procesu.

=cut

sub end {
    return unless ( defined($DBI) );
    my $dbi = $DBI;
    $DBI = undef;
    foreach my $dbid ( @{ $dbi->getDbidList() } ) {
        eval { $dbi->disconnect($dbid); 1 } or $LOG->error("Odpojeni databaze $dbid selhalo: $@");
    }
}

=head2 B<[Private] PWE::Request::Accept()>

    Request FastCGI nad socketem enginu (listen_socket) je objekt tridy PWE::Request, potomka
    tridy FCGI. Lisi se jen tim, ze si vysledek Accept knihovny FastCGI (0 = prijaty request,
    zaporne cislo = -errno) uklada do $ACCEPT. CGI::Fast->new() ho zahazuje a vraci jen undef,
    next_request ale potrebuje rozlisit "zadne spojeni neceka" (EAGAIN) od skutecne chyby.

=cut

{

    package PWE::Request;
    use parent -norequire, 'FCGI';

    sub Accept {
        my $self = shift;
        $ACCEPT = $self->SUPER::Accept();
        main::signal_restart(1) if ( $ACCEPT >= 0 );
        return $ACCEPT;
    }
}

1;
