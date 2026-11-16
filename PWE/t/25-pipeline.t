#!/usr/bin/env perl
# Pipeline GitHub Actions (.github/workflows/images.yml a tests.yml) - pravidla usporadani image:
#   - 9 image = 9 cilu bake: zavislostni image (base mariadb mysql postgres debugger) a image vzorovych webu
#     (example-static example-mariadb example-mysql example-postgres); cil <cil> = image pwe-<cil>. Zrusene
#     image pwe a pwe-static se ve workflow nesmi objevit. Seznam BAKE_TARGETS = skupina default v docker-bake.hcl.
#   - krok Meta: kdo publikuje (vychozi vetev repozitare, promenna repozitare PUBLISH_BRANCHES), verze
#     z PWE/VERSION. Krok se spousti doopravdy: jeho skript se vyjme z YAML a pusti v bash s prostredim,
#     jake mu dava GitHub (udalost, typ a nazev ref, vychozi vetev, PUBLISH_BRANCHES).
#   - kroky s bake (Build linux/amd64, Build linux/arm64, Publish) se spousteji doopravdy s falesnym dockerem
#     a jq: vsechny tri stavi vsech 9 cilu se stejnymi promennymi pro docker-bake.hcl (REGISTRIES, VERSION,
#     SOURCE, REVISION, CREATED - zadny tag podle vetve), poruseni pravidla cilu a tagu build ukonci
#   - nastroje dostavaji tag = verze (PWE_TEST_IMAGE, PWE_IMAGE_TAG); testy enginu bezi v pwe-base
#   - pojistky publikace: prihlaseni a publikace jen po kroku Branch head (podminky kroku se vyhodnocuji,
#     gha_if), beh nad vetvi se nerusi (cancel-in-progress jen u pull requestu), krok Branch head (spousti se
#     doopravdy s falesnym gitem) nepublikuje pres novejsi hlavu vetve, kourove kontroly obou platforem maji
#     casovy limit, kroky jdou v danem poradi a zadny nema continue-on-error
#   - zdvojene behy push + pull_request se nededuplikuji: job nema podminku "if" (preskoceny job se v kontrolach
#     pull requestu pocita jako uspesny) a udalost pull_request neni omezena na typy ani cilove vetve
#   - vstupy image: on.push.paths = on.pull_request.paths = env IMAGE_PATHS, vcetne vzorovych webu a vseho,
#     co Dockerfile vzorovych webu kopiruji z korene repozitare
#   - tests.yml se s images.yml neprekryva a stavi jen pwe-base s VERSION z PWE/VERSION
# Test nic nestavi a k zadnemu registru se nepripojuje; potrebuje jen bash.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use lib "$FindBin::Bin/lib";
use PWE::TestEnv;

my $ROOT = PWE::TestEnv::root();    # koren enginu (PWE/)
my $REPO = dirname($ROOT);          # koren repozitare

sub slurp { my ($f) = @_; open(my $fh, '<', $f) or return ''; local $/; my $s = <$fh>; close($fh); return defined($s) ? $s : ''; }

my $WF    = slurp("$REPO/.github/workflows/images.yml");
my $TESTS = slurp("$REPO/.github/workflows/tests.yml");
plan skip_all => '.github/workflows neni k dispozici (engine bez korene repozitare)' unless (length($WF) && length($TESTS));
my ($BASH) = grep { -x $_ } map { "$_/bash" } grep { length } split(/:/, $ENV{'PATH'} || ''), '/bin', '/usr/bin';
plan skip_all => 'chybi bash' unless ($BASH);

# kontrakt usporadani image: cil bake <cil> = image pwe-<cil>
my @TARGETS = qw(base mariadb mysql postgres debugger example-static example-mariadb example-mysql example-postgres);

# step_names($wf) - nazvy kroku v poradi, v jakem jsou ve workflow
sub step_names { my ($wf) = @_; return ($wf =~ /^      - name: (.+)$/mg); }

# step_block($wf, $nazev) - text kroku od "- name: <nazev>" po dalsi krok (vcetne env a run)
sub step_block {
    my ($wf, $name) = @_;
    my ($body) = $wf =~ /^      - name: \Q$name\E\n(.*?)(?=^      - name: |\z)/ms;
    return defined($body) ? $body : '';
}

# step_run($wf, $nazev) - skript "run: |" kroku bez odsazeni YAML (prazdny retezec, kdyz krok skript nema)
sub step_run {
    my ($wf, $name) = @_;
    my ($run) = step_block($wf, $name) =~ /^        run: \|\n((?:(?: {10}.*)?\n)+)/m;
    return '' unless (defined($run));
    $run =~ s/^ {10}//mg;
    return $run;
}

# step_if($wf, $nazev) - podminka "if:" kroku (prazdny retezec, kdyz krok podminku nema)
sub step_if { my ($wf, $name) = @_; my ($if) = step_block($wf, $name) =~ /^        if: (.+)$/m; return defined($if) ? $if : ''; }

# step_env($wf, $nazev) - promenne z bloku "env:" kroku s hodnotami tak, jak jsou ve workflow
sub step_env {
    my ($wf, $name) = @_;
    my ($env) = step_block($wf, $name) =~ /^        env:\n((?:(?: {10}.*)?\n)+)/m;
    return map { /^ {10}([A-Za-z_][A-Za-z0-9_]*): (.*)$/ ? ($1 => $2) : () } split(/\n/, defined($env) ? $env : '');
}

# jobs_of($wf) - nazvy jobu workflow
sub jobs_of { my ($wf) = @_; my ($jobs) = $wf =~ /^jobs:\n(.*)\z/ms; return defined($jobs) ? ($jobs =~ /^  ([A-Za-z0-9_-]+):\s*$/mg) : (); }

# job_body($wf, $job) - text jobu (radky odsazene pod "<job>:")
sub job_body { my ($wf, $job) = @_; my ($body) = $wf =~ /^  \Q$job\E:\n((?:(?: {4}.*)?\n)+)/m; return defined($body) ? $body : ''; }

# job_keys($wf, $job) - klice jobu v poradi (name, runs-on, env, steps ...)
sub job_keys { my ($wf, $job) = @_; return (job_body($wf, $job) =~ /^    ([A-Za-z_-]+):/mg); }

# job_env($wf, $job) - promenne z bloku "env:" jobu
sub job_env {
    my ($wf, $job) = @_;
    my ($env) = job_body($wf, $job) =~ /^    env:\n((?:(?: {6}.*)?\n)+)/m;
    return map { /^ {6}([A-Za-z_][A-Za-z0-9_]*): (.*)$/ ? ($1 => $2) : () } split(/\n/, defined($env) ? $env : '');
}

# on_event($wf, $udalost) - text bloku on.<udalost>
sub on_event {
    my ($wf, $event) = @_;
    my ($on) = $wf =~ /^on:\n(.*?)^(?=\S)/ms;
    my ($ev) = defined($on) ? $on =~ /^  \Q$event\E:\n(.*?)(?=^  \S|\z)/ms : ();
    return defined($ev) ? $ev : '';
}

# on_list($wf, $udalost, $klic) - seznam z on.<udalost>.<klic> (paths, branches)
sub on_list {
    my ($wf, $event, $key) = @_;
    my ($list) = on_event($wf, $event) =~ /^    \Q$key\E:\n((?:      - .*\n)+)/m;
    return () unless (defined($list));
    return map { /^      - '(.*)'$/ ? $1 : $_ } split(/\n/, $list);
}

# on_keys($wf, $udalost) - klice on.<udalost> (paths, branches, types ...)
sub on_keys { my ($wf, $event) = @_; return (on_event($wf, $event) =~ /^    ([A-Za-z_-]+):/mg); }

# paths_of($wf, $udalost) - seznam cest z on.<udalost>.paths
sub paths_of { my ($wf, $event) = @_; return on_list($wf, $event, 'paths'); }

