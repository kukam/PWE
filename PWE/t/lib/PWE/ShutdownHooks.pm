package PWE::ShutdownHooks;

=head1 NAME

PWE::ShutdownHooks - zasahy do enginu jen pro testy ukoncovani (t/24-shutdown.t)

=head1 POPIS

    Modul se nacita do procesu serveru volbou perlu (pred spustenim pwe.fcgi):

        perl -I<engine> -I<engine>/t/lib -MPWE::ShutdownHooks <engine>/pwe.fcgi

    a podle promennych prostredi obali metody enginu tak, aby test mohl server zastihnout
    v presne danem stavu. Promenne se ctou hned pri nacteni modulu (FastCGI behem requestu
    obsah %ENV vymeni). Bez nich modul nedela nic.

      PWE_TEST_HOOK_DIR             adresar pro znacky (prazdne soubory), kterymi si test a server
                                    davaji vedet o udalostech; povinny pro vse nize
      PWE_TEST_STARTUP=wait         zdrzi start: pred vznikem Libs::MyDBI zalozi znacku
                                    startup.waiting a ceka na znacku startup.release, pak start
                                    dobehne
      PWE_TEST_STARTUP=stop         jako Libs::MyDBI cekajici na databazi: zalozi startup.waiting,
                                    ceka na Libs::MyDBI::stopRequested() a pak skonci vyjimkou
                                    "Startup interrupted by termination request" (kontrakt mezi
                                    Libs::MyDBI a pwe.fcgi)
      PWE_TEST_FAKE_DB=1            do Libs::MyDBI prida spojeni 'tdb' (PWE::ShutdownHooks::Conn):
                                    ping vraci, zda je jeste pripojene, disconnect zalozi znacku
                                    db.disconnected
      PWE_TEST_TERM_BEFORE_ACCEPT=1 po prvnim obslouzenem requestu posle server sam sobe signal
                                    TERM tesne pred tim, nez znovu zacne cekat na request (znacka
                                    term.sent) - signal tedy cekani neprerusi, prisel pred nim
      PWE_TEST_BODY_MARK=1          pred ctenim tela requestu (CGI::read_from_client) zalozi znacku
                                    body.reading - test pak vi, ze server ceka na telo POST
      PWE_TEST_USR2=1               handler signalu USR2, ktery jen zalozi znacku usr2.handled
                                    (signal, ktery engine ukoncit nema - jako handler ve strance
                                    nebo sluzbe webu)

=cut

use strict;
use warnings;

my $DIR     = $ENV{'PWE_TEST_HOOK_DIR'};
my $STARTUP = $ENV{'PWE_TEST_STARTUP'} || '';
my $FAKE_DB = $ENV{'PWE_TEST_FAKE_DB'};
my $TERM    = $ENV{'PWE_TEST_TERM_BEFORE_ACCEPT'};
my $USR2    = $ENV{'PWE_TEST_USR2'};
my $BODY    = $ENV{'PWE_TEST_BODY_MARK'};

=head2 B<[Private] mark($nazev)>

    Zalozi znacku: prazdny soubor $nazev v adresari PWE_TEST_HOOK_DIR.

=cut

sub mark {
    my ($name) = @_;
    open(my $fh, '>>', "$DIR/$name") or return 0;
    close($fh);
    return 1;
}

=head2 B<[Private] wait_until($podminka,$sekundy)>

    Ceka, az funkce $podminka vrati pravdu (zkousi ji po 20 ms), nejdele $sekundy. Signal cekani
    neukonci. Vraci 1 = splneno, 0 = cas vyprsel.

=cut

sub wait_until {
    my ($cond, $sec) = @_;
    my $end = time + $sec;
    until ($cond->()) {
        return 0 if (time > $end);
        select(undef, undef, undef, 0.02);
    }
    return 1;
}

if (defined($DIR) and ($STARTUP or $FAKE_DB)) {
    require Libs::MyDBI;
    my $new = \&Libs::MyDBI::new;
    no warnings 'redefine';
    *Libs::MyDBI::new = sub {
        if ($STARTUP) {
            mark('startup.waiting');
            if ($STARTUP eq 'stop') {
                my $stop = sub { return (Libs::MyDBI->can('stopRequested') and Libs::MyDBI::stopRequested()) ? 1 : 0; };
                wait_until($stop, 30);
                die "Startup interrupted by termination request\n" if ($stop->());
            } else {
                wait_until(sub { -e "$DIR/startup.release" }, 30);
            }
        }
        my $self = $new->(@_);
        $self->{'DBC'}->{'tdb'} = {0 => PWE::ShutdownHooks::Conn->new()} if ($FAKE_DB);
        return $self;
    };
}

if (defined($DIR) and $TERM) {
    require CGI::Fast;
    my $new = \&CGI::Fast::new;
    my ($served, $sent) = (0, 0);
    no warnings 'redefine';
    *CGI::Fast::new = sub {
        if ($served and !$sent) {
            $sent = 1;
            mark('term.sent');
            kill('TERM', $$);
        }
        my $cgi = $new->(@_);
        $served++ if (defined($cgi));
        return $cgi;
    };
}

if (defined($DIR) and $BODY) {
    require CGI;
    my $read = \&CGI::read_from_client;
    no warnings 'redefine';
    *CGI::read_from_client = sub { mark('body.reading'); goto &$read; };
}

$SIG{'USR2'} = sub { mark('usr2.handled'); } if (defined($DIR) and $USR2);

package PWE::ShutdownHooks::Conn;

=head2 B<[Private] PWE::ShutdownHooks::Conn::new()>

    Nahrada objektu spojeni (driveru) v poolu Libs::MyDBI: zna jen ping a disconnect.

=cut

sub new {
    my ($class) = @_;
    return bless {'connected' => 1}, $class;
}

=head2 B<[Private] PWE::ShutdownHooks::Conn::ping()>

    Vraci 1, dokud spojeni nikdo neodpojil, pak 0.

=cut

sub ping {
    my ($self) = @_;
    return $self->{'connected'};
}

=head2 B<[Private] PWE::ShutdownHooks::Conn::disconnect()>

    Odpoji spojeni a zalozi znacku db.disconnected (test podle ni pozna, kdy engine databazi
    odpojil).

=cut

sub disconnect {
    my ($self) = @_;
    $self->{'connected'} = 0;
    PWE::ShutdownHooks::mark('db.disconnected');
    return 1;
}

1;
