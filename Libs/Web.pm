package Libs::Web;

use strict;
use JSON;
use Template;

#use XML::Simple;
use File::Basename;
use Cz::Cstocs 'utf8_ascii';

my ($CONF, $LOG, $VALIDATE, $DBI, $USER);

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

    Metoda vraci obsah atributu ($key),
    pokud promena neexistuje vraci metoda hodnotu $def.
    
=cut

sub getValue {
    my ($self, $key, $def) = @_;

    return $def unless (exists($self->{$key}));
    return $self->{$key};
}

=head2 B<[Public] getScriptName()>

    Metoda vraci jmeno scriptu ktery pustil tento proces.
    
=cut

sub getScriptName {
    my $self = shift;
    return $self->getValue("script_name", 'pwe.fcgi');
}

=head2 B<[Public] addResourceBundlePagePath()>

    Metoda prida cestu k resourcbandlu.
    
    Mapa pak vypada nejak takto:
    'pagename' = {
        'CZE' => [
            'Entities/MailQueue/rb.tmpl',
            'Entities/Session/rb.tmpl',
            'Services/DBTable/rb.tmpl',
            'Sites/Default/rb.tmpl',
            'Sites/HomePage/rb.tmpl',
            'Pages/pweCreator/rb.tmpl'
        ]
        'EN' => [
            'Entities/MailQueue/rb_EN.tmpl',
            'Entities/Session/rb_EN.tmpl',
            'Services/DBTable/rb_EN.tmpl',
            'Sites/Default/rb_EN.tmpl',
            'Sites/HomePage/rb_EN.tmpl',
            'Pages/pweCreator/rb_EN.tmpl'
        ]
    };
    
=cut

sub addResourceBundlePagePath {
    my ($self, $page, $lang, $rbpath) = @_;
    $self->{'rb_map'}->{$page} = {} unless (exists($self->{'rb_map'}->{$page}));
    $self->{'rb_map'}->{$page}->{$lang} = [] unless (exists($self->{'rb_map'}->{$page}->{$lang}));
    push(@{$self->{'rb_map'}->{$page}->{$lang}}, $rbpath);
}

=head2 B<[Public] delResourceBundlePagePaths($page)>

    Metoda smaze zaznamy o rb dane page.

=cut

sub delResourceBundlePagePaths {
    my ($self, $page) = @_;
    delete $self->{'rb_map'}->{$page};
}

=head2 B<[Public] getResourceBundleList($page,$lang)>

    Metoda vraci v poli vsechny resourcbundly ktere jsou prirazeny k
    danemu jazyku a dane pagi.

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

sub printHttpHeader {
    my ($self, %tmpl) = @_;

    # HEADER DATE FORMAT : Wed, 09 Feb 1994 08:23:32 GMT
    my ($w, $m, $d, $t, $y) = split(/\s+/, gmtime(time()));
    $d = $d + 100;
    $d =~ s/^[1]{1}//;
    my $date = "$w, $d $m $y $t GMT";

    # COOKIE EXPIRE DATE FORMAT : Wed, 09-Feb-1994 01:23:32 GMT
    my ($w2, $m2, $d2, $t2, $y2) = split(/\s+/, gmtime(time() + ((3600 * 24) * $CONF->getValue("http", "cookie_expire_day", 100))));
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
    } elsif ($tmpl_type eq "ajax") {
        $output = $self->genTmpl("templates/HttpHeaderAjax.tmpl", %tmpl);
    } elsif ($tmpl_type eq "ajax_redirect") {
        $output = $self->genTmpl("templates/HttpHeaderAjaxRedirect.tmpl", %tmpl);
    } elsif ($tmpl_type eq "redirect") {
        $output = $self->genTmpl("templates/HttpHeaderRedirect.tmpl", %tmpl);
    } elsif ($tmpl_type eq "image" and $tmpl{'image'}) {
        $output = $self->genTmpl("templates/HttpHeaderImage.tmpl", %tmpl);
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
    } elsif ($tmpl_type eq "error") {
        $output = $self->genTmpl("templates/HttpHeaderError.tmpl", %tmpl);
    } else {
        $output = $self->genTmpl("templates/HttpHeaderStandart.tmpl", %tmpl);
    }

    # print output to log
    $LOG->info("print layout type: $tmpl_type \n$output") if ($tmpl{'log_output'});

    print $output;
}

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

    Metoda vraci vystup ze sablony
    
    $src - "/skelet.tmpl" OR "text [% mytemplate %] text"
    %tmpl - "{ data }"
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
    $tmpl{'http_host'}        = $USER->getValue("env", "HTTP_HOST", $CONF->getValue("http", "base_url", "localhost"));
    $tmpl{'http_https'}       = ($USER->getValue("env", "HTTPS", undef) ? "https://" : "http://");
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
        $LOG->delay("gen_tmpl", "Generate template $src");
    } elsif ($src =~ /\.html$/ or $src =~ /\.css$/ or $src =~ /\.js$/) {

        # TEMPLATE JE V SOUBORU
        my $TEMPLATE = $self->genTemplateObject('postchomp' => 1, 'prechomp' => 1, 'trim' => 1);
        $TEMPLATE->process($src, \%tmpl, \$out, binmode => ":utf8") || $LOG->error($src . " " . $TEMPLATE->error . " " . $Template::ERROR);
        $LOG->delay("gen_tmpl", "Generate template $src");
    } else {

        # VLASTNI TEMPLATE
        my $TEMPLATE = $self->genTemplateObject();
        $TEMPLATE->process(\$src, \%tmpl, \$out, binmode => ":utf8") || $LOG->error($TEMPLATE->error . " " . $Template::ERROR);
        $LOG->delay("gen_tmpl", "Generate template (internal template)");
    }

    return $out;
}

