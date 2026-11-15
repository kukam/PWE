#!/usr/bin/env perl
# Nastroje enginu PWE/tools/ (new-webapp.pl, new-module.pl, check-webapp.pl, smtp-test.pl):
# vygenerovany webapp se nacte a obslouzi requesty (CGI rezim). Dale jmena image (PWE::ToolEnv proti
# shell funkcim tools/lib/images.sh), Dockerfile webu (behove prostredi z image pwe-<profil>, engine
# z image pwe, zadny vlastni entrypoint), Dockerfile enginu (rodokmen stage, balicky), .dockerignore
# (soukrome klice webu) a entrypoint image docker/entrypoint.sh (symlink conf/database.conf, varovani).
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Basename qw(dirname);
use File::Path qw(remove_tree make_path);
use lib "$FindBin::Bin/lib";
use lib "$FindBin::Bin/../tools/lib";
use PWE::TestEnv;
use PWE::ToolEnv qw(run_cgi parse_response);

plan skip_all => 'chybi Template / CGI::Fast (spust v kontejneru: make test, tj. PWE/tools/run-tests.sh)' unless (eval { require Template; require CGI::Fast; require Class::Inspector; 1 });

PWE::TestEnv::clean_env();
my $ROOT  = PWE::TestEnv::root();    # koren enginu (adresar PWE/ v koreni repozitare, v kontejneru /PWE/PWE)
my $TOOLS = "$ROOT/tools";
my $base  = PWE::TestEnv::app() . "ramdisk/webapps";
remove_tree($base);
make_path($base);

# ---------------------------------------------------------------------------------------------
# rozlozeni repozitare: nastroje i testy se musi shodnout na koreni enginu (regrese prejmenovani
# adresare enginu z "core" na "PWE"; cesta se odvozuje od umisteni souboru, nazev adresare neni pevny)
# ---------------------------------------------------------------------------------------------
is(PWE::ToolEnv::core_root(), $ROOT, 'ToolEnv::core_root() = koren enginu (stejny jako TestEnv::root())');
is(PWE::ToolEnv::engine_root(), $ROOT, 'ToolEnv::engine_root() je alias core_root()');
is(PWE::ToolEnv::repo_root(), dirname($ROOT), 'ToolEnv::repo_root() = nadrazeny adresar enginu (koren repozitare)');
ok(-f "$ROOT/pwe.fcgi" && -f "$ROOT/VERSION" && -d "$ROOT/Libs" && -d "$TOOLS/lib/PWE", 'koren enginu obsahuje pwe.fcgi, VERSION, Libs/ a tools/lib/PWE/');

sub run_tool {
    my (@args) = @_;
    my $cmd = join(' ', map { "'$_'" } ($^X, @args)) . ' 2>&1';
    my $out = `$cmd`;
    return ($? >> 8, $out);
}

sub slurp { my ($f) = @_; open(my $fh, '<', $f) or return ''; local $/; my $s = <$fh>; close($fh); return $s; }

# Spusti prikaz bez shellu (argumenty se predaji presne, i s mezerami a uvodni pomlckou) a vrati
# (navratovy kod, STDOUT+STDERR). Volby: cwd => adresar, env => { PROMENNA => hodnota | undef (= smazat) },
# stderr => soubor (STDERR se zapise zvlast do souboru misto do vraceneho vystupu), drop_root => 1
# (bezi-li test jako root, spusti se prikaz jako nobody: root by zapsal i do adresare bez prava zapisu).
sub run_cmd {
    my ($o, @cmd) = @_;
    my $pid = open(my $fh, '-|');
    die "fork: $!" unless (defined($pid));
    if ($pid == 0) {
        if ($o->{'cwd'}) { chdir($o->{'cwd'}) or do { print "chdir $o->{'cwd'}: $!\n"; exit(125); }; }
        foreach my $k (keys %{$o->{'env'} || {}}) {
            if (defined($o->{'env'}->{$k})) { $ENV{$k} = $o->{'env'}->{$k}; } else { delete $ENV{$k}; }
        }
        if ($o->{'stderr'}) {
            open(STDERR, '>', $o->{'stderr'}) or do { print "stderr $o->{'stderr'}: $!\n"; exit(125); };
        } else {
            open(STDERR, '>&', \*STDOUT);
        }
        if ($o->{'drop_root'} and $> == 0) {
            require POSIX;
            $) = '65534 65534';
            POSIX::setgid(65534);
            POSIX::setuid(65534);
            if ($> == 0) { print "nelze zahodit prava roota\n"; exit(124); }
        }
        exec(@cmd) or do { print "exec $cmd[0]: $!\n"; exit(127); };
    }
    my $out = do { local $/; <$fh> };
    close($fh);
    return ($? >> 8, (defined($out) ? $out : ''));
}

# Entrypoint image PWE (jediny zdroj: stage base ho instaluje do /usr/local/bin/entrypoint.sh a vsechny
# odvozene image vcetne image webu ho dedi). Web vlastni kopii nema, generator zadnou nevytvari.
my $ENTRYPOINT_SRC = "$ROOT/docker/entrypoint.sh";
my $BASH           = (grep { -x $_ } map { "$_/bash" } split(/:/, ($ENV{'PATH'} || '')), '/bin')[0];

# Instrukce Dockerfile: bez komentaru a prazdnych radku, pokracovaci radky (\ na konci) spojene do
# jednoho - co radek, to jedna instrukce. Aserce se tak tykaji toho, co build provede, ne zneni
# komentaru (uprava komentare v sablone nesmi test shodit).
sub dockerfile_instructions {
    my ($text) = @_;
    $text =~ s/^[ \t]*#.*\n//mg;
    $text =~ s/^[ \t]*\n//mg;
    $text =~ s/[ \t]*\\\n[ \t]*/ /g;
    return $text;
}

