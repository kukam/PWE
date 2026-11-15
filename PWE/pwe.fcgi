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

=cut

# use Cwd qw( abs_path realpath cwd );
use File::Basename qw( dirname basename );

my $dirname = ((dirname($0) =~ /^\//) ? dirname($0)."/" : ((dirname($0) =~ /^\./) ? dirname($0)."/" : "./".dirname($0)."./" ));
my $basename = basename($0); 

use lib dirname($0);
use CGI::Fast socket_perm => '0770';
use CGI qw/ :standard /;
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

use POSIX qw(setsid);

# require 'syscall.ph';

local $SIG{TERM} = \&end;

CGI::Fast->file_handles( { fcgi_error_file_handle => IO::Handle->new } );

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
my $DBI = Libs::MyDBI->new( $CONF, $LOG, $VALIDATE );
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

if ( $ENV{FCGI_DAEMONIZE} ) { &daemonize; }

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

while ( my $CGI = CGI::Fast->new() ) {

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

&end();

=head2 B<[Private] end()>

    Ukonceni serveru: odpoji vsechna databazova spojeni (pro kazde dbid z $DBI->getDbidList).
    Vola se po skonceni FastCGI smycky a jako handler signalu TERM.

=cut

sub end {
    foreach my $dbid ( @{ $DBI->getDbidList() } ) {
        $DBI->disconnect($dbid);
    }
}

1;
