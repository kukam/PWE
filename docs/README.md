# Dokumentace PWE (Perl Web Engine)

PWE je odlehčený **FastCGI webový engine v Perlu**: routing na stránky a akce, šablony
(Template Toolkit), vícejazyčné texty, deklarativní validace vstupů, databázová vrstva
(MySQL/MariaDB/PostgreSQL s entitami nad tabulkami), stránkované tabulky, AJAX a životní
cyklus modulů s izolací pádů. Konkrétní web se píše **nad enginem** jako samostatný adresář
`webapps/<nazev>/` — obsahuje jen vlastní stránky, vzhled, služby, entity, konfiguraci a
statiku; engine ani jeho kopie v něm nejsou.

Tato dokumentace je psána tak, aby podle ní **vývojář i AI asistent napsali web od nuly**,
bez nahlížení do jiných webů. Každá kapitola stojí sama o sobě a odkazuje na související.
Kompletní, ověřený příklad webu (databáze, formuláře, AJAX, přihlášení, dva jazyky) je
v kapitole [12 — Tutoriál: Úkolníček](12-tutorial-ukolnicek.md).

## Jak číst

| Chci… | Začni tady |
| --- | --- |
| rozběhnout první web za 10 minut | [02 — Rychlý start](02-rychly-start.md) |
| pochopit, jak engine funguje | [01 — Úvod a koncepty](01-uvod.md), pak [04 — Stránky](04-stranky.md) |
| napsat celý web krok za krokem | [12 — Tutoriál: Úkolníček](12-tutorial-ukolnicek.md) |
| najít přesnou signaturu metody | [14 — API reference](14-api-reference.md) |
| napsat web podle zadání (AI asistent) | [21 — Nový web podle zadání](21-novy-web-podle-zadani.md) a [`../AGENTS.md`](../AGENTS.md) |
| nasadit web do provozu | [17 — Nasazení](17-nasazeni.md) |
| vyřešit chybu | [20 — Časté problémy](20-faq.md) |

## Kapitoly

