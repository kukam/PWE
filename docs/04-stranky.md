# 04 — Stránky (Pages)

Stránka je controller: modul `Pages/<X>/<X>.pm` (balíček `Pages::<X>::<X>`), který engine
zavolá pro URL `?page=<X>&func=<akce>`. Tato kapitola je úplný kontrakt stránky — co musí
a může deklarovat a jaké API má k dispozici. Zdroj pravdy je `PWE/Libs/Pages.pm`.

## Kostra

```perl
package Pages::mojeStranka::mojeStranka;

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);     # + proměnné pro injektované služby

sub new {
    my ($class, $self, $conf, $log, $validate, $dbi, $entities, $user, $web) = @_;

    $DBI = $dbi; $LOG = $log; $CONF = $conf; $USER = $user;
    $WEB = $web; $VALIDATE = $validate; $ENTITIES = $entities;

    $self->{'func'}->{'default'} = [];                  # akce a práva (viz níže)
    $self->{'func'}->{'form'}    = [];
    $self->{'defined'}->{'form'} = {parameters => ['email']};          # validace (kapitola 05)
    $self->{'error'}->{'form'}   = "error";                             # kam při chybě validace

    bless $self, $class;
    return $self;
}

sub Site_Default      { my ($self, $input) = @_; $WEB = $input; }       # injektáž vzhledu
sub Service_UserAccount { my ($self, $input) = @_; $USER = $input; }    # injektáž služby

sub KOMODO { return; ... }                                               # mrtvý kód pro IDE (viz níže)

sub default { ... }                                                      # akce
sub form    { ... }
sub error   { my ($self, $error) = @_; ... }                             # chybová metoda validace

1;
```

Konstruktor dostane **předpřipravený** `$self` (hash s klíči `access`, `services_list`,
`entities_list`, `sites_list`, `autostart`), do kterého zapíše atributy, a **musí ho
`bless`-nout a vrátit**. Pokud konstruktor spadne nebo nevrátí objekt, stránka se nenačte
(do logu jde `[E]`, server běží dál bez ní).

Globální proměnné modulu (`my ($CONF, …)`) jsou lexikální proměnné souboru — nastavují se
v `new()` a přežívají celou dobu běhu procesu. **Nikdy do nich neukládej stav requestu.**

## Atributy stránky

### `func` — akce a práva (povinné)

```perl
$self->{'func'}->{'default'} = [];                 # kdokoli (i nepřihlášený = skupina guest)
$self->{'func'}->{'add'}     = ['admin'];          # jen skupina admin
$self->{'func'}->{'report'}  = ['admin', 'manager']; # kterákoli z uvedených skupin
```

Z URL jsou volatelné **jen** metody registrované ve `func`. Hodnota je pole skupin uživatele
s přístupem; prázdné pole = bez omezení. Skupiny uživateli přiděluje služba účtu
(`$USER->addGroup('admin')`, [11 — Uživatelé a práva](11-uzivatele-a-prava.md)).

### `access` — práva na celou stránku

```perl
$self->{'access'} = ['admin'];    # bez skupiny admin → 401 na všechny akce
```

Pravidlo (`Libs::Pages::accessFunc`): má-li akce vlastní neprázdný seznam skupin, rozhoduje
on; jinak rozhoduje `access`; jsou-li oba prázdné, má přístup každý. Nepovolený přístup
vrací 401 (`errorPage/e401`).

**Veřejná akce na chráněné stránce** musí skupiny vyjmenovat — prázdné pole u akce při nastaveném
`access` NEznamená „pro všechny“, ale „platí `access`“:

```perl
$self->{'access'}          = ['admin'];                        # celá administrace jen pro správce
$self->{'func'}->{'default'} = ['guest', 'customer', 'admin'];  # přihlašovací formulář vidí každý
$self->{'func'}->{'login'}   = ['guest', 'customer', 'admin'];
$self->{'func'}->{'orders'}  = [];                               # prázdné = platí access = admin
```

### `error` — chybová metoda validace

```perl
$self->{'error'}->{'form'} = "error";
```

