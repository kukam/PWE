#!/usr/bin/env perl
# Shell nastroje kolem image (PWE/tools/lib/images.sh, build-images.sh, run-tests.sh, perl-compile.sh,
# pwe-cgi.sh, run-webapp.sh) a textova pravidla docker-bake.hcl:
#   - tag image = vetev gitu (pwe_image_branch, pwe_image_tag), kontrola PWE_IMAGE_TAG, shoda s PWE::ToolEnv
#   - build-images.sh: pojistky --push, tag tvaru verze, hodnoty voleb, promenne pro docker buildx bake
#   - run-tests.sh a perl-compile.sh: skutecna prikazova radka docker run, zamek pracovni kopie
#   - pwe-cgi.sh: k siti compose stacku se pripoji jen tehdy, kdyz stack patri temuz webu
#   - run-webapp.sh: neznamy profil nebo prikaz, varovani pri neshode webu a profilu
#
# V testovacim kontejneru neni git ani docker. Test si proto v docasnem adresari vytvori falesne
# spustitelne soubory git a docker (chovani ridi promenne FAKE_*, kazde volani se zapise do souboru
# $FAKE_LOG) a da je na zacatek PATH.
#
# Nastroje se nespousteji z pracovni kopie, ale z KOPIE v docasnem stromu (<tmp>/repo/PWE/tools/...,
# vedle falesne weby <tmp>/repo/webapps/*.web a vlastni PWE/VERSION). Duvod: tento test bezi uvnitr
# vnejsiho run-tests.sh, ktery uz drzi zamek pracovni kopie PWE/t/.run-tests.lock - testovany
# run-tests.sh na nej nesmi sahnout. Skripty odvozuji koren repozitare od sveho umisteni, takze kopie
# pracuje se zamkem <tmp>/repo/PWE/t/.run-tests.lock a nastroje nepotrebuji zadnou promennou jen pro testy.
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

make_path("$REPO/PWE/tools/lib", "$REPO/PWE/t", "$T/bin", "$T/bin-nogit");
foreach my $sh (qw(build-images.sh run-tests.sh perl-compile.sh pwe-cgi.sh run-webapp.sh lib/images.sh)) {
    copy("$TOOLS/$sh", "$REPO/PWE/tools/$sh") or die "Nelze zkopirovat tools/$sh: $!";
    chmod(0755, "$REPO/PWE/tools/$sh");
}
spit("$REPO/PWE/VERSION", "9.8.7\n");

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
        printf 'env\tREGISTRIES=%s\tTAG=%s\tVERSION=%s\tREVISION=%s\tCREATED=%s\tSOURCE=%s\tPWE_WEBAPP=%s\tCOMPOSE_PROFILES=%s\tPWE_IMAGE_REGISTRY=%s\tPWE_IMAGE_TAG=%s\tCWD=%s\n' \
            "${REGISTRIES-<unset>}" "${TAG-<unset>}" "${VERSION-<unset>}" "${REVISION-<unset>}" "${CREATED-<unset>}" "${SOURCE-<unset>}" \
            "${PWE_WEBAPP-<unset>}" "${COMPOSE_PROFILES-<unset>}" "${PWE_IMAGE_REGISTRY-<unset>}" "${PWE_IMAGE_TAG-<unset>}" "$PWD" >> "$FAKE_LOG"
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

# Spusti prikaz a pocka na nej. Volby: env => { PROMENNA => hodnota | undef }, cwd => adresar.
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
# images.sh: vetev gitu -> tag image (pwe_image_branch, pwe_image_tag), shoda s PWE::ToolEnv::image_tag()
# ---------------------------------------------------------------------------------------------

# PWE::ToolEnv::image_tag() s chovanim hostitele: v kontejneru by _git_branch() git vubec nevolal
# (in_container()), proto se pro test in_container() docasne nahradi. Vraci tag, nebo "DIE: hlaska".
sub perl_image_tag {
    my ($env) = @_;
    local %ENV = (%BASE_ENV, %{$env});
    foreach my $k (keys %ENV) { delete $ENV{$k} unless (defined($ENV{$k})); }
    no warnings 'redefine';
    local *PWE::ToolEnv::in_container = sub { return 0; };
    my $tag = eval { PWE::ToolEnv::image_tag() };
    return defined($tag) ? $tag : "DIE: $@";
}

