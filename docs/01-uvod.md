# 01 — Úvod a koncepty

## Co je PWE

PWE (Perl Web Engine) je perzistentní **FastCGI** proces napsaný v Perlu. Spustí se jednou,
načte do paměti engine i všechny moduly webu (stránky, vzhledy, služby, entity) a pak
v nekonečné smyčce obsluhuje HTTP requesty. Před ním stojí webserver (nginx, Apache), který
mu requesty předává protokolem FastCGI a který může sám servírovat statické soubory.

```
prohlížeč ──HTTP──> nginx / Apache ──FastCGI──> pwe.fcgi (smyčka, 1..N procesů)
                                                   │
                                                   ├─ Libs::*      jádro enginu
                                                   ├─ Sites::*     vzhled (layout, menu)
                                                   ├─ Services::*  business logika
                                                   ├─ Entities::*  tabulky databáze
                                                   └─ Pages::*     stránky = controllery
```

Co engine dává k dispozici:

| Oblast | Co to umí | Kapitola |
| --- | --- | --- |
| routing | `?page=<stránka>&func=<akce>` → metoda modulu `Pages/<stránka>/<stránka>.pm` | [04](04-stranky.md) |
| validace | deklarativní pravidla nad vstupy, spouštějí se před akcí | [05](05-validace.md) |
| šablony | Template Toolkit, layouty, automatické proměnné, texty ve více jazycích | [06](06-sablony-a-i18n.md) |
| vzhled | vlastní layout a menu webu v jednom modulu `Sites/Default` | [07](07-vzhled-site.md) |
| služby | singletony s logikou, injektované do stránek, s hooky na začátek/konec requestu | [08](08-sluzby.md) |
| databáze | MySQL/MariaDB/PostgreSQL, pool spojení, migrace schématu, DAO a entity, stránkované tabulky | [09](09-databaze-a-entity.md) |
| AJAX | odpověď jako HTML fragment nebo JSON „nahraď element“, klientská knihovna `pwe.js` | [10](10-ajax.md) |
| uživatelé | session cookie, skupiny a práva na akce, data mezi requesty (opts / DB session) | [11](11-uzivatele-a-prava.md) |
| robustnost | pád metody neshodí proces: modul se odregistruje, pošle se report, modul se znovu načte | [19](19-engine-internals.md) |

Výchozí UI je Bootstrap 5.3.8, jQuery 4.0.0 a Font Awesome 6.4.2 — engine je nese v `PWE/assets`
a každý web je dostává bez kopírování.

## Filozofie

1. **Konvence místo konfigurace.** Modul `Foo` je vždy v `Foo/Foo.pm` s balíčkem `Pages::Foo::Foo`
   (resp. `Sites::`, `Services::`, `Entities::`). Co nesplňuje konvenci, engine tiše přeskočí.
2. **Závislosti předává engine.** Stránka si služby a vzhled ne-`require`-uje; deklaruje metodu
   `Service_<Nazev>` nebo `Site_<Nazev>` a engine do ní objekt při startu vloží (dependency
   injection). Konstruktor každého modulu dostane singletony enginu (`$CONF`, `$LOG`, `$USER`, …).
3. **Web neobsahuje engine.** Web je jen to, co je specifické pro něj. Engine je v adresáři
   `PWE/` v kořeni repozitáře, web ho dostane přes proměnné prostředí a v `conf/web.conf` vyjmenuje, které sdílené moduly
   enginu používá. Oba se verzují a vydávají nezávisle.
4. **Pád není fatální.** Metoda stránky smí `die`-nout: engine to odchytí, pošle report, modul
   znovu načte a klient dostane 500. Píše se proto čitelný kód bez obranných `eval`ů, chyby
   vstupu se řeší deklarativní validací.
5. **Deklarativní validace.** Co je povinné, jakého tvaru a zda existuje v DB, stránka
   deklaruje v konstruktoru; engine to zkontroluje před voláním akce a při chybě zavolá
   chybovou metodu se seznamem klíčů, které se přeloží z resource bundle.

## Životní cyklus

### Start procesu

[`PWE/pwe.fcgi`](../PWE/pwe.fcgi) postaví singletony **v pevném pořadí** a každý dalšímu předá ty
předchozí konstruktorem:

```
Libs::Config    conf/web.conf + conf/database.conf, přepis z ENV PWE_CONF_*
Libs::Log       logování, úrovně, měření času
Libs::Validate  validátory is_*
Libs::MyDBI     připojení k DB (pool), migrace dbversion, mapa tabulek (DAO mapa)
Libs::User      stav requestu: session cookie, parametry, skupiny, opts
Libs::Web       render: šablony, HTTP hlavičky, AJAX, resource bundle
Libs::Entities  načte Entities/*  (sdílená instance každé entity)
Libs::Services  načte Services/*, injektuje Service_* mezi službami, zavolá autostart()
Libs::Sites     načte Sites/*,    injektuje Service_*/Site_*, autostart()
Libs::Pages     načte Pages/*,    injektuje Site_*/Service_*, registruje rb soubory, autostart()
```

