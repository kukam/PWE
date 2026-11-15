# 11 — Uživatelé, session a práva

Engine sám neřeší účty ani hesla. Dává k dispozici tři stavební kameny: **session cookie**
(identita prohlížeče), **skupiny** (role, podle kterých se povolují akce stránek) a **úložiště
stavu mezi requesty** (opts soubor, nebo DB session). Přihlášení je pak malá služba webu,
kterou tato kapitola popisuje — tutoriál ji obsahuje celou a ověřenou.

## Session cookie

- Název cookie je `http.cookie_name` (unikátní pro každý web), hodnota `C0…`/`C1…` + MD5
  (`C0` pro HTTP, `C1` pro HTTPS; cookie z druhého schématu se zahodí a vygeneruje nová).
- Vytváří ji engine při prvním requestu (`$USER->newRequest`), posílá ji každá HTTP hlavička
  kromě `static`. Expirace `http.cookie_expire_day`, jinak `http.cookie_expire_guest` (dny).
- V kódu `$USER->getSid()`, v šablonách `cookie_id`. Hodnota se nikde neukládá jako
  „přihlášení“ — identita je jen klíč k datům uživatele.
- Tvar je přísný: přesně `C0`/`C1` + 32 hexadecimálních znaků. Cokoli jiného (kratší, delší,
  podstrčené `C0ABC`) engine zahodí a vygeneruje nové sid — útočník tak nemůže oběti vnutit sid,
  které si sám vymyslel.
- **Po přihlášení sid vyměň** (ochrana proti session fixation): web s DB session volá
  `$SESSION->regenerate()` (smaže starý řádek `session`, založí nový se stejnými daty pod novým
  sid a vrátí ho), web bez DB `$USER->regenerateSid()`. Novou cookie pošle automaticky
  nejbližší `printHttpHeader()` (i u redirectu) — `cookie_id` se bere z `getSid()` při každém
  volání. Zároveň je vhodné vygenerovat nový CSRF token, pokud ho web v session drží.

## Skupiny a práva

Každý request začíná se skupinou `guest`. Služba účtu podle svého stavu skupiny upraví:

```perl
$USER->deleteGroup('guest');
$USER->addGroup('admin');          # nebo 'user', 'manager', ...
$USER->existGroup('admin');        # 1/0
my $groups = $USER->getGroup();    # { admin => 1 }
```

Stránky deklarují, kdo smí co:

```perl
$self->{'func'}->{'default'} = [];                # kdokoli
$self->{'func'}->{'add'}     = ['admin'];         # jen admin
$self->{'access'}            = ['admin', 'user']; # celá stránka (pokud akce nemá vlastní seznam)
```

Nepovolený request dostane 401 (`errorPage/e401`, při AJAXu messenger). V šablonách je hash
skupin jako `group` — `[% IF group.admin %]…[% END %]` schová tlačítka, která by stejně skončily 401.

## Stav mezi requesty

| Web | Mechanismus | Co se ukládá | Konfigurace |
| --- | --- | --- | --- |
| bez DB | **opts soubor** (`Libs::User`, `Storable`) v `pwe.opts_dir/<3 znaky sid>/<sid>.bin` | jazyk, poslední page/func/parametry, messenger, `setOpts/getOpts` data | `pwe.enable_opt => 1`, `pwe.save_opt_to => "file"` |
| s DB | **DB session** (`Services::Session`, tabulka `session`) | sloupce tabulky: `lang`, `admin`, `messenger`, `expire`, `ipaddres`, `useragent` + vlastní | `pwe.save_opt_to => "db"`, `core_services => ["Session", …]`, `core_entities => ["Session", …]` |

Opts bez DB:

```perl
$USER->setOpts(\@basket, "eshop", "basket");          # hluboká kopie, uloží se ve flush
my $basket = $USER->getOpts("eshop", "basket", []);
$USER->delOpts("eshop", "basket");
```

