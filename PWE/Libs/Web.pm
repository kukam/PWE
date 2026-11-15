package Libs::Web;

=head1 NAME

Libs::Web - render vrstva: Template Toolkit sablony, HTTP hlavicky, layouty, AJAX (JSON), resource bundle (i18n)

=head1 POPIS

    Do stranek se dostava pres vzhled (Sites::*). genTmpl doplnuje do kazde sablony automaticke promenne
    (script_name, idp, cookie_id, use_language, rb_list, http_host, ...). Sablony: *.tmpl (bez chompu),
    *.html/*.css/*.js (s chompem a trimem), jinak inline retezec. INCLUDE_PATH = pwe.home, pwe.core.

=cut

use strict;
use JSON;
use Template;

#use XML::Simple;
use Sys::Hostname;
use File::Basename;
use Cz::Cstocs 'utf8_ascii';

my ($CONF, $LOG, $VALIDATE, $DBI, $USER);

=head2 B<[Public] new($conf,$log,$validate,$dbi,$user)>

    Konstruktor render vrstvy. Drzi nazev skriptu (pwe.cgi_script_name), vychozi layouty
    (templates/LayoutHeader.html, templates/LayoutBody.html), mapu resource bundlu (rb_map),
    buffer AJAX odpovedi a id stranky (idp). Do stranek se typicky nedostava primo, ale
    pres fasadu Sites::<Vzhled> (Site_Default apod.).

=cut

sub new {
    my ($class, $conf, $log, $validate, $dbi, $user) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $CONF     = $conf;
    $USER     = $user;
    $VALIDATE = $validate;

    my $self = {
        'script_name'   => $CONF->getValue("pwe", "cgi_script_name", basename($0)),
        'layout_header' => "templates/LayoutHeader.html",
        'layout_body'   => "templates/LayoutBody.html",
        'rb_map'        => {},
        'ajax'          => {},
        'idp'           => undef,
    };

    bless $self, $class;

    return $self;
}

=head2 B<[Public] getValue($key,$def)>

    Metoda vraci hodnotu atributu objektu $key (napr. 'idp', 'script_name', 'layout_body').
    Pokud atribut neexistuje, vraci $def (existujici atribut s hodnotou undef vraci undef).

=cut

sub getValue {
    my ($self, $key, $def) = @_;

    return $def unless (exists($self->{$key}));
    return $self->{$key};
}

=head2 B<[Public] getScriptName()>

    Metoda vraci nazev CGI skriptu enginu (conf pwe.cgi_script_name, vychozi 'pwe.fcgi').
    V sablonach je dostupny jako promenna script_name a pouziva se pri sestavovani odkazu
    a akci formularu.

=cut

sub getScriptName {
    my $self = shift;
    return $self->getValue("script_name", 'pwe.fcgi');
}

=head2 B<[Public] addResourceBundlePagePath($page,$lang,$rbpath)>

    Metoda prida do mapy resource bundlu (rb_map) cestu $rbpath (relativni k pwe.home)
    k souboru rb*.tmpl pro stranku $page a jazyk $lang. Vola ji Libs::Pages::registerResourceBundle
    pri nacitani stranky. Mapa pak vypada napr. takto:

    'pagename' => {
        'CZE' => [
            'Entities/MailQueue/rb.tmpl',
            'Entities/Session/rb.tmpl',
            'Services/DBTable/rb.tmpl',
            'Sites/Default/rb.tmpl',
            'Pages/pweCreator/rb.tmpl',
        ],
        'EN' => [
            'Entities/MailQueue/rb_EN.tmpl',
            'Entities/Session/rb_EN.tmpl',
            'Services/DBTable/rb_EN.tmpl',
            'Sites/Default/rb_EN.tmpl',
            'Pages/pweCreator/rb_EN.tmpl',
        ],
    }

=cut

sub addResourceBundlePagePath {
    my ($self, $page, $lang, $rbpath) = @_;
    $self->{'rb_map'}->{$page} = {} unless (exists($self->{'rb_map'}->{$page}));
    $self->{'rb_map'}->{$page}->{$lang} = [] unless (exists($self->{'rb_map'}->{$page}->{$lang}));
    push(@{$self->{'rb_map'}->{$page}->{$lang}}, $rbpath);
}

=head2 B<[Public] delResourceBundlePagePaths($page)>

    Metoda smaze z mapy resource bundlu vsechny zaznamy (pro vsechny jazyky) stranky $page.
    Vola se pri odregistrovani stranky (Libs::Pages::unloadPage).

=cut

sub delResourceBundlePagePaths {
    my ($self, $page) = @_;
    delete $self->{'rb_map'}->{$page};
}

=head2 B<[Public] getResourceBundleList($page,$lang)>

    Metoda vraci referenci na pole (kopii) cest ke vsem resource bundlum, ktere jsou prirazeny
    strance $page a jazyku $lang. Pokud stranka nebo jazyk v mape nejsou, vraci prazdne pole [].
    Pouziva ji genTmpl pro sestaveni promenne rb_list.

=cut

sub getResourceBundleList {
    my ($self, $page, $lang) = @_;

    my $rblist = [];
    return $rblist unless (exists($self->{'rb_map'}->{$page}));
    return $rblist unless (exists($self->{'rb_map'}->{$page}->{$lang}));
    foreach my $path (@{$self->{'rb_map'}->{$page}->{$lang}}) {
        push(@{$rblist}, $path);
    }
    return $rblist;
}

=head2 B<[Public] printHttpHeader(type => $typ, %tmpl)>

    Vytiskne HTTP hlavicku podle sablony templates/HttpHeader<Typ>.tmpl. Doplni GMT datum
    a expiraci session cookie (http.cookie_expire_day, jinak http.cookie_expire_guest, jinak 100 dni).
    Typy: (bez typu) HTML, css, plain, js, font, ajax (text/xml), ajax_redirect (+redirect_link),
    svg_xml, redirect (+redirect_link, Status 301), image (+image), file (+filename, octet-stream),
    csvdown, 400, 401, 404, 500, error (+status). Volba log_output => 1 zapise hlavicku do logu.

=cut

sub printHttpHeader {
    my ($self, %tmpl) = @_;

    # HEADER DATE FORMAT : Wed, 09 Feb 1994 08:23:32 GMT
    my ($w, $m, $d, $t, $y) = split(/\s+/, gmtime(time()));
    $d = $d + 100;
    $d =~ s/^[1]{1}//;
    my $date = "$w, $d $m $y $t GMT";

    # COOKIE EXPIRE DATE FORMAT : Wed, 09-Feb-1994 01:23:32 GMT
    # Expirace cookie: http.cookie_expire_day, jinak http.cookie_expire_guest (stejna hodnota jako u DB session), jinak 100 dni.
    my $cookie_days = $CONF->getValue("http", "cookie_expire_day", $CONF->getValue("http", "cookie_expire_guest", 100));
    my ($w2, $m2, $d2, $t2, $y2) = split(/\s+/, gmtime(time() + ((3600 * 24) * $cookie_days)));
    $d2 = $d2 + 100;
    $d2 =~ s/^[1]{1}//;
    my $date_exp = $w2 . ", " . $d2 . "-" . $m2 . "-" . $y2 . " " . $t2 . " GMT";

    # SET ACTUAL VALUES
    $tmpl{'http_gmt_date'}      = $date;
    $tmpl{'cookie_expire_date'} = $date_exp;

    my $output    = "";
    my $tmpl_type = $tmpl{'type'};

    if ($tmpl_type eq "css") {
        $output = $self->genTmpl("templates/HttpHeaderCss.tmpl", %tmpl);
    } elsif ($tmpl_type eq "plain") {
        $output = $self->genTmpl("templates/HttpHeaderPlain.tmpl", %tmpl);
    } elsif ($tmpl_type eq "js") {
        $output = $self->genTmpl("templates/HttpHeaderJavascript.tmpl", %tmpl);
    } elsif ($tmpl_type eq "font") {
        $output = $self->genTmpl("templates/HttpHeaderFont.tmpl", %tmpl);
    } elsif ($tmpl_type eq "ajax") {
        $output = $self->genTmpl("templates/HttpHeaderAjax.tmpl", %tmpl);
    } elsif ($tmpl_type eq "ajax_redirect") {
        $output = $self->genTmpl("templates/HttpHeaderAjaxRedirect.tmpl", %tmpl);
    } elsif ($tmpl_type eq "svg_xml") {
        $output = $self->genTmpl("templates/HttpHeaderSVGXML.tmpl", %tmpl);
    } elsif ($tmpl_type eq "redirect") {
        $output = $self->genTmpl("templates/HttpHeaderRedirect.tmpl", %tmpl);
    } elsif ($tmpl_type eq "image" and $tmpl{'image'}) {
        $output = $self->genTmpl("templates/HttpHeaderImage.tmpl", %tmpl);
    } elsif ($tmpl_type eq "file" and $tmpl{'filename'}) {
        $output = $self->genTmpl("templates/HttpHeaderOctetStream.tmpl", %tmpl);
    } elsif ($tmpl_type eq "csvdown") {
        $output = $self->genTmpl("templates/HttpHeaderCsvDownload.tmpl", %tmpl);
    } elsif ($tmpl_type eq "400") {
        $output = $self->genTmpl("templates/HttpHeader400.tmpl", %tmpl);
    } elsif ($tmpl_type eq "401") {
        $output = $self->genTmpl("templates/HttpHeader401.tmpl", %tmpl);
    } elsif ($tmpl_type eq "404") {
        $output = $self->genTmpl("templates/HttpHeader404.tmpl", %tmpl);
    } elsif ($tmpl_type eq "500") {
        $output = $self->genTmpl("templates/HttpHeader500.tmpl", %tmpl);
    } elsif ($tmpl_type eq "static" and $tmpl{'content_type'}) {
        $output = $self->genTmpl("templates/HttpHeaderStatic.tmpl", %tmpl);
    } elsif ($tmpl_type eq "error") {
        $output = $self->genTmpl("templates/HttpHeaderError.tmpl", %tmpl);
    } else {
        $output = $self->genTmpl("templates/HttpHeaderStandart.tmpl", %tmpl);
    }

    # print output to log
    $LOG->info("print layout type: $tmpl_type \n$output") if ($tmpl{'log_output'});

    print $output;
}

=head2 B<[Public] printHtmlHeader(%tmpl)>

    Vytiskne hlavicku HTML dokumentu (<!DOCTYPE html>...<head>) ze sablony layout_header
    (z %tmpl, jinak atribut objektu). Promenne (%tmpl, napr. title) jsou dostupne v sablone.
    Pri pwe.prettyhtml zjednodusi bile znaky.

=cut

sub printHtmlHeader {
    my ($self, %tmpl) = @_;

    my $layout = (defined($tmpl{'layout_header'}) ? $tmpl{'layout_header'} : $self->getValue("layout_header", ""));

    my $output = $self->genTmpl($layout, %tmpl);

    # print output to log
    $LOG->info("print layout : $layout \n$output") if ($tmpl{'log_output'});

    if ($CONF->getValue('pwe', 'prettyhtml', 0)) {
        $output =~ s/\>\n/>/g;
        $output =~ s/\>\s+\</></g;
        $output =~ s/\<html/\n\<html/;
    }
    print $output;
}

=head2 B<[Public] printHtmlLayout(html_main => "Pages/X/main.html", %tmpl)>

    Vytiskne telo stranky ze sablony layout_body (z %tmpl, jinak atribut objektu); layout
    typicky INCLUDE-uje html_main. Pokud neni v %tmpl 'messenger', doplni ho z $USER->getMessenger()
    (flash zprava se tim smaze). Vsechny klice %tmpl jsou promenne sablony.

=cut

sub printHtmlLayout {
    my ($self, %tmpl) = @_;

    unless (defined($tmpl{'messenger'})) {
        $tmpl{'messenger'} = $USER->getMessenger();
    }

    my $layout = (defined($tmpl{'layout_body'}) ? $tmpl{'layout_body'} : $self->getValue("layout_body", ""));

    my $output = $self->genTmpl($layout, %tmpl);

    # print output to log
    $LOG->info("print layout : $layout \n$output") if ($tmpl{'log_output'});

    if ($CONF->getValue('pwe', 'prettyhtml', 0)) {
        $output =~ s/\>\n/>/g;
        $output =~ s/\>\s+\</> </g;
        $output =~ s/\<\/html\>/\<\/html\>\n/;
    }
    print $output;
}

=head2 B<[Public] printAjaxLayout(ajax_id => [...], ajax_tmpl => [...]|ajax_html => [...], ajax_data => {...}|[{...},...])>

    Sestavi a vytiskne JSON odpoved pro pwe.js: {"REPLACE":[{"ID":id,"HTML":html},...]}.
    Pro kazde id v ajax_id se pouzije bud hotove HTML z ajax_html, nebo se vyrenderuje sablona
    z ajax_tmpl s daty z ajax_data (jedna sablona/hash se pouzije pro vsechna id, pole = po
    jednom pro kazde id). Pokud existuje messenger, prida se pod ID "messenger".
    Pouzivat spolu s printHttpHeader(type => 'ajax').

=cut

sub printAjaxLayout {
    my ($self, %tmpl) = @_;

    if ((ref($tmpl{'ajax_tmpl'}) eq "ARRAY") and (ref($tmpl{'ajax_id'}) eq "ARRAY")) {

        if (ref($tmpl{'ajax_data'}) ne "ARRAY") {
            if (ref($tmpl{'ajax_data'}) eq "HASH") {
                $tmpl{'ajax_data'} = [$tmpl{'ajax_data'}];
            } else {
                $LOG->error("Invalid set AjaxLayout data !");
                $tmpl{'ajax_data'} = [{}];
            }
        }

        my @id   = @{$tmpl{'ajax_id'}};
        my @tmpl = @{$tmpl{'ajax_tmpl'}};
        my @data = @{$tmpl{'ajax_data'}};

        my $i = 0;
        foreach (@id) {
            my $html = $self->genTmpl(((@tmpl > 1) ? $tmpl[$i] : $tmpl[0]), %{((@data > 1) ? $data[$i] : $data[0])});
            if ($CONF->getValue('pwe', 'prettyhtml', 0)) {
                $html =~ s/\>\n/>/g;
                $html =~ s/\>\s+\</> </g;
            }
            $self->setAjax($id[$i], $html);
            $i++;
        }

    } elsif ((ref($tmpl{'ajax_html'}) eq "ARRAY") and (ref($tmpl{'ajax_id'}) eq "ARRAY")) {

        my @id   = @{$tmpl{'ajax_id'}};
        my @html = @{$tmpl{'ajax_html'}};

        my $i = 0;
        foreach (@id) {
            $self->setAjax($id[$i], $html[$i]);
            $i++;
        }
    }

    # SET messenger
    if ($self->existMessenger()) {
        $self->setAjax("messenger", $USER->getMessenger());
    }

    my $output = $self->renderReplaceJSON();

    #my $output = $self->renderReplaceXML();

    # print output to log
    $LOG->info("print Ajax layout : \n$output") if ($tmpl{'log_output'});

    print $output;
}

=head2 B<[Public] genTmpl($src,%tmpl)>

    Metoda vyrenderuje sablonu (Template Toolkit) a vrati vystup jako retezec.

    $src  - cesta k sablone relativni k pwe.home, nebo primo text sablony:
            *.tmpl              - soubor, bez chompu bilych znaku
            *.html, *.css, *.js - soubor, s PRE_CHOMP, POST_CHOMP a TRIM
            cokoliv jineho      - retezec "text [% promenna %] text" se zpracuje jako sablona
    %tmpl - promenne pro sablonu (klic => hodnota)

    my $html = $WEB->genTmpl("Pages/mojeStranka/main.html", title => "Nadpis", items => \@items);
    my $text = $WEB->genTmpl("Ahoj [% name %]", name => "svete");

    Do %tmpl metoda vzdy doplni (a pripadne prepise) automaticke promenne: idp, script_name,
    parameters, cookie_id, group, script_page, script_func, start_time, http_https, http_host
    (bez portu), http_host_full, http_referer, server_name, request_uri, use_language, languages,
    def_language, cookie_name, http_host_path, name_page, conf_title, conf_keywords,
    conf_description, conf_development, full_url, hostname, random_number a rb_list (resource
    bundly aktivni stranky pro vychozi jazyk a pro pouzity jazyk).

    Chyba sablony se zaloguje (error) a vrati se to, co se stihlo vygenerovat (typicky "").

=cut

sub genTmpl {
    my ($self, $src, %tmpl) = @_;

    my $out    = "";
    my $result = undef;

    $LOG->delay("gen_tmpl");

    # SET default values
    $tmpl{'idp'}         = $self->getValue("idp",         undef);
    $tmpl{'script_name'} = $self->getValue("script_name", 'pwe.fcgi');
    $tmpl{'parameters'}  = $self->getParameters();

    $tmpl{'cookie_id'}        = $USER->getSid();
    $tmpl{'group'}            = $USER->getGroup();
    $tmpl{'script_page'}      = $USER->getValue("page", undef, "default");
    $tmpl{'script_func'}      = $USER->getValue("func", undef, "default");
    $tmpl{'start_time'}       = $USER->getValue("env", "APACHE_START_TIME", "");
    $tmpl{'http_https'}       = ($USER->getValue("env", "HTTPS", undef) ? "https://" : "http://");
    $tmpl{'http_host'}        = $USER->getValue("env", "HTTP_HOST", $CONF->getValue("http", "base_url", "localhost"));
    $tmpl{'http_host_full'}   = $USER->getValue("env", "HTTP_HOST", $CONF->getValue("http", "base_url", "localhost"));
    $tmpl{'http_referer'}     = ($USER->getValue("env", "HTTP_REFERER", $USER->getValue("env", "HTTP_HOST", $CONF->getValue("http", "base_url", "localhost"))));
    $tmpl{'server_name'}      = $USER->getValue("env", "SERVER_NAME", $CONF->getValue("http", "base_url", "localhost"));
    $tmpl{'request_uri'}      = $USER->getValue("env", "REQUEST_URI", "/");
    $tmpl{'use_language'}     = $USER->getValue("language", undef, "CZE");
    $tmpl{'languages'}        = $CONF->getValue("http", "languages", ["CZE"]);
    $tmpl{'def_language'}     = @{$CONF->getValue("http", "languages", ["CZE"])}[0];
    $tmpl{'cookie_name'}      = $CONF->getValue("http", "cookie_name", "unknown_cookie_name");
    $tmpl{'http_host_path'}   = $CONF->getValue("http", "http_host_path", "/");
    $tmpl{'name_page'}        = $CONF->getValue("http", "name", "UNKNOWN_NAME_PAGE");
    $tmpl{'conf_title'}       = $CONF->getValue("http", "title", "");
    $tmpl{'conf_keywords'}    = $CONF->getValue("http", "keywords", "");
    $tmpl{'conf_description'} = $CONF->getValue("http", "description", "");
    $tmpl{'conf_development'} = $CONF->getValue("pwe", "development", 0);
    $tmpl{'full_url'}         = $tmpl{'http_https'} . $tmpl{'server_name'} . "/";
    $tmpl{'hostname'}         = hostname;
    $tmpl{'random_number'}    = int(rand(999999999));

    # odstraneni portu za hostem (kukam.freebox.cz:8080)
    $tmpl{'http_host'} =~ s/:.*//;

    # SET resource bundle
    my $activepage   = $USER->getActivePage();
    my @languages    = @{$CONF->getValue("http", "languages", [])};
    my $use_language = $USER->getValue("language", undef, "CZE");
    my $def_language = $languages[0];

    if ($use_language ne $def_language) {
        push(@{$tmpl{'rb_list'}}, @{$self->getResourceBundleList($activepage, $def_language)});
    }
    push(@{$tmpl{'rb_list'}}, @{$self->getResourceBundleList($activepage, $use_language)});

    # undef template nema!
    $src = "" if (!ref($src) and !$src);

    if ($src =~ /\.tmpl$/) {

        # TEMPLATE JE V SOUBORU SE SPECIALNIM NAZVEM (JINY OBJECT $TEMPLATE)
        my $TEMPLATE = $self->genTemplateObject();
        $TEMPLATE->process($src, \%tmpl, \$out, binmode => ":utf8") || $LOG->error($src . " " . $TEMPLATE->error . " " . $Template::ERROR);
        $self->resetTemplateStash($TEMPLATE);
        $LOG->delay("gen_tmpl", "Generate template $src");
    } elsif ($src =~ /\.html$/ or $src =~ /\.css$/ or $src =~ /\.js$/) {

        # TEMPLATE JE V SOUBORU
        my $TEMPLATE = $self->genTemplateObject('postchomp' => 1, 'prechomp' => 1, 'trim' => 1);
        $TEMPLATE->process($src, \%tmpl, \$out, binmode => ":utf8") || $LOG->error($src . " " . $TEMPLATE->error . " " . $Template::ERROR);
        $self->resetTemplateStash($TEMPLATE);
        $LOG->delay("gen_tmpl", "Generate template $src");
    } else {

        # VLASTNI TEMPLATE
        my $TEMPLATE = $self->genTemplateObject();
        $TEMPLATE->process(\$src, \%tmpl, \$out, binmode => ":utf8") || $LOG->error($TEMPLATE->error . " " . $Template::ERROR);
        $self->resetTemplateStash($TEMPLATE);
        $LOG->delay("gen_tmpl", "Generate template (internal template)");
    }

    return $out;
}

