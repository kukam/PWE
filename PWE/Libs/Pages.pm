package Libs::Pages;

=head1 NAME

Libs::Pages - loader stranek, routing (callPageFunc), kontrola prav a deklarativni validace vstupu

=head1 POPIS

    Stranka = Pages/<X>/<X>.pm, package Pages::<X>::<X>. Loader ji nacte, injektuje Site_*/Service_*
    zavislosti, zaregistruje resource bundly a pri requestu zavola funkci registrovanou v $self->{'func'}.
    Pred funkci probehne validace podle atributu replace/defined/validate/rules/exist/unique.
    Pad metody stranky se izoluje (eval), stranka se znovu nacte a klient dostane 500.

=cut

use strict;
use Class::Inspector;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB, $SERVICES, $SITES);

=head2 B<[Public] new($conf,$log,$validate,$dbi,$user,$web,$entities,$services,$sites)>

    Konstruktor loaderu stranek. Ulozi si vsechny singletony enginu, najde a nacte vsechny
    stranky (loadPages) a zavola jejich autostart(). Vytvari se jako posledni v pwe.fcgi,
    protoze stranky zavisi na vsech ostatnich vrstvach.

=cut

sub new {
    my ($class, $conf, $log, $validate, $dbi, $user, $web, $entities, $services, $sites) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $WEB      = $web;
    $CONF     = $conf;
    $USER     = $user;
    $SITES    = $sites;
    $SERVICES = $services;
    $VALIDATE = $validate;
    $ENTITIES = $entities;

    my $self = {
        'pages'   => {},
        'methods' => {},
    };

    bless $self, $class;
    $self->loadPages();
    $self->autostarts();
    return $self;
}

=head2 B<[Private] loadPages()>

    Pro kazdou nalezenou stranku: loadPage (require + konstruktor + seznam metod), registerSite
    (injektaz Site_*), registerService (injektaz Service_*) a registerResourceBundle (mapa rb*.tmpl).
    Pokud se stranka nenacte, preskoci se a zaloguje chyba - server bezi dal.

=cut

sub loadPages {
    my $self = shift;
    foreach my $page ($self->findPages()) {

        # LOAD PAGE
        $LOG->delay("page_name_$page");
        my $result = $self->loadPage($page);
        $LOG->delay("page_name_$page", "Loaded page $page");

        next unless ($result);

        # LOAD SITE
        $LOG->delay("page_site_register_$page");
        $self->registerSite($page);
        $LOG->delay("page_site_register_$page", "Registring dependency site for page : $page");

        # LOAD SERVICE
        $LOG->delay("page_service_register_$page");
        $self->registerService($page);
        $LOG->delay("page_service_register_$page", "Registring dependency service for page : $page");

        # REGISTER RESOURCEBUNDLE
        $LOG->delay("page_resourcebundle_register_$page");
        $self->registerResourceBundle($page);
        $LOG->delay("page_resourcebundle_register_$page", "Registring dependency resourcebundle for page : $page");
    }
}

=head2 B<[Private] autostarts()>

    Zavola autostart() na vsech nactenych strankach, ktere tuto metodu maji.

=cut

sub autostarts {
    my $self = shift;
    foreach my $page (@{$self->getLoadPagesList()}) {
        $LOG->delay("page_autostart_$page");
        $self->autostart($page);
        $LOG->delay("page_autostart_$page", "Autostarting $page is completed");
    }
}

=head2 B<[Private] findPages()>

    Vrati abecedne serazeny seznam adresaru s <Adresar>/<Adresar>.pm ze vsech korenu
    (Libs::Config::getModuleRoots: nejdrive web, pak engine omezeny na pwe.core_pages).
    Stejny nazev ve webu i v enginu = modul webu (engine se preskoci). Jine adresare/soubory
    se ignoruji (konvence nazvu je striktni).

=cut

sub findPages {
    my $self = shift;
    my (@pages, %seen);
    foreach my $root ($CONF->getModuleRoots('pages')) {
        opendir(my $dh, $root->{'dir'}) or next;
        foreach my $page (readdir($dh)) {
            next if ($page =~ /^\./ or $seen{$page});
            next unless (-d "$root->{'dir'}/$page" and -f "$root->{'dir'}/$page/$page.pm");
            next if ($root->{'allowed'} and !$root->{'allowed'}->{$page});
            $seen{$page} = 1;
            push(@pages, $page);
        }
        closedir($dh);
    }
    @pages = sort { $a cmp $b } @pages;
    return @pages;
}

=head2 B<[Private] loadPage($page)>

    Nacte modul Pages::<page>::<page> (require) a zavola jeho konstruktor s predpripravenou
    strukturou $self (access, services_list, entities_list, sites_list, autostart) a vsemi
    singletony. Z Class::Inspector ulozi seznam verejnych metod do $self->{'methods'}->{$page}.
    Pri jakekoliv chybe stranku odregistruje a vrati 0, jinak 1.

    POZNAMKA: opakovane require uz nacteneho modulu kod znovu nekompiluje (%INC), "reload"
    po padu tedy znamena jen novou instanci objektu.

=cut

sub loadPage {
    my ($self, $page) = @_;

    eval "local \$SIG{__DIE__} = 'DEFAULT'; require Pages::${page}::${page};";

    if ($@) {
        chomp($@);
        $LOG->error("$@");
        $LOG->error("Loading page: failed to load $page");
        return 0;
    }

    my $object_structure = {
        'access'        => [],
        'services_list' => $SERVICES->getLoadServicesList(),
        'entities_list' => $ENTITIES->getLoadEntitiesList(),
        'sites_list'    => $SITES->getLoadSitesList(),
        'autostart'     => 0,
    };

    # BEZ TOHOTO SE NEDAJI PREDAT GLOBALNI PROMENE
    my $log      = $LOG;
    my $dbi      = $DBI;
    my $web      = $WEB;
    my $user     = $USER;
    my $conf     = $CONF;
    my $validate = $VALIDATE;
    my $entities = $ENTITIES;

    eval "local \$SIG{__DIE__} = 'DEFAULT'; \$self->{'pages'}->{\$page} = new Pages::${page}::${page}(\$object_structure,\$conf,\$log,\$validate,\$dbi,\$entities,\$user,\$web);";
    if ($@ or !$self->isExistPage($page)) {
        chomp($@);
        $LOG->error("$@");
        $LOG->error("Loading page: failed construction of $page [ FAILED ]");
        $self->unloadPage($page);
        return 0;
    }

    # SET METHOD LIST
    foreach my $method (@{Class::Inspector->methods("Pages::$page\:\:$page", 'full', 'public')}) {
        $method =~ s/.*\:\://;
        $self->{'methods'}->{$page}->{$method} = 1;
    }

    $LOG->debug("Loading page: $page [ OK ]");

    return 1;
}

