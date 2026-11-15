package Services::Session::Session;

=head1 NAME

Services::Session::Session - DB session uzivatele (tabulka session): nacteni v newSession, ulozeni ve flush

=cut

use strict;
our ($AUTOLOAD);

my($CONF,$LOG,$VALIDATE,$DBI,$ENTITIES,$USER,$WEB);

=head2 B<[Public] new($conf,$log,$validate,$dbi,$entities,$user,$web)>

    Sluzba DB session (tabulka session pres entitu Session). Drzi data session aktualniho
    requestu v $self->{'session'}; na konci requestu je flush() zapise do DB. Vyzaduje databazi -
    pro weby bez DB se nepouziva (opts se ukladaji do souboru pres Libs::User).

=cut

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
            # Via Entities::Session
        },
        'new_count' => 0,    # pocet novych session zalozenych timto procesem (cleanupExpired)
    };
        
    bless $self,$class;
    return $self;
}

=head2 B<[Public] newSession()>

    Nacte (nebo zalozi) session podle sid z cookie; expirovanou session smaze a zalozi novou.
    Pri zalozeni nove session prilezitostne uklidi expirovane radky cele tabulky (cleanupExpired).
    Aktualizuje IP a User-Agent, nastavi jazyk uzivatele z DB ($USER->setLanguage) a vrati hash
    dat session. Vola Services::UserAccount::newRequest.

=cut

