# 02 — Rychlý start

Cíl: za několik minut mít běžící vlastní web nad enginem a vědět, kam sáhnout pro další
stránku. Engine, testy i celý stack běží v Dockeru; hostitelským Perlem (stačí jádro, závislosti
enginu se na hostitele neinstalují) se jen spouštějí skripty `PWE/tools/*.pl`.

## Požadavky

- Docker s `docker compose` (v2) a `docker buildx`.
- Závislostní image `ghcr.io/kukam/pwe-<profil>` (`pwe-mariadb`, `pwe-mysql`, `pwe-postgres`; web bez
  databáze běží v `pwe-base`) a `ghcr.io/kukam/pwe-debugger` s tagem **verze enginu** — obsah souboru `PWE/VERSION` v pracovní
  kopii (např. `2.2.1`; každý image má ještě tag `latest`, tagy podle větve gitu neexistují).
  Docker si je stáhne sám z GitHub Container Registry; když image této verze publikované nejsou
  (nebo jsou balíčky soukromé a nejsi přihlášen), sestavíš si je lokálně jedním příkazem
  `make images` — [krok 1](#1-repozitář) to ověří a zařídí. Přehled image, tagů a přihlášení
  k registru: [17 — Nasazení](17-nasazeni.md#image).
- `make`, `git`, `bash`, `curl` a libovolný Perl 5 (`perl`; stačí jádro, bez závislostí enginu).
  Hostitelským Perlem se jen spouštějí skripty `PWE/tools/*.pl` za cíli `make new`, `make module`,
  `make check` a `make smtp-test`: `new-webapp.pl` běží celý na hostiteli, ostatní se při chybějících
  modulech samy spustí znovu v kontejneru. `make test`, `make compile`, `make cgi` a `make run` běží
  v kontejneru vždy.
- Volné porty `7778` (web), `8025` (Mailpit – zachycené e-maily) a `7776`/`7777`/`7775` (databáze podle profilu).

## 1. Repozitář

```bash
git clone <url-repozitare> PWE
cd PWE             # kořen repozitáře; odtud se spouští všechny příkazy této kapitoly
make help          # přehled cílů (test, compile, new, module, check, cgi, smtp-test, run, restart, logs, down, images, images-check) a používaných image

# image PWE této verze: jsou v místním Dockeru? jinak je stáhni; když to nejde, sestav je lokálně
IMAGE="$(bash PWE/tools/lib/images.sh pwe_image pwe-debugger)"     # ghcr.io/kukam/pwe-debugger:<verze z PWE/VERSION>
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker pull "$IMAGE" || make images
```

Poslední řádek lze spustit kdykoli znovu. Když image `pwe-debugger` této verze v místním Dockeru je,
neudělá nic. Jinak ho zkusí stáhnout z registru, a teprve když to nejde — verze tam publikovaná
není, nebo jsou balíčky soukromé a Docker není přihlášen (hlásí `pull access denied`,
`manifest unknown`, u `ghcr.io` také `denied` nebo `403 Forbidden`) — sestaví `make images` všech
devět image lokálně (s tagy `<verze>` a `latest`). Image profilu (`pwe-mariadb`, …) si pak Docker při
`make run` stáhne sám; po `make images` už je v místním Dockeru také. Po každém zvýšení
`PWE/VERSION` (třeba po `git pull`) řádek spusť znovu — nástroje pak berou image s tagem nové verze.

V kořeni repozitáře je adresář enginu `PWE/` (`PWE/pwe.fcgi`, `PWE/Libs/`, `PWE/tools/`),
adresář webů `webapps/` a tato dokumentace `docs/`. Nenech se zmást shodou jmen: po `git clone … PWE`
se jmenuje `PWE` pracovní kopie i engine uvnitř ní; cesty `PWE/…` v dokumentaci jsou vždy relativní
ke kořeni repozitáře a míří do enginu.

## 2. Kostra webu

```bash
make new WEB=mujweb.web ARGS='--title "Můj web" --lang CZE,EN --db mariadb'
```

Vznikne `webapps/mujweb.web/` — úvodní stránka, vzhled s menu, služba účtu, konfigurace,
migrace databáze (tabulky `dbtable` a `session`), `Dockerfile`, `README.md`. Bez `--db`
vznikne web bez databáze (stav uživatele se ukládá do souborů). Volby:

| Volba | Význam |
| --- | --- |
| `--db mariadb\|mysql\|postgres` | web s databází (bez volby: bez DB) |
| `--title "…"` | název webu (titulek, `http.title`) |
| `--lang CZE,EN` | jazyky; první je výchozí |
| `--examples` | zapne ukázkové stránky enginu (`formExamples`, `ajaxExamples`, `responsive`) a přidá je do menu |
| `--dir <cesta>` | jiný adresář než `webapps/` |
| `--force` | přepíše existující soubory |

Název webu je konvenčně krátký, bez diakritiky, s příponou `.web`. `WEB` je u `make new` (a `make module`)
povinný — bez něj `make` skončí chybou `Zadej web vyslovne …`, protože výchozí `example-db.web` je
vzorový web jen ke čtení. Znak dolaru se v `ARGS` píše zdvojeně (`$$`).

## 3. Spuštění

```bash
make run WEB=mujweb.web PROFILE=mariadb      # PROFILE=static pro web bez DB; ARGS=-d pro běh na pozadí
```

Otevři <http://127.0.0.1:7778/>. Stack tvoří nginx (statika + FastCGI), tři procesy enginu
a databáze. Repozitář je namountovaný do kontejnerů (do `/PWE`, engine je tam `/PWE/PWE`, web
`/PWE/webapps/mujweb.web`), takže běží aktuální pracovní kopie enginu i webu — image
`pwe-<profil>` (u profilu `static` `pwe-base`) dodává jen Perl, knihovny a DB ovladač; kód enginu ani
žádný web v něm není. `make run` na začátku vypíše,
s jakým registrem, tagem a image stack spouští (`[run-webapp] web=… profil=… registr=… tag=… image=…`), a upozorní,
když image v místním Dockeru nejsou. Chyba stažení image při startu (`pull access denied`,
`manifest unknown`, u `ghcr.io` také `denied` nebo `403 Forbidden`) znamená, že image této verze
nejsou ani v registru: vrať se ke [kroku 1](#1-repozitář) (`make images`), případně použij naposledy
publikované image (`PWE_IMAGE_TAG=latest make run …`). Profil musí odpovídat webu:
překlep (`PROFILE=Mariadb`) `make run` odmítne, web bez databáze s databázovým profilem (nebo naopak)
poběží, ale s varováním `[run-webapp] POZOR` — web bez databáze spouštěj s `PROFILE=static`.

| Příkaz | Kdy |
| --- | --- |
| `make restart WEB=mujweb.web PROFILE=mariadb` | po změně `.pm` souboru (šablony a `rb*.tmpl` se načítají za běhu) |
| `make logs WEB=mujweb.web PROFILE=mariadb` | log enginu; chyby mají `[E]` |
| `make down WEB=mujweb.web PROFILE=mariadb` | zastavit (`ARGS=-v` smaže i databázi webu) |

## 4. První vlastní stránka

```bash
make module TYPE=page WEB=mujweb.web NAME=kontakt ARGS='--site Default --services UserAccount'
```

Vznikne `Pages/kontakt/` s `kontakt.pm`, `main.html`, `msg.html`, `rb.tmpl` a `rb_EN.tmpl`.
Uprav:

1. `Pages/kontakt/main.html` — HTML stránky (Template Toolkit, texty přes `[% rb.klic %]`).
2. `Pages/kontakt/rb.tmpl` a `rb_EN.tmpl` — texty v obou jazycích (soubor musí končit prázdným řádkem).
3. `Sites/Default/layout_body.html` — položka menu:
   ```html
   <li class="nav-item"><a class="nav-link[% IF idp == "kontakt" %] active[% END %]" href="[% script_name %]?page=kontakt&func=default">[% rb.menu_kontakt %]</a></li>
   ```
   a text `rb.menu_kontakt` do `Sites/Default/rb*.tmpl`.
4. `make restart …` a otevři `http://127.0.0.1:7778/?page=kontakt&func=default`.

Modul stránky vypadá takto (to je celý kontrakt; detail v [04 — Stránky](04-stranky.md)):

```perl
package Pages::kontakt::kontakt;

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

sub new {
    my ($class, $self, $conf, $log, $validate, $dbi, $entities, $user, $web) = @_;

    $DBI = $dbi; $LOG = $log; $CONF = $conf; $USER = $user;
    $WEB = $web; $VALIDATE = $validate; $ENTITIES = $entities;

    $self->{'func'}->{'default'} = [];          # ?page=kontakt&func=default, přístup pro všechny

    bless $self, $class;
    return $self;
}

sub Site_Default {                              # engine sem vloží vzhled webu (render API)
    my ($self, $input) = @_;
    $WEB = $input;
}

sub Service_UserAccount {                       # engine sem vloží službu účtu (nahrazuje $USER)
    my ($self, $input) = @_;
    $USER = $input;
}

# KOMODO-IDE/KOMODO-EDIT: mrtvý kód jen pro IDE (napovídání typů), nikdy se nevolá
sub KOMODO {
    return;
    require Libs::Config; require Libs::Log; require Libs::Validate; require Libs::DBI;
    require Libs::Entities; require Services::UserAccount::UserAccount; require Sites::Default::Default;
    $CONF = new Libs::Config; $LOG = new Libs::Log; $VALIDATE = new Libs::Validate; $DBI = new Libs::DBI;
    $ENTITIES = new Libs::Entities; $USER = new Services::UserAccount::UserAccount; $WEB = new Sites::Default::Default;
}

sub default {
    my $self = shift;
    $WEB->setIDP("kontakt");                                   # id stránky pro šablony (aktivní menu)
    $WEB->printHttpHeader();                                   # HTTP hlavička
    $WEB->printHtmlHeader();                                   # <html><head>…
    $WEB->printHtmlLayout(html_main => "Pages/kontakt/main.html");   # <body> z layoutu vzhledu + tvoje HTML
}

1;
```

## 5. Kontrola

```bash
make check WEB=mujweb.web                                   # struktura, konvence názvů, rb soubory, perl -c, smoke requesty
make cgi WEB=mujweb.web Q='page=kontakt&func=default'       # jeden request bez serveru, HTTP hlavičky + HTML, log na STDERR
```

`make check` končí `VYSLEDEK: bez chyb` a návratovým kódem 0, jinak vypíše `FAIL` řádky.
U webu s databází se smoke requesty přeskakují (ověř je přes běžící stack a `curl`).

## 6. Co dál

| Potřebuji | Kapitola |
| --- | --- |
| formulář s validací a flash zprávou | [05 — Validace](05-validace.md), [13 — Cookbook §1](13-cookbook.md) |
| vlastní tabulku v databázi a práci s ní | [09 — Databáze a entity](09-databaze-a-entity.md) |
| upravit vzhled, menu, CSS | [07 — Vzhled](07-vzhled-site.md) |
| přihlášení a práva | [11 — Uživatelé a práva](11-uzivatele-a-prava.md) |
| vidět vše pohromadě na reálném webu | [12 — Tutoriál: Úkolníček](12-tutorial-ukolnicek.md) |
| nasadit | [17 — Nasazení](17-nasazeni.md) |

## Ruční běh bez `make`

`make` jen volá skripty enginu v `PWE/tools/`; totéž lze spustit přímo z kořene repozitáře:

```bash
PWE/tools/new-webapp.pl mujweb.web --title "Můj web" --lang CZE,EN --db mariadb
PWE/tools/new-module.pl page mujweb.web kontakt --site Default --services UserAccount
PWE/tools/check-webapp.pl mujweb.web
PWE/tools/run-webapp.sh mujweb.web mariadb up -d
PWE/tools/pwe-cgi.sh mujweb.web 'page=kontakt&func=default'
```

Skripty, které potřebují Perl závislosti enginu (`Template`, `CGI::Fast`), se mimo kontejner
samy spustí znovu v kontejneru z image `ghcr.io/kukam/pwe-debugger:<verze>`
([16 — Nástroje](16-nastroje.md#výběr-image)).
