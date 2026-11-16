#!/usr/bin/env perl
# PWE/tools/k8s.sh (nasazeni do Kubernetes, cile make k8s-*):
#   - bezpecnost kontextu: bez KUBE_CONTEXT se ke clusteru nic nepripoji, template bez kontextu dostane
#     prazdny kubeconfig, kazdy helm/kubectl dostane --kube-context/--context a --namespace (hlida se
#     u KAZDEHO volani ve vsech bezich testu, viz @VIOLATIONS), prepinace menici cluster, kontext,
#     prihlaseni nebo namespace (v argumentech i v K8S_HELM_ARGS, vcetne slepenych kratkych -s/-n) se
#     odmitnou a promenne HELM_KUBE*, HELM_NAMESPACE a KUBERNETES_MASTER se helmu ani kubectl nepredaji
#   - deploy podle digestu (jen stdout dockeru, presny tvar sha256:<64 hex>), chybejici image = chyba
#     (vyjimka K8S_ALLOW_TAG=1); oznameni, kdyz cluster taha z jineho registru, nez kde se zjistil digest
#   - dva druhy nasazeni podle generic.pweImage: vzorove (pwe-example-static | -mariadb | -mysql | -postgres
#     = hotovy image vzoroveho webu: registr image PWE, tag verze z PWE/VERSION, prikaz image nic nestavi;
#     web a profil ve values musi nazvu image odpovidat) a vlastni web (image stavi prikaz image Dockerfilem
#     webu nad zavislostnim image pwe-<profil>, u webu bez databaze pwe-base; registr K8S_REGISTRY, vychozi
#     tag latest); nazvy zavislostnich image, pwe-example-* a zrusenych image pwe a pwe-static jsou vyhrazene
#   - hesla: zalozeni secrets-<nazev>.yml ze vzoru, ochrana existujiciho releasu (stav clusteru, ktery
#     nejde zjistit, neni "release neexistuje"), nevyplnene CHANGE_ME, zkouska nasucho (--dry-run
#     v argumentech i v K8S_HELM_ARGS), delete bez mistniho souboru s hesly
#   - kubernetes/local.env (uvozovky, CR, mezery, prednost promenne prostredi), kontrola nazvu a tagu
#   - image vlastniho webu: Dockerfile z drivejsi sablony se odmitne, kontrola platformy mistniho
#     zavislostniho image, argumenty docker buildx build
#   - status/delete hledaji svazky podle stitku releasu, test pouziva adresu z generic.pweHost
#   - values soubory: image vzoroveho webu z ghcr.io/kukam, tag latest, cesty /PWE/PWE a /PWE/webapps/<web>,
#     engine posloucha jen na 127.0.0.1:7779
#   - .gitignore a .dockerignore nepousti kubernetes/local.env a secrets-*.yml do gitu ani do image
#
# Skript se spousti z KOPIE v docasnem stromu (<tmp>/repo/PWE/tools, values a vzory z kubernetes/
# repozitare, vlastni PWE/VERSION) s falesnymi programy helm, kubectl, docker, curl a openssl na zacatku
# PATH. Falesne programy jen zapisuji sva volani do $FAKE_LOG (a promennou KUBECONFIG, se kterou byly
# spusteny; helm a kubectl navic do $FAKE_LOG.env promenne prostredi, ktere by menily cluster);
# k zadnemu clusteru ani registru se test nepripojuje.
use strict;
use warnings;
use Test::More;
use FindBin;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use POSIX ();
use lib "$FindBin::Bin/lib";
use PWE::TestEnv;

my $SYS_PATH = $ENV{'PATH'} || '/usr/local/bin:/usr/bin:/bin';
my ($BASH) = grep { -x $_ } map { "$_/bash" } grep { length } split(/:/, $SYS_PATH), '/bin';
plan skip_all => 'chybi bash' unless ($BASH);

my $ROOT     = PWE::TestEnv::root();    # adresar enginu PWE/ (v kontejneru /PWE/PWE)
my $REPOROOT = abs_path("$ROOT/..");     # koren repozitare
plan skip_all => 'chybi kubernetes/values-static.yml (repozitar bez adresare kubernetes/)'
    unless (-f "$REPOROOT/kubernetes/values-static.yml");

sub slurp { my ($f) = @_; open(my $fh, '<', $f) or return ''; local $/; my $s = <$fh>; close($fh); return defined($s) ? $s : ''; }

sub spit {
    my ($f, $content, $mode) = @_;
    make_path(dirname($f)) unless (-d dirname($f));
    open(my $fh, '>', $f) or die "Nelze zapsat $f: $!";
    print $fh $content;
    close($fh);
    chmod($mode, $f) if (defined($mode));
}

# ---------------------------------------------------------------------------------------------
# docasny strom
# ---------------------------------------------------------------------------------------------
my $T    = abs_path(tempdir('pwe-k8s-tool-XXXXXX', TMPDIR => 1, CLEANUP => 1));
my $REPO = "$T/repo";
my $LOG  = "$T/fake.log";
my $K8S  = "$REPO/PWE/tools/k8s.sh";

make_path("$REPO/PWE/tools/lib", "$REPO/kubernetes", "$REPO/PWE/assets/css/bootstrap-5.3.8", "$T/bin");
foreach my $f (qw(k8s.sh lib/images.sh)) {
    copy("$ROOT/tools/$f", "$REPO/PWE/tools/$f") or die "Nelze zkopirovat tools/$f: $!";
    chmod(0755, "$REPO/PWE/tools/$f");
}
foreach my $f (qw(values-static.yml values-generic.yml secrets-generic.example.yml)) {
    copy("$REPOROOT/kubernetes/$f", "$REPO/kubernetes/$f") or die "Nelze zkopirovat kubernetes/$f: $!";
}
# Verze enginu docasneho stromu: vychozi tag image PWE (pwe_image_tag cte PWE/VERSION vedle images.sh).
# Zamerne jina nez v repozitari - tag se nesmi brat odjinud.
my $VERSION = '9.8.7';
spit("$REPO/PWE/VERSION", "$VERSION\n");

# Vzorove weby v docasnem strome NEMAJI Dockerfile: vzorova nasazeni berou hotovy image vzoroveho webu
# (pwe-example-<profil>) a nic nestavi.
spit("$REPO/webapps/example.web/static/css/site.css", "body{}\n");

# Ctyri image vzorovych webu: [nazev image, profil, web]. Vzorove nasazeni se pozna jen podle nazvu image.
my @SAMPLES = (['pwe-example-static', 'static', 'example.web'], ['pwe-example-mariadb', 'mariadb', 'example-db.web'],
    ['pwe-example-mysql', 'mysql', 'example-db.web'], ['pwe-example-postgres', 'postgres', 'example-db.web']);

# values_variant(zdroj, web, profil, image) -> text kubernetes/values-<zdroj>.yml (static | generic) s jinym
# webem, profilem a nazvem image v bloku generic; undef = hodnotu ponechat. Vse ostatni je beze zmeny.
sub values_variant {
    my ($src, $web, $profile, $image) = @_;
    my $v = slurp("$REPO/kubernetes/values-$src.yml");
    my %set = ('pweWeb' => $web, 'pweProfile' => $profile, 'pweImage' => $image);
    foreach my $key (sort keys %set) {
        next unless (defined($set{$key}));
        $v =~ s/^  \Q$key\E: \S+/  $key: $set{$key}/m or die "values-$src.yml bez generic.$key";
    }
    return $v;
}

# web_dockerfile(zaklad, web) -> Dockerfile webu v dnesnim tvaru (sablona PWE/tools/new-webapp.pl):
# zavislostni image + engine z kontextu sestaveni + web. <zaklad> je nazev image ve FROM: pwe-base u webu
# bez databaze, pwe-${PWE_PROFILE} u webu s databazi.
sub web_dockerfile {
    my ($base, $web) = @_;
    return "# Image webu $web (zavislostni image + engine z kontextu + web)\n"
        . "ARG PWE_IMAGE_REGISTRY=ghcr.io/kukam\nARG PWE_IMAGE_TAG=latest\nARG PWE_PROFILE=static\n\n"
        . "FROM \${PWE_IMAGE_REGISTRY}/$base:\${PWE_IMAGE_TAG}\nARG PWE_PROFILE\n"
        . "COPY PWE/Libs /PWE/PWE/Libs\nCOPY PWE/pwe.fcgi /PWE/PWE/pwe.fcgi\nCOPY webapps/$web /PWE/webapps/$web\n"
        . "ENV PWE_CONF_pwe_home=/PWE/webapps/$web PWE_PROFILE=\${PWE_PROFILE}\nCMD [\"perl\", \"/PWE/PWE/pwe.fcgi\"]\n";
}

# Vlastni web bez databaze: kopie values-static.yml s jinym webem a nazvem image (postup z kubernetes/README.md)
spit("$REPO/webapps/mujweb.web/Dockerfile", web_dockerfile('pwe-base', 'mujweb.web'));
spit("$REPO/kubernetes/values-mujweb.yml", values_variant('static', 'mujweb.web', undef, 'mujweb-image'));
# Vlastni web s databazi: kopie values-generic.yml (bez vzoru hesel - prikazy image a template ho nepotrebuji)
spit("$REPO/webapps/mujdb.web/Dockerfile", web_dockerfile('pwe-${PWE_PROFILE}', 'mujdb.web'));
spit("$REPO/kubernetes/values-mujdb.yml", values_variant('generic', 'mujdb.web', undef, 'mujdb-image'));

my $DIGEST = 'sha256:' . ('ab' x 32);

# Falesne programy: radek "<program><TAB>KUBECONFIG=<hodnota|-><TAB>argumenty..." do $FAKE_LOG.
my $LOGLINE = <<'EOS';
{ printf '%s\tKUBECONFIG=%s' "$(basename "$0")" "${KUBECONFIG--}"; for a in "$@"; do printf '\t%s' "${a//$'\n'/ }"; done; printf '\n'; } >> "$FAKE_LOG"
EOS

# helm a kubectl zapisuji do $FAKE_LOG.env promenne prostredi, kterymi by slo zmenit cluster, prihlaseni
# nebo namespace mimo KUBE_CONTEXT a K8S_NAMESPACE - skript jim zadnou predat nesmi.
my $ENVLINE = <<'EOS';
env | grep -E '^(HELM_KUBE|HELM_NAMESPACE=|KUBERNETES_MASTER=)' | sed "s/^/$(basename "$0") /" >> "$FAKE_LOG.env"
EOS

# helm: "status" vraci FAKE_HELM_STATUS_RC (vychozi 1 = release neexistuje) a pri chybe vypise na stderr
# FAKE_HELM_STATUS_ERR (vychozi "Error: release: not found" jako skutecny helm; jina hlaska = stav releasu
# nejde zjistit, napr. nedostupny cluster). "upgrade" vraci FAKE_HELM_UPGRADE_RC (vychozi 0), ostatni 0.
spit("$T/bin/helm", "#!/bin/bash\n$LOGLINE$ENVLINE" . <<'EOS', 0755);
if [ "$1" = status ]; then
    rc="${FAKE_HELM_STATUS_RC:-1}"
    [ "$rc" = 0 ] || echo "${FAKE_HELM_STATUS_ERR-Error: release: not found}" >&2
    exit "$rc"
fi
[ "$1" = upgrade ] && exit "${FAKE_HELM_UPGRADE_RC:-0}"
exit 0
EOS

# kubectl: svazky (-o name / tabulka), jmena Secretu s certifikatem z ingressu, certifikaty a Secrety.
# FAKE_KUBECTL_RC = kazde volani skonci chybou (nedostupny cluster), FAKE_KUBECTL_WARN = varovani na
# stderr pri uspesnem volani (napr. "No resources found in pwe namespace.").
spit("$T/bin/kubectl", "#!/bin/bash\n$LOGLINE$ENVLINE" . <<'EOS', 0755);
if [ -n "${FAKE_KUBECTL_RC:-}" ]; then echo "Unable to connect to the server: dial tcp: i/o timeout" >&2; exit "$FAKE_KUBECTL_RC"; fi
[ -z "${FAKE_KUBECTL_WARN:-}" ] || echo "$FAKE_KUBECTL_WARN" >&2
case "$*" in
    *persistentvolumeclaims*"-o name"*) [ -n "${FAKE_PVC:-}" ] && printf 'persistentvolumeclaim/%s\n' "$FAKE_PVC" ;;
    *persistentvolumeclaims*)           [ -n "${FAKE_PVC:-}" ] && printf 'NAME STATUS\n%s Bound\n' "$FAKE_PVC" ;;
    *ingress*jsonpath*)                 printf '%s' "${FAKE_TLS:-}" ;;
    *"get certificates"*)               printf 'NAME READY\n%s True\n' "${FAKE_TLS:-}" ;;
    *"get secrets"*)                    printf 'NAME TYPE\n%s kubernetes.io/tls\n' "${FAKE_TLS:-}" ;;
esac
exit 0
EOS

# docker: digest v registru (FAKE_DIGEST, jinak "not found"), mistni zavislostni image (FAKE_LOCAL_PLATFORMS =
# seznam platforem oddeleny mezerou; prazdne = image mistne neni), kontext dockeru. FAKE_DOCKER_WARN =
# varovani na stderr pred digestem i za nim, FAKE_DIGEST_RC = navratovy kod, i kdyz digest vypise.
spit("$T/bin/docker", "#!/bin/bash\n$LOGLINE" . <<'EOS', 0755);
case "$1 $2" in
    "buildx imagetools")
        if [ -n "${FAKE_DIGEST:-}" ]; then
            [ -z "${FAKE_DOCKER_WARN:-}" ] || echo "WARNING: $FAKE_DOCKER_WARN" >&2
            printf '%s\n' "$FAKE_DIGEST"
            [ -z "${FAKE_DOCKER_WARN:-}" ] || echo "WARNING: $FAKE_DOCKER_WARN" >&2
            exit "${FAKE_DIGEST_RC:-0}"
        fi
        echo "ERROR: docker.io/x/y:z: not found" >&2; exit 1 ;;
    "buildx build") exit 0 ;;
    "context show") echo desktop-linux; exit 0 ;;
    "image inspect")
        shift 2
        case "$1" in --help) echo "      --platform string   Inspect a specific platform"; exit 0 ;; esac
        [ -n "${FAKE_LOCAL_PLATFORMS:-}" ] || exit 1
        case "$1" in
            --format) printf '%s\n' "${FAKE_LOCAL_PLATFORMS%% *}"; exit 0 ;;
            --platform) case " $FAKE_LOCAL_PLATFORMS " in *" $2 "*) exit 0 ;; *) exit 1 ;; esac ;;
        esac
        exit 0 ;;
esac
exit 0
EOS

# curl: stavovy kod FAKE_CURL_CODE (vychozi 200), telo "<html> ok"
spit("$T/bin/curl", "#!/bin/bash\n$LOGLINE" . <<'EOS', 0755);
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && printf '<html> ok\n' > "$out"
printf '%s' "${FAKE_CURL_CODE:-200}"
exit 0
EOS
spit("$T/bin/openssl", "#!/bin/bash\nexit 0\n", 0755);

# ---------------------------------------------------------------------------------------------
# spousteni
# ---------------------------------------------------------------------------------------------
my $RUN = 0;
my @VIOLATIONS;    # poruseni invariantu bezpecnosti pres vsechny behy k8s() (kontroluje se na konci testu)
my $CHECKED = 0;   # pocet volani helm a kubectl, nad kterymi se invarianty overovaly
my $FILE_CTX;      # kontext z kubernetes/local.env, dokud ho test v souboru ma (jinak undef)
my $ENVLOG = '';   # obsah $FAKE_LOG.env posledniho behu

# k8s({PROMENNA => hodnota}, argumenty...) -> (rc, stdout, stderr). Prostredi je jen to, co test nastavi.
#
# Po kazdem behu se nad VSEMI volanimi helm a kubectl overi invarianty (nezavisle na tom, co ktery test
# vyslovne kontroluje - hlidaji i mista volani, ktera do skriptu teprve pribudou):
#   - kubectl nese prave jedno --context <kontext>, helm prave jedno --kube-context <kontext>; kontext je
#     KUBE_CONTEXT z prostredi behu, jinak z local.env ($FILE_CTX). Jedina vyjimka: helm bez kontextu
#     s prazdnym kubeconfigem (template bez KUBE_CONTEXT);
#   - oba nesou prave jedno --namespace <K8S_NAMESPACE nebo pwe> a zadne -n;
#   - v jejich prostredi neni zadna promenna HELM_KUBE*, HELM_NAMESPACE ani KUBERNETES_MASTER.
sub k8s {
    my ($env, @args) = @_;
    $RUN++;
    my ($fout, $ferr) = ("$T/run-$RUN.out", "$T/run-$RUN.err");
    unlink($LOG, "$LOG.env");
    my $pid = fork();
    die "fork: $!" unless (defined($pid));
    if ($pid == 0) {
        %ENV = ('PATH' => "$T/bin:$SYS_PATH", 'HOME' => $T, 'FAKE_LOG' => $LOG, 'LC_ALL' => 'C');
        foreach my $k (keys %{$env}) { $ENV{$k} = $env->{$k} if (defined($env->{$k})); }
        open(STDIN,  '<', '/dev/null') or POSIX::_exit(126);
        open(STDOUT, '>', $fout)       or POSIX::_exit(126);
        open(STDERR, '>', $ferr)       or POSIX::_exit(126);
        exec($BASH, $K8S, @args) or POSIX::_exit(127);
    }
    local $SIG{'ALRM'} = sub { kill('KILL', $pid); };
    alarm(60);
    waitpid($pid, 0);
    alarm(0);
    my $rc = ($? & 127) ? 128 + ($? & 127) : ($? >> 8);

    my $want_ctx = defined($env->{'KUBE_CONTEXT'}) ? $env->{'KUBE_CONTEXT'} : $FILE_CTX;
    my $want_ns  = defined($env->{'K8S_NAMESPACE'}) ? $env->{'K8S_NAMESPACE'} : 'pwe';
    foreach my $line (split(/\n/, slurp($LOG))) {
        my ($p, $kc, @a) = split(/\t/, $line, -1);
        next unless (defined($p) and ($p eq 'helm' or $p eq 'kubectl'));
        $CHECKED++;
        push(@VIOLATIONS, map { "$_: beh $RUN (@args): $p " . join(' ', @a) } call_violations($p, $kc, \@a, $want_ctx, $want_ns));
    }
    $ENVLOG = slurp("$LOG.env");
    push(@VIOLATIONS, "prostredi: beh $RUN (@args): $_") foreach (split(/\n/, $ENVLOG));

    return ($rc, slurp($fout), slurp($ferr));
}