{
    my @cases = (
        # [popis, prostredi falesneho gitu, ocekavana vetev, ocekavany tag]
        ['vetev pwe.ai',                              {FAKE_GIT_BRANCH => 'pwe.ai'},                              'pwe.ai',        'pwe.ai'],
        ['vetev s lomitkem',                          {FAKE_GIT_BRANCH => 'feature/kosik'},                       'feature/kosik', 'feature-kosik'],
        ['vetev master',                              {FAKE_GIT_BRANCH => 'master'},                              'master',        'master'],
        ['vetev +master (prevod da master)',          {FAKE_GIT_BRANCH => '+master'},                             '+master',       'master'],
        ['odpojeny HEAD',                             {FAKE_GIT_BRANCH => ''},                                    '',              'master'],
        ['neprazdny --show-prefix (uvnitr ciziho gitu)', {FAKE_GIT_BRANCH => 'cizi', FAKE_GIT_PREFIX => 'sub/pwe/'}, '',           'master'],
        ['adresar neni repozitar',                    {FAKE_GIT_BRANCH => 'cizi', FAKE_GIT_NOREPO => 1},          '',              'master'],
    );
    foreach my $c (@cases) {
        my ($what, $env, $branch, $tag) = @{$c};
        log_reset();
        my ($rc, $out, $err) = sh($env, $IMAGES_SH, 'pwe_image_branch');
        is($rc,  0,                                      "pwe_image_branch ($what): navratovy kod 0");
        is($out, (length($branch) ? "$branch\n" : ''),   "pwe_image_branch ($what): " . (length($branch) ? $branch : 'prazdny vystup = vetev nelze urcit'));
        ($rc, $out, $err) = sh($env, $IMAGES_SH, 'pwe_image_tag');
        is("$rc|$out|$err", "0|$tag\n|",                 "pwe_image_tag ($what): $tag");
        is(perl_image_tag($env), $tag,                   "ToolEnv::image_tag() ($what) = images.sh pwe_image_tag");
    }

    # git se pta na koren kopie repozitare (ne na aktualni adresar) a vetev cte jen v koreni pracovni kopie
    log_reset();
    sh({FAKE_GIT_BRANCH => 'pwe.ai'}, $IMAGES_SH, 'pwe_image_branch');
    is_deeply([calls('git')], [['-C', $REPO, 'rev-parse', '--show-prefix'], ['-C', $REPO, 'symbolic-ref', '--quiet', '--short', 'HEAD']],
        'pwe_image_branch: git -C <koren repozitare> rev-parse --show-prefix, pak symbolic-ref --quiet --short HEAD');
    log_reset();
    sh({FAKE_GIT_BRANCH => 'cizi', FAKE_GIT_PREFIX => 'sub/pwe/'}, $IMAGES_SH, 'pwe_image_branch');
    is(scalar(grep { $_->[2] eq 'symbolic-ref' } calls('git')), 0, 'pwe_image_branch: uvnitr ciziho gitu se na vetev vubec nepta');
    log_reset();
    perl_image_tag({FAKE_GIT_BRANCH => 'pwe.ai'});
    my $repo_root = PWE::ToolEnv::repo_root();
    is_deeply([calls('git')], [['-C', $repo_root, 'rev-parse', '--show-prefix'], ['-C', $repo_root, 'symbolic-ref', '--quiet', '--short', 'HEAD']],
        'ToolEnv::image_tag(): stejne dotazy na git jako images.sh (nad repo_root())');

    # bez prikazu git
    my ($rc, $out, $err) = sh({PATH => $NOGIT_PATH}, $IMAGES_SH, 'pwe_image_branch');
    is("$rc|$out", '0|', 'pwe_image_branch (bez gitu v PATH): prazdny vystup');
    ($rc, $out, $err) = sh({PATH => $NOGIT_PATH}, $IMAGES_SH, 'pwe_image_tag');
    is("$rc|$out", "0|master\n", 'pwe_image_tag (bez gitu v PATH): master');
    is(perl_image_tag({PATH => "$T/bin-nogit"}), 'master', 'ToolEnv::image_tag() (bez gitu v PATH): master');
    ($rc, $out, $err) = sh({FAKE_GIT_BRANCH => 'pwe.ai'}, $IMAGES_SH, 'pwe_image_git_repo');
    is($rc, 0, 'pwe_image_git_repo: koren pracovni kopie -> 0');
    ($rc, $out, $err) = sh({FAKE_GIT_BRANCH => 'cizi', FAKE_GIT_PREFIX => 'sub/'}, $IMAGES_SH, 'pwe_image_git_repo');
    isnt($rc, 0, 'pwe_image_git_repo: uvnitr ciziho gitu -> nenulovy kod');

    # PWE_IMAGE_TAG ma prednost a git se nevola
    log_reset();
    ($rc, $out, $err) = sh({PWE_IMAGE_TAG => 'x_1.2', FAKE_GIT_BRANCH => 'pwe.ai'}, $IMAGES_SH, 'pwe_image_tag');
    is("$rc|$out|$err", "0|x_1.2\n|", 'pwe_image_tag: platny PWE_IMAGE_TAG se vraci beze zmeny');
    is(scalar(calls('git')), 0, 'pwe_image_tag: s PWE_IMAGE_TAG se git nevola');
    is(perl_image_tag({PWE_IMAGE_TAG => 'x_1.2', FAKE_GIT_BRANCH => 'pwe.ai'}), 'x_1.2', 'ToolEnv::image_tag(): platny PWE_IMAGE_TAG');

    # neplatny PWE_IMAGE_TAG: hlaska na stderr, nic na stdout, kod 2 (Perl: die se stejnou hlaskou)
    my @invalid = (['feature/kosik', 'lomitko'], ['-x', 'uvodni pomlcka'], ['.x', 'uvodni tecka'], ['a b', 'mezera'], ['a:b', 'dvojtecka'],
        ['x' x 129, '129 znaku'], ["a\nb", 'novy radek'], ["v\xc4\x9btev", 'diakritika']);
    foreach my $c (@invalid) {
        my ($tag, $what) = @{$c};
        ($rc, $out, $err) = sh({PWE_IMAGE_TAG => $tag, FAKE_GIT_BRANCH => 'pwe.ai'}, $IMAGES_SH, 'pwe_image_tag');
        is("$rc|$out", '2|', "pwe_image_tag: neplatny PWE_IMAGE_TAG ($what) -> kod 2, prazdny stdout");
        like($err, qr/neni platny tag image.*pwe_image_tag_sanitize/s, "pwe_image_tag: neplatny PWE_IMAGE_TAG ($what) -> hlaska s radou na pwe_image_tag_sanitize");
        like(perl_image_tag({PWE_IMAGE_TAG => $tag}), qr/^DIE: PWE_IMAGE_TAG=.*neni platny tag image.*pwe_image_tag_sanitize/s, "ToolEnv::image_tag(): neplatny PWE_IMAGE_TAG ($what) -> die");
    }

    # pravidlo platnosti tagu: shell a Perl se shoduji
    my @tags = (['a', 1], ['_', 1], ['0', 1], ['pwe.ai', 1], ['A-Z_0.9', 1], ['2.1.0', 1], ['x' x 128, 1],
        ['', 0], ['.x', 0], ['-x', 0], ['a b', 0], ['a/b', 0], ['a:b', 0], ["a\nb", 0], ["abc\n", 0], ['x' x 129, 0], ["v\xc4\x9btev", 0]);
    foreach my $c (@tags) {
        my ($tag, $valid) = @{$c};
        (my $show = (length($tag) > 20) ? length($tag) . ' znaku' : $tag) =~ s/\n/\\n/g;
        ($rc, $out, $err) = sh({}, $IMAGES_SH, 'pwe_image_tag_valid', $tag);
        is(($rc == 0 ? 1 : 0), $valid, "pwe_image_tag_valid('$show') -> " . ($valid ? 'platny' : 'neplatny'));
        is(PWE::ToolEnv::image_tag_valid($tag), $valid, "ToolEnv::image_tag_valid('$show') = images.sh");
    }
}

