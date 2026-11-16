# PWE/ — engine PWE (Perl Web Engine)

Adresář `PWE/` v kořeni repozitáře je **engine** — a jen engine: vstupní bod `pwe.fcgi` (a `debug.cgi`, tentýž kód pod jiným jménem pro ladění ve VS Code), jádro `Libs/`,
globální šablony `templates/`, statika `assets/` (Bootstrap 5.3.8, jQuery 4.0.0, Font Awesome 6.4.2, `pwe.js`)
a sdílené moduly `Pages/`, `Sites/`, `Services/`, `Entities/`, které si weby zapínají v `conf/web.conf`
(`pwe.core_*`). Verze je v `VERSION`; weby ji vyžadují přes `pwe.require_core`.

Kořen repozitáře se jmenuje také PWE, proto pozor na cesty:

| Kde | Cesta k enginu | Příklad |
|-----|----------------|---------|
| hostitel (relativně ke kořeni repozitáře) | `PWE/` | `PWE/pwe.fcgi`, `PWE/tools/run-tests.sh`, `PWE/t/` |
| kontejner ze závislostního image `ghcr.io/kukam/pwe-*` (repozitář je namountovaný do `/PWE`) a image webu včetně image vzorových webů `pwe-example-*` (engine zkopírovaný při sestavení) | `/PWE/PWE/` | `perl /PWE/PWE/pwe.fcgi`, `PWE_CONF_pwe_core=/PWE/PWE` |

Ve verzích 1.0.0–2.1.0 se adresář jmenoval `core/`; přejmenování na `PWE/` a postup pro existující
weby a nasazení popisuje [`CHANGELOG.md`](CHANGELOG.md) u verze 2.2.0. Slovo „core“ zůstalo jen v názvech kontraktu —
konfigurační klíče `pwe.core`, `pwe.core_pages`, `pwe.core_sites`, `pwe.core_services`,
`pwe.core_entities`, `pwe.require_core`, proměnná prostředí `PWE_CONF_pwe_core`, metody
`getCore()`/`coreVersion()` — kde znamená „kořen enginu“, ne název adresáře.

Engine se **neupravuje kvůli jednomu webu**. Weby žijí ve [`../webapps/`](../webapps/README.md)
a berou si engine přes `PWE_CONF_pwe_home` (web) + `PWE_CONF_pwe_core` (tento adresář);
moduly, šablony, resource bundly i statika se hledají nejdřív ve webu, pak tady.

Cesty v následujících tabulkách jsou relativní k tomuto adresáři (`tools/` = `PWE/tools/` v repozitáři).