# call_violations(program, "KUBECONFIG=<hodnota|->", [argumenty], ocekavany kontext | undef, ocekavany namespace)
# -> seznam porusenych invariantu jednoho volani helm nebo kubectl (prazdny = v poradku)
sub call_violations {
    my ($p, $kc, $a, $want_ctx, $want_ns) = @_;
    my @bad;
    my @ctx = flag_values($a, ($p eq 'helm') ? '--kube-context' : '--context');
    if (@ctx) {
        push(@bad, 'kontext') unless (scalar(@ctx) == 1 and defined($want_ctx) and length($want_ctx) and $ctx[0] eq $want_ctx);
    }
    elsif (!($p eq 'helm' and !defined($want_ctx) and $kc eq 'KUBECONFIG=/dev/null')) {
        push(@bad, 'bez kontextu');
    }
    my @ns = flag_values($a, '--namespace');
    push(@bad, 'namespace') unless (scalar(@ns) == 1 and $ns[0] eq $want_ns and !grep({ /^-n/ } @{$a}));
    return @bad;
}

# hodnoty prepinace v argumentech volani: "--flag hodnota" i "--flag=hodnota" (chybejici hodnota = '')
sub flag_values {
    my ($args, $flag) = @_;
    my @v;
    for my $i (0 .. $#{$args}) {
        if ($args->[$i] eq $flag) { push(@v, defined($args->[$i + 1]) ? $args->[$i + 1] : ''); }
        elsif ($args->[$i] =~ /^\Q$flag\E=(.*)$/s) { push(@v, $1); }
    }
    return @v;
}