# ---------------------------------------------------------------------------------------------
# images.sh: pwe_image, pwe_tool_image, chovani pod set -e, CDPATH, zsh, rada pri chybejicim image
# ---------------------------------------------------------------------------------------------
{
    my %git = (FAKE_GIT_BRANCH => 'feature/kosik');
    my ($rc, $out, $err) = sh({%git}, $IMAGES_SH, 'pwe_image', 'pwe-mariadb');
    is("$rc|$out", "0|ghcr.io/kukam/pwe-mariadb:feature-kosik\n", 'pwe_image pwe-mariadb: vychozi registr, tag z vetve');
    ($rc, $out, $err) = sh({%git, PWE_IMAGE_REGISTRY => 'registry.example.test/tym/', PWE_IMAGE_TAG => 'rucni'}, $IMAGES_SH, 'pwe_image', 'pwe-static');
    is("$rc|$out", "0|registry.example.test/tym/pwe-static:rucni\n", 'pwe_image: PWE_IMAGE_REGISTRY (bez koncoveho lomitka) a PWE_IMAGE_TAG');
    ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => 'a/b'}, $IMAGES_SH, 'pwe_image', 'pwe-static');
    is("$rc|$out", '2|', 'pwe_image: neplatny PWE_IMAGE_TAG -> kod 2 a zadne (neuplne) jmeno image na stdout');

    ($rc, $out, $err) = sh({%git}, $IMAGES_SH, 'pwe_tool_image');
    is("$rc|$out", "0|ghcr.io/kukam/pwe-debugger:feature-kosik\n", 'pwe_tool_image: vychozi image nastroju je pwe-debugger:<tag vetve>');
    ($rc, $out, $err) = sh({%git, PWE_TEST_IMAGE => 'ghcr.io/kukam/pwe-base:jina', PWE_IMAGE_TAG => 'a/b'}, $IMAGES_SH, 'pwe_tool_image');
    is("$rc|$out", "0|ghcr.io/kukam/pwe-base:jina\n", 'pwe_tool_image: PWE_TEST_IMAGE ma prednost (PWE_IMAGE_TAG se pak nepouzije ani nekontroluje)');
    ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => 'a/b'}, $IMAGES_SH, 'pwe_tool_image');
    is("$rc|$out", '2|', 'pwe_tool_image: neplatny PWE_IMAGE_TAG -> kod 2, prazdny stdout');

    # prirazeni IMAGE="$(pwe_tool_image)" pod set -e skonci a hlaska je videt
    ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => 'a/b'}, '-c', 'set -e; . "$1"; IMAGE="$(pwe_tool_image)"; echo "DOSLO $IMAGE"', 'x', $IMAGES_SH);
    is($rc, 2, 'set -e + IMAGE="$(pwe_tool_image)": neplatny PWE_IMAGE_TAG ukonci skript kodem 2');
    unlike($out, qr/DOSLO/, 'set -e + IMAGE="$(pwe_tool_image)": skript za prirazenim nepokracuje');
    like($err, qr/PWE_IMAGE_TAG='a\/b' neni platny tag image/, 'set -e + IMAGE="$(pwe_tool_image)": hlaska je na stderr');

    # neznama funkce pri primem spusteni
    ($rc, $out, $err) = sh({}, $IMAGES_SH, 'neznama_funkce');
    is($rc, 2, 'images.sh <neznama funkce>: kod 2');
    like($err, qr/pwe_image_branch.*pwe_image_missing_hint/s, 'images.sh <neznama funkce>: napoveda jmenuje i nove funkce');

    # exportovany CDPATH nesmi zmenit koren repozitare (cd by cilovy adresar vypsal na stdout)
    log_reset();
    ($rc, $out, $err) = run_cmd({env => {FAKE_GIT_BRANCH => 'pwe.ai', CDPATH => "$T:."}, cwd => $T}, $BASH, 'repo/PWE/tools/lib/images.sh', 'pwe_image_tag');
    is("$rc|$out|$err", "0|pwe.ai\n|", 'images.sh s exportovanym CDPATH: tag z vetve (ne tichy master)');
    is(((calls('git'))[0] || [])->[1], $REPO, 'images.sh s exportovanym CDPATH: koren repozitare je jedna cesta');
    foreach my $tool (qw(run-tests.sh perl-compile.sh)) {
        log_reset();
        ($rc, $out, $err) = run_cmd({env => {FAKE_GIT_BRANCH => 'pwe.ai', CDPATH => "$T:."}, cwd => $T}, $BASH, "repo/PWE/tools/$tool");
        is($rc, 0, "$tool s exportovanym CDPATH: probehne") or diag($err);
        ok(has_pair(((calls('docker', 'run'))[0] || []), '-v', "$REPO:/PWE"), "$tool s exportovanym CDPATH: mount korene repozitare");
    }

  SKIP: {
        my ($zsh) = grep { -x $_ } map { "$_/zsh" } grep { length } split(/:/, $SYS_PATH);
        skip 'zsh neni k dispozici (v kontejneru; nacteni ze zsh se overuje na hostiteli)', 3 unless ($zsh);
        ($rc, $out, $err) = run_cmd({env => {FAKE_GIT_BRANCH => 'feature/kosik'}}, $zsh, '-c', '. "$1"; pwe_image_tag; pwe_image pwe-base; pwe_image_tag_valid "a/b" || echo neplatny', 'x', $IMAGES_SH);
        is("$rc|$out", "0|feature-kosik\nghcr.io/kukam/pwe-base:feature-kosik\nneplatny\n", 'images.sh nactene ze zsh: tag z vetve, pwe_image, pwe_image_tag_valid');
        is($err, '', 'images.sh nactene ze zsh: bez chyb na stderr');
        ($rc, $out, $err) = run_cmd({env => {FAKE_GIT_BRANCH => 'pwe.ai'}, cwd => $T}, $zsh, '-f', '-i', '-c', '. repo/PWE/tools/lib/images.sh; pwe_image_tag');
        is("$rc|$out", "0|pwe.ai\n", 'images.sh nactene z interaktivniho zsh relativni cestou: tag z vetve (ne tichy master)');
    }

    # rada pri chybejicim image: shell pwe_image_missing_hint i Perl _image_missing_note
    my $note = sub {
        my ($env, $image) = @_;
        local %ENV = (%BASE_ENV, %{$env});
        return PWE::ToolEnv::_image_missing_note($image);
    };
    my $image = 'ghcr.io/kukam/pwe-debugger:nova-vetev';
    log_reset();
    ($rc, $out, $err) = sh({FAKE_DOCKER_INSPECT_RC => 0}, $IMAGES_SH, 'pwe_image_missing_hint', $image, 'run-tests');
    is("$rc|$out|$err", '0||', 'pwe_image_missing_hint: image je v lokalnim Dockeru -> nic nevypise');
    is_deeply([calls('docker')], [['image', 'inspect', $image]], 'pwe_image_missing_hint: pta se docker image inspect <image>');
    is($note->({FAKE_DOCKER_INSPECT_RC => 0}, $image), '', 'ToolEnv::_image_missing_note: image je v lokalnim Dockeru -> prazdny retezec');

    my %missing = (FAKE_DOCKER_INSPECT_RC => 1, FAKE_DOCKER_TAGS => 'pwe.ai <none> master pwe.ai');
    log_reset();
    ($rc, $out, $err) = sh({%missing}, $IMAGES_SH, 'pwe_image_missing_hint', $image, 'run-tests');
    is("$rc|$out", '0|', 'pwe_image_missing_hint: chybejici image -> kod 0 (jen rada), nic na stdout');
    like($err, qr/^\[run-tests\] image \Q$image\E neni v lokalnim Dockeru, docker ho zkusi stahnout z registru/, 'pwe_image_missing_hint: image neni v lokalnim Dockeru a docker ho zkusi stahnout');
    like($err, qr/^\[run-tests\] .*make images/m, 'pwe_image_missing_hint: nabizi make images');
    like($err, qr{^\[run-tests\] .*tagy ghcr\.io/kukam/pwe-debugger: master pwe\.ai \(pouziti: PWE_IMAGE_TAG=<tag>\)$}m, 'pwe_image_missing_hint: mistne dostupne tagy tehoz repozitare (serazene, bez <none> a opakovani)');
    unlike($err, qr/PWE_IMAGE_TAG=master/, 'pwe_image_missing_hint: zadne slepe doporuceni PWE_IMAGE_TAG=master');
    is_deeply((calls('docker', 'image'))[-1], ['image', 'ls', '--format', '{{.Tag}}', 'ghcr.io/kukam/pwe-debugger'], 'pwe_image_missing_hint: tagy z docker image ls <repozitar>');
    ($rc, $out, $err) = sh({%missing}, $IMAGES_SH, 'pwe_image_missing_hint', $image);
    is($note->({%missing}, $image), $err, 'ToolEnv::_image_missing_note = pwe_image_missing_hint (mistni tagy)');

    ($rc, $out, $err) = sh({FAKE_DOCKER_INSPECT_RC => 1}, $IMAGES_SH, 'pwe_image_missing_hint', 'localhost:5000/tym/pwe-debugger:x');
    like($err, qr{^\[tools\] .*neni zadny image localhost:5000/tym/pwe-debugger$}m, 'pwe_image_missing_hint: bez mistnich tagu to rekne (repozitar = jmeno bez tagu, port registru zustava)');
    is($note->({FAKE_DOCKER_INSPECT_RC => 1}, 'localhost:5000/tym/pwe-debugger:x'), $err, 'ToolEnv::_image_missing_note = pwe_image_missing_hint (zadny mistni tag)');

    my %test_image = (%missing, PWE_TEST_IMAGE => 'ghcr.io/kukam/pwe-base:nic');
    ($rc, $out, $err) = sh({%test_image}, $IMAGES_SH, 'pwe_image_missing_hint', 'ghcr.io/kukam/pwe-base:nic');
    like($err, qr{\(pouziti: PWE_TEST_IMAGE=ghcr\.io/kukam/pwe-base:<tag>\)$}m, 'pwe_image_missing_hint: u image z PWE_TEST_IMAGE radi PWE_TEST_IMAGE, ne PWE_IMAGE_TAG');
    is($note->({%test_image}, 'ghcr.io/kukam/pwe-base:nic'), $err, 'ToolEnv::_image_missing_note = pwe_image_missing_hint (PWE_TEST_IMAGE)');

    # Perl nastroje: ensure_modules() se pri chybejicim modulu spusti znovu v kontejneru image nastroju
    # a preda mu registr a tag (v kontejneru neni git, image_tag() by tam jinak vratil master).
    # Skript si in_container() nahrazuje ze stejneho duvodu jako perl_image_tag().
    my $tool = "$T/tool.pl";
    spit($tool, <<'EOS');
