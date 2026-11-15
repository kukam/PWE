package Libs::Validate::Postgres;

=head1 NAME

Libs::Validate::Postgres - doplnkove validatory pro PostgreSQL (boolean); INT a VARCHAR se prebiraji z Libs::Validate::MySQL

=cut

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

=head2 B<[Public] new()>

    Konstruktor pro OO pouziti (funkce lze volat i primo, jsou exportovany do Libs::Validate).

=cut

sub new {
    my $class = shift;
    return bless {}, $class;
}

=head2 B<[Public] is_psql_boolean($value)>

    Vraci normalizovanou (malymi pismeny) hodnotu, pokud je to platny zapis PostgreSQL boolean:
    t/true/y/yes/on/1 nebo f/false/n/no/off/0; jinak undef.

=cut

sub is_psql_boolean {
    my $self = shift if ref($_[0]);
    my $value = shift;
    $value = lc($value);
    return $value if (($value eq "t") or ($value eq "true")  or ($value eq "y") or ($value eq "yes") or ($value eq "on")  or ($value eq "1"));
    return $value if (($value eq "f") or ($value eq "false") or ($value eq "n") or ($value eq "no")  or ($value eq "off") or ($value eq "0"));
    return undef;
}

