# PWE — Perl Web Engine

PWE je odlehčený **FastCGI webový engine v Perlu**: routing na stránky a akce, šablony
(Template Toolkit), vícejazyčné texty, deklarativní validace vstupů, databázová vrstva
(MySQL/MariaDB/PostgreSQL s entitami nad tabulkami a migracemi schématu), stránkované tabulky,
AJAX s klientskou knihovnou a životní cyklus modulů, který izoluje pády. Výchozí UI je
Bootstrap 5.3.8, jQuery 4.0.0 a Font Awesome 6.4.2.

Konkrétní web se píše **nad enginem** jako samostatný adresář `webapps/<nazev>/` s vlastním
gitem — obsahuje jen vlastní stránky, vzhled, služby, entity, konfiguraci a statiku; engine
(adresář [`PWE/`](PWE/README.md) v kořeni repozitáře) najde přes proměnné prostředí a v konfiguraci
vyjmenuje, které sdílené moduly používá.
Dokumentace je psána tak, aby podle ní **vývojář i AI asistent napsali web od nuly**.

> **English summary.** PWE is a lightweight Perl FastCGI web engine (routing, Template Toolkit,
> i18n, declarative input validation, DB layer with table entities and schema migrations,
> paginated tables, AJAX, crash isolation). The engine itself lives in the [`PWE/`](PWE/README.md)
> directory of this repository; web applications live in `webapps/<name>/` without any
> engine code and are versioned separately. Container images are built by GitHub Actions and
> published to `ghcr.io/kukam`, tagged by git branch: `pwe-base` (runtime libraries only), `pwe`
> (engine code carrier, also tagged by version), runtime profiles `pwe-static`, `pwe-mariadb`,
> `pwe-mysql`, `pwe-postgres`, and `pwe-debugger` (debugging tools); build them locally with
> `make images`. Documentation (Czech) is in [`docs/`](docs/README.md);
> start with [`docs/02-rychly-start.md`](docs/02-rychly-start.md) and the complete tutorial
> [`docs/12-tutorial-ukolnicek.md`](docs/12-tutorial-ukolnicek.md). License: Apache 2.0.

## Rychlý start

Potřebujete Docker s `docker compose` a `docker buildx`, `make` a libovolný Perl 5 (stačí jádro, bez
závislostí enginu — spouštějí se jím jen skripty `PWE/tools/*.pl`, které si zbytek odbaví v kontejneru).
Závislosti enginu se na hostitele neinstalují. Image enginu si Docker stáhne z `ghcr.io/kukam`
(tag = větev gitu); když pro vaši větev publikované nejsou (nebo jsou balíčky soukromé a nejste
přihlášeni — `docker login ghcr.io`), sestaví je `make images`.

```bash
git clone <url> PWE && cd PWE
make images                                                                   # jen když image pro vaši větev nejsou v registru
make new WEB=mujweb.web ARGS='--title "Můj web" --lang CZE,EN --db mariadb'   # kostra webu (bez --db = bez databáze)
make run WEB=mujweb.web PROFILE=mariadb                                       # http://127.0.0.1:7778/
make module TYPE=page WEB=mujweb.web NAME=kontakt ARGS='--site Default --services UserAccount'
make check WEB=mujweb.web                                                     # konvence, perl -c, smoke requesty
make test && make compile                                                     # testy a kompilace enginu
```

Podrobně: [`docs/02-rychly-start.md`](docs/02-rychly-start.md).

## Dokumentace

| Chci… | Kapitola |
| --- | --- |
| pochopit, jak engine funguje | [01 — Úvod a koncepty](docs/01-uvod.md) |
| rozjet první web | [02 — Rychlý start](docs/02-rychly-start.md) |
| znát soubory webu a konfiguraci | [03 — Struktura webu a konfigurace](docs/03-struktura-webu.md) |
| napsat stránku, validaci, šablony, vzhled, službu, entitu | [04](docs/04-stranky.md) · [05](docs/05-validace.md) · [06](docs/06-sablony-a-i18n.md) · [07](docs/07-vzhled-site.md) · [08](docs/08-sluzby.md) · [09](docs/09-databaze-a-entity.md) · [10 AJAX](docs/10-ajax.md) · [11 uživatelé a práva](docs/11-uzivatele-a-prava.md) |
| vidět celý web pohromadě | [12 — Tutoriál: Úkolníček](docs/12-tutorial-ukolnicek.md) |
| hotové recepty a přesné API | [13 — Cookbook](docs/13-cookbook.md) · [14 — API reference](docs/14-api-reference.md) · [15 — Vestavěné moduly](docs/15-vestavene-moduly.md) |
| nástroje, nasazení, testy | [16 — Nástroje a ladění](docs/16-nastroje.md) · [17 — Nasazení](docs/17-nasazeni.md) · [18 — Testy](docs/18-testy.md) |
| vnitřnosti enginu, problémy | [19 — Vnitřní fungování](docs/19-engine-internals.md) · [20 — Časté problémy](docs/20-faq.md) |
| napsat web podle zadání (AI asistent) | [21 — Nový web podle zadání](docs/21-novy-web-podle-zadani.md), pravidla v [`AGENTS.md`](AGENTS.md) |

Rozcestník všech kapitol: [`docs/README.md`](docs/README.md).

## Struktura repozitáře