=head2 B<[Private] registerSite($page)>

    Pro kazdou metodu stranky pojmenovanou Site_<Nazev> zavola tuto metodu s objektem
    vzhledu Sites::<Nazev> (dependency injection). Pokud vzhled neexistuje, stranku odregistruje.

=cut

sub registerSite {
    my ($self, $page) = @_;

    # REGISTR SITES OBJECTS
    foreach my $method (keys %{$self->{'methods'}->{$page}}) {
        if ($method =~ /^Site_(\S+)$/) {
            if ($SITES->isExistSite($1)) {
                my $SITE = $SITES->getSiteObject($1);
                $self->callPageMethod($page, "Site_$1", $SITE);
            } else {
                $LOG->error("Registred site object $1 not exist!");
                $self->unloadPage($page);
                return 0;
            }
        }
    }
}

=head2 B<[Private] registerService($page)>

    Pro kazdou metodu stranky pojmenovanou Service_<Nazev> zavola tuto metodu s objektem
    sluzby Services::<Nazev>. Pokud sluzba neexistuje, stranku odregistruje.

=cut

sub registerService {
    my ($self, $page) = @_;

    # REGISTR SERVICES OBJECTS
    foreach my $method (keys %{$self->{'methods'}->{$page}}) {
        if ($method =~ /^Service_(\S+)$/) {
            if ($SERVICES->isExistService($1)) {
                my $SERVICE = $SERVICES->getServiceObject($1);
                $self->callPageMethod($page, "Service_$1", $SERVICE);
            } else {
                $LOG->error("Registred service object $1 not exist!");
                $self->unloadPage($page);
                return 0;
            }
        }
    }
}

=head2 B<[Private] registerResourceBundle($page)>

    Metoda najde vsechny resource bundly (soubory rb*.tmpl) patrici strance $page a zaregistruje
    je pres $WEB->addResourceBundlePagePath($page, $lang, $path). Prohledava adresare (relativne
    k pwe.home): adresare vsech entit ($ENTITIES->getEntitiesResourceBundleDir()), Services/<X>/
    pro kazdou metodu Service_X stranky, Sites/<X>/ pro kazdou metodu Site_X a nakonec Pages/<page>/.

    Soubor rb.tmpl patri vychozimu jazyku, tj. prvnimu v conf http.languages; soubor
    rb_<LANG>.tmpl jazyku LANG (porovnava se bez ohledu na velikost pismen; jazyky, ktere
    v konfiguraci nejsou, se ignoruji). Vola se pri nacteni stranky (loadPages) a po jejim
    znovunacteni (reloadPage).

=cut

sub registerResourceBundle {
    my ($self, $page) = @_;

    my @paths = ();

    push(@paths, @{$ENTITIES->getEntitiesResourceBundleDir()});

    foreach my $method (keys %{$self->{'methods'}->{$page}}) {
        if ($method =~ /^Service_(\S+)$/) {
            push(@paths, $CONF->getValue("pwe", "services_dir", "Services/") . $1 . "/");
        }
    }

    foreach my $method (keys %{$self->{'methods'}->{$page}}) {
        if ($method =~ /^Site_(\S+)$/) {
            push(@paths, $CONF->getValue("pwe", "sites_dir", "Sites/") . $1 . "/");
        }
    }

    push(@paths, $CONF->getValue("pwe", "pages_dir", "Pages/") . $page . "/");

    my @langs = @{$CONF->getValue("http", "languages", [])};
    my $dlang = $langs[0];

    foreach my $rbroot (@paths) {
        # adresar modulu muze byt ve webu (pwe.home) nebo v enginu (pwe.core); web ma prednost
        my $home = $CONF->resolveDir($rbroot) or next;
        opendir(DIR, $home . $rbroot) or next;
        foreach my $x (grep !/^\.\.?$/, readdir(DIR)) {
            if (-f $home . $rbroot . "/" . $x and lc($x) =~ /^rb/) {
                if (lc($x) eq "rb.tmpl") {
                    $WEB->addResourceBundlePagePath($page, $dlang, $rbroot . $x);
                } else {
                    foreach my $lang (@langs) {
                        if (lc($x) eq lc("rb_" . $lang . ".tmpl")) {
                            $WEB->addResourceBundlePagePath($page, $lang, $rbroot . $x);
                        }
                    }
                }
            }
        }
        closedir(DIR);
    }
}

=head2 B<[Private] autostart($page)>

    Pokud ma stranka metodu autostart(), zavola ji (jednou pri startu serveru).
    Vraci 1 pokud se volalo, jinak 0.

=cut

sub autostart {
    my ($self, $page) = @_;

    # AUTOSTART
    if ($self->isExistPageMethod($page, "autostart")) {
        $LOG->info("autoexec page:$page method:autostart");
        $self->callPageMethod($page, "autostart");
        return 1;
    }

    return 0;
}

=head2 B<[Private] callPageMethod($page,$method,$value)>

    Bezpecne zavola metodu $method na objektu stranky s jednim argumentem $value (eval).
    Pri die: zaloguje, stranku odregistruje, posle e-mail report (sendErrorReport), stranku znovu
    nacte (reloadPage) a vrati 500. Navratova hodnota 1 (typicky z print) se mapuje na 200,
    ostatni hodnoty se vraci beze zmeny.

=cut

sub callPageMethod {
    my ($self, $page, $method, $value) = @_;

    my $result = undef;

    return 404 if (!$self->isExistPage($page));
    return 404 if (!$self->isExistPageMethod($page, $method));

    $LOG->delay("page_namemethod_$page");
    eval { local $SIG{__DIE__} = 'DEFAULT'; $result = $self->{'pages'}->{$page}->$method($value); };
    $LOG->delay("page_namemethod_$page", "Called page method, page:$page method: $method");

    if ($@) {
        chomp($@);
        my $error = $@;
        $LOG->error($error);
        $LOG->error("PAGE : $page METHOD: $method [ CRASHED ]");
        $self->unloadPage($page);
        $LOG->sendErrorReport("PAGE", $page, $method, $error);
        $self->reloadPage($page);
        return 500;
    }

    if ($result =~ /^\d+$/) {
        return 200 if ($result == 1);
    }

    return $result;
}

