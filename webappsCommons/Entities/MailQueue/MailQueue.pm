package Entities::MailQueue::MailQueue;

use MIME::Base64;

=DB

    /* POSTGRES */
    CREATE TABLE mailqueue (
        mid 		    SERIAL 				        NOT NULL        PRIMARY KEY,
        mailfrom	    VARCHAR(256)	            NOT NULL,
        mailto		    TEXT			            NOT NULL,
        cc		        TEXT			            NULL,
        bcc		        TEXT			            NULL,
        replyto		    VARCHAR(256)	            NULL,
        returnpath	    VARCHAR(256)	            NULL,
        errorto	        VARCHAR(256)	            NULL,
        subject	        TEXT			            NOT NULL,
        text		    TEXT			            NOT NULL,
        textalt		    TEXT			            NULL,
        attachment      BYTEA                       NULL,
        sendstatus	    VARCHAR(1)		            NOT NULL        DEFAULT 'N',
        started	        TIMESTAMP WITH TIME ZONE 	NOT NULL        DEFAULT NOW(),
        updated         TIMESTAMP WITH TIME ZONE 	NULL,
        created         TIMESTAMP WITH TIME ZONE	NOT NULL 	    DEFAULT NOW()
    );

    /* MYSQL */
    CREATE TABLE IF NOT EXISTS `mailqueue` (
        mid 		    INT(8) 				    UNSIGNED NOT NULL auto_increment,
        mailfrom	    VARCHAR(256)	        NOT NULL,
        mailto		    TEXT			        NOT NULL,
        cc		        TEXT			        DEFAULT NULL,
        bcc		        TEXT			        DEFAULT NULL,
        replyto		    TEXT			        DEFAULT NULL,
        returnpath	    VARCHAR(256)	        DEFAULT NULL,
        errorto	        VARCHAR(256)	        DEFAULT NULL,
        subject	        TEXT			        NOT NULL,
        text		    TEXT			        NOT NULL,
        textalt		    TEXT			        DEFAULT NULL,
        attachment      MEDIUMBLOB              DEFAULT NULL,
        sendstatus	    ENUM('Y','N','E')		NOT NULL            DEFAULT 'N',
        started	        DATETIME			    NOT NULL       	    DEFAULT NOW(),
        updated         TIMESTAMP 				NULL		        DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
        created         TIMESTAMP				NOT NULL            DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY  (`mid`),
        KEY `sendstatus` (`sendstatus`)
    ) ENGINE=InnoDB  DEFAULT CHARSET=utf8 COLLATE=utf8_czech_ci AUTO_INCREMENT=0;
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

    my $self = new Entities::Entity($CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB, "db1", "mailqueue", $opts);

    bless $self, $class;
    return $self;
}

sub mailto {
    my $self = shift;
    if (@_) {

        # ONLY SET
        my ($value) = @_;
        $value =~ s/.*<(.*)>.*/$1/;
        return ($VALIDATE->is_email($value) ? $self->SUPER::mailto(@_) : $self->SUPER::setErrorList("Invalid write data : column_name:mailto, value:$value"));
    }
    return $self->SUPER::mailto();
}

sub mailfrom {
    my $self = shift;
    if (@_) {

        # ONLY SET
        my ($value) = @_;
        $value =~ s/.*<(.*)>.*/$1/;
        return ($VALIDATE->is_email($value) ? $self->SUPER::mailfrom(@_) : $self->SUPER::setErrorList("Invalid write data : column_name:mailfrom, value:$value"));
    }
    return $self->SUPER::mailfrom();
}

sub sendstatus {
    my $self = shift;
    if (@_) {

        # ONLY SET
        my ($value) = @_;
        return (($value eq "Y" or $value eq "N" or $value eq "E") ? $self->SUPER::sendstatus(@_) : $self->SUPER::setErrorList("Invalid write data : column_name:sendstatus, value:$value"));
    }
    return $self->SUPER::sendstatus();
}

sub attachment {
    my $self = shift;
    if (@_) {

        # ONLY SET
        my ($value) = @_;
        return $self->SUPER::attachment(encode_base64($value));
    }
    return decode_base64($self->SUPER::attachment());
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