use strict;
use warnings;
use PWE::ToolEnv qw(ensure_modules);
{ no warnings 'redefine'; *PWE::ToolEnv::in_container = sub { return 0; }; }
ensure_modules('PWE::Tento::Modul::Neexistuje');
print "POKRACUJE NA HOSTITELI\n";
EOS
    my $repo_root = PWE::ToolEnv::repo_root();
    my $tool_img  = 'registry.example.test/tym/pwe-debugger:feature-kosik';
    log_reset();
    ($rc, $out, $err) = run_cmd({env => {%git, PWE_IMAGE_REGISTRY => 'registry.example.test/tym/', FAKE_DOCKER_INSPECT_RC => 1, FAKE_DOCKER_RUN_RC => 6}}, $^X, "-I$TOOLS/lib", $tool, '--volba', 'hodnota');
    is($rc, 6, 'ensure_modules: skript skonci s navratovym kodem behu v kontejneru');
    unlike($out, qr/POKRACUJE/, 'ensure_modules: na hostiteli skript nepokracuje');
    my @em = @{(calls('docker', 'run'))[0] || []};
    is_deeply([@em[0 .. 3]], ['run', '--rm', '--entrypoint', 'perl'], 'ensure_modules: docker run --rm --entrypoint perl');
    ok(has_pair(\@em, '-v', "$repo_root:/PWE") && has_pair(\@em, '-w', '/PWE') && has_pair(\@em, '-e', 'PWE_TOOLS_IN_DOCKER=1'), 'ensure_modules: mount korene repozitare do /PWE, pracovni adresar /PWE, PWE_TOOLS_IN_DOCKER=1');
    ok(has_pair(\@em, '-e', 'PWE_IMAGE_REGISTRY=registry.example.test/tym') && has_pair(\@em, '-e', 'PWE_IMAGE_TAG=feature-kosik'), 'ensure_modules: do kontejneru preda registr a tag (vetev z hostitele)');
    ok(has_pair(\@em, $tool_img, '-I/PWE/PWE/tools/lib'), 'ensure_modules: image nastroju podle registru a vetve, moduly z /PWE/PWE/tools/lib');
    is_deeply([@em[-3 .. -1]], [$tool, '--volba', 'hodnota'], 'ensure_modules: tentyz skript se stejnymi argumenty');
    like($err, qr/^\[tools\] image \Q$tool_img\E neni v lokalnim Dockeru/m, 'ensure_modules: rada pri chybejicim image');
    log_reset();
    ($rc, $out, $err) = run_cmd({env => {%git, PWE_TEST_IMAGE => 'ghcr.io/kukam/pwe-base:jina'}}, $^X, "-I$TOOLS/lib", $tool);
    @em = @{(calls('docker', 'run'))[0] || []};
    ok(has_pair(\@em, 'ghcr.io/kukam/pwe-base:jina', '-I/PWE/PWE/tools/lib') && has_pair(\@em, '-e', 'PWE_TEST_IMAGE=ghcr.io/kukam/pwe-base:jina'), 'ensure_modules: PWE_TEST_IMAGE prepise image nastroju a preda se do kontejneru');
    log_reset();
    ($rc, $out, $err) = run_cmd({env => {%git, PWE_IMAGE_TAG => 'a/b'}}, $^X, "-I$TOOLS/lib", $tool);
    isnt($rc, 0, 'ensure_modules: neplatny PWE_IMAGE_TAG -> chyba');
    like($err, qr/PWE_IMAGE_TAG='a\/b' neni platny tag image/, 'ensure_modules: neplatny PWE_IMAGE_TAG -> hlaska');
    is(scalar(calls('docker', 'run')), 0, 'ensure_modules: neplatny PWE_IMAGE_TAG -> docker run se nespusti');
}

