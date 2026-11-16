# Změny enginu PWE (adresář `PWE/`)

Verze je v `PWE/VERSION`; weby ji vyžadují přes `pwe.require_core` v `conf/web.conf`.
Semver: oprava = patch, nová metoda/služba = minor, změna kontraktu stránky/Site nebo
sdílených šablon = major.

Adresář enginu se ve verzích 1.0.0–2.1.0 jmenoval `core/`, od 2.2.0 je to `PWE/` (v kořeni repozitáře;
v kontejnerech `/PWE/PWE`). Cesty k dnes existujícím souborům jsou v celém tomto souboru psané podle
dnešního názvu (`PWE/…`); kde záznam popisuje tehdejší stav, je to výslovně uvedeno („tehdy `core/`“).
Podle dnešního umístění jsou psané i cesty k souborům vývojového stacku (`docker-compose/`) a nasazení
do Kubernetes (`kubernetes/`), přesunutým 15. 11. 2026 (viz 2.2.0).

## 2.2.1 — 2026-11-16

Opravy jádra enginu (ukončování procesu, FastCGI socket, zámek migrace schématu) a nové uspořádání image.
Kontrakt stránek, API pro weby ani konfigurace webu se nemění — `pwe.require_core => ">=2.2"` vyhovuje dál.
Co má zkontrolovat provozovatel, shrnuje `docs/17-nasazeni.md`, oddíl „Přechod na verzi 2.2.1“.

**Ukončování procesu a FastCGI socket** (`PWE/pwe.fcgi`; popis v `docs/17-nasazeni.md`, „Běh procesu enginu“):

- **Oprava: pořádané ukončení na `SIGTERM`.** Handler dřív jen odpojil databázi — i pod rozpracovaným
  requestem — a proces po requestu (nebo po signálu těsně po odeslání odpovědi) neskončil, takže na něj
  orchestrátor čekal až do `SIGKILL`; signál během startu končil chybou
  `Can't call method "getDbidList" on an undefined value`. Nově: nečinný proces skončí hned, rozpracovaný
  request doběhne s funkční databází a klient dostane celou odpověď, naslouchající socket se zavře hned po
  signálu a proces končí kódem 0. Během startu se engine přeruší na bezpečném místě (mezi pokusy o připojení
  k databázi, mezi kroky migrace) a skončí, aniž otevře socket. `SIGUSR1` má stejný účinek jako `SIGTERM`.
  Na Linuxu engine čeká na spojení sám (neblokující socket, probuzení nejpozději po 1 s), takže se signál
  neztratí a nezdrží ho prázdná spojení (TCP sondy). Do logu: `PWE server ukoncen signalem TERM`, při startu
  `Start PWE serveru prerusen signalem TERM`.
- Skutečná chyba čekání na request ukončí engine s kódem 1 a hláškou
  `PWE server konci: cekani na request FastCGI selhalo (…)` (dřív tichý konec s kódem 0).
- **Oprava: `FCGI_SOCKET_PATH` ve tvaru `host:port`** (`127.0.0.1:7779`, `*:7779`). Dřív start skončil chybou
  `Couldn't chmod(127.0.0.1:7779)`; fungovalo jen `:7779` a cesta k unix socketu. Engine za webserverem na
  stejném stroji nebo ve stejném podu tak může poslouchat jen na loopbacku.
- **Oprava a změna chování: práva unix socketu.** Socket měl mít práva 0770, hodnota se ale četla desítkově
  a socket vznikal s právy **1402** — připojit se směli „ostatní“, vlastník a skupina ne. Nově má skutečných
  0770. **Nasazení, kde webserver běží pod jiným uživatelem než engine a není ve skupině jeho procesu, se po
  aktualizaci k socketu nepřipojí** (nginx: `connect() … failed (13: Permission denied)`, 502): dej webserver
  a engine do společné skupiny, nastav `FCGI_SOCKET_PERM` (např. `0666`), nebo přejdi na
  `FCGI_SOCKET_PATH=127.0.0.1:7779`.
- **Změna: `FCGI_SOCKET_PERM` se čte osmičkově** (`0660`, `660`, `0777`), výchozí 0770; jiná hodnota než tři
  až čtyři osmičkové číslice ukončí start chybou. U adresy TCP se nepoužívá. Dřív proměnnou četla knihovna
  `CGI::Fast` jako desítkové číslo — **hodnotu zapsanou desítkově přepiš** (`432` → `0660`, `438` → `0666`,
  `511` → `0777`); `432` a `511` jsou platný osmičkový zápis a daly by jiná práva. Úspěšné otevření socketu
  engine loguje včetně skutečných práv (`FastCGI socket :7779: adresa TCP`, `… unix socket s pravy 0770`).
- Omezení daná knihovnou FastCGI (nemění se): signál ve chvíli, kdy knihovna čte hlavičku právě přijatého
  requestu nebo čeká na další request na spojení drženém webserverem (`fastcgi_keep_conn on`), tento request
  neobslouží. `fastcgi_keep_conn` s enginem nepoužívat — jeden proces obsluhuje jedno spojení.

**Zámek migrace schématu** (`Libs::MyDBI`, `Libs::MyDBI::DRIVER::MySQL`, `Libs::MyDBI::DRIVER::Postgre`; popis
v `docs/03-struktura-webu.md`, „Zámek migrace“, a `docs/17-nasazeni.md`, „Migrace schématu při startu“):

- **Oprava: zámek migrace, který zůstal po pádu procesu.** Když proces skončil uprostřed migrace (`SIGKILL`,
  OOM, výměna podu), zůstal v tabulce `dbversion` nastavený `lockid` a každý další start čekal donekonečna
  (`Dbversion is locked by lockid:N`). Migraci nově chrání **zámek vázaný na databázové spojení**
  (MySQL/MariaDB `GET_LOCK('pwe.dbversion.<databáze>')`, PostgreSQL poradní zámek úrovně session), který
  server uvolní sám, jakmile spojení zanikne. Další start se zotaví bez zásahu: opuštěný `lockid` převezme,
  migraci dokončí a zapíše to do logu (`[E] Dbversion: zamek lockid:N … je opusteny … Prebiram ho`).
- **Oprava: souběžný start.** Tabulku `dbversion` zakládá proces až pod zámkem spojení — dva současně
  startující procesy ji už nezaloží dvakrát a každý krok proběhne právě jednou. Řádek do nové tabulky vkládá
  až po kontrolním čtení o sekundu později (první start nad čistou databází je o tu sekundu delší), aby při
  souběhu se starší verzí enginu nezůstaly v tabulce dva řádky. Proces, který nemá co
  migrovat, na cizí migraci nečeká (leda že si strukturu tabulek čte z databáze — pak počká, aby nenačetl
  rozpracované schéma, a to i na migraci procesu bez zámku spojení) a do sloupce `lockid` vůbec nezapisuje.
- Sloupec `dbversion.lockid` se zapisuje dál kvůli procesům bez zámku spojení: proces se zámkem spojení
  zapisuje číslo záporné, proces bez něj (i starší verze enginu) kladné. Na kladný cizí `lockid` proces čeká,
  dokud migrace postupuje, a převezme ho až po `dbversion_legacy_lock_wait` sekundách beze změny — postupná
  výměna starší verze enginu za novou tak kroky migrace nespustí dvakrát, pokud žádný krok netrvá déle než
  tato doba.
- **Nové klíče v `conf/<profil>.conf`** (sekce `dbi`): `dbversion_session_lock` (výchozí zapnuto i bez klíče;
  `0` = chování starších verzí, nutné za poolerem v režimu transaction pooling a v clusteru s více zapisovacími
  uzly) a `dbversion_legacy_lock_wait` (výchozí 300 s, `0` = cizí zámek nikdy nepřebírat). Generátor webu je
  zapisuje; do staršího webu je potřeba je doplnit, aby šly přepsat přes `PWE_CONF_dbi_db1_*`.
- **Přerušení startu:** nové funkce `Libs::MyDBI::requestStop()` a `stopRequested()`; konstruktor kontroluje
  příznak před každým pokusem o připojení, migrace při čekání na zámek a před každým krokem. Rozběhnutý krok
  se vždy dokončí a zapíše, start pak končí výjimkou `Startup interrupted by termination request`
  (`pwe.fcgi` ji po `SIGTERM` převede na kód 0).
- **Chyby místo tichého pokračování nebo nekonečné smyčky:** selhání zápisu verze po provedeném kroku,
  nečitelná tabulka `dbversion`, soubor migrací, který nejde načíst (`Dbversion: <soubor>: <důvod>`), a zámek
  `lockid`, který se nepodaří získat ani na 20 pokusů, ukončí start chybou. Tabulce bez řádku (pád mezi
  `CREATE TABLE` a `INSERT`) engine pod zámkem spojení řádek doplní. Po převzetí opuštěného zámku chyba
  prvního kroku upozorní, že krok mohl být už dřív částečně proveden (DDL v MySQL/MariaDB není transakční).
- Hláška `Dbversion is locked by lockid:N` (jen bez zámku spojení) se loguje poprvé a pak po 30 s místo každou
  sekundu a radí, jak zámek uvolnit ručně; čekání na zámek spojení se loguje poprvé jako info, opakovaně jako
  error.
- Ovladače: nové metody `sessionLock($name,$timeout)` a `sessionUnlock($name)`. MySQL po dobu držení zámku
  vypíná tichý reconnect ovladače (`mysql_auto_reconnect` — spojení obnovené bez zámku by migrovalo dál
  nechráněné). PostgreSQL pozná serverové spojení sdílené poolerem v režimu transaction pooling (PgBouncer
  `pool_mode = transaction`) a zámek nevezme — start pak chrání jen sloupec `lockid`; je to pojistka, za
  takovým poolerem nastav `dbversion_session_lock => 0` u všech procesů.
