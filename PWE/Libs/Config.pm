package Libs::Config;

=head1 NAME

Libs::Config - konfigurace enginu (conf/web.conf + conf/database.conf) s prepisem pres promenne prostredi

=head1 POPIS

    Konfigurace je perlovy hash sekci (pwe, http, web, css, tmpl, log, dbi, smtp_*). Pristup pres
    getValue($sekce,$klic,$default). Klic s hodnotou undef se povazuje za nenastaveny (vraci se default),
    hodnoty 0 a '' se vraceji tak, jak jsou. Prepis z ENV: PWE_CONF_<sekce>_<klic>, PWE_CONF_dbi_<dbid>_<klic>.

    Engine pracuje se dvema koreny:

      pwe.home  - adresar webu (conf/web.conf, vlastni Pages/Sites/Services/Entities, static/, ramdisk/...)
                  = PWE_CONF_pwe_home, jinak adresar skriptu pwe.fcgi
      pwe.core  - adresar enginu (Libs/, templates/, assets/, sdilene Pages/Sites/Services/Entities)
                  = PWE_CONF_pwe_core, jinak adresar skriptu pwe.fcgi

    Adresar enginu se v repozitari jmenuje PWE/ (v kontejnerech kukam/pwe-* /PWE/PWE). Slovo "core"
    v klicich pwe.core, pwe.core_*, pwe.require_core a v PWE_CONF_pwe_core znamena "koren enginu",
    ne nazev adresare.

    Pokud jsou oba stejne (puvodni rezim webu slozeneho symlinky uvnitr enginu), chova se engine
    jako drive. Pokud se lisi, hledaji se moduly, sablony, resource bundly i staticke soubory
    nejdrive ve webu a pak v enginu (web ma prednost); z enginu se nacitaji jen moduly uvedene
    v pwe.core_pages / core_sites / core_services / core_entities (viz getModuleRoots).

=cut

use strict;

# Vychozi moduly enginu, ktere web dostane, kdyz v conf nenastavi pwe.core_<typ>.
my %DEFAULT_CORE = (
    'pages'    => ['css', 'errorPage', 'systemPage', 'pweCreator'],
    'sites'    => ['Default'],
    'services' => [],
    'entities' => [],
);

=head2 B<[Public] new($dirname,$basename,$mainconfig,$databaseconfig)>

    Konstruktor konfigurace. $dirname je adresar skriptu pwe.fcgi. Koren webu (pwe.home) je
    PWE_CONF_pwe_home, jinak $dirname; koren enginu (pwe.core) je PWE_CONF_pwe_core, jinak $dirname.
    Oba se ukladaji vzdy s koncovym lomitkem. Nacte perlovy hash ze souboru pwe.home.$mainconfig
    (conf/web.conf) a doplni pwe.home, pwe.core a pwe.cgi_script_name = $basename. Pokud existuje
    pwe.home.$databaseconfig (conf/database.conf), nacte ho do sekce 'dbi'.

    Kazdy klic lze prepsat promennou prostredi PWE_CONF_<sekce>_<klic> (napr. PWE_CONF_log_loglevel=4)
    a pro databaze PWE_CONF_dbi_<dbid>_<klic> (napr. PWE_CONF_dbi_db1_password=...). Prepise se jen
    klic, ktery v konfiguraci uz existuje (ochrana proti preklepum). Nazev sekce i klice smi
    obsahovat podtrzitko (napr. PWE_CONF_smtp_primary_authpw = sekce smtp_primary, klic authpw):
    zkousi se kazde rozdeleni jmena na "sekce_klic" a pouzije se prvni, kde sekce i klic existuji.

    Pri chybejicim nebo neplatnem hlavnim konfiguraku metoda die (server nenastartuje).

=cut

