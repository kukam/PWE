#!/usr/bin/env perl
# PWE/tools/k8s.sh (nasazeni do Kubernetes, cile make k8s-*):
#   - bezpecnost kontextu: bez KUBE_CONTEXT se ke clusteru nic nepripoji, template bez kontextu dostane
#     prazdny kubeconfig, kazdy helm/kubectl dostane --kube-context/--context, prepinace menici cluster
#     nebo kontext (v argumentech i v K8S_HELM_ARGS) se odmitnou
#   - deploy podle digestu, chybejici image = chyba (vyjimka K8S_ALLOW_TAG=1)
#   - hesla: zalozeni secrets-<nazev>.yml ze vzoru, ochrana existujiciho releasu, nevyplnene CHANGE_ME
#   - kubernetes/local.env (uvozovky, CR, mezery, prednost promenne prostredi), kontrola nazvu a tagu
#   - image: kontrola platformy mistnich image enginu, argumenty docker buildx build
#   - status/delete hledaji svazky podle stitku releasu, test pouziva adresu z generic.pweHost
#   - .gitignore a .dockerignore nepousti kubernetes/local.env a secrets-*.yml do gitu ani do image
#
# Skript se spousti z KOPIE v docasnem stromu (<tmp>/repo/PWE/tools, values a vzory z kubernetes/
# repozitare) s falesnymi programy helm, kubectl, docker, curl a openssl na zacatku PATH. Falesne
# programy jen zapisuji sva volani do $FAKE_LOG (a promennou KUBECONFIG, se kterou byly spusteny);
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
spit("$REPO/webapps/example.web/Dockerfile",    "FROM scratch\n");
spit("$REPO/webapps/example-db.web/Dockerfile", "FROM scratch\n");
spit("$REPO/webapps/example.web/static/css/site.css", "body{}\n");

my $DIGEST = 'sha256:' . ('ab' x 32);

# Falesne programy: radek "<program><TAB>KUBECONFIG=<hodnota|-><TAB>argumenty..." do $FAKE_LOG.
my $LOGLINE = <<'EOS';
{ printf '%s\tKUBECONFIG=%s' "$(basename "$0")" "${KUBECONFIG--}"; for a in "$@"; do printf '\t%s' "${a//$'\n'/ }"; done; printf '\n'; } >> "$FAKE_LOG"
EOS

# helm: "status" vraci FAKE_HELM_STATUS_RC (vychozi 1 = release neexistuje), ostatni 0
spit("$T/bin/helm", "#!/bin/bash\n$LOGLINE" . <<'EOS', 0755);
[ "$1" = status ] && exit "${FAKE_HELM_STATUS_RC:-1}"
exit 0
EOS

# kubectl: svazky (-o name / tabulka), jmena Secretu s certifikatem z ingressu, certifikaty a Secrety
spit("$T/bin/kubectl", "#!/bin/bash\n$LOGLINE" . <<'EOS', 0755);
case "$*" in
    *persistentvolumeclaims*"-o name"*) [ -n "${FAKE_PVC:-}" ] && printf 'persistentvolumeclaim/%s\n' "$FAKE_PVC" ;;
    *persistentvolumeclaims*)           [ -n "${FAKE_PVC:-}" ] && printf 'NAME STATUS\n%s Bound\n' "$FAKE_PVC" ;;
    *ingress*jsonpath*)                 printf '%s' "${FAKE_TLS:-}" ;;
    *"get certificates"*)               printf 'NAME READY\n%s True\n' "${FAKE_TLS:-}" ;;
    *"get secrets"*)                    printf 'NAME TYPE\n%s kubernetes.io/tls\n' "${FAKE_TLS:-}" ;;
esac
exit 0
EOS

# docker: digest v registru (FAKE_DIGEST, jinak "not found"), mistni image enginu (FAKE_LOCAL_PLATFORMS =
# seznam platforem oddeleny mezerou; prazdne = image mistne neni), kontext dockeru
spit("$T/bin/docker", "#!/bin/bash\n$LOGLINE" . <<'EOS', 0755);
case "$1 $2" in
    "buildx imagetools")
        if [ -n "${FAKE_DIGEST:-}" ]; then printf '%s\n' "$FAKE_DIGEST"; exit 0; fi
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

