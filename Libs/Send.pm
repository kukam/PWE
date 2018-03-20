package Libs::Send;

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

sub new {
    my ($class, $conf) = @_;

    my $self = {
        debug    => (defined($conf->{'debug'})    ? $conf->{'debug'}    : 0),
        timeout  => (defined($conf->{'timeout'})  ? $conf->{'timeout'}  : 30),
        host     => (defined($conf->{'host'})     ? $conf->{'host'}     : "localhost"),
        port     => (defined($conf->{'port'})     ? $conf->{'port'}     : "25"),
        hello    => (defined($conf->{'host'})     ? $conf->{'host'}     : "localhost.localdomain"),
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

sub setSubject {
    my ($self, $subject) = @_;
    $self->{'subject'} = $subject if (defined($subject));
}

sub setSubjectUTF8 {
    my ($self, $subject) = @_;
    $self->{'subject'} = $self->_mimeencode($subject, 'UTF-8') if (defined($subject));
}

sub setSubjectUTF8toASCI {
    my ($self, $subject) = @_;
    $self->{'subject'} = utf8_ascii($subject) if (defined($subject));
}

sub setFrom {
    my ($self, $from) = @_;
    push(@{$self->{'from'}}, $from) if (defined($from));
}

sub setReturnPath {
    my ($self, $rpath) = @_;
    push(@{$self->{'rpath'}}, $rpath) if (defined($rpath));
}

sub setErrorTo {
    my ($self, $errto) = @_;
    push(@{$self->{'errto'}}, $errto) if (defined($errto));
}

sub setTo {
    my ($self, $to) = @_;
    push(@{$self->{'to'}}, $to) if (defined($to));
}

sub setReplyTo {
    my ($self, $replyto) = @_;
    push(@{$self->{'replyto'}}, $replyto) if (defined($replyto));
}

sub setCc {
    my ($self, $cc) = @_;
    push(@{$self->{'cc'}}, $cc) if (defined($cc));
}

sub setBcc {
    my ($self, $bcc) = @_;
    push(@{$self->{'bcc'}}, $bcc) if (defined($bcc));
}

sub setBody {
    my ($self, $body) = @_;
    push(@{$self->{'body'}}, $body) if (defined($body));
}

sub setBodyPlainUTF8 {
    my ($self, $body) = @_;
    if (defined($body)) {
        $body = "Content-Type: text/plain; charset=UTF-8\n" . "Content-Transfer-Encoding: quoted-printable\n" . "Content-Transfer-Encoding: 8bit\n\n" . $body;
        push(@{$self->{'body'}}, $body);
    }
}

sub setBodyHtmlUTF8 {
    my ($self, $body) = @_;
    if (defined($body)) {
        $body = "Content-Type: text/html; charset=UTF-8\n" . "Content-Transfer-Encoding: quoted-printable\n" . "Content-Transfer-Encoding: 8bit\n\n" . $body;
        push(@{$self->{'body'}}, $body);
    }
}

sub setAttachment {
    my ($self, $attachment) = @_;
    push(@{$self->{'attachments'}}, $attachment) if (defined($attachment));
}

sub send {
    my $self = shift;

    return "Invalid email address " . $self->_findInvalidEmail() if (defined($self->_findInvalidEmail()));
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

sub _messageID {
    my ($self, $from) = @_;
    $from =~ s/.*<//;
    $from =~ s/>.*//;
    my ($sec, $min, $hour, $mday, $mon, $year) = gmtime(time);
    $mon++;
    $year += 1900;
    return sprintf "<%04d%02d%02d_%02d%02d%02d_%06d.%s>", $year, $mon, $mday, $hour, $min, $sec, rand(100000), $from;
}

sub _mimeencode {
    my ($self, $str, $enc) = @_;
    return $str unless $str =~ /[[:^ascii:]]/;
    my @parts;
    while ($str =~ /(.{1,40}.*?(?:\s|$))/g) {
        my $part = $1;
        push @parts, MIME::QuotedPrint::encode($part, '');
    }
    return join "\r\n\t", map { "=?$enc?Q?$_?=" } @parts;
}

sub _findInvalidEmail {
    my $self = shift;

    # Validate email
    foreach my $src (qw(from to replyto cc bcc errto rpath)) {
        foreach my $email (@{$self->{$src}}) { return $email unless ($self->_validEmail($email)); }
    }

    return undef;
}

sub _validEmail {
    my ($self, $email) = @_;
    $email =~ s/.*<//;
    $email =~ s/>.*//;
    return undef if (!Mail::RFC822::Address::valid($email));
    return undef if ($email !~ /^[_a-zA-Z0-9\.\-]+@[a-zA-Z0-9\.\-]+\.[a-zA-Z]{2,4}$/);
    return 1;
}

1;