=head2 B<[Public] genTemplateObject(%opt)>

    Metoda vrati objekt Template (Template Toolkit) s INCLUDE_PATH = (pwe.home, pwe.core) - sablona
    se hleda nejdrive ve webu, pak v enginu. Objekt se vytvari jen jednou pro kazdou kombinaci
    voleb a dale se vraci z cache (vytvareni objektu pro kazdy render bylo nejdrazsi casti requestu).
    Volby v %opt (evalperl, postchomp, prechomp, trim, recursion) jsou jen vychozi hodnoty -
    pokud je stejny klic nastaven v conf sekci tmpl, ma prednost konfigurace. Bez voleb
    i konfigurace plati EVAL_PERL=1, POST_CHOMP=0, PRE_CHOMP=0, TRIM=0, RECURSION=1.
    Kompilovane sablony se ukladaji do pwe.home + tmpl.croot (COMPILE_EXT "c" pri zapnutem
    tmpl.cache). Pri selhani konstruktoru Template metoda die.

    my $TEMPLATE = $WEB->genTemplateObject('postchomp' => 1, 'prechomp' => 1, 'trim' => 1);

=cut

sub genTemplateObject {
    my ($self, %opt) = @_;

    # Objekt Template je drahy (kompiluje konfiguraci, drzi cache prelozenych sablon) - drzime jeden
    # na kazdou kombinaci voleb po celou dobu zivota procesu. Zmeny souboru sablon hlida Template sam
    # (STAT_TTL), cache prezije i flush().
    my $cache_key = join(';', map { "$_=" . (defined($opt{$_}) ? $opt{$_} : '') } sort keys %opt);
    return $self->{'template_cache'}->{$cache_key} if ($self->{'template_cache'}->{$cache_key});

    $LOG->delay("gen_tmpl_obj");
    my $TEMPLATE = Template->new(
        'INCLUDE_PATH' => [$CONF->getRoots()],    # web (pwe.home) ma prednost pred enginem (pwe.core)
        'EVAL_PERL'  => $CONF->getValue("tmpl", "evalperl",  (defined($opt{'evalperl'})  ? $opt{'evalperl'}  : 1)),    # Povolit pouzivani perl syntaxe v sablonach
        'POST_CHOMP' => $CONF->getValue("tmpl", "postchomp", (defined($opt{'postchomp'}) ? $opt{'postchomp'} : 0)),    # Removes whitespace before/after directives (default: 0).
        'PRE_CHOMP'  => $CONF->getValue("tmpl", "prechomp",  (defined($opt{'prechomp'})  ? $opt{'prechomp'}  : 0)),    # Removes whitespace before/after directives (default: 0).
        'TRIM'       => $CONF->getValue("tmpl", "trim",      (defined($opt{'trim'})      ? $opt{'trim'}      : 0)),    # Remove leading and trailing whitespace from template (default: 0)
        'RECURSION'  => $CONF->getValue("tmpl", "recursion", (defined($opt{'recursion'}) ? $opt{'recursion'} : 1)),    # Povolit volani recursivniho volani (includ zavola sam sebe)
        'COMPILE_DIR' => $CONF->getValue("pwe", "home", "") . $CONF->getValue("tmpl", "croot", undef),
        'COMPILE_EXT' => ($CONF->getValue("tmpl", "cache", undef) ? "c" : undef),
    ) || die $Template::ERROR, "\n";
    $LOG->delay("gen_tmpl_obj", "Generated template object");

    $self->{'template_cache'}->{$cache_key} = $TEMPLATE;
    $self->{'template_stash'}->{$cache_key} = $TEMPLATE->context->stash;    # korenovy stash - obnovuje se po kazdem renderu
    return $TEMPLATE;
}

