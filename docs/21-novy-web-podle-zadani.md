# 21 — Nový web podle zadání (postup pro AI asistenta i vývojáře)

Jak se dostat od zadání („udělej web pro …“) k běžícímu webu nad enginem PWE. Závazná
pravidla pro AI asistenty jsou v [`../AGENTS.md`](../AGENTS.md); tato kapitola je pracovní
postup s kontrolními seznamy. Kompletní příklad výsledku je [12 — Tutoriál](12-tutorial-ukolnicek.md).

## 0. Zásady

- **Engine se nemění.** Adresář enginu `PWE/` (v kořeni repozitáře) zůstává beze změny; chyba
  enginu se opravuje zvlášť (s regresním testem), ne obcházením ve webu. Modul enginu, který
  nevyhovuje, web přebije vlastním modulem stejného jména.
- **Pracuje se jen ve `webapps/<nazev>/`.** Nástroje generují kostru, ručně se píše obsah.
- **Engine běží v kontejneru** (`make …`). Na hostiteli je potřeba Docker s `docker compose`, `make`
  a libovolný Perl 5 (stačí jádro, bez závislostí enginu) — spouštějí se jím jen skripty
  `PWE/tools/*.pl`, které si zbytek odbaví v kontejneru; závislosti enginu se na hostitele neinstalují.