# ---------------------------------------------------------------------------------------------
# build-images.sh
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
    is($env->{'TAG'},        'pwe.ai',        'build-images.sh: TAG = vetev gitu');
    is($env->{'VERSION'},    '9.8.7',         'build-images.sh: VERSION = obsah PWE/VERSION (bez bilych znaku)');
    is($env->{'REVISION'},   $HEAD,           'build-images.sh: REVISION = commit (cisty strom)');
    like($env->{'CREATED'}, qr/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/, 'build-images.sh: CREATED ve tvaru RFC 3339 (UTC)');
    is($env->{'SOURCE'}, '<unset>', 'build-images.sh: SOURCE se bez PWE_IMAGE_SOURCE nepredava (plati vychozi z docker-bake.hcl)');
    is($env->{'CWD'},    $REPO,     'build-images.sh: bake bezi z korene repozitare');

    log_reset();
    ($rc, $out, $err) = sh({%git, FAKE_GIT_DIRTY => ' M PWE/pwe.fcgi'}, $build, 'pwe', 'debugger', 'pwe-base');
    is($rc, 0, 'build-images.sh: mistni build s necommitnutymi zmenami je v poradku');
    is_deeply(bake_args(), ['-f', 'docker-bake.hcl', '--load', 'pwe', 'debugger', 'base'], 'build-images.sh: vybrane cile (i s predponou pwe-)');
    is(call_env()->{'REVISION'}, '', 'build-images.sh: s necommitnutymi zmenami je REVISION prazdna');

    log_reset();
    ($rc, $out, $err) = sh({%git}, $build, 'pwe-foo');
    is($rc, 2, 'build-images.sh: neznamy cil -> kod 2');
    ok(!defined(bake_args()), 'build-images.sh: neznamy cil -> bake se nespusti');

    log_reset();
    ($rc, $out, $err) = sh({%git}, $build, '--print', 'base');
    is_deeply(bake_args(), ['-f', 'docker-bake.hcl', '--print', 'base'], 'build-images.sh --print: jen vypis (bez --load a --push)');

    ($rc, $out, $err) = sh({%git}, $build, '--help');
    is($rc, 0, 'build-images.sh --help: kod 0');
    like($out, qr/--allow-dirty.*--platform.*PWE_IMAGE_REGISTRIES/s, 'build-images.sh --help: popisuje --allow-dirty, --platform i PWE_IMAGE_REGISTRIES');

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

    # tag: neplatny PWE_IMAGE_TAG a tag tvaru verze (zamenil by se s tagem verze image pwe) - vzdy kod 2
    log_reset();
    ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => 'feature/kosik'}, $build, '--print');
    is($rc, 2, 'build-images.sh: neplatny PWE_IMAGE_TAG -> kod 2');
    like($err, qr/neni platny tag image/, 'build-images.sh: neplatny PWE_IMAGE_TAG -> hlaska z pwe_image_tag');
    ok(!defined(bake_args()), 'build-images.sh: neplatny PWE_IMAGE_TAG -> bake se nespusti');
    foreach my $c ([{%git, PWE_IMAGE_TAG => '2.1.0'}, [], 'PWE_IMAGE_TAG=2.1.0, mistni build'], [{%git, PWE_IMAGE_TAG => '2.1.0'}, ['--print'], 'PWE_IMAGE_TAG=2.1.0, --print'],
        [{%git, PWE_IMAGE_TAG => '9.8.7'}, ['--push'], 'PWE_IMAGE_TAG = verze enginu, --push'], [{FAKE_GIT_BRANCH => '10.20.30'}, ['pwe'], 'vetev 10.20.30'], [{FAKE_GIT_BRANCH => '-2.1.0'}, ['--print'], 'vetev -2.1.0 (prevod da 2.1.0)'])
    {
        log_reset();
        ($rc, $out, $err) = sh($c->[0], $build, @{$c->[1]});
        is($rc, 2, "build-images.sh: tag tvaru verze ($c->[2]) -> kod 2");
        like($err, qr/tvar verze X\.Y\.Z/, "build-images.sh: tag tvaru verze ($c->[2]) -> hlaska");
        ok(!defined(bake_args()), "build-images.sh: tag tvaru verze ($c->[2]) -> bake se nespusti");
    }
    foreach my $tag (qw(v2.1.0 2.1 2.1.0-rc1 release-2.1.0 2.1.x)) {
        log_reset();
        ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => $tag}, $build, '--print');
        is("$rc|" . (call_env()->{'TAG'} || ''), "0|$tag", "build-images.sh: tag $tag neni tvar verze X.Y.Z -> projde");
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
    is($rc, 0, 'build-images.sh --push: cisty strom na vetvi -> publikuje') or diag($err);
    is_deeply(bake_args(), ['-f', 'docker-bake.hcl', '--set', '*.platform=linux/amd64,linux/arm64', '--push'], 'build-images.sh --push bez --platform: vychozi platformy linux/amd64,linux/arm64');
    like($err, qr{--push bez --platform.*linux/amd64,linux/arm64}, 'build-images.sh --push bez --platform: vychozi platformy vypise');
    is(call_env()->{'TAG'} . '|' . call_env()->{'REVISION'}, "pwe.ai|$HEAD", 'build-images.sh --push: tag vetve a commit v REVISION');
    log_reset();
    ($rc, $out, $err) = sh({%git}, $build, '--push', '--platform', 'linux/arm64', 'pwe');
    is_deeply(bake_args(), ['-f', 'docker-bake.hcl', '--set', '*.platform=linux/arm64', '--push', 'pwe'], 'build-images.sh --push --platform P: zadana platforma zustava');
    unlike($err, qr/--push bez --platform/, 'build-images.sh --push --platform P: hlaska o vychozich platformach se nevypise');

    # --push: tag musi byt urcity (PWE_IMAGE_TAG nebo vetev)
    foreach my $c (
        [{FAKE_GIT_BRANCH => ''},                               'odpojeny HEAD'],
        [{FAKE_GIT_BRANCH => 'cizi', FAKE_GIT_NOREPO => 1},     'kopie bez gitoveho repozitare'],
        [{FAKE_GIT_BRANCH => 'cizi', FAKE_GIT_PREFIX => 'sub/'}, 'kopie uvnitr ciziho gitu'],
        [{PATH => $NOGIT_PATH},                                 'bez prikazu git'],
        [{FAKE_GIT_BRANCH => '+master'},                        'vetev +master (prevod da master)'],
      )
    {
        log_reset();
        ($rc, $out, $err) = sh($c->[0], $build, '--push');
        is($rc, 2, "build-images.sh --push ($c->[1]): kod 2");
        like($err, qr/PWE_IMAGE_TAG=<tag>/, "build-images.sh --push ($c->[1]): radi zadat PWE_IMAGE_TAG");
        ok(!defined(bake_args()), "build-images.sh --push ($c->[1]): nic se nestavi ani nepublikuje");
    }
    log_reset();
    ($rc, $out, $err) = sh({FAKE_GIT_BRANCH => 'master'}, $build, '--push');
    is("$rc|" . (call_env()->{'TAG'} || ''), '0|master', 'build-images.sh --push na vetvi master: tag master je v poradku');
    log_reset();
    ($rc, $out, $err) = sh({FAKE_GIT_BRANCH => '', PWE_IMAGE_TAG => 'rucni'}, $build, '--push');
    is("$rc|" . (call_env()->{'TAG'} || ''), '0|rucni', 'build-images.sh --push v odpojenem HEAD s PWE_IMAGE_TAG: publikuje zadany tag');

    # mistni build bez urcitelne vetve jen varuje, ze stavi tag master
    log_reset();
    ($rc, $out, $err) = sh({FAKE_GIT_BRANCH => ''}, $build);
    is("$rc|" . (call_env()->{'TAG'} || ''), '0|master', 'build-images.sh v odpojenem HEAD (mistni build): stavi tag master');
    like($err, qr/POZOR: vetev gitu nelze urcit.*tag master/, 'build-images.sh v odpojenem HEAD (mistni build): varovani');
    log_reset();
    ($rc, $out, $err) = sh({%git}, $build);
    unlike($err, qr/POZOR/, 'build-images.sh na vetvi: zadne varovani');

    # --print s --push: pojistky jen varuji (nic se nepublikuje)
    log_reset();
    ($rc, $out, $err) = sh({FAKE_GIT_BRANCH => ''}, $build, '--print', '--push');
    is($rc, 0, 'build-images.sh --print --push v odpojenem HEAD: jen vypis, kod 0');
    like($err, qr/POZOR: .*PWE_IMAGE_TAG=<tag>.*--push by skoncil chybou/, 'build-images.sh --print --push v odpojenem HEAD: varuje, ze --push by skoncil chybou');
    is_deeply(bake_args(), ['-f', 'docker-bake.hcl', '--set', '*.platform=linux/amd64,linux/arm64', '--print'], 'build-images.sh --print --push: vypis s platformami publikace, bez --push');

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
    like($err, qr/POZOR: .*--allow-dirty.*revision/, 'build-images.sh --push --allow-dirty: varuje, ze image nebude mit popisek revision');
    ok(scalar(grep { $_ eq '--push' } @{bake_args() || []}), 'build-images.sh --push --allow-dirty: bake dostane --push');

    # --push bez gitu (tag zadany vyslovne): varovani, ze popisek revision bude prazdny
    log_reset();
    ($rc, $out, $err) = sh({PATH => $NOGIT_PATH, PWE_IMAGE_TAG => 'rucni'}, $build, '--push');
    is($rc, 0, 'build-images.sh --push bez gitu s PWE_IMAGE_TAG: publikuje') or diag($err);
    like($err, qr/POZOR: bez gitu.*revision.*prazdny/, 'build-images.sh --push bez gitu: varuje, ze popisek revision bude prazdny');
    is(call_env()->{'TAG'} . '|' . call_env()->{'REVISION'}, 'rucni|', 'build-images.sh --push bez gitu: zadany tag, prazdna REVISION');
    log_reset();
    ($rc, $out, $err) = sh({FAKE_GIT_BRANCH => 'cizi', FAKE_GIT_PREFIX => 'sub/', FAKE_GIT_HEAD => 'ffffffffffffffffffffffffffffffffffffffff', PWE_IMAGE_TAG => 'rucni'}, $build, '--push');
    is("$rc|" . (defined(call_env()->{'REVISION'}) ? call_env()->{'REVISION'} : 'x'), '0|', 'build-images.sh --push uvnitr ciziho gitu: commit ciziho repozitare se do REVISION nedostane');
}

