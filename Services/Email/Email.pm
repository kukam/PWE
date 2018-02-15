package Services::Email::Email;

use strict;
use Libs::Send;
use MIME::Base64;
use Archive::Tar;

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

    my $self = {
        'timeout_for_result_E' => ((3600 * 24) * 3),    # 3 days, za jak dlouhou dobu se email oznaci 'E' v pripade ze ho mailserver stale odmita.
    };

    bless $self, $class;
    return $self;
}

=head2 B<[Public] sendAllEmail()>

    Metoda se pokusi odeslat vsechny maily ve fronte.
    
=cut

sub sendAllEmail {
    my $self = shift;

    # TODO : Metoda nerozlisuje nedostupnost postovniho servru a chyby pri konstrukci email (rejecting)
    #        To muze zpusobit ze validni emaily pri dlouhodobem vypadku mailservru budou invalidovany a nasledne zahozeny!!!

    my $SQL   = undef;
    my $error = undef;

    if ($DBI->getDbDriver("db1") eq "MySQL") {

        $SQL = $DBI->select("db1", "mid,mailfrom,mailto,replyto,cc,bcc,returnpath,errorto,subject,text,textalt,attachment, TIME_TO_SEC(TIMEDIFF(NOW(),started)) as `timedif` FROM mailqueue WHERE sendstatus = ? AND started < NOW()", ["N"]);

    } elsif ($DBI->getDbDriver("db1") eq "Postgres") {

        # TODO : Slo by pouzit tuto funkci age(NOW(), started), ale nevim jak prevest tento format na secundy
        $SQL = $DBI->select("db1","mid,mailfrom,mailto,replyto,cc,bcc,returnpath,errorto,subject,text,textalt,attachment, (extract(epoch from NOW() at time zone 'utc' at time zone 'utc') - extract(epoch from started at time zone 'utc' at time zone 'utc')) as timedif FROM mailqueue WHERE sendstatus = ? AND started < NOW()",["N"]);
    }

    NEXT: while (my ($mid, $from, $to, $replyto, $cc, $bcc, $returnpath, $errorto, $sub, $text, $textalt, $attachment, $timedif) = $SQL->fetchrow()) {

        foreach my $smtp_server (@{$CONF->getValue("pwe", "smtp_servers", ["smtp_primary"])}) {

            my $config = $CONF->getValue($smtp_server, undef, undef);

            if (ref($config) ne "HASH") {
                $LOG->error("smtp server '$smtp_server' config is not defined");
                next;
            }

            my $send = new Libs::Send($config);

            foreach (split(/,/, $from))       { $send->setFrom($_); }
            foreach (split(/,/, $to))         { $send->setTo($_); }
            foreach (split(/,/, $cc))         { $send->setCc($_); }
            foreach (split(/,/, $bcc))        { $send->setBcc($_); }
            foreach (split(/,/, $replyto))    { $send->setReplyTo($_); }
            foreach (split(/,/, $returnpath)) { $send->setReturnPath($_); }
            foreach (split(/,/, $errorto))    { $send->setErrorTo($_); }

            $send->setSubjectUTF8($sub);
            $send->setBody($textalt);
            $send->setBody($text);

            my @tarfiles;            
            my $extract = $CONF->getValue('pwe', 'home', '/tmp/') . $CONF->getValue('pwe', 'upload_dir', 'upload/') . "extract/";

            if ($attachment) {
                open(ZIP, '<', \decode_base64($attachment));
                binmode ZIP;
                my $tar = Archive::Tar->new(\*ZIP);
                $tar->setcwd($extract);
                foreach my $oldpath ($tar->list_files()) {
                    my $newpath = $oldpath;
                    $newpath =~ s/.*\///;
                    $tar->rename($oldpath,$newpath);
                    $send->setAttachment($extract.$newpath);
                    push(@tarfiles,$extract.$newpath);
                }
                $tar->extract();
                close (ZIP);
            }

            my $result = $send->send();

            # CLER ATTACHMENT
            foreach my $path (@tarfiles) { unlink($path); }

            if ($result) {
                $LOG->error("Traing send email to:$to id:$mid FAIL, msg:$result");
                sleep(1);
            } else {
                $self->updateSendResult($mid, "Y");
                $LOG->info("Send mail id:$mid to:$to is completed.");
                next NEXT;
            }
        }

        # POKUD SE EMAIL NEDARI ODESLAT DELSI DOBU, OZNACIME JEJ STAVEM 'E' + ODESLEME INFO ADMINISTRATOROVY.
        if ($timedif > $self->getValue('timeout_for_result_E', 3600)) {
            $self->updateSendResult($mid, "E");
            $error->{$mid} = $to;
            $LOG->error("Send error report email to administrator. Error email is '$to' mid: $mid");
        }
    }
    $SQL->finish;
    $self->sendErrorEmail($error) if (defined($error));
}