Když deklarativní validace akce `form` najde chybu, engine místo `form` zavolá metodu `error`
s referencí na pole klíčů chyb (`['error_exist__email', 'error_email']`). Pokud atribut `error`
pro akci není, zavolá se **původní akce** s polem chyb jako argumentem (`sub form { my ($self,
$error) = @_; … }`). Chybějící metoda uvedená v `error` → 500.

### `defined`, `validate`, `rules`, `exist`, `unique`, `replace` — validace vstupu

Spouští se **před** akcí v tomto pořadí; běh se zastaví na první vrstvě, která vrátí chyby.
Kompletní popis včetně syntaxe je v [05 — Validace](05-validace.md).

### `autostart`

Metoda `autostart()` (pokud existuje) se zavolá **jednou při načtení stránky** (start
procesu, reload po pádu). Hodí se pro jednorázovou přípravu (např. vytvoření adresáře).
Hooky `newRequest`/`flush` stránky nemají — ty mají jen služby a vzhledy.

## Injektážní metody

```perl
sub Site_Default     { my ($self, $in) = @_; $WEB     = $in; }   # vzhled Sites/Default
sub Service_DBTable  { my ($self, $in) = @_; $DBTABLE = $in; }   # služba Services/DBTable (z enginu)
sub Service_Tasks    { my ($self, $in) = @_; $TASKS   = $in; }   # vlastní služba webu
```

Název za `Site_` / `Service_` je přesně název adresáře modulu. Engine metodu zavolá při načtení
stránky s instancí vzhledu/služby. Každý injektovaný modul **musí být dostupný** — buď vlastní
modul webu, nebo název v `pwe.core_sites`/`core_services` — jinak engine stránku odregistruje
a zaloguje `Registred service object X not exist!`.

Konvence: `Site_Default` přepisuje `$WEB` (stránka pak renderuje přes vzhled webu).
`Service_UserAccount` typicky přepisuje `$USER` — služba účtu má stejné API jako `Libs::User`
(deleguje na něj) a navíc `getAccount`, `login`, … Ostatní služby mají vlastní proměnnou.

## Akce

```perl
sub default {
    my $self = shift;

    $WEB->setIDP("mojeStranka");                                  # id stránky pro šablony (menu, rb)
    $WEB->printHttpHeader();                                      # HTTP hlavička text/html + cookie
    $WEB->printHtmlHeader(title => "Moje stránka");               # <!DOCTYPE html><html><head>…</head>
    $WEB->printHtmlLayout(html_main => "Pages/mojeStranka/main.html", polozky => \@polozky);
}
```

Akce dostane jako argument `undef` (nebo pole chyb, viz `error`). Vrací:

| Návrat | Význam |
| --- | --- |
| `undef`, `1`, cokoli jiného | 200 OK — stránka už vytiskla odpověď (volání `print` vrací 1) |
| `400` | špatný parametr → `errorPage/e400` (typicky vrací chybová metoda při AJAX requestu) |
| `401` | přístup odepřen → `errorPage/e401` |
| `404` | nenalezeno → `errorPage/e404` |
| `500` | interní chyba → `errorPage/e500` |
| `die` | engine odchytí: zaloguje, odregistruje stránku, pošle e-mail report, znovu načte, vrátí 500 |

Chybová stránka vykreslí messenger — pokud ho stránka před `return 4xx` nastavila, použije se
její text, jinak výchozí (`error_bad_parameter`, `error_access_denied`, `error_page_not_found`,
`error_hups`).

### Typická struktura akcí

| Akce | Co dělá |
| --- | --- |
| `default` | vykreslí stránku (GET) |
| `form` / `add` / `save` | zpracuje POST, nastaví messenger, znovu vykreslí (`$self->default()`) nebo přesměruje |
| `error` | zobrazí chyby validace; při AJAX requestu `return 400` |
| `setlanguage` | `$USER->setLanguage($lang)` a `$self->default()` |

### POST formuláře

CGI.pm při POST čte parametry jen z těla požadavku. Engine od verze 2.2.0 doplní `page` a `func`
z query stringu, když v těle chybí (hodí se pro callbacky platebních bran a webhooky, jejichž tělo
neovlivníš); ostatní parametry z query stringu při POST dostupné nejsou. U vlastních formulářů
posílej `page` a `func` pro jistotu ve skrytých polích:

