package PWE::ToolEnv;

=head1 NAME

PWE::ToolEnv - spolecne pomocne funkce pro vyvojove skripty v PWE/tools/ (new-webapp.pl, new-module.pl, check-webapp.pl, smtp-test.pl)

=head1 POPIS

    Modul pouziva jen moduly z jadra Perlu, aby sel spustit i na hostiteli bez zavislosti
    enginu. Skripty, ktere potrebuji Template / Class::Inspector, zavolaji ensure_modules()
    a ta je v pripade potreby znovu spusti v kontejneru s image nastroju (docker_image(),
    vychozi ghcr.io/kukam/pwe-debugger:<vetev>) s repozitarem namountovanym do /PWE.

    Jmena image (stejna pravidla jako shell funkce v PWE/tools/lib/images.sh, ktere pouzivaji
    skripty *.sh - obe implementace musi davat stejny vysledek, hlidaji to PWE/t/14-tools.t
    a PWE/t/21-image-tools.t):

      PWE_IMAGE_REGISTRY   registr a jmenny prostor image (vychozi ghcr.io/kukam)   -> image_registry()
      PWE_IMAGE_TAG        tag image (vychozi = aktualni vetev gitu repozitare)     -> image_tag()
                           musi to byt platny tag image (image_tag_valid()), jinak image_tag() konci chybou
      PWE_TEST_IMAGE       cele jmeno image nastroju vcetne tagu, ma prednost       -> docker_image()

    Rozlozeni repozitare: <repo>/PWE/ = engine (pwe.fcgi, Libs, ...), <repo>/webapps/<web>/ = weby.
    V kontejneru je <repo> namountovan do /PWE, engine je tam tedy /PWE/PWE a weby /PWE/webapps/<web>.

    Slovo "core" v nazvech (core_root(), volba core => ..., pwe.core, PWE_CONF_pwe_core) znamena
    koren enginu, tedy adresar PWE/ - neni to nazev adresare. V ceste k tomuto souboru
    (PWE/tools/lib/PWE/ToolEnv.pm) je prvni PWE adresar enginu, druhe PWE jmenny prostor modulu.

    use FindBin;
    use lib "$FindBin::Bin/lib";
    use PWE::ToolEnv qw(repo_root core_root resolve_webapp ensure_modules write_file read_conf run_cgi parse_response);

=cut

use strict;
use warnings;
use Cwd qw(abs_path getcwd);
use File::Basename qw(dirname basename);
use File::Path qw(make_path);
use File::Spec;
use Exporter 'import';

# Puvodni argumenty skriptu - GetOptions je z @ARGV odebere, ale re-exec v kontejneru je potrebuje cele.
our @ORIG_ARGV;
BEGIN { @ORIG_ARGV = @ARGV; }

our @EXPORT_OK = qw(
    repo_root core_root engine_root resolve_webapp webapp_name in_container docker_image has_docker ensure_modules
    image_registry image_tag image_tag_sanitize image_tag_valid
    write_file symlink_rel read_conf conf_languages run_cgi parse_response shell_quote
);

=head2 B<[Public] core_root()>

    Vraci absolutni cestu ke koreni enginu (adresar PWE/ v koreni repozitare, tj. adresar
    s pwe.fcgi; v kontejneru /PWE/PWE), bez koncoveho lomitka. Odvozuje se od umisteni tohoto
    modulu (<engine>/tools/lib/PWE/ToolEnv.pm -> tri urovne nahoru), ne od nazvu adresare.

=cut

sub core_root {
    my $root = abs_path(dirname(__FILE__) . "/../../..");
    $root =~ s{/+$}{};
    return $root;
}

=head2 B<[Public] engine_root()>

    Alias core_root() (puvodni nazev) - koren enginu, adresar PWE/.

=cut

sub engine_root { return core_root(); }

=head2 B<[Public] repo_root()>

    Vraci absolutni cestu ke koreni repozitare (adresar o uroven vys nez engine PWE/), kde lezi
    webapps/, docker-compose.yml, Makefile a docs/. V kontejneru je to /PWE.

