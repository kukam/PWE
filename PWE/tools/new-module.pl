#!/usr/bin/env perl

=head1 NAME

PWE/tools/new-module.pl - vytvori kostru stranky / sluzby / vzhledu / entity ve webappu (CLI obdoba stranky pweCreator)

=head1 POUZITI

    Spousti se z korene repozitare (PWE/ je adresar enginu), nebo pres make module TYPE=... WEB=... NAME=... ARGS='...':

    PWE/tools/new-module.pl page    <webapp> <Nazev> [--site Default] [--services UserAccount,DBTable]
    PWE/tools/new-module.pl service <webapp> <Nazev> [--services Session]
    PWE/tools/new-module.pl site    <webapp> <Nazev> [--parent Default] [--services Session]
    PWE/tools/new-module.pl entity  <webapp> <Nazev> --table <db_tabulka>

    PWE/tools/new-module.pl page mujweb.web kontakt --site Default --services UserAccount
    PWE/tools/new-module.pl entity eshop.web Product --table products

    <webapp> je nazev adresare ve webapps/ (nebo cesta s lomitkem). Vygenerovane soubory:

      page    Pages/<Nazev>/<Nazev>.pm + main.html + msg.html + rb.tmpl, rb_<LANG>.tmpl
      service Services/<Nazev>/<Nazev>.pm + rb*.tmpl
      site    Sites/<Nazev>/<Nazev>.pm + rb*.tmpl (proxy metody podle rodicovskeho vzhledu / Libs::Web)
      entity  Entities/<Nazev>/<Nazev>.pm + rb*.tmpl (nad tabulkou --table, dbid db1)

    Kostry .pm vznikaji ze stejnych sablon jako ve strance pweCreator (PWE/Pages/pweCreator/*.tmpl),
    takze maji spravne injektory Site_*/Service_*, promenne i blok KOMODO. Jazyky pro rb soubory
    se berou z conf/web.conf webappu (http.languages). Volba --force prepise existujici soubory.

    Skript potrebuje Template Toolkit a Class::Inspector; pokud na hostiteli chybi, spusti se sam
    znovu v kontejneru s image nastroju (docker; vychozi ghcr.io/kukam/pwe-debugger:<verze enginu>,
    zmena pres PWE_IMAGE_TAG / PWE_IMAGE_REGISTRY / PWE_TEST_IMAGE, viz PWE::ToolEnv::docker_image()).
    Po vytvoreni modulu je nutne restartovat bezici FastCGI proces (engine nacita moduly pri startu).

=cut

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Getopt::Long qw(GetOptions);
use File::Path qw(make_path);
use PWE::ToolEnv qw(engine_root resolve_webapp webapp_name ensure_modules write_file read_conf conf_languages);

my %opt;
GetOptions(\%opt, 'site=s', 'services=s', 'parent=s', 'table=s', 'dbid=s', 'force', 'help|h') or usage(1);
usage(0) if ($opt{'help'});

my ($type, $webapp_arg, $name) = @ARGV;
usage(1) unless (defined($type) and defined($webapp_arg) and defined($name));
die "Neznamy typ '$type' (page|service|site|entity)\n" unless ($type =~ /^(page|service|site|entity)$/);
die "Nazev modulu smi obsahovat jen pismena, cislice a podtrzitko a musi zacinat pismenem: '$name'\n" unless ($name =~ /^[A-Za-z][A-Za-z0-9_]*$/);
die "Entita potrebuje --table <nazev_tabulky>\n" if ($type eq 'entity' and !defined($opt{'table'}));

ensure_modules('Template', 'Class::Inspector');
require Template;
require Class::Inspector;

my $ROOT   = engine_root();    # koren enginu (adresar PWE/ v repozitari)
my $APP    = resolve_webapp($webapp_arg);
die "Webapp $APP neexistuje nebo nema conf/web.conf (vytvor ho: PWE/tools/new-webapp.pl)\n" unless (-f "$APP/conf/web.conf");

my $conf  = read_conf($APP);
my @langs = conf_languages($conf);

# adresare podle conf (bez lomitka), stejne jako pweCreator
my %dir = map { $_ => dir_name($conf->{'pwe'}->{"${_}_dir"} || ucfirst($_) . "s/") } qw(pages sites services entities);

my %target = ('page' => $dir{'pages'}, 'service' => $dir{'services'}, 'site' => $dir{'sites'}, 'entity' => $dir{'entities'});
my $moddir = "$APP/$target{$type}/$name";
if (-e "$moddir/$name.pm" and !$opt{'force'}) {
    die "Modul $target{$type}/$name/$name.pm uz existuje (pouzij --force pro prepsani).\n";
}

# sluzby a vzhled
my @services = grep { length } split(/\s*,\s*/, ($opt{'services'} || ''));
my $site     = ($type eq 'page') ? (defined($opt{'site'}) ? $opt{'site'} : 'Default') : undef;
my $parent   = ($type eq 'site') ? $opt{'parent'} : undef;

# modul je k dispozici, kdyz ho ma web, nebo ho ma engine a web ho povoluje v pwe.core_<typ>
# (stejne pravidlo jako loadery enginu - viz docs/03-struktura-webu.md)
sub has_module {
    my ($kind, $mod) = @_;
    return 1 if (-f "$APP/$dir{$kind}/$mod/$mod.pm");
    my $allowed = $conf->{'pwe'}->{"core_$kind"};
    $allowed = [] unless (ref($allowed) eq 'ARRAY');
    return 1 if (-f "$ROOT/$dir{$kind}/$mod/$mod.pm" and grep { $_ eq $mod } @{$allowed});
    return 0;
}

foreach my $s (@services) {
    warn "VAROVANI: sluzba $s ve webappu neexistuje ($target{'service'}/$s/$s.pm) ani neni povolena v pwe.core_services - engine stranku bez ni nenacte.\n" unless (has_module('services', $s));
}
warn "VAROVANI: vzhled $site ve webappu neexistuje ($dir{'sites'}/$site/$site.pm) ani neni povolen v pwe.core_sites.\n" if (defined($site) and length($site) and !has_module('sites', $site));
warn "VAROVANI: rodicovsky vzhled $parent ve webappu neexistuje ani neni povolen v pwe.core_sites.\n" if (defined($parent) and !has_module('sites', $parent));

# promenne modulu (stejna logika jako pweCreator::get_service_map)
my @def_vars = ('$CONF', '$LOG', '$VALIDATE', '$DBI', '$ENTITIES', '$USER', '$WEB');
my %servicemap;
foreach my $s (@services) {
    my $var = '$' . uc($s);
    $var = '$' . uc("C$s") if (grep { $_ eq $var } @def_vars);
    $servicemap{$s} = $var;
}
my $variables = join(",", @def_vars, map { $servicemap{$_} } @services);

# Template Toolkit nad sablonami pweCreator (pres webapp, nebo primo z enginu)
my $tt = Template->new({INCLUDE_PATH => [$APP, $ROOT], ABSOLUTE => 1, RELATIVE => 1}) or die Template->error();

my %vars = (
    'servicemap'   => \%servicemap,
    'services'     => \@services,
    'variables'    => $variables,
    'pages_dir'    => $dir{'pages'},
    'sites_dir'    => $dir{'sites'},
    'services_dir' => $dir{'services'},
    'entities_dir' => $dir{'entities'},
);

my ($tmpl, @extra);
if ($type eq 'page') {
    $tmpl = 'Pages/pweCreator/page.tmpl';
    @vars{qw(pagename defsitename)} = ($name, $site);
} elsif ($type eq 'service') {
    $tmpl = 'Pages/pweCreator/service.tmpl';
    $vars{'servicename'} = $name;
} elsif ($type eq 'site') {
    $tmpl = 'Pages/pweCreator/site.tmpl';
    @vars{qw(sitename defsitename)} = ($name, $parent);
    $vars{'methods'} = site_methods($parent);
} else {
    $tmpl = 'Pages/pweCreator/entity.tmpl';
    @vars{qw(entityname dbtable)} = ($name, $opt{'table'});
}

my $code = '';
$tt->process($tmpl, \%vars, \$code) or die "Sablona $tmpl: " . $tt->error() . "\n";
$code =~ s/"db1"/"$opt{'dbid'}"/ if ($type eq 'entity' and defined($opt{'dbid'}));

make_path($moddir) unless (-d $moddir);
my @created;
put("$name.pm", $code);

if ($type eq 'page') {
    put('main.html', "[% PROCESS templates/resource_bundle.tmpl %]\n<h1>[% rb.${name}_title %]</h1>\n");
    put('msg.html',  "[% PROCESS templates/resource_bundle.tmpl %]\n\n[% INCLUDE templates/messenger.html %]\n");
}

foreach my $lang (@langs) {
    my $file = ($lang eq $langs[0]) ? 'rb.tmpl' : "rb_$lang.tmpl";
    my $body = "[% # RESOURCE BUNDLE ($lang) %]\n\n";
    $body .= "[% SET rb.${name}_title = \"$name\" %]\n\n" if ($type eq 'page');
    $body .= "[% # POZOR: soubor rb*.tmpl musi koncit prazdnym radkem (bug parseru) %]\n\n";
    put($file, $body);
}

(my $rel = $moddir) =~ s{^\Q$ROOT\E/}{};
print "Vytvoren $type $name v $rel/\n";
print "  $_\n" foreach (@created);
print "\nDalsi kroky:\n";
if ($type eq 'page') {
    print "  - akce registruj v new(): \$self->{'func'}->{'nazev'} = [];  (prava: ['admin'])\n";
    print "  - validaci vstupu pis deklarativne (defined/rules/error), viz docs/05-validace.md\n";
    print "  - URL: ?page=$name&func=default ; texty do rb*.tmpl, HTML do main.html\n";
} elsif ($type eq 'service') {
    print "  - do stranky ji injektuj metodou Service_$name (PWE/tools/new-module.pl page ... --services $name)\n";
} elsif ($type eq 'site') {
    print "  - stranka ho dostane metodou Site_$name; layouty dej do $target{$type}/$name/layout_*.html\n";
} else {
    print "  - tabulka $opt{'table'} musi existovat v DB (conf/<driver>.dbversion), jinak se entita nenacte\n";
    print "  - pouziti: \$ENTITIES->createEntityObject('$name', \$id)\n";
}
print "  - restartuj FastCGI proces (engine nacita moduly pri startu) a over: PWE/tools/check-webapp.pl $webapp_arg\n";
exit 0;

# ---------------------------------------------------------------------------------------------

sub usage {
    my ($code) = @_;
    print STDERR <<"USAGE";
Pouziti: PWE/tools/new-module.pl page|service|site|entity <webapp> <Nazev> [volby]
  page    --site <Vzhled>      (vychozi Default)   --services A,B
  service --services A,B
  site    --parent <Vzhled>    (jinak proxy na Libs::Web)   --services A,B
  entity  --table <tabulka>    [--dbid db1]
  --force prepise existujici soubory. Detaily: perldoc PWE/tools/new-module.pl
USAGE
    exit($code);
}

sub dir_name {
    my ($d) = @_;
    $d =~ s{/+$}{};
    $d =~ s{^/+}{};
    return $d;
}

sub put {
    my ($file, $content) = @_;
    write_file("$moddir/$file", $content);
    push(@created, "$target{$type}/$name/$file");
}

# Seznam verejnych metod rodicovskeho vzhledu (nebo Libs::Web), pro ktere site.tmpl vygeneruje
# proxy metody - stejny filtr jako pweCreator::get_list_methods_for_class.
sub site_methods {
    my ($parent_site) = @_;
    my $class = (defined($parent_site) and length($parent_site)) ? "$dir{'sites'}::${parent_site}::${parent_site}" : 'Libs::Web';
    unshift(@INC, $APP, $ROOT);
    eval "require $class; 1" or die "Nelze nacist $class: $@\n";
    require B;
    my @methods;
    foreach my $m (@{Class::Inspector->methods($class, 'public') || []}) {
        next if ($m =~ /^(new|flush|KOMODO|AUTOLOAD|DESTROY|import|can|isa)$/);
        next if ($m =~ /^(Site|Service)_/);
        no strict 'refs';
        my $cv = *{"${class}::$m"}{CODE} or next;
        next unless (B::svref_2object($cv)->GV->STASH->NAME eq $class);    # jen vlastni, ne importovane funkce
        push(@methods, $m);
    }
    return [sort @methods];
}