- PostgreSQL: tabulku `dbversion`, která leží v jiném schématu, než kde ji hledá kontrola existence (conf
  `schema` neodpovídá `search_path`), engine použije a zapíše `[E]` do logu (start kvůli tomu nespadne). Po
  získání zámku spojení se při vypnutém autocommitu ukončí transakce, ve které se o zámek žádalo — čtení pod
  zámkem vidí aktuální stav i při izolaci REPEATABLE READ.
- Známé omezení z 2.2.0 („zámek migrace zůstane nastavený … handler SIGTERM odpojí databázi i pod
  rozpracovaným požadavkem“) tím přestává platit.

**Nové uspořádání image** (API enginu beze změny; popis v `docs/17-nasazeni.md`, oddíl „Image“):

- **Devět image dvou druhů místo sedmi.** *Závislostní image* `pwe-base` (běhové knihovny), `pwe-mariadb`,
  `pwe-mysql`, `pwe-postgres` (základ + DB ovladač) a `pwe-debugger` (všechny ovladače + ladicí nástroje)
  nesou jen závislosti — kód enginu ani web v nich není; balíčky v nich se proti 2.2.0 nemění. Nové *image
  vzorových webů* `pwe-example-static` (`pwe-base` + engine + `webapps/example.web`) a `pwe-example-mariadb`,
  `pwe-example-mysql`, `pwe-example-postgres` (`pwe-<profil>` + engine + `webapps/example-db.web`) jsou samy
  spustitelné; staví je přímo `Dockerfile` vzorového webu (`make images` i pipeline) a publikují se. Jsou to
  **ukázky, nejsou určené pro veřejný provoz** — každý návštěvník vzorového webu je ve skupině `admin`
  včetně generátoru kódu `pweCreator`.
- **Zrušené image `pwe` a `pwe-static`.** Image `pwe` (základ + kód enginu, zdroj pro `COPY --from`
  v `Dockerfile` webu) už není potřeba — engine se do image webu kopíruje z repozitáře; web bez databáze
  (profil `static`) běží nad `pwe-base`. Zanikly i stage a cíle `pwe` a `static` a kontrola při sestavení
  `PWE_VERSION=… neodpovida PWE/VERSION=…` (shodu verze hlídají kouřové kontroly). Nástroje zrušené názvy
  odmítají s vysvětlením (`image pwe-static byl zrusen: web bez databaze bezi nad pwe-base, …`). Balíčky
  zrušených image v registru nic nemaže — smazat ručně.
- **`Dockerfile` webu = závislostní image + engine z repozitáře + web.** Jediný `FROM` `pwe-<profil>:<tag>`
  (web bez databáze `pwe-base:<tag>`; výchozí `PWE_IMAGE_TAG=latest`), engine `COPY --link` z kontextu
  sestavení (položky `PWE/` kromě `PWE/t`, `PWE/docker` a `PWE/tools`) do `/PWE/PWE`, jediný `RUN` (pracovní adresáře
  a `conf/database.conf`); popisek `version` vyprazdňuje. Sestavuje se **vždy z kořene repozitáře**; verzi
  enginu v image určuje pracovní kopie, `PWE_IMAGE_TAG` vybírá jen závislostní image. Argument
  `PWE_ENGINE_TAG`, druhý `FROM` s image `pwe` a `COPY --from=engine` zanikly. Šablona je jen
  v `PWE/tools/new-webapp.pl` (`gen_dockerfile`); nová položka přímo v `PWE/` znamená doplnit ji do šablony
  a `Dockerfile` vzorových webů vygenerovat znovu. **Existující web:** `Dockerfile` vygenerovat znovu
  (`PWE/tools/new-webapp.pl <web> [--db <profil>] --dir <dočasný adresář>` a převzít z výsledku `Dockerfile`)
  a image webu sestavit z kořene repozitáře.
- **`make check` varuje na `Dockerfile` webu ze staré šablony** (`check-webapp.pl`:
  `WARN Dockerfile je ze stare sablony (<znaky>): … Vygeneruj novy: …`) — image `pwe` jako zdroj enginu,
  `PWE_ENGINE_TAG`, `COPY --from=engine`, základ `pwe-static`, chybějící `COPY` položek enginu, výchozí tag
  podle větve, vlastní `ENTRYPOINT`. Varuje i na `Dockerfile` webu bez databáze u webu s `conf/<profil>.conf`
  a na `FROM` odlišný od šablony. Kontrolu neshodí.
- **Tagy: každý image má právě `<verze>` (obsah `PWE/VERSION`) a `latest`.** Tagy podle větve gitu zanikly
  (žádné `master`, `pwe.ai`, `pr-N`); oba tagy se přepisují každým sestavením a publikací. Staré tagy podle
  větve v registru nic nemaže — smazat ručně.
- **Nástroje berou tag z `PWE/VERSION`**, ne z větve gitu: výchozí `PWE_IMAGE_TAG` je verze enginu, výchozí
  image nástrojů `pwe-debugger:<verze>`. Nové funkce `pwe_image_version`, `pwe_image_names`
  a `pwe_profile_image` (`PWE::ToolEnv`: `image_version()`, `image_names()`, `profile_image()`,
  `dockerfile_base()`, `engine_image_entries()`), zrušené `pwe_image_branch` a `pwe_image_tag_sanitize`
  (`image_tag_sanitize()`). Rada při chybějícím image jmenuje cíl sestavení (`make images ARGS=<cíl>`). Po
  zvýšení `PWE/VERSION` je potřeba `make images` (nebo dočasně `PWE_IMAGE_TAG=latest`).
  `PWE_IMAGE_TAG=master` už neexistuje.
- `make images` (`build-images.sh`) staví devět cílů — `base`, `mariadb`, `mysql`, `postgres`, `debugger`,
  `example-static`, `example-mariadb`, `example-mysql`, `example-postgres` — s tagy `<verze>` a `latest`;
  `PWE_IMAGE_TAG` se při sestavení nepoužívá a pojistky kolem větve a tagu tvaru verze zanikly (zůstává
  `--push` jen z čisté pracovní kopie nebo s `--allow-dirty`). Vzorový cíl si základ sestaví sám z téhož
  volání (`contexts` v `docker-bake.hcl`), do místního Dockeru nebo registru se ale základ uloží jen tehdy,
  je-li také mezi cíli — skript na to upozorní. `docker-bake.hcl`: proměnná `TAG` zanikla, `VERSION` je
  povinná.
- `docker-compose.yml`: výchozí tag služeb `fcgi` a `debugger` je `latest` (dřív `master`); `make run` nastavuje
  verzi z `PWE/VERSION`. Nová proměnná `PWE_FCGI_IMAGE` (image služby `fcgi`, výchozí
  `pwe-<COMPOSE_PROFILES>`): profil `static` běží nad `pwe-base`. `make run` ji nastavuje sám; **přímé
  `COMPOSE_PROFILES=static docker compose up` potřebuje `PWE_FCGI_IMAGE=pwe-base`**.
- Kouřové kontroly (`smoke-images.sh`) pro devět image: závislostní image nesmějí obsahovat engine ani web,
  image vzorových webů musejí vycházet ze závislostního image téhož tagu a jejich výchozí příkaz musí vrátit
  stránku (databázové profily dojít k pokusu o připojení). **Srovnání s pracovní kopií porovnává i obsah
  souborů** enginu, vzorového webu a vstupního skriptu (dřív jen seznam souborů enginu): po změně v `PWE/`
  nebo ve vzorovém webu je `FAIL`, dokud neproběhne `make images`. Nové volby `--tree` / `--no-tree`
  a řádky `SKIP`; bez voleb se srovnává jen místní image s tagem = verze.
- `entrypoint.sh`: nová varování — image nemá ovladač databáze profilu
  (`[entrypoint] VAROVANI: PWE_PROFILE=…, ale image nema ovladac databaze …`) a jako server běží vzorový web
  zapečený v image (`[entrypoint] VAROVANI: bezi vzorovy web … - neni urcen pro verejny provoz …`).
- `.dockerignore`: testy enginu (`PWE/t`) se nedostanou do žádného image.
- `run-tests.sh`: v kontejneru odstraňuje i `PWE_PROFILE`; zbylou značku přebírání zámku smaže sám, opuštěný
  zámek v adresáři bez práva zápisu běh nezablokuje.
- **Pipeline:** `.github/workflows/images.yml` staví, kontroluje a publikuje všech devět image; publikuje jen
  `push` a ruční spuštění nad výchozí větví repozitáře a nad větvemi z proměnné repozitáře `PUBLISH_BRANCHES`
  (přesné názvy oddělené mezerou nebo čárkou). Ostatní větve a pull requesty image jen sestaví a otestují
  (job nemá podmínku `if` — pull request z větve téhož repozitáře se sestaví vedle běhu `push`). Vstupem image
  jsou nově i vzorové weby (`webapps/example.web/**`, `webapps/example-db.web/**`), které proto přestal
  sledovat workflow Tests. Kontrola před sestavením ověřuje cíle i tagy (cíl `<cíl>` = právě
  `pwe-<cíl>:<verze>` a `pwe-<cíl>:latest`), základní image Ubuntu se v běhu připíná na digest (krok *Base
  image digest*), sestavení `linux/arm64` dostává stejné proměnné pro bake jako publikace. Kouřové kontroly
  běží s `--tree` a **mají časový limit** (`linux/amd64` 15 minut, `linux/arm64` 30 minut), aby zaseknutý
  proces nevisel až do limitu jobu. Ruční spuštění nad gitovým tagem už nekončí chybou (jen sestaví
  a otestuje).
