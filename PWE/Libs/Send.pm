package Libs::Send;

=head1 NAME

Libs::Send - odesilani e-mailu pres SMTP (Net::SMTP): hlavicky, UTF-8 predmet, multipart tela a prilohy

=cut

# http://robertmaldon.blogspot.cz/2006/10/sending-email-through-google-smtp-from.html
# https://en.wikipedia.org/wiki/Variable_envelope_return_path (verp)
# http://stackoverflow.com/questions/11440475/verp-and-perl-postfix-not-working

use strict;
use warnings;
use Net::SMTP;
use File::Spec;
use Time::Local;
use MIME::Base64;
use LWP::MediaTypes;
use MIME::QuotedPrint;
use Cz::Cstocs 'utf8_ascii';
use Mail::RFC822::Address qw(valid);

=head1 CONSTRUCTOR

    use Libs::Send;

    my $smtp = new Libs::Send(
        {
            host 	    => "smtp.domain.net",
            port        => 25,
            timeout	    => 30,
            debug 	    => 0,
            hello 	    => 'my.domain.net',
            ssl         => 0,   # 1/0
            starttls    => 0,   # 1/0
            authid      => 'username@domain.net',
            authpw      => 'password',
        }
    );

    $smtp->setFrom('username@domain.net');
    $smtp->setTo('username@domain.net');
    $smtp->setSubjectUTF8($subject);
    $smtp->setBodyPlainUTF8($body);
    my $result = $smtp->send(); # undef = OK, msg = Error    
    ...

    $smtp->setSubject($subject);
    $smtp->setSubjectUTF8($subject);
    $smtp->setSubjectUTF8toASCI($subject);

    # multi To
    $smtp->setTo('username1@domain.net');
    $smtp->setTo('username2@domain.net');

    # multi Cc
    $smtp->setCc('username1@domain.net');
    $smtp->setCc('username2@domain.net');

    # multi Bc
    $smtp->setBc('username1@domain.net');
    $smtp->setBc('username2@domain.net');

    # single replyTo
    $smtp->setReplyTo('username@domain.net');

    # single Return-Path
    $smtp->setReturnPath('username@domain.net');

    # single Errors-To
    $smtp->setErrorTo('username@domain.net');

    # custom body
    $smtp->setBody("Content-Type: text/plain; charset=UTF-8\n\n".$body);

    # multi body (alternative_body + body)
    $smtp->setBodyPlainUTF8($body1); # Alternative body is fist!
    $smtp->setBodyHtmlUTF8($body2);

    # multi attachments
    $smtp->setAttachment("/tmp/file1.txt");
    $smtp->setAttachment("/tmp/file2.txt");
    $smtp->setAttachment("/tmp/file3.txt");

=cut

=head2 B<[Public] new($conf)>

    Konstruktor odesilace e-mailu pres SMTP (Net::SMTP). Konfigurace: host, port (25), timeout (30),
    debug, hello (HELO jmeno; bez nej se pouzije host), ssl (1/0), starttls (1/0), authid, authpw.
    Konfigurace se typicky bere ze sekce conf <smtp_servers> (napr. smtp_primary).

=cut

sub new {
    my ($class, $conf) = @_;

    my $self = {
        debug    => (defined($conf->{'debug'})    ? $conf->{'debug'}    : 0),
        timeout  => (defined($conf->{'timeout'})  ? $conf->{'timeout'}  : 30),
        host     => (defined($conf->{'host'})     ? $conf->{'host'}     : "localhost"),
        port     => (defined($conf->{'port'})     ? $conf->{'port'}     : "25"),
        hello    => (defined($conf->{'hello'})    ? $conf->{'hello'}    : (defined($conf->{'host'}) ? $conf->{'host'} : "localhost.localdomain")),
        authid   => (defined($conf->{'authid'})   ? $conf->{'authid'}   : undef),
        authpw   => (defined($conf->{'authpw'})   ? $conf->{'authpw'}   : undef),
        ssl      => (defined($conf->{'ssl'})      ? $conf->{'ssl'}      : 0),
        starttls => (defined($conf->{'starttls'}) ? $conf->{'starttls'} : 0),
        from     => [],
        replyto  => [],
        rpath    => [],
        errto    => [],
        subject  => undef,
        to       => [],
        cc       => [],
        bcc      => [],
        body     => [],
        attachments => [],
    };

    bless $self, $class;
    return $self;
}

=head2 B<[Public] setSubject($subject)>

    Nastavi predmet bez kodovani (jen ASCII).

=cut

sub setSubject {
    my ($self, $subject) = @_;
    $self->{'subject'} = $subject if (defined($subject));
}

=head2 B<[Public] setSubjectUTF8($subject)>

    Nastavi predmet v UTF-8 zakodovany dle RFC 2047 (=?UTF-8?Q?...?=), pokud obsahuje ne-ASCII znaky.

