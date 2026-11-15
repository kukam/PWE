package Libs::User;

=head1 NAME

Libs::User - stav requestu a uzivatele: session cookie, parametry, skupiny, opts, messenger, upload

=cut

use strict;
use Storable;
use Digest::MD5 qw(md5_hex);
use File::Path qw(make_path);
use File::Basename qw(basename);

=head1 DESCRIPTION

    Trida drzi stav aktualniho requestu (page, func, sid, env, parametry, skupiny) a pokud je
    zapnuta volba pwe.enable_opt, uchovava uzivatelska data mezi requesty v souboru opts
    (pwe.save_opt_to = file) nebo je necha ulozit aplikaci (db, typicky Services::Session).

    Pri kazdem requestu se ulozena data nactou a vlozi do atributu:

      language       = jazyk uzivatele
      lastpage       = predchozi stranka
      lastfunc       = predchozi funkce
      lastparameters = webove parametry z predchoziho requestu
      options        = univerzalni odkladaci misto pro vsechny stranky a sluzby (setOpts/getOpts)

    Trida ke svemu fungovani nepotrebuje databazi. Pokud opts vypnete, musi perzistenci
    techto hodnot zajistit aplikace jinym zpusobem.

=cut

my ($CONF, $LOG, $VALIDATE, $DBI);

=head2 B<[Public] new($conf,$log,$validate,$dbi)>

    Konstruktor objektu uzivatele/requestu. Objekt je singleton - stav se plni v newRequest()
    a nuluje ve flush(). Drzi: sid (session cookie), page/func, uid, skupiny (group), env,
    vstupni parametry (parameters), data z minuleho requestu (lastpage, lastfunc, lastenv,
    lastparameters), jazyk a univerzalni uloziste options (opts).

=cut

sub new {
    my ($class, $conf, $log, $validate, $dbi) = @_;

    $CONF     = $conf;
    $DBI      = $dbi;
    $LOG      = $log;
    $VALIDATE = $validate;

    my $self = {
        'sid'            => undef,
        'page'           => undef,
        'func'           => undef,
        'uid'            => undef,
        'opt'            => $CONF->getValue("pwe", "enable_opt", 1),
        'language'       => @{$CONF->getValue("http", "languages", ["CZE"])}[0],
        'group'          => {},
        'env'            => {},
        'parameters'     => {},
        'lastpage'       => undef,
        'lastfunc'       => undef,
        'lastenv'        => {},
        'lastparameters' => {},
        'options'        => {},
        'CGI'            => {},                                                    # CGI object
    };

    bless $self, $class;
    return $self;
}

=head2 B<[Public] newRequest($page,$func,$sid,$opt,$env,$cgi)>

    Zacatek requestu (vola pwe.fcgi). Overi session cookie: musi mit presne tvar prefix C0 (HTTP)
    nebo C1 (HTTPS) + 32 hexadecimalnich znaku (md5); jiny tvar (kratsi, delsi, nehexovy - napr.
    podstrceny pri session fixation) nebo "prehozena" cookie (C0 pres HTTPS a naopak) se zahodi
    a vygeneruje se nova (generateSid: uc("C0|C1" . md5_hex(cas.random))). Nastavi IP do logu,
    vychozi skupinu 'guest' a pokud je $opt zapnuty a existuje soubor opts, nacte z nej data
    uzivatele (importUserData). Soubor: pwe.home/pwe.opts_dir/<prvni 3 znaky sid>/<sid>.bin.

=cut