- **Kubernetes** (`PWE/tools/k8s.sh`, `kubernetes/values-*.yml`): vzorová nasazení `static` a `generic` berou
  hotové image `ghcr.io/kukam/pwe-example-static` a `pwe-example-mariadb` — nic se nestaví (ve 2.2.0 si image
  `pwe-example-static` / `pwe-example-generic` stavěla sama). `make k8s-image` je jen pro vlastní web a staví
  jeho `Dockerfile` nad `pwe-<profil>`, bez databáze nad `pwe-base`. Engine v podu poslouchá jen na
  `127.0.0.1:7779`. Opravy a pojistky skriptu:
  - **oprava:** `deploy` nezaloží nová hesla, když chybí `kubernetes/secrets-<název>.yml` a stav releasu nebo
    jeho svazků v clusteru **nejde zjistit** (nedostupný cluster, chybějící `kubectl`) — skončí chybou
    `stav releasu … v clusteru nelze zjistit (…) - nova hesla nezakladam`. Dřív se nezjistitelný stav bral jako
    „release neexistuje“ a nová hesla by nesouhlasila s existující databází. Výslovně `K8S_NEW_SECRETS=1`;
  - `delete` odmítne odinstalovat release s hesly, když soubor s hesly na stroji chybí (pojistka; obejití
    `K8S_DELETE_WITHOUT_SECRETS=1`);
  - **vyhrazené názvy image:** `generic.pweImage` vlastního webu nesmí být závislostní image, název
    `pwe-example-*` ani zrušené `pwe` a `pwe-static` (ani s cestou); vzorové nasazení je právě jeden ze čtyř
    názvů `pwe-example-*` a `pweWeb` i `pweProfile` mu musí odpovídat; nové kontroly znaků v `pweImage`
    a hodnoty `pweProfile`;
  - odmítané přepínače: vedle přepínačů clusteru a přihlášení (`--kube-context`, `--kubeconfig`, `--context`,
    `--server`, …) nově i namespace (`--namespace`, `-n`) a krátké slepené tvary; proměnné `HELM_KUBE*`,
    `HELM_NAMESPACE` a `KUBERNETES_MASTER`, kterými by `helm` nebo `kubectl` vybraly cluster či namespace mimo
    `KUBE_CONTEXT` a `K8S_NAMESPACE`, skript před spuštěním ruší a oznámí to. Neznámá hodnota `--dry-run` se
    odmítne;
  - `make k8s-image` odmítne `Dockerfile` webu ze starší šablony ještě před sestavením.

- Nástroje pro vývojáře (`PWE/tools`) už nejsou součástí image webu (engine je za běhu nepotřebuje) a spolu
  s testy (`PWE/t`) přestaly být vstupem image: změna skriptu nebo testu spouští jen workflow Tests, image se
  kvůli ní nesestavují ani nepublikují (výjimkou jsou kouřové kontroly `smoke-images.sh` a `lib/images.sh`,
  brána před publikací). `make k8s-delete` odmítne název dalšího releasu v `ARGS` (obešel by
  pojistku hesel).

- Kubernetes: vzorová nasazení se jmenují podle image (`example-static`, `example-mariadb`, nově i
  `example-mysql` a `example-postgres`; soubory `kubernetes/values-example-*.yml`), takže release i adresa webu
  jsou `pwe-example-<varianta>`. Každé nasazení má vlastní namespace pojmenovaný jako release (dřív společný
  `pwe`); `K8S_NAMESPACE` ho přepíše.

**Testy:** nové `t/23-dbversion-lock.t` (zámek migrace nad falešnou databází), `t/24-shutdown.t` (ukončování
a socket nad skutečným FastCGI serverem) a `t/25-pipeline.t` (pravidla workflow: devět image, kdo publikuje,
kroky s bake přehrané s falešným `docker`); pomocné moduly
`t/lib/PWE/TestServer.pm` a `t/lib/PWE/ShutdownHooks.pm`, akce `slow` a `plen` fixture stránky `tPage2`;
rozšířené `t/10-drivers.t` (zámek spojení ovladačů), `t/14-tools.t`, `t/21-image-tools.t` a `t/22-k8s-tool.t`
(nové uspořádání image — závislostní image, image vzorových webů, šablona `Dockerfile` webu a její kontrola
v `make check` —, tagy, Makefile, kouřové kontroly, vyhrazené názvy image a ochrana hesel v `k8s.sh`);
`t/20-debug-entry.t` používá `PWE::TestServer`.

## 2.2.0 — 2026-11-08

**Přejmenování adresáře enginu `core/` → `PWE/`** (2026-11-15; mění se jen cesty — API enginu, kontrakt
stránek ani konfigurační klíče se nemění):

- Adresář enginu v kořeni repozitáře se jmenuje **`PWE/`** (dřív `core/`), aby bylo hned jasné, že jde o engine.
  V kontejnerech je repozitář v `/PWE`, engine je tedy v **`/PWE/PWE`** (dřív `/PWE/core`).
  Nástroje jsou `PWE/tools/*`, testy `PWE/t/`, image se staví z `PWE/docker/Dockerfile`; cíle `make`
  (`make test`, `make new`, `make check`, `make run`, …) se nemění.
- **Co musí udělat existující web a nasazení** (weby mají vlastní git, přejmenování se v nich neprojeví samo;
  stejný postup je v `docs/17-nasazeni.md`, oddíl „Přechod z rozložení s adresářem `core/`“):
  - `Dockerfile` webu: engine v `/PWE/PWE` a `CMD ["perl", "/PWE/PWE/pwe.fcgi"]` — nejlépe rovnou nová šablona
    z oddílu „Nové uspořádání image a CI“ níže;
  - soubor `vars` webu: `export PERL5LIB="$(pwd):/PWE/PWE"` a `export PWE_CONF_pwe_core=/PWE/PWE/`
    (stejně tak příkaz `perl /PWE/PWE/pwe.fcgi` v komentářích, v README webu a v cron úlohách);
  - nginx: `root` pro assety enginu je `/PWE/PWE` (v `docker-compose/docker-compose_nginx.conf` location `@core_assets`);
    vlastní compose a Kubernetes manifesty: `command`, `PWE_CONF_pwe_core`, `PERL5LIB` a mount statiky
    enginu `PWE/assets` → `/PWE/PWE/assets`;
  - skripty a CI, které volaly `core/tools/*` nebo `core/t`, přepsat na `PWE/tools/*` a `PWE/t`
    (nebo použít `make`);
  - **image webu znovu sestavit** — historické image `kukam/pwe-*` z Docker Hubu mají engine v `/PWE/core`
    a zapečené `PWE_CONF_pwe_core=/PWE/core`, takže web s novými cestami nad starým základem (ani naopak)
    nenastartuje. Image se od této verze jmenují a staví jinak — viz „Nové uspořádání image a CI“ níže.
- **Nemění se:** konfigurační klíče `pwe.core`, `pwe.core_pages`, `pwe.core_sites`, `pwe.core_services`,
  `pwe.core_entities`, `pwe.require_core` a název proměnné prostředí `PWE_CONF_pwe_core` (mění se jen její
  hodnota); stejně tak metody `Libs::Config::getCore()`, `coreVersion()`, `checkCoreVersion()`. Slovo „core“
  v nich znamená „kořen enginu“, ne název adresáře — `conf/web.conf` webu se proto upravovat nemusí.

**Přejmenování adresáře `LXC/` → `docker-compose/` a `kubernetes/`** (2026-11-15; soubory vývojového stacku
mění jen cestu):

- Soubory vývojového stacku — `docker-compose_nginx.conf` a `docker-compose_<profil>.env`, `docker-compose_common.env` —
  jsou v adresáři **`docker-compose/`** (dřív `LXC/`); `docker-compose.yml` v kořeni na ně odkazuje novou cestou.
- Historické manifesty Kubernetes (`kubernetes.yml`, `helmfile-*-values.yml`, dřív také v `LXC/`) a kořenový
  `helmfile.yaml` mířily na starý chart a historický image `kukam/pwe:latest`; nahradil je adresář
  **`kubernetes/`** s novým nasazením (viz „Nasazení do Kubernetes“ níže) a z repozitáře jsou smazané.
- Vlastní skripty, compose soubory a dokumentace webů, které odkazovaly na `LXC/…`, je potřeba přepsat na nové cesty
  (soubory `docker-compose_*` → `docker-compose/`); nasazení postavená na historických manifestech převést na
  `kubernetes/values-<název>.yml` a `make k8s-*`.

**Nové uspořádání image a CI** (2026-11-15; API enginu ani kontrakt stránek se nemění — mění se image, jejich
názvy a tagy, `Dockerfile` webu a výchozí image nástrojů; popis je v `docs/17-nasazeni.md`, oddíl „Image“):

- **Sedm image v registru `ghcr.io/kukam`** (GitHub Container Registry) místo dosavadních `kukam/pwe-base`
  a `kukam/pwe-<profil>` s tagem `latest` na Docker Hubu. Všechny vycházejí z `pwe-base`:
  - `pwe-base` — `ubuntu:26.04` (dřív plovoucí `ubuntu:latest`) a **jen běhové knihovny enginu**. Kód enginu
    v něm už **není** (dřív byl v `/PWE/PWE`), stejně tak DB ovladače a ladicí a build nástroje.
  - `pwe` — nový image, „nosič“ kódu enginu: základ + `/PWE/PWE` (bez `t/` a `docker/`) a `/PWE/LICENSE`.
  - `pwe-static`, `pwe-mariadb`, `pwe-mysql`, `pwe-postgres` — běhové profily: základ + DB ovladač (`static`
    žádný, `mariadb` nově i `DBD::MariaDB`). Kód enginu ani vzorový web už neobsahují (dřív to byly image
    vzorových webů se zapečeným `PWE_CONF_pwe_home`).
  - `pwe-debugger` — nový image pro ladění: základ + všechny tři DB ovladače, `Perl::LanguageServer`
    (z balíčku Ubuntu `libperl-languageserver-perl`, sestavení hlídá verzi ≥ 2.6.2), `Perl::Critic`,
    `Perl::Tidy`, `cpanminus`, `build-essential`, `perl-doc`, klienti MariaDB a PostgreSQL, síťové nástroje,
    `cgi-fcgi`. Běží z něj služba `debugger` v compose a je to výchozí image nástrojů.