=cut

sub repo_root {
    return dirname(core_root());
}

=head2 B<[Public] resolve_webapp($arg)>

    Prevede argument skriptu na absolutni cestu k adresari webu. Nazev bez lomitka znamena
    <repo>/webapps/<nazev>, cesta s lomitkem se pouzije tak, jak je (relativne k aktualnimu
    adresari). Koncove lomitko se odstrani.

=cut

sub resolve_webapp {
    my ($arg) = @_;
    die "Chybi nazev webu (napr. mujweb.web nebo cesta/k/webu)\n" unless (defined($arg) and length($arg));
    my $dir = ($arg =~ m{/}) ? File::Spec->rel2abs($arg) : repo_root() . "/webapps/$arg";
    $dir =~ s{/+$}{};
    return $dir;
}

=head2 B<[Public] webapp_name($dir)>

    Vraci nazev webu (posledni cast cesty).

=cut

sub webapp_name {
    my ($dir) = @_;
    $dir =~ s{/+$}{};
    return basename($dir);
}

=head2 B<[Public] in_container()>

    Vraci 1, pokud skript bezi uvnitr kontejneru (existuje /.dockerenv nebo je nastaveno
    PWE_TOOLS_IN_DOCKER), jinak 0.

=cut

sub in_container {
    return 1 if (-f '/.dockerenv');
    return 1 if ($ENV{'PWE_TOOLS_IN_DOCKER'});
    return 0;
}

=head2 B<[Public] image_registry()>

    Vraci registr a jmenny prostor image PWE bez koncoveho lomitka: $ENV{PWE_IMAGE_REGISTRY},
    jinak ghcr.io/kukam. (Shell: pwe_image_registry v PWE/tools/lib/images.sh.)

=cut

sub image_registry {
    my $registry = _env('PWE_IMAGE_REGISTRY');
    $registry = 'ghcr.io/kukam' unless (length($registry));
    $registry =~ s{/$}{};
    return $registry;
}

=head2 B<[Public] image_tag_sanitize($vetev)>

    Prevede nazev vetve na platny tag image: znaky mimo [A-Za-z0-9_.-] nahradi pomlckou, odstrani
    uvodni tecky a pomlcky a zkrati na 128 znaku (feature/kosik -> feature-kosik). Prazdny
    vysledek (i undef) = master. Pracuje po bajtech jako shell (znak s diakritikou v UTF-8 =
    dve pomlcky). Cista funkce bez vedlejsich ucinku. (Shell: pwe_image_tag_sanitize.)

=cut

sub image_tag_sanitize {
    my ($branch) = @_;
    my $tag = defined($branch) ? $branch : '';
    utf8::encode($tag) if (utf8::is_utf8($tag));
    $tag =~ s/\n+\z//;
    $tag =~ s/[^A-Za-z0-9_.-]/-/g;
    $tag =~ s/^[.-]+//;
    $tag = substr($tag, 0, 128);
    return length($tag) ? $tag : 'master';
}

=head2 B<[Public] image_tag_valid($tag)>

    Vraci 1, kdyz je $tag platny tag image, tj. odpovida ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$
    (bez koncoveho noveho radku), jinak 0. Cista funkce. (Shell: pwe_image_tag_valid.)

=cut

sub image_tag_valid {
    my ($tag) = @_;
    return 0 unless (defined($tag));
    return ($tag =~ /\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\z/) ? 1 : 0;
}

=head2 B<[Public] image_tag()>

    Vraci tag image PWE: $ENV{PWE_IMAGE_TAG} (beze zmeny), jinak aktualni vetev gitu repozitare
    (repo_root()) prevedenou pres image_tag_sanitize(). Bez gitu, mimo gitovy repozitar a
    v detached HEAD vraci master. V kontejneru (in_container()) se git nevola - neni tam a
    repozitar je jen namountovany do /PWE: plati $ENV{PWE_IMAGE_TAG} (ensure_modules() ho do
    kontejneru predava), jinak master. $ENV{PWE_IMAGE_TAG}, ktery neni platny tag image
    (image_tag_valid(), napr. neprevedeny nazev vetve s lomitkem), se nepouzije: funkce skonci
    pres die s hlaskou, jak nazev vetve prevest. (Shell: pwe_image_tag, tam navratovy kod 2.)

