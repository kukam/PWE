#!/usr/bin/env perl
# Shell nastroje kolem image (PWE/tools/lib/images.sh, build-images.sh, run-tests.sh, perl-compile.sh,
# pwe-cgi.sh, run-webapp.sh, smoke-images.sh), Makefile v koreni repozitare a textova pravidla
# docker-bake.hcl a .github/workflows/images.yml:
#   - tag image = verze enginu z PWE/VERSION (pwe_image_version, pwe_image_tag) bez gitu a bez ohledu na
#     vetev, kontrola PWE_IMAGE_TAG, shoda s PWE::ToolEnv
#   - seznam image (5 zavislostnich bez enginu a bez webu, 4 image vzorovych webu), zavislostni image profilu
#     (static -> pwe-base), rada pri chybejicim image (cil sestaveni, zrusene image)
#   - build-images.sh: cile = jmena image bez predpony pwe-, tagy <verze> + latest, pojistka --push
#     (necommitnute zmeny), hodnoty voleb, promenne pro docker buildx bake
#   - run-tests.sh a perl-compile.sh: skutecna prikazova radka docker run, zamek pracovni kopie
#   - pwe-cgi.sh: k siti compose stacku se pripoji jen tehdy, kdyz stack patri temuz webu
#   - run-webapp.sh: neznamy profil nebo prikaz, image sluzby fcgi podle profilu (PWE_FCGI_IMAGE), varovani pri
#     neshode webu a profilu
#   - smoke-images.sh: zavislostni image neobsahuji engine ani web; image vzorovych webu vychazeji ze sveho
#     zakladu a obsahuji engine a vzorovy web; srovnani s pracovni kopii (seznam i obsah souboru, entrypoint) jen
#     u image, ktery ji odpovida (--tree, --no-tree); pwe-example-static obslouzi request i s korenovym
#     souborovym systemem jen pro cteni (--read-only + tmpfs pres pracovni adresare); entrypoint pri startu
#     serveru varuje, ze bezi vzorovy web
#   - Makefile: recepty cilu (text) a jejich rozvinuti (make -n, jen kdyz je v image make)
#   - images.yml: zaklad image pripnuty na digest ve vsech volanich bake, kourove kontroly s --tree
#   - docker-bake.hcl: 9 cilu (5 zavislostnich image, 4 image vzorovych webu stavene Dockerfilem webu nad prave
#     sestavenym zakladem), kazdy s tagy <verze> a latest, zadny tag podle vetve
#
# V testovacim kontejneru neni git ani docker. Test si proto v docasnem adresari vytvori falesne
# spustitelne soubory git a docker (chovani ridi promenne FAKE_*, kazde volani se zapise do souboru
# $FAKE_LOG) a da je na zacatek PATH.
#
# Nastroje se nespousteji z pracovni kopie, ale z KOPIE v docasnem stromu (<tmp>/repo/PWE/tools/...,
# vedle falesne weby <tmp>/repo/webapps/*.web a vlastni PWE/VERSION - testy tak nezavisi na cisle verze
# enginu v repozitari). Duvod: tento test bezi uvnitr vnejsiho run-tests.sh, ktery uz drzi zamek pracovni
# kopie PWE/t/.run-tests.lock - testovany run-tests.sh na nej nesmi sahnout. Skripty odvozuji koren
# repozitare od sveho umisteni, takze kopie pracuje se zamkem <tmp>/repo/PWE/t/.run-tests.lock a nastroje
# nepotrebuji zadnou promennou jen pro testy. Kopii ma i PWE::ToolEnv (<tmp>/repo/PWE/tools/lib/PWE):
# verzi cte ze souboru VERSION vedle sebe, takze shodu se shell funkcemi jde overit nad stejnym souborem.
use strict;
use warnings;
use Test::More;
use FindBin;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);
use POSIX ();
use Time::HiRes ();
use lib "$FindBin::Bin/lib";
use lib "$FindBin::Bin/../tools/lib";
use PWE::TestEnv;
use PWE::ToolEnv;

my $SYS_PATH = $ENV{'PATH'} || '/usr/local/bin:/usr/bin:/bin';
my ($BASH) = grep { -x $_ } map { "$_/bash" } grep { length } split(/:/, $SYS_PATH), '/bin';
plan skip_all => 'chybi bash' unless ($BASH);

my $ROOT  = PWE::TestEnv::root();    # koren enginu (adresar PWE/ v koreni repozitare, v kontejneru /PWE/PWE)
my $TOOLS = "$ROOT/tools";

# ---------------------------------------------------------------------------------------------
# docasny strom: kopie nastroju, falesne weby, falesny git a docker
# ---------------------------------------------------------------------------------------------
my $T    = abs_path(tempdir('pwe-image-tools-XXXXXX', TMPDIR => 1, CLEANUP => 1));
my $REPO = "$T/repo";
my $LOG  = "$T/fake.log";
my $LOCK = "$REPO/PWE/t/.run-tests.lock";

sub slurp { my ($f) = @_; open(my $fh, '<', $f) or return ''; local $/; my $s = <$fh>; close($fh); return defined($s) ? $s : ''; }

sub spit {
    my ($f, $content, $mode) = @_;
    make_path(dirname($f)) unless (-d dirname($f));
    open(my $fh, '>', $f) or die "Nelze zapsat $f: $!";
    print $fh $content;
    close($fh);
    chmod($mode, $f) if (defined($mode));
}

make_path("$REPO/PWE/tools/lib/PWE", "$REPO/PWE/t", "$T/bin", "$T/bin-nogit");
foreach my $sh (qw(build-images.sh run-tests.sh perl-compile.sh pwe-cgi.sh run-webapp.sh smoke-images.sh lib/images.sh lib/PWE/ToolEnv.pm)) {
    copy("$TOOLS/$sh", "$REPO/PWE/tools/$sh") or die "Nelze zkopirovat tools/$sh: $!";
    chmod(0755, "$REPO/PWE/tools/$sh");
}
my $VERSION      = '9.8.7';                  # verze enginu v docasnem stromu (zamerne jina nez v repozitari)
my $VERSION_FILE = "$REPO/PWE/VERSION";
spit($VERSION_FILE, "$VERSION\n");

# weby: st.web bez databaze, db.web s conf/mariadb.conf (bez database.conf), dblink.web s databazi
# zapnutou symlinkem conf/database.conf -> postgres.conf, other.web = web "ciziho" stacku,
# badlink.web se symlinkem na neznamy profil
foreach my $web (qw(st.web db.web dblink.web other.web badlink.web)) { spit("$REPO/webapps/$web/conf/web.conf", "{}\n"); }
spit("$REPO/webapps/db.web/conf/mariadb.conf",      "{}\n");
spit("$REPO/webapps/dblink.web/conf/mysql.conf",    "{}\n");
spit("$REPO/webapps/dblink.web/conf/postgres.conf", "{}\n");
symlink('postgres.conf', "$REPO/webapps/dblink.web/conf/database.conf") or die "symlink: $!";
symlink('vlastni.conf',  "$REPO/webapps/badlink.web/conf/database.conf") or die "symlink: $!";

# Falesny git. FAKE_GIT_NOREPO=1: adresar neni repozitar; FAKE_GIT_PREFIX: vystup rev-parse --show-prefix
# (neprazdny = repozitar PWE lezi uvnitr ciziho gitu); FAKE_GIT_BRANCH: vetev (prazdna = odpojeny HEAD);
# FAKE_GIT_DIRTY: vystup status --porcelain; FAKE_GIT_HEAD: commit. Zna jen prikazy, ktere nastroje
# opravdu pouzivaji (cokoli jineho = kod 99), a jako skutecny git selze, kdyz adresar z -C neexistuje.
# Na vetev (symbolic-ref) se uz zadny nastroj ptat nema - tag image na ni nezavisi; falesny git dotaz
# presto umi, aby ho test v logu volani poznal.
spit("$T/bin/git", <<'EOS', 0755);
#!/bin/bash
{ printf 'git'; for a in "$@"; do printf '\t%s' "${a//$'\n'/<NL>}"; done; printf '\n'; } >> "$FAKE_LOG"
if [ "${FAKE_GIT_NOREPO:-0}" = 1 ]; then echo "fatal: not a git repository" >&2; exit 128; fi
if [ "$1" = "-C" ]; then
    [ -d "$2" ] || { echo "fatal: cannot change to '$2'" >&2; exit 128; }
    shift 2
fi
case "$*" in
    "rev-parse --show-prefix")           printf '%s\n' "${FAKE_GIT_PREFIX:-}" ;;
    "rev-parse HEAD")                    printf '%s\n' "${FAKE_GIT_HEAD:-0123456789abcdef0123456789abcdef01234567}" ;;
    "symbolic-ref --quiet --short HEAD") [ -n "${FAKE_GIT_BRANCH:-}" ] || exit 1; printf '%s\n' "$FAKE_GIT_BRANCH" ;;
    "status --porcelain")                if [ -n "${FAKE_GIT_DIRTY:-}" ]; then printf '%s\n' "$FAKE_GIT_DIRTY"; fi ;;
    *) echo "falesny git: neocekavany prikaz $*" >&2; exit 99 ;;
esac
exit 0
EOS

# Falesny docker. Do logu zapise radek "docker<TAB>argumenty" (nove radky v argumentu -> mezera) a
# u buildx / compose jeste radek "env<TAB>PROMENNA=hodnota..." s promennymi, ktere nastroj predava.
#   FAKE_DOCKER_INSPECT_RC   navratovy kod "image inspect" (0 = image je v lokalnim Dockeru)
#   FAKE_DOCKER_TAGS         vystup "image ls" (tagy oddelene mezerou)
#   FAKE_DOCKER_NETWORK_RC   navratovy kod "network inspect" (0 = sit pwe_default existuje)
#   FAKE_DOCKER_FCGI_CID / FAKE_DOCKER_DEBUGGER_CID   vystup "ps" pro sluzbu fcgi / debugger
#   FAKE_DOCKER_WORKDIR      vystup "inspect" (pracovni adresar kontejneru)
#   FAKE_DOCKER_RUN_RC       navratovy kod "run"
#   FAKE_DOCKER_RUN_STARTED  soubor, ktery "run" po startu vytvori
#   FAKE_DOCKER_RUN_HOLD     "run" ceka, dokud tento soubor neexistuje (nejvys 30 s)
spit("$T/bin/docker", <<'EOS', 0755);
#!/bin/bash
{ printf 'docker'; for a in "$@"; do printf '\t%s' "${a//$'\n'/ }"; done; printf '\n'; } >> "$FAKE_LOG"
case "$1" in
    buildx | compose)
        printf 'env\tREGISTRIES=%s\tTAG=%s\tVERSION=%s\tREVISION=%s\tCREATED=%s\tSOURCE=%s\tPWE_WEBAPP=%s\tCOMPOSE_PROFILES=%s\tPWE_IMAGE_REGISTRY=%s\tPWE_IMAGE_TAG=%s\tPWE_FCGI_IMAGE=%s\tCWD=%s\n' \
            "${REGISTRIES-<unset>}" "${TAG-<unset>}" "${VERSION-<unset>}" "${REVISION-<unset>}" "${CREATED-<unset>}" "${SOURCE-<unset>}" \
            "${PWE_WEBAPP-<unset>}" "${COMPOSE_PROFILES-<unset>}" "${PWE_IMAGE_REGISTRY-<unset>}" "${PWE_IMAGE_TAG-<unset>}" "${PWE_FCGI_IMAGE-<unset>}" "$PWD" >> "$FAKE_LOG"
        ;;
    image)
        case "$2" in
            inspect) exit "${FAKE_DOCKER_INSPECT_RC:-0}" ;;
            ls)      for t in ${FAKE_DOCKER_TAGS:-}; do printf '%s\n' "$t"; done ;;
        esac
        ;;
    network) exit "${FAKE_DOCKER_NETWORK_RC:-1}" ;;
    ps)
        case "$*" in
            *service=fcgi*)     if [ -n "${FAKE_DOCKER_FCGI_CID:-}" ]; then printf '%s\n' "$FAKE_DOCKER_FCGI_CID"; fi ;;
            *service=debugger*) if [ -n "${FAKE_DOCKER_DEBUGGER_CID:-}" ]; then printf '%s\n' "$FAKE_DOCKER_DEBUGGER_CID"; fi ;;
        esac
        ;;
    inspect) printf '%s\n' "${FAKE_DOCKER_WORKDIR:-}" ;;
    run)
        if [ -n "${FAKE_DOCKER_RUN_STARTED:-}" ]; then : > "$FAKE_DOCKER_RUN_STARTED"; fi
        if [ -n "${FAKE_DOCKER_RUN_HOLD:-}" ]; then
            i=0
            while [ ! -e "$FAKE_DOCKER_RUN_HOLD" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
        fi
        exit "${FAKE_DOCKER_RUN_RC:-0}"
        ;;
esac
exit 0
EOS
copy("$T/bin/docker", "$T/bin-nogit/docker") or die "copy: $!";
chmod(0755, "$T/bin-nogit/docker");

# Prostredi nastroju: jen to, co test sam nastavi (zadne PWE_IMAGE_*, CDPATH ani FAKE_* zvenci).
my %BASE_ENV = (
    'PATH'     => "$T/bin:$SYS_PATH",
    'HOME'     => $T,
    'FAKE_LOG' => $LOG,
);
my $NOGIT_PATH = "$T/bin-nogit:$SYS_PATH";    # bez falesneho gitu (v kontejneru tedy bez gitu uplne)

# Potomek: nastavi prostredi (undef = promenna se smaze) a pracovni adresar, presmeruje vystupy a spusti prikaz.
# Volba drop_root => 1: bezi-li test jako root, spusti se prikaz jako nobody (root by zapsal i do adresare
# bez prava zapisu); kdyz se prava zahodit nepodari, skonci potomek kodem 124.
sub child_exec {
    my ($o, $fout, $ferr, @cmd) = @_;
    %ENV = %BASE_ENV;
    foreach my $k (keys %{$o->{'env'} || {}}) {
        if (defined($o->{'env'}->{$k})) { $ENV{$k} = $o->{'env'}->{$k}; } else { delete $ENV{$k}; }
    }
    if ($o->{'cwd'}) { chdir($o->{'cwd'}) or POSIX::_exit(125); }
    open(STDIN,  '<', '/dev/null') or POSIX::_exit(126);
    open(STDOUT, '>', $fout)       or POSIX::_exit(126);
    open(STDERR, '>', $ferr)       or POSIX::_exit(126);
    if ($o->{'drop_root'} and $> == 0) {
        $) = '65534 65534';
        POSIX::setgid(65534);
        POSIX::setuid(65534);
        POSIX::_exit(124) if ($> == 0);
    }
    exec(@cmd) or POSIX::_exit(127);
}

my $RUN_SEQ = 0;

# Spusti prikaz na pozadi (bez shellu). Vraci popis behu pro finish_bg().
sub start_bg {
    my ($o, @cmd) = @_;
    $RUN_SEQ++;
    my %h = ('out' => "$T/run-$RUN_SEQ.out", 'err' => "$T/run-$RUN_SEQ.err");
    my $pid = fork();
    die "fork: $!" unless (defined($pid));
    child_exec($o, $h{'out'}, $h{'err'}, @cmd) if ($pid == 0);
    $h{'pid'} = $pid;
    return \%h;
}

# Pocka na konec behu z start_bg(). Vraci (navratovy kod, STDOUT, STDERR); ukonceni signalem = 128 + signal.
# Beh, ktery neskonci do $RUN_TIMEOUT sekund (napr. nastroj cekajici na zamek, ktery se nikdy neuvolni),
# se ukonci signalem KILL (kod 137) - test pak selze, ale nezustane viset.
my $RUN_TIMEOUT = 90;

sub finish_bg {
    my ($h) = @_;
    my $timed_out = 0;
    local $SIG{'ALRM'} = sub { $timed_out = 1; kill('KILL', $h->{'pid'}); };
    alarm($RUN_TIMEOUT);
    my $w;
    do { $w = waitpid($h->{'pid'}, 0); } while ($w == -1 and $!{'EINTR'});
    my $status = $?;
    alarm(0);
    diag("prikaz (pid $h->{'pid'}) neskoncil do $RUN_TIMEOUT s a byl ukoncen") if ($timed_out);
    my $rc = ($status & 127) ? 128 + ($status & 127) : ($status >> 8);
    return ($rc, slurp($h->{'out'}), slurp($h->{'err'}));
}

# Spusti prikaz a pocka na nej. Volby: env => { PROMENNA => hodnota | undef }, cwd => adresar, drop_root => 1.
sub run_cmd { my ($o, @cmd) = @_; return finish_bg(start_bg($o, @cmd)); }

# Spusti skript pres bash s danym prostredim: sh({ PROMENNA => hodnota }, skript, argumenty...).
sub sh { my ($env, @args) = @_; return run_cmd({'env' => $env}, $BASH, @args); }

# Ceka (nejvys $timeout sekund), az podminka vrati pravdu.
sub wait_for {
    my ($cond, $timeout) = @_;
    my $end = Time::HiRes::time() + ($timeout || 10);
    while (Time::HiRes::time() < $end) {
        return 1 if ($cond->());
        Time::HiRes::sleep(0.05);
    }
    return $cond->() ? 1 : 0;
}

sub log_reset { unlink($LOG); }

# Cislo procesu, ktery uz nebezi (potomek, ktery hned skoncil a byl vyzvednut).
sub dead_pid {
    my $pid = fork();
    die "fork: $!" unless (defined($pid));
    POSIX::_exit(0) if ($pid == 0);
    waitpid($pid, 0);
    return $pid;
}

# Volani falesnych prikazu z logu: calls('docker') = seznam poli argumentu, calls('docker', 'run') jen podprikaz run.
sub calls {
    my ($cmd, $sub) = @_;
    my @calls;
    foreach my $line (split(/\n/, slurp($LOG))) {
        my ($c, @args) = split(/\t/, $line, -1);
        next unless (defined($c) and $c eq $cmd);
        next if (defined($sub) and (!@args or $args[0] ne $sub));
        push(@calls, \@args);
    }
    return @calls;
}