sub newRequest {
    my ($self, $page, $func, $sid, $opt, $env, $cgi) = @_;

    # Ochrana proti podstrceni jineho tvaru cookie nez je povoleno, NEMAZAT!!!
    # Presne C0/C1 + 32 hex znaku; volnejsi kontrola (jen "hex") pustila i cookie typu C0ABC.
    $sid = ((defined($sid) and $sid =~ /^C[01][0-9A-Fa-f]{32}$/) ? $sid : undef);

    # HTTPS/HTTP (C1/C0)
    # Bezpecnostni pojistka, aby lidi nemohli chodit po webu (http) a
    # pak se prihlasili (https) a meli stejnou cookis!
    my $https = ((defined($env->{'HTTPS'}) and ($env->{'HTTPS'} eq 'on')) ? 1 : 0);

    if (!defined($sid)) {

        # zadna nebo neplatna cookie -> nize se vygeneruje nova
    } elsif (($sid =~ /^C0/) and $https) {
        $sid = undef;
    } elsif (($sid =~ /^C1/) and !$https) {
        $sid = undef;
    } elsif ($sid !~ /^C[0-1]{1}/) {
        $sid = undef;
    }

    $self->{'page'} = $page;
    $self->{'func'} = $func;
    $self->{'sid'}  = $sid;
    $self->{'opt'}  = $opt;
    $self->{'CGI'}  = $cgi;
    $self->{'env'}  = $env;

    my $ip  = $self->getIP;
    my $who = $self->getUserAgent();

    $LOG->setIP($ip);

    unless ($sid) {
        $sid = $self->generateSid($https);
        $LOG->debug("Generated new cookie_id:$sid");
        $self->{'sid'} = $sid;
    }

    # SET DEFAULT GROUP
    $self->addGroup('guest');

    # READ OPTIONS
    my $home = $CONF->getValue("pwe", "home");
    my $opts = $CONF->getValue("pwe", "opts_dir");
    my $sdir = substr($sid, 0, 3) . "/";
    my $dir  = $home . $opts . $sdir;
    my $file = $dir . $sid . ".bin";

    # Import user data (only if exists file and is enabled opt load)
    if (-f $file and $opt) {
        my $data = $self->readFile($file);
        $self->importUserData($data);
    }
}

=head2 B<[Public] getPage()>

    Metoda vraci nazev stranky aktualniho requestu (parametr page).

=cut

sub getPage {
    my $self = shift;
    return $self->{'page'};
}

=head2 B<[Public] getFunc()>

    Metoda vraci nazev funkce aktualniho requestu (parametr func).

=cut

sub getFunc {
    my $self = shift;
    return $self->{'func'};
}

=head2 B<[Public] addGroup($name)>

    Prida uzivateli skupinu (roli), napr. 'admin'. Skupiny se pouzivaji v Libs::Pages::accessFunc
    pro kontrolu prav k funkcim stranek. Typicky vola Services::UserAccount::newRequest.

=cut

sub addGroup {
    my ($self, $name) = @_;
    $self->{'group'}->{$name} = 1;
}

=head2 B<[Public] getCGI()>

    Vraci CGI objekt aktualniho requestu (potreba napr. pro upload souboru - $CGI->upload()).

=cut

sub getCGI {
    my $self = shift;
    return $self->{'CGI'};
}

=head2 B<[Public] getSid()>

    Vraci session id (hodnotu cookie) aktualniho requestu, napr. "C0A1B2...".

=cut

sub getSid {
    my $self = shift;
    return $self->{'sid'};
}

=head2 B<[Public] regenerateSid()>

    Vygeneruje nove session id (stejne jako newRequest: C0/C1 podle env HTTPS + md5_hex), ulozi
    ho do objektu a vrati. Dalsi printHttpHeader() posle nove sid v Set-Cookie automaticky
    (cookie_id se bere z getSid pri kazdem volani), opts se ve flush() ulozi uz pod novym sid.
    Ochrana proti session fixation: volat po prihlaseni uzivatele, aby utocnikem podstrcena cookie
    po prihlazeni neplatila. Web s DB session vola misto toho Services::Session::regenerate(), ktera
    zaroven presune radek tabulky session pod nove sid.

=cut

sub regenerateSid {
    my $self = shift;
    my $https = ((defined($self->{'env'}->{'HTTPS'}) and ($self->{'env'}->{'HTTPS'} eq 'on')) ? 1 : 0);
    my $sid = $self->generateSid($https);
    $LOG->debug("Regenerated cookie_id:$sid (old:" . (defined($self->{'sid'}) ? $self->{'sid'} : '') . ")");
    $self->{'sid'} = $sid;
    return $sid;
}

