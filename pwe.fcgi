#!/usr/bin/env perl

use strict;
use warnings;

# use Cwd qw( abs_path );
use File::Basename qw( dirname basename );

# use lib dirname( abs_path( $0 ) );
use lib dirname($0);
use CGI::Fast socket_perm => 0770;
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

#require 'syscall.ph';

$SIG{TERM} = \&end;

CGI::Fast->file_handles( { fcgi_error_file_handle => IO::Handle->new } );

my $CONF = new Libs::Config('conf/webconfig.pl');
my $LOG  = new Libs::Log($CONF);
$LOG->info("Starting PWE server...");

$LOG->delay("create_object_validate");
my $VALIDATE = new Libs::Validate( $CONF, $LOG );
$LOG->delay( "create_object_validate", "Created object VALIDATE" );

$LOG->delay("create_object_dbi");
my $DBI = new Libs::MyDBI( $CONF, $LOG, $VALIDATE );
$LOG->delay( "create_object_dbi", "Created object DBI" );

$LOG->delay("create_object_user");
my $USER = new Libs::User( $CONF, $LOG, $VALIDATE, $DBI );
$LOG->delay( "create_object_user", "Created object USER" );

$LOG->delay("create_object_web");

my $WEB = new Libs::Web( $CONF, $LOG, $VALIDATE, $DBI, $USER );
$LOG->delay( "create_object_web", "Created object WEB" );

$LOG->delay("create_object_entities");
my $ENTITIES = new Libs::Entities( $CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB );
$LOG->delay( "create_object_entities", "Created object ENTITIES" );

$LOG->delay("create_object_services");
my $SERVICES =
  new Libs::Services( $CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB, $ENTITIES );
$LOG->delay( "create_object_services", "Created object SERVICES" );

$LOG->delay("create_object_sites");
my $SITES =
  new Libs::Sites( $CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB, $ENTITIES,
    $SERVICES );
$LOG->delay( "create_object_sites", "Created object SITES" );

$LOG->delay("create_object_pages");
my $PAGES =
  new Libs::Pages( $CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB, $ENTITIES,
    $SERVICES, $SITES );
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

    #my $env  = $FCGI->GetEnvironment();
    my $env = \%ENV;
    my $sid = $CGI->cookie(
        $CONF->getValue( "http", "cookie_name", "UNKNOWN_SESSION_NAME" ) );
    my $page = (
        defined( $CGI->param('page') )
        ? $CGI->param('page')
        : $CONF->getValue( "pwe", "default_page", 'default' )
    );
    my $func = (
        defined( $CGI->param('func') )
        ? $CGI->param('func')
        : $CONF->getValue( "pwe", "default_func", 'default' )
    );
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
    elsif (( basename($0) eq $env->{'SCRIPT_FILENAME'} )
        or ( "/" . basename($0) eq $env->{'SCRIPT_FILENAME'} )
        or ( basename($0) eq "." . $env->{'SCRIPT_FILENAME'} )
        or ( $env->{'SCRIPT_FILENAME'} eq "/" )
        or ( !$env->{'SCRIPT_FILENAME'} ) )
    {
        $result = $PAGES->callPageFunc( $page, $func );
    }
    elsif (
        -f $CONF->getValue( 'pwe', 'home', '' ) . "$env->{'SCRIPT_FILENAME'}" )
    {
        $result = $PAGES->callPageFunc( 'systemPage', 'file' );
    }
    elsif (
        -d $CONF->getValue( 'pwe', 'home', '' ) . "$env->{'SCRIPT_FILENAME'}" )
    {
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

    $LOG->info(
        "User call page finis: PID:$$ page:$page func:$func result:$result_info"
    );

    $page = $USER->getPage();
    $func = $USER->getFunc();

    $SITES->flush();
    $SERVICES->flush();
    $WEB->flush();
    $USER->flush();
    $LOG->debug("Fastcgi cycle ended");

    # CLEAR
    undef @CGI::QUERY_PARAM;

    $LOG->delay( "generate_page", "Generated page page:$page, func:$func" );
}

&end();

sub end {
    foreach my $dbid ( @{ $DBI->getDbidList() } ) {
        $DBI->disconnect($dbid);
    }
}

1;