sub newSession {
    my $self = shift;

    my $sid    = $USER->getSid;
    my $ip     = $USER->getIP;
    my $who    = $USER->getValue("env", "HTTP_USER_AGENT", "UNKNOWN");
    my $expire = (time() + ((3600 * 24) * $CONF->getValue("http", "cookie_expire_guest", 100)));

    while (1) {
        
        my $SESSION = $ENTITIES->createEntityObject('Session', {'where' => "sid = ?", 'conds' => [$sid]});

        if (!$SESSION->expire()) {
            # NEW SESSION (nejdrive prilezitostny uklid expirovanych radku, drive je nikdo nemazal)
            $self->cleanupExpired($SESSION);
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

        # entitu si nechame do konce requestu - flush() ji pouzije misto noveho SELECTu
        $self->{'dao'} = $SESSION;

        last;
    }
    
    # SET NEW VALUE FROM BROWSER
    $self->setValue('ipaddres',$ip);
    $self->setValue('useragent',$who);
    
    # SET LANG TO USER OBJECT
    $USER->setLanguage($self->getValue('lang'));
    
    return $self->{'session'};
}

=head2 B<[Public] getValue($key,$defvalue)>

    Vrati hodnotu atributu $key z dat session aktualniho requestu (sid, ipaddres, useragent,
    lang, messenger, expire, ...). Pokud atribut neexistuje, vrati $defvalue.

=cut

sub getValue {
    my ($self,$key,$def) = @_;
    return $def unless(exists($self->{'session'}->{$key}));
    return $self->{'session'}->{$key};
}

=head2 B<[Public] setValue($key,$value)>

    Nastavi hodnotu atributu $key v datech session. Do databaze (tabulka session) se hodnoty
    zapisou az na konci requestu v metode flush(); $key proto musi byt sloupec teto tabulky
    (jiny klic skonci pri flushi chybou v logu).

=cut

sub setValue {
    my ($self,$key,$value) = @_;
    $self->{'session'}->{$key} = $value;
}

=head2 B<[Public] existKey($key)>

    Vrati 1, pokud atribut $key v datech session existuje (i s hodnotou undef), jinak undef.

=cut

sub existKey {
    my ($self,$key) = @_;
    return undef unless(exists($self->{'session'}->{$key}));
    return 1;
}

=head2 B<[Public] existKeyValue($key)>

    Vrati 1, pokud atribut $key v datech session existuje a zaroven ma definovanou hodnotu
    (neni undef), jinak undef.

=cut

sub existKeyValue {
    my ($self,$key) = @_;
    return undef unless($self->existKey($key));
    return undef unless(defined($self->{'session'}->{$key}));
    return 1;
}

=head2 B<[Public] flush()>

    Konec requestu (vola Libs::Services): zapise zmenene hodnoty session do DB. Pouzije entitu
    nactenou v newSession (zadny dalsi SELECT); UPDATE a commit se provede jen tehdy, kdyz se
    nejaka hodnota zmenila. Bez newSession a bez dat nedela nic. Data session v objektu vymaze.

=cut

sub flush {
    my $self = shift;

    my $SESSION = delete $self->{'dao'};

    # bez newSession a bez dat neni co ukladat
    unless ($SESSION or (ref($self->{'session'}) eq 'HASH' and %{$self->{'session'}})) {
        delete $self->{'session'};
        return;
    }

    # bez newSession (nebo po jejim padu) si entitu nacteme ted
    my $fresh = 0;
    unless ($SESSION) {
        my $sid = $USER->getSid();
        $SESSION = $ENTITIES->createEntityObject('Session', {'where' => "sid = ?", 'conds' => [$sid]});
        $fresh = 1;
    }

    # Save to db (DAO si pamatuje jen skutecne zmenene sloupce)
    foreach my $key (keys %{$self->{'session'}}) {
        $SESSION->$key($self->getValue($key));
    }

    if (@{$SESSION->getChangeList()}) {
        $SESSION->logit;
        $SESSION->flush;
        if ($SESSION->error()) {
            $SESSION->rollback;
        } else {
            $SESSION->commit;
        }
    } elsif ($fresh) {
        # SELECT bez commitu by na Postgres s vypnutym autocommitem nechal otevrenou transakci
        $SESSION->commit;
    }

    # CLEAR OBJ.DATA
    delete $self->{'session'};
}

=head2 B<[Public] regenerate()>

    Vymeni session id (ochrana proti session fixation - volat po uspesnem prihlaseni): smaze
    stary radek tabulky session (DELETE_ROW + commit), necha Libs::User vygenerovat nove sid
    (regenerateSid) a zalozi pod nim novy radek se stejnymi daty aktualni session - vcetne
    vlastnich sloupcu webu (admin, uid, csrf, ...); sloupce created/updated doplni entita sama.
    Novou entitu drzi do konce requestu, takze dalsi setValue() ulozi flush() UPDATEm jako
    obvykle. Novou cookie posle automaticky printHttpHeader() (cookie_id bere z $USER->getSid
    pri kazdem volani). Bez predchoziho newSession() v tomto requestu ho zavola sama. Vraci nove sid.

        sub login {
            ...
            $SESSION->regenerate();                 # nove sid - podstrcena cookie uz neplati
            $SESSION->setValue('admin', 't');
            $SESSION->setValue('csrf', $self->genToken(32));
        }

=cut

sub regenerate {
    my $self = shift;

    # bez newSession v tomto requestu si session nejdrive nacteme (nebo zalozime)
    $self->newSession() unless ($self->{'dao'});

    my $oldsid = $USER->getSid();
    my $OLD    = delete $self->{'dao'};

    # smazat stary radek (existuje-li; po neuspesnem INSERTu v newSession uz entita data nema)
    if ($OLD and $OLD->expire()) {
        $OLD->DELETE_ROW;
        $OLD->logit;
        if ($OLD->error()) {
            $OLD->rollback;
        } else {
            $OLD->commit;
        }
    }

    # nove sid (do cookie se dostane pri printHttpHeader)
    my $sid = $USER->regenerateSid();

    # novy radek se stejnymi daty; created/updated nastavuje entita pri flush
    my $data = ((ref($self->{'session'}) eq 'HASH') ? $self->{'session'} : {});
    my $NEW  = $ENTITIES->createEntityObject('Session', {});
    foreach my $key (sort keys %{$data}) {
        next if ($key eq 'sid' or $key eq 'created' or $key eq 'updated');
        next unless (defined($data->{$key}));
        $NEW->$key($data->{$key});
    }
    $NEW->sid($sid);
    $NEW->flush;
    $NEW->logit;
    if ($NEW->error()) {
        $NEW->rollback;
    } else {
        $NEW->commit;
    }

    $self->{'session'}->{'sid'} = $sid;
    $self->{'dao'} = $NEW;

    $LOG->info("Session regenerated: $oldsid -> $sid");
    return $sid;
}

=head2 B<[Private] cleanupExpired($SESSION)>

    Prilezitostny uklid tabulky session: pri prvni nove session zalozene timto procesem a pak
    pri kazde http.session_cleanup_every-te (vychozi 20.; 0 = vypnuto) smaze vsechny radky
    s expire < ted a potvrdi commit (pocitadlo new_count je v objektu sluzby). Bez toho by radky
    navstevniku bez cookie (roboti, curl z cronu) zustavaly v tabulce navzdy - newSession maze
    expirovanou session jen tehdy, kdyz se stejne sid znovu ohlasi. Pouziva spojeni a nazev
    tabulky predane (zatim prazdne) entity $SESSION. Vraci 1, kdyz uklid probehl, jinak 0.

=cut

sub cleanupExpired {
    my ($self, $SESSION) = @_;

    my $every = $CONF->getValue('http', 'session_cleanup_every', 20);
    return 0 unless ($every and $every > 0);

    my $count = $self->{'new_count'}++;
    return 0 if ($count % $every);

    my $table = $SESSION->getTableName();
    my $now   = time();

    $SESSION->delete("FROM $table WHERE expire < ?", [$now]);
    if ($SESSION->error()) {
        $SESSION->rollback;
        return 0;
    }
    $SESSION->commit;

    $LOG->debug("Session cleanup: expired rows of $table deleted (expire < $now), new sessions in this process: " . ($count + 1));
    return 1;
}

=head2 B<[Private] AUTOLOAD(...)>

    Nezname metody deleguje na $USER (Libs::User), takze sluzba muze slouzit jako jeho nahrada.

=cut

sub AUTOLOAD {
    my $self = shift;
    my $name = $AUTOLOAD;
    $name =~ s/.*://;
    return if ($name =~ /^DESTROY$/);
    return $USER->$name(@_);
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
    
    $CONF       = new Libs::Config;
    $LOG        = new Libs::Log;
    $VALIDATE   = new Libs::Validate;
    $DBI        = new Libs::DBI;
    $ENTITIES   = new Libs::Entities;
    $USER       = new Libs::User;
    $WEB        = new Libs::Web;
}

1;