=head2 B<[Public] addEmailToQueue(%HASH)>

    Metoda prida novy email do fronty.

    $EMAIL->addEmailToQueue(
        to => 'to@email.com',
        from => 'from@email.com',
        subject => "Sujbect",
        text => "Content-Type: text/plain; charset=UTF-8\n TEXT",
        
        # Nepovine hodnoty
        textalt => "ALTERNATIVE BODY",
        cc => 'cc@email.com',
        bcc => 'bcc@email.com',
        replyto => 'replyto@email.com',
        returnpath => 'returnpath@email.com',
        errorto => 'errorto@email.com',
        attachments => [ '/path/filename1.txt', '/path/filename2.txt' ],
        started => '2003-09-13 13:13:13'
    );
    
=cut

sub addEmailToQueue {
    my ($self, %values) = @_;

    my $MAILQ = $ENTITIES->createEntityObject('MailQueue');

    $MAILQ->mailfrom($values{'from'});
    $MAILQ->mailto($values{'to'});
    $MAILQ->subject($values{'subject'});
    $MAILQ->text($values{'text'});
    $MAILQ->replyto($values{'replyto'});
    $MAILQ->cc($values{'cc'});
    $MAILQ->bcc($values{'bcc'});
    $MAILQ->returnpath($values{'returnpath'});
    $MAILQ->errorto($values{'errorto'});
    
    ($values{'started'} ? $MAILQ->started($values{'started'}) : $MAILQ->started('NOW()'));

    if (exists($values{'attachments'})) {

        my $tar = Archive::Tar->new;
        foreach my $file (@{$values{'attachments'}}) {
            if (-f $file) {
                $tar->add_files($file);
            } else {
                $LOG->error("File '$file' not exist!");
            }
        }
        $MAILQ->attachment($tar->write);
    }
    
    $MAILQ->flush;
    $MAILQ->logit;
    
    if ($MAILQ->error) {
        $MAILQ->rollback;
        return undef;
    } else {
        $MAILQ->commit;
        $LOG->info("ADD email to queue from:$values{'from'} to:$values{'to'}");
        return 1;
    }
}

=head2 B<[Public] updateSendResult($mid,$result)>

    Metoda prepne stav emailu.
    
    MID = id v mail_queue
    
    Stavy ($result):
    Y  = "Email byl v poradku servrem prijat a je povazovany za odeslany.
    E  = "Email se nepodarilo odeslat a byl vyrazen z fronty.
    N  = "Email je novy, jeste neni odeslan.
    
=cut

sub updateSendResult {
    my ($self, $mid, $result) = @_;

    my $EMAIL = $ENTITIES->createEntityObject('MailQueue', $mid);

    $EMAIL->sendstatus($result);
    $EMAIL->flush;
    $EMAIL->logit;

    if ($EMAIL->error) {
        $EMAIL->rollback;
    } else {
        $EMAIL->commit;
    }
}

=head2 B<[Private] sendErrorEmail($error)>

    Metoda odesle informace o emailech ktere se nepodarilo odeslat po stanovenou dobu.
    
    $error = {
        id => email,
        ....
    };
    
=cut

sub sendErrorEmail {
    my ($self, $error) = @_;

    my $from = $CONF->getValue("web", "email_admin",    "root\@localhost");
    my $to   = $CONF->getValue("web", "email_admin",    "root\@localhost");
    my $sub  = $CONF->getValue("web", "email_subtitle", "Pwe error Report") . " : Seznam emailu ktere se po nekolika pokusech nepodarilo odeslat!";

    my $text = "\nTyto emaily nebylo mozne odeslat, jsou vyrazeny z fronty.\n";

    $text .= "=========================================================\n\n";

    while (my ($id, $email) = each(%{$error})) {
        $text .= "id: $id to: $email\n";
    }

    $text .= "\nTimto prikaze vratis emaily zpet do fronty\n";
    $text .= "==========================================\n\n";

    while (my ($id, $email) = each(%{$error})) {
        $text .= "UPDATE mail_queue SET sendstatus = 'N', started = NOW() WHERE mid = $id;\n";
    }

    $self->addEmailToQueue(to => $to, from => $from, subject => $sub, text => $text);
}

=head2 B<[Private] getValue($key,$def)>

    Metoda vraci obsah atributu ($key), pokud atribut neexistuje
    vraci metoda hodnotu $def.
    
=cut

sub getValue {
    my ($self, $key, $def) = @_;
    return $def unless (exists($self->{$key}));
    return $def unless ($self->{$key});
    return $self->{$key};
}

# KOMODO-IDE/KOMODO-EDIT
sub KOMODO {
    return;
    require Libs::Config;
    require Libs::Log;
    require Libs::Validate;
    require Libs::DBI;
    require Libs::User;
    require Libs::Web;
    require Libs::Entities;
    $CONF     = new Libs::Config;
    $LOG      = new Libs::Log;
    $VALIDATE = new Libs::Validate;
    $DBI      = new Libs::DBI;
    $USER     = new Libs::User;
    $WEB      = new Libs::Web;
    $ENTITIES = new Libs::Entities;
}

1;
