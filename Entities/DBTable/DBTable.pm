package Entities::DBTable::DBTable;

use strict;
use base qw(Entities::Entity);

=DB
    /* POSTGRES */
    CREATE TABLE dbtable (
        id             	SERIAL          		    NOT NULL        PRIMARY KEY,
        name		    VARCHAR(128)			    NULL,
        sid		        VARCHAR(128)			    NOT NULL,
        dbid	        VARCHAR(32)			        NOT NULL        DEFAULT 'db1',
        script		    VARCHAR(256)			    NULL,
        appendurl	    VARCHAR(256)			    NULL,
        page		    VARCHAR(128)			    NULL,
        func		    VARCHAR(128)			    NULL,
        tmpl		    VARCHAR(256)			    NULL,
        query		    TEXT				        NOT NULL,
        conditions	    TEXT				        NOT NULL,
        ordercolumn	    VARCHAR(64)			        NULL,
        orderby		    VARCHAR(64)			        NULL            DEFAULT 'ASC',
        groupby		    VARCHAR(128)			    NULL,   
        maxrow		    INTEGER				        NULL            DEFAULT 40,
        gopage		    INTEGER				        NULL            DEFAULT 1,
        rowcount	    INTEGER				        NULL            DEFAULT 0,
        endpage		    SMALLINT			        NOT NULL        DEFAULT 0,
        nlimit		    SMALLINT			        NOT NULL        DEFAULT 0,
        updated         TIMESTAMP WITH TIME ZONE	NULL,
        created         TIMESTAMP WITH TIME ZONE	NOT NULL 	    DEFAULT NOW()
    );
    
    /* MYSQL */
    CREATE TABLE IF NOT EXISTS `dbtable` (
        id 		        INT(8) 				UNSIGNED NOT NULL auto_increment,
        name		    VARCHAR(128)		DEFAULT NULL,
        sid		        VARCHAR(128)		NOT NULL,
        dbid	        VARCHAR(32)			NOT NULL        DEFAULT 'db1',
        script		    VARCHAR(256)		DEFAULT NULL,
        appendurl	    VARCHAR(256)		NULL,
        page		    VARCHAR(128)		DEFAULT NULL,
        func		    VARCHAR(128)		DEFAULT NULL,
        tmpl		    VARCHAR(256)		DEFAULT NULL,
        query		    TEXT				NOT NULL,
        conditions	    TEXT				NOT NULL,
        ordercolumn	    VARCHAR(64)			DEFAULT 	NULL,
        orderby		    VARCHAR(64)			NULL        DEFAULT 'ASC',
        groupby		    VARCHAR(128)		DEFAULT 	NULL,   
        maxrow		    INTEGER				NULL        DEFAULT 40,
        gopage		    INTEGER				NULL        DEFAULT 1,
        rowcount	    INTEGER				NULL        DEFAULT 0,
        endpage		    SMALLINT			NULL        DEFAULT 0,
        nlimit		    SMALLINT			DEFAULT 	NULL,
        updated         TIMESTAMP 			NULL		DEFAULT NULL,
        created         TIMESTAMP			NOT NULL 	DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY  (`id`),
        KEY `name` (`name`),
        KEY `sid` (`sid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_czech_ci AUTO_INCREMENT=0;
=cut

my ($CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB);

sub new {
    my ($class, $conf, $log, $validate, $dbi, $user, $web, $opts) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $CONF     = $conf;
    $USER     = $user;
    $WEB      = $web;
    $VALIDATE = $validate;

    my $self = new Entities::Entity($CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB, "db1", "dbtable", $opts);

    bless $self, $class;
    return $self;
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