# Promenne, ktere dostal posledni docker buildx / docker compose (radek "env" v logu), jako hash.
sub call_env {
    my %env;
    foreach my $line (split(/\n/, slurp($LOG))) {
        next unless ($line =~ s/^env\t//);
        %env = map { my ($k, $v) = split(/=/, $_, 2); ($k => $v) } split(/\t/, $line, -1);
    }
    return \%env;
}

# Posledni volani "docker buildx bake": pole argumentu za "buildx bake" (undef = bake se nevolal).
sub bake_args {
    my @bake = grep { @{$_} >= 2 and $_->[1] eq 'bake' } calls('docker', 'buildx');
    return undef unless (@bake);
    my @args = @{$bake[-1]};
    return [@args[2 .. $#args]];
}

sub has_pair { my ($args, $a, $b) = @_; for my $i (0 .. $#{$args} - 1) { return 1 if ($args->[$i] eq $a and $args->[$i + 1] eq $b); } return 0; }

my $IMAGES_SH = "$REPO/PWE/tools/lib/images.sh";
my $HEAD      = '0123456789abcdef0123456789abcdef01234567';

# ---------------------------------------------------------------------------------------------
# images.sh: verze enginu z PWE/VERSION = vychozi tag image (pwe_image_version, pwe_image_tag); na gitu
# ani na vetvi nezavisi. Shoda s PWE::ToolEnv::image_version() a image_tag().
# ---------------------------------------------------------------------------------------------

# PWE::ToolEnv z kopie v docasnem stromu (cte tamni PWE/VERSION): spusti kod v samostatnem procesu.
# Vraci (navratovy kod, STDOUT, STDERR).
sub perl_env { my ($env, $code) = @_; return run_cmd({'env' => $env}, $^X, "-I$REPO/PWE/tools/lib", '-MPWE::ToolEnv', '-e', $code); }

# PWE::ToolEnv::image_tag() z kopie: vraci tag, nebo "DIE: hlaska".
sub perl_image_tag {
    my ($env) = @_;
    my ($rc, $out, $err) = perl_env($env, 'print PWE::ToolEnv::image_tag()');
    return ($rc == 0) ? $out : "DIE: $err";
}

{
    # stav gitu tag neovlivni: at je pracovni kopie na jakekoli vetvi, v odpojenem HEAD, uvnitr ciziho
    # repozitare nebo bez gitu, tag je verze z PWE/VERSION a git se vubec nevola
    my @git_states = (
        ['vetev pwe.ai',                         {FAKE_GIT_BRANCH => 'pwe.ai'}],
        ['vetev s lomitkem',                     {FAKE_GIT_BRANCH => 'feature/kosik'}],
        ['vetev master',                         {FAKE_GIT_BRANCH => 'master'}],
        ['vetev tvaru verze',                    {FAKE_GIT_BRANCH => '1.2.3'}],
        ['odpojeny HEAD',                        {FAKE_GIT_BRANCH => ''}],
        ['kopie uvnitr ciziho gitu',             {FAKE_GIT_BRANCH => 'cizi', FAKE_GIT_PREFIX => 'sub/pwe/'}],
        ['adresar neni repozitar',               {FAKE_GIT_BRANCH => 'cizi', FAKE_GIT_NOREPO => 1}],
        ['bez prikazu git',                      {PATH => $NOGIT_PATH}],
    );
    foreach my $c (@git_states) {
        my ($what, $env) = @{$c};
        log_reset();
        my ($rc, $out, $err) = sh($env, $IMAGES_SH, 'pwe_image_tag');
        is("$rc|$out|$err", "0|$VERSION\n|", "pwe_image_tag ($what): verze z PWE/VERSION");
        ($rc, $out, $err) = sh($env, $IMAGES_SH, 'pwe_image_version');
        is("$rc|$out|$err", "0|$VERSION\n|", "pwe_image_version ($what): obsah PWE/VERSION");
        ($rc, $out, $err) = sh($env, $IMAGES_SH, 'pwe_tool_image');
        is("$rc|$out", "0|ghcr.io/kukam/pwe-debugger:$VERSION\n", "pwe_tool_image ($what): pwe-debugger:<verze>");
        is(perl_image_tag($env), $VERSION, "ToolEnv::image_tag() ($what) = images.sh pwe_image_tag");
        is(scalar(calls('git')), 0, "tag image ($what): git se nevola (shell ani Perl)");
    }

    # obsah PWE/VERSION: bile znaky se zahodi, verze musi mit tvar X.Y.Z; shell a Perl se shoduji
    my @contents = (
        # [obsah souboru (undef = soubor chybi), ocekavana verze (undef = chyba), popis]
        ["9.8.7\n",          '9.8.7',    'verze s koncem radku'],
        [" 10.20.30 \r\n\n", '10.20.30', 'bile znaky kolem (mezery, CR LF, prazdny radek)'],
        ['0.0.1',            '0.0.1',    'bez konce radku'],
        ["1\t.2.3\n",        '1.2.3',    'bily znak uvnitr se zahodi (jako tr -d [:space:])'],
        ['',                 undef,      'prazdny soubor'],
        ["\n",               undef,      'jen konec radku'],
        ["2.2\n",            undef,      'jen dve casti'],
        ["2.2.1.4\n",        undef,      'ctyri casti'],
        ["v2.2.1\n",         undef,      'predpona v'],
        ["2.2.x\n",          undef,      'pismeno misto cisla'],
        ["2..1\n",           undef,      'prazdna prostredni cast'],
        [".2.1\n",           undef,      'prazdna prvni cast'],
        ["2.2.\n",           undef,      'prazdna posledni cast'],
        ["2.2.1-rc1\n",      undef,      'pripona -rc1'],
        ["2.2.1\nneco\n",    undef,      'druhy radek s textem'],
        ["latest\n",         undef,      'slovo latest'],
        ["feature/kosik\n",  undef,      'nazev vetve'],
        [undef,              undef,      'soubor chybi'],
    );
    my $bad = qr/^Soubor \Q$VERSION_FILE\E neobsahuje verzi enginu tvaru X\.Y\.Z \(obsah: '[^\n]*'\) - verzi image nelze urcit\. .*PWE_IMAGE_TAG=<tag> \(napr\. latest\)\n\z/;
    foreach my $c (@contents) {
        my ($content, $want, $what) = @{$c};
        if (defined($content)) { spit($VERSION_FILE, $content); } else { unlink($VERSION_FILE); }
        my ($rc, $out, $err)    = sh({}, $IMAGES_SH, 'pwe_image_version');
        my ($prc, $pout, $perr) = perl_env({}, 'print PWE::ToolEnv::image_version(), "\n"');
        if (defined($want)) {
            is("$rc|$out|$err", "0|$want\n|", "pwe_image_version ($what): $want");
            is("$prc|$pout|$perr", "0|$want\n|", "ToolEnv::image_version() ($what) = images.sh pwe_image_version");
        }
        else {
            is("$rc|$out", '2|', "pwe_image_version ($what): kod 2, prazdny stdout");
            like($err, $bad, "pwe_image_version ($what): hlaska jmenuje soubor, obsah a radi PWE_IMAGE_TAG");
            ok($prc != 0 && $pout eq '' && $perr eq $err, "ToolEnv::image_version() ($what): die se stejnou hlaskou jako shell") or diag($perr);
        }
    }

    # PWE/VERSION bez verze: vychozi tag urcit nejde (kod 2), vyslovny PWE_IMAGE_TAG a PWE_TEST_IMAGE funguji dal
    spit($VERSION_FILE, "neni-verze\n");
    my ($rc, $out, $err) = sh({}, $IMAGES_SH, 'pwe_image_tag');
    is("$rc|$out", '2|', 'pwe_image_tag: PWE/VERSION bez verze a bez PWE_IMAGE_TAG -> kod 2, prazdny stdout');
    like($err, $bad, 'pwe_image_tag: PWE/VERSION bez verze -> hlaska z pwe_image_version');
    like(perl_image_tag({}), qr/^DIE: Soubor .* neobsahuje verzi enginu tvaru X\.Y\.Z/, 'ToolEnv::image_tag(): PWE/VERSION bez verze -> die');
    ($rc, $out, $err) = sh({}, $IMAGES_SH, 'pwe_image', 'pwe-base');
    is("$rc|$out", '2|', 'pwe_image: PWE/VERSION bez verze -> kod 2 a zadne (neuplne) jmeno image na stdout');
    ($rc, $out, $err) = sh({PWE_IMAGE_TAG => 'latest'}, $IMAGES_SH, 'pwe_image', 'pwe-base');
    is("$rc|$out|$err", "0|ghcr.io/kukam/pwe-base:latest\n|", 'pwe_image: s PWE_IMAGE_TAG se PWE/VERSION necte (rozbity soubor nevadi)');
    is(perl_image_tag({PWE_IMAGE_TAG => 'latest'}), 'latest', 'ToolEnv::image_tag(): s PWE_IMAGE_TAG se PWE/VERSION necte');
    ($rc, $out, $err) = sh({PWE_TEST_IMAGE => 'ghcr.io/kukam/pwe-debugger:pwe.ai'}, $IMAGES_SH, 'pwe_tool_image');
    is("$rc|$out|$err", "0|ghcr.io/kukam/pwe-debugger:pwe.ai\n|", 'pwe_tool_image: PWE_TEST_IMAGE je uplne prepsani - funguje i s rozbitym PWE/VERSION');
    ($rc, $out, $err) = perl_env({PWE_TEST_IMAGE => 'ghcr.io/kukam/pwe-debugger:pwe.ai'}, 'print PWE::ToolEnv::docker_image()');
    is("$rc|$out|$err", '0|ghcr.io/kukam/pwe-debugger:pwe.ai|', 'ToolEnv::docker_image(): PWE_TEST_IMAGE funguje i s rozbitym PWE/VERSION');
    spit($VERSION_FILE, "$VERSION\n");

    # git slouzi uz jen build-images.sh (commit do popisku, necommitnute zmeny): pwe_image_git_repo
    log_reset();
    ($rc, $out, $err) = sh({FAKE_GIT_BRANCH => 'pwe.ai'}, $IMAGES_SH, 'pwe_image_git_repo');
    is($rc, 0, 'pwe_image_git_repo: koren pracovni kopie -> 0');
    is_deeply([calls('git')], [['-C', $REPO, 'rev-parse', '--show-prefix']], 'pwe_image_git_repo: git -C <koren repozitare> rev-parse --show-prefix (na vetev se nepta)');
    ($rc, $out, $err) = sh({FAKE_GIT_BRANCH => 'cizi', FAKE_GIT_PREFIX => 'sub/'}, $IMAGES_SH, 'pwe_image_git_repo');
    isnt($rc, 0, 'pwe_image_git_repo: uvnitr ciziho gitu -> nenulovy kod');
    ($rc, $out, $err) = sh({PATH => $NOGIT_PATH}, $IMAGES_SH, 'pwe_image_git_repo');
    isnt($rc, 0, 'pwe_image_git_repo: bez prikazu git -> nenulovy kod');

    # PWE_IMAGE_TAG ma prednost pred verzi
    log_reset();
    ($rc, $out, $err) = sh({PWE_IMAGE_TAG => 'x_1.2', FAKE_GIT_BRANCH => 'pwe.ai'}, $IMAGES_SH, 'pwe_image_tag');
    is("$rc|$out|$err", "0|x_1.2\n|", 'pwe_image_tag: platny PWE_IMAGE_TAG se vraci beze zmeny');
    is(scalar(calls('git')), 0, 'pwe_image_tag: s PWE_IMAGE_TAG se git nevola');
    is(perl_image_tag({PWE_IMAGE_TAG => 'x_1.2', FAKE_GIT_BRANCH => 'pwe.ai'}), 'x_1.2', 'ToolEnv::image_tag(): platny PWE_IMAGE_TAG');
    ($rc, $out, $err) = sh({PWE_IMAGE_TAG => 'latest'}, $IMAGES_SH, 'pwe_image_tag');
    is("$rc|$out|$err", "0|latest\n|", 'pwe_image_tag: PWE_IMAGE_TAG=latest');
    ($rc, $out, $err) = sh({PWE_IMAGE_TAG => 'latest'}, $IMAGES_SH, 'pwe_image_version');
    is("$rc|$out|$err", "0|$VERSION\n|", 'pwe_image_version: PWE_IMAGE_TAG verzi pracovni kopie nemeni');
    ($rc, $out, $err) = sh({PWE_IMAGE_TAG => ''}, $IMAGES_SH, 'pwe_image_tag');
    is("$rc|$out|$err", "0|$VERSION\n|", 'pwe_image_tag: prazdny PWE_IMAGE_TAG = nenastaveny');

    # neplatny PWE_IMAGE_TAG: hlaska na stderr, nic na stdout, kod 2 (Perl: die se stejnou hlaskou)
    my @invalid = (['feature/kosik', 'lomitko'], ['-x', 'uvodni pomlcka'], ['.x', 'uvodni tecka'], ['a b', 'mezera'], ['a:b', 'dvojtecka'],
        ['x' x 129, '129 znaku'], ["a\nb", 'novy radek'], ["v\xc4\x9btev", 'diakritika']);
    foreach my $c (@invalid) {
        my ($tag, $what) = @{$c};
        ($rc, $out, $err) = sh({PWE_IMAGE_TAG => $tag, FAKE_GIT_BRANCH => 'pwe.ai'}, $IMAGES_SH, 'pwe_image_tag');
        is("$rc|$out", '2|', "pwe_image_tag: neplatny PWE_IMAGE_TAG ($what) -> kod 2, prazdny stdout");
        like($err, qr/\APWE_IMAGE_TAG='.*' neni platny tag image .*tagy <verze> \(obsah PWE\/VERSION\) a latest\.\n\z/s, "pwe_image_tag: neplatny PWE_IMAGE_TAG ($what) -> hlaska, jake tagy image maji");
        unlike($err, qr/sanitize/, "pwe_image_tag: neplatny PWE_IMAGE_TAG ($what) -> hlaska neodkazuje na zrusenou funkci pwe_image_tag_sanitize");
        is(perl_image_tag({PWE_IMAGE_TAG => $tag}), "DIE: $err", "ToolEnv::image_tag(): neplatny PWE_IMAGE_TAG ($what) -> die se stejnou hlaskou jako shell");
    }

    # pravidlo platnosti tagu: shell a Perl se shoduji
    my @tags = (['a', 1], ['_', 1], ['0', 1], ['pwe.ai', 1], ['A-Z_0.9', 1], ['2.1.0', 1], ['latest', 1], ['x' x 128, 1],
        ['', 0], ['.x', 0], ['-x', 0], ['a b', 0], ['a/b', 0], ['a:b', 0], ["a\nb", 0], ["abc\n", 0], ['x' x 129, 0], ["v\xc4\x9btev", 0]);
    foreach my $c (@tags) {
        my ($tag, $valid) = @{$c};
        (my $show = (length($tag) > 20) ? length($tag) . ' znaku' : $tag) =~ s/\n/\\n/g;
        ($rc, $out, $err) = sh({}, $IMAGES_SH, 'pwe_image_tag_valid', $tag);
        is(($rc == 0 ? 1 : 0), $valid, "pwe_image_tag_valid('$show') -> " . ($valid ? 'platny' : 'neplatny'));
        is(PWE::ToolEnv::image_tag_valid($tag), $valid, "ToolEnv::image_tag_valid('$show') = images.sh");
    }

    # funkce pro tag podle vetve zanikly
    foreach my $gone (qw(pwe_image_branch pwe_image_tag_sanitize)) {
        ($rc, $out, $err) = sh({FAKE_GIT_BRANCH => 'feature/kosik'}, $IMAGES_SH, $gone, 'feature/kosik');
        is("$rc|$out", '2|', "images.sh $gone: zrusena funkce -> kod 2, nic na stdout");
    }
    ($rc, $out, $err) = sh({}, '-c', '. "$1"; for f in pwe_image_branch pwe_image_tag_sanitize; do if type "$f" >/dev/null 2>&1; then echo "definovana $f"; fi; done; type pwe_image_version >/dev/null 2>&1 && echo "ma pwe_image_version"', 'x', $IMAGES_SH);
    is($out, "ma pwe_image_version\n", 'images.sh po nacteni (source): definuje pwe_image_version, nedefinuje pwe_image_branch ani pwe_image_tag_sanitize');
}

# ---------------------------------------------------------------------------------------------
# images.sh: pwe_image, pwe_tool_image, chovani pod set -e, CDPATH, zsh, rada pri chybejicim image
# ---------------------------------------------------------------------------------------------
{
    my %git = (FAKE_GIT_BRANCH => 'feature/kosik');    # vetev s lomitkem: na jmena image nesmi mit zadny vliv
    my ($rc, $out, $err) = sh({%git}, $IMAGES_SH, 'pwe_image', 'pwe-mariadb');
    is("$rc|$out", "0|ghcr.io/kukam/pwe-mariadb:$VERSION\n", 'pwe_image pwe-mariadb: vychozi registr, tag = verze enginu');
    ($rc, $out, $err) = sh({%git, PWE_IMAGE_REGISTRY => 'registry.example.test/tym/', PWE_IMAGE_TAG => 'rucni'}, $IMAGES_SH, 'pwe_image', 'pwe-example-static');
    is("$rc|$out", "0|registry.example.test/tym/pwe-example-static:rucni\n", 'pwe_image: PWE_IMAGE_REGISTRY (bez koncoveho lomitka) a PWE_IMAGE_TAG');
    ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => 'a/b'}, $IMAGES_SH, 'pwe_image', 'pwe-base');
    is("$rc|$out", '2|', 'pwe_image: neplatny PWE_IMAGE_TAG -> kod 2 a zadne (neuplne) jmeno image na stdout');

    ($rc, $out, $err) = sh({%git}, $IMAGES_SH, 'pwe_tool_image');
    is("$rc|$out", "0|ghcr.io/kukam/pwe-debugger:$VERSION\n", 'pwe_tool_image: vychozi image nastroju je pwe-debugger:<verze>');
    ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => 'latest'}, $IMAGES_SH, 'pwe_tool_image');
    is("$rc|$out", "0|ghcr.io/kukam/pwe-debugger:latest\n", 'pwe_tool_image: PWE_IMAGE_TAG=latest');
    ($rc, $out, $err) = sh({%git, PWE_TEST_IMAGE => 'ghcr.io/kukam/pwe-base:jina', PWE_IMAGE_TAG => 'a/b'}, $IMAGES_SH, 'pwe_tool_image');
    is("$rc|$out", "0|ghcr.io/kukam/pwe-base:jina\n", 'pwe_tool_image: PWE_TEST_IMAGE ma prednost (PWE_IMAGE_TAG se pak nepouzije ani nekontroluje)');
    ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => 'a/b'}, $IMAGES_SH, 'pwe_tool_image');
    is("$rc|$out", '2|', 'pwe_tool_image: neplatny PWE_IMAGE_TAG -> kod 2, prazdny stdout');

    # prirazeni IMAGE="$(pwe_tool_image)" pod set -e skonci a hlaska je videt
    ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => 'a/b'}, '-c', 'set -e; . "$1"; IMAGE="$(pwe_tool_image)"; echo "DOSLO $IMAGE"', 'x', $IMAGES_SH);
    is($rc, 2, 'set -e + IMAGE="$(pwe_tool_image)": neplatny PWE_IMAGE_TAG ukonci skript kodem 2');
    unlike($out, qr/DOSLO/, 'set -e + IMAGE="$(pwe_tool_image)": skript za prirazenim nepokracuje');
    like($err, qr/PWE_IMAGE_TAG='a\/b' neni platny tag image/, 'set -e + IMAGE="$(pwe_tool_image)": hlaska je na stderr');

    # seznam image: 5 zavislostnich (jen knihovny) + 4 image vzorovych webu; zrusene image pwe a pwe-static v nem nejsou.
    # Stav gitu ani PWE_IMAGE_TAG na nej nemaji vliv.
    my @deps     = qw(pwe-base pwe-mariadb pwe-mysql pwe-postgres pwe-debugger);
    my @examples = qw(pwe-example-static pwe-example-mariadb pwe-example-mysql pwe-example-postgres);
    foreach my $c ([[], [@deps, @examples], 'bez argumentu vsech 9 (zavislostni pred vzorovymi)'], [['all'], [@deps, @examples], 'all'], [['deps'], \@deps, 'deps'], [['examples'], \@examples, 'examples']) {
        ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => 'a/b'}, $IMAGES_SH, 'pwe_image_names', @{$c->[0]});
        is("$rc|$out|$err", '0|' . join('', map { "$_\n" } @{$c->[1]}) . '|', "pwe_image_names ($c->[2])");
    }
    ($rc, $out, $err) = sh({}, $IMAGES_SH, 'pwe_image_names', 'profily');
    is("$rc|$out", '2|', 'pwe_image_names: neznama skupina -> kod 2, nic na stdout');
    like($err, qr/^Neznama skupina image 'profily' \(deps \| examples \| all\)$/, 'pwe_image_names: neznama skupina -> hlaska');
    is_deeply([PWE::ToolEnv::image_names()], [@deps, @examples], 'ToolEnv::image_names() = images.sh pwe_image_names');
    # zavislostni image profilu: profil static (web bez databaze) bezi nad pwe-base, databazove profily nad pwe-<profil>
    foreach my $c (['static', 'pwe-base'], ['mariadb', 'pwe-mariadb'], ['mysql', 'pwe-mysql'], ['postgres', 'pwe-postgres']) {
        ($rc, $out, $err) = sh({%git}, $IMAGES_SH, 'pwe_profile_image', $c->[0]);
        is("$rc|$out|$err", "0|$c->[1]\n|", "pwe_profile_image $c->[0] -> $c->[1]");
        is(PWE::ToolEnv::profile_image($c->[0]), $c->[1], "ToolEnv::profile_image($c->[0]) = images.sh pwe_profile_image");
    }
    foreach my $bad ('', 'Static', 'oracle', 'base', 'pwe-static', 'static mariadb') {
        ($rc, $out, $err) = sh({%git}, $IMAGES_SH, 'pwe_profile_image', $bad);
        is("$rc|$out", '2|', "pwe_profile_image '$bad': neznamy profil -> kod 2, nic na stdout");
        is($err, "Neznamy profil '$bad' (static | mariadb | mysql | postgres)\n", "pwe_profile_image '$bad': hlaska se seznamem profilu");
        ok(!defined(eval { PWE::ToolEnv::profile_image($bad) }) && $@ eq $err, "ToolEnv::profile_image('$bad'): die se stejnou hlaskou jako shell");
    }
    ($rc, $out, $err) = sh({%git}, '-c', 'set -e; . "$1"; IMAGE="$(pwe_image "$(pwe_profile_image oracle)")"; echo "DOSLO $IMAGE"', 'x', $IMAGES_SH);
    ok($rc != 0 && $out !~ /DOSLO/, 'set -e + pwe_image "$(pwe_profile_image <neznamy>)": skript skonci (zadne jmeno image z neznameho profilu)') or diag("rc=$rc out=$out");

    # neznama funkce pri primem spusteni
    ($rc, $out, $err) = sh({}, $IMAGES_SH, 'neznama_funkce');
    is($rc, 2, 'images.sh <neznama funkce>: kod 2');
    like($err, qr/pwe_image_version.*pwe_image_names.*pwe_profile_image.*pwe_image_missing_hint/s, 'images.sh <neznama funkce>: napoveda jmenuje i pwe_image_version, pwe_image_names a pwe_profile_image');
    unlike($err, qr/pwe_image_branch|pwe_image_tag_sanitize/, 'images.sh <neznama funkce>: napoveda nejmenuje zrusene funkce');

    # exportovany CDPATH nesmi zmenit koren repozitare (cd by cilovy adresar vypsal na stdout a soubor
    # PWE/VERSION by se nenasel)
    log_reset();
    ($rc, $out, $err) = run_cmd({env => {%git, CDPATH => "$T:."}, cwd => $T}, $BASH, 'repo/PWE/tools/lib/images.sh', 'pwe_image_tag');
    is("$rc|$out|$err", "0|$VERSION\n|", 'images.sh s exportovanym CDPATH: verze z PWE/VERSION kopie (koren repozitare se urci spravne)');
    log_reset();
    run_cmd({env => {%git, CDPATH => "$T:."}, cwd => $T}, $BASH, 'repo/PWE/tools/lib/images.sh', 'pwe_image_git_repo');
    is(((calls('git'))[0] || [])->[1], $REPO, 'images.sh s exportovanym CDPATH: koren repozitare je jedna cesta');
    foreach my $tool (qw(run-tests.sh perl-compile.sh)) {
        log_reset();
        ($rc, $out, $err) = run_cmd({env => {%git, CDPATH => "$T:."}, cwd => $T}, $BASH, "repo/PWE/tools/$tool");
        is($rc, 0, "$tool s exportovanym CDPATH: probehne") or diag($err);
        ok(has_pair(((calls('docker', 'run'))[0] || []), '-v', "$REPO:/PWE"), "$tool s exportovanym CDPATH: mount korene repozitare");
    }

  SKIP: {
        my ($zsh) = grep { -x $_ } map { "$_/zsh" } grep { length } split(/:/, $SYS_PATH);
        skip 'zsh neni k dispozici (v kontejneru; nacteni ze zsh se overuje na hostiteli)', 3 unless ($zsh);
        ($rc, $out, $err) = run_cmd({env => {%git}}, $zsh, '-c', '. "$1"; pwe_image_tag; pwe_image pwe-base; pwe_image_tag_valid "a/b" || echo neplatny', 'x', $IMAGES_SH);
        is("$rc|$out", "0|$VERSION\nghcr.io/kukam/pwe-base:$VERSION\nneplatny\n", 'images.sh nactene ze zsh: verze z PWE/VERSION, pwe_image, pwe_image_tag_valid');
        is($err, '', 'images.sh nactene ze zsh: bez chyb na stderr');
        ($rc, $out, $err) = run_cmd({env => {%git}, cwd => $T}, $zsh, '-f', '-i', '-c', '. repo/PWE/tools/lib/images.sh; pwe_image_tag');
        is("$rc|$out", "0|$VERSION\n", 'images.sh nactene z interaktivniho zsh relativni cestou: verze z PWE/VERSION kopie');
    }

    # rada pri chybejicim image: shell pwe_image_missing_hint i Perl _image_missing_note
    my $note = sub {
        my ($env, $image) = @_;
        local %ENV = (%BASE_ENV, %{$env});
        return PWE::ToolEnv::_image_missing_note($image);
    };
    my $image = 'ghcr.io/kukam/pwe-debugger:9.9.9';
    log_reset();
    ($rc, $out, $err) = sh({FAKE_DOCKER_INSPECT_RC => 0}, $IMAGES_SH, 'pwe_image_missing_hint', $image, 'run-tests');
    is("$rc|$out|$err", '0||', 'pwe_image_missing_hint: image je v lokalnim Dockeru -> nic nevypise');
    is_deeply([calls('docker')], [['image', 'inspect', $image]], 'pwe_image_missing_hint: pta se docker image inspect <image>');
    is($note->({FAKE_DOCKER_INSPECT_RC => 0}, $image), '', 'ToolEnv::_image_missing_note: image je v lokalnim Dockeru -> prazdny retezec');

    my %missing = (FAKE_DOCKER_INSPECT_RC => 1, FAKE_DOCKER_TAGS => 'latest <none> 9.8.6 latest');
    log_reset();
    ($rc, $out, $err) = sh({%missing}, $IMAGES_SH, 'pwe_image_missing_hint', $image, 'run-tests');
    is("$rc|$out", '0|', 'pwe_image_missing_hint: chybejici image -> kod 0 (jen rada), nic na stdout');
    like($err, qr/^\[run-tests\] image \Q$image\E neni v lokalnim Dockeru, docker ho zkusi stahnout z registru/, 'pwe_image_missing_hint: image neni v lokalnim Dockeru a docker ho zkusi stahnout');
    like($err, qr/^\[run-tests\]   sestaveni: make images ARGS=debugger \(PWE\/tools\/build-images\.sh debugger\)$/m, 'pwe_image_missing_hint: image PWE -> nabizi make images s cilem (jmeno image bez predpony pwe-)');
    like($err, qr{^\[run-tests\] .*tagy ghcr\.io/kukam/pwe-debugger: 9\.8\.6 latest \(pouziti: PWE_IMAGE_TAG=<tag>\)$}m, 'pwe_image_missing_hint: mistne dostupne tagy tehoz repozitare (serazene, bez <none> a opakovani)');
    unlike($err, qr/PWE_IMAGE_TAG=(?:master|latest)\b/, 'pwe_image_missing_hint: zadne slepe doporuceni konkretniho tagu');
    is_deeply((calls('docker', 'image'))[-1], ['image', 'ls', '--format', '{{.Tag}}', 'ghcr.io/kukam/pwe-debugger'], 'pwe_image_missing_hint: tagy z docker image ls <repozitar>');
    ($rc, $out, $err) = sh({%missing}, $IMAGES_SH, 'pwe_image_missing_hint', $image);
    is($note->({%missing}, $image), $err, 'ToolEnv::_image_missing_note = pwe_image_missing_hint (mistni tagy)');

    ($rc, $out, $err) = sh({FAKE_DOCKER_INSPECT_RC => 1}, $IMAGES_SH, 'pwe_image_missing_hint', 'localhost:5000/tym/pwe-debugger:x');
    like($err, qr{^\[tools\] .*neni zadny image localhost:5000/tym/pwe-debugger$}m, 'pwe_image_missing_hint: bez mistnich tagu to rekne (repozitar = jmeno bez tagu, port registru zustava)');
    is($note->({FAKE_DOCKER_INSPECT_RC => 1}, 'localhost:5000/tym/pwe-debugger:x'), $err, 'ToolEnv::_image_missing_note = pwe_image_missing_hint (zadny mistni tag)');

    # cil sestaveni v rade = jmeno image bez predpony pwe- (pro kazdy z 9 image); cizi image dostane obecnou radu
    foreach my $name (PWE::ToolEnv::image_names()) {
        (my $target = $name) =~ s/^pwe-//;
        ($rc, $out, $err) = sh({%missing}, $IMAGES_SH, 'pwe_image_missing_hint', "registry.example.test/tym/$name:$VERSION", 'run-webapp');
        like($err, qr/^\[run-webapp\]   sestaveni: make images ARGS=\Q$target\E \(PWE\/tools\/build-images\.sh \Q$target\E\)$/m, "pwe_image_missing_hint $name: rada jmenuje cil $target");
        is($note->({%missing}, "registry.example.test/tym/$name:$VERSION") =~ s/^\[tools\]/[run-webapp]/mgr, $err, "ToolEnv::_image_missing_note = pwe_image_missing_hint ($name)");
    }
    foreach my $other ('registry.example.test/tym/muj-nastroj:1', 'ghcr.io/kukam/pwe-debugger-extra:1', 'pwe-base-x') {
        ($rc, $out, $err) = sh({%missing}, $IMAGES_SH, 'pwe_image_missing_hint', $other);
        like($err, qr/^\[tools\]   sestaveni: make images \(PWE\/tools\/build-images\.sh\)$/m, "pwe_image_missing_hint $other: image, ktery neni image PWE -> obecna rada make images (bez cile)");
        is($note->({%missing}, $other), $err, "ToolEnv::_image_missing_note = pwe_image_missing_hint ($other)");
    }
    # zrusene image (starsi usporadani): misto rady k sestaveni vysvetleni, co je nahrazuje
    foreach my $c (['ghcr.io/kukam/pwe-static:2.2.1', qr/image pwe-static byl zrusen: web bez databaze bezi nad pwe-base, vzorovy web bez databaze je image pwe-example-static/],
        ['ghcr.io/kukam/pwe:latest', qr/image pwe byl zrusen: engine se do image webu kopiruje z repozitare \(webapps\/<web>\/Dockerfile\)/], ['localhost:5000/pwe-static', qr/image pwe-static byl zrusen/])
    {
        my ($gone, $re) = @{$c};
        ($rc, $out, $err) = sh({%missing}, $IMAGES_SH, 'pwe_image_missing_hint', $gone, 'run-tests');
        like($err, qr/^\[run-tests\]   $re/m, "pwe_image_missing_hint $gone: zruseny image -> rada rika, ze byl zrusen a co ho nahrazuje");
        unlike($err, qr/sestaveni: make images/, "pwe_image_missing_hint $gone: zruseny image -> zadna rada k sestaveni (sestavit ho uz nejde)");
        is($note->({%missing}, $gone) =~ s/^\[tools\]/[run-tests]/mgr, $err, "ToolEnv::_image_missing_note = pwe_image_missing_hint ($gone)");
    }

    my %test_image = (%missing, PWE_TEST_IMAGE => 'ghcr.io/kukam/pwe-base:nic');
    ($rc, $out, $err) = sh({%test_image}, $IMAGES_SH, 'pwe_image_missing_hint', 'ghcr.io/kukam/pwe-base:nic');
    like($err, qr{\(pouziti: PWE_TEST_IMAGE=ghcr\.io/kukam/pwe-base:<tag>\)$}m, 'pwe_image_missing_hint: u image z PWE_TEST_IMAGE radi PWE_TEST_IMAGE, ne PWE_IMAGE_TAG');
    is($note->({%test_image}, 'ghcr.io/kukam/pwe-base:nic'), $err, 'ToolEnv::_image_missing_note = pwe_image_missing_hint (PWE_TEST_IMAGE)');

    # Perl nastroje: ensure_modules() se pri chybejicim modulu spusti znovu v kontejneru image nastroju
    # a preda mu registr a tag. Skript pouziva PWE::ToolEnv z kopie v docasnem stromu (tag = tamni verze)
    # a in_container() si nahrazuje - test sam bezi v kontejneru, kde by se ensure_modules() znovu nespustil.
    my $tool = "$T/tool.pl";
    spit($tool, <<'EOS');
use strict;
use warnings;
use PWE::ToolEnv qw(ensure_modules);
{ no warnings 'redefine'; *PWE::ToolEnv::in_container = sub { return 0; }; }
ensure_modules('PWE::Tento::Modul::Neexistuje');
print "POKRACUJE NA HOSTITELI\n";
EOS
    my $tool_lib = "$REPO/PWE/tools/lib";
    my $tool_img = "registry.example.test/tym/pwe-debugger:$VERSION";
    log_reset();
    ($rc, $out, $err) = run_cmd({env => {%git, PWE_IMAGE_REGISTRY => 'registry.example.test/tym/', FAKE_DOCKER_INSPECT_RC => 1, FAKE_DOCKER_RUN_RC => 6}}, $^X, "-I$tool_lib", $tool, '--volba', 'hodnota');
    is($rc, 6, 'ensure_modules: skript skonci s navratovym kodem behu v kontejneru');
    unlike($out, qr/POKRACUJE/, 'ensure_modules: na hostiteli skript nepokracuje');
    my @em = @{(calls('docker', 'run'))[0] || []};
    is_deeply([@em[0 .. 3]], ['run', '--rm', '--entrypoint', 'perl'], 'ensure_modules: docker run --rm --entrypoint perl');
    ok(has_pair(\@em, '-v', "$REPO:/PWE") && has_pair(\@em, '-w', '/PWE') && has_pair(\@em, '-e', 'PWE_TOOLS_IN_DOCKER=1'), 'ensure_modules: mount korene repozitare do /PWE, pracovni adresar /PWE, PWE_TOOLS_IN_DOCKER=1');
    ok(has_pair(\@em, '-e', 'PWE_IMAGE_REGISTRY=registry.example.test/tym') && has_pair(\@em, '-e', "PWE_IMAGE_TAG=$VERSION"), 'ensure_modules: do kontejneru preda registr a tag (verze enginu)');
    ok(has_pair(\@em, $tool_img, '-I/PWE/PWE/tools/lib'), 'ensure_modules: image nastroju podle registru a verze, moduly z /PWE/PWE/tools/lib');
    is_deeply([@em[-3 .. -1]], [$tool, '--volba', 'hodnota'], 'ensure_modules: tentyz skript se stejnymi argumenty');
    like($err, qr/^\[tools\] image \Q$tool_img\E neni v lokalnim Dockeru/m, 'ensure_modules: rada pri chybejicim image');
    is(scalar(calls('git')), 0, 'ensure_modules: git se nevola (tag image na vetvi nezavisi)');
    log_reset();
    ($rc, $out, $err) = run_cmd({env => {%git, PWE_IMAGE_TAG => 'latest'}}, $^X, "-I$tool_lib", $tool);
    @em = @{(calls('docker', 'run'))[0] || []};
    ok(has_pair(\@em, 'ghcr.io/kukam/pwe-debugger:latest', '-I/PWE/PWE/tools/lib') && has_pair(\@em, '-e', 'PWE_IMAGE_TAG=latest'), 'ensure_modules: PWE_IMAGE_TAG=latest urci image nastroju a preda se do kontejneru');
    log_reset();
    ($rc, $out, $err) = run_cmd({env => {%git, PWE_TEST_IMAGE => 'ghcr.io/kukam/pwe-base:jina'}}, $^X, "-I$tool_lib", $tool);
    @em = @{(calls('docker', 'run'))[0] || []};
    ok(has_pair(\@em, 'ghcr.io/kukam/pwe-base:jina', '-I/PWE/PWE/tools/lib') && has_pair(\@em, '-e', 'PWE_TEST_IMAGE=ghcr.io/kukam/pwe-base:jina'), 'ensure_modules: PWE_TEST_IMAGE prepise image nastroju a preda se do kontejneru');
    # PWE_TEST_IMAGE = uplne prepsani: tag se nezjistuje ani nekontroluje (neplatny PWE_IMAGE_TAG, rozbity PWE/VERSION)
    spit($VERSION_FILE, "neni-verze\n");
    log_reset();
    ($rc, $out, $err) = run_cmd({env => {%git, PWE_TEST_IMAGE => 'ghcr.io/kukam/pwe-base:jina', PWE_IMAGE_TAG => 'a/b', FAKE_DOCKER_RUN_RC => 0}}, $^X, "-I$tool_lib", $tool);
    @em = @{(calls('docker', 'run'))[0] || []};
    ok($rc == 0 && has_pair(\@em, 'ghcr.io/kukam/pwe-base:jina', '-I/PWE/PWE/tools/lib'), 'ensure_modules: s PWE_TEST_IMAGE bezi i s neplatnym PWE_IMAGE_TAG a rozbitym PWE/VERSION') or diag($err);
    ok(!scalar(grep { /^PWE_IMAGE_TAG=/ } @em), 'ensure_modules: s PWE_TEST_IMAGE se PWE_IMAGE_TAG do kontejneru nepredava');
    log_reset();
    ($rc, $out, $err) = run_cmd({env => {%git}}, $^X, "-I$tool_lib", $tool);
    isnt($rc, 0, 'ensure_modules: rozbity PWE/VERSION bez PWE_IMAGE_TAG a PWE_TEST_IMAGE -> chyba');
    like($err, qr/neobsahuje verzi enginu tvaru X\.Y\.Z/, 'ensure_modules: rozbity PWE/VERSION -> hlaska');
    is(scalar(calls('docker', 'run')), 0, 'ensure_modules: rozbity PWE/VERSION -> docker run se nespusti');
    spit($VERSION_FILE, "$VERSION\n");
    log_reset();
    ($rc, $out, $err) = run_cmd({env => {%git, PWE_IMAGE_TAG => 'a/b'}}, $^X, "-I$tool_lib", $tool);
    isnt($rc, 0, 'ensure_modules: neplatny PWE_IMAGE_TAG -> chyba');
    like($err, qr/PWE_IMAGE_TAG='a\/b' neni platny tag image/, 'ensure_modules: neplatny PWE_IMAGE_TAG -> hlaska');
    is(scalar(calls('docker', 'run')), 0, 'ensure_modules: neplatny PWE_IMAGE_TAG -> docker run se nespusti');
}