Požadavek `pwe.require_core` ověří proti `PWE/VERSION` hned po načtení konfigurace a logu
(`Libs::Config`, `Libs::Log`) — ještě před připojením k databázi a sestavením ostatních singletonů;
při nesplnění zapíše chybu do logu a skončí. Teprve po sestavení všech singletonů — tedy až po
připojení k databázi a migracích schématu — otevře FastCGI socket (`FCGI_SOCKET_PATH`) a vstoupí do
smyčky requestů.

### Ukončení procesu

Signál `SIGTERM` ukončí proces pořádaně: rozpracovaný request doběhne s funkční databází a klient
dostane celou odpověď, nová spojení už engine nepřijímá, pak odpojí databáze a skončí s kódem 0.
Během startu se přeruší na bezpečném místě (mezi pokusy o připojení k databázi, mezi kroky migrace).
Podrobně [17 — Běh procesu enginu](17-nasazeni.md#běh-procesu-enginu).

### Jeden request

1. `$DBI->testConnection()` — ping DB spojení (nejvýše jednou za `pwe.db_ping_interval` s).
2. Z parametrů se přečte `page`, `func` (výchozí `pwe.default_page`/`default_func`) a session
   cookie (`http.cookie_name`).
3. `$USER->newRequest(...)` — ověří/založí session ID, nastaví skupinu `guest`, načte opts.
4. `$SITES->newRequest()`, `$SERVICES->newRequest()` — hooky vzhledů a služeb (např. služba
   účtu zde načte session z DB a přidělí skupiny).
5. Všechny CGI parametry se zkopírují do `$USER` (`getParam`).
6. Routing podle `SCRIPT_FILENAME`: běžný request → `$PAGES->callPageFunc($page,$func)`;
   existující soubor pod `pwe.assets_dir` → `systemPage/file`; adresář → `systemPage/folder`;
   `..` v cestě → 401; chyba CGI (velký upload) → `errorPage/cgi_error`.
7. `callPageFunc`: stránka a akce existují? → práva (`access`/skupiny) → deklarativní validace →
   akce (nebo chybová metoda). Návratový kód `404/401/400/500` → `errorPage`; jinak 200.
8. `$SITES->flush()`, `$SERVICES->flush()`, `$WEB->flush()`, `$USER->flush()` — úklid, uložení
   opts / DB session.
9. Do logu se zapíše řádek `Page printed : PID:… page:… func:… result:…`.

> Důsledek FastCGI: proměnné `my` na úrovni modulu **přežívají mezi requesty**. Stav patřící
> requestu drž v `$USER` (parametry, opts) nebo v session, nikdy v proměnných modulu.

## Dva kořeny: web a engine

Engine pracuje se dvěma adresáři:

| Kořen | Odkud | Co obsahuje |
| --- | --- | --- |
| `pwe.home` = **web** (`webapps/<nazev>/`) | `PWE_CONF_pwe_home` (jinak adresář skriptu `pwe.fcgi`, tedy stejný jako engine) | `conf/web.conf`, vlastní `Pages/ Sites/ Services/ Entities/`, `static/`, dočasná data |
| `pwe.core` = **engine** (adresář `PWE/`) | `PWE_CONF_pwe_core` (jinak adresář skriptu `pwe.fcgi`) | `Libs/`, `templates/`, `assets/`, sdílené `Pages/ Sites/ Services/ Entities/`, `VERSION` |

Slovo `core` v názvech klíčů (`pwe.core`, `PWE_CONF_pwe_core`, `pwe.core_pages`, `pwe.require_core`, …)
znamená „kořen enginu“; žádný adresář `core/` v repozitáři není. Engine leží v adresáři `PWE/`
v kořeni repozitáře; v kontejnerech, kde je repozitář namountovaný do `/PWE`, je to `/PWE/PWE`
(proto `PWE_CONF_pwe_core=/PWE/PWE`), weby jsou v `/PWE/webapps/<nazev>`.

Moduly, šablony (Template `INCLUDE_PATH`), resource bundly i statické soubory se hledají
**nejdřív ve webu, pak v enginu**. Stejný název modulu ve webu i v enginu znamená, že platí
modul webu — tak lze přebít třeba `Pages/errorPage` nebo šablonu `templates/messenger.html`.

Z enginu se nenačítá všechno automaticky. Web v `conf/web.conf` vyjmenuje, co si bere:

```perl
pwe => {
    require_core  => ">=2.2",                                        # minimální verze enginu (PWE/VERSION)
    core_pages    => ["css", "errorPage", "systemPage", "pweCreator"],
    core_sites    => [],                                             # web má vlastní Sites/Default
    core_services => ["DBTable", "Session"],
    core_entities => ["DBTable", "Session"],
},
```

Když klíč chybí, platí výchozí hodnoty (`core_pages` = css, errorPage, systemPage, pweCreator;
`core_sites` = Default; služby a entity žádné). Hodnota `"*"` znamená „vše z enginu“.
Bez `PWE_CONF_pwe_home` jsou oba kořeny stejné a engine funguje jako jeden celek (tak běží
testovací fixture).

## Mapa repozitáře

```text
PWE/                          KOŘEN REPOZITÁŘE (pracovní kopie; v kontejnerech namountovaný do /PWE)
├── PWE/                      ENGINE = kořen pwe.core (v kontejnerech /PWE/PWE; tamtéž v image webu, kam se kopíruje při sestavení)
│   ├── pwe.fcgi              vstupní bod
│   ├── debug.cgi             tentýž engine pod jménem debug.cgi: ladění ve VS Code přes nginx /debug.cgi
│   ├── Libs/                 jádro: Config, Log, Validate, User, Web, Pages, Sites, Services, Entities,
│   │                         MyDBI (+ DAO, DRIVER/MySQL, DRIVER/Postgre), Send, Pics
│   ├── templates/            HTTP hlavičky, výchozí layouty, messenger, resource_bundle, href
│   ├── assets/               pwe.js, ajaxprogress.js, Bootstrap 5.3.8, jQuery 4.0.0, Font Awesome 6.4.2
│   ├── Pages/                css, errorPage, systemPage, pweCreator, ajaxExamples, formExamples, responsive
│   ├── Sites/                Default (tenká fasáda), Responsive (ukázka)
│   ├── Services/             Session, UserAccount (ukázka), DBTable, Email
│   ├── Entities/             Entity (základní třída), Session, DBTable, MailQueue
│   ├── tools/                new-webapp.pl, new-module.pl, check-webapp.pl, smtp-test.pl, pwe-cgi.sh, run-webapp.sh,
│   │                         run-tests.sh, perl-compile.sh, build-images.sh (make images), smoke-images.sh
│   │                         (make images-check), k8s.sh (make k8s-*), lib/images.sh (název image)
│   ├── t/                    testy enginu
│   ├── docker/               Dockerfile závislostních image (jeden vícestupňový: base, mariadb, mysql, postgres, debugger)
│   │                         a entrypoint.sh (vstupní skript všech image včetně image webu)
│   ├── VERSION  CHANGELOG.md   verze enginu = tag image (vedle latest)
├── webapps/                  WEBY: každý ve vlastním adresáři, vlastní git (gitignore webapps/*)
│   ├── example.web/  example-db.web/   vzorové weby (v gitu enginu; vznikají z nich image pwe-example-*)
│   └── <nazev>/              conf/ Pages/ Sites/ Services/ Entities/ static/ Dockerfile README.md
├── docs/                     tato dokumentace
├── Makefile                  jednotný vstup pro vývoj (make new/module/check/cgi/run/test/images/k8s-*)
├── docker-compose.yml        vývojový stack: nginx + 3× fcgi + databáze
├── docker-compose/           soubory stacku: docker-compose_nginx.conf (nginx) a docker-compose_*.env (proměnné služeb)
├── kubernetes/               nasazení do Kubernetes (make k8s-*, chart nxs-universal-chart): values-static.yml,
│                             values-generic.yml, vzory secrets-generic.example.yml a local.env.example, README.md
├── docker-bake.hcl           sestavení 9 image PWE (cíle a tagy pro docker buildx bake)
├── .github/                  GitHub Actions: workflows/images.yml (testy, sestavení, kouřové kontroly a publikace
│                             image do ghcr.io/kukam z výchozí větve a z větví v proměnné PUBLISH_BRANCHES),
│                             workflows/tests.yml (jen testy), dependabot.yml
└── AGENTS.md                 závazná pravidla pro AI asistenty
```

PWE se dodává jako devět image z registru `ghcr.io/kukam`; každý má právě dva tagy — verzi enginu
(obsah `PWE/VERSION`) a `latest`. Pět **závislostních image** nese jen závislosti, bez kódu enginu
a bez webu: základ `pwe-base` (běhové knihovny; nad ním běží web bez databáze), `pwe-mariadb`,
`pwe-mysql` a `pwe-postgres` (základ + DB ovladač) a `pwe-debugger` (všechny ovladače + ladicí
nástroje). **Image webu** = závislostní image + engine zkopírovaný z repozitáře + web; staví ho
`Dockerfile` webu z kořene repozitáře. Stejně vznikají čtyři **image vzorových webů**
`pwe-example-static`, `pwe-example-mariadb`, `pwe-example-mysql` a `pwe-example-postgres` — samy
spustitelné ukázky, které nejsou určené pro veřejný provoz (každý návštěvník je v nich ve skupině
`admin`). Podrobně [17 — Nasazení](17-nasazeni.md#image).

Cesty v dokumentaci jsou relativní ke kořeni repozitáře: `PWE/pwe.fcgi` je tedy soubor enginu,
`webapps/<nazev>/conf/web.conf` konfigurace webu.

Verze enginu je v `PWE/VERSION` (semver). Web říká v `pwe.require_core`, jakou verzi
potřebuje; změny enginu jsou v [`PWE/CHANGELOG.md`](../PWE/CHANGELOG.md).

## Co dál

- Rozjet web: [02 — Rychlý start](02-rychly-start.md).
- Pochopit soubory webu a konfiguraci: [03 — Struktura webu](03-struktura-webu.md).
- Napsat stránku: [04 — Stránky](04-stranky.md).
