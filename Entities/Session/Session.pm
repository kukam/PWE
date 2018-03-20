package Entities::Session::Session;

=DB

    /* POSTGRES */
    CREATE TABLE session (
        sid             VARCHAR(256)          		NOT NULL    PRIMARY KEY,
        useragent	    VARCHAR(256)          		NOT NULL,
        ipaddres        VARCHAR(128)          		NOT NULL,
        lang            VARCHAR(32)          		NOT NULL    DEFAULT 'CZE',
        messenger	    TEXT				        NULL,
        expire		    INT				            NOT NULL,
        updated         TIMESTAMP WITH TIME ZONE	NULL,
        created         TIMESTAMP WITH TIME ZONE	NOT NULL 	DEFAULT NOW()
    );
    
    /* MySQL */
    CREATE TABLE session IF NOT EXISTS `session` (
        sid             VARCHAR(256)          		NOT NULL,
        useragent	    VARCHAR(256)          		NOT NULL,
        ipaddres        VARCHAR(128)          		NOT NULL,
        lang            VARCHAR(32)          		NOT NULL    DEFAULT 'CZE',
        messenger	    TEXT				        NULL,
        expire		    INT(12)				        NOT NULL,
        updated         TIMESTAMP	                NULL,
        created         TIMESTAMP	                NOT NULL 	DEFAULT NOW(),
        PRIMARY KEY  (`sid`)
    ) ENGINE=InnoDB  DEFAULT CHARSET=utf8 COLLATE=utf8_czech_ci;
    
=cut

use strict;
use base qw(Entities::Entity);

my ($CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB);

sub new {
    my ($class, $conf, $log, $validate, $dbi, $user, $web, $opts) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $CONF     = $conf;
    $USER     = $user;
    $WEB      = $web;
    $VALIDATE = $validate;

    my $self = new Entities::Entity($CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB, "db1", "session", $opts);

    bless $self, $class;
    return $self;
}

sub messenger {
    my $self = shift;
    if (@_) {

        # ONLY SET
        my ($value) = @_;
        $value =~ s/\n//g;
        $value =~ s/\r//g;
        $value =~ s/\t//g;
        $value =~ s/\s+</</g;
        $value =~ s/\s+>/>/g;
        $value =~ s/<\s+>/<>/g;
        return $self->SUPER::messenger($value);
    }
    return $self->SUPER::messenger();
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

1;