# ---------------------------------------------------------------------------------------------
# build-images.sh: image dostavaji tagy <verze> (PWE/VERSION) a latest - bake dostane jen VERSION, zadny
# tag; na vetvi gitu sestaveni ani publikace nezavisi (pojistky kolem vetve a tagu tvaru verze zanikly)
# ---------------------------------------------------------------------------------------------
{
    my $build = "$REPO/PWE/tools/build-images.sh";
    my %git   = (FAKE_GIT_BRANCH => 'pwe.ai');    # cisty strom na vetvi pwe.ai
    my ($rc, $out, $err);

    # mistni build: vsechny cile, promenne pro docker-bake.hcl
    log_reset();
    ($rc, $out, $err) = sh({%git}, $build);
    is($rc, 0, 'build-images.sh: mistni build skonci 0') or diag($err);
    is_deeply(bake_args(), ['-f', 'docker-bake.hcl', '--load'], 'build-images.sh: docker buildx bake -f docker-bake.hcl --load (bez cile = vsechny)');
    my $env = call_env();
    is($env->{'REGISTRIES'}, 'ghcr.io/kukam', 'build-images.sh: REGISTRIES = vychozi registr');
    is($env->{'VERSION'},    $VERSION,        'build-images.sh: VERSION = obsah PWE/VERSION (bez bilych znaku)');
    is($env->{'TAG'},        '<unset>',       'build-images.sh: promenna TAG se bake nepredava (tagy <verze> a latest urcuje docker-bake.hcl z VERSION)');
    is($env->{'REVISION'},   $HEAD,           'build-images.sh: REVISION = commit (cisty strom)');
    like($env->{'CREATED'}, qr/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/, 'build-images.sh: CREATED ve tvaru RFC 3339 (UTC)');
    is($env->{'SOURCE'}, '<unset>', 'build-images.sh: SOURCE se bez PWE_IMAGE_SOURCE nepredava (plati vychozi z docker-bake.hcl)');
    is($env->{'CWD'},    $REPO,     'build-images.sh: bake bezi z korene repozitare');
    like($err, qr/^\[build-images\] registr=ghcr\.io\/kukam tagy=\Q$VERSION\E,latest /m, 'build-images.sh: uvodni radek jmenuje oba tagy (<verze>, latest)');
    unlike($err, qr/POZOR/, 'build-images.sh na vetvi: zadne varovani');
    is(scalar(grep { $_->[2] eq 'symbolic-ref' } calls('git')), 0, 'build-images.sh: na vetev gitu se nepta');
    my @listed = map { ('--filter', "reference=ghcr.io/kukam/$_:$VERSION", '--filter', "reference=ghcr.io/kukam/$_:latest") } PWE::ToolEnv::image_names();
    is_deeply((calls('docker', 'image'))[-1], ['image', 'ls', '--format', '{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}', @listed],
        'build-images.sh: po nacteni vypise mistni image s tagy <verze> a latest - prave 9 image PWE (zadny zastupny znak, ktery by vypsal i zbytky zrusenych image)');

    # cile = jmena image bez predpony pwe- (lze psat i cele jmeno image)
    log_reset();
    ($rc, $out, $err) = sh({%git, FAKE_GIT_DIRTY => ' M PWE/pwe.fcgi'}, $build, 'example-static', 'debugger', 'pwe-base', 'pwe-example-mysql');
    is($rc, 0, 'build-images.sh: mistni build s necommitnutymi zmenami je v poradku');
    is_deeply(bake_args(), ['-f', 'docker-bake.hcl', '--load', 'example-static', 'debugger', 'base', 'example-mysql'], 'build-images.sh: vybrane cile (i s predponou pwe-)');
    is(call_env()->{'REVISION'}, '', 'build-images.sh: s necommitnutymi zmenami je REVISION prazdna');
    log_reset();
    ($rc, $out, $err) = sh({%git}, $build, map { s/^pwe-//r } PWE::ToolEnv::image_names());
    is_deeply(bake_args(), ['-f', 'docker-bake.hcl', '--load', qw(base mariadb mysql postgres debugger example-static example-mariadb example-mysql example-postgres)],
        'build-images.sh: cilem je kazdy z 9 image (5 zavislostnich, 4 vzorove weby)') or diag($err);

    # vzorovy cil bez sveho zakladu mezi cili: zaklad se sestavi jen jako zavislost a neulozi se - skript na to upozorni
    my $unsaved = qr/^\[build-images\] cil (\S+): zaklad (\S+) se sestavi z pracovni kopie, ale neulozi se \(neni mezi cili\) - mistni \S+:\Q$VERSION\E zustava beze zmeny; oba: \S+build-images\.sh (\S+) (\S+)$/m;
    ($rc, $out, $err) = sh({%git}, $build, 'example-static', 'pwe-example-postgres', 'mysql', 'example-mysql');
    is_deeply([map { [split(/ /, $_)] } ($err =~ /^\[build-images\] cil (\S+: zaklad \S+) se sestavi/mg)], [['example-static:', 'zaklad', 'pwe-base'], ['example-postgres:', 'zaklad', 'pwe-postgres']],
        'build-images.sh: vzorovy cil bez zakladu mezi cili -> upozorneni, ze se zaklad neulozi (example-static -> pwe-base, example-postgres -> pwe-postgres; example-mysql ma zaklad mezi cili)') or diag($err);
    like($err, qr/^\[build-images\] cil example-static: zaklad pwe-base se sestavi z pracovni kopie, ale neulozi se \(neni mezi cili\) - mistni pwe-base:\Q$VERSION\E zustava beze zmeny; oba: \S+build-images\.sh base example-static$/m, 'build-images.sh: upozorneni radi sestavit zaklad i vzorovy cil');
    foreach my $c ([[], 'bez cile (vsechny)'], [['base', 'example-static'], 'zaklad i vzorovy cil'], [['mariadb', 'debugger'], 'jen zavislostni image'], [['--print', 'example-static'], '--print (nic se nestavi)'],
        [['--print', '--push', 'example-static'], '--print --push (nic se nepublikuje)'], [['--platform', 'linux/amd64', 'example-static'], 'zkusebni build bez nacteni (nic se neuklada)'])
    {
        ($rc, $out, $err) = sh({%git}, $build, @{$c->[0]});
        unlike($err, qr/se sestavi z pracovni kopie, ale neulozi se/, "build-images.sh ($c->[1]): zadne upozorneni na neulozeny zaklad");
    }
    ($rc, $out, $err) = sh({%git}, $build, '--push', 'example-mariadb');
    like($err, qr/^\[build-images\] cil example-mariadb: zaklad pwe-mariadb se sestavi z pracovni kopie, ale neulozi se /m, 'build-images.sh --push jen vzoroveho cile: upozorneni, ze se zaklad nepublikuje');

    log_reset();
    ($rc, $out, $err) = sh({%git}, $build, 'pwe-foo');
    is($rc, 2, 'build-images.sh: neznamy cil -> kod 2');
    ok(!defined(bake_args()), 'build-images.sh: neznamy cil -> bake se nespusti');
    like($err, qr/^Neznamy cil pwe-foo \(cile: base mariadb mysql postgres debugger example-static example-mariadb example-mysql example-postgres\)$/, 'build-images.sh: neznamy cil -> hlaska vyjmenuje 9 cilu');
    # cile zrusene pri prestavbe image: odmitnuti s vysvetlenim, co je nahrazuje
    foreach my $c (['pwe', qr/^Cil pwe \(image pwe = jen engine\) byl zrusen: engine se do image webu kopiruje z repozitare/], ['static', qr/^Cil static \(image pwe-static\) byl zrusen: web bez databaze bezi nad pwe-base \(cil base\), vzorovy web bez databaze je cil example-static/],
        ['pwe-static', qr/^Cil static \(image pwe-static\) byl zrusen/])
    {
        log_reset();
        ($rc, $out, $err) = sh({%git}, $build, 'base', $c->[0]);
        is($rc, 2, "build-images.sh $c->[0]: zruseny cil -> kod 2");
        like($err, $c->[1], "build-images.sh $c->[0]: zruseny cil -> hlaska rika, ze byl zrusen a co ho nahrazuje");
        ok(!defined(bake_args()), "build-images.sh $c->[0]: zruseny cil -> bake se nespusti");
    }

    log_reset();
    ($rc, $out, $err) = sh({%git}, $build, '--print', 'base');
    is_deeply(bake_args(), ['-f', 'docker-bake.hcl', '--print', 'base'], 'build-images.sh --print: jen vypis (bez --load a --push)');

    ($rc, $out, $err) = sh({%git}, $build, '--help');
    is($rc, 0, 'build-images.sh --help: kod 0');
    like($out, qr/--allow-dirty.*--platform.*PWE_IMAGE_REGISTRIES/s, 'build-images.sh --help: popisuje --allow-dirty, --platform i PWE_IMAGE_REGISTRIES');
    like($out, qr/^  base mariadb mysql postgres debugger\n\s+zavislostni image pwe-base, pwe-mariadb, pwe-mysql, pwe-postgres, pwe-debugger: jen knihovny,\n\s+zadny kod enginu a zadny web$/m, 'build-images.sh --help: vyjmenuje cile zavislostnich image (jen knihovny, zadny kod enginu, zadny web)');
    like($out, qr/^  example-static example-mariadb example-mysql example-postgres\n\s+image vzorovych webu pwe-example-\*: zavislostni image \+ engine \+ vzorovy web/m, 'build-images.sh --help: vyjmenuje cile image vzorovych webu');
    like($out, qr/Vzorovy cil si svuj\s+zaklad sestavi sam/, 'build-images.sh --help: vzorovy cil si zaklad sestavi sam (zavislost v docker-bake.hcl)');
    unlike($out, qr/pwe-static|\bimage pwe(?![\w.-])|vsech 7/, 'build-images.sh --help: zadna zminka o zrusenych image pwe a pwe-static ani o 7 image');
    like($out, qr/<verze> \(obsah PWE\/VERSION[^\n]*\) a latest/, 'build-images.sh --help: popisuje tagy <verze> a latest');
    like($out, qr/--push\s[^\n]*\n\s+POZOR - ZADNA POJISTKA VETVE \(zamer\): rucni --push z LIBOVOLNE vetve i z odpojeneho HEAD\s+prepise v registru tagy <verze> i latest/, 'build-images.sh --help: u --push zretelne rika, ze nema pojistku vetve a prepise tagy <verze> i latest');
    like($out, qr/hlida jen\s+pipeline \(\.github\/workflows\/images\.yml[^)]*PUBLISH_BRANCHES\)/, 'build-images.sh --help: kdo smi publikovat, hlida jen pipeline (vychozi vetev a PUBLISH_BRANCHES)');
    unlike($out, qr/vetev gitu\)|tag master|X\.Y\.Z \(ani jako nazev vetve\)/, 'build-images.sh --help: zadne zbytky tagu podle vetve (vychozi tag = vetev, tag master, zakaz tagu tvaru verze)');

    # na stavu gitu mistni build nezavisi: zadna vetev, zadny git - stejne tagy, zadne varovani o vetvi
    foreach my $c ([{FAKE_GIT_BRANCH => ''}, 'odpojeny HEAD'], [{FAKE_GIT_BRANCH => 'feature/kosik'}, 'vetev s lomitkem'], [{FAKE_GIT_BRANCH => '10.20.30'}, 'vetev tvaru verze'],
        [{FAKE_GIT_BRANCH => 'cizi', FAKE_GIT_PREFIX => 'sub/'}, 'kopie uvnitr ciziho gitu'], [{PATH => $NOGIT_PATH}, 'bez prikazu git'])
    {
        log_reset();
        ($rc, $out, $err) = sh($c->[0], $build);
        is("$rc|" . (call_env()->{'VERSION'} || '') . '|' . (call_env()->{'TAG'} || ''), "0|$VERSION|<unset>", "build-images.sh ($c->[1]): mistni build stavi tagy <verze> a latest");
        unlike($err, qr/POZOR|vetev|master/, "build-images.sh ($c->[1]): zadne varovani o vetvi ani tag master");
    }

    # PWE_IMAGE_TAG vybira image pro nastroje, sestaveni ho nepouziva (jen na to upozorni)
    foreach my $tag ('2.1.0', 'master', 'feature/kosik') {
        log_reset();
        ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => $tag}, $build, '--print');
        is("$rc|" . (call_env()->{'VERSION'} || '') . '|' . (call_env()->{'TAG'} || ''), "0|$VERSION|<unset>", "build-images.sh s PWE_IMAGE_TAG=$tag: stavi dal tagy <verze> a latest");
        like($err, qr/^\[build-images\] PWE_IMAGE_TAG=\Q$tag\E se pri sestaveni nepouziva: image dostanou tagy \Q$VERSION\E \(PWE\/VERSION\) a latest$/m, "build-images.sh s PWE_IMAGE_TAG=$tag: upozorni, ze se tag pri sestaveni nepouziva");
    }
    foreach my $tag ($VERSION, 'latest') {
        ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => $tag}, $build, '--print');
        unlike($err, qr/se pri sestaveni nepouziva/, "build-images.sh s PWE_IMAGE_TAG=$tag: tag, ktery sestaveni vyrobi - bez upozorneni");
    }

    # verze: PWE/VERSION musi obsahovat verzi tvaru X.Y.Z, jinak se nic nestavi
    foreach my $c (["2.2\n", 'jen dve casti'], ["vyvoj\n", 'text'], ['', 'prazdny soubor'], [undef, 'soubor chybi']) {
        if (defined($c->[0])) { spit($VERSION_FILE, $c->[0]); } else { unlink($VERSION_FILE); }
        foreach my $args ([], ['--print'], ['--push']) {
            log_reset();
            ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => 'latest'}, $build, @{$args});
            ok($rc == 2 && !defined(bake_args()) && $err =~ /neobsahuje verzi enginu tvaru X\.Y\.Z/, "build-images.sh @{$args}: PWE/VERSION bez verze ($c->[1]) -> kod 2, hlaska, bake se nespusti (ani s PWE_IMAGE_TAG)") or diag("rc=$rc\n$err");
        }
    }
    spit($VERSION_FILE, "$VERSION\n");

    # registry: normalizace a kontrola
    log_reset();
    ($rc, $out, $err) = sh({%git, PWE_IMAGE_REGISTRIES => ' ghcr.io/kukam/ , ,docker.io/kukam// ', PWE_IMAGE_REGISTRY => 'ignorovan.test/x'}, $build, '--print');
    is(call_env()->{'REGISTRIES'}, 'ghcr.io/kukam,docker.io/kukam', 'build-images.sh: PWE_IMAGE_REGISTRIES bez mezer, prazdnych polozek a koncovych lomitek (prednost pred PWE_IMAGE_REGISTRY)');
    log_reset();
    ($rc, $out, $err) = sh({%git, PWE_IMAGE_REGISTRY => 'localhost:5000/tym/', PWE_IMAGE_SOURCE => 'https://example.test/repo'}, $build, '--print');
    is(call_env()->{'REGISTRIES'}, 'localhost:5000/tym', 'build-images.sh: PWE_IMAGE_REGISTRY (registr s portem, bez koncoveho lomitka)');
    is(call_env()->{'SOURCE'}, 'https://example.test/repo', 'build-images.sh: PWE_IMAGE_SOURCE -> SOURCE');
    foreach my $c ([' , ', 'prazdny seznam'], ['ghcr.io/Kukam', 'velke pismeno ve jmennem prostoru'], ['ghcr.io//kukam', 'dvojite lomitko'], ['ghcr.io/kukam/pwe:tag', 'jmeno image misto registru']) {
        log_reset();
        ($rc, $out, $err) = sh({%git, PWE_IMAGE_REGISTRIES => $c->[0]}, $build, '--print');
        is($rc, 2, "build-images.sh: neplatny registr ($c->[1]) -> kod 2");
        ok(!defined(bake_args()) && length($err), "build-images.sh: neplatny registr ($c->[1]) -> hlaska a zadny bake");
    }

    # volby s hodnotou: chybejici hodnota i hodnota zacinajici pomlckou
    foreach my $args (['--platform'], ['--platform', '--push'], ['--platform='], ['--platform=--push'], ['--set'], ['--set', '--push'], ['--set=']) {
        log_reset();
        ($rc, $out, $err) = sh({%git}, $build, @{$args});
        is($rc, 2, "build-images.sh @{$args}: chybejici hodnota -> kod 2");
        like($err, qr/^--(?:platform|set) vyzaduje hodnotu/, "build-images.sh @{$args}: srozumitelna hlaska");
        ok(!defined(bake_args()), "build-images.sh @{$args}: bake se nespusti");
    }
    log_reset();
    ($rc, $out, $err) = sh({%git}, $build, '--set', '*.cache-from=type=gha', '--set=*.x=y', '--platform=linux/amd64', '--no-cache', 'base');
    is_deeply(bake_args(), ['-f', 'docker-bake.hcl', '--set', '*.platform=linux/amd64', '--no-cache', '--set', '*.cache-from=type=gha', '--set', '*.x=y', '--set', '*.output=type=cacheonly', 'base'],
        'build-images.sh --platform bez --push: zkusebni build bez nacteni, --set a --no-cache se predaji');
    log_reset();
    ($rc, $out, $err) = sh({%git}, $build, '--push', '--load');
    is($rc, 2, 'build-images.sh --push --load: kod 2');

    # --push: vychozi platformy
    log_reset();
    ($rc, $out, $err) = sh({%git}, $build, '--push');
    is($rc, 0, 'build-images.sh --push: cisty strom -> publikuje') or diag($err);
    is_deeply(bake_args(), ['-f', 'docker-bake.hcl', '--set', '*.platform=linux/amd64,linux/arm64', '--push'], 'build-images.sh --push bez --platform: vychozi platformy linux/amd64,linux/arm64');
    like($err, qr{--push bez --platform.*linux/amd64,linux/arm64}, 'build-images.sh --push bez --platform: vychozi platformy vypise');
    is(call_env()->{'VERSION'} . '|' . call_env()->{'TAG'} . '|' . call_env()->{'REVISION'}, "$VERSION|<unset>|$HEAD", 'build-images.sh --push: verze, zadny TAG a commit v REVISION');
    log_reset();
    ($rc, $out, $err) = sh({%git}, $build, '--push', '--platform', 'linux/arm64', 'example-static');
    is_deeply(bake_args(), ['-f', 'docker-bake.hcl', '--set', '*.platform=linux/arm64', '--push', 'example-static'], 'build-images.sh --push --platform P: zadana platforma zustava');
    unlike($err, qr/--push bez --platform/, 'build-images.sh --push --platform P: hlaska o vychozich platformach se nevypise');

    # --push na vetvi nezavisi: pojistky kolem vetve zanikly (kdo smi publikovat, rozhoduje pipeline)
    foreach my $c ([{FAKE_GIT_BRANCH => ''}, 'odpojeny HEAD'], [{FAKE_GIT_BRANCH => 'master'}, 'vetev master'], [{FAKE_GIT_BRANCH => '+master'}, 'vetev +master'], [{FAKE_GIT_BRANCH => '10.20.30'}, 'vetev tvaru verze']) {
        log_reset();
        ($rc, $out, $err) = sh($c->[0], $build, '--push');
        is("$rc|" . (call_env()->{'VERSION'} || '') . '|' . (call_env()->{'REVISION'} || ''), "0|$VERSION|$HEAD", "build-images.sh --push ($c->[1]): cisty strom publikuje tagy <verze> a latest s commitem v REVISION") or diag($err);
        unlike($err, qr/PWE_IMAGE_TAG|master|vetev/, "build-images.sh --push ($c->[1]): zadna hlaska o vetvi ani o tagu");
    }

    # --push: necommitnute zmeny
    log_reset();
    ($rc, $out, $err) = sh({%git, FAKE_GIT_DIRTY => '?? novy-soubor'}, $build, '--push');
    is($rc, 2, 'build-images.sh --push s necommitnutymi zmenami: kod 2');
    like($err, qr/necommitnute zmeny.*--allow-dirty/, 'build-images.sh --push s necommitnutymi zmenami: radi --allow-dirty');
    ok(!defined(bake_args()), 'build-images.sh --push s necommitnutymi zmenami: nic se nepublikuje');
    log_reset();
    ($rc, $out, $err) = sh({%git, FAKE_GIT_DIRTY => '?? novy-soubor'}, $build, '--push', '--allow-dirty');
    is($rc, 0, 'build-images.sh --push --allow-dirty: publikuje') or diag($err);
    is(call_env()->{'REVISION'}, '', 'build-images.sh --push --allow-dirty: REVISION je prazdna');
    like($err, qr/POZOR: .*--allow-dirty.*image vzorovych webu nebudou mit popisek revision/, 'build-images.sh --push --allow-dirty: varuje, ze image vzorovych webu nebudou mit popisek revision');
    ok(scalar(grep { $_ eq '--push' } @{bake_args() || []}), 'build-images.sh --push --allow-dirty: bake dostane --push');

    # --print s --push: pojistka jen varuje (nic se nepublikuje)
    log_reset();
    ($rc, $out, $err) = sh({%git, FAKE_GIT_DIRTY => '?? novy-soubor'}, $build, '--print', '--push');
    is($rc, 0, 'build-images.sh --print --push s necommitnutymi zmenami: jen vypis, kod 0');
    like($err, qr/POZOR: .*necommitnute zmeny.*--push by skoncil chybou/, 'build-images.sh --print --push s necommitnutymi zmenami: varuje, ze --push by skoncil chybou');
    is_deeply(bake_args(), ['-f', 'docker-bake.hcl', '--set', '*.platform=linux/amd64,linux/arm64', '--print'], 'build-images.sh --print --push: vypis s platformami publikace, bez --push');

    # --push bez gitu: varovani, ze popisek revision bude prazdny
    log_reset();
    ($rc, $out, $err) = sh({PATH => $NOGIT_PATH}, $build, '--push');
    is($rc, 0, 'build-images.sh --push bez gitu: publikuje') or diag($err);
    like($err, qr/POZOR: bez gitu.*revision image vzorovych webu bude prazdny/, 'build-images.sh --push bez gitu: varuje, ze popisek revision image vzorovych webu bude prazdny');
    is(call_env()->{'VERSION'} . '|' . call_env()->{'REVISION'}, "$VERSION|", 'build-images.sh --push bez gitu: verze z PWE/VERSION, prazdna REVISION');
    log_reset();
    ($rc, $out, $err) = sh({FAKE_GIT_BRANCH => 'cizi', FAKE_GIT_PREFIX => 'sub/', FAKE_GIT_HEAD => 'ffffffffffffffffffffffffffffffffffffffff'}, $build, '--push');
    is("$rc|" . (defined(call_env()->{'REVISION'}) ? call_env()->{'REVISION'} : 'x'), '0|', 'build-images.sh --push uvnitr ciziho gitu: commit ciziho repozitare se do REVISION nedostane');
}