=head2 B<[Public] genTemplateObject()>

    Metoda vraci object pro praci s template

=cut

sub genTemplateObject {
    my ($self, %opt) = @_;

    $LOG->delay("gen_tmpl_obj");
    my $TEMPLATE = Template->new(
        'INCLUDE_PATH' => $CONF->getValue("pwe", "home", ""),
        'EVAL_PERL'  => $CONF->getValue("tmpl", "evalperl",  (defined($opt{'evalperl'})  ? $opt{'evalperl'}  : 1)),    # Povolit pouzivani perl syntaxe v sablonach
        'POST_CHOMP' => $CONF->getValue("tmpl", "postchomp", (defined($opt{'postchomp'}) ? $opt{'postchomp'} : 0)),    # Removes whitespace before/after directives (default: 0).
        'PRE_CHOMP'  => $CONF->getValue("tmpl", "prechomp",  (defined($opt{'prechomp'})  ? $opt{'prechomp'}  : 0)),    # Removes whitespace before/after directives (default: 0).
        'TRIM'       => $CONF->getValue("tmpl", "trim",      (defined($opt{'trim'})      ? $opt{'trim'}      : 0)),    # Remove leading and trailing whitespace from template (default: 0)
        'RECURSION'  => $CONF->getValue("tmpl", "recursion", (defined($opt{'recursion'}) ? $opt{'recursion'} : 1)),    # Povolit volani recursivniho volani (includ zavola sam sebe)
        'COMPILE_DIR' => $CONF->getValue("pwe", "home", "") . $CONF->getValue("tmpl", "croot", undef),
        'COMPILE_EXT' => ($CONF->getValue("tmpl", "cache", undef) ? "c" : undef),
    ) || die $Template::ERROR, "\n";
    $LOG->delay("gen_tmpl_obj", "Generated template object");

    return $TEMPLATE;
}

=head2 B<[Public] ConvertToRewrite($value)>

    Funkce prevede vlozeny text do Rewrite tvaru

=cut

sub convertToRewrite {
    my ($self, $value) = @_;
    $value = utf8_ascii($value);
    $value =~ s/\W+/_/g;
    $value =~ s/\_$//;
    $value = lc($value);
    return $value;
}

=head2 B<[Public] renderReplaceXML()>

    Metoda vraci data pro AJAX v XML

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

    Metoda vraci data pro AJAX v JSON

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

    Zapiseme data pro Ajax

=cut

sub setAjax {
    my ($self, $key, $value) = @_;

    #push(@{$self->{'ajax'}->{'REPLACE_XML'}->{'REPLACE'}},{ 'ID' => $key, 'HTML' => $value });
    push(@{$self->{'ajax'}->{'REPLACE_JSON'}->{'REPLACE'}}, {'ID' => $key, 'HTML' => $value});
}

=head2 B<[Public] setMessenger($tmpl,%tmpl)>

    Zapiseme data (messenger) pro HTML

=cut

sub setMessenger {
    my ($self, $msg, %tmpl) = @_;
    my $messenger = $self->genTmpl($msg, %tmpl);
    $USER->setMessenger($messenger);
}

=head2 B<[Public] setIDP($idp)>

    Zapiseme id stranky

=cut

sub setIDP {
    my ($self, $idp) = @_;
    $self->{'idp'} = $idp;
}

=head2 B<[Public] getIDP()>

    Metoda vraci id stranky

=cut

sub getIDP {
    my $self = shift;
    return (defined($self->{'idp'}) ? $self->{'idp'} : 'unknownidp');
}

=head2 B<[Public] getParameters()>

    Metoda vraci hash vsech parametru

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

    Metoda vraci informaci o nasetovanem messengru (1/undef)

=cut

sub existMessenger {
    my $self = shift;
    return $USER->existMessenger();
}

sub flush {
    my $self = shift;
    $self->{'ajax'} = {};
    $self->{'idp'}  = undef;
}

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