- **Tagy:** všechny image mají tag podle větve gitu (`master`, `pwe.ai`; znaky mimo `A–Z a–z 0–9 _ . -` → `-`),
  **jen `pwe` má navíc tag verze** z `PWE/VERSION` (`ghcr.io/kukam/pwe:2.2.0`). Tag `latest` se nepublikuje.
  Tagy se přepisují — i tag verze, který publikuje běh pipeline z kterékoli větve; jednoznačně kód určuje jen
  digest nebo popisek `org.opencontainers.image.revision` image `pwe` (`docs/17-nasazeni.md`, „Registr a tagy“).
- **Sestavení:** jeden vícestupňový `PWE/docker/Dockerfile` (stage `base`, `pwe`, `static`, `mariadb`, `mysql`,
  `postgres`, `debugger`), cíle a tagy v `docker-bake.hcl`, lokálně `make images [ARGS='pwe debugger']`
  (`PWE/tools/build-images.sh [--push] [--platform P] [--load] [--no-cache] [--print] [--set K=V] [cíl…]`).
  Každý stage si obsah při sestavení ověří (programy volané pevnou cestou, načtení modulů a ovladačů, verze
  jazykového serveru, shoda `PWE_VERSION` s `PWE/VERSION`). Popisky `org.opencontainers.image.*` mají všechny
  image; čas sestavení (`created`), commit (`revision`) a verzi nese **jen `pwe`** (proměnné `CREATED`
  a `REVISION` v `docker-bake.hcl`) — ostatní image kód enginu neobsahují a s každým commitem se nemění.
- **Vstupní skript** je jeden pro všechny image — `PWE/docker/entrypoint.sh`; stage `base` ho instaluje do
  `/usr/local/bin/entrypoint.sh` a dědí ho všechny image **včetně image webu**. Web vlastní kopii nemá
  (generátor ji nevytváří, `Dockerfile` webu `ENTRYPOINT` nenastavuje; dřív byla v každém webu a `ADD`
  ji kopíroval do image). Oproti dřívějším kopiím ve webech pracuje jen v adresáři s `conf/web.conf`, symlink
  `conf/database.conf` vyměňuje atomicky (repliky nad stejným adresářem nikdy nevidí stav bez konfigurace),
  běžný soubor `conf/database.conf` nepřepíše, s `PWE_PROFILE=static` nebo bez profilu symlink nemění a chyba
  zápisu (souborový systém jen pro čtení) start neshodí. Když `PWE_PROFILE` neodpovídá webu (neznámá hodnota,
  databázový profil bez `conf/<profil>.conf`, symlink nejde nastavit, `static` se zbylým symlinkem), vypíše
  jednořádkové varování `[entrypoint] VAROVANI: …` na stderr; start se nikdy nepřeruší.
- **CI:** nová pipeline GitHub Actions `.github/workflows/images.yml` běží při `push` do libovolné větve, který
  mění `PWE/**`, `docker-bake.hcl`, `.dockerignore`, `LICENSE` nebo workflow (a ručně): sestaví všech sedm image,
  v čerstvém `pwe-base` spustí testy enginu (`run-tests.sh`, `perl-compile.sh`) a kouřové kontroly image
  a teprve potom je publikuje pro `linux/amd64` a `linux/arm64` do `ghcr.io/<vlastník repozitáře>`
  (přihlášení vestavěným `GITHUB_TOKEN`). U pull requestu jen sestaví a otestuje, nepublikuje. Větev, jejíž
  název by dal stejný tag jako `master` nebo výchozí větev, pipeline odmítne. Volitelně image
  zrcadlí na Docker Hub (proměnná repozitáře `DOCKERHUB_NAMESPACE`, tajemství `DOCKERHUB_USERNAME`
  a `DOCKERHUB_TOKEN`). Nové balíčky v `ghcr.io` jsou soukromé, dokud jim vlastník nenastaví viditelnost
  (ručně u každého ze sedmi); pro soukromé je potřeba `docker login ghcr.io`.
  - Krok *Meta* odmítá i větev, jejíž tag má tvar verze `X.Y.Z` (zaměnil by se s `pwe:<verze>`), a větev,
    která dává stejný tag jako jiná větev repozitáře (`feature/kosik` a `feature-kosik`).
  - Publikující běh se už neruší novým pushem (ruší se jen běhy pull requestů); publikuje jen běh, jehož
    commit je stále hlavou větve (*Re-run* starého běhu image nepřepíše).
  - `linux/arm64` se sestaví v emulaci a projde kouřovými kontrolami **před** publikací; krok publikace nic
    nestaví (obě platformy z mezipaměti builderu) a index doplní anotacemi OCI `source`, `licenses`
    a `description`. Kouřové kontroly jsou samostatný skript `PWE/tools/smoke-images.sh` (lokálně
    `make images-check`), mezipaměť má obory `images-<cíl>-amd64` a `images-<cíl>-arm64`, souhrn běhu vznikne
    i po chybě.
  - Nový lehký workflow `.github/workflows/tests.yml` pouští testy enginu pro změny vzorových webů,
    `docker-compose.yml`, `docker-compose/`, `kubernetes/` a `Makefile` (nic nepublikuje).
  - Akce jsou připnuté na SHA commitu; nové verze navrhuje Dependabot (`.github/dependabot.yml`, týdně),
    push do větví `dependabot/**` workflow nespouští.
- **Nástroje:** výchozí image pro `make test`, `compile`, `check`, `cgi`, `module` a `smtp-test` je
  `ghcr.io/kukam/pwe-debugger:<větev>` (dřív `kukam/pwe-mariadb:latest`). Registr a tag určují nové proměnné
  `PWE_IMAGE_REGISTRY` (výchozí `ghcr.io/kukam`) a `PWE_IMAGE_TAG` (výchozí aktuální větev gitu, bez gitu
  `master`); `PWE_TEST_IMAGE` zůstává jako úplné přepsání. Pravidla jsou na jednom místě: shell funkce
  v `PWE/tools/lib/images.sh` (jde načíst z bash i zsh, nebo spustit `bash PWE/tools/lib/images.sh <funkce>`)
  a `PWE::ToolEnv::image_registry()`, `image_tag()`, `image_tag_sanitize()`, `image_tag_valid()`, `docker_image()`;
  jejich shodu hlídají `t/14-tools.t` a `t/21-image-tools.t`. Nástroje použitý image vypisují (`[run-tests] image …`, `[run-webapp] … registr=… tag=…`)
  a když v místním Dockeru není, poradí (`make images` a tagy téhož image, které v místním Dockeru jsou).
  Neplatný `PWE_IMAGE_TAG` (nepřevedený název větve) nástroje odmítnou. `docker-compose.yml` bere
  stejné proměnné (`fcgi` = `pwe-<profil>`, `debugger` = `pwe-debugger`; bez `PWE_IMAGE_TAG` tag `master`),
  `make run` je nastavuje; služba `debugger` má `init: true` (zastavení stacku nečeká na vypršení limitu).
- **Pojistky nástrojů:** `make images ARGS=--push` skončí chybou bez určitelného tagu (odpojený `HEAD`, kopie
  bez gitu) a z pracovní kopie s necommitnutými změnami (obejití `--allow-dirty`), bez `--platform` publikuje
  `linux/amd64,linux/arm64`; tag tvaru `X.Y.Z` odmítá vždy. `make test` drží zámek pracovní kopie
  `PWE/t/.run-tests.lock` (souběžný běh čeká nejvýš `PWE_TEST_LOCK_WAIT` s, výchozí 600). `make cgi` se
  připojí k síti a databázi jen stacku téhož webu (u stacku jiného webu skončí web s databází kódem 2).
  `make run` odmítne neznámý profil nebo příkaz a varuje, když profil neodpovídá `conf/` webu. `make new`
  a `make module` vyžadují `WEB` zadaný výslovně. Nový test `t/21-image-tools.t` (shellové nástroje kolem
  image s falešným `git` a `docker`).
- **`Dockerfile` webu** (šablona generátoru i vzorové weby): profil je do image zapečený
  (`ENV PWE_CONF_pwe_home=… PWE_PROFILE=<profil>`), takže `entrypoint.sh` připraví `conf/database.conf`
  i bez `-e PWE_PROFILE`. Šablona kopíruje web přes `COPY` (místo `ADD`), nemá `ADD … entrypoint.sh`
  ani `ENTRYPOINT`, znovu deklaruje `ARG PWE_IMAGE_REGISTRY`, `PWE_IMAGE_TAG` a `PWE_PROFILE`, nastavuje
  vlastní popisky (`LABEL` title, description, `base.name`; `source` a `licenses` prázdné k doplnění)
  a už při sestavení (`RUN`) zakládá pracovní adresáře a symlink `conf/database.conf` — image webu tak
  běží i s kořenovým souborovým systémem jen pro čtení. Záhlaví obsahuje příkazy sestavení (z image aktuální
  větve, větve `master` a s enginem připnutým na `$(cat PWE/VERSION)`). Kořenový `.dockerignore` nově
  vynechává i `**/.git` (weby mají vlastní git), `webapps/*/conf/local.env` a `webapps/*/conf/database.conf`
  — image webu nezávisí na stavu pracovní kopie
  (profil, se kterým web naposledy běžel přes `make run`, ani lokální hesla se do něj nedostanou).
- **Soukromé klíče se do image webu nezapékají:** `.dockerignore` vynechává i `webapps/*/conf/**/*.pem`, `*.key`,
  `*.p12` a `*.pfx` (veřejné klíče `*.pub` zůstávají) a lokální nastavení vývojáře `webapps/*/.env`
  a `webapps/*/.vscode`. Dřív se privátní klíč uložený na dokumentovaném místě (`conf/csob/private.pem` e-shopu)
  dostal do image a s ním do registru. **Nasazení, které na klíč v image spoléhalo, ho musí kontejneru dodat za
  běhu** — mountem nebo secretem, cestu přes `PWE_CONF_*` (např. `PWE_CONF_csob_private_key=/run/secrets/…`);
  bez něj platba v režimu `test`/`production` končí chybou `error_payment_keys` (`docs/17-nasazeni.md`, „Image
  vlastního webu“; `docs/22-platebni-brana-csob.md`, §10).