# ---------------------------------------------------------------------------------------------
# run-tests.sh a perl-compile.sh: prikazova radka docker run, navratovy kod, zamek pracovni kopie
# ---------------------------------------------------------------------------------------------
{
    my $run_tests = "$REPO/PWE/tools/run-tests.sh";
    my $compile   = "$REPO/PWE/tools/perl-compile.sh";
    my %git       = (FAKE_GIT_BRANCH => 'feature/kosik');    # vetev na image nastroju nema vliv
    my $image     = "ghcr.io/kukam/pwe-debugger:$VERSION";
    my ($rc, $out, $err);

    log_reset();
    ($rc, $out, $err) = sh({%git}, $run_tests);
    is($rc, 0, 'run-tests.sh: kod 0') or diag($err);
    my @run = calls('docker', 'run');
    is(scalar(@run), 1, 'run-tests.sh: jedno volani docker run');
    my @args = @{$run[0] || []};
    is_deeply([@args[0 .. 10]], ['run', '--rm', '--init', '--entrypoint', 'bash', '-v', "$REPO:/PWE", '-w', '/PWE/PWE', $image, '-c'],
        'run-tests.sh: docker run --rm --init --entrypoint bash -v <repo>:/PWE -w /PWE/PWE <image nastroju pwe-debugger:verze> -c');
    like($args[11] || '', qr{unset FCGI_SOCKET_PATH.*PWE_CONF_.*exec prove -I/PWE/PWE -I/PWE/PWE/t/lib "\$\@"}s, 'run-tests.sh: skript v kontejneru cisti prostredi a spousti prove');
    like($args[11] || '', qr{^\s*unset [^\n]*\bPWE_PROFILE\b}m, 'run-tests.sh: skript v kontejneru odstrani i PWE_PROFILE (image webu vcetne pwe-example-* ho maji zapeceny)');
    is(scalar(calls('git')), 0, 'run-tests.sh: git se nevola (image nastroju na vetvi nezavisi)');
    is_deeply([@args[12 .. $#args]], ['--', '-r', 't'], 'run-tests.sh: bez argumentu cela sada (prove -r t)');
    like($err, qr/^\[run-tests\] image \Q$image\E$/m, 'run-tests.sh: vypise pouzity image');
    ok(!-e $LOCK, 'run-tests.sh: zamek pracovni kopie po behu neexistuje');

    log_reset();
    ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => 'rucni', PWE_IMAGE_REGISTRY => 'registry.example.test/tym', FAKE_DOCKER_RUN_RC => 7}, $run_tests, 't/03-validate.t', '-v');
    @args = @{(calls('docker', 'run'))[0] || []};
    is($args[9], 'registry.example.test/tym/pwe-debugger:rucni', 'run-tests.sh: image z PWE_IMAGE_REGISTRY a PWE_IMAGE_TAG');
    is_deeply([@args[12 .. $#args]], ['--', 't/03-validate.t', '-v'], 'run-tests.sh: argumenty se predaji prove');
    is($rc, 7, 'run-tests.sh: navratovy kod = navratovy kod prove (docker run)');
    ok(!-e $LOCK, 'run-tests.sh: zamek se uvolni i po neuspesnem behu');

    log_reset();
    ($rc, $out, $err) = sh({%git, PWE_TEST_IMAGE => 'ghcr.io/kukam/pwe-base:jina', FAKE_DOCKER_INSPECT_RC => 1, FAKE_DOCKER_TAGS => 'pwe.ai'}, $run_tests);
    is(((calls('docker', 'run'))[0] || [])->[9], 'ghcr.io/kukam/pwe-base:jina', 'run-tests.sh: PWE_TEST_IMAGE prepise image nastroju');
    like($err, qr{^\[run-tests\] image ghcr\.io/kukam/pwe-base:jina neni v lokalnim Dockeru.*^\[run-tests\] .*make images.*^\[run-tests\] .*tagy ghcr\.io/kukam/pwe-base: pwe\.ai}ms, 'run-tests.sh: rada pri chybejicim image (pwe_image_missing_hint)');

    # PWE_TEST_IMAGE = uplne prepsani: funguje bez ohledu na pravidla tagu (neplatny PWE_IMAGE_TAG, rozbity
    # PWE/VERSION) - tak testy poustej nad image, ktery pravidlum tagu neodpovida
    spit($VERSION_FILE, "neni-verze\n");
    foreach my $tool ($run_tests, $compile) {
        (my $name = $tool) =~ s{.*/}{};
        log_reset();
        ($rc, $out, $err) = sh({%git, PWE_TEST_IMAGE => 'ghcr.io/kukam/pwe-debugger:pwe.ai', PWE_IMAGE_TAG => 'a/b'}, $tool);
        ok($rc == 0 && scalar(grep { $_ eq 'ghcr.io/kukam/pwe-debugger:pwe.ai' } @{(calls('docker', 'run'))[0] || []}), "$name: PWE_TEST_IMAGE funguje i s neplatnym PWE_IMAGE_TAG a rozbitym PWE/VERSION") or diag($err);
        log_reset();
        ($rc, $out, $err) = sh({%git}, $tool);
        is($rc . '|' . scalar(calls('docker')), '2|0', "$name: rozbity PWE/VERSION bez PWE_TEST_IMAGE a PWE_IMAGE_TAG -> kod 2, docker se nevola");
        like($err, qr/neobsahuje verzi enginu tvaru X\.Y\.Z/, "$name: rozbity PWE/VERSION -> hlaska z pwe_image_version");
        log_reset();
        ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => 'latest'}, $tool);
        ok($rc == 0 && scalar(grep { $_ eq 'ghcr.io/kukam/pwe-debugger:latest' } @{(calls('docker', 'run'))[0] || []}), "$name: s PWE_IMAGE_TAG=latest se PWE/VERSION necte") or diag($err);
    }
    spit($VERSION_FILE, "$VERSION\n");

    log_reset();
    ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => 'feature/kosik'}, $run_tests);
    is($rc, 2, 'run-tests.sh: neplatny PWE_IMAGE_TAG -> kod 2');
    like($err, qr/neni platny tag image/, 'run-tests.sh: neplatny PWE_IMAGE_TAG -> hlaska');
    is(scalar(calls('docker')), 0, 'run-tests.sh: neplatny PWE_IMAGE_TAG -> docker se vubec nevola');

    # perl-compile.sh
    log_reset();
    ($rc, $out, $err) = sh({%git}, $compile);
    is($rc, 0, 'perl-compile.sh: kod 0') or diag($err);
    @args = @{(calls('docker', 'run'))[0] || []};
    is_deeply([@args[0 .. 9]], ['run', '--rm', '--entrypoint', 'bash', '-v', "$REPO:/PWE", '-w', '/PWE/PWE', $image, '-c'],
        'perl-compile.sh: docker run --rm --entrypoint bash -v <repo>:/PWE -w /PWE/PWE <image nastroju pwe-debugger:verze> -c');
    like($args[10] || '', qr{PERL5LIB=/PWE/PWE:/PWE/PWE/tools/lib.*perl -c}s, 'perl-compile.sh: skript v kontejneru spousti perl -c');
    is(scalar(@args), 11, 'perl-compile.sh: zadne dalsi argumenty');
    like($err, qr/^\[perl-compile\] image \Q$image\E$/m, 'perl-compile.sh: vypise pouzity image');
    log_reset();
    ($rc, $out, $err) = sh({%git, PWE_TEST_IMAGE => 'ghcr.io/kukam/pwe-base:jina', FAKE_DOCKER_RUN_RC => 1, FAKE_DOCKER_INSPECT_RC => 1}, $compile);
    is($rc, 1, 'perl-compile.sh: navratovy kod = navratovy kod docker run');
    is(((calls('docker', 'run'))[0] || [])->[8], 'ghcr.io/kukam/pwe-base:jina', 'perl-compile.sh: PWE_TEST_IMAGE prepise image nastroju');
    like($err, qr/^\[perl-compile\] image .* neni v lokalnim Dockeru/m, 'perl-compile.sh: rada pri chybejicim image');
    log_reset();
    ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => '-x'}, $compile);
    is($rc . '|' . scalar(calls('docker')), '2|0', 'perl-compile.sh: neplatny PWE_IMAGE_TAG -> kod 2, docker se nevola');

    # --- zamek pracovni kopie -------------------------------------------------------------------
    # Beh A drzi zamek: jeho falesny docker run ceka na soubor $hold.
    my ($started, $hold) = ("$T/a.started", "$T/a.hold");
    log_reset();
    my $a = start_bg({env => {%git, FAKE_DOCKER_RUN_STARTED => $started, FAKE_DOCKER_RUN_HOLD => $hold, FAKE_DOCKER_RUN_RC => 5}}, $BASH, $run_tests);
    ok(wait_for(sub { -e $started }, 20), 'zamek: beh A spustil docker run');
    ok(-d $LOCK, 'zamek: za behu existuje adresar PWE/t/.run-tests.lock');
    is(slurp("$LOCK/pid"), "$a->{'pid'}\n", 'zamek: soubor pid obsahuje cislo procesu run-tests.sh');

    # PWE_TEST_LOCK_WAIT=0: necekat, kod 2
    my $t0 = Time::HiRes::time();
    ($rc, $out, $err) = sh({%git, PWE_TEST_LOCK_WAIT => 0}, $run_tests);
    is($rc, 2, 'zamek: druhy beh s PWE_TEST_LOCK_WAIT=0 skonci kodem 2');
    like($err, qr/bezi jiny beh testu \(PID $a->{'pid'}, zamek \Q$LOCK\E\).*PWE_TEST_LOCK_WAIT=0/, 'zamek: PWE_TEST_LOCK_WAIT=0 -> hlaska s PID a cestou zamku');
    cmp_ok(Time::HiRes::time() - $t0, '<', 10, 'zamek: PWE_TEST_LOCK_WAIT=0 opravdu neceka');

    # PWE_TEST_LOCK_WAIT=1: ceka nejvys 1 s, pak kod 2
    ($rc, $out, $err) = sh({%git, PWE_TEST_LOCK_WAIT => 1}, $run_tests);
    is($rc, 2, 'zamek: po vyprseni PWE_TEST_LOCK_WAIT skonci kodem 2');
    like($err, qr/cekam, az skonci \(nejvys 1 s.*neskoncil ani po 1 s/s, 'zamek: vyprseni cekani -> hlaska');
    is(scalar(calls('docker', 'run')), 1, 'zamek: beh, ktery zamek neziskal, docker run nespusti');
    is(slurp("$LOCK/pid"), "$a->{'pid'}\n", 'zamek: neuspesne behy cizi zamek nesmazou');

    # neplatna hodnota PWE_TEST_LOCK_WAIT
    ($rc, $out, $err) = sh({%git, PWE_TEST_LOCK_WAIT => 'dlouho'}, $run_tests);
    is($rc, 2, 'zamek: PWE_TEST_LOCK_WAIT, ktere neni cislo -> kod 2');

    # beh C ceka (vychozi cekani), po skonceni A zamek ziska a probehne
    my $c = start_bg({env => {%git, FAKE_DOCKER_RUN_RC => 3}}, $BASH, $run_tests);
    ok(wait_for(sub { slurp($c->{'err'}) =~ /cekam, az skonci/ }, 20), 'zamek: beh C ceka na beh A');
    is(scalar(calls('docker', 'run')), 1, 'zamek: cekajici beh C zatim docker run nespustil');
    spit($hold, '');
    ($rc, $out, $err) = finish_bg($a);
    is($rc, 5, 'zamek: beh A skonci s navratovym kodem prove');
    ($rc, $out, $err) = finish_bg($c);
    is($rc, 3, 'zamek: beh C po uvolneni zamku probehne (navratovy kod prove)');
    is(scalar(() = $err =~ /cekam, az skonci/g), 1, 'zamek: na co ceka, vypise beh C jen jednou');
    like($err, qr/nejvys 600 s/, 'zamek: vychozi cekani je 600 s');
    is(scalar(calls('docker', 'run')), 2, 'zamek: docker run spustily prave dva behy (A a C)');
    ok(!-e $LOCK, 'zamek: po skonceni vsech behu neexistuje');

    # opusteny zamek (proces uz nebezi) se prevezme, i s PWE_TEST_LOCK_WAIT=0
    my $dead = fork();
    die "fork: $!" unless (defined($dead));
    POSIX::_exit(0) if ($dead == 0);
    waitpid($dead, 0);
    make_path($LOCK);
    spit("$LOCK/pid", "$dead\n");
    log_reset();
    ($rc, $out, $err) = sh({%git, PWE_TEST_LOCK_WAIT => 0}, $run_tests);
    is($rc, 0, 'zamek: opusteny zamek (proces uz nebezi) beh prevezme') or diag($err);
    like($err, qr/prevzat opusteny zamek .*\(beh s PID $dead uz nebezi\)/, 'zamek: prevzeti opusteneho zamku ohlasi');
    is(scalar(calls('docker', 'run')), 1, 'zamek: po prevzeti testy probehnou');
    ok(!-e $LOCK, 'zamek: prevzaty zamek se po behu smaze');

    # cislo procesu z opusteneho zamku mezitim dostal jiny program (zde sleep): zamek se take prevezme
  SKIP: {
        my ($sleep) = grep { -x $_ } map { "$_/sleep" } grep { length } split(/:/, $SYS_PATH);
        skip 'chybi ps nebo sleep (bez ps rozhoduje jen kill -0)', 2 unless ($sleep and `ps -p $$ -o command= 2>/dev/null` =~ /\S/);
        my $other = start_bg({}, $sleep, '60');
        make_path($LOCK);
        spit("$LOCK/pid", "$other->{'pid'}\n");
        ($rc, $out, $err) = sh({%git, PWE_TEST_LOCK_WAIT => 0}, $run_tests);
        kill('KILL', $other->{'pid'});
        finish_bg($other);
        is($rc, 0, 'zamek: PID z opusteneho zamku patri jinemu programu -> beh zamek prevezme') or diag($err);
        ok(!-e $LOCK, 'zamek: zamek prevzaty po cizim programu se po behu smaze');
    }

    # opusteny zamek bez souboru pid (beh ukonceny mezi mkdir a zapisem pid) se prevezme po kratkem odkladu
    make_path($LOCK);
    log_reset();
    ($rc, $out, $err) = sh({%git, PWE_TEST_LOCK_WAIT => 0}, $run_tests);
    is($rc, 0, 'zamek: zamek bez souboru pid beh po odkladu prevezme') or diag($err);
    like($err, qr/prevzat opusteny zamek .*\(bez souboru pid\)/, 'zamek: prevzeti zamku bez pid ohlasi');
    ok(!-e $LOCK, 'zamek: zamek bez pid se po behu smaze');

    # opusteny zamek, ve kterem zbyla znacka prebirani (beh ukonceny uprostred prebirani): znacka se po
    # kratkem odkladu smaze a zamek se prevezme. Regrese: takovy zamek se hlasil jako bezici beh a skript
    # cekal PWE_TEST_LOCK_WAIT sekund na proces, ktery uz neexistuje.
    my $gone = dead_pid();
    make_path("$LOCK/takeover");
    spit("$LOCK/pid", "$gone\n");
    log_reset();
    ($rc, $out, $err) = sh({%git, PWE_TEST_LOCK_WAIT => 0}, $run_tests);
    is($rc, 0, 'zamek: opusteny zamek se zbylou znackou prebirani beh prevezme (i s PWE_TEST_LOCK_WAIT=0)') or diag($err);
    like($err, qr/smazana znacka prebirani \Q$LOCK\E\/takeover .*prevzat opusteny zamek \Q$LOCK\E \(beh s PID $gone uz nebezi\)/s, 'zamek: smazani zbyle znacky a prevzeti zamku ohlasi');
    unlike($err, qr/bezi jiny beh testu|neskoncil/, 'zamek: opusteny zamek se zbylou znackou se nehlasi jako bezici beh');
    is(scalar(calls('docker', 'run')), 1, 'zamek: po smazani zbyle znacky testy probehnou');
    ok(!-e $LOCK, 'zamek: zamek prevzaty po smazani zbyle znacky se po behu smaze');

    # opusteny zamek, ktery prevzit nejde, i kdyz se do nej da zapisovat (znacku prebirani nejde smazat -
    # neni to prazdny adresar): beh skonci kodem 2 a rekne, ze zamek je opusteny a jak ho smazat - ne ze
    # bezi jiny beh
    $gone = dead_pid();
    make_path("$LOCK/takeover");
    spit("$LOCK/takeover/zbytek", '');
    spit("$LOCK/pid", "$gone\n");
    log_reset();
    ($rc, $out, $err) = sh({%git, PWE_TEST_LOCK_WAIT => 0}, $run_tests);
    is($rc, 2, 'zamek: opusteny zamek, ktery nejde prevzit -> kod 2');
    like($err, qr/zamek \Q$LOCK\E je opusteny \(beh s PID $gone uz nebezi\), ale nejde prevzit - koncim\. Smaz ho: rm -rf \Q$LOCK\E$/m, 'zamek: opusteny zamek, ktery nejde prevzit -> hlaska, ze je opusteny, a jak ho smazat');
    unlike($err, qr/bezi jiny beh testu|neskoncil|cekam, az skonci/, 'zamek: opusteny zamek, ktery nejde prevzit, se nehlasi jako bezici beh');
    is(scalar(calls('docker', 'run')), 0, 'zamek: opusteny zamek, ktery nejde prevzit -> docker run se nespusti');
    ($rc, $out, $err) = sh({%git, PWE_TEST_LOCK_WAIT => 1}, $run_tests);
    is($rc, 2, 'zamek: opusteny zamek, ktery nejde prevzit, s cekanim -> po vyprseni kod 2');
    like($err, qr/je opusteny \(beh s PID $gone uz nebezi\), ale nejde prevzit - zkousim to dal \(nejvys 1 s.*ale nejde prevzit - koncim/s, 'zamek: opusteny zamek, ktery nejde prevzit, s cekanim -> ohlasi, ze to zkousi dal, a pak skonci');
    is(slurp("$LOCK/pid") . (-f "$LOCK/takeover/zbytek" ? '|zbytek' : ''), "$gone\n|zbytek", 'zamek: opusteny zamek, ktery nejde prevzit, zustava beze zmeny');
    remove_tree($LOCK);

    # opusteny zamek v adresari, do ktereho beh nesmi zapisovat (souborovy system jen pro cteni, zamek
    # ciziho uzivatele): prevzit ho nejde -> beh pokracuje bez zamku s varovanim (stejne jako kdyz zamek
    # nejde zalozit). Regrese: hlasil se jako bezici beh. Test bezi jako root, ktery by zapsal kamkoli -
    # nastroj se proto spousti jako nobody (docasny strom mu musi byt pristupny, log zapisovatelny).
  SKIP: {
        $gone = dead_pid();
        make_path($LOCK);
        spit("$LOCK/pid", "$gone\n");
        chmod(0755, $T);
        log_reset();
        spit($LOG, '', 0666);
        my ($rc_p) = run_cmd({drop_root => 1}, $BASH, '-c', 'mkdir "$1"', 'zkouska', "$LOCK/zkouska");
        if ($> != 0 or $rc_p == 0 or $rc_p == 124) {
            remove_tree($LOCK);
            chmod(0700, $T);
            skip 'adresar zamku nejde udelat nezapisovatelnym (test nebezi jako root, nebo nelze zahodit prava roota)', 5;
        }
        log_reset();
        spit($LOG, '', 0666);
        ($rc, $out, $err) = run_cmd({env => {%git, PWE_TEST_LOCK_WAIT => 0, FAKE_DOCKER_RUN_RC => 4}, drop_root => 1}, $BASH, $run_tests);
        is($rc, 4, 'zamek: opusteny zamek, do ktereho se neda zapisovat -> testy presto probehnou (navratovy kod prove)') or diag($err);
        like($err, qr/POZOR: opusteny zamek \Q$LOCK\E \(beh s PID $gone uz nebezi\) nejde prevzit - do adresare se neda zapisovat.* - pokracuji bez zamku/, 'zamek: opusteny zamek, do ktereho se neda zapisovat -> varovani a beh bez zamku');
        unlike($err, qr/bezi jiny beh testu|neskoncil/, 'zamek: opusteny zamek, do ktereho se neda zapisovat, se nehlasi jako bezici beh');
        is(scalar(calls('docker', 'run')), 1, 'zamek: beh bez prevzateho zamku spusti docker run');
        is(slurp("$LOCK/pid"), "$gone\n", 'zamek: opusteny zamek, do ktereho se neda zapisovat, zustava (beh bez zamku ho po sobe nemaze)');
        remove_tree($LOCK);
        chmod(0700, $T);
    }

    # signal TERM: zamek se uvolni (trap), kod 143
    unlink($started, $hold);
    log_reset();
    $a = start_bg({env => {%git, FAKE_DOCKER_RUN_STARTED => $started, FAKE_DOCKER_RUN_HOLD => $hold}}, $BASH, $run_tests);
    ok(wait_for(sub { -e $started and -d $LOCK }, 20), 'zamek: beh pred signalem TERM drzi zamek');
    kill('TERM', $a->{'pid'});
    spit($hold, '');
    ($rc, $out, $err) = finish_bg($a);
    is($rc, 143, 'zamek: po signalu TERM skonci beh kodem 143');
    ok(!-e $LOCK, 'zamek: po signalu TERM se zamek uvolni');

    # zamek nejde zalozit z jineho duvodu (zde: PWE/t neni adresar; totez plati pro souborovy system jen
    # pro cteni) -> beh pokracuje bez zamku s varovanim
    rename("$REPO/PWE/t", "$REPO/PWE/t.bak") or die "rename: $!";
    spit("$REPO/PWE/t", '');
    log_reset();
    ($rc, $out, $err) = sh({%git, FAKE_DOCKER_RUN_RC => 4}, $run_tests);
    unlink("$REPO/PWE/t");
    rename("$REPO/PWE/t.bak", "$REPO/PWE/t") or die "rename: $!";
    is($rc, 4, 'zamek: kdyz zamek nejde zalozit, testy presto probehnou (navratovy kod prove)');
    like($err, qr/POZOR: zamek .* nejde zalozit.*bez zamku/, 'zamek: kdyz zamek nejde zalozit, beh varuje');
    is(scalar(calls('docker', 'run')), 1, 'zamek: beh bez zamku spusti docker run');

    # perl-compile.sh zamek nepouziva (nezapisuje do sdilenych docasnych dat)
    make_path($LOCK);
    spit("$LOCK/pid", "$$\n");
    ($rc, $out, $err) = sh({%git}, $compile);
    is($rc, 0, 'perl-compile.sh: bezi i pri drzenem zamku testu');
    remove_tree($LOCK);
}

# ---------------------------------------------------------------------------------------------
# pwe-cgi.sh: sit a databaze compose stacku jen pro web, kteremu stack patri
# ---------------------------------------------------------------------------------------------
{
    my $cgi   = "$REPO/PWE/tools/pwe-cgi.sh";
    my %git   = (FAKE_GIT_BRANCH => 'pwe.ai');
    my $image = "ghcr.io/kukam/pwe-debugger:$VERSION";
    my %stack = (FAKE_DOCKER_NETWORK_RC => 0, FAKE_DOCKER_FCGI_CID => 'c0ffee');
    my ($rc, $out, $err, @args);
    my $has_db_env = sub { return scalar(grep { /^PWE_CONF_dbi_/ } @_); };

    # zadny stack nebezi
    log_reset();
    ($rc, $out, $err) = sh({%git}, $cgi, 'st.web', 'page=kontakt&func=default', '--cookie', 'A=B', '--loglevel', '4');
    is($rc, 0, 'pwe-cgi.sh: kod 0') or diag($err);
    @args = @{(calls('docker', 'run'))[0] || []};
    is_deeply([@args[0 .. 4]], ['run', '--rm', '-i', '--entrypoint', 'bash'], 'pwe-cgi.sh: docker run --rm -i --entrypoint bash');
    ok(has_pair(\@args, '-v', "$REPO:/PWE") && has_pair(\@args, '-w', '/PWE/webapps/st.web'), 'pwe-cgi.sh: mount korene repozitare, pracovni adresar = web');
    ok(has_pair(\@args, $image, '-c'), 'pwe-cgi.sh: image nastroju pwe-debugger:<verze>');
    is(scalar(calls('git')), 0, 'pwe-cgi.sh: git se nevola');
    ok(has_pair(\@args, '-e', 'QS=page=kontakt&func=default') && has_pair(\@args, '-e', 'METHOD=GET') && has_pair(\@args, '-e', 'COOKIE=A=B') && has_pair(\@args, '-e', 'LOGLEVEL=4') && has_pair(\@args, '-e', 'SCRIPT=/pwe.fcgi'),
        'pwe-cgi.sh: request (query string, metoda, cookie, loglevel, skript) se preda v promennych');
    ok(!scalar(grep { $_ eq '--network' } @args) && !$has_db_env->(@args), 'pwe-cgi.sh: bez site pwe_default zadna --network ani prihlaseni k databazi');
    is(scalar(calls('docker', 'ps')), 0, 'pwe-cgi.sh: bez site pwe_default se na kontejnery stacku nepta');

    # stack tehoz webu (sluzba fcgi)
    log_reset();
    ($rc, $out, $err) = sh({%git, %stack, FAKE_DOCKER_WORKDIR => '/PWE/webapps/dblink.web', DB_NAME => 'jina'}, $cgi, 'dblink.web', '--post', 'page=a&func=b');
    is($rc, 0, 'pwe-cgi.sh: stack tehoz webu -> kod 0') or diag($err);
    @args = @{(calls('docker', 'run'))[0] || []};
    ok(has_pair(\@args, '--network', 'pwe_default'), 'pwe-cgi.sh: stack tehoz webu -> pripoji se k siti pwe_default');
    ok(has_pair(\@args, '-e', 'PWE_CONF_dbi_db1_database=jina') && has_pair(\@args, '-e', 'PWE_CONF_dbi_db1_login=pwe') && has_pair(\@args, '-e', 'PWE_CONF_dbi_db1_password=pwe'),
        'pwe-cgi.sh: stack tehoz webu -> prihlaseni k databazi (DB_NAME, vychozi pwe/pwe)');
    ok(has_pair(\@args, '-e', 'METHOD=POST') && has_pair(\@args, '-e', 'POST_LEN=13'), 'pwe-cgi.sh --post: metoda POST a delka tela');
    unlike($err, qr/\[pwe-cgi\]/, 'pwe-cgi.sh: stack tehoz webu -> bez upozorneni');
    is_deeply((calls('docker', 'ps'))[0], ['ps', '-q', '--filter', 'label=com.docker.compose.project=pwe', '--filter', 'label=com.docker.compose.service=fcgi'],
        'pwe-cgi.sh: web stacku hleda podle kontejneru sluzby fcgi projektu pwe');
    is_deeply((calls('docker', 'inspect'))[0], ['inspect', '--format', '{{.Config.WorkingDir}}', 'c0ffee'], 'pwe-cgi.sh: web stacku = pracovni adresar kontejneru');

    # stack tehoz webu, bezi jen sluzba debugger
    log_reset();
    ($rc, $out, $err) = sh({%git, FAKE_DOCKER_NETWORK_RC => 0, FAKE_DOCKER_DEBUGGER_CID => 'deb', FAKE_DOCKER_WORKDIR => '/PWE/webapps/st.web/'}, $cgi, 'st.web');
    ok(has_pair((calls('docker', 'run'))[0] || [], '--network', 'pwe_default'), 'pwe-cgi.sh: web stacku pozna i podle sluzby debugger');

    # stack JINEHO webu, web bez conf/database.conf: bez site, s upozornenim
    foreach my $web (qw(st.web db.web)) {
        log_reset();
        ($rc, $out, $err) = sh({%git, %stack, FAKE_DOCKER_WORKDIR => '/PWE/webapps/other.web'}, $cgi, $web);
        is($rc, 0, "pwe-cgi.sh: stack jineho webu, $web bez conf/database.conf -> request probehne");
        @args = @{(calls('docker', 'run'))[0] || []};
        ok(scalar(@args) && !scalar(grep { $_ eq '--network' } @args) && !$has_db_env->(@args), "pwe-cgi.sh: stack jineho webu ($web) -> zadna --network ani prihlaseni k cizi databazi");
        like($err, qr/^\[pwe-cgi\] bezi stack webu other\.web, ne \Q$web\E - k jeho siti a databazi se nepripojuji/m, "pwe-cgi.sh: stack jineho webu ($web) -> upozorneni [pwe-cgi]");
    }

    # stack JINEHO webu, web s conf/database.conf (pouziva databazi): chyba, nic se nespusti
    foreach my $web (qw(dblink.web badlink.web)) {
        log_reset();
        ($rc, $out, $err) = sh({%git, %stack, FAKE_DOCKER_WORKDIR => '/PWE/webapps/other.web'}, $cgi, $web);
        is($rc, 2, "pwe-cgi.sh: stack jineho webu, $web s conf/database.conf -> kod 2");
        is(scalar(calls('docker', 'run')), 0, "pwe-cgi.sh: stack jineho webu ($web s databazi) -> docker run se nespusti");
        like($err, qr/^\[pwe-cgi\] bezi stack webu other\.web, ne \Q$web\E.*make run WEB=\Q$web\E/m, "pwe-cgi.sh: stack jineho webu ($web s databazi) -> hlaska s radou make run");
    }

    # sit existuje, ale fcgi ani debugger nebezi: web stacku nelze urcit -> bez site
    log_reset();
    ($rc, $out, $err) = sh({%git, FAKE_DOCKER_NETWORK_RC => 0}, $cgi, 'dblink.web');
    is($rc, 0, 'pwe-cgi.sh: sit bez bezicich sluzeb -> request probehne');
    ok(!scalar(grep { $_ eq '--network' } @{(calls('docker', 'run'))[0] || []}), 'pwe-cgi.sh: sit bez bezicich sluzeb -> bez --network');
    like($err, qr/^\[pwe-cgi\] sit pwe_default existuje, ale sluzba fcgi ani debugger nebezi/m, 'pwe-cgi.sh: sit bez bezicich sluzeb -> upozorneni');

    # volba bez hodnoty, neznama volba, neexistujici web
    foreach my $opt (qw(--post --cookie --script --loglevel)) {
        log_reset();
        ($rc, $out, $err) = sh({%git}, $cgi, 'st.web', 'page=default', $opt);
        is($rc, 2, "pwe-cgi.sh $opt bez hodnoty: kod 2");
        like($err, qr/^Volba \Q$opt\E vyzaduje hodnotu/, "pwe-cgi.sh $opt bez hodnoty: srozumitelna hlaska");
        is(scalar(calls('docker', 'run')), 0, "pwe-cgi.sh $opt bez hodnoty: docker run se nespusti");
    }
    log_reset();
    ($rc, $out, $err) = sh({%git}, $cgi, 'st.web', '--post', '');
    ok($rc == 0 && has_pair((calls('docker', 'run'))[0] || [], '-e', 'METHOD=POST'), 'pwe-cgi.sh --post s prazdnou hodnotou: POST s prazdnym telem');
    ($rc, $out, $err) = sh({%git}, $cgi, 'st.web', '--neco');
    is($rc, 2, 'pwe-cgi.sh: neznama volba -> kod 2');
    ($rc, $out, $err) = sh({%git}, $cgi, 'neexistuje.web');
    is($rc, 2, 'pwe-cgi.sh: neexistujici web -> kod 2');
    log_reset();
    ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => 'a/b'}, $cgi, 'st.web');
    is($rc . '|' . scalar(calls('docker')), '2|0', 'pwe-cgi.sh: neplatny PWE_IMAGE_TAG -> kod 2, docker se nevola');
    log_reset();
    ($rc, $out, $err) = sh({%git, FAKE_DOCKER_INSPECT_RC => 1}, $cgi, 'st.web');
    like($err, qr/^\[pwe-cgi\] image \Q$image\E neni v lokalnim Dockeru/m, 'pwe-cgi.sh: rada pri chybejicim image');
    log_reset();
    ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => 'latest'}, $cgi, 'st.web');
    ok(has_pair((calls('docker', 'run'))[0] || [], 'ghcr.io/kukam/pwe-debugger:latest', '-c'), 'pwe-cgi.sh: PWE_IMAGE_TAG=latest -> image nastroju pwe-debugger:latest');
    # prostredi image se v kontejneru zahazuje (env -i): PWE_CONF_pwe_home a PWE_PROFILE zapecene v image webu
    # (PWE_TEST_IMAGE=.../pwe-example-mariadb:...) request neovlivni
    log_reset();
    ($rc, $out, $err) = sh({%git, PWE_TEST_IMAGE => 'ghcr.io/kukam/pwe-example-mariadb:latest'}, $cgi, 'st.web');
    @args = @{(calls('docker', 'run'))[0] || []};
    like($args[-1] || '', qr{exec env -i [^\n]*PWE_CONF_pwe_home="\$PWD/" PWE_CONF_pwe_core=/PWE/PWE/}, 'pwe-cgi.sh: engine bezi s cistym prostredim (env -i) a PWE_CONF_pwe_home = pracovni adresar webu');
}

