package Entities::MailQueue::MailQueue;

=head1 NAME

Entities::MailQueue::MailQueue - entita tabulky mailqueue (fronta e-mailu, Services::Email)

=cut

use MIME::Base64;

=head1 DB

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

=head2 B<[Public] new($conf,$log,$validate,$dbi,$user,$web,$opts)>

    Entita tabulky 'mailqueue' (db1) - fronta odchozich e-mailu pro Services::Email
    (sendstatus N = ceka, Y = odeslano, E = chyba/vyrazeno).

=cut

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

=head2 B<[Public] mailto([$address])>

    Getter/setter prijemce; pri zapisu overi e-mail (z tvaru "Jmeno <adresa>" vezme adresu),
    neplatna hodnota zapise chybu do errorlistu a vrati undef.

=cut

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

=head2 B<[Public] mailfrom([$address])>

    Getter/setter odesilatele se stejnou validaci jako mailto.

=cut

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

=head2 B<[Public] sendstatus([$status])>

    Getter/setter stavu odeslani; povoleny jen hodnoty Y, N, E.

=cut

sub sendstatus {
    my $self = shift;
    if (@_) {

        # ONLY SET
        my ($value) = @_;
        return (($value eq "Y" or $value eq "N" or $value eq "E") ? $self->SUPER::sendstatus(@_) : $self->SUPER::setErrorList("Invalid write data : column_name:sendstatus, value:$value"));
    }
    return $self->SUPER::sendstatus();
}

=head2 B<[Public] attachment([$data])>

    Getter/setter prilohy. Zapis ulozi data (tar archiv souboru) zakodovane base64,
    cteni vraci dekodovana data (undef pokud priloha neni).

=cut

sub attachment {
    my $self = shift;
    if (@_) {

        # ONLY SET
        my ($value) = @_;
        return $self->SUPER::attachment(encode_base64($value));
    }
    my $data = $self->SUPER::attachment();
    return (defined($data) ? decode_base64($data) : undef);
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

1;