=head2 B<[Private] resetTemplateStash($TEMPLATE)>

    Po kazdem renderu vrati objektu Template jeho korenovy stash (ulozeny pri vytvoreni v genTemplateObject).
    Template Toolkit promenne lokalizuje sam (clone/declone), ale sablona s [% PERL %] blokem muze zivy
    stash poskodit (napr. smazat _PARENT) a pak by promenne zustavaly ve sdilenem objektu i pro dalsi
    requesty - objekt Template je v cache procesu, takze by data pretekala mezi uzivateli (regrese 2.1.0,
    templates/DumpData.tmpl). Tato pojistka to vylucuje bez ohledu na chovani sablon.

=cut

sub resetTemplateStash {
    my ($self, $TEMPLATE) = @_;
    foreach my $key (keys %{$self->{'template_stash'} || {}}) {
        next unless ($self->{'template_cache'}->{$key} and $self->{'template_cache'}->{$key} == $TEMPLATE);
        my $root = $self->{'template_stash'}->{$key};
        $TEMPLATE->context->{'STASH'} = $root if ($root and $TEMPLATE->context->stash != $root);
        last;
    }
}

=head2 B<[Public] convertToRewrite($value)>

    Metoda prevede text na URL "slug": odstrani diakritiku (Cz::Cstocs utf8_ascii),
    vsechny ne-slovni znaky nahradi podtrzitkem, orizne podtrzitka na zacatku a konci
    a prevede na mala pismena. Napr. "Prilis zlutoucky kun!" (s diakritikou) -> "prilis_zlutoucky_kun".