=head2 B<[Private] generateSid($https)>

    Vrati nove session id: uc("C0" | "C1" . md5_hex(cas . nahodne cislo)), prefix C1 pro HTTPS.
    Pouziva newRequest a regenerateSid.

=cut

sub generateSid {
    my ($self, $https) = @_;
    my $ckey = time() . int(rand(999999999));
    return uc(($https ? "C1" : "C0") . md5_hex($ckey));
}

=head2 B<[Public] getUid()>

    Vraci id prihlaseneho uzivatele nastavene pres setUid (engine sam ho nenastavuje,
    dela to aplikacni sluzba uctu).

=cut

sub getUid {
    my $self = shift;
    return $self->{'uid'};
}

=head2 B<[Public] getIP()>

    Vraci IP klienta (env REMOTE_ADDR, jinak 127.0.0.1).

=cut

sub getIP {
    my $self = shift;
    return $self->getValue("env", "REMOTE_ADDR", "127.0.0.1");
}

=head2 B<[Public] getUserAgent()>

    Vraci hlavicku User-Agent klienta (env HTTP_USER_AGENT, jinak "UNKNOWN").

=cut

sub getUserAgent {
    my $self = shift;
    return $self->getValue("env", "HTTP_USER_AGENT", "UNKNOWN");
}

=head2 B<[Private] getEnv($key,$def)>

    Metoda vraci hodnotu promenne prostredi $key aktualniho requestu (atribut env,
    napr. 'SCRIPT_FILENAME'). Pokud promenna neexistuje nebo ma prazdnou (nepravdivou)
    hodnotu, vraci $def.

=cut

sub getEnv {
    my ($self, $key, $def) = @_;
    return $def unless (exists($self->{'env'}->{$key}));
    return $def unless ($self->{'env'}->{$key});
    return $self->{'env'}->{$key};
}

=head2 B<[Public] getGroup()>

    Vraci hash vsech skupin uzivatele { 'guest' => 1, 'admin' => 1, ... }.

=cut

sub getGroup {
    my $self = shift;
    return $self->{'group'};
}

=head2 B<[Public] getActivePage()>

    Vraci nazev prave zpracovavane stranky (nebo "default"). Pouziva Libs::Web pro vyber
    resource bundlu.

=cut

sub getActivePage {
    my $self = shift;
    return $self->getValue("page", undef, "default");
}

=head2 B<[Public] getValue($key,$value,$def)>

    Metoda vraci hodnotu atributu objektu $key (napr. 'page', 'language', 'env', 'group'),
    pripadne jeho podklice $value, pokud je atribut hash (napr. getValue('env', 'HTTP_HOST', $def)).
    Pokud atribut neexistuje, vraci $def. U podklice vraci $def i tehdy, kdyz atribut neni hash,
    podklic neexistuje nebo ma prazdnou (nepravdivou) hodnotu. Bez podklice vraci $def, pokud
    atribut neexistuje nebo je undef; jinak hodnotu tak, jak je (vcetne 0 a prazdneho retezce).

=cut

sub getValue {
    my ($self, $key, $value, $def) = @_;

    return $def unless (exists($self->{$key}));

    if ($value) {
        return $def if (ref($self->{$key}) ne "HASH");
        return $def unless (exists($self->{$key}->{$value}));
        return $def unless ($self->{$key}->{$value});
        return $self->{$key}->{$value};
    } else {
        return $def unless (defined($self->{$key}));
        return $self->{$key};
    }
}

=head2 B<[Private] readFile($file)>

    Metoda nacte (Storable::retrieve) serializovana uzivatelska data (opts) ze souboru
    a vrati je jako hash. Pokud soubor neexistuje, vraci undef. Pokud je soubor poskozeny
    a nejde nacist, zaloguje chybu, soubor smaze a vrati undef.
    Vola se z newRequest(), kdyz je zapnute enable_opt a save_opt_to = "file".

=cut

