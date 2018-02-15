package Entities::Entity;

=README

    UKAZKA ENTITY, V KTERE JE MOZNE OVLIVNIT VSECHNA VOLANI NAD ENTITAMI.

=cut

use strict;
our ($AUTOLOAD);

my ($CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB, $DAO);

sub new {
    my ($class, $conf, $log, $validate, $dbi, $user, $web, $dbid, $table, $opts) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $CONF     = $conf;
    $USER     = $user;
    $WEB      = $web;
    $VALIDATE = $validate;

    my $self = {'DAORef' => $DBI->getDAO($dbid, $table, $opts)};

    bless $self, $class;

    return $self;
}

sub DAORef {
    my $self = shift;
    return $self->{'DAORef'};
}

sub flush {
    my $self = shift;
    $self->autoUpdateTimestamp();
    my $who = sprintf("%s line %d", (caller)[1, 2]);
    $self->DAORef->setWhoCallingMe($who);
    return $self->DAORef->flush(@_);
}

sub autoUpdateTimestamp {
    my $self = shift;

    return if (@{$self->DAORef->getChangeList()} == 0);

    NEXT: foreach my $method1 (@{$self->DAORef->getMethodList()}) {

        # Pokud metoda je zmenena, nebude do ni nijak zasahovat
        foreach my $method2 (@{$self->DAORef->getChangeList()}) {
            next NEXT if ($method1 eq $method2);
        }

        # SETNEME SLOUPEC V DB POKUD SE JMENUJE updated, JE EDITOVAN A NENENI VYTVAREN NOVY,
        # DEF HODNOTA JE NULL, TYP SLOUPCE JE TIMESTAMP
        if (    ($method1 eq "updated")
            and (defined($self->DAORef->getPrimaryValue()))
            and (!defined($self->DAORef->getValue($method1, 'def')))
            and (lc($self->DAORef->getValue($method1, 'type')) =~ /^timestamp/))
        {
            $self->DAORef->setValue($method1, 'NOW()');
        }

        # SETNEME SLOUPEC V DB POKUD SE JMENUJE created, JE NOVE VYTVAREN,
        # DEF HODNOTA JE NULL, TYP SLOUPCE JE TIMESTAMP
        if (    ($method1 eq "created")
            and (!defined($self->DAORef->getPrimaryValue()))
            and (defined($self->DAORef->getValue($method1, 'def')))
            and (lc($self->DAORef->getValue($method1, 'type')) =~ /^timestamp/))
        {
            $self->DAORef->setValue($method1, 'NOW()');
        }

        # SETOVANI TIMESTAMP V MYSQL
        my $def = $self->DAORef->getValue($method1, 'def') || "";
        if (uc($def) eq "CURRENT_TIMESTAMP") {
            $self->DAORef->setValue($method1, 'CURRENT_TIMESTAMP');
        }
    }
}

# KOMODO-IDE/KOMODO-EDIT
sub KOMODO {
    return;
    require Libs::Config;
    require Libs::Log;
    require Libs::Validate;
    require Libs::DBI;
    require Libs::User;
    $CONF     = new Libs::Config;
    $LOG      = new Libs::Log;
    $VALIDATE = new Libs::Validate;
    $DBI      = new Libs::DBI;
    $USER     = new Libs::User;
}

sub AUTOLOAD {
    my $self = shift;
    my $name = $AUTOLOAD;
    $name =~ s/.*://;
    return if ($name =~ /^DESTROY$/);
    my $who = sprintf("%s line %d", (caller)[1, 2]);
    $self->DAORef->setWhoCallingMe($who);
    return $self->DAORef->$name(@_);
}

1;