# Volani run-webapp.sh z Makefile (make run / restart / logs / down, s profilem i bez, s ARGS):
# [argumenty run-webapp.sh, ocekavany profil, ocekavany prikaz docker compose, popis, argumenty make].
# Blok run-webapp.sh overuje, co nastroj s argumenty udela; blok Makefile (make -n), ze make z uvedenych
# argumentu slozi prave tuto prikazovou radku - zmena receptu v Makefile se tak v testu projevi.
my @MAKE_RUN_CASES = (
    [['st.web', 'up', '--remove-orphans'],                       'static',  ['up', '--remove-orphans'],                  'make run',                                           ['run', 'WEB=st.web']],
    [['db.web', 'up', '--remove-orphans', '-d', '--build'],      'mariadb', ['up', '--remove-orphans', '-d', '--build'], "make run ARGS='-d --build'",                         ['run', 'WEB=db.web', 'ARGS=-d --build']],
    [['st.web', 'static', 'up', '--remove-orphans', '-d'],       'static',  ['up', '--remove-orphans', '-d'],            'make run PROFILE=static ARGS=-d',                    ['run', 'WEB=st.web', 'PROFILE=static', 'ARGS=-d']],
    [['db.web', 'restart', 'fcgi'],                              'mariadb', ['restart', 'fcgi'],                         'make restart',                                       ['restart', 'WEB=db.web']],
    [['db.web', 'mariadb', 'restart', 'fcgi'],                   'mariadb', ['restart', 'fcgi'],                         'make restart PROFILE=mariadb',                       ['restart', 'WEB=db.web', 'PROFILE=mariadb']],
    [['st.web', 'logs', '-f', 'fcgi'],                           'static',  ['logs', '-f', 'fcgi'],                      'make logs',                                          ['logs', 'WEB=st.web']],
    [['db.web', 'down', '-v'],                                   'mariadb', ['down', '-v'],                              'make down ARGS=-v',                                  ['down', 'WEB=db.web', 'ARGS=-v']],
    [['dblink.web', 'mysql', 'down', '-v', '--remove-orphans'],  'mysql',   ['down', '-v', '--remove-orphans'],          "make down PROFILE=mysql ARGS='-v --remove-orphans'", ['down', 'WEB=dblink.web', 'PROFILE=mysql', 'ARGS=-v --remove-orphans']],
);

# ---------------------------------------------------------------------------------------------
# run-webapp.sh: profil, prikaz docker compose, varovani pri neshode webu a profilu
# ---------------------------------------------------------------------------------------------
{
    my $run = "$REPO/PWE/tools/run-webapp.sh";
    my %git = (FAKE_GIT_BRANCH => 'feature/kosik');
    my ($rc, $out, $err);
    my $compose = sub { my @c = calls('docker', 'compose'); return @c ? [@{$c[-1]}[1 .. $#{$c[-1]}]] : undef; };

    # profil podle konfigurace webu, vychozi prikaz up
    foreach my $c (['st.web', 'static', 'web bez databaze'], ['db.web', 'mariadb', 'web s conf/mariadb.conf'], ['dblink.web', 'postgres', 'symlink conf/database.conf -> postgres.conf']) {
        my ($web, $profile, $what) = @{$c};
        log_reset();
        ($rc, $out, $err) = sh({%git}, $run, $web);
        is($rc, 0, "run-webapp.sh $web: kod 0") or diag($err);
        is_deeply($compose->(), ['up', '--remove-orphans'], "run-webapp.sh $web: vychozi prikaz docker compose up --remove-orphans");
        my $env = call_env();
        is("$env->{'PWE_WEBAPP'}|$env->{'COMPOSE_PROFILES'}", "$web|$profile", "run-webapp.sh $web: profil $profile ($what)");
        is("$env->{'PWE_IMAGE_REGISTRY'}|$env->{'PWE_IMAGE_TAG'}|$env->{'CWD'}", "ghcr.io/kukam|$VERSION|$REPO", "run-webapp.sh $web: registr a tag (verze enginu) pro docker-compose.yml, beh z korene repozitare");
        is($env->{'PWE_FCGI_IMAGE'}, PWE::ToolEnv::profile_image($profile), "run-webapp.sh $web: PWE_FCGI_IMAGE = zavislostni image profilu $profile (" . PWE::ToolEnv::profile_image($profile) . ')');
        is(scalar(calls('git')), 0, "run-webapp.sh $web: git se nevola (tag image na vetvi nezavisi)");
        unlike($err, qr/POZOR/, "run-webapp.sh $web: profil odvozeny z webu -> zadne varovani");
    }

    # volani z Makefile (@MAKE_RUN_CASES) a dalsi tvary argumentu
    foreach my $c (
        @MAKE_RUN_CASES,
        [['webapps/db.web/', 'ps'],                                  'mariadb', ['ps'],                                 'web zadany cestou webapps/<web>/'],
        [['st.web', 'static', '--progress', 'plain', 'up'],          'static',  ['--progress', 'plain', 'up'],          'globalni volba docker compose pred prikazem'],
      )
    {
        my ($args, $profile, $want, $what) = @{$c};
        log_reset();
        ($rc, $out, $err) = sh({%git}, $run, @{$args});
        is($rc, 0, "run-webapp.sh ($what): kod 0") or diag($err);
        is_deeply($compose->(), $want, "run-webapp.sh ($what): docker compose @{$want}");
        is(call_env()->{'COMPOSE_PROFILES'}, $profile, "run-webapp.sh ($what): profil $profile");
    }

    # image sluzby fcgi (PWE_FCGI_IMAGE pro docker-compose.yml): profil static nema vlastni image a bezi nad pwe-base,
    # databazove profily nad pwe-<profil> - i kdyz profil neodpovida webu nebo je PWE_FCGI_IMAGE v prostredi jine
    foreach my $c (['st.web', 'static', 'pwe-base'], ['db.web', 'static', 'pwe-base'], ['st.web', 'mariadb', 'pwe-mariadb'], ['db.web', 'mysql', 'pwe-mysql'], ['dblink.web', 'postgres', 'pwe-postgres']) {
        my ($web, $profile, $image) = @{$c};
        log_reset();
        ($rc, $out, $err) = sh({%git, PWE_FCGI_IMAGE => 'pwe-neco-jineho'}, $run, $web, $profile, 'config');
        is("$rc|" . (call_env()->{'PWE_FCGI_IMAGE'} || ''), "0|$image", "run-webapp.sh $web $profile: sluzba fcgi pobezi v image $image (PWE_FCGI_IMAGE z prostredi se prepise)") or diag($err);
        like($err, qr/^\[run-webapp\] web=\Q$web\E profil=$profile registr=ghcr\.io\/kukam tag=\Q$VERSION\E image=\Q$image\E -> docker compose config$/m, "run-webapp.sh $web $profile: uvodni radek jmenuje image sluzby fcgi");
    }

    # neznamy profil nebo prikaz
    foreach my $c ([['st.web', 'oracle', 'config'], 'oracle', 'neznamy profil'], [['st.web', 'oracle', 'up', '--remove-orphans'], 'oracle', 'make run PROFILE=oracle'],
        [['db.web', 'Mariadb', 'up'], 'Mariadb', 'profil s velkym pismenem'], [['st.web', 'static', 'spustit'], 'spustit', 'neznamy prikaz za profilem'], [['st.web', 'static mariadb', 'up'], 'static mariadb', 'dva profily v jednom argumentu'])
    {
        my ($args, $bad, $what) = @{$c};
        log_reset();
        ($rc, $out, $err) = sh({%git}, $run, @{$args});
        is($rc, 2, "run-webapp.sh ($what): kod 2");
        like($err, qr/^Neznamy profil nebo prikaz '\Q$bad\E' \(profily: static \| mariadb \| mysql \| postgres/, "run-webapp.sh ($what): srozumitelna hlaska");
        is(scalar(calls('docker')), 0, "run-webapp.sh ($what): docker se nevola");
    }
    log_reset();
    ($rc, $out, $err) = sh({%git}, $run, 'badlink.web');
    is($rc, 2, 'run-webapp.sh: symlink conf/database.conf na neznamy profil -> kod 2');
    like($err, qr/^Neznamy profil vlastni/, 'run-webapp.sh: symlink conf/database.conf na neznamy profil -> hlaska');
    ($rc, $out, $err) = sh({%git}, $run, 'neexistuje.web');
    is($rc, 2, 'run-webapp.sh: neexistujici web -> kod 2');

    # neshoda webu a profilu: jen varovani, stack se spusti
    log_reset();
    ($rc, $out, $err) = sh({%git}, $run, 'db.web', 'static', 'up');
    is($rc, 0, 'run-webapp.sh: web s databazi a profil static -> spusti se');
    like($err, qr{^\[run-webapp\] POZOR: web db\.web ma conf/mariadb\.conf, ale profil je static - pobezi bez databaze \(image pwe-base nema databazove ovladace\)}m, 'run-webapp.sh: web s conf/mariadb.conf a profil static -> varovani (pobezi nad pwe-base bez ovladacu)');
    is_deeply($compose->(), ['up'], 'run-webapp.sh: po varovani se docker compose spusti');
    log_reset();
    ($rc, $out, $err) = sh({%git}, $run, 'dblink.web', 'static', 'up', '-d');
    like($err, qr{^\[run-webapp\] POZOR: web dblink\.web ma conf/mysql\.conf conf/postgres\.conf, ale profil je static}m, 'run-webapp.sh: varovani vyjmenuje konfigurace databazi webu');
    foreach my $c (['st.web', 'mariadb', 'web bez databaze'], ['db.web', 'mysql', 'web s jinou databazi']) {
        my ($web, $profile, $what) = @{$c};
        log_reset();
        ($rc, $out, $err) = sh({%git}, $run, $web, $profile, 'up');
        is($rc, 0, "run-webapp.sh: $what a profil $profile -> spusti se");
        like($err, qr{^\[run-webapp\] POZOR: web \Q$web\E nema conf/$profile\.conf, ale profil je $profile}m, "run-webapp.sh: $what a profil $profile -> varovani");
        is(call_env()->{'COMPOSE_PROFILES'}, $profile, "run-webapp.sh: $what a profil $profile -> profil se nemeni");
    }
    log_reset();
    ($rc, $out, $err) = sh({%git}, $run, 'db.web', 'mariadb', 'up');
    unlike($err, qr/POZOR/, 'run-webapp.sh: web s conf/mariadb.conf a profil mariadb -> bez varovani');
    ($rc, $out, $err) = sh({%git}, $run, 'db.web', 'static', 'logs', '-f', 'fcgi');
    unlike($err, qr/POZOR/, 'run-webapp.sh: prikazy, ktere kontejnery nevytvareji (logs), nevaruji');

    # PWE_IMAGE_TAG a PWE_IMAGE_REGISTRY z prostredi se predaji docker compose
    log_reset();
    ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => 'latest', PWE_IMAGE_REGISTRY => 'registry.example.test/tym/'}, $run, 'st.web');
    is(call_env()->{'PWE_IMAGE_REGISTRY'} . '|' . call_env()->{'PWE_IMAGE_TAG'}, 'registry.example.test/tym|latest', 'run-webapp.sh: PWE_IMAGE_REGISTRY (bez koncoveho lomitka) a PWE_IMAGE_TAG=latest pro docker-compose.yml');
    like($err, qr/^\[run-webapp\] web=st\.web profil=static registr=registry\.example\.test\/tym tag=latest image=pwe-base -> docker compose up --remove-orphans$/m, 'run-webapp.sh: vypise web, profil, registr, tag a image sluzby fcgi');

    # rada pri chybejicim image a neplatny tag
    log_reset();
    ($rc, $out, $err) = sh({%git, FAKE_DOCKER_INSPECT_RC => 1, FAKE_DOCKER_TAGS => 'latest'}, $run, 'st.web', 'static', 'up');
    like($err, qr{^\[run-webapp\] image ghcr\.io/kukam/pwe-base:\Q$VERSION\E neni v lokalnim Dockeru.*^\[run-webapp\] image ghcr\.io/kukam/pwe-debugger:\Q$VERSION\E neni v lokalnim Dockeru}ms,
        'run-webapp.sh up: rada pri chybejicim image profilu (static = pwe-base) i ladiciho image');
    like($err, qr{^\[run-webapp\] .*tagy ghcr\.io/kukam/pwe-base: latest \(pouziti: PWE_IMAGE_TAG=<tag>\)$}m, 'run-webapp.sh up: rada vyjmenuje mistne dostupne tagy (latest)');
    like($err, qr{^\[run-webapp\]   sestaveni: make images ARGS=base .*^\[run-webapp\]   sestaveni: make images ARGS=debugger }ms, 'run-webapp.sh up: rada jmenuje cile sestaveni obou image (base, debugger)');
    is_deeply([map { $_->[2] } grep { $_->[1] eq 'inspect' } calls('docker', 'image')], ["ghcr.io/kukam/pwe-base:$VERSION", "ghcr.io/kukam/pwe-debugger:$VERSION"], 'run-webapp.sh up s profilem static: v lokalnim Dockeru hleda pwe-base a pwe-debugger (zadny image profilu static)');
    log_reset();
    ($rc, $out, $err) = sh({%git, FAKE_DOCKER_INSPECT_RC => 1}, $run, 'db.web', 'mariadb', 'up');
    is_deeply([map { $_->[2] } grep { $_->[1] eq 'inspect' } calls('docker', 'image')], ["ghcr.io/kukam/pwe-mariadb:$VERSION", "ghcr.io/kukam/pwe-debugger:$VERSION"], 'run-webapp.sh up s profilem mariadb: v lokalnim Dockeru hleda pwe-mariadb a pwe-debugger');
    spit($VERSION_FILE, "neni-verze\n");
    log_reset();
    ($rc, $out, $err) = sh({%git}, $run, 'st.web');
    is($rc . '|' . scalar(calls('docker')), '2|0', 'run-webapp.sh: rozbity PWE/VERSION bez PWE_IMAGE_TAG -> kod 2, docker se nevola');
    spit($VERSION_FILE, "$VERSION\n");
    log_reset();
    ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => 'a/b'}, $run, 'st.web');
    is($rc . '|' . scalar(calls('docker')), '2|0', 'run-webapp.sh: neplatny PWE_IMAGE_TAG -> kod 2, docker se nevola');
}

# ---------------------------------------------------------------------------------------------
# smoke-images.sh: co ktery image obsahuje - zavislostni image (pwe-base, pwe-mariadb, pwe-mysql,
# pwe-postgres, pwe-debugger) jen knihovny, zadny kod enginu a zadny web; image vzorovych webu (pwe-example-*)
# vychazeji ze sveho zakladu a obsahuji engine a vzorovy web. Srovnani s pracovni kopii (PWE/VERSION, seznam
# i obsah souboru enginu a vzoroveho webu, entrypoint) jen u image, ktery ji odpovida - mistni image s tagem =
# verze pracovni kopie, nebo vynucene volbou --tree. Image s jinym tagem (jina verze, latest) a image
# z registru by srovnani hlasilo jako chybne, i kdyz jsou v poradku.
# ---------------------------------------------------------------------------------------------
{
    my $smoke = "$REPO/PWE/tools/smoke-images.sh";
    my %git   = (FAKE_GIT_BRANCH => 'pwe.ai');
    my ($rc, $out, $err);
    my @deps     = PWE::ToolEnv::image_names('deps');
    my @examples = PWE::ToolEnv::image_names('examples');
    # image vzoroveho webu: [jmeno, vzorovy web, profil, zakladni image]
    my @samples = (['pwe-example-static', 'example.web', 'static', 'pwe-base'], ['pwe-example-mariadb', 'example-db.web', 'mariadb', 'pwe-mariadb'],
        ['pwe-example-mysql', 'example-db.web', 'mysql', 'pwe-mysql'], ['pwe-example-postgres', 'example-db.web', 'postgres', 'pwe-postgres']);

    # Falesny docker pro smoke-images.sh (misto obecneho ze $T/bin). Jmeno image pozna z argumentu
    # <registr>/<jmeno>:<tag>. Chovani:
    #   FAKE_SMOKE_VERSION       obsah /PWE/PWE/VERSION v image vzoroveho webu; FAKE_SMOKE_LABEL = jeho popisek version
    #                            (vychozi = verze); FAKE_SMOKE_DEPS_LABEL = popisek version zavislostnich image (vychozi prazdny)
    #   FAKE_SMOKE_FILES         soubor s vystupem cksum pro soubory enginu v image ("<soucet> <velikost> ./<cesta>");
    #                            FAKE_SMOKE_WEB_FILES / FAKE_SMOKE_DBWEB_FILES = totez pro vzorovy web example.web / example-db.web
    #   FAKE_SMOKE_ENTRY         "<soucet> <velikost>" souboru /usr/local/bin/entrypoint.sh v image
    #   FAKE_SMOKE_MISSING       image (oddelene mezerou), ktere v lokalnim Dockeru nejsou
    #   FAKE_SMOKE_OLD_BASE      image vzorovych webu, ktere jsou sestavene nad jinym zakladem, nez je mistni zakladni image;
    #                            FAKE_SMOKE_NO_OWN_LAYERS = image vzorovych webu bez vlastnich vrstev (stejne vrstvy jako zaklad)
    #   FAKE_SMOKE_HAS_ENGINE    zavislostni image, ve kterych je kod enginu (/PWE/PWE); FAKE_SMOKE_HAS_WEB = je v nich web;
    #                            FAKE_SMOKE_HAS_ENV = maji zapecene PWE_CONF_pwe_home / PWE_PROFILE
    #   FAKE_SMOKE_WEB_BAD       image, ve kterych kontrola vzoroveho webu (sh -c s --read-only) selze
    #   FAKE_SMOKE_NOWARN        image, jejichz entrypoint pri startu serveru (FCGI_SOCKET_PATH, prikaz true) o vzorovem
    #                            webu nevaruje; FAKE_SMOKE_WARN_EXTRA = image, ktere k varovani pridaji dalsi radek
    #   FAKE_SMOKE_CGI           pwe-example-static, vychozi prikaz: ok (stranka) | status (Status: 500) | crash (engine spadne)
    #   FAKE_SMOKE_CGI_RO        pwe-example-static, vychozi prikaz s --read-only: ok (jako FAKE_SMOKE_CGI) | rofs (engine
    #                            narazi na souborovy system jen pro cteni a spadne) | rowarn (stranka, ale na stderr
    #                            "Read-only file system")
    #   FAKE_SMOKE_DB            databazove profily, vychozi prikaz: noconnect (skonci na pripojeni) | nodriver |
    #                            wrongconf (jina konfigurace nez profilu) | started (engine nabehl)
    # Vsechny ostatni kontroly v kontejneru prochazeji.
    spit("$T/bin-smoke/docker", <<'EOS', 0755);
#!/bin/bash
{ printf 'docker'; for a in "$@"; do printf '\t%s' "${a//$'\n'/ }"; done; printf '\n'; } >> "$FAKE_LOG"
name=""
for a in "$@"; do
    case "$a" in
        */pwe:* | */pwe-*:*) name="${a##*/}"; name="${name%%:*}" ;;
    esac
done
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
example=0
base=""
case "$name" in
    pwe-example-static) example=1; base="pwe-base" ;;
    pwe-example-*)      example=1; base="pwe-${name#pwe-example-}" ;;
esac
case "$1 $2" in
    "image inspect")
        if in_list "$name" "${FAKE_SMOKE_MISSING:-}"; then exit 1; fi
        case "$*" in
            *org.opencontainers.image.title*)   echo "$name" ;;
            *org.opencontainers.image.version*) if [ "$example" = 1 ]; then echo "${FAKE_SMOKE_LABEL-$FAKE_SMOKE_VERSION}"; else echo "${FAKE_SMOKE_DEPS_LABEL:-}"; fi ;;
            *org.opencontainers.image.revision*) if [ "$example" = 1 ]; then echo "${FAKE_SMOKE_REVISION:-}"; fi ;;
            *org.opencontainers.image.created*)  if [ "$example" = 1 ]; then echo "${FAKE_SMOKE_CREATED:-}"; fi ;;
            *"{{.Id}}"*)                        echo "sha256:0123456789abcdef0123456789abcdef" ;;
            *RootFS.Layers*)
                if [ "$example" = 1 ]; then
                    if in_list "$name" "${FAKE_SMOKE_OLD_BASE:-}"; then
                        printf 'sha256:ubuntu\nsha256:stary-%s\n\n' "$base"
                    else
                        printf 'sha256:ubuntu\nsha256:%s\n\n' "$base"
                    fi
                    if ! in_list "$name" "${FAKE_SMOKE_NO_OWN_LAYERS:-}"; then printf 'sha256:engine\nsha256:web-%s\n\n' "$name"; fi
                else
                    printf 'sha256:ubuntu\nsha256:%s\n\n' "$name"
                fi
                ;;
        esac
        exit 0
        ;;
esac
if [ "$1" = run ]; then
    case "$*" in
        *" uname -m")                                     echo "x86_64" ;;
        *" cat /PWE/PWE/VERSION")                         printf '%s\n' "$FAKE_SMOKE_VERSION" ;;
        *" cksum /usr/local/bin/entrypoint.sh")           printf '%s /usr/local/bin/entrypoint.sh\n' "$FAKE_SMOKE_ENTRY" ;;
        *"-exec cksum "*" sh /PWE/PWE")                   cat "$FAKE_SMOKE_FILES" ;;
        *"-exec cksum "*" sh /PWE/webapps/example.web")   cat "$FAKE_SMOKE_WEB_FILES" ;;
        *"-exec cksum "*" sh /PWE/webapps/example-db.web") cat "$FAKE_SMOKE_DBWEB_FILES" ;;
        *"/PWE/PWE v zavislostnim image byt nema"*)
            if in_list "$name" "${FAKE_SMOKE_HAS_ENGINE:-}"; then echo "/PWE/PWE v zavislostnim image byt nema, je tam: Libs pwe.fcgi "; exit 1; fi ;;
        *"v /PWE/webapps byt nic nema"*)
            if in_list "$name" "${FAKE_SMOKE_HAS_WEB:-}"; then echo "v /PWE/webapps byt nic nema, je tam: example-db.web "; exit 1; fi ;;
        *"v zavislostnim image byt nema (je "*)
            if in_list "$name" "${FAKE_SMOKE_HAS_ENV:-}"; then echo 'PWE_PROFILE v zavislostnim image byt nema (je "mariadb")'; exit 1; fi ;;
        *" FCGI_SOCKET_PATH=:7779 "*" true")
            web="example-db.web"
            if [ "$name" = pwe-example-static ]; then web="example.web"; fi
            if ! in_list "$name" "${FAKE_SMOKE_NOWARN:-}"; then
                echo "[entrypoint] VAROVANI: bezi vzorovy web $web zapeceny v image (ukazka: kazdy navstevnik ma skupinu admin vcetne generatoru kodu pweCreator) - neni urcen pro verejny provoz" >&2
            fi
            if in_list "$name" "${FAKE_SMOKE_WARN_EXTRA:-}"; then echo "[entrypoint] VAROVANI: neznamy PWE_PROFILE='x'" >&2; fi
            ;;
        *" SCRIPT_FILENAME=/pwe.fcgi "*)
            if [ "$name" = pwe-example-static ]; then
                case "$*" in
                    *" --read-only "*)
                        case "${FAKE_SMOKE_CGI_RO:-ok}" in
                            rofs)   echo "[E] Libs::Pages:345 :: mkdir /PWE/webapps/example.web/ramdisk/templates//PWE: Read-only file system" >&2; exit 30 ;;
                            rowarn) echo "mkdir: cannot create directory '/PWE/webapps/example.web/temp': Read-only file system" >&2 ;;
                        esac
                        ;;
                esac
                case "${FAKE_SMOKE_CGI:-ok}" in
                    ok)     printf 'Set-Cookie: X=1\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n<html><body>vzor</body></html>\n' ;;
                    status) printf 'Status: 500 Internal Server Error\r\nContent-Type: text/html\r\n\r\n<html></html>\n' ;;
                    crash)  echo "Can't locate Template.pm in @INC" >&2; exit 2 ;;
                esac
            else
                profile="${name#pwe-example-}"
                case "${FAKE_SMOKE_DB:-noconnect}" in
                    noconnect) printf '[E] Libs::MyDBI:204 :: Connect to %s dbid:db1 connect_status:0 error:2005 Unknown host\npwe.fcgi: Unable connect to db1, poolid 0 bye...\n' "$profile" >&2; exit 255 ;;
                    nodriver)  echo "install_driver(mysql) failed: Can't locate DBD/mysql.pm in @INC" >&2; exit 255 ;;
                    wrongconf) printf '[E] Libs::MyDBI:204 :: Connect to jina dbid:db1 connect_status:0 error:1\npwe.fcgi: Unable connect to db1, poolid 0 bye...\n' >&2; exit 255 ;;
                    started)   printf 'Content-Type: text/html\r\n\r\n<html></html>\n' ;;
                esac
            fi
            ;;
        *" --read-only "*)
            if in_list "$name" "${FAKE_SMOKE_WEB_BAD:-}"; then echo "chybi pracovni adresar /PWE/webapps/vzor/log (ma vzniknout pri sestaveni)"; exit 1; fi ;;
    esac
