#!/usr/bin/env perl

=head1 NAME

PWE/tools/check-webapp.pl - kontrola webappu: struktura, konvence nazvu, rb soubory, perl -c a smoke request

=head1 POUZITI

    Spousti se z korene repozitare (PWE/ je adresar enginu):

    PWE/tools/check-webapp.pl <web> [--static] [--request 'page=X&func=Y'] [--verbose]     (make check WEB=...)

    PWE/tools/check-webapp.pl mujweb.web
    PWE/tools/check-webapp.pl mujweb.web --request 'page=kontakt&func=default'

    Kontroly (vypis radku OK / WARN / FAIL, navratovy kod 1 pri jakemkoli FAIL):

      struktura   conf/web.conf, adresare Pages/Sites/Services/Entities, platnost pripadnych symlinku
                  (web nema obsahovat kod enginu - ten se bere z adresare enginu PWE/ podle pwe.core_*)
      Dockerfile  jen varovani (WARN), ma-li web Dockerfile. Sablona generatoru (PWE/tools/new-webapp.pl):
                  jediny FROM = zavislostni image bez enginu (pwe-base pro web bez databaze, pwe-<profil>
                  pro web s databazi), engine se kopiruje z kontextu sestaveni (COPY PWE/...). Hlasi se
                  zbytky starsich sablon - engine z image pwe (dalsi FROM, ARG PWE_ENGINE_TAG, COPY
                  --from=engine), engine ocekavany v zakladnim image (chybi COPY polozek enginu, RUN test -f
                  /PWE/PWE/pwe.fcgi, mazani vzoroveho webu), zruseny zaklad pwe-static, vychozi
                  PWE_IMAGE_TAG jiny nez latest nebo verze X.Y.Z, vlastni ENTRYPOINT / entrypoint.sh - a radek
                  FROM vysledneho image jiny nez v sablone, Dockerfile pro web bez databaze (zaklad pwe-base)
                  u webu s konfiguraci databaze. Rada: vygenerovat web znovu do docasneho adresare a prevzit
                  z nej Dockerfile.
      konfigurace nacitatelny web.conf, http.languages, pwe.default_page existuje, save_opt_to=db
                  jen s databazi a sluzbou Session
      moduly      <Dir>/<X>/<X>.pm existuje, package = <Dir>::<X>::<X>, blok KOMODO, u stranek
                  registrace func, injektory Site_*/Service_* ukazuji na existujici moduly,
                  zadne "use Libs::..." ve vlastnich modulech
      rb soubory  rb.tmpl pro vychozi jazyk a rb_<LANG>.tmpl pro ostatni, konci prazdnym radkem
      perl -c     vsechny vlastni (ne symlinkovane) moduly  [vynecha --static]
      smoke       default stranka (200, HTML), neznama stranka (404), kazda vlastni stranka
                  s akci default nesmi vracet 500  [vynecha --static; u webu s databazi se
                  preskakuje - pouzijte PWE/tools/run-webapp.sh a curl]

    Dynamicke kontroly potrebuji Perl zavislosti enginu; mimo kontejner se skript sam spusti
    znovu v kontejneru s image nastroju (docker; vychozi ghcr.io/kukam/pwe-debugger:<verze enginu>,
    zmena pres PWE_IMAGE_TAG / PWE_IMAGE_REGISTRY / PWE_TEST_IMAGE, viz PWE::ToolEnv::docker_image()).
    --static funguje vsude.

=cut

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Getopt::Long qw(GetOptions);
use File::Basename qw(basename);
use PWE::ToolEnv qw(core_root resolve_webapp webapp_name ensure_modules read_conf conf_languages run_cgi parse_response dockerfile_base engine_image_entries engine_image_excludes);

my %opt;
GetOptions(\%opt, 'static', 'request=s', 'verbose|v', 'help|h') or usage(1);
usage(0) if ($opt{'help'});
my $arg = shift(@ARGV) or usage(1);

my $ROOT = core_root();    # koren enginu (adresar PWE/ v repozitari)
my $APP  = resolve_webapp($arg);
my $NAME = webapp_name($APP);

my ($fails, $warns) = (0, 0);
sub ok_   { print "OK   $_[0]\n" if ($opt{'verbose'} or $_[1]); }
sub warn_ { print "WARN $_[0]\n"; $warns++; }
sub fail_ { print "FAIL $_[0]\n"; $fails++; }
sub info_ { print "---- $_[0]\n"; }