=cut

sub image_tag {
    my $tag = _env('PWE_IMAGE_TAG');
    if (length($tag)) {
        die "PWE_IMAGE_TAG='$tag' neni platny tag image (povolene znaky A-Z a-z 0-9 _ . -, nezacina teckou ani pomlckou, nejvys 128 znaku). Nazev vetve preved: bash PWE/tools/lib/images.sh pwe_image_tag_sanitize '$tag'\n" unless (image_tag_valid($tag));
        return $tag;
    }
    return image_tag_sanitize(_git_branch());
}

=head2 B<[Private] _git_branch()>

    Vraci nazev aktualni vetve gitu repozitare, nebo prazdny retezec (v kontejneru, bez prikazu
    git, mimo repozitar, v detached HEAD). Vetev se bere jen tehdy, kdyz je repo_root() korenem
    pracovni kopie (rev-parse --show-prefix je prazdny): repozitar rozbaleny uvnitr ciziho
    gitoveho repozitare jeho vetev nepouzije.

=cut

sub _git_branch {
    return '' if (in_container());
    return '' unless (_in_path('git'));
    my $repo = shell_quote(repo_root());
    my $prefix = `git -C $repo rev-parse --show-prefix 2>/dev/null`;
    return '' if ($? != 0 or !defined($prefix));
    $prefix =~ s/\n+\z//;
    return '' if (length($prefix));
    my $branch = `git -C $repo symbolic-ref --quiet --short HEAD 2>/dev/null`;
    return '' if ($? != 0 or !defined($branch));
    $branch =~ s/\n+\z//;
    return $branch;
}

=head2 B<[Public] docker_image()>

    Image pro vyvojove nastroje spoustene v kontejneru (make module, check, smtp-test; shell
    skripty make test, compile, cgi pouzivaji stejne pravidlo pres pwe_tool_image; make new bezi
    na hostiteli a image nepotrebuje): $ENV{PWE_TEST_IMAGE} (cele jmeno vcetne tagu), jinak
    <image_registry()>/pwe-debugger:<image_tag()> - image pwe-debugger ma vsechny databazove
    ovladace. Vychozi tedy ghcr.io/kukam/pwe-debugger:<vetev>; sestavi ho make images
    (PWE/tools/build-images.sh). Pri neplatnem $ENV{PWE_IMAGE_TAG} konci chybou jako image_tag().

=cut

sub docker_image {
    my $image = _env('PWE_TEST_IMAGE');
    return $image if (length($image));
    return image_registry() . '/pwe-debugger:' . image_tag();
}

=head2 B<[Private] _env($nazev)>

    Vraci hodnotu promenne prostredi, nedefinovana = prazdny retezec.

=cut

sub _env {
    my ($name) = @_;
    return defined($ENV{$name}) ? $ENV{$name} : '';
}

=head2 B<[Private] _in_path($prikaz)>

    Vraci 1, pokud je v nekterem adresari z PATH spustitelny soubor $prikaz.

=cut

sub _in_path {
    my ($cmd) = @_;
    foreach my $p (split(/:/, _env('PATH'))) {
        return 1 if (length($p) and -x "$p/$cmd");
    }
    return 0;
}

=head2 B<[Public] has_docker()>

    Vraci 1, pokud je v PATH prikaz docker.

=cut

sub has_docker {
    return _in_path('docker');
}