| Co | Kde |
|----|-----|
| veřejné API pro stránky (kontrakt) | [`../docs/04-stranky.md`](../docs/04-stranky.md), [`../docs/14-api-reference.md`](../docs/14-api-reference.md), POD v `Libs/*.pm` |
| sdílené stránky | `Pages/css`, `errorPage`, `systemPage`, `pweCreator` (infrastruktura); `ajaxExamples`, `formExamples`, `responsive` (ukázky) |
| sdílené služby / entity | `Services/Session`, `DBTable`, `Email`, `UserAccount` (ukázka); `Entities/Session`, `DBTable`, `MailQueue` |
| nástroje | `tools/` (`new-webapp.pl`, `new-module.pl`, `check-webapp.pl`, `pwe-cgi.sh`, `run-webapp.sh`, `run-tests.sh`, `perl-compile.sh`, `smtp-test.pl`, `build-images.sh`, `smoke-images.sh`, `k8s.sh`, `lib/images.sh`) — spouštějí se z kořene repozitáře přes `make` (`make help`) nebo přímo jako `PWE/tools/<skript>` |
| testy | `t/` (`make test`; `make compile` = `perl -c` všeho), fixture weby `t/fixtures/app` (jeden kořen: web uvnitř enginu se symlinky) a `t/fixtures/app2` (dva kořeny: web mimo engine), pomocné moduly `t/lib/PWE/` (`TestEnv`, `TestServer` — skutečný FastCGI server pro testy) |
| běh procesu | `pwe.fcgi`: socket z `FCGI_SOCKET_PATH` (`:7779`, `127.0.0.1:7779`, unix socket s právy `FCGI_SOCKET_PERM`, výchozí 0770), pořádané ukončení na `SIGTERM` (rozpracovaný request doběhne, kód 0), migrace schématu při startu se zámkem vázaným na databázové spojení — [`../docs/17-nasazeni.md`](../docs/17-nasazeni.md#běh-procesu-enginu), POD v `pwe.fcgi` a `Libs/MyDBI.pm` |
| image | `docker/Dockerfile` (jeden vícestupňový, stage = image; vše z balíčků Ubuntu, `cpanm` se při sestavení nepoužívá) + `docker/entrypoint.sh` (jediný zdroj vstupního skriptu — stage `base` ho instaluje a dědí ho všechny image včetně image webu; web vlastní kopii nemá) → pět **závislostních image** v registru `ghcr.io/kukam`, všechny bez kódu enginu a bez webu: `pwe-base` (jen běhové knihovny a `tzdata`; základ image webu bez databáze), `pwe-mariadb`, `pwe-mysql`, `pwe-postgres` (základ + DB ovladač; základ image webu s databází) a `pwe-debugger` (všechny ovladače + ladicí nástroje včetně `curl`). Tento adresář se do image dostává až v **image webu**: `Dockerfile` webu (šablona jen v `tools/new-webapp.pl`, funkce `gen_dockerfile`) ho z kořene repozitáře kopíruje do `/PWE/PWE` bez `t/` a `docker/` — nová položka přímo v tomto adresáři proto znamená doplnit `COPY` do šablony a `Dockerfile` vzorových webů vygenerovat znovu. Stejně vznikají čtyři **image vzorových webů** `pwe-example-static` (`pwe-base` + engine + `../webapps/example.web`) a `pwe-example-mariadb`, `pwe-example-mysql`, `pwe-example-postgres` (`pwe-<profil>` + engine + `../webapps/example-db.web`) — spustitelné ukázky, ne image pro veřejný provoz (každý návštěvník je v nich ve skupině `admin`). Každý z devíti image má právě dva tagy: verzi z `VERSION` a `latest`; tagy podle větve neexistují. Sestavení z kořene repozitáře: `make images` (`tools/build-images.sh`, cíle v `../docker-bake.hcl`), kouřové kontroly `make images-check` (`tools/smoke-images.sh`); publikuje pipeline `../.github/workflows/images.yml` (po testech enginu v `pwe-base` a kouřových kontrolách obou platforem; jen z výchozí větve repozitáře a z větví v proměnné `PUBLISH_BRANCHES`), testy pro změny mimo vstupy image pouští `../.github/workflows/tests.yml`. Oba tagy se přepisují. Podrobně [`../docs/17-nasazeni.md`](../docs/17-nasazeni.md#image) |

## Knihovny třetích stran v `assets/` a `Libs/`

Archivy knihoven se v repozitáři neverzují (adresář archivů `sources/` byl z enginu odstraněn ve verzi 2.0.0);
při aktualizaci stáhni distribuci a nahraď adresář.

| Knihovna | Verze | Kde v enginu | Zdroj |
|----------|-------|--------------|-------|
| Bootstrap | 5.3.8 | `assets/css/bootstrap-5.3.8/` (`bootstrap.css`, `.min.css` + mapy), `assets/javascript/bootstrap-5.3.8/` (`bootstrap.bundle.min.js`, `bootstrap.min.js` + mapy) | https://github.com/twbs/bootstrap/releases/download/v5.3.8/bootstrap-5.3.8-dist.zip |
| jQuery | 4.0.0 | `assets/javascript/jquery-4.0.0/` (`jquery-4.0.0.js`, `.min.js`, `.min.map`) | https://code.jquery.com/jquery-4.0.0.min.js |
| Font Awesome Free | 6.4.2 | `assets/css/fontawesome-free-6.4.2/` (`all.min.css` upravené na cesty `/assets/fonts/...`), `assets/fonts/fontawesome-free-6.4.2/` | https://fontawesome.com/download (Free for Web) |
| Data::Validate | 0.08 | vendorováno jako `Libs/Validate/Data.pm` | https://metacpan.org/dist/Data-Validate |
| Data::Validate::MySQL | 0.03 | vendorováno jako `Libs/Validate/MySQL.pm` | https://metacpan.org/dist/Data-Validate-MySQL |

Změna v enginu = oprava s regresním testem v `t/`, `make test` a `make compile` zelené,
záznam do `CHANGELOG.md`. Změna kontraktu stránky/Site = zvýšení `VERSION`
(major při nekompatibilní změně).