=head2 B<[Public] callPageFunc($page,$func)>

    Hlavni vstupni bod routingu: zavola funkci $func stranky $page (pouziva pwe.fcgi).

    Poradi: existence stranky a registrovane funkce (func) -> kontrola prav (accessFunc)
    -> deklarativni validace vstupu (checkInputData) -> pri chybe validace se misto
    $func zavola metoda z $self->{'error'}->{$func} s polem chyb, jinak $func.

    Navratove hodnoty (pwe.fcgi je mapuje na errorPage):
      undef/'' nebo 200 = v poradku (metoda stranky typicky konci print() -> 1 -> 200)
      404 = stranka/funkce neexistuje nebo neni registrovana ve 'func'
      401 = neopravneny pristup (uzivatel neni v povolene skupine)
      500 = metoda stranky spadla (die) nebo chybi metoda z atributu 'error'
      400 = spatny parametr (vraci ji typicky sama error metoda stranky)
    Jakekoliv jine cislo vracene metodou stranky se propaguje beze zmeny.

=cut

sub callPageFunc {
    my ($self, $page, $func) = @_;

    return 404 if (!$self->isExistPage($page));
    return 404 if (!$self->isExistPageFunc($page, $func));
    return 401 if (!$self->accessFunc($page, $func));

    # CALL METHOD
    $LOG->debug("System call page:$page method:$func");

    my $error = $self->checkInputData($page, $func);

    if ($error and $self->isExistPageAtribute($page, "error", $func)) {
        my $method = $self->getPageAtribute($page, "error", $func, undef);
        if ($self->isExistPageMethod($page, $method)) {
            return $self->callPageMethod($page, $method, $error);
        } else {
            $LOG->error("Method name: $method, page:$page not exists!");
            return 500;
        }
    } else {
        return $self->callPageMethod($page, $func, $error);
    }

}

=head2 B<[Private] reloadPage($page)>

    Znovunacteni stranky po padu: loadPage + registerSite + registerService + registerResourceBundle.
    Bez opetovne registrace by stranka po padu prisla o injektovane objekty a o i18n texty.
    Vraci 1/0 podle toho, zda je stranka po reloadu nactena.

=cut

sub reloadPage {
    my ($self, $page) = @_;

    return 0 unless ($self->loadPage($page));

    # Po znovunacteni je nutne znovu provest injektaz zavislosti a registraci
    # resource bundlu, jinak by stranka po padu prisla o i18n texty a o objekty Site_*/Service_*.
    $self->registerSite($page);
    $self->registerService($page);
    $self->registerResourceBundle($page) if ($self->isExistPage($page));

    return $self->isExistPage($page);
}

=head2 B<[Private] unloadPage($page)>

    Odregistruje stranku: smaze objekt, seznam metod a jeji resource bundle cesty ve $WEB.

=cut

sub unloadPage {
    my ($self, $page) = @_;

    $LOG->delay("unload_page");
    eval "no Pages::${page}::${page};";

    delete $self->{'pages'}->{$page};
    delete $self->{'methods'}->{$page};

    # CLEAR RESOURCEBUNDLE PATHS
    $WEB->delResourceBundlePagePaths($page);

    $LOG->delay("unload_page", "Unload page $page");
    $LOG->info("Unloading page:$page [ OK ]");
}

=head2 B<[Private] accessFunc($page,$func)>

    Kontrola prav ke spusteni funkce $func stranky $page podle skupin uzivatele ($USER->getGroup()).
    Stranka deklaruje povolene skupiny v atributech:

    $self->{'access'}        = ["admin", "user", ...];    # globalne pro vsechny funkce stranky
    $self->{'func'}->{$func} = ["admin", ...];            # jen pro danou funkci

    Pokud jsou oba seznamy prazdne, ma pristup kazdy (i 'guest'). Pokud je seznam u funkce
    neprazdny, rozhoduje jen on; jinak rozhoduje globalni seznam. Vraci 1 (povoleno) nebo 0
    (callPageFunc pak vraci 401).

=cut

sub accessFunc {
    my ($self, $page, $func) = @_;

    # GET PAGE OBJECT
    my $OBJ = $self->getPageObject($page);

    my $global_access = $OBJ->{'access'}        || [];
    my $func_access   = $OBJ->{'func'}->{$func} || [];
    my $groups = $USER->getValue("group", undef, {});

    return 1 if (@{$global_access} == 0 and @{$func_access} == 0);

    if (@{$func_access} > 0) {
        foreach my $group (@{$func_access}) {
            return 1 if (defined($groups->{$group}));
        }
    } else {
        foreach my $group (@{$global_access}) {
            return 1 if (defined($groups->{$group}));
        }
    }

    return 0;
}

=head2 B<[Private] checkInputData($page,$func)>

    Spusti deklarativni validaci vstupu pro funkci $func v poradi: replace (uprava hodnot),
    defined (povinne parametry), validate (kontrola entitou), rules (pravidla), exist (existence
    v DB), unique (unikatnost v DB). Kazda dalsi faze bezi jen pokud predchozi neprinesla chybu.
    Vraci undef (vse OK) nebo referenci na pole klicu chyb (napr. ['error_exist__email']).

=cut

sub checkInputData {
    my ($self, $page, $func) = @_;

    my $error     = undef;
    my $replace   = $self->getPageAtribute($page, "replace", $func, {});
    my $defined   = $self->getPageAtribute($page, "defined", $func, {});
    my $validates = $self->getPageAtribute($page, "validate", $func, []);
    my $exists    = $self->getPageAtribute($page, "exist", $func, []);
    my $uniques   = $self->getPageAtribute($page, "unique", $func, []);
    my $rules     = $self->getPageAtribute($page, "rules", $func, {});

    $error = $self->replaceInputParameters($page, $func, $replace, $error);

    unless (defined($error)) {
        $error = $self->checkDefined($page, $func, $defined, $error);
    }

    unless (defined($error)) {
        foreach my $validate (@{$validates}) {
            $error = $self->checkParameters($page, $func, $validate, $error);
        }
    }

    unless (defined($error)) {
        $error = $self->checkRules($page, $func, $rules, $error);
    }

    unless (defined($error)) {
        foreach my $exist (@{$exists}) {
            $error = $self->checkExist($page, $func, $exist, $error);
        }
    }

    unless (defined($error)) {
        foreach my $unique (@{$uniques}) {
            $error = $self->checkUnique($page, $func, $unique, $error);
        }
    }

    return $error;
}

