package Libs::User;

use strict;
use Storable;
use Digest::MD5 qw(md5_hex);

=DESCRIPTIONS

    Trida uchovvava uzivatelska data v soboru opt (pokud je volba enable_opt zapnuta).
    
    Pri kazdem requestu se tyto data nactou znovu a vlozi se do atributu
    'lastparameters', options' a 'language', lastpage, lastfunc.
    
    language = jazyk
    lastpage = predchozi page
    lastfunc = predchozi funkce
    lastparameters = webove parametry z minuleho requestu
    options = univerzalni odkladaci misto pro vsechny page a servisy.
    
    Trida ke svemu fungovani nepotrebuje databazi ani opts.

    Pokud vypnete opts, musite zajistti setovani hodnot jinym zpusobem.
    
=cut

my ($CONF, $LOG, $VALIDATE, $DBI);

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

sub newRequest {
    my ($self, $page, $func, $sid, $opt, $env, $cgi) = @_;

    # Ochrana proti podstrceni jineho tvaru cookie nez je povoleno, NEMAZAT!!!
    $sid = ($VALIDATE->is_md5hex($sid) ? $sid : undef);

    # HTTPS/HTTP (C1/C0)
    # Bezpecnostni pojistka, aby lidi nemohli chodit po webu (http) a
    # pak se prihlasili (https) a meli stejnou cookis!
    if (($sid =~ /^C0/) and ($env->{'HTTPS'} eq 'on')) {
        $sid = undef;
    } elsif (($sid =~ /^C1/) and ($env->{'HTTPS'} ne 'on')) {
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
        my $ckey = time() . int(rand(999999999));
        $sid = uc(($env->{'HTTPS'} eq 'on') ? "C1" . md5_hex($ckey) : "C0" . md5_hex($ckey));
        $LOG->debug("Generated new cookie_id:$sid, cookie_key:$ckey");
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

    Metoda vraci nazev stranky ktera se nacita

=cut

sub getPage {
    my $self = shift;
    return $self->{'page'};
}

=head2 B<[Public] getFunc()>

    Metoda vraci nazev funkce ktera se nacita

=cut

sub getFunc {
    my $self = shift;
    return $self->{'func'};
}

sub addGroup {
    my ($self, $name) = @_;
    $self->{'group'}->{$name} = 1;
}

sub getCGI {
    my $self = shift;
    return $self->{'CGI'};
}

sub getSid {
    my $self = shift;
    return $self->{'sid'};
}

sub getUid {
    my $self = shift;
    return $self->{'uid'};
}

sub getIP {
    my $self = shift;
    return $self->getValue("env", "REMOTE_ADDR", "127.0.0.1");
}

sub getUserAgent {
    my $self = shift;
    return $self->getValue("env", "HTTP_USER_AGENT", "UNKNOWN");
}

=head2 B<[Private] getEnv($key,$def)>

    Metoda vraci obsah atributu env ($key), pokud atribut neexistuje
    vraci metoda hodnotu $def.
    
=cut

sub getEnv {
    my ($self, $key, $def) = @_;
    return $def unless (exists($self->{'env'}->{$key}));
    return $def unless ($self->{'env'}->{$key});
    return $self->{'env'}->{$key};
}

sub getGroup {
    my $self = shift;
    return $self->{'group'};
}

sub getActivePage {
    my $self = shift;
    return $self->getValue("page", undef, "default");
}

=head2 B<[Public] getValue($key,$value,$def)>

    Metoda vraci obsah atributu ($key) a jeho hodnotu ($value),
    pokud jedna z promenych neexistuje vraci metoda hodnotu $def.
    
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
        return $def unless (exists($self->{$key}));
        return $self->{$key};
    }
}

=head2 B<[Public] readOpts()>

    Metoda pouze nacte obsah souboru!

=cut