=cut

sub convertToRewrite {
    my ($self, $value) = @_;
    $value = utf8_ascii($value);
    $value =~ s/\W+/_/g;
    $value =~ s/^\_//;
    $value =~ s/\_$//;
    $value = lc($value);
    return $value;
}

=head2 B<[Public] renderReplaceXML()>

    Puvodni varianta AJAX odpovedi ve formatu XML (XML::Simple). Metoda je v soucasne dobe
    zakomentovana a neni dostupna - AJAX odpovedi se generuji vyhradne v JSON,
    viz renderReplaceJSON.

=cut

#sub renderReplaceXML {
#    my $self = shift;
#    $LOG->delay("xmlout");
#    my $ajax = $self->getValue("ajax",{});
#    my $xml = XMLout($self->getValue($ajax->{'REPLACE_XML}), NoAttr => 1, RootName => 'root', XMLDecl => "<?xml version='1.0' encoding='UTF-8' ?>");
#    $LOG->delay("xmlout","Revert hash to xml (ajax)");
#    return $xml;
#}

=head2 B<[Public] renderReplaceJSON()>

    Metoda vraci obsah AJAX bufferu (naplneneho pres setAjax) jako JSON retezec ve tvaru
    {"REPLACE":[{"ID":"id_elementu","HTML":"obsah"},...]}, ktery zpracovava pwe.js.
    Vola ji printAjaxLayout.

