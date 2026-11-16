#!/usr/bin/env perl

=head1 NAME

PWE/tools/new-webapp.pl - vytvori kostru noveho webu (webappu) nad enginem PWE

=head1 POUZITI

    Spousti se z korene repozitare (PWE/ je adresar enginu):

    PWE/tools/new-webapp.pl <nazev> [volby]                  (make new WEB=<nazev> ARGS='...')

    PWE/tools/new-webapp.pl mujweb.web                       # web bez databaze (opts v souborech)
    PWE/tools/new-webapp.pl eshop.web --db mariadb           # web s databazi (Session, DBTable z enginu)
    PWE/tools/new-webapp.pl mujweb.web --title "Muj web" --lang CZE,EN,DE --examples

    Volby:
      --db none|mariadb|mysql|postgres   varianta s databazi (vychozi none). Vytvori conf/<driver>.conf
                                         a conf/<driver>.dbversion pro vsechny tri drivery, symlink
                                         conf/database.conf na zvoleny a povoli Session a DBTable z enginu
                                         (pwe.core_services, pwe.core_entities)
      --title "Nazev webu"               titulek webu (http.title/name), vychozi = nazev webappu
      --lang CZE,EN                      jazyky (http.languages), prvni je vychozi (rb.tmpl)
      --examples                         povoli ukazkove stranky enginu (ajaxExamples, formExamples,
                                         responsive) v pwe.core_pages a prida je do menu
      --dir <cesta>                      vytvorit webapp jinde nez ve webapps/<nazev> (testy)
      --force                            existujici adresar nevadi, generovane soubory se prepisou
      --help

    Skript pouziva jen jadro Perlu, bezi na hostiteli i v kontejneru. Vysledek je adresar
    webapps/<nazev>/ BEZ symlinku na engine: obsahuje jen vlastni moduly (Pages/default,
    Sites/Default, Services/UserAccount), conf/, static/ a Dockerfile. Vse ostatni (Libs,
    templates, assets, sdilene stranky css/errorPage/systemPage/pweCreator, sluzby Session/
    DBTable, ...) bere engine ze sveho adresare PWE/ (koren enginu = pwe.core) podle seznamu
    pwe.core_* v conf/web.conf. Dalsi kroky vypise na konci.

    Dockerfile webu ma pro vsechny weby stejnou sablonu (lisi se nazvem webu, profilem PWE_PROFILE
    a zakladem: --db mariadb|mysql|postgres, bez databaze static). Image webu = zavislostni image
    + engine + web:
      - FROM ghcr.io/kukam/pwe-base (web bez databaze) nebo ghcr.io/kukam/pwe-<profil> (web
        s databazi) - jen knihovny, ovladac databaze a entrypoint; kod enginu v nich neni,
      - engine se kopiruje z kontextu sestaveni (adresar PWE/ repozitare bez PWE/t a PWE/docker)
        do /PWE/PWE,
      - web z webapps/<web> do /PWE/webapps/<web>.
    Sestavuje se proto vzdy z korene repozitare enginu:
      docker build -f webapps/<web>/Dockerfile [--build-arg PWE_IMAGE_TAG=<verze>] -t <nazev> .
    Vlastni entrypoint.sh web nema: image webu dedi ENTRYPOINT ze zakladniho image (zdroj
    PWE/docker/entrypoint.sh). Stejnou sablonou vznikaji i image vzorovych webu pwe-example-*
    (docker-bake.hcl je stavi primo z webapps/example.web/Dockerfile a webapps/example-db.web/Dockerfile).

    Existujici web s Dockerfile ze starsi sablony (engine ze zruseneho image pwe nebo ze zakladniho
    image pwe-<profil>, zruseny zaklad pwe-static): PWE/tools/check-webapp.pl (make check) na nej upozorni. Novy
    Dockerfile ziskas tak, ze web vygenerujes znovu jinam (--dir <docasny adresar>, stejny nazev
    a --db) a prevezmes z vysledku jen Dockerfile; vlastni upravy prenes rucne.

=cut

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Getopt::Long qw(GetOptions);
use File::Path qw(make_path);
use PWE::ToolEnv qw(core_root repo_root resolve_webapp webapp_name write_file symlink_rel profile_image dockerfile_base);

my %opt = ('db' => 'none', 'lang' => 'CZE,EN');
GetOptions(\%opt, 'db=s', 'title=s', 'lang=s', 'examples', 'dir=s', 'force', 'help|h') or usage(1);
usage(0) if ($opt{'help'});

my $name = shift(@ARGV);
usage(1) unless (defined($name));
die "Nazev webappu smi obsahovat jen pismena, cislice, tecku, pomlcku a podtrzitko: '$name'\n" unless ($name =~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/);
die "Neznamy driver --db '$opt{'db'}' (none|mariadb|mysql|postgres)\n" unless ($opt{'db'} =~ /^(none|mariadb|mysql|postgres)$/);

my $ROOT  = core_root();                                                  # koren enginu (adresar PWE/ v repozitari)
my $REPO  = repo_root();                                                  # koren repozitare (webapps/, docker-compose.yml)
my $APP   = ($opt{'dir'} ? resolve_webapp($opt{'dir'}) : "$REPO/webapps/$name");
my $DB    = ($opt{'db'} eq 'none' ? undef : $opt{'db'});
my $TITLE = (defined($opt{'title'}) and length($opt{'title'})) ? $opt{'title'} : $name;
my @LANGS = grep { length } map { uc } split(/\s*,\s*/, $opt{'lang'});
@LANGS = ('CZE') unless (@LANGS);

if (-e $APP and !$opt{'force'}) {
    die "Adresar $APP uz existuje (pouzij --force pro prepsani generovanych souboru).\n";
}

my @created;

# ---------------------------------------------------------------------------------------------
# CO SI WEB BERE Z ENGINU (zapisuje se do conf/web.conf jako pwe.core_*; zadne symlinky)
# ---------------------------------------------------------------------------------------------
make_path($APP) unless (-d $APP);

my @core_pages    = qw(css errorPage systemPage pweCreator);    # infrastrukturni stranky enginu
my @core_sites    = ();                                         # Default je vlastni
my @core_services = $DB ? qw(DBTable Session) : ();             # UserAccount je vlastni (nize)
my @core_entities = $DB ? qw(DBTable Session) : ();
my @menu_examples;
if ($opt{'examples'}) {
    push(@core_pages, qw(ajaxExamples formExamples responsive));
    push(@core_sites, 'Responsive');
    push(@menu_examples, ['ajaxExamples', 'Ajax'], ['formExamples', 'Forms'], ['responsive', 'Responsive']);
}

# vlastni sluzba uctu (bez DB stub nad Libs::User, s DB nad Services::Session z enginu)
put('Services/UserAccount/UserAccount.pm', ($DB ? gen_useraccount_db() : gen_useraccount_file()));
put_rb('Services/UserAccount', sub { "" });
put('Entities/.gitkeep', '');

# ---------------------------------------------------------------------------------------------
# VLASTNI MODULY WEBU
# ---------------------------------------------------------------------------------------------
put('Pages/default/default.pm', gen_default_page());
put('Pages/default/main.html',  gen_default_main());
put('Pages/default/msg.html',   gen_msg_html());
put_rb('Pages/default', \&gen_rb_default);

put('Sites/Default/Default.pm',          gen_site());
put('Sites/Default/layout_header.html',  gen_layout_header());
put('Sites/Default/layout_body.html',    gen_layout_body());
put('Sites/Default/layout_footer.html',  gen_layout_footer());
put_rb('Sites/Default', \&gen_rb_site);

put('static/css/site.css',      gen_site_css());
put('static/images/.gitkeep',   '');

# ---------------------------------------------------------------------------------------------
# KONFIGURACE A PROVOZ
# ---------------------------------------------------------------------------------------------
put('conf/web.conf', gen_web_conf());
if ($DB) {
    foreach my $drv (qw(mariadb mysql postgres)) {
        put("conf/$drv.conf",      gen_db_conf($drv));
        put("conf/$drv.dbversion", gen_dbversion($drv));
    }
    symlink_rel("$APP/conf/$DB.conf", "$APP/conf/database.conf");
    push(@created, "conf/database.conf -> $DB.conf (symlink, v .gitignore; v kontejneru ho podle PWE_PROFILE nastavuje entrypoint image)");
}

put('Dockerfile', gen_dockerfile());
put('.htaccess',  gen_htaccess());
put('robots.txt', "User-agent: *\nDisallow:\n");
put('vars',       gen_vars());
put('README.md',  gen_readme());