=head2 B<[Public] ensure_modules(@moduly)>

    Overi, ze jdou nacist uvedene Perl moduly (napr. 'Template', 'Class::Inspector').
    Pokud nektery chybi a skript bezi mimo kontejner, spusti TENTYZ skript se stejnymi
    argumenty znovu v kontejneru docker_image() (koren repozitare namountovany do /PWE, pracovni
    adresar /PWE, moduly z /PWE/PWE/tools/lib) a skonci s jeho navratovym kodem. Cesty
    v argumentech (i cesta ke skriptu), ktere zacinaji korenem repozitare, se prepisou na /PWE/...,
    skript z <repo>/PWE/tools/ se tedy spusti jako /PWE/PWE/tools/<skript>. Do kontejneru se
    predaji PWE_IMAGE_REGISTRY, PWE_IMAGE_TAG a PWE_TEST_IMAGE, aby tam image_tag() a
    docker_image() vracely totez co na hostiteli (v kontejneru neni git). Neni-li image
    v lokalnim Dockeru, vypise se rada, jak ho ziskat (docker ho jinak zkusi stahnout z registru).
    Pokud docker neni k dispozici, skonci chybou.

=cut

sub ensure_modules {
    my (@mods) = @_;
    my @missing = grep { !eval "require $_; 1" } @mods;
    return 1 unless (@missing);

    my $repo = repo_root();
    if (in_container() or !has_docker()) {
        die "Chybi Perl moduly: @missing (spust v kontejneru " . docker_image() . ", nebo je nainstaluj)\n";
    }

    my $image  = docker_image();
    my $script = abs_path($0);
    my @args = map { my $a = $_; $a =~ s{^\Q$repo\E(/|$)}{/PWE$1}; $a } ($script, @ORIG_ARGV);
    my @cmd = ('docker', 'run', '--rm', '--entrypoint', 'perl', '-v', "$repo:/PWE", '-w', '/PWE', '-e', 'PWE_TOOLS_IN_DOCKER=1');
    push(@cmd, '-e', 'PWE_IMAGE_REGISTRY=' . image_registry(), '-e', 'PWE_IMAGE_TAG=' . image_tag());
    push(@cmd, '-e', "PWE_TEST_IMAGE=$image") if (length(_env('PWE_TEST_IMAGE')));
    push(@cmd, '--user', "$<:" . (split(/\s+/, $())[0]) if ($^O eq 'linux');
    push(@cmd, $image, '-I/PWE/PWE/tools/lib', @args);
    print STDERR "[tools] chybi moduly @missing -> spoustim v kontejneru $image\n";
    print STDERR _image_missing_note($image);
    exec(@cmd) or die "exec docker: $!\n";
}

=head2 B<[Private] _image_missing_note($image)>

    Vraci radu (tri radky zacinajici "[tools]"), kdyz image neni v lokalnim Dockeru (docker image
    inspect neuspeje), jinak prazdny retezec: docker ho zkusi stahnout z registru, sestavit ho
    jde pres make images, a ktere tagy tehoz repozitare v lokalnim Dockeru jsou (docker image ls).
    Image s tagem nove vetve v registru byt nemusi a chyba dockeru ("manifest unknown", u ghcr.io
    i "denied") sama nerekne, co s tim. Stejny text vypisuje shell funkce pwe_image_missing_hint
    (PWE/tools/lib/images.sh).

=cut

sub _image_missing_note {
    my ($image) = @_;
    my $q = shell_quote($image);
    system("docker image inspect $q >/dev/null 2>&1");
    return '' if ($? == 0);

    # repozitar = jmeno bez digestu a bez tagu (dvojtecka v registru s portem zustava)
    (my $repo = $image) =~ s/\@.*\z//s;
    $repo =~ s/:[^:\/]*\z//;
    my $qrepo = shell_quote($repo);
    my $list  = `docker image ls --format '{{.Tag}}' $qrepo 2>/dev/null`;
    my %seen;
    my @tags = sort grep { length($_) and $_ ne '<none>' and !$seen{$_}++ } split(/\n/, (defined($list) ? $list : ''));

    my $note = "[tools] image $image neni v lokalnim Dockeru, docker ho zkusi stahnout z registru.\n";
    $note .= "[tools]   sestaveni: make images (PWE/tools/build-images.sh)\n";
    if (@tags) {
        my $var = ($image eq _env('PWE_TEST_IMAGE')) ? "PWE_TEST_IMAGE=$repo:<tag>" : 'PWE_IMAGE_TAG=<tag>';
        $note .= "[tools]   mistne dostupne tagy $repo: @tags (pouziti: $var)\n";
    }
    else {
        $note .= "[tools]   v lokalnim Dockeru neni zadny image $repo\n";
    }
    return $note;
}

=head2 B<[Public] write_file($cesta,$obsah,%volby)>

    Zapise soubor (vytvori chybejici adresare). Volba exec => 1 nastavi prava 0755.
    Volba keep => 1 existujici soubor neprepise (vraci 0). Vraci 1 pri zapisu.

=cut

sub write_file {
    my ($path, $content, %o) = @_;
    return 0 if ($o{'keep'} and -e $path);
    make_path(dirname($path)) unless (-d dirname($path));
    open(my $fh, '>', $path) or die "Nelze zapsat $path: $!\n";
    binmode($fh);
    print $fh $content;
    close($fh);
    chmod(0755, $path) if ($o{'exec'});
    return 1;
}

=head2 B<[Public] symlink_rel($cil,$link)>

    Vytvori RELATIVNI symlink $link -> $cil (obe cesty absolutni). Existujici symlink nahradi.
    Vraci relativni cil. (Nove weby symlinky na engine nepotrebuji - engine si sve soubory
    nachazi pres pwe.core = koren enginu, adresar PWE/; funkce zustava pro conf/database.conf
    a specialni pripady.)

=cut

sub symlink_rel {
    my ($target, $link) = @_;
    $link =~ s{/+$}{};
    my $rel = File::Spec->abs2rel($target, dirname($link));
    make_path(dirname($link)) unless (-d dirname($link));
    if (-l $link) { unlink($link) or die "Nelze smazat symlink $link: $!\n"; }
    die "Cil $link existuje a neni symlink\n" if (-e $link);
    symlink($rel, $link) or die "symlink $link -> $rel: $!\n";
    return $rel;
}

=head2 B<[Public] read_conf($webapp)>

    Nacte conf/web.conf webu (Perl hash literal pres do()) bez enginu. Pri chybe die.

=cut

sub read_conf {
    my ($webapp) = @_;
    my $file = "$webapp/conf/web.conf";
    die "Chybi $file\n" unless (-f $file);
    my $conf = do($file);
    die "Chyba v $file: " . ($@ || $! || 'nevraci hash') . "\n" unless (ref($conf) eq 'HASH');
    return $conf;
}

=head2 B<[Public] conf_languages($conf)>

    Vraci seznam jazyku z http.languages (prvni je vychozi, pouziva rb.tmpl), nejmene ['CZE'].

=cut

sub conf_languages {
    my ($conf) = @_;
    my $l = $conf->{'http'}->{'languages'};
    return (ref($l) eq 'ARRAY' and @{$l}) ? @{$l} : ('CZE');
}

=head2 B<[Public] shell_quote($retezec)>

    Obali retezec jednoduchymi uvozovkami pro shell.

=cut

sub shell_quote {
    my ($s) = @_;
    $s = '' unless (defined($s));
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

=head2 B<[Public] run_cgi($webapp,%request)>

    Spusti engine (pwe.fcgi z korene enginu PWE/) nad webem $webapp jako jednorazove CGI (bez
    FastCGI socketu, bez databaze): PWE_CONF_pwe_home = web, PWE_CONF_pwe_core = core_root(),
    PERL5LIB = web:engine, ostatni prostredi se zahodi (env -i). Vrati vystup
    (HTTP hlavicky + telo). Ve skalarnim kontextu vraci STDOUT, v seznamovem (STDOUT, STDERR).
    Potrebuje Perl zavislosti enginu (volat v kontejneru nebo po ensure_modules). Volby:

      query   => 'page=default&func=default'   QUERY_STRING (vychozi default/default)
      script  => '/pwe.fcgi'                   SCRIPT_FILENAME; cesta /assets/... vrati staticky soubor
      post    => 'a=1&b=2'                     telo POST requestu (x-www-form-urlencoded); page/func patri do tela!
      cookie  => 'NAZEV=SID'                   HTTP_COOKIE (session)
      env     => { HTTPS => 'on', ... }        dalsi promenne prostredi
      loglevel => 1                            PWE_CONF_log_loglevel (log jde na STDERR)
      core    => '/jina/cesta/PWE'             jiny koren enginu nez core_root() (adresar s pwe.fcgi)
      entry   => 'debug.cgi'                   vstupni skript enginu misto pwe.fcgi (ladici vstup; k nemu script => '/debug.cgi')

=cut

sub run_cgi {
    my ($webapp, %r) = @_;
    $webapp =~ s{/+$}{};
    my $core = $r{'core'} || core_root();
    $core =~ s{/+$}{};
    die "Web $webapp nema conf/web.conf\n" unless (-f "$webapp/conf/web.conf");
    my $entry = $r{'entry'} || 'pwe.fcgi';
    die "Engine $core nema $entry\n"       unless (-f "$core/$entry");

    my %env = (
        'PATH'                  => ($ENV{'PATH'} || '/usr/bin:/bin'),
        'PERL5LIB'              => "$webapp:$core",
        'PWE_CONF_pwe_home'     => "$webapp/",
        'PWE_CONF_pwe_core'     => "$core/",
        'PWE_CONF_log_loglevel' => (defined($r{'loglevel'}) ? $r{'loglevel'} : 1),
        'PWE_CONF_log_logout'   => 'STDERR',
        'SCRIPT_FILENAME'       => ($r{'script'} || '/pwe.fcgi'),
        'REQUEST_METHOD'        => (defined($r{'post'}) ? 'POST' : 'GET'),
        'QUERY_STRING'          => (defined($r{'query'}) ? $r{'query'} : 'page=default&func=default'),
        'REMOTE_ADDR'           => '127.0.0.1',
        'HTTP_HOST'             => 'localhost',
        'SERVER_NAME'           => 'localhost',
        'HTTP_USER_AGENT'       => 'pwe-tools',
        %{$r{'env'} || {}},
    );
    $env{'HTTP_COOKIE'} = $r{'cookie'} if (defined($r{'cookie'}));
    if (defined($r{'post'})) {
        $env{'CONTENT_TYPE'}   = 'application/x-www-form-urlencoded';
        $env{'CONTENT_LENGTH'} = length($r{'post'});
    }

    my $tmp = "$webapp/ramdisk";
    make_path("$tmp/templates") unless (-d "$tmp/templates");
    my $err_file  = "$tmp/pwe-tools-cgi-$$.err";
    my $post_file = "$tmp/pwe-tools-cgi-$$.post";
    write_file($post_file, (defined($r{'post'}) ? $r{'post'} : ''));

    my $cmd = join(' ', 'cd', shell_quote($webapp), '&&', 'env', '-i', (map { shell_quote("$_=$env{$_}") } sort keys %env), shell_quote($^X), shell_quote("$core/$entry"), '<', shell_quote($post_file), '2>', shell_quote($err_file));
    my $out = `$cmd`;
    my $err = '';
    if (open(my $fh, '<', $err_file)) { local $/; $err = <$fh>; close($fh); }
    unlink($err_file, $post_file);
    return wantarray ? ($out, $err) : $out;
}

=head2 B<[Public] parse_response($vystup)>

    Rozlozi vystup run_cgi na { status => 200|404|..., headers => { 'content-type' => ..., ... },
    body => '...' }. Status se bere z hlavicky Status:, jinak 200.

=cut

sub parse_response {
    my ($out) = @_;
    $out = '' unless (defined($out));
    my ($head, $body) = split(/\r?\n\r?\n/, $out, 2);
    my %headers;
    foreach my $line (split(/\r?\n/, ($head || ''))) {
        next unless ($line =~ /^([A-Za-z][\w-]*):\s*(.*)$/);
        $headers{lc($1)} = $2;
    }
    my $status = 200;
    $status = $1 if (defined($headers{'status'}) and $headers{'status'} =~ /^(\d{3})/);
    return {status => $status, headers => \%headers, body => (defined($body) ? $body : '')};
}

1;