=cut

sub setSubjectUTF8 {
    my ($self, $subject) = @_;
    $self->{'subject'} = $self->_encodeSubject($subject, 'UTF-8') if (defined($subject));
}

=head2 B<[Public] setSubjectUTF8toASCI($subject)>

    Nastavi predmet prevedeny z UTF-8 na ASCII bez diakritiky (Cz::Cstocs).

=cut

sub setSubjectUTF8toASCI {
    my ($self, $subject) = @_;
    $self->{'subject'} = utf8_ascii($subject) if (defined($subject));
}

=head2 B<[Public] setFrom($from)>

    Nastavi odesilatele (pouzije se prvni nastaveny).

=cut

sub setFrom {
    my ($self, $from) = @_;
    push(@{$self->{'from'}}, $from) if (defined($from));
}

=head2 B<[Public] setReturnPath($address)>

    Nastavi hlavicku Return-Path (prvni nastavena).

=cut

sub setReturnPath {
    my ($self, $rpath) = @_;
    push(@{$self->{'rpath'}}, $rpath) if (defined($rpath));
}

=head2 B<[Public] setErrorTo($address)>

    Nastavi hlavicku Errors-To (prvni nastavena).

=cut

sub setErrorTo {
    my ($self, $errto) = @_;
    push(@{$self->{'errto'}}, $errto) if (defined($errto));
}

=head2 B<[Public] setTo($to)>

    Prida prijemce (lze volat opakovane).

=cut

sub setTo {
    my ($self, $to) = @_;
    push(@{$self->{'to'}}, $to) if (defined($to));
}

=head2 B<[Public] setReplyTo($address)>

    Nastavi hlavicku Reply-To (prvni nastavena).

=cut

sub setReplyTo {
    my ($self, $replyto) = @_;
    push(@{$self->{'replyto'}}, $replyto) if (defined($replyto));
}

=head2 B<[Public] setCc($address)>

    Prida prijemce kopie (lze volat opakovane).

=cut

sub setCc {
    my ($self, $cc) = @_;
    push(@{$self->{'cc'}}, $cc) if (defined($cc));
}

=head2 B<[Public] setBcc($address)>

    Prida prijemce skryte kopie (lze volat opakovane).

=cut

sub setBcc {
    my ($self, $bcc) = @_;
    push(@{$self->{'bcc'}}, $bcc) if (defined($bcc));
}

=head2 B<[Public] setBody($body)>

    Prida telo zpravy vcetne vlastnich MIME hlavicek (napr. "Content-Type: text/plain; charset=UTF-8\n\nText").
    Vice tel = multipart/alternative (prvni je alternativni, posledni preferovane).

=cut

sub setBody {
    my ($self, $body) = @_;
    push(@{$self->{'body'}}, $body) if (defined($body));
}

=head2 B<[Public] setBodyPlainUTF8($text)>

    Prida textove telo v UTF-8 (quoted-printable) s hlavickami.

=cut

sub setBodyPlainUTF8 {
    my ($self, $body) = @_;
    if (defined($body)) {
        $body = "Content-Type: text/plain; charset=UTF-8\n" . "Content-Transfer-Encoding: quoted-printable\n\n" . MIME::QuotedPrint::encode($body);
        #$body = "Content-Type: text/plain; charset=UTF-8\n" . "Content-Transfer-Encoding: quoted-printable\n" . "Content-Transfer-Encoding: 8bit\n\n" . $body;
        push(@{$self->{'body'}}, $body);
    }
}

=head2 B<[Public] setBodyHtmlUTF8($html)>

    Prida HTML telo v UTF-8 (quoted-printable) s hlavickami.

=cut

sub setBodyHtmlUTF8 {
    my ($self, $body) = @_;
    if (defined($body)) {
        $body = "Content-Type: text/html; charset=UTF-8\n" . "Content-Transfer-Encoding: quoted-printable\n\n" . MIME::QuotedPrint::encode($body);
        #$body = "Content-Type: text/html; charset=UTF-8\n" . "Content-Transfer-Encoding: quoted-printable\n" . "Content-Transfer-Encoding: 8bit\n\n" . $body;
        push(@{$self->{'body'}}, $body);
    }
}

=head2 B<[Public] setAttachment($path)>

    Prida prilohu (cesta k souboru; MIME typ se odhadne z pripony). Lze volat opakovane.

=cut

sub setAttachment {
    my ($self, $attachment) = @_;
    push(@{$self->{'attachments'}}, $attachment) if (defined($attachment));
}

=head2 B<[Public] send()>

    Odesle zpravu. Overi adresy a povinne From/To, pripoji se k SMTP (volitelne STARTTLS, AUTH),
    posle hlavicky, tela (multipart/alternative) a prilohy (multipart/mixed, base64).
    Vraci undef pri uspechu, jinak text chyby (nikdy die).