# docasne adresare (jsou v .gitignore: webapps/*/ramdisk, sessions, uploadfile, log)
make_path("$APP/$_") foreach (qw(ramdisk/templates sessions uploadfile log));

# ---------------------------------------------------------------------------------------------
# SHRNUTI
# ---------------------------------------------------------------------------------------------
my $rel = $APP;
$rel =~ s{^\Q$ROOT\E/}{};
print "Vytvoren webapp $rel (" . ($DB ? "databaze: $DB" : "bez databaze") . ", jazyky: @LANGS)\n";
print "  $_\n" foreach (@created);
print "\nDalsi kroky (z korene repozitare):\n";
print "  PWE/tools/check-webapp.pl $name" . ($opt{'dir'} ? " (pouzij cestu $APP)" : "") . "      # kontrola struktury, perl -c, smoke request\n";
print "  PWE/tools/new-module.pl page $name mojeStranka  # nova stranka (ze sablon pweCreator)\n";
print "  PWE/tools/run-webapp.sh $name" . ($DB ? " $DB" : " static") . "          # spusteni pres docker compose -> http://127.0.0.1:7778/\n";
print "  Vzhled: $rel/Sites/Default/layout_*.html, styly: $rel/static/css/site.css\n";
print "  Co si web bere z enginu, je v $rel/conf/web.conf (pwe.core_pages/core_sites/core_services/core_entities).\n";
exit 0;

# =============================================================================================
# POMOCNE FUNKCE
# =============================================================================================

sub usage {
    my ($code) = @_;
    print STDERR <<"USAGE";
Pouziti: PWE/tools/new-webapp.pl <nazev> [--db none|mariadb|mysql|postgres] [--title "Nazev"] [--lang CZE,EN]
                                  [--examples] [--dir <cesta>] [--force]
Vytvori kostru noveho webu ve webapps/<nazev>/ (detaily: perldoc PWE/tools/new-webapp.pl, docs/21-novy-web-podle-zadani.md).
USAGE
    exit($code);
}

# zapis souboru do webappu
sub put {
    my ($file, $content, %o) = @_;
    write_file("$APP/$file", $content, %o);
    push(@created, $file);
}

# rb.tmpl (prvni jazyk) + rb_<LANG>.tmpl pro ostatni jazyky; $body->($lang) vraci radky SET
sub put_rb {
    my ($dir, $body) = @_;
    foreach my $lang (@LANGS) {
        my $file = ($lang eq $LANGS[0]) ? "rb.tmpl" : "rb_$lang.tmpl";
        my $text = "[% # RESOURCE BUNDLE ($lang) %]\n\n" . $body->($lang) . "\n[% # POZOR: soubor rb*.tmpl musi koncit prazdnym radkem (bug parseru) %]\n\n";
        put("$dir/$file", $text);
    }
}

# nahrada {{PROMENNA}} v sablone
sub tpl {
    my ($text, %v) = @_;
    $text =~ s/\{\{(\w+)\}\}/exists($v{$1}) ? $v{$1} : die("new-webapp.pl: neznama promenna sablony $1\n")/ge;
    return $text;
}

# texty podle jazyka (CZE, EN; ostatni jazyky dostanou anglictinu k prekladu)
sub txt {
    my ($lang, $key) = @_;
    my %t = (
        'CZE' => {
            'menu_home'       => 'Domů',
            'footer'          => 'Postaveno na PWE (Perl Web Engine).',
            'ok_title'        => 'Hotovo',
            'error_title'     => 'Chyba',
            'home_intro'      => 'Nový web vytvořený nad enginem PWE. Obsah této stránky je v Pages/default/main.html, vzhled v Sites/Default/layout_*.html, texty v rb.tmpl.',
            'error_language'  => 'Neznámý jazyk.',
        },
        'EN' => {
            'menu_home'       => 'Home',
            'footer'          => 'Powered by PWE (Perl Web Engine).',
            'ok_title'        => 'Done',
            'error_title'     => 'Error',
            'home_intro'      => 'A new web built on the PWE engine. Edit Pages/default/main.html for content, Sites/Default/layout_*.html for the look and rb.tmpl for texts.',
            'error_language'  => 'Unknown language.',
        },
    );
    my $set = $t{$lang} || $t{'EN'};
    return $set->{$key};
}

sub cookie_name {
    my $c = uc($name);
    $c =~ s/[^A-Z0-9]+/-/g;
    $c =~ s/^-|-$//g;
    return "PWE-$c";
}

# ---------------------------------------------------------------------------------------------
# conf/web.conf
# ---------------------------------------------------------------------------------------------
sub gen_web_conf {
    my $langs = join(", ", map { "\"$_\"" } @LANGS);
    my $dbi = $DB
        ? "    dbi => {\n        # Naplni se z conf/database.conf (symlink na mariadb.conf / mysql.conf / postgres.conf,\n        # v kontejneru ho podle PWE_PROFILE nastavuje entrypoint image). Hesla prepisujte pres PWE_CONF_dbi_db1_*.\n    },\n\n"
        : "";
    my %v = (
        TITLE         => perl_str($TITLE),
        COOKIE        => cookie_name(),
        NAME          => $name,
        LANGS         => $langs,
        SAVE_OPT_TO   => ($DB ? 'db' : 'file'),
        DBI           => $dbi,
        REQUIRE_CORE  => core_version(),
        CORE_PAGES    => perl_list(@core_pages),
        CORE_SITES    => perl_list(@core_sites),
        CORE_SERVICES => perl_list(@core_services),
        CORE_ENTITIES => perl_list(@core_entities),
    );
    return tpl(<<'CONF', %v);
{
    pwe => {
        home              => undef,                                   # doplni engine (PWE_CONF_pwe_home / adresar pwe.fcgi)
        upload_dir        => "uploadfile/",                           # cil $USER->saveUploadFile
        opts_dir          => "sessions/",                             # opts soubory uzivatelu (save_opt_to = file)
        expire_opts_time  => 48,                                      # hodiny
        default_tmpl      => "templates/",
        pages_dir         => "Pages/",
        sites_dir         => "Sites/",
        services_dir      => "Services/",
        entities_dir      => "Entities/",
        smtp_servers      => [],                                      # napr. ["smtp_primary"] (sekce nize), pouziva Services::Email
        enable_opt        => 1,
        save_opt_to       => "{{SAVE_OPT_TO}}",                                   # file = bez databaze, db = Services::Session
        cgi_script_name   => undef,                                   # doplni engine
        cgi_disableupload => 0,
        cgi_maxfilesize   => (100 * 1048576),                         # 100 MB
        cgi_maxopentries  => 1000,
        cgi_tmpdirectory  => "ramdisk/",
        assets_file       => "/favicon.ico, robots.txt",              # soubory servirovane z korene webappu
        assets_dir        => "assets/, static/, uploadfile/",         # adresare servirovane pres Pages/systemPage (assets = PWE/assets enginu, static = vlastni)
        assets_browse_dir => "uploadfile/",                           # adresare, jejichz obsah lze vypsat
        default_page      => "default",
        default_func      => "default",
        development       => 1,                                       # 1 = vyvoj (DumpData, skupina admin pro vsechny), v produkci 0
        db_ping_interval  => 60,                                      # jak casto (s) overovat DB spojeni pingem; 0 = kazdy request

        # Engine = adresar PWE/ v koreni repozitare (v kontejneru /PWE/PWE); "core" v nazvech klicu znamena engine.
        # Web si z nej bere jen to, co tu vyjmenuje; stejny nazev modulu ve webu ma prednost.
        require_core      => ">={{REQUIRE_CORE}}",                              # minimalni verze enginu (PWE/VERSION)
        core_pages        => [{{CORE_PAGES}}],
        core_sites        => [{{CORE_SITES}}],
        core_services     => [{{CORE_SERVICES}}],
        core_entities     => [{{CORE_ENTITIES}}],
    },

    # SMTP server (Libs::Send, Services::Email). Skutecny ucet nastavte promennymi prostredi, ne editaci souboru:
    # PWE_CONF_smtp_primary_host/_port/_ssl/_starttls/_authid/_authpw (napr. v conf/local.env, ktery cte docker compose).
    # Priklady: Gmail smtp.gmail.com 587 starttls=1 (heslo aplikace), Seznam smtp.seznam.cz 465 ssl=1. Test: make smtp-test WEB=...
    smtp_primary => {
        host     => "localhost",
        port     => 25,
        timeout  => 5,
        debug    => 0,                                                # 1 = SMTP dialog v logu (obsahuje AUTH, jen pri ladeni)
        ssl      => 0,                                                # 1 = SMTPS (implicitni TLS, port 465)
        starttls => 0,                                                # 1 = STARTTLS po pripojeni (port 587)
        authid   => "",                                               # prihlasovaci jmeno k SMTP (prazdne = bez autentizace)
        authpw   => "",                                               # heslo - nikdy do gitu, jen PWE_CONF_smtp_primary_authpw
    },

    css => {
        src_css    => "static",                                       # static = soubor static_css, scss = preklad scss_src pri kazdem requestu
        scss_src   => "/static/scss/site.scss",
        scss_out   => "/static/css/site.css",
        scss_bin   => "/usr/bin/sass -C --scss --style=compressed",
        static_css => "/static/css/site.css",
    },

    http => {
        http_host_path      => "/",                                   # path pro cookie
        layout_error_header => "templates/LayoutErrorHeader.html",
        layout_error_body   => "templates/LayoutErrorBody.html",
        languages           => [{{LANGS}}],                            # prvni jazyk = vychozi (rb.tmpl), dalsi = rb_<LANG>.tmpl
        name                => {{TITLE}},
        title               => {{TITLE}},
        keywords            => '',
        description         => '',
        cookie_name         => '{{COOKIE}}',
        base_url            => '{{NAME}}',                            # pouziva se pri generovani odkazu mimo HTTP request (cron)
        cookie_expire_guest => 3,                                     # dny
        cookie_expire_user  => 30,                                    # dny
    },

    web => {
        email_admin    => 'admin@example.com',                        # prijemce reportu enginu a e-mailu webu (musi projit is_email, ne @localhost)
        email_subtitle => {{TITLE}},
    },

    tmpl => {
        croot => "ramdisk/templates/",                                # cache prelozenych sablon
        cache => 1,
    },

{{DBI}}    log => {
        loglevel             => 1,                                    # 0=DISABLE, 1=ERROR, 2=WARNING, 3=INFO, 4=DEBUG
        filter_list          => [],
        error_filter_list    => [],
        warning_filter_list  => [],
        info_filter_list     => [],
        debug_filter_list    => [],
        print_filter_list    => [],
        delay_filter_list    => [],
        exclude_list         => [],
        error_exclude_list   => [],
        warning_exclude_list => [],
        info_exclude_list    => [],
        debug_exclude_list   => [],
        print_exclude_list   => [],
        delay_exclude_list   => [],
        logout               => "STDERR",                             # undef = /dev/null, STDOUT, STDERR, log/pwe.log
        log_delay            => 0,                                    # 1 = merit casy (profilovani)
        log_delay_minimum    => "0.001",
        error_report_interval => 300,                                # stejnou chybu hlasit e-mailem nejvyse jednou za N s (0 = vzdy)
    },
};
CONF
}