| Adresář | Co to je |
| --- | --- |
| [`PWE/`](PWE/README.md) | **engine**: `pwe.fcgi` (+ `debug.cgi` — tentýž engine pro ladění ve VS Code přes nginx `/debug.cgi`), `Libs/`, `templates/`, `assets/`, sdílené `Pages/ Sites/ Services/ Entities/`, `tools/`, `t/`, `VERSION`, `CHANGELOG.md` |
| [`webapps/`](webapps/README.md) | weby postavené nad enginem (vlastní weby jsou mimo tento git: `.gitignore webapps/*`) |
| [`docs/`](docs/README.md) | dokumentace |
| `Makefile`, `docker-compose.yml`, `docker-compose/` | vývojový stack: nginx + 3× engine + databáze (`make run`); v adresáři `docker-compose/` je konfigurace nginx (`docker-compose_nginx.conf`) a proměnné prostředí služeb (`docker-compose_*.env`) |
| [`kubernetes/`](kubernetes/README.md) | nasazení do Kubernetes chartem `nxs-universal-chart` (`make k8s-*`, skript `PWE/tools/k8s.sh`): hodnoty `values-static.yml` (`example.web`) a `values-generic.yml` (`example-db.web` + MariaDB), vzory `secrets-generic.example.yml` a `local.env.example`; cílový cluster jen přes povinný `KUBE_CONTEXT` ([17 — Nasazení](docs/17-nasazeni.md#kubernetes)) |
| `PWE/docker/`, `docker-bake.hcl` | sestavení image: jeden vícestupňový `Dockerfile` + `entrypoint.sh` (vstupní skript všech image, i image webu), cíle a tagy pro `docker buildx bake` (`make images`, kouřové kontroly `make images-check`) |
| `.github/` | GitHub Actions: `workflows/images.yml` (testy enginu, sestavení, kouřové kontroly a publikace image do `ghcr.io/kukam`), `workflows/tests.yml` (jen testy pro změny vzorových webů, compose, `kubernetes/` a `Makefile`), `dependabot.yml` (týdenní aktualizace akcí připnutých na SHA) |
| [`AGENTS.md`](AGENTS.md) | závazná pravidla pro AI asistenty |

Cesty v dokumentaci jsou relativní ke kořeni repozitáře: engine je tedy `PWE/…`, i když se
kořen repozitáře po `git clone` jmenuje také `PWE`. V kontejnerech je repozitář v `/PWE`,
engine proto v `/PWE/PWE/…` a weby v `/PWE/webapps/<nazev>/`.

Engine se neupravuje kvůli jednomu webu; opravy enginu mají regresní test v `PWE/t/` a záznam
v [`PWE/CHANGELOG.md`](PWE/CHANGELOG.md). Verze enginu je v `PWE/VERSION`, web ji vyžaduje
přes `pwe.require_core`. Slovo `core` v názvech konfigurace a API (`pwe.core_pages`,
`pwe.require_core`, `PWE_CONF_pwe_core`, `getCore()`) znamená „kořen enginu“, tedy adresář `PWE/`.

## Image a nasazení

Engine se dodává jako sedm image v registru `ghcr.io/kukam`; všechny vycházejí z `pwe-base`:

| Image | Obsah | Tagy |
| --- | --- | --- |
| `pwe-base` | jen běhové knihovny enginu (Perl, moduly, `sass`, ImageMagick, `tzdata`) — bez kódu enginu, bez DB ovladačů | větev |
| `pwe` | základ + kód enginu v `/PWE/PWE` („nosič“ enginu) | větev a verze (`PWE/VERSION`) |
| `pwe-static`, `pwe-mariadb`, `pwe-mysql`, `pwe-postgres` | základ + DB ovladač profilu (`static` žádný) | větev |
| `pwe-debugger` | základ + všechny DB ovladače + ladicí nástroje (`Perl::LanguageServer`, `Perl::Critic`, klienti DB, …) | větev |

Image staví a publikuje pipeline GitHub Actions (`.github/workflows/images.yml`) při každém `push`,
který mění engine (`PWE/`) nebo definici image, s tagem podle větve; před publikací v čerstvém
`pwe-base` spustí testy enginu a kouřové kontroly všech image pro `linux/amd64` i `linux/arm64`
a publikuje jen běh nad hlavou větve, pull request jen sestaví a otestuje.
Tagy se přepisují (tag verze `pwe:<verze>` publikuje běh z kterékoli větve) a nové balíčky jsou
v `ghcr.io` soukromé, dokud jim vlastník nenastaví viditelnost —
[`docs/17-nasazeni.md`](docs/17-nasazeni.md#registr-a-tagy). Lokálně image sestaví `make images`
a zkontroluje `make images-check`. Image webu vzniká z generovaného `Dockerfile`: běhové prostředí
z `pwe-<profil>` (včetně vstupního skriptu — web vlastní `entrypoint.sh` nemá), engine zkopírovaný
z `pwe` (lze připnout na verzi) a adresář webu. Image běží v UTC; časové pásmo pro požadavky předává
webserver (`fastcgi_param TZ`) nebo `/etc/localtime` kontejneru — samotná proměnná `TZ` nestačí. Podrobnosti, nginx, proměnné prostředí, Kubernetes a produkční checklist:
[`docs/17-nasazeni.md`](docs/17-nasazeni.md); nasazení do Kubernetes (`make k8s-deploy K8S=static`,
vždy s výslovným `KUBE_CONTEXT`): [`kubernetes/README.md`](kubernetes/README.md).
Ladění ve VS Code: [`docs/16-nastroje.md`](docs/16-nastroje.md).

## Licence

Apache License 2.0 — viz [`LICENSE`](LICENSE).