# Kontroly Dockerfile webu podle jednotne sablony: behove prostredi z image pwe-<profil>, engine z image
# pwe, entrypoint zdedeny z behoveho image. Vraci seznam [nazev, kontrola]; kontrola dostane instrukce
# (dockerfile_instructions) a vraci pravdu. Seznam je zaroven pocet testu v dockerfile_ok().
sub dockerfile_checks {
    my ($web, $profile) = @_;
    my $w       = quotemeta($web);
    my $runtime = quotemeta('${PWE_IMAGE_REGISTRY}/pwe-${PWE_PROFILE}:${PWE_IMAGE_TAG}');
    my $has     = sub { my ($re) = @_; return sub { $_[0] =~ $re }; };
    my $hasnt   = sub { my ($re) = @_; return sub { $_[0] !~ $re }; };
    my $times   = sub { my ($re, $n) = @_; return sub { my $c = () = $_[0] =~ /$re/g; $c == $n }; };
    # instrukce behoveho stage (za druhym FROM)
    my $stage2 = sub { my ($ins) = @_; my ($s2) = $ins =~ /^FROM $runtime\n(.*)\z/ms; return defined($s2) ? $s2 : ''; };
    # poradi: kazdy vzor musi v instrukcich existovat a lezet az za predchozim
    my $ordered = sub {
        my (@re) = @_;
        return sub {
            my ($ins) = @_;
            my $last = -1;
            foreach my $re (@re) {
                return 0 unless ($ins =~ $re);
                return 0 unless ($-[0] > $last);
                $last = $-[0];
            }
            return 1;
        };
    };
    return (
        ['ARG PWE_IMAGE_REGISTRY (vychozi ghcr.io/kukam)',                             $has->(qr{^ARG PWE_IMAGE_REGISTRY=ghcr\.io/kukam$}m)],
        ['ARG PWE_IMAGE_TAG (vychozi master)',                                         $has->(qr{^ARG PWE_IMAGE_TAG=master$}m)],
        ['ARG PWE_ENGINE_TAG (vychozi = PWE_IMAGE_TAG; vetev nebo verze enginu)',      $has->(qr{^ARG PWE_ENGINE_TAG=\$\{PWE_IMAGE_TAG\}$}m)],
        ["ARG PWE_PROFILE=$profile",                                                   $has->(qr{^ARG PWE_PROFILE=\Q$profile\E$}m)],
        ['vychozi hodnota PWE_PROFILE je nastavena prave jednou',                      $times->(qr{^ARG PWE_PROFILE=}m, 1)],
        ['FROM .../pwe:<tag enginu> AS engine',                                        $has->(qr{^FROM \$\{PWE_IMAGE_REGISTRY\}/pwe:\$\{PWE_ENGINE_TAG\} AS engine$}m)],
        ['FROM .../pwe-<profil>:<tag> (behove prostredi)',                             $has->(qr{^FROM $runtime$}m)],
        ['prave dva stage (engine + behovy image)',                                    $times->(qr{^FROM }m, 2)],
        ['zadny zbytek stareho rozlozeni (FROM / COPY --from z kukam/pwe-base:latest)', $hasnt->(qr{^(?:FROM|COPY\s+--from=\S+)\s.*(?:pwe-base:|:latest)}m)],
        ['ARG PWE_PROFILE, PWE_IMAGE_REGISTRY a PWE_IMAGE_TAG znovu deklarovany v behovem stage pred ENV a LABEL (jinak by dostaly prazdnou hodnotu)', sub {
            my $s2 = $stage2->($_[0]);
            my ($head) = $s2 =~ /\A(.*?)^(?:ENV|LABEL) /ms;
            return (defined($head) and !(grep { $head !~ /^ARG \Q$_\E$/m } qw(PWE_PROFILE PWE_IMAGE_REGISTRY PWE_IMAGE_TAG)));
        }],
        ['COPY --from=engine /PWE/PWE /PWE/PWE',                                       $has->(qr{^COPY --from=engine /PWE/PWE /PWE/PWE$}m)],
        ['COPY --from=engine /PWE/LICENSE /PWE/LICENSE',                               $has->(qr{^COPY --from=engine /PWE/LICENSE /PWE/LICENSE$}m)],
        ['ENV PWE_CONF_pwe_home = adresar webu, PWE_PROFILE zapeceny do image (entrypoint nastavi conf/database.conf i bez -e)', $has->(qr{^ENV PWE_CONF_pwe_home=/PWE/webapps/$w PWE_PROFILE=\$\{PWE_PROFILE\}$}m)],
        ['COPY webu do /PWE/webapps/<web> (cesta od korene repozitare)',               $has->(qr{^WORKDIR /PWE/webapps/?\nCOPY webapps/$w $w$}m)],
        ['zadna instrukce ADD (soubory se kopiruji pres COPY)',                        $hasnt->(qr{^ADD\b}m)],
        ['posledni WORKDIR = adresar webu (entrypoint tam hleda conf/web.conf)',       sub { my @wd = $_[0] =~ /^WORKDIR (\S+)$/mg; return (@wd and $wd[-1] eq "/PWE/webapps/$web"); }],
        ['zadny ENTRYPOINT: image webu ho dedi z image pwe-<profil> (pwe-base)',       $hasnt->(qr{^ENTRYPOINT\b}m)],
        ['zadna instrukce nepracuje s entrypoint.sh (web vlastni kopii nema)',         $hasnt->(qr{entrypoint\.sh})],
        ['zadna instrukce USER (image bezi pod stejnym uzivatelem jako behovy image)', $hasnt->(qr{^USER\b}m)],
        ['RUN zalozi pracovni adresare ramdisk/templates, sessions, uploadfile a log', $has->(qr{^RUN .*\bmkdir -p ramdisk/templates sessions uploadfile log;}m)],
        ['RUN nasmeruje conf/database.conf na conf/<PWE_PROFILE>.conf, jen kdyz ten soubor existuje', $has->(qr{^RUN .*\bif \[ -f "conf/\$\{PWE_PROFILE\}\.conf" \].*; then ln -s\w* "\$\{PWE_PROFILE\}\.conf" conf/database\.conf; fi$}m)],
        ['LABEL title = nazev webu',                                                   $has->(qr{^LABEL .*\borg\.opencontainers\.image\.title="$w"(?: |$)}m)],
        ['LABEL description = web nad PWE',                                            $has->(qr{^LABEL .*\borg\.opencontainers\.image\.description="Web $w nad PWE\b[^"]*"(?: |$)}m)],
        ['LABEL source a licenses jsou prazdne (jinak by se zdedily udaje enginu)',    sub { $_[0] =~ /^LABEL .*\borg\.opencontainers\.image\.source=""(?: |$)/m and $_[0] =~ /^LABEL .*\borg\.opencontainers\.image\.licenses=""(?: |$)/m }],
        ['LABEL base.name = behovy image, ze ktereho se stavi',                        $has->(qr{^LABEL .*\borg\.opencontainers\.image\.base\.name="$runtime"(?: |$)}m)],
        ['CMD spousti engine z /PWE/PWE a je posledni instrukci',                      $has->(qr{^CMD \["perl", "/PWE/PWE/pwe\.fcgi"\]\n?\z}m)],
        # ARG pred prvnim FROM (jinak je FROM nevidi), engine pred behovym image, COPY --from az v behovem
        # image, RUN az nad zkopirovanym webem v jeho adresari
        ['poradi instrukci: ARG, FROM engine, FROM profil, COPY --from, ENV, COPY webu, WORKDIR webu, RUN, CMD', $ordered->(
            qr{^ARG PWE_IMAGE_REGISTRY=}m, qr{^ARG PWE_PROFILE=}m, qr{^FROM \$\{PWE_IMAGE_REGISTRY\}/pwe:}m, qr{^FROM $runtime$}m,
            qr{^COPY --from=engine /PWE/PWE }m, qr{^ENV PWE_CONF_pwe_home=}m, qr{^COPY webapps/$w }m, qr{^WORKDIR /PWE/webapps/$w$}m, qr{^RUN }m, qr{^CMD }m)],
    );
}
my $DOCKERFILE_TESTS = scalar(() = dockerfile_checks('pocet.web', 'static'));

# $label = prefix nazvu testu (ktery web / varianta).
sub dockerfile_ok {
    my ($file, $web, $profile, $label) = @_;
    my $ins = dockerfile_instructions(slurp($file));
    foreach my $check (dockerfile_checks($web, $profile)) {
        my ($what, $code) = @{$check};
        ok($code->($ins), "$label: $what") or diag($ins);
    }
    return;
}

# Jednoducha obdoba vyhodnoceni .dockerignore (jako Docker: * a ? v ramci jednoho adresare, ** pres
# libovolny pocet adresaru vcetne zadneho, vzor plati i pro vse pod adresarem, ktery mu odpovida,
# !vzor vraci zpet, rozhoduje posledni odpovidajici vzor). Vraci 1, kdyz se cesta do kontextu nedostane.
sub dockerignore_excludes {
    my ($patterns, $path) = @_;
    my $excluded = 0;
    foreach my $pattern (@{$patterns}) {
        my $p   = $pattern;
        my $neg = ($p =~ s/^!//) ? 1 : 0;
        $p =~ s{^/+|/+$}{}g;
        my $re = join('', map { $_ eq '**/' ? '(?:.*/)?' : $_ eq '**' ? '.*' : $_ eq '*' ? '[^/]*' : $_ eq '?' ? '[^/]' : quotemeta($_) } ($p =~ m{(\*\*/|\*\*|\*|\?|[^*?]+)}g));
        $excluded = ($neg ? 0 : 1) if ($path =~ m{^$re(?:/.*)?$});
    }
    return $excluded;
}

# ---------------------------------------------------------------------------------------------
# jmena image: PWE::ToolEnv (Perl nastroje) musi davat totez co tools/lib/images.sh (shell nastroje)
# ---------------------------------------------------------------------------------------------
{
    my $images_sh = "$TOOLS/lib/images.sh";
    my $valid_tag = qr/^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/;

    # prevod nazvu vetve na tag: cista funkce
    my @cases = (
        ['pwe.ai',                        'pwe.ai',             'tecka uvnitr zustava'],
        ['master',                        'master',             'bezny nazev beze zmeny'],
        ['release_2.2-rc1',               'release_2.2-rc1',    'podtrzitko, tecka a pomlcka jsou povolene'],
        ['feature/Nova vec',              'feature-Nova-vec',   'lomitko a mezera -> pomlcka, velikost pismen zustava'],
        ['-x..y',                         'x..y',               'uvodni pomlcka pryc, tecky uvnitr zustavaji'],
        ['.-.-skryta',                    'skryta',             'uvodni tecky a pomlcky pryc'],
        ['/vetev',                        'vetev',              'uvodni lomitko -> pomlcka -> pryc'],
        ["v\xc4\x9btev",                  'v--tev',             'znak s diakritikou (2 bajty UTF-8) -> dve pomlcky'],
        ['a@b#c:d',                       'a-b-c-d',            'znaky neplatne v tagu -> pomlcka'],
        ['x' x 200,                       'x' x 128,            '200 znaku -> zkraceno na 128'],
        [('-' x 5) . ('y' x 200),         'y' x 128,            'nejdriv uvodni pomlcky pryc, pak zkraceni na 128'],
        ['',                              'master',             'prazdny nazev -> master'],
        ['---',                           'master',             'jen pomlcky -> master'],
        ['///',                           'master',             'jen neplatne znaky -> master'],
    );
    foreach my $c (@cases) {
        my ($in, $want, $what) = @{$c};
        my $got = PWE::ToolEnv::image_tag_sanitize($in);
        my $show = (length($in) > 40) ? substr($in, 0, 12) . '...(' . length($in) . ' znaku)' : $in;
        is($got, $want, "image_tag_sanitize('$show'): $what");
        like($got, $valid_tag, "image_tag_sanitize('$show') je platny tag image");
    }
    is(PWE::ToolEnv::image_tag_sanitize(undef), 'master', 'image_tag_sanitize(undef) -> master');
    is(PWE::ToolEnv::image_tag_sanitize("vetev\n"), 'vetev', 'image_tag_sanitize: koncovy novy radek (vystup gitu) se zahodi');
    is(PWE::ToolEnv::image_tag_sanitize("v\x{11b}tev"), 'v--tev', 'image_tag_sanitize: dekodovany retezec se pocita po bajtech jako v shellu');

    # registr, tag a image nastroju podle promennych prostredi. PWE_TOOLS_IN_DOCKER=1 = chovani
    # v kontejneru: image_tag() nevola git, bez PWE_IMAGE_TAG vraci master (i kdyz test bezi na hostiteli).
    local %ENV = %ENV;
    delete @ENV{qw(PWE_TEST_IMAGE PWE_IMAGE_REGISTRY PWE_IMAGE_TAG)};
    $ENV{'PWE_TOOLS_IN_DOCKER'} = 1;
    is(PWE::ToolEnv::image_registry(), 'ghcr.io/kukam', 'image_registry(): vychozi ghcr.io/kukam');
    is(PWE::ToolEnv::image_tag(), 'master', 'image_tag(): v kontejneru bez PWE_IMAGE_TAG -> master');
    is(PWE::ToolEnv::docker_image(), 'ghcr.io/kukam/pwe-debugger:master', 'docker_image(): vychozi image nastroju je pwe-debugger');
    $ENV{'PWE_IMAGE_TAG'} = 'pwe.ai';
    is(PWE::ToolEnv::image_tag(), 'pwe.ai', 'image_tag(): PWE_IMAGE_TAG');
    is(PWE::ToolEnv::docker_image(), 'ghcr.io/kukam/pwe-debugger:pwe.ai', 'docker_image(): tag z PWE_IMAGE_TAG');
    $ENV{'PWE_IMAGE_REGISTRY'} = 'registry.example.test/tym/';
    is(PWE::ToolEnv::image_registry(), 'registry.example.test/tym', 'image_registry(): PWE_IMAGE_REGISTRY bez koncoveho lomitka');
    is(PWE::ToolEnv::docker_image(), 'registry.example.test/tym/pwe-debugger:pwe.ai', 'docker_image(): registr z PWE_IMAGE_REGISTRY');
    $ENV{'PWE_TEST_IMAGE'} = 'ghcr.io/kukam/pwe-base:jina';
    is(PWE::ToolEnv::docker_image(), 'ghcr.io/kukam/pwe-base:jina', 'docker_image(): PWE_TEST_IMAGE ma prednost pred registrem i tagem');
    is(PWE::ToolEnv::image_tag(), 'pwe.ai', 'image_tag(): PWE_TEST_IMAGE tag ostatnich image nemeni');
    $ENV{'PWE_TEST_IMAGE'} = '';
    is(PWE::ToolEnv::docker_image(), 'registry.example.test/tym/pwe-debugger:pwe.ai', 'docker_image(): prazdne PWE_TEST_IMAGE = nenastaveno');
    $ENV{'PWE_IMAGE_REGISTRY'} = '';
    $ENV{'PWE_IMAGE_TAG'}      = '';
    is(PWE::ToolEnv::docker_image(), 'ghcr.io/kukam/pwe-debugger:master', 'docker_image(): prazdne PWE_IMAGE_REGISTRY a PWE_IMAGE_TAG = vychozi');

    # hlaska nastroje, ktery nema moduly a nemuze se sam spustit v kontejneru, jmenuje image nastroju
    my ($rc_e, $out_e) = run_cmd({env => {PWE_IMAGE_TAG => 'pwe.ai', PWE_IMAGE_REGISTRY => undef, PWE_TEST_IMAGE => undef}},
        $^X, "-I$TOOLS/lib", '-MPWE::ToolEnv=ensure_modules', '-e', 'ensure_modules("PWE::Tento::Modul::Neexistuje")');
    isnt($rc_e, 0, 'ensure_modules: chybejici modul v kontejneru -> chyba');
    like($out_e, qr{spust v kontejneru ghcr\.io/kukam/pwe-debugger:pwe\.ai\b}, 'ensure_modules: hlaska jmenuje image nastroju (docker_image())');

    # shoda se shell implementaci (tools/lib/images.sh), kterou pouzivaji run-tests.sh, pwe-cgi.sh, run-webapp.sh a CI
  SKIP: {
        skip 'chybi bash nebo tools/lib/images.sh', scalar(@cases) + 5 unless ($BASH and -f $images_sh);
        foreach my $c (@cases) {
            my ($in, $want) = @{$c};
            my ($rc_s, $out_s) = run_cmd({}, $BASH, $images_sh, 'pwe_image_tag_sanitize', $in);
            chomp($out_s);
            my $show = (length($in) > 40) ? substr($in, 0, 12) . '...(' . length($in) . ' znaku)' : $in;
            is($out_s, $want, "images.sh pwe_image_tag_sanitize('$show') = ToolEnv::image_tag_sanitize");
        }
        foreach my $e (
            {PWE_IMAGE_TAG => 'pwe.ai', PWE_IMAGE_REGISTRY => undef,                         PWE_TEST_IMAGE => undef},
            {PWE_IMAGE_TAG => 'x_1.2',  PWE_IMAGE_REGISTRY => 'registry.example.test/tym/',  PWE_TEST_IMAGE => undef},
            {PWE_IMAGE_TAG => 'pwe.ai', PWE_IMAGE_REGISTRY => 'registry.example.test/tym',   PWE_TEST_IMAGE => 'ghcr.io/kukam/pwe-base:jina'},
            {PWE_IMAGE_TAG => 'pwe.ai', PWE_IMAGE_REGISTRY => '',                            PWE_TEST_IMAGE => ''},
        ) {
            my ($rc_s, $out_s) = run_cmd({env => $e}, $BASH, $images_sh, 'pwe_tool_image');
            chomp($out_s);
            local %ENV = %ENV;
            foreach my $k (keys %{$e}) { if (defined($e->{$k})) { $ENV{$k} = $e->{$k}; } else { delete $ENV{$k}; } }
            is(PWE::ToolEnv::docker_image(), $out_s, 'docker_image() = images.sh pwe_tool_image (' . join(' ', map { "$_=" . (defined($e->{$_}) ? "'$e->{$_}'" : 'nenastaveno') } sort keys %{$e}) . ')');
        }
        my ($rc_s, $out_s) = run_cmd({env => {PWE_IMAGE_TAG => 'pwe.ai', PWE_IMAGE_REGISTRY => undef, PWE_TEST_IMAGE => undef}}, $BASH, $images_sh, 'pwe_image', 'pwe-mariadb');
        chomp($out_s);
        is($out_s, 'ghcr.io/kukam/pwe-mariadb:pwe.ai', 'images.sh pwe_image pwe-mariadb (image profilu pro compose)');
    }

    # shell nastroje berou image z images.sh (pwe_tool_image / pwe_image_*), zadny nema jmeno image napevno
    my $old_image = qr{kukam/pwe-[a-z]+:latest};
    foreach my $sh (qw(run-tests.sh perl-compile.sh pwe-cgi.sh)) {
        my $src = slurp("$TOOLS/$sh");
        like($src, qr{^\. "\$ROOT/PWE/tools/lib/images\.sh"$}m, "$sh nacita tools/lib/images.sh");
        like($src, qr{^IMAGE="\$\(pwe_tool_image\)"$}m,          "$sh: image nastroju z pwe_tool_image");
        unlike($src, $old_image,                                 "$sh: zadne pevne jmeno stareho image");
    }
    my $runsh = slurp("$TOOLS/run-webapp.sh");
    like($runsh, qr{^\. "\$ROOT/PWE/tools/lib/images\.sh"$}m, 'run-webapp.sh nacita tools/lib/images.sh');
    like($runsh, qr{^PWE_IMAGE_REGISTRY="\$\(pwe_image_registry\)"$}m, 'run-webapp.sh: PWE_IMAGE_REGISTRY z pwe_image_registry');
    like($runsh, qr{^PWE_IMAGE_TAG="\$\(pwe_image_tag\)"$}m,           'run-webapp.sh: PWE_IMAGE_TAG z pwe_image_tag');
    like($runsh, qr{^export PWE_IMAGE_REGISTRY PWE_IMAGE_TAG$}m,       'run-webapp.sh exportuje obe promenne pro docker-compose.yml');
    unlike($runsh, $old_image, 'run-webapp.sh: zadne pevne jmeno stareho image');
    unlike(slurp("$TOOLS/lib/PWE/ToolEnv.pm"), $old_image, 'ToolEnv.pm: zadne pevne jmeno stareho image');
  SKIP: {
        skip 'chybi bash', 6 unless ($BASH);
        foreach my $sh (qw(run-tests.sh perl-compile.sh pwe-cgi.sh run-webapp.sh build-images.sh lib/images.sh)) {
            my ($rc_n, $out_n) = run_cmd({}, $BASH, '-n', "$TOOLS/$sh");
            is($rc_n, 0, "bash -n tools/$sh") or diag($out_n);
        }
    }

    # docker-compose.yml: sluzby berou image z registru a tagu v promennych (PWE_IMAGE_REGISTRY, PWE_IMAGE_TAG)
  SKIP: {
        my $compose = slurp(dirname($ROOT) . '/docker-compose.yml');
        skip 'docker-compose.yml neni k dispozici (engine bez korene repozitare)', 6 unless (length($compose));
        my ($fcgi)     = $compose =~ /^  fcgi:\n((?:(?:    .*)?\n)+)/m;
        my ($debugger) = $compose =~ /^  debugger:\n((?:(?:    .*)?\n)+)/m;
        like($fcgi || '', qr{^    image: \$\{PWE_IMAGE_REGISTRY:-ghcr\.io/kukam\}/pwe-\$\{COMPOSE_PROFILES:-mariadb\}:\$\{PWE_IMAGE_TAG:-master\}$}m, 'compose: sluzba fcgi = image profilu pwe-<profil>:<tag>');
        like($debugger || '', qr{^    image: \$\{PWE_IMAGE_REGISTRY:-ghcr\.io/kukam\}/pwe-debugger:\$\{PWE_IMAGE_TAG:-master\}$}m, 'compose: sluzba debugger = image pwe-debugger:<tag>');
        unlike(($fcgi || '') . ($debugger || ''), qr{^    entrypoint:}m, 'compose: sluzby fcgi a debugger entrypoint neprepisuji (maji ho z pwe-base)');
        like($fcgi || '', qr{^      PWE_PROFILE: \$\{COMPOSE_PROFILES:-mariadb\}$}m, 'compose: sluzba fcgi predava PWE_PROFILE entrypointu');
        unlike($compose, $old_image, 'compose: zadne pevne jmeno stareho image');
        like($debugger || '', qr{^    init: true$}m, 'compose: sluzba debugger ma init (PID 1 = sleep infinity jinak neodpovi na SIGTERM a zastaveni ceka na timeout)');
    }
}

# ---------------------------------------------------------------------------------------------
# new-webapp.pl bez databaze
# ---------------------------------------------------------------------------------------------
my $app = "$base/tool.web";
my ($rc, $out) = run_tool("$TOOLS/new-webapp.pl", 'tool.web', '--dir', $app, '--title', 'Tool Test', '--lang', 'CZE,EN', '--examples');
is($rc, 0, 'new-webapp.pl (bez DB) skoncil 0') or diag($out);
like($out, qr/Vytvoren webapp/, 'vypis shrnuti');

ok(!-e "$app/Libs" && !-e "$app/templates" && !-e "$app/pwe.fcgi" && !-e "$app/assets", 'zadne symlinky na engine (engine se bere z PWE/)');
ok(!-e "$app/Pages/css" && !-e "$app/Pages/errorPage", 'sdilene stranky nejsou ve webu');
ok(-f "$app/Entities/.gitkeep" && -d "$app/Services" && -d "$app/Sites", 'adresare modulu existuji');
ok(-f "$app/Pages/default/default.pm", 'vlastni Pages/default');
ok(-f "$app/Sites/Default/Default.pm", 'vlastni Sites/Default');
ok(-f "$app/Services/UserAccount/UserAccount.pm", 'vlastni Services/UserAccount (stub bez DB)');
ok(-f "$app/conf/web.conf", 'conf/web.conf');
ok(!-e "$app/conf/database.conf", 'bez DB neni database.conf');
ok(-f "$app/static/css/site.css", 'static/css/site.css');
ok(-f "$app/Dockerfile" && -f "$app/.htaccess" && -f "$app/README.md", 'Dockerfile, .htaccess, README.md');
ok(!-e "$app/entrypoint.sh", 'bez DB: web nema vlastni entrypoint.sh (image webu ho dedi z image pwe-<profil>)');
unlike($out, qr/entrypoint\.sh/, 'bez DB: vypis generatoru zadny entrypoint.sh neuvadi');
ok(-d "$app/ramdisk/templates" && -d "$app/sessions" && -d "$app/uploadfile" && -d "$app/log", 'docasne adresare');
dockerfile_ok("$app/Dockerfile", 'tool.web', 'static', 'Dockerfile bez DB');
unlike(slurp("$app/README.md"), qr/^\| `entrypoint\.sh` \|/m, 'bez DB: README nema radek o souboru entrypoint.sh');

my $conf = do("$app/conf/web.conf");
is(ref($conf), 'HASH', 'web.conf je platny Perl hash');
is_deeply($conf->{'http'}->{'languages'}, ['CZE', 'EN'], 'http.languages z --lang');
is($conf->{'http'}->{'title'}, 'Tool Test', 'http.title z --title');
is($conf->{'pwe'}->{'save_opt_to'}, 'file', 'bez DB save_opt_to = file');
is($conf->{'http'}->{'cookie_name'}, 'PWE-TOOL-WEB', 'cookie_name odvozen z nazvu');
like($conf->{'pwe'}->{'require_core'}, qr/^>=\d+\.\d+$/, 'require_core podle PWE/VERSION');
is_deeply($conf->{'pwe'}->{'core_pages'}, ['css', 'errorPage', 'systemPage', 'pweCreator', 'ajaxExamples', 'formExamples', 'responsive'], '--examples: ukazkove stranky v core_pages (bez NewBootstrap523 bez DB)');
is_deeply($conf->{'pwe'}->{'core_sites'}, ['Responsive'], 'core_sites');
is_deeply($conf->{'pwe'}->{'core_services'}, [], 'bez DB zadne sluzby z enginu');
is_deeply($conf->{'pwe'}->{'core_entities'}, [], 'bez DB zadne entity z enginu');

foreach my $rb ("$app/Pages/default/rb.tmpl", "$app/Pages/default/rb_EN.tmpl", "$app/Sites/Default/rb_EN.tmpl", "$app/Services/UserAccount/rb.tmpl") {
    like(slurp($rb), qr/\n\n\z/, "rb konci prazdnym radkem: " . substr($rb, length($app) + 1));
}
like(slurp("$app/Pages/default/rb.tmpl"), qr/rb\.home_title = "Tool Test"/, 'rb obsahuje titulek');

($rc, $out) = run_tool("$TOOLS/new-webapp.pl", 'tool.web', '--dir', $app);
isnt($rc, 0, 'existujici adresar bez --force -> chyba');
like($out, qr/--force/, 'napoveda na --force');

# perl -c vlastnich modulu
foreach my $pm (qw(Pages/default/default.pm Sites/Default/Default.pm Services/UserAccount/UserAccount.pm)) {
    my $o = `$^X -I'$app' -I'$ROOT' -c '$app/$pm' 2>&1`;
    like($o, qr/syntax OK/, "perl -c $pm") or diag($o);
}

# --- smoke requesty (CGI rezim) --------------------------------------------------------------
my ($res, $err) = run_cgi($app);
my $r = parse_response($res);
is($r->{'status'}, 200, 'default stranka 200') or diag($err);
like($r->{'headers'}->{'content-type'} || '', qr{text/html}, 'content-type text/html');
like($r->{'headers'}->{'set-cookie'} || '', qr/^PWE-TOOL-WEB=C0[0-9A-F]{32}/, 'session cookie s nazvem webu');
like($r->{'body'}, qr/<title>Tool Test<\/title>/, 'titulek z conf');
like($r->{'body'}, qr/<h1[^>]*>Tool Test<\/h1>/, 'obsah main.html s rb');
like($r->{'body'}, qr/Domů/, 'ceske menu (vychozi jazyk CZE)');
like($r->{'body'}, qr/assets\/javascript\/pwe\.js/, 'layout nacita pwe.js');
like($r->{'body'}, qr/static\/css\/site\.css/, 'layout nacita static/css/site.css');
like($r->{'body'}, qr/page=formExamples/, '--examples: polozka menu');
my ($res_f) = run_cgi($app, query => 'page=formExamples&func=default');
is(parse_response($res_f)->{'status'}, 200, 'formExamples z PWE/Pages odpovida (pwe.core_pages)');
like($r->{'body'}, qr/assets\/css\/bootstrap-5\.3\.8\/bootstrap\.min\.css/, 'layout nacita Bootstrap 5.3.8');
like($r->{'body'}, qr/assets\/javascript\/jquery-4\.0\.0\/jquery-4\.0\.0\.min\.js/, 'layout nacita jQuery 4.0.0');
like($r->{'body'}, qr/data-bs-toggle="collapse"/, 'navbar s Bootstrap 5 atributy');
unlike($r->{'body'}, qr/bootstrap-3|jquery-1|glyphicon|navbar-default|btn-default|data-toggle=/, 'zadne zbytky Bootstrap 3');
my ($res_b) = run_cgi($app, script => '/assets/css/bootstrap-5.3.8/bootstrap.min.css');
is(parse_response($res_b)->{'status'}, 200, 'Bootstrap css se serviruje z enginu');
like($r->{'body'}, qr/page=pweCreator/, 'development=1: skupina admin -> odkaz pweCreator');
like($r->{'body'}, qr{</html>\s*$}, 'kompletni HTML');
unlike($err, qr/\[E\]/, 'engine nezalogoval chybu') or diag($err);

($res, $err) = run_cgi($app, query => 'page=default&func=setlanguage&lang=EN');
$r = parse_response($res);
is($r->{'status'}, 200, 'setlanguage 200');
like($r->{'body'}, qr/>Home</, 'po prepnuti anglicke menu (rb_EN.tmpl)');

($res, $err) = run_cgi($app, query => 'page=default&func=setlanguage&lang=XX');
$r = parse_response($res);
is($r->{'status'}, 200, 'neplatny jazyk -> error metoda vykresli stranku');
like($r->{'body'}, qr/Neznámý jazyk|alert-danger/, 'messenger s chybou error_language');

($res, $err) = run_cgi($app, query => 'page=neexistuje&func=default');
is(parse_response($res)->{'status'}, 404, 'neznama stranka 404');

($res, $err) = run_cgi($app, script => '/assets/javascript/pwe.js');
$r = parse_response($res);
is($r->{'status'}, 200, 'statika z PWE/assets bez symlinku 200');
like($r->{'headers'}->{'content-type'} || '', qr/javascript/, 'content-type javascript');

($res, $err) = run_cgi($app, script => '/static/css/site.css');
$r = parse_response($res);
like($r->{'headers'}->{'content-type'} || '', qr{text/css}, 'static/ je v assets_dir -> text/css');
like($r->{'body'}, qr/pwe-footer/, 'obsah site.css');

($res, $err) = run_cgi($app, script => '/conf/web.conf');
is(parse_response($res)->{'status'}, 401, 'conf/ neni servirovan (401)');

($res, $err) = run_cgi($app, query => 'page=pweCreator&func=default');
is(parse_response($res)->{'status'}, 200, 'pweCreator dostupny (development=1 -> admin)');

# ---------------------------------------------------------------------------------------------
# new-module.pl
# ---------------------------------------------------------------------------------------------
($rc, $out) = run_tool("$TOOLS/new-module.pl", 'page', $app, 'kontakt', '--site', 'Default', '--services', 'UserAccount');
is($rc, 0, 'new-module.pl page') or diag($out);
ok(-f "$app/Pages/kontakt/kontakt.pm", 'Pages/kontakt/kontakt.pm');
ok(-f "$app/Pages/kontakt/main.html" && -f "$app/Pages/kontakt/msg.html", 'main.html, msg.html');
ok(-f "$app/Pages/kontakt/rb.tmpl" && -f "$app/Pages/kontakt/rb_EN.tmpl", 'rb.tmpl + rb_EN.tmpl podle conf');
my $src = slurp("$app/Pages/kontakt/kontakt.pm");
like($src, qr/^package Pages::kontakt::kontakt;/m, 'package podle konvence');
like($src, qr/^sub Site_Default/m, 'injektor Site_Default');
like($src, qr/^sub Service_UserAccount/m, 'injektor Service_UserAccount');
like($src, qr/\$USERACCOUNT = \$input/, 'promenna sluzby $USERACCOUNT');
like($src, qr/^sub KOMODO/m, 'blok KOMODO');
like(slurp("$app/Pages/kontakt/rb.tmpl"), qr/\n\n\z/, 'rb stranky konci prazdnym radkem');
my $o = `$^X -I'$app' -I'$ROOT' -c '$app/Pages/kontakt/kontakt.pm' 2>&1`;
like($o, qr/syntax OK/, 'perl -c vygenerovane stranky') or diag($o);

($res, $err) = run_cgi($app, query => 'page=kontakt&func=default');
$r = parse_response($res);
is($r->{'status'}, 200, 'nova stranka odpovida 200') or diag($err);
like($r->{'body'}, qr/<h1>kontakt<\/h1>/, 'nova stranka vykresli main.html s rb');

($rc, $out) = run_tool("$TOOLS/new-module.pl", 'page', $app, 'kontakt');
isnt($rc, 0, 'existujici modul bez --force -> chyba');

($rc, $out) = run_tool("$TOOLS/new-module.pl", 'service', $app, 'Counter', '--services', 'UserAccount');
is($rc, 0, 'new-module.pl service') or diag($out);
$o = `$^X -I'$app' -I'$ROOT' -c '$app/Services/Counter/Counter.pm' 2>&1`;
like($o, qr/syntax OK/, 'perl -c sluzby') or diag($o);
like(slurp("$app/Services/Counter/Counter.pm"), qr/^package Services::Counter::Counter;/m, 'package sluzby');

# smtp-test.pl --dry-run: vypise vysledne SMTP nastaveni (bez site), prepis z --env-file (sekce s podtrzitkem)
my $envf = "$base/smtp.env";
open(my $efh, '>', $envf) or die $!; print $efh "# test\nPWE_CONF_smtp_primary_host=smtp.example.test\nPWE_CONF_smtp_primary_authpw=tajne\n"; close($efh);
($rc, $out) = run_tool("$TOOLS/smtp-test.pl", $app, '--dry-run', '--to', 'test@example.test', '--env-file', $envf);
is($rc, 0, 'smtp-test.pl --dry-run') or diag($out);
like($out, qr/^host:\s+smtp\.example\.test$/m, 'host prepsan z --env-file (sekce smtp_primary s podtrzitkem)');
like($out, qr/^authpw:\s+\*{8}$/m, 'heslo maskovane');
unlike($out, qr/tajne/, 'heslo se nevypisuje');
like($out, qr/^to:\s+test\@example\.test$/m, 'prijemce z --to');
like($out, qr/dry-run: nic se neodesila/, 'dry-run neodesila');
($rc, $out) = run_tool("$TOOLS/smtp-test.pl", $app, '--dry-run', '--server', 'neexistuje');
isnt($rc, 0, 'neznama SMTP sekce -> chyba');
unlink($envf);

# regrese: vzhled/sluzba z enginu povolene v pwe.core_* se nehlasi jako chybejici (tool.web ma core_sites Responsive)
($rc, $out) = run_tool("$TOOLS/new-module.pl", 'page', $app, 'nahled', '--site', 'Responsive');
is($rc, 0, 'new-module.pl page --site Responsive (z core_sites)') or diag($out);
unlike($out, qr/VAROVANI: vzhled/, 'vzhled z pwe.core_sites neni hlasen jako chybejici');
like(slurp("$app/Pages/nahled/nahled.pm"), qr/^sub Site_Responsive/m, 'injektor Site_Responsive vygenerovan');
($rc, $out) = run_tool("$TOOLS/new-module.pl", 'page', $app, 'nahled2', '--site', 'Neexistuje', '--services', 'Session');
like($out, qr/VAROVANI: vzhled Neexistuje/, 'neznamy vzhled je hlasen');
like($out, qr/VAROVANI: sluzba Session/, 'sluzba enginu bez povoleni v core_services je hlasena');
File::Path::remove_tree("$app/Pages/nahled2");   # stranka s neexistujicim vzhledem by rozbila check-webapp.pl nize
ok(!-d "$app/Pages/nahled2", 'testovaci stranka s chybnym vzhledem uklizena');

($rc, $out) = run_tool("$TOOLS/new-module.pl", 'site', $app, 'Admin', '--parent', 'Default');
is($rc, 0, 'new-module.pl site') or diag($out);
my $site = slurp("$app/Sites/Admin/Admin.pm");
like($site, qr/^package Sites::Admin::Admin;/m, 'package vzhledu');
like($site, qr/^sub Site_Default/m, 'rodicovsky vzhled injektovan');
like($site, qr/^sub printHtmlLayout \{ my \$self = shift; return \$WEB->printHtmlLayout\(\@_\); \}/m, 'proxy metoda podle rodice');
unlike($site, qr/^sub (new|KOMODO|AUTOLOAD) \{ my \$self = shift; return \$WEB/m, 'new/KOMODO/AUTOLOAD se neproxuji');
$o = `$^X -I'$app' -I'$ROOT' -c '$app/Sites/Admin/Admin.pm' 2>&1`;
like($o, qr/syntax OK/, 'perl -c vzhledu') or diag($o);

($rc, $out) = run_tool("$TOOLS/new-module.pl", 'entity', $app, 'Item', '--table', 'items');
is($rc, 0, 'new-module.pl entity') or diag($out);
my $ent = slurp("$app/Entities/Item/Item.pm");
like($ent, qr/^package Entities::Item::Item;/m, 'package entity');
like($ent, qr/"db1",\s*"items"/, 'tabulka items nad db1');
$o = `$^X -I'$app' -I'$ROOT' -c '$app/Entities/Item/Item.pm' 2>&1`;
like($o, qr/syntax OK/, 'perl -c entity') or diag($o);

($rc, $out) = run_tool("$TOOLS/new-module.pl", 'entity', $app, 'Bad');
isnt($rc, 0, 'entita bez --table -> chyba');
($rc, $out) = run_tool("$TOOLS/new-module.pl", 'page', $app, '1bad');
isnt($rc, 0, 'neplatny nazev modulu -> chyba');

# ---------------------------------------------------------------------------------------------
# check-webapp.pl
# ---------------------------------------------------------------------------------------------
remove_tree("$app/Entities/Item");    # entita bez DB by se stejne nenacetla
($rc, $out) = run_tool("$TOOLS/check-webapp.pl", $app);
is($rc, 0, 'check-webapp.pl: vygenerovany webapp bez chyb') or diag($out);
unlike($out, qr/^FAIL/m, 'zadny FAIL');
like($out, qr/smoke: \?page=default&func=default -> 200/, 'smoke default');
like($out, qr/pwe\.require_core >=\d+\.\d+ splnen/, 'kontrola verze enginu');
like($out, qr/smoke: neznama stranka -> 404/, 'smoke 404');
like($out, qr/smoke: \?page=kontakt&func=default -> 200/, 'smoke nove stranky');

# rozbity modul: spatny package a chybejici sluzba
make_path("$app/Pages/broken");
open(my $fh, '>', "$app/Pages/broken/broken.pm") or die $!;
print $fh "package Pages::Broken::broken;\nuse strict;\nsub new { my (\$class,\$self) = \@_; bless \$self, \$class; return \$self; }\nsub Service_Nope { }\n1;\n";
close($fh);
($rc, $out) = run_tool("$TOOLS/check-webapp.pl", $app, '--static');
is($rc, 1, 'check-webapp.pl --static: rozbity modul -> navratovy kod 1');
like($out, qr/^FAIL Pages\/broken\/broken\.pm ma package Pages::Broken::broken, ocekavano Pages::broken::broken/m, 'detekce spatneho package');
like($out, qr/^FAIL Pages\/broken injektuje Service_Nope/m, 'detekce neexistujici sluzby');
{
    my $wc = slurp("$app/conf/web.conf");
    $wc =~ s/core_services     => \[\]/core_services     => ["Neexistuje"]/ or die "conf";
    open(my $cf, '>', "$app/conf/web.conf") or die $!; print $cf $wc; close($cf);
    my ($rc2, $out2) = run_tool("$TOOLS/check-webapp.pl", $app, '--static');
    is($rc2, 1, 'neexistujici modul v pwe.core_services -> chyba');
    like($out2, qr/^FAIL pwe\.core_services uvadi 'Neexistuje'/m, 'hlaseni modulu, ktery engine nema');
    $wc =~ s/core_services     => \["Neexistuje"\]/core_services     => []/;
    open($cf, '>', "$app/conf/web.conf") or die $!; print $cf $wc; close($cf);
}
like($out, qr/^WARN Pages\/broken\/broken\.pm nema blok 'sub KOMODO'/m, 'varovani na chybejici KOMODO');
remove_tree("$app/Pages/broken");

# ---------------------------------------------------------------------------------------------
# new-webapp.pl s databazi (jen struktura a kompilace - bez DB serveru)
# ---------------------------------------------------------------------------------------------
my $dbapp = "$base/tooldb.web";
($rc, $out) = run_tool("$TOOLS/new-webapp.pl", 'tooldb.web', '--dir', $dbapp, '--db', 'postgres', '--examples');
is($rc, 0, 'new-webapp.pl --db postgres') or diag($out);
ok(-l "$dbapp/conf/database.conf" && readlink("$dbapp/conf/database.conf") eq 'postgres.conf', 'database.conf -> postgres.conf');
ok(-f "$dbapp/conf/$_", "conf/$_") foreach (qw(mariadb.conf mysql.conf postgres.conf mariadb.dbversion mysql.dbversion postgres.dbversion));
ok(!-e "$dbapp/Services/Session" && !-e "$dbapp/Entities/Entity.pm", 'zadne symlinky na sluzby/entity enginu');
my $dbconf = do("$dbapp/conf/web.conf");
is($dbconf->{'pwe'}->{'save_opt_to'}, 'db', 's DB save_opt_to = db');
is_deeply($dbconf->{'pwe'}->{'core_services'}, ['DBTable', 'Session'], 's DB: sluzby DBTable a Session z enginu (UserAccount vlastni)');
is_deeply($dbconf->{'pwe'}->{'core_entities'}, ['DBTable', 'Session'], 's DB: entity z enginu');
ok(!(grep { $_ eq 'NewBootstrap523' } @{$dbconf->{'pwe'}->{'core_pages'}}), 'NewBootstrap523 uz neexistuje (odstranen)');
ok((grep { $_ eq 'responsive' } @{$dbconf->{'pwe'}->{'core_pages'}}), '--examples s DB: responsive v core_pages');
is_deeply($dbconf->{'pwe'}->{'core_sites'}, ['Responsive'], '--examples s DB: core_sites');
my $pg = do("$dbapp/conf/postgres.conf");
is($pg->{'db1'}->{'dbdriver'}, 'postgres', 'postgres.conf driver');
is($pg->{'db1'}->{'port'}, 5432, 'postgres.conf port');
my $ver = do("$dbapp/conf/mariadb.dbversion");
is(ref($ver), 'HASH', 'dbversion je hash');
like($ver->{1}, qr/CREATE TABLE `dbtable`/, 'dbversion 1 = dbtable');
like($ver->{2}, qr/CREATE TABLE `session`/, 'dbversion 2 = session');
like(slurp("$dbapp/Sites/Default/Default.pm"), qr/^sub Service_Session/m, 'Site s DB ma injektor Session (messenger v DB)');
like(slurp("$dbapp/Services/UserAccount/UserAccount.pm"), qr/\$SESSION->newSession\(\)/, 'UserAccount s DB pouziva Session');
dockerfile_ok("$dbapp/Dockerfile", 'tooldb.web', 'postgres', 'Dockerfile --db postgres');
ok(!-e "$dbapp/entrypoint.sh", 's DB: web nema vlastni entrypoint.sh');
like($out, qr{^  conf/database\.conf -> postgres\.conf }m, 's DB: vypis generatoru uvadi symlink conf/database.conf');
unlike($out, qr/entrypoint\.sh/, 's DB: vypis generatoru zadny entrypoint.sh neuvadi');
like(slurp("$dbapp/README.md"), qr{ghcr\.io/kukam/pwe-postgres\b}, 'README jmenuje behovy image profilu');
like(slurp("$dbapp/README.md"), qr{ghcr\.io/kukam/pwe`}, 'README jmenuje image pwe (zdroj enginu)');
unlike(slurp("$dbapp/README.md"), qr/^\| `entrypoint\.sh` \|/m, 'README nema radek o souboru entrypoint.sh');
unlike(slurp("$dbapp/README.md"), qr{kukam/pwe-base}, 'README neodkazuje na stare rozlozeni (FROM kukam/pwe-base)');
like(slurp("$dbapp/vars"), qr{^export PWE_CONF_pwe_core=/PWE/PWE/$}m, 'vars: PWE_CONF_pwe_core = /PWE/PWE/');
# regrese prejmenovani adresare enginu: vygenerovany web nesmi odkazovat na puvodni adresar (cesta
# "<puvodni nazev>/..." nebo v kontejneru "/PWE/<puvodni nazev>"); klice pwe.core_* a PWE_CONF_pwe_core zustavaji
my $old_dir = 'core';
foreach my $gen (qw(Dockerfile vars README.md conf/web.conf)) {
    unlike(slurp("$dbapp/$gen"), qr{/PWE/\Q$old_dir\E\b|(?<![\w.\$])\Q$old_dir\E/}, "$gen neodkazuje na puvodni adresar enginu ($old_dir)");
}
foreach my $pm (qw(Pages/default/default.pm Sites/Default/Default.pm Services/UserAccount/UserAccount.pm)) {
    my $o2 = `$^X -I'$dbapp' -I'$ROOT' -c '$dbapp/$pm' 2>&1`;
    like($o2, qr/syntax OK/, "DB varianta: perl -c $pm") or diag($o2);
}
($rc, $out) = run_tool("$TOOLS/check-webapp.pl", $dbapp, '--static');
is($rc, 0, 'check-webapp.pl --static na DB variante bez chyb') or diag($out);

# ---------------------------------------------------------------------------------------------
# Dockerfile pro zbyvajici profily (--db mariadb, --db mysql)
# ---------------------------------------------------------------------------------------------
foreach my $drv (qw(mariadb mysql)) {
    my $web = "tool$drv.web";
    ($rc, $out) = run_tool("$TOOLS/new-webapp.pl", $web, '--dir', "$base/$web", '--db', $drv);
    is($rc, 0, "new-webapp.pl --db $drv") or diag($out);
    dockerfile_ok("$base/$web/Dockerfile", $web, $drv, "Dockerfile --db $drv");
    ok(!-e "$base/$web/entrypoint.sh", "--db $drv: web nema vlastni entrypoint.sh");
    ok(-l "$base/$web/conf/database.conf" && readlink("$base/$web/conf/database.conf") eq "$drv.conf", "--db $drv: database.conf -> $drv.conf");
}

# ---------------------------------------------------------------------------------------------
# Dockerfile vygenerovaneho webu: prikaz instrukce RUN (pracovni adresare a conf/database.conf uz pri
# buildu - image pak bezi i s korenovym souborovym systemem jen pro cteni) spusteny tak, jak ho
# spousti docker build: /bin/sh -c v adresari webu, PWE_PROFILE z ENV image.
# ---------------------------------------------------------------------------------------------
SKIP: {
    skip 'prikaz RUN z Dockerfile webu se spousti jen v kontejneru (Linux)', 6 unless ($^O eq 'linux' and -x '/bin/sh');
    my ($run) = dockerfile_instructions(slurp("$dbapp/Dockerfile")) =~ /^RUN (.+)$/m;
    my $img = "$base/image-webu";    # obdoba adresare webu v image: bez docasnych adresaru a bez database.conf (.dockerignore)
    make_path("$img/conf");
    foreach my $f (qw(web.conf mariadb.conf postgres.conf)) {
        open(my $c, '>', "$img/conf/$f") or die $!; print $c "{};\n"; close($c);
    }
    my ($rc_r, $out_r) = run_cmd({cwd => $img, env => {PWE_PROFILE => 'postgres'}}, '/bin/sh', '-c', $run || 'exit 99');
    is($rc_r, 0, 'Dockerfile webu: prikaz RUN skoncil 0') or diag($out_r);
    ok(-d "$img/ramdisk/templates" && -d "$img/sessions" && -d "$img/uploadfile" && -d "$img/log", 'Dockerfile webu: RUN zalozi pracovni adresare');
    ok(-l "$img/conf/database.conf" && readlink("$img/conf/database.conf") eq 'postgres.conf', 'Dockerfile webu: RUN nasmeruje conf/database.conf na konfiguraci profilu');
    ($rc_r, $out_r) = run_cmd({cwd => $img, env => {PWE_PROFILE => 'static'}}, '/bin/sh', '-c', $run || 'exit 99');
    ok($rc_r == 0 && readlink("$img/conf/database.conf") eq 'postgres.conf', 'Dockerfile webu: RUN bez conf/<profil>.conf (profil static) symlink nemeni a neskonci chybou') or diag($out_r);
    unlink("$img/conf/database.conf") or die $!;
    ($rc_r, $out_r) = run_cmd({cwd => $img, env => {PWE_PROFILE => 'static'}}, '/bin/sh', '-c', $run || 'exit 99');
    ok($rc_r == 0 && !-e "$img/conf/database.conf" && !-l "$img/conf/database.conf", 'Dockerfile webu: RUN u webu bez databaze conf/database.conf nevytvari') or diag($out_r);
    open(my $own, '>', "$img/conf/database.conf") or die $!; print $own "{ 'db1' => { dbdriver => 'vlastni' } };\n"; close($own);
    ($rc_r, $out_r) = run_cmd({cwd => $img, env => {PWE_PROFILE => 'mariadb'}}, '/bin/sh', '-c', $run || 'exit 99');
    ok($rc_r == 0 && !-l "$img/conf/database.conf" && slurp("$img/conf/database.conf") =~ /vlastni/, 'Dockerfile webu: RUN bezny soubor conf/database.conf neprepisuje') or diag($out_r);
}

# ---------------------------------------------------------------------------------------------
# entrypoint image PWE (docker/entrypoint.sh; maji ho vsechny image vcetne image webu): podle
# PWE_PROFILE nastavi conf/database.conf, zalozi pracovni adresare a spusti prikaz. Pri nesouladu
# profilu a webu vypise jednoradkove varovani na stderr, start nikdy neprerusi. Jen Linux
# (kontejner): atomicka vymena symlinku pouziva mv -T z GNU coreutils.
# ---------------------------------------------------------------------------------------------
ok(length(slurp($ENTRYPOINT_SRC)) > 0, 'engine ma docker/entrypoint.sh');
SKIP: {
    skip 'entrypoint se testuje jen v kontejneru (Linux, bash)', 43 unless ($^O eq 'linux' and $BASH);
    my $link = "$dbapp/conf/database.conf";
    my %none = (PWE_PROFILE => undef);
    my $errf = "$base/entrypoint.stderr";
    my $warn = qr/\[entrypoint\] VAROVANI: /;

    # Spusti entrypoint (pres bash, zdrojovy soubor nemusi byt spustitelny) s prikazem; vraci
    # (navratovy kod, STDOUT, STDERR). Volba script => jiny soubor entrypointu, ostatni jako run_cmd.
    my $entry = sub {
        my ($o, @cmd) = @_;
        my %o = %{$o};
        my $script = delete($o{'script'}) || $ENTRYPOINT_SRC;
        unlink($errf);
        my ($rc_e, $out_e) = run_cmd({%o, stderr => $errf}, $BASH, $script, @cmd);
        my $err_e = slurp($errf);
        unlink($errf);
        return ($rc_e, $out_e, $err_e);
    };

    # --- profil odpovida webu: zadne varovani ---
    ($rc, $out, $err) = $entry->({cwd => $dbapp, env => {PWE_PROFILE => 'mariadb'}}, 'readlink', 'conf/database.conf');
    is($rc, 0, 'entrypoint: PWE_PROFILE=mariadb skoncil 0') or diag($out . $err);
    is($out, "mariadb.conf\n", 'entrypoint: existujici symlink (postgres.conf) nahrazen za mariadb.conf a prikaz spusten');
    is($err, '', 'entrypoint: prepnuti symlinku bez varovani');
    ($rc, $out, $err) = $entry->({cwd => $dbapp, env => \%none}, 'readlink', 'conf/database.conf');
    is($out, "mariadb.conf\n", 'entrypoint: bez PWE_PROFILE symlink nemeni');
    is($err, '', 'entrypoint: bez PWE_PROFILE zadne varovani');
    ($rc, $out, $err) = $entry->({cwd => $dbapp, env => {PWE_PROFILE => ''}}, 'readlink', 'conf/database.conf');
    is($out . $err, "mariadb.conf\n", 'entrypoint: prazdny PWE_PROFILE = nenastaveny (symlink nemeni, zadne varovani)');
    ($rc, $out, $err) = $entry->({cwd => $dbapp, env => {PWE_PROFILE => 'postgres'}}, 'sh', '-c', 'readlink conf/database.conf; exit 7');
    is($out, "postgres.conf\n", 'entrypoint: PWE_PROFILE=postgres -> postgres.conf');
    is($rc, 7, 'entrypoint: navratovy kod prikazu se zachova (exec "$@")');
    is($err, '', 'entrypoint: PWE_PROFILE=postgres bez varovani');
    ($rc, $out, $err) = $entry->({cwd => $dbapp, env => {PWE_PROFILE => 'postgres'}}, 'readlink', 'conf/database.conf');
    is($out . $err, "postgres.conf\n", 'entrypoint: symlink uz ukazuje na profil -> beze zmeny a bez varovani');
    ok(!(grep { !/^(database|mariadb|mysql|postgres|web)\./ } map { substr($_, length("$dbapp/conf/")) } glob("$dbapp/conf/* $dbapp/conf/.[!.]*")), 'entrypoint: v conf/ nezustal docasny symlink');

    # --- varovani: profil static a v conf/ zustal symlink z jineho profilu ---
    ($rc, $out, $err) = $entry->({cwd => $dbapp, env => {PWE_PROFILE => 'static'}}, 'sh', '-c', 'readlink conf/database.conf; exit 3');
    is($out, "postgres.conf\n", 'entrypoint: PWE_PROFILE=static symlink nemeni a prikaz spusti');
    is($rc, 3, 'entrypoint: PWE_PROFILE=static se symlinkem start neprerusi');
    like($err, qr/\A${warn}PWE_PROFILE=static, ale conf\/database\.conf ukazuje na postgres\.conf\b[^\n]*\n\z/, 'entrypoint: PWE_PROFILE=static a symlink conf/database.conf -> jednoradkove varovani na stderr');

    # --- varovani: neznamy profil (preklep, velka pismena) ---
    ($rc, $out, $err) = $entry->({cwd => $dbapp, env => {PWE_PROFILE => 'MariaDB'}}, 'sh', '-c', 'readlink conf/database.conf; exit 4');
    is($out, "postgres.conf\n", 'entrypoint: neznamy PWE_PROFILE symlink nemeni a prikaz spusti');
    is($rc, 4, 'entrypoint: neznamy PWE_PROFILE start neprerusi');
    like($err, qr/\A${warn}neznamy PWE_PROFILE='MariaDB' \(platne hodnoty: static, mariadb, mysql, postgres\)[^\n]*\n\z/, 'entrypoint: neznamy PWE_PROFILE -> jednoradkove varovani na stderr se seznamem platnych hodnot');
    ($rc, $out, $err) = $entry->({cwd => $dbapp, env => {PWE_PROFILE => "dva\nradky"}}, 'true');
    is(scalar(() = $err =~ /\n/g), 1, 'entrypoint: varovani je jeden radek i s novym radkem v hodnote PWE_PROFILE');

    # --- varovani: databazovy profil a chybi conf/<profil>.conf ---
    rename("$dbapp/conf/mysql.conf", "$dbapp/conf/mysql.conf.off") or die $!;
    ($rc, $out, $err) = $entry->({cwd => $dbapp, env => {PWE_PROFILE => 'mysql'}}, 'sh', '-c', 'readlink conf/database.conf; exit 5');
    is($out, "postgres.conf\n", 'entrypoint: chybi conf/<profil>.conf -> symlink zustava a prikaz se spusti');
    is($rc, 5, 'entrypoint: chybejici conf/<profil>.conf start neprerusi');
    like($err, qr/\A${warn}PWE_PROFILE=mysql, ale conf\/mysql\.conf neexistuje[^\n]*conf\/database\.conf ukazuje na postgres\.conf[^\n]*\n\z/, 'entrypoint: chybi conf/<profil>.conf -> jednoradkove varovani na stderr (vcetne soucasneho stavu symlinku)');
    rename("$dbapp/conf/mysql.conf.off", "$dbapp/conf/mysql.conf") or die $!;

    # --- bezny soubor conf/database.conf = vlastni konfigurace webu: nikdy se neprepisuje, bez varovani ---
    unlink($link) or die $!;
    open(my $own, '>', $link) or die $!; print $own "{ 'db1' => { dbdriver => 'vlastni' } };\n"; close($own);
    ($rc, $out, $err) = $entry->({cwd => $dbapp, env => {PWE_PROFILE => 'mariadb'}}, 'true');
    ok(-f $link && !-l $link && slurp($link) =~ /vlastni/, 'entrypoint: bezny soubor conf/database.conf (vlastni konfigurace webu) se neprepisuje');
    is($err, '', 'entrypoint: bezny soubor conf/database.conf bez varovani');
    ($rc, $out, $err) = $entry->({cwd => $dbapp, env => {PWE_PROFILE => 'static'}}, 'true');
    is($err, '', 'entrypoint: PWE_PROFILE=static a bezny soubor conf/database.conf bez varovani (neni to symlink jineho profilu)');
    unlink($link) or die $!;
    ($rc, $out, $err) = $entry->({cwd => $dbapp, env => {PWE_PROFILE => 'mariadb'}}, 'true');
    ok(-l $link && readlink($link) eq 'mariadb.conf', 'entrypoint: chybejici conf/database.conf vytvori');
    is($err, '', 'entrypoint: vytvoreni conf/database.conf bez varovani');

    remove_tree("$dbapp/ramdisk", "$dbapp/sessions", "$dbapp/uploadfile", "$dbapp/log");
    ($rc, $out, $err) = $entry->({cwd => $dbapp, env => \%none}, 'true');
    ok(-d "$dbapp/ramdisk/templates" && -d "$dbapp/sessions" && -d "$dbapp/uploadfile" && -d "$dbapp/log", 'entrypoint: zalozi ramdisk/templates, sessions, uploadfile a log');

    # --- web bez databaze ---
    ($rc, $out, $err) = $entry->({cwd => $app, env => {PWE_PROFILE => 'static'}}, 'echo', 'bezi');
    is($out, "bezi\n", 'entrypoint webu bez DB: prikaz spusten');
    is($err, '', 'entrypoint webu bez DB s profilem static: zadne varovani');
    ($rc, $out, $err) = $entry->({cwd => $app, env => {PWE_PROFILE => 'mariadb'}}, 'echo', 'bezi');
    is($out, "bezi\n", 'entrypoint webu bez DB s databazovym profilem: prikaz spusten');
    like($err, qr/\A${warn}PWE_PROFILE=mariadb, ale conf\/mariadb\.conf neexistuje[^\n]*conf\/database\.conf neexistuje[^\n]*\n\z/, 'entrypoint webu bez DB s databazovym profilem: jednoradkove varovani');
    ok(!-e "$app/conf/database.conf" && !-l "$app/conf/database.conf", 'entrypoint webu bez DB: conf/database.conf nevznika');

    # --- mimo adresar webu (bez conf/web.conf) jen spusti prikaz, PWE_PROFILE se nepouzije ---
    my $outside = "$base/mimo-web";
    make_path($outside);
    ($rc, $out, $err) = $entry->({cwd => $outside, env => {PWE_PROFILE => 'mariadb'}}, 'echo', 'jen', 'prikaz');
    is($rc, 0, 'entrypoint mimo adresar webu skoncil 0');
    is($out, "jen prikaz\n", 'entrypoint mimo adresar webu jen spusti prikaz');
    ($rc, $out, $err) = $entry->({cwd => $outside, env => {PWE_PROFILE => 'Neznamy'}}, 'echo', 'jen', 'prikaz');
    is($out . $err, "jen prikaz\n", 'entrypoint mimo adresar webu nevaruje ani pri neznamem PWE_PROFILE');
    opendir(my $dh, $outside) or die $!;
    my @left = grep { !/^\.\.?$/ } readdir($dh);
    closedir($dh);
    is(scalar(@left), 0, 'entrypoint mimo adresar webu nic nevytvari');

    # --- web jen pro cteni (read-only root FS, mount :ro): chyby zapisu start neprerusi; varuje se jen
    #     tehdy, kdyz conf/database.conf profilu neodpovida. Adresar je mimo mount repozitare (/tmp
    #     kontejneru) a prikaz bezi bez prav roota - root by do adresare bez prava zapisu zapsal.
    require File::Temp;
    my $tmp = File::Temp::tempdir('pwe-entrypoint-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $ro  = "$tmp/ro.web";
    make_path("$ro/conf");
    foreach my $f (qw(web.conf mariadb.conf mysql.conf)) {
        open(my $c, '>', "$ro/conf/$f") or die $!; print $c "{};\n"; close($c);
    }
    symlink('mysql.conf', "$ro/conf/database.conf") or die $!;
    open(my $src, '<', $ENTRYPOINT_SRC) or die $!; my $sh = do { local $/; <$src> }; close($src);
    open(my $cp, '>', "$tmp/entrypoint.sh") or die $!; print $cp $sh; close($cp);
    chmod(0755, $tmp, "$tmp/entrypoint.sh");
    chmod(0555, $ro, "$ro/conf");
    my %ro = (cwd => $ro, script => "$tmp/entrypoint.sh", drop_root => 1);
    my ($rc_p) = run_cmd({cwd => $ro, drop_root => 1}, '/bin/sh', '-c', ': > conf/.zkouska');
  SKIP: {
        skip 'adresar bez prava zapisu je pro testovaciho uzivatele porad zapisovatelny (nelze zahodit prava roota)', 7 if ($rc_p == 0 or $rc_p == 124);
        ($rc, $out, $err) = $entry->({%ro, env => {PWE_PROFILE => 'mariadb'}}, 'sh', '-c', 'readlink conf/database.conf; exit 6');
        is($out, "mysql.conf\n", 'entrypoint: conf/ jen pro cteni -> symlink zustava a prikaz se spusti');
        is($rc, 6, 'entrypoint: chyba zapisu do conf/ start neprerusi');
        like($err, qr/\A${warn}conf\/database\.conf se nepodarilo nasmerovat na mariadb\.conf \(PWE_PROFILE=mariadb[^\n]*conf\/database\.conf ukazuje na mysql\.conf[^\n]*\n\z/, 'entrypoint: symlink nejde nastavit a profilu neodpovida -> jednoradkove varovani na stderr');
        ($rc, $out, $err) = $entry->({%ro, env => {PWE_PROFILE => 'mysql'}}, 'sh', '-c', 'readlink conf/database.conf; exit 6');
        is($out . $err, "mysql.conf\n", 'entrypoint: conf/ jen pro cteni, ale symlink profilu odpovida -> bez varovani');
        is($rc, 6, 'entrypoint: web jen pro cteni s odpovidajicim symlinkem start neprerusi');
        ok(!-e "$ro/ramdisk" && !-e "$ro/log", 'entrypoint: pracovni adresare v adresari jen pro cteni nevznikly a chyba se nehlasi (ohlasi ji engine)');
        opendir(my $cd, "$ro/conf") or die $!;
        is(join(' ', sort grep { !/^\.\.?$/ } readdir($cd)), 'database.conf mariadb.conf mysql.conf web.conf', 'entrypoint: v conf/ jen pro cteni nic nepribylo');
        closedir($cd);
    }
    chmod(0755, $ro, "$ro/conf");
}

# ---------------------------------------------------------------------------------------------
# .dockerignore v koreni repozitare: do image webu se nesmi dostat soukrome klice a lokalni soubory
# webu (webapps/<web>/Dockerfile kopiruje cely adresar webu); konfigurace a verejne klice zustavaji
# ---------------------------------------------------------------------------------------------
SKIP: {
    my $ignore = slurp(dirname($ROOT) . '/.dockerignore');
    my @secret = (
        'conf/private.pem', 'conf/csob/private.pem', 'conf/csob/2026/merchant/private.pem', 'conf/server.key', 'conf/csob/rsa_M1TEST.key',
        'conf/klient.p12', 'conf/csob/klient.pfx', 'conf/local.env', 'conf/database.conf', '.env', '.vscode/launch.json', '.git/config',
        'log/pwe.log', 'sessions/C0AA', 'ramdisk/templates/x.tmplc', 'uploadfile/faktura.pdf',
        'keys/private.pem', 'private.key', 'conf/csob/PRIVATE.PEM', 'conf/.env', 'conf/csob/local.env',
    );
    my @kept = (
        'conf/web.conf', 'conf/mariadb.conf', 'conf/mariadb.dbversion', 'conf/local.env.example', 'conf/csob/README',
        'conf/csob/mips_platebnibrana.csob.cz.pub', 'Pages/default/default.pm', 'Pages/default/rb.tmpl', 'static/css/site.css', 'Dockerfile', 'README.md',
    );
    skip '.dockerignore neni k dispozici (engine bez korene repozitare)', scalar(@secret) + scalar(@kept) + 1 unless (length($ignore));
    my @patterns = grep { length($_) and $_ !~ /^#/ } map { my $l = $_; $l =~ s/^\s+|\s+$//g; $l } split(/\n/, $ignore);
    ok(dockerignore_excludes(\@patterns, "webapps/muj.web/$_"), ".dockerignore: webapps/<web>/$_ se do image webu nedostane") foreach (@secret);
    ok(!dockerignore_excludes(\@patterns, "webapps/muj.web/$_"), ".dockerignore: webapps/<web>/$_ v image webu zustava") foreach (@kept);
    ok(!(grep { dockerignore_excludes(\@patterns, $_) } qw(PWE/pwe.fcgi PWE/Libs/Web.pm PWE/docker/entrypoint.sh PWE/tools/new-webapp.pl PWE/VERSION LICENSE)), '.dockerignore: soubory enginu pro image pwe a pwe-base zustavaji v kontextu');
}

# ---------------------------------------------------------------------------------------------
# Dockerfile enginu (docker/Dockerfile): rodokmen stage, balicky zakladniho image (jen to, co
# potrebuje beh enginu a webu), ladici nastroje jen v image debugger
# ---------------------------------------------------------------------------------------------
SKIP: {
    my $engine_df = slurp("$ROOT/docker/Dockerfile");
    skip 'docker/Dockerfile neni k dispozici', 27 unless (length($engine_df));
    my (@stages, %from, %body);
    foreach my $line (split(/\n/, dockerfile_instructions($engine_df))) {
        if ($line =~ /^FROM\s+(\S+)\s+AS\s+(\S+)$/i) {
            push(@stages, $2);
            $from{$2} = $1;
            $body{$2} = '';
        } elsif (@stages) {
            $body{$stages[-1]} .= "$line\n";
        }
    }
    # balicky instalovane v kazdem stage (apt-get install ... ;)
    my %pkg;
    foreach my $st (@stages) {
        $pkg{$st} = [map { split(' ', $_) } ($body{$st} =~ /apt-get install -y --no-install-recommends ([^;]*);/g)];
    }
    my $has_pkg = sub { my ($st, $name) = @_; return scalar(grep { $_ eq $name } @{$pkg{$st} || []}); };

    is_deeply(\@stages, [qw(base pwe static mariadb mysql postgres debugger)], 'Dockerfile enginu: stage base, pwe, static, mariadb, mysql, postgres, debugger (kazdy = jeden image)');
    is($from{'base'}, '${UBUNTU_IMAGE}', 'Dockerfile enginu: base vychazi z image Ubuntu (jediny vnejsi zaklad)');
    is($from{$_}, 'base', "Dockerfile enginu: stage $_ vychazi z base") foreach (qw(pwe static mariadb mysql postgres debugger));

    is_deeply([sort @{$pkg{'base'}}], [sort qw(
        perl libcgi-pm-perl libcgi-fast-perl libtemplate-perl libclass-inspector-perl libmoose-perl libjson-perl libjson-xs-perl libdbi-perl
        libmail-rfc822-address-perl cstocs liblwp-mediatypes-perl libio-socket-ssl-perl libnet-ssleay-perl libauthen-sasl-perl ca-certificates
        ruby-sass imagemagick tzdata
        libimage-magick-perl libcrypt-openssl-rsa-perl openssl liburi-perl libhtml-parser-perl
    )], 'Dockerfile enginu: base instaluje prave balicky pro beh enginu a webu (novy balicek = vedoma zmena tohoto seznamu)');
    ok($has_pkg->('base', 'tzdata'), 'Dockerfile enginu: base ma tzdata (bez nej nema promenna TZ ucinek)');
    like($body{'base'}, qr{\btest -f /usr/share/zoneinfo/Europe/Prague;}, 'Dockerfile enginu: build base overuje databazi casovych pasem (Europe/Prague)');
    unlike(join('', values %body), qr{^ENV .*\bTZ=}m, 'Dockerfile enginu: zadny stage nenastavuje TZ (vychozi pasmo zustava UTC, meni se promennou TZ za behu)');
    ok(!(grep { $has_pkg->('base', $_) } qw(libwww-perl liblwp-protocol-https-perl libdata-uuid-perl libdata-guid-perl libcrypt-openssl-x509-perl)), 'Dockerfile enginu: base nema knihovny, ktere engine ani weby nepouzivaji (LWP, Data::UUID, Data::GUID, Crypt::OpenSSL::X509)');
    ok($has_pkg->('base', 'liblwp-mediatypes-perl'), 'Dockerfile enginu: LWP::MediaTypes (Libs::Send) zustava ze samostatneho balicku');
    ok(!(grep { /^libdbd-/ } @{$pkg{'base'}}), 'Dockerfile enginu: base nema zadny databazovy ovladac');
    ok($has_pkg->('debugger', 'curl'), 'Dockerfile enginu: curl je v image debugger');
    ok(!(grep { $has_pkg->($_, 'curl') } grep { $_ ne 'debugger' } @stages), 'Dockerfile enginu: curl neni v zadnem jinem image nez debugger');
    is_deeply($pkg{'pwe'},    [], 'Dockerfile enginu: stage pwe nic neinstaluje (jen kod enginu nad base)');
    is_deeply($pkg{'static'}, [], 'Dockerfile enginu: stage static nic neinstaluje (obsahem = base)');
    is_deeply([sort @{$pkg{'mariadb'}}],  [qw(libdbd-mariadb-perl libdbd-mysql-perl)], 'Dockerfile enginu: stage mariadb = base + DBD::mysql a DBD::MariaDB');
    is_deeply([sort @{$pkg{'mysql'}}],    ['libdbd-mysql-perl'],                        'Dockerfile enginu: stage mysql = base + DBD::mysql');
    is_deeply([sort @{$pkg{'postgres'}}], ['libdbd-pg-perl'],                           'Dockerfile enginu: stage postgres = base + DBD::Pg');
    ok(!(grep { !$has_pkg->('debugger', $_) } qw(libdbd-mysql-perl libdbd-mariadb-perl libdbd-pg-perl cpanminus)), 'Dockerfile enginu: debugger ma vsechny tri ovladace a cpanm');
    like($body{'debugger'}, qr{^ENV PERL_CPANM_OPT="--from https://www\.cpan\.org/"$}m, 'Dockerfile enginu: cpanm v image debugger stahuje jen pres HTTPS (PERL_CPANM_OPT)');
    like($body{'base'}, qr{^COPY --chmod=0755 PWE/docker/entrypoint\.sh /usr/local/bin/entrypoint\.sh$}m, 'Dockerfile enginu: base instaluje docker/entrypoint.sh jako spustitelny');
    like($body{'base'}, qr{^ENTRYPOINT \["/usr/local/bin/entrypoint\.sh"\]$}m, 'Dockerfile enginu: base nastavuje ENTRYPOINT');
    ok(!(grep { $body{$_} =~ /^(?:ENTRYPOINT|CMD)\b/m } grep { $_ ne 'base' } @stages), 'Dockerfile enginu: odvozene stage ENTRYPOINT ani CMD neprepisuji (dedi je z base)');
}

# ---------------------------------------------------------------------------------------------
# vzorove weby v repozitari pouzivaji tutez sablonu: Dockerfile = vystup generatoru (lisi se jen
# nazvem webu a PWE_PROFILE), vlastni entrypoint.sh nemaji
# ---------------------------------------------------------------------------------------------
foreach my $ex (['example.web', 'none', 'static'], ['example-db.web', 'mariadb', 'mariadb']) {
    my ($web, $db, $profile) = @{$ex};
    my $dir = dirname($ROOT) . "/webapps/$web";
  SKIP: {
        skip "webapps/$web neni k dispozici ($dir)", $DOCKERFILE_TESTS + 3 unless (-f "$dir/conf/web.conf");
        ($rc, $out) = run_tool("$TOOLS/new-webapp.pl", $web, '--dir', "$base/vzor/$web", '--db', $db);
        is($rc, 0, "new-webapp.pl $web --db $db (vzor pro porovnani)") or diag($out);
        dockerfile_ok("$dir/Dockerfile", $web, $profile, "webapps/$web/Dockerfile");
        ok(slurp("$dir/Dockerfile") eq slurp("$base/vzor/$web/Dockerfile"), "webapps/$web/Dockerfile je shodny s vystupem generatoru");
        ok(!-e "$dir/entrypoint.sh", "webapps/$web nema vlastni entrypoint.sh (image webu ho dedi z image pwe-<profil>)");
    }
}

remove_tree($base);
done_testing();