# seznam retezcu pro Perl pole: "a", "b"
sub perl_list {
    return join(", ", map { "\"$_\"" } @_);
}

# verze enginu (PWE/VERSION) bez patch cisla, pro pwe.require_core
sub core_version {
    my $v = '1.0';
    if (open(my $fh, '<', "$ROOT/VERSION")) {
        my $line = <$fh>;
        close($fh);
        if (defined($line) and $line =~ /^\s*(\d+)\.(\d+)/) { $v = "$1.$2"; }
    }
    return $v;
}

# Perl retezcovy literal (jednoduche uvozovky)
sub perl_str {
    my ($s) = @_;
    $s =~ s/\\/\\\\/g;
    $s =~ s/'/\\'/g;
    return "'$s'";
}

sub gen_db_conf {
    my ($drv) = @_;
    my %port   = ('mariadb' => 3306, 'mysql' => 3306, 'postgres' => 5432);
    my $schema = ($drv eq 'postgres') ? "        schema         => \"public\",\n" : "";
    return tpl(<<'CONF', DRV => $drv, PORT => $port{$drv}, SCHEMA => $schema);
{
    'db1' => {
        dbdriver       => "{{DRV}}",
        login          => "pwe",                      # prepis: PWE_CONF_dbi_db1_login
        password       => "pwe",                      # prepis: PWE_CONF_dbi_db1_password
        database       => "pwe",                      # prepis: PWE_CONF_dbi_db1_database
        host           => "{{DRV}}",                  # nazev sluzby v docker-compose.yml
        port           => {{PORT}},
{{SCHEMA}}        logfile        => "log/{{DRV}}",
        loglevel       => 0,                          # DBI trace: 1 = kazde SQL vcetne vazanych hodnot do logfile (jen ladeni: PWE_CONF_dbi_db1_loglevel=1 v conf/local.env)
        dao            => 1,                          # zapne DAO/Entity vrstvu
        db_pool        => 3,
        trayconnect    => 10,
        daomap_file    => "conf/{{DRV}}_daomap.dump",
        dbversion_file => "conf/{{DRV}}.dbversion",
        dbversion_session_lock     => 1,              # zamek migrace vazany na spojeni, server ho po padu procesu uvolni sam (0 = vypnout); prepis: PWE_CONF_dbi_db1_dbversion_session_lock
        dbversion_legacy_lock_wait => 300,            # po kolika s beze zmeny prevzit zamek dbversion.lockid po procesu bez zamku spojeni (0 = nikdy); prepis: PWE_CONF_dbi_db1_dbversion_legacy_lock_wait
    }
};
CONF
}