=cut

sub send {
    my $self = shift;

    my $invalid_email = $self->_findInvalidEmail();
    return "Invalid email address " . $invalid_email if (defined($invalid_email));
    return "SMTP From address is required to send a message!" unless (defined($self->{'from'}[0]));
    return "SMTP To address is required to send a message!"   unless (defined($self->{'to'}[0]));

    my $smtp = Net::SMTP->new(
        $self->{'host'},
        SSL     => $self->{'ssl'},
        Port    => $self->{'port'},
        Hello   => $self->{'hello'},
        Timeout => $self->{'timeout'},
        Debug   => $self->{'debug'},
    ) or return "Could not connect to SMTP host: $self->{'host'}, port: $self->{'port'}";

    # STARTTLS (vyzaduje IO::Socket::SSL), zapina se volbou starttls => 1
    if ($self->{'starttls'}) {
        $smtp->starttls() or return "STARTTLS failed: " . $smtp->message();
    }

    # Authenticate
    if ($self->{'authid'}) {
        $smtp->auth($self->{'authid'}, $self->{'authpw'}) or return $smtp->message();
    }

    # Create arbitrary boundary text used to seperate
    # different parts of the message
    my $boundry1 = ((@{$self->{'body'}} > 1 or @{$self->{'attachments'}} >= 1) ? $self->_boundry() : undef);
    my $boundry2 = ((@{$self->{'body'}} > 1) ? $self->_boundry() : undef);

    # SEND THE HEADER

    # FROM
    $smtp->mail($self->{'from'}[0] . "\n") or return $smtp->message();

    # TO
    foreach my $recp (@{$self->{'to'}}) {
        $smtp->to($recp . "\n") or return $smtp->message();
    }

    # CC
    foreach my $recp (@{$self->{'cc'}}) {
        $smtp->cc($recp . "\n") or return $smtp->message();
    }

    # BC
    foreach my $recp (@{$self->{'bcc'}}) {
        $smtp->bcc($recp . "\n") or return $smtp->message();
    }

    # SEND THE BODY
    $smtp->data()                                                                  or return $smtp->message();
    $smtp->datasend("Date: " . $self->_dateAndTime() . "\n")                       or return $smtp->message();
    $smtp->datasend("Message-ID: " . $self->_messageID($self->{'from'}[0]) . "\n") or return $smtp->message();
    $smtp->datasend("From: " . $self->{'from'}[0] . "\n")                          or return $smtp->message();
    $smtp->datasend("To: " . join(',', @{$self->{'to'}}) . "\n") or return $smtp->message();

    if (defined($self->{'cc'}[0])) {
        $smtp->datasend("Cc: " . join(',', @{$self->{'cc'}}) . "\n") or return $smtp->message();
    }

    if (defined($self->{'replyto'}[0])) {
        $smtp->datasend("Reply-To: $self->{'replyto'}[0]\n") or return $smtp->message();
    }

    if (defined($self->{'rpath'}[0])) {
        $smtp->datasend("Return-Path: $self->{'rpath'}[0]\n") or return $smtp->message();
    }

    if (defined($self->{'errto'}[0])) {
        $smtp->datasend("Errors-To: $self->{'errto'}[0]\n") or return $smtp->message();
    }

    $smtp->datasend("Subject: " . $self->{'subject'} . "\n") or return $smtp->message();

    # SEND BOUNDARY FIRST HEADER
    if ($boundry1) {
        $smtp->datasend("MIME-Version: 1.0\n")                                     or return $smtp->message();
        $smtp->datasend("Content-Type: multipart/mixed; BOUNDARY=\"$boundry1\"\n") or return $smtp->message();
        $smtp->datasend("\n--$boundry1\n")                                         or return $smtp->message();
    }

    # Send Multi BODY
    if ($boundry2) {
        $smtp->datasend("Content-Type: multipart/alternative; BOUNDARY=\"$boundry2\"\n") or return $smtp->message();
        foreach my $body (@{$self->{'body'}}) {
            $smtp->datasend("\n--$boundry2\n") or return $smtp->message();
            $smtp->datasend($body)             or return $smtp->message();
            $smtp->datasend("\n\n")            or return $smtp->message();
        }
        $smtp->datasend("\n--$boundry2--\n") or return $smtp->message();
    } else {
        foreach my $body (@{$self->{'body'}}) {
            $smtp->datasend($body)  or return $smtp->message();
            $smtp->datasend("\n\n") or return $smtp->message();
        }
    }

    # Send attachments
    foreach my $file (@{$self->{'attachments'}}) {

        return "Attachment '$file' does not exist!" unless (-f $file);

        # Get the file name without its directory
        my ($volume, $dir, $fileName) = File::Spec->splitpath($file);

        # Try and guess the MIME type from the file extension so
        # that the email client doesn't have to
        my $contentType = guess_media_type($file);

        $smtp->datasend("--$boundry1\n")                                                   or return $smtp->message();
        $smtp->datasend("Content-Type: $contentType; charset=UTF-8; name=\"$fileName\"\n") or return $smtp->message();
        $smtp->datasend("Content-Transfer-Encoding: base64\n")                             or return $smtp->message();
        $smtp->datasend("Content-Disposition: attachment; filename=\"$fileName\"\n\n")     or return $smtp->message();

        my $bufer;
        open(FILE, $file) or return "$!";
        while (read(FILE, $bufer, 60 * 57)) {
            $smtp->datasend(encode_base64($bufer)) or return $smtp->message();
        }
        close(FILE);
        $smtp->datasend("\n\n") or return $smtp->message();
    }

    # Quit
    if ($boundry1) {
        $smtp->datasend("\n--$boundry1--\n") or return $smtp->message();    # send boundary end message
    }
    $smtp->datasend("\n\n") or return $smtp->message();
    $smtp->dataend()        or return $smtp->message();
    $smtp->quit()           or return $smtp->message();

    return undef;
}