die "Webapp $APP neexistuje\n" unless (-d $APP);
info_("Kontrola webappu $NAME ($APP)");

# ---------------------------------------------------------------------------------------------
# 1. STRUKTURA
# ---------------------------------------------------------------------------------------------
if (-f "$APP/conf/web.conf") { ok_("existuje conf/web.conf", 1); } else { fail_("chybi conf/web.conf"); }
foreach my $d (qw(Pages Sites Services Entities)) {
    if (-d "$APP/$d") { ok_("adresar $d"); } else { fail_("chybi adresar $d/"); }
}
foreach my $f (qw(Libs templates pwe.fcgi debug.cgi devel.cgi favicon.ico assets)) {
    next unless (-l "$APP/$f");
    if (-e "$APP/$f") { info_("$f je symlink na engine (puvodni rezim) - nove weby ho nepotrebuji, engine se bere z adresare PWE/ (pwe.core)"); }
    else { fail_("$f je symlink na neexistujici cil: " . readlink("$APP/$f") . " (engine je v adresari PWE/ v koreni repozitare - symlink smaz, nove weby ho nepotrebuji)"); }
}
ok_("engine: $ROOT (verze " . (core_version() || '?') . ")", 1);
foreach my $d (qw(ramdisk sessions uploadfile log)) {
    warn_("chybi docasny adresar $d/ (vytvori: mkdir -p $d)") unless (-d "$APP/$d");
}
check_dockerfile();

# ---------------------------------------------------------------------------------------------
# 2. KONFIGURACE
# ---------------------------------------------------------------------------------------------
my $conf = eval { read_conf($APP) };
if (!$conf) {
    fail_("conf/web.conf nejde nacist: $@");
    finish();
}
ok_("conf/web.conf nacten", 1);

my @langs = conf_languages($conf);
if (ref($conf->{'http'}->{'languages'}) eq 'ARRAY' and @{$conf->{'http'}->{'languages'}}) { ok_("http.languages = @langs", 1); }
else { warn_("http.languages neni nastaveno (pouzije se CZE)"); }

my %dir = map { $_ => dir_name($conf->{'pwe'}->{"${_}_dir"} || ucfirst($_) . "s/") } qw(pages sites services entities);
my $default_page = $conf->{'pwe'}->{'default_page'} || 'default';
if (-f "$APP/$dir{'pages'}/$default_page/$default_page.pm") { ok_("pwe.default_page '$default_page' existuje", 1); }
else { fail_("pwe.default_page '$default_page' nema modul $dir{'pages'}/$default_page/$default_page.pm"); }

if (my $req = $conf->{'pwe'}->{'require_core'}) {
    my $ver = core_version();
    if (!defined($ver)) { warn_("pwe.require_core = $req, ale engine nema soubor VERSION"); }
    elsif ($req =~ /^\s*(>=|>|==|=)?\s*v?(\d+(?:\.\d+){0,2})\s*$/) {
        my ($op, $want) = (($1 || '>='), $2);
        my $cmp = cmp_version($ver, $want);
        my $ok = ($op eq '>') ? ($cmp > 0) : (($op eq '=' or $op eq '==') ? ($cmp == 0) : ($cmp >= 0));
        if ($ok) { ok_("pwe.require_core $req splnen (engine $ver)", 1); } else { fail_("pwe.require_core $req nesplnen - engine ma verzi $ver"); }
    } else { fail_("pwe.require_core '$req' ma neplatny format (napr. >=1.0)"); }
} else {
    warn_("pwe.require_core neni nastaveno - web nerika, jakou verzi enginu potrebuje");
}
my %core_allowed;
foreach my $type (qw(pages sites services entities)) {
    my $list = $conf->{'pwe'}->{"core_$type"};
    my %def  = (pages => ['css', 'errorPage', 'systemPage', 'pweCreator'], sites => ['Default'], services => [], entities => []);
    $list = $def{$type} unless (defined($list));
    if (ref($list) eq 'ARRAY') { $core_allowed{$type} = {map { $_ => 1 } @{$list}}; }
    elsif ($list eq '*') { $core_allowed{$type} = undef; }
    else { $core_allowed{$type} = {map { $_ => 1 } grep { length } split(/\s*,\s*/, $list)}; }
}
my $has_db = (-e "$APP/conf/database.conf" or (ref($conf->{'dbi'}) eq 'HASH' and %{$conf->{'dbi'}})) ? 1 : 0;
my $save   = $conf->{'pwe'}->{'save_opt_to'} || 'file';
if ($save eq 'db') {
    fail_("pwe.save_opt_to = db, ale webapp nema conf/database.conf ani sekci dbi") unless ($has_db);
}
warn_("http.cookie_name neni nastaveno") unless ($conf->{'http'}->{'cookie_name'});
ok_("pwe.save_opt_to = $save" . ($has_db ? " (databaze)" : " (bez databaze)"), 1);