# volani falesneho programu: seznam [KUBECONFIG, argumenty...]
sub calls {
    my ($prog) = @_;
    my @c;
    foreach my $line (split(/\n/, slurp($LOG))) {
        my ($p, $kc, @args) = split(/\t/, $line, -1);
        next unless (defined($p) and $p eq $prog);
        $kc =~ s/^KUBECONFIG=//;
        push(@c, [$kc, @args]);
    }
    return @c;
}
sub has_pair { my ($args, $a, $b) = @_; for my $i (0 .. $#{$args} - 1) { return 1 if ($args->[$i] eq $a and $args->[$i + 1] eq $b); } return 0; }
sub has_arg  { my ($args, $a) = @_; return scalar(grep { $_ eq $a } @{$args}); }
# Vsechna volani helm i kubectl. Pozor: "return (calls('helm'), calls('kubectl'))" by ve skalarnim
# kontextu vratilo jen pocet volani kubectl (operator carka) - proto pres pole.
sub cluster_calls { my @c = (calls('helm'), calls('kubectl')); return @c; }
# odkazy na image, jejichz digest skript zjistoval v registru (docker buildx imagetools inspect <image>)
sub digest_refs { return map { $_->[4] } grep { ($_->[1] || '') eq 'buildx' and ($_->[2] || '') eq 'imagetools' } calls('docker'); }
sub builds      { return grep { ($_->[1] || '') eq 'buildx' and ($_->[2] || '') eq 'build' } calls('docker'); }

# %BASE = bez registru a tagu (vychozi hodnoty skriptu), %CFG = registr a tag zadane vyslovne
my %BASE = ('K8S_DOMAIN' => 'example.test', 'K8S_ISSUER' => 'issuer-test');
my %CFG  = (%BASE, 'K8S_REGISTRY' => 'reg.test/ns', 'K8S_IMAGE_TAG' => 'v-test');
my %CTX  = (%CFG,  'KUBE_CONTEXT' => 'ctx-test', 'FAKE_DIGEST' => $DIGEST);
my %BCTX = (%BASE, 'KUBE_CONTEXT' => 'ctx-test', 'FAKE_DIGEST' => $DIGEST);
my $SECRETS = "$REPO/kubernetes/secrets-generic.yml";

my ($rc, $out, $err);

# ---------------------------------------------------------------------------------------------
# napoveda a vstupy
# ---------------------------------------------------------------------------------------------
($rc, $out, $err) = k8s({}, '--help');
is($rc, 0, 'help: kod 0');
like($out, qr/KUBE_CONTEXT/,  'help: popisuje KUBE_CONTEXT');
like($out, qr/K8S_TIMEOUT/,   'help: popisuje K8S_TIMEOUT');
like($out, qr/K8S_ALLOW_TAG/, 'help: popisuje K8S_ALLOW_TAG');
unlike($out, qr/^set -e/m,    'help: konci pred kodem');

($rc, $out, $err) = k8s({%CTX}, 'deploy', 'Static');
is($rc, 2, 'nazev s velkym pismenem se odmitne');
($rc, $out, $err) = k8s({%CTX}, 'deploy', 'neni');
is($rc, 2, 'neexistujici values soubor: kod 2');
like($err, qr/values-neni\.yml neexistuje.*static/s, 'neexistujici values: hlaska nabizi dostupne nazvy');
($rc, $out, $err) = k8s({%CTX, 'K8S_IMAGE_TAG' => 'feature/x'}, 'template', 'static');
is($rc, 2, 'neplatny K8S_IMAGE_TAG se odmitne');
($rc, $out, $err) = k8s({%CTX, 'K8S_IMAGE_TAG' => 'v1@sha256:kratky'}, 'template', 'static');
is($rc, 2, 'K8S_IMAGE_TAG s neplatnym digestem se odmitne');
is(scalar(cluster_calls()), 0, 'neplatne vstupy: zadne volani helm ani kubectl');

# ---------------------------------------------------------------------------------------------
# kontext: nikdy aktualni kontext
# ---------------------------------------------------------------------------------------------
foreach my $cmd (qw(deploy status logs delete)) {
    ($rc, $out, $err) = k8s({%CFG}, $cmd, 'static');
    is($rc, 2, "$cmd bez KUBE_CONTEXT: kod 2");
    like($err, qr/neni nastaven KUBE_CONTEXT/, "$cmd bez KUBE_CONTEXT: hlaska");
    is(scalar(cluster_calls()), 0, "$cmd bez KUBE_CONTEXT: helm ani kubectl se nevolaji");
}
($rc, $out, $err) = k8s({%CTX, 'KUBE_CONTEXT' => '--context=jiny'}, 'deploy', 'static');
is($rc, 2, 'KUBE_CONTEXT zacinajici pomlckou se odmitne');

($rc, $out, $err) = k8s({%CFG}, 'template', 'static', '--validate');
is($rc, 0, 'template bez KUBE_CONTEXT: kod 0');
my ($tpl) = calls('helm');
ok($tpl, 'template: helm se zavola');
is($tpl->[0], '/dev/null', 'template bez KUBE_CONTEXT: helm dostane prazdny kubeconfig (--validate nepouzije aktualni kontext)');
ok(!grep({ /kube-context/ } @{$tpl}), 'template bez KUBE_CONTEXT: bez --kube-context');

($rc, $out, $err) = k8s({%CTX}, 'template', 'static');
($tpl) = calls('helm');
ok(has_pair($tpl, '--kube-context', 'ctx-test'), 'template s KUBE_CONTEXT: --kube-context ctx-test');

foreach my $bad (['--kube-context', 'jiny'], ['--kube-context=jiny'], ['--kubeconfig', '/x'], ['--kube-apiserver=https://x'], ['--context', 'jiny'], ['--server=https://x']) {
    ($rc, $out, $err) = k8s({%CTX}, 'deploy', 'static', @{$bad});
    is($rc, 2, "deploy s prepinacem $bad->[0]: kod 2");
    is(scalar(cluster_calls()), 0, "deploy s prepinacem $bad->[0]: helm ani kubectl se nevolaji");
}
# zbyle vzory odmitanych prepinacu: prihlaseni a TLS helmu, --cluster kubectl (kazdy vzor ma vlastni pripad)
foreach my $bad (['--kube-token=x'], ['--kube-as-user=x'], ['--kube-as-group=x'], ['--kube-ca-file=/x'], ['--kube-insecure-skip-tls-verify'],
    ['--kube-tls-server-name=x'], ['--cluster=jiny'], ['--kubeconfig=/x'], ['--kube-apiserver', 'https://x'], ['--server', 'https://x'], ['--context=jiny'])
{
    foreach my $cmd (qw(deploy delete template)) {
        ($rc, $out, $err) = k8s({%CTX}, $cmd, 'static', @{$bad});
        is($rc, 2, "$cmd s prepinacem $bad->[0]: kod 2");
        like($err, qr/prepinac '\Q$bad->[0]\E' neni povolen/, "$cmd s prepinacem $bad->[0]: hlaska jmenuje prepinac");
        is(scalar(cluster_calls()), 0, "$cmd s prepinacem $bad->[0]: helm ani kubectl se nevolaji");
    }
}
($rc, $out, $err) = k8s({%CTX, 'K8S_HELM_ARGS' => '--set-string a=b --kube-context jiny'}, 'template', 'static');
is($rc, 2, 'prepinac --kube-context v K8S_HELM_ARGS: kod 2');
is(scalar(cluster_calls()), 0, 'prepinac --kube-context v K8S_HELM_ARGS: helm ani kubectl se nevolaji');
($rc, $out, $err) = k8s({%CTX, 'K8S_HELM_ARGS' => '--kube-token=x'}, 'deploy', 'static');
is($rc, 2, 'prepinac --kube-token v K8S_HELM_ARGS: kod 2');
is(scalar(cluster_calls()), 0, 'prepinac --kube-token v K8S_HELM_ARGS: helm ani kubectl se nevolaji');

# namespace jen pres K8S_NAMESPACE: jinak by skript hlasil a hlidal (hesla, svazky) jiny namespace, nez do
# ktereho helm nebo kubectl sahne. Kratke -n i slepene (-njiny, -n=jiny, -in jiny).
foreach my $bad (['--namespace', 'jiny'], ['--namespace=jiny'], ['-n', 'jiny'], ['-njiny'], ['-n=jiny'], ['-in', 'jiny']) {
    foreach my $cmd (qw(deploy delete template)) {
        ($rc, $out, $err) = k8s({%CTX}, $cmd, 'static', @{$bad});
        is($rc, 2, "$cmd s prepinacem $bad->[0] (jiny namespace): kod 2");
        like($err, qr/prepinac '\Q$bad->[0]\E' neni povolen: namespace se nastavuje jen pres K8S_NAMESPACE/, "$cmd s prepinacem $bad->[0]: hlaska");
        is(scalar(cluster_calls()), 0, "$cmd s prepinacem $bad->[0]: helm ani kubectl se nevolaji");
    }
}
($rc, $out, $err) = k8s({%CTX, 'K8S_HELM_ARGS' => '--set a=b -n jiny'}, 'deploy', 'static');
is($rc, 2, 'prepinac -n v K8S_HELM_ARGS: kod 2');
is(scalar(cluster_calls()), 0, 'prepinac -n v K8S_HELM_ARGS: helm ani kubectl se nevolaji');
# kratke prepinace helmu s hodnotou (-f, -o, -a, -s, -l) projdou, i kdyz jejich slepena hodnota zacina
# na "n" (-fn.yml je soubor n.yml, ne -f a -n); za znakem "=" je vzdy hodnota
foreach my $good (['-f', '/x/values-navic.yml'], ['-f/x/values-navic.yml'], ['-fn.yml'], ['-on'], ['-an'], ['-sn'], ['-ln=x'], ['-i=nikdy'],
    ['--timeout=5m'], ['--set-string', 'a=-n'])
{
    ($rc, $out, $err) = k8s({%CTX}, 'deploy', 'static', @{$good});
    is($rc, 0, "deploy @{$good}: povoleno") or diag($err);
    my ($u) = grep { $_->[1] eq 'upgrade' } calls('helm');
    is_deeply([@{$u || []}[-scalar(@{$good}) .. -1]], $good, "deploy @{$good}: argumenty se predaji helmu beze zmeny");
}

# logs: server (-s) a namespace (-n) kubectl, i slepene s hodnotou nebo za prepinaci bez hodnoty; prihlaseni
foreach my $bad (['-s', 'https://x'], ['-shttps://x'], ['-s=https://x'], ['-fs', 'https://x'], ['-pfs=https://x'],
    ['-n', 'kube-system'], ['-nkube-system'], ['-fn', 'kube-system'], ['--namespace=kube-system'],
    ['--user=x'], ['--username=x'], ['--token=x'], ['--password=x'], ['--cluster=jiny'], ['--server=https://x'], ['--context', 'jiny'],
    ['--as=system:admin'], ['--as', 'system:admin'], ['--as-group=system:masters'], ['--client-certificate=/x'], ['--client-key=/x'],
    ['--certificate-authority=/x'], ['--insecure-skip-tls-verify'], ['--insecure-skip-tls-verify=true'], ['--tls-server-name=x'])
{
    ($rc, $out, $err) = k8s({%CTX}, 'logs', 'static', @{$bad});
    is($rc, 2, "logs s prepinacem $bad->[0]: kod 2");
    like($err, qr/prepinac '\Q$bad->[0]\E' neni /, "logs s prepinacem $bad->[0]: hlaska jmenuje prepinac");
    is(scalar(cluster_calls()), 0, "logs s prepinacem $bad->[0]: kubectl se nevola");
}
# povolene kratke prepinace kubectl logs: bez hodnoty (-f, -p, i slepene) a s hodnotou (-c, -l, -v), jejiz
# slepeny text muze na "s" i "n" zacinat (-cs je kontejner "s", ne -c a -s); za znakem "=" je vzdy hodnota
foreach my $good (['-f'], ['-p'], ['-fp'], ['-c', 'nginx'], ['-cnginx'], ['-cs'], ['-cn'], ['-c=static'], ['-ls=x'], ['-ln=x'], ['-vs'], ['-vn'],
    ['-f=nikdy'], ['-p=snad'], ['--since=5s'], ['--tail=-1'], ['--timestamps'], ['--all-pods'], ['--insecure-skip-tls-verify-backend'])
{
    ($rc, $out, $err) = k8s({%CTX}, 'logs', 'static', @{$good});
    is($rc, 0, "logs @{$good}: povoleno") or diag($err);
    my ($l) = calls('kubectl');
    is_deeply([@{$l || []}[-scalar(@{$good}) .. -1]], $good, "logs @{$good}: argumenty se predaji kubectl beze zmeny");
}

# Promenne prostredi, kterymi helm (HELM_KUBE*, HELM_NAMESPACE) nebo kubectl (KUBERNETES_MASTER) vybiraji
# cluster, prihlaseni ci namespace mimo KUBE_CONTEXT a K8S_NAMESPACE - obdoba odmitanych prepinacu. Skript
# je zrusi, at prisly z prostredi, nebo z kubernetes/local.env; helm ani kubectl je nedostanou.
{
    my %evil = ('HELM_KUBEAPISERVER' => 'https://jiny.example:6443', 'HELM_KUBECONTEXT' => 'jiny', 'HELM_KUBETOKEN' => 't', 'HELM_KUBECAFILE' => '/x',
        'HELM_KUBEASUSER' => 'u', 'HELM_KUBEASGROUPS' => 'g', 'HELM_KUBEINSECURE_SKIP_TLS_VERIFY' => 'true', 'HELM_KUBETLS_SERVER_NAME' => 'x',
        'HELM_KUBENECO_NOVEHO' => 'x', 'HELM_NAMESPACE' => 'jiny-ns', 'KUBERNETES_MASTER' => 'https://jiny.example:6443');
    ($rc, $out, $err) = k8s({%CTX, %evil}, 'deploy', 'static');
    is($rc, 0, 'deploy s HELM_KUBE* v prostredi: kod 0') or diag($err);
    ok(scalar(grep { $_->[1] eq 'upgrade' } calls('helm')), 'deploy s HELM_KUBE* v prostredi: helm upgrade probehl');
    is($ENVLOG, '', 'HELM_KUBE*, HELM_NAMESPACE a KUBERNETES_MASTER z prostredi se helmu nepredaji');
    like($err, qr/promenne .*\bHELM_KUBEAPISERVER\b.* se nepouziji: cluster se vybira jen pres KUBE_CONTEXT/, 'HELM_KUBE* v prostredi: skript oznami, ze je nepouzije');
    like($err, qr/promenne .*\bHELM_KUBENECO_NOVEHO\b.* se nepouziji/, 'HELM_KUBE*: zrusi se kazda promenna s touto predponou, nejen dnes zname');
    ($rc, $out, $err) = k8s({%CTX, %evil, 'FAKE_TLS' => 'pwe-static-web-tls'}, 'status', 'static');
    ok(scalar(calls('helm')) && scalar(calls('kubectl')), 'status s HELM_KUBE* v prostredi: helm i kubectl se volaji');
    is($ENVLOG, '', 'status: HELM_KUBE* ani KUBERNETES_MASTER se helmu a kubectl nepredaji');
    ($rc, $out, $err) = k8s({%CFG, %evil}, 'template', 'static', '--validate');
    my ($t) = calls('helm');
    is($t && $t->[0], '/dev/null', 'template bez KUBE_CONTEXT s HELM_KUBEAPISERVER v prostredi: prazdny kubeconfig');
    is($ENVLOG, '', 'template bez KUBE_CONTEXT: HELM_KUBEAPISERVER a HELM_KUBETOKEN se helmu nepredaji (--validate se nikam nepripoji)');
    spit("$REPO/kubernetes/local.env", "HELM_KUBEAPISERVER=https://jiny.example:6443\nHELM_KUBETOKEN=t\nHELM_NAMESPACE=jiny-ns\n");
    ($rc, $out, $err) = k8s({%CTX}, 'deploy', 'static');
    is($rc, 0, 'deploy s HELM_KUBE* v local.env: kod 0') or diag($err);
    ok(scalar(grep { $_->[1] eq 'upgrade' } calls('helm')), 'deploy s HELM_KUBE* v local.env: helm upgrade probehl');
    is($ENVLOG, '', 'HELM_KUBEAPISERVER, HELM_KUBETOKEN a HELM_NAMESPACE z local.env se helmu nepredaji');
    unlink("$REPO/kubernetes/local.env");
    ($rc, $out, $err) = k8s({%CTX}, 'deploy', 'static');
    unlike($err, qr/se nepouziji/, 'bez techto promennych skript nic neoznamuje');

    # KUBECONFIG se naopak respektuje: urcuje jen soubor s kontexty (oddeleny kubeconfig jen s kontexty,
    # do kterych se smi nasazovat), kontext v nem vybira vzdy KUBE_CONTEXT
    ($rc, $out, $err) = k8s({%CTX, 'KUBECONFIG' => '/x/kubeconfig', 'FAKE_TLS' => 'pwe-static-web-tls'}, 'status', 'static');
    ok(scalar(calls('helm')) && scalar(calls('kubectl')) && !grep({ $_->[0] ne '/x/kubeconfig' } cluster_calls()),
        'KUBECONFIG z prostredi dostane helm i kubectl beze zmeny');
    ($rc, $out, $err) = k8s({%CTX, 'KUBECONFIG' => '/x/kubeconfig'}, 'deploy', 'static');
    ok(scalar(calls('helm')) && !grep({ $_->[0] ne '/x/kubeconfig' } calls('helm')), 'deploy: KUBECONFIG z prostredi dostane helm beze zmeny');
    ($rc, $out, $err) = k8s({%CFG, 'KUBECONFIG' => '/x/kubeconfig'}, 'template', 'static');
    ($t) = calls('helm');
    is($t && $t->[0], '/dev/null', 'template bez KUBE_CONTEXT: prazdny kubeconfig ma prednost pred KUBECONFIG z prostredi');
}

# ---------------------------------------------------------------------------------------------
# deploy
# ---------------------------------------------------------------------------------------------
($rc, $out, $err) = k8s({%CTX}, 'deploy', 'static');
is($rc, 0, 'deploy static: kod 0');
my ($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok($up, 'deploy: helm upgrade');
ok(has_pair($up, '--kube-context', 'ctx-test'), 'deploy: --kube-context ctx-test');
ok(has_pair($up, '--namespace', 'pwe'),         'deploy: vychozi namespace pwe');
ok(has_arg($up, '--install') && has_arg($up, '--wait'), 'deploy: --install --wait');
ok(has_pair($up, '-f', "$REPO/kubernetes/values-static.yml"), 'deploy: -f values-static.yml');
ok(has_pair($up, '--set-string', "generic.pweImageTag=v-test\@$DIGEST"), 'deploy: tag image s digestem');
ok(has_pair($up, '--set-string', 'generic.pweRegistry=reg.test/ns'),  'deploy: registr image');
ok(has_pair($up, '--set-string', 'generic.pweDomain=example.test'),   'deploy: domena');
ok(has_pair($up, '--set-string', 'generic.pweIssuer=issuer-test'),    'deploy: issuer');
like($err, qr{nasazeno: https://pwe-static\.example\.test/}, 'deploy: hlaska s adresou webu');
unlike($err, qr/K8S_PULL_REGISTRY/, 'deploy bez K8S_PULL_REGISTRY: zadne oznameni o zrcadle registru');
# pojistka pomocne funkce: kontroly "helm ani kubectl se nevolaji" stoji na tom, ze pocita i volani helm
is(scalar(cluster_calls()), scalar(calls('helm')) + scalar(calls('kubectl')), 'cluster_calls ve skalarnim kontextu: pocet volani helm i kubectl');
ok(scalar(cluster_calls()) >= 1, 'cluster_calls: deploy vola helm, pocet neni nula');

($rc, $out, $err) = k8s({%CTX, 'K8S_PULL_REGISTRY' => 'proxy.test/hub/ns/', 'K8S_NAMESPACE' => 'jiny-ns'}, 'deploy', 'static');
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok(has_pair($up, '--set-string', 'generic.pweRegistry=proxy.test/hub/ns'), 'deploy: K8S_PULL_REGISTRY bez koncoveho lomitka');
ok(has_pair($up, '--namespace', 'jiny-ns'), 'deploy: K8S_NAMESPACE');
# cluster taha odjinud, nez kde se zjistil digest: skript to pred nasazenim zretelne rekne (overit to neumi)
like($err, qr{image se overuje v registru reg\.test/ns \(tam se zjistuje digest\), cluster ho ale taha z proxy\.test/hub/ns/pwe-example-static \(K8S_PULL_REGISTRY\) - musi to byt zrcadlo \(proxy cache\) registru reg\.test/ns},
    'deploy s K8S_PULL_REGISTRY: oznameni, odkud je digest a odkud taha cluster');
($rc, $out, $err) = k8s({%CTX, 'K8S_PULL_REGISTRY' => 'reg.test/ns/'}, 'deploy', 'static');
unlike($err, qr/zrcadlo/, 'K8S_PULL_REGISTRY shodny s K8S_REGISTRY (az na koncove lomitko): bez oznameni');
($rc, $out, $err) = k8s({%CTX, 'K8S_PULL_REGISTRY' => 'proxy.test/hub/ns', 'K8S_IMAGE_TAG' => "v2\@$DIGEST", 'FAKE_DIGEST' => undef}, 'deploy', 'static');
like($err, qr{cluster ho ale taha z proxy\.test/hub/ns/pwe-example-static \(K8S_PULL_REGISTRY\)}, 'K8S_PULL_REGISTRY s tagem vcetne digestu: oznameni take');
($rc, $out, $err) = k8s({%CFG, 'K8S_PULL_REGISTRY' => 'proxy.test/hub/ns'}, 'template', 'static');
like($err, qr{cluster ho ale taha z proxy\.test/hub/ns/pwe-example-static \(K8S_PULL_REGISTRY\)}, 'template s K8S_PULL_REGISTRY: oznameni take');
unlike($out, qr/zrcadlo/, 'template s K8S_PULL_REGISTRY: oznameni jde na stderr, ne mezi manifesty');

($rc, $out, $err) = k8s({%CTX, 'FAKE_DIGEST' => undef}, 'deploy', 'static');
is($rc, 2, 'deploy bez image v registru: kod 2');
like($err, qr{digest image reg\.test/ns/pwe-example-static:v-test nelze zjistit.*K8S_ALLOW_TAG=1}s, 'deploy bez image: hlaska s odkazem na image a vyjimkou');
ok(!grep({ $_->[1] eq 'upgrade' } calls('helm')), 'deploy bez image: helm upgrade se nevola');
($rc, $out, $err) = k8s({%CTX, 'FAKE_DIGEST' => undef, 'K8S_ALLOW_TAG' => '1'}, 'deploy', 'static');
is($rc, 0, 'deploy bez image s K8S_ALLOW_TAG=1: kod 0');
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok(has_pair($up, '--set-string', 'generic.pweImageTag=v-test'), 'K8S_ALLOW_TAG=1: nasazeni jen podle tagu');
($rc, $out, $err) = k8s({%CTX, 'FAKE_DIGEST' => undef, 'K8S_IMAGE_TAG' => "v2\@$DIGEST"}, 'deploy', 'static');
is($rc, 0, 'deploy s tagem vcetne digestu: registr se neoveruje');
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok(has_pair($up, '--set-string', "generic.pweImageTag=v2\@$DIGEST"), 'deploy: tag s digestem beze zmeny');

# Digest je jen radek stdout dockeru presneho tvaru sha256:<64 hex> z uspesneho behu. Varovani dockeru na
# stderr se nesmi dostat do odkazu na image (viceradkova hodnota generic.pweImageTag = InvalidImageName
# az v clusteru) ani zpusobit, ze se existujici image vyhodnoti jako nenalezeny.
($rc, $out, $err) = k8s({%CTX, 'FAKE_DOCKER_WARN' => 'nejake varovani dockeru'}, 'deploy', 'static');
is($rc, 0, 'varovani dockeru na stderr pred digestem i za nim: digest se presto zjisti') or diag($err);
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok($up && has_pair($up, '--set-string', "generic.pweImageTag=v-test\@$DIGEST"), 'varovani dockeru na stderr se nedostane do odkazu na image');
ok($up && !grep({ /WARNING|varovani/ } @{$up}), 'varovani dockeru neni v zadnem argumentu helmu');
foreach my $t (['sha256:abc', 'kratky digest'], ['sha256:' . ('XY' x 32), '64 znaku, ktere nejsou sestnactkove'], ['sha256:' . ('AB' x 32), 'velka pismena'],
    ["$DIGEST-neco", 'text za digestem'], ['md5:' . ('ab' x 32), 'jiny algoritmus'])
{
    ($rc, $out, $err) = k8s({%CTX, 'FAKE_DIGEST' => $t->[0]}, 'deploy', 'static');
    is($rc, 2, "vystup dockeru, ktery neni sha256:<64 hex> ($t->[1]), se jako digest nepouzije: kod 2");
    like($err, qr/digest image .* nelze zjistit \(docker nevypsal digest tvaru sha256:<64 hex>/, "$t->[1]: hlaska rika, co docker vypsal spatne");
    ok(!grep({ $_->[1] eq 'upgrade' } calls('helm')), "$t->[1]: helm upgrade se nevola");
}
($rc, $out, $err) = k8s({%CTX, 'FAKE_DIGEST_RC' => 1}, 'deploy', 'static');
is($rc, 2, 'docker skonci chybou, i kdyz neco vypsal: digest se nepouzije (navratovy kod se respektuje)');
ok(!grep({ $_->[1] eq 'upgrade' } calls('helm')), 'docker skonci chybou: helm upgrade se nevola');
($rc, $out, $err) = k8s({%CTX, 'K8S_IMAGE_TAG' => 'v1@sha256:' . ('XY' x 32)}, 'deploy', 'static');
is($rc, 2, 'K8S_IMAGE_TAG s digestem, ktery neni sestnactkovy: kod 2');
like($err, qr/za \@ musi byt digest sha256:<64 sestnactkovych znaku/, 'K8S_IMAGE_TAG s neplatnym digestem: hlaska');
is(scalar(cluster_calls()), 0, 'K8S_IMAGE_TAG s neplatnym digestem: helm ani kubectl se nevolaji');

($rc, $out, $err) = k8s({%CTX, 'K8S_HELM_ARGS' => '--set-string generic.pweNginxImage=proxy/nginx --set x=*'}, 'deploy', 'static');
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok(has_pair($up, '--set-string', 'generic.pweNginxImage=proxy/nginx'), 'K8S_HELM_ARGS se predaji helmu');
ok(has_pair($up, '--set', 'x=*'), 'K8S_HELM_ARGS: hvezdicka se nerozvine na soubory');

# ---------------------------------------------------------------------------------------------
# vzorove nasazeni: hotovy image vzoroveho webu pwe-example-<profil> z registru image PWE, tag = verze enginu
# ---------------------------------------------------------------------------------------------
($rc, $out, $err) = k8s({%BCTX}, 'deploy', 'static');
is($rc, 0, 'vzorove nasazeni bez K8S_REGISTRY a K8S_IMAGE_TAG: kod 0') or diag($err);
is_deeply([digest_refs()], ["ghcr.io/kukam/pwe-example-static:$VERSION"], 'vzorove nasazeni: digest image vzoroveho webu z ghcr.io/kukam s tagem verze z PWE/VERSION');
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok($up && has_pair($up, '--set-string', 'generic.pweRegistry=ghcr.io/kukam'),          'vzorove nasazeni: vychozi registr ghcr.io/kukam');
ok($up && has_pair($up, '--set-string', "generic.pweImageTag=$VERSION\@$DIGEST"),      'vzorove nasazeni: tag verze enginu s digestem');
ok(!builds(), 'vzorove nasazeni: deploy nic nestavi');

($rc, $out, $err) = k8s({%BCTX}, 'deploy', 'generic', '--dry-run=server');
is($rc, 0, 'vzorove nasazeni generic: kod 0') or diag($err);
is_deeply([digest_refs()], ["ghcr.io/kukam/pwe-example-mariadb:$VERSION"], 'vzorove nasazeni generic: image vzoroveho webu pwe-example-mariadb');

($rc, $out, $err) = k8s({%BCTX, 'PWE_IMAGE_TAG' => 'latest', 'PWE_IMAGE_REGISTRY' => 'fork.test/x/'}, 'deploy', 'static');
is_deeply([digest_refs()], ['fork.test/x/pwe-example-static:latest'], 'vzorove nasazeni: registr a tag image PWE z PWE_IMAGE_REGISTRY a PWE_IMAGE_TAG');
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok($up && has_pair($up, '--set-string', 'generic.pweRegistry=fork.test/x') && has_pair($up, '--set-string', "generic.pweImageTag=latest\@$DIGEST"),
    'vzorove nasazeni: PWE_IMAGE_REGISTRY a PWE_IMAGE_TAG se predaji helmu');

($rc, $out, $err) = k8s({%BCTX, 'PWE_IMAGE_TAG' => 'latest', 'PWE_IMAGE_REGISTRY' => 'fork.test/x', 'K8S_REGISTRY' => 'reg.test/ns', 'K8S_IMAGE_TAG' => 'v-test'}, 'deploy', 'static');
is_deeply([digest_refs()], ['reg.test/ns/pwe-example-static:v-test'], 'vzorove nasazeni: K8S_REGISTRY a K8S_IMAGE_TAG maji prednost pred PWE_IMAGE_*');

($rc, $out, $err) = k8s({%BCTX, 'K8S_PULL_REGISTRY' => 'proxy.test/ghcr/kukam'}, 'deploy', 'static');
is_deeply([digest_refs()], ["ghcr.io/kukam/pwe-example-static:$VERSION"], 'vzorove nasazeni s K8S_PULL_REGISTRY: digest se zjistuje v registru image PWE');
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok($up && has_pair($up, '--set-string', 'generic.pweRegistry=proxy.test/ghcr/kukam'), 'vzorove nasazeni s K8S_PULL_REGISTRY: cluster taha z proxy');
like($err, qr{image se overuje v registru ghcr\.io/kukam \(tam se zjistuje digest\), cluster ho ale taha z proxy\.test/ghcr/kukam/pwe-example-static \(K8S_PULL_REGISTRY\) - musi to byt zrcadlo \(proxy cache\) registru ghcr\.io/kukam},
    'vzorove nasazeni s K8S_PULL_REGISTRY: skript rekne, odkud je digest, odkud cluster taha a ceho to ma byt zrcadlo');

($rc, $out, $err) = k8s({%BCTX, 'FAKE_DIGEST' => undef}, 'deploy', 'static');
is($rc, 2, 'vzorove nasazeni bez image v registru: kod 2');
like($err, qr{digest image ghcr\.io/kukam/pwe-example-static:\Q$VERSION\E nelze zjistit}, 'vzorove nasazeni bez image: hlaska jmenuje image vzoroveho webu');
like($err, qr/Vzorove nasazeni static bere hotovy image vzoroveho webu z registru ghcr\.io\/kukam \(PWE_IMAGE_REGISTRY\)/, 'vzorove nasazeni bez image: rada jmenuje registr image PWE');
like($err, qr/over, ze tam image s tagem \Q$VERSION\E je \(publikuje ho pipeline; make images ho stavi jen mistne\)/, 'vzorove nasazeni bez image: rada rika, kdo image do registru dava');
unlike($err, qr/make k8s-image/, 'vzorove nasazeni bez image: rada neposila na make k8s-image');
($rc, $out, $err) = k8s({%BCTX, 'FAKE_DIGEST' => undef, 'K8S_REGISTRY' => 'reg.test/ns'}, 'deploy', 'static');
like($err, qr/K8S_REGISTRY z prostredi nebo z kubernetes\/local\.env plati i pro vzorova nasazeni; registr image PWE: K8S_REGISTRY=ghcr\.io\/kukam/,
    'vzorove nasazeni bez image s vlastnim K8S_REGISTRY: rada upozorni na K8S_REGISTRY');
unlike($err, qr/K8S_PULL_REGISTRY/, 'vzorove nasazeni bez image, K8S_PULL_REGISTRY nenastaven: rada ho nezminuje');
# Rada "zvol jiny registr" musi zminit i K8S_PULL_REGISTRY: ten (typicky z local.env) plati dal, takze by
# samotny jiny K8S_REGISTRY vedl k digestu z jednoho registru a tahani z proxy cache jineho.
($rc, $out, $err) = k8s({%BCTX, 'FAKE_DIGEST' => undef, 'K8S_REGISTRY' => 'reg.test/ns', 'K8S_PULL_REGISTRY' => 'proxy.test/hub/ns'}, 'deploy', 'static');
is($rc, 2, 'vzorove nasazeni bez image s K8S_PULL_REGISTRY: kod 2');
like($err, qr{registr image PWE: K8S_REGISTRY=ghcr\.io/kukam\).*S jinym K8S_REGISTRY zmen i K8S_PULL_REGISTRY \(ted proxy\.test/hub/ns, plati dal\)}s,
    'vzorove nasazeni bez image s K8S_PULL_REGISTRY: rada zmenit registr upozorni i na K8S_PULL_REGISTRY');
($rc, $out, $err) = k8s({%BCTX, 'FAKE_DIGEST' => undef, 'K8S_PULL_REGISTRY' => 'proxy.test/ghcr/kukam'}, 'deploy', 'static');
like($err, qr{S jinym K8S_REGISTRY zmen i K8S_PULL_REGISTRY \(ted proxy\.test/ghcr/kukam, plati dal\)},
    'vzorove nasazeni bez image, vychozi registr a K8S_PULL_REGISTRY: rada ho zminuje take');

($rc, $out, $err) = k8s({%BCTX, 'PWE_IMAGE_TAG' => 'feature/x'}, 'template', 'static');
is($rc, 2, 'vzorove nasazeni: neplatny PWE_IMAGE_TAG se odmitne');
is(scalar(cluster_calls()), 0, 'neplatny PWE_IMAGE_TAG: helm ani kubectl se nevolaji');
($rc, $out, $err) = k8s({%BCTX, 'PWE_IMAGE_TAG' => 'feature/x', 'K8S_IMAGE_TAG' => 'feature/y'}, 'logs', 'static');
is($rc, 0, 'logs tag image nepotrebuje (neplatny PWE_IMAGE_TAG ani K8S_IMAGE_TAG nevadi)') or diag($err);

# PWE/VERSION bez verze: vzorove nasazeni vychozi tag neurci; vyslovny tag a nasazeni vlastniho webu na ni nezavisi
spit("$REPO/PWE/VERSION", "neni-verze\n");
($rc, $out, $err) = k8s({%BCTX}, 'deploy', 'static');
is($rc, 2, 'vzorove nasazeni s PWE/VERSION bez verze: kod 2');
like($err, qr/VERSION/, 'PWE/VERSION bez verze: hlaska jmenuje soubor VERSION');
ok(!grep({ $_->[1] eq 'upgrade' } calls('helm')), 'PWE/VERSION bez verze: helm upgrade se nevola');
($rc, $out, $err) = k8s({%BCTX, 'PWE_IMAGE_TAG' => 'latest'}, 'deploy', 'static');
is($rc, 0, 'PWE/VERSION bez verze: s PWE_IMAGE_TAG vzorove nasazeni projde') or diag($err);
($rc, $out, $err) = k8s({%BCTX, 'K8S_REGISTRY' => 'reg.test/ns'}, 'deploy', 'mujweb');
is($rc, 0, 'PWE/VERSION bez verze: nasazeni vlastniho webu na verzi enginu nezavisi') or diag($err);
spit("$REPO/PWE/VERSION", "$VERSION\n");

# prikaz image u vzoroveho nasazeni: nic nestavi, kod 0 (i bez K8S_REGISTRY a bez Dockerfile vzoroveho webu)
foreach my $t (['static', 'pwe-example-static', 'example.web'], ['generic', 'pwe-example-mariadb', 'example-db.web']) {
    my ($name, $image, $web) = @{$t};
    ($rc, $out, $err) = k8s({%BASE}, 'image', $name);
    is($rc, 0, "image $name (vzorove nasazeni): kod 0") or diag($err);
    like($err, qr{nasazeni \Q$name\E je vzorove: pouziva hotovy image vzoroveho webu ghcr\.io/kukam/\Q$image:$VERSION\E \(knihovny, engine i web \Q$web\E\) - nic se nestavi},
        "image $name: hlaska, ze se nic nestavi");
    like($err, qr/make k8s-deploy K8S=\Q$name\E/, "image $name: hlaska odkazuje na make k8s-deploy");
    like($err, qr/image vzorovych webu stavi make images a do registru je publikuje pipeline; make k8s-image stavi jen image vlastniho webu/, "image $name: hlaska rika, kdo image vzorovych webu stavi");
    is(scalar(calls('docker')), 0, "image $name: docker se nevola");
    is(scalar(cluster_calls()), 0, "image $name: helm ani kubectl se nevolaji");
}
($rc, $out, $err) = k8s({%CFG, 'FAKE_LOCAL_PLATFORMS' => 'linux/arm64'}, 'image', 'static', '--no-cache');
is($rc, 0, 'image static s K8S_REGISTRY a mistnim image jine platformy: porad kod 0, nic se nekontroluje ani nestavi');
is(scalar(calls('docker')), 0, 'image static s K8S_REGISTRY: docker se nevola');

# Vzorove nasazeni se pozna jen podle nazvu image: vsechny ctyri image vzorovych webu, kazdy se svym webem a
# profilem. Nic se pro ne nestavi - ani kdyz vzorovy web Dockerfile ma a mistni image je pro jinou platformu.
spit("$REPO/webapps/example.web/Dockerfile", web_dockerfile('pwe-base', 'example.web'));
spit("$REPO/webapps/example-db.web/Dockerfile", web_dockerfile('pwe-${PWE_PROFILE}', 'example-db.web'));
foreach my $t (@SAMPLES) {
    my ($image, $profile, $web) = @{$t};
    spit("$REPO/kubernetes/values-vz.yml", values_variant('static', $web, $profile, $image));
    ($rc, $out, $err) = k8s({%BCTX}, 'deploy', 'vz');
    is($rc, 0, "$image (web $web, profil $profile) je vzorove nasazeni: deploy kod 0") or diag($err);
    is_deeply([digest_refs()], ["ghcr.io/kukam/$image:$VERSION"], "$image: hotovy image z registru image PWE s tagem verze enginu");
    ($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
    ok($up && has_pair($up, '--set-string', 'generic.pweRegistry=ghcr.io/kukam') && has_pair($up, '--set-string', "generic.pweImageTag=$VERSION\@$DIGEST"),
        "$image: registr image PWE a tag verze s digestem pro helm");
    ok(!builds(), "$image: deploy nic nestavi");
    ($rc, $out, $err) = k8s({%BASE, 'FAKE_LOCAL_PLATFORMS' => 'linux/arm64'}, 'image', 'vz', '--no-cache');
    is($rc, 0, "image u vzoroveho nasazeni $image: kod 0 (i bez K8S_REGISTRY)") or diag($err);
    like($err, qr{nasazeni vz je vzorove: pouziva hotovy image vzoroveho webu ghcr\.io/kukam/\Q$image:$VERSION\E \(knihovny, engine i web \Q$web\E\) - nic se nestavi},
        "image $image: hlaska, ze se nic nestavi");
    is(scalar(calls('docker')), 0, "image $image: docker se nevola (nic se nestavi, nekontroluje ani nenahrava)");
    is(scalar(cluster_calls()), 0, "image $image: helm ani kubectl se nevolaji");
    ($rc, $out, $err) = k8s({%BASE, 'PWE_IMAGE_REGISTRY' => 'fork.test/x/', 'PWE_IMAGE_TAG' => 'latest'}, 'template', 'vz');
    ($tpl) = calls('helm');
    ok($tpl && has_pair($tpl, '--set-string', 'generic.pweRegistry=fork.test/x') && has_pair($tpl, '--set-string', 'generic.pweImageTag=latest'),
        "$image: template bere registr a tag z PWE_IMAGE_REGISTRY a PWE_IMAGE_TAG");
    is_deeply([digest_refs()], ["fork.test/x/$image:latest"], "$image: template zjistuje digest image vzoroveho webu");
}

# Image vzoroveho webu ma web i profil zapecene: values, ktere tvrdi neco jineho, jsou chyba (kopie values
# pro vlastni web, ve ktere zustal nazev image; postup "jina databaze", pri kterem se zmenil jen pweProfile).
foreach my $t (@SAMPLES) {
    my ($image, $profile, $web) = @{$t};
    foreach my $bad_web ('mujweb.web', ($web eq 'example.web') ? 'example-db.web' : 'example.web') {
        spit("$REPO/kubernetes/values-spatny.yml", values_variant('static', $bad_web, $profile, $image));
        foreach my $cmd (qw(image deploy template)) {
            ($rc, $out, $err) = k8s({%CTX}, $cmd, 'spatny');
            is($rc, 2, "pweImage $image s webem $bad_web: $cmd konci kodem 2");
            like($err, qr/generic\.pweImage '\Q$image\E' je image vzoroveho webu \Q$web\E, ale generic\.pweWeb je '\Q$bad_web\E'\. Pro vlastni web nastav generic\.pweImage na nazev image webu/,
                "pweImage $image s webem $bad_web ($cmd): hlaska radi zmenit generic.pweImage");
            is(scalar(cluster_calls()) + scalar(calls('docker')), 0, "pweImage $image s webem $bad_web ($cmd): nic se nevola");
        }
    }
    foreach my $bad_profile (grep { $_ ne $profile } qw(static mariadb mysql postgres)) {
        spit("$REPO/kubernetes/values-spatny.yml", values_variant('static', $web, $bad_profile, $image));
        foreach my $cmd (qw(image deploy)) {
            ($rc, $out, $err) = k8s({%CTX}, $cmd, 'spatny');
            is($rc, 2, "pweImage $image s profilem $bad_profile: $cmd konci kodem 2");
            like($err, qr/generic\.pweImage '\Q$image\E' je image vzoroveho webu s profilem \Q$profile\E, ale generic\.pweProfile je '\Q$bad_profile\E'/,
                "pweImage $image s profilem $bad_profile ($cmd): hlaska jmenuje profil image i profil z values");
            is(scalar(cluster_calls()) + scalar(calls('docker')), 0, "pweImage $image s profilem $bad_profile ($cmd): nic se nevola");
        }
    }
}

# Vyhrazene nazvy: zavislostni image (jen knihovny - nasadit je nejde), vsechny pwe-example-* a zrusene image
# pwe a pwe-static. Bez kontroly by se braly jako image vlastniho webu a prikaz image by web nahral pod
# jmenem image PWE (v registru s image PWE nebo se starymi tagy zrusenych image by prepsal tag). Plati i pro
# values, ktere byly v predchozim usporadani vzorovym nasazenim (pwe-static + example.web, pwe-mariadb +
# example-db.web), a pro nazev s cestou (ns/pwe-base).
foreach my $t (
    ['pwe-base',     'static',   'mujweb.web',     'zavislostni image: jen knihovny, bez enginu a webu - nasadit ho nejde'],
    ['pwe-base',     'mariadb',  'example-db.web', 'zavislostni image'],
    ['pwe-mariadb',  'mariadb',  'example-db.web', 'zavislostni image'],
    ['pwe-mariadb',  'postgres', 'mujweb.web',     'zavislostni image'],
    ['pwe-mysql',    'mysql',    'example-db.web', 'zavislostni image'],
    ['pwe-postgres', 'postgres', 'mujweb.web',     'zavislostni image'],
    ['pwe-debugger', 'static',   'mujweb.web',     'zavislostni image'],
    ['pwe',          'static',   'mujweb.web',     'zruseny image, uz se nestavi ani nepublikuje'],
    ['pwe-static',   'static',   'example.web',    'zruseny image'],
    ['pwe-static',   'postgres', 'mujweb.web',     'zruseny image'],
    ['pwe-example-oracle',   'static',  'mujweb.web',     'nazvy pwe-example-* patri image vzorovych webu'],
    ['pwe-example-generic',  'mariadb', 'example-db.web', 'nazvy pwe-example-* patri image vzorovych webu'],
    ['pwe-example-',         'static',  'example.web',    'nazvy pwe-example-* patri image vzorovych webu'],
    ['pwe-example-static-2', 'static',  'example.web',    'nazvy pwe-example-* patri image vzorovych webu'],
    ['ns/pwe-example-static', 'static', 'example.web',    've values se pisou bez cesty'],
    ['ns/pwe-base',          'static',  'mujweb.web',     'zavislostni image'],
    ['a/b/pwe-static',       'static',  'mujweb.web',     'zruseny image'],
    ['kukam/pwe',            'static',  'mujweb.web',     'zruseny image'],
    ['kukam/pwe-debugger',   'mariadb', 'mujweb.web',     'zavislostni image'],
) {
    my ($image, $profile, $web, $why) = @{$t};
    spit("$REPO/kubernetes/values-spatny.yml", values_variant('static', $web, $profile, $image));
    ($rc, $out, $err) = k8s({%CFG, 'FAKE_DIGEST' => $DIGEST}, 'image', 'spatny');
    is($rc, 2, "pweImage $image (profil $profile, web $web): prikaz image konci kodem 2 (vyhrazeny nazev)");
    like($err, qr/generic\.pweImage '\Q$image\E' je vyhrazeny nazev image PWE \([^)]*\Q$why\E/, "pweImage $image (profil $profile): hlaska rika, proc je nazev vyhrazeny");
    like($err, qr/Vzorove nasazeni ma generic\.pweImage pwe-example-static, pwe-example-mariadb, pwe-example-mysql, pwe-example-postgres/, "pweImage $image: hlaska jmenuje image vzorovych webu");
    is(scalar(calls('docker')), 0, "pweImage $image (profil $profile): nic se nestavi ani nenahrava");
    ($rc, $out, $err) = k8s({%CTX}, 'deploy', 'spatny');
    is($rc, 2, "pweImage $image (profil $profile): deploy konci kodem 2");
    is(scalar(cluster_calls()) + scalar(calls('docker')), 0, "pweImage $image (profil $profile): deploy nic nevola");
}
# nazvy, ktere vyhrazene nejsou (vyhrazenemu se jen podobaji): image vlastniho webu se tak jmenovat smi
foreach my $image ('pwe-mujweb', 'pwe-basex', 'xpwe-base', 'pwe-example', 'mujweb/pwe-web', 'pwe-static.cz', 'pwe_static', 'pwe-base/mujweb') {
    spit("$REPO/kubernetes/values-spatny.yml", values_variant('static', 'mujweb.web', undef, $image));
    ($rc, $out, $err) = k8s({%CFG, 'FAKE_DIGEST' => $DIGEST}, 'image', 'spatny');
    is($rc, 0, "pweImage $image neni vyhrazeny nazev: image vlastniho webu se stavi") or diag($err);
    my ($b) = builds();
    ok($b && has_pair($b, '-t', "reg.test/ns/$image:v-test"), "pweImage $image: image webu se nahraje pod timto nazvem");
}
# generic.pweImage je nazev image bez registru a tagu: jine znaky by navic obesly kontrolu vyhrazenych nazvu
# (pwe-base:latest, Pwe-Base)
foreach my $image ('pwe-base:latest', 'mujweb:1.0', 'Pwe-Base', 'mujWeb', '/mujweb', 'mujweb/', 'muj//web', 'mujweb@sha256:abc', 'muj+web') {
    spit("$REPO/kubernetes/values-spatny.yml", values_variant('static', 'mujweb.web', undef, $image));
    foreach my $cmd (qw(image deploy)) {
        ($rc, $out, $err) = k8s({%CTX}, $cmd, 'spatny');
        is($rc, 2, "pweImage $image neni nazev image: $cmd konci kodem 2");
        like($err, qr/generic\.pweImage '\Q$image\E' neni nazev image: smi obsahovat jen mala pismena, cislice a znaky \. _ - \//, "pweImage $image ($cmd): hlaska");
        is(scalar(cluster_calls()) + scalar(calls('docker')), 0, "pweImage $image ($cmd): nic se nevola");
    }
}
# generic.pweProfile: static (web bez databaze) nebo ovladac databaze - u vzoroveho nasazeni i u vlastniho webu
foreach my $t (['mujweb-image', 'oracle', 'mujweb.web'], ['mujweb-image', 'Static', 'mujweb.web'], ['mujweb-image', 'base', 'mujweb.web'],
    ['pwe-example-static', 'none', 'example.web'], ['pwe-example-mariadb', 'mariadb11', 'example-db.web'])
{
    my ($image, $profile, $web) = @{$t};
    spit("$REPO/kubernetes/values-spatny.yml", values_variant('static', $web, $profile, $image));
    foreach my $cmd (qw(image deploy template)) {
        ($rc, $out, $err) = k8s({%CTX}, $cmd, 'spatny');
        is($rc, 2, "pweProfile $profile (pweImage $image): $cmd konci kodem 2");
        like($err, qr/generic\.pweProfile '\Q$profile\E' neni profil PWE \(static, mariadb, mysql, postgres\)/, "pweProfile $profile ($cmd): hlaska vyjmenuje profily");
        is(scalar(cluster_calls()) + scalar(calls('docker')), 0, "pweProfile $profile ($cmd): nic se nevola");
    }
}
# Kazdy image PWE, ktery zna PWE/tools/lib/images.sh (pwe_image_names), je pro k8s.sh bud image vzoroveho
# webu, nebo vyhrazeny nazev: novy image PWE se nesmi dat pouzit jako nazev image vlastniho webu.
SKIP: {
    my $names = qx{"$BASH" "$REPO/PWE/tools/lib/images.sh" pwe_image_names all 2>/dev/null};
    my @names = grep { length } split(/\n/, defined($names) ? $names : '');
    skip('PWE/tools/lib/images.sh nema funkci pwe_image_names', 2) unless ($? == 0 and scalar(@names));
    my (@as_own, @samples);
    foreach my $image (@names) {
        spit("$REPO/kubernetes/values-spatny.yml", values_variant('static', 'mujweb.web', undef, $image));
        ($rc, $out, $err) = k8s({%CFG, 'FAKE_DIGEST' => $DIGEST}, 'image', 'spatny');
        push(@as_own, $image) if ($rc != 2 or scalar(calls('docker')));
        push(@samples, $image) if ($err =~ /je image vzoroveho webu/);
    }
    is_deeply(\@as_own, [], 'zadny image PWE z images.sh (pwe_image_names) nejde pouzit jako nazev image vlastniho webu');
    is_deeply([sort @samples], [sort map { $_->[0] } @SAMPLES], 'image vzorovych webu podle images.sh jsou prave ty, ktere k8s.sh nasazuje jako vzorova nasazeni');
}
unlink("$REPO/webapps/example.web/Dockerfile", "$REPO/webapps/example-db.web/Dockerfile", "$REPO/kubernetes/values-spatny.yml", "$REPO/kubernetes/values-vz.yml");

# ---------------------------------------------------------------------------------------------
# vlastni web: image stavi prikaz image, registr K8S_REGISTRY, vychozi tag latest
# ---------------------------------------------------------------------------------------------
($rc, $out, $err) = k8s({%BCTX}, 'deploy', 'mujweb');
is($rc, 2, 'vlastni web bez K8S_REGISTRY: deploy konci kodem 2');
like($err, qr/digest image <K8S_REGISTRY>\/mujweb-image:latest nelze zjistit \(neni nastaven K8S_REGISTRY\)/, 'vlastni web bez K8S_REGISTRY: hlaska (zadny vychozi registr)');
like($err, qr/make k8s-image K8S=mujweb.*K8S_ALLOW_TAG=1/s, 'vlastni web bez image: rada sestavit image (make k8s-image)');
is(scalar(digest_refs()), 0, 'vlastni web bez K8S_REGISTRY: registr image PWE se nezkousi');
ok(!grep({ $_->[1] eq 'upgrade' } calls('helm')), 'vlastni web bez K8S_REGISTRY: helm upgrade se nevola');

($rc, $out, $err) = k8s({%BCTX, 'K8S_REGISTRY' => 'reg.test/ns', 'PWE_IMAGE_TAG' => 'engine-tag', 'PWE_IMAGE_REGISTRY' => 'fork.test/x'}, 'deploy', 'mujweb');
is($rc, 0, 'vlastni web: deploy kod 0') or diag($err);
is_deeply([digest_refs()], ['reg.test/ns/mujweb-image:latest'], 'vlastni web: vychozi tag latest, nezavisle na PWE_IMAGE_TAG a PWE_IMAGE_REGISTRY');
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok($up && has_pair($up, '--set-string', 'generic.pweRegistry=reg.test/ns') && has_pair($up, '--set-string', "generic.pweImageTag=latest\@$DIGEST"),
    'vlastni web: registr a tag s digestem pro helm');
ok($up && has_pair($up, '-f', "$REPO/kubernetes/values-mujweb.yml"), 'vlastni web: -f values-mujweb.yml');

($rc, $out, $err) = k8s({%BCTX, 'K8S_REGISTRY' => 'reg.test/ns', 'K8S_IMAGE_TAG' => '1.4.0'}, 'deploy', 'mujweb');
is_deeply([digest_refs()], ['reg.test/ns/mujweb-image:1.4.0'], 'vlastni web: K8S_IMAGE_TAG');

# ---------------------------------------------------------------------------------------------
# hesla (generic)
# ---------------------------------------------------------------------------------------------
unlink($SECRETS);
($rc, $out, $err) = k8s({%CTX}, 'deploy', 'generic', '--dry-run=server');
is($rc, 0, 'deploy --dry-run: kod 0');
ok(!-e $SECRETS, 'deploy --dry-run: hesla se nezakladaji');
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok(has_pair($up, '-f', "$REPO/kubernetes/secrets-generic.example.yml"), 'deploy --dry-run: pouzije se vzor hesel');
like($err, qr/zkouska nasucho \(--dry-run\): v clusteru se nic nezmenilo/, 'deploy --dry-run: hlaska o zkousce nasucho');
ok(!grep({ $_->[1] eq 'status' } calls('helm')), 'deploy --dry-run: stav releasu se nezjistuje');

# Zkouska nasucho se pozna z argumentu helmu v poradi, v jakem je dostane (K8S_HELM_ARGS, pak prikazova
# radka; plati posledni vyskyt). Zkouska nasucho nesmi zalozit skutecna hesla a skutecne nasazeni
# (--dry-run=none, --dry-run=false) nesmi pouzit vzor hesel s CHANGE_ME.
foreach my $t (
    [{'K8S_HELM_ARGS' => '--dry-run=server'}, [],                   1, '--dry-run=server v K8S_HELM_ARGS'],
    [{'K8S_HELM_ARGS' => '--dry-run'},        [],                   1, '--dry-run v K8S_HELM_ARGS'],
    [{},                                      ['--dry-run'],        1, '--dry-run'],
    [{},                                      ['--dry-run=client'], 1, '--dry-run=client'],
    [{},                                      ['--dry-run=true'],   1, '--dry-run=true'],
    [{'K8S_HELM_ARGS' => '--dry-run=none'},   ['--dry-run=server'], 1, '--dry-run=none v K8S_HELM_ARGS a --dry-run=server v argumentech (plati posledni)'],
    [{},                                      ['--dry-run=false'],  0, '--dry-run=false'],
    [{},                                      ['--dry-run=none'],   0, '--dry-run=none'],
    [{'K8S_HELM_ARGS' => '--dry-run=none'},   [],                   0, '--dry-run=none v K8S_HELM_ARGS'],
    [{'K8S_HELM_ARGS' => '--dry-run=server'}, ['--dry-run=none'],   0, '--dry-run=server v K8S_HELM_ARGS a --dry-run=none v argumentech (plati posledni)'],
    [{},                                      ['--description', '--dry-run-neni-prepinac'], 0, 'argument, ktery prepinacem --dry-run jen zacina'],
) {
    my ($env, $args, $dry, $name) = @{$t};
    ($rc, $out, $err) = k8s({%CTX, %{$env}}, 'deploy', 'generic', @{$args});
    is($rc, 0, "$name: kod 0") or diag($err);
    ($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
    if ($dry) {
        ok(!-e $SECRETS, "$name = zkouska nasucho: hesla se nezakladaji");
        ok($up && has_pair($up, '-f', "$REPO/kubernetes/secrets-generic.example.yml"), "$name: pouzije se vzor hesel");
        like($err, qr/zkouska nasucho \(--dry-run\)/, "$name: hlaska o zkousce nasucho");
        unlike($err, qr/nasazeno: /, "$name: nehlasi 'nasazeno'");
    }
    else {
        ok(-f $SECRETS, "$name = skutecne nasazeni: hesla se zalozi");
        ok($up && has_pair($up, '-f', $SECRETS) && !has_pair($up, '-f', "$REPO/kubernetes/secrets-generic.example.yml"), "$name: vzor hesel s CHANGE_ME se do clusteru neposila");
        like($err, qr/nasazeno: /, "$name: hlasi 'nasazeno'");
        unlike($err, qr/zkouska nasucho/, "$name: nehlasi zkousku nasucho");
    }
    unlink($SECRETS);
}
($rc, $out, $err) = k8s({%CTX}, 'deploy', 'generic', '--dry-run=neco');
is($rc, 2, 'neznama hodnota --dry-run: kod 2 (podle ni se rozhoduje o heslech)');
like($err, qr/prepinac '--dry-run=neco': neznama hodnota --dry-run/, 'neznama hodnota --dry-run: hlaska');
ok(!-e $SECRETS, 'neznama hodnota --dry-run: hesla se nezakladaji');
is(scalar(cluster_calls()), 0, 'neznama hodnota --dry-run: helm ani kubectl se nevolaji');

($rc, $out, $err) = k8s({%CTX, 'FAKE_HELM_STATUS_RC' => 0}, 'deploy', 'generic');
is($rc, 2, 'release existuje a soubor s hesly chybi: kod 2');
{
    my @st = grep { $_->[1] eq 'status' } calls('helm');
    ok(scalar(@st) && !grep({ !has_pair($_, '--kube-context', 'ctx-test') } @st), 'ochrana hesel: helm status s --kube-context ctx-test');
    ok(scalar(@st) && !grep({ !has_pair($_, '--namespace', 'pwe') } @st), 'ochrana hesel: helm status s --namespace');
}
like($err, qr/get values pwe-generic/, 'chybejici hesla: rada, jak soubor obnovit');
ok(!-e $SECRETS, 'chybejici hesla u existujiciho releasu: nova se nevygeneruji');
ok(!grep({ $_->[1] eq 'upgrade' } calls('helm')), 'chybejici hesla u existujiciho releasu: helm upgrade se nevola');
($rc, $out, $err) = k8s({%CTX, 'FAKE_PVC' => 'data-pwe-generic-mariadb-0'}, 'deploy', 'generic');
is($rc, 2, 'svazek databaze existuje a soubor s hesly chybi: kod 2');
like($err, qr/secrets-generic\.yml chybi, ale release pwe-generic nebo jeho svazek v clusteru uz existuje/, 'svazek databaze existuje: hlaska');
ok(!-e $SECRETS, 'svazek databaze existuje: nova hesla se nevygeneruji');
my ($pvcq) = grep { grep({ $_ eq 'persistentvolumeclaims' } @{$_}) } calls('kubectl');
ok($pvcq && has_pair($pvcq, '-l', 'app.kubernetes.io/instance=pwe-generic') && has_pair($pvcq, '--context', 'ctx-test'),
    'svazek se hleda podle stitku releasu a s --context');
($rc, $out, $err) = k8s({%CTX, 'FAKE_PVC' => 'data-pwe-generic-mariadb-0', 'FAKE_KUBECTL_WARN' => 'Warning: neco'}, 'deploy', 'generic');
is($rc, 2, 'svazek databaze existuje a kubectl k tomu vypise varovani: kod 2');

# Stav clusteru nejde zjistit (nedostupny cluster, preklep v KUBE_CONTEXT, vyprsene prihlaseni, selhani nebo
# chybejici kubectl): "nevim" neni "release neexistuje". Hesla se nezalozi, nic se nenasadi a po behu
# nezustane soubor s hesly - jinak by dalsi (uz uspesny) deploy prepsal Secret existujiciho releasu hesly,
# ktera nesouhlasi s databazi. FAKE_HELM_UPGRADE_RC: kdyby se helm upgrade presto zavolal, skoncil by chybou
# jako pri skutecnem vypadku (kod 1) - soubor s hesly by ale uz existoval.
foreach my $t (
    ['nedostupny cluster', {'FAKE_HELM_STATUS_ERR' => 'Error: Kubernetes cluster unreachable: dial tcp: i/o timeout', 'FAKE_KUBECTL_RC' => 1},
        qr/stav releasu pwe-generic v clusteru nelze zjistit \(Error: Kubernetes cluster unreachable: dial tcp: i\/o timeout\)/],
    ['preklep v KUBE_CONTEXT', {'FAKE_HELM_STATUS_ERR' => 'Error: Kubernetes cluster unreachable: context "ctx-test" does not exist', 'FAKE_KUBECTL_RC' => 1},
        qr/stav releasu pwe-generic v clusteru nelze zjistit \(.*context "ctx-test" does not exist\)/],
    ['vyprsene prihlaseni', {'FAKE_HELM_STATUS_ERR' => "WARNING: neco\nError: Kubernetes cluster unreachable: the server has asked for the client to provide credentials"},
        qr/stav releasu pwe-generic v clusteru nelze zjistit \(Error: Kubernetes cluster unreachable: the server has asked for the client to provide credentials\)/],
    ['helm status bez hlasky', {'FAKE_HELM_STATUS_ERR' => '', 'FAKE_HELM_STATUS_RC' => 3},
        qr/stav releasu pwe-generic v clusteru nelze zjistit \(helm status skoncil kodem 3 bez hlasky\)/],
    ['helm status selze, i kdyz svazek neni', {'FAKE_HELM_STATUS_ERR' => 'Error: query: failed to query with labels: secrets is forbidden'},
        qr/stav releasu pwe-generic v clusteru nelze zjistit \(Error: query: failed to query with labels: secrets is forbidden\)/],
    ['release neni, kubectl selze', {'FAKE_KUBECTL_RC' => 1},
        qr/svazky releasu pwe-generic v clusteru nelze zjistit \(Unable to connect to the server: dial tcp: i\/o timeout\).*kubectl --context ctx-test -n pwe get persistentvolumeclaims -l app\.kubernetes\.io\/instance=pwe-generic/],
    ['release neni, kubectl neni nainstalovany', {'KUBECTL' => 'kubectl-neni-nainstalovany'},
        qr/svazky releasu pwe-generic v clusteru nelze zjistit \(program kubectl-neni-nainstalovany neni nainstalovany\)/],
) {
    my ($name, $env, $re) = @{$t};
    ($rc, $out, $err) = k8s({%CTX, 'FAKE_HELM_UPGRADE_RC' => 1, %{$env}}, 'deploy', 'generic');
    is($rc, 2, "$name a soubor s hesly chybi: kod 2");
    like($err, $re, "$name: hlaska rika, co nejde zjistit a proc");
    like($err, qr/nova hesla nezakladam.*K8S_NEW_SECRETS=1/s, "$name: hesla se nezakladaji, rada s vyslovnou vyjimkou");
    unlike($err, qr/zalozen kubernetes\/secrets-generic\.yml/, "$name: skript neohlasi zalozeni hesel");
    ok(!-e $SECRETS, "$name: po behu nezustane soubor s hesly");
    ok(!grep({ $_->[1] eq 'upgrade' } calls('helm')), "$name: helm upgrade se nevola");
    unlink($SECRETS);
}
# release prokazatelne neexistuje = helm status ohlasi "release: not found" A dotaz na svazky uspesne nic
# nenajde; varovani helmu ani kubectl na stderr na tom nic nemeni
($rc, $out, $err) = k8s({%CTX, 'FAKE_HELM_STATUS_ERR' => "WARNING: Kubernetes configuration file is group-readable.\nError: release: not found",
    'FAKE_KUBECTL_WARN' => 'No resources found in pwe namespace.'}, 'deploy', 'generic');
is($rc, 0, 'varovani helmu + release: not found, kubectl nic nenajde (jen hlaska na stderr): novy release, kod 0') or diag($err);
ok(-f $SECRETS, 'prokazatelne novy release: hesla zalozena');
ok(scalar(grep { $_->[1] eq 'status' } calls('helm')) && scalar(grep { has_arg($_, 'persistentvolumeclaims') } calls('kubectl')),
    'prokazatelne novy release: zjistoval se release i svazky');
unlink($SECRETS);
# vyslovna vyjimka K8S_NEW_SECRETS=1 stav clusteru nezjistuje
($rc, $out, $err) = k8s({%CTX, 'FAKE_HELM_STATUS_ERR' => 'Error: Kubernetes cluster unreachable', 'FAKE_KUBECTL_RC' => 1, 'K8S_NEW_SECRETS' => 1}, 'deploy', 'generic');
is($rc, 0, 'K8S_NEW_SECRETS=1 pri nezjistitelnem stavu: kod 0') or diag($err);
ok(-f $SECRETS, 'K8S_NEW_SECRETS=1 pri nezjistitelnem stavu: hesla zalozena');
ok(!grep({ $_->[1] eq 'status' } calls('helm')) && !scalar(calls('kubectl')), 'K8S_NEW_SECRETS=1: stav releasu ani svazku se nezjistuje');
unlink($SECRETS);

($rc, $out, $err) = k8s({%CTX}, 'deploy', 'generic');
is($rc, 0, 'novy release: kod 0');
ok(-f $SECRETS, 'novy release: secrets-generic.yml zalozen');
is((stat($SECRETS))[2] & 07777, 0600, 'secrets-generic.yml: prava 0600');
my $sec = slurp($SECRETS);
unlike($sec, qr/CHANGE_ME/, 'secrets-generic.yml: zadne CHANGE_ME');
my @pw = $sec =~ /PASSWORD: "([0-9a-f]{32})"/g;
is(scalar(@pw), 2, 'secrets-generic.yml: dve hesla po 32 hex znacich');
isnt($pw[0], $pw[1], 'secrets-generic.yml: hesla se lisi');
like($sec, qr/^# SKUTECNA HESLA/, 'secrets-generic.yml: hlavicka upozornuje na skutecna hesla');
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok(has_pair($up, '-f', $SECRETS), 'deploy: -f secrets-generic.yml');

($rc, $out, $err) = k8s({%CTX, 'FAKE_HELM_STATUS_RC' => 0}, 'deploy', 'generic');
is($rc, 0, 'existujici soubor s hesly: dalsi deploy projde');
is(slurp($SECRETS), $sec, 'existujici soubor s hesly se neprepise');

spit($SECRETS, "secrets:\n  db:\n    data:\n      MARIADB_PASSWORD: \"CHANGE_ME\"\n");
($rc, $out, $err) = k8s({%CTX}, 'deploy', 'generic');
is($rc, 2, 'nevyplnene CHANGE_ME v secrets-generic.yml: kod 2');
unlink($SECRETS);
($rc, $out, $err) = k8s({%CTX, 'FAKE_HELM_STATUS_RC' => 0, 'K8S_NEW_SECRETS' => 1}, 'deploy', 'generic');
is($rc, 0, 'K8S_NEW_SECRETS=1: nova hesla i pro existujici release');
ok(-f $SECRETS, 'K8S_NEW_SECRETS=1: soubor zalozen');
unlink($SECRETS);

# ---------------------------------------------------------------------------------------------
# kubernetes/local.env
# ---------------------------------------------------------------------------------------------
$FILE_CTX = 'ctx-ze-souboru';    # invariant v k8s(): kontext behu bez KUBE_CONTEXT v prostredi je ten ze souboru
spit("$REPO/kubernetes/local.env", join("\r\n",
    '# komentar',
    'KUBE_CONTEXT="ctx-ze-souboru"',
    '  K8S_DOMAIN = example.env  ',
    "K8S_ISSUER='issuer-env'",
    'K8S_REGISTRY=reg.env/ns',
    'K8S_IMAGE_TAG=t1',
    '') . "\r\n");
($rc, $out, $err) = k8s({'FAKE_DIGEST' => $DIGEST}, 'deploy', 'static');
is($rc, 0, 'local.env: deploy jen z nastaveni v souboru');
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok(has_pair($up, '--kube-context', 'ctx-ze-souboru'), 'local.env: uvozovky a CR se odstrani (kontext)');
ok(has_pair($up, '--set-string', 'generic.pweDomain=example.env'), 'local.env: mezery kolem klice a hodnoty se odstrani');
ok(has_pair($up, '--set-string', 'generic.pweIssuer=issuer-env'), 'local.env: jednoduche uvozovky se odstrani');
is_deeply([digest_refs()], ['reg.env/ns/pwe-example-static:t1'], 'local.env: K8S_REGISTRY a K8S_IMAGE_TAG ze souboru plati i pro vzorove nasazeni');
($rc, $out, $err) = k8s({'FAKE_DIGEST' => $DIGEST, 'KUBE_CONTEXT' => 'ctx-z-prostredi'}, 'deploy', 'static');
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok(has_pair($up, '--kube-context', 'ctx-z-prostredi'), 'local.env: promenna prostredi ma prednost');
($rc, $out, $err) = k8s({'FAKE_DIGEST' => $DIGEST, 'K8S_REGISTRY' => 'ghcr.io/kukam', 'K8S_IMAGE_TAG' => 'latest'}, 'deploy', 'static');
is_deeply([digest_refs()], ['ghcr.io/kukam/pwe-example-static:latest'], 'local.env: registr a tag ze souboru lze pro jedno nasazeni prepsat z prostredi');
# local.env psany pro vlastni web (registr + jeho proxy cache): K8S_PULL_REGISTRY ze souboru plati dal,
# i kdyz se K8S_REGISTRY pro vzorove nasazeni prepise z prostredi - rada i nasazeni na to musi upozornit
spit("$REPO/kubernetes/local.env", "KUBE_CONTEXT=ctx-ze-souboru\nK8S_DOMAIN=example.env\nK8S_ISSUER=issuer-env\nK8S_REGISTRY=reg.env/ns\nK8S_PULL_REGISTRY=proxy.env/hub/ns\n");
($rc, $out, $err) = k8s({}, 'deploy', 'static');
is($rc, 2, 'local.env s K8S_PULL_REGISTRY, image vzoroveho webu v K8S_REGISTRY neni: kod 2');
like($err, qr{registr image PWE: K8S_REGISTRY=ghcr\.io/kukam\).*S jinym K8S_REGISTRY zmen i K8S_PULL_REGISTRY \(ted proxy\.env/hub/ns, plati dal\)}s,
    'local.env s K8S_PULL_REGISTRY: rada zmenit registr upozorni i na K8S_PULL_REGISTRY');
($rc, $out, $err) = k8s({'FAKE_DIGEST' => $DIGEST, 'K8S_REGISTRY' => 'ghcr.io/kukam'}, 'deploy', 'static');
is($rc, 0, 'local.env s K8S_PULL_REGISTRY, K8S_REGISTRY prepsany z prostredi: kod 0') or diag($err);
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok($up && has_pair($up, '--set-string', 'generic.pweRegistry=proxy.env/hub/ns'), 'K8S_PULL_REGISTRY z local.env plati i s K8S_REGISTRY z prostredi');
like($err, qr{image se overuje v registru ghcr\.io/kukam \(tam se zjistuje digest\), cluster ho ale taha z proxy\.env/hub/ns/pwe-example-static \(K8S_PULL_REGISTRY\) - musi to byt zrcadlo \(proxy cache\) registru ghcr\.io/kukam},
    'K8S_PULL_REGISTRY z local.env s jinym K8S_REGISTRY: nasazeni rekne, ze cluster taha z proxy jineho registru');
($rc, $out, $err) = k8s({'FAKE_DIGEST' => $DIGEST, 'K8S_REGISTRY' => 'ghcr.io/kukam', 'K8S_PULL_REGISTRY' => 'ghcr.io/kukam/'}, 'deploy', 'static');
unlike($err, qr/zrcadlo/, 'K8S_REGISTRY i K8S_PULL_REGISTRY prepsane z prostredi na tentyz registr: bez oznameni');
# vzor local.env.example: bez K8S_REGISTRY a K8S_IMAGE_TAG - vzorove nasazeni ma vychozi registr a tag image PWE
spit("$REPO/kubernetes/local.env", "KUBE_CONTEXT=ctx-ze-souboru\nK8S_DOMAIN=example.env\nK8S_ISSUER=issuer-env\n");
($rc, $out, $err) = k8s({'FAKE_DIGEST' => $DIGEST}, 'deploy', 'static');
is($rc, 0, 'local.env jen s kontextem, domenou a issuerem: vzorove nasazeni projde') or diag($err);
is_deeply([digest_refs()], ["ghcr.io/kukam/pwe-example-static:$VERSION"], 'local.env bez registru a tagu: image vzoroveho webu z vychoziho registru s tagem verze');
# vzor kubernetes/local.env.example z repozitare je platny local.env: skript ho nacte tak, jak je, a vzorove
# nasazeni s nim projde (registr, tag ani vyjimky v nem nastavene nejsou)
copy("$REPOROOT/kubernetes/local.env.example", "$REPO/kubernetes/local.env") or die "Nelze zkopirovat kubernetes/local.env.example: $!";
$FILE_CTX = 'muj-cluster';
($rc, $out, $err) = k8s({'FAKE_DIGEST' => $DIGEST}, 'deploy', 'static');
is($rc, 0, 'local.env.example jako local.env: vzorove nasazeni projde') or diag($err);
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok($up && has_pair($up, '--kube-context', 'muj-cluster') && has_pair($up, '--namespace', 'pwe')
        && has_pair($up, '--set-string', 'generic.pweDomain=example.com') && has_pair($up, '--set-string', 'generic.pweIssuer=letsencrypt'),
    'local.env.example: kontext, namespace, domena a issuer ze vzoru');
is_deeply([digest_refs()], ["ghcr.io/kukam/pwe-example-static:$VERSION"], 'local.env.example: registr ani tag nenastavuje (vychozi image vzoroveho webu)');
ok($up && has_pair($up, '--set-string', 'generic.pweRegistry=ghcr.io/kukam') && !grep({ /^--dry-run/ } @{$up}), 'local.env.example: bez K8S_PULL_REGISTRY a bez dalsich argumentu helmu');
unlike($err, qr/zrcadlo|se nepouziji|VAROVANI/, 'local.env.example: skript nic neoznamuje ani nevaruje');
$FILE_CTX = undef;
spit("$REPO/kubernetes/local.env", "1SPATNE=x\n");
($rc, $out, $err) = k8s({}, 'template', 'static');
is($rc, 2, 'local.env: neplatny nazev promenne se odmitne');
spit("$REPO/kubernetes/local.env", "X=\$(touch $T/pwned)\n");
($rc, $out, $err) = k8s({%CFG}, 'template', 'static');
ok(!-e "$T/pwned", 'local.env: hodnota se nespousti jako prikaz');
unlink("$REPO/kubernetes/local.env");

# ---------------------------------------------------------------------------------------------
# image vlastniho webu (prikaz image u vzoroveho nasazeni je vyse): zavislostni image + engine + web
# ---------------------------------------------------------------------------------------------
($rc, $out, $err) = k8s({%BASE}, 'image', 'mujweb');
is($rc, 2, 'image vlastniho webu bez K8S_REGISTRY: kod 2');
like($err, qr/neni nastaven K8S_REGISTRY/, 'image bez K8S_REGISTRY: hlaska');
is(scalar(calls('docker')), 0, 'image bez K8S_REGISTRY: docker se nevola');

# web bez databaze (profil static) se stavi nad pwe-base: image pwe-static neexistuje
($rc, $out, $err) = k8s({%CFG, 'FAKE_LOCAL_PLATFORMS' => 'linux/arm64'}, 'image', 'mujweb');
is($rc, 2, 'image: mistni zavislostni image jen pro jinou platformu: kod 2');
like($err, qr{mistni image ghcr\.io/kukam/pwe-base:\Q$VERSION\E neni pro platformu linux/amd64 \(je linux/arm64\)}, 'image webu bez databaze: hlaska o platforme jmenuje zavislostni image pwe-base');
like($err, qr{docker build --platform linux/amd64 --target base -t ghcr\.io/kukam/pwe-base:\Q$VERSION\E-amd64 -f PWE/docker/Dockerfile \. }, 'image webu bez databaze: rada sestavit stage base pro platformu clusteru pod vlastnim tagem');
like($err, qr/PWE_IMAGE_TAG=\Q$VERSION\E-amd64 make k8s-image K8S=mujweb/, 'image: rada predat vlastni tag zavislostniho image pres PWE_IMAGE_TAG');
unlike($err, qr/pwe-static/, 'image webu bez databaze: zruseny image pwe-static hlaska nezminuje');
ok(!builds(), 'image: pri spatne platforme se nestavi');

($rc, $out, $err) = k8s({%BASE, 'K8S_REGISTRY' => 'reg.test/ns/', 'FAKE_LOCAL_PLATFORMS' => 'linux/arm64 linux/amd64', 'FAKE_DIGEST' => $DIGEST}, 'image', 'mujweb', '--no-cache');
is($rc, 0, 'image: mistni zavislostni image pro cilovou platformu: kod 0') or diag($err);
my ($bld) = builds();
ok($bld, 'image: docker buildx build');
ok(has_pair($bld, '--platform', 'linux/amd64'),   'image: vychozi platforma linux/amd64');
ok(has_pair($bld, '--builder', 'desktop-linux'),  'image: builder podle kontextu dockeru');
ok(has_pair($bld, '-f', "$REPO/webapps/mujweb.web/Dockerfile"), 'image: Dockerfile webu z generic.pweWeb');
ok(has_pair($bld, '-t', 'reg.test/ns/mujweb-image:latest'), 'image: jmeno image z generic.pweImage, registr K8S_REGISTRY, vychozi tag latest');
ok(has_pair($bld, '--build-arg', 'PWE_IMAGE_REGISTRY=ghcr.io/kukam'), 'image: vychozi registr zavislostniho image');
ok(has_pair($bld, '--build-arg', "PWE_IMAGE_TAG=$VERSION"),           'image: vychozi tag zavislostniho image = verze z PWE/VERSION');
ok(has_pair($bld, '--build-arg', 'PWE_PROFILE=static'),               'image: profil z values');
is(scalar(grep { $_ eq '--build-arg' } @{$bld}), 3, 'image: prave tri build-arg (registr, tag, profil) - PWE_ENGINE_TAG ani jiny se nepredava');
ok(has_arg($bld, '--push'), 'image: --push');
ok(has_arg($bld, '--no-cache'), 'image: dalsi argumenty se predaji docker buildx build');
is($bld->[-1], $REPO, 'image: kontext sestaveni = koren repozitare (engine se do image bere z nej)');
my @inspected = map { $_->[-1] } grep { ($_->[1] || '') eq 'image' and ($_->[2] || '') eq 'inspect' and !has_arg($_, '--help') } calls('docker');
ok(scalar(@inspected), 'image: platforma mistniho zavislostniho image se kontroluje');
is_deeply([grep { $_ ne "ghcr.io/kukam/pwe-base:$VERSION" } @inspected], [], 'image webu bez databaze: kontroluje se jen pwe-base (pwe-static ani pwe se nehledaji)');
is_deeply([digest_refs()], ['reg.test/ns/mujweb-image:latest'], 'image: po nahrani vypise digest image webu');
like($err, qr{image webu reg\.test/ns/mujweb-image:latest \(linux/amd64\): zavislostni image ghcr\.io/kukam/pwe-base:\Q$VERSION\E \+ engine z pracovni kopie \(PWE/\) \+ web webapps/mujweb\.web},
    'image: hlaska rika, z ceho image webu vznika');
like($err, qr{nahrano: reg\.test/ns/mujweb-image:latest; nasazeni: make k8s-deploy K8S=mujweb}, 'image: hlaska po nahrani');

# web s databazi se stavi nad zavislostnim image sveho profilu (pwe-<profil>)
foreach my $profile (qw(mariadb mysql postgres)) {
    spit("$REPO/kubernetes/values-mujdb.yml", values_variant('generic', 'mujdb.web', $profile, 'mujdb-image'));
    ($rc, $out, $err) = k8s({%CFG, 'FAKE_LOCAL_PLATFORMS' => 'linux/arm64'}, 'image', 'mujdb');
    is($rc, 2, "image webu s profilem $profile, mistni zavislostni image jine platformy: kod 2");
    like($err, qr{mistni image ghcr\.io/kukam/pwe-\Q$profile:$VERSION\E neni pro platformu linux/amd64}, "image webu s profilem $profile: zavislostni image pwe-$profile");
    like($err, qr{docker build --platform linux/amd64 --target \Q$profile\E -t ghcr\.io/kukam/pwe-\Q$profile:$VERSION\E-amd64 -f PWE/docker/Dockerfile \. },
        "image webu s profilem $profile: rada stavi stage $profile");
    ok(!builds(), "image webu s profilem $profile: pri spatne platforme se nestavi");
    ($rc, $out, $err) = k8s({%CFG, 'FAKE_DIGEST' => $DIGEST}, 'image', 'mujdb');
    is($rc, 0, "image webu s profilem $profile, zavislostni image mistne neni (buildx ho stahne): kod 0") or diag($err);
    ($bld) = builds();
    ok($bld && has_pair($bld, '--build-arg', "PWE_PROFILE=$profile") && has_pair($bld, '--build-arg', "PWE_IMAGE_TAG=$VERSION")
            && has_pair($bld, '-f', "$REPO/webapps/mujdb.web/Dockerfile") && has_pair($bld, '-t', 'reg.test/ns/mujdb-image:v-test'),
        "image webu s profilem $profile: Dockerfile webu, build-arg PWE_PROFILE=$profile a tag z K8S_IMAGE_TAG");
    @inspected = map { $_->[-1] } grep { ($_->[1] || '') eq 'image' and ($_->[2] || '') eq 'inspect' and !has_arg($_, '--help') } calls('docker');
    ok(scalar(@inspected) && !grep({ $_ ne "ghcr.io/kukam/pwe-$profile:$VERSION" } @inspected), "image webu s profilem $profile: kontroluje se jen pwe-$profile");
    like($err, qr{zavislostni image ghcr\.io/kukam/pwe-\Q$profile:$VERSION\E \+ engine z pracovni kopie}, "image webu s profilem $profile: hlaska jmenuje zavislostni image");
}
spit("$REPO/kubernetes/values-mujdb.yml", values_variant('generic', 'mujdb.web', undef, 'mujdb-image'));
# stage, ktere rada pri spatne platforme stavi (--target base | mariadb | mysql | postgres), v PWE/docker/Dockerfile jsou
SKIP: {
    my $df = slurp("$ROOT/docker/Dockerfile");
    skip('strom bez PWE/docker/Dockerfile', 4) unless (length($df));
    like($df, qr/^FROM\s+\S+\s+AS\s+\Q$_\E\s*$/mi, "PWE/docker/Dockerfile ma stage $_ (rada pri spatne platforme ji stavi pres --target)") foreach (qw(base mariadb mysql postgres));
}

($rc, $out, $err) = k8s({%CFG, 'FAKE_DIGEST' => $DIGEST, 'PWE_IMAGE_TAG' => 'deps-tag', 'PWE_IMAGE_REGISTRY' => 'fork.test/x', 'K8S_PLATFORM' => 'linux/arm64'}, 'image', 'mujweb');
is($rc, 0, 'image s PWE_IMAGE_TAG a K8S_IMAGE_TAG: kod 0') or diag($err);
($bld) = builds();
ok($bld && has_pair($bld, '-t', 'reg.test/ns/mujweb-image:v-test'),              'image: tag image webu z K8S_IMAGE_TAG');
ok($bld && has_pair($bld, '--build-arg', 'PWE_IMAGE_TAG=deps-tag'),              'image: tag zavislostniho image z PWE_IMAGE_TAG');
ok($bld && has_pair($bld, '--build-arg', 'PWE_IMAGE_REGISTRY=fork.test/x'),      'image: registr zavislostniho image z PWE_IMAGE_REGISTRY');
ok($bld && has_pair($bld, '--platform', 'linux/arm64'),                          'image: K8S_PLATFORM');
like($err, qr{zavislostni image fork\.test/x/pwe-base:deps-tag \+ engine}, 'image: hlaska jmenuje zavislostni image z PWE_IMAGE_REGISTRY a PWE_IMAGE_TAG');

# tag zavislostniho image je verze z PWE/VERSION: bez ni (a bez PWE_IMAGE_TAG) se image webu nestavi
spit("$REPO/PWE/VERSION", "neni-verze\n");
($rc, $out, $err) = k8s({%CFG, 'FAKE_DIGEST' => $DIGEST}, 'image', 'mujweb');
is($rc, 2, 'image vlastniho webu s PWE/VERSION bez verze: kod 2 (tag zavislostniho image nejde urcit)');
like($err, qr/VERSION/, 'image s PWE/VERSION bez verze: hlaska jmenuje soubor VERSION');
ok(!builds(), 'image s PWE/VERSION bez verze: nestavi se');
($rc, $out, $err) = k8s({%CFG, 'FAKE_DIGEST' => $DIGEST, 'PWE_IMAGE_TAG' => 'latest'}, 'image', 'mujweb');
is($rc, 0, 'image s PWE/VERSION bez verze a s PWE_IMAGE_TAG: kod 0') or diag($err);
($bld) = builds();
ok($bld && has_pair($bld, '--build-arg', 'PWE_IMAGE_TAG=latest'), 'image s PWE_IMAGE_TAG: tag zavislostniho image se bere z nej');
spit("$REPO/PWE/VERSION", "$VERSION\n");

# Dockerfile z drivejsi sablony pocita se zakladnim image, ktery obsahuje engine (zruseny nosic pwe, zruseny
# pwe-static, mazani vzoroveho webu ze zakladu). Zavislostni image engine nemaji: sestaveni by skoncilo
# zavadejici chybou, nebo by nad starym mistnim tagem proslo a image webu by dostal stary engine.
{
    my $args = "ARG PWE_IMAGE_REGISTRY=ghcr.io/kukam\nARG PWE_IMAGE_TAG=latest\nARG PWE_PROFILE=static\n";
    my $from = "FROM \${PWE_IMAGE_REGISTRY}/pwe-\${PWE_PROFILE}:\${PWE_IMAGE_TAG}\n";
    foreach my $t (
        ['sablona se dvema FROM (nosic enginu pwe)', 'mujweb', 'pwe-base',
            "${args}ARG PWE_ENGINE_TAG=\${PWE_IMAGE_TAG}\nFROM \${PWE_IMAGE_REGISTRY}/pwe:\${PWE_ENGINE_TAG} AS engine\n${from}COPY --from=engine /PWE/PWE /PWE/PWE\nCOPY webapps/mujweb.web mujweb.web\n",
            'stavi nad zrusenym image pwe'],
        ['sablona s enginem v zakladu, profil static (maze vzorovy web)', 'mujweb', 'pwe-base',
            "${args}${from}RUN test -f /PWE/PWE/pwe.fcgi\nRUN rm -rf /PWE/webapps/example.web /PWE/webapps/example-db.web\nCOPY webapps/mujweb.web mujweb.web\n",
            'ze zakladniho image maze vzorovy web'],
        ['FROM pwe-static natvrdo', 'mujweb', 'pwe-base', "FROM ghcr.io/kukam/pwe-static:2.2.1\nCOPY webapps/mujweb.web mujweb.web\n", 'stavi nad zrusenym image pwe-static'],
        ['FROM s prepinacem --platform a digestem', 'mujweb', 'pwe-base', "FROM --platform=\$BUILDPLATFORM ghcr.io/kukam/pwe-static\@sha256:abc AS zaklad\n",
            'stavi nad zrusenym image pwe-static'],
        ['male from, odsazeni, registr s portem a konce radku CRLF', 'mujweb', 'pwe-base', "# komentar\r\n   from localhost:5000/kukam/pwe:latest as engine\r\nFROM scratch\r\n",
            'stavi nad zrusenym image pwe'],
        ['FROM pwe bez registru a tagu', 'mujweb', 'pwe-base', "FROM pwe\n", 'stavi nad zrusenym image pwe'],
        ['sablona s enginem v zakladu, profil s databazi (maze vzorovy web)', 'mujdb', 'pwe-mariadb',
            "${args}${from}RUN test -f /PWE/PWE/pwe.fcgi\nRUN rm -rf /PWE/webapps/example.web /PWE/webapps/example-db.web\nCOPY webapps/mujdb.web mujdb.web\n",
            'ze zakladniho image maze vzorovy web'],
        ['mazani jen vzoroveho webu s databazi uprostred prikazu', 'mujdb', 'pwe-mariadb', "FROM registry.example/muj/zaklad:1\nRUN set -eu; rm -r /PWE/webapps/example-db.web; mkdir -p /x\n",
            'ze zakladniho image maze vzorovy web'],
        ['mazani jen vzoroveho webu bez databaze', 'mujweb', 'pwe-base', "FROM registry.example/muj/zaklad:1\nRUN rm -rf /PWE/webapps/example.web\n", 'ze zakladniho image maze vzorovy web'],
        ['FROM bez tagu na konci radku s CRLF', 'mujweb', 'pwe-base', "FROM ghcr.io/kukam/pwe-static\r\nCOPY webapps/mujweb.web mujweb.web\r\n", 'stavi nad zrusenym image pwe-static'],
    ) {
        my ($name, $k8s, $base, $df, $why) = @{$t};
        my $regen = ($k8s eq 'mujdb') ? 'PWE/tools/new-webapp.pl mujdb.web --db mariadb --dir <docasny adresar>' : 'PWE/tools/new-webapp.pl mujweb.web --dir <docasny adresar>';
        spit("$REPO/webapps/$k8s.web/Dockerfile", $df);
        ($rc, $out, $err) = k8s({%CFG, 'FAKE_DIGEST' => $DIGEST}, 'image', $k8s);
        is($rc, 2, "Dockerfile z drivejsi sablony ($name): kod 2");
        like($err, qr{webapps/\Q$k8s\E\.web/Dockerfile je z drivejsi sablony \(\Q$why\E\)}, "Dockerfile z drivejsi sablony ($name): hlaska rika proc");
        like($err, qr{Dockerfile webu stavi nad \Q$base\E a engine kopiruje z kontextu sestaveni \(COPY PWE/\.\.\.\)\. Vygeneruj novy: \Q$regen\E a prevezmi z nej Dockerfile.*make check WEB=\Q$k8s\E\.web},
            "Dockerfile z drivejsi sablony ($name): rada jmenuje zavislostni image $base a jak ziskat novy Dockerfile");
        is(scalar(calls('docker')), 0, "Dockerfile z drivejsi sablony ($name): docker se nevola (nic se nestavi ani nenahrava)");
    }
    # co drivejsi sablona neni, projde: dnesni tvar, stare radky jen v komentari, vlastni zakladni image
    # a nazvy, ktere se zrusenym image jen podobaji
    my $new = web_dockerfile('pwe-base', 'mujweb.web');
    foreach my $t (
        ['dnesni tvar, web bez databaze nad pwe-base', 'mujweb', $new],
        ['dnesni tvar, web s databazi nad pwe-${PWE_PROFILE}', 'mujdb', web_dockerfile('pwe-${PWE_PROFILE}', 'mujdb.web')],
        ['stare radky jen v komentari', 'mujweb', "# FROM ghcr.io/kukam/pwe-static:1\n   # RUN rm -rf /PWE/webapps/example.web /PWE/webapps/example-db.web\n$new"],
        ['vlastni zakladni image', 'mujweb', "FROM registry.example/muj/zaklad:1\nCOPY PWE/Libs /PWE/PWE/Libs\nCOPY webapps/mujweb.web /PWE/webapps/mujweb.web\n"],
        ['nazvy, ktere se zrusenym image jen podobaji', 'mujweb', "FROM x/pwe-static-neco:1 AS a\nFROM x/mujpwe:1 AS b\nFROM x/pwe/zaklad:1 AS c\nFROM x/pwe-statics\n"],
        ['Dockerfile bez konce posledniho radku', 'mujweb', "FROM registry.example/muj/zaklad:1"],
    ) {
        my ($name, $k8s, $df) = @{$t};
        spit("$REPO/webapps/$k8s.web/Dockerfile", $df);
        ($rc, $out, $err) = k8s({%CFG, 'FAKE_DIGEST' => $DIGEST}, 'image', $k8s);
        is($rc, 0, "Dockerfile ($name): neni z drivejsi sablony, kod 0") or diag($err);
        ok(scalar(builds()) == 1, "Dockerfile ($name): image se stavi");
    }
    # posledni radek bez konce radku se take cte
    spit("$REPO/webapps/mujweb.web/Dockerfile", "FROM scratch\nFROM ghcr.io/kukam/pwe-static:1");
    ($rc, $out, $err) = k8s({%CFG, 'FAKE_DIGEST' => $DIGEST}, 'image', 'mujweb');
    is($rc, 2, 'Dockerfile z drivejsi sablony: FROM na poslednim radku bez konce radku se take pozna');
    # FROM .../pwe-${PWE_PROFILE} s profilem static by stavel nad zrusenym pwe-static. Bez dalsi znamky drivejsi
    # sablony to muze byt i dnesni Dockerfile webu s databazi a chybny pweProfile ve values: hlaska rika oboji.
    foreach my $t (
        ['FROM pwe-${PWE_PROFILE}', "${args}${from}COPY PWE/Libs /PWE/PWE/Libs\nCOPY webapps/mujweb.web /PWE/webapps/mujweb.web\n"],
        ['FROM pwe-$PWE_PROFILE bez slozenych zavorek', "FROM ghcr.io/kukam/pwe-\$PWE_PROFILE:latest\n"],
    ) {
        my ($name, $df) = @{$t};
        spit("$REPO/webapps/mujweb.web/Dockerfile", $df);
        ($rc, $out, $err) = k8s({%CFG, 'FAKE_DIGEST' => $DIGEST}, 'image', 'mujweb');
        is($rc, 2, "Dockerfile s $name a pweProfile static: kod 2 (image pwe-static neexistuje)");
        like($err, qr{webapps/mujweb\.web/Dockerfile stavi nad zavislostnim image profilu \(FROM \.\.\./pwe-\$\{PWE_PROFILE\}\), ale generic\.pweProfile v kubernetes/values-mujweb\.yml je static - image pwe-static neexistuje},
            "Dockerfile s $name a pweProfile static: hlaska");
        like($err, qr{Web s databazi: nastav generic\.pweProfile na jeji profil \(mariadb, mysql, postgres\)\. Web bez databaze: vygeneruj novy Dockerfile: PWE/tools/new-webapp\.pl mujweb\.web --dir <docasny adresar>},
            "Dockerfile s $name a pweProfile static: rada pro web s databazi i bez ni");
        unlike($err, qr/je z drivejsi sablony/, "Dockerfile s $name a pweProfile static: netvrdi, ze jde o drivejsi sablonu (muze byt chybny profil)");
        is(scalar(calls('docker')), 0, "Dockerfile s $name a pweProfile static: docker se nevola");
    }
    # web s databazi nasazovany s profilem static: jeho (dnesni) Dockerfile by stavel nad pwe-static
    spit("$REPO/kubernetes/values-spatny.yml", values_variant('generic', 'mujdb.web', 'static', 'mujdb-image'));
    ($rc, $out, $err) = k8s({%CFG, 'FAKE_DIGEST' => $DIGEST}, 'image', 'spatny');
    is($rc, 2, 'Dockerfile webu s databazi (FROM pwe-${PWE_PROFILE}) a pweProfile static: kod 2 (pwe-static neexistuje)');
    like($err, qr{webapps/mujdb\.web/Dockerfile stavi nad zavislostnim image profilu .* ale generic\.pweProfile v kubernetes/values-spatny\.yml je static}, 'Dockerfile webu s databazi a pweProfile static: hlaska jmenuje Dockerfile i values');
    ok(!builds(), 'Dockerfile webu s databazi a pweProfile static: nestavi se');
    unlink("$REPO/kubernetes/values-spatny.yml");

    # Sablona generatoru (webapps/example.web/Dockerfile a webapps/example-db.web/Dockerfile jsou jeji presny
    # vystup, hlida to PWE/t/14-tools.t) drzi krok se skriptem: neni to "drivejsi sablona", stavi nad
    # zavislostnim image, jehoz platformu skript kontroluje, a deklaruje build-arg, ktere skript predava.
  SKIP: {
        my %tpl = ('mujweb' => slurp("$REPOROOT/webapps/example.web/Dockerfile"), 'mujdb' => slurp("$REPOROOT/webapps/example-db.web/Dockerfile"));
        skip('strom bez webapps/example.web/Dockerfile a webapps/example-db.web/Dockerfile', 10) unless (length($tpl{'mujweb'}) and length($tpl{'mujdb'}));
        foreach my $k8s (sort keys %tpl) {
            my $base = ($k8s eq 'mujweb') ? 'pwe-base' : 'pwe-${PWE_PROFILE}';
            (my $df = $tpl{$k8s}) =~ s/example(?:-db)?\.web/$k8s.web/g;
            spit("$REPO/webapps/$k8s.web/Dockerfile", $df);
            ($rc, $out, $err) = k8s({%CFG, 'FAKE_DIGEST' => $DIGEST}, 'image', $k8s);
            is($rc, 0, "sablona generatoru ($k8s.web podle vzoroveho webu): skript image webu stavi") or diag($err);
            ok(scalar(builds()) == 1, "sablona generatoru ($k8s.web): docker buildx build se vola");
            is(scalar(() = $df =~ /^FROM[ \t]/mg), 1, "sablona generatoru ($k8s.web): jediny FROM");
            like($df, qr/^FROM \$\{PWE_IMAGE_REGISTRY\}\/\Q$base\E:\$\{PWE_IMAGE_TAG\}$/m, "sablona generatoru ($k8s.web): FROM <PWE_IMAGE_REGISTRY>/$base:<PWE_IMAGE_TAG> = zavislostni image, se kterym skript pocita");
            ok(scalar(grep { $df =~ /^ARG \Q$_\E=/m } qw(PWE_IMAGE_REGISTRY PWE_IMAGE_TAG PWE_PROFILE)) == 3, "sablona generatoru ($k8s.web): deklaruje build-arg PWE_IMAGE_REGISTRY, PWE_IMAGE_TAG a PWE_PROFILE");
        }
    }
    spit("$REPO/webapps/mujweb.web/Dockerfile", $new);
    spit("$REPO/webapps/mujdb.web/Dockerfile", web_dockerfile('pwe-${PWE_PROFILE}', 'mujdb.web'));
}

($rc, $out, $err) = k8s({%BASE, 'K8S_REGISTRY' => 'reg.test/ns', 'PWE_IMAGE_TAG' => 'deps-tag'}, 'template', 'mujweb');
($tpl) = calls('helm');
ok(has_pair($tpl, '--set-string', 'generic.pweImageTag=latest'), 'tag image vlastniho webu nezavisi na PWE_IMAGE_TAG');
($rc, $out, $err) = k8s({%CFG, 'K8S_IMAGE_TAG' => "v1\@$DIGEST"}, 'image', 'mujweb');
is($rc, 2, 'image s K8S_IMAGE_TAG vcetne digestu: kod 2');
ok(!builds(), 'image s K8S_IMAGE_TAG vcetne digestu: nestavi se');
unlink("$REPO/webapps/mujweb.web/Dockerfile");
($rc, $out, $err) = k8s({%CFG}, 'image', 'mujweb');
is($rc, 2, 'image vlastniho webu bez Dockerfile: kod 2');
like($err, qr{webapps/mujweb\.web/Dockerfile neexistuje}, 'image bez Dockerfile: hlaska');

# ---------------------------------------------------------------------------------------------
# status, logs, delete, test
# ---------------------------------------------------------------------------------------------
($rc, $out, $err) = k8s({%CTX, 'FAKE_PVC' => 'data-pwe-generic-mariadb-0', 'FAKE_TLS' => 'pwe-generic-web-tls'}, 'status', 'generic');
is($rc, 0, 'status: kod 0');
like($out, qr/data-pwe-generic-mariadb-0/, 'status: vypise svazek releasu');
like($out, qr/pwe-generic-web-tls True/, 'status: vypise certifikat podle jmena Secretu z ingressu');
ok(scalar(calls('kubectl')) && !grep({ !has_pair($_, '--context', 'ctx-test') } calls('kubectl')), 'status: kazdy kubectl s --context');
{
    my @st = grep { $_->[1] eq 'status' } calls('helm');
    ok(scalar(@st) && !grep({ !has_pair($_, '--kube-context', 'ctx-test') } calls('helm')), 'status: helm status (a kazdy helm) s --kube-context ctx-test');
    ok(scalar(@st) && !grep({ !has_pair($_, '--namespace', 'pwe') } cluster_calls()), 'status: kazdy helm i kubectl s --namespace pwe');
}

($rc, $out, $err) = k8s({%CTX}, 'logs', 'static', '-c', 'fcgi');
my ($lg) = calls('kubectl');
ok(has_pair($lg, '-c', 'fcgi') && !has_arg($lg, '--all-containers'), 'logs -c: bez --all-containers');
($rc, $out, $err) = k8s({%CTX}, 'logs', 'static');
($lg) = calls('kubectl');
ok(has_arg($lg, '--all-containers') && has_pair($lg, '--context', 'ctx-test'), 'logs: --all-containers a --context');

# delete bez mistniho souboru s hesly: hesla databaze by po odinstalovani zustala jen ve svazku, ktery
# odinstalovani nemaze (deploy ma pro zrcadlovy pripad ochranu existujiciho releasu)
unlink($SECRETS);
($rc, $out, $err) = k8s({%CTX, 'FAKE_PVC' => 'data-pwe-generic-mariadb-0', 'FAKE_TLS' => 'pwe-generic-web-tls'}, 'delete', 'generic');
is($rc, 2, 'delete bez mistniho secrets-generic.yml: kod 2 (hesla by zustala jen ve svazku)');
like($err, qr/secrets-generic\.yml na tomto stroji chybi.*get values pwe-generic -o yaml.*K8S_DELETE_WITHOUT_SECRETS=1/s, 'delete bez souboru s hesly: rada ulozit hesla a vyslovna vyjimka');
like($err, qr/helm --kube-context ctx-test -n pwe get values pwe-generic/, 'delete bez souboru s hesly: rada jmenuje kontext a namespace vyslovne');
ok(!grep({ $_->[1] eq 'uninstall' } calls('helm')), 'delete bez souboru s hesly: helm uninstall se nevola');
is(scalar(cluster_calls()), 0, 'delete bez souboru s hesly: helm ani kubectl se nevolaji');
($rc, $out, $err) = k8s({%CTX, 'FAKE_PVC' => 'data-pwe-generic-mariadb-0'}, 'delete', 'generic', '--dry-run');
is($rc, 0, 'delete --dry-run bez souboru s hesly: zkouska nasucho projde') or diag($err);
{
    my ($dry) = grep { $_->[1] eq 'uninstall' } calls('helm');
    ok($dry && has_arg($dry, '--dry-run') && has_pair($dry, '--kube-context', 'ctx-test'), 'delete --dry-run: helm uninstall dostane --dry-run a --kube-context');
}
like($err, qr/zkouska nasucho \(--dry-run\): release pwe-generic zustava/, 'delete --dry-run: hlaska o zkousce nasucho');
unlike($err, qr/odinstalovan/, 'delete --dry-run: nehlasi odinstalovani');
($rc, $out, $err) = k8s({%CTX}, 'delete', 'generic', '--dry-run=false');
is($rc, 2, 'delete --dry-run=false bez souboru s hesly: je to skutecne odinstalovani, kod 2');
ok(!grep({ $_->[1] eq 'uninstall' } calls('helm')), 'delete --dry-run=false bez souboru s hesly: helm uninstall se nevola');
($rc, $out, $err) = k8s({%CTX}, 'delete', 'static');
is($rc, 0, 'delete nasazeni bez hesel (static nema vzor secrets-static.example.yml): pojistka se neuplatni') or diag($err);
ok(scalar(grep { $_->[1] eq 'uninstall' } calls('helm')), 'delete static: helm uninstall');

# Regrese: helm uninstall bere argument bez pomlcky jako dalsi release - "delete static pwe-generic" odinstaloval
# i release s hesly, jehoz mistni soubor s hesly pojistka nekontrolovala.
($rc, $out, $err) = k8s({%CTX}, 'delete', 'static', 'pwe-generic');
is($rc, 2, 'delete s dalsim jmenem releasu: kod 2 (obesel by pojistku hesel)');
ok(!grep({ $_->[1] eq 'uninstall' } calls('helm')), 'delete s dalsim jmenem releasu: helm uninstall se nevola');
like($err, qr/argument 'pwe-generic' by helm vzal jako dalsi release .* jen release pwe-static/, 'delete s dalsim jmenem releasu: hlaska jmenuje argument i odinstalovavany release');
($rc, $out, $err) = k8s({%CTX}, 'delete', 'static', '--timeout', '5m', '--cascade=foreground');
is($rc, 0, 'delete --timeout 5m: hodnota prepinace oddelena mezerou neni dalsi release') or diag($err);
{
    my ($un) = grep { $_->[1] eq 'uninstall' } calls('helm');
    ok($un && has_pair($un, '--timeout', '5m') && has_arg($un, '--cascade=foreground'), 'delete --timeout 5m: prepinace se predaji helmu');
}
($rc, $out, $err) = k8s({%CTX}, 'delete', 'static', '--timeout', '5m', 'pwe-generic');
is($rc, 2, 'delete: dalsi release za prepinacem s hodnotou se odmitne take');
spit($SECRETS, "secrets:\n  db:\n    data:\n      MARIADB_PASSWORD: \"x\"\n", 0600);
($rc, $out, $err) = k8s({%CTX}, 'delete', 'generic');
is($rc, 0, 'delete s mistnim souborem s hesly: kod 0 bez vyjimky') or diag($err);
ok(scalar(grep { $_->[1] eq 'uninstall' } calls('helm')), 'delete s mistnim souborem s hesly: helm uninstall');
ok(-f $SECRETS, 'delete: mistni soubor s hesly zustava');
unlink($SECRETS);

($rc, $out, $err) = k8s({%CTX, 'FAKE_PVC' => 'data-pwe-generic-mariadb-0', 'FAKE_TLS' => 'pwe-generic-web-tls', 'K8S_DELETE_WITHOUT_SECRETS' => 1}, 'delete', 'generic');
is($rc, 0, 'delete s K8S_DELETE_WITHOUT_SECRETS=1: kod 0');
my ($un) = grep { $_->[1] eq 'uninstall' } calls('helm');
ok($un && has_pair($un, '--kube-context', 'ctx-test'), 'delete: helm uninstall s --kube-context');
is($un && $un->[2], 'pwe-generic', 'delete: odinstaluje se release pwe-<nazev>');
like($err, qr/release pwe-generic odinstalovan/, 'delete: hlaska o odinstalovani');
like($out, qr/data-pwe-generic-mariadb-0/, 'delete: vypise zbyly svazek');
like($out, qr/pwe-generic-web-tls/, 'delete: vypise zbyly Secret s certifikatem');
ok(scalar(calls('kubectl')) && !grep({ has_arg($_, 'delete') } calls('kubectl')), 'delete: sam nic dalsiho nemaze (zadny kubectl delete)');
is(scalar(grep { $_->[1] ne 'uninstall' } calls('helm')), 0, 'delete: jediny prikaz helmu je uninstall');
ok(scalar(calls('kubectl')) && !grep({ !has_pair($_, '--kube-context', 'ctx-test') } calls('helm')) && !grep({ !has_pair($_, '--context', 'ctx-test') } calls('kubectl')),
    'delete: kazdy helm i kubectl s vyslovnym kontextem');

($rc, $out, $err) = k8s({%CFG}, 'test', 'static');
is($rc, 0, 'test: kod 0');
my @urls = map { $_->[-1] } calls('curl');
ok(grep({ $_ eq 'https://pwe-static.example.test/' } @urls), 'test: uvodni stranka na pwe-<nazev>.<K8S_DOMAIN>');
ok(grep({ m{/assets/css/bootstrap-5\.3\.8/bootstrap\.min\.css$} } @urls), 'test: statika enginu podle verze v PWE/assets');
ok(grep({ m{/static/css/site\.css$} } @urls), 'test: statika webu, kdyz ji web ma');
($rc, $out, $err) = k8s({%CFG}, 'test', 'generic');
ok(!grep({ m{/static/css/site\.css$} } map { $_->[-1] } calls('curl')), 'test: bez statiky webu se nekontroluje');
($rc, $out, $err) = k8s({%CFG, 'FAKE_CURL_CODE' => '502'}, 'test', 'static');
is($rc, 1, 'test: chyba webu = kod 1');

my $hostvals = slurp("$REPO/kubernetes/values-static.yml");
$hostvals =~ s/^  pweHost: ""/  pweHost: "www.mujweb.test"/m or die 'values-static.yml bez pweHost';
spit("$REPO/kubernetes/values-host.yml", $hostvals);
($rc, $out, $err) = k8s({}, 'test', 'host');
is($rc, 0, 'test s generic.pweHost: K8S_DOMAIN (ani registr a tag) neni potreba');
ok(grep({ $_ eq 'https://www.mujweb.test/' } map { $_->[-1] } calls('curl')), 'test: adresa z generic.pweHost');

# ---------------------------------------------------------------------------------------------
# values soubory vzorovych nasazeni (kontrakt s image vzoroveho webu a s enginem od verze 2.2.1)
# ---------------------------------------------------------------------------------------------
foreach my $t (['static', 'pwe-example-static', 'static', 'example.web'], ['generic', 'pwe-example-mariadb', 'mariadb', 'example-db.web']) {
    my ($name, $image, $profile, $web) = @{$t};
    my $v = slurp("$REPOROOT/kubernetes/values-$name.yml");
    like($v, qr/^  pweImage: \Q$image\E\s/m,     "values-$name.yml: image vzoroveho webu $image (knihovny, engine i web)");
    like($v, qr/^  pweProfile: \Q$profile\E\s/m, "values-$name.yml: profil $profile");
    like($v, qr/^  pweWeb: \Q$web\E\s/m,         "values-$name.yml: vzorovy web $web");
    ok(scalar(grep { $_->[0] eq $image and $_->[1] eq $profile and $_->[2] eq $web } @SAMPLES), "values-$name.yml: image, profil a web patri k sobe (vzorove nasazeni)");
    like($v, qr/^  pweRegistry: ghcr\.io\/kukam\s/m, "values-$name.yml: vychozi registr ghcr.io/kukam");
    like($v, qr/^  pweImageTag: latest\s/m,      "values-$name.yml: vychozi tag latest (zadny tag podle vetve)");
    # Image vzoroveho webu je sestaveny sablonou webu: engine v /PWE/PWE, web v /PWE/webapps/<web>, pracovni
    # adresare z buildu; initContainer i kontejner enginu bezi z tehoz image.
    is(scalar(() = $v =~ m{image: "\{\{ \.Values\.generic\.pweRegistry \}\}/\{\{ \.Values\.generic\.pweImage \}\}"\n\s+imageTag: "\{\{ \.Values\.generic\.pweImageTag \}\}"\n}g), 2,
        "values-$name.yml: initContainer i engine bezi z image <pweRegistry>/<pweImage>:<pweImageTag>");
    like($v, qr{web="/PWE/webapps/\{\{ \.Values\.generic\.pweWeb \}\}"\n}, "values-$name.yml: initContainer bere statiku webu z /PWE/webapps/<web>");
    like($v, qr{cp -a /PWE/PWE/assets /srv/engine/\n}, "values-$name.yml: initContainer bere statiku enginu z /PWE/PWE/assets");
    like($v, qr{mountPath: "/PWE/webapps/\{\{ \.Values\.generic\.pweWeb \}\}/uploadfile"\n}, "values-$name.yml: svazek s nahranymi soubory je v adresari webu");
    unlike($v, qr/^\s*- name: (?:PWE_CONF_pwe_home|PWE_CONF_pwe_core|PWE_PROFILE)\s*$/m, "values-$name.yml: PWE_CONF_pwe_home, PWE_CONF_pwe_core ani PWE_PROFILE se nenastavuji (ma je image)");
    unlike($v, qr/^\s*(?:command|args):.*pwe\.fcgi/m, "values-$name.yml: prikaz kontejneru enginu se neprepisuje (vychozi prikaz image = engine nad webem)");
    like($v, qr/- name: FCGI_SOCKET_PATH\n\s+value: "127\.0\.0\.1:7779"\n/, "values-$name.yml: engine posloucha jen na 127.0.0.1:7779");
    unlike($v, qr/containerPort: 7779/,          "values-$name.yml: port enginu se nedeklaruje jako containerPort");
    like($v, qr/fastcgi_pass 127\.0\.0\.1:7779;/, "values-$name.yml: nginx se pripojuje na 127.0.0.1:7779");
    is(scalar(() = $v =~ m{command: \["bash", "-c", "exec 3<>/dev/tcp/127\.0\.0\.1/7779"\]}g), 3, "values-$name.yml: tri sondy enginu zkouseji 127.0.0.1:7779 zevnitr kontejneru");
    like($v, qr/^networkPolicies:\n(?:.*\n)*?  web:\n(?:.*\n)*?          - port: 80\n/m, "values-$name.yml: NetworkPolicy webu (port 80) zustava");
}
like(slurp("$REPOROOT/kubernetes/values-generic.yml"), qr/^  mariadb:\n(?:.*\n)*?          - port: 3306\n/m, 'values-generic.yml: NetworkPolicy databaze (port 3306) zustava');

# ---------------------------------------------------------------------------------------------
# hesla a mistni nastaveni nesmeji do gitu ani do image
# ---------------------------------------------------------------------------------------------
foreach my $f ('.gitignore', '.dockerignore') {
    my $s = slurp("$REPOROOT/$f");
    like($s, qr{^kubernetes/local\.env$}m,                 "$f: kubernetes/local.env");
    like($s, qr{^kubernetes/secrets-\*\.yml$}m,            "$f: kubernetes/secrets-*.yml");
    like($s, qr{^!kubernetes/secrets-\*\.example\.yml$}m,  "$f: vzor secrets-*.example.yml je vyjimka");
}

# ---------------------------------------------------------------------------------------------
# napoveda skriptu, kubernetes/README.md a local.env.example drzi krok se skriptem
# ---------------------------------------------------------------------------------------------
{
    my $script  = slurp($K8S);
    my $readme  = slurp("$REPOROOT/kubernetes/README.md");
    my $example = slurp("$REPOROOT/kubernetes/local.env.example");
    (my $flat = $readme) =~ s/\s*\n(?:>[ \t]?)?\s*/ /g;    # hlasky citovane pres zlom radku (i v ramecku "> ")
    ($rc, $out, $err) = k8s({}, '--help');

    # kazda promenna K8S_*, kterou skript cte, je popsana v napovede i v README
    my %vars = map { $_ => 1 } $script =~ /\$\{?(K8S_[A-Z_]+)/g;
    ok(scalar(keys %vars) >= 15, 'skript cte promenne K8S_* (kontrola dokumentace ma co overovat)');
    foreach my $var (sort keys %vars) {
        like($out,    qr/\b\Q$var\E\b/, "napoveda popisuje $var");
        like($readme, qr/\b\Q$var\E\b/, "kubernetes/README.md popisuje $var");
    }
    # vyjimky patri jen na prikazovou radku: vzor je zminuje, ale nenastavuje (ani zakomentovanym radkem)
    foreach my $var (qw(K8S_ALLOW_TAG K8S_NEW_SECRETS K8S_DELETE_WITHOUT_SECRETS)) {
        like($example,   qr/\b\Q$var\E=1\b/,     "local.env.example zminuje vyjimku $var");
        unlike($example, qr/^\s*#?\s*\Q$var\E=/m, "local.env.example vyjimku $var nenastavuje");
    }
    like($out, qr/HELM_KUBE/, 'napoveda zminuje promenne HELM_KUBE*, ktere skript rusi');

    # varovani entrypointu image vzoroveho webu (v logu kontejneru fcgi vzoroveho nasazeni): README cituje to,
    # ktere entrypoint opravdu vypisuje - pri zmene textu v PWE/docker/entrypoint.sh je potreba upravit i README
    ok(index($flat, 'VAROVANI: bezi vzorovy web') >= 0, 'kubernetes/README.md: varovani entrypointu o vzorovem webu');
  SKIP: {
        my $entry = slurp("$ROOT/docker/entrypoint.sh");
        skip('strom bez PWE/docker/entrypoint.sh', 1) unless (length($entry));
        ok(index($entry, 'VAROVANI: ') >= 0 && index($entry, 'bezi vzorovy web') >= 0, 'varovani o vzorovem webu, ktere README cituje, entrypoint image opravdu vypisuje (PWE/docker/entrypoint.sh)');
    }

    # nazvy image: napoveda i README jmenuji vsechny ctyri image vzorovych webu a vsechny vyhrazene nazvy
    foreach my $image ((map { $_->[0] } @SAMPLES), qw(pwe-base pwe-mariadb pwe-mysql pwe-postgres pwe-debugger pwe-static)) {
        like($out,    qr/(?<![\w-])\Q$image\E(?![\w-])/, "napoveda jmenuje image $image");
        like($readme, qr/(?<![\w-])\Q$image\E(?![\w-])/, "kubernetes/README.md jmenuje image $image");
    }
    like($example, qr/pwe-example-/, 'local.env.example: vzorova nasazeni nasazuji image pwe-example-<profil>');
    # zadny "image enginu" uz neexistuje (zavislostni image engine neobsahuji, engine je az v image webu)
    foreach my $doc (['napoveda', $out], ['kubernetes/README.md', $readme], ['kubernetes/local.env.example', $example],
        ['kubernetes/values-static.yml', slurp("$REPOROOT/kubernetes/values-static.yml")], ['kubernetes/values-generic.yml', slurp("$REPOROOT/kubernetes/values-generic.yml")])
    {
        unlike($doc->[1], qr/image\s+enginu/, "$doc->[0]: o \"image enginu\" uz nemluvi");
    }

    # hlasky, ktere README vysvetluje (reseni potizi, hesla, odinstalovani), skript opravdu vypisuje
    foreach my $msg (
        'neni nastaven KUBE_CONTEXT', 'neni povolen', 'se nepouziji', 'nelze zjistit', 'v clusteru nelze zjistit',
        'docker nevypsal digest tvaru sha256:<64 hex>', 'image se overuje v registru', 'je image vzoroveho webu',
        'je vyhrazeny nazev image PWE', 'neni nazev image', 'neni profil PWE', 'je z drivejsi sablony',
        'stavi nad zavislostnim image profilu', 'nic se nestavi', 'neni pro platformu', 'na tomto stroji chybi',
    ) {
        ok(index($script, $msg) >= 0, "skript vypisuje hlasku '$msg'");
        ok(index($flat, $msg) >= 0,   "kubernetes/README.md hlasku '$msg' vysvetluje");
    }
    ok(index($flat, 'release: not found') >= 0 && index($script, 'release: not found') >= 0, 'README i skript: release prokazatelne neexistuje = "release: not found"');

    # hlaska enginu o cekani na zamek migrace (druhy pod pri zakladani schematu): README cituje tu, kterou
    # engine opravdu loguje - pri zmene hlasky v PWE/Libs/MyDBI.pm je potreba upravit i README
    my $wait = 'Dbversion: migraci databaze dbid:db1 provadi jiny proces, cekam na zamek spojeni';
    ok(index($flat, $wait) >= 0, 'kubernetes/README.md: hlaska enginu o cekani na zamek migrace');
    unlike($readme, qr/Dbversion is locked/, 'kubernetes/README.md: stara hlaska "Dbversion is locked" uz v nem neni');
  SKIP: {
        my $engine = slurp("$ROOT/Libs/MyDBI.pm");
        skip('strom bez PWE/Libs/MyDBI.pm', 1) unless (length($engine));
        (my $tmpl = $wait) =~ s/dbid:db1/dbid:\$dbid/;
        ok(index($engine, $tmpl) >= 0, 'hlasku o cekani na zamek migrace, kterou README cituje, engine opravdu loguje (PWE/Libs/MyDBI.pm)');
    }
}

# ---------------------------------------------------------------------------------------------
# invarianty pres vsechny behy skriptu v tomto testu (viz k8s())
# ---------------------------------------------------------------------------------------------
is_deeply(\@VIOLATIONS, [], 'vsechny behy: kazdy helm/kubectl dostal vyslovny kontext (nebo helm template prazdny kubeconfig), '
    . 'namespace jen z K8S_NAMESPACE a zadnou promennou HELM_KUBE*, HELM_NAMESPACE ani KUBERNETES_MASTER');
ok($CHECKED > 100, "invarianty se overovaly nad volanimi helm a kubectl ze vsech behu ($CHECKED volani, $RUN behu)");
# kontrola kontroly: call_violations pozna kazdy druh poruseni (jinak by invariant vyse nic nehlidal)
{
    my @ok = ('--kube-context', 'ctx', '--namespace', 'pwe');
    my $v  = sub { return join(',', call_violations(@_)); };
    is($v->('helm', 'KUBECONFIG=-', ['upgrade', 'r', @ok], 'ctx', 'pwe'), '', 'invariant: helm s kontextem a namespace je v poradku');
    is($v->('kubectl', 'KUBECONFIG=-', ['--context', 'ctx', '--namespace', 'pwe', 'get', 'pods'], 'ctx', 'pwe'), '', 'invariant: kubectl s kontextem a namespace je v poradku');
    is($v->('helm', 'KUBECONFIG=/dev/null', ['template', 'r', '--namespace', 'pwe'], undef, 'pwe'), '', 'invariant: helm template bez kontextu s prazdnym kubeconfigem je v poradku');
    is($v->('helm', 'KUBECONFIG=-', ['template', 'r', '--namespace', 'pwe'], undef, 'pwe'), 'bez kontextu', 'invariant: helm bez kontextu a bez prazdneho kubeconfigu');
    is($v->('helm', 'KUBECONFIG=/dev/null', ['status', 'r', '--namespace', 'pwe'], 'ctx', 'pwe'), 'bez kontextu', 'invariant: helm bez --kube-context, kdyz kontext nastaven je');
    is($v->('helm', 'KUBECONFIG=-', ['status', 'r', '--kube-context', '', '--namespace', 'pwe'], undef, 'pwe'), 'kontext', 'invariant: helm s prazdnym --kube-context (= aktualni kontext)');
    is($v->('helm', 'KUBECONFIG=-', ['status', 'r', '--kube-context', 'cizi', '--namespace', 'pwe'], 'ctx', 'pwe'), 'kontext', 'invariant: helm s jinym kontextem');
    is($v->('helm', 'KUBECONFIG=-', ['upgrade', 'r', @ok, '--kube-context=cizi'], 'ctx', 'pwe'), 'kontext', 'invariant: helm s druhym --kube-context');
    is($v->('kubectl', 'KUBECONFIG=-', ['--namespace', 'pwe', 'get', 'pods'], 'ctx', 'pwe'), 'bez kontextu', 'invariant: kubectl bez --context');
    is($v->('kubectl', 'KUBECONFIG=/dev/null', ['--namespace', 'pwe', 'get', 'pods'], undef, 'pwe'), 'bez kontextu', 'invariant: kubectl bez --context ani s prazdnym kubeconfigem');
    is($v->('kubectl', 'KUBECONFIG=-', ['--context', 'ctx', '--namespace', 'pwe', 'logs', '-n', 'jiny'], 'ctx', 'pwe'), 'namespace', 'invariant: kubectl s -n');
    is($v->('helm', 'KUBECONFIG=-', ['uninstall', 'r', @ok, '--namespace=jiny'], 'ctx', 'pwe'), 'namespace', 'invariant: helm s druhym --namespace');
    is($v->('helm', 'KUBECONFIG=-', ['uninstall', 'r', '--kube-context', 'ctx'], 'ctx', 'pwe'), 'namespace', 'invariant: helm bez --namespace');
}

done_testing();