=head2 B<[Private] _boundry()>

    Vygeneruje nahodny MIME boundary retezec (29 alfanumerickych znaku).

=cut

sub _boundry {
    my ($bi, $bn, @bchrs);
    my $boundry = "";
    foreach $bn (48 .. 57, 65 .. 90, 97 .. 122) {
        $bchrs[$bi++] = chr($bn);
    }
    foreach $bn (0 .. 28) {
        $boundry .= $bchrs[rand($bi)];
    }
    return lc($boundry);
}

=head2 B<[Private] _dateAndTime()>

    Vraci aktualni cas ve formatu hlavicky Date (RFC 2822) vcetne posunu zony.

=cut

sub _dateAndTime {
    my $self  = shift;
    my $local = time;
    my $gm    = timelocal(gmtime $local);
    my $sign  = qw( + + - ) [$local <=> $gm];
    my $gmt   = sprintf "%s%02d%02d", $sign, (gmtime abs($local - $gm))[2, 1];
    my $date  = localtime();
    $date =~ s/^(\w+)\s+(\w+)\s+(\d+)\s+(\d+:\d+:\d+)\s+(\d+)$/$1, $3 $2 $5 $4/;
    return "$date $gmt";
}

=head2 B<[Private] _messageID($from)>

    Vygeneruje unikatni Message-ID ve tvaru <YYYYMMDD_HHMMSS_random.adresa>.

=cut

sub _messageID {
    my ($self, $from) = @_;
    $from =~ s/.*<//;
    $from =~ s/>.*//;
    my ($sec, $min, $hour, $mday, $mon, $year) = gmtime(time);
    $mon++;
    $year += 1900;
    return sprintf "<%04d%02d%02d_%02d%02d%02d_%06d.%s>", $year, $mon, $mday, $hour, $min, $sec, rand(100000), $from;
}

=head2 B<[Private] _encodeSubject($str,$encoding)>

    Zakoduje predmet dle RFC 2047 (Q-encoding po castech), ASCII retezec vraci beze zmeny.

=cut

sub _encodeSubject {
    my ($self, $str, $enc) = @_;
    return $str unless $str =~ /[[:^ascii:]]/;
    my @parts;
    while ($str =~ /(.{1,40}.*?(?:\s|$))/g) {
        my $part = $1;
        my $encode = MIME::QuotedPrint::encode($part, '');
        $encode =~ s/\s/_/g;
        push (@parts, $encode);
    }
    return join "\r\n\t", map { "=?$enc?Q?$_?=" } @parts;
}

=head2 B<[Private] _findInvalidEmail()>

    Projde vsechny nastavene adresy (from, to, replyto, cc, bcc, errto, rpath) a vrati prvni
    neplatnou, nebo undef.

=cut

sub _findInvalidEmail {
    my $self = shift;

    # Validate email
    foreach my $src (qw(from to replyto cc bcc errto rpath)) {
        foreach my $email (@{$self->{$src}}) { return $email unless ($self->_validEmail($email)); }
    }

    return undef;
}

=head2 B<[Private] _validEmail($email)>

    Vraci 1 pokud je adresa platna (povolen i tvar "Jmeno <adresa>"), jinak undef.

=cut

sub _validEmail {
    my ($self, $email) = @_;
    $email =~ s/.*<//;
    $email =~ s/>.*//;
    return undef if (!Mail::RFC822::Address::valid($email));
    return undef if ($email !~ /^[_a-zA-Z0-9\.\-\+]+@[a-zA-Z0-9\.\-]+\.[a-zA-Z]{2,}$/);
    return 1;
}

1;