=cut

sub renderReplaceJSON {
    my $self = shift;
    $LOG->delay("jsonout");
    my $ajax = $self->getValue("ajax", {});
    my $json = to_json($ajax->{"REPLACE_JSON"}, {'utf8' => 0, 'pretty' => 0});

    #my $json = JSON->new->utf8(0)->pretty(0)->encode($ajax->{"REPLACE_JSON"});
    $LOG->delay("jsonout", "Revert hash to json (ajax)");

    return $json;
}

###########
### SET ###
###########

=head2 B<[Private] setAjax($key,$value)>

    Metoda prida do AJAX bufferu dvojici ID => $key (id HTML elementu) a HTML => $value
    (novy obsah elementu). Buffer vypisuje renderReplaceJSON a na konci requestu nuluje flush().

=cut

sub setAjax {
    my ($self, $key, $value) = @_;

    #push(@{$self->{'ajax'}->{'REPLACE_XML'}->{'REPLACE'}},{ 'ID' => $key, 'HTML' => $value });
    push(@{$self->{'ajax'}->{'REPLACE_JSON'}->{'REPLACE'}}, {'ID' => $key, 'HTML' => $value});
}

=head2 B<[Public] setMessenger($msg,%tmpl)>

    Metoda vyrenderuje sablonu $msg (cesta k souboru nebo text, viz genTmpl) s promennymi %tmpl
    a vysledne HTML ulozi jako zpravu (messenger) pres $USER->setMessenger(). Zprava se zobrazi
    pri nejblizsim vykresleni layoutu (printHtmlLayout / printAjaxLayout) a pak se smaze -
    prezije tedy i presmerovani.

    $WEB->setMessenger("Pages/mojeStranka/msg.html", msg_error => $error);

