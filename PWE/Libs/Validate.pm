package Libs::Validate;

=head1 NAME

Libs::Validate - validatory vstupu a SQL hodnot; vola se z 'rules' stranek a z DAO

=head1 POPIS

    Vlastni metody (is_email, is_regx, escape_jsinjection, is_sql_*, ...) plus funkce importovane
    z Libs::Validate::Data, Libs::Validate::MySQL a Libs::Validate::Postgres. Konvence: definovana
    hodnota = OK, undef = chyba. Neznama metoda -> die (AUTOLOAD).

=cut

use strict;
use warnings;
use vars qw(@ISA);
use Libs::Validate::MySQL;
use Libs::Validate::Postgres;
use Libs::Validate::Data;
use Mail::RFC822::Address qw(valid);

our $AUTOLOAD;    # it's a package global

my ($CONF, $LOG);

=head2 B<[Public] new($conf,$log)>

    Konstruktor validatoru. Krome zde definovanych metod jsou jako metody dostupne i vsechny
    funkce exportovane z Libs::Validate::Data (is_integer, is_numeric, is_between, is_equal_to,
    length_is_between, ...), Libs::Validate::MySQL (is_int, is_varchar, is_enum, is_date,
    is_datetime, ...) a Libs::Validate::Postgres (is_psql_boolean). Konvence: validator vraci
    definovanou hodnotu pri uspechu a undef pri chybe.

=cut

sub new {
    my ($class, $conf, $log) = @_;

    $LOG  = $log;
    $CONF = $conf;

    my $self = {};

    bless $self, $class;
    return $self;
}

=head2 B<[Public] validate([ $method, $error_key, @args ])>

    Metoda spusti validator podle pravidla [ $method, $error_key, @args ]: zavola
    $self->$method(@args) a pokud validator vrati undef (chyba), vraci $error_key;
    pri uspechu vraci undef. Pouziva ji Libs::Pages pro atribut 'rules' stranek.

    my $err = $VALIDATE->validate(["is_enum", "error_enum", $value, 'a', 'b', 'c']);
    my $err = $VALIDATE->validate(["is_numeric", "error_cislo", 'a123']);    # vraci "error_cislo"

    Pokud validator neexistuje nebo spadne (die), chyba se zaloguje, odesle se e-mail report
    (sendErrorReport) a metoda die.

=cut

sub validate {
    my $self = shift;
    my @args = (@{$_[0]});

    my $method = $args[0];
    my $error  = $args[1];
    my $result = undef;

    splice(@args, 0, 2);

    eval { local $SIG{__DIE__} = 'DEFAULT'; $result = $self->$method(@args); };

    if ($@) {
        chomp($@);
        my $error = $@;
        $LOG->error($error);
        $LOG->error("VALIDATE : $method [ CRASHED ]");
        $LOG->sendErrorReport("VALIDATE", undef, $method, $error);
        die "Internal error, unknown method at validate method:$method";
        exit;
    }

    #no strict 'refs';
    #my $result = $self->$method(@args);
    #use strict 'refs';

    return $error unless (defined($result));
    return undef;
}

=head2 B<[Public] validate_decimal_vat($vat)>

    Metoda overi, ze $vat je povolena sazba DPH zapsana jako desetinny koeficient,
    napr. 1.21 pro 21 %. Povolene sazby v procentech (napr. [21, 10]) se ctou z conf
    web.access_vat. Vraci 1 pri shode, jinak undef. Porovnava se retezcove s hodnotou
    (sazba / 100) + 1, proto musi mit $vat presne tvar, v jakem cislo vypise Perl
    (1.1, nikoliv 1.10).

=cut

sub validate_decimal_vat {
    my ($self, $validate_vat) = @_;
    my $vats = $CONF->getValue("web", "access_vat", []);
    foreach my $v (@{$vats}) { return 1 if ((($v / 100) + 1) eq $validate_vat); }
    return undef;
}

=head2 B<[Public] is_md5hex($value)>

    Vraci 1 pokud je $value neprazdny hexadecimalni retezec (delka se nekontroluje), jinak undef.
    Session cookie uz touto metodou neprochazi (Libs::User::newRequest ma vlastni prisny tvar
    C0/C1 + 32 hex), metoda zustava jako obecny validator.

=cut

sub is_md5hex {
    my ($self, $value) = @_;
    return undef unless (defined($value));
    return (($value =~ /^[a-fA-F0-9]+$/) ? 1 : undef);
}