# bake_group($bake, $skupina) - cile skupiny v docker-bake.hcl; skupina uvedena ve skupine se rozvine
sub bake_group {
    my ($bake, $name, $seen) = @_;
    $seen ||= {};
    return () if ($seen->{$name}++);
    (my $code = $bake) =~ s/^\s*#.*\n//mg;
    my ($body) = $code =~ /^group\s+"\Q$name\E"\s*\{(.*?)\}/ms;
    my ($list) = defined($body) ? $body =~ /\btargets\s*=\s*\[(.*?)\]/s : ();
    return map { ($code =~ /^group\s+"\Q$_\E"\s*\{/m) ? bake_group($bake, $_, $seen) : $_ } (defined($list) ? ($list =~ /"([^"]+)"/g) : ());
}

# context_sources($dockerfile) - cesty kontextu sestaveni, ktere Dockerfile cte: zdroje COPY a ADD (bez --from,
# tedy ne z jine stage nebo image) a RUN --mount=type=bind bez from=
sub context_sources {
    my ($df) = @_;
    $df =~ s/\\\n//g;    # pokracovaci radky
    my @src;
    foreach my $line (split(/\n/, $df)) {
        if ($line =~ /^\s*(?:COPY|ADD)\s+(.*)$/i) {
            my @w = split(' ', $1);
            next if (grep { /^--from=/ } @w);
            @w = grep { !/^--/ } @w;
            pop(@w);    # posledni slovo je cil
            push(@src, @w);
        }
        while ($line =~ /--mount=(\S+)/g) {
            my %m = map { /^([^=]+)=(.*)$/ ? ($1 => $2) : ($_ => 1) } split(/,/, $1);
            next if ((defined($m{'type'}) ? $m{'type'} : 'bind') ne 'bind' || exists($m{'from'}));
            push(@src, defined($m{'source'}) ? $m{'source'} : defined($m{'src'}) ? $m{'src'} : '.');
        }
    }
    return map { (my $p = $_) =~ s{^\./}{}; $p =~ s{/+$}{}; $p } @src;
}

# gha_if($vyraz, \%kontext) - vyhodnoti podminku "if" tak, jak ji vyhodnoti GitHub Actions: 1 = krok (job) bezi,
# 0 = preskoci se, undef = vyraz obsahuje neco, co tato funkce neumi (pak je treba ji rozsirit).
# Umi jen to, co podminky workflow pouzivaji: porovnani == a != dvou hodnot, startsWith(), &&, || a zavorky;
# hodnota je retezec v apostrofech nebo cesta kontextu (steps.meta.outputs.publish ...), chybejici cesta je null.
# Retezce se porovnavaji bez ohledu na velikost pismen a null se chova jako prazdny retezec - pro vystupy
# kroku a nazvy udalosti je to totez, co dela GitHub (null != 'true' je pravda).
sub gha_if {
    my ($expr, $ctx) = @_;
    my @tok = $expr =~ /\G\s*(\|\||&&|==|!=|[(),]|'[^']*'|[A-Za-z_][A-Za-z0-9_.]*)/gc;
    return undef if (!@tok || $expr !~ /\G\s*\z/);
    my $i = 0;
    my $expect = sub { my ($want) = @_; my $t = $tok[$i++]; die "ceka se $want\n" unless (defined($t) && $t eq $want); };
    my $value = sub {
        my $t = $tok[$i++];
        die "ceka se hodnota\n" unless (defined($t));
        return $1 if ($t =~ /^'(.*)'$/);
        return $ctx->{$t} if ($t =~ /^[a-z]+\.[A-Za-z0-9_.]+$/);
        die "neznama hodnota $t\n";
    };
    my ($or, $and, $term);
    $term = sub {
        my $t = $tok[$i] // '';
        if ($t eq '(') {
            $i++;
            my $v = $or->();
            $expect->(')');
            return $v;
        }
        if ($t eq 'startsWith') {
            $i++;
            $expect->('(');
            my $str = $value->();
            $expect->(',');
            my $prefix = $value->();
            $expect->(')');
            return (index(lc($str // ''), lc($prefix // '')) == 0) ? 1 : 0;
        }
        my $left  = $value->();
        my $op    = $tok[$i++] // '';
        die "ceka se == nebo !=\n" unless ($op eq '==' || $op eq '!=');
        my $right = $value->();
        my $equal = (lc($left // '') eq lc($right // '')) ? 1 : 0;
        return ($op eq '==') ? $equal : 1 - $equal;
    };
    $and = sub { my $v = $term->(); while (($tok[$i] // '') eq '&&') { $i++; my $r = $term->(); $v = ($v && $r) ? 1 : 0; } return $v; };
    $or  = sub { my $v = $and->();  while (($tok[$i] // '') eq '||') { $i++; my $r = $and->();  $v = ($v || $r) ? 1 : 0; } return $v; };
    my $result = eval { my $v = $or->(); die "nadbytecny text\n" if ($i != scalar(@tok)); $v; };
    ($or, $and, $term) = ();
    return $result;
}

my $T = tempdir('pwe-pipeline-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $N = 0;

# run_script($skript, \%env, %volby) - pusti skript kroku v bash tak, jak ho pousti GitHub (shell: bash), v novem
# docasnem adresari a jen s prostredim z %env (+ PATH, GITHUB_OUTPUT = <adresar>/out, RUNNER_TEMP = <adresar>/tmp,
# FAKE_LOG = <adresar>/calls.log). Volby:
#   files => { cesta => obsah }    soubory pracovniho adresare (checkoutu)
#   dirs  => [ cesty ]             prazdne adresare pracovniho adresare
#   fakes => { program => skript } falesne programy; na PATH jsou pred skutecnymi
# Vraci (navratovy kod, log, adresar behu).
sub run_script {
    my ($script, $env, %o) = @_;
    my $dir = "$T/run" . (++$N);
    make_path("$dir/bin", "$dir/tmp", map { "$dir/$_" } @{$o{'dirs'} || []});
    my %files = (%{$o{'files'} || {}}, 'step.sh' => $script, 'out' => '', 'calls.log' => '');
    foreach my $f (keys %files) {
        make_path(dirname("$dir/$f"));
        open(my $fh, '>', "$dir/$f") or die "$dir/$f: $!"; print $fh $files{$f}; close($fh);
    }
    foreach my $p (keys %{$o{'fakes'} || {}}) {
        open(my $fh, '>', "$dir/bin/$p") or die "$dir/bin/$p: $!"; print $fh $o{'fakes'}->{$p}; close($fh);
        chmod(0755, "$dir/bin/$p");
    }
    my $log;
    {
        local %ENV = ('PATH' => "$dir/bin:$ENV{'PATH'}", 'GITHUB_OUTPUT' => "$dir/out", 'RUNNER_TEMP' => "$dir/tmp", 'FAKE_LOG' => "$dir/calls.log", %{$env});
        # stejne volby bash, s jakymi skript kroku pousti GitHub (shell: bash)
        $log = `cd '$dir' && '$BASH' --noprofile --norc -eo pipefail step.sh < /dev/null 2>&1`;
    }
    return ($? >> 8, $log, $dir);
}

# ---------------------------------------------------------------------------------------------
# usporadani: jeden job, kroky v danem poradi, 9 cilu bake = 9 image, zadny zruseny image
# ---------------------------------------------------------------------------------------------
is(join(' ', jobs_of($WF)),    'images', 'images.yml: jediny job images');
is(join(' ', jobs_of($TESTS)), 'tests',  'tests.yml: jediny job tests');
is(join(' | ', step_names($WF)),
    'Checkout | Meta | Set up QEMU | Set up Buildx | Base image digest | Expose GitHub runtime | Build (linux/amd64) | Engine tests (pwe-base)'
    . ' | Compile check (pwe-base) | Smoke checks (linux/amd64) | Branch head | Build (linux/arm64) | Smoke checks (linux/arm64) | Login to ghcr.io'
    . ' | Login to Docker Hub | Publish (linux/amd64, linux/arm64) | Summary',
    'images.yml: kroky v poradi sestaveni -> testy -> kourove kontroly -> Branch head -> arm64 -> prihlaseni -> publikace');
is(join(' | ', step_names($TESTS)), 'Checkout | Build pwe-base (linux/amd64) | Engine tests (pwe-base) | Compile check (pwe-base)', 'tests.yml: kroky sestaveni pwe-base -> testy -> kompilace');
unlike($WF . $TESTS, qr/continue-on-error/, 'workflow: zadny krok ani job nema continue-on-error (selhani testu nebo kontrol beh ukonci)');
# cizi akce jsou pripnute na SHA commitu (tag akce jde presunout na jiny kod), verze je v komentari pro Dependabot
foreach my $w (
    ['images.yml', $WF, 'actions/checkout docker/setup-qemu-action docker/setup-buildx-action crazy-max/ghaction-github-runtime docker/login-action docker/login-action'],
    ['tests.yml', $TESTS, 'actions/checkout'],
) {
    my ($file, $wf, $actions) = @{$w};
    my @uses = $wf =~ /^\s+(?:- )?uses: (.*)$/mg;
    is(join(' ', map { /^([^@\s]+)/ ? $1 : '?' } @uses), $actions, "$file: pouzite akce (nova cizi akce = vedome rozsireni tohoto seznamu)");
    is(join(' ', grep { !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.\/-]+\@[0-9a-f]{40} # v\d+\.\d+\.\d+$/ } @uses), '', "$file: kazda akce je pripnuta na SHA commitu s verzi v komentari");
}

my %JOB_ENV = job_env($WF, 'images');
is($JOB_ENV{'BAKE_TARGETS'} // '', join(' ', @TARGETS), 'images.yml: BAKE_TARGETS = 5 zavislostnich image a 4 image vzorovych webu');
is($JOB_ENV{'BAKE_FILE'} // '', 'docker-bake.hcl', 'images.yml: BAKE_FILE = docker-bake.hcl v koreni repozitare');
is(join(' ', sort(bake_group(slurp("$REPO/docker-bake.hcl"), 'default'))), join(' ', sort(@TARGETS)),
    'docker-bake.hcl: skupina default = cile z BAKE_TARGETS (image, ktery by ve workflow chybel, by se nepublikoval)');
# zrusene image: pwe (nosic enginu) a pwe-static - ani v komentarich; "pwe" jako cele slovo (ne pwe-base, pwe.ai)
unlike($WF . $TESTS, qr/pwe-static/, 'workflow: zruseny image pwe-static se nikde neuvadi');
unlike($WF . $TESTS, qr/(?<![\w.\/-])pwe(?![\w.-])|\/pwe(?![\w.-])/, 'workflow: zruseny image pwe (nosic enginu) se nikde neuvadi');

# ---------------------------------------------------------------------------------------------
# krok Meta: rozhodnuti o publikaci
# ---------------------------------------------------------------------------------------------
my $META = step_run($WF, 'Meta');
ok(length($META) > 200, 'images.yml: krok Meta ma skript');

# meta(%env) - pusti krok Meta v cistem prostredi; vraci (navratovy kod, vystupy kroku, log, adresar behu).
# Klic VERSION_FILE = obsah PWE/VERSION (vychozi "2.2.1\n"), ostatni klice jsou promenne prostredi.
# Pracovni adresar ma jako checkout i adresare docs a webapps: vzor v PUBLISH_BRANCHES se na ne nesmi rozvinout.
sub meta {
    my (%o) = @_;
    my $version = exists($o{'VERSION_FILE'}) ? delete($o{'VERSION_FILE'}) : "2.2.1\n";
    my ($rc, $log, $dir) = run_script($META, {
        'GITHUB_EVENT_NAME' => 'push', 'GITHUB_REF_TYPE' => 'branch', 'GITHUB_REF_NAME' => 'master',
        'GITHUB_REPOSITORY_OWNER' => 'kukam', 'GITHUB_REPOSITORY' => 'kukam/PWE', 'GITHUB_SERVER_URL' => 'https://github.com',
        'DEFAULT_BRANCH' => 'master', 'PUBLISH_BRANCHES' => '', 'DOCKERHUB_NAMESPACE' => '', 'DOCKERHUB_SECRETS' => 'false', %o,
    }, 'files' => {'PWE/VERSION' => $version}, 'dirs' => ['docs', 'webapps']);
    my %out = map { /^([a-z_]+)=(.*)$/ ? ($1 => $2) : () } split(/\n/, slurp("$dir/out"));
    return ($rc, \%out, $log, $dir);
}

my $DEFAULT = qr/vychozi vetvi repozitare$/;
my $LISTED  = qr/^vetev je v promenne repozitare PUBLISH_BRANCHES$/;
my $OTHER   = qr/^vetev neni vychozi vetvi repozitare ani neni v promenne repozitare PUBLISH_BRANCHES$/;
my $PR      = qr/^pull request nepublikuje nikdy$/;
my $TAG     = qr/^workflow bezi nad gitovym tagem, ne nad vetvi$/;
my $last_dir;
foreach my $c (
    ['push do vychozi vetve',                              'true',  qr/^vetev je vychozi vetvi repozitare$/, {}],
    ['push do vetve z PUBLISH_BRANCHES',                   'true',  $LISTED, {GITHUB_REF_NAME => 'pwe.ai', PUBLISH_BRANCHES => 'pwe.ai'}],
    ['push do jine vetve',                                 'false', $OTHER,  {GITHUB_REF_NAME => 'feature/kosik', PUBLISH_BRANCHES => 'pwe.ai'}],
    ['push do vetve, PUBLISH_BRANCHES prazdna',            'false', $OTHER,  {GITHUB_REF_NAME => 'pwe.ai'}],
    ['pull request',                                       'false', $PR,     {GITHUB_EVENT_NAME => 'pull_request', GITHUB_REF_NAME => '12/merge'}],
    ['pull request, ref v PUBLISH_BRANCHES',               'false', $PR,     {GITHUB_EVENT_NAME => 'pull_request', GITHUB_REF_NAME => '12/merge', PUBLISH_BRANCHES => '12/merge master'}],
    ['pull request s ref = vychozi vetev',                 'false', $PR,     {GITHUB_EVENT_NAME => 'pull_request'}],
    ['pull request s ref = vetev z PUBLISH_BRANCHES',      'false', $PR,     {GITHUB_EVENT_NAME => 'pull_request', GITHUB_REF_NAME => 'pwe.ai', PUBLISH_BRANCHES => 'pwe.ai'}],
    ['pull request z forku (udalost pull_request_target)', 'false', qr/^udalost pull_request_target nepublikuje$/, {GITHUB_EVENT_NAME => 'pull_request_target'}],
    ['rucni spusteni nad vychozi vetvi',                   'true',  $DEFAULT, {GITHUB_EVENT_NAME => 'workflow_dispatch'}],
    ['rucni spusteni nad jinou vetvi',                     'false', $OTHER,  {GITHUB_EVENT_NAME => 'workflow_dispatch', GITHUB_REF_NAME => 'pokus'}],
    ['rucni spusteni nad vetvi z PUBLISH_BRANCHES',        'true',  $LISTED, {GITHUB_EVENT_NAME => 'workflow_dispatch', GITHUB_REF_NAME => 'pwe.ai', PUBLISH_BRANCHES => 'pwe.ai'}],
    ['rucni spusteni nad gitovym tagem master',            'false', $TAG,    {GITHUB_EVENT_NAME => 'workflow_dispatch', GITHUB_REF_TYPE => 'tag'}],
    ['neznama udalost',                                    'false', qr/^udalost schedule nepublikuje$/, {GITHUB_EVENT_NAME => 'schedule'}],
    ['PUBLISH_BRANCHES s carkami',                         'true',  $LISTED, {GITHUB_REF_NAME => 'pwe.ai', PUBLISH_BRANCHES => 'a,pwe.ai,b'}],
    ['PUBLISH_BRANCHES s mezerami',                        'true',  $LISTED, {GITHUB_REF_NAME => 'pwe.ai', PUBLISH_BRANCHES => 'a pwe.ai b'}],
    ['PUBLISH_BRANCHES s carkou i mezerou a konci radku',  'true',  $LISTED, {GITHUB_REF_NAME => 'pwe.ai', PUBLISH_BRANCHES => " ,a,\r\n\tpwe.ai ,\nb"}],
    ['PUBLISH_BRANCHES jen z oddelovacu',                  'false', $OTHER,  {GITHUB_REF_NAME => 'pwe.ai', PUBLISH_BRANCHES => ' , ,, '}],
    ['nazev se porovnava presne (podretezec)',             'false', $OTHER,  {GITHUB_REF_NAME => 'pwe', PUBLISH_BRANCHES => 'pwe.ai xpwe'}],
    ['tecka neni zastupny znak',                           'false', $OTHER,  {GITHUB_REF_NAME => 'pwexai', PUBLISH_BRANCHES => 'pwe.ai'}],
    ['vzor v PUBLISH_BRANCHES neodpovida nicemu',          'false', $OTHER,  {GITHUB_REF_NAME => 'release/2.x', PUBLISH_BRANCHES => 'release/* *'}],
    ['vychozi vetev main, push do master',                 'false', $OTHER,  {DEFAULT_BRANCH => 'main'}],
    ['vychozi vetev neznama, vetev v PUBLISH_BRANCHES',    'true',  $LISTED, {DEFAULT_BRANCH => '', PUBLISH_BRANCHES => 'master'}],
    ['vychozi vetev neznama, seznam prazdny',              'false', $OTHER,  {DEFAULT_BRANCH => ''}],
    ['vzor se nerozvine na soubory checkoutu (set -f)',    'false', $OTHER,  {GITHUB_REF_NAME => 'docs', PUBLISH_BRANCHES => 'd* * [d]ocs ????'}],
    ['nazev vetve jako prikaz shellu',                    'false', $OTHER,  {GITHUB_REF_NAME => '$(touch pwned);`id`', PUBLISH_BRANCHES => 'pwe.ai'}],
) {
    my ($desc, $publish, $reason, $env) = @{$c};
    my ($rc, $out, $log, $dir) = meta(%{$env});
    is($rc, 0, "Meta ($desc): navratovy kod 0") or diag($log);
    is($out->{'publish'}, $publish, "Meta ($desc): publish=$publish") or diag($log);
    like($out->{'reason'} // '', $reason, "Meta ($desc): duvod");
    $last_dir = $dir;
}
ok(-d $last_dir && !-e "$last_dir/pwned", 'Meta: nazev vetve se nevykona');

{
    my ($rc, $out, $log) = meta();
    is(join(' ', map { "$_=" . ($out->{$_} // '?') } qw(version registries image_prefix source dockerhub)),
        'version=2.2.1 registries=ghcr.io/kukam image_prefix=ghcr.io/kukam source=https://github.com/kukam/PWE dockerhub=false',
        'Meta: verze z PWE/VERSION, registr ghcr.io/<vlastnik>, bez zrcadla');
    ok(!exists($out->{'tag'}), 'Meta: zadny vystup "tag" (tagy <verze> a latest urcuje docker-bake.hcl)');
    like($log, qr/^::notice title=Publikace::Po kontrolach se image publikuji s tagy 2\.2\.1 a latest - vetev je vychozi vetvi repozitare$/m, 'Meta: duvod publikace je v anotaci behu');
    ($rc, $out, $log) = meta('GITHUB_REF_NAME' => 'x', 'PUBLISH_BRANCHES' => 'a, b');
    like($log, qr/^PUBLISH_BRANCHES: a b$/m, 'Meta: log vypisuje nacteny seznam PUBLISH_BRANCHES');
    like($log, qr/^::notice title=Bez publikace::Image se jen sestavi a otestuji \(linux\/amd64\) - vetev neni vychozi/m, 'Meta: duvod, proc se nepublikuje, je v anotaci behu');
    ($rc, $out, $log) = meta('GITHUB_REF_NAME' => 'x', 'PUBLISH_BRANCHES' => 'release/*');
    like($log, qr/^::warning::Promenna repozitare PUBLISH_BRANCHES obsahuje vzor \(release\/\*\)/m, 'Meta: vzor v PUBLISH_BRANCHES = varovani');
    ($rc, $out, $log) = meta('GITHUB_REPOSITORY_OWNER' => 'KuKam', 'DOCKERHUB_NAMESPACE' => 'Kukam', 'DOCKERHUB_SECRETS' => 'true');
    is("$out->{'registries'} $out->{'dockerhub'}", 'ghcr.io/kukam,docker.io/kukam true', 'Meta: zrcadlo na Docker Hub pri publikaci (jmena malymi pismeny)');
    ($rc, $out, $log) = meta('GITHUB_REF_NAME' => 'x', 'DOCKERHUB_NAMESPACE' => 'kukam', 'DOCKERHUB_SECRETS' => 'true');
    is("$out->{'registries'} $out->{'dockerhub'}", 'ghcr.io/kukam false', 'Meta: beh, ktery nepublikuje, zrcadlo nepouzije');
    foreach my $bad ("2.2\n", "v2.2.1\n", "2.2.1-rc1\n", "latest\n", "\n", "2.2.1\n9.9.9\n") {
        (my $show = $bad) =~ s/\n/\\n/g;
        ($rc, $out, $log) = meta('VERSION_FILE' => $bad);
        ok($rc != 0 && !%{$out} && $log =~ /^::error file=PWE\/VERSION::PWE\/VERSION nema tvar X\.Y\.Z/m, "Meta: PWE/VERSION '$show' = chyba, zadny vystup") or diag($log);
    }
    ($rc, $out, $log) = meta('VERSION_FILE' => "  10.20.30\r\n");
    is("$rc $out->{'version'}", '0 10.20.30', 'Meta: PWE/VERSION s mezerami a CRLF');
}
unlike($META, qr/pwe_image_tag_sanitize|pwe_image_branch|ls-remote/, 'Meta: zadny prevod vetve na tag ani kontrola kolize tagu vetvi');

# ---------------------------------------------------------------------------------------------
# bake a nastroje: verze misto tagu vetve, vsechna volani bake se stejnymi promennymi
# ---------------------------------------------------------------------------------------------
my @bake_steps = grep { step_block($WF, $_) =~ /^\s*docker buildx bake /m } step_names($WF);
is(join(' | ', @bake_steps), 'Build (linux/amd64) | Build (linux/arm64) | Publish (linux/amd64, linux/arm64)', 'images.yml: tri kroky s bake');
my %BAKE_ENV;    # krok => promenne kroku
foreach my $step (@bake_steps) {
    my %env = step_env($WF, $step);
    $BAKE_ENV{$step} = \%env;
    # LOCAL_REGISTRY (jen build linux/arm64) neni promenna pro bake - je to jmeno, pod kterym se image nacitaji
    is(join(' ', grep { $_ ne 'LOCAL_REGISTRY' } sort keys %env), 'CREATED NO_CACHE REGISTRIES REVISION SOURCE UBUNTU_IMAGE VERSION', "images.yml ($step): promenne pro bake - zadny TAG");
    is($env{'VERSION'}, '${{ steps.meta.outputs.version }}', "images.yml ($step): VERSION z kroku Meta");
    # Stejne hodnoty ve vsech trech krocich: docker-bake.hcl z nich odvozuje i argumenty sestaveni image
    # vzorovych webu (registr v jejich FROM a v popisku base.name). S jinou hodnotou by krok Publish vrstvy
    # nenasel v cache, sestavil by je znovu a nahral image, ktere neprosly kourovymi kontrolami.
    is(join(' | ', map { "$_=" . ($env{$_} // '') } qw(REGISTRIES SOURCE REVISION CREATED UBUNTU_IMAGE NO_CACHE)),
        'REGISTRIES=${{ steps.meta.outputs.registries }} | SOURCE=${{ steps.meta.outputs.source }} | REVISION=${{ github.sha }}'
        . ' | CREATED=${{ steps.meta.outputs.created }} | UBUNTU_IMAGE=${{ steps.base.outputs.image }} | NO_CACHE=${{ inputs.no_cache }}',
        "images.yml ($step): registry, zdroj, commit, cas a zakladni image z kroku Meta a Base image digest - stejne ve vsech volanich bake");
}
unlike($WF, qr/steps\.meta\.outputs\.tag\b/, 'images.yml: vystup "tag" kroku Meta nikdo necte');
is(scalar(() = $WF =~ /^ {10}PWE_TEST_IMAGE: \$\{\{ steps\.meta\.outputs\.image_prefix \}\}\/pwe-base:\$\{\{ steps\.meta\.outputs\.version \}\}$/mg), 2, 'images.yml: testy a kompilace v pwe-base:<verze>');
is(join(' | ', map { step_run($WF, $_) || (step_block($WF, $_) =~ /^        run: (.+)$/m)[0] } 'Engine tests (pwe-base)', 'Compile check (pwe-base)'),
    'bash PWE/tools/run-tests.sh | bash PWE/tools/perl-compile.sh', 'images.yml: testy enginu a kompilace pousti nastroje nad checkoutem (engine v pwe-base neni)');
is(scalar(() = $WF =~ /^ {10}PWE_IMAGE_TAG: \$\{\{ steps\.meta\.outputs\.version \}\}$/mg), 2, 'images.yml: kourove kontroly obou platforem s tagem = verze');
# linux/arm64 se sestavuje a kontroluje pod jmenem, ktere existuje jen na runneru (neprepise otestovane image
# linux/amd64); kourove kontroly kazde platformy berou image z buildu teze platformy
is($BAKE_ENV{'Build (linux/arm64)'}->{'LOCAL_REGISTRY'} // '', 'localhost/pwe-arm64', 'images.yml: build linux/arm64 se nacita pod mistnim jmenem localhost/pwe-arm64');
like(step_block($WF, 'Smoke checks (linux/arm64)'), qr/^          PWE_IMAGE_REGISTRY: localhost\/pwe-arm64$/m, 'images.yml: kourove kontroly linux/arm64 nad image z buildu linux/arm64');
like(step_block($WF, 'Smoke checks (linux/amd64)'), qr/^          PWE_IMAGE_REGISTRY: \$\{\{ steps\.meta\.outputs\.image_prefix \}\}$/m, 'images.yml: kourove kontroly linux/amd64 nad image z buildu linux/amd64');
# kourove kontroly bez jmen image = vsech 9 image (seznam ma PWE/tools/smoke-images.sh)
is(join(' | ', map { /^\s*(?:run: )?(bash PWE\/tools\/smoke-images\.sh .*)$/ ? $1 : () } split(/\n/, $WF)),
    'bash PWE/tools/smoke-images.sh --platform linux/amd64 --pull never --tree | bash PWE/tools/smoke-images.sh --platform linux/arm64 --pull never --tree',
    'images.yml: kourove kontroly obou platforem nad vsemi image (zadny vyber jmen), jen z mistniho Dockeru, se srovnanim s checkoutem');
# pravidlo cilu a tagu kontroluje skutecny jq az na runneru (v image nastroju jq neni) - tady aspon jeho zneni
my $BUILD = step_run($WF, 'Build (linux/amd64)');
like($BUILD, qr/\(\.target \| keys\) == \(\$targets \| split\(" "\) \| map\(select\(\. != ""\)\) \| sort\)/, 'images.yml: build kontroluje, ze bake stavi prave cile z BAKE_TARGETS');
like($BUILD, qr/\(\(\.value\.tags \/\/ \[\]\) \| sort\)\s+== \(\$r \| map\(\. \+ "\/pwe-" \+ \$t \+ ":" \+ \$version, \. \+ "\/pwe-" \+ \$t \+ ":latest"\) \| sort\)/,
    'images.yml: build kontroluje pravidlo cil <cil> = image pwe-<cil> s tagy <verze> + latest v kazdem registru');
is(join(' | ', grep { step_if($WF, $_) =~ /steps\.head\.outputs\.publish/ } step_names($WF)),
    'Build (linux/arm64) | Smoke checks (linux/arm64) | Login to ghcr.io | Login to Docker Hub | Publish (linux/amd64, linux/arm64)',
    'images.yml: arm64, prihlaseni a publikace jen po kroku Branch head');
like(step_block($WF, 'Branch head'), qr/^        if: steps\.meta\.outputs\.publish == 'true'$/m, 'images.yml: Branch head jen u behu, ktery smi publikovat');

# Kroky s bake se spousteji doopravdy, jen s falesnym dockerem a jq na PATH (nic se nestavi, v image nastroju
# neni docker ani jq): docker zapisuje sva volani a u "buildx bake" i promenne, ktere cte docker-bake.hcl.
my $FAKE_DOCKER = <<'FAKE';
#!/bin/bash
if [ "${1-} ${2-}" = "buildx bake" ]; then
    printf 'bake-env %s|%s|%s|%s|%s\n' "${REGISTRIES-}" "${VERSION-}" "${SOURCE-}" "${REVISION-}" "${CREATED-}" >> "$FAKE_LOG"
fi
printf '%s\n' "$*" >> "$FAKE_LOG"
case "${1-} ${2-}" in
    'buildx bake')   case " $* " in *' --print '*) echo '{}' ;; esac ;;
    'image inspect') echo 'popisek-z-image' ;;
esac
exit 0
FAKE
# jq: kontrola pravidla cilu a tagu (jq -e) konci kodem FAKE_JQ_RULE_RC, dotaz na cil (--arg t <cil>) vypise
# jmeno jeho image, ostatni dotazy nevypisuji nic
my $FAKE_JQ = <<'FAKE';
#!/bin/bash
[ -t 0 ] || cat > /dev/null
case "${1-}" in
    -e) exit "${FAKE_JQ_RULE_RC:-0}" ;;
esac
if [ "${2-}" = "--arg" ] && [ "${3-}" = "t" ]; then
    printf 'fake.local/pwe-%s:0.0.0\n' "$4"
fi
exit 0
FAKE

# hodnoty vyrazu ${{ ... }} v env kroku pro prehrani (jako u behu, ktery publikuje)
my $SHA   = 'a' x 40;
my $NEWER = 'b' x 40;
my $UBUNTU = 'ubuntu:26.04@sha256:' . ('d' x 64);
my %EXPR = (
    'steps.meta.outputs.registries' => 'ghcr.io/kukam,docker.io/kukam', 'steps.meta.outputs.version' => '2.2.1',
    'steps.meta.outputs.source' => 'https://github.com/kukam/PWE', 'steps.meta.outputs.created' => '2026-11-16T12:00:00Z',
    'steps.base.outputs.image' => $UBUNTU, 'github.sha' => $SHA, 'inputs.no_cache' => 'false',
);
my @UNKNOWN_EXPR;

# bake_step($workflow, $job, $krok, %env) - prehraje krok s bake; vraci (navratovy kod, log, volani "docker buildx bake").
# Prostredi = env jobu + env kroku (vyrazy nahrazeny hodnotami z %EXPR) + %env.
# Volani: { mode => print|load|push, targets => [cile], set => { klic => [hodnoty --set] }, opts => [ostatni volby], env => promenne bake }
sub bake_step {
    my ($wf, $job, $step, %o) = @_;
    my %env = (job_env($wf, $job), step_env($wf, $step));
    foreach my $k (keys %env) {
        $env{$k} =~ s/\$\{\{\s*(.*?)\s*\}\}/exists($EXPR{$1}) ? $EXPR{$1} : do { push(@UNKNOWN_EXPR, "$step: $1"); '' }/ge;
    }
    my ($rc, $log, $dir) = run_script(step_run($wf, $step), {%env, %o}, 'fakes' => {'docker' => $FAKE_DOCKER, 'jq' => $FAKE_JQ}, 'files' => {'PWE/VERSION' => "2.2.1\n"});
    my (@calls, $bake_env);
    foreach my $line (split(/\n/, slurp("$dir/calls.log"))) {
        if ($line =~ /^bake-env (.*)$/) { $bake_env = $1; next; }
        next unless ($line =~ /^buildx bake (.*)$/);
        my @a = split(' ', $1);
        my %c = ('mode' => '', 'targets' => [], 'set' => {}, 'opts' => [], 'env' => $bake_env);
        while (@a) {
            my $x = shift(@a);
            if ($x eq '--set') { my ($k, $v) = split(/=/, shift(@a) // '', 2); push(@{$c{'set'}->{$k}}, $v); }
            elsif ($x eq '-f' || $x eq '--metadata-file') { push(@{$c{'opts'}}, $x); shift(@a); }
            elsif ($x =~ /^--(print|load|push)$/) { $c{'mode'} .= $1; }
            elsif ($x =~ /^-/) { push(@{$c{'opts'}}, $x); }
            else { push(@{$c{'targets'}}, $x); }
        }
        push(@calls, \%c);
    }
    return ($rc, $log, \@calls);
}
# set_of($volani, $klic) - hodnoty --set <klic>=... jednoho volani bake, oddelene " | "
sub set_of { my ($call, $key) = @_; return join(' | ', @{$call->{'set'}->{$key} || []}); }

my %BUILT;    # krok => volani bake, ktere stavi
foreach my $s (
    ['Build (linux/amd64)',                'load', 'linux/amd64',             ['amd64'],          1],
    ['Build (linux/arm64)',                'load', 'linux/arm64',             ['arm64'],          1],
    ['Publish (linux/amd64, linux/arm64)', 'push', 'linux/amd64,linux/arm64', ['amd64', 'arm64'], 0],
) {
    my ($step, $mode, $platform, $scopes, $writes_cache) = @{$s};
    my ($rc, $log, $calls) = bake_step($WF, 'images', $step);
    is($rc, 0, "$step: prehrani kroku skonci kodem 0") or diag($log);
    my @build = grep { $_->{'mode'} ne 'print' } @{$calls};
    is(join(' ', map { $_->{'mode'} } @build), $mode, "$step: jedine volani bake, ktere stavi (--$mode)");
    my $b = $BUILT{$step} = $build[0] || {'targets' => [], 'set' => {}, 'opts' => [], 'env' => ''};
    is(join(' ', @{$b->{'targets'}}), join(' ', @TARGETS), "$step: stavi vsech 9 cilu (5 zavislostnich image a 4 image vzorovych webu)");
    is(set_of($b, '*.platform'), $platform, "$step: platforma $platform");
    is(set_of($b, '*.args.UBUNTU_IMAGE'), $UBUNTU, "$step: zakladni image pripnuty na digest");
    is(join(' ', sort @{$b->{'opts'}}), join(' ', sort('-f', '--provenance=false', '--sbom=false', ($mode eq 'push') ? '--metadata-file' : ())), "$step: bez atestaci, definice z BAKE_FILE");
    my @bad_from = grep { my $t = $_; set_of($b, "$t.cache-from") ne join(' | ', map { "type=gha,scope=images-$t-$_" } @{$scopes}) } @TARGETS;
    is("@bad_from", '', "$step: kazdy cil cte cache scope images-<cil>-<platforma> (" . join(', ', @{$scopes}) . ')');
    my @bad_to = grep { my $t = $_; set_of($b, "$t.cache-to") ne ($writes_cache ? "type=gha,mode=max,scope=images-$t-$scopes->[0],ignore-error=true" : '') } @TARGETS;
    is("@bad_to", '', "$step: " . ($writes_cache ? 'kazdy cil zapisuje cache sve platformy' : 'cache se jen cte'));
    # tataz konfigurace jako stavejici volani ma i vypis (--print): z nej se bere seznam image a kontroluji tagy
    my ($print) = grep { $_->{'mode'} eq 'print' } @{$calls};
    is(join(' ', @{($print || {})->{'targets'} || []}), join(' ', @TARGETS), "$step: vypis konfigurace (--print) nad stejnymi cili");
}
is(join(' ', @UNKNOWN_EXPR), '', 'images.yml: env kroku s bake pouziva jen zname vyrazy (jinak je treba doplnit %EXPR v testu)');
{
    my @env = map { $BUILT{$_}->{'env'} // '' } @bake_steps;
    is(scalar(grep { $_ ne $env[0] } @env), 0, 'images.yml: vsechna tri volani bake dostavaji stejne REGISTRIES, VERSION, SOURCE, REVISION a CREATED') or diag(join("\n", @env));
    is($env[0], "ghcr.io/kukam,docker.io/kukam|2.2.1|https://github.com/kukam/PWE|$SHA|2026-11-16T12:00:00Z", 'images.yml: bake dostava registry (i zrcadlo), verzi, zdroj, commit a cas z kroku Meta');
    # tagy: linux/amd64 a Publish je nechavaji na docker-bake.hcl, linux/arm64 je prepisuje jen na mistni jmeno
    my $amd64 = $BUILT{'Build (linux/amd64)'};
    my $arm64 = $BUILT{'Build (linux/arm64)'};
    my $push  = $BUILT{'Publish (linux/amd64, linux/arm64)'};
    is(join(' ', grep { /\.tags$/ } map { keys %{$_->{'set'}} } $amd64, $push), '', 'images.yml: build linux/amd64 a Publish tagy neprepisuji (urcuje je docker-bake.hcl)');
    my @bad = grep { my $t = $_; set_of($arm64, "$t.tags") ne "localhost/pwe-arm64/pwe-$t:2.2.1 | localhost/pwe-arm64/pwe-$t:latest" } @TARGETS;
    is("@bad", '', 'images.yml: build linux/arm64 nacita cil <cil> jako localhost/pwe-arm64/pwe-<cil>:<verze> a :latest') or diag(join("\n", map { "$_: " . set_of($arm64, "$_.tags") } @bad));
    is(join(' ', grep { /\.(?:tags|annotations|output)$/ } keys %{$amd64->{'set'}}), '', 'images.yml: build linux/amd64 nic nepublikuje (zadny output ani anotace)');
    # anotace indexu ma kazdy publikovany image - zdroj z kroku Meta, licence a popis z popisku otestovaneho image
    my $want = join(' | ', "index:org.opencontainers.image.source=https://github.com/kukam/PWE", map { "index:org.opencontainers.image.$_=popisek-z-image" } qw(licenses description));
    @bad = grep { set_of($push, "$_.annotations") ne $want } @TARGETS;
    is("@bad", '', 'images.yml: Publish dava indexu kazdeho z 9 image anotace source, licenses a description') or diag(join("\n", map { "$_: " . set_of($push, "$_.annotations") } @bad));
}
{
    # poruseni pravidla cilu a tagu (jq -e konci nenulou) build ukonci driv, nez se cokoli sestavi
    my ($rc, $log, $calls) = bake_step($WF, 'images', 'Build (linux/amd64)', 'FAKE_JQ_RULE_RC' => 1);
    ok($rc != 0 && $log =~ /^::error file=docker-bake\.hcl::Cile nebo tagy neodpovidaji pravidlu/m, 'Build (linux/amd64): poruseni pravidla cilu a tagu = chyba') or diag("rc=$rc\n$log");
    is(join(' ', map { $_->{'mode'} } @{$calls}), 'print', 'Build (linux/amd64): po poruseni pravidla se nic nestavi (jen vypis konfigurace)');
    # no_cache=true cache necte v zadnem volani, jen ji obnovi
    foreach my $step (@bake_steps) {
        ($rc, $log, $calls) = bake_step($WF, 'images', $step, 'NO_CACHE' => 'true');
        my ($b) = grep { $_->{'mode'} ne 'print' } @{$calls};
        is("$rc " . join(' ', grep { /\.cache-from$/ } keys %{($b || {})->{'set'} || {}}), '0 ', "$step: no_cache=true cache necte");
    }
    # bez pripnuteho zakladu (krok Base image digest nedal vystup) se nestavi
    foreach my $step (@bake_steps) {
        ($rc, $log, $calls) = bake_step($WF, 'images', $step, 'UBUNTU_IMAGE' => '');
        ok($rc != 0 && !@{$calls}, "$step: bez pripnuteho zakladniho image krok konci chybou a bake se nevola") or diag("rc=$rc\n$log");
    }
}
# publikuje jen krok Publish: nikde jinde neni --push ani zapis do registru
is(join(' | ', grep { step_block($WF, $_) =~ /--push\b|type=registry|docker push|imagetools create/ } step_names($WF)), 'Publish (linux/amd64, linux/arm64)', 'images.yml: do registru nahrava jen krok Publish');

# ---------------------------------------------------------------------------------------------
# pojistky publikace: beh nad vetvi se nerusi, Branch head nepublikuje pres novejsi hlavu, casove limity
# ---------------------------------------------------------------------------------------------
like($WF, qr/^concurrency:\n  group: images-\$\{\{ github\.ref \}\}\n  cancel-in-progress: \$\{\{ github\.event_name == 'pull_request' \}\}$/m, 'images.yml: beh nad vetvi se nerusi (zruseny publikujici beh by v registru nechal smes image)');
my $HEAD = step_run($WF, 'Branch head');
like($HEAD, qr/elif \[ "\$rc" -eq 1 \]; then\n[^\n]*Hlava vetve \$head meni vstupy image[^\n]*\n\s+publish=false\n/, 'images.yml: Branch head nepublikuje, kdyz novejsi hlava meni vstupy image');
like($HEAD, qr/elif \[ -z "\$head" \]; then\n[^\n]*Vetev uz v repozitari neni[^\n]*\n\s+publish=false\n/, 'images.yml: Branch head nepublikuje, kdyz vetev zanikla');

# Krok Branch head se spousti doopravdy (jako krok Meta), jen s falesnym gitem na PATH: ls-remote vypise
# FAKE_HEADS a skonci FAKE_LS_RC, fetch skonci FAKE_FETCH_RC, diff FAKE_DIFF_RC; volani se zapisuji do logu.
# Textove kontroly vyse hlidaji jen prirazeni publish=false - ne to, ze se hodnota dostane do vystupu kroku.
my $FAKE_GIT = <<'FAKE';
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$1" in
    ls-remote) printf '%b' "${FAKE_HEADS:-}"; exit "${FAKE_LS_RC:-0}" ;;
    fetch)     exit "${FAKE_FETCH_RC:-0}" ;;
    diff)      case "$*" in *smoke-images.sh*) exit "${FAKE_DIFF_EXTRA_RC:-${FAKE_DIFF_RC:-0}}" ;; esac; exit "${FAKE_DIFF_RC:-0}" ;;
esac
exit 99
FAKE
# branch_head(%env) - vraci (navratovy kod, vystup publish, log, volani gitu)
sub branch_head {
    my (%o) = @_;
    my ($rc, $log, $dir) = run_script($HEAD, {
        'GITHUB_REF_NAME' => 'pwe.ai', 'GITHUB_SHA' => $SHA, 'GITHUB_SERVER_URL' => 'https://github.com',
        'IMAGE_PATHS' => 'PWE docker-bake.hcl', 'GH_TOKEN' => 'tajny-token', %o,
    }, 'fakes' => {'git' => $FAKE_GIT});
    my ($publish) = slurp("$dir/out") =~ /^publish=(.*)$/m;
    return ($rc, $publish // '', $log, slurp("$dir/calls.log"));
}
foreach my $c (
    ['commit je hlavou vetve',                      0, 'true',  qr/je hlavou vetve/,              {FAKE_HEADS => "$SHA\\trefs/heads/pwe.ai\\n"}],
    ['vetev zanikla',                               0, 'false', qr/Vetev uz v repozitari neni/,   {FAKE_HEADS => ''}],
    ['jen vetev se stejnym koncem jmena',           0, 'false', qr/Vetev uz v repozitari neni/,   {FAKE_HEADS => "$NEWER\\trefs/heads/x/pwe.ai\\n"}],
    ['novejsi hlava meni vstupy image',             0, 'false', qr/meni vstupy image/,            {FAKE_HEADS => "$NEWER\\trefs/heads/pwe.ai\\n", FAKE_DIFF_RC => 1}],
    ['novejsi hlava se lisi jen mimo vstupy image', 0, 'true',  qr/lisi jen mimo vstupy image/,   {FAKE_HEADS => "$NEWER\\trefs/heads/pwe.ai\\n", FAKE_DIFF_RC => 0}],
    ['novejsi hlavu nejde stahnout',                0, 'true',  qr/^::warning::Rozdil vstupu image/m, {FAKE_HEADS => "$NEWER\\trefs/heads/pwe.ai\\n", FAKE_FETCH_RC => 128, FAKE_DIFF_RC => 1}],
    ['git diff selze',                              0, 'true',  qr/^::warning::Rozdil vstupu image/m, {FAKE_HEADS => "$NEWER\\trefs/heads/pwe.ai\\n", FAKE_DIFF_RC => 129}],
    ['git ls-remote selze',                         0, 'true',  qr/^::warning::Hlavu vetve se nepodarilo overit \(git ls-remote selhal\)/m, {FAKE_LS_RC => 128}],
    ['necekany vystup git ls-remote',               0, 'true',  qr/^::warning::Hlavu vetve se nepodarilo overit \(necekany vystup/m, {FAKE_HEADS => "nesmysl\\trefs/heads/pwe.ai\\n"}],
) {
    my ($desc, $want_rc, $want, $msg, $env) = @{$c};
    my ($rc, $publish, $log, $calls) = branch_head(%{$env});
    is("$rc $publish", "$want_rc $want", "Branch head ($desc): publish=$want") or diag($log);
    like($log, $msg, "Branch head ($desc): hlaska");
    unlike($log, qr/tajny-token/, "Branch head ($desc): token neni v logu");
}
{
    my ($rc, $publish, $log, $calls) = branch_head('FAKE_HEADS' => "$NEWER\\trefs/heads/pwe.ai\\n", 'FAKE_DIFF_RC' => 1);
    like($calls, qr/^ls-remote --heads origin refs\/heads\/pwe\.ai$/m, 'Branch head: hlava se cte presnym jmenem vetve');
    like($calls, qr/^diff --quiet $SHA $NEWER -- PWE docker-bake\.hcl$/m, 'Branch head: git diff srovnava commit behu s hlavou vetve jen v cestach z IMAGE_PATHS');
    ($rc, $publish, $log, $calls) = branch_head('FAKE_HEADS' => "$SHA\\trefs/heads/pwe.ai\\n");
    unlike($calls, qr/^(?:fetch|diff)/m, 'Branch head: je-li commit hlavou vetve, nic se nestahuje ani nesrovnava');
    ($rc, $publish, $log, $calls) = branch_head('FAKE_HEADS' => "$NEWER\\trefs/heads/pwe.ai\\n", 'FAKE_DIFF_RC' => 1, 'IMAGE_PATHS' => '');
    ok($rc != 0 && $publish eq '', 'Branch head: prazdny IMAGE_PATHS = chyba, zadny vystup (nesrovnava se cely strom)') or diag($log);
}

# kourove kontroly spousteji vychozi prikaz image (engine): kdyby neskoncil, krok bez limitu visi az do limitu jobu
my ($job_limit)   = $WF =~ /^    timeout-minutes: (\d+)$/m;
my ($smoke_amd64) = step_block($WF, 'Smoke checks (linux/amd64)') =~ /^        timeout-minutes: (\d+)$/m;
my ($smoke_arm64) = step_block($WF, 'Smoke checks (linux/arm64)') =~ /^        timeout-minutes: (\d+)$/m;
ok(defined($smoke_arm64) && $smoke_arm64 > 0 && $smoke_arm64 < ($job_limit // 0), 'images.yml: kourove kontroly linux/arm64 maji casovy limit kratsi nez limit jobu');
ok(defined($smoke_amd64) && $smoke_amd64 > 0 && $smoke_amd64 <= ($smoke_arm64 // 0), 'images.yml: kourove kontroly linux/amd64 maji casovy limit (nejvys jako emulovane linux/arm64)');

# ---------------------------------------------------------------------------------------------
# kdo se smi prihlasit a publikovat: podminky kroku se vyhodnocuji (gha_if), neporovnava se jen jejich text.
# Pull request (krok Meta da publish=false, Branch head se preskoci) nesmi dojit k prihlaseni ani k publikaci.
# ---------------------------------------------------------------------------------------------
# nejdriv vyhodnocovani samo: test podminek workflow nesmi projit jen proto, ze gha_if pocita spatne
my @GHA = (
    ["github.event_name == 'push'",                              {'github.event_name' => 'push'},          1],
    ["github.event_name != 'push'",                              {'github.event_name' => 'push'},          0],
    ["github.event_name == 'push'",                              {'github.event_name' => 'Push'},          1],    # bez ohledu na velikost pismen
    ["github.head_ref != 'x' && github.head_ref == ''",          {},                                       1],    # chybejici hodnota = null
    ["steps.head.outputs.publish == 'true'",                     {},                                       0],    # vystup preskoceneho kroku = null
    ["startsWith(github.head_ref, 'dependabot/')",               {'github.head_ref' => 'Dependabot/npm'},  1],
    ["startsWith(github.head_ref, 'dependabot/')",               {'github.head_ref' => 'moje/dependabot/'}, 0],
    ["github.a == 'x' || github.b == 'y' && github.c == 'z'",    {'github.a' => 'x'},                      1],    # && ma prednost pred ||
    ["(github.a == 'x' || github.b == 'y') && github.c == 'z'",  {'github.a' => 'x'},                      0],
);
is(join(' ', map { gha_if($_->[0], $_->[1]) // '?' } @GHA), join(' ', map { $_->[2] } @GHA), 'gha_if: ==, !=, &&, ||, zavorky, startsWith, null a velikost pismen');
is(join(' ', map { defined(gha_if($_, {})) ? 'ano' : 'ne' } "!cancelled()", "contains(github.ref, 'x')", "github.ref == 'x' ||", "github.ref", "always()", "github.ref == 'x' github.ref == 'x'", ''),
    'ne ne ne ne ne ne ne', 'gha_if: neznamy nebo neuplny vyraz nevyhodnocuje (undef)');

my @publishing = grep { step_block($WF, $_) =~ /docker\/login-action|--push\b/ } step_names($WF);
is(join(' | ', @publishing), 'Login to ghcr.io | Login to Docker Hub | Publish (linux/amd64, linux/arm64)', 'images.yml: kroky, ktere se prihlasuji do registru nebo publikuji');
# stavy, ve kterych se krok spustit nesmi - at beh vyvolala jakakoli udalost
my %NO = (
    'Meta publish=false, Branch head preskocen' => {'steps.meta.outputs.publish' => 'false'},
    'krok Meta nedobehl'                        => {},
    'Branch head nedal vystup'                  => {'steps.meta.outputs.publish' => 'true'},
    'commit uz neni hlavou vetve'               => {'steps.meta.outputs.publish' => 'true', 'steps.head.outputs.publish' => 'false'},
);
foreach my $step (@publishing, 'Build (linux/arm64)', 'Smoke checks (linux/arm64)') {
    my $if = step_if($WF, $step);
    foreach my $event ('pull_request', 'push', 'workflow_dispatch') {
        my %ctx = ('github.event_name' => $event, 'steps.meta.outputs.dockerhub' => 'true');
        foreach my $state (sort keys %NO) {
            is(gha_if($if, {%ctx, %{$NO{$state}}}), 0, "images.yml ($step; $event, $state): krok se preskoci") or diag("if: $if");
        }
        next if ($event eq 'pull_request');    # krok Meta u pull requestu publish=true nikdy neda
        is(gha_if($if, {%ctx, 'steps.meta.outputs.publish' => 'true', 'steps.head.outputs.publish' => 'true'}), 1, "images.yml ($step; $event, publikujici beh nad hlavou vetve): krok bezi") or diag("if: $if");
    }
}
is(gha_if(step_if($WF, 'Login to Docker Hub'), {'steps.meta.outputs.publish' => 'true', 'steps.head.outputs.publish' => 'true', 'steps.meta.outputs.dockerhub' => 'false'}), 0, 'images.yml: bez zrcadla se do Docker Hubu neprihlasuje');
is(join(' ', map { gha_if(step_if($WF, 'Branch head'), {'steps.meta.outputs.publish' => $_}) // '?' } 'false', 'true'), '0 1', 'images.yml: Branch head bezi jen po rozhodnuti kroku Meta publish=true');
is(join(' ', sort(job_keys($WF, 'images'))), 'defaults env name permissions runs-on steps timeout-minutes', 'images.yml: job nema jine klice nez name, runs-on, timeout-minutes, permissions, defaults, env a steps');
like(job_body($WF, 'images'), qr/^    permissions:\n      contents: read\n      packages: write\n/m, 'images.yml: job smi jen cist repozitar a zapisovat balicky');
like($WF, qr/^permissions:\n  contents: read\n\n/m, 'images.yml: vychozi opravneni workflow jen contents: read');

# ---------------------------------------------------------------------------------------------
# zdvojene behy: job nema podminku "if" - beh pull_request se po pushi do vetve tehoz repozitare nepreskakuje.
# Preskoceny job by se v kontrolach pull requestu pocital jako uspesny a beh push ho nemusi zastoupit
# (vetev bez workflow v commitu hlavy, push mimo sledovane cesty).
# ---------------------------------------------------------------------------------------------
foreach my $w (['images.yml', $WF, 'images'], ['tests.yml', $TESTS, 'tests']) {
    my ($file, $wf, $job) = @{$w};
    is(scalar(grep { $_ eq 'if' } job_keys($wf, $job)), 0, "$file: job $job nema podminku if - beh pull_request se nepreskakuje");
    # vetve Dependabota bezi jen jako pull request (push do nich by tutez praci delal podruhe)
    is(join(' ', on_list($wf, 'push', 'branches')), '** !dependabot/**', "$file: push spousti workflow ve vsech vetvich krome dependabot/** (ty bezi jen jako pull request)");
    # pull request se sestavi a otestuje pri kazdem pushi, i z forku a z vetve Dependabota
    is(join(' ', on_keys($wf, 'pull_request')), 'paths', "$file: pull_request neni omezen na typy udalosti ani na cilove vetve");
    is(join(' ', on_keys($wf, 'push')), 'branches paths', "$file: push ma jen filtr vetvi a cest (zadne tags, *-ignore)");
    unlike($wf, qr/^  pull_request_target:/m, "$file: zadna udalost pull_request_target (bezela by s opravnenim cilove vetve nad kodem z forku)");
}
is(join(' ', sort(job_keys($TESTS, 'tests'))), 'defaults env name runs-on steps timeout-minutes', 'tests.yml: job nema jine klice nez name, runs-on, timeout-minutes, defaults, env a steps');

# ---------------------------------------------------------------------------------------------
# vstupy image a prekryv s tests.yml
# ---------------------------------------------------------------------------------------------
my @push = paths_of($WF, 'push');
my @pr   = paths_of($WF, 'pull_request');
is_deeply(\@pr, \@push, 'images.yml: on.pull_request.paths = on.push.paths');
foreach my $p ('PWE/**', 'docker-bake.hcl', '.dockerignore', 'LICENSE', 'webapps/example.web/**', 'webapps/example-db.web/**', '.github/workflows/images.yml') {
    ok(scalar(grep { $_ eq $p } @push), "images.yml: vstupem image je $p");
}
# Testy (PWE/t) a nastroje pro vyvojare (PWE/tools) v image nejsou: jejich zmena image nemeni, nesmi spustit
# sestaveni ani publikaci a hlida ji workflow Tests. V IMAGE_PATHS (cesty pro git diff) je vyjimka zapsana
# jako :(exclude)<cesta>.
foreach my $p ('!PWE/t/**', '!PWE/tools/**') {
    my ($neg) = grep { $push[$_] eq $p } 0 .. $#push;
    my ($pos) = grep { $push[$_] eq 'PWE/**' } 0 .. $#push;
    ok(defined($neg) && defined($pos) && $neg > $pos, "images.yml: $p je vyjimka uvedena az za PWE/** (plati posledni odpovidajici vzor)");
}
# Kourove kontroly (brana pred publikaci) vstupem image zustavaji, i kdyz lezi ve vyrazenem PWE/tools: v paths
# jsou uvedene az za vyjimkou a pro git diff (ktery je v jednom volani s :(exclude) vratit neumi) v IMAGE_EXTRA_PATHS.
my @extra = grep { my $i = $_; $push[$i] !~ /^!/ && grep { my $n = $push[$_]; ($n =~ s{^!(.*)/\*\*$}{$1}) && index($push[$i], "$n/") == 0 } 0 .. $i - 1 } 0 .. $#push;
is(join(' ', map { $push[$_] } @extra), 'PWE/tools/smoke-images.sh PWE/tools/lib/images.sh', 'images.yml: kourove kontroly (smoke-images.sh, lib/images.sh) jsou vstupem image uvedenym za vyjimkou PWE/tools');
is($JOB_ENV{'IMAGE_EXTRA_PATHS'} // '', join(' ', map { $push[$_] } @extra), 'images.yml: env IMAGE_EXTRA_PATHS = cesty z on.push.paths uvedene za vyjimkou');
{
    my %is_extra = map { $_ => 1 } @extra;
    is(join(' ', sort split(' ', $JOB_ENV{'IMAGE_PATHS'} // '')), join(' ', sort map { (my $x = $push[$_]) =~ s{/\*\*$}{}; ($x =~ s{^!}{}) ? ":(exclude)$x" : $x } grep { !$is_extra{$_} } 0 .. $#push), 'images.yml: env IMAGE_PATHS = on.push.paths vcetne vyjimek (krok Branch head srovnava tytez cesty)');
}
like(step_run($WF, 'Branch head'), qr/git diff --quiet "\$GITHUB_SHA" "\$head" -- "\$\{extra\[\@\]\}"/, 'images.yml: Branch head srovnava i cesty z IMAGE_EXTRA_PATHS (druhe volani git diff)');
{
    my $NEW = 'b' x 40;
    my @h   = ('FAKE_HEADS' => "$NEW\\trefs/heads/pwe.ai\\n", 'IMAGE_EXTRA_PATHS' => 'PWE/tools/smoke-images.sh PWE/tools/lib/images.sh');
    my ($rc, $publish, $log, $calls) = branch_head(@h, 'FAKE_DIFF_RC' => 0, 'FAKE_DIFF_EXTRA_RC' => 1);
    is("$rc $publish", '0 false', 'Branch head: hlava meni jen kourove kontroly -> meni vstupy image, tento beh nepublikuje') or diag($log);
    like($calls, qr/^diff --quiet \S+ $NEW -- PWE\/tools\/smoke-images\.sh PWE\/tools\/lib\/images\.sh$/m, 'Branch head: druhe volani git diff jen nad IMAGE_EXTRA_PATHS');
    ($rc, $publish, $log, $calls) = branch_head(@h, 'FAKE_DIFF_RC' => 0, 'FAKE_DIFF_EXTRA_RC' => 0);
    is("$rc $publish", '0 true', 'Branch head: hlava se nelisi ve vstupech ani v kourovych kontrolach -> publikuje se') or diag($log);
    ($rc, $publish, $log, $calls) = branch_head('FAKE_HEADS' => "$NEW\\trefs/heads/pwe.ai\\n", 'FAKE_DIFF_RC' => 0, 'IMAGE_EXTRA_PATHS' => '');
    is(scalar(() = $calls =~ /^diff /mg), 1, 'Branch head: prazdny IMAGE_EXTRA_PATHS = jedine volani git diff');
}
like(step_run($WF, 'Branch head'), qr/git diff --quiet "\$GITHUB_SHA" "\$head" -- "\$\{paths\[\@\]\}"/, 'images.yml: Branch head srovnava cesty z IMAGE_PATHS');

# Image vzorovych webu se stavi Dockerfilem vzoroveho webu z korene repozitare (engine i web jdou z kontextu
# sestaveni): vse, co Dockerfile z kontextu kopiruje, musi byt vstupem image - jinak by zmena takoveho souboru
# workflow nespustila a krok Branch head by ji nepovazoval za zmenu image.
# covered($cesta) - lezi cesta pod nekterou cestou z on.push.paths?
sub covered {
    my ($p) = @_;
    my $hit = 0;    # jako GitHub: plati posledni vzor, ktery ceste odpovida (vzor s ! cestu vyrazuje)
    foreach my $pat (@push) {
        my $x   = $pat;
        my $neg = ($x =~ s{^!}{}) ? 1 : 0;
        next unless (($x =~ s{/\*\*$}{}) ? ($p eq $x || index($p, "$x/") == 0) : ($p eq $x));
        $hit = $neg ? 0 : 1;
    }
    return $hit;
}
is(join(' ', map { covered($_) } 'PWE/tools/k8s.sh', 'PWE/tools/lib/PWE/ToolEnv.pm', 'PWE/t/14-tools.t', 'PWE/t', 'PWE/tools', 'PWE/toolsx/a', 'PWE/docker/entrypoint.sh', 'PWE/pwe.fcgi', 'PWE/tools/smoke-images.sh', 'PWE/tools/lib/images.sh'),
    '0 0 0 0 0 1 1 1 1 1', 'covered: testy a nastroje enginu vstupem image nejsou (krome kourovych kontrol), zbytek PWE/ ano');
# Skutecne vstupy image nesmi vyradit zadna dalsi vyjimka (ani kdyby byla ve vsech trech seznamech shodne).
is(join(' ', grep { !covered($_) } 'docker-bake.hcl', '.dockerignore', 'LICENSE', '.github/workflows/images.yml', 'PWE/VERSION', 'PWE/docker/Dockerfile', context_sources(slurp("$REPO/PWE/docker/Dockerfile")), map { "webapps/$_/Dockerfile" } 'example.web', 'example-db.web'),
    '', 'images.yml: Dockerfile zavislostnich image, jeho zdroje z kontextu, bake, .dockerignore, VERSION a Dockerfile vzorovych webu jsou vstupem image');
is(join(' ', map { covered($_) } 'PWE', 'PWE/Libs/Web.pm', 'LICENSE', 'webapps/example.web', 'webapps/example.web/conf/web.conf', 'webapps/example.webx', 'webapps', 'LICENSE.txt', '.', 'README.md'),
    '1 1 1 1 1 0 0 0 0 0', 'covered: cesta pod vstupem image (adresar/** vcetne adresare sameho, soubor presne)');
is(join(' ', context_sources("FROM x\nCOPY --link a b/ /dst/\nCOPY --from=y c /c\nADD ./d /d\nRUN --mount=type=bind,source=e,target=/e --mount=type=cache,target=/f \\\n    true\nCOPY g \\\n    h /i/\n")),
    'a b d e g h', 'context_sources: zdroje COPY, ADD a RUN --mount=type=bind z kontextu sestaveni (bez --from)');
foreach my $web ('example.web', 'example-db.web') {
    my @src = context_sources(slurp("$REPO/webapps/$web/Dockerfile"));
    ok(scalar(grep { $_ eq "webapps/$web" } @src), "webapps/$web/Dockerfile: web se kopiruje z kontextu sestaveni (koren repozitare)");
    is(join(' ', grep { !covered($_) } @src), '', "webapps/$web/Dockerfile: kazdy zdroj COPY je vstupem image (on.push.paths workflow Images)");
}

my @tpush = paths_of($TESTS, 'push');
my @tpr   = paths_of($TESTS, 'pull_request');
is_deeply(\@tpr, \@tpush, 'tests.yml: on.pull_request.paths = on.push.paths');
ok(scalar(@tpush) > 0, 'tests.yml: ma seznam cest');
my %images_path = map { $_ => 1 } @push;
is(join(' ', grep { $images_path{$_} } @tpush), '', 'tests.yml: zadna cesta spolecna s images.yml');
is(join(' ', grep { covered($_) || (m{^(?:webapps|PWE)/} && !m{^PWE/(?:t|tools)/\*\*$}) } @tpush), '', 'tests.yml: vzorove weby, engine ani jiny vstup image nesleduje (patri images.yml)');
foreach my $p ('PWE/t/**', 'PWE/tools/**') {
    ok(scalar(grep { $_ eq $p } @tpush), "tests.yml: $p hlida workflow Tests (v image neni, images.yml ho vynechava)");
}
foreach my $p (map { $push[$_] } @extra) {
    my ($neg) = grep { $tpush[$_] eq "!$p" } 0 .. $#tpush;
    my ($pos) = grep { $tpush[$_] eq 'PWE/tools/**' } 0 .. $#tpush;
    ok(defined($neg) && defined($pos) && $neg > $pos, "tests.yml: $p vynechava (patri images.yml) - seznamy se neprekryvaji");
}
unlike($TESTS, qr/^\s+TAG: /m, 'tests.yml: zadna promenna TAG pro bake');
like($TESTS, qr/^      PWE_TEST_IMAGE: localhost\/pwe-tests\/pwe-base:latest$/m, 'tests.yml: testy bezi v mistnim pwe-base:latest');
my $tbuild = step_run($TESTS, 'Build pwe-base (linux/amd64)');
like($tbuild, qr/^VERSION="\$\(tr -d '\[:space:\]' < PWE\/VERSION\)"$/m, 'tests.yml: VERSION pro bake z PWE/VERSION');
like($tbuild, qr/^export VERSION$/m, 'tests.yml: VERSION se predava bake prostredim');
unlike($TESTS, qr/login|--push|packages: write/, 'tests.yml: nic nepublikuje');
{
    # krok sestaveni se spousti doopravdy (falesny docker): stavi jen cil base = image pwe-base, ve kterem bezi testy
    my ($rc, $log, $calls) = bake_step($TESTS, 'tests', 'Build pwe-base (linux/amd64)');
    is($rc, 0, 'tests.yml: prehrani kroku sestaveni skonci kodem 0') or diag($log);
    is(join(' | ', map { "$_->{'mode'}: @{$_->{'targets'}}" } @{$calls}), 'load: base', 'tests.yml: stavi jen cil base (pwe-base), zadny dalsi image');
    is(($calls->[0] || {})->{'env'} // '', 'localhost/pwe-tests|2.2.1|||', 'tests.yml: bake dostava mistni registr localhost/pwe-tests a verzi z PWE/VERSION');
    is(set_of($calls->[0] || {'set' => {}}, '*.platform'), 'linux/amd64', 'tests.yml: jen platforma runneru');
}

done_testing();
