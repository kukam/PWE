package Libs::Pages;

use strict;
use Class::Inspector;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB, $SERVICES, $SITES);

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

sub autostarts {
    my $self = shift;
    foreach my $page (@{$self->getLoadPagesList()}) {
        $LOG->delay("page_autostart_$page");
        $self->autostart($page);
        $LOG->delay("page_autostart_$page", "Autostarting $page is completed");
    }
}

sub findPages {
    my $self = shift;
    my @pages;
    my $dir = $self->getPagesDir();
    opendir(PDH, $dir);
    foreach my $page (readdir(PDH)) {
        next if ($page =~ /^\./);
        next unless (-d "$dir/$page");
        next unless (-f "$dir/$page/$page.pm");
        push @pages, $page;
    }
    closedir(PDH);
    @pages = sort { $a cmp $b } @pages;
    return @pages;
}

sub loadPage {
    my ($self, $page) = @_;

    eval "\$SIG{__DIE__}='DEFAULT'; require Pages::${page}::${page};";

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

    eval "\$SIG{__DIE__}='DEFAULT'; \$self->{'pages'}->{\$page} = new Pages::${page}::${page}(\$object_structure,\$conf,\$log,\$validate,\$dbi,\$entities,\$user,\$web);";
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

=head2 B<[Public] registerResourceBundle($page)>

    Metoda vytvori mapu vsech resourcbandlu s vazbou na stranku a zapise ji do objektu $WEB->addResourceBundlePath($pagename,$lang,$path).

    Za vychozi jazyk (rb.tmpl) je povazovan ten, ktery je jako prvni v poli.
    my $default_laungage = @{$CONF->getValue("http", "languages", [])}[0];    
=cut

sub registerResourceBundle {
    my ($self, $page) = @_;

    my @paths = [];

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

    my $home = $CONF->getValue("pwe", "home", "/tmp/");
    my @langs = @{$CONF->getValue("http", "languages", [])};
    my $dlang = $langs[0];

    foreach my $rbroot (@paths) {
        opendir(DIR, $home . $rbroot);
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
        close(DIR);
    }
}

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

sub callPageMethod {
    my ($self, $page, $method, $value) = @_;

    my $result = undef;

    return 404 if (!$self->isExistPage($page));
    return 404 if (!$self->isExistPageMethod($page, $method));

    $LOG->delay("page_namemethod_$page");
    eval "\$SIG{__DIE__}='DEFAULT'; \$result = \$self->{'pages'}->{\$page}->\$method(\$value);";
    $LOG->delay("page_namemethod_$page", "Called page method, page:$page method: $method");

    if ($@) {
        chomp($@);
        my $error = $@;
        $LOG->error($error);
        $LOG->error("PAGE : $page METHOD: $method [ CRASHED ]");
        $self->unloadPage($page);
        $LOG->sendErrorReport("PAGE", $page, $method, $error);
        $self->loadPage($page);
        return 500;
    }

    if ($result =~ /^\d+$/) {
        return 200 if ($result == 1);
    }

    return $result;
}

=head2 B<[Public] callPageFunc($page,$func)>

    metoda zavola prikaz v pageu.
    
    return 0 = vse probehlo v poradku
    return 1 = page/command neexistuje
    return 2 = pri zavolani prikazu se vyskytla chyba v kodu
    return 3 = neopravneny pristup (spatna uzivatlska skupina)
    return 4 = spatny parametr
        
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
    
    Kontrola prav ke spusteni prikazu.
        
    parametry global_access,func_access:

    ["admin","user",....]
    
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

=head2 B<[Private] replaceInputParameters($page,$func,$replace)>

    Metoda na zvolenych vstupnich datech provede kontrolu a zmeny ulozi do objektu USERS,
    kde se nahradi puvodni vstupni data za upravena.
    
    NOTE: Tato metoda puvodne vznikla pro replasovani JavascriptInjetions. 

    $self->{'replace'} = {
    'form' => {
        '*ALL*' => ['escape_jsinjection'],
    },
    };

    OR
    
    $self->{'replace'} = {
    'form' => {
        'psc' => ['Entities::Cpost::split_psc'],
    },
    };

    OR
    
    $self->{'replace'} = {
    'form' => {
        'mob' => ['escape_jsinjection', 'Pages::eorder::split_mobilenumber'],
    },
    };
    
=cut

sub replaceInputParameters {
    my ($self, $page, $func, $replace, $error) = @_;

    return undef unless ($self->isExistPageAtribute($page, "replace", $func));

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

    Tato metoda funguje jako pomocna metoda pro stejne se opakujici kod v metode replaceInputParameters.

=cut

sub replaceInputParametersHelper {
    my ($self, $page, $object, $method, $value) = @_;

    my $return = undef;

    eval "\$SIG{__DIE__}='DEFAULT'; \$return = \$object->\$method(\$value);";

    if ($@) {
        chomp($@);
        my $error = $@;
        $LOG->error($error);
        $LOG->error("PAGE : $page [ CRASHED ]");
        $self->unloadPage($page);
        $LOG->sendErrorReport("PAGE", $page, $method, $error);
        $self->loadPage($page);
        return (undef, undef);
    }

    return (1, $return);

}

=head2 B<[Private] checkDefined($page,$func,$opt,$error)>

    Metoda kontroluje zdali jsou definovany vsechny potrebne parametry.
    Atributy (login_form,password_form,myprofile_form) reprezentuji jmeno funkce.
    v hashi jsou pak atributy jako:
    prefix = pokud se u vsech parametru opakuje stejny prefix, pak nema cenu psat ho vsude. (nepovina volba)
    parameters = [seznam parametru v poli, pokud jsou parametry oddelene znakem '||' pak se chape jako OR (NEBO)]
    parametr = {
        pokud potrebujeme navazat na parametr dalsi definovane parametry tak se to definuje zase stejnym hashem,
        takto muzeme vnorovat dalsi a dalsi zavyslosti do sebe, viz ukazka c.3 vazba na parametr difadd
        (pokud existuje parametr difadd, pak udelej kontrolu z vnoreneho hashe).
    }
    
    $self->{'defined'} = {
    login_form => {
        parameters => [ 'login','pass' ],
    },
    
    OR
    
    password_form => {
        parameters => [ 'pass','pass1','pass2' ],
    },
    
    OR
    
    myprofile_form => {
        parameters => [ 'surname||firm', 'email', 'customer', 'town', 'street', 'streetnumber', 'zipcode' ],
        difadd => {
        prefix => "different_",
        parameters => [ 'surname||firm', 'town', 'street', 'streetnumber', 'zipcode' ],
        }
    },
    
    OR
    
    myprofile_form => {
        parameters => [ 'if[customer="P"]surname', 'if[customer="C"]firm', 'email', 'customer', 'town', 'street', 'streetnumber', 'zipcode' ],
    },
    };

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

    Metoda potvrzuje existeni/neexistenci dat v databazi. Jedna se o velmi jednoduchou validaci ktera nam zjisti
    zda napriklad id nebo md5sum nebo jina hodnta jiz v dane tabulce a sloupci existuje nebo ne. Pokud potrebujeme pouzit jineho
    nazvu pro parametr a nazev sloupce, pouzijeme tuto syntaxi '<parametr>#<columnname>'.
    v hashi jsou pak atributy jako:
    prefix = pokud se u vsech parametru opakuje stejny prefix, pak nema cenu psat ho vsude. (nepovina volba)
    parameters = [seznam parametru v poli kter se budou validovat ]
    entity => Jmeno entity ktera bude validovat hodnoty parametru uveden v poli (parameters)
    exist => 1/0,  1 = kdyz hodnota v db existuje metoda vrati chybu, 0 = kdyz hodnota v db neexistuje metoda vrati chybu
    parametr = {
        pokud potrebujeme navazat na parametr dalsi definovane parametry tak se to definuje zase stejnym hashem,
        takto muzeme vnorovat dalsi a dalsi zavyslosti do sebe, viz ukazka c.3 vazba na parametr difadd
        (pokud existuje parametr difadd, pak udelej kontrolu z vnoreneho hashe).
    }

    $self->{'exist'} = {
    
    'login_form' => [
        {
        entity => 'Entities::User',
        parameters => [ 'login', 'useremail#email' ],
        exist => 1/0 # 1 = kdyz hodnota v db existuje je to chyba, 0 = kdyz hodnota v db neexistuje je to chyba
        },
    ],

    OR
    
    myprofile_form => [
        {
        entity => 'Entities::User',
        parameters => [ 'uid', 'useremail#email' ],
        exist => 1/0 # 1 = kdyz hodnota v db existuje je to chyba, 0 = kdyz hodnota v db neexistuje je to chyba
        difadd => {
            prefix => "different_",
            entity => 'Entities::UserAddress',
            parameters => [ 'did' ],
            exist => 1/0 # 1 = kdyz hodnota v db existuje je to chyba, 0 = kdyz hodnota v db neexistuje je to chyba
        },
        },
    ],
    };

=cut

sub checkExist {
    my ($self, $page, $func, $opt, $error) = @_;

    return $error unless ($self->isExistPageAtribute($page, "exist", $func));

    my $prefix = $opt->{'prefix'};
    my @params = @{$opt->{'parameters'}};
    my $entity = $opt->{'entity'} || return "Internal_Error_atribute_entity_not_defined";
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
                my $SQL = $DBI->select("db1", "1 FROM $table_name WHERE $cname = ?", [$value]);
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

    Metoda udela kontrolu hodnot, tim ze je necha zvalidovat definovanou entitou.
    Atributy (login_form,password_form,myprofile_form) reprezentuji jmeno funkce.
    Pokud potrebujeme pouzit jineho nazvu pro parametr a nazev sloupce, pouzijeme tuto syntaxi '<parametr>#<columnname>'.
    v hashi jsou pak atributy jako:
    prefix = pokud se u vsech parametru opakuje stejny prefix, pak nema cenu psat ho vsude. (nepovina volba)
    parameters = [seznam parametru v poli kter se budou validovat ]
    entity => Jmeno entity ktera bude validovat hodnoty parametru uveden v poli (parameters)
    parametr = {
        pokud potrebujeme navazat na parametr dalsi definovane parametry tak se to definuje zase stejnym hashem,
        takto muzeme vnorovat dalsi a dalsi zavyslosti do sebe, viz ukazka c.3 vazba na parametr difadd
        (pokud existuje parametr difadd, pak udelej kontrolu z vnoreneho hashe).
    }
    

    $self->{'validate'} = {
    'login_form' => [
        {
        entity => 'Entities::User',
        parameters => [ 'login', 'password#pass' ],
        },
    ],

    OR

    myprofile_form => [
        {
            entity => 'Entities::User',
            parameters => [ 'difadd', 'firstname', 'sname#surname', 'firm', 'email', 'customer', 'town', 'street', 'streetnumber', 'zipcode' ],
            difadd => {
            prefix => "different_",
            entity => 'Entities::UserAddress',
            parameters => [ 'firstname', 'surname', 'town', 'street','streetnumber', 'zipcode' ],
        },
        },
    ]
    };
    
=cut

sub checkParameters {
    my ($self, $page, $func, $opt, $error) = @_;

    return $error unless ($self->isExistPageAtribute($page, "validate", $func));

    my $prefix = $opt->{'prefix'};
    my @params = @{$opt->{'parameters'}};
    my $entity = $opt->{'entity'} || return "Internal_Error_atribute_entity_not_defined";

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

    Metoda udela unikatni kontrolu hodnot, tim ze je necha zvalidovat definovanou entitou.
    Pokud potrebujeme pouzit jineho nazvu pro parametr a nazev sloupce, pouzijeme tuto syntaxi '<parametr>#<columnname>'.
    v hashi jsou pak atributy jako:
    prefix = pokud se u vsech parametru opakuje stejny prefix, pak nema cenu psat ho vsude. (nepovina volba)
    parameters = [seznam parametru v poli kter se budou validovat ]
    entity => Jmeno entity ktera bude validovat hodnoty parametru uveden v poli (parameters)
    primary => nazev primarniho sloupce ktery muze byt null (Update do DB/Insert do DB),
    parametr = {
        pokud potrebujeme navazat na parametr dalsi definovane parametry tak se to definuje zase stejnym hashem,
        takto muzeme vnorovat dalsi a dalsi zavyslosti do sebe, viz ukazka c.3 vazba na parametr difadd
        (pokud existuje parametr difadd, pak udelej kontrolu z vnoreneho hashe).
    }

    $self->{'unique'} = {
    'login_form' => [
        {
           entity => 'Entities::User',
           parameters => [ 'parameter1#column1', 'column2' ],
           primary => 'columnPrimaryID',
        },
    ],
    
    OR
    
    'register_form' => [
        {
           entity => 'Entities::User',
           primary => 'columnPrimaryID',
           parameters => [ 'parameter1#column1', 'column2' ],
           column1 => {
            prefix => "different_",
            entity => 'Entities::UserAddress',
            primary => 'columnPrimaryID',
            parameters => [ 'parameter1#column1', 'columnX' ],
        },
        },
    ],
    };
=cut

sub checkUnique {
    my ($self, $page, $func, $opt, $error) = @_;

    return $error unless ($self->isExistPageAtribute($page, "unique", $func));

    my $prefix  = $opt->{'prefix'};
    my @params  = @{$opt->{'parameters'}};
    my $entity  = $opt->{'entity'} || return "Internal_Error_atribute_entity_not_defined";
    my $primary = $opt->{'primary'} || return "Internal_Error_atribute_primary_not_defined";

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
    
    Kontrola vstupnich hodnot dle zadanych pravidel (rules).
    
    Pokud je v page definovan atribut:    
    $self->{'rules'}->{'func'}->{'parameter'} = [];
    pak se pole validuje.        

    Pole muze vypadat takto.
    
    [
    [ 'is_number', 'error_num', 'parameter' ],
    [ 'is_enum', 'error_num', 'parameter', ('a','b',c')],
    [ 'ServiceName::is_pid', 'error_pid', 'parameter' ],
    [ 'EntityName::pid', 'error_pid', 'parameter' ],
    .....
    ];

    prvni pozice v poli: jmeno funkce v objektu VALIDATE
    druha pozice v poli: jmeno navratove chyby
    treti pozice v poli: hodnota ktera je automaticka zmenena na aktualni hodnotu parametru. (NEMENIT)
    xta hodnota  v poli: hodnoty jsou predany validacni funkci.
    
=cut

sub checkRules {
    my ($self, $page, $func, $rules, $error) = @_;

    return undef unless ($self->isExistPageAtribute($page, "rules", $func));

    my $result = {};

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

    eval "\$SIG{__DIE__}='DEFAULT'; \$result = \$PAGE->\$method(\@args);";

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

sub getLoadPagesList {
    my $self   = shift;
    my $result = [];
    foreach (keys %{$self->{'pages'}}) { push(@{$result}, $_); }
    return $result;
}

sub getPagesDir {
    my $self = shift;
    return $CONF->getValue("pwe", "home", undef) . $CONF->getValue("pwe", "pages_dir", undef);
}

sub getPageObject {
    my ($self, $page) = @_;
    if ($self->isExistPage($page)) {
        return $self->{'pages'}->{$page};
    } else {
        $LOG->error("Unknown page $page !");
    }
}

sub getPageAtribute {
    my ($self, $page, $key, $value, $default) = @_;
    return $default unless ($self->isExistPageAtribute($page, $key, $value));
    my $OBJ = $self->getPageObject($page);
    return $OBJ->{$key}->{$value} if (defined($value));
    return $OBJ->{$key};
}

=head2 B<[Private] getPnameCname($value)>
    
    Pomocna metoda pro validacnich metody.
    Tato metoda rozrizne parametr od nazvu sloupce.
    Napr: <parameter>#<columnname>
    
=cut

sub getPnameCname {
    my ($self, $value) = @_;
    if ($_ =~ /#/) {
        return split(/#/, $value);
    } else {
        return ($value, $value);
    }
}

sub isExistPage {
    my ($self, $page) = @_;
    return 1 if (defined($self->{'pages'}->{$page}));
    return 0;
}

sub isExistPageMethod {
    my ($self, $page, $method) = @_;
    return 0 if (!$self->isExistPage($page));
    return 0 if (!defined($self->{'methods'}->{$page}->{$method}));
    return 1;
}

sub isExistPageAtribute {
    my ($self, $page, $key, $value) = @_;
    return 0 if (!$self->isExistPage($page));
    my $OBJ = $self->getPageObject($page);
    return 0 if (!exists($OBJ->{$key}));
    return 1 if (!defined($value));
    return 0 if (!exists($OBJ->{$key}->{$value}));
    return 1;
}

sub isExistPageFunc {
    my ($self, $page, $func) = @_;
    return 0 if (!$self->isExistPage($page));
    return 0 if (!$self->isExistPageMethod($page, $func));
    return 0 if (!defined($self->{'pages'}->{$page}->{'func'}));
    return 0 if (!exists($self->{'pages'}->{$page}->{'func'}->{$func}));
    return 1;
}

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
