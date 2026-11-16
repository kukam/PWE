#!/usr/bin/env perl
# Nastroje enginu PWE/tools/ (new-webapp.pl, new-module.pl, check-webapp.pl, smtp-test.pl):
# vygenerovany webapp se nacte a obslouzi requesty (CGI rezim). Dale jmena image (PWE::ToolEnv proti
# shell funkcim tools/lib/images.sh; tag = verze enginu z VERSION, bez gitu; profil static -> pwe-base),
# Dockerfile webu (jediny FROM = zavislostni image bez enginu - pwe-base pro web bez databaze, pwe-<profil>
# pro web s databazi; engine se kopiruje z kontextu sestaveni a sablona pokryva kazdou polozku korene enginu
# krome t a docker; zadny mazaci RUN; zadny vlastni entrypoint), check-webapp.pl nad Dockerfile webu (varovani
# na starsi sablony, na chybejici polozku enginu a na jiny radek FROM), Dockerfile zavislostnich image (stage
# base, mariadb, mysql, postgres, debugger - bez enginu a bez webu; balicky), docker-compose.yml,
# .dockerignore (soukrome klice webu, docasna data, testy enginu) a entrypoint image docker/entrypoint.sh
# (symlink conf/database.conf, varovani vcetne vzoroveho webu zapeceneho v image a spusteneho jako server).
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

# Polozky korene enginu (PWE/<polozka>), ktere Dockerfile kopiruje z kontextu sestaveni: { polozka => cil }.
# Dostane instrukce (dockerfile_instructions); COPY --from se nepocita, volby (--link) se preskakuji.
sub dockerfile_engine_sources {
    my ($ins) = @_;
    my %src;
    foreach my $copy ($ins =~ /^COPY ([^\n]+)$/mg) {
        next if ($copy =~ /(?:^| )--from=/);
        my @words = grep { !/^--/ } split(' ', $copy);
        my $dest  = pop(@words);
        foreach my $s (@words) { $src{$1} = $dest if ($s =~ m{^PWE/([^/]+)/?$}); }
    }
    return \%src;
}