sub gen_dbversion {
    my ($drv) = @_;
    if ($drv eq 'postgres') {
        return <<'SQL';
{
    # Migrace schematu: engine aplikuje klice vetsi nez aktualni verze (tabulka dbversion).
    # Dalsi tabulky pridavejte jako 3 => "CREATE TABLE ...", 4 => "ALTER TABLE ...".
    1 => "
        CREATE TABLE dbtable (
            id          SERIAL        NOT NULL PRIMARY KEY,
            name        VARCHAR(128)  NULL,
            dbid        VARCHAR(32)   NOT NULL DEFAULT 'db1',
            sid         VARCHAR(128)  NOT NULL,
            page        VARCHAR(128)  NULL,
            func        VARCHAR(128)  NULL,
            tmpl        VARCHAR(256)  NULL,
            script      VARCHAR(256)  NULL,
            query       TEXT          NOT NULL,
            conditions  TEXT          NOT NULL,
            ordercolumn VARCHAR(64)   NULL,
            orderby     VARCHAR(64)   NULL DEFAULT 'ASC',
            groupby     VARCHAR(128)  NULL,
            maxrow      INTEGER       NULL DEFAULT 40,
            gopage      INTEGER       NULL DEFAULT 1,
            rowcount    INTEGER       NULL DEFAULT 0,
            endpage     SMALLINT      NULL DEFAULT 0,
            appendurl   VARCHAR(256)  NULL,
            nlimit      SMALLINT      NULL,
            updated     TIMESTAMP WITH TIME ZONE NULL,
            created     TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
        );
    ",
    2 => "
        CREATE TABLE session (
            sid         VARCHAR(256)  NOT NULL PRIMARY KEY,
            useragent   VARCHAR(256)  NOT NULL,
            ipaddres    VARCHAR(128)  NOT NULL,
            admin       BOOLEAN       NOT NULL DEFAULT FALSE,
            messenger   TEXT          NULL,
            lang        VARCHAR(32)   DEFAULT 'CZE',
            expire      INT           NOT NULL,
            updated     TIMESTAMP WITH TIME ZONE NULL,
            created     TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
        );
    ",
};
SQL
    }
    return <<'SQL';
{
    # Migrace schematu: engine aplikuje klice vetsi nez aktualni verze (tabulka dbversion).
    # Dalsi tabulky pridavejte jako 3 => "CREATE TABLE ...", 4 => "ALTER TABLE ...".
    1 => "
        CREATE TABLE `dbtable` (
          `id` int(8) unsigned NOT NULL AUTO_INCREMENT,
          `name` varchar(128) DEFAULT NULL,
          `dbid` varchar(32) NOT NULL DEFAULT 'db1',
          `sid` varchar(128) DEFAULT NULL,
          `page` varchar(128) DEFAULT NULL,
          `func` varchar(128) DEFAULT NULL,
          `tmpl` varchar(255) DEFAULT NULL,
          `script` varchar(255) DEFAULT NULL,
          `query` text NOT NULL,
          `conditions` text NOT NULL,
          `ordercolumn` varchar(64) DEFAULT NULL,
          `orderby` varchar(64) DEFAULT 'ASC',
          `groupby` varchar(128) DEFAULT NULL,
          `maxrow` int(11) DEFAULT 40,
          `gopage` int(11) DEFAULT 1,
          `rowcount` int(11) DEFAULT 0,
          `endpage` smallint(6) DEFAULT 0,
          `appendurl` varchar(255) DEFAULT NULL,
          `nlimit` smallint(6) DEFAULT NULL,
          `updated` timestamp NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
          `created` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
          PRIMARY KEY (`id`),
          KEY `name` (`name`),
          KEY `sid` (`sid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_czech_ci;
    ",
    2 => "
        CREATE TABLE `session` (
          `sid` varchar(255) NOT NULL,
          `useragent` varchar(255) NOT NULL,
          `ipaddres` varchar(128) NOT NULL,
          `admin` enum ('t', 'f') NOT NULL DEFAULT 'f',
          `messenger` text DEFAULT NULL,
          `lang` varchar(32) NOT NULL DEFAULT 'CZE',
          `expire` int(12) NOT NULL,
          `updated` timestamp NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
          `created` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
          PRIMARY KEY (`sid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_czech_ci;
    ",
};
SQL
}

# ---------------------------------------------------------------------------------------------
# Pages/default
# ---------------------------------------------------------------------------------------------
sub gen_default_page {
    return tpl(<<'PERL', NAME => $name);
package Pages::default::default;

=head1 NAME

Pages::default::default - uvodni stranka webu {{NAME}}

=cut

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

=head2 B<[Public] new($self,$conf,$log,$validate,$dbi,$entities,$user,$web)>

    Uvodni stranka webu. Registrovane akce (?page=default&func=...):
      default     - vykresli Pages/default/main.html
      setlanguage - prepne jazyk podle parametru lang (pravidlo is_language), pri chybe vola error

=cut

sub new {
    my ($class, $self, $conf, $log, $validate, $dbi, $entities, $user, $web) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $CONF     = $conf;
    $USER     = $user;
    $WEB      = $web;
    $VALIDATE = $validate;
    $ENTITIES = $entities;

    $self->{'func'}->{'default'}     = [];
    $self->{'func'}->{'setlanguage'} = [];

    $self->{'rules'}->{'setlanguage'}->{'lang'} = [['is_language', 'error_language', 'parameter']];
    $self->{'error'}->{'setlanguage'} = "error";

    bless $self, $class;
    return $self;
}

=head2 B<[Private] Site_Default($site)>

    Injektaz vzhledu Sites::Default (vola loader) - $WEB je od te chvile vzhled webu.

=cut

sub Site_Default {
    my ($self, $input) = @_;
    $WEB = $input;
}

=head2 B<[Private] Service_UserAccount($service)>

    Injektaz sluzby UserAccount - nahradi $USER objektem se stejnym API jako Libs::User,
    rozsirenym o ucet a skupiny uzivatele.

=cut

sub Service_UserAccount {
    my ($self, $input) = @_;
    $USER = $input;
}

# KOMODO-IDE/KOMODO-EDIT
sub KOMODO {
    return;
    require Libs::Config;
    require Libs::Log;
    require Libs::Validate;
    require Libs::DBI;
    require Libs::Entities;
    require Services::UserAccount::UserAccount;
    require Sites::Default::Default;
    $CONF     = new Libs::Config;
    $LOG      = new Libs::Log;
    $VALIDATE = new Libs::Validate;
    $DBI      = new Libs::DBI;
    $ENTITIES = new Libs::Entities;
    $USER     = new Services::UserAccount::UserAccount;
    $WEB      = new Sites::Default::Default;
}

=head2 B<[Public] default()>

    Vykresli uvodni stranku (layout vzhledu + Pages/default/main.html).

=cut

sub default {
    my $self = shift;

    $WEB->setIDP("default");
    $WEB->printHttpHeader();
    $WEB->printHtmlHeader();
    $WEB->printHtmlLayout(html_main => "Pages/default/main.html");
}

=head2 B<[Public] setlanguage()>

    Nastavi jazyk uzivatele podle parametru lang a znovu vykresli uvodni stranku.

=cut

sub setlanguage {
    my $self = shift;

    my $default = $CONF->getValue("http", "languages", ["CZE"])->[0];
    $USER->setLanguage($USER->getParam("lang", 0, $default));
    $self->default();
}

=head2 B<[Public] error($error)>

    Chyby validace (pole klicu error_*): zobrazi je v messengeru; pri AJAX requestu vrati 400,
    jinak znovu vykresli stranku.

=cut

sub error {
    my ($self, $error) = @_;

    $WEB->setMessenger("Pages/default/msg.html", msg_error => $error);
    return 400 if ($USER->getParam("ajax_request", 0, undef));
    $self->default();
}

1;
PERL
}

sub gen_default_main {
    return <<'HTML';
[% PROCESS templates/resource_bundle.tmpl %]
<div class="p-5 mb-4 bg-body-tertiary rounded-3">
  <h1 class="display-6">[% rb.home_title %]</h1>
  <p class="lead mb-0">[% rb.home_intro %]</p>
</div>
HTML
}

sub gen_msg_html {
    return "[% PROCESS templates/resource_bundle.tmpl %]\n\n[% INCLUDE templates/messenger.html %]\n";
}

sub gen_rb_default {
    my ($lang) = @_;
    return join("",
        "[% SET rb.home_title = " . tt_str($TITLE) . " %]\n",
        "[% SET rb.home_intro = " . tt_str(txt($lang, 'home_intro')) . " %]\n",
        "\n",
        "[% SET rb.msg.error_language = " . tt_str(txt($lang, 'error_language')) . " %]\n",
    );
}

# retezec pro Template Toolkit (dvojite uvozovky)
sub tt_str {
    my ($s) = @_;
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\$/\\\$/g;
    return "\"$s\"";
}

# ---------------------------------------------------------------------------------------------
# Sites/Default
# ---------------------------------------------------------------------------------------------
sub gen_site {
    my $session_var    = $DB ? ', $SESSION' : '';
    my $session_inject = $DB ? <<'PERL' : '';

=head2 B<[Private] Service_Session($service)>

    Injektaz sluzby Session (vola loader) - messenger se uklada do DB session, ne do opts souboru.

=cut

sub Service_Session {
    my ($self, $input) = @_;
    $SESSION = $input;
}
PERL
    my $messenger_html = $DB ? "\n    \$tmpl{'messenger'} = \$self->getMessenger() if (\$self->existMessenger());\n" : "";
    my $messenger_ajax = $DB ? "\n    \$self->setAjax('messenger', \$self->getMessenger()) if (\$self->existMessenger());\n" : "";
    my $messenger_methods = $DB ? <<'PERL' : <<'PERL2';
=head2 B<[Public] setMessenger($tmpl,%tmpl)>

    Ulozi flash zpravu (vyrenderovanou sablonu $tmpl) do DB session (Services::Session),
    zobrazi se pri pristim printHtmlLayout/printAjaxLayout.

=cut

sub setMessenger {
    my ($self, $msg, %tmpl) = @_;
    $SESSION->setValue('messenger', $WEB->genTmpl($msg, %tmpl));
}

=head2 B<[Public] getMessenger()>

    Vrati flash zpravu ze session a smaze ji (zobrazi se jen jednou).

=cut

sub getMessenger {
    my $self = shift;
    my $msg = $SESSION->getValue('messenger');
    $SESSION->setValue('messenger', undef);
    return $msg;
}

=head2 B<[Public] existMessenger()>

    Vraci 1/undef podle toho, zda je v session ulozena flash zprava.

=cut

sub existMessenger {
    my $self = shift;
    return $SESSION->existKeyValue('messenger');
}
PERL
=head2 B<[Public] setMessenger($tmpl,%tmpl)>

    Flash zprava - deleguje na Libs::Web (uklada se do opts souboru uzivatele).

=cut

sub setMessenger   { my $self = shift; return $WEB->setMessenger(@_); }
sub getMessenger   { my $self = shift; return $WEB->getMessenger(@_); }
sub existMessenger { my $self = shift; return $WEB->existMessenger(@_); }
PERL2
    my $komodo_session = $DB ? "    require Services::Session::Session;\n" : "";
    my $komodo_session2 = $DB ? "    \$SESSION  = new Services::Session::Session;\n" : "";

    return tpl(<<'PERL', NAME => $name, SESSION_VAR => $session_var, SESSION_INJECT => $session_inject, MESSENGER_HTML => $messenger_html, MESSENGER_AJAX => $messenger_ajax, MESSENGER_METHODS => $messenger_methods, KOMODO_SESSION => $komodo_session, KOMODO_SESSION2 => $komodo_session2);
package Sites::Default::Default;

=head1 NAME

Sites::Default::Default - vzhled webu {{NAME}} (layout, menu, messenger), fasada nad Libs::Web

=cut

use strict;

our ($AUTOLOAD);

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB{{SESSION_VAR}});

=head2 B<[Public] new($conf,$log,$validate,$dbi,$entities,$user,$web)>

    Vzhled webu: drzi cesty k layoutum (Sites/Default/layout_*.html) a doplnuje vychozi
    hodnoty do kazde sablony. Stranky ho dostavaji metodou Site_Default jako $WEB a volaji
    printHttpHeader / printHtmlHeader / printHtmlLayout / printAjaxLayout / setMessenger.

=cut

sub new {
    my ($class, $conf, $log, $validate, $dbi, $entities, $user, $web) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $WEB      = $web;
    $CONF     = $conf;
    $USER     = $user;
    $VALIDATE = $validate;
    $ENTITIES = $entities;

    my $self = {
        'web_site'      => "default",
        'web_index'     => "/default",
        'layout_header' => "Sites/Default/layout_header.html",
        'layout_body'   => "Sites/Default/layout_body.html",
    };

    bless $self, $class;
    return $self;
}
{{SESSION_INJECT}}
=head2 B<[Public] getDefaultTemplateValues()>

    Vychozi promenne pro kazdou sablonu (web_site, web_index, layout_body). Sem patri data,
    ktera potrebuje layout na kazde strance (polozky menu, prihlaseny uzivatel, ...).

=cut

sub getDefaultTemplateValues {
    my $self = shift;

    return (
        'web_site'    => $self->{'web_site'},
        'web_index'   => $self->{'web_index'},
        'layout_body' => $self->{'layout_body'},
    );
}

=head2 B<[Public] printHtmlHeader(%tmpl)>

    Vytiskne <html><head> z layout_header.html (css = conf css.src_css).

=cut

sub printHtmlHeader {
    my ($self, %tmpl) = @_;

    $tmpl{'layout_header'} = $self->{'layout_header'} unless (exists($tmpl{'layout_header'}));
    $tmpl{'css'} = $CONF->getValue("css", "src_css", "static");

    $WEB->printHtmlHeader(%tmpl);
}

=head2 B<[Public] printHtmlLayout(%tmpl)>

    Vytiskne telo stranky: layout_body.html, ktery includuje html_main stranky. Doplni
    vychozi hodnoty (getDefaultTemplateValues) a messenger.

=cut

sub printHtmlLayout {
    my ($self, %tmpl) = @_;

    my %def = $self->getDefaultTemplateValues();
    foreach my $key (keys %def) {
        $tmpl{$key} = $def{$key} unless (exists($tmpl{$key}));
    }
{{MESSENGER_HTML}}
    $WEB->printHtmlLayout(%tmpl);
}

=head2 B<[Public] printAjaxLayout(%tmpl)>

    AJAX odpoved (JSON REPLACE): do kazdeho ajax_data doplni vychozi hodnoty a prida messenger.

=cut

sub printAjaxLayout {
    my ($self, %tmpl) = @_;

    if ((ref($tmpl{'ajax_tmpl'}) eq "ARRAY") and (ref($tmpl{'ajax_id'}) eq "ARRAY")) {

        my %defvalue = $self->getDefaultTemplateValues();

        if (ref($tmpl{'ajax_data'}) ne "ARRAY") {
            if (ref($tmpl{'ajax_data'}) eq "HASH") {
                $tmpl{'ajax_data'} = [$tmpl{'ajax_data'}];
            } else {
                $LOG->error("Invalid set AjaxLayout data !");
                $tmpl{'ajax_data'} = [{}];
            }
        }

        foreach my $hash (@{$tmpl{'ajax_data'}}) {
            foreach my $key (keys %defvalue) {
                $hash->{$key} = $defvalue{$key} unless (exists($hash->{$key}));
            }
        }
    }
{{MESSENGER_AJAX}}
    $WEB->printAjaxLayout(%tmpl);
}

{{MESSENGER_METHODS}}
# Ostatni metody deleguje na Libs::Web (explicitne ty nejpouzivanejsi, zbytek pres AUTOLOAD).
sub genTmpl               { my $self = shift; return $WEB->genTmpl(@_); }
sub printHttpHeader       { my $self = shift; return $WEB->printHttpHeader(@_); }
sub setIDP                { my $self = shift; return $WEB->setIDP(@_); }
sub getIDP                { my $self = shift; return $WEB->getIDP(@_); }
sub setAjax               { my $self = shift; return $WEB->setAjax(@_); }
sub renderReplaceJSON     { my $self = shift; return $WEB->renderReplaceJSON(@_); }
sub getScriptName         { my $self = shift; return $WEB->getScriptName(@_); }
sub getValue              { my $self = shift; return $WEB->getValue(@_); }
sub convertToRewrite      { my $self = shift; return $WEB->convertToRewrite(@_); }
sub findResourceBundles   { my $self = shift; return $WEB->findResourceBundles(@_); }
sub getResourceBundleList { my $self = shift; return $WEB->getResourceBundleList(@_); }

=head2 B<[Private] AUTOLOAD(...)>

    Nezname metody deleguje na Libs::Web.

=cut

sub AUTOLOAD {
    my $self = shift;
    my $name = $AUTOLOAD;
    $name =~ s/.*://;
    return if ($name =~ /^DESTROY$/);
    return $WEB->$name(@_);
}

# KOMODO-IDE/KOMODO-EDIT
sub KOMODO {
    return;
    require Libs::Config;
    require Libs::Log;
    require Libs::Validate;
    require Libs::DBI;
    require Libs::Web;
    require Libs::Entities;
    require Libs::User;
{{KOMODO_SESSION}}    $CONF     = new Libs::Config;
    $LOG      = new Libs::Log;
    $VALIDATE = new Libs::Validate;
    $ENTITIES = new Libs::Entities;
    $DBI      = new Libs::DBI;
    $WEB      = new Libs::Web;
    $USER     = new Libs::User;
{{KOMODO_SESSION2}}}

1;
PERL
}

sub gen_layout_header {
    return <<'HTML';
<!DOCTYPE html>
<html lang="[% IF use_language == 'EN' %]en[% ELSE %]cs[% END %]" data-bs-theme="light">
  <head>
    [% PROCESS templates/resource_bundle.tmpl %]
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="description" content="[% conf_description %]">
    <meta name="keywords" content="[% conf_keywords %]">
    <title>[% IF title %][% title | html %] | [% END %][% conf_title | html %]</title>
    [% # Bootstrap 5.3, Font Awesome 6, jQuery 4 a pwe.js se serviruji z enginu (PWE/assets) %]
    <link rel="stylesheet" href="assets/css/bootstrap-5.3.8/bootstrap.min.css" />
    <link rel="stylesheet" href="assets/css/fontawesome-free-6.4.2/all.min.css" />
    [% IF css == "static" %]
    <link rel="stylesheet" href="static/css/site.css?v=[% start_time %]" />
    [% ELSE %]
    <link rel="stylesheet" href="[% script_name %]?page=css&func=default&random=[% random_number %]" />
    [% END %]
    <script src="assets/javascript/jquery-4.0.0/jquery-4.0.0.min.js"></script>
    <script src="assets/javascript/bootstrap-5.3.8/bootstrap.bundle.min.js"></script>
    <script src="assets/javascript/ajaxprogress.js"></script>
    <script src="assets/javascript/pwe.js"></script>
  </head>
HTML
}

sub gen_layout_body {
    my $menu = join("\n", map { my ($p, $t) = @{$_};
        "        <li class=\"nav-item\"><a class=\"nav-link[% IF idp == \"$p\" %] active[% END %]\" href=\"[% script_name %]?page=$p&func=default\">$t</a></li>" } @menu_examples);
    $menu = "\n$menu" if ($menu);
    return tpl(<<'HTML', MENU_EXAMPLES => $menu);
<body>
[% PROCESS templates/resource_bundle.tmpl %]
<nav class="navbar navbar-expand-lg bg-body-tertiary border-bottom mb-4">
  <div class="container">
    <a class="navbar-brand" href="[% script_name %]">[% rb.site_brand %]</a>
    <button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#pwe-navbar" aria-controls="pwe-navbar" aria-expanded="false" aria-label="Toggle navigation">
      <span class="navbar-toggler-icon"></span>
    </button>
    <div class="collapse navbar-collapse" id="pwe-navbar">
      <ul class="navbar-nav me-auto">
        <li class="nav-item"><a class="nav-link[% IF idp == "default" %] active[% END %]" href="[% script_name %]?page=default&func=default">[% rb.menu_home %]</a></li>{{MENU_EXAMPLES}}
      </ul>
      <ul class="navbar-nav ms-auto">
        [% IF group.admin %]<li class="nav-item"><a class="nav-link[% IF idp == "pweCreator" %] active[% END %]" href="[% script_name %]?page=pweCreator&func=default">pweCreator</a></li>[% END %]
        [% IF languages.size > 1 %][% FOREACH l IN languages %]<li class="nav-item"><a class="nav-link[% IF use_language == l %] active fw-bold[% END %]" href="[% script_name %]?page=default&func=setlanguage&lang=[% l %]">[% l %]</a></li>[% END %][% END %]
        [% IF conf_development %]<li class="nav-item"><a class="nav-link" href="#" data-bs-toggle="modal" data-bs-target="#DumpData">DataDump</a></li>[% END %]
      </ul>
    </div>
  </div>
</nav>

<div class="container">
  <div id="messenger">[% messenger %]</div>
  [% IF html_main %][% INCLUDE $html_main %][% ELSIF print_main %][% print_main %][% END %]
</div>

[% INCLUDE Sites/Default/layout_footer.html %]
</body>
</html>
HTML
}

sub gen_layout_footer {
    return <<'HTML';
<footer class="container py-4 text-body-secondary small pwe-footer">
  <hr />
  <p class="mb-0">[% rb.footer_text %]</p>
</footer>
[% IF conf_development %]
<!-- Vypis dat sablony (jen pwe.development = 1) -->
<div class="modal fade" id="DumpData" tabindex="-1" aria-labelledby="DumpDataLabel" aria-hidden="true">
  <div class="modal-dialog modal-xl modal-dialog-scrollable">
    <div class="modal-content">
      <div class="modal-header">
        <h1 class="modal-title fs-5" id="DumpDataLabel">Dump template data</h1>
        <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button>
      </div>
      <div class="modal-body">
        [% INCLUDE templates/DumpData.tmpl %]
      </div>
      <div class="modal-footer">
        <button type="button" class="btn btn-secondary" data-bs-dismiss="modal">Close</button>
      </div>
    </div>
  </div>
</div>
[% END %]
HTML
}

sub gen_rb_site {
    my ($lang) = @_;
    return join("",
        "[% SET rb.site_brand = " . tt_str($TITLE) . " %]\n",
        "[% SET rb.menu_home = " . tt_str(txt($lang, 'menu_home')) . " %]\n",
        "[% SET rb.footer_text = " . tt_str(txt($lang, 'footer')) . " %]\n",
        "\n",
        "[% # titulky flash zprav (templates/messenger.html) %]\n",
        "[% SET rb.messanger_allright_title = " . tt_str(txt($lang, 'ok_title')) . " %]\n",
        "[% SET rb.messanger_error_title = " . tt_str(txt($lang, 'error_title')) . " %]\n",
    );
}

sub gen_site_css {
    return tpl(<<'CSS', NAME => $name);
/* Vlastni styly webu {{NAME}}. Bootstrap 5.3.8, Font Awesome 6.4.2, jQuery 4.0.0 a pwe.js
   se serviruji z enginu (PWE/assets) - sem patri jen to, co je specificke pro tento web. */

body { padding-bottom: 2rem; }

#messenger .alert { margin-top: 1rem; }

.pwe-footer { font-size: 90%; }
CSS
}

# ---------------------------------------------------------------------------------------------
# Services/UserAccount
# ---------------------------------------------------------------------------------------------
sub gen_useraccount_file {
    return tpl(<<'PERL', NAME => $name);
package Services::UserAccount::UserAccount;

=head1 NAME

Services::UserAccount::UserAccount - ucet a skupiny uzivatele webu {{NAME}} (varianta bez databaze)

=cut

use strict;
our ($AUTOLOAD);

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

=head2 B<[Public] new($conf,$log,$validate,$dbi,$entities,$user,$web)>

    Sluzba uzivatelskeho uctu. Web bez databaze nema session v DB, stav uzivatele drzi
    Libs::User (opts soubor). Do stranek se injektuje metodou Service_UserAccount a nahrazuje
    $USER (nezname metody deleguje na Libs::User).

    POZOR: ve vyvojovem rezimu (conf pwe.development = 1) dostane kazdy navstevnik skupinu
    'admin' (pristup k pweCreator). Skutecne prihlaseni doplnte do newRequest.

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

    my $self = {'account' => {}, 'group' => {}};

    bless $self, $class;
    return $self;
}

=head2 B<[Public] newRequest()>

    Zacatek requestu (vola Libs::Services). Nastavi skupiny uzivatele: ve vyvojovem rezimu
    admin, jinak zustava vychozi guest.

=cut

sub newRequest {
    my $self = shift;

    $self->{'account'} = {};
    $self->{'group'}   = {};

    # TODO prihlaseni: podle opts ($USER->getOpts) nebo cookie nacist ucet a skupiny uzivatele.

    if ($CONF->getValue("pwe", "development", 0)) {
        $self->{'group'}->{'admin'} = 1;
        $USER->deleteGroup('guest');
        $USER->addGroup('admin');
    }
}

=head2 B<[Public] getAccount()>

    Vraci hash dat uctu prihlaseneho uzivatele (prazdny, dokud neni implementovano prihlaseni).

=cut

sub getAccount {
    my $self = shift;
    return $self->{'account'};
}

=head2 B<[Public] getGroup()>

    Vraci hash skupin uzivatele podle teto sluzby (napr. { admin => 1 }).

=cut

sub getGroup {
    my $self = shift;
    return $self->{'group'};
}

=head2 B<[Public] flush()>

    Konec requestu: vynuluje ucet a skupiny v objektu.

=cut

sub flush {
    my $self = shift;
    $self->{'account'} = {};
    $self->{'group'}   = {};
}

=head2 B<[Private] AUTOLOAD(...)>

    Nezname metody deleguje na Libs::User (getParam, getSid, setLanguage, ...).

=cut

sub AUTOLOAD {
    my $self = shift;
    my $name = $AUTOLOAD;
    $name =~ s/.*://;
    return if ($name =~ /^DESTROY$/);
    return $USER->$name(@_);
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
    $CONF     = new Libs::Config;
    $LOG      = new Libs::Log;
    $VALIDATE = new Libs::Validate;
    $DBI      = new Libs::DBI;
    $ENTITIES = new Libs::Entities;
    $USER     = new Libs::User;
    $WEB      = new Libs::Web;
}

1;
PERL
}

sub gen_useraccount_db {
    return tpl(<<'PERL', NAME => $name);
package Services::UserAccount::UserAccount;

=head1 NAME

Services::UserAccount::UserAccount - ucet a skupiny uzivatele webu {{NAME}} nad Services::Session

=cut

use strict;
our ($AUTOLOAD);

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB, $SESSION);

=head2 B<[Public] new($conf,$log,$validate,$dbi,$entities,$user,$web)>

    Sluzba uzivatelskeho uctu nad Services::Session (tabulka session v DB). V kazdem requestu
    nacte session, ucet a skupiny uzivatele. Do stranek se injektuje metodou
    Service_UserAccount a nahrazuje $USER (nezname metody deleguje na Session -> Libs::User).

    POZOR: ve vyvojovem rezimu (conf pwe.development = 1) dostane kazdy navstevnik skupinu
    'admin' (pristup k pweCreator). Skutecne prihlaseni doplnte do newRequest.

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

    my $self = {'session' => {}, 'account' => {}, 'group' => {}};

    bless $self, $class;
    return $self;
}

