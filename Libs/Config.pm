package Libs::Config;

use strict;

sub new {
    my ($class, $mainconfig, $databaseconfig) = @_;

    die "$mainconfig not exist!" unless (-f $mainconfig);

    my $self = do($mainconfig);
    $self->{'dbi'} = do($databaseconfig) if (-f $databaseconfig);
    bless $self, $class;

    # Moznost prepsat konfiguraci pomoci globalnich promenych (Environment variables)
    # EXAMPLE: PWE_CONF_dbi_dbX_keyname
    # EXAMPLE: PWE_CONF_keyname1_keyname1 (pwe, home)
    while (my ($key, $value) = each %ENV) {
        if ($key =~ /^PWE_CONF_dbi_(db\d+)_([a-zA-Z0-9_]+)$/) {
            if ($self->getValue('dbi', "$1", undef)) {
                $self->{'dbi'}->{$1}->{$2} = $value if (exists($self->{'dbi'}->{$1}->{$2}));
            }
        } elsif ($key =~ /^PWE_CONF_([a-zA-Z0-9]+)_([a-zA-Z0-9_]+)$/) {
            $self->{$1}->{$2} = $value if ($self->isExistValue("$1", "$2"));
        }
    }

    # Rapair path
    if ($self->getValue('pwe', 'home', undef) !~ /\/$/) {
        $self->{'pwe'}->{'home'} .= "/";
    }

    return $self;
}

=head2 B<[Public] getValue($key,$subkey,$def)>

    Metoda vraci obsah atributu ($key) a jeho podklice ($subkey),
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

sub isExistValue {
    my ($self, $key, $subkey,) = @_;
    return 0 if (ref($self->{$key}) ne "HASH");
    return 0 unless (exists($self->{$key}->{$subkey}));
    return 1;
}

1;
