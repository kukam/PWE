# 16 — Nástroje a ladění

Vývoj běží z kořene repozitáře přes `make`, který volá skripty enginu v `PWE/tools/`. Vše, co
potřebuje Perl závislosti enginu, běží v kontejneru z image `ghcr.io/kukam/pwe-debugger:<verze>`
(tag = verze enginu z `PWE/VERSION`; skripty se do něj samy spustí znovu, když moduly na hostiteli
chybí; jak image vybrat nebo sestavit, je v oddílu [Výběr image](#výběr-image)).

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
make images [ARGS='base debugger']
make images-check [ARGS='pwe-base pwe-example-static']
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
Stack (`make run`) používá pro službu `fcgi` závislostní image profilu (`pwe-<profil>`, u profilu
`static` `pwe-base`) a `pwe-debugger` pro službu `debugger`. Žádný z těchto image kód enginu ani web
neobsahuje — obojí dostává mountem repozitáře do `/PWE`. Každý image má právě dva tagy — `<verze>` (obsah `PWE/VERSION`) a `latest`;
tagy podle větve gitu neexistují. Celý název image se skládá ze dvou proměnných prostředí:

| Proměnná | Výchozí | Význam |
| --- | --- | --- |
| `PWE_IMAGE_REGISTRY` | `ghcr.io/kukam` | registr image |
| `PWE_IMAGE_TAG` | verze enginu z `PWE/VERSION` (na gitu ani na větvi nezávisí) | tag image, typicky `latest` nebo starší verze; musí to být platný tag (hodnotu s lomítkem nástroje odmítnou) |
| `PWE_TEST_IMAGE` | `<registr>/pwe-debugger:<tag>` | celý název image nástrojů — úplné přepsání (tag se pak nezjišťuje ani nekontroluje) |

```bash
make test                                                 # ghcr.io/kukam/pwe-debugger:<verze>
PWE_IMAGE_TAG=latest make check WEB=mujweb.web            # image s tagem latest
PWE_TEST_IMAGE=ghcr.io/kukam/pwe-base:latest make test    # libovolný jiný image
```

Výchozí tag sleduje `PWE/VERSION`: po zvýšení verze image s novým tagem neexistují, dokud je
nesestaví `make images` (nebo nepublikuje pipeline) — do té doby `PWE_IMAGE_TAG=latest` nebo
předchozí verze.

Funkce pro skládání názvu jsou v `PWE/tools/lib/images.sh` a používají je všechny shellové nástroje.
Perl nástroje mají totéž v `PWE::ToolEnv` (`PWE/tools/lib/PWE/ToolEnv.pm`); že obě implementace
dávají stejný výsledek, hlídají `PWE/t/14-tools.t` a `PWE/t/21-image-tools.t`:

| Funkce (shell) | `PWE::ToolEnv` | Vypíše |
| --- | --- | --- |
| `pwe_image_registry` | `image_registry()` | registr bez koncového lomítka (`PWE_IMAGE_REGISTRY`, jinak `ghcr.io/kukam`) |
| `pwe_image_version` | `image_version()` | verze enginu = obsah `PWE/VERSION` bez bílých znaků (např. `2.2.1`); musí mít tvar `X.Y.Z`, jinak hláška na stderr, nic na stdout, kód 2 (Perl: `die` se stejnou hláškou). Git ani větev se nepoužívají |
| `pwe_image_tag` | `image_tag()` | tag (`PWE_IMAGE_TAG` beze změny, jinak `pwe_image_version`). Neplatný `PWE_IMAGE_TAG`: hláška na stderr, nic na stdout, kód 2 (Perl: `die` se stejnou hláškou) |
| `pwe_image_tag_valid <tag>` | `image_tag_valid($tag)` | nic; návratový kód 0 = platný tag image (`^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$`) |
| `pwe_image_git_repo` | — | nic; kód 0 = je k dispozici git a kořen repozitáře je kořenem pracovní kopie (slouží jen `build-images.sh` pro popisek `revision` a kontrolu necommitnutých změn; tag na gitu nezávisí) |
| `pwe_image <název>` | — | celý název, např. `pwe_image pwe-mariadb` → `ghcr.io/kukam/pwe-mariadb:<verze>` |
| `pwe_image_names [deps\|examples\|all]` | `image_names($skupina)` | názvy image PWE bez registru a tagu, jeden na řádek: `deps` = pět závislostních, `examples` = čtyři image vzorových webů, `all` (výchozí) = všech devět v pořadí, v jakém se staví a kontrolují. Cíl sestavení = název bez předpony `pwe-` |
| `pwe_profile_image <profil>` | `profile_image($profil)` | závislostní image profilu: `static` → `pwe-base`, `mariadb`, `mysql`, `postgres` → `pwe-<profil>` (v něm běží služba `fcgi` stacku a vychází z něj image webu); neznámý profil = kód 2 |
| `pwe_tool_image` | `docker_image()` | image nástrojů (`PWE_TEST_IMAGE`, jinak `<registr>/pwe-debugger:<tag>`) |
| `pwe_image_missing_hint <image> [nástroj]` | — (interně `_image_missing_note()`) | když image v místním Dockeru není, třířádková rada na stderr (viz níže); vždy kód 0 |

`PWE::ToolEnv` má navíc `dockerfile_base($profil)` (řádek `FROM` šablony `Dockerfile` webu),
`engine_image_excludes()` (položky `PWE/`, které se do image webu nekopírují: `t`, `docker`)
a `engine_image_entries([$kořen])` (položky enginu, které image webu obsahuje) — používají je generátor
webu a `make check`. Funkce `pwe_image_branch` a `pwe_image_tag_sanitize` (v `PWE::ToolEnv`
`image_tag_sanitize()`) z doby tagů podle větve zanikly.

```bash
bash PWE/tools/lib/images.sh pwe_image pwe-debugger                      # z příkazové řádky, Makefile, jiného jazyka
docker pull "$(bash PWE/tools/lib/images.sh pwe_image pwe-mariadb)"
. "$ROOT/PWE/tools/lib/images.sh"; IMAGE="$(pwe_tool_image)"             # uvnitř vlastního bash skriptu
```

Soubor jde načíst (`.`) z **bash i ze zsh** (výchozí shell macOS) — kořen repozitáře si v obou najde
podle vlastního umístění, takže funkce čtou správný `PWE/VERSION` odkudkoli. Spuštěný přímo
(`bash PWE/tools/lib/images.sh <funkce> [argument]`) zavolá jednu funkci; neznámý název vypíše
použití a skončí kódem 2. Tag na gitu nezávisí: na hostiteli i v kontejneru (kde git není) je to
verze ze souboru `PWE/VERSION`.

Nástroje vypisují, který image použily (`[run-tests] image ghcr.io/kukam/pwe-debugger:2.2.1`,
`[run-webapp] web=… profil=… registr=… tag=… image=…`), a když v místním Dockeru není, poradí:

```text
[run-tests] image ghcr.io/kukam/pwe-debugger:2.3.0 neni v lokalnim Dockeru, docker ho zkusi stahnout z registru.
[run-tests]   sestaveni: make images ARGS=debugger (PWE/tools/build-images.sh debugger)
[run-tests]   mistne dostupne tagy ghcr.io/kukam/pwe-debugger: 2.2.1 latest (pouziti: PWE_IMAGE_TAG=<tag>)
```

(bez místních tagů `v lokalnim Dockeru neni zadny image <repozitář>`; u `PWE_TEST_IMAGE` rada
`PWE_TEST_IMAGE=<repozitář>:<tag>`; u image mimo PWE jen `sestaveni: make images`). U zrušeného image
druhý řádek místo rady k sestavení říká, co ho nahrazuje: `image pwe-static byl zrusen: web bez databaze
bezi nad pwe-base, vzorovy web bez databaze je image pwe-example-static`, resp. `image pwe byl zrusen:
engine se do image webu kopiruje z repozitare (webapps/<web>/Dockerfile), nastroje a vyvojovy stack ho
berou z mountu repozitare`. Když tedy image této verze v registru nejsou
(Docker hlásí `pull access denied`, `manifest unknown`, u `ghcr.io` také `denied` nebo
`403 Forbidden`), sestav je lokálně, použij tag, který místně máš, nebo `PWE_IMAGE_TAG=latest`,
jsou-li image publikované. Neplatný `PWE_IMAGE_TAG` (např. `feature/x`) nástroje odmítnou hláškou
`PWE_IMAGE_TAG='feature/x' neni platny tag image (…). Image PWE maji tagy <verze> (obsah PWE/VERSION) a latest.`;
`PWE/VERSION` bez verze tvaru `X.Y.Z` hláškou `Soubor …/PWE/VERSION neobsahuje verzi enginu tvaru X.Y.Z … zadej tag vyslovne: PWE_IMAGE_TAG=<tag> (napr. latest)`.
Co který image obsahuje: [17 — Nasazení](17-nasazeni.md#image).

## `PWE/tools/build-images.sh` — sestavení image

```
PWE/tools/build-images.sh [--push [--allow-dirty]] [--platform P] [--load] [--no-cache] [--print] [--set K=V] [cíl...]      (make images [ARGS='...'])
```

Sestaví image PWE přes `docker buildx bake -f docker-bake.hcl`: závislostní image z `PWE/docker/Dockerfile`
(cíle `base`, `mariadb`, `mysql`, `postgres`, `debugger`) a image vzorových webů z `Dockerfile` vzorového
webu (cíle `example-static`, `example-mariadb`, `example-mysql`, `example-postgres`). Cíl `<cíl>` dává
image `pwe-<cíl>` a lze ho psát i celým názvem (`pwe-base`, `pwe-example-static`); bez cíle všech devět.
Registr bere z `PWE_IMAGE_REGISTRY`, verzi z `PWE/VERSION`; každý image dostane tagy `<verze>`
a `latest`. `PWE_IMAGE_TAG` se při sestavení nepoužívá. Zrušené cíle `pwe` a `static` skript odmítne
(kód 2) a řekne, co je nahrazuje.

```bash
make images                                   # všech 9 image → ghcr.io/kukam/<image>:<verze> a :latest
make images ARGS='base debugger'              # jen základ a ladicí image
make images ARGS='mariadb example-mariadb'    # image vzorového webu i se základem, ze kterého vychází
PWE/tools/build-images.sh --print             # vypíše cíle a tagy, nic nestaví
PWE/tools/build-images.sh --no-cache base     # základ znovu bez mezipaměti (nové verze balíčků)
PWE/tools/build-images.sh --platform linux/amd64 base example-static  # zkušební sestavení pro jinou platformu (nenačte se)
PWE/tools/build-images.sh --push              # publikace ručně, linux/amd64 i linux/arm64 (jinak ji dělá pipeline)
make images ARGS=--help                       # nápověda: cíle, volby, proměnné
```

Bez voleb se image sestaví pro platformu stroje a načtou do místního Dockeru — to stačí pro
`make run` i ostatní nástroje; skript na konci vypíše místní image s tagy `<verze>` a `latest`. Každé
sestavení oba tagy přepíše; po zvýšení `PWE/VERSION` je potřeba `make images` znovu. S `--platform`
bez `--push` jde jen o ověření, že sestavení projde (výsledek se nenačte, aby nenahradil image pro
platformu stroje; vynutit lze `--load`). `--push` vyžaduje `docker login`, nejde kombinovat
s `--load` a bez `--platform` publikuje `linux/amd64,linux/arm64`. Image vzorových webů dostanou
popisek s časem sestavení a — jen z čisté pracovní kopie — s commitem. Obsahují engine a vzorový web
z pracovní kopie; po změně v `PWE/`, ve vzorovém webu nebo ve vstupním skriptu je proto sestav znovu
(jinak `make images-check` ohlásí rozdíl obsahu). Vzorový cíl si svůj základ sestaví sám, do místního
Dockeru se ale základ uloží jen tehdy, když je také mezi cíli — skript na to upozorní
(`[build-images] cil example-static: zaklad pwe-base se sestavi z pracovni kopie, ale neulozi se …`).

Pojistky (kód 2, nic se nestaví): `PWE/VERSION` bez verze tvaru `X.Y.Z`; `--push` z pracovní kopie
s necommitnutými změnami (obejití: `--allow-dirty`); `--platform` a `--set` bez hodnoty; neplatný
registr v `PWE_IMAGE_REGISTRY`/`PWE_IMAGE_REGISTRIES`; neznámý nebo zrušený cíl. S `--print` pojistky `--push` jen varují.
Pojistky kolem větve (odpojený `HEAD`, tag tvaru verze) zanikly spolu s tagy podle větve. Publikaci do
`ghcr.io/kukam` běžně dělá pipeline GitHub Actions (`.github/workflows/images.yml`) — jen z výchozí
větve a z větví v proměnné repozitáře `PUBLISH_BRANCHES`; ruční `--push` přepíše tagy `<verze>`
i `latest` v registru.
Tabulka voleb, proměnné `PWE_IMAGE_REGISTRIES` a `PWE_IMAGE_SOURCE`, popisky image a pipeline:
[17 — Nasazení](17-nasazeni.md#lokální-sestavení).

## `PWE/tools/smoke-images.sh` — kouřové kontroly image

```
PWE/tools/smoke-images.sh [--platform P] [--pull never|always] [--tree|--no-tree] [image...]      (make images-check [ARGS='...'])
```

Ověří, že každý image obsahuje to, co má (moduly a programy základu, ovladače profilu, ladicí nástroje
v `pwe-debugger`; v image vzorových webů engine a vzorový web), a nic, co mít nemá (kód enginu a web
v závislostních image, DB ovladače v `pwe-base`, ovladače jiného profilu). U image vzorových webů
navíc ověří, že vycházejí ze závislostního image téhož tagu, a spustí je jejich výchozím příkazem:
`pwe-example-static` musí vrátit stránku vzorového webu, databázové profily musí dojít až k pokusu
o připojení k databázi. Bez jmen kontroluje všech devět image (vždy ve stejném pořadí, závislostní před
vzorovými); jména lze psát i zkráceně (`base`, `mariadb`, `example-static`), zrušené `pwe`, `static`
a `pwe-static` skript odmítne (kód 2). Registr a tag bere z `PWE_IMAGE_REGISTRY` a `PWE_IMAGE_TAG` (výchozí verze z `PWE/VERSION`).
Tentýž skript pouští pipeline před publikací pro obě platformy.

```bash
make images && make images-check                          # po sestavení: všech 9 image z místního Dockeru
make images-check ARGS='base example-static'              # jen vybrané
PWE/tools/smoke-images.sh --platform linux/arm64          # image jiné platformy (v emulaci QEMU)
PWE_IMAGE_TAG=latest PWE/tools/smoke-images.sh --pull always   # publikovaný image (nahradí místní pod stejným tagem)
```

Výchozí `--pull never` nikdy nic nestahuje — chybějící image je `FAIL`. Srovnání image s pracovní
kopií (`PWE/VERSION`, soubory enginu a vzorového webu — **seznam i obsah** —, vstupní skript) se dělá
jen u místního image s tagem
rovným verzi v `PWE/VERSION`; u jiného tagu (`latest`, jiná verze) a u `--pull always` se vypíše
`SKIP <image>: srovnani s pracovni kopii …` a ověří se jen vnitřní soulad image. `--tree` srovnání
vynutí (`make images-check ARGS=--tree`), `--no-tree` vypne. Výstup: řádky `OK   <image>: <popis>` /
`FAIL <image>: <popis>` s odsazeným důvodem / `SKIP <image>: <popis>`, na konci
`[smoke-images] OK: N kontrol (preskoceno: M)`; kód 0 = vše prošlo, 1 = něco selhalo, 2 = špatné
použití (`SKIP` kód nemění). Kontroly souborů selžou, když je místní image starší než poslední změna
v `PWE/` (i v `PWE/README.md` a `PWE/CHANGELOG.md`), ve vzorovém webu nebo ve vstupním skriptu
(`… v image maji jiny obsah nez v pracovni kopii`), a kontrola `vychazi z image <základ> tehoz tagu`,
když byl vzorový image sestaven bez svého základu mezi cíli (náprava: `make images`). Seznam kontrol:
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
`README.md`, dočasné adresáře. `conf/<profil>.conf` obsahuje i klíče zámku migrace
`dbversion_session_lock => 1` a `dbversion_legacy_lock_wait => 300`
([03 — Migrace schématu](03-struktura-webu.md#migrace-schématu-confdriverdbversion)), aby šly přepsat
proměnnou prostředí. `Dockerfile` má jediný `FROM` — závislostní image `pwe-<profil>`, u webu bez
databáze `pwe-base` (výchozí tag `latest`) — a engine (`PWE/`) i web kopíruje z kontextu sestavení;
staví se proto vždy z kořene repozitáře. Šablona `Dockerfile` je jen tady (funkce `gen_dockerfile`)
a vyjmenovává všechny položky `PWE/` kromě `t` a `docker`: nová položka enginu znamená doplnit `COPY`
do šablony a `Dockerfile` vzorových webů vygenerovat znovu. Vlastní `entrypoint.sh` web nemá —
image webu ho dědí ze základního image ([17 — Nasazení](17-nasazeni.md#image-vlastního-webu)).
`Dockerfile` existujícího webu obnovíš tak, že web stejného názvu a profilu vygeneruješ jinam
(`PWE/tools/new-webapp.pl <nazev> [--db <profil>] --dir <dočasný adresář>`) a převezmeš z výsledku jen
`Dockerfile`.
Potřebuje jen základní Perl (běží i na hostiteli). Přes `make new` je `WEB` povinný (viz výše).

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
| `Dockerfile` | odpovídá šabloně generátoru: `FROM` závislostního image (`pwe-base` u webu bez databáze, `pwe-<profil>` u webu s databází) a `COPY` každé položky enginu z `PWE/` (kromě `t` a `docker`). Jinak jen **varování** — `WARN Dockerfile je ze stare sablony (<znaky>): … Vygeneruj novy: PWE/tools/new-webapp.pl <web> [--db <profil>] --dir <docasny adresar> a prevezmi z nej Dockerfile (vlastni upravy prenes rucne)`; znaky jsou např. `2x FROM - image pwe jako zdroj enginu`, `ARG PWE_ENGINE_TAG`, `COPY --from=engine`, `zaklad pwe-static - image byl zrusen`, `engine se nekopiruje z kontextu sestaveni (zadne COPY PWE/...)`, `chybi COPY polozek enginu: PWE/…`, `vychozi PWE_IMAGE_TAG=master`, `vlastni ENTRYPOINT / entrypoint.sh`. Dále `WARN Dockerfile je pro web bez databaze (PWE_PROFILE=static, zaklad pwe-base nema ovladace databaze), ale web ma conf/…` (web dostal databázi až po založení) a `WARN Dockerfile: radek FROM vysledneho image (…) se lisi od sablony generatoru (…)` (i u záměrně přepsaného `FROM` — registr a tag patří do `--build-arg`). V pořádku: `OK Dockerfile: FROM a kopie enginu podle sablony generatoru` |
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

Nastaví `PWE_WEBAPP`, `COMPOSE_PROFILES`, `PWE_IMAGE_REGISTRY`, `PWE_IMAGE_TAG` (výchozí tag = verze
z `PWE/VERSION`, viz [Výběr image](#výběr-image)) a `PWE_FCGI_IMAGE` (závislostní image služby `fcgi`:
`pwe-<profil>`, u profilu `static` `pwe-base`) a spustí `docker compose` (výchozí
`up --remove-orphans`). Co spouští, vypíše na standardní chybový výstup:

```text
[run-webapp] web=mujweb.web profil=mariadb registr=ghcr.io/kukam tag=2.2.1 image=pwe-mariadb -> docker compose up --remove-orphans
```

První argument za webem musí být profil (`static`, `mariadb`, `mysql`, `postgres`), příkaz
`docker compose` (`up`, `down`, `logs`, `restart`, `ps`, `config`, `exec`, …) nebo globální volba
compose začínající pomlčkou; cokoli jiného — typicky překlep v profilu (`PROFILE=oracle`,
`PROFILE=Mariadb`) — skončí chybou `Neznamy profil nebo prikaz '<x>' (profily: static | mariadb |
mysql | postgres; …)`, kód 2, místo aby se předalo `docker compose` jako příkaz. Profil bez udání se
odvodí z `conf/database.conf` (symlink) nebo z existence `conf/<driver>.conf`, jinak `static`.

U příkazů, které vytvářejí kontejnery (`up`, `run`, `create`), navíc:

- upozorní, když závislostní image profilu nebo `pwe-debugger` v místním Dockeru není (třířádková rada
  z [Výběru image](#výběr-image));
- varuje, když profil neodpovídá webu:
  `[run-webapp] POZOR: web <web> ma conf/mariadb.conf, ale profil je static - pobezi bez databaze (image pwe-base nema databazove ovladace) …`,
  resp. `[run-webapp] POZOR: web <web> nema conf/<profil>.conf, ale profil je <profil> - databaze se spusti, web ji ale nepouzije …`.

Přímé `docker compose up` bez těchto proměnných bere tag `latest` a image `pwe-<COMPOSE_PROFILES>` —
s profilem `static` proto potřebuje `PWE_FCGI_IMAGE=pwe-base`
(`PWE_WEBAPP=example.web COMPOSE_PROFILES=static PWE_FCGI_IMAGE=pwe-base docker compose up`), jinak
hledá neexistující image `pwe-static`.
Web běží na <http://127.0.0.1:7778/> (nginx → 3× fcgi ze závislostního image profilu). Repozitář je
namountovaný do `/PWE`, takže běží pracovní kopie enginu i webu — image sám engine ani web neobsahuje —
a který web běží, určuje `working_dir` a `PWE_CONF_pwe_home` služby v `docker-compose.yml`. Databáze, uploady a session mají
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

Testy a kompilace enginu v kontejneru — [18 — Testy](18-testy.md). Výchozí image je
`pwe-debugger:<verze>`; `PWE_TEST_IMAGE` ho přepíše celý (pipeline tak pouští testy v `pwe-base`)
a testy projdou i v image webu včetně `pwe-example-*` — skript v kontejneru odstraní zapečené
`PWE_CONF_*` i `PWE_PROFILE` (závislostní image je zapečené nemají). `run-tests.sh` (`make test`)
drží po dobu běhu zámek pracovní kopie `PWE/t/.run-tests.lock`; druhý běh nad stejnou kopií počká
(nejvýš `PWE_TEST_LOCK_WAIT` sekund, výchozí 600), opuštěný zámek převezme sám — podrobně
[18 — Testy](18-testy.md#souběžné-běhy-zámek-pracovní-kopie). `perl-compile.sh` zámek nepoužívá.

## `PWE/tools/k8s.sh` — nasazení do Kubernetes

```
PWE/tools/k8s.sh image|template|deploy|status|test|logs|delete <název> [argumenty pro helm]      (make k8s-<příkaz> K8S=<název> [ARGS='...'])
```

Nasadí web chartem `nxs-universal-chart` podle `kubernetes/values-<název>.yml`. Cílový cluster určuje
**povinný `KUBE_CONTEXT`** — skript nikdy nepoužije aktuální kontext `kubectl` a každému příkazu ho
předává výslovně. Nastavení (`KUBE_CONTEXT`, `K8S_*`) bere z proměnných prostředí, jinak
z `kubernetes/local.env` (není v gitu).

Druh nasazení určuje `generic.pweImage` ve values:

- **`pwe-example-static`, `pwe-example-mariadb`, `pwe-example-mysql`, `pwe-example-postgres` = vzorové
  nasazení** (`static` → `pwe-example-static` s `example.web`, `generic` → `pwe-example-mariadb`
  s `example-db.web` + MariaDB): nasazuje se hotový image vzorového webu z registru image PWE
  (`K8S_REGISTRY`, výchozí `PWE_IMAGE_REGISTRY` = `ghcr.io/kukam`) s tagem `K8S_IMAGE_TAG` (výchozí
  `PWE_IMAGE_TAG`, jinak verze z `PWE/VERSION`). Příkaz `image` nic nestaví — vypíše
  `[k8s] nasazeni <název> je vzorove: pouziva hotovy image vzoroveho webu … (knihovny, engine i web …) - nic se nestavi`
  a skončí kódem 0. `pweWeb` a `pweProfile` musí názvu image odpovídat, jinak kód 2
  (`… je image vzoroveho webu …, ale generic.pweWeb je '…'`, `… s profilem …, ale generic.pweProfile je '…'`).
- **jiný název = vlastní web:** příkaz `image` sestaví `webapps/<web>/Dockerfile` z kořene repozitáře
  pro platformu `K8S_PLATFORM` (výchozí `linux/amd64`) — závislostní image `pwe-<profil>:<PWE_IMAGE_TAG>`
  (profil `static`: `pwe-base`) + engine z pracovní kopie + web — a nahraje ho do `K8S_REGISTRY`
  (povinný) s tagem `K8S_IMAGE_TAG` (výchozí `latest`). Předává argumenty sestavení
  `PWE_IMAGE_REGISTRY`, `PWE_IMAGE_TAG` a `PWE_PROFILE`; `PWE_IMAGE_TAG` vybírá jen závislostní image,
  verzi enginu neurčuje. Místní závislostní image pro jinou platformu odmítne s radou, jak ho pro
  platformu clusteru sestavit (`docker build --platform … --target base|mariadb|mysql|postgres …
  -f PWE/docker/Dockerfile .`). `Dockerfile` ze starší šablony odmítne ještě před sestavením
  (`webapps/<web>/Dockerfile je z drivejsi sablony (…)`), stejně jako `Dockerfile` webu s databází
  nasazovaný s `pweProfile: static`.
- **vyhrazené názvy** jako `pweImage` vlastního webu skript odmítne (`generic.pweImage '…' je vyhrazeny
  nazev image PWE (…)`), i s cestou: závislostní image `pwe-base`, `pwe-mariadb`, `pwe-mysql`,
  `pwe-postgres`, `pwe-debugger`, všechny názvy `pwe-example-*` a zrušené `pwe` a `pwe-static`. Další
  kontroly values: `generic.pweImage '…' neni nazev image` (jen malá písmena, číslice a `. _ - /`)
  a `generic.pweProfile '…' neni profil PWE (static, mariadb, mysql, postgres)`.

`deploy` nasazuje podle digestu (zjistí ho v registru; když to nejde, skončí chybou
`digest image … nelze zjistit`, výjimka `K8S_ALLOW_TAG=1`). Když stav releasu nebo jeho svazků v clusteru
zjistit nejde a soubor s hesly `kubernetes/secrets-<název>.yml` chybí, `deploy` nová hesla nezaloží
a skončí chybou (`stav releasu … v clusteru nelze zjistit (…) - nova hesla nezakladam …`; výslovně
`K8S_NEW_SECRETS=1`); `delete` odmítne odinstalovat release s hesly, když soubor s hesly na stroji chybí
(obejití `K8S_DELETE_WITHOUT_SECRETS=1`). Přepínače, které by změnily cluster, přihlášení nebo
namespace (`--kube-context`, `--kubeconfig`, `--context`, `--server`, `--namespace`, …), skript odmítne
a proměnné `HELM_KUBE*`, `HELM_NAMESPACE` a `KUBERNETES_MASTER` před spuštěním zruší. Tag se vyhodnocuje jen u příkazů `image`,
`template` a `deploy`; `status`, `logs`, `test` a `delete` ho nepotřebují. Hodnoty `K8S_REGISTRY`,
`K8S_PULL_REGISTRY` a `K8S_IMAGE_TAG` z `kubernetes/local.env` platí pro všechna nasazení včetně
vzorových.
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
| `[I] … FastCGI socket :7779: adresa TCP` (nebo `… unix socket s pravy 0770`) | engine dostartoval a poslouchá ([17 — FastCGI socket](17-nasazeni.md#fastcgi-socket)) |
| `[I] … Dbversion update to id N`, `Dbversion: migraci databaze dbid:db1 provadi jiny proces, cekam na zamek spojeni (…)` | migrace schématu při startu; čekání na jiný proces je v pořádku ([17 — Migrace schématu při startu](17-nasazeni.md#migrace-schématu-při-startu)) |
| `[I] … PWE server ukoncen signalem TERM` | pořádané ukončení (`make down`, `make restart`); proces končí kódem 0 ([17 — Ukončení procesu](17-nasazeni.md#ukončení-procesu-sigterm)) |

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
`pwe-<profil>` a `pwe-base`, ve kterých běží procesy `fcgi`, ladicí nástroje nemají. Hostitelský Perl nemá
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
  (engine do verze 2.2.0 by v tu chvíli skončil a `/debug.cgi` by vracelo chybu spojení; od 2.2.1
  čekání přerušené jiným signálem než `TERM` a `USR1` opakuje i sám `pwe.fcgi`).
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
  `"perl.containerMode": "run"` a `"perl.containerArgs": ["run", "--rm", "-i", "-v", "<repozitář>:/PWE", "ghcr.io/kukam/pwe-debugger:latest"]`
  (nebo tag verze, jejíž image máš místně; ladění přes `F5` pak nefunguje).
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
  bez stacku `docker run --rm -v "$PWD":/PWE -w /PWE ghcr.io/kukam/pwe-debugger:latest perlcritic --severity 5 webapps/<web>/Pages`
  (nebo tag verze, jejíž image máš místně).
- Texty pro uživatele jen v `rb*.tmpl` (UTF-8 s diakritikou), nikdy v kódu.
- Žádné `use Libs::…` v modulech webu mimo blok `KOMODO`.
- Bootstrap 5 markup, `$(function(){…})` pro inline skripty.