=head2 B<[Private] Service_Session($service)>

    Injektaz sluzby Session (vola loader).

=cut

sub Service_Session {
    my ($self, $input) = @_;
    $SESSION = $input;
}

=head2 B<[Public] newRequest()>

    Zacatek requestu (vola Libs::Services): nacte/zalozi session (Services::Session::newSession),
    vynuluje ucet a nastavi skupiny - ve vyvojovem rezimu admin, jinak zustava guest.

=cut

sub newRequest {
    my $self = shift;

    $self->{'session'} = $SESSION->newSession();
    $self->{'account'} = {};
    $self->{'group'}   = {};

    # TODO prihlaseni: podle hodnoty v session (napr. $SESSION->getValue('uid')) nacist ucet
    #      z vlastni entity a nastavit skupiny ($USER->addGroup('user')).

    if ($CONF->getValue("pwe", "development", 0)) {
        $self->{'group'}->{'admin'} = 1;
        $USER->deleteGroup('guest');
        $USER->addGroup('admin');
    }
}

=head2 B<[Public] setLanguage($lang)>

    Nastavi jazyk uzivatele do session (perzistentne) i do Libs::User pro aktualni request.

=cut

sub setLanguage {
    my ($self, $lang) = @_;
    $SESSION->setValue('lang', $lang);
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

    Vraci hash dat uctu prihlaseneho uzivatele (prazdny, dokud neni implementovano prihlaseni).

=cut

sub getAccount {
    my $self = shift;
    return $self->{'account'};
}

=head2 B<[Public] getGroup()>

    Vraci hash skupin uzivatele podle teto sluzby (napr. { admin => 1 }).

=cut

sub getGroup {
    my $self = shift;
    return $self->{'group'};
}

=head2 B<[Public] flush()>

    Konec requestu: vynuluje session, ucet a skupiny v objektu (zapis session do DB dela
    Services::Session::flush).

=cut

sub flush {
    my $self = shift;
    $self->{'session'} = {};
    $self->{'account'} = {};
    $self->{'group'}   = {};
}

=head2 B<[Private] AUTOLOAD(...)>

    Nezname metody deleguje na Services::Session (a ta dale na Libs::User).

=cut

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
PERL
}