=head2 B<[Private] replaceInputParameters($page,$func,$replace,$error)>

    Metoda upravi vstupni parametry podle atributu 'replace' stranky: kazdou hodnotu parametru
    protahne uvedenymi metodami a vysledek zapise zpet pres $USER->setParameter(), takze dalsi
    validace i funkce stranky uz pracuji s upravenou hodnotou. Puvodne vznikla kvuli ochrane
    proti JavaScript injection (escape_jsinjection).

    $replace je hash { nazev_parametru => [ metody ] } pro funkci $func; klic '*ALL*' znamena
    vsechny parametry requestu. Parametry, ktere v requestu nejsou vyplnene, se preskakuji.
    Metoda se zadava jako:
      'escape_jsinjection'           - metoda objektu Libs::Validate
      'Entities::Cpost::split_psc'   - metoda entity (chyba entity -> 'error_validate__<parametr>')
      'Services::Nazev::metoda'      - metoda sluzby
      'Pages::eorder::split_mobile'  - metoda (jine) stranky

    $self->{'replace'} = {
        'form' => {
            '*ALL*' => ['escape_jsinjection'],
            'psc'   => ['Entities::Cpost::split_psc'],
            'mob'   => ['escape_jsinjection', 'Pages::eorder::split_mobilenumber'],
        },
    };

    Pokud volana metoda spadne, prida se chyba 'InternalError_<metoda>' a zpracovani konci.
    Vraci $error (undef nebo referenci na pole klicu chyb).

=cut

sub replaceInputParameters {
    my ($self, $page, $func, $replace, $error) = @_;

    return undef unless ($self->isExistPageAtribute($page, "replace", $func));

    # Reset iteratoru each() - predchozi pruchod mohl skoncit predcasne (last LAST)
    # a hash je sdileny mezi requesty (atribut stranky).
    keys %{$replace};

  LAST: while (my ($parkey, $arguments) = each(%{$replace})) {

        my $parameters = [];

        # Vytvorime seznam parametru ktere umistime do pole
        if ($parkey eq "*ALL*") {
            $parameters = $USER->getParamsList();
        } else {
            next unless ($USER->isdefinedParam($parkey));
            push(@{$parameters}, $parkey);
        }

        # projdeme vsechny parametry ve vytvoreneme poli a vsechny jejich hodnoty protahneme
        # replacovacima metodama, vysledek nasetujeme do uzivatelskych parametru ($USER->setParameter)
        foreach my $meth (@{$arguments}) {
            foreach my $parameter_name (@{$parameters}) {
                my $array_position = 0;
                foreach my $parameter_value (@{$USER->getParam($parameter_name, "all", [])}) {
                    if ($meth =~ /Entities\:\:\S+\:\:\S+/) {
                        my ($root, $entitie, $method) = split(/\:\:/, $meth);
                        my $ENTITIE = $ENTITIES->getEntityObject($entitie);
                        my ($result, $new_parameter_value) = $self->replaceInputParametersHelper($page, $ENTITIE, $method, $parameter_value);
                        if (@{$ENTITIE->getErrorList()} > 0) {
                            foreach my $errtxt (@{$ENTITIE->getErrorList()}) { $LOG->error($errtxt); }
                            push(@{$error}, "error_validate__$parameter_name");
                            last LAST;
                        } elsif (defined($result)) {
                            $USER->setParameter($parameter_name, $new_parameter_value, $array_position);
                        } else {
                            push(@{$error}, "InternalError_$meth");
                            last LAST;
                        }
                    } elsif ($meth =~ /Services\:\:\S+\:\:\S+/) {
                        my ($root, $service, $method) = split(/\:\:/, $meth);
                        my $SERVICE = $SERVICES->getServiceObject($service);
                        my ($result, $new_parameter_value) = $self->replaceInputParametersHelper($page, $SERVICE, $method, $parameter_value);
                        if (defined($result)) {
                            $USER->setParameter($parameter_name, $new_parameter_value, $array_position);
                        } else {
                            push(@{$error}, "InternalError_$meth");
                            last LAST;
                        }
                    } elsif ($meth =~ /Pages\:\:\S+\:\:\S+/) {
                        my ($root, $pagename, $method) = split(/\:\:/, $meth);
                        my $PAGE = $self->getPageObject($pagename);
                        my ($result, $new_parameter_value) = $self->replaceInputParametersHelper($page, $PAGE, $method, $parameter_value);
                        if (defined($result)) {
                            $USER->setParameter($parameter_name, $new_parameter_value, $array_position);
                        } else {
                            push(@{$error}, "InternalError_$meth");
                            last LAST;
                        }
                    } else {
                        my ($result, $new_parameter_value) = $self->replaceInputParametersHelper($page, $VALIDATE, $meth, $parameter_value);
                        if (defined($result)) {
                            $USER->setParameter($parameter_name, $new_parameter_value, $array_position);
                        } else {
                            push(@{$error}, "InternalError_VALIDATE::$meth");
                            last LAST;
                        }
                    }
                    $array_position++;
                }
            }
        }
    }
    return $error;
}

=head2 B<[Private] replaceInputParametersHelper($page,$object,$method,$value)>

    Pomocna metoda pro replaceInputParameters(): v eval zavola $object->$method($value) a vraci
    seznam (1, $nova_hodnota). Pokud metoda spadne (die), chybu zaloguje, stranku $page
    odregistruje, posle e-mail report (sendErrorReport), stranku znovu nacte a vraci (undef, undef).

=cut