| # | Kapitola | Obsah |
| --- | --- | --- |
| 01 | [Úvod a koncepty](01-uvod.md) | co je PWE, pojmy, životní cyklus requestu, dva kořeny (web + engine), mapa repozitáře |
| 02 | [Rychlý start](02-rychly-start.md) | požadavky, `make new` → `make run`, první stránka, kontrola `make check` |
| 03 | [Struktura webu a konfigurace](03-struktura-webu.md) | anatomie `webapps/<web>/`, kompletní reference `conf/web.conf`, `database.conf`, migrace `dbversion` a jejich zámek, Dockerfile |
| 04 | [Stránky (Pages)](04-stranky.md) | kontrakt stránky: konstruktor, akce a práva, injektáž, render, návratové kódy, čtení vstupů |
| 05 | [Validace vstupů](05-validace.md) | `defined`, `validate`, `unique`, `exist`, `rules`, `replace`, vestavěné validátory, vlastní validátory |
| 06 | [Šablony a texty (i18n)](06-sablony-a-i18n.md) | Template Toolkit, layout pipeline, automatické proměnné, resource bundle, messenger, odkazy `href.tmpl` |
| 07 | [Vzhled (Sites)](07-vzhled-site.md) | layouty, vlastní Site, výchozí proměnné, CSS/SCSS, statika, více vzhledů |
| 08 | [Služby (Services)](08-sluzby.md) | kontrakt služby, lifecycle hooky, injektáž, validační metody, vestavěné služby Session, UserAccount, DBTable, Email |
| 09 | [Databáze a entity](09-databaze-a-entity.md) | konfigurace DB, šifrované spojení a volby DSN (`dsn_options`), migrace, nízkoúrovňové API, DAO, entity, transakce, stránkované tabulky `genTable` |
| 10 | [AJAX](10-ajax.md) | serverová odpověď (HTML/JSON/redirect), klient `pwe.js`, AJAX formuláře, chyby |
| 11 | [Uživatelé, session a práva](11-uzivatele-a-prava.md) | skupiny a `access`, session cookie, opts bez DB, DB session, hotový vzor přihlášení |
| 12 | [Tutoriál: Úkolníček](12-tutorial-ukolnicek.md) | kompletní web s databází krok za krokem, všechny soubory v plném znění |
| 13 | [Cookbook](13-cookbook.md) | hotové recepty: formulář, upload, tabulka, redirect, jazyk, e-mail, cron, vlastní chybová stránka… |
| 14 | [API reference](14-api-reference.md) | metody `$CONF`, `$LOG`, `$USER`, `$WEB`, `$DBI`, `$ENTITIES`, `$VALIDATE`, entit/DAO a vestavěných služeb |
| 15 | [Vestavěné moduly enginu](15-vestavene-moduly.md) | co je v adresáři enginu `PWE/`: stránky, vzhledy, služby, entity, šablony, assets; co a jak přebít |
| 16 | [Nástroje a ladění](16-nastroje.md) | `make`, `PWE/tools/*`, výběr, sestavení a kouřové kontroly image (`make images`, `make images-check`), `make k8s-*`, `pweCreator`, CGI režim, logy, VS Code debugger |
| 17 | [Nasazení](17-nasazeni.md) | devět image (závislostní `pwe-base`, `pwe-mariadb`, `pwe-mysql`, `pwe-postgres`, `pwe-debugger` a image vzorových webů `pwe-example-*`), přidání knihovny, časové pásmo, registr a tagy (`<verze>` a `latest`), kouřové kontroly, workflow GitHub Actions (Images, Tests, Dependabot; kdo publikuje), image vlastního webu, docker compose, nginx, proměnné prostředí, běh procesu (FastCGI socket, ukončení na `SIGTERM`, migrace při startu), Apache, Kubernetes (`make k8s-*`), produkční checklist, přechod na verzi 2.2.1 |
| 18 | [Testy](18-testy.md) | testy enginu (`make test`, zámek souběžných běhů), psaní testů, test vlastního webu, integrační test přes compose, CI |
| 19 | [Vnitřní fungování enginu](19-engine-internals.md) | pro údržbáře enginu (adresář `PWE/`): vstupní bod, socket a ukončování, loadery, samoléčení, opts, pooling, dbversion a zámek migrace, bezpečnostní pojistky |
| 20 | [Časté problémy a známá omezení](20-faq.md) | diagnostika podle projevu, známá omezení enginu |
| 21 | [Nový web podle zadání](21-novy-web-podle-zadani.md) | postup pro AI asistenta i vývojáře: od zadání k běžícímu webu, mapování požadavků, Definition of Done |
| 22 | [Platební brána ČSOB](22-platebni-brana-csob.md) | napojení ČSOB eAPI v1.9 v PWE: režimy simulator/test/production, klíče, konfigurace `csob.*`, průběh init → process → return → status, stavy, cron, simulátor, přechod do produkce, bezpečnost |

## Rychlý start (zkráceně)

Potřebujete Docker (s `docker compose` a `docker buildx`), `make` a libovolný Perl 5 (stačí jádro,
bez závislostí enginu — spouštějí se jím jen skripty `PWE/tools/*.pl`, které si zbytek odbaví
v kontejnerech z image `ghcr.io/kukam/pwe-*`). Závislosti enginu se na hostitele neinstalují; engine,
testy i kompilace běží vždy v kontejneru. Image mají tag verze enginu (obsah `PWE/VERSION`) a tag
`latest`; když image této verze v registru nejsou, sestaví je `make images`.