```html
<form action="[% script_name %]?page=mojeStranka&func=form" method="POST">
  <input type="hidden" name="page" value="mojeStranka" />
  <input type="hidden" name="func" value="form" />
  …
</form>
```

### Přesměrování

```perl
$WEB->printHttpHeader('type' => 'redirect', 'redirect_link' => $WEB->getScriptName() . '?page=ukoly&func=default');
```

Pošle `Status: 301` + `Location`. Messenger nastavený před redirectem se zobrazí na cílové
stránce (přežije request). Pro AJAX viz `ajax_redirect` v [10 — AJAX](10-ajax.md).

## Render API (`$WEB`)

`$WEB` je vzhled (Site) webu; co nemá sám, deleguje na `Libs::Web`. Nejpoužívanější metody
(úplný seznam v [14 — API reference](14-api-reference.md)):

| Metoda | Účel |
| --- | --- |
| `setIDP($idp)` | id stránky; v šablonách `idp` (aktivní položka menu, `rb.$idp.*`) |
| `printHttpHeader(%tmpl)` | HTTP hlavička; `type => 'ajax' \| 'redirect' \| 'ajax_redirect' \| 'css' \| 'js' \| 'plain' \| 'file' \| 'image' \| 'static' \| 'csvdown' \| '400' …` |
| `printHtmlHeader(%tmpl)` | `<head>` z layoutu vzhledu; `title => …` (čistý text, layout ho escapuje `\| html`); `layout_header => "…"` přebije hlavičku pro tento request (tisk, faktura) |
| `printHtmlLayout(html_main => "Pages/X/main.html", %tmpl)` | `<body>` z layoutu vzhledu, do kterého se vloží `html_main`; všechny klíče `%tmpl` jsou proměnné šablony |
| `printAjaxLayout(ajax_id => [...], ajax_tmpl => [...] \| ajax_html => [...], ajax_data => {...})` | JSON odpověď pro `pwe.js` |
| `setMessenger("Pages/X/msg.html", msg_allright => ['ok'] \| msg_error => $error, %tmpl)` | flash zpráva |
| `genTmpl("Pages/X/cast.html", %tmpl)` | vyrenderuje šablonu do řetězce (fragmenty, e-maily) |
| `getScriptName()` | `pwe.fcgi` — pro sestavování URL |
| `convertToRewrite($text)` | URL slug bez diakritiky |

## Čtení vstupů (`$USER`)

| Metoda | Účel |
| --- | --- |
| `getParam("email", 0, $default)` | první hodnota parametru (index 0) nebo default; `"all"` místo indexu vrátí celé pole |
| `isdefinedParam("email")` | 1, pokud parametr přišel a není prázdný řetězec |
| `existParam("email")` | 1, pokud parametr přišel (i prázdný) |
| `getParamsList()` / `getParams()` | názvy / hash všech parametrů |
| `setParameter("x", ["v"])`, `setParameter("x", "v", 0)` | přepsat parametr |
| `getRequestMethod()` | `GET`/`POST` (z CLI lze předat parametrem `request_method`) |
| `getSid()`, `getIP()`, `getUserAgent()` | session id, IP, User-Agent |
| `getGroup()`, `existGroup('admin')` | skupiny uživatele |
| `setLanguage("EN")` | přepnutí jazyka (jen jazyk z `http.languages`) |
| `setOpts($data, "klic")`, `getOpts("klic", undef, $default)`, `delOpts("klic")` | data uživatele mezi requesty (opts) |
| `saveUploadFile($param, $home, $path, $rewrite)` | uloží nahrané soubory; vrací `($error, @soubory)` |

> **`$USER` jako služba účtu.** Když stránka injektuje `Service_UserAccount` do `$USER`, volání neznámých metod
> jde přes `Services::Session` na `Libs::User`. Metody `getParam`, `getSid`, `addGroup` fungují beze změny, ale
> `getValue` má v `Services::Session` jinou signaturu (`getValue($klic, $default)` = sloupec session), takže
> `$USER->getValue("language", undef, "CZE")` vrátí `undef`. Jazyk uživatele zjišťuj metodou vlastní služby
> (např. `getLanguage()`, viz [11](11-uzivatele-a-prava.md)) nebo ve službách přes `Libs::User` (`$USER` ve službě
> je vždy `Libs::User`).