- **Oprava (nginx ve vývojovém stacku):** `docker-compose/docker-compose_nginx.conf` má upstreamy `pwe_balancer`
  a `pwe_balancer_debug` s parametrem `resolve` (sdílená zóna + `resolver 127.0.0.11`), takže nginx sleduje
  změny adres kontejnerů. Dřív si je přeložil jen při svém startu: po znovuvytvoření kontejnerů `fcgi` nebo
  `debugger` (např. `make run` po `make images`) posílal requesty na staré adresy a `/debug.cgi` mohlo skončit
  u běžného procesu `fcgi` místo u debuggeru.
- **`Libs::Pics`:** programy ImageMagick `/usr/bin/identify` a `/usr/bin/convert`, které modul volá, v dosavadním
  image **chyběly** (byl v něm jen Perl modul `Image::Magick`), takže `getInfo` a `convert` v kontejneru
  nefungovaly. `pwe-base` nově obsahuje balíček `imagemagick`.
- **Obsah základu:** závislosti jsou vyjmenované výslovně a instalují se bez doporučených balíčků; sestavení
  samo ověří, že `/usr/bin/sass`, `/usr/bin/identify` a `/usr/bin/convert` existují a moduly enginu jdou načíst.
  Ze základu zmizely `node-less` (engine `lessc` nepoužívá), `IO::AIO` (potřebuje ho jen `Perl::LanguageServer`
  → je v `pwe-debugger`), DB ovladače (→ profilové image) a celý ladicí blok (→ `pwe-debugger`). `Cz::Cstocs`
  a `Class::MOP` jsou z balíčků Ubuntu (`cstocs`, `libmoose-perl`) a `Perl::LanguageServer` v `pwe-debugger`
  z balíčku `libperl-languageserver-perl` — `cpanm` se při sestavení žádného image nespouští (sestavení nezávisí
  na CPAN a projde i v emulaci `linux/arm64`). Image jsou díky tomu výrazně menší (základ zhruba 410 MB místo
  1,4 GB).
- **Složení základu zúžené na to, co se používá:** z `pwe-base` odešly `libwww-perl` (`LWP::UserAgent`),
  `liblwp-protocol-https-perl`, `libdata-uuid-perl`, `libdata-guid-perl`, `libcrypt-openssl-x509-perl` a `curl`
  (`curl` je nově v `pwe-debugger`); HTTPS klient kódu webu je `HTTP::Tiny` + `IO::Socket::SSL`, `LWP::MediaTypes`
  zůstává ze samostatného balíčku. Přibyl `tzdata` — image dál běží v UTC, ale pásmo jde nastavit:
  pro requesty přes `fastcgi_param TZ` webserveru nebo `/etc/localtime` kontejneru (samotná proměnná `TZ`
  kontejneru platí jen při startu enginu, FastCGI ji v requestu nahradí prostředím od webserveru). Sestavení navíc ověří `/usr/bin/openssl`, pásmo `Europe/Prague`
  a načtení `Crypt::OpenSSL::RSA`, `URI`, `HTML::Parser`. `cpanm` v `pwe-debugger` stahuje z CPAN jen přes
  HTTPS (`PERL_CPANM_OPT`). **Web, který odebrané knihovny používá, si je musí přidat ve svém `Dockerfile`**
  (`docs/17-nasazeni.md`, „Přidání knihovny“).
- **Co musí udělat existující web a nasazení** (`docs/17-nasazeni.md`, „Přechod ze starého uspořádání image“):
  - **nový `Dockerfile`** — místo `FROM kukam/pwe-base:latest` šablona se dvěma image: běh z
    `ghcr.io/kukam/pwe-<profil>:<větev>`, engine zkopírovaný z `ghcr.io/kukam/pwe:<větev nebo verze>`
    (`COPY --from=engine /PWE/PWE /PWE/PWE`); argumenty sestavení `PWE_IMAGE_REGISTRY`, `PWE_IMAGE_TAG`,
    `PWE_ENGINE_TAG` (připnutí enginu na verzi, např. `2.2.0`) a `PWE_PROFILE` (zapečený i jako proměnná
    prostředí image). Řádek `ENV PWE_CONF_pwe_core=/PWE/PWE` v něm už není (má ho `pwe-base`). Sestavení:
    `docker build --build-arg PWE_IMAGE_TAG=<větev> -t <image> -f webapps/<web>/Dockerfile .`
    (image enginu z místního Dockeru — `make images` —, jinak z registru; prostý `docker build` místní image
    vidí, jen `docker buildx build` s vybraným builderem typu `docker-container` ne — pak
    `--builder <builder s ovladačem docker> --load`, název ukáže `docker buildx ls`).
    Starý `Dockerfile` nad novým základem nenastartuje — základ engine nenese;
  - `entrypoint.sh` webu **smazat** a `Dockerfile` nahradit výstupem generátoru (image webu vstupní skript dědí
    z `pwe-<profil>`); web se starou šablonou funguje dál, ale s vlastní starou kopií skriptu bez varování;
  - knihovnu, která byla ve starém základu a v novém není (`lessc`, `IO::AIO`, překladač, `cpanm`, `curl`,
    `LWP::UserAgent`, `Data::UUID`, `Data::GUID`, `Crypt::OpenSSL::X509`, DB ovladač jiného profilu), přidat
    do `Dockerfile` webu; časové pásmo nastavit přes `fastcgi_param TZ` webserveru nebo `/etc/localtime`;
  - skripty a CI s `PWE_TEST_IMAGE=kukam/pwe-…:latest`: proměnnou odebrat (výchozí image nástrojů se odvodí
    z větve), nebo nahradit `PWE_IMAGE_TAG` / `PWE_IMAGE_REGISTRY`;
  - vlastní compose a Kubernetes manifesty: `kukam/pwe-<profil>:latest` → `ghcr.io/kukam/pwe-<profil>:<větev>`;
    VS Code v režimu `run`: image `ghcr.io/kukam/pwe-debugger:<větev>`.

**Nasazení do Kubernetes** (2026-11-15; engine beze změny):

- Nové nasazení webu jako **image webu** obecným chartem `oci://registry.nixys.ru/nuc/nxs-universal-chart`
  verze 3.2.2: `kubernetes/values-example-static.yml` (`webapps/example.web`, bez databáze) a
  `kubernetes/values-example-mariadb.yml` (`webapps/example-db.web` + MariaDB), vzory `kubernetes/secrets-example-mariadb.example.yml`
  a `kubernetes/local.env.example`, návod `kubernetes/README.md`. Pod = nginx (statika) + engine, HTTPS na ingressu
  s certifikátem z cert-manageru, nasazení podle digestu image.
- Cíle `make k8s-image | k8s-template | k8s-deploy | k8s-status | k8s-test | k8s-logs | k8s-delete K8S=<název>`
  (skript `PWE/tools/k8s.sh`, release `pwe-<název>`). Cílový cluster jen přes povinný `KUBE_CONTEXT` —
  skript nikdy nepoužije aktuální kontext `kubectl` a každému příkazu `helm` i `kubectl` ho předává výslovně.
- Pojistky skriptu: argumenty měnící cluster nebo kontext (i v `K8S_HELM_ARGS`) se odmítají, `make k8s-template`
  bez `KUBE_CONTEXT` běží s prázdným kubeconfigem, `make k8s-image` odmítne místní image enginu pro jinou
  platformu, `make k8s-deploy` bez zjištěného digestu image skončí chybou (`K8S_ALLOW_TAG=1`) a nevygeneruje nová
  hesla, když release nebo svazek databáze už existuje (`K8S_NEW_SECRETS=1`); soubor s hesly vzniká s právy 0600.
  Test `PWE/t/22-k8s-tool.t` (falešné helm, kubectl, docker a curl) hlídá i to, že `.gitignore` a `.dockerignore`
  nepustí `kubernetes/local.env` a `kubernetes/secrets-*.yml` do gitu ani do image.
- Values: `startupProbe` (engine otevře socket až po připojení k databázi a migracích; liveness ho nezabije
  uprostřed migrace), `preStop` 5 s, pody bez tokenu service accountu a bez linuxových oprávnění, `NetworkPolicy`
  (do podů webu jen port 80, databáze jen od podů webu), vypnuté trasování DBI, `generic.pweHost` pro vlastní adresu,
  časové pásmo pro requesty přes `fastcgi_param TZ` v nginx podu.
- Smazané: historický `kubernetes/kubernetes.yml`, `kubernetes/helmfile-*-values.yml` a kořenový `helmfile.yaml`
  (starý chart, image `kukam/pwe:latest`, vložený self-signed certifikát s klíčem).
- Generátor webu zakládá `conf/<profil>.conf` s `loglevel => 0` (dřív 1 = trasování každého SQL včetně vázaných
  hodnot do `log/<ovladač>`). Existující weby si hodnotu upraví samy.
- Známé omezení enginu ve verzi 2.2.0 (**opraveno ve 2.2.1**, viz výše): zámek migrace schématu
  (`dbversion.lockid`) zůstane nastavený, když proces skončí uprostřed migrace, a další starty pak čekají
  donekonečna; handler SIGTERM v `PWE/pwe.fcgi` odpojí databázi i pod rozpracovaným požadavkem. `startupProbe`
  a `preStop` riziko v Kubernetes zmenšují, neodstraňují.

**Vývojové profily `mysql` a `postgres`** (2026-11-15; oba profily s aktuálními image `mysql:latest` (MySQL 26.10)
a `postgres:latest` (PostgreSQL 18) nenastartovaly — chyba nesouvisí s novým uspořádáním image, starý
`kukam/pwe-mariadb:latest` selhal stejně):