```bash
git clone <repozitar> PWE && cd PWE                                           # kořen repozitáře; engine je v jeho podadresáři PWE/
make images                                                                   # jen když image této verze enginu nejsou v ghcr.io/kukam
make new WEB=mujweb.web ARGS='--title "Můj web" --lang CZE,EN --db mariadb'   # kostra webu (bez --db = web bez databáze)
make run WEB=mujweb.web PROFILE=mariadb                                       # http://127.0.0.1:7778/
make module TYPE=page WEB=mujweb.web NAME=kontakt ARGS='--site Default --services UserAccount'
make check WEB=mujweb.web                                                     # konvence, perl -c, smoke requesty
```

Podrobně v [02 — Rychlý start](02-rychly-start.md).

## Slovníček

- **Engine** — adresář [`PWE/`](../PWE/README.md) v kořeni repozitáře (v kontejnerech `/PWE/PWE`):
  `pwe.fcgi`, knihovny `Libs/`, globální šablony, statika (Bootstrap 5.3.8, jQuery 4.0.0,
  Font Awesome 6.4.2, `pwe.js`) a sdílené moduly.
- **core** — není adresář, ale pojem „kořen enginu“ v názvech konfiguračních klíčů a proměnných:
  `pwe.core` / `PWE_CONF_pwe_core` (cesta k adresáři enginu `PWE/`), `pwe.core_pages`, `core_sites`,
  `core_services`, `core_entities` (co si web z enginu bere) a `pwe.require_core` (požadovaná verze
  enginu). Tyto názvy jsou součást kontraktu a píší se přesně takto.
- **Web (webapp)** — adresář `webapps/<nazev>/` s vlastním kódem; engine ho najde přes `PWE_CONF_pwe_home`.
- **Dva kořeny** — `pwe.home` (web, `webapps/<nazev>/`) a `pwe.core` (engine, adresář `PWE/`).
  Vše se hledá nejdřív ve webu, pak v enginu.
- **Page (stránka)** — controller `Pages/<X>/<X>.pm`; volá se `?page=<X>&func=<akce>`.
- **Func (akce)** — metoda stránky registrovaná v `$self->{'func'}`; jen ty jsou volatelné z URL.
- **Site (vzhled)** — `Sites/<X>/<X>.pm`, fasáda nad render vrstvou `Libs::Web`; drží layouty a menu.
- **Service (služba)** — `Services/<X>/<X>.pm`, singleton s business logikou; injektuje se do stránek.
- **Entity** — `Entities/<X>/<X>.pm`, objekt nad jednou DB tabulkou (nad DAO).
- **DAO** — `Libs::MyDBI::DAO`, řádek tabulky s dynamickými gettery/settery podle sloupců.
- **Injektáž** — metoda `Site_<X>` / `Service_<X>` ve stránce; engine do ní předá objekt při startu.
- **Resource bundle (rb)** — texty `rb.tmpl` (výchozí jazyk) a `rb_<LANG>.tmpl` v adresáři modulu.
- **Messenger** — flash zpráva (úspěch/chyba), zobrazí se při dalším vykreslení.
- **opts** — perzistentní data uživatele mezi requesty (soubor, nebo DB session).

## Konvence dokumentace

Texty jsou česky. Názvy souborů, metod a konfiguračních klíčů jsou vždy uvedeny přesně tak,
jak jsou v kódu. Ukázky kódu jsou převzaty z ověřeného tutoriálového webu nebo z enginu.

Cesty jsou uváděny relativně ke kořeni repozitáře: `PWE/…` je adresář enginu (`PWE/pwe.fcgi`,
`PWE/Libs/`, `PWE/tools/`), `webapps/<nazev>/…` je web. Pracovní kopie se po `git clone … PWE`
jmenuje také `PWE`; cesta `PWE/…` v dokumentaci ale vždy znamená adresář enginu uvnitř ní.
V kontejnerech je kořen repozitáře namountovaný do `/PWE`, engine je tam tedy `/PWE/PWE/…`
a weby `/PWE/webapps/<nazev>/…`.

Kód enginu je pod licencí Apache 2.0 ([`../LICENSE`](../LICENSE)).