Parametr `ajax_request=1` posílá klient `pwe.js` u každého AJAX volání — podle něj stránka
pozná, zda má odpovědět celou stránkou, nebo AJAX odpovědí:

```perl
if ($USER->getParam("ajax_request", 0, undef)) {
    $WEB->printHttpHeader('type' => 'ajax');
    $WEB->printAjaxLayout(ajax_id => ['tabulka'], ajax_tmpl => ['Pages/X/table.html'], ajax_data => {table => $table});
} else {
    $WEB->printHttpHeader();
    $WEB->printHtmlHeader();
    $WEB->printHtmlLayout(html_main => "Pages/X/main.html", table => $table);
}
```

## Stránka bez vzhledu (API, cron, callbacky)

Stránka nemusí mít žádný injektor `Site_X`: `$WEB` pak zůstává `Libs::Web` z konstruktoru a stránka
odpovídá přímo:

```perl
sub mail {
    my $self = shift;
    return 401 unless ($self->keyOk($USER->getParam("key", 0, "")));   # vlastní kontrola tajného klíče
    my $n = $EMAIL->sendAllEmail();
    $WEB->printHttpHeader('type' => 'plain');
    print "OK\n";
}
```

Hodí se pro cron akce, JSON API (`type => 'static', content_type => 'application/json'`) a návratové URL
externích systémů. Takové akce nemají CSRF token — chraň je tajným klíčem z konfigurace (porovnej časově
konstantně), IP adresou nebo podpisem (platební brána).

## Blok `KOMODO`

```perl
# KOMODO-IDE/KOMODO-EDIT
sub KOMODO {
    return;
    require Libs::Config; require Libs::Log; require Libs::Validate; require Libs::DBI;
    require Libs::Entities; require Libs::User; require Sites::Default::Default;
    require Services::Tasks::Tasks;
    $CONF = new Libs::Config; $LOG = new Libs::Log; $VALIDATE = new Libs::Validate; $DBI = new Libs::DBI;
    $ENTITIES = new Libs::Entities; $USER = new Libs::User; $WEB = new Sites::Default::Default;
    $TASKS = new Services::Tasks::Tasks;
}
```

Mrtvý kód (první příkaz je `return`), který IDE pomůže rozpoznat typy globálních proměnných
a napovídat metody. Je součástí konvence — každý modul ho má, nikdo ho nevolá. Je to zároveň
**jediné místo**, kde se v modulu webu smí objevit `require Libs::…`; závislosti jinak
předává engine.

## Soubory stránky

| Soubor | Účel |
| --- | --- |
| `Pages/X/X.pm` | modul |
| `Pages/X/main.html` | tělo stránky (vkládá se do layoutu vzhledu přes `html_main`) |
| `Pages/X/msg.html` | šablona flash zpráv: `[% PROCESS templates/resource_bundle.tmpl %]` + `[% INCLUDE templates/messenger.html %]` |
| `Pages/X/*.html` | další fragmenty (formulář, tabulka, řádek) — `INCLUDE` z `main.html` nebo render přes `genTmpl`/`ajax_tmpl` |
| `Pages/X/rb.tmpl`, `rb_<LANG>.tmpl` | texty stránky a klíče chyb `rb.msg.<klíč>` |

Kostru vytvoří `make module TYPE=page WEB=<web> NAME=X ARGS='--site Default --services A,B'`
(nebo stránka `pweCreator` v prohlížeči). Šablona kostry je `PWE/Pages/pweCreator/page.tmpl`.

## Životní cyklus stránky

```
new()                    jednou při startu procesu (nebo při reloadu po pádu)
Site_X / Service_X       jednou (injektáž)
autostart()              jednou (pokud existuje)
── každý request ──
accessFunc               práva (401)
checkInputData           replace → defined → validate → rules → exist → unique
<akce>() | error($err)   tvoje metoda; tiskne přes $WEB nebo vrací status kód
```

Po změně `.pm` souboru je nutný restart FastCGI procesů (`make restart`); šablony a `rb*.tmpl`
se načítají při requestu.