# ---------------------------------------------------------------------------------------------
# Docker / provoz
# ---------------------------------------------------------------------------------------------
# Dockerfile webu: jednotna sablona pro vsechny weby (lisi se nazvem webu, PWE_PROFILE a zakladem).
# Image webu = zavislostni image + engine + web:
#   - jediny FROM = zavislostni image BEZ kodu enginu: pwe-base pro web bez databaze, pwe-${PWE_PROFILE} pro
#     web s databazi (PWE::ToolEnv::dockerfile_base),
#   - engine se kopiruje z kontextu sestaveni (koren repozitare): LICENSE a vsechny polozky adresare PWE/
#     krome PWE::ToolEnv::engine_image_excludes() (t, docker). Vycet COPY je zamerne vyslovny (zadne mazani
#     v image, zadny COPY --from jineho image); PWE/t/14-tools.t hlida, ze pokryva kazdou polozku PWE/ - nova
#     polozka enginu = doplnit ji sem a znovu vygenerovat Dockerfile vzorovych webu,
#   - web z webapps/<web>.
# ENTRYPOINT sablona nenastavuje a web zadny entrypoint.sh nema: image webu ho dedi ze zakladniho image
# (zdroj PWE/docker/entrypoint.sh).
# POZOR pri uprave: prikaz RUN sablony spousti i PWE/t/14-tools.t (v kontejneru s repozitarem v /PWE), mimo
# docker build. Zadny RUN sablony proto nesmi nic mazat ani zapisovat mimo pracovni adresar webu.
# Radek FROM a vycet COPY sablony cte PWE/tools/check-webapp.pl (kontrola Dockerfile webu).
sub gen_dockerfile {
    my $profile = $DB ? $DB : 'static';
    my $image   = lc($name);                 # jmeno image v ukazkach buildu: mujweb.web -> mujweb-web
    $image =~ s/[^a-z0-9]+/-/g;
    $image =~ s/^-+|-+$//g;
    $image = 'web' unless (length($image));
    my $base      = dockerfile_base($profile);                 # pwe-base | pwe-${PWE_PROFILE}
    my $base_name = $DB ? 'pwe-<profil>' : $base;              # zaklad v komentarich
    my $base_what = $DB
        ? 'Perl, knihovny enginu, DB ovladac podle PWE_PROFILE a entrypoint'
        : 'Perl, knihovny enginu a entrypoint (bez DB ovladacu - web bez databaze)';
    my $profile_arg = $DB
        ? 'profil databaze: mariadb | mysql | postgres (urcuje zaklad pwe-<profil> a conf/database.conf)'
        : 'static = web bez databaze (zaklad pwe-base). Web s databazi ma jiny zaklad: vygeneruj Dockerfile s --db';
    return tpl(<<'DOCKER', NAME => $name, PROFILE => $profile, IMAGE => $image, BASE => $base, BASE_NAME => $base_name, BASE_WHAT => $base_what, PROFILE_ARG => $profile_arg);
# Image webu {{NAME}} = zavislostni image PWE + engine + tento web:
#   - zaklad {{BASE_NAME}}: {{BASE_WHAT}};
#     kod enginu ani zadny web v nem neni,
#   - engine z kontextu sestaveni (adresar PWE/ repozitare enginu bez PWE/t a PWE/docker) do /PWE/PWE,
#   - tento web z webapps/{{NAME}} do /PWE/webapps/{{NAME}}.
#
# Sestaveni VZDY z korene repozitare enginu (kontext "."): engine i web se berou z pracovni kopie, verze enginu
# v image = PWE/VERSION v okamziku sestaveni (v image /PWE/PWE/VERSION). Co se do image nedostane, urcuje tamni
# .dockerignore: docasna data webu (ramdisk, log, sessions, uploadfile, temp), conf/local.env, conf/database.conf
# a soukrome klice a mistni promenne prostredi (*.pem, *.key, *.p12, *.pfx, *.env) - ty v CELEM adresari
# webu, ne jen pod conf/. Kontejner je dostava mountem nebo jako Secret.
#
#   # nad nejnovejsim zavislostnim image (vychozi PWE_IMAGE_TAG=latest; z registru nebo z lokalniho Dockeru po make images)
#   docker build -t {{IMAGE}} -f webapps/{{NAME}}/Dockerfile .
#
#   # zavislosti pripnute na verzi enginu: tag image {{BASE_NAME}} = obsah PWE/VERSION
#   docker build --build-arg PWE_IMAGE_TAG="$(cat PWE/VERSION)" -t {{IMAGE}}:1.0 -f webapps/{{NAME}}/Dockerfile .
#
# Prosty "docker build" stavi vychozim builderem Dockeru (ovladac docker): image z lokalniho Dockeru
# pouzije a do registru jde jen pro ty, ktere tam nejsou. "docker buildx build" (a prosty "docker build"
# s nastavenou promennou BUILDX_BUILDER) stavi vybranym builderem; je-li typu docker-container, lokalni
# image nevidi a hleda je v registru - pak pridej --builder <builder s ovladacem docker> --load
# (Docker Desktop: desktop-linux, Linux: default).
#
# Argumenty buildu:
#   PWE_IMAGE_REGISTRY   registr a jmenny prostor zavislostnich image PWE
#   PWE_IMAGE_TAG        tag image {{BASE_NAME}}: verze enginu (napr. 2.2.1), nebo latest
#   PWE_PROFILE          {{PROFILE_ARG}}
ARG PWE_IMAGE_REGISTRY=ghcr.io/kukam
ARG PWE_IMAGE_TAG=latest
ARG PWE_PROFILE={{PROFILE}}

FROM ${PWE_IMAGE_REGISTRY}/{{BASE}}:${PWE_IMAGE_TAG}
ARG PWE_IMAGE_REGISTRY
ARG PWE_IMAGE_TAG
ARG PWE_PROFILE

# Engine z kontextu sestaveni do /PWE/PWE: vsechny polozky adresare PWE/ krome testu (PWE/t) a sestaveni
# zavislostnich image (PWE/docker). Vycet musi byt uplny - make check (PWE/tools/check-webapp.pl) upozorni,
# kdyz v nem nektera polozka enginu chybi (napr. po aktualizaci enginu: pak Dockerfile vygeneruj znovu).
# Poradi od nejmene po nejcasteji menene. COPY --link: vrstva nezavisi na vrstvach pod sebou - zmena zakladu
# ji nezneplatni a image webu nad stejnym enginem ji sdili.
COPY --link LICENSE /PWE/LICENSE
COPY --link PWE/assets /PWE/PWE/assets
COPY --link PWE/templates /PWE/PWE/templates
COPY --link PWE/tools /PWE/PWE/tools
COPY --link PWE/Entities /PWE/PWE/Entities
COPY --link PWE/Services /PWE/PWE/Services
COPY --link PWE/Sites /PWE/PWE/Sites
COPY --link PWE/Pages /PWE/PWE/Pages
COPY --link PWE/Libs /PWE/PWE/Libs
COPY --link PWE/pwe.fcgi PWE/debug.cgi PWE/favicon.ico PWE/README.md PWE/CHANGELOG.md PWE/VERSION /PWE/PWE/

# Web (bez toho, co vynechava .dockerignore - viz zahlavi).
COPY --link webapps/{{NAME}} /PWE/webapps/{{NAME}}

# PWE_CONF_pwe_core=/PWE/PWE nastavuje uz zakladni image. PWE_PROFILE = profil, pro ktery je image sestaveny.
# Za behu ho lze prepsat (-e PWE_PROFILE=...) jen na profil, jehoz ovladac zakladni image obsahuje:
# pwe-mariadb a pwe-mysql umi mariadb i mysql (engine pro oba pouziva DBD::mysql), pwe-postgres jen
# postgres, pwe-base zadnou databazi. Entrypoint pak conf/database.conf presmeruje na novy profil.
ENV PWE_CONF_pwe_home=/PWE/webapps/{{NAME}} \
    PWE_PROFILE=${PWE_PROFILE}

# Popisky image webu. Jinak by se zdedily popisky zakladniho image (nazev, popis, repozitar a licence
# zavislostniho image PWE), ktere o image webu neplati. version, source a licenses jsou proto prazdne - dopln
# verzi, adresu repozitare a licenci webu; base.name = image, ze ktereho je image webu sestaveny (verzi
# enginu v image rika soubor /PWE/PWE/VERSION).
LABEL org.opencontainers.image.title="{{NAME}}" \
      org.opencontainers.image.description="Web {{NAME}} nad PWE (Perl Web Engine): engine v /PWE/PWE, web v /PWE/webapps/{{NAME}}" \
      org.opencontainers.image.version="" \
      org.opencontainers.image.source="" \
      org.opencontainers.image.licenses="" \
      org.opencontainers.image.base.name="${PWE_IMAGE_REGISTRY}/{{BASE}}:${PWE_IMAGE_TAG}"

WORKDIR /PWE/webapps/{{NAME}}

# Pracovni adresare a conf/database.conf (symlink na konfiguraci profilu, pokud ji web ma) vznikaji uz pri
# buildu. Image tak jde spustit i s korenovym souborovym systemem jen pro cteni (docker run --read-only,
# Kubernetes readOnlyRootFilesystem) - engine ale do ramdisk, sessions, uploadfile a log zapisuje, takze
# tyto ctyri adresare pak musi byt zapisovatelne (tmpfs nebo volume pres adresare z image); bez
# zapisovatelneho ramdisk neobslouzi ani jeden request. Entrypoint dela totez pri startu - kvuli prepsani
# PWE_PROFILE a mountum pres adresar webu.
RUN set -eu; \
    mkdir -p ramdisk/templates sessions uploadfile log; \
    if [ -f "conf/${PWE_PROFILE}.conf" ] && { [ -L conf/database.conf ] || [ ! -e conf/database.conf ]; }; then \
        ln -sfn "${PWE_PROFILE}.conf" conf/database.conf; \
    fi

# ENTRYPOINT se dedi ze zakladniho image (/usr/local/bin/entrypoint.sh z pwe-base), web vlastni nema.
CMD ["perl", "/PWE/PWE/pwe.fcgi"]
DOCKER
}

