package Services::UserAccount::UserAccount;

use strict;
our ($AUTOLOAD);

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB,$SESSION);

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

sub Service_Session {
    my ($self,$input) = @_;
    $SESSION = $input;
}

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

sub setLanguage {
    my ($self,$lang) = @_;
    $SESSION->setValue('lang',$lang);
    $USER->setLanguage($lang);
}

sub getSession {
    my $self = shift;
    return $self->{'session'};
}

=head2 B<[Private] getSessionValue($key,$def)>

    Metoda vraci obsah atributu ($key), pokud atribut neexistuje
    vraci metoda hodnotu $def. Metoda prohledava v informacich o uzivateli.
    (login,uid,email,atd...)
    
=cut

sub getSessionValue {
    my ($self, $key, $def) = @_;
    my $session = $self->getSession();
    return $def unless (exists($session->{$key}));
    return $def unless ($session->{$key});
    return $session->{$key};
}

sub getAccount {
    my $self = shift;
    return $self->{'account'};
}

=head2 B<[Private] getAccountValue($key,$def)>

    Metoda vraci obsah atributu ($key), pokud atribut neexistuje
    vraci metoda hodnotu $def. Metoda prohledava v informacich o uzivateli.
    (login,uid,email,atd...)
    
=cut

sub getAccountValue {
    my ($self, $key, $def) = @_;
    my $account = $self->getAccount();
    return $def unless (exists($account->{$key}));
    return $def unless ($account->{$key});
    return $account->{$key};
}

sub getGroup {
    my $self = shift;
    return $self->{'group'};
}

=head2 B<[Private] getGroupValue($key,$def)>

    Metoda vraci obsah atributu ($key), pokud atribut neexistuje
    vraci metoda hodnotu $def. Metoda prohledava v informacich o uzivateli.
    (login,uid,email,atd...)
    
=cut

sub getGroupValue {
    my ($self, $key, $def) = @_;
    my $group = $self->getGroup();
    return $def unless (exists($group->{$key}));
    return $def unless ($group->{$key});
    return $group->{$key};
}

sub flush {
    my $self = shift;
    # Clear data
    $self->{'group'} = {};
    $self->{'session'} = {};
    $self->{'account'} = {};
}

sub AUTOLOAD {
    my $self = shift;
    my $name = $AUTOLOAD;
    $name =~ s/.*://;
    return if ($name =~ /^DESTROY$/);
    return $SESSION->$name(@_);
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