# k8s({PROMENNA => hodnota}, argumenty...) -> (rc, stdout, stderr). Prostredi je jen to, co test nastavi.
sub k8s {
    my ($env, @args) = @_;
    $RUN++;
    my ($fout, $ferr) = ("$T/run-$RUN.out", "$T/run-$RUN.err");
    unlink($LOG);
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
    return ($rc, slurp($fout), slurp($ferr));
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
sub cluster_calls { return (calls('helm'), calls('kubectl')); }

my %CFG = (
    'K8S_DOMAIN'    => 'example.test',
    'K8S_ISSUER'    => 'issuer-test',
    'K8S_REGISTRY'  => 'reg.test/ns',
    'K8S_IMAGE_TAG' => 'vetev',
);
my %CTX = (%CFG, 'KUBE_CONTEXT' => 'ctx-test', 'FAKE_DIGEST' => $DIGEST);
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
($rc, $out, $err) = k8s({%CTX, 'K8S_HELM_ARGS' => '--set-string a=b --kube-context jiny'}, 'template', 'static');
is($rc, 2, 'prepinac --kube-context v K8S_HELM_ARGS: kod 2');
($rc, $out, $err) = k8s({%CTX}, 'logs', 'static', '-s', 'https://x');
is($rc, 2, 'logs -s (jiny server): kod 2');
is(scalar(cluster_calls()), 0, 'logs -s: kubectl se nevola');

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
ok(has_pair($up, '--set-string', "generic.pweImageTag=vetev\@$DIGEST"), 'deploy: tag image s digestem');
ok(has_pair($up, '--set-string', 'generic.pweRegistry=reg.test/ns'),  'deploy: registr image');
ok(has_pair($up, '--set-string', 'generic.pweDomain=example.test'),   'deploy: domena');
ok(has_pair($up, '--set-string', 'generic.pweIssuer=issuer-test'),    'deploy: issuer');
like($err, qr{nasazeno: https://pwe-static\.example\.test/}, 'deploy: hlaska s adresou webu');

($rc, $out, $err) = k8s({%CTX, 'K8S_PULL_REGISTRY' => 'proxy.test/hub/ns/', 'K8S_NAMESPACE' => 'jiny-ns'}, 'deploy', 'static');
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok(has_pair($up, '--set-string', 'generic.pweRegistry=proxy.test/hub/ns'), 'deploy: K8S_PULL_REGISTRY bez koncoveho lomitka');
ok(has_pair($up, '--namespace', 'jiny-ns'), 'deploy: K8S_NAMESPACE');

($rc, $out, $err) = k8s({%CTX, 'FAKE_DIGEST' => undef}, 'deploy', 'static');
is($rc, 2, 'deploy bez image v registru: kod 2');
like($err, qr/make k8s-image K8S=static.*K8S_ALLOW_TAG=1/s, 'deploy bez image: rada');
ok(!grep({ $_->[1] eq 'upgrade' } calls('helm')), 'deploy bez image: helm upgrade se nevola');
($rc, $out, $err) = k8s({%CTX, 'FAKE_DIGEST' => undef, 'K8S_ALLOW_TAG' => '1'}, 'deploy', 'static');
is($rc, 0, 'deploy bez image s K8S_ALLOW_TAG=1: kod 0');
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok(has_pair($up, '--set-string', 'generic.pweImageTag=vetev'), 'K8S_ALLOW_TAG=1: nasazeni jen podle tagu');
($rc, $out, $err) = k8s({%CTX, 'FAKE_DIGEST' => undef, 'K8S_IMAGE_TAG' => "v2\@$DIGEST"}, 'deploy', 'static');
is($rc, 0, 'deploy s tagem vcetne digestu: registr se neoveruje');
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok(has_pair($up, '--set-string', "generic.pweImageTag=v2\@$DIGEST"), 'deploy: tag s digestem beze zmeny');

($rc, $out, $err) = k8s({%CTX, 'K8S_HELM_ARGS' => '--set-string generic.pweNginxImage=proxy/nginx --set x=*'}, 'deploy', 'static');
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok(has_pair($up, '--set-string', 'generic.pweNginxImage=proxy/nginx'), 'K8S_HELM_ARGS se predaji helmu');
ok(has_pair($up, '--set', 'x=*'), 'K8S_HELM_ARGS: hvezdicka se nerozvine na soubory');

# ---------------------------------------------------------------------------------------------
# hesla (generic)
# ---------------------------------------------------------------------------------------------
unlink($SECRETS);
($rc, $out, $err) = k8s({%CTX}, 'deploy', 'generic', '--dry-run=server');
is($rc, 0, 'deploy --dry-run: kod 0');
ok(!-e $SECRETS, 'deploy --dry-run: hesla se nezakladaji');
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok(has_pair($up, '-f', "$REPO/kubernetes/secrets-generic.example.yml"), 'deploy --dry-run: pouzije se vzor hesel');

($rc, $out, $err) = k8s({%CTX, 'FAKE_HELM_STATUS_RC' => 0}, 'deploy', 'generic');
is($rc, 2, 'release existuje a soubor s hesly chybi: kod 2');
like($err, qr/get values pwe-generic/, 'chybejici hesla: rada, jak soubor obnovit');
ok(!-e $SECRETS, 'chybejici hesla u existujiciho releasu: nova se nevygeneruji');
($rc, $out, $err) = k8s({%CTX, 'FAKE_PVC' => 'data-pwe-generic-mariadb-0'}, 'deploy', 'generic');
is($rc, 2, 'svazek databaze existuje a soubor s hesly chybi: kod 2');
my ($pvcq) = grep { grep({ $_ eq 'persistentvolumeclaims' } @{$_}) } calls('kubectl');
ok($pvcq && has_pair($pvcq, '-l', 'app.kubernetes.io/instance=pwe-generic') && has_pair($pvcq, '--context', 'ctx-test'),
    'svazek se hleda podle stitku releasu a s --context');

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
($rc, $out, $err) = k8s({'FAKE_DIGEST' => $DIGEST, 'KUBE_CONTEXT' => 'ctx-z-prostredi'}, 'deploy', 'static');
($up) = grep { $_->[1] eq 'upgrade' } calls('helm');
ok(has_pair($up, '--kube-context', 'ctx-z-prostredi'), 'local.env: promenna prostredi ma prednost');
spit("$REPO/kubernetes/local.env", "1SPATNE=x\n");
($rc, $out, $err) = k8s({}, 'template', 'static');
is($rc, 2, 'local.env: neplatny nazev promenne se odmitne');
spit("$REPO/kubernetes/local.env", "X=\$(touch $T/pwned)\n");
($rc, $out, $err) = k8s({%CFG}, 'template', 'static');
ok(!-e "$T/pwned", 'local.env: hodnota se nespousti jako prikaz');
unlink("$REPO/kubernetes/local.env");

# ---------------------------------------------------------------------------------------------
# image
# ---------------------------------------------------------------------------------------------
($rc, $out, $err) = k8s({%CFG, 'FAKE_LOCAL_PLATFORMS' => 'linux/arm64'}, 'image', 'static');
is($rc, 2, 'image: mistni image enginu jen pro jinou platformu: kod 2');
like($err, qr/neni pro platformu linux\/amd64/, 'image: hlaska o platforme');
ok(!grep({ $_->[1] eq 'buildx' and $_->[2] eq 'build' } calls('docker')), 'image: pri spatne platforme se nestavi');

($rc, $out, $err) = k8s({%CFG, 'FAKE_LOCAL_PLATFORMS' => 'linux/arm64 linux/amd64', 'FAKE_DIGEST' => $DIGEST, 'PWE_IMAGE_TAG' => 'engine-tag'}, 'image', 'static');
is($rc, 0, 'image: mistni image enginu pro cilovou platformu: kod 0');
my ($bld) = grep { $_->[1] eq 'buildx' and $_->[2] eq 'build' } calls('docker');
ok($bld, 'image: docker buildx build');
ok(has_pair($bld, '--platform', 'linux/amd64'),   'image: vychozi platforma linux/amd64');
ok(has_pair($bld, '--builder', 'desktop-linux'),  'image: builder podle kontextu dockeru');
ok(has_pair($bld, '-t', 'reg.test/ns/pwe-example-static:vetev'), 'image: jmeno a tag image webu');
ok(has_pair($bld, '--build-arg', 'PWE_IMAGE_TAG=engine-tag'),   'image: tag enginu z PWE_IMAGE_TAG');
ok(has_pair($bld, '--build-arg', 'PWE_PROFILE=static'),         'image: profil z values');
ok(has_arg($bld, '--push'), 'image: --push');

($rc, $out, $err) = k8s({%CFG, 'PWE_IMAGE_TAG' => 'engine-tag'}, 'template', 'static');
($tpl) = calls('helm');
ok(has_pair($tpl, '--set-string', 'generic.pweImageTag=vetev'), 'tag webu nezavisi na PWE_IMAGE_TAG');
($rc, $out, $err) = k8s({%CFG, 'K8S_IMAGE_TAG' => "v1\@$DIGEST"}, 'image', 'static');
is($rc, 2, 'image s K8S_IMAGE_TAG vcetne digestu: kod 2');

# ---------------------------------------------------------------------------------------------
# status, logs, delete, test
# ---------------------------------------------------------------------------------------------
($rc, $out, $err) = k8s({%CTX, 'FAKE_PVC' => 'data-pwe-generic-mariadb-0', 'FAKE_TLS' => 'pwe-generic-web-tls'}, 'status', 'generic');
is($rc, 0, 'status: kod 0');
like($out, qr/data-pwe-generic-mariadb-0/, 'status: vypise svazek releasu');
like($out, qr/pwe-generic-web-tls True/, 'status: vypise certifikat podle jmena Secretu z ingressu');
ok(!grep({ !has_pair($_, '--context', 'ctx-test') } calls('kubectl')), 'status: kazdy kubectl s --context');

($rc, $out, $err) = k8s({%CTX}, 'logs', 'static', '-c', 'fcgi');
my ($lg) = calls('kubectl');
ok(has_pair($lg, '-c', 'fcgi') && !has_arg($lg, '--all-containers'), 'logs -c: bez --all-containers');
($rc, $out, $err) = k8s({%CTX}, 'logs', 'static');
($lg) = calls('kubectl');
ok(has_arg($lg, '--all-containers') && has_pair($lg, '--context', 'ctx-test'), 'logs: --all-containers a --context');

($rc, $out, $err) = k8s({%CTX, 'FAKE_PVC' => 'data-pwe-generic-mariadb-0', 'FAKE_TLS' => 'pwe-generic-web-tls'}, 'delete', 'generic');
is($rc, 0, 'delete: kod 0');
my ($un) = grep { $_->[1] eq 'uninstall' } calls('helm');
ok($un && has_pair($un, '--kube-context', 'ctx-test'), 'delete: helm uninstall s --kube-context');
like($out, qr/data-pwe-generic-mariadb-0/, 'delete: vypise zbyly svazek');
like($out, qr/pwe-generic-web-tls/, 'delete: vypise zbyly Secret s certifikatem');
ok(!grep({ $_->[2] eq 'delete' } calls('kubectl')), 'delete: sam nic dalsiho nemaze');

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
($rc, $out, $err) = k8s({'K8S_IMAGE_TAG' => 'x'}, 'test', 'host');
is($rc, 0, 'test s generic.pweHost: K8S_DOMAIN neni potreba');
ok(grep({ $_ eq 'https://www.mujweb.test/' } map { $_->[-1] } calls('curl')), 'test: adresa z generic.pweHost');

# ---------------------------------------------------------------------------------------------
# hesla a mistni nastaveni nesmeji do gitu ani do image
# ---------------------------------------------------------------------------------------------
foreach my $f ('.gitignore', '.dockerignore') {
    my $s = slurp("$REPOROOT/$f");
    like($s, qr{^kubernetes/local\.env$}m,                 "$f: kubernetes/local.env");
    like($s, qr{^kubernetes/secrets-\*\.yml$}m,            "$f: kubernetes/secrets-*.yml");
    like($s, qr{^!kubernetes/secrets-\*\.example\.yml$}m,  "$f: vzor secrets-*.example.yml je vyjimka");
}

done_testing();