DB session: hodnoty jen přes `Services::Session` (`setValue/getValue`), klíč musí být sloupec
tabulky — vlastní položky přidej migrací (`ALTER TABLE session ADD COLUMN uid int NULL`).
Expirovaná session se smaže při dalším requestu daného sid (`expire` = `http.cookie_expire_guest` dní);
řádky, jejichž sid se už nikdy neohlásí (roboti, `curl` z cronu bez cookie), uklízí engine sám —
při první a pak každé `http.session_cleanup_every`-té (výchozí 20.) nově založené session smaže
všechny řádky s `expire < now` (`0` = vypnuto).

Vygenerovaný vzhled webu s DB ukládá messenger do session, web bez DB do opts — obojí
transparentně přes `$WEB->setMessenger`.

## Služba účtu (`Services/UserAccount`)

Generátor vytvoří ve webu vlastní `Services/UserAccount/UserAccount.pm`, která v `newRequest`
načte session a ve vývojovém režimu (`pwe.development = 1`) dá každému skupinu `admin`.
Stránky ji injektují do `$USER`:

```perl
sub Service_UserAccount { my ($self, $input) = @_; $USER = $input; }
```

Proč do `$USER`: služba deleguje neznámé metody na `Session` a ta na `Libs::User`, takže
`$USER->getParam`, `getSid`, `setLanguage` fungují beze změny a navíc jsou k dispozici
`getAccount`, `getSession`, `login`, `logout`. Vzhled si ji injektuje také (`Service_UserAccount`)
a z `getAccount()` plní proměnnou `account` pro menu.

### `getValue` a jazyk přes službu účtu

`Services::Session::getValue($klic, $default)` čte sloupce session a má jinou signaturu než
`Libs::User::getValue($klic, $podklic, $default)`. Protože `$USER` ve stránce je služba účtu, která přes
`AUTOLOAD` deleguje na `Session`, nefunguje ve stránce `$USER->getValue("language", undef, "CZE")`. Služba
webu proto definuje vlastní `getLanguage()` (čte `Libs::User`) a případně `getValue` se sémantikou
`Libs::User`. `Libs::User::setLanguage` jazyk sama **neukládá** do DB session — u webu s DB ho zapisuje
služba účtu (`$SESSION->setValue('lang', $lang)`), jak to dělá generovaná `setLanguage`.

## Hotový vzor přihlášení (tutoriál)

Tabulka `session` z generátoru má sloupec `admin enum('t','f')`. Přihlášení správce je pak:

1. `web.conf`, sekce `web`: `admin_login => 'admin'`, `admin_password => '…'` (v produkci
   přepsat proměnnou `PWE_CONF_web_admin_password`).