sub new {
    my ($class, $dirname, $basename, $mainconfig, $databaseconfig) = @_;

    my $home = _dir((defined($ENV{'PWE_CONF_pwe_home'}) and length($ENV{'PWE_CONF_pwe_home'})) ? $ENV{'PWE_CONF_pwe_home'} : $dirname);
    my $core = _dir((defined($ENV{'PWE_CONF_pwe_core'}) and length($ENV{'PWE_CONF_pwe_core'})) ? $ENV{'PWE_CONF_pwe_core'} : $dirname);

    die "$mainconfig not exist!" unless (-f $home . $mainconfig);

    my $self = do($home . $mainconfig);
    die "$home$mainconfig: " . ($@ || $! || "soubor nevraci hash") . "\n" unless (ref($self) eq 'HASH');

    $self->{'pwe'}->{'home'}            = $home;
    $self->{'pwe'}->{'core'}            = $core;
    $self->{'pwe'}->{'cgi_script_name'} = $basename;
    $self->{'dbi'} = do($home . $databaseconfig) if (-f $home . $databaseconfig);
    bless $self, $class;

    # Moznost prepsat konfiguraci pomoci globalnich promenych (Environment variables)
    # EXAMPLE: PWE_CONF_dbi_dbX_keyname
    # EXAMPLE: PWE_CONF_keyname1_keyname1 (pwe, home)
    while (my ($key, $value) = each %ENV) {
        if ($key =~ /^PWE_CONF_dbi_(db\d+)_([a-zA-Z0-9_]+)$/) {
            if ($self->getValue('dbi', "$1", undef)) {
                $self->{'dbi'}->{$1}->{$2} = $value if (exists($self->{'dbi'}->{$1}->{$2}));
            }
        } elsif ($key =~ /^PWE_CONF_([a-zA-Z0-9_]+)$/) {
            # sekce i klic mohou obsahovat podtrzitko (smtp_primary.authpw): zkusi se kazde rozdeleni
            # "sekce_klic" zleva a pouzije se prvni, kde sekce i klic v konfiguraci existuji
            my @parts = split(/_/, $1);
            foreach my $i (1 .. $#parts) {
                my ($section, $subkey) = (join('_', @parts[0 .. $i - 1]), join('_', @parts[$i .. $#parts]));
                next unless ($self->isExistValue($section, $subkey));
                $self->{$section}->{$subkey} = $value;
                last;
            }
        }
    }

    # Rapair path
    foreach my $key (qw(home core)) {
        $self->{'pwe'}->{$key} = _dir($self->{'pwe'}->{$key});
    }

    return $self;
}

# Normalizace cesty adresare: koncove lomitko; relativni cesta bez ./ dostane ./ (kvuli do()).
sub _dir {
    my ($dir) = @_;
    $dir = "./" unless (defined($dir) and length($dir));
    $dir = "./$dir" unless ($dir =~ /^[\/\.]/);
    $dir .= "/" unless ($dir =~ /\/$/);
    return $dir;
}

=head2 B<[Public] getValue($key,$subkey,$def)>

    Metoda vraci hodnotu konfigurace ze sekce $key a klice $subkey, napr.
    getValue('http', 'languages', ['CZE']). Pokud sekce nebo klic neexistuje, nebo je
    hodnota klice undef, vraci $def (hodnoty 0 a '' se vraceji tak, jak jsou).
    Bez $subkey vraci celou sekci (typicky hashref), pripadne $def, pokud sekce
    neexistuje nebo je undef.

=cut

sub getValue {
    my ($self, $key, $subkey, $def) = @_;

    return $def unless (exists($self->{$key}));

    if ($subkey) {
        return $def if (ref($self->{$key}) ne "HASH");
        return $def unless (exists($self->{$key}->{$subkey}));
        return $def unless (defined($self->{$key}->{$subkey}));
        return $self->{$key}->{$subkey};
    } else {
        return $def unless (defined($self->{$key}));
        return $self->{$key};
    }
}

=head2 B<[Public] isExistValue($key,$subkey)>

    Metoda vraci 1, pokud v konfiguraci existuje klic $subkey v sekci $key (bez ohledu na
    hodnotu, i undef), jinak 0. Pouziva se pri prepisu konfigurace z promennych prostredi.

=cut

sub isExistValue {
    my ($self, $key, $subkey,) = @_;
    return 0 if (ref($self->{$key}) ne "HASH");
    return 0 unless (exists($self->{$key}->{$subkey}));
    return 1;
}

=head2 B<[Public] getHome()>

    Vraci adresar webu (pwe.home) s koncovym lomitkem.

=cut

sub getHome {
    my $self = shift;
    return $self->getValue('pwe', 'home', './');
}

=head2 B<[Public] getCore()>

    Vraci adresar enginu (pwe.core) s koncovym lomitkem.

=cut

sub getCore {
    my $self = shift;
    return $self->getValue('pwe', 'core', $self->getHome());
}

=head2 B<[Public] getRoots()>

    Vraci seznam korenu v poradi hledani: (pwe.home, pwe.core). Pokud jsou oba stejne
    (web uvnitr enginu), vraci jen jeden. Pouziva Template INCLUDE_PATH, @INC v pwe.fcgi
    a resolveFile/resolveDir.

=cut

sub getRoots {
    my $self = shift;
    my $home = $self->getHome();
    my $core = $self->getCore();
    return ($home) if ($core eq $home);
    return ($home, $core);
}

=head2 B<[Public] resolveFile($relative_path)>

    Pro cestu relativni ke koreni (napr. "/assets/javascript/pwe.js" nebo "Pages/x/rb.tmpl")
    vrati koren (s lomitkem), ve kterem soubor existuje - nejdrive web, pak engine. Pokud
    neexistuje nikde, vraci undef. Vysledna absolutni cesta je $koren . $relative_path.

=cut

sub resolveFile {
    my ($self, $rel) = @_;
    return undef unless (defined($rel));
    foreach my $root ($self->getRoots()) {
        return $root if (-f $root . $rel);
    }
    return undef;
}

=head2 B<[Public] resolveDir($relative_path)>

    Totez co resolveFile, ale pro adresar.

=cut

sub resolveDir {
    my ($self, $rel) = @_;
    return undef unless (defined($rel));
    foreach my $root ($self->getRoots()) {
        return $root if (-d $root . $rel);
    }
    return undef;
}

=head2 B<[Public] getModuleRoots($type)>

    Vraci seznam korenu, ve kterych loadery hledaji moduly typu $type (pages | sites | services |
    entities), v poradi priority. Kazdy prvek je { dir => "<koren>/<pwe.<type>_dir>", allowed => ... }:

      - adresar webu (pwe.home): allowed = undef (nacte se vse),
      - adresar enginu (pwe.core, jen pokud se lisi od webu): allowed = hash povolenych nazvu
        podle conf pwe.core_<type> (pole nazvu, nebo retezec "*" = vse -> undef).

    Vychozi hodnoty, kdyz conf klic chybi: core_pages = css, errorPage, systemPage, pweCreator;
    core_sites = Default; core_services = []; core_entities = []. Web tak v conf/web.conf explicitne
    rika, co si z enginu bere, napr. core_services => ['Session', 'DBTable', 'Email'].

=cut

sub getModuleRoots {
    my ($self, $type) = @_;
    my $sub   = $self->getValue('pwe', "${type}_dir", ucfirst($type) . "/");
    my @roots = ({'dir' => $self->getHome() . $sub, 'allowed' => undef});
    my $core  = $self->getCore();
    if ($core ne $self->getHome()) {
        my $list = $self->getValue('pwe', "core_$type", (exists($DEFAULT_CORE{$type}) ? $DEFAULT_CORE{$type} : []));
        my $allowed = undef;
        if (ref($list) eq 'ARRAY') {
            $allowed = {map { $_ => 1 } @{$list}};
        } elsif (defined($list) and $list ne '*') {
            $allowed = {map { $_ => 1 } grep { length } split(/\s*,\s*/, $list)};
        }
        push(@roots, {'dir' => $core . $sub, 'allowed' => $allowed});
    }
    return @roots;
}

=head2 B<[Public] coreVersion()>

    Vraci verzi enginu ze souboru pwe.core/VERSION (prvni radek bez bilych znaku), nebo undef,
    pokud soubor chybi.

=cut

sub coreVersion {
    my $self = shift;
    my $file = $self->getCore() . "VERSION";
    return undef unless (-f $file);
    open(my $fh, '<', $file) or return undef;
    my $line = <$fh>;
    close($fh);
    return undef unless (defined($line));
    $line =~ s/^\s+|\s+$//g;
    return (length($line) ? $line : undef);
}

=head2 B<[Public] checkCoreVersion()>

    Overi pozadavek webu na verzi enginu z conf pwe.require_core (napr. ">=1.2", ">=1.2.3",
    "=1.2" = rada 1.2.x, ">1.0"; bez operatoru plati >=) proti coreVersion(). Vraci undef,
    pokud pozadavek neni nastaven nebo je splnen, jinak chybovy text (pwe.fcgi s nim skonci).

=cut

sub checkCoreVersion {
    my $self = shift;
    my $req  = $self->getValue('pwe', 'require_core', undef);
    return undef unless (defined($req) and length($req));

    my $ver = $self->coreVersion();
    return "Engine PWE nema soubor VERSION (pwe.core = " . $self->getCore() . "), web vyzaduje pwe.require_core $req" unless (defined($ver));

    my ($op, $want) = ($req =~ /^\s*(>=|==|=|>)?\s*v?(\d+(?:\.\d+){0,2})\s*$/) ? (($1 || '>='), $2) : (undef, undef);
    return "Neplatny format pwe.require_core '$req' (ocekavano napr. >=1.2 nebo =1.2.3)" unless (defined($want));

    my $cmp = _cmpVersion($ver, $want);
    my $ok = ($op eq '>') ? ($cmp > 0) : (($op eq '=' or $op eq '==') ? ($cmp == 0) : ($cmp >= 0));
    return undef if ($ok);
    return "Web vyzaduje engine PWE $op$want, k dispozici je $ver (" . $self->getCore() . "VERSION)";
}

# Porovna verze po castech; porovnava se jen tolik casti, kolik ma pozadovana verze
# (1.2 vyhovuje 1.2.5). Vraci -1 / 0 / 1.
sub _cmpVersion {
    my ($have, $want) = @_;
    my @h = split(/\./, $have);
    my @w = split(/\./, $want);
    foreach my $i (0 .. $#w) {
        my $a = (defined($h[$i]) and $h[$i] =~ /^\d+$/) ? $h[$i] : 0;
        my $b = ($w[$i] =~ /^\d+$/) ? $w[$i] : 0;
        return ($a <=> $b) if ($a != $b);
    }
    return 0;
}

1;