- **Oprava (`Libs::MyDBI::DRIVER::MySQL`, MySQL 8+):** engine se nepřipojil k serveru, jehož účet používá výchozí
  plugin `caching_sha2_password`. `DBD::mysql` se připojuje nešifrovaně a server plné ověření hesla po nešifrovaném
  spojení odmítne — chyba klienta 2061 `Authentication plugin 'caching_sha2_password' reported error:
  Authentication requires secure connection.`; procesy `fcgi` se jen restartovaly. Ovladač nově po chybě 2061
  pokus zopakuje s volbou DSN `mysql_ssl=1` (TLS bez ověření certifikátu serveru). První pokus je stejný jako
  dřív, takže MariaDB a MySQL s `mysql_native_password` se připojují beze změny (ověřeno: MariaDB 13.0,
  MySQL 8.0 s oběma pluginy, MySQL 26.10). Výměnu veřejného klíče serveru (`mysql_get_server_pubkey`) použít
  nešlo — sestavení `DBD::mysql` 4.053 z Ubuntu 26.04 tu volbu nezná a tiše ji ignoruje.
- **Nový volitelný klíč `dsn_options`** v `conf/<profil>.conf` (sekce `dbi`, oba ovladače): doplňkové volby DSN
  oddělené středníkem, které se připojí za `dbi:mysql:dbname=…;host=…;port=…` (resp. `dbi:Pg:…`) — např.
  `"mysql_ssl=1"`, `"mysql_connect_timeout=5"`, `"sslmode=require"`. Výchozí hodnota je prázdná = DSN stejný jako
  dřív. Obsahují-li volby `mysql_ssl=…`, řídí šifrování jen ony a záložní pokus se nedělá (`mysql_ssl=0` ho vypne).
  Popis: `docs/03-struktura-webu.md` a `docs/09-databaze-a-entity.md`.
- **Diagnostika připojení:** ovladače ukládají chybu neúspěšného `connect()` (`getError()`, `error()`)
  a `Libs::MyDBI::createConnection` ji píše do logu: `Connect to mysql dbid:db1 connect_status:0 error:2003
  Can't connect to MySQL server on 'mysql:3306' (111)` (dřív jen `connect_status:0`). Heslo ani DSN v hlášce nejsou.
- **`Libs::MyDBI::DRIVER::MySQL::connect`:** nepodaří-li se čtecí spojení, zapisovací se už nezkouší; podaří-li se
  jen čtecí, zase se odpojí (dřív zůstalo otevřené do konce procesu).
- **Oprava (`docker-compose.yml`, PostgreSQL 18+):** volume služby `postgres` se mountuje na `/var/lib/postgresql`
  (dřív `/var/lib/postgresql/data`). Image `postgres` od verze 18 ukládá data do `/var/lib/postgresql/<major>/docker`
  a mount na původní cestě odmítne (`Error: in 18+, these Docker images are configured to store database data
  in a format which is compatible with "pg_ctlcluster"…`), kontejner se jen restartoval. Volume `pwe_postgres_<web>`
  založený starším image (PostgreSQL ≤ 17) nový image nepřevezme — vývojovou databázi je potřeba založit znovu
  (`make down WEB=<web> PROFILE=postgres ARGS=-v`), nebo data převést (`pg_upgrade`, dump a obnova).
- **Testy:** `t/10-drivers.t` — složení DSN, `dsn_options`, záložní pokus přes TLS, chyba připojení v `getError()`
  a v logu (29 → 85 testů).

Infrastruktura a nástroje (API enginu beze změny):

- Základní image (`PWE/docker/Dockerfile`, dnes `pwe-base`) nově obsahuje `IO::Socket::SSL`, `Net::SSLeay`,
  `LWP::UserAgent` s `LWP::Protocol::https`, `Crypt::OpenSSL::RSA`, `Crypt::OpenSSL::X509`, `curl` a `ca-certificates`
  — weby mohou volat HTTPS API a podepisovat RSA (platební brány). (15. 11. 2026 z `pwe-base` opět odešly
  `LWP::UserAgent`, `LWP::Protocol::https`, `Crypt::OpenSSL::X509` a `curl` — viz „Nové uspořádání image a CI“;
  HTTPS klient je `HTTP::Tiny` + `IO::Socket::SSL`.) Kořenový `.dockerignore` vynechává
  `webapps-example`, `.git` a dočasná data webů z build kontextu.
