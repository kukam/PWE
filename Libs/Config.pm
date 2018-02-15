package Libs::Config;

use strict;

sub new {
    my ($class, $file) = @_;

    my $self = do($file);

    bless $self, $class;
    return $self;
}

=head2 B<[Public] getValue($key,$subkey,$def)>

    Metoda vraci obsah atributu ($key) a jeho podklic ($subkey),
    pokud jedna z promenych neexistuje vraci metoda hodnotu $def.
    
=cut

sub getValue {
    my ($self, $key, $subkey, $def) = @_;

    return $def unless (exists($self->{$key}));

    if ($subkey) {
        return $def if (ref($self->{$key}) ne "HASH");
        return $def unless (exists($self->{$key}->{$subkey}));
        return $def unless ($self->{$key}->{$subkey});
        return $self->{$key}->{$subkey};
    } else {
        return $def unless ($self->{$key});
        return $self->{$key};
    }
}

1;