sub readFile {
    my ($self, $file) = @_;

    my $result = undef;

    return undef unless (-f $file);

    $LOG->delay("read_file");

    eval { local $SIG{__DIE__} = 'DEFAULT'; $result = retrieve($file); };
    if ($@) {
        chomp($@);
        $LOG->error("$@");
        $LOG->error("REMOVE OPTS FILE: $file [ FAILED ]");
        unlink($file);
        return undef;
    }

    $LOG->delay("read_file", "Reading opts file $file");
    return $result;
}

=head2 B<[Private] importUserData($data)>

    Metoda prevezme hash nacteny z opts (viz readFile) a prepise z nej atributy
    lastpage, lastfunc, language, lastenv, lastparameters a options. Ostatni klice ignoruje.

=cut

sub importUserData {
    my ($self, $data) = @_;

    if (ref($data) eq "HASH") {
        foreach my $key (@{['lastpage', 'lastfunc', 'language', 'lastenv', 'lastparameters', 'options']}) {
            next unless (exists($data->{$key}));
            $self->{$key} = $data->{$key};
        }
    }
}

=head2 B<[Public] getOpts($key,$value,$def)>

    Metoda vraci hodnotu ulozenou v uzivatelskem nastaveni (options) pres setOpts() pod klicem
    $key, pripadne pod podklicem $value. Pokud zaznam neexistuje, vraci $def.

    my $basket = $USER->getOpts("eshop", "basket", []);

=cut

sub getOpts {
    my ($self, $key, $value, $def) = @_;

    if ($value) {
        return $def if (!$self->existOpts($key, $value));
        return @{$self->{'options'}->{$key}->{$value}}[0];
    } else {
        return $def if (!$self->existOpts($key));
        return @{$self->{'options'}->{$key}}[0];
    }
}

=head2 B<[Public] getParam($key,$value,$def)>

    Metoda vraci hodnotu vstupniho parametru $key. Parametr muze mit vice hodnot (pole),
    proto $value urcuje, co se vrati:
      cislo (0, 1, ...) = hodnota na dane pozici v poli
      'all'             = reference na cele pole hodnot
      undef nebo ''     = prvni hodnota
    Pokud parametr nebo pozice neexistuje, vraci $def.

    my $email = $USER->getParam("email", 0, "");
    my $ids   = $USER->getParam("id", "all", []);

=cut

sub getParam {
    my ($self, $key, $value, $def) = @_;

    return $def unless ($self->existParam($key));

    if ($value eq "all") {
        return $self->{'parameters'}->{$key};
    } elsif ($value =~ /^\d+$/) {
        return $def if (@{$self->{'parameters'}->{$key}} < ($value + 1));
        return @{$self->{'parameters'}->{$key}}[$value];
    } else {
        return $def if (@{$self->{'parameters'}->{$key}} < 1);
        return @{$self->{'parameters'}->{$key}}[0];
    }
}

=head2 B<[Public] getParams()>

    Metoda vraci hashref vsech vstupnich parametru requestu ve tvaru { nazev => [ hodnoty ] }.

=cut

sub getParams {
    my $self = shift;
    return $self->{'parameters'};
}

=head2 B<[Public] getParamsList()>

    Metoda vraci referenci na pole nazvu vsech vstupnich parametru requestu.

=cut

sub getParamsList {
    my $self       = shift;
    my $parameters = [];
    foreach my $p (keys %{$self->{'parameters'}}) { push(@{$parameters}, $p); }
    return $parameters;
}

=head2 B<[Public] getLastParam($key,$value,$def)>

    Metoda vraci hodnotu parametru $key z predchoziho requestu (nacteno z opts). Jinak funguje
    stejne jako getParam(): $value je pozice v poli, 'all' vraci cele pole, undef prvni hodnotu.
    Pokud parametr nebo pozice neexistuje, vraci $def.

=cut