sub replaceInputParametersHelper {
    my ($self, $page, $object, $method, $value) = @_;

    my $return = undef;

    eval { local $SIG{__DIE__} = 'DEFAULT'; $return = $object->$method($value); };

    if ($@) {
        chomp($@);
        my $error = $@;
        $LOG->error($error);
        $LOG->error("PAGE : $page [ CRASHED ]");
        $self->unloadPage($page);
        $LOG->sendErrorReport("PAGE", $page, $method, $error);
        $self->reloadPage($page);
        return (undef, undef);
    }

    return (1, $return);

}

=head2 B<[Private] checkDefined($page,$func,$opt,$error)>

    Metoda kontroluje podle atributu 'defined' stranky, zda jsou v requestu vyplneny vsechny
    povinne parametry ($USER->isdefinedParam). Za kazdy chybejici parametr prida do $error klic
    'error_exist__<prefix><parametr>'. Klice atributu (login_form, ...) jsou nazvy funkci stranky;
    $opt je hash pro funkci $func s temito klici:

    prefix     = spolecny prefix vsech parametru v hashi, aby se nemusel psat u kazdeho (nepovinne)
    parameters = pole nazvu povinnych parametru; zapis 'a||b' znamena NEBO (staci jeden z nich,
                 pripadna chyba se hlasi pod prvni alternativou); zapis 'if[p="v"]x' znamena,
                 ze parametr x je povinny jen tehdy, kdyz ma parametr p hodnotu v
    <parametr> = vnoreny hash stejne struktury, ktery se kontroluje jen tehdy, kdyz je parametr
                 <parametr> vyplneny (viz 'difadd' nize); vnorovat lze libovolne hluboko

    $self->{'defined'} = {
        login_form => {
            parameters => [ 'login', 'pass' ],
        },
        password_form => {
            parameters => [ 'pass', 'pass1', 'pass2' ],
        },
        myprofile_form => {
            parameters => [ 'surname||firm', 'email', 'customer', 'town', 'street', 'streetnumber', 'zipcode' ],
            difadd => {
                prefix     => "different_",
                parameters => [ 'surname||firm', 'town', 'street', 'streetnumber', 'zipcode' ],
            },
        },
        customer_form => {
            parameters => [ 'if[customer="P"]surname', 'if[customer="C"]firm', 'email', 'customer' ],
        },
    };

    Vraci $error (undef nebo referenci na pole klicu chyb).

=cut