2. Služba `UserAccount` — jádro (celý soubor v [12 — Tutoriál](12-tutorial-ukolnicek.md#5-přihlášení-správce)):

```perl
sub newRequest {
    my $self = shift;
    $self->{'session'} = $SESSION->newSession();
    $self->{'account'} = {};
    $self->{'group'}   = {};
    my $adm = $SESSION->getValue('admin', 'f');                                     # MariaDB 't'/'f', PostgreSQL (BOOLEAN) 1/0
    $self->setAdminGroup() if (defined($adm) and $adm =~ /^(t|true|1)$/i);         # přihlášený má v session admin = 't'
}

sub login {
    my ($self, $login, $password) = @_;
    my $conf_login    = $CONF->getValue("web", "admin_login", "admin");
    my $conf_password = $CONF->getValue("web", "admin_password", undef);
    return undef unless (defined($conf_password) and defined($login) and defined($password));
    return undef unless ($login eq $conf_login and $password eq $conf_password);
    $SESSION->regenerate();                           # nové sid - cookie podstrčená před přihlášením už neplatí
    $SESSION->setValue('admin', 't');                 # platí pro další requesty (flush session)
    $self->setAdminGroup();                           # platí pro tento request
    $LOG->info("Admin '$login' logged in from " . $USER->getIP());
    return 1;
}

sub logout {
    my $self = shift;
    $SESSION->setValue('admin', 'f');
    $self->{'account'} = {}; $self->{'group'} = {};
    $USER->deleteGroup('admin'); $USER->addGroup('guest');
    return 1;
}

sub setAdminGroup {
    my $self = shift;
    $self->{'account'} = {'login' => $CONF->getValue("web", "admin_login", "admin")};
    $self->{'group'}->{'admin'} = 1;
    $USER->deleteGroup('guest');
    $USER->addGroup('admin');
}
```

   `regenerate()` je metoda `Services::Session` (engine ≥ 2.2.0): přenese všechna data session
   včetně vlastních sloupců (`admin`, `uid`, …) pod nové sid, takže hodnoty nastavené před ní i po
   ní se uloží normálně ve `flush`. Volej ji v každém přihlášení (zákazník i správce); drží-li web
   v session CSRF token, vygeneruj po přihlášení i ten.

3. Stránka `prihlaseni` s akcemi `default` (formulář), `login` (POST, `defined` login +
   password, po úspěchu redirect s flash zprávou) a `logout`.
4. Chráněné akce: `$self->{'func'}->{'add'} = ['admin']`, v šablonách `[% IF group.admin %]`.

Po `make run` se přihlaste na `?page=prihlaseni&func=default` (admin / heslo z `web.conf`).

## Uživatelé v databázi (náčrt rozšíření)

Pro více účtů nahraď porovnání s konfigurací tabulkou (vzor, není součástí tutoriálového webu):

1. Migrace: `CREATE TABLE users (uid int unsigned NOT NULL AUTO_INCREMENT, login varchar(64) NOT NULL UNIQUE, password_hash char(64) NOT NULL, role varchar(32) NOT NULL DEFAULT 'user', active enum('t','f') NOT NULL DEFAULT 't', updated timestamp NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP, created timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (uid))`
   a `ALTER TABLE session ADD COLUMN uid int unsigned NULL`.
2. Entita `User` (`make module TYPE=entity WEB=<web> NAME=User ARGS='--table users'`).
3. Ve službě účtu (`use Digest::SHA qw(sha256_hex);` — standardní modul Perlu je ve webu dovolený,
   zakázané je jen `use Libs::…`):
   ```perl
   sub login {
       my ($self, $login, $password) = @_;
       my $U = $ENTITIES->createEntityObject('User', {where => "login = ? AND active = 't'", conds => [$login]});
       return undef unless ($U->uid and $U->password_hash eq sha256_hex($password . $CONF->getValue("web", "password_salt", "")));
       $SESSION->setValue('uid', $U->uid);
       $self->setAccountFromEntity($U);        # account = { uid, login, role }, addGroup($U->role)
       return 1;
   }
   ```
   a v `newRequest` načíst účet podle `$SESSION->getValue('uid')`.
4. Registraci/správu účtů řeší stránka s `unique => [{entity => 'Entities::User', primary => 'uid', parameters => ['login']}]`.

## Bezpečnostní poznámky

- Heslo nikdy do gitu: `PWE_CONF_web_admin_password` (nebo `PWE_CONF_dbi_db1_password` pro DB)
  v prostředí kontejneru ([17 — Nasazení](17-nasazeni.md)).
- `pwe.development => 0` v produkci — vývojový režim dává vygenerovaná služba všem `admin`
  (tutoriál tuto zkratku odstraňuje) a zobrazuje DataDump s obsahem proměnných. Generátor kódu
  `pweCreator` zapisuje soubory jen při `pwe.development => 1` (jinak 401) — i tak ho
  z `pwe.core_pages` produkčního webu vyhoď, skupina `admin` webu je většinou „správce obsahu“,
  ne vývojář.
- Session fixation: po přihlášení vždy `$SESSION->regenerate()` (resp. `$USER->regenerateSid()`
  bez DB), viz výše; engine přijme jen cookie přesného tvaru `C0`/`C1` + 32 hex.
- Výstup uživatelských dat escapuj (`| html`), vstup validuj deklarativně ([05](05-validace.md)).
- Nahrané soubory ukládá `saveUploadFile` pod `basename` jména od klienta do `pwe.upload_dir`;
  přímý přístup k nim řídí `pwe.assets_dir`/`assets_browse_dir`.
- Přístup k `.pm`, `.conf`, `.tmpl` chrání webserver (nginx servíruje jen `assets/`/`static/`,
  Apache `.htaccess`), engine servíruje jen cesty z `pwe.assets_dir`/`assets_file` a odmítá `..`.