sub gen_htaccess {
    return <<'HTACCESS';
# Apache: cache statiky a zakaz primeho pristupu ke zdrojum webu (vse jde pres pwe.fcgi).
<FilesMatch "\.(jpg|jpeg|png|gif|svg|woff2)$">
    Header set Cache-Control "max-age=604800, public"
</FilesMatch>

<FilesMatch "\.(js|css)$">
    Header set Cache-Control "max-age=172800, proxy-revalidate"
</FilesMatch>

<Files ~ "\.(pm|pl|log|tmpl|tmplc|bin|html|conf|dbversion|dump)$">
    Order Deny,Allow
    Deny from all
</Files>
HTACCESS
}

sub gen_vars {
    return <<'VARS';
# Ladeni z prikazove radky (v kontejneru s Perl zavislostmi, engine v /PWE/PWE):
#
#   . vars
#   QUERY_STRING='page=default&func=default' perl /PWE/PWE/pwe.fcgi
#
# Pohodlneji z hostitele (z korene repozitare): PWE/tools/pwe-cgi.sh <web> 'page=default&func=default'

export PERL5LIB="$(pwd):/PWE/PWE"
export PWE_CONF_pwe_home="$(pwd)/"
export PWE_CONF_pwe_core=/PWE/PWE/
export SCRIPT_FILENAME=/pwe.fcgi
export REQUEST_METHOD=GET
unset FCGI_SOCKET_PATH
VARS
}