=cut

sub setMessenger {
    my ($self, $msg, %tmpl) = @_;
    my $messenger = $self->genTmpl($msg, %tmpl);
    $USER->setMessenger($messenger);
}

=head2 B<[Public] setIDP($idp)>

    Metoda nastavi identifikator stranky (idp), ktery je v sablonach dostupny jako promenna idp
    (napr. pro zvyrazneni aktivni polozky menu nebo id elementu <body>). Stranka ho typicky
    vola na zacatku kazde funkce: $WEB->setIDP("mojeStranka"). Na konci requestu se nuluje (flush).

=cut

sub setIDP {
    my ($self, $idp) = @_;
    $self->{'idp'} = $idp;
}

=head2 B<[Public] getIDP()>

    Metoda vraci identifikator stranky nastaveny pres setIDP(); pokud nebyl nastaven,
    vraci 'unknownidp'.

=cut

sub getIDP {
    my $self = shift;
    return (defined($self->{'idp'}) ? $self->{'idp'} : 'unknownidp');
}

=head2 B<[Public] getParameters()>

    Metoda vraci hashref vsech vstupnich parametru requestu ve tvaru { nazev => prvni_hodnota }
    (z vicehodnotovych parametru se bere jen prvni hodnota). V sablonach je dostupny jako
    promenna parameters.

=cut

sub getParameters {
    my $self       = shift;
    my $parameters = {};
    while (my ($key, $value) = each(%{$USER->getParams()})) {
        $parameters->{$key} = @{$value}[0];
    }
    return $parameters;
}

=head2 B<[Public] existMessenger()>

    Metoda vraci 1, pokud je nastavena zprava (messenger) k zobrazeni, jinak undef.
    Deleguje na $USER->existMessenger().

=cut

sub existMessenger {
    my $self = shift;
    return $USER->existMessenger();
}

=head2 B<[Public] flush()>

    Konec requestu: vynuluje buffer AJAX odpovedi a id stranky (idp). Vola pwe.fcgi.

=cut

sub flush {
    my $self = shift;
    $self->{'ajax'} = {};
    $self->{'idp'}  = undef;
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
    require Libs::Validate;
    $LOG      = new Libs::Log;
    $CONF     = new Libs::Config;
    $DBI      = new Libs::DBI;
    $USER     = new Libs::User;
    $VALIDATE = new Libs::Validate;
}

1;