# ---------------------------------------------------------------------------------------------
# run-tests.sh a perl-compile.sh: prikazova radka docker run, navratovy kod, zamek pracovni kopie
# ---------------------------------------------------------------------------------------------
{
    my $run_tests = "$REPO/PWE/tools/run-tests.sh";
    my $compile   = "$REPO/PWE/tools/perl-compile.sh";
    my %git       = (FAKE_GIT_BRANCH => 'feature/kosik');
    my $image     = 'ghcr.io/kukam/pwe-debugger:feature-kosik';
    my ($rc, $out, $err);

    log_reset();
    ($rc, $out, $err) = sh({%git}, $run_tests);
    is($rc, 0, 'run-tests.sh: kod 0') or diag($err);
    my @run = calls('docker', 'run');
    is(scalar(@run), 1, 'run-tests.sh: jedno volani docker run');
    my @args = @{$run[0] || []};
    is_deeply([@args[0 .. 10]], ['run', '--rm', '--init', '--entrypoint', 'bash', '-v', "$REPO:/PWE", '-w', '/PWE/PWE', $image, '-c'],
        'run-tests.sh: docker run --rm --init --entrypoint bash -v <repo>:/PWE -w /PWE/PWE <image nastroju podle vetve> -c');
    like($args[11] || '', qr{unset FCGI_SOCKET_PATH.*PWE_CONF_.*exec prove -I/PWE/PWE -I/PWE/PWE/t/lib "\$\@"}s, 'run-tests.sh: skript v kontejneru cisti prostredi a spousti prove');
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
        'perl-compile.sh: docker run --rm --entrypoint bash -v <repo>:/PWE -w /PWE/PWE <image nastroju podle vetve> -c');
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
    my $image = 'ghcr.io/kukam/pwe-debugger:pwe.ai';
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
    ok(has_pair(\@args, $image, '-c'), 'pwe-cgi.sh: image nastroju podle vetve');
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
}

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
        is("$env->{'PWE_IMAGE_REGISTRY'}|$env->{'PWE_IMAGE_TAG'}|$env->{'CWD'}", "ghcr.io/kukam|feature-kosik|$REPO", "run-webapp.sh $web: registr a tag pro docker-compose.yml, beh z korene repozitare");
        unlike($err, qr/POZOR/, "run-webapp.sh $web: profil odvozeny z webu -> zadne varovani");
    }

    # volani z Makefile: make run / restart / logs / down, s profilem i bez, s ARGS
    foreach my $c (
        [['st.web', 'up', '--remove-orphans'],                       'static',  ['up', '--remove-orphans'],             'make run'],
        [['db.web', 'up', '--remove-orphans', '-d', '--build'],      'mariadb', ['up', '--remove-orphans', '-d', '--build'], "make run ARGS='-d --build'"],
        [['st.web', 'static', 'up', '--remove-orphans', '-d'],       'static',  ['up', '--remove-orphans', '-d'],       'make run PROFILE=static ARGS=-d'],
        [['db.web', 'restart', 'fcgi'],                              'mariadb', ['restart', 'fcgi'],                    'make restart'],
        [['db.web', 'mariadb', 'restart', 'fcgi'],                   'mariadb', ['restart', 'fcgi'],                    'make restart PROFILE=mariadb'],
        [['st.web', 'logs', '-f', 'fcgi'],                           'static',  ['logs', '-f', 'fcgi'],                 'make logs'],
        [['db.web', 'down', '-v'],                                   'mariadb', ['down', '-v'],                         'make down ARGS=-v'],
        [['dblink.web', 'mysql', 'down', '-v', '--remove-orphans'],  'mysql',   ['down', '-v', '--remove-orphans'],     "make down PROFILE=mysql ARGS='-v --remove-orphans'"],
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
    like($err, qr{^\[run-webapp\] POZOR: web db\.web ma conf/mariadb\.conf, ale profil je static}m, 'run-webapp.sh: web s conf/mariadb.conf a profil static -> varovani');
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

    # rada pri chybejicim image a neplatny tag
    log_reset();
    ($rc, $out, $err) = sh({%git, FAKE_DOCKER_INSPECT_RC => 1, FAKE_DOCKER_TAGS => 'pwe.ai'}, $run, 'st.web', 'static', 'up');
    like($err, qr{^\[run-webapp\] image ghcr\.io/kukam/pwe-static:feature-kosik neni v lokalnim Dockeru.*^\[run-webapp\] image ghcr\.io/kukam/pwe-debugger:feature-kosik neni v lokalnim Dockeru}ms,
        'run-webapp.sh up: rada pri chybejicim image profilu i ladiciho image');
    unlike($err, qr/PWE_IMAGE_TAG=master/, 'run-webapp.sh up: zadne slepe doporuceni PWE_IMAGE_TAG=master');
    log_reset();
    ($rc, $out, $err) = sh({%git, PWE_IMAGE_TAG => 'a/b'}, $run, 'st.web');
    is($rc . '|' . scalar(calls('docker')), '2|0', 'run-webapp.sh: neplatny PWE_IMAGE_TAG -> kod 2, docker se nevola');
}