sub readFile {
    my ($self, $file) = @_;

    my $result = undef;

    return undef unless (-f $file);

    $LOG->delay("read_file");

    eval "\$SIG{__DIE__}='DEFAULT'; \$result = retrieve(\$file);";
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

=head2 B<[Public] importOpts()>

    Metoda vlozi nova data do atributu options, lastpage, lastfunc .....

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

    Metoda vraci obsah ulozeneho nastaveni.

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

    Metoda vraci obsah parametru ($key) a jeho radovou pozici ($value [0-9]),
    pokud do promene $value dosadime slovo 'all', vraci cele pole.
    V pripade ze parametr nebo pozice neexistuje funkce vraci hodnotu $def.
    
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

    Metoda vraci cely seznam vsech parametru.
    
=cut

sub getParams {
    my $self = shift;
    return $self->{'parameters'};
}

=head2 B<[Public] getParamsList()>

    Metoda vraci cely seznam vsech parametru v poli.
    
=cut

sub getParamsList {
    my $self       = shift;
    my $parameters = [];
    foreach my $p (keys %{$self->{'parameters'}}) { push(@{$parameters}, $p); }
    return $parameters;
}

=head2 B<[Public] getLastParam($key,$value,$def)>

    Metoda vraci obsah parametru z minuleho requestu ($key) a jeho radovou pozici ($value [0-9]),
    pokud do promene $value dosadime slovo 'all', vraci cele pole.
    V pripade ze parametr nebo pozice neexistuje funkce vraci hodnotu $def.
    
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

=head2 B<[Public] getLastParams()>

    Metoda vraci cely seznam vsech parametru z predesleho requestu.
    
=cut

sub getLastParams {
    my $self = shift;
    return $self->{'lastparameters'};
}

=head2 B<[Private] getLastEnv($key,$def)>

    Metoda vraci obsah atributu lastenv ($key), pokud atribut neexistuje
    vraci metoda hodnotu $def.
    
=cut

sub getLastEnv {
    my ($self, $key, $def) = @_;
    return $def unless (exists($self->{'lastenv'}->{$key}));
    return $def unless ($self->{'lastenv'}->{$key});
    return $self->{'lastenv'}->{$key};
}

=head2 B<[Public] getRequestMethod()>

    metoda vraci hodnoty POST/GET, v pripade ze pwe.fcgi je spousten z prikazove radky
    prebira se hodnota z parametru request_method=POST/GET (./pwe.fcgi 'page=myaccount&func=login&request_method=POST)

=cut

sub getRequestMethod {
    my $self = shift;

    my $request = $self->getValue("env", "REQUEST_METHOD", undef);
    $request = $self->getParam("request_method", undef, "GET") unless (defined($request));

    return uc($request);
}

=head2 B<[Public] setOpts($data,$key,$value)>

    Metoda ulozi nastaveni pod klic ($key) a pod hodnotu ($value).

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

    Metoda smaze nastaveni (opts) pod klicem($key) a pod hodnotou ($value)

=cut

sub delOpts {
    my ($self, $key, $value) = @_;
    if ($value) {
        delete $self->{'options'}->{$key}->{$value};
    } else {
        delete $self->{'options'}->{$key};
    }
    if (ref($self->{'options'}) eq "HASH") {
        foreach (keys %{$self->{'options'}}) { return; }
    }
}

=head2 B<[Private] exportOpts()>

    Metoda ulozi 'options'.

=cut

sub exportUserData {
    my $self = shift;

    return {
        'lastpage'       => $self->{'page'},
        'lastfunc'       => $self->{'func'},
        'language'       => $self->{'language'},
        'lastenv'        => Storable::dclone($self->{'env'}),
        'lastparameters' => Storable::dclone($self->{'parameters'}),
        'options'        => Storable::dclone($self->{'options'}),
    };

}

=head2 B<[Public] writeOpts()>

    Metoda pouze ulozi souboru!

=cut

sub writeFile {
    my ($self, $data, $file) = @_;
    $LOG->delay("write_file");
    store($data, $file);
    $LOG->delay("write_file", "Saving file $file");
}

sub setUid {
    my ($self, $uid) = @_;
    $self->{'uid'} = $uid;
}

=head2 B<[Public] setParameter("parametr_name",["value1","value2",...]|"parametr_name","value","position_array")>

    Metoda uklada nebo prepisuje vstupni parametry
    $USER->setParameter("parametr_name",["value1","value2",...]);
    OR
    $USER->setParameter("parametr_name","value","position_array");

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

    Metoda zapise do OPTS zpravu ktera se objevi hned pri prvnim nacteni stranky

=cut

sub setMessenger {
    my ($self, $html) = @_;
    $self->setOpts($html, "messenger");
}

=head2 B<[Public] setLanguage($language)>

    Metoda zmeni uzivateli volbu jazyka

=cut

sub setLanguage {
    my ($self, $lang) = @_;
    return unless (defined($VALIDATE->is_language($lang)));
    $self->{'language'} = $lang;
}

=head2 B<[Public] setPage($page)>

    Metoda setne nazev stranky ktera se nacita

=cut

sub setPage {
    my ($self, $page) = @_;
    $self->{'page'} = $page;
}

=head2 B<[Public] setFunc($func)>

    Metoda setne nazev funkce ktera se nacita

=cut

sub setFunc {
    my ($self, $func) = @_;
    $self->{'func'} = $func;
}

=head2 B<[Public] saveUploadFile($parameter_name,$home,$path,$rewrite_enable)>

    Metoda ulozi uploudnuty soubor.
    
    Pokud je volba rewrite_enable vypnuta a soubor s timto nazvevm jiz existuje, vraci chybu 'error_file_is_exist'.
    Pokud v zadanem parametru neni uploudnuty souboru, vraci chybu 'error_parameter_is_empty'.
    
    Metoda vraci (error/undef,@filelist)

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

            if (-f $home . $path . $fh and !$rewrite_enable) {
                $LOG->error("SaveUploadFile, file exists: $path$fh, rewrite_enable:$rewrite_enable");
                return ("error_file_is_exist", @filelist);
            }

            push(@filelist, $fh);

            $LOG->info("SaveUploadFile new file to: $path$fh");
            $LOG->delay("SaveUploadFile");
            open(OUTFILE, '>', $home . $path . $fh);
            while (my $bytesread = $io_handle->read(my $buffer, 1024)) {
                print OUTFILE $buffer;
            }
            close(OUTFILE);
            $LOG->delay("SaveUploadFile", "upload file to: $path$fh");
        }
    }
    return (undef, @filelist);
}

