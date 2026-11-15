# 12 — Tutoriál: Úkolníček

Kompletní web nad PWE od prázdného adresáře po běžící aplikaci. Všechny soubory jsou uvedeny
v plném znění a celý postup byl ověřen proti běžícímu stacku s MariaDB (43 automatických
kontrol: stránky, přihlášení, AJAX, validace, stránkování, jazyky, práva).

## Co postavíme

**Úkolníček** (`ukoly.web`) — seznam úkolů:

- úvodní stránka s počtem úkolů (služba + nízkoúrovňový SELECT),
- stránkovaný a řaditelný seznam úkolů (`Services::DBTable`), veřejný,
- přidání úkolu AJAX formulářem s deklarativní validací (povinný název, délka podle sloupce,
  vlastní validace v entitě),
- přepnutí stavu „hotovo“ AJAX odkazem a smazání klasickým odkazem s potvrzením,
- přihlášení správce (DB session, skupina `admin`), změny jen pro přihlášeného,
- menu s aktivní položkou, přihlášeným uživatelem a přepínáním CZE/EN,
- dva jazyky všech textů.

Použité části enginu: entita, služba, stránka s AJAXem, `DBTable`, `Session`, vlastní vzhled,
resource bundle, messenger, migrace schématu.

## 1. Kostra webu

```bash
make new WEB=ukoly.web ARGS='--db mariadb --title "Úkolníček" --lang CZE,EN'
```

Generátor vytvoří `webapps/ukoly.web/` s úvodní stránkou (`Pages/default`), vzhledem
(`Sites/Default`), službou účtu (`Services/UserAccount`), konfigurací (`conf/web.conf`,
`conf/{mariadb,mysql,postgres}.conf`, migrace s tabulkami `dbtable` a `session`), `static/css/site.css`,
`Dockerfile`, `.htaccess`, `robots.txt`, `vars`, `README.md` (vstupní skript `entrypoint.sh` web nemá —
image webu ho dědí z běhového image). Co si web bere
z enginu, je v `conf/web.conf`:

```perl
require_core  => ">=2.2",
core_pages    => ["css", "errorPage", "systemPage", "pweCreator"],
core_sites    => [],
core_services => ["DBTable", "Session"],
core_entities => ["DBTable", "Session"],
```

Soubory, které v dalších krocích **nebudeme měnit** (generátor je vytvořil hotové):
`Sites/Default/layout_header.html`, `layout_footer.html`, `Pages/default/msg.html`, všechny
`conf/*.conf`, `Dockerfile`, `.htaccess`, `robots.txt`, `vars`.

## 2. Databáze: tabulka úkolů

Do `conf/mariadb.dbversion` (a stejně do `mysql.dbversion`) přidej třetí migraci:

```perl
    3 => "
        CREATE TABLE `tasks` (
          `id` int(8) unsigned NOT NULL AUTO_INCREMENT,
          `title` varchar(128) NOT NULL,
          `note` text DEFAULT NULL,
          `done` enum ('t', 'f') NOT NULL DEFAULT 'f',
          `updated` timestamp NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
          `created` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
          PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_czech_ci;
    ",
```

a do `conf/postgres.dbversion`:

```perl
    3 => "
        CREATE TABLE tasks (
            id          SERIAL                      NOT NULL PRIMARY KEY,
            title       VARCHAR(128)                NOT NULL,
            note        TEXT                        NULL,
            done        VARCHAR(1)                  NOT NULL DEFAULT 'f',
            updated     TIMESTAMP WITH TIME ZONE    NULL,
            created     TIMESTAMP WITH TIME ZONE    NOT NULL DEFAULT NOW()
        );
    ",
```