sub checkDefined {
    my ($self, $page, $func, $opt, $error) = @_;

    return $error unless ($self->isExistPageAtribute($page, "defined", $func));

    my $prefix = $opt->{'prefix'};
    my @params = @{$opt->{'parameters'}};

  NEXT: foreach my $param (@params) {
        if ($param =~ /^\S+\|\|\S+/) {
            my $e = [];
            foreach (split(/\|\|/, $param)) {
                next NEXT if ($USER->isdefinedParam($prefix . $_));
                push(@{$e}, "error_exist__$prefix$_");
            }
            foreach (@{$e}) {
                push(@{$error}, $_);
                $LOG->error("Not-defined input parameter(1) page:$page, func:$func, parameter:$_");
                next NEXT;
            }
        } elsif ($param =~ /^if\[(\S+)\=\"(\S+)\"](\S+)/) {
            next NEXT if (!$USER->isdefinedParam($prefix . $1));
            foreach my $value (@{$USER->getParam($prefix . $1, "all", [])}) {
                next NEXT if ($value ne $2);
                if (!$USER->isdefinedParam($prefix . $3)) {
                    push(@{$error}, "error_exist__$prefix$3");
                    $LOG->error("Not-defined input parameter(2) page:$page, func:$func, parameter:$prefix$3");
                }
            }
        } elsif (!$USER->isdefinedParam($prefix . $param)) {
            push(@{$error}, "error_exist__$prefix$param");
            $LOG->error("Not-defined input parameter(3) page:$page, func:$func, parameter:$prefix$param");
        }
    }

    foreach my $key (keys %{$opt}) {
        next if (ref($opt->{$key}) ne "HASH");
        next if (!$USER->isdefinedParam($prefix . $key));
        $error = checkDefined($self, $page, $func, $opt->{$key}, $error);
    }

    return $error;
}

=head2 B<[Private] checkExist($page,$func,$opt,$error)>

    Metoda overuje podle atributu 'exist' stranky existenci nebo neexistenci hodnot parametru
    v databazi - jednoducha kontrola, zda napr. id, e-mail nebo md5sum uz v dane tabulce
    a sloupci je, nebo neni. Hodnota se nejdrive protahne metodou sloupce entity (validace
    a uprava hodnoty) a pak se dotazem "SELECT 1 FROM <tabulka> WHERE <sloupec> = ?" pres DAO
    entity zjisti, zda existuje. Pokud se nazev parametru lisi od nazvu sloupce, pouzije se
    zapis '<parametr>#<sloupec>'.

    Atribut je pro kazdou funkci pole hashu ($opt je jeden z nich) s klici:

    prefix     = spolecny prefix vsech parametru v hashi (nepovinne)
    parameters = pole parametru, ktere se kontroluji
    entity     = nazev entity ('Entities::User'), jejiz tabulka a metody sloupcu se pouziji
    exist      = 1 = chyba, kdyz hodnota v DB existuje ('error_exist__<prefix><parametr>')
                 0 = chyba, kdyz hodnota v DB neexistuje ('error_not_exist__<prefix><parametr>')
    <parametr> = vnoreny hash stejne struktury, kontroluje se jen tehdy, kdyz je parametr
                 vyplneny (viz 'difadd' nize)

    $self->{'exist'} = {
        'login_form' => [
            {
                entity     => 'Entities::User',
                parameters => [ 'login', 'useremail#email' ],
                exist      => 0,
            },
        ],
        'myprofile_form' => [
            {
                entity     => 'Entities::User',
                parameters => [ 'uid', 'useremail#email' ],
                exist      => 1,
                difadd => {
                    prefix     => "different_",
                    entity     => 'Entities::UserAddress',
                    parameters => [ 'did' ],
                    exist      => 0,
                },
            },
        ],
    };

    Nevyplnene parametry se preskakuji. Pokud hodnota neprojde validaci metodou sloupce, prida se
    'Internal_error-int_validate:<tabulka>:<sloupec>' (resenim je pridat na stranku i atribut
    'validate'). Chybejici entita nebo metoda sloupce se hlasi jako 'Internal_error-...'.
    Vraci $error (undef nebo referenci na pole klicu chyb).

=cut

sub checkExist {
    my ($self, $page, $func, $opt, $error) = @_;

    return $error unless ($self->isExistPageAtribute($page, "exist", $func));

    my $prefix = $opt->{'prefix'};
    my @params = @{$opt->{'parameters'}};
    my $entity = $opt->{'entity'} || return ["Internal_Error_atribute_entity_not_defined"];
    my $exist  = $opt->{'exist'};

    my ($entity_root, $entity_name) = split(/\:\:/, $entity);

    unless ($ENTITIES->isExistEntity($entity_name)) {
        $LOG->error("Entities:$entity_name not exists!");
        push(@{$error}, "Internal_error-entity_not_exist:$entity_name");
        return $error;
    }

    my $ENTITY     = $ENTITIES->getEntityObject($entity_name);
    my $table_name = $ENTITY->getTableName();

    foreach (@params) {

        my ($pname, $cname) = $self->getPnameCname($_);
        next unless ($USER->isdefinedParam($prefix . $pname));

        foreach my $value (@{$USER->getParam($prefix . $pname, "all", [])}) {

            # Nad timto objektm nechceme provadet kontrolu na unikatnost
            $ENTITY->setUniqueCheckValue(0);

            unless ($ENTITY->existsPublicMethodName($cname)) {
                $LOG->error("Entities:$entity_name method:$cname not exists!");
                push(@{$error}, "Internal_error-entity`s_name_not_exist:$entity_name:$cname");
                return $error;
            }

            # Validace + Oprava (uprava) hodnoty
            $value = $ENTITY->$cname($value);

            if ($ENTITY->error()) {

                # Tato chyba vznika v pripade, ze neprovedeme klasickou validaci a rovnou kontrolujeme na existenci.
                # Staci na strance pridat klasickou validaci hodnot, a tato chyba se nebude vyskytovat.
                my $error_result = "Internal_error-int_validate:$table_name:$cname";
                $LOG->error("Invalid input parameter: page:$page, func:$func, parameter:$prefix$pname, value:'$value' validate_result:'$error_result'");
                push(@{$error}, $error_result);
            } else {
                # Dotaz jde pres DAO entity (jeji vlastni spojeni/dbid), ne natvrdo pres "db1".
                my $SQL = $ENTITY->select("1 FROM $table_name WHERE $cname = ?", [$value]);
                my $result = $SQL->fetchrow_array();
                $SQL->finish;
                if ($result and $exist) {
                    my $error_result = "error_exist__" . $prefix . $pname;
                    push(@{$error}, $error_result);
                    $LOG->error("Invalid input parameter: page:$page, func:$func, parameter:$prefix$pname, value:'$value' validate_result:'$error_result'");
                } elsif (!$result and !$exist) {
                    my $error_result = "error_not_exist__" . $prefix . $pname;
                    push(@{$error}, $error_result);
                    $LOG->error("Invalid input parameter: page:$page, func:$func, parameter:$prefix.$pname, value:'$value' validate_result:'$error_result'");
                }
            }

            $ENTITY->setUniqueCheckValue(1);

        }
    }

    foreach my $key (keys %{$opt}) {
        next if (ref($opt->{$key}) ne "HASH");
        next if (!$USER->isdefinedParam($prefix . $key));
        $error = checkExist($self, $page, $func, $opt->{$key}, $error);
    }

    return $error;
}

=head2 B<[Private] checkParameters($page,$func,$opt,$error)>

    Metoda zvaliduje hodnoty parametru podle atributu 'validate' stranky tim, ze je necha
    zkontrolovat metodami sloupcu uvedene entity ($ENTITIES->validate). Pri neplatne hodnote
    prida do $error klic 'error_validate__<parametr>' (nazev parametru bez prefixu).
    Pokud se nazev parametru lisi od nazvu sloupce entity, pouzije se zapis '<parametr>#<sloupec>'.

    Atribut je pro kazdou funkci pole hashu ($opt je jeden z nich) s klici:

    prefix     = spolecny prefix vsech parametru v hashi (nepovinne)
    parameters = pole parametru, ktere se validuji
    entity     = nazev entity ('Entities::User'), jejimiz metodami sloupcu se hodnoty validuji
    <parametr> = vnoreny hash stejne struktury, kontroluje se jen tehdy, kdyz je parametr
                 vyplneny (viz 'difadd' nize); vnorovat lze libovolne hluboko

    $self->{'validate'} = {
        'login_form' => [
            {
                entity     => 'Entities::User',
                parameters => [ 'login', 'password#pass' ],
            },
        ],
        'myprofile_form' => [
            {
                entity     => 'Entities::User',
                parameters => [ 'difadd', 'firstname', 'sname#surname', 'firm', 'email', 'customer', 'town', 'street', 'streetnumber', 'zipcode' ],
                difadd => {
                    prefix     => "different_",
                    entity     => 'Entities::UserAddress',
                    parameters => [ 'firstname', 'surname', 'town', 'street', 'streetnumber', 'zipcode' ],
                },
            },
        ],
    };

    Nevyplnene parametry se preskakuji. Vraci $error (undef nebo referenci na pole klicu chyb).

=cut

sub checkParameters {
    my ($self, $page, $func, $opt, $error) = @_;

    return $error unless ($self->isExistPageAtribute($page, "validate", $func));

    my $prefix = $opt->{'prefix'};
    my @params = @{$opt->{'parameters'}};
    my $entity = $opt->{'entity'} || return ["Internal_Error_atribute_entity_not_defined"];

    foreach (@params) {

        my ($pname, $cname) = $self->getPnameCname($_);
        next unless ($USER->isdefinedParam($prefix . $pname));

        foreach my $value (@{$USER->getParam($prefix . $pname, "all", [])}) {
            my $result = $ENTITIES->validate([$entity . "::" . $cname, $pname, $value]);
            if ($result) {
                push(@{$error}, $result);
                $LOG->error("Invalid input parameter: page:$page, func:$func, parameter:$prefix$pname, value:'$value' validate_result:'$result'");
            }
        }
    }

    foreach my $key (keys %{$opt}) {
        next if (ref($opt->{$key}) ne "HASH");
        next if (!$USER->isdefinedParam($prefix . $key));
        $error = checkParameters($self, $page, $func, $opt->{$key}, $error);
    }

    return $error;
}

=head2 B<[Private] checkUnique($page,$func,$opt,$error)>

    Metoda kontroluje podle atributu 'unique' stranky unikatnost hodnot parametru v databazi
    pres entitu ($ENTITIES->validate s primarnim klicem). Pro kazdou hodnotu parametru 'primary'
    (pri INSERTu parametr v requestu chybi a pouzije se 0 = novy radek; pri UPDATE je to id
    radku, ktery se z kontroly vynecha) se hodnoty parametru zvaliduji metodami sloupcu entity
    se zapnutou kontrolou unikatnosti. Pri duplicite se prida klic 'error_validate_unique__<parametr>',
    pri neplatne hodnote 'error_validate__<parametr>'. Pokud se nazev parametru lisi od nazvu
    sloupce, pouzije se zapis '<parametr>#<sloupec>'.

    Atribut je pro kazdou funkci pole hashu ($opt je jeden z nich) s klici:

    prefix     = spolecny prefix vsech parametru v hashi (nepovinne)
    parameters = pole parametru, ktere se kontroluji
    entity     = nazev entity ('Entities::User')
    primary    = nazev parametru s primarnim klicem radku (povinne; pri INSERTu nemusi byt
                 v requestu, pak se kontroluje jako novy radek)
    <parametr> = vnoreny hash stejne struktury, kontroluje se jen tehdy, kdyz je parametr vyplneny

    $self->{'unique'} = {
        'login_form' => [
            {
                entity     => 'Entities::User',
                parameters => [ 'parameter1#column1', 'column2' ],
                primary    => 'columnPrimaryID',
            },
        ],
        'register_form' => [
            {
                entity     => 'Entities::User',
                primary    => 'columnPrimaryID',
                parameters => [ 'parameter1#column1', 'column2' ],
                column1 => {
                    prefix     => "different_",
                    entity     => 'Entities::UserAddress',
                    primary    => 'columnPrimaryID',
                    parameters => [ 'parameter1#column1', 'columnX' ],
                },
            },
        ],
    };

    Nevyplnene parametry se preskakuji. Vraci $error (undef nebo referenci na pole klicu chyb).

=cut

sub checkUnique {
    my ($self, $page, $func, $opt, $error) = @_;

    return $error unless ($self->isExistPageAtribute($page, "unique", $func));

    my $prefix  = $opt->{'prefix'};
    my @params  = @{$opt->{'parameters'}};
    my $entity  = $opt->{'entity'} || return ["Internal_Error_atribute_entity_not_defined"];
    my $primary = $opt->{'primary'} || return ["Internal_Error_atribute_primary_not_defined"];

    # Hodnota undef je predkladana jako defaultni schvalne, bez ni by neslo validovat nad insertovanymi daty.
    foreach my $primaryID (@{$USER->getParam($prefix . $primary, "all", [0])}) {
        foreach (@params) {

            my ($pname, $cname) = $self->getPnameCname($_);
            next unless ($USER->isdefinedParam($prefix . $pname));

            foreach my $value (@{$USER->getParam($prefix . $pname, "all", [])}) {

                my $result = $ENTITIES->validate([$entity . "::" . $cname . "::" . $primaryID, $pname, $value]);

                if ($result) {
                    push(@{$error}, $result);
                    $LOG->error("Invalid input parameter: page:$page, func:$func, parameter:$prefix$pname, value:'$value' validate_result:'$result'");
                }
            }
        }
    }

    foreach my $key (keys %{$opt}) {
        next if (ref($opt->{$key}) ne "HASH");
        next if (!$USER->isdefinedParam($prefix . $key));
        $error = checkUnique($self, $page, $func, $opt->{$key}, $error);
    }

    return $error;
}

=head2 B<[Private] checkRules($page,$func,$rules,$error)>

    Kontrola vstupnich hodnot podle pravidel v atributu 'rules' stranky:

    $self->{'rules'}->{'func'}->{'parametr'} = [
        [ 'is_numeric', 'error_num', 'parametr' ],
        [ 'is_enum', 'error_enum', 'parametr', 'a', 'b', 'c' ],
        [ 'Services::Nazev::is_pid', 'error_pid', 'parametr' ],
        [ 'Entities::Nazev::pid', 'error_pid', 'parametr' ],
        [ 'Pages::Nazev::metoda', 'error_x', 'parametr' ],
    ];

    Kazde pravidlo je pole:
      1. pozice:    nazev validacni metody - bez prefixu metoda objektu Libs::Validate, jinak
                    'Entities::<X>::<sloupec>', 'Services::<X>::<metoda>' nebo 'Pages::<X>::<metoda>'
      2. pozice:    klic chyby, ktery se pri neuspechu prida do $error
      3. pozice:    zastupne misto - engine sem pred volanim dosadi aktualni hodnotu parametru
      dalsi pozice: dalsi argumenty predane validacni metode

    Kontroluji se jen vyplnene parametry ($USER->isdefinedParam), kazda hodnota parametru zvlast.
    Pri prvnim neuspesnem pravidle se zapamatuje jeho klic chyby a prejde se na dalsi parametr.
    Vraci $error doplnene o klice chyb.

=cut

sub checkRules {
    my ($self, $page, $func, $rules, $error) = @_;

    return undef unless ($self->isExistPageAtribute($page, "rules", $func));

    my $result = {};

    # Reset iteratoru each() (hash je sdileny mezi requesty - atribut stranky).
    keys %{$rules};

  NEXT: while (my ($parameter_name, $arguments) = each(%{$rules})) {
        next unless ($USER->isdefinedParam($parameter_name));
        foreach my $arg (@{$arguments}) {
            my $meth      = @{$arg}[0];
            my $error_txt = @{$arg}[1];
            foreach my $parameter_value (@{$USER->getParam($parameter_name, "all", [])}) {
                my $res = 0;

                # nahradime 2 pozici hodnotou parametru '$parameter_name'
                splice(@{$arg}, 2, 1, $parameter_value);
                if ($meth =~ /Entities\:\:\S+\:\:\S+/) {
                    $res = $ENTITIES->validate($arg);
                } elsif ($meth =~ /Services\:\:\S+\:\:\S+/) {
                    $res = $SERVICES->validate($arg);
                } elsif ($meth =~ /Pages\:\:\S+\:\:\S+/) {
                    $res = $self->validate($arg);
                } else {
                    $res = $VALIDATE->validate($arg);
                }

                if (defined($res)) {
                    $result->{$error_txt} = 1;
                    $LOG->error("Invalid rule: $meth $parameter_name:$parameter_value");
                    next NEXT;
                } else {
                    $LOG->debug("Check rules: $parameter_name, parameter_value: $parameter_value, method:$meth, args:[ " . join(",", @{$arg}) . " ]");
                }
            }
        }
    }

    foreach (keys %{$result}) { push(@{$error}, $_); }
    return $error;
}

=head2 B<[Private] validate([ 'Pages::<page>::<metoda>', $error_key, $value, @args ])>

    Zavola validacni metodu jine (nebo stejne) stranky z pravidla 'rules'. Metoda stranky musi
    vratit definovanou hodnotu = OK; undef = chyba -> vraci se $error_key. Pri padu metody
    stranku odregistruje a die (chyba se propaguje do pwe.fcgi).

=cut

sub validate {
    my $self = shift;
    my @args = (@{$_[0]});

    my ($root, $page, $method) = split(/\:\:/, $args[0]);

    unless ($self->isExistPageMethod($page, $method)) {
        $LOG->error("Checking method Pages::$page::$method not exists!");
        return "Internal_error-page`s_method_not_exist:$page:$method";
    }

    my $result = undef;
    my $error  = $args[1];
    splice(@args, 0, 2);
    my $PAGE = $self->getPageObject($page);

    eval { local $SIG{__DIE__} = 'DEFAULT'; $result = $PAGE->$method(@args); };

    if ($@) {
        chomp($@);
        my $error = $@;
        $LOG->error($error);
        $LOG->error("PAGE : $page [ CRASHED ]");
        $self->unloadPage($page);
        $LOG->sendErrorReport("PAGE", $page, $method, $error);
        die "Internal error, unknown method page:$page, method:$method";
    }

    return $error unless (defined($result));
    return undef;
}

=head2 B<[Public] getLoadPagesList()>

    Vraci referenci na pole nazvu vsech aktualne nactenych stranek.

=cut

sub getLoadPagesList {
    my $self   = shift;
    my $result = [];
    foreach (keys %{$self->{'pages'}}) { push(@{$result}, $_); }
    return $result;
}

=head2 B<[Public] getPageObject($page)>

    Vraci instanci stranky $page, nebo undef (a zaloguje chybu), pokud neni nactena.

=cut

sub getPageObject {
    my ($self, $page) = @_;
    if ($self->isExistPage($page)) {
        return $self->{'pages'}->{$page};
    } else {
        $LOG->error("Unknown page $page !");
    }
}

=head2 B<[Private] getPageAtribute($page,$key,$value,$default)>

    Vraci atribut stranky $self->{$key}->{$value} (napr. 'defined' pro funkci 'form');
    bez $value vraci cely $self->{$key}. Pokud atribut neexistuje, vraci $default.

=cut

sub getPageAtribute {
    my ($self, $page, $key, $value, $default) = @_;
    return $default unless ($self->isExistPageAtribute($page, $key, $value));
    my $OBJ = $self->getPageObject($page);
    return $OBJ->{$key}->{$value} if (defined($value));
    return $OBJ->{$key};
}

=head2 B<[Private] getPnameCname($value)>

    Pomocna metoda validacnich metod (checkExist, checkParameters, checkUnique). Rozdeli zapis
    '<parametr>#<sloupec>' na seznam (nazev_parametru, nazev_sloupce); pokud zapis '#'
    neobsahuje, vraci ($value, $value).

=cut

sub getPnameCname {
    my ($self, $value) = @_;
    if ($value =~ /#/) {
        return split(/#/, $value);
    } else {
        return ($value, $value);
    }
}

=head2 B<[Public] isExistPage($page)>

    Vraci 1/0 podle toho, zda je stranka nactena.

=cut

sub isExistPage {
    my ($self, $page) = @_;
    return 1 if (defined($self->{'pages'}->{$page}));
    return 0;
}

=head2 B<[Public] isExistPageMethod($page,$method)>

    Vraci 1/0 podle toho, zda ma nactena stranka verejnou metodu $method (dle Class::Inspector).

=cut

sub isExistPageMethod {
    my ($self, $page, $method) = @_;
    return 0 if (!$self->isExistPage($page));
    return 0 if (!defined($self->{'methods'}->{$page}->{$method}));
    return 1;
}

=head2 B<[Private] isExistPageAtribute($page,$key,$value)>

    Vraci 1/0 podle existence atributu $self->{$key} (a pripadne podklice $value) ve strance.

=cut

sub isExistPageAtribute {
    my ($self, $page, $key, $value) = @_;
    return 0 if (!$self->isExistPage($page));
    my $OBJ = $self->getPageObject($page);
    return 0 if (!exists($OBJ->{$key}));
    return 1 if (!defined($value));
    return 0 if (!exists($OBJ->{$key}->{$value}));
    return 1;
}

=head2 B<[Public] isExistPageFunc($page,$func)>

    Vraci 1 jen pokud metoda $func existuje A JE registrovana v $self->{'func'} stranky.
    Jen takove metody jsou volatelne pres ?page=X&func=Y.

=cut

sub isExistPageFunc {
    my ($self, $page, $func) = @_;
    return 0 if (!$self->isExistPage($page));
    return 0 if (!$self->isExistPageMethod($page, $func));
    return 0 if (!defined($self->{'pages'}->{$page}->{'func'}));
    return 0 if (!exists($self->{'pages'}->{$page}->{'func'}->{$func}));
    return 1;
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
    require Libs::User;
    require Libs::Web;
    require Libs::Services;
    require Libs::Validate;
    require Libs::Entities;
    require Libs::Sites;
    $LOG      = new Libs::Log;
    $CONF     = new Libs::Config;
    $DBI      = new Libs::DBI;
    $USER     = new Libs::User;
    $WEB      = new Libs::Web;
    $SERVICES = new Libs::Services;
    $VALIDATE = new Libs::Validate;
    $ENTITIES = new Libs::Entities;
    $SITES    = new Libs::Sites;
}

1;
