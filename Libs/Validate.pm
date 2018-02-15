package Libs::Validate;

use strict;
use warnings;
use vars qw(@ISA);
use Libs::Validate::MySQL;
use Libs::Validate::Postgres;
use Libs::Validate::Data;
use Mail::RFC822::Address qw(valid);

our $AUTOLOAD;    # it's a package global

my ($CONF, $LOG);

sub new {
    my ($class, $conf, $log) = @_;

    $LOG  = $log;
    $CONF = $conf;

    my $self = {};

    bless $self, $class;
    return $self;
}

=head2 B<[Public] validate([])>

    Metoda validuje hodnoty v poli, viz priklad

    print Dumper($V->validate(["is_enum","error_enum","value",('sdf','sdf1','valuesxx')]));

    or
    
    print Dumper($V->validate(["is_numeric","error_cislo",'a123']));

    ...

=cut

sub validate {
    my $self = shift;
    my @args = (@{$_[0]});

    my $method = $args[0];
    my $error  = $args[1];
    my $result = undef;

    splice(@args, 0, 2);

    eval "\$SIG{__DIE__}='DEFAULT'; \$result = \$self->\$method(\@args);";

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

    Metoda validuje hodnotu dane s povolenymi hodnotami v konfiguraku.
    Validuji se zde hodnoty ve tvar 1.21,(21%)  1.10 (10%) atd 

=cut

sub validate_decimal_vat {
    my ($self, $validate_vat) = @_;
    my $vats = $CONF->getValue("web", "access_vat", []);
    foreach my $v (@{$vats}) { return 1 if ((($v / 100) + 1) eq $validate_vat); }
    return undef;
}

=head2 B<[Public] validate_numeric_vat($vat)>

    Metoda validuje hodnotu dane s povolenymi hodnotami v konfiguraku.
    Validuji se zde hodnoty ve tvar 21% 10% atd

=cut

sub validate_numeric_vat {
    my ($self, $validate_vat) = @_;
    my $vats = $CONF->getValue("web", "access_vat", []);
    foreach my $v (@{$vats}) { return 1 if ($v eq $validate_vat); }
    return undef;
}

sub must_be_defined {
    my ($self, $value) = @_;
    return (defined($value) ? $value : undef);
}

sub is_md5hex {
    my ($self, $value) = @_;
    return undef unless (defined($value));
    return (($value =~ /^[a-fA-F0-9]+$/) ? 1 : undef);
}

sub is_percent {
    my ($self, $value) = @_;
    my $value1 = $value;
    $value1 =~ s/\%$//;
    return ($self->is_numeric($value1) ? $value : undef);
}

sub is_regx {
    my ($self, $value, $args) = @_;
    return (($value =~ /$args/) ? $value : undef);
}

sub isnot_regx {
    my ($self, $value, $args) = @_;
    return (($value !~ $args) ? $value : undef);
}

sub is_email {
    my ($self, $value) = @_;
    return undef if (!Mail::RFC822::Address::valid($value));
    return undef if ($value !~ /^[_a-zA-Z0-9\.\-]+@[a-zA-Z0-9\.\-]+\.[a-zA-Z]{2,4}$/);
    return $value;
}

sub isnot_equal_to {
    my ($self, $value1, $value2) = @_;
    return ($self->is_equal_to($value1, $value2) ? undef : 1);
}

sub is_language {
    my ($self, $value) = @_;
    foreach (@{$CONF->getValue("http", "languages", [])}) {
        return $value if ($value eq $_);
    }
    return undef;
}

sub is_zipcode {
    my ($self, $null, $value) = @_;
    return 1 if ($null and !$value);
    return undef if ($value !~ /^\d+$/);
    return undef if (length($value) != 5);
    return 1;
}

sub escape_jsinjection {
    my ($self, $value) = @_;
    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    return $value;
}

sub is_sql_int {
    my ($self, $dbdriver, $value, $unsig) = @_;
    if ($dbdriver eq "MySQL") {
        my $result = (defined(Libs::Validate::MySQL::is_int($value, $unsig)) ? 1 : undef);
        return $result;
    } elsif ($dbdriver eq "Postgres") {
        return (defined(Libs::Validate::Postgres::is_int($value)) ? 1 : undef);
    }
}

sub is_sql_varchar {
    my ($self, $dbdriver, $value, $size) = @_;
    if ($dbdriver eq "MySQL") {
        return (defined(Libs::Validate::MySQL::is_varchar($value, $size)) ? 1 : undef);
    } elsif ($dbdriver eq "Postgres") {
        return (defined(Libs::Validate::Postgres::is_varchar($value, $size)) ? 1 : undef);
    }
}

sub is_sql_enum {
    my ($self, $dbdriver, $value, $enumv) = @_;
    if ($dbdriver eq "MySQL") {
        return (defined(Libs::Validate::MySQL::is_enum($value, @{$enumv})) ? 1 : undef);
    } elsif ($dbdriver eq "Postgres") {
        $LOG->error("TODO : DODELAT VALIDACI PRO POSTGRES ENUM");
        return undef;
    }
}

sub is_sql_decimal {
    my ($self, $dbdriver, $value0, $value1, $value2, $unsig) = @_;
    if ($dbdriver eq "MySQL") {
        return (defined(Libs::Validate::MySQL::is_decimal($value0, $value1, $value2, $unsig)) ? 1 : undef);
    } elsif ($dbdriver eq "Postgres") {
        return (defined(Libs::Validate::MySQL::is_decimal($value0, $value1, $value2)) ? 1 : undef);
        return undef;
    }
}

sub is_sql_boolen {
    my ($self, $dbdriver, $value) = @_;
    if ($dbdriver eq "MySQL") {
        $LOG->error("TODO: DODELAT BOOLEAN V MYSQL");
        return undef;
    } elsif ($dbdriver eq "Postgres") {
        return (defined(Libs::Validate::Postgres::is_psql_boolean($value)) ? 1 : undef);
    }
}

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

# KOMODO-IDE/KOMODO-EDIT
sub KOMODO {
    return;
    require Libs::Config;
    require Libs::Log;
    $LOG  = new Libs::Log;
    $CONF = new Libs::Config;
}

1;