sub getLastParam {
    my ($self, $key, $value, $def) = @_;

    return $def unless ($self->existLastParam($key));

    if ($value eq "all") {
        return $self->{'lastparameters'}->{$key};
    } elsif ($value =~ /^\d+$/) {
        return $def if (@{$self->{'lastparameters'}->{$key}} < ($value + 1));
        return @{$self->{'lastparameters'}->{$key}}[$value];
    } else {
        return $def if (@{$self->{'lastparameters'}->{$key}} < 1);
        return @{$self->{'lastparameters'}->{$key}}[0];
    }
}

=head2 B<[Private] getLastEnv($key,$def)>

    Metoda vraci hodnotu promenne prostredi $key z predchoziho requestu (atribut lastenv,
    nacteny z opts). Pokud promenna neexistuje nebo ma prazdnou (nepravdivou) hodnotu, vraci $def.

=cut

sub getLastEnv {
    my ($self, $key, $def) = @_;
    return $def unless (exists($self->{'lastenv'}->{$key}));
    return $def unless ($self->{'lastenv'}->{$key});
    return $self->{'lastenv'}->{$key};
}

=head2 B<[Public] getRequestMethod()>

    Metoda vraci HTTP metodu requestu velkymi pismeny (GET/POST/...) z promenne prostredi
    REQUEST_METHOD. Pokud neni nastavena (napr. pri spusteni pwe.fcgi z prikazove radky),
    pouzije se vstupni parametr request_method, vychozi je GET:

    QUERY_STRING='page=myaccount&func=login&request_method=POST' perl pwe.fcgi

=cut

sub getRequestMethod {
    my $self = shift;

    my $request = $self->getValue("env", "REQUEST_METHOD", undef);
    $request = $self->getParam("request_method", undef, "GET") unless (defined($request));

    return uc($request);
}

=head2 B<[Public] setOpts($data,$key,$value)>

    Metoda ulozi hodnotu $data (skalar nebo reference) do uzivatelskeho nastaveni (options)
    pod klic $key, pripadne pod podklic $value. Uklada se hluboka kopie (Storable::dclone).
    Nastaveni se na konci requestu serializuje do opts souboru (flush) a je dostupne
    v dalsich requestech pres getOpts().

    $USER->setOpts(\@basket, "eshop", "basket");

=cut

sub setOpts {
    my ($self, $data, $key, $value) = @_;

    if ($value) {
        $self->{'options'}->{$key}->{$value} = Storable::dclone([$data]);
    } else {
        $self->{'options'}->{$key} = Storable::dclone([$data]);
    }
}

=head2 B<[Public] delOpts($key,$value)>

    Metoda smaze z uzivatelskeho nastaveni (options) zaznam pod klicem $key, pripadne jen
    jeho podklic $value.

=cut

sub delOpts {
    my ($self, $key, $value) = @_;
    if ($value) {
        delete $self->{'options'}->{$key}->{$value};
    } else {
        delete $self->{'options'}->{$key};
    }
}

=head2 B<[Private] exportUserData()>

    Metoda vrati hash se stavem uzivatele pro ulozeni do opts: lastpage/lastfunc
    (aktualni page/func), language, kopii env, kopii parametru (viz exportParameters)
    a kopii options. Vola se z flush().

=cut

sub exportUserData {
    my $self = shift;

    return {
        'lastpage'       => $self->{'page'},
        'lastfunc'       => $self->{'func'},
        'language'       => $self->{'language'},
        'lastenv'        => Storable::dclone($self->{'env'}),
        'lastparameters' => $self->exportParameters(),
        'options'        => Storable::dclone($self->{'options'}),
    };

}

=head2 B<[Private] exportParameters()>

    Metoda vraci kopii vstupnich parametru vhodnou pro serializaci (Storable).
    Hodnoty uploadu (objekty CGI Fh - GLOB) nelze serializovat, uklada se jen
    jejich textova podoba (jmeno souboru). Bez teto upravy padal flush()
    s chybou "Can't store GLOB items" po kazdem requestu s uploadem.

=cut

sub exportParameters {
    my $self = shift;
    my $copy = {};
    while (my ($key, $values) = each(%{$self->{'parameters'}})) {
        $copy->{$key} = [map { (ref($_) ? "$_" : $_) } @{$values}];
    }
    return $copy;
}