=head2 B<[Public] is_percent($value)>

    Vraci $value pokud je to cislo, volitelne s koncovym znakem % (napr. "15%" nebo "1.21"), jinak undef.

=cut

sub is_percent {
    my ($self, $value) = @_;
    my $value1 = $value;
    $value1 =~ s/\%$//;
    return ($self->is_numeric($value1) ? $value : undef);
}

=head2 B<[Public] is_regx($value,$regex)>

    Vraci $value pokud odpovida regularnimu vyrazu $regex (qr// nebo retezec), jinak undef.
    V rules: ['is_regx', 'error_x', 'parameter', qr/^\d+$/].

=cut

sub is_regx {
    my ($self, $value, $args) = @_;
    return (($value =~ /$args/) ? $value : undef);
}

=head2 B<[Public] isnot_regx($value,$regex)>

    Vraci $value pokud NEodpovida regularnimu vyrazu, jinak undef.

=cut

sub isnot_regx {
    my ($self, $value, $args) = @_;
    return (($value !~ $args) ? $value : undef);
}

=head2 B<[Public] is_email($value)>

    Vraci $value pokud je to platna e-mailova adresa (Mail::RFC822::Address + vlastni regex:
    jen bezne znaky v lokalni casti, TLD alespon 2 pismena), jinak undef.

=cut

sub is_email {
    my ($self, $value) = @_;
    return undef if (!Mail::RFC822::Address::valid($value));
    return undef if ($value !~ /^[_a-zA-Z0-9\.\-\+]+@[a-zA-Z0-9\.\-]+\.[a-zA-Z]{2,}$/);
    return $value;
}

=head2 B<[Public] is_language($value)>

    Vraci $value pokud je to jazyk uvedeny v conf http.languages, jinak undef.

=cut

sub is_language {
    my ($self, $value) = @_;
    foreach (@{$CONF->getValue("http", "languages", [])}) {
        return $value if ($value eq $_);
    }
    return undef;
}

=head2 B<[Public] is_zipcode($null,$value)>

    POZOR na poradi argumentu: prvni je priznak, zda je povolena prazdna hodnota (NULL sloupec),
    druhy je PSC. Vraci 1 pro 5 cislic (nebo prazdnou hodnotu pri $null), jinak undef.
    Kvuli poradi argumentu neni primo pouzitelna v 'rules' - pouzivaji ji entity.

=cut

sub is_zipcode {
    my ($self, $null, $value) = @_;
    return 1 if ($null and !$value);
    return undef if ($value !~ /^\d+$/);
    return undef if (length($value) != 5);
    return 1;
}

=head2 B<[Public] escape_jsinjection($value)>

    Vraci $value s nahrazenymi znaky & < > za HTML entity (zakladni ochrana proti XSS).
    Typicke pouziti v atributu 'replace' stranky: {'*ALL*' => ['escape_jsinjection']}.

=cut

sub escape_jsinjection {
    my ($self, $value) = @_;
    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    return $value;
}

=head2 B<[Public] is_sql_int($dbdriver,$value,$unsigned)>

    Vraci 1 pokud $value odpovida typu INT daneho driveru (mysql/mariadb/postgres), jinak undef.
    Neznamy driver -> undef.

=cut

sub is_sql_int {
    my ($self, $dbdriver, $value, $unsig) = @_;
    if (($dbdriver eq "mysql") or ($dbdriver eq "mariadb")) {
        my $result = (defined(Libs::Validate::MySQL::is_int($value, $unsig)) ? 1 : undef);
        return $result;
    } elsif ($dbdriver eq "postgres") {
        return (defined(Libs::Validate::Postgres::is_int($value)) ? 1 : undef);
    }
    return undef;
}

=head2 B<[Public] is_sql_tinyint($dbdriver,$value,$unsigned)>

    Vraci 1 pokud $value odpovida typu TINYINT (-128..127, unsigned 0..255), jinak undef.
    Postgres TINYINT nema, pouzije se stejny rozsah.

=cut

sub is_sql_tinyint {
    my ($self, $dbdriver, $value, $unsig) = @_;
    if (($dbdriver eq "mysql") or ($dbdriver eq "mariadb")) {
        return (defined(Libs::Validate::MySQL::is_tinyint($value, $unsig)) ? 1 : undef);
    } elsif ($dbdriver eq "postgres") {

        # Postgres TINYINT nema (nejblizsi je SMALLINT); validujeme stejny rozsah jako MySQL.
        return (defined(Libs::Validate::MySQL::is_tinyint($value, $unsig)) ? 1 : undef);
    }
    return undef;
}

=head2 B<[Public] is_sql_varchar($dbdriver,$value,$size)>

    Vraci 1 pokud $value neni delsi nez $size znaku, jinak undef.

=cut

sub is_sql_varchar {
    my ($self, $dbdriver, $value, $size) = @_;
    if (($dbdriver eq "mysql") or ($dbdriver eq "mariadb")) {
        return (defined(Libs::Validate::MySQL::is_varchar($value, $size)) ? 1 : undef);
    } elsif ($dbdriver eq "postgres") {
        return (defined(Libs::Validate::Postgres::is_varchar($value, $size)) ? 1 : undef);
    }
    return undef;
}

=head2 B<[Public] is_sql_enum($dbdriver,$value,\@enum_values)>

    Vraci 1 pokud je $value jednou z povolenych hodnot ENUM, jinak undef.
    Pro postgres neni implementovano (loguje TODO, vraci undef).

=cut

sub is_sql_enum {
    my ($self, $dbdriver, $value, $enumv) = @_;
    if (($dbdriver eq "mysql") or ($dbdriver eq "mariadb")) {
        return (defined(Libs::Validate::MySQL::is_enum($value, @{$enumv})) ? 1 : undef);
    } elsif ($dbdriver eq "postgres") {
        $LOG->error("TODO : DODELAT VALIDACI PRO POSTGRES ENUM");
        return undef;
    }
    return undef;
}

=head2 B<[Public] is_sql_decimal($dbdriver,$value,$precision,$scale,$unsigned)>

    Vraci 1 pokud $value odpovida typu DECIMAL($precision,$scale), jinak undef.

=cut

sub is_sql_decimal {
    my ($self, $dbdriver, $value0, $value1, $value2, $unsig) = @_;
    if (($dbdriver eq "mysql") or ($dbdriver eq "mariadb")) {
        return (defined(Libs::Validate::MySQL::is_decimal($value0, $value1, $value2, $unsig)) ? 1 : undef);
    } elsif ($dbdriver eq "postgres") {
        return (defined(Libs::Validate::MySQL::is_decimal($value0, $value1, $value2)) ? 1 : undef);
    }
    return undef;
}

=head2 B<[Public] is_sql_boolen($dbdriver,$value)>

    Vraci 1 pokud je $value platny zapis boolean hodnoty (t/f, true/false, y/n, yes/no, on/off,
    1/0 - bez ohledu na velikost pismen), jinak undef. Nazev s preklepem je ponechan kvuli
    zpetne kompatibilite, preferujte alias is_sql_boolean.

=cut

sub is_sql_boolen {
    my ($self, $dbdriver, $value) = @_;
    if (($dbdriver eq "mysql") or ($dbdriver eq "mariadb")) {

        # MySQL BOOLEAN je ve skutecnosti TINYINT(1); akceptujeme stejne zapisy jako Postgres (t/f, 1/0, true/false, ...)
        return (defined(Libs::Validate::Postgres::is_psql_boolean($value)) ? 1 : undef);
    } elsif ($dbdriver eq "postgres") {
        return (defined(Libs::Validate::Postgres::is_psql_boolean($value)) ? 1 : undef);
    }
    return undef;
}

=head2 B<[Public] is_sql_boolean($dbdriver,$value)>

    Alias pro is_sql_boolen (spravne pojmenovany).

=cut

sub is_sql_boolean {
    my $self = shift;
    return $self->is_sql_boolen(@_);
}

=head2 B<[Private] AUTOLOAD(...)>

    Volani nezname validacni metody: zaloguje, posle e-mail report a die - preklep v nazvu
    validatoru v 'rules' se tak projevi hned a hlasite.

=cut

sub AUTOLOAD {
    my $self = shift;
    my $name = $AUTOLOAD;
    $name =~ s/.*://;
    return if ($name =~ /^DESTROY$/);
    $LOG->error("INTERNAL ERROR !!!");
    $LOG->error("Unknwon method name:$name");
    $LOG->sendErrorReport("VALIDATE", undef, $name, "Unknwon method name:$name");
    die "Internal error, unknown method name:$name";
    exit;
}

=head2 B<[Private] KOMODO()>

    Mrtvy kod pro IDE (Komodo/VS Code), aby umelo doplnit typy globalnich promennych.
    Nikdy se nevola - prvni prikaz je return.

=cut

# KOMODO-IDE/KOMODO-EDIT
sub KOMODO {
    return;
    require Libs::Config;
    require Libs::Log;
    $LOG  = new Libs::Log;
    $CONF = new Libs::Config;
}

1;
