package Services::Session::Session;

use strict;
our ($AUTOLOAD);

my($CONF,$LOG,$VALIDATE,$DBI,$ENTITIES,$USER,$WEB);

sub new {
    my ($class,$conf,$log,$validate,$dbi,$entities,$user,$web) = @_;

    $DBI  = $dbi;
    $LOG  = $log;
    $WEB  = $web;
    $CONF = $conf;
    $USER = $user;
    $VALIDATE = $validate;
    $ENTITIES = $entities;
    
    my $self = {
        'session' => {
            # Data seved in the database.
        }
    };
        
    bless $self,$class;
    return $self;
}

sub newSession {
    my $self = shift;

    my $sid    = $USER->getSid;
    my $ip     = $USER->getIP;
    my $who    = $USER->getValue("env", "HTTP_USER_AGENT", "UNKNOWN");
    my $expire = (time() + ((3600 * 24) * $CONF->getValue("http", "cookie_expire_guest", 100)));

    while (1) {
        
        my $SESSION = $ENTITIES->createEntityObject('Session', {'where' => "sid = ?", 'conds' => [$sid]});

        if (!$SESSION->expire()) {
            # NEW SESSION
            $SESSION->sid($sid);
            $SESSION->expire($expire);
        } elsif ($SESSION->expire() < time()) {
            # OLD SESSION
            $SESSION->DELETE_ROW;
            $SESSION->logit;
            if ($SESSION->error()) {
                $SESSION->rollback;
            } else {
                $SESSION->commit;
            }
            next;
        }

        $SESSION->ipaddres($ip);
        $SESSION->useragent($who);
        $SESSION->flush;
        $SESSION->logit;

        if ($SESSION->error()) {
            $SESSION->rollback;
        } else {
            # SET VALUE FROM DB
            $self->{'session'} = $SESSION->getMirroredData();
            $SESSION->commit;
        }

        last;
    }                    
    
    # SET NEW VALUE FROM BROWSER
    $self->setValue('ipaddres',$ip);
    $self->setValue('useragent',$who);
    
    # SET LANG TO USER OBJECT
    my $def_lang = $CONF->getValue("web", "def_language", "EN");
    $USER->setLanguage($self->getValue('lang',$def_lang));
    
    return $self->{'session'};
}

=head2 B<[Public] getValue($key,$defvalue)>

    Metoda vrati pozadovany atribut z session objektu.

=cut

sub getValue {
    my ($self,$key,$def) = @_;
    return $def unless(exists($self->{'session'}->{$key}));
    return $self->{'session'}->{$key};
}

=head2 B<[Public] setValue($key,$value)>

    Metoda zapise do databaze (na konci relace pri flushi) hodnoty sessiony

=cut

sub setValue {
    my ($self,$key,$value) = @_;
    $self->{'session'}->{$key} = $value;
}

=head2 B<[Public] existKey($key)>

    Metoda vrati 1/0 podle toho zdali zadany atribut existuje nebo ne.

=cut

sub existKey {
    my ($self,$key) = @_;
    return undef unless(exists($self->{'session'}->{$key}));
    return 1;
}

=head2 B<[Public] existKeyValue($key)>

    Metoda vrati 1/0 podle toho zdali zadany atribut existuje nebo ne a zarovne neni prazdny.

=cut

sub existKeyValue {
    my ($self,$key) = @_;
    return undef unless($self->existKey($key));
    return undef unless(defined($self->{'session'}->{$key}));
    return 1;
}

sub flush {
    my $self = shift;

    my $sid = $USER->getSid();
    
    my $SESSION = $ENTITIES->createEntityObject('Session', {'where' => "sid = ?", 'conds' => [$sid]});

    # Save to db    
    foreach my $key (keys %{$self->{'session'}}) {
        $SESSION->$key($self->getValue($key));
    }

    $SESSION->logit;
    $SESSION->flush;
    if ($SESSION->error()) {
        $SESSION->rollback;
    } else {
        $SESSION->commit;
    }

    # CLEAR OBJ.DATA
    delete $self->{'session'};
}

sub AUTOLOAD {
    my $self = shift;
    my $name = $AUTOLOAD;
    $name =~ s/.*://;
    return if ($name =~ /^DESTROY$/);
    return $USER->$name(@_);
}

1;