=head2 B<[Private] writeFile($data,$file)>

    Ulozi hash $data (Storable::store) do souboru $file atomicky: zapise do $file.<pid>.tmp a pak
    rename. Vraci 1/0; chybu zaloguje a docasny soubor smaze. Vola flush().

=cut

sub writeFile {
    my ($self, $data, $file) = @_;
    $LOG->delay("write_file");

    # Atomicky zapis: do docasneho souboru a rename. Soubezny request (3 FastCGI procesy nad jednim
    # adresarem sessions) tak nikdy necte rozepsany soubor; posledni zapis vyhrava.
    my $tmp = "$file.$$.tmp";
    my $ok  = eval { store($data, $tmp); 1 };
    if ($ok and rename($tmp, $file)) {
        $LOG->delay("write_file", "Saving file $file");
        return 1;
    }
    $LOG->error("Saving opts file $file FAILED: " . ($@ || $!));
    unlink($tmp);
    return 0;
}

=head2 B<[Public] setUid($uid)>

    Nastavi id prihlaseneho uzivatele pro aktualni request.

=cut

sub setUid {
    my ($self, $uid) = @_;
    $self->{'uid'} = $uid;
}

=head2 B<[Public] setParameter($parameter,$value,$position)>

    Metoda ulozi nebo prepise vstupni parametr. Ma dve podoby:

    $USER->setParameter("jmeno", ["hodnota1", "hodnota2", ...]);    # nahradi cele pole hodnot
    $USER->setParameter("jmeno", "hodnota", 0);                     # prepise hodnotu na pozici $position

    V druhe podobe musi byt $value definovana a $position cele cislo, jinak se nic neprovede.
    Pouziva ji napr. Libs::Pages::replaceInputParameters pro zapis upravenych hodnot.

=cut

sub setParameter {
    my ($self, $parameter, $value, $position) = @_;
    if (ref($value) eq "ARRAY") {
        $self->{'parameters'}->{$parameter} = $value;
    } elsif ((defined($value)) and ($position =~ /^\d+$/)) {
        splice(@{$self->{'parameters'}->{$parameter}}, $position, 1, $value);
    }
}

=head2 B<[Public] setMessenger($html)>

    Metoda ulozi HTML zpravu (messenger) do uzivatelskeho nastaveni (opts). Zprava se zobrazi
    pri nejblizsim vykresleni stranky (getMessenger ji vrati a zaroven smaze), takze prezije
    i presmerovani. Stranky typicky pouzivaji $WEB->setMessenger(), ktery zpravu vyrenderuje
    ze sablony a pote zavola tuto metodu.

=cut

sub setMessenger {
    my ($self, $html) = @_;
    $self->setOpts($html, "messenger");
}

=head2 B<[Public] setLanguage($language)>

    Metoda nastavi uzivateli jazyk (napr. "CZE", "EN"). Prijme jen jazyk uvedeny v conf
    http.languages (Libs::Validate::is_language), jinou hodnotu tise ignoruje.
    Volba se uklada do opts a plati i pro dalsi requesty.

=cut

sub setLanguage {
    my ($self, $lang) = @_;
    return unless (defined($VALIDATE->is_language($lang)));
    $self->{'language'} = $lang;
}

=head2 B<[Public] setPage($page)>

    Metoda nastavi nazev stranky aktualniho requestu (viz getPage).

=cut

sub setPage {
    my ($self, $page) = @_;
    $self->{'page'} = $page;
}

=head2 B<[Public] setFunc($func)>

    Metoda nastavi nazev funkce aktualniho requestu (viz getFunc).

=cut

sub setFunc {
    my ($self, $func) = @_;
    $self->{'func'} = $func;
}