- `docker-compose.yml`: volumes databází, uploadů a session jsou pojmenované podle webu (`pwe_mariadb_<web>`, …),
  takže weby si při `make run WEB=…` nesdílejí databázi (dřív druhý web přeskočil své migrace, protože tabulka
  `dbversion` už byla na vyšší verzi); nginx servíruje i `/uploadfile/` (volume s nahranými soubory je namountovaný
  do `webproxy`); nová služba `mailpit` (SMTP sink s UI na http://127.0.0.1:8025) pro e-maily z `Services::Email`.
- **Bezpečnostní oprava:** `templates/DumpData.tmpl` (vývojový výpis proměnných) mazal z živého stashe Template
  Toolkitu klíč `_PARENT`, čímž rozbil lokalizaci proměnných. Od 2.1.0 engine drží objekt `Template` v cache,
  takže proměnné jednoho renderu (včetně dat jiného uživatele, např. statistik administrace) zůstávaly ve sdíleném
  stashi a objevovaly se v dalších requestech téhož procesu. Šablona teď dumpuje mělkou kopii a
  `Libs::Web::genTmpl` po každém renderu obnoví kořenový stash (`resetTemplateStash`) — ani šablona s chybným
  `[% PERL %]` blokem už nemůže data propustit dál. Regresní testy v `t/17-performance.t`.
- `pwe.fcgi`: při POST bez `page`/`func` v těle se cíl vezme z query stringu (`CGI::url_param`) — callbacky
  platebních bran a webhooky s cizím tělem mohou mít stránku v URL; `page`/`func` v těle mají přednost (regresní
  test `t/13-regressions.t`).
- `templates/messenger.html`: titulek chybové zprávy padá na `rb.messanger_error_title` z vzhledu (dřív chyběl
  fallback a úspěšná větev testovala špatný klíč); regresní test `t/16-ui-templates.t`.
- `PWE/tools/new-webapp.pl`: úvodní stránka s Bootstrap 5 markupem (dřív třída `jumbotron` z Bootstrapu 3);
  odkazy generovaných README na novou dokumentaci.
- Dokumentace přepsána do 22 kapitol (`docs/`), viz `docs/README.md`; historie oprav je v příloze tohoto souboru.

Bezpečnost a nové metody (z revize e-shopu nad enginem; API zpětně kompatibilní):

- **Session fixation:** `Libs::User::newRequest` přijme jen cookie přesného tvaru `C0`/`C1` + 32 hex
  znaků (dřív `is_md5hex` pustilo libovolně dlouhý hex, např. `C0ABC`, a engine pro něj založil
  session). Nová `Libs::User::regenerateSid()` vygeneruje nové sid (C0/C1 podle HTTPS + md5) a
  `Services::Session::regenerate()` k tomu smaže starý řádek `session`, založí nový se stejnými daty
  (včetně vlastních sloupců webu) a drží ho pro `flush`; novou cookie pošle nejbližší
  `printHttpHeader()` sám. Služba účtu webu má `regenerate()` volat po každém přihlášení
  (`docs/11`). Testy `t/04-user.t`, `t/19-session.t`.
- `Services::Session::newSession` při založení nové session příležitostně (první a pak každá
  `http.session_cleanup_every`-tá, výchozí 20.; `0` = vypnuto) smaže expirované řádky
  (`DELETE FROM session WHERE expire < <unix čas>`); dřív se expirovaný řádek mazal jen při návratu
  stejného sid, takže requesty bez cookie (cron přes `curl`, roboti) plnily tabulku navždy.
  Test `t/19-session.t`.
- `Pages::pweCreator`: akce zapisující soubory (`cpage`, `cservice`, `csite`, `centity`) vrací 401,
  když `pwe.development` není pravdivé; názvy (`pagename`, `servicename`, `sitename`, `entityname`,
  `dbtable`, `default_site`, `default_service`) mají `rules` na identifikátor (písmeno, pak
  písmena/číslice/podtržítko, max. 64 znaků) s chybovými klíči v `rb.tmpl`/`rb_EN.tmpl`. Dřív mohl
  každý se skupinou `admin` (u e-shopu správce objednávek) zapisovat kód a skládat cesty
  z parametru. Test `t/18-pwecreator.t`; `PWE::TestEnv->boot(conf => {...})` umí přepsat conf.
- Nový vstupní bod `debug.cgi` v adresáři enginu pro ladění ve VS Code (`"program": "${workspaceFolder}/PWE/debug.cgi"`,
  nginx `location /debug.cgi` → kontejner `pwe-debugger-1`): načte `pwe.fcgi` (`require` s absolutní cestou) pod
  jménem `debug.cgi`, takže engine požadavky na `/debug.cgi` obslouží jako stránky a odkazy vedou zpět do laděného
  procesu. Od rozdělení na engine a weby (1.0.0) tento vstup chyběl a postup z dokumentace (`program` = `pwe.fcgi`)
  končil chybou — engine bere request jako stránku jen při shodě `SCRIPT_FILENAME` s názvem skriptu. Pod debuggerem
  (`perl -d`) navíc `debug.cgi` po přerušení signálem INT zopakuje čekání na další request: VS Code posílá INT při
  každé změně breakpointu a při Pause, což dřív čekající FastCGI server ukončilo. Bez debuggeru se INT/Ctrl-C chová
  beze změny. `PWE::ToolEnv::run_cgi` má volbu `entry => 'debug.cgi'`; regresní testy `t/20-debug-entry.t`
  (nad fixture `app2`: relativní spuštění, přenos chyby startu, INT pod debuggerem přes skutečný FastCGI request)
  a `t/11-smoke-example.t` (zdroják `debug.cgi`/`pwe.fcgi` se jako statický soubor neservíruje); `t/00-compile.t`
  a `make compile` kompilují i `debug.cgi`. Postup a nastavení rozšíření (jazykový server v kontejneru,
  `perl.pathMap`, `reloadModules: false`) jsou v `docs/16-nastroje.md`.
- `docker-compose.yml`: bind mounty jsou relativní k souboru (`.:/PWE` místo `${PWD}:/PWE`), takže `docker compose`
  funguje i z podadresáře repozitáře (dřív by se z adresáře enginu namountoval špatný kořen); služba `debugger`
  načítá stejný volitelný `webapps/<web>/conf/local.env` jako `fcgi`. `conf/local.env` je nově v `.gitignore`
  i `.dockerignore` (tajné údaje se nedostanou do gitu ani do image webu).
- `Libs::Config`: přepis z prostředí `PWE_CONF_<sekce>_<klíč>` funguje i pro sekce s podtržítkem
  v názvu (`PWE_CONF_smtp_primary_authpw` → `smtp_primary.authpw`); dřív se jméno dělilo na prvním
  podtržítku a SMTP heslo tak z prostředí nastavit nešlo. Test `t/01-config.t`.
- Nový nástroj `PWE/tools/smtp-test.pl` (`make smtp-test WEB=… ARGS='--to …'`): odešle testovací
  e-mail přes SMTP z konfigurace webu (včetně `PWE_CONF_*` a `conf/local.env`), `--dry-run` vypíše
  výsledné nastavení s maskovaným heslem. `docker-compose.yml` načítá volitelný
  `webapps/<web>/conf/local.env` (SMTP účet a hesla mimo git). Test `t/14-tools.t`.
- `PWE/tools/new-module.pl`: kontrola existence vzhledu (`--site`, `--parent`) a služeb (`--services`)
  počítá i s moduly enginu povolenými v `pwe.core_sites` / `pwe.core_services` (dřív hlásil
  „vzhled Responsive ve webappu neexistuje“, i když ho web z enginu používal). Test `t/14-tools.t`.
- `assets/javascript/pwe.js`: `AjaxFormAppender` po úspěchu už neroluje nepodmíněně na
  `#messenger` — rolování řídí success handler podle odpovědi (položka `messenger` bez
  `disable_scrolltomessenger`); formulář se dál vynuluje. „Do košíku“ u karty dole na stránce
  tak uživatele neodhodí nahoru. Test `t/16-ui-templates.t`.

## 2.1.0 — 2026-11-08

Výkon a robustnost (bez změny API stránek; viz `docs/19-engine-internals.md`):

- `Libs::Web::genTemplateObject` drží jeden objekt `Template` na sadu voleb po celou dobu života
  procesu (dřív nový objekt při každém renderu): render stránky ve fixture 1,63 ms → 0,21 ms.
- `Pages::systemPage::file`: Content-Type podle přípony (`%MIME`: obrázky, fonty, pdf, json, …),
  soubor inline bez session cookie přes novou `templates/HttpHeaderStatic.tmpl`, čtení po 64 kB
  blocích; dřív šlo vše kromě js/css/svg/woff2 jako `application/octet-stream` + `attachment`
  (obrázky a favicon se stahovaly místo zobrazení). `HttpHeaderOctetStream.tmpl` bez středníku v typu.
- nginx v compose servíruje `/assets/` a `/static/` přímo z disku (web, pak `PWE/assets`),
  engine je jen záloha (`docker-compose/docker-compose_nginx.conf`, volumes a `PWE_WEBAPP` u služby `webproxy`).
- `Libs::MyDBI::testConnection` pinguje spojení nejvýše jednou za `pwe.db_ping_interval` s
  (výchozí 60; 0 = každý request jako dřív); MySQL driver pinguje přes `DBI->ping` místo dvou
  `SELECT 1`. Vzorový web `db_pool => 3` (dřív 5).
- `Services::Session`: entita načtená v `newSession` se použije i ve `flush` (dřív druhý SELECT
  téhož řádku); UPDATE a commit jen při změně hodnoty; `flush` bez dat nic nedělá. Vedlejší
  oprava: dřív druhý SELECT + zápis zrcadlených dat posílal při každém requestu UPDATE sloupce
  `created` na text `current_timestamp()` (výchozí hodnota z metadat místo načtené hodnoty).
- `Libs::MyDBI::DAO::commit` vyprázdní seznam změn (`getChangeList`), takže entitu lze držet
  přes celý request a další `flush` na ní nezapíše znovu už potvrzené sloupce (`flush` sám seznam
  nemaže, aby po něm šel zavolat `logit`).
- `Libs::User::writeFile`: opts soubor se zapisuje atomicky (`.tmp` + `rename`), souběžné
  requesty nečtou rozepsaný soubor; chyba zápisu se loguje místo pádu.
- `Libs::Log::sendErrorReport`: stejná chyba (`název:kdo:metoda`) se e-mailem hlásí nejvýše jednou
  za `log.error_report_interval` s (výchozí 300, 0 = vždy), potlačené se počítají do dalšího
  reportu; vrací 1/0. `write` drží otevřený handle logu (autoflush, znovuotevření po rotaci).
- Volání metod stránek/služeb/vzhledů/entit/validátorů přes blokový `eval { }` s
  `local $SIG{__DIE__}` místo řetězcového `eval "..."` (žádná kompilace při každém volání,
  `$SIG{__DIE__}` se už nepřepisuje globálně); `require`/`new` modulů zůstávají řetězcové s `local`.
- Drivery MySQL/Postgre: `prepare_cached` pro SELECT/INSERT/UPDATE/DELETE; `Libs::MyDBI` přidává
  komentář s místem volání do SQL jen při `log.loglevel >= 3` (jinak každé místo = jiný text
  dotazu a cache nefunguje).
- Nové konfigurační klíče (generátor je zapisuje): `pwe.db_ping_interval`, `log.error_report_interval`.

## 2.0.0 — 2026-11-08

**Breaking:** výchozí UI knihovny enginu jsou Bootstrap **5.3.8** a jQuery **4.0.0**
(`PWE/assets/css/bootstrap-5.3.8/`, `PWE/assets/javascript/bootstrap-5.3.8/`,
`PWE/assets/javascript/jquery-4.0.0/`). Bootstrap 3.x/5.2.3 a jQuery 1.x/2.x/3.x byly
z `PWE/assets` i z adresáře archivů `sources/` (tehdy `core/sources`, dnes neexistuje) odstraněny;
sdílené šablony používají Bootstrap 5 markup (`data-bs-*`, `btn-close`, `.accordion`,
`.pagination .page-item`, `form-select`, …):

- `templates/messenger.html`, `templates/LayoutErrorHeader.html`, `LayoutErrorBody.html`
- `Pages/formExamples`, `Pages/pweCreator`, `Pages/ajaxExamples` (`badge text-bg-*` místo `label label-*`)
- `Services/DBTable/pagination.html`, `pager.html` (Bootstrap 5 nemá `.pager`), `orderby.html`
  (ikony Font Awesome místo glyphicons)
- `assets/javascript/pwe.js`: `form.on("submit")` místo zastaralého `form.submit(fn)`;
  šablony používají `$(function(){...})` místo `$(window).load(...)` (odstraněno už v jQuery 3);
  všechny funkce `pwe.js` a `ajaxprogress.js` mají popis (co dělají, parametry, použití ze šablon);
  oprava: po JSON odpovědi s messengerem se stránka odroluje na `#messenger`, pokud šablona
  neobsahuje `#disablescrolltomessenger` (dřív se díky chybné podmínce neodrolovala nikdy);
  `scrollToMessenger()` nespadne na stránce bez `#messenger`; `ajaxprogress.js` pozná češtinu
  podle `lang="cs"` i `cs_CZ`
- odstraněna stránka a vzhled `NewBootstrap523` (nedokončený pokus, nahrazen výchozím Bootstrapem 5)
- `Pages/css`: výchozí cesty `static/css/site.css` / `static/scss/site.scss`

**Odstraněno (úklid nepoužívaného kódu):**

- moduly `Libs/GoogleGraph.pm` (Google Chart API je ukončené; jediný uživatel byl historický web `lz`),
  `Libs/jQuery/File/Upload.pm` (nikdo nepoužíval) a prázdný driver `Libs/MyDBI/DRIVER/Oracle.pm`
  (hodnota `dbdriver => "oracle"` teď skončí chybou "Unknown database driver")
- metody bez jediného použití: `Libs::Sites::validate` (pravidla `rules` se na vzhledy nikdy neposílala),
  `Libs::Pages::getPagesDir`, `Libs::Sites::getSitesDir`, `Libs::Services::getServicesDir`,
  `Libs::Entities::getEntitiesDir` (nahrazeno `Libs::Config::getModuleRoots`), `Libs::MyDBI::DAO::existsError`,
  `Libs::User::getLastParams`, `Libs::Validate::must_be_defined`, `isnot_equal_to`, `validate_numeric_vat`,
  `Services::UserAccount::getSessionValue`, `getGroupValue`
- šablony `templates/HttpHeader550.tmpl` a `HttpHeaderPDF.tmpl` (`printHttpHeader` je nikdy nevydával)
- z adresáře enginu (tehdy `core/`) zmizely `lib/Libs` (symlink pro Komodo debugger) a `sources/*` (archivy
  knihoven třetích stran — odkud je stáhnout, je v `PWE/README.md`), dále nepoužívané varianty Font Awesome
  (`assets/javascript/fontawesome-*`, `assets/images/fontawesome-*`, `assets/scss/fontawesome-*`; layouty
  potřebují jen `assets/css` a `assets/fonts`)

Web postavený na Bootstrapu 3 (např. historické weby ve `webapps-example/`) musí při přechodu
na tuto verzi buď přejít na Bootstrap 5, nebo si přebít sdílené šablony vlastními
(`templates/messenger.html`, `Services/DBTable/*.html` ve webu mají přednost) a nést si
vlastní kopii Bootstrapu 3 ve `static/`.

## 1.0.0 — 2026-11-08

- Engine přesunut z kořene repozitáře do samostatného adresáře enginu (tehdy `core/`, od 2.2.0 `PWE/`),
  weby ve `webapps/<web>` bez symlinků.
- Dva kořeny: `pwe.home` (web) + `pwe.core` (engine), `Libs::Config::getRoots/getModuleRoots/
  resolveFile/checkCoreVersion`; web vyjmenuje moduly enginu v `pwe.core_pages/core_sites/
  core_services/core_entities`, `pwe.require_core` hlídá verzi.
- Opravy chyb jádra a POD ke všem metodám — viz příloha na konci tohoto souboru.

## Příloha: opravy enginu před verzí 1.0.0 (2026-11-08)

Přehled chyb jádra nalezených a opravených při revizi enginu (původně v docs/12-testy-a-kvalita.md).

### Provedené opravy enginu (2026-11-08)

Všechny opravy jsou kryty testy v `PWE/t/` (viz `docs/18-testy.md`). Cesty k nástrojům a testům jsou níže
psané podle dnešního názvu adresáře enginu `PWE/`; v době ověření to byl `core/` (`core/tools/…`, `core/t/`).

Ověřeno 2026-11-08 (2. kolo): `PWE/tools/perl-compile.sh` bez chyb (vč. `PWE/tools/*.pl`), `PWE/tools/run-tests.sh`
15 souborů / 724 testů zelených; web vygenerovaný `PWE/tools/new-webapp.pl --db mariadb --examples` spuštěný přes
`PWE/tools/run-webapp.sh` s MariaDB: migrace `dbversion` 1–2, stránky default/kontakt (z `new-module.pl`)/formExamples/
NewBootstrap523/pweCreator 200, 404 pro neznámou stránku, `static/css/site.css` i `assets/javascript/pwe.js`
servírovány, `conf/web.conf` 401, `PWE/tools/pwe-cgi.sh` přes síť compose. První kolo (12 souborů / 547 testů) ověřilo
integrační běh `COMPOSE_PROFILES=mariadb docker compose up` (generic webapp,
MariaDB, nginx): migrace `dbversion` 1–3, stránky default/dbTableExamples/NewBootstrap523/
pweCreator 200, AJAX INSERT a toggle, validační chyba s textem z rb, upload s názvem
`../../evil.txt` uložen jen do upload adresáře, 404 pro neznámou stránku, CSS přes `systemPage`.

| Soubor | Oprava |
|--------|--------|
| `Libs/Log.pm` | Překlep `$self-- > info(...)` v `sendErrorReport` — při selhání odeslání reportu metoda spadla. |
| `Libs/Config.pm` | `getValue` vracelo default i pro hodnoty `0` a `''` (nešlo vypnout např. `tmpl.evalperl`). Nyní jen `undef` = nenastaveno. |
| `Libs/Pages.pm` | `registerResourceBundle`: `my @paths = []` vkládalo prázdnou referenci jako první cestu; `close(DIR)` místo `closedir`; neošetřený `opendir`. |
| `Libs/Pages.pm` | `getPnameCname` testovalo `$_` místo `$value` (fungovalo jen náhodou). |
| `Libs/Pages.pm` | Po pádu metody se stránka znovu načetla, ale bez injektáže `Site_*`/`Service_*` a bez resource bundlů → ztráta i18n textů. Přidáno `reloadPage`. |
| `Libs/Pages.pm` | `checkExist` dotazoval natvrdo `db1`; nyní přes DAO entity (její spojení/dbid). |
| `Libs/Pages.pm` | Reset iterátoru `each()` nad sdílenými hashi `replace`/`rules` (hash je atribut stránky a přežívá requesty). |
| `Libs/Pages.pm` | POD `callPageFunc` popisoval návratové kódy 0–4, skutečnost je 200/404/401/500/400. |
| `Libs/MyDBI.pm` | `createDAO`: `next` mimo smyčku při neznámém typu tabulky → `return undef`. `getDAO` s hashem bez `where` už nevolá `refreshTABLE` s prázdnou podmínkou. |
| `Libs/MyDBI/DAO.pm` | `existsInternalMethodName` kontrolovalo neexistující paket `Libs::DAO` — ochrana proti sloupci pojmenovanému jako interní metoda nikdy nefungovala. |
| `Libs/MyDBI/DAO.pm` | TINYINT sloupce: volalo se `$VALIDATE->is_tinyint($dbdriver, …)`, takže se validoval řetězec „mysql“ → TINYINT nešel nikdy zapsat. Nové `is_sql_tinyint`. |
| `Libs/MyDBI/DAO.pm` | `refreshTABLE`: větev „řádek nenalezen“ byla mrtvá (`ref({}) eq "HASH"`). |
| `Libs/MyDBI/DRIVER/MySQL.pm`, `Postgre.pm` | `setError()` bez statementu nemazal předchozí chybu (po `command`/`commit` „visela“ až do dalšího selectu). `DESTROY` na nepřipojeném objektu. Cesta k `logfile` relativně k `pwe.home` sjednocena. |
| `Libs/Validate.pm` | `is_email` odmítal TLD delší než 4 znaky a znak `+`; `is_sql_*` pro neznámý driver vracely `''` místo `undef`; `is_sql_boolen` pro MySQL vracel vždy chybu (TODO); přidán alias `is_sql_boolean` a `is_sql_tinyint`. |
| `Libs/Send.pm` | `hello` bral hodnotu z klíče `host`; volba `starttls` se ignorovala; `_validEmail` stejné TLD omezení; dvojí volání `_findInvalidEmail`. |
| `Libs/User.pm` | `flush`: `mkdir` nebyl rekurzivní → bez existujícího `opts_dir` se opts tiše neukládaly. `exportUserData`: `Storable` padal na GLOB (upload) → po každém uploadu spadl celý request (`exportParameters`). `saveUploadFile`: jméno souboru od klienta ořezáno na `basename` (ochrana proti `../`), kontrola `open`, `binmode`. `newRequest`: ošetřeno `undef` sid/HTTPS. |
| `Libs/Web.pm` | Expirace cookie byla vždy 100 dní (`http.cookie_expire_day` v konfiguracích není); nyní fallback na `http.cookie_expire_guest`. `convertToRewrite` odstraní i úvodní `_`. |
| `Entities/MailQueue/MailQueue.pm` | Getter `attachment` dekódoval `undef`. |
| `Libs/GoogleGraph.pm` | Překlepy `defcolorline`/`schorten`, volba `maxc` vs `maxv`. (Modul byl později odstraněn, viz 5. kolo.) |
| `Libs/jQuery/File/Upload.pm` | `Net::SSH2` se načítá až při použití scp. (Modul byl později odstraněn, nikdo ho nepoužíval.) |
| `Services/Email/Email.pm` | `addEmailToQueue` ignoroval klíč `textalt` (alternativní tělo se nikdy neuložilo); report administrátorovi obsahoval SQL s neexistující tabulkou `mail_queue` (správně `mailqueue`). |
| `Services/DBTable/DBTable.pm` | Návrat na stranu 1 při změně řazení/počtu řádků porovnával `existParam` (0/1) s uloženou hodnotou → podmínka platila vždy; nyní se porovnává hodnota parametru s uloženou. |
| `Libs/MyDBI.pm` | `reconnect`: `die` před `ping` → o jeden pokus víc než `trayconnect` a poslední pokus bez ověření, při nenastaveném `trayconnect` `die` hned bez pingu. `createDAO`: při plném poolu dostal nesdílený DAO spojení 0 a při zániku ho **odemkl** (sdílené spojení pak mohl dostat další DAO) — nyní se DAO označí jako sdílený. |
| `Libs/MyDBI/DRIVER/MySQL.pm`, `Postgre.pm` | `commit`/`rollback` vracely stav ze `setError()` (SQLSTATE) místo výsledku DBI; log `Commit … result:` tak tiskl nesmysl. |
| `Libs/Pages.pm` | `checkExist`/`checkParameters`/`checkUnique` vracely při chybějícím `entity`/`primary` **řetězec** místo pole chyb → metoda `error` stránky spadla na `@{$error}` (500). |
| `Libs/User.pm` | `getValue` bez podklíče vracelo `undef` místo defaultu pro existující, ale nenastavený atribut (`getActivePage()` → `undef` místo `default`); mrtvý kód v `delOpts`. |
| `Libs/GoogleGraph.pm` | `GetMaxCount` porovnával referenci na pole místo počtu prvků. (Modul odstraněn.) |
| `PWE/assets/javascript/pwe.js` | Po AJAX JSON odpovědi s messengerem se nikdy neodrolovalo na `#messenger` (`.find(...)` je vždy pravdivé, chyběl `.length`); `scrollToMessenger` padal bez `#messenger`. Doplněny popisy všech funkcí (`getAjaxAppender` mělo „TODO: dopsat popis“). |
| POD (kontrola autorových popisků) | Všech 167 původních `=head2` bloků autora enginu zkontrolováno proti aktuálnímu kódu a přepsáno (zastaralé signatury — `sendErrorReport`, `genTableData`, `addResourceBundlePagePath`, `setMessenger`, `command`, `lastInsertID`…, chybné příklady, překlepy, slovosled, MySQL-ismy v Postgres driveru). `registerResourceBundle` označeno `[Private]`, driverové metody dostaly `[Public]`/`[Private]`. |
| POD | Chybné názvy hlaviček (`readOpts`→`readFile`, `importOpts`, `exportOpts`, `writeOpts`, `ConvertToRewrite`, `GetDAO`, `SetLink`→`SetLine`), neplatné direktivy `=DB`/`=README`/`=DESCRIPTIONS`. Doplněny `=head2` popisky ke **všem** metodám a `=head1 NAME` ke všem modulům. |