Sloupce `created`/`updated` v tomto tvaru plní entita automaticky. Migrace se spustí při startu
enginu ([03 — Migrace](03-struktura-webu.md#migrace-schématu-confdriverdbversion)).

## 3. Entita `Task`

```bash
make module TYPE=entity WEB=ukoly.web NAME=Task ARGS='--table tasks'
```

`Entities/Task/Task.pm` — doplněný o vlastní validaci sloupce `title`:

```perl
package Entities::Task::Task;

=head1 NAME

Entities::Task::Task - entita tabulky tasks (ukoly webu ukoly.web)

=cut

use strict;
use base qw(Entities::Entity);

my ($CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB);

=head2 B<[Public] new($conf,$log,$validate,$dbi,$user,$web,$opts)>

    Entita tabulky 'tasks' v databazi db1 (sloupce id, title, note, done, updated, created;
    CREATE TABLE je v conf/<driver>.dbversion). $opts je id radku, {where => "...", conds => [...]}
    nebo nic (prazdny radek pro INSERT). Vytvari se pres $ENTITIES->createEntityObject('Task', ...).

=cut

sub new {
    my ($class, $conf, $log, $validate, $dbi, $user, $web, $opts) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $CONF     = $conf;
    $USER     = $user;
    $WEB      = $web;
    $VALIDATE = $validate;

    my $self = new Entities::Entity($CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB, "db1", "tasks", $opts);

    bless $self, $class;
    return $self;
}

=head2 B<[Public] title([$value])>

    Getter/setter sloupce title. Pri zapisu orizne bile znaky na krajich; prazdny nazev odmitne
    (zapise chybu do errorlistu a vrati undef). Maximalni delku (VARCHAR 128) kontroluje DAO
    podle typu sloupce. Tuto metodu pouziva i deklarativni validace stranek (atribut 'validate').

=cut

sub title {
    my $self = shift;
    if (@_) {
        my ($value) = @_;
        $value =~ s/^\s+|\s+$//g if (defined($value));
        unless (defined($value) and length($value)) {
            $self->SUPER::setErrorList("Invalid write data : column_name:title, value:empty");
            return undef;
        }
        return $self->SUPER::title($value);
    }
    return $self->SUPER::title();
}

# KOMODO-IDE/KOMODO-EDIT
sub KOMODO {
    return;
    require Libs::Config;
    require Libs::Log;
    require Libs::Validate;
    require Libs::DBI;
    require Libs::User;
    $CONF     = new Libs::Config;
    $LOG      = new Libs::Log;
    $VALIDATE = new Libs::Validate;
    $DBI      = new Libs::DBI;
    $USER     = new Libs::User;
}

1;
```

## 4. Služba `Tasks`

```bash
make module TYPE=service WEB=ukoly.web NAME=Tasks
```

`Services/Tasks/Tasks.pm`:

```perl
package Services::Tasks::Tasks;

=head1 NAME

Services::Tasks::Tasks - business logika ukolu: zalozeni, zmena stavu, smazani, statistika

=cut

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

=head2 B<[Public] new($conf,$log,$validate,$dbi,$entities,$user,$web)>

    Sluzba nad entitou Task (tabulka tasks). Do stranek se injektuje metodou Service_Tasks.
    Kazda metoda pracuje s vlastni instanci entity a sama resi commit/rollback.

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

    my $self = {};

    bless $self, $class;
    return $self;
}

=head2 B<[Public] addTask(title => $title, note => $note)>

    Zalozi novy ukol (done = 'f'). Vraci id noveho radku, pri neplatne hodnote nebo chybe DB
    vraci undef (zmeny se odrollbackuji, duvod je v logu pres logit).

=cut

sub addTask {
    my ($self, %task) = @_;

    my $T = $ENTITIES->createEntityObject('Task');
    $T->title($task{'title'});
    $T->note($task{'note'}) if (defined($task{'note'}) and length($task{'note'}));
    $T->done('f');

    my $id = $T->flush;
    $T->logit;
    if ($T->error) {
        $T->rollback;
        return undef;
    }
    $T->commit;
    return $id;
}

=head2 B<[Public] setDone($id,$done)>

    Nastavi stav ukolu $id na $done ('t' = hotovo, 'f' = ceka). Vraci 1; pokud ukol neexistuje
    nebo zapis selze, vraci undef.

=cut

sub setDone {
    my ($self, $id, $done) = @_;

    my $T = $ENTITIES->createEntityObject('Task', $id);
    return undef unless ($T->id);

    $T->done($done);
    $T->flush;
    $T->logit;
    if ($T->error) {
        $T->rollback;
        return undef;
    }
    $T->commit;
    return 1;
}

=head2 B<[Public] deleteTask($id)>

    Smaze ukol $id. Vraci 1; pokud ukol neexistuje nebo smazani selze, vraci undef.

=cut

sub deleteTask {
    my ($self, $id) = @_;

    my $T = $ENTITIES->createEntityObject('Task', $id);
    return undef unless ($T->id);

    $T->DELETE_ROW;
    $T->logit;
    if ($T->error) {
        $T->rollback;
        return undef;
    }
    $T->commit;
    return 1;
}

=head2 B<[Public] getTask($id)>

    Vraci hash se sloupci ukolu ({ id, title, note, done, created, updated }), nebo undef,
    pokud ukol neexistuje.

=cut

sub getTask {
    my ($self, $id) = @_;

    my $T = $ENTITIES->createEntityObject('Task', $id);
    return ($T->id ? $T->getMirroredData() : undef);
}

=head2 B<[Public] getStats()>

    Vraci { total => pocet ukolu, done => pocet hotovych } jednim SELECTem (nizkourovnove
    API Libs::MyDBI - vhodne pro agregace, kde entita nedava smysl).

=cut

sub getStats {
    my $self = shift;

    my $SQL = $DBI->select("db1", "COUNT(*) AS total, SUM(CASE WHEN done = 't' THEN 1 ELSE 0 END) AS done FROM tasks", []);
    my $row = $SQL->fetchrow_hashref();
    $SQL->finish();

    return {total => ($row->{'total'} || 0), done => ($row->{'done'} || 0)};
}

=head2 B<[Public] is_task_id($id)>

    Validator pro atribut 'rules' stranek (['Services::Tasks::is_task_id', 'error_task_id', 'parameter']):
    vraci $id, pokud je to cislo existujiciho ukolu, jinak undef.

=cut

sub is_task_id {
    my ($self, $id) = @_;

    return undef unless (defined($id) and $id =~ /^\d+$/);
    my $T = $ENTITIES->createEntityObject('Task', $id);
    return ($T->id ? $id : undef);
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
```

## 5. Přihlášení správce

### Konfigurace

Do `conf/web.conf`, sekce `web`, přidej přihlašovací údaje:

```perl
    web => {
        email_admin    => 'admin@localhost',
        email_subtitle => 'Úkolníček',
        admin_login    => 'admin',            # prihlaseni spravce (Services/UserAccount::login)
        admin_password => 'tajneheslo',       # v produkci prepsat promennou PWE_CONF_web_admin_password
    },
```

### Služba `UserAccount`

Generátor vytvořil `Services/UserAccount/UserAccount.pm` s vývojovou zkratkou (každý je admin).
Nahraď ji skutečným přihlášením nad DB session (sloupec `admin` v tabulce `session`):

```perl
package Services::UserAccount::UserAccount;

=head1 NAME

Services::UserAccount::UserAccount - prihlaseni spravce a skupiny uzivatele nad Services::Session

=cut

use strict;
our ($AUTOLOAD);

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB, $SESSION);

=head2 B<[Public] new($conf,$log,$validate,$dbi,$entities,$user,$web)>

    Sluzba uzivatelskeho uctu nad Services::Session (tabulka session v DB). Prihlaseny spravce
    ma ve sve session admin = 't'; newRequest mu podle toho prideli skupinu 'admin', kterou
    stranky pouzivaji v $self->{'func'}->{akce} = ['admin']. Prihlasovaci udaje jsou v conf
    web.admin_login / web.admin_password (v produkci prepsat promennou PWE_CONF_web_admin_password).

    Do stranek se injektuje metodou Service_UserAccount a nahrazuje $USER: nezname metody
    (getParam, getSid, ...) deleguje na Session -> Libs::User.

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

    Zacatek requestu (vola Libs::Services): nacte/zalozi session (Services::Session::newSession)
    a pokud je v ni admin = 't', nastavi ucet a skupinu 'admin'. Jinak zustava skupina 'guest'.

=cut

sub newRequest {
    my $self = shift;

    $self->{'session'} = $SESSION->newSession();
    $self->{'account'} = {};
    $self->{'group'}   = {};

    # MariaDB/MySQL vraci 't'/'f', PostgreSQL (BOOLEAN) 1/0 - proto regularni vyraz, ne eq 't'
    my $adm = $SESSION->getValue('admin', 'f');
    $self->setAdminGroup() if (defined($adm) and $adm =~ /^(t|true|1)$/i);
}

=head2 B<[Public] login($login,$password)>

    Overi prihlasovaci udaje proti conf web.admin_login / web.admin_password. Pri shode obnovi
    session (Services::Session::regenerate - nove sid), ulozi do session admin = 't' (plati
    i pro dalsi requesty) a nastavi skupinu 'admin'. Vraci 1, jinak undef.

=cut

sub login {
    my ($self, $login, $password) = @_;

    my $conf_login    = $CONF->getValue("web", "admin_login", "admin");
    my $conf_password = $CONF->getValue("web", "admin_password", undef);

    return undef unless (defined($conf_password) and defined($login) and defined($password));
    return undef unless ($login eq $conf_login and $password eq $conf_password);

    $SESSION->regenerate();    # nove sid proti session fixation (engine >= 2.2.0), data session zustavaji
    $SESSION->setValue('admin', 't');
    $self->setAdminGroup();
    $LOG->info("Admin '$login' logged in from " . $USER->getIP());
    return 1;
}

=head2 B<[Public] logout()>

    Odhlasi spravce: v session nastavi admin = 'f', odebere skupinu 'admin' a vrati 'guest'.

=cut

sub logout {
    my $self = shift;

    $SESSION->setValue('admin', 'f');
    $self->{'account'} = {};
    $self->{'group'}   = {};
    $USER->deleteGroup('admin');
    $USER->addGroup('guest');
    return 1;
}

=head2 B<[Public] isLoggedIn()>

    Vraci 1, pokud je v aktualnim requestu prihlaseny spravce, jinak 0.

=cut

sub isLoggedIn {
    my $self = shift;
    return ($self->{'group'}->{'admin'} ? 1 : 0);
}

=head2 B<[Private] setAdminGroup()>

    Nastavi ucet ({ login => ... }) a skupinu 'admin' v teto sluzbe i v Libs::User
    (addGroup - podle ni Libs::Pages::accessFunc povoluje akce stranek).

=cut

sub setAdminGroup {
    my $self = shift;

    $self->{'account'} = {'login' => $CONF->getValue("web", "admin_login", "admin")};
    $self->{'group'}->{'admin'} = 1;
    $USER->deleteGroup('guest');
    $USER->addGroup('admin');
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

    Vraci hash dat session (sid, ipaddres, useragent, lang, admin, expire, ...).

=cut

sub getSession {
    my $self = shift;
    return $self->{'session'};
}

=head2 B<[Public] getAccount()>

    Vraci hash dat prihlaseneho uctu ({ login => ... }), nebo prazdny hash.

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
```

### Stránka `prihlaseni`

```bash
make module TYPE=page WEB=ukoly.web NAME=prihlaseni ARGS='--site Default --services UserAccount'
```

`Pages/prihlaseni/prihlaseni.pm`:

```perl
package Pages::prihlaseni::prihlaseni;

=head1 NAME

Pages::prihlaseni::prihlaseni - prihlaseni a odhlaseni spravce (Services::UserAccount)

=cut

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

=head2 B<[Public] new($self,$conf,$log,$validate,$dbi,$entities,$user,$web)>

    Registrovane akce (?page=prihlaseni&func=...):
      default - prihlasovaci formular (nebo info o prihlasenem uzivateli)
      login   - POST: overi login a password pres Services::UserAccount::login, po uspechu
                presmeruje na seznam ukolu (HTTP redirect + flash zprava)
      logout  - odhlasi a vykresli formular

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

    $self->{'func'}->{'default'} = [];
    $self->{'func'}->{'login'}   = [];
    $self->{'func'}->{'logout'}  = [];

    $self->{'defined'}->{'login'} = {parameters => ['login', 'password']};
    $self->{'error'}->{'login'}   = "error";

    bless $self, $class;
    return $self;
}

=head2 B<[Private] Site_Default($site)>

    Injektaz vzhledu Sites::Default (vola loader).

=cut

sub Site_Default {
    my ($self, $input) = @_;
    $WEB = $input;
}

=head2 B<[Private] Service_UserAccount($service)>

    Injektaz sluzby UserAccount (login/logout; jinak stejne API jako Libs::User).

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
    require Sites::Default::Default;
    require Services::UserAccount::UserAccount;
    $CONF     = new Libs::Config;
    $LOG      = new Libs::Log;
    $VALIDATE = new Libs::Validate;
    $DBI      = new Libs::DBI;
    $ENTITIES = new Libs::Entities;
    $USER     = new Services::UserAccount::UserAccount;
    $WEB      = new Sites::Default::Default;
}

=head2 B<[Public] default()>

    Vykresli prihlasovaci formular (Pages/prihlaseni/main.html).

=cut

sub default {
    my $self = shift;

    $WEB->setIDP("prihlaseni");
    $WEB->printHttpHeader();
    $WEB->printHtmlHeader();
    $WEB->printHtmlLayout(html_main => "Pages/prihlaseni/main.html");
}

=head2 B<[Public] login()>

    Overi prihlasovaci udaje. Po uspechu ulozi flash zpravu a presmeruje na ?page=ukoly
    (zprava se zobrazi az tam - messenger prezije redirect), jinak vykresli formular s chybou.

=cut

sub login {
    my $self = shift;

    if ($USER->login($USER->getParam("login", 0, ""), $USER->getParam("password", 0, ""))) {
        $WEB->setMessenger("Pages/prihlaseni/msg.html", msg_allright => ['ok_login']);
        $WEB->printHttpHeader('type' => 'redirect', 'redirect_link' => $WEB->getScriptName() . '?page=ukoly&func=default');
    } else {
        $WEB->setMessenger("Pages/prihlaseni/msg.html", msg_error => ['error_login']);
        $self->default();
    }
}

=head2 B<[Public] logout()>

    Odhlasi uzivatele a vykresli formular s potvrzenim.

=cut

sub logout {
    my $self = shift;

    $USER->logout();
    $WEB->setMessenger("Pages/prihlaseni/msg.html", msg_allright => ['ok_logout']);
    $self->default();
}

=head2 B<[Public] error($error)>

    Chyby validace (chybejici login/password): zobrazi je v messengeru a vykresli formular.

=cut

sub error {
    my ($self, $error) = @_;

    $WEB->setMessenger("Pages/prihlaseni/msg.html", msg_error => $error);
    return 400 if ($USER->getParam("ajax_request", 0, undef));
    $self->default();
}

1;
```

`Pages/prihlaseni/main.html` (klasický formulář bez AJAXu):

```html
[% PROCESS templates/resource_bundle.tmpl %]
<h1 class="border-bottom pb-2 mb-4">[% rb.login_title %]</h1>

[% IF group.admin %]
<p>[% rb.logged_as %] <strong>[% account.login %]</strong>.</p>
<a class="btn btn-outline-secondary" href="[% script_name %]?page=prihlaseni&func=logout">[% rb.logout %]</a>
[% ELSE %]
[% # Klasicky (ne-AJAX) formular: po odeslani prijde cela stranka nebo redirect %]
<form class="col-md-4" action="[% script_name %]?page=prihlaseni&func=login" method="POST">
  <input type="hidden" name="page" value="prihlaseni" />
  <input type="hidden" name="func" value="login" />
  <div class="mb-3">
    <label for="login" class="form-label">[% rb.login %]</label>
    <input type="text" class="form-control" id="login" name="login" autocomplete="username" />
  </div>
  <div class="mb-3">
    <label for="password" class="form-label">[% rb.password %]</label>
    <input type="password" class="form-control" id="password" name="password" autocomplete="current-password" />
  </div>
  <button type="submit" class="btn btn-primary">[% rb.submit %]</button>
</form>
[% END %]
```

`Pages/prihlaseni/rb.tmpl`:

```
[% # RESOURCE BUNDLE (CZE) %]

[% SET rb.login_title = "Přihlášení správce" %]
[% SET rb.logged_as = "Jste přihlášen jako" %]
[% SET rb.logout = "Odhlásit" %]
[% SET rb.login = "Přihlašovací jméno" %]
[% SET rb.password = "Heslo" %]
[% SET rb.submit = "Přihlásit" %]

[% SET rb.msg.error_exist__login = "Vyplňte přihlašovací jméno." %]
[% SET rb.msg.error_exist__password = "Vyplňte heslo." %]
[% SET rb.msg.error_login = "Nesprávné jméno nebo heslo." %]
[% SET rb.msg.ok_login = "Přihlášení proběhlo, můžete upravovat úkoly." %]
[% SET rb.msg.ok_logout = "Byli jste odhlášeni." %]

[% # POZOR: soubor rb*.tmpl musi koncit prazdnym radkem (bug parseru) %]

```

`Pages/prihlaseni/rb_EN.tmpl`:

```
[% # RESOURCE BUNDLE (EN) %]

[% SET rb.login_title = "Administrator login" %]
[% SET rb.logged_as = "You are logged in as" %]
[% SET rb.logout = "Log out" %]
[% SET rb.login = "Username" %]
[% SET rb.password = "Password" %]
[% SET rb.submit = "Log in" %]

[% SET rb.msg.error_exist__login = "Enter your username." %]
[% SET rb.msg.error_exist__password = "Enter your password." %]
[% SET rb.msg.error_login = "Wrong username or password." %]
[% SET rb.msg.ok_login = "You are logged in and can edit tasks." %]
[% SET rb.msg.ok_logout = "You have been logged out." %]

[% # POZOR: soubor rb*.tmpl musi koncit prazdnym radkem (bug parseru) %]

```

Generovaný `Pages/prihlaseni/msg.html` zůstává:

```
[% PROCESS templates/resource_bundle.tmpl %]

[% INCLUDE templates/messenger.html %]
```

## 6. Stránka `ukoly`

```bash
make module TYPE=page WEB=ukoly.web NAME=ukoly ARGS='--site Default --services UserAccount,DBTable,Tasks'
```

`Pages/ukoly/ukoly.pm`:

```perl
package Pages::ukoly::ukoly;

=head1 NAME

Pages::ukoly::ukoly - seznam ukolu (Services::DBTable), pridani, zmena stavu a smazani (AJAX)

=cut

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB, $DBTABLE, $TASKS);

=head2 B<[Public] new($self,$conf,$log,$validate,$dbi,$entities,$user,$web)>

    Registrovane akce (?page=ukoly&func=...):
      default - strankovany seznam ukolu (verejny); pri ajax_request prekresli jen tabulku
      add     - POST z formulare: novy ukol (jen skupina admin)
      toggle  - prepne stav ukolu id na done=t|f (jen admin, volano AJAXem z tabulky)
      remove  - smaze ukol id (jen admin, klasicky odkaz s potvrzenim)
    Vstupy se validuji deklarativne (defined, validate entitou, rules); pri chybe se vola error.

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

    # Akce a prava: seznam je verejny, zmeny jen pro skupinu 'admin' (Services/UserAccount::login)
    $self->{'func'}->{'default'} = [];
    $self->{'func'}->{'add'}     = ['admin'];
    $self->{'func'}->{'toggle'}  = ['admin'];
    $self->{'func'}->{'remove'}  = ['admin'];

    # Povinne parametry -> chyba error_exist__<parametr>
    $self->{'defined'}->{'add'}    = {parameters => ['title']};
    $self->{'defined'}->{'toggle'} = {parameters => ['id', 'done']};
    $self->{'defined'}->{'remove'} = {parameters => ['id']};

    # Hodnoty zkontroluje entita Task metodami sloupcu -> chyba error_validate__<parametr>
    $self->{'validate'}->{'add'} = [{entity => 'Entities::Task', parameters => ['title', 'note']}];

    # Pravidla: id musi byt existujici ukol (validator sluzby), done jen t/f
    $self->{'rules'}->{'toggle'}->{'id'}   = [['Services::Tasks::is_task_id', 'error_task_id', 'parameter']];
    $self->{'rules'}->{'toggle'}->{'done'} = [['is_regx', 'error_done', 'parameter', qr/^[tf]$/]];
    $self->{'rules'}->{'remove'}->{'id'}   = [['Services::Tasks::is_task_id', 'error_task_id', 'parameter']];

    # Pri chybe validace se misto akce zavola metoda error
    $self->{'error'}->{'add'}    = "error";
    $self->{'error'}->{'toggle'} = "error";
    $self->{'error'}->{'remove'} = "error";

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

    Injektaz sluzby UserAccount - nahradi $USER objektem se stejnym API jako Libs::User
    (getParam, getSid, ...), rozsirenym o ucet a skupiny uzivatele.

=cut

sub Service_UserAccount {
    my ($self, $input) = @_;
    $USER = $input;
}

=head2 B<[Private] Service_DBTable($service)>

    Injektaz sluzby DBTable (strankovana tabulka z SQL dotazu).

=cut

sub Service_DBTable {
    my ($self, $input) = @_;
    $DBTABLE = $input;
}

=head2 B<[Private] Service_Tasks($service)>

    Injektaz sluzby Tasks (business logika ukolu).

=cut

sub Service_Tasks {
    my ($self, $input) = @_;
    $TASKS = $input;
}

# KOMODO-IDE/KOMODO-EDIT
sub KOMODO {
    return;
    require Libs::Config;
    require Libs::Log;
    require Libs::Validate;
    require Libs::DBI;
    require Libs::Entities;
    require Sites::Default::Default;
    require Services::UserAccount::UserAccount;
    require Services::DBTable::DBTable;
    require Services::Tasks::Tasks;
    $CONF     = new Libs::Config;
    $LOG      = new Libs::Log;
    $VALIDATE = new Libs::Validate;
    $DBI      = new Libs::DBI;
    $ENTITIES = new Libs::Entities;
    $USER     = new Services::UserAccount::UserAccount;
    $WEB      = new Sites::Default::Default;
    $DBTABLE  = new Services::DBTable::DBTable;
    $TASKS    = new Services::Tasks::Tasks;
}

=head2 B<[Public] default()>

    Vykresli seznam ukolu. Nastaveni tabulky (razeni, strana) drzi Services::DBTable v DB podle
    session. Pri AJAX requestu (ajax_request=1 - razeni, strankovani, odpoved na add/toggle)
    posle JSON, ktery prekresli jen element tabulky (id = nazev tabulky) a messenger.

=cut

sub default {
    my $self = shift;

    my $table = $DBTABLE->genTable(
        name        => 'tasks-list',                 # klic nastaveni v tabulce dbtable = id elementu v HTML
        tmpl        => "Pages/ukoly/table.html",     # sablona tabulky (pro AJAX prekresleni)
        query       => "* FROM tasks",
        conditions  => [],
        ordercolumn => "created",
        orderby     => "DESC",
        maxrow      => 10,
    );

    $WEB->setIDP("ukoly");

    if ($USER->getParam("ajax_request", 0, undef)) {
        $WEB->printHttpHeader('type' => 'ajax');
        $WEB->printAjaxLayout(
            ajax_id   => [$table->{'name'}],
            ajax_tmpl => [$table->{'tmpl'}],
            ajax_data => {table => $table},
        );
    } else {
        $WEB->printHttpHeader();
        $WEB->printHtmlHeader();
        $WEB->printHtmlLayout(html_main => "Pages/ukoly/main.html", table => $table);
    }
}

=head2 B<[Public] add()>

    Zalozi ukol z parametru title a note (vstup uz prosel validaci), nastavi flash zpravu
    a vykresli seznam (pri AJAX formulari jen tabulku + messenger).

=cut

sub add {
    my $self = shift;

    my $id = $TASKS->addTask(
        title => $USER->getParam("title", 0, ""),
        note  => $USER->getParam("note",  0, undef),
    );

    if ($id) {
        $WEB->setMessenger("Pages/ukoly/msg.html", msg_allright => ['ok_added']);
    } else {
        $WEB->setMessenger("Pages/ukoly/msg.html", msg_error => ['error_db']);
    }
    $self->default();
}

=head2 B<[Public] toggle()>

    Nastavi stav ukolu id podle parametru done (t/f) a prekresli seznam.

=cut

sub toggle {
    my $self = shift;

    my $done = $USER->getParam("done", 0, "f");

    if ($TASKS->setDone($USER->getParam("id", 0, 0), $done)) {
        $WEB->setMessenger("Pages/ukoly/msg.html", msg_allright => [($done eq 't' ? 'ok_done' : 'ok_undone')], disable_scrolltomessenger => 1);
    } else {
        $WEB->setMessenger("Pages/ukoly/msg.html", msg_error => ['error_db']);
    }
    $self->default();
}

=head2 B<[Public] remove()>

    Smaze ukol id a vykresli seznam.

=cut

sub remove {
    my $self = shift;

    if ($TASKS->deleteTask($USER->getParam("id", 0, 0))) {
        $WEB->setMessenger("Pages/ukoly/msg.html", msg_allright => ['ok_removed']);
    } else {
        $WEB->setMessenger("Pages/ukoly/msg.html", msg_error => ['error_db']);
    }
    $self->default();
}

=head2 B<[Public] error($error)>

    Chyby validace (pole klicu error_*): zobrazi je v messengeru; pri AJAX requestu vrati 400
    (pwe.js vyjme messenger z chybove stranky), jinak znovu vykresli seznam.

=cut

sub error {
    my ($self, $error) = @_;

    $WEB->setMessenger("Pages/ukoly/msg.html", msg_error => $error);
    return 400 if ($USER->getParam("ajax_request", 0, undef));
    $self->default();
}

1;
```

`Pages/ukoly/main.html`:

```html
[% PROCESS templates/resource_bundle.tmpl %]
<h1 class="border-bottom pb-2 mb-4">[% rb.ukoly_title %]</h1>

[% IF group.admin %]
<div class="card mb-4">
  <div class="card-body">
    [% INCLUDE Pages/ukoly/form.html formid = "task-form" %]
  </div>
</div>
[% ELSE %]
<p class="text-body-secondary">[% rb.login_hint %] <a href="[% script_name %]?page=prihlaseni&func=default">[% rb.login_link %]</a></p>
[% END %]

<div id="[% table.name %]" class="table-responsive">
  [% INCLUDE Pages/ukoly/table.html %]
</div>
```

`Pages/ukoly/form.html` (AJAX formulář):

```html
[% # Formular noveho ukolu; odesila se AJAXem (pwe.js AjaxFormAppender), odpoved prekresli tabulku %]
<script>$(function() { AjaxFormAppender($("#[% formid %]")); });</script>
<form id="[% formid %]" action="[% script_name %]?page=ukoly&func=add" method="POST">
  [% # POST: page a func musi byt v tele formulare (CGI.pm na POST ignoruje query string) %]
  <input type="hidden" name="page" value="ukoly" />
  <input type="hidden" name="func" value="add" />
  <div class="row g-3">
    <div class="col-md-5">
      <label for="[% formid %]_title" class="form-label">[% rb.form_title %]</label>
      <input type="text" class="form-control" id="[% formid %]_title" name="title" maxlength="128" placeholder="[% rb.form_title_placeholder %]" />
    </div>
    <div class="col-md-5">
      <label for="[% formid %]_note" class="form-label">[% rb.form_note %]</label>
      <input type="text" class="form-control" id="[% formid %]_note" name="note" />
    </div>
    <div class="col-md-2 d-flex align-items-end">
      <input type="submit" class="btn btn-primary w-100" name="save" value="[% rb.form_submit %]" />
    </div>
  </div>
</form>
```

`Pages/ukoly/table.html` (renderuje se v stránce i samostatně přes AJAX, proto začíná načtením textů):

```html
[% PROCESS templates/resource_bundle.tmpl %]
[% # Tabulka ukolu: table = vysledek Services::DBTable::genTable; renderuje se i samostatne pres AJAX %]
[% SET enable_ajax = 1 %]
<table class="table table-hover align-middle">
  <thead>
    <tr>
      <th>[% INCLUDE Services/DBTable/orderby.html thname = rb.th_title   ordercolumn = "title"   ajaxjson = "$enable_ajax" %]</th>
      <th>[% INCLUDE Services/DBTable/orderby.html thname = rb.th_created ordercolumn = "created" ajaxjson = "$enable_ajax" %]</th>
      <th>[% INCLUDE Services/DBTable/orderby.html thname = rb.th_done    ordercolumn = "done"    ajaxjson = "$enable_ajax" %]</th>
      [% IF group.admin %]<th></th>[% END %]
    </tr>
  </thead>
  <tbody>
  [% FOREACH t IN table.rows %]
    <tr[% IF t.done == 't' %] class="task-done"[% END %]>
      <td>
        [% t.title | html %]
        [% IF t.note %]<div class="small text-body-secondary">[% t.note | html %]</div>[% END %]
      </td>
      <td class="text-nowrap">[% t.created %]</td>
      <td>
        [% IF t.done == 't' %]<span class="badge text-bg-success">[% rb.done_yes %]</span>
        [% ELSE %]<span class="badge text-bg-secondary">[% rb.done_no %]</span>[% END %]
      </td>
      [% IF group.admin %]
      <td class="text-end text-nowrap">
        [% SET newdone = (t.done == 't' ? 'f' : 't') %]
        <a class="btn btn-sm btn-outline-success" title="[% rb.btn_toggle %]" [% INCLUDE templates/href.tmpl href = "$script_name?page=ukoly&func=toggle&id=$t.id&done=$newdone" ajaxjson = "$enable_ajax" %]><i class="fa-solid fa-check"></i></a>
        <a class="btn btn-sm btn-outline-danger" title="[% rb.btn_remove %]" href="[% script_name %]?page=ukoly&func=remove&id=[% t.id %]" onclick="return confirm('[% rb.confirm_remove %]');"><i class="fa-solid fa-trash"></i></a>
      </td>
      [% END %]
    </tr>
  [% END %]
  [% UNLESS table.rows.size %]
    <tr><td colspan="4" class="text-center text-body-secondary py-4">[% rb.empty %]</td></tr>
  [% END %]
  </tbody>
</table>
[% IF table.endpage > 1 %]
  [% INCLUDE Services/DBTable/pagination.html table = table ajaxjson = "$enable_ajax" %]
[% END %]
```

`Pages/ukoly/rb.tmpl`:

```
[% # RESOURCE BUNDLE (CZE) %]

[% SET rb.ukoly_title = "Seznam úkolů" %]
[% SET rb.th_title = "Úkol" %]
[% SET rb.th_created = "Vytvořeno" %]
[% SET rb.th_done = "Stav" %]
[% SET rb.done_yes = "hotovo" %]
[% SET rb.done_no = "čeká" %]
[% SET rb.empty = "Zatím žádné úkoly." %]
[% SET rb.btn_toggle = "Přepnout stav" %]
[% SET rb.btn_remove = "Smazat" %]
[% SET rb.confirm_remove = "Opravdu smazat úkol?" %]
[% SET rb.form_title = "Nový úkol" %]
[% SET rb.form_title_placeholder = "Co je třeba udělat" %]
[% SET rb.form_note = "Poznámka" %]
[% SET rb.form_submit = "Přidat" %]
[% SET rb.login_hint = "Úkoly může měnit jen přihlášený správce." %]
[% SET rb.login_link = "Přihlásit se" %]

[% # klice chyb z validace (error_exist__ = chybi, error_validate__ = entita odmitla) a z akci %]
[% SET rb.msg.error_exist__title = "Vyplňte název úkolu." %]
[% SET rb.msg.error_validate__title = "Název úkolu je prázdný nebo delší než 128 znaků." %]
[% SET rb.msg.error_validate__note = "Poznámka má neplatnou hodnotu." %]
[% SET rb.msg.error_exist__id = "Chybí číslo úkolu." %]
[% SET rb.msg.error_exist__done = "Chybí nový stav úkolu." %]
[% SET rb.msg.error_task_id = "Úkol neexistuje." %]
[% SET rb.msg.error_done = "Neplatný stav úkolu." %]
[% SET rb.msg.error_db = "Uložení se nepodařilo, zkuste to znovu." %]
[% SET rb.msg.ok_added = "Úkol byl přidán." %]
[% SET rb.msg.ok_done = "Úkol je hotový." %]
[% SET rb.msg.ok_undone = "Úkol znovu čeká na splnění." %]
[% SET rb.msg.ok_removed = "Úkol byl smazán." %]

[% # POZOR: soubor rb*.tmpl musi koncit prazdnym radkem (bug parseru) %]

```

`Pages/ukoly/rb_EN.tmpl`:

```
[% # RESOURCE BUNDLE (EN) %]

[% SET rb.ukoly_title = "Task list" %]
[% SET rb.th_title = "Task" %]
[% SET rb.th_created = "Created" %]
[% SET rb.th_done = "Status" %]
[% SET rb.done_yes = "done" %]
[% SET rb.done_no = "open" %]
[% SET rb.empty = "No tasks yet." %]
[% SET rb.btn_toggle = "Toggle status" %]
[% SET rb.btn_remove = "Delete" %]
[% SET rb.confirm_remove = "Really delete this task?" %]
[% SET rb.form_title = "New task" %]
[% SET rb.form_title_placeholder = "What needs to be done" %]
[% SET rb.form_note = "Note" %]
[% SET rb.form_submit = "Add" %]
[% SET rb.login_hint = "Only a logged-in administrator can change tasks." %]
[% SET rb.login_link = "Log in" %]

[% SET rb.msg.error_exist__title = "Enter the task title." %]
[% SET rb.msg.error_validate__title = "The title is empty or longer than 128 characters." %]
[% SET rb.msg.error_validate__note = "The note has an invalid value." %]
[% SET rb.msg.error_exist__id = "Task id is missing." %]
[% SET rb.msg.error_exist__done = "New status is missing." %]
[% SET rb.msg.error_task_id = "The task does not exist." %]
[% SET rb.msg.error_done = "Invalid task status." %]
[% SET rb.msg.error_db = "Saving failed, please try again." %]
[% SET rb.msg.ok_added = "Task added." %]
[% SET rb.msg.ok_done = "Task completed." %]
[% SET rb.msg.ok_undone = "Task reopened." %]
[% SET rb.msg.ok_removed = "Task deleted." %]

[% # POZOR: soubor rb*.tmpl musi koncit prazdnym radkem (bug parseru) %]

```

`Pages/ukoly/msg.html` zůstává vygenerovaný (stejný jako u `prihlaseni`).

## 7. Vzhled: menu a přihlášený uživatel

V `Sites/Default/Default.pm` přidej injektáž služby účtu a proměnnou `account` do výchozích
hodnot šablon (tři změny v generovaném souboru):

```perl
my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB, $SESSION, $ACCOUNT);   # + $ACCOUNT

sub Service_UserAccount {              # nová metoda
    my ($self, $input) = @_;
    $ACCOUNT = $input;
}

sub getDefaultTemplateValues {
    my $self = shift;
    return (
        'web_site'    => $self->{'web_site'},
        'web_index'   => $self->{'web_index'},
        'layout_body' => $self->{'layout_body'},
        'account'     => $ACCOUNT->getAccount(),      # nový klíč: { login => 'admin' } nebo {}
    );
}
```

(a do bloku `KOMODO` `require Services::UserAccount::UserAccount; $ACCOUNT = new
Services::UserAccount::UserAccount;`). Celý modul vzhledu je v [07 — Vzhled](07-vzhled-site.md#modul-vzhledu).

`Sites/Default/layout_body.html` — menu s položkou Úkoly, přihlášením a jazyky:

```html
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
        <li class="nav-item"><a class="nav-link[% IF idp == "default" %] active[% END %]" href="[% script_name %]?page=default&func=default">[% rb.menu_home %]</a></li>
        <li class="nav-item"><a class="nav-link[% IF idp == "ukoly" %] active[% END %]" href="[% script_name %]?page=ukoly&func=default">[% rb.menu_tasks %]</a></li>
      </ul>
      <ul class="navbar-nav ms-auto">
        [% IF account.login %]
        <li class="nav-item"><span class="nav-link disabled"><i class="fa-solid fa-user"></i> [% account.login %]</span></li>
        <li class="nav-item"><a class="nav-link[% IF idp == "pweCreator" %] active[% END %]" href="[% script_name %]?page=pweCreator&func=default">pweCreator</a></li>
        <li class="nav-item"><a class="nav-link" href="[% script_name %]?page=prihlaseni&func=logout">[% rb.menu_logout %]</a></li>
        [% ELSE %]
        <li class="nav-item"><a class="nav-link[% IF idp == "prihlaseni" %] active[% END %]" href="[% script_name %]?page=prihlaseni&func=default">[% rb.menu_login %]</a></li>
        [% END %]
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
```

`Sites/Default/rb.tmpl`:

```
[% # RESOURCE BUNDLE (CZE) %]

[% SET rb.site_brand = "Úkolníček" %]
[% SET rb.menu_home = "Domů" %]
[% SET rb.menu_tasks = "Úkoly" %]
[% SET rb.menu_login = "Přihlásit" %]
[% SET rb.menu_logout = "Odhlásit" %]
[% SET rb.footer_text = "Postaveno na PWE (Perl Web Engine)." %]

[% # titulky flash zprav (templates/messenger.html) %]
[% SET rb.messanger_allright_title = "Hotovo" %]
[% SET rb.messanger_error_title = "Chyba" %]

[% # POZOR: soubor rb*.tmpl musi koncit prazdnym radkem (bug parseru) %]

```

`Sites/Default/rb_EN.tmpl`:

```
[% # RESOURCE BUNDLE (EN) %]

[% SET rb.site_brand = "Úkolníček" %]
[% SET rb.menu_home = "Home" %]
[% SET rb.menu_tasks = "Tasks" %]
[% SET rb.menu_login = "Log in" %]
[% SET rb.menu_logout = "Log out" %]
[% SET rb.footer_text = "Powered by PWE (Perl Web Engine)." %]

[% # titulky flash zprav (templates/messenger.html) %]
[% SET rb.messanger_allright_title = "Done" %]
[% SET rb.messanger_error_title = "Error" %]

[% # POZOR: soubor rb*.tmpl musi koncit prazdnym radkem (bug parseru) %]

```

Do `static/css/site.css` přidej styl hotových úkolů:

```css
/* Hotove ukoly v seznamu (Pages/ukoly/table.html) */
tr.task-done td { color: var(--bs-secondary-color); }
tr.task-done td:first-child { text-decoration: line-through; }
```

## 8. Úvodní stránka s počty úkolů

V `Pages/default/default.pm` přidej injektáž služby `Tasks` a předej statistiku šabloně:

```perl
my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB, $TASKS);   # + $TASKS

sub Service_Tasks {
    my ($self, $input) = @_;
    $TASKS = $input;
}

sub default {
    my $self = shift;

    $WEB->setIDP("default");
    $WEB->printHttpHeader();
    $WEB->printHtmlHeader();
    $WEB->printHtmlLayout(
        html_main => "Pages/default/main.html",
        stats     => $TASKS->getStats(),
    );
}
```

(do `KOMODO`: `require Services::Tasks::Tasks; $TASKS = new Services::Tasks::Tasks;`;
zbytek souboru — akce `setlanguage` a `error` — zůstává z generátoru). `Pages/default/main.html`:

```html
[% PROCESS templates/resource_bundle.tmpl %]
<div class="p-5 mb-4 bg-body-tertiary rounded-3">
  <h1 class="display-6">[% rb.home_title %]</h1>
  <p class="lead">[% rb.home_intro %]</p>
  <p class="mb-3">
    <span class="badge text-bg-primary fs-6">[% stats.total %]</span> [% rb.home_total %]
    <span class="badge text-bg-success fs-6 ms-3">[% stats.done %]</span> [% rb.home_done %]
  </p>
  <a class="btn btn-primary" href="[% script_name %]?page=ukoly&func=default"><i class="fa-solid fa-list-check"></i> [% rb.home_button %]</a>
</div>
```

`Pages/default/rb.tmpl`:

```
[% # RESOURCE BUNDLE (CZE) %]

[% SET rb.home_title = "Úkolníček" %]
[% SET rb.home_intro = "Jednoduchý seznam úkolů postavený nad enginem PWE: databáze, stránkovaná tabulka, AJAX formulář, přihlášení správce a dva jazyky." %]
[% SET rb.home_total = "úkolů celkem" %]
[% SET rb.home_done = "hotových" %]
[% SET rb.home_button = "Zobrazit úkoly" %]

[% SET rb.msg.error_language = "Neznámý jazyk." %]

[% # POZOR: soubor rb*.tmpl musi koncit prazdnym radkem (bug parseru) %]

```

`Pages/default/rb_EN.tmpl`:

```
[% # RESOURCE BUNDLE (EN) %]

[% SET rb.home_title = "Úkolníček" %]
[% SET rb.home_intro = "A simple task list built on the PWE engine: database, paginated table, AJAX form, administrator login and two languages." %]
[% SET rb.home_total = "tasks in total" %]
[% SET rb.home_done = "done" %]
[% SET rb.home_button = "Show tasks" %]

[% SET rb.msg.error_language = "Unknown language." %]

[% # POZOR: soubor rb*.tmpl musi koncit prazdnym radkem (bug parseru) %]

```

## 9. Spuštění a ověření

```bash
make check WEB=ukoly.web                              # ---- VYSLEDEK: bez chyb, 0 varovani
make run   WEB=ukoly.web PROFILE=mariadb ARGS=-d       # http://127.0.0.1:7778/
make logs  WEB=ukoly.web PROFILE=mariadb               # při startu proběhnou migrace 1–3; žádné [E]
```

Ruční průchod v prohlížeči nebo přes `curl` (očekávané chování):

| Krok | Očekávání |
| --- | --- |
| `/` | úvodní stránka s počty úkolů |
| `?page=ukoly&func=default` jako host | seznam, žádný formulář, odkaz na přihlášení |
| POST `page=ukoly&func=add&title=x` jako host | 401 |
| `?page=prihlaseni` → špatné heslo | červený messenger „Nesprávné jméno nebo heslo.“ |
| přihlášení `admin` / `tajneheslo` | redirect na seznam, zelený messenger, formulář a tlačítka v tabulce, jméno v menu |
| přidání úkolu (AJAX) | tabulka se překreslí bez reloadu, messenger „Úkol byl přidán.“ |
| prázdný název | messenger „Vyplňte název úkolu.“ (HTTP 400 z AJAXu) |
| název přes 128 znaků, nebo jen mezery | „Název úkolu je prázdný nebo delší než 128 znaků.“ |
| zelené tlačítko u úkolu | stav se přepne, řádek se přeškrtne, messenger bez odrolování |
| 11+ úkolů | stránkování pod tabulkou; řazení kliknutím na hlavičku (AJAX) |
| koš u úkolu | potvrzení, reload, „Úkol byl smazán.“ |
| EN v menu | celý web anglicky včetně flash zpráv, `<html lang="en">` |
| Odhlásit | „Byli jste odhlášeni.“; akce `remove` → 401; `?page=pweCreator` → 401 |
| `static/css/site.css`, `assets/javascript/pwe.js` | 200 (nginx) |

Totéž jako skript přes `curl` je v [18 — Testy](18-testy.md#integrační-test-webu-přes-compose).
V logu enginu (`make logs`) se validační chyby objeví jako `[E] Libs::Pages … Not-defined input
parameter` / `Invalid rule` — to jsou chyby vstupu uživatele, ne enginu. Stack zastavíš
`make down WEB=ukoly.web PROFILE=mariadb` (`ARGS=-v` smaže i databázi).

## 10. Co jsme použili a kde je to popsané

| Část webu | Mechanismus | Kapitola |
| --- | --- | --- |
| `conf/*.dbversion` | migrace schématu | [03](03-struktura-webu.md) |
| `Entities/Task` | entita, vlastní validace sloupce, automatická razítka | [09](09-databaze-a-entity.md) |
| `Services/Tasks` | služba nad entitou, transakce, nízkoúrovňový SELECT, validátor `is_task_id` | [08](08-sluzby.md), [05](05-validace.md) |
| `Services/UserAccount` | DB session, skupiny, přihlášení | [11](11-uzivatele-a-prava.md) |
| `Pages/ukoly` | akce a práva, `defined`/`validate`/`rules`, `genTable`, AJAX JSON, messenger | [04](04-stranky.md), [09](09-databaze-a-entity.md), [10](10-ajax.md) |
| `Pages/prihlaseni` | klasický POST formulář, redirect s flash zprávou | [04](04-stranky.md) |
| `Sites/Default` | layouty, menu podle `idp`/`account`/`group`, injektáž služby do vzhledu | [07](07-vzhled-site.md) |
| `rb*.tmpl` | texty ve dvou jazycích, klíče chyb | [06](06-sablony-a-i18n.md) |

## 11. Náměty na rozšíření

- Účty v tabulce `users` s hashem hesla místo konfigurace ([11](11-uzivatele-a-prava.md#uživatelé-v-databázi-náčrt-rozšíření)).
- Detail úkolu AJAXem do panelu (`replaceHTMLSimple` + `genTmpl`, [10](10-ajax.md)).
- E-mail při přidání úkolu (`Email` do `core_services`, `MailQueue` do `core_entities`, tabulka
  `mailqueue`, cron akce `sendAllEmail`, [13 — Cookbook](13-cookbook.md)).
- Export do CSV (`printHttpHeader(type => 'csvdown')`).
- Termín splnění: sloupec `due date` migrací, formulářové pole `type="date"`, pravidlo `is_regx`.
- Produkce: `pwe.development => 0`, heslo přes `PWE_CONF_web_admin_password`, image z `Dockerfile`
  ([17 — Nasazení](17-nasazeni.md)).