=head2 B<[Public] saveUploadFile($parameter_name,$home,$path,$rewrite_enable)>

    Metoda ulozi soubor(y) nahrane formularem v parametru $parameter_name do adresare
    $home.$path (adresar se vytvori, pokud neexistuje; nevytvari se rekurzivne).
    Nazev souboru se prebira od klienta a ocisti na holy basename (ochrana proti "../").

    Metoda vraci seznam ($error, @filelist), kde $error je undef pri uspechu, nebo klic chyby:
      'error_parameter_is_empty' - v parametru neni nahrany soubor
      'error_file_is_exist'      - soubor jiz existuje a $rewrite_enable je vypnuty
      'error_file_write'         - soubor se nepodarilo otevrit pro zapis
    @filelist obsahuje nazvy (basename) zpracovanych souboru.

    my ($error, @files) = $USER->saveUploadFile("photo", $home, "upload/images/", 0);

=cut

sub saveUploadFile {
    my ($self, $parameter_name, $home, $path, $rewrite_enable) = @_;

    my @filelist;

    my $CGI = $self->getCGI();
    my $param = $self->getParam($parameter_name, 0, undef);

    unless (ref($param) or UNIVERSAL::can($param, 'can')) {
        $LOG->error("SaveUploadFile, parameter:$parameter_name is empty");
        return ("error_parameter_is_empty", @filelist);
    }

    mkdir($home . $path) unless (-d $home . $path);

    my @lightweight_fh = $CGI->upload($parameter_name);

    foreach my $fh (@lightweight_fh) {

        # undef may be returned if it's not a valid file handle
        if (defined $fh) {

            # Upgrade the handle to one compatible with IO::Handle:
            my $io_handle = $fh->handle;

            # Jmeno souboru od klienta se ocisti na holy basename (ochrana proti "../" v nazvu).
            my $fname = basename("$fh");

            if (-f $home . $path . $fname and !$rewrite_enable) {
                $LOG->error("SaveUploadFile, file exists: $path$fname, rewrite_enable:$rewrite_enable");
                return ("error_file_is_exist", @filelist);
            }

            push(@filelist, $fname);

            $LOG->info("SaveUploadFile new file to: $path$fname");
            $LOG->delay("SaveUploadFile");
            unless (open(OUTFILE, '>', $home . $path . $fname)) {
                $LOG->error("SaveUploadFile, cannot write $path$fname: $!");
                return ("error_file_write", @filelist);
            }
            binmode(OUTFILE);
            while (my $bytesread = $io_handle->read(my $buffer, 1024)) {
                print OUTFILE $buffer;
            }
            close(OUTFILE);
            $LOG->delay("SaveUploadFile", "upload file to: $path$fname");
        }
    }
    return (undef, @filelist);
}

=head2 B<[Public] getMessenger()>

    Metoda vrati HTML zpravu (messenger) ulozenou pres setMessenger() a zaroven ji z opts smaze,
    takze se zobrazi jen jednou. Pokud zadna zprava neni, vraci undef.

=cut

sub getMessenger {
    my $self = shift;
    my $msg  = $self->getOpts("messenger");
    $self->delOpts("messenger");
    return $msg;
}

=head2 B<[Public] existMessenger()>

    Metoda vraci 1, pokud je nastavena zprava (messenger), jinak undef.

=cut

sub existMessenger {
    my $self = shift;
    return $self->existOpts("messenger");
}

=head2 B<[Private] existOpts($key,$value)>

    Metoda vraci 1, pokud v uzivatelskem nastaveni (options) existuje zaznam pod klicem $key,
    pripadne pod podklicem $value; jinak undef.

=cut

sub existOpts {
    my ($self, $key, $value) = @_;
    if (ref($self->{'options'}->{$key}) eq 'HASH' and $value) {
        return undef if (!exists($self->{'options'}->{$key}->{$value}));
        return 1;
    } else {
        return undef if (!exists($self->{'options'}->{$key}));
        return 1;
    }
}

=head2 B<[Public] existGroup($group)>

    Metoda vraci 1, pokud uzivatel patri do skupiny (role) $group, napr. 'admin'; jinak 0.

=cut

sub existGroup {
    my ($self, $group) = @_;
    return 0 if (!exists($self->{'group'}->{$group}));
    return 1;
}