- **Image mají tag podle větve gitu** (`ghcr.io/kukam/pwe-<profil>:<větev>`, nástroje běží
  v `ghcr.io/kukam/pwe-debugger:<větev>`). Když Docker hlásí `pull access denied`,
  `manifest unknown`, u `ghcr.io` také `denied` nebo `403 Forbidden`, image pro aktuální větev
  v registru nejsou: jednou spusť `make images` (sestaví je lokálně), nebo pracuj s image větve
  `master`, jsou-li publikované (`PWE_IMAGE_TAG=master make …`).
  Image se kvůli webu neupravují — knihovna navíc (např. `LWP::UserAgent` = `libwww-perl`; HTTPS
  klient v image je `HTTP::Tiny`) patří do `Dockerfile` webu
  ([17 — Nasazení](17-nasazeni.md#přidání-knihovny)). Vlastní `entrypoint.sh` web nemá (dědí ho
  z image), `WEB` je u `make new` a `make module` povinný.
- **Necommituje se**, pokud o to uživatel výslovně nepožádá.

## 1. Rozbor zadání

Než se něco vygeneruje, rozhodni (a do odpovědi uživateli napiš):

| Otázka | Vede k |
| --- | --- |
| Ukládají se data (záznamy, objednávky, uživatelé, přihlášení)? | **ano** → `--db mariadb` (nebo mysql/postgres); **ne** → web bez DB (`save_opt_to = file`) |
| Jaké stránky (obrazovky) web má? | seznam `Pages/<nazev>` a akce (`func`) každé stránky |
| Jaké jazyky? | `--lang CZE,EN` → `rb.tmpl` + `rb_EN.tmpl` všude |
| Je potřeba přihlášení / role? | `Services/UserAccount` s `login`/`logout` (vzor v tutoriálu), akce s `['admin']` |
| Posílají se e-maily? | `Email` + `MailQueue` z enginu, tabulka `mailqueue`, `pwe.smtp_servers`, cron akce |
| Jaký vzhled? | `Sites/Default/layout_*.html` + `static/css/site.css` (Bootstrap 5.3.8 z enginu) |
| Co má být veřejné a co jen pro správce? | `func` → skupiny, `[% IF group.admin %]` v šablonách |

Název webu: krátký, bez diakritiky, s příponou `.web` (`rezervace.web`).

## 2. Kostra

```bash
make new WEB=rezervace.web ARGS='--title "Rezervace sálu" --lang CZE,EN --db mariadb'
```

Vznikne úvodní stránka, vzhled, služba účtu, konfigurace, migrace (`dbtable`, `session`),
`Dockerfile` (image webu: běh z `pwe-<profil>`, engine z image `pwe`), `README.md`
([03 — Struktura webu](03-struktura-webu.md)). Bez `--db` web bez databáze.
`--examples` zapne ukázkové stránky enginu (do produkce ne).

## 3. Konfigurace

V `conf/web.conf` zkontroluj `http.name/title/keywords/description`, `http.cookie_name` (unikátní),
`http.languages`, `web.email_admin`, `pwe.smtp_servers`, `pwe.development` (1 ve vývoji, **0
v produkci**). Vlastní klíče aplikace patří do sekce `web`. Hesla ne do souborů — `PWE_CONF_*`.

## 4. Databáze

Každá tabulka = nová položka v `conf/<driver>.dbversion` (pro každý podporovaný driver), entita
`make module TYPE=entity WEB=<web> NAME=<Entita> ARGS='--table <tabulka>'`, logika ve službě
`make module TYPE=service WEB=<web> NAME=<Sluzba>`. Sloupce `created`/`updated` v tutoriálovém
tvaru plní entita sama. Vlastní validace sloupce = přepsaný setter v entitě
([09 — Databáze a entity](09-databaze-a-entity.md)).

## 5. Vzhled

`Sites/Default/layout_body.html` — menu (položka pro každou stránku, aktivní podle `idp`),
`<div id="messenger">`, `[% INCLUDE $html_main %]`; `layout_header.html` — title, meta, CSS/JS;
`rb*.tmpl` — texty menu; `static/css/site.css` — styly. Data pro každou stránku (přihlášený
uživatel, košík) do `Sites/Default/Default.pm::getDefaultTemplateValues` ([07](07-vzhled-site.md)).

## 6. Stránky

```bash
make module TYPE=page WEB=rezervace.web NAME=rezervace ARGS='--site Default --services UserAccount,DBTable,Rezervace'
```

Pak v modulu: akce a práva v `func`, validace deklarativně (`defined`, `validate`, `rules`,
`error`), render přes `$WEB`, AJAX podle potřeby; HTML do `main.html` (+ fragmenty), texty do
`rb*.tmpl` pro všechny jazyky ([04](04-stranky.md), [05](05-validace.md), [10](10-ajax.md)).

## 7. Přihlášení

Vygenerovaná `Services/UserAccount` má vývojovou zkratku (každý admin). Pro skutečné přihlášení
použij vzor z tutoriálu (`login`/`logout` nad DB session, sloupec `admin`; stránka `prihlaseni`),
pro více účtů tabulku `users` ([11](11-uzivatele-a-prava.md)).

## 8. Ověření

```bash
make check WEB=rezervace.web                           # VYSLEDEK: bez chyb
make run   WEB=rezervace.web PROFILE=mariadb ARGS=-d   # http://127.0.0.1:7778/
make logs  WEB=rezervace.web PROFILE=mariadb | grep '\[E\]'
curl -s 'http://127.0.0.1:7778/?page=rezervace&func=default' | head
```

Po změně `.pm` → `make restart`. Šablony a `rb*.tmpl` se načítají při requestu.

## 9. Předání

Do `webapps/<nazev>/README.md` doplň, co web dělá, jaké má stránky, jak se spouští a co zbývá.
Uživateli shrň rozhodnutí z kroku 1, seznam stránek, co je hotové a otevřené body (SMTP,
produkční `development => 0`, skutečné účty).

## Mapování požadavků na konstrukce PWE

| Požadavek | Jak v PWE | Kde |
| --- | --- | --- |
| několik statických stránek | web bez DB; `Pages/<x>` s `main.html`; menu v `layout_body.html` | [02](02-rychly-start.md), [07](07-vzhled-site.md) |
| formulář (kontakt, poptávka) | akce s `defined`/`rules`/`error`, messenger; odeslání přes `Email` | [05](05-validace.md), [13 §1, §8](13-cookbook.md) |
| evidence záznamů (seznam, přidání, úprava, smazání) | `--db`; entita + migrace; služba s CRUD; seznam přes `genTable`; AJAX akce | [12](12-tutorial-ukolnicek.md), [09](09-databaze-a-entity.md) |
| přihlášení, role, administrace | `UserAccount::login`, skupiny, `func => ['admin']`, DB session | [11](11-uzivatele-a-prava.md) |
| upload souborů / obrázků | `saveUploadFile`, `pwe.upload_dir`, `Libs::Pics` | [13 §2](13-cookbook.md) |
| vícejazyčný web | `http.languages`, `rb_<LANG>.tmpl`, akce `setlanguage` | [06](06-sablony-a-i18n.md) |
| interaktivita bez reloadu | `ajax_request`, `printAjaxLayout`, `href.tmpl`, `AjaxFormAppender` | [10](10-ajax.md) |
| e-mailové notifikace | `Email` + `MailQueue` + cron akce `sendAllEmail` | [08](08-sluzby.md), [13 §8–9](13-cookbook.md) |
| plánované úlohy | stránka volaná z CLI v CGI režimu | [13 §9](13-cookbook.md) |
| export dat | `type => 'csvdown'`, `file` | [13 §13](13-cookbook.md) |
| více vzhledů / sekcí | další `Sites/<X>` s `--parent`, injektor `Site_X` | [07](07-vzhled-site.md) |
| vlastní chybové stránky | vlastní `Pages/errorPage` nebo `http.layout_error_*` | [13 §10](13-cookbook.md) |
| stav bez databáze (košík) | `setOpts/getOpts` | [11](11-uzivatele-a-prava.md), [13 §11](13-cookbook.md) |

## Kontrolní seznam generovaného kódu

- Adresář = název `.pm` = poslední část balíčku; `rb.tmpl` + `rb_<LANG>.tmpl` pro každý jazyk,
  končí prázdným řádkem; klíče, které šablony používají, existují.
- Žádné `use Libs::…` mimo blok `KOMODO`; závislosti přes konstruktor a `Site_X`/`Service_X`;
  každý injektovaný modul existuje (web nebo `core_*`).
- Validace deklarativně + metoda `error`; parametry přes `$USER->getParam("x", 0, $default)`.
- POST formuláře mají `page`/`func` ve skrytých polích; AJAX formuláře `id` a `AjaxFormAppender`.
- Výstup uživatelských dat přes `| html`.
- Bootstrap 5 markup (`data-bs-*`, `btn-close`, `row/col`, `text-bg-*`), Font Awesome 6 ikony,
  `$(function(){…})`; žádné třídy Bootstrapu 3.
- Komentáře a POD v `.pm` česky bez diakritiky; texty pro uživatele jen v `rb*.tmpl`.
- Před předáním `pwe.development => 0` pro produkci, unikátní `http.cookie_name`, `web.email_admin`.

## Definition of Done

1. `make check WEB=<web>` končí `VYSLEDEK: bez chyb` (varování vyřešena nebo vysvětlena).
2. Každá stránka odpoví 200 na `?page=<x>&func=default`, neznámá stránka 404, chráněné akce 401
   pro nepřihlášené.
3. V logu nejsou `[E]` z běžného procházení (kromě validačních chyb vstupu).
4. Formuláře: validační chyba zobrazí text z `rb` (ne `[msg.…]`), úspěch flash zprávu.
5. Všechny jazyky mají kompletní texty.
6. `make test` a `make compile` stále procházejí (pokud se sahalo do enginu).
7. `README.md` webu popisuje účel, stránky, spuštění a otevřené body.

## Nástroje

Přehled `make` cílů a skriptů enginu `PWE/tools/*` s volbami: [16 — Nástroje a ladění](16-nastroje.md).
Vestavěná stránka `?page=pweCreator` dělá totéž co `make module` z prohlížeče (skupina `admin`).