# Kontroly Dockerfile webu podle jednotne sablony. Image webu = zavislostni image + engine + web:
#   - jediny FROM = zavislostni image BEZ enginu: pwe-base pro web bez databaze (profil static), pwe-${PWE_PROFILE}
#     pro web s databazi,
#   - engine z kontextu sestaveni: COPY LICENSE a COPY PWE/<polozka> pro kazdou polozku korene enginu krome
#     t a docker (PWE::ToolEnv::engine_image_entries) - nova polozka enginu, kterou sablona nekopiruje, test shodi,
#   - web z webapps/<web>; entrypoint zdedeny ze zakladniho image; jedina instrukce RUN (pracovni adresare a
#     symlink conf/database.conf) - sablona nic nemaze.
# Vraci seznam [nazev, kontrola]; kontrola dostane instrukce (dockerfile_instructions) a vraci pravdu.
# Seznam je zaroven pocet testu v dockerfile_ok().
sub dockerfile_checks {
    my ($web, $profile) = @_;
    my $w       = quotemeta($web);
    my $image   = ($profile eq 'static') ? 'pwe-base' : 'pwe-${PWE_PROFILE}';
    my $base    = '${PWE_IMAGE_REGISTRY}/' . $image . ':${PWE_IMAGE_TAG}';
    my $runtime = quotemeta($base);
    my @entries = PWE::ToolEnv::engine_image_entries($ROOT);
    my $has     = sub { my ($re) = @_; return sub { $_[0] =~ $re }; };
    my $hasnt   = sub { my ($re) = @_; return sub { $_[0] !~ $re }; };
    my $times   = sub { my ($re, $n) = @_; return sub { my $c = () = $_[0] =~ /$re/g; $c == $n }; };
    # instrukce za FROM
    my $stage = sub { my ($ins) = @_; my ($st) = $ins =~ /^FROM $runtime\n(.*)\z/ms; return defined($st) ? $st : ''; };
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
    my $run_dirs = qr{^RUN set -eu; mkdir -p ramdisk/templates sessions uploadfile log; }m;
    return (
        ['ARG PWE_IMAGE_REGISTRY (vychozi ghcr.io/kukam)',                             $has->(qr{^ARG PWE_IMAGE_REGISTRY=ghcr\.io/kukam$}m)],
        ['ARG PWE_IMAGE_TAG (vychozi latest)',                                         $has->(qr{^ARG PWE_IMAGE_TAG=latest$}m)],
        ["ARG PWE_PROFILE=$profile",                                                   $has->(qr{^ARG PWE_PROFILE=\Q$profile\E$}m)],
        ['vychozi hodnota PWE_PROFILE je nastavena prave jednou',                      $times->(qr{^ARG PWE_PROFILE=}m, 1)],
        ["jediny FROM: zavislostni image $image:<tag> (web bez databaze pwe-base, web s databazi pwe-<profil>)", sub { my @from = $_[0] =~ /^FROM (.*)$/mg; return (@from == 1 and $from[0] eq $base); }],
        ['zadne COPY --from (engine se nekopiruje z jineho image ani stage)',          $hasnt->(qr{^COPY\s+(?:--\S+\s+)*--from\b}m)],
        ['zadny zbytek starsich usporadani (PWE_ENGINE_TAG, image pwe jako zdroj enginu, zaklad pwe-static, tag master)', $hasnt->(qr{PWE_ENGINE_TAG|/pwe:|pwe-static|=master\b})],
        ['zadna kontrola enginu v zakladnim image (zavislostni image engine neobsahuje - sestaveni by skoncilo chybou)', $hasnt->(qr{test -f /PWE/PWE/pwe\.fcgi})],
        ['ARG PWE_PROFILE, PWE_IMAGE_REGISTRY a PWE_IMAGE_TAG znovu deklarovany za FROM pred ENV a LABEL (jinak by dostaly prazdnou hodnotu)', sub {
            my $st = $stage->($_[0]);
            my ($head) = $st =~ /\A(.*?)^(?:ENV|LABEL) /ms;
            return (defined($head) and !(grep { $head !~ /^ARG \Q$_\E$/m } qw(PWE_PROFILE PWE_IMAGE_REGISTRY PWE_IMAGE_TAG)));
        }],
        ['engine z kontextu sestaveni: COPY LICENSE do /PWE/LICENSE',                  $has->(qr{^COPY (?:--link )?LICENSE /PWE/LICENSE$}m)],
        ['engine z kontextu sestaveni: COPY PWE/<polozka> pro KAZDOU polozku korene enginu krome t a docker (nova polozka enginu nesmi v image tise chybet)', sub {
            my $src = dockerfile_engine_sources($_[0]);
            my @missing = grep { !exists($src->{$_}) } @entries;
            diag("sablona nekopiruje polozky enginu: @missing - dopln COPY do gen_dockerfile (PWE/tools/new-webapp.pl) a vygeneruj znovu Dockerfile vzorovych webu") if (@missing);
            return (@entries > 10 and !@missing);
        }],
        ['engine: kopiruji se jen existujici polozky enginu - zadne testy (PWE/t), sestaveni image (PWE/docker) ani cely adresar PWE', sub {
            my $src = dockerfile_engine_sources($_[0]);
            my %known = map { $_ => 1 } @entries;
            return (!(grep { !$known{$_} } keys %{$src}) and $_[0] !~ m{^COPY (?:--\S+ )*(?:\S+ )*PWE/? }m);
        }],
        ['engine: cil kazde polozky je /PWE/PWE (adresar do /PWE/PWE/<adresar>, soubory do /PWE/PWE/)', sub {
            my $src = dockerfile_engine_sources($_[0]);
            return !(grep { my $d = $src->{$_}; !((-d "$ROOT/$_") ? ($d eq "/PWE/PWE/$_") : ($d eq '/PWE/PWE/' or $d eq "/PWE/PWE/$_")) } keys %{$src});
        }],
        ['COPY webu z kontextu do /PWE/webapps/<web> (cesta od korene repozitare, absolutni cil)', $has->(qr{^COPY (?:--link )?webapps/$w /PWE/webapps/$w$}m)],
        ['z kontextu se kopiruje prave jeden web - tento',                             sub { my @webs = $_[0] =~ m{^COPY (?:--\S+ )*webapps/(\S+) }mg; return (@webs == 1 and $webs[0] eq $web); }],
        ['zadna instrukce ADD (soubory se kopiruji pres COPY)',                        $hasnt->(qr{^ADD\b}m)],
        ['ENV PWE_CONF_pwe_home = adresar webu, PWE_PROFILE zapeceny do image (entrypoint nastavi conf/database.conf i bez -e)', $has->(qr{^ENV PWE_CONF_pwe_home=/PWE/webapps/$w PWE_PROFILE=\$\{PWE_PROFILE\}$}m)],
        ['jediny WORKDIR = adresar webu (entrypoint tam hleda conf/web.conf)',         sub { my @wd = $_[0] =~ /^WORKDIR (\S+)$/mg; return (@wd == 1 and $wd[0] eq "/PWE/webapps/$web"); }],
        ['zadny ENTRYPOINT: image webu ho dedi ze zakladniho image (pwe-base)',        $hasnt->(qr{^ENTRYPOINT\b}m)],
        ['zadna instrukce nepracuje s entrypoint.sh (web vlastni kopii nema)',         $hasnt->(qr{entrypoint\.sh})],
        ['zadna instrukce USER (image bezi pod stejnym uzivatelem jako zakladni image)', $hasnt->(qr{^USER\b}m)],
        ['prave jedna instrukce RUN - zalozeni pracovnich adresaru (zadny dalsi prikaz se pri sestaveni nespousti)', sub { my @run = $_[0] =~ /^RUN [^\n]*$/mg; return (@run == 1 and $run[0] =~ $run_dirs); }],
        ['zadna instrukce nic nemaze (rm, rmdir, unlink, find -delete): vzorovy web ani nic jineho v zakladu neni a prikaz RUN spousti i tento test', $hasnt->(qr{\brm\b|\brmdir\b|\bunlink\b|-delete\b})],
        ['zadna instrukce nezaklada znacku vzoroveho webu .pwe-sample-web (vzorovy web se pozna podle jmena adresare)', $hasnt->(qr{pwe-sample-web})],
        ['RUN zalozi pracovni adresare ramdisk/templates, sessions, uploadfile a log', $has->(qr{^RUN .*\bmkdir -p ramdisk/templates sessions uploadfile log;}m)],
        ['RUN nasmeruje conf/database.conf na conf/<PWE_PROFILE>.conf, jen kdyz ten soubor existuje', $has->(qr{^RUN .*\bif \[ -f "conf/\$\{PWE_PROFILE\}\.conf" \].*; then ln -s\w* "\$\{PWE_PROFILE\}\.conf" conf/database\.conf; fi$}m)],
        ['LABEL title = nazev webu',                                                   $has->(qr{^LABEL .*\borg\.opencontainers\.image\.title="$w"(?: |$)}m)],
        ['LABEL description = web nad PWE',                                            $has->(qr{^LABEL .*\borg\.opencontainers\.image\.description="Web $w nad PWE\b[^"]*"(?: |$)}m)],
        ['LABEL version, source a licenses jsou prazdne (jinak by se zdedily udaje zavislostniho image)', sub { my $ins = $_[0]; return !(grep { $ins !~ /^LABEL .*\borg\.opencontainers\.image\.\Q$_\E=""(?: |$)/m } qw(version source licenses)); }],
        ['LABEL base.name = zavislostni image, ze ktereho se stavi (stejny jako ve FROM)', $has->(qr{^LABEL .*\borg\.opencontainers\.image\.base\.name="$runtime"(?: |$)}m)],
        ['CMD spousti engine z /PWE/PWE a je posledni instrukci',                      $has->(qr{^CMD \["perl", "/PWE/PWE/pwe\.fcgi"\]\n?\z}m)],
        # ARG pred FROM (jinak je FROM nevidi), engine pred webem (zmena webu nezneplatni vrstvy enginu),
        # RUN s adresari az nad zkopirovanym webem v jeho adresari
        ['poradi instrukci: ARG, FROM, COPY enginu (LICENSE, PWE/...), COPY webu, ENV, WORKDIR webu, RUN mkdir, CMD', $ordered->(
            qr{^ARG PWE_IMAGE_REGISTRY=}m, qr{^ARG PWE_PROFILE=}m, qr{^FROM $runtime$}m, qr{^COPY (?:--link )?LICENSE }m, qr{^COPY (?:--link )?PWE/Libs }m, qr{^COPY (?:--link )?PWE/pwe\.fcgi }m,
            qr{^COPY (?:--link )?webapps/$w }m, qr{^ENV PWE_CONF_pwe_home=}m, qr{^WORKDIR /PWE/webapps/$w$}m, $run_dirs, qr{^CMD }m)],
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
# jmena image: PWE::ToolEnv (Perl nastroje) musi davat totez co tools/lib/images.sh (shell nastroje).
# Kazdy image ma tagy <verze> a latest; vychozi tag nastroju = verze enginu ze souboru VERSION -
# bez gitu a bez ohledu na vetev. Testy nezavisi na konkretnim cisle verze (ctou ho ze souboru).
# ---------------------------------------------------------------------------------------------
{
    my $images_sh = "$TOOLS/lib/images.sh";
    (my $version = slurp("$ROOT/VERSION")) =~ s/\s+//g;
    like($version, qr/^[0-9]+\.[0-9]+\.[0-9]+$/, 'VERSION enginu ma tvar X.Y.Z (je to tag vsech image)');

    # tag podle vetve gitu zanikl: prevod nazvu vetve ani dotazy na git v Perl nastrojich nejsou
    my $toolenv_src = slurp("$TOOLS/lib/PWE/ToolEnv.pm");
    ok(!PWE::ToolEnv->can('image_tag_sanitize') && !PWE::ToolEnv->can('_git_branch'), 'ToolEnv: image_tag_sanitize() a zjistovani vetve gitu uz neexistuji');
    ok(!(grep { $_ eq 'image_tag_sanitize' } @PWE::ToolEnv::EXPORT_OK) && (grep { $_ eq 'image_version' } @PWE::ToolEnv::EXPORT_OK), 'ToolEnv: exportuje image_version, ne image_tag_sanitize');
    unlike($toolenv_src, qr/symbolic-ref|rev-parse|\bgit -C\b/, 'ToolEnv.pm: zadny dotaz na git (tag image na gitu nezavisi)');
    my $images_src = slurp($images_sh);
    unlike($images_src, qr/^pwe_image_(?:branch|tag_sanitize)\s*\(\)/m, 'images.sh: funkce pwe_image_branch a pwe_image_tag_sanitize uz neexistuji');
    unlike($images_src, qr/symbolic-ref/, 'images.sh: vetev gitu se nezjistuje');
    like($images_src, qr/^pwe_image_version\s*\(\)/m, 'images.sh: funkce pwe_image_version');

    # registr, tag a image nastroju podle promennych prostredi; vychozi tag = verze enginu, stejne
    # v kontejneru (PWE_TOOLS_IN_DOCKER=1) i mimo nej a i bez jedineho programu v PATH (git se nevola)
    local %ENV = %ENV;
    delete @ENV{qw(PWE_TEST_IMAGE PWE_IMAGE_REGISTRY PWE_IMAGE_TAG)};
    $ENV{'PWE_TOOLS_IN_DOCKER'} = 1;
    is(PWE::ToolEnv::image_version(), $version, 'image_version() = obsah VERSION bez bilych znaku');
    is(PWE::ToolEnv::image_registry(), 'ghcr.io/kukam', 'image_registry(): vychozi ghcr.io/kukam');
    is(PWE::ToolEnv::image_tag(), $version, 'image_tag(): bez PWE_IMAGE_TAG -> verze enginu (VERSION)');
    is(PWE::ToolEnv::docker_image(), "ghcr.io/kukam/pwe-debugger:$version", 'docker_image(): vychozi image nastroju je pwe-debugger:<verze>');
    {
        local $ENV{'PATH'} = '/nonexistent';
        no warnings 'redefine';
        local *PWE::ToolEnv::in_container = sub { return 0; };
        is(PWE::ToolEnv::image_tag(), $version, 'image_tag(): mimo kontejner a bez gitu v PATH take verze enginu (zadna zavislost na gitu ani vetvi)');
    }
    $ENV{'PWE_IMAGE_TAG'} = 'latest';
    is(PWE::ToolEnv::image_tag(), 'latest', 'image_tag(): PWE_IMAGE_TAG');
    is(PWE::ToolEnv::docker_image(), 'ghcr.io/kukam/pwe-debugger:latest', 'docker_image(): tag z PWE_IMAGE_TAG');
    is(PWE::ToolEnv::image_version(), $version, 'image_version(): PWE_IMAGE_TAG verzi enginu nemeni');
    $ENV{'PWE_IMAGE_REGISTRY'} = 'registry.example.test/tym/';
    is(PWE::ToolEnv::image_registry(), 'registry.example.test/tym', 'image_registry(): PWE_IMAGE_REGISTRY bez koncoveho lomitka');
    is(PWE::ToolEnv::docker_image(), 'registry.example.test/tym/pwe-debugger:latest', 'docker_image(): registr z PWE_IMAGE_REGISTRY');
    $ENV{'PWE_TEST_IMAGE'} = 'ghcr.io/kukam/pwe-base:jina';
    is(PWE::ToolEnv::docker_image(), 'ghcr.io/kukam/pwe-base:jina', 'docker_image(): PWE_TEST_IMAGE ma prednost pred registrem i tagem');
    is(PWE::ToolEnv::image_tag(), 'latest', 'image_tag(): PWE_TEST_IMAGE tag ostatnich image nemeni');
    $ENV{'PWE_IMAGE_TAG'} = 'vetev/s-lomitkem';
    is(PWE::ToolEnv::docker_image(), 'ghcr.io/kukam/pwe-base:jina', 'docker_image(): s PWE_TEST_IMAGE se PWE_IMAGE_TAG nepouzije ani nekontroluje');
    ok(!defined(eval { PWE::ToolEnv::image_tag() }) && $@ =~ /PWE_IMAGE_TAG='vetev\/s-lomitkem' neni platny tag image/, 'image_tag(): neplatny PWE_IMAGE_TAG -> die');
    unlike($@, qr/sanitize/, 'image_tag(): hlaska o neplatnem tagu neodkazuje na zrusenou funkci pwe_image_tag_sanitize');
    $ENV{'PWE_IMAGE_TAG'}  = 'latest';
    $ENV{'PWE_TEST_IMAGE'} = '';
    is(PWE::ToolEnv::docker_image(), 'registry.example.test/tym/pwe-debugger:latest', 'docker_image(): prazdne PWE_TEST_IMAGE = nenastaveno');
    $ENV{'PWE_IMAGE_REGISTRY'} = '';
    $ENV{'PWE_IMAGE_TAG'}      = '';
    is(PWE::ToolEnv::docker_image(), "ghcr.io/kukam/pwe-debugger:$version", 'docker_image(): prazdne PWE_IMAGE_REGISTRY a PWE_IMAGE_TAG = vychozi');

    # image PWE: 5 zavislostnich (jen knihovny) a 4 image vzorovych webu; zrusene image pwe a pwe-static mezi nimi nejsou
    my @deps     = qw(pwe-base pwe-mariadb pwe-mysql pwe-postgres pwe-debugger);
    my @examples = qw(pwe-example-static pwe-example-mariadb pwe-example-mysql pwe-example-postgres);
    is_deeply([PWE::ToolEnv::image_names('deps')],     \@deps,     'image_names(deps): zavislostni image pwe-base, pwe-mariadb, pwe-mysql, pwe-postgres, pwe-debugger');
    is_deeply([PWE::ToolEnv::image_names('examples')], \@examples, 'image_names(examples): image vzorovych webu pwe-example-static, -mariadb, -mysql, -postgres');
    is_deeply([PWE::ToolEnv::image_names()],           [@deps, @examples], 'image_names(): vsech 9 image, zavislostni pred vzorovymi');
    is_deeply([PWE::ToolEnv::image_names('all')],      [@deps, @examples], 'image_names(all) = image_names()');
    ok(!(grep { $_ eq 'pwe' or $_ eq 'pwe-static' } PWE::ToolEnv::image_names()), 'image_names(): zrusene image pwe a pwe-static mezi image PWE nejsou');
    ok(!defined(eval { PWE::ToolEnv::image_names('profily') }) && $@ =~ /Neznama skupina image 'profily'/, 'image_names(): neznama skupina -> die');
    # zavislostni image profilu: web bez databaze (static) bezi nad pwe-base, databazove profily nad pwe-<profil>
    is(PWE::ToolEnv::profile_image('static'), 'pwe-base', 'profile_image(static) = pwe-base (profil static nema vlastni image)');
    is(PWE::ToolEnv::profile_image($_), "pwe-$_", "profile_image($_) = pwe-$_") foreach (qw(mariadb mysql postgres));
    foreach my $bad ('', 'Static', 'oracle', 'base', 'pwe-base', "mysql\n", undef) {
        my $show = defined($bad) ? "'$bad'" : 'undef';
        $show =~ s/\n/\\n/g;
        ok(!defined(eval { PWE::ToolEnv::profile_image($bad) }) && $@ =~ /^Neznamy profil '.*' \(static \| mariadb \| mysql \| postgres\)$/s, "profile_image($show): neznamy profil -> die");
    }
    # zaklad v radku FROM Dockerfile webu: bez databaze pevny pwe-base, s databazi pwe-${PWE_PROFILE} (argument sestaveni)
    is(PWE::ToolEnv::dockerfile_base('static'), 'pwe-base', 'dockerfile_base(static) = pwe-base');
    is(PWE::ToolEnv::dockerfile_base($_), 'pwe-${PWE_PROFILE}', "dockerfile_base($_) = pwe-\${PWE_PROFILE}") foreach (qw(mariadb mysql postgres));
    ok(!defined(eval { PWE::ToolEnv::dockerfile_base('oracle') }), 'dockerfile_base(): neznamy profil -> die');
    # polozky korene enginu, ktere patri do image webu: vse krome t (testy), docker (sestaveni image) a skrytych
    is_deeply([PWE::ToolEnv::engine_image_excludes()], [qw(t docker)], 'engine_image_excludes(): do image webu nepatri PWE/t a PWE/docker');
    {
        my @entries = PWE::ToolEnv::engine_image_entries();
        my %entry   = map { $_ => 1 } @entries;
        ok(!(grep { !$entry{$_} } qw(pwe.fcgi debug.cgi VERSION Libs Pages Sites Services Entities templates assets tools)), 'engine_image_entries(): obsahuje soubory a adresare enginu (pwe.fcgi, VERSION, Libs, Pages, tools, ...)') or diag("@entries");
        ok(!$entry{'t'} && !$entry{'docker'} && !(grep { /^\./ } @entries), 'engine_image_entries(): bez t, docker a skrytych polozek');
        is_deeply(\@entries, [sort @entries], 'engine_image_entries(): serazeny seznam');
        my $fake = "$base/engine-entries";
        make_path("$fake/Libs", "$fake/Nova", "$fake/t", "$fake/docker", "$fake/.git");
        foreach my $f (qw(pwe.fcgi .DS_Store)) { open(my $fh, '>', "$fake/$f") or die $!; close($fh); }
        is_deeply([PWE::ToolEnv::engine_image_entries($fake)], [qw(Libs Nova pwe.fcgi)], 'engine_image_entries(<koren>): kazda dalsi polozka korene enginu (zde Nova) do image patri - vyjimky jsou jen t, docker a skryte polozky');
        remove_tree($fake);
    }

    # hlaska nastroje, ktery nema moduly a nemuze se sam spustit v kontejneru, jmenuje image nastroju
    my ($rc_e, $out_e) = run_cmd({env => {PWE_IMAGE_TAG => undef, PWE_IMAGE_REGISTRY => undef, PWE_TEST_IMAGE => undef}},
        $^X, "-I$TOOLS/lib", '-MPWE::ToolEnv=ensure_modules', '-e', 'ensure_modules("PWE::Tento::Modul::Neexistuje")');
    isnt($rc_e, 0, 'ensure_modules: chybejici modul v kontejneru -> chyba');
    like($out_e, qr{spust v kontejneru ghcr\.io/kukam/pwe-debugger:\Q$version\E\b}, 'ensure_modules: hlaska jmenuje image nastroju (docker_image(), vychozi tag = verze)');

    # shoda se shell implementaci (tools/lib/images.sh), kterou pouzivaji run-tests.sh, pwe-cgi.sh, run-webapp.sh a CI
  SKIP: {
        skip 'chybi bash nebo tools/lib/images.sh', 23 unless ($BASH and -f $images_sh);
        my %unset = (PWE_IMAGE_TAG => undef, PWE_IMAGE_REGISTRY => undef, PWE_TEST_IMAGE => undef);
        my ($rc_s, $out_s) = run_cmd({env => {%unset}}, $BASH, $images_sh, 'pwe_image_version');
        is("$rc_s|$out_s", "0|$version\n", 'images.sh pwe_image_version = ToolEnv::image_version() = obsah VERSION');
        ($rc_s, $out_s) = run_cmd({env => {%unset}}, $BASH, $images_sh, 'pwe_image_tag');
        is("$rc_s|$out_s", "0|$version\n", 'images.sh pwe_image_tag: bez PWE_IMAGE_TAG verze enginu (v kontejneru neni git - na gitu nezavisi)');
        foreach my $e (
            {%unset},
            {PWE_IMAGE_TAG => 'latest', PWE_IMAGE_REGISTRY => undef,                         PWE_TEST_IMAGE => undef},
            {PWE_IMAGE_TAG => 'x_1.2',  PWE_IMAGE_REGISTRY => 'registry.example.test/tym/',  PWE_TEST_IMAGE => undef},
            {PWE_IMAGE_TAG => 'latest', PWE_IMAGE_REGISTRY => 'registry.example.test/tym',   PWE_TEST_IMAGE => 'ghcr.io/kukam/pwe-base:jina'},
            {PWE_IMAGE_TAG => 'a/b',    PWE_IMAGE_REGISTRY => undef,                         PWE_TEST_IMAGE => 'ghcr.io/kukam/pwe-base:jina'},
            {PWE_IMAGE_TAG => '',       PWE_IMAGE_REGISTRY => '',                            PWE_TEST_IMAGE => ''},
        ) {
            ($rc_s, $out_s) = run_cmd({env => $e}, $BASH, $images_sh, 'pwe_tool_image');
            chomp($out_s);
            local %ENV = %ENV;
            foreach my $k (keys %{$e}) { if (defined($e->{$k})) { $ENV{$k} = $e->{$k}; } else { delete $ENV{$k}; } }
            is(PWE::ToolEnv::docker_image(), $out_s, 'docker_image() = images.sh pwe_tool_image (' . join(' ', map { "$_=" . (defined($e->{$_}) ? "'$e->{$_}'" : 'nenastaveno') } sort keys %{$e}) . ')');
        }
        ($rc_s, $out_s) = run_cmd({env => {%unset}}, $BASH, $images_sh, 'pwe_image', 'pwe-mariadb');
        is("$rc_s|$out_s", "0|ghcr.io/kukam/pwe-mariadb:$version\n", 'images.sh pwe_image pwe-mariadb: vychozi tag = verze (image profilu pro compose)');
        ($rc_s, $out_s) = run_cmd({env => {%unset, PWE_IMAGE_TAG => 'latest'}}, $BASH, $images_sh, 'pwe_image', 'pwe-mariadb');
        is("$rc_s|$out_s", "0|ghcr.io/kukam/pwe-mariadb:latest\n", 'images.sh pwe_image pwe-mariadb: PWE_IMAGE_TAG=latest');
        foreach my $gone (qw(pwe_image_branch pwe_image_tag_sanitize)) {
            ($rc_s, $out_s) = run_cmd({env => {%unset}}, $BASH, $images_sh, $gone, 'feature/kosik');
            is($rc_s, 2, "images.sh $gone: zrusena funkce -> kod 2 (napoveda)");
        }
        # seznam image a zavislostni image profilu: shell = Perl
        foreach my $group ('', 'deps', 'examples', 'all') {
            ($rc_s, $out_s) = run_cmd({env => {%unset}}, $BASH, $images_sh, 'pwe_image_names', (length($group) ? ($group) : ()));
            is("$rc_s|$out_s", '0|' . join('', map { "$_\n" } PWE::ToolEnv::image_names($group)), "images.sh pwe_image_names $group = ToolEnv::image_names('$group')");
        }
        foreach my $profile (qw(static mariadb mysql postgres)) {
            ($rc_s, $out_s) = run_cmd({env => {%unset}}, $BASH, $images_sh, 'pwe_profile_image', $profile);
            is("$rc_s|$out_s", '0|' . PWE::ToolEnv::profile_image($profile) . "\n", "images.sh pwe_profile_image $profile = ToolEnv::profile_image('$profile')");
        }
        ($rc_s, $out_s) = run_cmd({env => {%unset}}, $BASH, $images_sh, 'pwe_image', 'pwe-base');
        is("$rc_s|$out_s", "0|ghcr.io/kukam/pwe-base:$version\n", 'images.sh pwe_image pwe-base: image profilu static (web bez databaze)');
        ($rc_s, $out_s) = run_cmd({env => {%unset}, stderr => "$base/images.stderr"}, $BASH, $images_sh, 'pwe_profile_image', 'oracle');
        is("$rc_s|$out_s", '2|', 'images.sh pwe_profile_image: neznamy profil -> kod 2, nic na stdout');
        is(slurp("$base/images.stderr"), (eval { PWE::ToolEnv::profile_image('oracle') } // $@), 'images.sh pwe_profile_image: hlaska o neznamem profilu = ToolEnv::profile_image()');
        unlink("$base/images.stderr");
    }

    # shell nastroje berou image z images.sh (pwe_tool_image / pwe_image_*), zadny nema jmeno image napevno
    my $old_image = qr{kukam/pwe-[a-z]+:(?:master|pwe\.ai)\b|\$\{PWE_IMAGE_TAG:-master\}};
    foreach my $sh (qw(run-tests.sh perl-compile.sh pwe-cgi.sh)) {
        my $src = slurp("$TOOLS/$sh");
        like($src, qr{^\. "\$ROOT/PWE/tools/lib/images\.sh"$}m, "$sh nacita tools/lib/images.sh");
        like($src, qr{^IMAGE="\$\(pwe_tool_image\)"$}m,          "$sh: image nastroju z pwe_tool_image");
        unlike($src, $old_image,                                 "$sh: zadne pevne jmeno image s tagem vetve");
    }
    my $runsh = slurp("$TOOLS/run-webapp.sh");
    like($runsh, qr{^\. "\$ROOT/PWE/tools/lib/images\.sh"$}m, 'run-webapp.sh nacita tools/lib/images.sh');
    like($runsh, qr{^PWE_IMAGE_REGISTRY="\$\(pwe_image_registry\)"$}m, 'run-webapp.sh: PWE_IMAGE_REGISTRY z pwe_image_registry');
    like($runsh, qr{^PWE_IMAGE_TAG="\$\(pwe_image_tag\)"$}m,           'run-webapp.sh: PWE_IMAGE_TAG z pwe_image_tag');
    like($runsh, qr{^export PWE_IMAGE_REGISTRY PWE_IMAGE_TAG$}m,       'run-webapp.sh exportuje obe promenne pro docker-compose.yml');
    unlike($runsh, $old_image, 'run-webapp.sh: zadne pevne jmeno image s tagem vetve');
    unlike($toolenv_src, $old_image, 'ToolEnv.pm: zadne pevne jmeno image s tagem vetve');
    foreach my $sh (qw(build-images.sh smoke-images.sh)) {
        unlike(slurp("$TOOLS/$sh"), qr/pwe_image_branch|pwe_image_tag_sanitize/, "$sh: nevola zrusene funkce pwe_image_branch a pwe_image_tag_sanitize");
    }
  SKIP: {
        skip 'chybi bash', 7 unless ($BASH);
        foreach my $sh (qw(run-tests.sh perl-compile.sh pwe-cgi.sh run-webapp.sh build-images.sh smoke-images.sh lib/images.sh)) {
            my ($rc_n, $out_n) = run_cmd({}, $BASH, '-n', "$TOOLS/$sh");
            is($rc_n, 0, "bash -n tools/$sh") or diag($out_n);
        }
    }

    # docker-compose.yml: sluzby berou image z registru a tagu v promennych (PWE_IMAGE_REGISTRY, PWE_IMAGE_TAG,
    # vychozi tag latest). Sluzba fcgi bezi v zavislostnim image profilu: vychozi pwe-<COMPOSE_PROFILES>, profil
    # static nema vlastni image a bezi nad pwe-base (PWE_FCGI_IMAGE - nastavuje ho run-webapp.sh). Image kod enginu
    # ani web neobsahuji: repozitar se mountuje do /PWE a web urcuje compose (working_dir, PWE_CONF_pwe_home)
  SKIP: {
        my $compose = slurp(dirname($ROOT) . '/docker-compose.yml');
        skip 'docker-compose.yml neni k dispozici (engine bez korene repozitare)', 18 unless (length($compose));
        my ($fcgi)     = $compose =~ /^  fcgi:\n((?:(?:    .*)?\n)+)/m;
        my ($debugger) = $compose =~ /^  debugger:\n((?:(?:    .*)?\n)+)/m;
        like($fcgi || '', qr{^    image: \$\{PWE_IMAGE_REGISTRY:-ghcr\.io/kukam\}/\$\{PWE_FCGI_IMAGE:-pwe-\$\{COMPOSE_PROFILES:-mariadb\}\}:\$\{PWE_IMAGE_TAG:-latest\}$}m,
            'compose: sluzba fcgi = zavislostni image z PWE_FCGI_IMAGE (vychozi pwe-<profil>), vychozi tag latest');
        like($debugger || '', qr{^    image: \$\{PWE_IMAGE_REGISTRY:-ghcr\.io/kukam\}/pwe-debugger:\$\{PWE_IMAGE_TAG:-latest\}$}m, 'compose: sluzba debugger = image pwe-debugger:<tag>, vychozi tag latest');
        unlike(($fcgi || '') . ($debugger || ''), qr{^    entrypoint:}m, 'compose: sluzby fcgi a debugger entrypoint neprepisuji (maji ho z pwe-base)');
        like($fcgi || '', qr{^      PWE_PROFILE: \$\{COMPOSE_PROFILES:-mariadb\}$}m, 'compose: sluzba fcgi predava PWE_PROFILE entrypointu');
        unlike($compose, $old_image, 'compose: zadny tag podle vetve (master) v jmenech image');
        my @pwe_images = $compose =~ m{^\s+image:\s+(\S*/\S*pwe\S*)\s*$}mg;
        ok(@pwe_images == 2 && !(grep { $_ !~ /:\$\{PWE_IMAGE_TAG:-latest\}$/ } @pwe_images), 'compose: prave dve sluzby s image PWE, obe s tagem z PWE_IMAGE_TAG (vychozi latest)') or diag("@pwe_images");
        unlike($compose, qr{pwe-static|/pwe:}, 'compose: zadna zminka o zrusenych image pwe-static a pwe');
        like($compose, qr{^#\s+PWE_WEBAPP=example\.web COMPOSE_PROFILES=static PWE_FCGI_IMAGE=pwe-base docker compose up\b}m, 'compose: zahlavi uvadi prime spusteni profilu static s PWE_FCGI_IMAGE=pwe-base');
        # run-webapp.sh nastavuje PWE_FCGI_IMAGE podle profilu (static -> pwe-base) stejnou funkci jako ostatni nastroje
        like($runsh, qr{^PWE_FCGI_IMAGE="\$\(pwe_profile_image "\$PROFILE"\)"$}m, 'run-webapp.sh: PWE_FCGI_IMAGE z pwe_profile_image (static -> pwe-base)');
        like($runsh, qr{^export PWE_FCGI_IMAGE$}m, 'run-webapp.sh exportuje PWE_FCGI_IMAGE pro docker-compose.yml');
        like($debugger || '', qr{^    init: true$}m, 'compose: sluzba debugger ma init (PID 1 = sleep infinity jinak neodpovi na SIGTERM a zastaveni ceka na timeout)');
        foreach my $svc (['fcgi', $fcgi], ['debugger', $debugger]) {
            my ($name, $body) = @{$svc};
            $body = '' unless (defined($body));
            like($body, qr{^      - \.:/PWE(?: |$)}m, "compose: sluzba $name mountuje koren repozitare do /PWE (engine i weby z pracovni kopie - image je neobsahuji)");
            like($body, qr{^    working_dir: /PWE/webapps/\$\{PWE_WEBAPP:-example-db\.web\}$}m, "compose: sluzba $name - pracovni adresar = web z PWE_WEBAPP");
            like($body, qr{^      PWE_CONF_pwe_home: /PWE/webapps/\$\{PWE_WEBAPP:-example-db\.web\}$}m, "compose: sluzba $name - PWE_CONF_pwe_home urcuje compose");
        }
        like($fcgi || '', qr{^    command: \["perl", "/PWE/PWE/pwe\.fcgi"\]$}m, 'compose: sluzba fcgi spousti engine z mountu /PWE/PWE');
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
ok(!-e "$app/entrypoint.sh", 'bez DB: web nema vlastni entrypoint.sh (image webu ho dedi ze zakladniho image)');
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
like($out, qr/^OK   Dockerfile: FROM a kopie enginu podle sablony generatoru$/m, 'check-webapp.pl: Dockerfile z generatoru -> OK (FROM zavislostni image, engine z kontextu sestaveni)');
unlike($out, qr/^WARN Dockerfile/m, 'check-webapp.pl: Dockerfile z generatoru -> zadne varovani');

# Dockerfile webu: varovani (ne chyba) na zbytky starsich sablon a na radek FROM jiny nez v sablone generatoru.
#   - prvni usporadani: engine z image pwe ve druhem FROM, ARG PWE_ENGINE_TAG, COPY --from=engine, vychozi tag
#     podle vetve, vlastni entrypoint,
#   - usporadani s enginem v zakladnim image pwe-<profil> (jediny FROM bez kopie enginu, kontrola enginu
#     v zakladu, mazani vzoroveho webu, zaklad pwe-static),
#   - Dockerfile, ktery nekopiruje nekterou polozku enginu (image by ji neobsahoval).
{
    my $df_new   = slurp("$app/Dockerfile");
    my $tpl_from = 'FROM ${PWE_IMAGE_REGISTRY}/pwe-base:${PWE_IMAGE_TAG}';
    my $regen    = qr{PWE/tools/new-webapp\.pl tool\.web --dir <docasny adresar> a prevezmi z nej Dockerfile};
    my $check_df = sub {
        my ($text) = @_;
        open(my $d, '>', "$app/Dockerfile") or die $!; print $d $text; close($d);
        return run_tool("$TOOLS/check-webapp.pl", $app, '--static');
    };
    my $warns = sub { my ($o) = @_; return scalar(() = $o =~ /^WARN Dockerfile/mg); };
    ok(index($df_new, "\n$tpl_from\n") > 0, 'sablona generatoru (web bez databaze) ma radek FROM pwe-base, se kterym check-webapp.pl srovnava');

    # prvni usporadani image: dva FROM, engine z image pwe
    my $df_old = <<'OLD';
# Image webu tool.web (stara sablona).
ARG PWE_IMAGE_REGISTRY=ghcr.io/kukam
ARG PWE_IMAGE_TAG=master
ARG PWE_ENGINE_TAG=${PWE_IMAGE_TAG}
ARG PWE_PROFILE=static

FROM ${PWE_IMAGE_REGISTRY}/pwe:${PWE_ENGINE_TAG} AS engine
FROM ${PWE_IMAGE_REGISTRY}/pwe-${PWE_PROFILE}:${PWE_IMAGE_TAG}
ARG PWE_IMAGE_REGISTRY
ARG PWE_IMAGE_TAG
ARG PWE_PROFILE

COPY --from=engine /PWE/PWE /PWE/PWE
COPY --from=engine /PWE/LICENSE /PWE/LICENSE

ENV PWE_CONF_pwe_home=/PWE/webapps/tool.web \
    PWE_PROFILE=${PWE_PROFILE}

WORKDIR /PWE/webapps/
COPY webapps/tool.web tool.web
WORKDIR /PWE/webapps/tool.web
RUN set -eu; \
    mkdir -p ramdisk/templates sessions uploadfile log
CMD ["perl", "/PWE/PWE/pwe.fcgi"]
OLD
    my ($rc_d, $out_d) = $check_df->($df_old);
    is($rc_d, 0, 'check-webapp.pl: Dockerfile ze stare sablony neni chyba (navratovy kod 0)') or diag($out_d);
    unlike($out_d, qr/^FAIL/m, 'check-webapp.pl: Dockerfile ze stare sablony -> zadny FAIL');
    like($out_d, qr/^WARN Dockerfile je ze stare sablony \(2x FROM - image pwe jako zdroj enginu; ARG PWE_ENGINE_TAG; COPY --from=engine; zaklad pwe-static - image byl zrusen; engine se nekopiruje z kontextu sestaveni \(zadne COPY PWE\/\.\.\.\); vychozi PWE_IMAGE_TAG=master\): /m,
        'check-webapp.pl: prvni usporadani -> WARN vyjmenuje dva FROM s image pwe, ARG PWE_ENGINE_TAG, COPY --from=engine, zruseny zaklad pwe-static, chybejici kopii enginu a vychozi tag master') or diag($out_d);
    like($out_d, qr/^WARN Dockerfile je ze stare sablony [^\n]* nad zavislostnim image BEZ enginu \(pwe-base pro web bez databaze, pwe-<profil> pro web s databazi[^\n]*engine kopiruje z kontextu sestaveni/m,
        'check-webapp.pl: stara sablona -> varovani rika, jak se image webu stavi dnes (zaklad bez enginu, engine z kontextu)');
    like($out_d, qr/^WARN Dockerfile je ze stare sablony [^\n]* Vygeneruj novy: $regen/m, 'check-webapp.pl: stara sablona -> rada vygenerovat web znovu a prevzit Dockerfile');
    is($warns->($out_d), 1, 'check-webapp.pl: stara sablona -> jedine varovani (zruseny zaklad pwe-static uz v nem je, radek FROM se zvlast nehlasi)');
    unlike($out_d, qr/^OK   Dockerfile/m, 'check-webapp.pl: stara sablona -> zadny radek OK o Dockerfile');
    like($out_d, qr/^---- VYSLEDEK: bez chyb, [1-9]\d* varovani$/m, 'check-webapp.pl: varovani o Dockerfile se pocita do souhrnu');

    # usporadani s enginem v zakladnim image pwe-<profil>: jediny FROM, kontrola enginu v zakladu, mazani
    # vzoroveho webu, zadna kopie enginu. Web bez databaze mel zaklad pwe-static (image byl zrusen).
    my $df_mid = <<'MID';
ARG PWE_IMAGE_REGISTRY=ghcr.io/kukam
ARG PWE_IMAGE_TAG=latest
ARG PWE_PROFILE=static

FROM ${PWE_IMAGE_REGISTRY}/pwe-${PWE_PROFILE}:${PWE_IMAGE_TAG}
ARG PWE_IMAGE_REGISTRY
ARG PWE_IMAGE_TAG
ARG PWE_PROFILE

RUN test -f /PWE/PWE/pwe.fcgi || { \
        echo "Zakladni image neobsahuje engine" >&2; \
        exit 1; \
    }

WORKDIR /PWE/webapps/

RUN rm -rf /PWE/webapps/example.web /PWE/webapps/example-db.web

ENV PWE_CONF_pwe_home=/PWE/webapps/tool.web \
    PWE_PROFILE=${PWE_PROFILE}

COPY webapps/tool.web tool.web

WORKDIR /PWE/webapps/tool.web

RUN set -eu; \
    mkdir -p ramdisk/templates sessions uploadfile log

CMD ["perl", "/PWE/PWE/pwe.fcgi"]
MID
    ($rc_d, $out_d) = $check_df->($df_mid);
    like($out_d, qr/^WARN Dockerfile je ze stare sablony \(zaklad pwe-static - image byl zrusen; RUN test -f \/PWE\/PWE\/pwe\.fcgi - kontrola enginu v zakladnim image; RUN rm vzoroveho webu ze zakladniho image; engine se nekopiruje z kontextu sestaveni \(zadne COPY PWE\/\.\.\.\)\): /m,
        'check-webapp.pl: sablona s enginem v zakladnim image (web bez databaze) -> WARN: zruseny zaklad pwe-static, kontrola enginu v zakladu, mazani vzoroveho webu, zadna kopie enginu') or diag($out_d);
    is("$rc_d|" . $warns->($out_d), '0|1', 'check-webapp.pl: sablona s enginem v zakladnim image -> prave jedno varovani, zadna chyba');
    (my $df_mid_db = $df_mid) =~ s/^ARG PWE_PROFILE=static$/ARG PWE_PROFILE=mariadb/m or die 'ARG';
    ($rc_d, $out_d) = $check_df->($df_mid_db);
    like($out_d, qr/^WARN Dockerfile je ze stare sablony \(RUN test -f \/PWE\/PWE\/pwe\.fcgi - kontrola enginu v zakladnim image; RUN rm vzoroveho webu ze zakladniho image; engine se nekopiruje z kontextu sestaveni \(zadne COPY PWE\/\.\.\.\)\): [^\n]* Vygeneruj novy: PWE\/tools\/new-webapp\.pl tool\.web --db mariadb --dir /m,
        'check-webapp.pl: sablona s enginem v zakladnim image (web s databazi, FROM stejny jako dnes) -> WARN: kontrola enginu, mazani vzoroveho webu, zadna kopie enginu; rada s --db') or diag($out_d);
    is("$rc_d|" . $warns->($out_d), '0|1', 'check-webapp.pl: sablona s enginem v zakladnim image (web s databazi) -> prave jedno varovani (radek FROM je stejny jako v dnesni sablone)');

    # jednotlive znaky starsich sablon v jinak nove sablone
    foreach my $c (
        ['vychozi tag podle vetve',  sub { $_[0] =~ s/^ARG PWE_IMAGE_TAG=latest$/ARG PWE_IMAGE_TAG=pwe.ai/m },                                  qr/\(vychozi PWE_IMAGE_TAG=pwe\.ai\): /],
        ['ARG PWE_ENGINE_TAG',       sub { $_[0] =~ s/^(ARG PWE_PROFILE=static)$/$1\nARG PWE_ENGINE_TAG=latest/m },                              qr/\(ARG PWE_ENGINE_TAG\): /],
        ['vlastni ENTRYPOINT',       sub { $_[0] =~ s/^(CMD .*)$/ENTRYPOINT ["\/PWE\/webapps\/tool.web\/entrypoint.sh"]\n$1/m },                 qr/\(vlastni ENTRYPOINT \/ entrypoint\.sh\): /],
        ['engine z image pwe pres COPY --from=<image>', sub { $_[0] =~ s/^(WORKDIR \/PWE\/webapps\/tool\.web)$/COPY --from=ghcr.io\/kukam\/pwe:2.2.0 \/PWE\/PWE \/PWE\/PWE\n$1/m }, qr/\(COPY --from=<image pwe>\): /],
        ['kontrola enginu v zakladnim image', sub { $_[0] =~ s/^(COPY --link LICENSE .*)$/RUN test -f \/PWE\/PWE\/pwe.fcgi || exit 1\n$1/m },         qr/\(RUN test -f \/PWE\/PWE\/pwe\.fcgi - kontrola enginu v zakladnim image\): /],
        ['mazani vzoroveho webu',    sub { $_[0] =~ s/^(COPY --link LICENSE .*)$/RUN rm -rf \/PWE\/webapps\/example.web \/PWE\/webapps\/example-db.web\n$1/m }, qr/\(RUN rm vzoroveho webu ze zakladniho image\): /],
        ['chybi jedna polozka enginu (adresar)', sub { $_[0] =~ s/^COPY --link PWE\/Libs [^\n]*\n//m },                                           qr/\(chybi COPY polozek enginu: PWE\/Libs\): /],
        ['chybi polozky enginu (soubory)', sub { $_[0] =~ s/^(COPY --link PWE\/pwe\.fcgi) PWE\/debug\.cgi (.*) PWE\/VERSION (\/PWE\/PWE\/)$/$1 $2 $3/m }, qr/\(chybi COPY polozek enginu: PWE\/VERSION, PWE\/debug\.cgi\): /],
        ['engine se nekopiruje vubec', sub { my $n = ($_[0] =~ s/^COPY --link PWE\/[^\n]*\n//mg); $n > 5 },                                       qr/\(engine se nekopiruje z kontextu sestaveni \(zadne COPY PWE\/\.\.\.\)\): /],
    ) {
        my ($what, $edit, $re) = @{$c};
        my $df = $df_new;
        $edit->($df) or die "uprava Dockerfile ($what) se neprovedla";
        ($rc_d, $out_d) = $check_df->($df);
        like($out_d, qr/^WARN Dockerfile je ze stare sablony $re/m, "check-webapp.pl: $what -> WARN stare sablony") or diag($out_d);
        is("$rc_d|" . $warns->($out_d), '0|1', "check-webapp.pl: $what -> prave jedno varovani, zadna chyba");
    }

    # radek FROM jiny nez v sablone generatoru: pevny image s tagem vetve, zaklad s ovladacem u webu bez databaze,
    # zruseny zaklad pwe-static
    (my $df_from = $df_new) =~ s/^FROM .*$/FROM ghcr.io\/kukam\/pwe-base:pwe.ai/m or die 'FROM';
    ($rc_d, $out_d) = $check_df->($df_from);
    like($out_d, qr/^WARN Dockerfile: radek FROM vysledneho image \(FROM ghcr\.io\/kukam\/pwe-base:pwe\.ai\) se lisi od sablony generatoru \(\Q$tpl_from\E\) - [^\n]*pwe-base pro web bez databaze, pwe-<profil> pro web s databazi\. Sablona: $regen/m,
        'check-webapp.pl: jiny radek FROM -> WARN s obema radky a radou') or diag($out_d);
    is("$rc_d|" . $warns->($out_d), '0|1', 'check-webapp.pl: jiny radek FROM -> prave jedno varovani, zadna chyba');
    unlike($out_d, qr/stare sablony/, 'check-webapp.pl: jiny radek FROM sam o sobe neni "stara sablona"');
    (my $df_dbfrom = $df_new) =~ s/^FROM .*$/FROM \${PWE_IMAGE_REGISTRY}\/pwe-\${PWE_PROFILE}:\${PWE_IMAGE_TAG}/m or die 'FROM';
    ($rc_d, $out_d) = $check_df->($df_dbfrom);
    like($out_d, qr/^WARN Dockerfile je ze stare sablony \(zaklad pwe-static - image byl zrusen\): /m, 'check-webapp.pl: web bez databaze se zakladem pwe-${PWE_PROFILE} (= pwe-static) -> WARN: image byl zrusen') or diag($out_d);
    is("$rc_d|" . $warns->($out_d), '0|1', 'check-webapp.pl: zruseny zaklad pwe-static -> prave jedno varovani (radek FROM se zvlast nehlasi)');
    (my $df_static = $df_new) =~ s/^FROM .*$/FROM ghcr.io\/kukam\/pwe-static:latest/m or die 'FROM';
    ($rc_d, $out_d) = $check_df->($df_static);
    like($out_d, qr/^WARN Dockerfile je ze stare sablony \(zaklad pwe-static - image byl zrusen\): /m, 'check-webapp.pl: FROM s pevnym jmenem pwe-static -> WARN: image byl zrusen') or diag($out_d);
    (my $df_base = $df_new) =~ s/^FROM .*$/FROM kukam\/pwe-mariadb:latest/m or die 'FROM';
    $df_base =~ s/^(CMD .*)$/COPY webapps\/tool.web\/entrypoint.sh \/entrypoint.sh\nENTRYPOINT ["\/entrypoint.sh"]\n$1/m or die 'CMD';
    ($rc_d, $out_d) = $check_df->($df_base);
    is("$rc_d|" . $warns->($out_d), '0|2', 'check-webapp.pl: jiny FROM a vlastni entrypoint -> obe varovani, zadna chyba') or diag($out_d);
    (my $df_none = $df_new) =~ s/^FROM .*\n//m or die 'FROM';
    ($rc_d, $out_d) = $check_df->($df_none);
    like($out_d, qr/^WARN Dockerfile nema instrukci FROM /m, 'check-webapp.pl: Dockerfile bez FROM -> WARN');

    # co varovani vyvolat nesmi: zminka v komentari, pripnuta verze enginu, zapis promennych bez zavorek,
    # volba --platform a vlastni instrukce navic, vicestupnovy build, COPY bez --link, engine jednim COPY
    foreach my $c (
        ['zminka o starsich sablonach jen v komentari', sub { $_[0] =~ s/^(ARG PWE_IMAGE_REGISTRY=)/# drive: ARG PWE_ENGINE_TAG, FROM ...\/pwe:master AS engine, COPY --from=engine, FROM pwe-static, RUN rm -rf \/PWE\/webapps\/example.web, entrypoint.sh\n$1/m }],
        ['vychozi tag = pripnuta verze enginu',    sub { $_[0] =~ s/^ARG PWE_IMAGE_TAG=latest$/ARG PWE_IMAGE_TAG=2.2.1/m }],
        ['promenne ve FROM bez slozenych zavorek', sub { $_[0] =~ s/^FROM .*$/FROM \$PWE_IMAGE_REGISTRY\/pwe-base:\$PWE_IMAGE_TAG/m }],
        ['FROM s volbou --platform a vlastni RUN', sub { $_[0] =~ s/^FROM (.*)$/FROM --platform=linux\/amd64 $1/m and $_[0] =~ s/^(CMD .*)$/RUN perl -MJSON -e 1\n$1/m }],
        ['vicestupnovy build s vlastnim stage',    sub { $_[0] =~ s/^(FROM .*)$/FROM node:22 AS assets\n$1/m and $_[0] =~ s/^(CMD .*)$/COPY --from=assets \/dist static\/dist\n$1/m }],
        ['COPY bez --link',                        sub { $_[0] =~ s/^COPY --link /COPY /mg }],
        ['cely adresar enginu jednim COPY',        sub { my $n = ($_[0] =~ s/^COPY --link PWE\/[^\n]*\n//mg); $n > 5 and $_[0] =~ s/^(COPY --link LICENSE [^\n]*\n)/$1COPY PWE \/PWE\/PWE\n/m }],
        ['polozky enginu zastupnym znakem',        sub { $_[0] =~ s/^COPY --link PWE\/pwe\.fcgi [^\n]*$/COPY PWE\/*.fcgi PWE\/*.cgi PWE\/favicon.ico PWE\/*.md PWE\/VERSION \/PWE\/PWE\//m }],
    ) {
        my ($what, $edit) = @{$c};
        my $df = $df_new;
        $edit->($df) or die "uprava Dockerfile ($what) se neprovedla";
        ($rc_d, $out_d) = $check_df->($df);
        is("$rc_d|" . $warns->($out_d), '0|0', "check-webapp.pl: $what -> zadne varovani") or diag($out_d);
        like($out_d, qr/^OK   Dockerfile: FROM a kopie enginu podle sablony generatoru$/m, "check-webapp.pl: $what -> OK");
    }

    # web bez Dockerfile: zadne varovani (image webu se nestavi)
    unlink("$app/Dockerfile") or die $!;
    ($rc_d, $out_d) = run_tool("$TOOLS/check-webapp.pl", $app, '--static');
    is("$rc_d|" . $warns->($out_d), '0|0', 'check-webapp.pl: web bez Dockerfile -> zadne varovani');
    unlike($out_d, qr/Dockerfile/, 'check-webapp.pl: web bez Dockerfile -> o Dockerfile se bez --verbose nic nevypisuje');

    # Dockerfile zpet do stavu z generatoru
    ($rc_d, $out_d) = $check_df->($df_new);
    is(slurp("$app/Dockerfile"), $df_new, 'Dockerfile testovaciho webu vracen do stavu z generatoru');
}

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
# zamek migrace: klice musi byt v konfiguraci vyslovne - engine promennou PWE_CONF_dbi_db1_<klic> prepise
# jen klic, ktery v konfiguraci existuje
foreach my $drv (qw(mariadb mysql postgres)) {
    my $dbc = do("$dbapp/conf/$drv.conf");
    is(ref($dbc), 'HASH', "conf/$drv.conf je platny Perl hash");
    is($dbc->{'db1'}->{'dbversion_session_lock'}, 1, "conf/$drv.conf: dbversion_session_lock => 1 (zamek migrace vazany na spojeni)");
    is($dbc->{'db1'}->{'dbversion_legacy_lock_wait'}, 300, "conf/$drv.conf: dbversion_legacy_lock_wait => 300");
    my $text = slurp("$dbapp/conf/$drv.conf");
    like($text, qr/^\s+\Q$_\E\s+=> \d+,\s+# \S[^\n]*PWE_CONF_dbi_db1_\Q$_\E$/m, "conf/$drv.conf: $_ ma jednoradkovy komentar s promennou PWE_CONF_dbi_db1_$_") foreach (qw(dbversion_session_lock dbversion_legacy_lock_wait));
}
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
like(slurp("$dbapp/README.md"), qr{`FROM ghcr\.io/kukam/pwe-postgres:<tag>`}, 'README jmenuje zavislostni image profilu, ze ktereho image webu vychazi (jediny FROM)');
like(slurp("$dbapp/README.md"), qr{`PWE_IMAGE_TAG`}, 'README uvadi argument PWE_IMAGE_TAG (verze enginu nebo latest)');
unlike(slurp("$dbapp/README.md"), qr{ghcr\.io/kukam/pwe`|COPY --from|PWE_ENGINE_TAG}, 'README neodkazuje na image pwe jako zdroj enginu (COPY --from, PWE_ENGINE_TAG)');
like(slurp("$app/README.md"), qr{`FROM ghcr\.io/kukam/pwe-base:<tag>`}, 'bez DB: README jmenuje zaklad pwe-base (web bez databaze)');
foreach my $readme ("$app/README.md", "$dbapp/README.md") {
    my $text = slurp($readme);
    like($text, qr{engine se kopíruje z adresáře `PWE/` repozitáře do `/PWE/PWE`}, 'README (' . ($readme eq "$app/README.md" ? 'bez DB' : 's DB') . '): engine se do image kopiruje z repozitare');
    like($text, qr{`docker build -f webapps/tool(?:db)?\.web/Dockerfile \.`}, 'README (' . ($readme eq "$app/README.md" ? 'bez DB' : 's DB') . '): sestaveni z korene repozitare');
    unlike($text, qr{pwe-static|vzorový web enginu z něj smaže}, 'README (' . ($readme eq "$app/README.md" ? 'bez DB' : 's DB') . '): zadna zminka o zrusenem image pwe-static ani o mazani vzoroveho webu');
}
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
like($out, qr/^OK   Dockerfile: FROM a kopie enginu podle sablony generatoru$/m, 'check-webapp.pl: Dockerfile DB varianty z generatoru -> OK (FROM pwe-${PWE_PROFILE})');
{
    # rada k novemu vygenerovani jmenuje i profil webu (--db), aby vznikl Dockerfile se stejnym PWE_PROFILE
    my $df_db = slurp("$dbapp/Dockerfile");
    (my $df_old = $df_db) =~ s/^ARG PWE_IMAGE_TAG=latest$/ARG PWE_IMAGE_TAG=master/m or die 'ARG';
    open(my $d, '>', "$dbapp/Dockerfile") or die $!; print $d $df_old; close($d);
    my ($rc_d, $out_d) = run_tool("$TOOLS/check-webapp.pl", $dbapp, '--static');
    like($out_d, qr{^WARN Dockerfile je ze stare sablony \(vychozi PWE_IMAGE_TAG=master\): [^\n]* Vygeneruj novy: PWE/tools/new-webapp\.pl tooldb\.web --db postgres --dir <docasny adresar> }m,
        'check-webapp.pl: web s databazi -> rada k novemu vygenerovani uvadi --db <profil z Dockerfile>') or diag($out_d);
    is($rc_d, 0, 'check-webapp.pl: stary vychozi tag u webu s databazi neni chyba');
    # web s databazi nad zakladem bez ovladace (pwe-base): radek FROM se lisi od sablony webu s databazi
    (my $df_nodrv = $df_db) =~ s/^FROM .*$/FROM \${PWE_IMAGE_REGISTRY}\/pwe-base:\${PWE_IMAGE_TAG}/m or die 'FROM';
    open($d, '>', "$dbapp/Dockerfile") or die $!; print $d $df_nodrv; close($d);
    ($rc_d, $out_d) = run_tool("$TOOLS/check-webapp.pl", $dbapp, '--static');
    like($out_d, qr{^WARN Dockerfile: radek FROM vysledneho image \(FROM \$\{PWE_IMAGE_REGISTRY\}/pwe-base:\$\{PWE_IMAGE_TAG\}\) se lisi od sablony generatoru \(FROM \$\{PWE_IMAGE_REGISTRY\}/pwe-\$\{PWE_PROFILE\}:\$\{PWE_IMAGE_TAG\}\) }m,
        'check-webapp.pl: web s databazi (PWE_PROFILE=postgres) nad pwe-base -> WARN: sablona webu s databazi vychazi z pwe-${PWE_PROFILE}') or diag($out_d);
    # web s konfiguraci databaze a Dockerfile pro web bez databaze (PWE_PROFILE=static, zaklad pwe-base bez ovladacu):
    # image by bezel bez databaze - web s databazi ma jinou sablonu (zaklad pwe-<profil>)
    (my $df_static = slurp("$app/Dockerfile")) =~ s/tool\.web/tooldb.web/g;
    open($d, '>', "$dbapp/Dockerfile") or die $!; print $d $df_static; close($d);
    ($rc_d, $out_d) = run_tool("$TOOLS/check-webapp.pl", $dbapp, '--static');
    like($out_d, qr{^WARN Dockerfile je pro web bez databaze \(PWE_PROFILE=static, zaklad pwe-base nema ovladace databaze\), ale web ma conf/mariadb\.conf, conf/mysql\.conf, conf/postgres\.conf - image webu pobezi bez databaze\. Web s databazi: PWE/tools/new-webapp\.pl tooldb\.web --db <mariadb\|mysql\|postgres> --dir <docasny adresar> }m,
        'check-webapp.pl: web s konfiguraci databaze a Dockerfile pro web bez databaze -> WARN (image by bezel bez databaze), rada s --db') or diag($out_d);
    is($rc_d . '|' . scalar(() = $out_d =~ /^WARN Dockerfile/mg), '0|1', 'check-webapp.pl: Dockerfile pro web bez databaze u webu s databazi -> prave jedno varovani, zadna chyba');
    open($d, '>', "$dbapp/Dockerfile") or die $!; print $d $df_db; close($d);
    ($rc_d, $out_d) = run_tool("$TOOLS/check-webapp.pl", $dbapp, '--static');
    unlike($out_d, qr/^WARN Dockerfile/m, 'check-webapp.pl: Dockerfile DB varianty vracen do stavu z generatoru -> zadne varovani');
}

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
    skip 'prikaz RUN z Dockerfile webu se spousti jen v kontejneru (Linux)', 8 unless ($^O eq 'linux' and -x '/bin/sh');
    # POZOR: test bezi v kontejneru s repozitarem namountovanym do /PWE - prikaz, ktery by neco mazal nebo
    # zapisoval mimo pracovni adresar, by poskodil pracovni kopii. Sablona proto smi mit jedinou instrukci RUN
    # (hlida dockerfile_checks) a ta se tu spusti jen tehdy, kdyz zacina presne ocekavanym prikazem, nic
    # nemaze (rm, rmdir, unlink, -delete) a nepouziva zadnou absolutni cestu; jinak "exit 99" = test selze.
    my $ins  = dockerfile_instructions(slurp("$dbapp/Dockerfile"));
    my @runs = $ins =~ /^RUN ([^\n]+)$/mg;
    is(scalar(@runs), 1, 'Dockerfile webu: prave jedna instrukce RUN (zadny dalsi prikaz se mimo docker build nespousti)') or diag(join("\n", @runs));
    my ($run) = grep { /^set -eu; mkdir -p ramdisk\/templates / } @runs;
    my $safe  = (defined($run) and $run !~ /\brm\b|\brmdir\b|\bunlink\b|-delete\b/ and $run !~ m{(?:^|[\s"'=])/}) ? 1 : 0;
    ok($safe, 'Dockerfile webu: prikaz RUN nic nemaze a pracuje jen s relativnimi cestami v adresari webu (bezpecne ho spustit mimo docker build)') or diag($run);
    $run = 'exit 99' unless ($safe);

    my $img = "$base/image-webu";    # obdoba adresare webu v image: bez docasnych adresaru a bez database.conf (.dockerignore)
    make_path("$img/conf");
    foreach my $f (qw(web.conf mariadb.conf postgres.conf)) {
        open(my $c, '>', "$img/conf/$f") or die $!; print $c "{};\n"; close($c);
    }
    my ($rc_r, $out_r) = run_cmd({cwd => $img, env => {PWE_PROFILE => 'postgres'}}, '/bin/sh', '-c', $run);
    is($rc_r, 0, 'Dockerfile webu: prikaz RUN skoncil 0') or diag($out_r);
    ok(-d "$img/ramdisk/templates" && -d "$img/sessions" && -d "$img/uploadfile" && -d "$img/log", 'Dockerfile webu: RUN zalozi pracovni adresare');
    ok(-l "$img/conf/database.conf" && readlink("$img/conf/database.conf") eq 'postgres.conf', 'Dockerfile webu: RUN nasmeruje conf/database.conf na konfiguraci profilu');
    ($rc_r, $out_r) = run_cmd({cwd => $img, env => {PWE_PROFILE => 'static'}}, '/bin/sh', '-c', $run);
    ok($rc_r == 0 && readlink("$img/conf/database.conf") eq 'postgres.conf', 'Dockerfile webu: RUN bez conf/<profil>.conf (profil static) symlink nemeni a neskonci chybou') or diag($out_r);
    unlink("$img/conf/database.conf") or die $!;
    ($rc_r, $out_r) = run_cmd({cwd => $img, env => {PWE_PROFILE => 'static'}}, '/bin/sh', '-c', $run);
    ok($rc_r == 0 && !-e "$img/conf/database.conf" && !-l "$img/conf/database.conf", 'Dockerfile webu: RUN u webu bez databaze conf/database.conf nevytvari') or diag($out_r);
    open(my $own, '>', "$img/conf/database.conf") or die $!; print $own "{ 'db1' => { dbdriver => 'vlastni' } };\n"; close($own);
    ($rc_r, $out_r) = run_cmd({cwd => $img, env => {PWE_PROFILE => 'mariadb'}}, '/bin/sh', '-c', $run);
    ok($rc_r == 0 && !-l "$img/conf/database.conf" && slurp("$img/conf/database.conf") =~ /vlastni/, 'Dockerfile webu: RUN bezny soubor conf/database.conf neprepisuje') or diag($out_r);
}

# ---------------------------------------------------------------------------------------------
# entrypoint image PWE (docker/entrypoint.sh; maji ho vsechny image vcetne image webu): podle
# PWE_PROFILE nastavi conf/database.conf, zalozi pracovni adresare a spusti prikaz. Pri nesouladu
# profilu a webu (i kdyz image nema ovladac databaze profilu) vypise jednoradkove varovani na stderr,
# start nikdy neprerusi. Jen Linux (kontejner): atomicka vymena symlinku pouziva mv -T z GNU coreutils.
# ---------------------------------------------------------------------------------------------
ok(length(slurp($ENTRYPOINT_SRC)) > 0, 'engine ma docker/entrypoint.sh');
SKIP: {
    skip 'entrypoint se testuje jen v kontejneru (Linux, bash)', 86 unless ($^O eq 'linux' and $BASH);
    require File::Temp;
    my $link = "$dbapp/conf/database.conf";
    my %none = (PWE_PROFILE => undef);
    my $errf = "$base/entrypoint.stderr";
    my $warn = qr/\[entrypoint\] VAROVANI: /;

    # Ovladac databaze profilu zjistuje entrypoint prikazem "perl -M<ovladac> -e 1". Testovaci image
    # ovladace mit nemusi (pwe-base nema zadny, pwe-debugger vsechny), proto entrypoint v testu dostava
    # na zacatek PATH falesny perl: argumenty zapise do souboru $perl_calls a skonci kodem 0 (adresar
    # "ok" = ovladac v image je) nebo 2 (adresar "missing" = ovladac chybi, jako skutecny perl).
    # Adresar je mimo mount repozitare a pristupny vsem - cast testu bezi jako nobody.
    my $fake       = File::Temp::tempdir('pwe-fakeperl-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $perl_calls = "$fake/perl.calls";
    foreach my $kind (['ok', 0], ['missing', 2]) {
        make_path("$fake/$kind->[0]");
        open(my $fp, '>', "$fake/$kind->[0]/perl") or die $!;
        print $fp "#!/bin/sh\necho \"\$*\" >> '$perl_calls'\nif [ $kind->[1] -ne 0 ]; then echo \"Can't locate modul in \@INC\" >&2; fi\nexit $kind->[1]\n";
        close($fp);
        chmod(0755, "$fake/$kind->[0]", "$fake/$kind->[0]/perl");
    }
    chmod(0755, $fake);
    my $perl_log = sub { my $l = slurp($perl_calls); unlink($perl_calls); return $l; };

    # Spusti entrypoint (pres bash, zdrojovy soubor nemusi byt spustitelny) s prikazem; vraci
    # (navratovy kod, STDOUT, STDERR). Volby: script => jiny soubor entrypointu, perl => 'ok' (vychozi)
    # | 'missing' | 'real' (falesny perl s ovladacem / bez ovladace / skutecny perl image), ostatni jako
    # run_cmd.
    my $entry = sub {
        my ($o, @cmd) = @_;
        my %o = %{$o};
        my $script = delete($o{'script'}) || $ENTRYPOINT_SRC;
        my $perl   = delete($o{'perl'}) || 'ok';
        my %env    = %{$o{'env'} || {}};
        $env{'PATH'} = "$fake/$perl:" . ($ENV{'PATH'} || '/usr/local/bin:/usr/bin:/bin') unless ($perl eq 'real');
        unlink($errf);
        my ($rc_e, $out_e) = run_cmd({%o, env => \%env, stderr => $errf}, $BASH, $script, @cmd);
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
    # Prikaz musi proces entrypointu NAHRADIT (exec), ne bezet jako jeho potomek: PID 1 kontejneru je pak
    # engine a dostane SIGTERM (docker stop, rolling update); bash by signal nepredal a zastaveni by cekalo
    # na timeout a SIGKILL. Entrypoint spousti test primo (bez shellu), takze rodicem prikazu je tento test.
    ($rc, $out, $err) = $entry->({cwd => $dbapp, env => {PWE_PROFILE => 'postgres'}}, 'sh', '-c', 'echo "$PPID"');
    is($out, "$$\n", 'entrypoint: prikaz nahradi proces entrypointu (exec "$@" - rodicem prikazu je test, ne bash entrypointu)');
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

    # --- varovani: conf/database.conf ukazuje na profil, ale image nema jeho ovladac databaze ---
    # (v tuto chvili conf/database.conf -> mariadb.conf; ovladac se zjistuje az po nasmerovani symlinku)
    $perl_log->();
    ($rc, $out, $err) = $entry->({cwd => $dbapp, env => {PWE_PROFILE => 'mariadb'}}, 'readlink', 'conf/database.conf');
    is($out . $err, "mariadb.conf\n", 'entrypoint: ovladac profilu v image je -> bez varovani');
    is($perl_log->(), "-MDBD::mysql -e 1\n", 'entrypoint: profil mariadb -> zjistuje DBD::mysql (perl -MDBD::mysql -e 1)');
    ($rc, $out, $err) = $entry->({cwd => $dbapp, perl => 'missing', env => {PWE_PROFILE => 'postgres'}}, 'sh', '-c', 'readlink conf/database.conf; exit 8');
    is($out, "postgres.conf\n", 'entrypoint: chybi ovladac profilu -> symlink se presto nasmeruje a prikaz se spusti');
    is($rc, 8, 'entrypoint: chybejici ovladac profilu start neprerusi');
    like($err, qr/\A${warn}PWE_PROFILE=postgres, ale image nema ovladac databaze DBD::Pg \(maji ho pwe-postgres a pwe-debugger\) - engine se k databazi nepripoji\n\z/, 'entrypoint: PWE_PROFILE=postgres v image bez DBD::Pg -> jednoradkove varovani na stderr');
    is($perl_log->(), "-MDBD::Pg -e 1\n", 'entrypoint: profil postgres -> zjistuje DBD::Pg');
    foreach my $profile (qw(mariadb mysql)) {
        ($rc, $out, $err) = $entry->({cwd => $dbapp, perl => 'missing', env => {PWE_PROFILE => $profile}}, 'readlink', 'conf/database.conf');
        is($out, "$profile.conf\n", "entrypoint: PWE_PROFILE=$profile bez ovladace -> symlink nasmerovan");
        like($err, qr/\A${warn}PWE_PROFILE=$profile, ale image nema ovladac databaze DBD::mysql \(maji ho pwe-mariadb, pwe-mysql a pwe-debugger\)[^\n]*\n\z/, "entrypoint: PWE_PROFILE=$profile v image bez DBD::mysql -> jednoradkove varovani");
        is($perl_log->(), "-MDBD::mysql -e 1\n", "entrypoint: profil $profile -> zjistuje DBD::mysql (engine ho pouziva pro mariadb i mysql)");
    }
    # ovladac se nezjistuje, kdyz o databazi profil nerozhoduje: profil static, zadny profil, vlastni
    # konfigurace webu (bezny soubor), chybejici conf/<profil>.conf (to uz hlasi jine varovani)
    ($rc, $out, $err) = $entry->({cwd => $dbapp, perl => 'missing', env => {PWE_PROFILE => 'static'}}, 'true');
    like($err, qr/\A${warn}PWE_PROFILE=static, ale conf\/database\.conf ukazuje na[^\n]*\n\z/, 'entrypoint: profil static -> jen varovani o symlinku, zadne o ovladaci');
    ($rc, $out, $err) = $entry->({cwd => $dbapp, perl => 'missing', env => \%none}, 'true');
    is($err, '', 'entrypoint: bez PWE_PROFILE se ovladac nezjistuje (zadne varovani)');
    rename("$dbapp/conf/postgres.conf", "$dbapp/conf/postgres.conf.off") or die $!;
    ($rc, $out, $err) = $entry->({cwd => $dbapp, perl => 'missing', env => {PWE_PROFILE => 'postgres'}}, 'true');
    like($err, qr/\A${warn}PWE_PROFILE=postgres, ale conf\/postgres\.conf neexistuje[^\n]*\n\z/, 'entrypoint: chybi conf/<profil>.conf -> jen varovani o konfiguraci, zadne o ovladaci');
    rename("$dbapp/conf/postgres.conf.off", "$dbapp/conf/postgres.conf") or die $!;
    unlink($link) or die $!;
    open(my $own2, '>', $link) or die $!; print $own2 "{ 'db1' => { dbdriver => 'vlastni' } };\n"; close($own2);
    ($rc, $out, $err) = $entry->({cwd => $dbapp, perl => 'missing', env => {PWE_PROFILE => 'postgres'}}, 'true');
    is($err, '', 'entrypoint: vlastni konfigurace webu (bezny soubor conf/database.conf) -> ovladac profilu se nehlasi');
    unlink($link) or die $!;
    is($perl_log->(), '', 'entrypoint: kdyz o databazi profil nerozhoduje, perl se kvuli ovladaci vubec nespousti');
    # skutecny perl image: varovani prave tehdy, kdyz ovladac v image opravdu neni
    foreach my $c (['postgres', 'DBD::Pg'], ['mariadb', 'DBD::mysql']) {
        my ($profile, $driver) = @{$c};
        my $has = eval("require $driver; 1") ? 1 : 0;
        ($rc, $out, $err) = $entry->({cwd => $dbapp, perl => 'real', env => {PWE_PROFILE => $profile}}, 'readlink', 'conf/database.conf');
        is($out, "$profile.conf\n", "entrypoint (skutecny perl): PWE_PROFILE=$profile -> symlink nasmerovan");
        is((($err =~ /\A${warn}PWE_PROFILE=$profile, ale image nema ovladac databaze \Q$driver\E [^\n]*\n\z/) ? 1 : 0), ($has ? 0 : 1),
            "entrypoint (skutecny perl): varovani o ovladaci $driver " . ($has ? 'neni - ovladac v image je' : 'je - ovladac v image chybi')) or diag($err);
    }

    # --- web bez databaze ---
    ($rc, $out, $err) = $entry->({cwd => $app, env => {PWE_PROFILE => 'static'}}, 'echo', 'bezi');
    is($out, "bezi\n", 'entrypoint webu bez DB: prikaz spusten');
    is($err, '', 'entrypoint webu bez DB s profilem static: zadne varovani');
    ($rc, $out, $err) = $entry->({cwd => $app, env => {PWE_PROFILE => 'mariadb'}}, 'echo', 'bezi');
    is($out, "bezi\n", 'entrypoint webu bez DB s databazovym profilem: prikaz spusten');
    like($err, qr/\A${warn}PWE_PROFILE=mariadb, ale conf\/mariadb\.conf neexistuje[^\n]*conf\/database\.conf neexistuje[^\n]*\n\z/, 'entrypoint webu bez DB s databazovym profilem: jednoradkove varovani');
    ok(!-e "$app/conf/database.conf" && !-l "$app/conf/database.conf", 'entrypoint webu bez DB: conf/database.conf nevznika');

    # --- vzorovy web zapeceny v image (pwe-example-*) spusteny jako server (FCGI_SOCKET_PATH): varovani, ze
    #     neni urcen pro verejny provoz (kazdy navstevnik ma skupinu admin vcetne pweCreator). Rozpoznani bez
    #     znacky v image: adresar webu example.web / example-db.web A engine zapeceny v image - v koreni enginu
    #     (PWE_CONF_pwe_core) je pwe.fcgi a neni docker/entrypoint.sh (pracovni kopie repozitare ho ma vzdy,
    #     Dockerfile webu adresar PWE/docker nekopiruje). Vyvojovy stack (mount repozitare), vlastni web,
    #     jeden request v rezimu CGI a jine prikazy (bez FCGI_SOCKET_PATH) varovani nevypisuji.
    my $img_root = File::Temp::tempdir('pwe-sample-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    chmod(0755, $img_root);
    my $core_img  = "$img_root/image/PWE";              # engine zapeceny v image: pwe.fcgi, zadny adresar docker
    my $core_repo = "$img_root/repo/PWE";               # pracovni kopie repozitare: pwe.fcgi i docker/entrypoint.sh
    my $core_none = "$img_root/prazdny/PWE";            # koren enginu bez enginu (zavislostni image bez mountu)
    make_path($core_img, "$core_repo/docker", $core_none);
    foreach my $f ("$core_img/pwe.fcgi", "$core_repo/pwe.fcgi", "$core_repo/docker/entrypoint.sh") { open(my $fh, '>', $f) or die $!; print $fh "#\n"; close($fh); }
    my %sample;                                         # vzorove weby (kopie vygenerovanych webu pod jmeny vzorovych)
    foreach my $c (['example.web', $app], ['example-db.web', $dbapp], ['muj.web', $app], ['example.webx', $app]) {
        my ($web, $from) = @{$c};
        $sample{$web} = "$img_root/webapps/$web";
        make_path("$sample{$web}/conf");
        open(my $fh, '>', "$sample{$web}/conf/web.conf") or die $!; print $fh slurp("$from/conf/web.conf"); close($fh);
    }
    my $sample_warn = sub { my ($web) = @_; return qr/${warn}bezi vzorovy web \Q$web\E zapeceny v image \([^\n]*skupinu admin[^\n]*pweCreator[^\n]*\) - neni urcen pro verejny provoz[^\n]*\n/; };
    my %server = (PWE_PROFILE => 'static', FCGI_SOCKET_PATH => ':7779', PWE_CONF_pwe_core => $core_img);
    my $w_static = $sample_warn->('example.web');
    ($rc, $out, $err) = $entry->({cwd => $sample{'example.web'}, env => {%server}}, 'sh', '-c', 'echo bezi; exit 9');
    is("$rc|$out", "9|bezi\n", 'entrypoint: vzorovy web z image jako server -> prikaz se spusti a start se neprerusi');
    like($err, qr/\A$w_static\z/, 'entrypoint: vzorovy web example.web zapeceny v image jako server (FCGI_SOCKET_PATH) -> jednoradkove varovani, ze neni urcen pro verejny provoz');
    ($rc, $out, $err) = $entry->({cwd => $sample{'example-db.web'}, env => {%server, PWE_PROFILE => undef}}, 'true');
    like($err, qr/\A@{[$sample_warn->('example-db.web')]}\z/, 'entrypoint: vzorovy web example-db.web -> stejne varovani (na PWE_PROFILE nezavisi)');
    ($rc, $out, $err) = $entry->({cwd => $sample{'example.web'}, env => {%server, FCGI_SOCKET_PATH => '/run/pwe/fcgi.sock'}}, 'true');
    like($err, qr/\A$w_static\z/, 'entrypoint: vzorovy web jako server na unix socketu -> stejne varovani');
    ($rc, $out, $err) = $entry->({cwd => $sample{'example.web'}, env => {%server, PWE_CONF_pwe_core => "$core_img/"}}, 'true');
    like($err, qr/\A$w_static\z/, 'entrypoint: PWE_CONF_pwe_core s koncovym lomitkem -> stejne varovani');
    # kdy se nevaruje
    ($rc, $out, $err) = $entry->({cwd => $sample{'example.web'}, env => {%server, FCGI_SOCKET_PATH => undef}}, 'echo', 'bezi');
    is($out . $err, "bezi\n", 'entrypoint: vzorovy web bez FCGI_SOCKET_PATH (jeden request v rezimu CGI, jiny prikaz) -> bez varovani');
    ($rc, $out, $err) = $entry->({cwd => $sample{'example.web'}, env => {%server, FCGI_SOCKET_PATH => ''}}, 'echo', 'bezi');
    is($out . $err, "bezi\n", 'entrypoint: prazdna FCGI_SOCKET_PATH = nenastavena (bez varovani)');
    ($rc, $out, $err) = $entry->({cwd => $sample{'example.web'}, env => {%server, PWE_CONF_pwe_core => $core_repo}}, 'echo', 'bezi');
    is($out . $err, "bezi\n", 'entrypoint: vzorovy web nad pracovni kopii repozitare (v koreni enginu je docker/entrypoint.sh - vyvojovy stack) -> bez varovani');
    ($rc, $out, $err) = $entry->({cwd => $sample{'example-db.web'}, env => {%server, PWE_PROFILE => undef, PWE_CONF_pwe_core => "$core_repo/"}}, 'echo', 'bezi');
    is($out . $err, "bezi\n", 'entrypoint: example-db.web nad pracovni kopii repozitare (vychozi web vyvojoveho stacku) -> bez varovani');
    ($rc, $out, $err) = $entry->({cwd => $sample{'example.web'}, env => {%server, PWE_CONF_pwe_core => $core_none}}, 'echo', 'bezi');
    is($out . $err, "bezi\n", 'entrypoint: koren enginu bez pwe.fcgi (engine v image neni) -> bez varovani');
    foreach my $own (qw(muj.web example.webx)) {
        ($rc, $out, $err) = $entry->({cwd => $sample{$own}, env => {%server}}, 'echo', 'bezi');
        is($out . $err, "bezi\n", "entrypoint: vlastni web $own zapeceny v image jako server -> bez varovani (varuje se jen u example.web a example-db.web)");
    }
    ($rc, $out, $err) = $entry->({cwd => $app, env => {%server}}, 'echo', 'bezi');
    is($out . $err, "bezi\n", 'entrypoint: vygenerovany web tool.web jako server -> bez varovani');
    # varovani o profilu a o vzorovem webu se nevylucuji: kazde na svem radku, start se neprerusi
    ($rc, $out, $err) = $entry->({cwd => $sample{'example.web'}, env => {%server, PWE_PROFILE => 'mariadb'}}, 'sh', '-c', 'exit 4');
    is($rc, 4, 'entrypoint: vzorovy web s neodpovidajicim profilem start neprerusi');
    is(scalar(() = $err =~ /^\[entrypoint\] VAROVANI: /mg), 2, 'entrypoint: varovani o profilu a o vzorovem webu - kazde na svem radku');
    like($err, qr/\A${warn}PWE_PROFILE=mariadb, ale conf\/mariadb\.conf neexistuje[^\n]*\n$w_static\z/, 'entrypoint: nejdriv varovani o profilu, pak o vzorovem webu');
    # bez PWE_CONF_pwe_core plati vychozi koren enginu /PWE/PWE: v testovacim kontejneru je to mount repozitare
    # (pracovni kopie s docker/entrypoint.sh) -> bez varovani
  SKIP: {
        skip 'vychozi koren enginu /PWE/PWE neni pracovni kopie repozitare', 1 unless (-f '/PWE/PWE/pwe.fcgi' and -f '/PWE/PWE/docker/entrypoint.sh');
        ($rc, $out, $err) = $entry->({cwd => $sample{'example.web'}, env => {%server, PWE_CONF_pwe_core => undef}}, 'echo', 'bezi');
        is($out . $err, "bezi\n", 'entrypoint: bez PWE_CONF_pwe_core se koren enginu hleda v /PWE/PWE (mount repozitare = pracovni kopie -> bez varovani)');
    }
    ok(!-e "$sample{'example.web'}/.pwe-sample-web" && !-e "$app/.pwe-sample-web", 'entrypoint: zadnou znacku vzoroveho webu nezaklada');

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
    # adresar se jmenem vzoroveho webu, ale bez conf/web.conf (neni to adresar webu): zadne varovani
    make_path("$img_root/mimo/example.web");
    ($rc, $out, $err) = $entry->({cwd => "$img_root/mimo/example.web", env => {%server}}, 'echo', 'jen', 'prikaz');
    is($out . $err, "jen prikaz\n", 'entrypoint mimo adresar webu nevaruje ani v adresari se jmenem vzoroveho webu');

    # --- web jen pro cteni (read-only root FS, mount :ro): chyby zapisu start neprerusi; varuje se jen
    #     tehdy, kdyz conf/database.conf profilu neodpovida. Adresar je mimo mount repozitare (/tmp
    #     kontejneru) a prikaz bezi bez prav roota - root by do adresare bez prava zapisu zapsal.
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
        skip 'adresar bez prava zapisu je pro testovaciho uzivatele porad zapisovatelny (nelze zahodit prava roota)', 9 if ($rc_p == 0 or $rc_p == 124);
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
        # ovladac se zjistuje i u webu jen pro cteni, kdyz symlink profilu odpovida
        ($rc, $out, $err) = $entry->({%ro, perl => 'missing', env => {PWE_PROFILE => 'mysql'}}, 'sh', '-c', 'readlink conf/database.conf; exit 6');
        is("$rc|$out", "6|mysql.conf\n", 'entrypoint: web jen pro cteni bez ovladace profilu -> prikaz se spusti');
        like($err, qr/\A${warn}PWE_PROFILE=mysql, ale image nema ovladac databaze DBD::mysql [^\n]*\n\z/, 'entrypoint: web jen pro cteni, symlink odpovida, ovladac chybi -> jednoradkove varovani');
    }
    chmod(0755, $ro, "$ro/conf");
}

# ---------------------------------------------------------------------------------------------
# .dockerignore v koreni repozitare (kontext sestaveni vsech image): do image webu se nesmi dostat soukrome
# klice a lokalni soubory webu (webapps/<web>/Dockerfile kopiruje cely adresar webu) ani testy enginu;
# konfigurace, verejne klice a engine (zdroj /PWE/PWE v image webu) zustavaji
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
    skip '.dockerignore neni k dispozici (engine bez korene repozitare)', scalar(@secret) + scalar(@kept) + 11 unless (length($ignore));
    my @patterns = grep { length($_) and $_ !~ /^#/ } map { my $l = $_; $l =~ s/^\s+|\s+$//g; $l } split(/\n/, $ignore);
    ok(dockerignore_excludes(\@patterns, "webapps/muj.web/$_"), ".dockerignore: webapps/<web>/$_ se do image webu nedostane") foreach (@secret);
    ok(!dockerignore_excludes(\@patterns, "webapps/muj.web/$_"), ".dockerignore: webapps/<web>/$_ v image webu zustava") foreach (@kept);
    # kontext image webu obsahuje i engine: vsechno, co Dockerfile webu kopiruje do /PWE/PWE, musi v kontextu zustat
    my @engine_ctx = ('LICENSE', map { (-d "$ROOT/$_") ? ("PWE/$_", "PWE/$_/soubor", "PWE/$_/pod/adresar/soubor.pm") : ("PWE/$_") } PWE::ToolEnv::engine_image_entries($ROOT));
    ok(@engine_ctx > 20 && !(grep { dockerignore_excludes(\@patterns, $_) } @engine_ctx), '.dockerignore: kazda polozka enginu, kterou kopiruje Dockerfile webu (LICENSE, PWE/<polozka>), zustava v kontextu') or diag(join(' ', grep { dockerignore_excludes(\@patterns, $_) } @engine_ctx));
    ok(!dockerignore_excludes(\@patterns, 'PWE/docker/entrypoint.sh'), '.dockerignore: PWE/docker/entrypoint.sh zustava v kontextu (kopiruje ho stage base zavislostnich image)');
    ok(!(grep { !dockerignore_excludes(\@patterns, $_) } qw(PWE/t PWE/t/14-tools.t PWE/t/lib/PWE/TestEnv.pm PWE/t/fixtures/app/ramdisk/x PWE/t/.run-tests.lock/pid)), '.dockerignore: testy enginu (PWE/t vcetne docasnych dat fixture) se do zadneho image nedostanou');
    ok(!(grep { !dockerignore_excludes(\@patterns, $_) } qw(.git/config webapps/muj.web/.git/HEAD webapps-example/knihy/conf/web.conf PWE/Libs/.DS_Store kubernetes/local.env kubernetes/secrets-generic.yml)), '.dockerignore: git, historicke weby, .DS_Store a mistni nastaveni nasazeni se do kontextu nedostanou');
    unlike($ignore, qr{pwe-static|\bimage pwe(?![\w.-])|profilov}, '.dockerignore: komentare nemluvi o zrusenych image (pwe, pwe-static) ani o profilovych image se vzorovym webem');
    # hlavicka generovaneho Dockerfile webu popisuje, co .dockerignore vynechava: vzory soukromych klicu, ktere
    # jmenuje, musi .dockerignore opravdu mit - a pro cely adresar webu, ne jen pod conf/
    my ($head) = slurp("$app/Dockerfile") =~ /\A((?:#[^\n]*\n)+)/;
    my @named = (defined($head) ? $head : '') =~ /(\*\.\w+)/g;
    ok(scalar(@named) >= 5 && !(grep { my $ext = substr($_, 1); !dockerignore_excludes(\@patterns, "webapps/muj.web/soubor$ext") or !dockerignore_excludes(\@patterns, "webapps/muj.web/klice/2026/soubor$ext") } @named),
        'Dockerfile webu: vzory soukromych souboru jmenovane v hlavicce (*.pem, *.key, *.p12, *.pfx, *.env) .dockerignore vynechava v celem adresari webu') or diag("@named");
    unlike(defined($head) ? $head : '', qr{klice conf/|conf/\*\*/}, 'Dockerfile webu: hlavicka netvrdi, ze se soukrome klice vynechavaji jen pod conf/');
    # vzorove weby se kopiruji do image pwe-example-* (jejich Dockerfile): bez docasnych adresaru, bez
    # mistniho nastaveni a bez conf/database.conf (symlink podle profilu zaklada az Dockerfile webu)
    foreach my $sample (qw(example.web example-db.web)) {
        ok(!(grep { !dockerignore_excludes(\@patterns, "webapps/$sample/$_") } ('ramdisk', 'ramdisk/templates/x.tmplc', 'log', 'log/mysql', 'sessions/C0AA', 'uploadfile/soubor.pdf', 'temp/x', 'conf/database.conf', 'conf/local.env', '.vscode/launch.json', '.DS_Store')),
            ".dockerignore: docasna data, mistni nastaveni a conf/database.conf vzoroveho webu $sample se do image vzoroveho webu nedostanou");
        ok(!(grep { dockerignore_excludes(\@patterns, "webapps/$sample/$_") } qw(conf/web.conf conf/mariadb.conf conf/mariadb.dbversion conf/postgres.conf Pages/default/default.pm Sites/Default/Default.pm static/css/site.css .htaccess)),
            ".dockerignore: soubory vzoroveho webu $sample zustavaji v kontextu");
    }
}

# ---------------------------------------------------------------------------------------------
# Dockerfile zavislostnich image (docker/Dockerfile): stage base, mariadb, mysql, postgres, debugger = jen
# knihovny. Zadny stage neobsahuje kod enginu ani web (z kontextu se kopiruje jen entrypoint) a nenastavuje
# PWE_CONF_pwe_home ani PWE_PROFILE; zrusene stage pwe (nosic enginu) a static uz neexistuji. Balicky
# zakladniho image (jen to, co potrebuje beh enginu a webu), ladici nastroje jen v image debugger.
# ---------------------------------------------------------------------------------------------
SKIP: {
    my $engine_df = slurp("$ROOT/docker/Dockerfile");
    skip 'docker/Dockerfile neni k dispozici', 51 unless (length($engine_df));
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
    my @db      = qw(mariadb mysql postgres);

    is_deeply(\@stages, [qw(base mariadb mysql postgres debugger)], 'Dockerfile zavislostnich image: stage base, mariadb, mysql, postgres, debugger (kazdy = jeden image)');
    ok(!exists($from{'pwe'}) && !exists($from{'static'}), 'Dockerfile zavislostnich image: zrusene stage pwe (nosic enginu) a static uz neexistuji');
    is_deeply([map { "pwe-$_" } @stages], [PWE::ToolEnv::image_names('deps')], 'Dockerfile zavislostnich image: stage odpovidaji seznamu zavislostnich image (image_names deps)');
    is($from{'base'}, '${UBUNTU_IMAGE}', 'Dockerfile zavislostnich image: base vychazi z image Ubuntu (jediny vnejsi zaklad)');
    is($from{$_}, 'base', "Dockerfile zavislostnich image: stage $_ vychazi z base") foreach (@db, 'debugger');

    is_deeply([sort @{$pkg{'base'}}], [sort qw(
        perl libcgi-pm-perl libcgi-fast-perl libtemplate-perl libclass-inspector-perl libmoose-perl libjson-perl libjson-xs-perl libdbi-perl
        libmail-rfc822-address-perl cstocs liblwp-mediatypes-perl libio-socket-ssl-perl libnet-ssleay-perl libauthen-sasl-perl ca-certificates
        ruby-sass imagemagick tzdata
        libimage-magick-perl libcrypt-openssl-rsa-perl openssl liburi-perl libhtml-parser-perl
    )], 'Dockerfile zavislostnich image: base instaluje prave balicky pro beh enginu a webu (novy balicek = vedoma zmena tohoto seznamu)');
    ok($has_pkg->('base', 'tzdata'), 'Dockerfile zavislostnich image: base ma tzdata (bez nej nema promenna TZ ucinek)');
    like($body{'base'}, qr{\btest -f /usr/share/zoneinfo/Europe/Prague;}, 'Dockerfile zavislostnich image: build base overuje databazi casovych pasem (Europe/Prague)');
    unlike(join('', values %body), qr{^ENV .*\bTZ=}m, 'Dockerfile zavislostnich image: zadny stage nenastavuje TZ (vychozi pasmo zustava UTC, meni se promennou TZ za behu)');
    ok(!(grep { $has_pkg->('base', $_) } qw(libwww-perl liblwp-protocol-https-perl libdata-uuid-perl libdata-guid-perl libcrypt-openssl-x509-perl)), 'Dockerfile zavislostnich image: base nema knihovny, ktere engine ani weby nepouzivaji (LWP, Data::UUID, Data::GUID, Crypt::OpenSSL::X509)');
    ok($has_pkg->('base', 'liblwp-mediatypes-perl'), 'Dockerfile zavislostnich image: LWP::MediaTypes (Libs::Send) zustava ze samostatneho balicku');
    ok(!(grep { /^libdbd-/ } @{$pkg{'base'}}), 'Dockerfile zavislostnich image: base nema zadny databazovy ovladac');
    ok($has_pkg->('debugger', 'curl'), 'Dockerfile zavislostnich image: curl je v image debugger');
    ok(!(grep { $has_pkg->($_, 'curl') } grep { $_ ne 'debugger' } @stages), 'Dockerfile zavislostnich image: curl neni v zadnem jinem image nez debugger');
    is_deeply([sort @{$pkg{'mariadb'}}],  [qw(libdbd-mariadb-perl libdbd-mysql-perl)], 'Dockerfile zavislostnich image: stage mariadb instaluje prave DBD::mysql a DBD::MariaDB');
    is_deeply([sort @{$pkg{'mysql'}}],    ['libdbd-mysql-perl'],                        'Dockerfile zavislostnich image: stage mysql instaluje prave DBD::mysql');
    is_deeply([sort @{$pkg{'postgres'}}], ['libdbd-pg-perl'],                           'Dockerfile zavislostnich image: stage postgres instaluje prave DBD::Pg');
    ok(!(grep { !$has_pkg->('debugger', $_) } qw(libdbd-mysql-perl libdbd-mariadb-perl libdbd-pg-perl cpanminus)), 'Dockerfile zavislostnich image: debugger ma vsechny tri ovladace a cpanm');
    like($body{'debugger'}, qr{^ENV PERL_CPANM_OPT="--from https://www\.cpan\.org/"$}m, 'Dockerfile zavislostnich image: cpanm v image debugger stahuje jen pres HTTPS (PERL_CPANM_OPT)');
    like($body{'base'}, qr{^COPY --chmod=0755 PWE/docker/entrypoint\.sh /usr/local/bin/entrypoint\.sh$}m, 'Dockerfile zavislostnich image: base instaluje docker/entrypoint.sh jako spustitelny');
    like($body{'base'}, qr{^ENTRYPOINT \["/usr/local/bin/entrypoint\.sh"\]$}m, 'Dockerfile zavislostnich image: base nastavuje ENTRYPOINT');
    like($body{'base'}, qr{^ENV PWE_CONF_pwe_core=/PWE/PWE$}m, 'Dockerfile zavislostnich image: base nastavuje PWE_CONF_pwe_core=/PWE/PWE (koren enginu z mountu nebo z image webu)');
    like($body{'base'}, qr{^CMD \["perl", "/PWE/PWE/pwe\.fcgi"\]$}m, 'Dockerfile zavislostnich image: base nastavuje CMD perl /PWE/PWE/pwe.fcgi');
    ok(!(grep { $body{$_} =~ /^(?:ENTRYPOINT|CMD|WORKDIR)\b/m } grep { $_ ne 'base' } @stages), 'Dockerfile zavislostnich image: odvozene stage ENTRYPOINT, CMD ani WORKDIR neprepisuji (dedi je z base)');
    like($engine_df, qr/^ARG UBUNTU_IMAGE=[a-z0-9][a-z0-9._\/-]*:[A-Za-z0-9_][A-Za-z0-9_.-]*$/m, 'Dockerfile zavislostnich image: zakladni image Ubuntu je pripnuty argumentem UBUNTU_IMAGE tvaru <image>:<tag>');

    # --- zadny kod enginu a zadny web: z kontextu se kopiruje jen entrypoint ---
    my @copies = map { my $st = $_; map { "$st: $_" } ($body{$st} =~ /^(COPY [^\n]*)$/mg) } @stages;
    is_deeply(\@copies, ['base: COPY --chmod=0755 PWE/docker/entrypoint.sh /usr/local/bin/entrypoint.sh'], 'Dockerfile zavislostnich image: jedina instrukce COPY v celem souboru je entrypoint (zadny kod enginu, zadny web, zadne COPY --from)');
    unlike($engine_df =~ s/^\s*#.*\n//mgr, qr{^ADD\b}m, 'Dockerfile zavislostnich image: zadna instrukce ADD');
    foreach my $st (@stages) {
        unlike($body{$st}, qr{\bwebapps/example|PWE_CONF_pwe_home|PWE_PROFILE|pwe-sample-web|PWE_VERSION}, "Dockerfile zavislostnich image: stage $st je bez vzoroveho webu, bez ENV webu (PWE_CONF_pwe_home, PWE_PROFILE), bez znacky vzoroveho webu a bez verze enginu");
        like($body{$st}, qr{^LABEL .*\borg\.opencontainers\.image\.title="pwe-\Q$st\E"(?: |$)}m, "Dockerfile zavislostnich image: stage $st - popisek title pwe-$st");
        like($body{$st}, qr{^LABEL .*\borg\.opencontainers\.image\.description="[^"]*\bbez kodu enginu\b[^"]*"(?: |$)}m, "Dockerfile zavislostnich image: stage $st - popisek description rika, ze image je bez kodu enginu");
    }
    foreach my $st (@db) {
        my @ins = split(/\n/, $body{$st});
        ok(@ins == 2 && $ins[0] =~ /^RUN [^\n]*apt-get install/ && $ins[1] =~ /^LABEL /, "Dockerfile zavislostnich image: stage $st = jen instalace ovladace a popisky (nic dalsiho)") or diag($body{$st});
    }
    is_deeply([map { $_ =~ /^ENV (\S+?)=/ ? $1 : () } split(/\n/, join('', map { $body{$_} } @stages))], [qw(PWE_CONF_pwe_core PERL_CPANM_OPT)], 'Dockerfile zavislostnich image: jedine ENV jsou PWE_CONF_pwe_core (base) a PERL_CPANM_OPT (debugger)');
    like($body{'base'}, qr{^LABEL .*\borg\.opencontainers\.image\.version=""(?: |$)}m, 'Dockerfile zavislostnich image: base popisek version vyprazdni (verze image Ubuntu o PWE nic nerika; verzi enginu nesou jen image s enginem)');
    unlike(join('', values %body), qr{org\.opencontainers\.image\.version="[^"]|org\.opencontainers\.image\.revision|org\.opencontainers\.image\.created="[^"]}, 'Dockerfile zavislostnich image: verzi enginu, commit ani cas buildu zadny stage nenastavuje (digest se meni jen se zavislostmi; tyto popisky doplnuje docker-bake.hcl image vzorovych webu)');
}

# ---------------------------------------------------------------------------------------------
# vzorove weby v repozitari pouzivaji tutez sablonu: Dockerfile = presny vystup generatoru (lisi se jen
# nazvem webu, PWE_PROFILE a zakladem), vlastni entrypoint.sh nemaji. Jejich Dockerfile stavi image
# vzorovych webu pwe-example-* (docker-bake.hcl) - zadna zvlastni stage v docker/Dockerfile.
# ---------------------------------------------------------------------------------------------
foreach my $ex (['example.web', 'none', 'static'], ['example-db.web', 'mariadb', 'mariadb']) {
    my ($web, $db, $profile) = @{$ex};
    my $dir = dirname($ROOT) . "/webapps/$web";
  SKIP: {
        skip "webapps/$web neni k dispozici ($dir)", $DOCKERFILE_TESTS + 4 unless (-f "$dir/conf/web.conf");
        ($rc, $out) = run_tool("$TOOLS/new-webapp.pl", $web, '--dir', "$base/vzor/$web", '--db', $db);
        is($rc, 0, "new-webapp.pl $web --db $db (vzor pro porovnani)") or diag($out);
        dockerfile_ok("$dir/Dockerfile", $web, $profile, "webapps/$web/Dockerfile");
        ok(slurp("$dir/Dockerfile") eq slurp("$base/vzor/$web/Dockerfile"), "webapps/$web/Dockerfile je shodny s vystupem generatoru");
        ok(!-e "$dir/entrypoint.sh", "webapps/$web nema vlastni entrypoint.sh (image webu ho dedi ze zakladniho image)");
        ($rc, $out) = run_tool("$TOOLS/check-webapp.pl", $dir, '--static');
        like($out, qr/^OK   Dockerfile: FROM a kopie enginu podle sablony generatoru$/m, "check-webapp.pl: Dockerfile vzoroveho webu $web -> OK") or diag($out);
    }
}

# ---------------------------------------------------------------------------------------------
# zrusene image pwe (nosic enginu) a pwe-static: v nastrojich, Dockerfile, bake ani compose o nich nesmi zustat
# zminka - krome mist, ktera je vyslovne odmitaji nebo popisuji prechod ze starsiho usporadani (radek pak
# obsahuje slovo "zrusen")
# ---------------------------------------------------------------------------------------------
{
    my $repo  = dirname($ROOT);
    my @files = ((map { "$TOOLS/$_" } qw(new-webapp.pl new-module.pl check-webapp.pl smtp-test.pl build-images.sh smoke-images.sh run-webapp.sh run-tests.sh perl-compile.sh pwe-cgi.sh lib/images.sh lib/PWE/ToolEnv.pm)),
        "$ROOT/docker/Dockerfile", "$ROOT/docker/entrypoint.sh",
        (grep { -f $_ } map { "$repo/$_" } qw(docker-bake.hcl docker-compose.yml Makefile .dockerignore webapps/example.web/Dockerfile webapps/example-db.web/Dockerfile)));
    my @bad;
    foreach my $file (@files) {
        my $n = 0;
        foreach my $line (split(/\n/, slurp($file))) {
            $n++;
            next unless ($line =~ m{pwe-static|/pwe:|\bimage pwe(?![\w.-])|\b[Cc]il pwe(?![\w.-])|\bstage pwe(?![\w.-])});
            next if ($line =~ /zrusen/i);
            # check-webapp.pl: rozpoznani Dockerfile z prvniho usporadani (engine z image pwe) = popis prechodu
            next if ($file =~ m{/check-webapp\.pl$} and $line =~ /image pwe(?: \(jen engine\))? jako (?:zdroj enginu|dalsi FROM)|<image pwe>|engine z image pwe/);
            push(@bad, substr($file, length($repo) + 1) . ":$n: $line");
        }
    }
    is_deeply(\@bad, [], 'nastroje, Dockerfile, bake, compose, Makefile: zadna zminka o zrusenych image pwe a pwe-static mimo jejich odmitnuti a popis prechodu') or diag(join("\n", @bad));
}

remove_tree($base);
done_testing();