=head2 B<[Public] existParam($parameter)>

    Metoda vraci 1, pokud byl v requestu poslan vstupni parametr $parameter (i s prazdnou
    hodnotou), jinak 0. Pro kontrolu neprazdne hodnoty viz isdefinedParam().

=cut

sub existParam {
    my ($self, $parameter) = @_;
    return 0 if (!exists($self->{'parameters'}->{$parameter}));
    return 1;
}

=head2 B<[Public] existLastParam($parameter)>

    Metoda vraci 1, pokud parametr $parameter existoval v predchozim requestu, jinak 0.

=cut

sub existLastParam {
    my ($self, $parameter) = @_;
    return 0 if (!exists($self->{'lastparameters'}->{$parameter}));
    return 1;
}

=head2 B<[Public] existLastParams()>

    Metoda vraci 1, pokud v predchozim requestu existoval alespon jeden parametr, jinak 0.

=cut

sub existLastParams {
    my $self = shift;
    foreach (keys %{$self->{'lastparameters'}}) { return 1; }
    return 0;
}

=head2 B<[Public] isdefinedParam($parameter)>

    Metoda vraci 1, pokud vstupni parametr $parameter existuje a jeho prvni hodnota neni prazdny
    retezec ''; jinak 0. Pouziva se v deklarativni validaci (Libs::Pages) pro kontrolu
    povinnych parametru.

=cut

sub isdefinedParam {
    my ($self, $parameter) = @_;
    return 0 if (!$self->existParam($parameter));
    return 0 if (@{$self->{'parameters'}->{$parameter}}[0] =~ /^$/);
    return 1;
}

=head2 B<[Public] deleteGroup($name)>

    Odebere uzivateli skupinu (napr. 'guest' po prihlaseni).

=cut

sub deleteGroup {
    my ($self, $name) = @_;
    delete $self->{'group'}->{$name};
}

=head2 B<[Public] flush()>

    Konec requestu (vola pwe.fcgi). Pokud je enable_opt zapnuty a pwe.save_opt_to = "file",
    ulozi exportUserData() do opts souboru (adresar se vytvori rekurzivne). Pak kompletne
    vynuluje stav requestu (sid, page, func, uid, skupiny, parametry, env, options, jazyk).
    Pri save_opt_to = "db" musi perzistenci zajistit aplikace (napr. Services::Session).

=cut

sub flush {
    my $self = shift;

    my $sid  = $self->getSid();
    my $opt  = $self->getValue("opt", undef, 1);
    my $home = $CONF->getValue("pwe", "home");
    my $opts = $CONF->getValue("pwe", "opts_dir");
    my $sdir = substr($sid, 0, 3) . "/";
    my $dir  = $home . $opts . $sdir;
    my $file = $dir . $sid . ".bin";
    my $save = (($CONF->getValue("pwe", "save_opt_to", "file") eq "file") ? 1 : 0);

    if ($opt and $save) {
        make_path($dir) unless (-d $dir);
        my $exp = $self->exportUserData();
        $self->writeFile($exp, $file);
    }

    # CLEAR USER DATA
    $self->{'sid'}            = undef;
    $self->{'page'}           = undef;
    $self->{'func'}           = undef;
    $self->{'uid'}            = undef;
    $self->{'language'}       = @{$CONF->getValue("http", "languages", ["CZE"])}[0];
    $self->{'opt'}            = $CONF->getValue("pwe", "enable_opt", 1);
    $self->{'CGI'}            = {};
    $self->{'env'}            = {};
    $self->{'group'}          = {};
    $self->{'parameters'}     = {};
    $self->{'lastpage'}       = undef;
    $self->{'lastfunc'}       = undef;
    $self->{'lastenv'}        = {};
    $self->{'lastparameters'} = {};
    $self->{'options'}        = {};
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
    require Libs::DBI;
    require Libs::Validate;
    $LOG      = new Libs::Log;
    $CONF     = new Libs::Config;
    $DBI      = new Libs::DBI;
    $VALIDATE = new Libs::Validate;
}

1;
