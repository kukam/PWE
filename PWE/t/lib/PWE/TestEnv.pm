package PWE::TestEnv;

=head1 NAME

PWE::TestEnv - pomocny modul pro testy enginu PWE (t/*.t)

=head1 POPIS

    Postavi kompletni engine (stejne poradi singletonu jako pwe.fcgi) nad fixture
    aplikaci v t/fixtures/app, ktera nema databazi. Nabizi pomocne funkce pro
    simulaci requestu a zachytavani vystupu na STDOUT.

    Cesty t/... jsou relativni k adresari enginu (adresar PWE/ v koreni repozitare, v kontejneru
    /PWE/PWE). Koren enginu neni nikde zapsany pevne: root() ho odvozuje od umisteni spusteneho
    testu ($FindBin::Bin/..), fixture weby app() a app2() lezi pod nim.

    use lib "$FindBin::Bin/lib";                  # t/lib (prove navic dostava -I<engine> -I<engine>/t/lib)
    use PWE::TestEnv;
    my $E = PWE::TestEnv->boot();                 # { CONF, LOG, VALIDATE, DBI, USER, WEB, ENTITIES, SERVICES, SITES, PAGES }
    PWE::TestEnv::request($E, page => 'tPage', func => 'default', params => { email => ['a@b.cz'] });
    my $out = PWE::TestEnv::capture(sub { $E->{PAGES}->callPageFunc('tPage', 'default') });
    PWE::TestEnv::finish($E);

=cut

use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);
use File::Path qw(make_path remove_tree);

our $ROOT = abs_path("$FindBin::Bin/..");    # koren enginu = adresar s pwe.fcgi (PWE/ v repozitari, /PWE/PWE v kontejneru)
our $APP  = "$ROOT/t/fixtures/app/";    # fixture web uvnitr enginu (symlinky, jeden koren)
our $APP2 = "$ROOT/t/fixtures/app2/";   # fixture web bez symlinku na engine (dva koreny: pwe.home = app2, pwe.core = $ROOT)

sub root { return $ROOT; }
sub app  { return $APP; }
sub app2 { return $APP2; }

# Smaze z prostredi vsechny PWE_CONF_* (image pwe-* maji zapecene PWE_CONF_pwe_core, image webu
# i PWE_CONF_pwe_home) a FCGI_SOCKET_PATH (v image neni, maji ji az kontejnery compose stacku).
sub clean_env {
    foreach my $k (grep { /^PWE_CONF_/ } keys %ENV) { delete $ENV{$k}; }
    delete $ENV{'FCGI_SOCKET_PATH'};
}

# Pripravi (vycisti) docasny adresar ramdisk fixture aplikace.
sub reset_ramdisk {
    my $app = shift || $APP;
    remove_tree("${app}ramdisk");
    make_path("${app}ramdisk/templates", "${app}ramdisk/opts", "${app}ramdisk/upload");
}

# Fixture aplikace musi byt v @INC pred enginem (v pwe.fcgi to dela "use lib" + getRoots()).
sub add_inc {
    my $app = shift || $APP;
    foreach my $d ($ROOT, $app) {
        (my $dir = $d) =~ s{/$}{};
        @INC = grep { $_ ne $dir } @INC;
        unshift(@INC, $dir);
    }
}

# Jen jadro bez loaderu: CONF, LOG, VALIDATE (pro testy nizkourovnovych trid).
# Volby: app => adresar fixture webu (vychozi $APP), core => koren enginu, typicky root() (nastavi
# PWE_CONF_pwe_core, tj. rezim dvou korenu; nazev volby odpovida klici pwe.core, ne nazvu adresare),
# loglevel, logout, keep_ramdisk, conf => { sekce => { klic => hodnota } }
# (prepis konfigurace pred startem loaderu, napr. core_pages s pweCreator).
sub core {
    my ($class, %opt) = @_;
    my $app = $opt{'app'} || $APP;
    $app .= '/' unless ($app =~ m{/$});
    clean_env();
    $ENV{'PWE_CONF_pwe_core'} = $opt{'core'} if ($opt{'core'});
    add_inc($app);
    reset_ramdisk($app) unless ($opt{'keep_ramdisk'});
    require Libs::Config;
    require Libs::Log;
    require Libs::Validate;
    my $CONF = Libs::Config->new($app, 'pwe.fcgi', 'conf/web.conf', 'conf/database.conf');
    $CONF->{'log'}->{'loglevel'} = $opt{'loglevel'} if (defined($opt{'loglevel'}));
    $CONF->{'log'}->{'logout'}   = $opt{'logout'}   if (defined($opt{'logout'}));
    if (ref($opt{'conf'}) eq 'HASH') {
        foreach my $sec (keys %{$opt{'conf'}}) {
            foreach my $key (keys %{$opt{'conf'}->{$sec}}) { $CONF->{$sec}->{$key} = $opt{'conf'}->{$sec}->{$key}; }
        }
    }
    my $LOG      = Libs::Log->new($CONF);
    my $VALIDATE = Libs::Validate->new($CONF, $LOG);
    return {CONF => $CONF, LOG => $LOG, VALIDATE => $VALIDATE, APP => $app};
}

# Kompletni engine (bez DB).
sub boot {
    my ($class, %opt) = @_;
    my $E = $class->core(%opt);
    require Libs::MyDBI;
    require Libs::User;
    require Libs::Web;
    require Libs::Entities;
    require Libs::Services;
    require Libs::Sites;
    require Libs::Pages;
    my ($CONF, $LOG, $VALIDATE) = @{$E}{qw(CONF LOG VALIDATE)};
    $E->{'DBI'}      = Libs::MyDBI->new($CONF, $LOG, $VALIDATE);
    $E->{'USER'}     = Libs::User->new($CONF, $LOG, $VALIDATE, $E->{'DBI'});
    $E->{'WEB'}      = Libs::Web->new($CONF, $LOG, $VALIDATE, $E->{'DBI'}, $E->{'USER'});
    $E->{'ENTITIES'} = Libs::Entities->new($CONF, $LOG, $VALIDATE, $E->{'DBI'}, $E->{'USER'}, $E->{'WEB'});
    $E->{'SERVICES'} = Libs::Services->new($CONF, $LOG, $VALIDATE, $E->{'DBI'}, $E->{'USER'}, $E->{'WEB'}, $E->{'ENTITIES'});
    $E->{'SITES'}    = Libs::Sites->new($CONF, $LOG, $VALIDATE, $E->{'DBI'}, $E->{'USER'}, $E->{'WEB'}, $E->{'ENTITIES'}, $E->{'SERVICES'});
    $E->{'PAGES'}    = Libs::Pages->new($CONF, $LOG, $VALIDATE, $E->{'DBI'}, $E->{'USER'}, $E->{'WEB'}, $E->{'ENTITIES'}, $E->{'SERVICES'}, $E->{'SITES'});
    return $E;
}

# Simulace zacatku requestu (to, co dela smycka v pwe.fcgi pred callPageFunc).
sub request {
    my ($E, %r) = @_;
    require CGI;
    my $env = {
        'REMOTE_ADDR'     => '10.0.0.1',
        'HTTP_USER_AGENT' => 'pwe-test',
        'HTTP_HOST'       => 'test.local',
        'REQUEST_METHOD'  => 'GET',
        'SCRIPT_FILENAME' => '/pwe.fcgi',
        %{$r{'env'} || {}},
    };
    my $cgi = CGI->new('');
    $E->{'USER'}->newRequest($r{'page'} || 'tPage', $r{'func'} || 'default', $r{'sid'}, (defined($r{'opt'}) ? $r{'opt'} : 1), $env, $cgi);
    $E->{'SITES'}->newRequest();
    $E->{'SERVICES'}->newRequest();
    my $params = $r{'params'} || {};
    foreach my $p (keys %{$params}) {
        my $v = $params->{$p};
        $E->{'USER'}->setParameter($p, (ref($v) eq 'ARRAY' ? $v : [$v]));
    }
    return $env;
}

# Konec requestu (flush vsech vrstev).
sub finish {
    my $E = shift;
    $E->{'SITES'}->flush();
    $E->{'SERVICES'}->flush();
    $E->{'WEB'}->flush();
    $E->{'USER'}->flush();
}

# Zachyti vse, co kod vytiskne na STDOUT, a vrati to jako retezec.
sub capture {
    my $code = shift;
    my $out  = '';
    open(my $fh, ">", \$out) or die "capture: $!";
    my $old = select($fh);
    my $ret = eval { $code->() };
    my $err = $@;
    select($old);
    close($fh);
    die $err if ($err);
    return wantarray ? ($out, $ret) : $out;
}

1;