sub gen_readme {
    my $dbtext = $DB
        ? "s databází (`conf/$DB.conf`, migrace `conf/$DB.dbversion`, session v DB přes `Services::Session`)"
        : "bez databáze (stav uživatele v souborech `sessions/`)";
    my $profile    = $DB ? $DB : 'static';
    my $drivertext = $DB ? ' a ovladač databáze' : '';
    my $baseimage  = profile_image($profile);    # pwe-base (bez databaze) | pwe-<profil>
    return tpl(<<'MD', NAME => $name, TITLE => $TITLE, DBTEXT => $dbtext, PROFILE => $profile, BASEIMAGE => $baseimage, DRIVERTEXT => $drivertext, LANGS => join(", ", @LANGS));
# {{TITLE}}

Web postavený nad enginem [PWE](../../docs/README.md), varianta {{DBTEXT}}.
Jazyky: {{LANGS}}. Vygenerováno skriptem `PWE/tools/new-webapp.pl`.

## Spuštění

```bash
make run WEB={{NAME}} PROFILE={{PROFILE}}         # docker compose, web na http://127.0.0.1:7778/
make cgi WEB={{NAME}} Q='page=default&func=default'   # jeden request bez serveru (CGI režim)
make check WEB={{NAME}}                           # kontrola konvencí, perl -c, smoke test
```

(Totéž přímo: `PWE/tools/run-webapp.sh`, `PWE/tools/pwe-cgi.sh`, `PWE/tools/check-webapp.pl`.)
Příkazy se spouštějí z kořene repozitáře (o dvě úrovně výš než tento web); cesty `PWE/...`
jsou relativní k němu a `PWE/` je adresář enginu.

## Struktura

Web neobsahuje žádný kód enginu ani symlinky na něj. Engine (adresář `PWE/` v kořeni
repozitáře, v kontejneru `/PWE/PWE`) ho najde přes `PWE_CONF_pwe_home`; co si web z enginu
bere, říká `conf/web.conf` (`pwe.core_pages`, `core_sites`, `core_services`, `core_entities`),
`pwe.require_core` hlídá verzi enginu (`PWE/VERSION`).

| Cesta | Co to je |
|-------|----------|
| `Pages/default/` | úvodní stránka (`default.pm`, `main.html`, `msg.html`, `rb*.tmpl`) |
| `Sites/Default/` | vzhled webu: `Default.pm`, `layout_header.html`, `layout_body.html` (menu), `layout_footer.html` |
| `Services/UserAccount/` | účet a skupiny uživatele (ve vývoji má každý skupinu `admin`, viz `pwe.development`) |
| `static/css/site.css` | vlastní styly a obrázky (Bootstrap, jQuery a `pwe.js` se servírují z enginu, `PWE/assets`) |
| `conf/web.conf` | konfigurace webu včetně toho, co se bere z enginu |
| `Dockerfile` | image webu = závislostní image + engine + web: `FROM ghcr.io/kukam/{{BASEIMAGE}}:<tag>` (jen knihovny enginu{{DRIVERTEXT}}, bez kódu enginu; tag = verze enginu nebo `latest`, argument `PWE_IMAGE_TAG`), engine se kopíruje z adresáře `PWE/` repozitáře do `/PWE/PWE` a web do `/PWE/webapps/{{NAME}}`; `CMD perl /PWE/PWE/pwe.fcgi`. Sestavuje se z kořene repozitáře: `docker build -f webapps/{{NAME}}/Dockerfile .` (podrobnosti v záhlaví souboru). Vstupní skript (entrypoint) se dědí ze základního image — podle `PWE_PROFILE` nasměruje `conf/database.conf` a založí dočasné adresáře; web vlastní `entrypoint.sh` nemá |

## Nová stránka

```bash
make module TYPE=page WEB={{NAME}} NAME=mojeStranka ARGS='--site Default --services UserAccount'
```

Postup a pravidla: [docs/21-novy-web-podle-zadani.md](../../docs/21-novy-web-podle-zadani.md),
kontrakt stránky: [docs/04-stranky.md](../../docs/04-stranky.md), kompletní příklad webu: [docs/12-tutorial-ukolnicek.md](../../docs/12-tutorial-ukolnicek.md).
MD
}
