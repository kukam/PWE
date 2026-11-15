# 16 — Nástroje a ladění

Vývoj běží z kořene repozitáře přes `make`, který volá skripty enginu v `PWE/tools/`. Vše, co
potřebuje Perl závislosti enginu, běží v kontejneru z image `ghcr.io/kukam/pwe-debugger:<větev>`
(skripty se do něj samy spustí znovu, když moduly na hostiteli chybí; jak image vybrat nebo
sestavit, je v oddílu [Výběr image](#výběr-image)).

Cesty `PWE/…` v této kapitole jsou relativní ke kořeni repozitáře: `PWE/` je adresář enginu
(pracovní kopie repozitáře se obvykle jmenuje také `PWE`, proto pozor na záměnu). V kontejneru
je repozitář namountovaný do `/PWE`, engine je tam tedy v `/PWE/PWE` a weby ve `/PWE/webapps/<web>`.

## `make`

```
make help
make new WEB=<web> ARGS='--db mariadb|mysql|postgres --title "..." --lang CZE,EN --examples --dir <cesta> --force'
make module TYPE=page|service|site|entity WEB=<web> NAME=<Nazev> ARGS='...'
make check WEB=<web> [ARGS='--request "page=X&func=Y" --static --verbose']
make cgi WEB=<web> Q='page=X&func=Y' [ARGS='--post DATA --cookie C --script /assets/... --loglevel 4']
make smtp-test WEB=<web> [ARGS='--to vas@email.cz --dry-run --debug']
make run WEB=<web> [PROFILE=static|mariadb|mysql|postgres] [ARGS='-d']
make restart|logs|down WEB=<web> [PROFILE=...] [ARGS='-v']
make test [ARGS='-v t/06-pages.t']
make compile
make images [ARGS='pwe debugger']
make images-check [ARGS='pwe pwe-debugger']
make k8s-image|k8s-template|k8s-deploy|k8s-status|k8s-test|k8s-logs|k8s-delete K8S=<název> [ARGS='...']
```

Proměnné: `WEB` (název adresáře ve `webapps/`, výchozí `example-db.web`), `PROFILE` (databáze; bez
něj se odvodí z `conf/`), `TYPE` (výchozí `page`), `NAME`, `Q` (query string, výchozí
`page=default&func=default`), `ARGS` (další argumenty skriptu), `K8S` (název nasazení do Kubernetes).
**`make new` a `make module` vyžadují `WEB` zadaný výslovně** — na příkazové řádce nebo jako proměnnou
prostředí; jinak skončí ještě před spuštěním nástroje chybou `Zadej web vyslovne: make new
WEB=<nazev>.web (vychozi example-db.web je vzorovy web jen ke cteni)` (zapisují do webu a výchozí
`example-db.web` je vzorový web jen ke čtení). Znak dolaru se v `ARGS` a `Q` píše zdvojeně, jinak ho
`make` rozvine: `ARGS='--title "Cena $$5"'`, `Q='page=x&cena=$$5'`. `make test` spouští `prove`
v adresáři enginu, cesta k testu v `ARGS` je proto relativní k `PWE/` (`t/06-pages.t`, ne
`PWE/t/06-pages.t`). `make help` vypíše přehled cílů a na konci, ve kterých image nástroje a stack
běží a kterými proměnnými se to mění.

## Výběr image

Nástroje (`make test`, `compile`, `check`, `cgi`, `module`, `smtp-test`) běží ve výchozím
stavu v image **`pwe-debugger`** — má všechny tři DB ovladače, takže stejný image poslouží webu
s MariaDB, MySQL i PostgreSQL (`make new` kontejner nepotřebuje, generátor běží na hostiteli).
Stack (`make run`) používá `pwe-<profil>` pro engine a `pwe-debugger`
pro službu `debugger`. Celý název image se skládá ze dvou proměnných prostředí:

| Proměnná | Výchozí | Význam |
| --- | --- | --- |
| `PWE_IMAGE_REGISTRY` | `ghcr.io/kukam` | registr image |
| `PWE_IMAGE_TAG` | aktuální větev gitu převedená na tag (znaky mimo `A–Z a–z 0–9 _ . -` → `-`); bez gitu nebo v odpojeném `HEAD` `master` | tag image; musí to být platný tag (nepřevedený název větve s lomítkem nástroje odmítnou) |
| `PWE_TEST_IMAGE` | `<registr>/pwe-debugger:<tag>` | celý název image nástrojů — úplné přepsání |

```bash
make test                                                 # ghcr.io/kukam/pwe-debugger:<větev>
PWE_IMAGE_TAG=master make check WEB=mujweb.web            # image větve master
PWE_TEST_IMAGE=ghcr.io/kukam/pwe-base:master make test    # libovolný jiný image
```

Funkce pro skládání názvu jsou v `PWE/tools/lib/images.sh` a používají je všechny shellové nástroje.
Perl nástroje mají totéž v `PWE::ToolEnv` (`PWE/tools/lib/PWE/ToolEnv.pm`); že obě implementace
dávají stejný výsledek, hlídají `PWE/t/14-tools.t` a `PWE/t/21-image-tools.t`:

| Funkce (shell) | `PWE::ToolEnv` | Vypíše |
| --- | --- | --- |
| `pwe_image_registry` | `image_registry()` | registr bez koncového lomítka (`PWE_IMAGE_REGISTRY`, jinak `ghcr.io/kukam`) |
| `pwe_image_tag` | `image_tag()` | tag (`PWE_IMAGE_TAG` beze změny, jinak aktuální větev převedená na tag; když větev nejde určit, `master`). Neplatný `PWE_IMAGE_TAG`: hláška na stderr, nic na stdout, kód 2 (Perl: `die` se stejnou hláškou) |
| `pwe_image_branch` | — | aktuální větev gitu; prázdný výstup = nejde určit (bez gitu, odpojený `HEAD`, kopie uvnitř cizího gitu) |
| `pwe_image_tag_valid <tag>` | `image_tag_valid($tag)` | nic; návratový kód 0 = platný tag image (`^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$`) |
| `pwe_image_git_repo` | — | nic; kód 0 = je k dispozici git a kořen repozitáře je kořenem pracovní kopie |
| `pwe_image_tag_sanitize <větev>` | `image_tag_sanitize($vetev)` | název větve převedený na platný tag (znaky mimo `A–Z a–z 0–9 _ . -` → `-`, bez úvodních teček a pomlček, nejvýše 128 znaků, prázdný výsledek = `master`) — stejné pravidlo používá pipeline |
| `pwe_image <název>` | — | celý název, např. `pwe_image pwe-mariadb` → `ghcr.io/kukam/pwe-mariadb:<větev>` |
| `pwe_tool_image` | `docker_image()` | image nástrojů (`PWE_TEST_IMAGE`, jinak `<registr>/pwe-debugger:<tag>`) |
| `pwe_image_missing_hint <image> [nástroj]` | — (interně `_image_missing_note()`) | když image v místním Dockeru není, třířádková rada na stderr (viz níže); vždy kód 0 |

```bash
bash PWE/tools/lib/images.sh pwe_image pwe-debugger                      # z příkazové řádky, Makefile, jiného jazyka
docker pull "$(bash PWE/tools/lib/images.sh pwe_image pwe-mariadb)"
. "$ROOT/PWE/tools/lib/images.sh"; IMAGE="$(pwe_tool_image)"             # uvnitř vlastního bash skriptu
```

Soubor jde načíst (`.`) z **bash i ze zsh** (výchozí shell macOS) — kořen repozitáře si v obou najde
podle vlastního umístění, takže funkce vracejí tag aktuální větve odkudkoli. Spuštěný přímo
(`bash PWE/tools/lib/images.sh <funkce> [argument]`) zavolá jednu funkci; neznámý název vypíše
použití a skončí kódem 2. Tag se z větve odvodí jen tehdy, když je kořen repozitáře zároveň kořenem
pracovní kopie gitu; bez gitu, v odpojeném `HEAD` nebo v repozitáři rozbaleném uvnitř cizího gitu je
to `master`. V kontejneru git není — Perl nástroje si tam tag předávají proměnnou `PWE_IMAGE_TAG`.

Nástroje vypisují, který image použily (`[run-tests] image ghcr.io/kukam/pwe-debugger:pwe.ai`,
`[run-webapp] web=… profil=… registr=… tag=…`), a když v místním Dockeru není, poradí:

```text
[run-tests] image ghcr.io/kukam/pwe-debugger:feature-x neni v lokalnim Dockeru, docker ho zkusi stahnout z registru.
[run-tests]   sestaveni: make images (PWE/tools/build-images.sh)
[run-tests]   mistne dostupne tagy ghcr.io/kukam/pwe-debugger: master pwe.ai (pouziti: PWE_IMAGE_TAG=<tag>)
```

(bez místních tagů `v lokalnim Dockeru neni zadny image <repozitář>`; u `PWE_TEST_IMAGE` rada
`PWE_TEST_IMAGE=<repozitář>:<tag>`). Když tedy image pro aktuální větev v registru nejsou
(Docker hlásí `pull access denied`, `manifest unknown`, u `ghcr.io` také `denied` nebo
`403 Forbidden`), sestav je lokálně, použij tag, který místně máš, nebo přepni na image větve
`master`, jsou-li publikované (`PWE_IMAGE_TAG=master`). Neplatný `PWE_IMAGE_TAG` (např. nepřevedené
`feature/x`) nástroje odmítnou hláškou s radou `bash PWE/tools/lib/images.sh pwe_image_tag_sanitize 'feature/x'`.
Co který image obsahuje: [17 — Nasazení](17-nasazeni.md#image).

## `PWE/tools/build-images.sh` — sestavení image

```
PWE/tools/build-images.sh [--push [--allow-dirty]] [--platform P] [--load] [--no-cache] [--print] [--set K=V] [cíl...]      (make images [ARGS='...'])
```

Sestaví image enginu přes `docker buildx bake -f docker-bake.hcl` z `PWE/docker/Dockerfile`. Cíle:
`base`, `pwe`, `static`, `mariadb`, `mysql`, `postgres`, `debugger` (lze psát i `pwe-base`,
`pwe-mariadb`, …); bez cíle všech sedm. Registr a tag bere z `PWE_IMAGE_REGISTRY` /
`PWE_IMAGE_TAG` (tag tedy podle větve), verzi pro druhý tag image `pwe` z `PWE/VERSION`.

```bash
make images                                   # všech 7 image → ghcr.io/kukam/<image>:<větev> (+ ghcr.io/kukam/pwe:<verze>)
make images ARGS='pwe debugger'               # jen nosič enginu a ladicí image
PWE/tools/build-images.sh --print             # vypíše cíle a tagy, nic nestaví
PWE/tools/build-images.sh --no-cache base     # základ znovu bez mezipaměti (nové verze balíčků)
PWE/tools/build-images.sh --platform linux/amd64 base pwe             # zkušební sestavení pro jinou platformu (nenačte se)
PWE/tools/build-images.sh --push              # publikace ručně, linux/amd64 i linux/arm64 (jinak ji dělá pipeline)
make images ARGS=--help                       # nápověda: cíle, volby, proměnné
```

Bez voleb se image sestaví pro platformu stroje a načtou do místního Dockeru — to stačí pro
`make run` i ostatní nástroje; skript na konci vypíše místní image s tagem větve. S `--platform`
bez `--push` jde jen o ověření, že sestavení projde (výsledek se nenačte, aby nenahradil image pro
platformu stroje; vynutit lze `--load`). `--push` vyžaduje `docker login`, nejde kombinovat
s `--load` a bez `--platform` publikuje `linux/amd64,linux/arm64`. Image `pwe` dostane popisek s časem
sestavení a — jen z čisté pracovní kopie — s commitem.

Pojistky (kód 2, nic se nestaví): `--push` bez `PWE_IMAGE_TAG` v odpojeném `HEAD`, v kopii bez gitu
nebo uvnitř cizího gitu (publikoval by se tag `master`), z větve, jejíž název se na `master` teprve
převede, a z pracovní kopie s necommitnutými změnami (obejití: `--allow-dirty`); tag tvaru verze
`X.Y.Z` (z `PWE_IMAGE_TAG` i z názvu větve) vždy, i bez `--push`; `--platform` a `--set` bez hodnoty;
neplatný registr v `PWE_IMAGE_REGISTRY`/`PWE_IMAGE_REGISTRIES`. S `--print` pojistky `--push` jen
varují. Publikaci do `ghcr.io/kukam` běžně dělá pipeline GitHub Actions (`.github/workflows/images.yml`).
Tabulka voleb, proměnné `PWE_IMAGE_REGISTRIES` a `PWE_IMAGE_SOURCE`, popisky image a pipeline:
[17 — Nasazení](17-nasazeni.md#lokální-sestavení).

## `PWE/tools/smoke-images.sh` — kouřové kontroly image

```
PWE/tools/smoke-images.sh [--platform P] [--pull never|always] [image...]      (make images-check [ARGS='...'])
```

Ověří, že každý image obsahuje to, co má (moduly a programy základu, ovladače profilu, kód enginu
v `pwe` shodný s pracovní kopií `PWE/`, ladicí nástroje v `pwe-debugger`), a nic, co mít nemá (kód
enginu mimo `pwe`, DB ovladače v `pwe-base` a `pwe-static`). Bez jmen kontroluje všech sedm image;
jména lze psát i zkráceně (`base`, `mariadb`, `debugger`). Registr a tag bere z `PWE_IMAGE_REGISTRY`
a `PWE_IMAGE_TAG` (výchozí větev gitu). Tentýž skript pouští pipeline před publikací pro obě platformy.

```bash
make images && make images-check                          # po sestavení: všech 7 image z místního Dockeru
make images-check ARGS='pwe debugger'                     # jen vybrané
PWE/tools/smoke-images.sh --platform linux/arm64          # image jiné platformy (v emulaci QEMU)
PWE_IMAGE_TAG=master PWE/tools/smoke-images.sh --pull always   # publikovaný image (nahradí místní pod stejným tagem)
```

Výchozí `--pull never` nikdy nic nestahuje — chybějící image je `FAIL`. Výstup: řádky
`OK   <image>: <popis>` / `FAIL <image>: <popis>` s odsazeným důvodem; kód 0 = vše prošlo,
1 = něco selhalo, 2 = špatné použití. Kontrola souborů enginu selže i tehdy, když je místní image
`pwe` starší než pracovní kopie (`make images ARGS=pwe`). Seznam kontrol:
[17 — Nasazení](17-nasazeni.md#kouřové-kontroly-image).

## `PWE/tools/new-webapp.pl` — kostra webu

```
PWE/tools/new-webapp.pl <nazev> [--db none|mariadb|mysql|postgres] [--title "Nazev"] [--lang CZE,EN] [--examples] [--dir <cesta>] [--force]
```

Vytvoří `webapps/<nazev>/` (viz [03 — Struktura webu](03-struktura-webu.md)): `Pages/default`
(úvodní stránka + `setlanguage`), `Sites/Default` (layouty s Bootstrapem 5.3.8, menu, messenger),
`Services/UserAccount` (účet a skupiny nad `Session`), `conf/web.conf` s `require_core` a
`core_*`, DB konfigurace a migrace (`dbtable`, `session`) při `--db` (a symlink `conf/database.conf`
na zvolený profil), `static/css/site.css`, `Dockerfile`, `.htaccess`, `robots.txt`, `vars`,
`README.md`, dočasné adresáře. Vlastní `entrypoint.sh` web nemá — image webu ho dědí z běhového
image ([17 — Nasazení](17-nasazeni.md#image-vlastního-webu)). Potřebuje jen základní Perl (běží
i na hostiteli). Přes `make new` je `WEB` povinný (viz výše).

## `PWE/tools/new-module.pl` — kostra modulu

```
PWE/tools/new-module.pl page    <web> <Nazev> [--site Default] [--services A,B]
PWE/tools/new-module.pl service <web> <Nazev> [--services A,B]
PWE/tools/new-module.pl site    <web> <Nazev> [--parent Default] [--services A,B]
PWE/tools/new-module.pl entity  <web> <Nazev> --table <tabulka> [--dbid db1]
                                  [--force]
```

Renderuje šablony `PWE/Pages/pweCreator/{page,service,site,entity}.tmpl` — tytéž, které používá
stránka `pweCreator` v prohlížeči. Ke stránce vytvoří `main.html`, `msg.html` a `rb*.tmpl` pro
všechny jazyky z `http.languages`; k službě a vzhledu `rb*.tmpl`; vzhled dostane proxy metody na
rodičovský vzhled (`--parent`) nebo na `Libs::Web`. Po vytvoření modulu je nutný restart enginu
(`make restart`).

## `PWE/tools/check-webapp.pl` — kontrola webu

```
PWE/tools/check-webapp.pl <web> [--static] [--request 'page=X&func=Y'] [--verbose]
```

| Kontrola | Co hlídá |
| --- | --- |
| struktura | `conf/web.conf`, adresáře modulů, žádné symlinky na engine |
| konfigurace | načtení `web.conf`, `http.languages`, existence `pwe.default_page`, `require_core` vs `PWE/VERSION`, názvy v `core_*` existují v enginu, `save_opt_to = db` jen s DB a službou `Session` |
| moduly | `<Dir>/<X>/<X>.pm`, správný `package`, blok `KOMODO`, registrace `func`, injektory `Site_*`/`Service_*` ukazují na existující moduly (web nebo `core_*`), žádné `use Libs::…` |
| rb soubory | `rb.tmpl` + `rb_<LANG>.tmpl` pro každý jazyk, koncový prázdný řádek |
| `perl -c` | všechny vlastní moduly (přeskočí `--static`) |
| smoke | výchozí stránka 200 + HTML, neznámá stránka 404, každá vlastní stránka s akcí `default` nesmí vrátit 500 (přeskočí `--static`; u webu s DB se přeskakuje — použij běžící stack) |

Výpis `OK`/`WARN`/`FAIL`, návratový kód 1 při jakémkoli `FAIL`. `--request` přidá vlastní smoke
request.

## `PWE/tools/pwe-cgi.sh` — jeden request bez serveru

```
PWE/tools/pwe-cgi.sh <web> ['page=X&func=Y'] [--post DATA] [--cookie C] [--script S] [--loglevel N]
```

Spustí engine v **CGI režimu** (bez FastCGI socketu obslouží jeden request z prostředí a skončí)
v kontejneru; vypíše HTTP hlavičky a tělo, log enginu jde na STDERR. Když běží compose stack
projektu `pwe` **téhož webu**, kontejner se připojí k jeho síti (`pwe_default`) a dostane přihlášení
k databázi (`DB_NAME`/`DB_USER`/`DB_USER_PASSWORD`, výchozí `pwe`/`pwe`/`pwe`), takže funguje i web
s databází. Který web stack spustil, pozná skript z pracovního adresáře služby `fcgi` (nebo
`debugger`). Běží-li stack **jiného** webu, k jeho síti ani databázi se nepřipojí — engine by do cizí
databáze zapsal migrace tohoto webu:

- web s `conf/database.conf` (používá databázi) skončí kódem 2:
  `[pwe-cgi] bezi stack webu <jiný>, ne <web> - k jeho siti a databazi se nepripojuji (…). Web <web> pouziva databazi (conf/database.conf), spust jeho stack: make run WEB=<web>`;
- web bez databáze proběhne bez sítě stacku s upozorněním `[pwe-cgi]`.

Když síť existuje, ale služba `fcgi` ani `debugger` neběží, request proběhne bez sítě s upozorněním.
Každá volba vyžaduje hodnotu (i prázdnou: `--post ''`); volba bez hodnoty skončí kódem 2
(`Volba --post vyzaduje hodnotu …`). Příklady:

```bash
PWE/tools/pwe-cgi.sh ukoly.web 'page=ukoly&func=default' --loglevel 4
PWE/tools/pwe-cgi.sh ukoly.web --post 'page=prihlaseni&func=login&login=admin&password=x'   # POST: page/func v těle
PWE/tools/pwe-cgi.sh ukoly.web --script /assets/javascript/pwe.js                            # statický soubor
PWE/tools/pwe-cgi.sh ukoly.web 'page=ukoly' --cookie 'PWE-UKOLY-WEB=C0...'                    # s existující session
```

Ručně uvnitř kontejneru (např. `docker compose exec fcgi bash`):

```bash
cd /PWE/webapps/<web> && . vars
QUERY_STRING='page=default&func=default' perl /PWE/PWE/pwe.fcgi
```

## `PWE/tools/smtp-test.pl` — testovací e-mail

```bash
make smtp-test WEB=mujweb.web ARGS='--to vas@email.cz'            # odešle jeden testovací e-mail
PWE/tools/smtp-test.pl mujweb.web --dry-run                       # jen vypíše výsledné SMTP nastavení
PWE/tools/smtp-test.pl mujweb.web --to x@y.cz --debug             # SMTP dialog na STDERR (obsahuje AUTH!)
docker compose exec fcgi perl /PWE/PWE/tools/smtp-test.pl /PWE/webapps/mujweb.web   # uvnitř stacku (dosáhne na mailpit)
```

Načte konfiguraci webu přesně jako engine (`Libs::Config` včetně `PWE_CONF_*`), navíc proměnné ze
souboru `--env-file` (výchozí `webapps/<web>/conf/local.env`, stejný soubor čte compose), vypíše
`host/port/ssl/starttls/authid` (heslo maskované), odesílatele a příjemce a pošle krátký e-mail přes
`Libs::Send`. Odesílatel: `--from`, jinak `web.email_from`, `web.company_email`, `web.email_admin`;
příjemce `--to`, jinak `web.email_admin`. Návratový kód 1 při chybě (spojení, TLS, AUTH, odmítnutí).
Mimo kontejner se spustí v image nástrojů (`pwe-debugger`), takže SMTP server musí být dosažitelný z Dockeru; vývojový
`mailpit` z compose sítě odtud dostupný není — pro něj použijte variantu `docker compose exec`.

## `PWE/tools/run-webapp.sh` — spuštění přes docker compose

```
PWE/tools/run-webapp.sh <web> [static|mariadb|mysql|postgres] [compose příkaz a argumenty]
```

Nastaví `PWE_WEBAPP`, `COMPOSE_PROFILES`, `PWE_IMAGE_REGISTRY` a `PWE_IMAGE_TAG` (tag podle větve,
viz [Výběr image](#výběr-image)) a spustí `docker compose` (výchozí `up --remove-orphans`). Co
spouští, vypíše na standardní chybový výstup:

```text
[run-webapp] web=mujweb.web profil=mariadb registr=ghcr.io/kukam tag=pwe.ai -> docker compose up --remove-orphans
```

První argument za webem musí být profil (`static`, `mariadb`, `mysql`, `postgres`), příkaz
`docker compose` (`up`, `down`, `logs`, `restart`, `ps`, `config`, `exec`, …) nebo globální volba
compose začínající pomlčkou; cokoli jiného — typicky překlep v profilu (`PROFILE=oracle`,
`PROFILE=Mariadb`) — skončí chybou `Neznamy profil nebo prikaz '<x>' (profily: static | mariadb |
mysql | postgres; …)`, kód 2, místo aby se předalo `docker compose` jako příkaz. Profil bez udání se
odvodí z `conf/database.conf` (symlink) nebo z existence `conf/<driver>.conf`, jinak `static`.

U příkazů, které vytvářejí kontejnery (`up`, `run`, `create`), navíc:

- upozorní, když image `pwe-<profil>` nebo `pwe-debugger` v místním Dockeru není (třířádková rada
  z [Výběru image](#výběr-image));
- varuje, když profil neodpovídá webu:
  `[run-webapp] POZOR: web <web> ma conf/mariadb.conf, ale profil je static - pobezi bez databaze …`,
  resp. `[run-webapp] POZOR: web <web> nema conf/<profil>.conf, ale profil je <profil> - databaze se spusti, web ji ale nepouzije …`.

Přímé `docker compose up` bez těchto proměnných bere tag `master`.
Web běží na <http://127.0.0.1:7778/> (nginx → 3× fcgi z image `pwe-<profil>`). Repozitář je
namountovaný do `/PWE`, takže běží pracovní kopie enginu i webu. Databáze, uploady a session mají
volume pojmenované podle webu (`pwe_mariadb_<web>`), weby si tedy data nesdílejí.

| Příkaz | Účel |
| --- | --- |
| `up -d` | start na pozadí |
| `restart fcgi` | po změně `.pm` (moduly se načítají při startu) |
| `logs -f fcgi` | log enginu (`[E]` = chyba) |
| `exec fcgi bash` | shell v kontejneru enginu |
| `down`, `down -v` | zastavit; `-v` smaže i DB a uploady webu |

Po změně `conf/*.dbversion` stačí restart (migrace doběhnou při startu), po změně `web.conf`
také restart.

## `PWE/tools/run-tests.sh`, `perl-compile.sh`

Testy a kompilace enginu v kontejneru — [18 — Testy](18-testy.md). `run-tests.sh` (`make test`)
drží po dobu běhu zámek pracovní kopie `PWE/t/.run-tests.lock`; druhý běh nad stejnou kopií počká
(nejvýš `PWE_TEST_LOCK_WAIT` sekund, výchozí 600) — podrobně
[18 — Testy](18-testy.md#souběžné-běhy-zámek-pracovní-kopie). `perl-compile.sh` zámek nepoužívá.

## `PWE/tools/k8s.sh` — nasazení do Kubernetes

```
PWE/tools/k8s.sh image|template|deploy|status|test|logs|delete <název> [argumenty pro helm]      (make k8s-<příkaz> K8S=<název> [ARGS='...'])
```

Sestaví image webu a nasadí ho chartem `nxs-universal-chart` podle `kubernetes/values-<název>.yml`
(vzorová nasazení `static` a `generic`). Cílový cluster určuje **povinný `KUBE_CONTEXT`** — skript
nikdy nepoužije aktuální kontext `kubectl` a každému příkazu ho předává výslovně. Nastavení
(`KUBE_CONTEXT`, `K8S_*`) bere z proměnných prostředí, jinak z `kubernetes/local.env` (není v gitu).
Přehled: [17 — Nasazení](17-nasazeni.md#kubernetes), postup a řešení potíží:
[`kubernetes/README.md`](../kubernetes/README.md).

## `pweCreator` — generátor v prohlížeči

`?page=pweCreator&func=default` (jen skupina `admin`; v tutoriálu po přihlášení). Formuláře
pro stránku (s výběrem vzhledu a služeb), službu, vzhled (s rodičem) a entitu (výběr tabulky
z DAO mapy). Soubory zapisuje přímo do adresáře webu; po vytvoření je nutný restart enginu.

## Ladění

### Log

`log.loglevel` 4 a `logout => "STDERR"` ve vývoji (compose nastavuje `PWE_CONF_log_loglevel=3`
v `docker-compose/docker-compose_common.env`); `make logs` nebo `docker compose logs fcgi`. Užitečné řádky:

| Řádek | Význam |
| --- | --- |
| `Page printed : PID:… page:… func:… result:'200, OK'` | každý obsloužený request |
| `[E] … Not-defined input parameter` / `Invalid rule` / `Invalid input parameter` | validační chyba vstupu (ne chyba enginu) |
| `[E] … Registred service object X not exist!` | stránka injektuje neexistující službu/vzhled → není načtena |
| `[E] … Unknown DAO MAP dbid:db1, table:x` | entita nad neexistující tabulkou (chybí migrace) |
| `PAGE : x [ CRASHED ]` + traceback | pád metody stránky (500); e-mail report |
| `Couldn't load any row (CREATE NEW EMPTY ROW)` | `[I]` při „načti nebo založ“ — normální |
| `/* DB:db1 Soubor line N */ SELECT …` | SQL s místem volání (loglevel ≥ 3) |

### DataDump

Ve vývojovém režimu (`pwe.development = 1`) má vygenerovaný layout v menu odkaz **DataDump**
— modal s výpisem všech proměnných šablony (`templates/DumpData.tmpl`). AJAX odpovědi `pwe.js`
zapisuje do téhož elementu `#DATA_DUMPER`.

### Měření času

`log.log_delay => 1`, `log_delay_minimum => 0.01`: engine loguje `[d]` řádky s dobou trvání
šablon, SQL dotazů a dalších úseků; vlastní měření `$LOG->delay("klic")` … `$LOG->delay("klic", "popis")`.

### Debugger ve VS Code

Rozšíření „Perl – Language Server and Debugger for Perl“ (Gerald Richter, `richterger.perl`) spouští
jazykový server i debugger **v kontejneru** `pwe-debugger-1` (služba `debugger` v compose, čeká na
`sleep infinity`). Kontejner běží z image **`pwe-debugger`** — jediného, který obsahuje
`Perl::LanguageServer` (z balíčku Ubuntu `libperl-languageserver-perl`, verze 2.6.2 — odpovídá
rozšíření 2.6.2; sestavení image hlídá, že neklesne níž), `perlcritic`, `perltidy`,
`perldoc`, `cpanm`, klienty databází (`mariadb`, `psql`), síťové nástroje a `cgi-fcgi`; image
`pwe-<profil>`, ve kterých běží procesy `fcgi`, ladicí nástroje nemají. Hostitelský Perl nemá
závislosti enginu ani modul `Perl::LanguageServer` — bez tohoto nastavení rozšíření končí chybou
`Can't locate Perl/LanguageServer.pm in @INC`.

```jsonc
// .vscode/settings.json  (složka .vscode není v gitu)
{
  "perl.containerCmd": "docker", "perl.containerMode": "exec", "perl.containerName": "pwe-debugger-1",
  // [cesta v kontejneru, lokální kořen repozitáře] – absolutní cesta navazuje na file:// (celkem tři lomítka)
  "perl.pathMap": [["file:///PWE", "file:///Users/ja/prace/PWE"]],
  "perl.perlInc": ["/usr/share/perl5", "/PWE/PWE"],                            // cesty v kontejneru
  "perl.fileFilter": [".pm", ".pl", ".cgi", ".fcgi", ".t"],                    // s tečkou, jinak „pl“ zabere i *.tmpl
  "perl.ignoreDirs": [".vscode", ".git", "webapps-example", "assets", "ramdisk", "sessions", "uploadfile", "log"]
}
// .vscode/launch.json — konfigurace
{
  "type": "perl", "request": "launch", "name": "PWE: ladit web ze spuštěného stacku (/debug.cgi)",
  "program": "${workspaceFolder}/PWE/debug.cgi",
  "stopOnEntry": false, "reloadModules": false,
  "env": { "FCGI_SOCKET_PATH": ":7779" },
  "pathMap": [["file:///PWE", "file:///Users/ja/prace/PWE"]]
}
```

Postup: `make run WEB=<web> PROFILE=<profil> ARGS=-d`, ve VS Code `F5`, v prohlížeči
<http://127.0.0.1:7778/debug.cgi?page=…&func=…>. Nginx směruje `/debug.cgi` do debugger kontejneru
(`upstream pwe_balancer_debug`, port 7779), ostatní URL dál obsluhují běžné procesy `fcgi`. Adresy
kontejnerů nginx sleduje průběžně (`resolve`), takže po jejich znovuvytvoření — třeba `make run` po
`make images` — míří `/debug.cgi` dál do debuggeru a `webproxy` není potřeba restartovat
([17 — Nasazení](17-nasazeni.md#nginx-docker-composedocker-compose_nginxconf)).

- **Laděný skript je `PWE/debug.cgi`, ne `pwe.fcgi`.** Engine bere request jako stránku jen tehdy, když se
  `SCRIPT_FILENAME` shoduje s názvem spuštěného skriptu; `pwe.fcgi` by na `/debug.cgi` hledal statický
  soubor a vrátil chybu. `debug.cgi` načte `pwe.fcgi` přes `require`, takže běží stejný kód, breakpointy
  nastavené v `PWE/pwe.fcgi` zabírají a odkazy na stránkách (`script_name`) vedou zpět na `debug.cgi` —
  celé procházení webu zůstává v laděném procesu.
- **Breakpointy lze přidávat a odebírat i za běhu** a funguje i Pause. Rozšíření při tom posílá laděnému
  procesu signál INT; `debug.cgi` proto pod debuggerem čekání na další request po přerušení zopakuje
  (holý `pwe.fcgi` by v tu chvíli skončil a `/debug.cgi` by vracelo chybu spojení).
- **`reloadModules` nech na `false`.** Moduly PWE drží závislosti v souborových proměnných (`$WEB`, `$USER`, …),
  které plní jen `new()` a injektory; kdyby debugger změněný modul sám znovu načetl, zůstaly by prázdné
  a stránka by skončila chybou 500. Změna `.pm` se projeví po restartu ladění (`Ctrl+Shift+F5`) —
  `make restart` k tomu není potřeba, `F5` spouští nový proces.
- **Ladí se web, se kterým stack běží.** Pracovní adresář, `PWE_CONF_pwe_home` i proměnné z
  `webapps/<web>/conf/local.env` má kontejner z `make run WEB=…`, proto konfigurace neobsahuje název webu
  ani `cwd` (hodnota `cwd` se na rozdíl od `program` přes `pathMap` nepřekládá — musela by to být cesta
  v kontejneru).
- `pathMap` mapuje kořen repozitáře v kontejneru (`/PWE`) na lokální kořen repozitáře, ne na adresář
  enginu: `/PWE/PWE/debug.cgi` odpovídá `<repozitář>/PWE/debug.cgi`.
- Bez běžícího stacku rozšíření ohlásí, že kontejner neexistuje; po `make run` stačí příkaz
  „Developer: Reload Window“. Kdo chce jen kontrolu syntaxe bez stacku, nastaví místo toho
  `"perl.containerMode": "run"` a `"perl.containerArgs": ["run", "--rm", "-i", "-v", "<repozitář>:/PWE", "ghcr.io/kukam/pwe-debugger:master"]`
  (tag podle větve, jejíž image máš; ladění přes `F5` pak nefunguje).
- Ladění ukončuj tlačítkem Stop, až potom zavírej nebo znovu načítej okno. Když jazykový server skončí
  dřív, laděný proces v kontejneru zůstane a další `F5` selže na obsazeném portu
  (`Address already in use`); uklidí ho `docker exec pwe-debugger-1 pkill -f debug.cgi`.
- Při `stopOnEntry: true` se běh zastaví hned na začátku `debug.cgi`.

Bloky `KOMODO` v modulech slouží IDE k napovídání typů globálních proměnných.

### Konvence kódu

- Komentáře a POD v `.pm` česky bez diakritiky (ASCII); `=head1 NAME` na začátku modulu,
  `=head2 B<[Public] nazev($arg)>` / `[Private]` nad každou metodou. Kontrola `podchecker`.
- Image `pwe-debugger` má `perlcritic`, `perltidy` a `perldoc`; ve spuštěném stacku
  `docker exec pwe-debugger-1 perlcritic --severity 5 Pages` (pracovní adresář je adresář webu),
  bez stacku `docker run --rm -v "$PWD":/PWE -w /PWE ghcr.io/kukam/pwe-debugger:master perlcritic --severity 5 webapps/<web>/Pages`
  (tag podle větve, jejíž image máš).
- Texty pro uživatele jen v `rb*.tmpl` (UTF-8 s diakritikou), nikdy v kódu.
- Žádné `use Libs::…` v modulech webu mimo blok `KOMODO`.
- Bootstrap 5 markup, `$(function(){…})` pro inline skripty.
