package Entities::Entity;

=head1 NAME

Entities::Entity - zakladni trida entit; deleguje volani na Libs::MyDBI::DAO a doplnuje casova razitka

=cut

=head1 README

    ZAKLADNI TRIDA ENTIT, V KTERE JE MOZNE OVLIVNIT VSECHNA VOLANI NAD ENTITAMI.

=cut

use strict;
our ($AUTOLOAD);

my ($CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB, $DAO);

=head2 B<[Public] new($conf,$log,$validate,$dbi,$user,$web,$dbid,$table,$opts)>

    Zakladni trida vsech entit. Vytvori DAO objekt tabulky $table v databazi $dbid
    (viz Libs::MyDBI::getDAO - $opts je id radku, {where,conds} nebo {disable_db_pooler}).
    Konkretni entita (Entities::X::X) dedi pres "use base qw(Entities::Entity)" a v new()
    vola tento konstruktor s nazvem sve tabulky.

=cut

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

=head2 B<[Public] DAORef()>

    Vraci podkladovy DAO objekt (Libs::MyDBI::DAO).

=cut

sub DAORef {
    my $self = shift;
    return $self->{'DAORef'};
}

=head2 B<[Public] flush()>

    Zapise zmeny do DB (DAO::flush). Pred tim automaticky nastavi sloupce updated/created
    (autoUpdateTimestamp) a zaznamena volajiciho pro SQL komentar.

=cut

sub flush {
    my $self = shift;
    $self->autoUpdateTimestamp();
    my $who = sprintf("%s line %d", (caller)[1, 2]);
    $self->DAORef->setWhoCallingMe($who);
    return $self->DAORef->flush(@_);
}

=head2 B<[Private] autoUpdateTimestamp()>

    Pokud ma radek zmeny, doplni casova razitka u sloupcu, ktere uzivatel sam nezmenil:
    'updated' (TIMESTAMP, default NULL) = NOW() pri UPDATE; 'created' (TIMESTAMP) = NOW()
    pri INSERT; libovolny sloupec s defaultem CURRENT_TIMESTAMP = CURRENT_TIMESTAMP.

=cut

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

=head2 B<[Private] KOMODO()>

    Mrtvy kod pro IDE (Komodo/VS Code), aby umelo doplnit typy globalnich promennych.
    Nikdy se nevola - prvni prikaz je return.

=cut

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

=head2 B<[Private] AUTOLOAD(...)>

    Vsechna ostatni volani ($E->sloupec, $E->commit, $E->error, $E->logit, ...) deleguje na DAO
    objekt a zaznamena volajiciho (soubor:radek) pro SQL komentare. Entita tak ma kompletni
    API DAO plus sve vlastni prepsane settery sloupcu.

=cut

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