# ---------------------------------------------------------------------------------------------
# 3. MODULY
# ---------------------------------------------------------------------------------------------
my %real;    # realne (vlastni) moduly: "Pages/default" => cesta k .pm
my %all;     # vsechny dostupne moduly (web + povolene z enginu): typ => { nazev => 'web'|'core' }, 'core' = z enginu (PWE/)
foreach my $type (qw(pages sites services entities)) {
    my $cdir = "$ROOT/$dir{$type}";
    if (opendir(my $ch, $cdir)) {
        foreach my $x (readdir($ch)) {
            next if ($x =~ /^\./ or !-f "$cdir/$x/$x.pm");
            next if (defined($core_allowed{$type}) and !$core_allowed{$type}->{$x});
            $all{$type}->{$x} = 'core';
        }
        closedir($ch);
    }
    foreach my $x (grep { !-f "$cdir/$_/$_.pm" } keys %{$core_allowed{$type} || {}}) {
        fail_("pwe.core_$type uvadi '$x', ale engine takovy modul nema ($dir{$type}/$x/$x.pm)");
    }
}
foreach my $type (qw(pages sites services entities)) {
    my $d = "$APP/$dir{$type}";
    next unless (-d $d);
    my $Dir = $dir{$type};
    opendir(my $dh, $d) or next;
    foreach my $x (sort readdir($dh)) {
        next if ($x =~ /^\./);
        next if ($x eq 'Entity.pm' and $type eq 'entities');
        my $path = "$d/$x";
        if (-l $path and !-e $path) { fail_("$Dir/$x je symlink na neexistujici cil: " . readlink($path)); next; }
        unless (-d $path) { warn_("$Dir/$x neni adresar (loader ho ignoruje)"); next; }
        my $pm = "$path/$x.pm";
        unless (-f $pm) { fail_("$Dir/$x nema $x.pm (konvence <Dir>/<X>/<X>.pm, loader modul preskoci)"); next; }
        $all{$type}->{$x} = 'web';
        my $src = slurp($pm);
        my ($pkg) = $src =~ /^\s*package\s+([\w:]+)\s*;/m;
        my $expect = "${Dir}::${x}::${x}";
        if (!defined($pkg)) { fail_("$Dir/$x/$x.pm nema radek package"); }
        elsif ($pkg ne $expect) { fail_("$Dir/$x/$x.pm ma package $pkg, ocekavano $expect"); }
        else { ok_("$Dir/$x: package $pkg"); }
        next if (-l $path);    # sdilene moduly enginu dal nekontrolujeme
        $real{"$Dir/$x"} = $pm;
        warn_("$Dir/$x/$x.pm nema blok 'sub KOMODO' (pomucka pro IDE, konvence enginu)") unless ($src =~ /^\s*sub\s+KOMODO\b/m);
        if ($type eq 'pages' and $src !~ /\{\s*['"]?func['"]?\s*\}/) { warn_("$Dir/$x/$x.pm neregistruje zadnou akci (\$self->{'func'}->{...})"); }
        (my $code = $src) =~ s/^\s*sub\s+KOMODO\s*\{.*?\n\}//ms;    # blok KOMODO smi require Libs::* obsahovat
        foreach my $u ($code =~ /^\s*(?:use|require)\s+(Libs::[\w:]+)/mg) {
            next if ($type eq 'entities' and $u eq 'Libs::MyDBI::DAO');
            warn_("$Dir/$x/$x.pm pouziva '$u' primo - zavislosti enginu se predavaji konstruktorem a injektory (AGENTS.md, pravidlo 3)");
        }
        foreach my $s ($src =~ /^\s*sub\s+Service_(\w+)/mg) {
            next if (-f "$APP/$dir{'services'}/$s/$s.pm" or $all{'services'}->{$s});
            fail_("$Dir/$x injektuje Service_$s, ale sluzba neni ve webu ani v pwe.core_services - engine modul odregistruje");
        }
        foreach my $s ($src =~ /^\s*sub\s+Site_(\w+)/mg) {
            next if (-f "$APP/$dir{'sites'}/$s/$s.pm" or $all{'sites'}->{$s});
            fail_("$Dir/$x injektuje Site_$s, ale vzhled neni ve webu ani v pwe.core_sites - engine modul odregistruje");
        }

        # resource bundle
        foreach my $lang (@langs) {
            my $rb = ($lang eq $langs[0]) ? 'rb.tmpl' : "rb_$lang.tmpl";
            unless (-f "$path/$rb") { warn_("$Dir/$x nema $rb (texty pro jazyk $lang)"); next; }
            my $txt = slurp("$path/$rb");
            if ($txt !~ /\n\z/) { warn_("$Dir/$x/$rb nekonci novym radkem - musi koncit prazdnym radkem (bug parseru rb)"); }
            elsif ($txt !~ /\n\n\z/ and $txt !~ /\[%\s*#[^%]*%\]\s*\n\z/) { warn_("$Dir/$x/$rb nekonci prazdnym radkem (bug parseru rb)"); }
            else { ok_("$Dir/$x/$rb"); }
        }
    }
    closedir($dh);
}
my $ncore = grep { $_ eq 'core' } map { values %{$_} } values %all;
ok_(scalar(keys %real) . " vlastnich modulu, $ncore z enginu (pwe.core_*)", 1);
unless (-f "$APP/$dir{'sites'}/Default/Default.pm" or $all{'sites'}->{'Default'}) { warn_("web nema vlastni $dir{'sites'}/Default/Default.pm ani Default v pwe.core_sites (vzhled)"); }
if ($has_db and ($conf->{'pwe'}->{'save_opt_to'} || '') eq 'db' and !$all{'services'}->{'Session'}) { warn_("web s databazi nema sluzbu Session (pridej 'Session' do pwe.core_services a do pwe.core_entities)"); }

# ---------------------------------------------------------------------------------------------
# 4. perl -c + SMOKE (vyzaduje zavislosti enginu)
# ---------------------------------------------------------------------------------------------
if ($opt{'static'}) {
    info_("--static: perl -c a smoke requesty preskoceny");
    finish();
}

ensure_modules('Template', 'CGI::Fast', 'Class::Inspector', 'JSON');

foreach my $mod (sort keys %real) {
    my $out = `$^X -I'$APP' -I'$ROOT' -c '$real{$mod}' 2>&1`;
    if ($out =~ /syntax OK/) { ok_("perl -c $mod" . (($out =~ /\S.*\n.*syntax OK/s) ? " (s varovanim)" : "")); }
    else { fail_("perl -c $mod:\n" . indent($out)); }
}
ok_("perl -c: " . scalar(keys %real) . " modulu", 1);

if ($has_db) {
    info_("smoke requesty preskoceny: web pouziva databazi (spust PWE/tools/run-webapp.sh $NAME a otestuj curl http://127.0.0.1:7778/)");
} else {
    my ($out, $err) = run_cgi($APP, query => "page=$default_page&func=default");
    my $r = parse_response($out);
    if ($r->{'status'} == 200 and ($r->{'headers'}->{'content-type'} || '') =~ m{text/html} and $r->{'body'} =~ m{</html>}i) { ok_("smoke: ?page=$default_page&func=default -> 200 text/html", 1); }
    else { fail_("smoke: default stranka -> status $r->{'status'}, content-type " . ($r->{'headers'}->{'content-type'} || '?') . "\n" . indent(tail($err))); }
    my @elog = grep { /\[E\]|error/i } split(/\n/, $err);
    warn_("smoke: engine zalogoval chyby:\n" . indent(join("\n", @elog[0 .. ($#elog > 9 ? 9 : $#elog)]))) if (@elog);

    ($out, $err) = run_cgi($APP, query => 'page=neexistujici_stranka_x&func=default');
    $r = parse_response($out);
    if ($r->{'status'} == 404) { ok_("smoke: neznama stranka -> 404", 1); } else { fail_("smoke: neznama stranka -> $r->{'status'} (ocekavano 404)"); }

    ($out, $err) = run_cgi($APP, script => '/assets/javascript/pwe.js');
    $r = parse_response($out);
    if ($r->{'status'} == 200 and ($r->{'headers'}->{'content-type'} || '') =~ /javascript/) { ok_("smoke: /assets/javascript/pwe.js servirovan (z enginu)", 1); }
    else { warn_("smoke: /assets/javascript/pwe.js -> $r->{'status'} " . ($r->{'headers'}->{'content-type'} || '') . " (zkontroluj pwe.assets_dir)"); }

    foreach my $mod (sort grep { m{^\Q$dir{'pages'}\E/} } keys %real) {
        my $page = basename($mod);
        next if ($page eq $default_page);
        my $src = slurp($real{$mod});
        next unless ($src =~ /\{\s*['"]?func['"]?\s*\}\s*->\s*\{\s*['"]default['"]\s*\}/);
        ($out, $err) = run_cgi($APP, query => "page=$page&func=default");
        $r = parse_response($out);
        if ($r->{'status'} == 500) { fail_("smoke: ?page=$page&func=default -> 500 (pad metody)\n" . indent(tail($err))); }
        else { ok_("smoke: ?page=$page&func=default -> $r->{'status'}", 1); }
    }

    if ($opt{'request'}) {
        ($out, $err) = run_cgi($APP, query => $opt{'request'}, loglevel => 3);
        info_("request '$opt{'request'}':");
        my $show = $out;
        $show = substr($show, 0, 3000) . "\n... (zkraceno)" if (length($show) > 3000);
        print indent($show), "\n";
        print indent("STDERR:\n" . tail($err, 30)), "\n" if (length($err));
    }
}

finish();

# ---------------------------------------------------------------------------------------------
sub finish {
    info_(($fails ? "VYSLEDEK: $fails chyb" : "VYSLEDEK: bez chyb") . ", $warns varovani");
    exit($fails ? 1 : 0);
}

sub usage {
    my ($code) = @_;
    print STDERR "Pouziti: PWE/tools/check-webapp.pl <web> [--static] [--request 'page=X&func=Y'] [--verbose]\n";
    exit($code);
}

# Instrukce Dockerfile: bez komentaru a prazdnych radku, pokracovaci radky (\ na konci) spojene do jednoho -
# co radek, to jedna instrukce. Kontroly se tak tykaji toho, co build provede: zminka o stare sablone
# v komentari varovani nevyvola.
sub dockerfile_instructions {
    my ($text) = @_;
    $text =~ s/\r\n/\n/g;
    $text =~ s/^[ \t]*#.*\n?//mg;
    $text =~ s/^[ \t]*\n//mg;
    $text =~ s/[ \t]*\\\n[ \t]*/ /g;
    return $text;
}

# Image z instrukci FROM v poradi stage: bez voleb (--platform=...) a bez "AS <jmeno>", promenne ve tvaru
# $JMENO (sablona pise ${JMENO}; oba zapisy znamenaji totez). Vraci seznam [image, jmeno stage nebo '',
# image tak, jak je zapsany].
sub dockerfile_from {
    my ($ins) = @_;
    my @from;
    foreach my $f ($ins =~ /^FROM[ \t]+(\S[^\n]*?)[ \t]*$/mig) {
        $f =~ s/^(?:--\S+[ \t]+)+//;
        my ($image, $as) = $f =~ /^(\S+)(?:[ \t]+AS[ \t]+(\S+))?/i;
        next unless (defined($image));
        (my $norm = $image) =~ s/\$\{(\w+)\}/\$$1/g;
        push(@from, [$norm, (defined($as) ? $as : ''), $image]);
    }
    return @from;
}

# Radek FROM sablony Dockerfile webu pro dany profil, jak ji pise generator (PWE/tools/new-webapp.pl, funkce
# gen_dockerfile). Cte se primo ze sablony vedle tohoto skriptu - jediny zdroj pravdy je generator; zaklad
# ({{BASE}}: pwe-base pro web bez databaze, pwe-${PWE_PROFILE} pro web s databazi) doplni stejna funkce jako
# v generatoru (PWE::ToolEnv::dockerfile_base). Vraci polozku jako dockerfile_from(); undef, kdyz generator
# neni k dispozici, profil neni znamy nebo sablona nema prave jeden FROM.
sub template_from {
    my ($profile) = @_;
    my $base = eval { dockerfile_base($profile) };
    return undef unless (defined($base));
    my $src = slurp("$FindBin::Bin/new-webapp.pl");
    my ($tpl) = $src =~ /^sub gen_dockerfile\b.*?<<'DOCKER'[^\n]*\n(.*?)^DOCKER$/ms;
    return undef unless (defined($tpl));
    $tpl =~ s/\{\{BASE\}\}/$base/g;
    my @from = dockerfile_from(dockerfile_instructions($tpl));
    return (@from == 1) ? $from[0] : undef;
}

# Polozky korene enginu (PWE/<polozka>), ktere Dockerfile kopiruje z kontextu sestaveni: zdroje instrukci
# COPY bez --from (zdroj PWE/<polozka>; zastupne znaky * a ? v nazvu polozky; zdroj PWE nebo PWE/ = cely
# adresar enginu). Dostane instrukce (dockerfile_instructions) a seznam polozek enginu, vraci hash
# { polozka => 1 } tech, ktere Dockerfile kopiruje.
sub dockerfile_engine_copies {
    my ($ins, @entries) = @_;
    my %copied;
    foreach my $copy ($ins =~ /^COPY[ \t]+([^\n]+)$/mig) {
        my @words = split(' ', $copy);
        next if (grep { /^--from=/i } @words);
        @words = grep { !/^--/ } @words;
        pop(@words);    # posledni slovo je cil
        foreach my $source (@words) {
            $source =~ s{^\./}{};
            if ($source =~ m{^PWE/?\.?$}) { $copied{$_} = 1 foreach (@entries); next; }
            next unless ($source =~ m{^PWE/([^/]+)/?$});
            my $glob = join('', map { $_ eq '*' ? '.*' : $_ eq '?' ? '.' : quotemeta($_) } split(/([*?])/, $1));
            foreach my $entry (@entries) { $copied{$entry} = 1 if ($entry =~ /\A$glob\z/); }
        }
    }
    return \%copied;
}

# Dockerfile webu (jen varovani, web ho mit nemusi). Sablona generatoru: jediny FROM = zavislostni image
# BEZ enginu (pwe-base pro web bez databaze, pwe-<profil> pro web s databazi; tagy jen <verze> a latest),
# engine se kopiruje z kontextu sestaveni (COPY PWE/<polozka> pro kazdou polozku korene enginu krome t a
# docker), entrypoint se dedi ze zakladniho image. Varuje se na:
#   - zbytky prvniho usporadani image: image pwe (jen engine) jako dalsi FROM, ARG PWE_ENGINE_TAG,
#     COPY --from=engine,
#   - zbytky usporadani, kde engine obsahoval zakladni image pwe-<profil>: mazani vzoroveho webu (RUN rm -rf
#     /PWE/webapps/example...), kontrola enginu v zakladu (RUN test -f /PWE/PWE/pwe.fcgi - nad dnesnim
#     zakladem by sestaveni skoncilo chybou), zaklad pwe-static (image byl zrusen),
#   - polozku enginu, kterou Dockerfile nekopiruje (starsi sablona, nebo polozka pribyla s novou verzi
#     enginu) - image by ji neobsahoval,
#   - vychozi PWE_IMAGE_TAG jiny nez latest nebo verze X.Y.Z (tag podle vetve uz nikdo neaktualizuje),
#     vlastni ENTRYPOINT / entrypoint.sh (dedi se ze zakladniho image),
#   - radek FROM vysledneho image (posledni FROM), ktery se lisi od sablony generatoru,
#   - Dockerfile pro web bez databaze (PWE_PROFILE=static, zaklad pwe-base) u webu s konfiguraci databaze.
# Vlastni upravy Dockerfile (dalsi balicky, RUN, COPY) se nehlasi.
sub check_dockerfile {
    my $file = "$APP/Dockerfile";
    unless (-f $file) {
        ok_("web nema Dockerfile (image webu se nestavi)");
        return;
    }
    my $ins  = dockerfile_instructions(slurp($file));
    my @from = dockerfile_from($ins);

    # profil webu: z Dockerfile (vychozi hodnota ARG PWE_PROFILE), jinak ze symlinku conf/database.conf,
    # jinak podle konfiguraci databaze v conf/ (zadna = web bez databaze)
    my ($profile) = $ins =~ /^ARG[ \t]+PWE_PROFILE=["']?(\w+)/mi;
    if (!defined($profile) and -l "$APP/conf/database.conf") { ($profile) = (readlink("$APP/conf/database.conf") || '') =~ /^(\w+)\.conf$/; }
    my $guessed = 0;
    if (!defined($profile)) {
        my @db_confs = grep { -f "$APP/conf/$_.conf" } qw(mariadb mysql postgres);
        $profile = @db_confs ? $db_confs[0] : 'static';
        $guessed = scalar(@db_confs);
    }

    # jak web vygenerovat znovu
    my $db = '';
    if    ($guessed)                                   { $db = ' --db <mariadb|mysql|postgres>'; }
    elsif ($profile =~ /^(?:mariadb|mysql|postgres)$/) { $db = " --db $profile"; }
    my $regen = "PWE/tools/new-webapp.pl $NAME$db --dir <docasny adresar> a prevezmi z nej Dockerfile (vlastni upravy prenes rucne)";

    my @old;
    my $is_pwe = sub { return ($_[0] =~ m{(?:^|/)pwe(?:[:@]|$)}) ? 1 : 0; };
    my %engine_stage = map { $_->[1] => 1 } grep { length($_->[1]) and $is_pwe->($_->[0]) } @from;
    $engine_stage{'engine'} = 1 if (grep { lc($_->[1]) eq 'engine' } @from);
    if (grep { $is_pwe->($_->[0]) } @from) { push(@old, scalar(@from) . 'x FROM - image pwe jako zdroj enginu'); }
    push(@old, 'ARG PWE_ENGINE_TAG') if ($ins =~ /\bPWE_ENGINE_TAG\b/);
    if (grep { my $s = quotemeta($_); $ins =~ /^COPY[ \t]+(?:--\S+[ \t]+)*?--from=$s(?:[ \t]|$)/mi } keys %engine_stage) { push(@old, 'COPY --from=engine'); }
    elsif ($ins =~ m{^COPY[ \t]+(?:--\S+[ \t]+)*?--from=\S*/pwe[:@]}mi) { push(@old, 'COPY --from=<image pwe>'); }

    # zaklad vysledneho image s dosazenym vychozim profilem (FROM .../pwe-${PWE_PROFILE}:... s profilem static)
    my $removed_base = 0;
    if (@from) {
        (my $resolved = $from[-1]->[0]) =~ s/\$PWE_PROFILE\b/$profile/g;
        $removed_base = 1 if ($resolved =~ m{(?:^|/)pwe-static(?:[:@]|$)});    # zruseny image profilu static
    }
    push(@old, 'zaklad pwe-static - image byl zrusen') if ($removed_base);
    push(@old, 'RUN test -f /PWE/PWE/pwe.fcgi - kontrola enginu v zakladnim image') if ($ins =~ m{^RUN[ \t]+test[ \t]+-f[ \t]+/PWE/PWE/pwe\.fcgi\b}mi);
    push(@old, 'RUN rm vzoroveho webu ze zakladniho image') if ($ins =~ m{^RUN[ \t][^\n]*\brm[ \t][^\n]*/PWE/webapps/example(?:-db)?\.web\b}mi);

    # engine z kontextu sestaveni: kazda polozka korene enginu (krome t, docker a tools) musi mit svuj COPY
    my @entries = eval { engine_image_entries($ROOT) };
    my $copied  = dockerfile_engine_copies($ins, @entries);
    my @missing = grep { !$copied->{$_} } @entries;
    if (@entries and @missing == @entries) { push(@old, 'engine se nekopiruje z kontextu sestaveni (zadne COPY PWE/...)'); }
    elsif (@missing)                       { push(@old, 'chybi COPY polozek enginu: ' . join(', ', map { "PWE/$_" } @missing)); }

    # polozky enginu, ktere do image webu nepatri (t, docker, tools) - sablona z prvniho vydani 2.2.1 kopirovala PWE/tools
    my %not_in_image = map { $_ => 1 } engine_image_excludes();
    my %extra;
    foreach my $copy ($ins =~ /^COPY[ \t]+([^\n]+)$/mig) {
        my @words = split(' ', $copy);
        next if (grep { /^--from=/i } @words);
        @words = grep { !/^--/ } @words;
        pop(@words);
        foreach my $source (@words) { $source =~ s{^\./}{}; $extra{"PWE/$1"} = 1 if ($source =~ m{^PWE/([^/]+)(?:/|$)} and $not_in_image{$1}); }
    }
    push(@old, 'COPY polozek enginu, ktere do image webu nepatri: ' . join(', ', sort keys %extra)) if (%extra);

    my ($default_tag) = $ins =~ /^ARG[ \t]+PWE_IMAGE_TAG=["']?([^"'\s]+)/mi;
    if (defined($default_tag) and $default_tag !~ /^(?:latest|\d+\.\d+\.\d+)$/) { push(@old, "vychozi PWE_IMAGE_TAG=$default_tag"); }
    if ($ins =~ /^ENTRYPOINT\b/mi or $ins =~ /entrypoint\.sh/ or -e "$APP/entrypoint.sh") { push(@old, 'vlastni ENTRYPOINT / entrypoint.sh'); }
    if (@old) {
        warn_("Dockerfile je ze stare sablony (" . join('; ', @old) . "): image webu se stavi nad zavislostnim image BEZ enginu "
            . "(pwe-base pro web bez databaze, pwe-<profil> pro web s databazi; tagy jen <verze> a latest), engine kopiruje z kontextu sestaveni "
            . "(adresar PWE/ repozitare) a entrypoint dedi ze zakladniho image. Image tohoto Dockerfile by se nesestavil nebo by neobsahoval "
            . "aktualni engine. Vygeneruj novy: $regen");
    }

    # Dockerfile pro web bez databaze u webu, ktery konfiguraci databaze ma: zaklad pwe-base nema ovladace a
    # profil static databazi nezapina - image webu by bezel bez databaze (web s databazi ma jinou sablonu)
    my @db_confs = grep { -f "$APP/conf/$_.conf" } qw(mariadb mysql postgres);
    if ($profile eq 'static' and @db_confs) {
        warn_("Dockerfile je pro web bez databaze (PWE_PROFILE=static, zaklad pwe-base nema ovladace databaze), ale web ma " . join(', ', map { "conf/$_.conf" } @db_confs)
            . " - image webu pobezi bez databaze. Web s databazi: PWE/tools/new-webapp.pl $NAME --db <mariadb|mysql|postgres> --dir <docasny adresar> a prevezmi z nej Dockerfile (vlastni upravy prenes rucne)");
    }

    my $want = template_from($profile);
    if (!@from) {
        warn_("Dockerfile nema instrukci FROM - image webu ma vychazet ze zavislostniho image (pwe-base pro web bez databaze, pwe-<profil> pro web s databazi). Sablona: $regen");
    }
    elsif ($removed_base) {
        # zruseny zaklad pwe-static uz hlasi varovani o stare sablone
    }
    elsif (defined($want) and $from[-1]->[0] ne $want->[0]) {
        warn_("Dockerfile: radek FROM vysledneho image (FROM $from[-1]->[2]) se lisi od sablony generatoru (FROM $want->[2]) - "
            . "image webu ma vychazet ze zavislostniho image: pwe-base pro web bez databaze, pwe-<profil> pro web s databazi. Sablona: $regen");
    }
    elsif (!@old) {
        ok_("Dockerfile: FROM a kopie enginu podle sablony generatoru" . (defined($want) ? '' : ' (sablona neni k dispozici, radek FROM se nesrovnava)'), 1);
    }
    return;
}

sub dir_name { my ($d) = @_; $d =~ s{/+$}{}; $d =~ s{^/+}{}; return $d; }
sub core_version { open(my $fh, '<', "$ROOT/VERSION") or return undef; my $l = <$fh>; close($fh); return undef unless (defined($l)); $l =~ s/^\s+|\s+$//g; return (length($l) ? $l : undef); }
sub cmp_version { my ($have, $want) = @_; my @h = split(/\./, $have); my @w = split(/\./, $want); foreach my $i (0 .. $#w) { my $a = ($h[$i] || 0); my $b = ($w[$i] || 0); return ($a <=> $b) if ($a != $b); } return 0; }
sub slurp { my ($f) = @_; open(my $fh, '<', $f) or return ''; local $/; my $s = <$fh>; close($fh); return (defined($s) ? $s : ''); }
sub indent { my ($s) = @_; $s =~ s/^/      /mg; return $s; }
sub tail { my ($s, $n) = @_; $n ||= 15; my @l = split(/\n/, ($s || '')); @l = @l[-$n .. -1] if (@l > $n); return join("\n", @l); }
