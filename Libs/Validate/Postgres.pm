package Libs::Validate::Postgres;

use strict;
use warnings;
use Libs::Validate::Data;
use Libs::Validate::MySQL;

use vars qw(@ISA @EXPORT);

require Exporter;

@ISA = qw(Exporter);

@EXPORT = qw(
  &is_psql_boolean
);

sub new {
    my $class = shift;
    return bless {}, $class;
}

sub is_psql_boolean {
    my $self = shift if ref($_[0]);
    my $value = shift;
    $value = lc($value);
    return $value if (($value eq "t") or ($value eq "true")  or ($value eq "y") or ($value eq "yes") or ($value eq "on")  or ($value eq "1"));
    return $value if (($value eq "f") or ($value eq "false") or ($value eq "n") or ($value eq "no")  or ($value eq "off") or ($value eq "0"));
    return undef;
}