fi
exit 0
EOS

    # kopie repozitare v docasnem stromu: entrypoint, vzorove weby a .dockerignore (docasna data, conf/database.conf
    # a testy enginu se do image nedostanou)
    make_path("$REPO/PWE/docker");
    copy("$ROOT/docker/entrypoint.sh", "$REPO/PWE/docker/entrypoint.sh") or die "Nelze zkopirovat docker/entrypoint.sh: $!";
    spit("$REPO/PWE/docker/Dockerfile", "FROM scratch\n");
    spit("$REPO/.dockerignore", "webapps/*/ramdisk\nwebapps/*/log\nwebapps/*/conf/database.conf\nPWE/t\n");
    foreach my $web (qw(example.web example-db.web)) {
        spit("$REPO/webapps/$web/conf/web.conf",                  "{}\n");
        spit("$REPO/webapps/$web/Pages/default/default.pm",       "1;\n");
        spit("$REPO/webapps/$web/ramdisk/templates/stary.tmplc", 'x');
        spit("$REPO/webapps/$web/log/pwe.log",                    'x');
    }
    spit("$REPO/webapps/example-db.web/conf/mariadb.conf", "{}\n");
    symlink('mariadb.conf', "$REPO/webapps/example-db.web/conf/database.conf") or die "symlink: $!";

    # Kontrolni soucty "v image" pocita tentyz program jako smoke-images.sh (cksum): radky "<soucet> <velikost> ./<cesta>".
    # cksum_of(adresar, cesty...) = vystup cksum pro soubory v adresari; soubor, ktery v adresari neni (jen "v image"),
    # dostane pevny soucet.
    my $cksum_of = sub {
        my ($dir, @paths) = @_;
        my @lines;
        foreach my $path (@paths) {
            if (-e "$dir/$path") {
                my ($rc_c, $out_c) = run_cmd({cwd => $dir}, 'cksum', $path);
                die "cksum $dir/$path: kod $rc_c" unless ($rc_c == 0 and $out_c =~ /^(\d+ \d+) /);
                push(@lines, "$1 ./$path\n");
            } else {
                push(@lines, "4242424242 7 ./$path\n");
            }
        }
        return join('', @lines);
    };
    # soubory enginu "v image": stejne jako v kopii repozitare (PWE/ bez t/ a docker/), nebo jine
    my @tree;
    my $walk;
    $walk = sub {
        my ($dir, $rel) = @_;
        opendir(my $dh, $dir) or die "opendir $dir: $!";
        foreach my $e (sort grep { !/^\.\.?$/ } readdir($dh)) {
            next if ($rel eq '' and ($e eq 't' or $e eq 'docker'));
            my $path = length($rel) ? "$rel/$e" : $e;
            if (-d "$dir/$e" and !-l "$dir/$e") { $walk->("$dir/$e", $path); }
            else                                { push(@tree, $path); }
        }
        closedir($dh);
    };
    $walk->("$REPO/PWE", '');
    undef($walk);
    ok((grep { $_ eq 'tools/smoke-images.sh' } @tree) && (grep { $_ eq 'VERSION' } @tree) && !(grep { m{^(?:t|docker)/} } @tree), 'falesny image: soubory enginu = kopie PWE/ bez t/ a docker/');
    my $same_engine = $cksum_of->("$REPO/PWE", @tree);
    spit("$T/smoke-same.lst", $same_engine);
    # stary image: jeden soubor chybi (tools/run-webapp.sh), jeden je navic (Libs/JenVImage.pm) a jeden ma jiny obsah
    # (tools/build-images.sh - stejna cesta, jiny soucet)
    (my $other_engine = $cksum_of->("$REPO/PWE", (grep { $_ ne 'tools/run-webapp.sh' } @tree), 'Libs/JenVImage.pm')) =~ s{^\d+ \d+ (\./tools/build-images\.sh)$}{1 2 $1}m or die 'build-images.sh neni v seznamu';
    spit("$T/smoke-other.lst", $other_engine);
    # jen jiny obsah jednoho souboru (image sestaveny pred posledni zmenou enginu; seznam souboru je stejny)
    (my $changed_engine = $same_engine) =~ s{^\d+ \d+ (\./tools/lib/images\.sh)$}{1 2 $1}m or die 'lib/images.sh neni v seznamu';
    spit("$T/smoke-changed.lst", $changed_engine);
    # soubory vzorovych webu "v image": bez docasnych dat; symlink conf/database.conf zaklada az Dockerfile webu
    # (v kontextu sestaveni neni a do srovnani se nepocita)
    spit("$T/smoke-web.lst",   $cksum_of->("$REPO/webapps/example.web", 'conf/web.conf', 'Pages/default/default.pm'));
    spit("$T/smoke-dbweb.lst", $cksum_of->("$REPO/webapps/example-db.web", 'conf/web.conf', 'conf/mariadb.conf', 'conf/database.conf', 'Pages/default/default.pm'));
    spit("$T/smoke-web-other.lst",   $cksum_of->("$REPO/webapps/example.web", 'conf/web.conf', 'ramdisk/templates/stary.tmplc'));
    spit("$T/smoke-dbweb-other.lst", $cksum_of->("$REPO/webapps/example-db.web", 'conf/web.conf', 'conf/mariadb.conf', 'Pages/default/default.pm', 'Pages/stara/stara.pm'));
    (my $dbweb_changed = slurp("$T/smoke-dbweb.lst")) =~ s{^\d+ \d+ (\./conf/web\.conf)$}{1 2 $1}m or die 'conf/web.conf neni v seznamu';
    spit("$T/smoke-dbweb-changed.lst", $dbweb_changed);
    my ($entry_sum) = $cksum_of->("$REPO/PWE/docker", 'entrypoint.sh') =~ /^(\d+ \d+) /;

    # image = pracovni kopie / image jine verze (jina verze, jine soubory, jiny entrypoint)
    my %same  = (FAKE_SMOKE_VERSION => $VERSION, FAKE_SMOKE_FILES => "$T/smoke-same.lst",  FAKE_SMOKE_WEB_FILES => "$T/smoke-web.lst",       FAKE_SMOKE_DBWEB_FILES => "$T/smoke-dbweb.lst",       FAKE_SMOKE_ENTRY => $entry_sum);
    my %other = (FAKE_SMOKE_VERSION => '1.0.0',  FAKE_SMOKE_FILES => "$T/smoke-other.lst", FAKE_SMOKE_WEB_FILES => "$T/smoke-web-other.lst", FAKE_SMOKE_DBWEB_FILES => "$T/smoke-dbweb-other.lst", FAKE_SMOKE_ENTRY => '1 2');
    my $run_smoke = sub {
        my ($env, @args) = @_;
        log_reset();
        return sh({PATH => "$T/bin-smoke:$T/bin:$SYS_PATH", %git, %{$env}}, $smoke, @args);
    };
    my $tree_checks = sub { return scalar(grep { / cksum / } map { join(' ', @{$_}) } calls('docker', 'run')); };    # vypisy souctu z image (soubory enginu a webu, entrypoint)
    my $E = 'pwe-example-static';    # image vzoroveho webu, na kterem se overuje srovnani s pracovni kopii (se zakladem pwe-base)
    my @one = ('pwe-base', $E);

    # --- image vzoroveho webu: mistni image s tagem = verze pracovni kopie se srovnava ---
    ($rc, $out, $err) = $run_smoke->({%same}, @one);
    is($rc, 0, 'smoke-images.sh: mistni image verze pracovni kopie shodny s pracovni kopii -> kod 0') or diag($out . $err);
    like($out, qr/^OK   $E: VERSION = \Q$VERSION\E \(PWE\/VERSION pracovni kopie\)$/m, 'smoke-images.sh: mistni image verze -> VERSION se srovnava s PWE/VERSION');
    like($out, qr/^OK   $E: popisky image: title=$E, version=\Q$VERSION\E \(revision=neuvedena, created=neuveden\)$/m, 'smoke-images.sh: mistni image verze -> popisek version se srovnava s PWE/VERSION (commit a cas buildu se jen vypisuji)');
    like($out, qr/^OK   $E: soubory enginu v \/PWE\/PWE = pracovni kopie PWE\/ \(seznam i obsah; .*\): \d+ souboru$/m, 'smoke-images.sh: mistni image verze -> soubory enginu (seznam i obsah) se srovnavaji s pracovni kopii');
    like($out, qr/^OK   $E: soubory vzoroveho webu v \/PWE\/webapps\/example\.web = pracovni kopie webapps\/example\.web \(seznam i obsah; bez \.dockerignore\): 2 souboru$/m, 'smoke-images.sh: mistni image verze -> soubory vzoroveho webu (seznam i obsah) se srovnavaji s pracovni kopii');
    like($out, qr/^OK   $E: entrypoint v image \(\/usr\/local\/bin\/entrypoint\.sh\) = PWE\/docker\/entrypoint\.sh pracovni kopie$/m, 'smoke-images.sh: mistni image verze -> entrypoint se srovnava s pracovni kopii');
    like($out, qr/^OK   pwe-base: entrypoint v image \(\/usr\/local\/bin\/entrypoint\.sh\) = PWE\/docker\/entrypoint\.sh pracovni kopie$/m, 'smoke-images.sh: entrypoint se srovnava i u zavislostniho image (jediny soubor, ktery z pracovni kopie obsahuje)');
    like($out, qr/^OK   $E: vychazi z image pwe-base tehoz tagu \(vrstvy zakladu jsou zacatkem vrstev image\): 2 vrstev zakladu$/m, 'smoke-images.sh: image vzoroveho webu vychazi z mistniho zakladniho image (vrstvy zakladu jsou zacatkem jeho vrstev)');
    unlike($out, qr/^(?:SKIP|FAIL)/m, 'smoke-images.sh: mistni image verze -> nic se nepreskakuje ani neselze');
    like($err, qr/^\[smoke-images\] registr=ghcr\.io\/kukam tag=\Q$VERSION\E verze=\Q$VERSION\E .*srovnani-s-pracovni-kopii=ano image=pwe-base $E$/m, 'smoke-images.sh: uvodni radek - vychozi tag = verze z PWE/VERSION, srovnava se s pracovni kopii');
    like($err, qr/^\[smoke-images\] OK: \d+ kontrol$/m, 'smoke-images.sh: souhrn bez preskocenych kontrol');
    is(scalar(calls('git')), 0, 'smoke-images.sh: git se nevola (tag pracovni kopie = verze, ne vetev)');
    my @all_runs = calls('docker', 'run');
    ok(@all_runs > 10 && !(grep { my $r = $_; !(grep { $_ eq "ghcr.io/kukam/pwe-base:$VERSION" or $_ eq "ghcr.io/kukam/$E:$VERSION" } @{$r}) } @all_runs), 'smoke-images.sh: vsechny kontejnery bezi z image <registr>/<image>:<verze>');
    ok(!(grep { my $r = $_; !(has_pair($r, '--pull', 'never') && has_pair($r, '--network', 'none')) } @all_runs), 'smoke-images.sh: kontejnery bezi jen z lokalniho image (--pull never) a bez site (--network none)');
    is($tree_checks->(), 4, 'smoke-images.sh: z image se ctou soucty souboru enginu, vzoroveho webu a entrypointu obou image');
    ($rc, $out, $err) = $run_smoke->({%same, FAKE_SMOKE_REVISION => $HEAD, FAKE_SMOKE_CREATED => '2026-11-16T12:00:00Z'}, @one);
    like($out, qr/^OK   $E: popisky image: title=$E, version=\Q$VERSION\E \(revision=$HEAD, created=2026-11-16T12:00:00Z\)$/m, 'smoke-images.sh: commit a cas buildu image vzoroveho webu se vypisuji');

    # stary mistni image (jina verze, jine soubory, jiny entrypoint) je FAIL
    ($rc, $out, $err) = $run_smoke->({%other}, @one);
    is($rc, 1, 'smoke-images.sh: mistni image, ktery se od pracovni kopie lisi -> kod 1 (stary image)');
    like($out, qr/^FAIL $E: VERSION = \Q$VERSION\E \(PWE\/VERSION pracovni kopie\)\n\s+v image je verze 1\.0\.0, v pracovni kopii \Q$VERSION\E$/m, 'smoke-images.sh: stary image -> FAIL verze');
    like($out, qr/^FAIL $E: popisky image: title=$E, version=\Q$VERSION\E\n\s+popisek org\.opencontainers\.image\.version je '1\.0\.0', ocekavano '\Q$VERSION\E' \(PWE\/VERSION\)$/m, 'smoke-images.sh: stary image -> FAIL popisku version');
    like($out, qr/^FAIL $E: soubory enginu .*\n\s+v image chybi .*\n\s+tools\/run-webapp\.sh\n\s+v image navic .*\n\s+Libs\/JenVImage\.pm\n\s+v image maji jiny obsah nez v pracovni kopii \(image je starsi nez posledni zmena - sestav znovu: make images\):\n\s+tools\/build-images\.sh$/m,
        'smoke-images.sh: stary image -> FAIL souboru enginu (chybi, navic i jiny obsah)');
    like($out, qr/^FAIL $E: entrypoint v image .*\n\s+obsah se lisi \(cksum v image: 1 2, v pracovni kopii: \Q$entry_sum\E\) - image je starsi nez posledni zmena entrypointu; sestav znovu: make images$/m, 'smoke-images.sh: stary image -> FAIL entrypointu (obsah se lisi)');
    like($out, qr/^FAIL pwe-base: entrypoint v image /m, 'smoke-images.sh: stary zavislostni image -> FAIL entrypointu');

    # stejny seznam souboru, ale jiny OBSAH jednoho souboru enginu / vzoroveho webu (image sestaveny pred posledni zmenou)
    ($rc, $out, $err) = $run_smoke->({%same, FAKE_SMOKE_FILES => "$T/smoke-changed.lst"}, @one);
    is($rc, 1, 'smoke-images.sh: soubor enginu ma v image jiny obsah nez v pracovni kopii -> kod 1');
    like($out, qr/^FAIL $E: soubory enginu .*\n\s+v image maji jiny obsah nez v pracovni kopii .*\n\s+tools\/lib\/images\.sh$/m, 'smoke-images.sh: jiny obsah souboru enginu -> FAIL jmenuje soubor');
    unlike($out, qr/v image chybi|v image navic/, 'smoke-images.sh: jiny obsah souboru enginu -> seznam souboru se nelisi (nic nechybi ani neni navic)');
    is(scalar(() = $out =~ /^FAIL /mg), 1, 'smoke-images.sh: jiny obsah jednoho souboru enginu -> prave jeden FAIL');
    ($rc, $out, $err) = $run_smoke->({%same, FAKE_SMOKE_DBWEB_FILES => "$T/smoke-dbweb-changed.lst"}, 'pwe-mariadb', 'pwe-example-mariadb');
    is($rc, 1, 'smoke-images.sh: soubor vzoroveho webu ma v image jiny obsah nez v pracovni kopii -> kod 1');
    like($out, qr/^FAIL pwe-example-mariadb: soubory vzoroveho webu v \/PWE\/webapps\/example-db\.web .*\n\s+v image maji jiny obsah nez v pracovni kopii .*\n\s+conf\/web\.conf$/m, 'smoke-images.sh: jiny obsah souboru vzoroveho webu -> FAIL jmenuje soubor');

    # image s jinym tagem (PWE_IMAGE_TAG != verze pracovni kopie; i latest): srovnani se preskoci, overi se vnitrni soulad
    foreach my $tag ('latest', '1.0.0') {
        ($rc, $out, $err) = $run_smoke->({%other, PWE_IMAGE_TAG => $tag}, @one);
        is($rc, 0, "smoke-images.sh: image s tagem $tag v poradku -> kod 0 (bez srovnani s pracovni kopii)") or diag($out . $err);
        like($out, qr/^SKIP $E: srovnani s pracovni kopii \(PWE\/VERSION, soubory enginu a vzoroveho webu, entrypoint\)\n\s+tag \Q$tag\E neni verze teto pracovni kopie \(\Q$VERSION\E\) - [^\n]*; overuje se jen vnitrni soulad image \(vynuceni srovnani: --tree\)$/m,
            "smoke-images.sh: image vzoroveho webu s tagem $tag -> SKIP s vysvetlenim a radou --tree");
        like($out, qr/^SKIP pwe-base: srovnani s pracovni kopii \(entrypoint\)\n\s+tag \Q$tag\E neni verze teto pracovni kopie \(\Q$VERSION\E\) - [^\n]* \(vynuceni srovnani: --tree\)$/m, "smoke-images.sh: zavislostni image s tagem $tag -> SKIP srovnani entrypointu");
        like($out, qr/^OK   $E: VERSION v image = 1\.0\.0 \(tvar X\.Y\.Z\)$/m, "smoke-images.sh: image s tagem $tag -> VERSION v image ma tvar X.Y.Z");
        like($out, qr/^OK   $E: popisky image: title=$E, version=1\.0\.0 /m, "smoke-images.sh: image s tagem $tag -> popisek version = VERSION v image");
        unlike($out, qr/^FAIL/m, "smoke-images.sh: image s tagem $tag -> zadny FAIL");
        is($tree_checks->(), 0, "smoke-images.sh: image s tagem $tag -> soucty souboru se z image vubec nectou");
        like($err, qr/tag=\Q$tag\E verze=\Q$VERSION\E .*srovnani-s-pracovni-kopii=ne /, "smoke-images.sh: image s tagem $tag -> uvodni radek rika, ze se nesrovnava");
        like($err, qr/^\[smoke-images\] OK: \d+ kontrol \(preskoceno: 2\)$/m, "smoke-images.sh: image s tagem $tag -> souhrn uvadi pocet preskocenych kontrol (jedna na image)");
        ok(!(grep { my $r = $_; !(grep { $_ eq "ghcr.io/kukam/pwe-base:$tag" or $_ eq "ghcr.io/kukam/$E:$tag" } @{$r}) } calls('docker', 'run')), "smoke-images.sh: kontroluji se image s tagem $tag");
    }
    unlike($out, qr/^::warning/m, 'smoke-images.sh: mimo GitHub Actions zadna anotace');
    ($rc, $out, $err) = $run_smoke->({%other, PWE_IMAGE_TAG => 'latest', GITHUB_ACTIONS => 'true'}, @one);
    like($out, qr/^::warning title=Kourova kontrola $E preskocena::srovnani s pracovni kopii/m, 'smoke-images.sh: v GitHub Actions je preskocena kontrola videt jako anotace ::warning');

    # vnitrni nesoulad image s jinym tagem je porad chyba
    ($rc, $out, $err) = $run_smoke->({%other, PWE_IMAGE_TAG => 'latest', FAKE_SMOKE_LABEL => '2.0.0'}, @one);
    is($rc, 1, 'smoke-images.sh: image s jinym tagem, popisek version != VERSION v image -> kod 1');
    like($out, qr/^FAIL $E: popisky image: title=$E, version=1\.0\.0\n\s+popisek org\.opencontainers\.image\.version je '2\.0\.0', ocekavano '1\.0\.0' \(VERSION v image\)$/m, 'smoke-images.sh: vnitrni nesoulad -> FAIL popisku version proti VERSION v image (tag verze nesmi ukazovat na jiny kod)');
    ($rc, $out, $err) = $run_smoke->({%other, PWE_IMAGE_TAG => 'latest', FAKE_SMOKE_VERSION => 'vyvoj'}, @one);
    is($rc, 1, 'smoke-images.sh: image s jinym tagem, VERSION neni X.Y.Z -> kod 1');
    like($out, qr/^FAIL $E: VERSION v image ma tvar X\.Y\.Z\n\s+v image je verze 'vyvoj'$/m, 'smoke-images.sh: VERSION v image, ktera neni X.Y.Z -> FAIL');

    # image z registru (--pull always) pod tagem verze: taky se nesrovnava
    ($rc, $out, $err) = $run_smoke->({%other}, '--pull', 'always', @one);
    is($rc, 0, 'smoke-images.sh --pull always: image z registru v poradku -> kod 0');
    like($out, qr/^SKIP $E: srovnani s pracovni kopii .*\n\s+image se stahuje z registru \(--pull always\)/m, 'smoke-images.sh --pull always: SKIP s vysvetlenim');
    is_deeply([grep { $_->[0] eq 'pull' } calls('docker')], [['pull', "ghcr.io/kukam/pwe-base:$VERSION"], ['pull', "ghcr.io/kukam/$E:$VERSION"]], 'smoke-images.sh --pull always: stahnou se image <image>:<verze> (docker pull)');

    # --tree: srovnani vynucene (napr. image z teto pracovni kopie pod tagem latest)
    ($rc, $out, $err) = $run_smoke->({%same, PWE_IMAGE_TAG => 'latest'}, '--tree', @one);
    is($rc, 0, 'smoke-images.sh --tree: image pod tagem latest shodny s pracovni kopii -> kod 0') or diag($out . $err);
    unlike($out, qr/^SKIP/m, 'smoke-images.sh --tree: nic se nepreskakuje');
    is($tree_checks->(), 4, 'smoke-images.sh --tree: soucty souboru se srovnavaji');
    ($rc, $out, $err) = $run_smoke->({%other, PWE_IMAGE_TAG => 'latest'}, '--tree', '--pull', 'always', $E);
    is($rc, 1, 'smoke-images.sh --tree: image, ktery se od pracovni kopie lisi -> kod 1 (i s --pull always)');
    is(scalar(() = $out =~ /^FAIL $E: /mg), 5, 'smoke-images.sh --tree: FAIL verze, popisku, souboru enginu, souboru vzoroveho webu i entrypointu');

    # --no-tree: srovnani vypnute i u mistniho image verze pracovni kopie
    ($rc, $out, $err) = $run_smoke->({%other}, '--no-tree', @one);
    is($rc, 0, 'smoke-images.sh --no-tree: mistni image se s pracovni kopii nesrovnava -> kod 0');
    like($out, qr/^SKIP $E: srovnani s pracovni kopii .*\n\s+volba --no-tree; /m, 'smoke-images.sh --no-tree: SKIP s vysvetlenim');

    # tag pracovni kopie = verze: PWE_IMAGE_TAG shodny s verzi se srovnava; na stavu gitu nezalezi
    ($rc, $out, $err) = $run_smoke->({%same, PWE_IMAGE_TAG => $VERSION}, @one);
    unlike($out, qr/^SKIP/m, 'smoke-images.sh: PWE_IMAGE_TAG shodny s verzi pracovni kopie -> srovnava se');
    foreach my $c ([{FAKE_GIT_BRANCH => 'feature/kosik'}, 'vetev s lomitkem'], [{FAKE_GIT_BRANCH => ''}, 'odpojeny HEAD'], [{PATH => "$T/bin-smoke:$NOGIT_PATH"}, 'bez prikazu git']) {
        ($rc, $out, $err) = $run_smoke->({%same, %{$c->[0]}}, @one);
        like($err, qr/tag=\Q$VERSION\E verze=\Q$VERSION\E .*srovnani-s-pracovni-kopii=ano /, "smoke-images.sh ($c->[1]): tag = verze pracovni kopie, srovnava se");
    }

    # PWE/VERSION bez verze: neni s cim srovnavat ani jak urcit vychozi tag -> kod 2
    spit($VERSION_FILE, "neni-verze\n");
    ($rc, $out, $err) = $run_smoke->({%same}, @one);
    is($rc . '|' . scalar(calls('docker')), '2|0', 'smoke-images.sh: PWE/VERSION bez verze -> kod 2, docker se nevola');
    like($err, qr/neobsahuje verzi enginu tvaru X\.Y\.Z/, 'smoke-images.sh: PWE/VERSION bez verze -> hlaska z pwe_image_version');
    spit($VERSION_FILE, "$VERSION\n");

    # volby a jmena image
    ($rc, $out, $err) = $run_smoke->({%same}, '--strom', 'pwe-base');
    is($rc, 2, 'smoke-images.sh: neznama volba -> kod 2');
    ($rc, $out, $err) = $run_smoke->({%same}, 'pwe-neznamy');
    is($rc . '|' . scalar(calls('docker')), '2|0', 'smoke-images.sh: neznamy image -> kod 2, docker se nevola');
    like($err, qr/^Neznamy image pwe-neznamy \(image: pwe-base pwe-mariadb pwe-mysql pwe-postgres pwe-debugger pwe-example-static pwe-example-mariadb pwe-example-mysql pwe-example-postgres\)$/, 'smoke-images.sh: neznamy image -> hlaska vyjmenuje 9 image');
    # image zrusene pri prestavbe: odmitnuti s vysvetlenim
    foreach my $c (['pwe', qr/^Image pwe \(jen engine\) byl zrusen: engine je soucasti image webu/], ['pwe-static', qr/^Image pwe-static byl zrusen: web bez databaze bezi nad pwe-base, vzorovy web bez databaze je pwe-example-static/], ['static', qr/^Image pwe-static byl zrusen/]) {
        ($rc, $out, $err) = $run_smoke->({%same}, 'pwe-base', $c->[0]);
        is($rc . '|' . scalar(calls('docker')), '2|0', "smoke-images.sh $c->[0]: zruseny image -> kod 2, docker se nevola");
        like($err, $c->[1], "smoke-images.sh $c->[0]: zruseny image -> hlaska rika, ze byl zrusen a co ho nahrazuje");
    }
    ($rc, $out, $err) = sh({%git}, $smoke, '--help');
    like($out, qr/--tree .*--no-tree /s, 'smoke-images.sh --help: popisuje --tree a --no-tree');
    like($out, qr/zavislostni image\s+pwe-base pwe-mariadb pwe-mysql pwe-postgres pwe-debugger - jen knihovny, zadny kod enginu, zadny web/, 'smoke-images.sh --help: zavislostni image jsou jen knihovny (zadny kod enginu, zadny web)');
    like($out, qr/vzorove weby\s+pwe-example-static pwe-example-mariadb pwe-example-mysql pwe-example-postgres/, 'smoke-images.sh --help: vyjmenuje image vzorovych webu');
    like($out, qr/Srovnava se OBSAH souboru/, 'smoke-images.sh --help: srovnani s pracovni kopii srovnava obsah souboru, ne jen seznam');
    like($out, qr/--read-only a tmpfs pres pracovni adresare webu/, 'smoke-images.sh --help: beh s --read-only popisuje vcetne tmpfs pres pracovni adresare');
    like($out, qr/Jen s --read-only, bez zapisovatelnych pracovnich adresaru,\s+engine request neobslouzi/, 'smoke-images.sh --help: netvrdi, ze image bezi jen s --read-only');
    unlike($out, qr/pwe-static|\bimage pwe(?![\w.-])|vsech 7|COPY --from=pwe/, 'smoke-images.sh --help: zadna zminka o zrusenych image pwe a pwe-static');
    # vyjimky z enginu v image (t, docker): skript = PWE::ToolEnv::engine_image_excludes
    like(slurp($smoke), qr/^ENGINE_EXCLUDES="@{[join(' ', PWE::ToolEnv::engine_image_excludes())]}"$/m, 'smoke-images.sh: polozky enginu mimo image (ENGINE_EXCLUDES) = PWE::ToolEnv::engine_image_excludes()');

    # --- vsech 9 image: zavislostni image bez enginu a bez webu, image vzorovych webu s enginem a vzorovym webem ---
    ($rc, $out, $err) = $run_smoke->({%same});
    is($rc, 0, 'smoke-images.sh (vsech 9 image shodnych s pracovni kopii): kod 0') or diag($out . $err);
    unlike($out, qr/^(?:FAIL|SKIP)/m, 'smoke-images.sh (vsech 9 image): zadny FAIL ani SKIP');
    is_deeply([$out =~ /^OK   (\S+): kontejner se spusti pres entrypoint image/mg], [@deps, @examples], 'smoke-images.sh bez vyberu: vsech 9 image v pevnem poradi (zavislostni pred vzorovymi)');
    like($err, qr/ image=@{[join(' ', @deps, @examples)]}$/m, 'smoke-images.sh bez vyberu: uvodni radek vyjmenuje vsech 9 image');
    foreach my $name (@deps) {
        like($out, qr/^OK   \Q$name\E: bez kodu enginu \(\/PWE\/PWE v image neni\)$/m, "smoke-images.sh: $name je bez kodu enginu");
        like($out, qr/^OK   \Q$name\E: bez webu \(\/PWE\/webapps je prazdny\)$/m, "smoke-images.sh: $name je bez webu");
        like($out, qr/^OK   \Q$name\E: ENV: PWE_CONF_pwe_core=\/PWE\/PWE, zadne PWE_CONF_pwe_home ani PWE_PROFILE$/m, "smoke-images.sh: $name nema zapecene nastaveni webu");
        like($out, qr/^OK   \Q$name\E: popisky image: title=\Q$name\E, version prazdna$/m, "smoke-images.sh: $name - popisek title a prazdna verze (engine neobsahuje)");
        like($out, qr/^OK   \Q$name\E: entrypoint v image /m, "smoke-images.sh: $name - entrypoint = pracovni kopie");
        unlike($out, qr/^\w+\s+\Q$name\E: (?:perl -c pwe\.fcgi|VERSION|vzorovy web|vychazi z image|vychozi prikaz|soubory enginu)/m, "smoke-images.sh: $name se nekontroluje jako image s enginem a webem");
    }
    like($out, qr/^OK   pwe-base: bez ovladacu databazi$/m,                                 'smoke-images.sh: pwe-base je bez ovladacu databazi');
    like($out, qr/^OK   pwe-mariadb: DBD::mysql a DBD::MariaDB$/m,                          'smoke-images.sh: pwe-mariadb ma DBD::mysql a DBD::MariaDB');
    like($out, qr/^OK   pwe-mariadb: bez ovladacu jinych profilu \(DBD::Pg\)$/m,            'smoke-images.sh: pwe-mariadb nema ovladac jineho profilu');
    like($out, qr/^OK   pwe-mysql: DBD::mysql$/m,                                           'smoke-images.sh: pwe-mysql ma DBD::mysql');
    like($out, qr/^OK   pwe-mysql: bez ovladacu jinych profilu \(DBD::MariaDB DBD::Pg\)$/m, 'smoke-images.sh: pwe-mysql nema ovladace jinych profilu');
    like($out, qr/^OK   pwe-postgres: DBD::Pg$/m,                                           'smoke-images.sh: pwe-postgres ma DBD::Pg');
    like($out, qr/^OK   pwe-postgres: bez ovladacu jinych profilu \(DBD::mysql DBD::MariaDB\)$/m, 'smoke-images.sh: pwe-postgres nema ovladace jinych profilu');
    like($out, qr/^OK   pwe-debugger: ovladace vsech databazi$/m,                           'smoke-images.sh: pwe-debugger ma ovladace vsech databazi');
    foreach my $p (@samples) {
        my ($name, $web, $profile, $base) = @{$p};
        my $w = quotemeta($web);
        unlike($out, qr/^\w+\s+\Q$name\E: bez (?:kodu enginu|webu)/m, "smoke-images.sh: $name se nekontroluje jako image bez enginu a bez webu");
        like($out, qr/^OK   \Q$name\E: vychazi z image \Q$base\E tehoz tagu \(vrstvy zakladu jsou zacatkem vrstev image\): \d+ vrstev zakladu$/m, "smoke-images.sh: $name vychazi ze zakladu $base");
        like($out, qr/^OK   \Q$name\E: perl -c pwe\.fcgi$/m, "smoke-images.sh: $name - perl -c pwe.fcgi (image obsahuje engine)");
        like($out, qr/^OK   \Q$name\E: obsah \/PWE \(LICENSE, PWE, webapps\) a \/PWE\/PWE /m, "smoke-images.sh: $name - obsah /PWE a /PWE/PWE");
        like($out, qr/^OK   \Q$name\E: VERSION = \Q$VERSION\E \(PWE\/VERSION pracovni kopie\)$/m, "smoke-images.sh: $name - verze enginu = PWE/VERSION");
        like($out, qr/^OK   \Q$name\E: popisky image: title=\Q$name\E, version=\Q$VERSION\E /m, "smoke-images.sh: $name - popisek version = verze enginu");
        like($out, qr/^OK   \Q$name\E: soubory enginu v \/PWE\/PWE = pracovni kopie PWE\/ .*: \d+ souboru$/m, "smoke-images.sh: $name - soubory enginu = pracovni kopie");
        like($out, qr/^OK   \Q$name\E: vzorovy web $w ze sestaveni \(--read-only: entrypoint nic nezalozi\): /m, "smoke-images.sh: $name - vzorovy web $web tak, jak ho zalozilo sestaveni");
        like($out, qr/^OK   \Q$name\E: entrypoint pri startu serveru \(FCGI_SOCKET_PATH\) varuje, ze bezi vzorovy web $w \(neni urcen pro verejny provoz\)$/m, "smoke-images.sh: $name - entrypoint pri startu serveru varuje, ze bezi vzorovy web");
        like($out, qr/^OK   \Q$name\E: soubory vzoroveho webu v \/PWE\/webapps\/$w = pracovni kopie webapps\/$w \(seznam i obsah; bez \.dockerignore\): \d+ souboru$/m, "smoke-images.sh: $name - soubory vzoroveho webu = pracovni kopie (bez docasnych dat a conf/database.conf)");
        my $ref = "ghcr.io/kukam/$name:$VERSION";
        my @cgi_runs = grep { $_->[-1] eq $ref and (grep { $_ eq 'SCRIPT_FILENAME=/pwe.fcgi' } @{$_}) } calls('docker', 'run');
        my @web_runs = grep { (grep { $_ eq '--read-only' } @{$_}) and (grep { $_ eq $ref } @{$_}) and !(grep { $_ eq 'SCRIPT_FILENAME=/pwe.fcgi' } @{$_}) } calls('docker', 'run');
        ok(@web_runs == 1 && $web_runs[0]->[-2] eq $web && $web_runs[0]->[-1] eq $profile, "smoke-images.sh: $name - kontrola vzoroveho webu bezi s --read-only (bez enginu) a dostane web $web a profil $profile");
        my ($warn_run) = grep { $_->[-1] eq 'true' and $_->[-2] eq $ref } calls('docker', 'run');
        ok($warn_run && has_pair($warn_run, '-e', 'FCGI_SOCKET_PATH=:7779') && has_pair($warn_run, '--network', 'none'), "smoke-images.sh: $name - varovani o vzorovem webu se overuje startem s FCGI_SOCKET_PATH a prikazem true (server se nespousti)");
        my ($cmd_run) = grep { !(grep { $_ eq '--read-only' } @{$_}) } @cgi_runs;
        ok($cmd_run && has_pair($cmd_run, '--network', 'none') && has_pair($cmd_run, '-e', 'REQUEST_METHOD=GET'), "smoke-images.sh: $name - vychozi prikaz image (za jmenem image nic) jako jeden request CGI, bez site");
        if ($profile eq 'static') {
            like($out, qr/^OK   \Q$name\E: bez ovladacu databazi$/m, "smoke-images.sh: $name je bez ovladacu databazi (zaklad pwe-base)");
            like($out, qr/^OK   \Q$name\E: vychozi prikaz image: jeden request v rezimu CGI vrati stranku vzoroveho webu example\.web$/m, "smoke-images.sh: $name - vychozi prikaz vrati stranku vzoroveho webu");
            ok($cmd_run && !(grep { /^PWE_CONF_dbi_/ } @{$cmd_run}), "smoke-images.sh: $name - request bez nastaveni databaze");
            # beh s korenovym souborovym systemem jen pro cteni: engine se opravdu spusti (vychozi prikaz image),
            # zapisovatelne jsou jen pracovni adresare webu (tmpfs)
            like($out, qr/^OK   \Q$name\E: vychozi prikaz image s korenovym souborovym systemem jen pro cteni \(--read-only, pracovni adresare webu jako tmpfs\): jeden request v rezimu CGI vrati stranku vzoroveho webu example\.web$/m,
                "smoke-images.sh: $name - vychozi prikaz vrati stranku i s korenovym souborovym systemem jen pro cteni");
            my @ro_runs = grep { (grep { $_ eq '--read-only' } @{$_}) } @cgi_runs;
            is(scalar(@cgi_runs) . '|' . scalar(@ro_runs), '2|1', "smoke-images.sh: $name - vychozi prikaz bezi dvakrat: bezne a s --read-only");
            ok(@ro_runs == 1 && !(grep { !has_pair($ro_runs[0], '--tmpfs', "/PWE/webapps/example.web/$_") } qw(ramdisk sessions uploadfile log)),
                "smoke-images.sh: $name - beh s --read-only ma tmpfs pres ramdisk, sessions, uploadfile a log vzoroveho webu");
            is(scalar(grep { $_ eq '--tmpfs' } @{$ro_runs[0] || []}), 4, "smoke-images.sh: $name - beh s --read-only ma prave ctyri tmpfs (nic dalsiho zapisovatelneho)");
            ok(@ro_runs == 1 && has_pair($ro_runs[0], '--network', 'none') && has_pair($ro_runs[0], '-e', 'REQUEST_METHOD=GET'), "smoke-images.sh: $name - beh s --read-only je tentyz request CGI bez site");
        }
        else {
            like($out, qr/^OK   \Q$name\E: DBD::/m, "smoke-images.sh: $name ma ovladac databaze sveho zakladu");
            like($out, qr/^OK   \Q$name\E: vychozi prikaz image bez databaze: engine nacte konfiguraci a ovladac profilu $profile a skonci az na pripojeni$/m, "smoke-images.sh: $name - bez databaze engine dojde az k pripojeni");
            ok($cmd_run && has_pair($cmd_run, '-e', 'PWE_CONF_dbi_db1_trayconnect=1'), "smoke-images.sh: $name - start bez databaze jen s jednim pokusem o pripojeni (trayconnect=1)");
            is(scalar(@cgi_runs), 1, "smoke-images.sh: $name - engine se s --read-only nespousti (bez databaze skonci driv, nez do pracovnich adresaru zapise - kontrola by nic nerekla)");
            unlike($out, qr/^\w+\s+\Q$name\E: [^\n]*jen pro cteni/m, "smoke-images.sh: $name - zadna kontrola netvrdi beh se souborovym systemem jen pro cteni");
        }
    }

    # poradi a opakovani na prikazove radce: kazdy image jednou, zavislostni pred vzorovymi; jmeno i bez predpony pwe-
    ($rc, $out, $err) = $run_smoke->({%same}, 'example-mysql', 'debugger', 'pwe-mysql', 'pwe-example-mysql', 'mysql', 'base');
    is_deeply([$out =~ /^OK   (\S+): kontejner se spusti pres entrypoint image/mg], [qw(pwe-base pwe-mysql pwe-debugger pwe-example-mysql)], 'smoke-images.sh: vybrane image se kontroluji jednou a v pevnem poradi (zaklad pred vzorovym image)');

    # image s jinym tagem: srovnani s pracovni kopii se preskoci u vsech image, vzorovy web a zaklad se overuji dal
    ($rc, $out, $err) = $run_smoke->({%other, PWE_IMAGE_TAG => 'latest'});
    is($rc, 0, 'smoke-images.sh (vsech 9 image s tagem latest, jina verze nez pracovni kopie): kod 0') or diag($out . $err);
    is_deeply([$out =~ /^SKIP (\S+): srovnani s pracovni kopii/mg], [@deps, @examples], 'smoke-images.sh: srovnani s pracovni kopii se preskoci u kazdeho image');
    like($err, qr/^\[smoke-images\] OK: \d+ kontrol \(preskoceno: 9\)$/m, 'smoke-images.sh: souhrn - 9 preskocenych kontrol');
    is($tree_checks->(), 0, 'smoke-images.sh: bez srovnani se soucty souboru enginu, vzorovych webu ani entrypointu z image nectou');
    is(scalar(() = $out =~ /^OK   pwe-example-\w+: vzorovy web example(?:-db)?\.web ze sestaveni \(--read-only: /mg), 4, 'smoke-images.sh: vzorovy web se overuje i bez srovnani s pracovni kopii');
    is(scalar(() = $out =~ /^OK   pwe-example-\w+: entrypoint pri startu serveru \(FCGI_SOCKET_PATH\) varuje, ze bezi vzorovy web /mg), 4, 'smoke-images.sh: varovani o vzorovem webu se overuje i bez srovnani s pracovni kopii');
    is(scalar(() = $out =~ /^OK   pwe-example-\w+: vychazi z image pwe-\w+ tehoz tagu/mg), 4, 'smoke-images.sh: zaklad image vzoroveho webu se overuje i bez srovnani s pracovni kopii');
    is(scalar(() = $out =~ /^OK   pwe-\w+: bez kodu enginu /mg), 5, 'smoke-images.sh: zavislostni image bez enginu se overuji i bez srovnani s pracovni kopii');

    # zavislostni image, ktery obsahuje engine, web nebo nastaveni webu (image ze starsiho usporadani pod novym tagem)
    ($rc, $out, $err) = $run_smoke->({%same, FAKE_SMOKE_HAS_ENGINE => 'pwe-mariadb', FAKE_SMOKE_HAS_WEB => 'pwe-mariadb', FAKE_SMOKE_HAS_ENV => 'pwe-mariadb', FAKE_SMOKE_DEPS_LABEL => $VERSION}, 'pwe-mariadb');
    is($rc, 1, 'smoke-images.sh: zavislostni image s enginem a webem (starsi usporadani) -> kod 1');
    like($out, qr/^FAIL pwe-mariadb: bez kodu enginu \(\/PWE\/PWE v image neni\)\n\s+\/PWE\/PWE v zavislostnim image byt nema, je tam: /m, 'smoke-images.sh: zavislostni image s kodem enginu -> FAIL');
    like($out, qr/^FAIL pwe-mariadb: bez webu \(\/PWE\/webapps je prazdny\)\n\s+v \/PWE\/webapps byt nic nema, je tam: example-db\.web/m, 'smoke-images.sh: zavislostni image s webem -> FAIL');
    like($out, qr/^FAIL pwe-mariadb: ENV: PWE_CONF_pwe_core=\/PWE\/PWE, zadne PWE_CONF_pwe_home ani PWE_PROFILE\n\s+PWE_PROFILE v zavislostnim image byt nema/m, 'smoke-images.sh: zavislostni image se zapecenym PWE_PROFILE -> FAIL');
    like($out, qr/^FAIL pwe-mariadb: popisky image: title=pwe-mariadb, version prazdna\n\s+popisek org\.opencontainers\.image\.version je '\Q$VERSION\E', ocekavan prazdny \(zavislostni image engine neobsahuje\)$/m, 'smoke-images.sh: zavislostni image s popiskem verze enginu -> FAIL');
    is(scalar(() = $out =~ /^FAIL /mg), 4, 'smoke-images.sh: zavislostni image ze starsiho usporadani -> prave tyto ctyri FAIL');

    # stare image vzorovych webu: soubory vzoroveho webu se lisi od pracovni kopie
    ($rc, $out, $err) = $run_smoke->({%same, FAKE_SMOKE_WEB_FILES => "$T/smoke-web-other.lst", FAKE_SMOKE_DBWEB_FILES => "$T/smoke-dbweb-other.lst"}, 'pwe-base', 'pwe-mariadb', 'pwe-example-static', 'pwe-example-mariadb');
    is($rc, 1, 'smoke-images.sh: vzorovy web v image se lisi od pracovni kopie -> kod 1');
    like($out, qr/^FAIL pwe-example-static: soubory vzoroveho webu v \/PWE\/webapps\/example\.web .*\n\s+v image chybi .*\n\s+Pages\/default\/default\.pm\n\s+v image navic .*\n\s+ramdisk\/templates\/stary\.tmplc$/m, 'smoke-images.sh: pwe-example-static - chybejici soubor webu a docasna data v image -> FAIL');
    like($out, qr/^FAIL pwe-example-mariadb: soubory vzoroveho webu v \/PWE\/webapps\/example-db\.web .*\n\s+v image navic .*\n\s+Pages\/stara\/stara\.pm$/m, 'smoke-images.sh: pwe-example-mariadb - soubor navic (stary image) -> FAIL');
    unlike($out, qr/^\s+conf\/database\.conf$/m, 'smoke-images.sh: symlink conf/database.conf (zaklada ho Dockerfile webu) se do srovnani nepocita');
    is(scalar(() = $out =~ /^FAIL /mg), 2, 'smoke-images.sh: lisi se jen soubory vzorovych webu -> prave dva FAIL');

    # image vzoroveho webu sestaveny nad jinym zakladem, nez je mistni zakladni image (image nepochazeji z jednoho sestaveni)
    ($rc, $out, $err) = $run_smoke->({%same, FAKE_SMOKE_OLD_BASE => 'pwe-example-mysql'});
    is($rc, 1, 'smoke-images.sh: pwe-example-mysql nevychazi z mistniho pwe-mysql -> kod 1');
    like($out, qr/^FAIL pwe-example-mysql: vychazi z image pwe-mysql tehoz tagu \(vrstvy zakladu jsou zacatkem vrstev image\)\n\s+vrstvy image ghcr\.io\/kukam\/pwe-mysql:\Q$VERSION\E nejsou zacatkem vrstev image ghcr\.io\/kukam\/pwe-example-mysql:\Q$VERSION\E - image nepochazeji z jednoho sestaveni; sestav znovu vsechny: make images$/m,
        'smoke-images.sh: jiny zaklad -> FAIL s radou make images');
    like($out, qr/^\s+vrstvy zakladu \(2\):\n\s+sha256:ubuntu\n\s+sha256:pwe-mysql\n\s+vrstvy image:\n\s+sha256:ubuntu\n\s+sha256:stary-pwe-mysql\n/m, 'smoke-images.sh: jiny zaklad -> duvod vypise vrstvy zakladu i image');
    is(scalar(() = $out =~ /^FAIL /mg), 1, 'smoke-images.sh: jiny zaklad jednoho image -> prave jeden FAIL');

    # pod tagem image vzoroveho webu je sam zakladni image (zadne vlastni vrstvy s enginem a webem): take FAIL
    ($rc, $out, $err) = $run_smoke->({%same, FAKE_SMOKE_NO_OWN_LAYERS => 'pwe-example-postgres'}, 'pwe-postgres', 'pwe-example-postgres');
    like($out, qr/^FAIL pwe-example-postgres: vychazi z image pwe-postgres tehoz tagu \(vrstvy zakladu jsou zacatkem vrstev image\)\n/m, 'smoke-images.sh: image vzoroveho webu se stejnymi vrstvami jako zaklad (nic nad nim) -> FAIL');
    is($rc . '|' . scalar(() = $out =~ /^FAIL /mg), '1|1', 'smoke-images.sh: image vzoroveho webu bez vlastnich vrstev -> kod 1, prave jeden FAIL');

    # zakladni image se nekontroluje: srovnani vrstev se preskoci (mistni zaklad muze byt starsi), ostatni kontroly bezi
    ($rc, $out, $err) = $run_smoke->({%same, FAKE_SMOKE_OLD_BASE => 'pwe-example-static'}, 'pwe-example-static', 'pwe-example-postgres');
    is($rc, 0, 'smoke-images.sh: jen image vzorovych webu -> kod 0') or diag($out . $err);
    is_deeply([$out =~ /^SKIP (\S+): vychazi z image /mg], [qw(pwe-example-static pwe-example-postgres)], 'smoke-images.sh: bez zakladniho image ve vyberu se srovnani vrstev preskoci (SKIP)');
    like($out, qr/^SKIP pwe-example-static: vychazi z image pwe-base tehoz tagu .*\n\s+image pwe-base se v tomto behu nekontroluje \(srovnani: spust bez vyberu image, nebo pridej pwe-base\)$/m, 'smoke-images.sh: SKIP srovnani vrstev s vysvetlenim');
    is(scalar(grep { join(' ', @{$_}) =~ /RootFS\.Layers/ } calls('docker', 'image')), 0, 'smoke-images.sh: bez zakladniho image ve vyberu se vrstvy nectou');

    # zakladni image chybi v lokalnim Dockeru: jeho FAIL, srovnani vrstev u image vzoroveho webu se preskoci
    ($rc, $out, $err) = $run_smoke->({%same, FAKE_SMOKE_MISSING => 'pwe-base'}, 'pwe-base', 'pwe-example-static');
    is($rc, 1, 'smoke-images.sh: image pwe-base neni v lokalnim Dockeru -> kod 1');
    like($out, qr/^FAIL pwe-base: image je v lokalnim Dockeru\n\s+ghcr\.io\/kukam\/pwe-base:\Q$VERSION\E neni v lokalnim Dockeru \(sestaveni: make images; image z registru: --pull always\)$/m, 'smoke-images.sh: chybejici image -> FAIL s radou');
    like($out, qr/^SKIP pwe-example-static: vychazi z image pwe-base tehoz tagu .*\n\s+image pwe-base neni k dispozici /m, 'smoke-images.sh: chybejici zakladni image -> srovnani vrstev se u image vzoroveho webu preskoci');
    is(scalar(() = $out =~ /^FAIL /mg), 1, 'smoke-images.sh: chybejici zakladni image -> jediny FAIL (dalsi kontroly image se preskoci)');

    # vzorovy web v image neni v poradku (chybi pracovni adresar, spatny symlink...)
    ($rc, $out, $err) = $run_smoke->({%same, FAKE_SMOKE_WEB_BAD => 'pwe-example-postgres'}, 'pwe-postgres', 'pwe-example-postgres');
    is($rc, 1, 'smoke-images.sh: vzorovy web v image neni v poradku -> kod 1');
    like($out, qr/^FAIL pwe-example-postgres: vzorovy web example-db\.web ze sestaveni \(--read-only: .*\n\s+chybi pracovni adresar /m, 'smoke-images.sh: vzorovy web neni v poradku -> FAIL s duvodem z kontejneru');
    is(scalar(() = $out =~ /^FAIL /mg), 1, 'smoke-images.sh: vzorovy web neni v poradku -> prave jeden FAIL');

    # entrypoint pri startu serveru o vzorovem webu nevaruje, nebo varuje jeste na neco
    foreach my $c (['FAKE_SMOKE_NOWARN', qr/kod 0, vystup:\n\s+\(zadny\)$/m, 'entrypoint nevaruje'], ['FAKE_SMOKE_WARN_EXTRA', qr/kod 0, vystup:\n\s+\[entrypoint\] VAROVANI: bezi vzorovy web example-db\.web [^\n]*\n\s+\[entrypoint\] VAROVANI: neznamy PWE_PROFILE/m, 'entrypoint varuje i na neco dalsiho']) {
        ($rc, $out, $err) = $run_smoke->({%same, $c->[0] => 'pwe-example-mysql'}, 'pwe-mysql', 'pwe-example-mysql');
        is($rc, 1, "smoke-images.sh: pwe-example-mysql, $c->[2] -> kod 1");
        like($out, qr/^FAIL pwe-example-mysql: entrypoint pri startu serveru \(FCGI_SOCKET_PATH\) varuje, ze bezi vzorovy web example-db\.web \(neni urcen pro verejny provoz\)\n\s+ocekavan jediny radek "\[entrypoint\] VAROVANI: bezi vzorovy web example-db\.web \.\.\." a kod 0; /m, "smoke-images.sh: pwe-example-mysql, $c->[2] -> FAIL kontroly varovani");
        like($out, $c->[1], "smoke-images.sh: pwe-example-mysql, $c->[2] -> duvod s vystupem entrypointu");
        is(scalar(() = $out =~ /^FAIL /mg), 1, "smoke-images.sh: pwe-example-mysql, $c->[2] -> prave jeden FAIL");
    }

    # pwe-example-static s korenovym souborovym systemem jen pro cteni: engine request neobslouzi / zapisuje mimo tmpfs
    my $ro_desc = qr/vychozi prikaz image s korenovym souborovym systemem jen pro cteni \(--read-only, pracovni adresare webu jako tmpfs\): jeden request v rezimu CGI vrati stranku vzoroveho webu example\.web/;
    ($rc, $out, $err) = $run_smoke->({%same, FAKE_SMOKE_CGI_RO => 'rofs'}, @one);
    is($rc, 1, 'smoke-images.sh: pwe-example-static s --read-only request neobslouzi -> kod 1');
    like($out, qr/^FAIL $E: $ro_desc\n\s+engine skoncil kodem 30\n\s+odpoved nema hlavicku Content-Type: text\/html\n/m, 'smoke-images.sh: pwe-example-static s --read-only request neobslouzi -> FAIL behu jen pro cteni');
    like($out, qr/^\s+zapis mimo pracovni adresare webu \(ramdisk, sessions, uploadfile, log\) - na stderr je "Read-only file system"$/m, 'smoke-images.sh: pwe-example-static s --read-only -> duvod jmenuje zapis mimo pracovni adresare');
    like($out, qr/^OK   $E: vychozi prikaz image: jeden request v rezimu CGI vrati stranku vzoroveho webu example\.web$/m, 'smoke-images.sh: bezny beh pwe-example-static je pritom v poradku (selhal jen beh s --read-only)');
    is(scalar(() = $out =~ /^FAIL /mg), 1, 'smoke-images.sh: pwe-example-static s --read-only request neobslouzi -> prave jeden FAIL');
    ($rc, $out, $err) = $run_smoke->({%same, FAKE_SMOKE_CGI_RO => 'rowarn'}, @one);
    is($rc, 1, 'smoke-images.sh: pwe-example-static s --read-only vrati stranku, ale zapisuje mimo pracovni adresare -> kod 1');
    like($out, qr/^FAIL $E: $ro_desc\n\s+zapis mimo pracovni adresare webu /m, 'smoke-images.sh: zapis mimo pracovni adresare pri behu s --read-only -> FAIL, i kdyz stranka prisla');

    # vychozi prikaz image pwe-example-static nevrati stranku
    foreach my $c (['status', qr/odpoved ma chybovy stav: Status: 500 Internal Server Error/, 'odpoved se stavem 500'], ['crash', qr/engine skoncil kodem 2\n\s+odpoved nema hlavicku Content-Type: text\/html/, 'engine spadne']) {
        ($rc, $out, $err) = $run_smoke->({%same, FAKE_SMOKE_CGI => $c->[0]}, @one);
        is($rc, 1, "smoke-images.sh: pwe-example-static, $c->[2] -> kod 1");
        like($out, qr/^FAIL $E: vychozi prikaz image: jeden request v rezimu CGI vrati stranku vzoroveho webu example\.web\n/m, "smoke-images.sh: pwe-example-static, $c->[2] -> FAIL vychoziho prikazu");
        like($out, $c->[1], "smoke-images.sh: pwe-example-static, $c->[2] -> duvod");
        like($out, qr/^\s+stdout \(prvnich 15 radku\):\n(?:.*\n)*?\s+stderr \(prvnich 15 radku\):$/m, "smoke-images.sh: pwe-example-static, $c->[2] -> duvod obsahuje vystup enginu");
    }

    # databazovy profil bez databaze: engine musi dojit az k pripojeni konfiguraci a ovladacem profilu
    foreach my $c (['nodriver', qr/chybi ovladac databaze nebo modul/, 'chybi ovladac'], ['wrongconf', qr/v logu chybi pokus o pripojeni "Connect to mariadb dbid:db1 \.\.\."/, 'jina konfigurace nez profilu'], ['started', qr/engine skoncil kodem 0, bez databaze ma start selhat/, 'engine nabehl bez databaze']) {
        ($rc, $out, $err) = $run_smoke->({%same, FAKE_SMOKE_DB => $c->[0]}, 'pwe-mariadb', 'pwe-example-mariadb');
        is($rc, 1, "smoke-images.sh: pwe-example-mariadb bez databaze, $c->[2] -> kod 1");
        like($out, qr/^FAIL pwe-example-mariadb: vychozi prikaz image bez databaze: /m, "smoke-images.sh: pwe-example-mariadb bez databaze, $c->[2] -> FAIL");
        like($out, $c->[1], "smoke-images.sh: pwe-example-mariadb bez databaze, $c->[2] -> duvod");
    }
}

# ---------------------------------------------------------------------------------------------
# Makefile v koreni repozitare: cile volaji nastroje PWE/tools s ocekavanymi argumenty. Text receptu se
# overuje vzdy (v pwe-base, kde bezi CI, make neni); rozvinuti receptu pres "make -n" (nic se nespousti)
# jen kdyz je v image make (pwe-debugger).
# ---------------------------------------------------------------------------------------------
SKIP: {
    my $makefile = dirname($ROOT) . '/Makefile';
    my $mk       = slurp($makefile);
    my %recipes  = (
        'test'         => ['$(TOOLS)/run-tests.sh $(ARGS)'],
        'compile'      => ['$(TOOLS)/perl-compile.sh'],
        'new'          => ['$(require-web)', '$(TOOLS)/new-webapp.pl $(WEB) $(ARGS)'],
        'module'       => ['$(require-web)', '$(TOOLS)/new-module.pl $(TYPE) $(WEB) $(NAME) $(ARGS)'],
        'check'        => ['$(TOOLS)/check-webapp.pl $(WEB) $(ARGS)'],
        'cgi'          => [q{$(TOOLS)/pwe-cgi.sh $(WEB) '$(Q)' $(ARGS)}],
        'smtp-test'    => ['$(TOOLS)/smtp-test.pl $(WEB) $(ARGS)'],
        'run'          => ['$(TOOLS)/run-webapp.sh $(WEB) $(PROFILE) up --remove-orphans $(ARGS)'],
        'restart'      => ['$(TOOLS)/run-webapp.sh $(WEB) $(PROFILE) restart fcgi'],
        'logs'         => ['$(TOOLS)/run-webapp.sh $(WEB) $(PROFILE) logs -f fcgi'],
        'down'         => ['$(TOOLS)/run-webapp.sh $(WEB) $(PROFILE) down $(ARGS)'],
        'images'       => ['$(TOOLS)/build-images.sh $(ARGS)'],
        'images-check' => ['$(TOOLS)/smoke-images.sh $(ARGS)'],
        (map { ("k8s-$_" => [q{$(TOOLS)/k8s.sh $(patsubst k8s-%,%,$@) '$(K8S)' $(ARGS)}]) } qw(image template deploy status test logs delete)),
    );
    # make -n: [argumenty make, ocekavany vypis (prikazova radka, mezery slouceny)]
    my @expand = (
        [['test'],                                                       'PWE/tools/run-tests.sh'],
        [['test', 'ARGS=t/03-validate.t -v'],                            'PWE/tools/run-tests.sh t/03-validate.t -v'],
        [['compile'],                                                    'PWE/tools/perl-compile.sh'],
        [['new', 'WEB=x.web'],                                           'PWE/tools/new-webapp.pl x.web'],
        [['new', 'WEB=x.web', 'ARGS=--db mariadb --title "Muj web"'],    'PWE/tools/new-webapp.pl x.web --db mariadb --title "Muj web"'],
        [['module', 'WEB=x.web', 'NAME=kontakt'],                        'PWE/tools/new-module.pl page x.web kontakt'],
        [['module', 'TYPE=service', 'WEB=x.web', 'NAME=Kos', 'ARGS=--force'], 'PWE/tools/new-module.pl service x.web Kos --force'],
        [['check'],                                                      'PWE/tools/check-webapp.pl example-db.web'],
        [['check', 'WEB=x.web', 'ARGS=--static'],                        'PWE/tools/check-webapp.pl x.web --static'],
        [['cgi'],                                                        q{PWE/tools/pwe-cgi.sh example-db.web 'page=default&func=default'}],
        [['cgi', 'WEB=x.web', 'Q=page=a&func=b', 'ARGS=--loglevel 4'],   q{PWE/tools/pwe-cgi.sh x.web 'page=a&func=b' --loglevel 4}],
        [['smtp-test', 'WEB=x.web', 'ARGS=--dry-run'],                   'PWE/tools/smtp-test.pl x.web --dry-run'],
        [['images'],                                                     'PWE/tools/build-images.sh'],
        [['images', 'ARGS=base example-static'],                         'PWE/tools/build-images.sh base example-static'],
        [['images-check'],                                               'PWE/tools/smoke-images.sh'],
        [['images-check', 'ARGS=pwe-base pwe-example-static'],           'PWE/tools/smoke-images.sh pwe-base pwe-example-static'],
        [['k8s-template', 'K8S=static'],                                 q{PWE/tools/k8s.sh template 'static'}],
        [['k8s-logs', 'K8S=generic', 'ARGS=--tail 20'],                  q{PWE/tools/k8s.sh logs 'generic' --tail 20}],
        # znak dolaru se v ARGS a Q pise zdvojene (napoveda v hlavicce Makefile)
        [['cgi', 'Q=page=x&cena=$$5'],                                   q{PWE/tools/pwe-cgi.sh example-db.web 'page=x&cena=$5'}],
        [['new', 'WEB=x.web', 'ARGS=--title "Cena \\$$5"'],              q{PWE/tools/new-webapp.pl x.web --title "Cena \\$5"}],
    );
    my @run_cases = grep { $_->[4] } @MAKE_RUN_CASES;
    my $n_text    = 9 + scalar(keys %recipes);
    my $n_make    = scalar(@expand) + scalar(@run_cases) + 8;
    skip 'Makefile neni k dispozici (engine bez korene repozitare)', $n_text + $n_make unless (length($mk));

    # --- text: cile a jejich recepty (radky zacinajici tabulatorem), .PHONY, napoveda ---
    my (%recipe, @phony, @current);
    (my $joined = $mk) =~ s/\\\n\s*/ /g;
    foreach my $line (split(/\n/, $joined)) {
        if    ($line =~ /^\.PHONY:\s*(.*)$/)                         { push(@phony, split(' ', $1)); @current = (); }
        elsif ($line =~ /^([A-Za-z0-9][A-Za-z0-9 _.-]*):\s*$/)       { @current = split(' ', $1); $recipe{$_} = [] foreach (@current); }
        elsif ($line =~ /^\t(.*)$/ and @current)                     { push(@{$recipe{$_}}, $1) foreach (@current); }
        elsif ($line !~ /^\s*(?:#.*)?$/)                             { @current = (); }
    }
    foreach my $target (sort keys %recipes) {
        is_deeply($recipe{$target}, $recipes{$target}, "Makefile: recept cile $target") or diag(join("\n", @{$recipe{$target} || ['(cil neexistuje)']}));
    }
    is_deeply([grep { my $t = $_; !grep { $_ eq $t } @phony } sort keys %recipe], [], 'Makefile: vsechny cile s receptem jsou v .PHONY (soubor stejneho jmena cil nevyradi)');
    like($mk, qr/^require-web = \$\(if \$\(filter command line environment,\$\(origin WEB\)\),,\$\(error Zadej web vyslovne: make \$\@ WEB=<nazev>\.web /m, 'Makefile: require-web = chyba, kdyz WEB neprisel z prikazove radky ani z prostredi');
    like($mk, qr/^WEB\s+\?= example-db\.web$/m, 'Makefile: vychozi WEB je vzorovy web example-db.web (proto cile new a module vyzaduji WEB vyslovne)');
    like($mk, qr/^TOOLS\s+= PWE\/tools$/m, 'Makefile: nastroje se volaji z PWE/tools');
    # make help vypisuje hlavicku Makefile (radky 2..N): N musi byt posledni radek hlavicky s textem a kazdy cil v ni ma byt zminen
    my @lines = split(/\n/, $mk);
    my ($help_to) = join("\n", @{$recipe{'help'} || []}) =~ /^\@sed -n '2,(\d+)p' Makefile \| sed 's\/\^# \\\{0,1\\\}\/\/'$/;
    my $header = 0;
    $header++ while ($header < @lines and $lines[$header] =~ /^#/);
    $header-- while ($header > 0 and $lines[$header - 1] =~ /^#\s*$/);
    is($help_to, $header, 'Makefile: make help vypisuje celou hlavicku (radky 2 az posledni radek komentare s textem)');
    my $help = join("\n", @lines[1 .. ($help_to || 1) - 1]);
    is_deeply([grep { $help !~ /(?<![\w-])\Q$_\E(?![\w-])/ } sort keys %recipe], [], 'Makefile: napoveda (make help) zminuje kazdy cil');
    # napoveda k image: 9 image, cile sestaveni = jmena image bez predpony pwe-, profil static bezi nad pwe-base
    my @targets = map { s/^pwe-//r } PWE::ToolEnv::image_names();
    is_deeply([grep { $help !~ /(?<![\w-])\Q$_\E(?![\w-])/ } @targets], [], 'Makefile: napoveda u make images vyjmenuje vsech 9 cilu sestaveni (base ... example-postgres)');
    like($help, qr/profil static v pwe-base:<verze>/, 'Makefile: napoveda rika, ze profil static bezi v pwe-base (zadny image profilu static)');
    unlike($mk, qr/pwe-static|vsech 7|ARGS='pwe /, 'Makefile: zadna zminka o zrusenych image pwe a pwe-static ani o 7 image');

    # --- make -n: rozvinuti receptu (nic se nespousti; pracovni adresar je prazdny, nastroje v nem nejsou) ---
  SKIP: {
        my ($make) = grep { -x $_ } map { "$_/make" } grep { length } split(/:/, $SYS_PATH);
        skip 'make neni k dispozici (image pwe-base ho nema; rozvinuti receptu se overuje v pwe-debugger)', $n_make unless ($make);
        my $cwd = "$T/make-cwd";
        make_path($cwd);
        my $make_n = sub {
            my ($env, @args) = @_;
            my ($rc, $out, $err) = run_cmd({env => $env, cwd => $cwd}, $make, '-n', '-f', $makefile, @args);
            $out =~ s/[ \t]+/ /g;
            $out =~ s/ ?\n/\n/g;
            return ($rc, $out, $err);
        };
        foreach my $c (@expand) {
            my ($args, $want) = @{$c};
            my ($rc, $out, $err) = $make_n->({}, @{$args});
            is("$rc|$out", "0|$want\n", "make -n @{$args}: $want") or diag($err);
        }
        # run / restart / logs / down: presne ta prikazova radka, kterou overuje blok run-webapp.sh
        foreach my $c (@run_cases) {
            my ($tool_args, undef, undef, $what, $make_args) = @{$c};
            my ($rc, $out, $err) = $make_n->({}, @{$make_args});
            is_deeply([$rc, split(' ', $out)], [0, 'PWE/tools/run-webapp.sh', @{$tool_args}], "make -n ($what): PWE/tools/run-webapp.sh @{$tool_args}") or diag($out . $err);
        }
        # cile new a module bez WEB: chyba jeste pred spustenim nastroje (vychozi WEB je vzorovy web jen ke cteni)
        foreach my $target (qw(new module)) {
            my ($rc, $out, $err) = $make_n->({}, $target, 'NAME=kontakt');
            isnt($rc, 0, "make -n $target bez WEB: chyba");
            like($err, qr/Zadej web vyslovne: make $target WEB=<nazev>\.web \(vychozi example-db\.web je vzorovy web jen ke cteni\)/, "make -n $target bez WEB: hlaska s radou");
            is($out, '', "make -n $target bez WEB: zadny prikaz se nevypise (nastroj by se nespustil)");
        }
        my ($rc, $out, $err) = $make_n->({WEB => 'y.web'}, 'new');
        is("$rc|$out", "0|PWE/tools/new-webapp.pl y.web\n", 'make -n new s WEB z prostredi: web z promenne prostredi se pouzije') or diag($err);
        ($rc, $out, $err) = $make_n->({WEB => 'y.web'}, 'new', 'WEB=x.web');
        is("$rc|$out", "0|PWE/tools/new-webapp.pl x.web\n", 'make -n new: WEB z prikazove radky ma prednost pred prostredim') or diag($err);
    }
}

# ---------------------------------------------------------------------------------------------
# .github/workflows/images.yml: zakladni image se v registru vyhleda jednou a vsechna volani bake ho
# dostanou pripnuty na digest (jinak by Publish mohl sestavit a nahrat image nad jinym zakladem, nez jaky
# prosel testy); kourove kontroly srovnavaji image pwe s checkoutem vzdy (--tree)
# ---------------------------------------------------------------------------------------------
SKIP: {
    my $wf = slurp(dirname($ROOT) . '/.github/workflows/images.yml');
    skip '.github/workflows/images.yml neni k dispozici (engine bez korene repozitare)', 7 unless (length($wf));
    my $engine_df = slurp("$ROOT/docker/Dockerfile");

    my @bake  = $wf =~ /^\s*(docker buildx bake .*)$/mg;
    my @build = grep { /--(?:load|push)\b/ } @bake;
    is(scalar(@build), 3, 'images.yml: tri volani bake, ktera stavi (linux/amd64, linux/arm64, Publish)');
    is(scalar(grep { !/^docker buildx bake "\$\{args\[\@\]\}" / } @bake), 0, 'images.yml: kazde volani bake bere volby z pole args');
    is(scalar(() = $wf =~ /^\s*args\+=\(--set "\*\.args\.UBUNTU_IMAGE=\$\{UBUNTU_IMAGE:\?[^"}]+\}"\)$/mg), 3, 'images.yml: kazde ze tri sestaveni pole args pripina zakladni image (--set *.args.UBUNTU_IMAGE, prazdna hodnota = chyba)');
    is(scalar(() = $wf =~ /^          UBUNTU_IMAGE: \$\{\{ steps\.base\.outputs\.image \}\}$/mg), 3, 'images.yml: pripnuty zaklad je ve vsech trech krocich vystup kroku base (stejna hodnota)');
    my $at_base  = index($wf, "      - name: Base image digest\n        id: base\n");
    my $at_build = index($wf, '      - name: Build (linux/amd64)');
    ok($at_base > 0 && $at_base < $at_build && substr($wf, $at_base, $at_build - $at_base) =~ /docker buildx imagetools inspect "\$image" .*echo "image=\$image\@\$digest" >> "\$GITHUB_OUTPUT"/s,
        'images.yml: digest zakladu se zjistuje jednou (krok base) pred prvnim buildem');
    # krok cte vychozi hodnotu ARG z Dockerfile enginu: musi tam byt v pripnutelnem tvaru <image>:<tag>
    like($engine_df, qr/^ARG UBUNTU_IMAGE=[a-z0-9][a-z0-9._\/-]*:[A-Za-z0-9_][A-Za-z0-9_.-]*$/m, 'Dockerfile zavislostnich image: ARG UBUNTU_IMAGE ma vychozi hodnotu tvaru <image>:<tag> (pipeline ji pripina na digest)');
    my @smoke = $wf =~ /^\s*(?:run: )?(bash PWE\/tools\/smoke-images\.sh .*)$/mg;
    ok(@smoke == 2 && !(grep { !/ --pull never --tree$/ } @smoke), 'images.yml: kourove kontroly obou platforem srovnavaji image s checkoutem (--pull never --tree)');
}

# ---------------------------------------------------------------------------------------------
# docker-bake.hcl: 9 cilu = jmena image bez predpony pwe-. Zavislostni image (base, mariadb, mysql, postgres,
# debugger) jsou stage PWE/docker/Dockerfile; image vzorovych webu (example-*) stavi primo Dockerfile vzoroveho
# webu z korene repozitare a pres "contexts" berou zaklad z prave sestaveneho ciloveho image (ne z registru).
# Kazdy cil ma prave tagy <verze> (promenna VERSION, povinna) a latest ve vsech registrech; tag podle vetve
# (promenna TAG) zanikl; verzi enginu, cas buildu a commit nesou jen image vzorovych webu (jedine obsahuji engine)
# ---------------------------------------------------------------------------------------------
SKIP: {
    my $bake = slurp(dirname($ROOT) . '/docker-bake.hcl');
    skip 'docker-bake.hcl neni k dispozici (engine bez korene repozitare)', 95 unless (length($bake));
    (my $code = $bake) =~ s/^\s*#.*\n//mg;    # bez komentaru
    my @deps     = qw(base mariadb mysql postgres debugger);
    # cil vzoroveho webu: [cil, vzorovy web, profil, zakladni image, cil zakladu]
    my @examples = (['example-static', 'example.web', 'static', 'pwe-base', 'base'], ['example-mariadb', 'example-db.web', 'mariadb', 'pwe-mariadb', 'mariadb'],
        ['example-mysql', 'example-db.web', 'mysql', 'pwe-mysql', 'mysql'], ['example-postgres', 'example-db.web', 'postgres', 'pwe-postgres', 'postgres']);
    my @names = (@deps, map { $_->[0] } @examples);

    my %target;
    while ($code =~ /^target\s+"([^"]+)"\s*\{\n(.*?)^\}/msg) { $target{$1} = $2; }
    is_deeply([sort grep { !/^_/ } keys %target], [sort @names], 'docker-bake.hcl: prave 9 cilu (base, mariadb, mysql, postgres, debugger, example-static, example-mariadb, example-mysql, example-postgres)');
    is_deeply([map { "pwe-$_" } @names], [PWE::ToolEnv::image_names()], 'docker-bake.hcl: cile = jmena image PWE bez predpony pwe- (image_names)');
    ok(!exists($target{'pwe'}) && !exists($target{'static'}) && !exists($target{'_engine'}), 'docker-bake.hcl: zrusene cile pwe (nosic enginu) a static uz neexistuji');
    unlike($code, qr{pwe-static|"pwe"|/pwe:}, 'docker-bake.hcl: zadna zminka o zrusenych image pwe a pwe-static');

    my ($group) = $code =~ /^group\s+"default"\s*\{\n(.*?)^\}/ms;
    my @default = (defined($group) and $group =~ /targets\s*=\s*\[([^\]]*)\]/) ? ($1 =~ /"([^"]+)"/g) : ();
    is_deeply(\@default, \@names, 'docker-bake.hcl: skupina default stavi vsech 9 cilu (zavislostni image pred image vzorovych webu)');

    # promenne: REGISTRIES, VERSION (povinna), SOURCE, REVISION, CREATED - a zadna TAG
    my %variable;
    while ($code =~ /^variable\s+"([^"]+)"\s*\{\n(.*?)^\}/msg) { $variable{$1} = $2; }
    is_deeply([sort keys %variable], [qw(CREATED REGISTRIES REVISION SOURCE VERSION)], 'docker-bake.hcl: promenne REGISTRIES, VERSION, SOURCE, REVISION, CREATED (promenna TAG zanikla)');
    unlike($code, qr/\bTAG\b/, 'docker-bake.hcl: promenna TAG se nikde nepouziva (zadny tag podle vetve)');
    like($variable{'REGISTRIES'} || '', qr{^\s*default\s*=\s*"ghcr\.io/kukam"\s*$}m, 'docker-bake.hcl: vychozi registr ghcr.io/kukam');
    like($variable{'VERSION'} || '', qr/^\s*validation\s*\{\s*\n\s*condition\s*=\s*VERSION != ""\s*$/m, 'docker-bake.hcl: VERSION je povinna (validation: prazdna hodnota = chyba)');
    unlike($variable{'VERSION'} || '', qr/^\s*default\s*=\s*"[^"]/m, 'docker-bake.hcl: VERSION nema zadnou vychozi verzi (cislo verze je jen v PWE/VERSION)');
    unlike($code, qr/"[0-9]+\.[0-9]+\.[0-9]+"/, 'docker-bake.hcl: zadne cislo verze napevno');

    # funkce image_tags: pro kazdy registr prave tagy VERSION a latest
    my %function;
    while ($code =~ /^function\s+"([^"]+)"\s*\{\n(.*?)^\}/msg) { $function{$1} = $2; }
    my $fn = $function{'image_tags'} || '';
    like($fn, qr/^\s*params\s*=\s*\[image\]\s*$/m, 'docker-bake.hcl: image_tags(image) - tagy si volajici nevybira');
    like($fn, qr/for tag in \[VERSION,\s*"latest"\]\s*:\s*"\$\{trimspace\(registry\)\}\/\$\{image\}:\$\{tag\}"/, 'docker-bake.hcl: image_tags dava <registr>/<image>:<VERSION> a <registr>/<image>:latest');
    like($fn, qr/for registry in split\(",",\s*REGISTRIES\)/, 'docker-bake.hcl: image_tags pro kazdy registr z REGISTRIES');
    is(scalar(() = $code =~ /"latest"/g), 1, 'docker-bake.hcl: tag latest je jen ve funkci image_tags (zadny cil si tagy nesklada sam)');
    # zaklad image vzorovych webu: <prvni registr>/<image>:<VERSION> = to, co stoji ve FROM Dockerfile webu
    like($function{'base_registry'} || '', qr/^\s*result\s*=\s*\[for registry in split\(",",\s*REGISTRIES\)\s*:\s*trimspace\(registry\) if trimspace\(registry\) != ""\]\[0\]\s*$/m, 'docker-bake.hcl: base_registry() = prvni neprazdny registr ze seznamu REGISTRIES');
    like($function{'base_ref'} || '', qr/^\s*result\s*=\s*"\$\{base_registry\(\)\}\/\$\{image\}:\$\{VERSION\}"\s*$/m, 'docker-bake.hcl: base_ref(image) = <prvni registr>/<image>:<VERSION> (zaklad se stejnou verzi jako image vzoroveho webu)');

    # --- zavislostni image: stage v PWE/docker/Dockerfile, bez verze enginu, bez popisku commitu a casu ---
    my $common = $target{'_common'} || '';
    like($common, qr/^\s*context\s*=\s*"\."\s*$/m,                        'docker-bake.hcl: zavislostni image - kontext = koren repozitare');
    like($common, qr{^\s*dockerfile\s*=\s*"PWE/docker/Dockerfile"\s*$}m, 'docker-bake.hcl: zavislostni image - jeden Dockerfile (PWE/docker/Dockerfile)');
    unlike($common, qr/^\s*(?:tags|target)\s*=/m,                         'docker-bake.hcl: spolecne nastaveni zavislostnich image samo nic nestavi ani neoznacuje');
    unlike($common, qr/\bVERSION\b/,                                      'docker-bake.hcl: zavislostni image verzi enginu nedostavaji (engine neobsahuji)');
    foreach my $name (@deps) {
        my $body = $target{$name} || '';
        like($body, qr/^\s*inherits\s*=\s*\["_common"\]\s*$/m, "docker-bake.hcl: cil $name dedi spolecne nastaveni zavislostnich image (_common)");
        like($body, qr/^\s*target\s*=\s*"\Q$name\E"\s*$/m,     "docker-bake.hcl: cil $name stavi stage $name");
        like($body, qr/^\s*tags\s*=\s*image_tags\("pwe-\Q$name\E"\)\s*$/m, "docker-bake.hcl: cil $name oznacuje image pwe-$name tagy <verze> a latest (image_tags)");
        is(scalar(() = $body =~ /^\s*tags\s*=/mg), 1,           "docker-bake.hcl: cil $name ma prave jedno nastaveni tagu");
        unlike($body, qr/\bVERSION\b|\blabels\b|CREATED|REVISION|\bcontexts\b|\bdockerfile\b/, "docker-bake.hcl: cil $name nema verzi enginu, popisky casu buildu a commitu, contexts ani vlastni Dockerfile (stabilni digest, dokud se nezmeni zavislosti)");
    }

    # --- image vzorovych webu: Dockerfile webu z korene repozitare, zaklad z prave sestaveneho cile ---
    my $example = $target{'_example'} || '';
    like($example, qr/^\s*context\s*=\s*"\."\s*$/m,                           'docker-bake.hcl: image vzorovych webu - kontext = koren repozitare (engine i web se berou z pracovni kopie)');
    like($example, qr/^\s*PWE_IMAGE_REGISTRY\s*=\s*base_registry\(\)\s*$/m,   'docker-bake.hcl: image vzorovych webu - argument PWE_IMAGE_REGISTRY = prvni registr');
    like($example, qr/^\s*PWE_IMAGE_TAG\s*=\s*VERSION\s*$/m,                  'docker-bake.hcl: image vzorovych webu - argument PWE_IMAGE_TAG = VERSION (zaklad teze verze)');
    like($example, qr/"org\.opencontainers\.image\.version"\s*=\s*VERSION/,   'docker-bake.hcl: image vzorovych webu - popisek version = VERSION (obsahuji engine)');
    like($example, qr/"org\.opencontainers\.image\.source"\s*=\s*SOURCE/,     'docker-bake.hcl: image vzorovych webu - popisek source = SOURCE (Dockerfile webu ho ma prazdny)');
    like($example, qr/"org\.opencontainers\.image\.licenses"\s*=\s*"Apache-2\.0"/, 'docker-bake.hcl: image vzorovych webu - popisek licenses');
    like($example, qr/CREATED != "" \? \{\s*"org\.opencontainers\.image\.created"\s*=\s*CREATED\s*\}/,    'docker-bake.hcl: image vzorovych webu - popisek created (cas buildu), jen kdyz je zadan');
    like($example, qr/REVISION != "" \? \{\s*"org\.opencontainers\.image\.revision"\s*=\s*REVISION\s*\}/, 'docker-bake.hcl: image vzorovych webu - popisek revision (commit), jen kdyz je zadan');
    unlike($example, qr/^\s*(?:tags|target|dockerfile)\s*=/m,                 'docker-bake.hcl: spolecne nastaveni image vzorovych webu samo nic nestavi ani neoznacuje');
    foreach my $e (@examples) {
        my ($name, $web, $profile, $base_image, $base_target) = @{$e};
        my $body = $target{$name} || '';
        like($body, qr/^\s*inherits\s*=\s*\["_example"\]\s*$/m, "docker-bake.hcl: cil $name dedi spolecne nastaveni image vzorovych webu (_example)");
        like($body, qr{^\s*dockerfile\s*=\s*"webapps/\Q$web\E/Dockerfile"\s*$}m, "docker-bake.hcl: cil $name stavi primo Dockerfile vzoroveho webu webapps/$web/Dockerfile (zadna zvlastni stage)");
        unlike($body, qr/^\s*target\s*=/m,                      "docker-bake.hcl: cil $name nestavi zadny stage PWE/docker/Dockerfile");
        like($body, qr/^\s*PWE_PROFILE\s*=\s*"\Q$profile\E"\s*$/m, "docker-bake.hcl: cil $name - argument PWE_PROFILE=$profile");
        like($body, qr/^\s*contexts\s*=\s*\{\s*\n\s*"\$\{base_ref\("\Q$base_image\E"\)\}"\s*=\s*"target:\Q$base_target\E"\s*\n\s*\}/m, "docker-bake.hcl: cil $name - FROM <registr>/$base_image:<verze> se nahradi prave sestavenym cilem $base_target (contexts)");
        is(scalar(() = $body =~ /"target:/g), 1,                "docker-bake.hcl: cil $name zavisi prave na jednom cili (svem zakladu)");
        like($body, qr/"org\.opencontainers\.image\.title"\s*=\s*"pwe-\Q$name\E"/, "docker-bake.hcl: cil $name - popisek title = jmeno image pwe-$name (ne nazev webu)");
        like($body, qr/^\s*tags\s*=\s*image_tags\("pwe-\Q$name\E"\)\s*$/m, "docker-bake.hcl: cil $name oznacuje image pwe-$name tagy <verze> a latest (image_tags)");
        is(scalar(() = $body =~ /^\s*tags\s*=/mg), 1,           "docker-bake.hcl: cil $name ma prave jedno nastaveni tagu");
        # zaklad v bake = zaklad v Dockerfile webu: FROM se po dosazeni argumentu musi shodovat s klicem contexts
        my $df = slurp(dirname($ROOT) . "/webapps/$web/Dockerfile");
        my ($from) = $df =~ /^FROM (\S+)$/m;
        (my $resolved = defined($from) ? $from : '') =~ s/\$\{PWE_PROFILE\}/$profile/g;
        is($resolved, "\${PWE_IMAGE_REGISTRY}/$base_image:\${PWE_IMAGE_TAG}", "docker-bake.hcl: cil $name - radek FROM v webapps/$web/Dockerfile s PWE_PROFILE=$profile je $base_image (stejny image, jaky contexts nahrazuje)");
    }
}

done_testing();
