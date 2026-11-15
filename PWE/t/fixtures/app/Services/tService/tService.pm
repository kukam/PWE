package Services::tService::tService;

# Testovaci sluzba pro t/*.t - pocita newRequest/flush a poskytuje validacni metodu is_adult.

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

sub new {
    my ($class, $conf, $log, $validate, $dbi, $entities, $user, $web) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $WEB      = $web;
    $CONF     = $conf;
    $USER     = $user;
    $VALIDATE = $validate;
    $ENTITIES = $entities;

    my $self = {'requests' => 0, 'flushed' => 0, 'autostarted' => 0};

    bless $self, $class;
    return $self;
}

sub autostart {
    my $self = shift;
    $self->{'autostarted'} = 1;
}

sub newRequest {
    my $self = shift;
    $self->{'requests'}++;
}

sub flush {
    my $self = shift;
    $self->{'flushed'}++;
}

sub is_adult {
    my ($self, $value) = @_;
    return undef unless (defined($value) and $value =~ /^\d+$/);
    return (($value >= 18) ? $value : undef);
}

sub crash {
    my $self = shift;
    die "service boom";
}

# KOMODO-IDE/KOMODO-EDIT
sub KOMODO {
    return;
    require Libs::Config;
    require Libs::Log;
    require Libs::Validate;
    require Libs::DBI;
    require Libs::Entities;
    require Libs::User;
    require Libs::Web;
    $CONF     = new Libs::Config;
    $LOG      = new Libs::Log;
    $VALIDATE = new Libs::Validate;
    $DBI      = new Libs::DBI;
    $ENTITIES = new Libs::Entities;
    $USER     = new Libs::User;
    $WEB      = new Libs::Web;
}

1;
