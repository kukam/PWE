package Services::Accounts::Accounts;

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

    my $self = {};

    bless $self, $class;
    return $self;
}

sub setAccount {
    my ($self, %acc) = @_;

    my $USER = $ENTITIES->createEntityObject('User', $acc{uid});
    $USER->fullname($acc{'fullname'}) if ($acc{'fullname'});
    $USER->active($acc{'active'})     if ($acc{'active'});
    $USER->flush;
    $USER->logit;
    if ($USER->error) {
        $USER->rollback();
        return undef;
    } else {
        $USER->commit;
        return 1;
    }
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