=head2 B<[Public] getMessenger()>

    Metoda vrati z OPTS zpravu ktera se objevi hned pri prvnim nacteni stranky

=cut

sub getMessenger {
    my $self = shift;
    my $msg  = $self->getOpts("messenger");
    $self->delOpts("messenger");
    return $msg;
}

=head2 B<[Public] existMessenger()>

    Metoda vrati informaci (1/undef) zdali je nebo neni nestovan messenger

=cut

sub existMessenger {
    my $self = shift;
    return $self->existOpts("messenger");
}

=head2 B<[Private] existOpts($key,$value)>

    Metoda overi jestli nastaveni (option) existuje.

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

=head2 B<[Public] existGroup()>

    Metoda vraci 1 nebo 0 podle toho jestli existuji dana role (group) nebo ne.
    
=cut

sub existGroup {
    my ($self, $group) = @_;
    return 0 if (!exists($self->{'group'}->{$group}));
    return 1;
}

=head2 B<[Public] existParam()>

    Metoda vraci 1 nebo 0 podle toho jestli existuji dany parametry nebo ne.
    
=cut

sub existParam {
    my ($self, $parameter) = @_;
    return 0 if (!exists($self->{'parameters'}->{$parameter}));
    return 1;
}

=head2 B<[Public] existLastParam()>

    Metoda vraci 1 nebo 0 podle toho jestli existuji dany parametry nebo ne.
    
=cut

sub existLastParam {
    my ($self, $parameter) = @_;
    return 0 if (!exists($self->{'lastparameters'}->{$parameter}));
    return 1;
}

=head2 B<[Public] existLastParams()>

    Metoda vraci 1 nebo 0 podle toho jestli existoval jakykoliv parametr v minulem requestu.
    
=cut

sub existLastParams {
    my $self = shift;
    foreach (keys %{$self->{'lastparameters'}}) { return 1; }
    return 0;
}

=head2 B<[Public] isdefinedParam()>

    Metoda vraci 1 nebo 0 podle toho jestli parametr obsahuje hodnotu nebo ne, prazdny znak '' se povazuje za 0.
    
=cut

sub isdefinedParam {
    my ($self, $parameter) = @_;
    return 0 if (!$self->existParam($parameter));
    return 0 if (@{$self->{'parameters'}->{$parameter}}[0] =~ /^$/);
    return 1;
}

sub deleteGroup {
    my ($self, $name) = @_;
    delete $self->{'group'}->{$name};
}

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
        mkdir($dir) unless (-d $dir);
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

1;