# ---------------------------------------------------------------------------------------------
# docker-bake.hcl: 7 cilu, vsechny dedi spolecne nastaveni, tag verze ma jen cil pwe
# ---------------------------------------------------------------------------------------------
SKIP: {
    my $bake = slurp(dirname($ROOT) . '/docker-bake.hcl');
    skip 'docker-bake.hcl neni k dispozici (engine bez korene repozitare)', 40 unless (length($bake));
    (my $code = $bake) =~ s/^\s*#.*\n//mg;    # bez komentaru
    my @names = qw(base pwe static mariadb mysql postgres debugger);

    my %target;
    while ($code =~ /^target\s+"([^"]+)"\s*\{\n(.*?)^\}/msg) { $target{$1} = $2; }
    is_deeply([sort grep { !/^_/ } keys %target], [sort @names], 'docker-bake.hcl: prave 7 cilu (base, pwe, static, mariadb, mysql, postgres, debugger)');

    my ($group) = $code =~ /^group\s+"default"\s*\{\n(.*?)^\}/ms;
    my @default = (defined($group) and $group =~ /targets\s*=\s*\[([^\]]*)\]/) ? ($1 =~ /"([^"]+)"/g) : ();
    is_deeply([sort @default], [sort @names], 'docker-bake.hcl: skupina default stavi vsech 7 cilu');

    my $common = $target{'_common'} || '';
    like($common, qr/^\s*context\s*=\s*"\."\s*$/m,                        'docker-bake.hcl: spolecne nastaveni - kontext = koren repozitare');
    like($common, qr{^\s*dockerfile\s*=\s*"PWE/docker/Dockerfile"\s*$}m, 'docker-bake.hcl: spolecne nastaveni - jeden Dockerfile');
    unlike($common, qr/^\s*tags\s*=/m,                                    'docker-bake.hcl: spolecne nastaveni samo zadny tag nema');

    foreach my $name (@names) {
        my $body  = $target{$name} || '';
        my $image = ($name eq 'pwe') ? 'pwe' : "pwe-$name";
        like($body, qr/^\s*inherits\s*=\s*\[[^\]]*"_common"[^\]]*\]/m, "docker-bake.hcl: cil $name dedi spolecne nastaveni (_common)");
        like($body, qr/^\s*target\s*=\s*"\Q$name\E"\s*$/m,             "docker-bake.hcl: cil $name stavi stage $name");
        my ($tags) = $body =~ /^\s*tags\s*=\s*(.*)$/m;
        $tags = '' unless (defined($tags));
        like($tags, qr/^image_tags\("\Q$image\E",/, "docker-bake.hcl: cil $name oznacuje image $image");
        if ($name eq 'pwe') {
            like($tags, qr/\[TAG,\s*VERSION\]/, 'docker-bake.hcl: cil pwe ma tag vetve i tag verze');
        }
        else {
            like($tags, qr/^image_tags\("\Q$image\E",\s*\[TAG\]\)\s*$/, "docker-bake.hcl: cil $name ma jen tag vetve");
            unlike($body, qr/\bVERSION\b/, "docker-bake.hcl: cil $name verzi enginu nepouziva");
        }
    }
    unlike($code, qr/latest/, 'docker-bake.hcl: zadny tag latest');
}

done_testing();
