package Services::UserAccount::UserAccount;

=head1 NAME

Services::UserAccount::UserAccount - ukazkova sluzba uctu nad Services::Session (vsem prideli skupinu admin)

=cut

use strict;
our ($AUTOLOAD);

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB,$SESSION);

=head2 B<[Public] new($conf,$log,$validate,$dbi,$entities,$user,$web)>

    Ukazkova sluzba uzivatelskeho uctu nad Services::Session. V kazdem requestu nacte session
    a vsem navstevnikum prideli skupinu 'admin' (jen pro example weby - realna aplikace zde
    resi prihlaseni a role). Do stranek se injektuje metodou Service_UserAccount.

=cut

sub new {
    my ($class, $conf, $log, $validate, $dbi, $entities, $user, $web) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $USER     = $user;
    $WEB      = $web;
    $CONF     = $conf;
    $VALIDATE = $validate;
    $ENTITIES = $entities;

    my $self = { 'session' => {}, 'account' => {}, 'group' => {} };

    bless $self, $class;
    return $self;
}

=head2 B<[Private] Service_Session($service)>

    Injektaz sluzby Session (vola loader).

=cut

sub Service_Session {
    my ($self,$input) = @_;
    $SESSION = $input;
}

=head2 B<[Public] newRequest()>

    Zacatek requestu: nacte session (Services::Session::newSession), vynuluje ucet, odebere
    skupinu 'guest' a prida 'admin'.

=cut

sub newRequest {
    my $self = shift;
    
    # Session informace (sid, ip, webagent, atd...)
    $self->{'session'} = $SESSION->newSession();
    
    # Informace o uzivateli (email,login, adresa atd...)
    $self->{'account'} = {};
    
    # GROUP = ADMIN (HACK, PRO SPRAVNE FUNGOVANI VSECH STRANEK)
    # Jedna se pouze o example web, takze na prava si tu nehrajeme...
    $self->{'group'}->{'admin'} = 1;

    # CLEAR DEFAULT GROUPS
    $USER->deleteGroup('guest');

    # SET ADMIN GROUP
    $USER->addGroup('admin');
}

=head2 B<[Public] setLanguage($lang)>

    Nastavi jazyk uzivatele do session (perzistentne) i do $USER pro aktualni request.

=cut

sub setLanguage {
    my ($self,$lang) = @_;
    $SESSION->setValue('lang',$lang);
    $USER->setLanguage($lang);
}

=head2 B<[Public] getSession()>

    Vraci hash dat session (sid, ipaddres, useragent, lang, expire, ...).

=cut

sub getSession {
    my $self = shift;
    return $self->{'session'};
}

=head2 B<[Public] getAccount()>

    Vraci hash dat uctu (v example implementaci prazdny).

=cut

sub getAccount {
    my $self = shift;
    return $self->{'account'};
}

=head2 B<[Private] getAccountValue($key,$def)>

    Vraci hodnotu atributu $key z informaci o uctu uzivatele (viz getAccount: login, uid,
    email atd.; v teto ukazkove implementaci je ucet prazdny). Pokud atribut neexistuje
    nebo ma prazdnou hodnotu (false), vraci $def.

=cut

sub getAccountValue {
    my ($self, $key, $def) = @_;
    my $account = $self->getAccount();
    return $def unless (exists($account->{$key}));
    return $def unless ($account->{$key});
    return $account->{$key};
}

=head2 B<[Public] getGroup()>

    Vraci hash skupin uzivatele podle teto sluzby.

=cut

sub getGroup {
    my $self = shift;
    return $self->{'group'};
}

=head2 B<[Public] flush()>

    Konec requestu: vynuluje session, ucet a skupiny v objektu.

=cut

sub flush {
    my $self = shift;
    # Clear data
    $self->{'group'} = {};
    $self->{'session'} = {};
    $self->{'account'} = {};
}

=head2 B<[Private] AUTOLOAD(...)>

    Nezname metody deleguje na sluzbu Session (a ta dale na Libs::User) - stranka tak muze
    pouzivat $USER = injektovany UserAccount se stejnym API jako Libs::User.

=cut

sub AUTOLOAD {
    my $self = shift;
    my $name = $AUTOLOAD;
    $name =~ s/.*://;
    return if ($name =~ /^DESTROY$/);
    return $SESSION->$name(@_);
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
    require Libs::Entities;
    require Libs::User;
    require Libs::Web;
    require Services::Session::Session;

    $CONF     = new Libs::Config;
    $LOG      = new Libs::Log;
    $VALIDATE = new Libs::Validate;
    $DBI      = new Libs::DBI;
    $ENTITIES = new Libs::Entities;
    $USER     = new Libs::User;
    $WEB      = new Libs::Web;
    $SESSION  = new Services::Session::Session;
}

1;