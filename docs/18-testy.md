# 18 — Testy

Engine má sadu automatických testů v `PWE/t/` (26 souborů, přes 4800 testů), které se spouštějí
v kontejneru. Web se ověřuje nástroji `check-webapp.pl`, CGI požadavky a integračně přes
compose; vlastní testy webu lze psát stejným způsobem jako testy enginu.

`PWE/` je zde vždy adresář enginu v kořeni repozitáře (`PWE/t/`, `PWE/tools/`); v kontejneru, kde je
repozitář namountovaný do `/PWE`, je to `/PWE/PWE`.

## Testy enginu

```bash
make test                                   # celá sada: prove -r t v /PWE/PWE (kontejner z image pwe-debugger)
make test ARGS='-v t/06-pages.t'            # jeden soubor, podrobně (cesta relativně k adresáři enginu PWE/)
make compile                                # perl -c všech modulů enginu, pwe.fcgi, debug.cgi a skriptů v PWE/tools
PWE_IMAGE_TAG=latest make test              # image s tagem latest místo image verze pracovní kopie
PWE_TEST_IMAGE=ghcr.io/kukam/pwe-base:latest PWE/tools/run-tests.sh   # jiný image (takto testuje CI)
PWE_TEST_LOCK_WAIT=0 make test              # nečekat na jiný běžící běh testů (hned kód 2)
```

`prove` běží v kontejneru s pracovním adresářem `/PWE/PWE` (adresář enginu), proto se soubor testu
zadává jako `t/06-pages.t` — ne `PWE/t/06-pages.t` (takovou cestu by `prove` hledal až uvnitř adresáře
enginu, kde žádný podadresář `PWE/` není).

**Image pro testy.** Výchozí je `ghcr.io/kukam/pwe-debugger:<verze>` (registr `PWE_IMAGE_REGISTRY`,
tag `PWE_IMAGE_TAG`, jinak verze enginu z `PWE/VERSION` — na gitu ani větvi nezávisí);
`PWE_TEST_IMAGE` přepíše celý název (tag se pak nezjišťuje). `pwe-debugger`, `pwe-base` ani ostatní
závislostní image kód enginu neobsahují a i tam, kde v image je (image webu včetně `pwe-example-*`), ho
překryje pracovní kopie namountovaná do `/PWE` — testy běží vždy nad ní. Když image této verze neexistuje (typicky po zvýšení `PWE/VERSION`),
`make images` ho sestaví lokálně ([16 — Nástroje](16-nastroje.md#výběr-image)). Skript na začátku
vypíše, který image použil (`[run-tests] image ghcr.io/kukam/pwe-debugger:2.2.1`, u `make compile`
`[perl-compile] image …`), a když v místním Dockeru není, přidá radu, jak ho získat. Sada musí projít
i v holém `pwe-base` (bez DB ovladačů a ladicích nástrojů) — tak ji pouští pipeline, viz [CI](#ci).

Skripty před spuštěním odstraní proměnné prostředí zapečené v image: všechny `PWE_CONF_*`
(`PWE_CONF_pwe_core=/PWE/PWE` má `pwe-base` a všechny image z něj, image webu — vlastního i vzorového —
navíc `PWE_CONF_pwe_home`) a `PWE_PROFILE`, jinak by engine v testech četl cizí konfiguraci.
Odstraní i `FCGI_SOCKET_PATH` — v image zapečená není, ale mají ji kontejnery
compose stacku (`docker-compose/docker-compose_common.env`) a engine by s ní místo jednoho CGI requestu začal
poslouchat na socketu. Testy běží **bez databáze** (DB vrstva nad mock objekty); skutečná DB se
ověřuje integračně.

### Souběžné běhy (zámek pracovní kopie)

Testy sdílejí dočasná data (`PWE/t/fixtures/app*/ramdisk`, `webapps/example*.web/ramdisk`), takže
dva souběžné běhy nad **toutéž pracovní kopií** by si je navzájem přepisovaly a oba by selhaly.
`run-tests.sh` (`make test`) si proto po dobu běhu založí zámek — adresář `PWE/t/.run-tests.lock`
(v `.gitignore`) se souborem `pid` — a na konci ho smaže, i po `Ctrl+C` nebo `kill` (pak skončí kódem
130, resp. 143). Zámek platí pro každý běh, i pro jediný test; `make compile` ho nepoužívá.

- Drží-li zámek jiný běžící běh, skript jednou ohlásí
  `[run-tests] nad touto pracovni kopii bezi jiny beh testu (PID <pid>, zamek …) - cekam, az skonci (nejvys 600 s; PWE_TEST_LOCK_WAIT=0 = necekat)`
  a čeká nejvýš `PWE_TEST_LOCK_WAIT` sekund (výchozí 600); pak skončí kódem 2. `PWE_TEST_LOCK_WAIT=0`
  = nečekat, hned kód 2; jiná než celočíselná hodnota = kód 2.
- **Opuštěný zámek převezme sám** (`[run-tests] prevzat opusteny zamek …`): když proces ze souboru
  `pid` už neběží, když jeho číslo mezitím dostal jiný program (po pádu nebo restartu stroje), nebo
  když zámek zůstal déle než 5 s bez souboru `pid`. Zbylou značku `PWE/t/.run-tests.lock/takeover`
  (běh zabitý uprostřed přebírání) po zhruba 2 s smaže sám (`[run-tests] smazana znacka prebirani …`)
  a zámek převezme.
- Když opuštěný zámek převzít nejde z jiného důvodu, běh to zkouší po dobu `PWE_TEST_LOCK_WAIT`
  (`[run-tests] zamek … je opusteny (…), ale nejde prevzit - zkousim to dal …`) a pak skončí kódem 2
  s radou `… koncim. Smaz ho: rm -rf <cesta k zámku>`. Hláška `jiny beh testu (PID …) neskoncil ani
  po … s` tak znamená opravdu běžící běh.
- Když zámek založit nejde, nebo opuštěný zámek nejde převzít, protože se do adresáře nedá zapisovat
  (souborový systém jen pro čtení, práva), běh pokračuje bez zámku s varováním
  `POZOR: zamek … nejde zalozit … pokracuji bez zamku`, resp.
  `POZOR: opusteny zamek … nejde prevzit - do adresare se neda zapisovat … pokracuji bez zamku`.

Návratový kód `run-tests.sh` je návratový kód `prove`.

| Soubor | Oblast |
| --- | --- |
| `00-compile.t` | `perl -c` všech modulů, `pwe.fcgi`, `debug.cgi`, nástrojů |
| `01-config.t` | `Libs::Config`: načtení, `getValue`, přepis z `PWE_CONF_*` |
| `02-log.t` | úrovně, filtry, `delay`, soubor, `sendErrorReport`, otevřený handle |
| `03-validate.t` | validátory včetně `is_sql_*`, `validate([...])`, AUTOLOAD |
| `04-user.t` | session cookie, parametry, skupiny, opts, messenger, upload |
| `05-web.t` | `genTmpl` a automatické proměnné, rb, HTTP hlavičky, layouty, AJAX JSON |
| `06-pages.t` | loadery, injektáž, autostart, routing, práva, validace, pád a reload |
| `07-dao.t` | DAO nad mock spojením: validace sloupců, UNIQUE, INSERT/UPDATE/DELETE, pool |
| `08-send.t` | `Libs::Send` |
| `09-dbtable-service.t` | stránkovací seznam `DBTable` |
| `10-drivers.t` | drivery MySQL/Postgre: chyby, pool lock, `prepare_cached`, ping, složení DSN a `dsn_options`; **zámek spojení** `sessionLock`/`sessionUnlock` (MySQL `GET_LOCK` se jménem `pwe.<jméno>.<databáze>`, PostgreSQL poradní zámek úrovně session, čekání, chyby, uvolnění ve zrušené transakci) |
| `11-smoke-example.t` | end-to-end vzorový web bez DB v CGI režimu |
| `12-email-service.t` | `Services::Email` nad mock entitou |
| `13-regressions.t` | drobné regrese (`reconnect`) |
| `14-tools.t` | `new-webapp.pl`, `new-module.pl`, `check-webapp.pl`, `smtp-test.pl --dry-run`: vygenerovaný web se zkompiluje a obslouží requesty, `conf/<profil>.conf` má klíče `dbversion_session_lock` a `dbversion_legacy_lock_wait`; **názvy image** (`PWE::ToolEnv` proti shell funkcím `tools/lib/images.sh`: výchozí tag = verze z `VERSION` bez gitu, nástroje nemají název image napevno); **`Dockerfile` webu** (kontroly nad instrukcemi šablony: jediný `FROM` — `pwe-<profil>` u webu s databází, `pwe-base` u webu bez databáze —, žádný image `pwe`, `COPY --from` ani `PWE_ENGINE_TAG`, `COPY --link` pro **každou** položku adresáře `PWE/` kromě `t`, `docker` a `tools`, právě jeden `RUN` a žádné mazání, žádné `ENTRYPOINT`, `ADD`, `USER` ani `entrypoint.sh`, znovu deklarované `ARG`, `LABEL`, zapečený `PWE_PROFILE`, pořadí instrukcí; příkaz `RUN` s `mkdir` spuštěný přes `/bin/sh`; `Dockerfile` vzorových webů = výstup generátoru; web ani výpis generátoru `entrypoint.sh` nemají); **`check-webapp.pl` nad `Dockerfile` ze starších šablon** (varování se znaky staré šablony a radou k přegenerování, `Dockerfile` webu bez databáze u webu s `conf/<profil>.conf`); **vstupní skript `docker/entrypoint.sh`** (symlink `conf/database.conf` podle `PWE_PROFILE`, dočasné adresáře, běh mimo adresář webu, varování na stderr včetně chybějícího ovladače databáze — s falešným `perl` v `PATH`, aby výsledek nezávisel na ovladačích testovacího image — a varování o vzorovém webu zapečeném v image (ne nad pracovní kopií), běh bez práv roota nad adresářem jen pro čtení); **`Dockerfile` závislostních image** (pět stage `base`, `mariadb`, `mysql`, `postgres`, `debugger`, jediná instrukce `COPY` = vstupní skript — žádný kód enginu ani web —, přesný seznam balíčků stage `base`, `curl` jen v `debugger`, `PERL_CPANM_OPT`, `ENTRYPOINT` jen v `base`); **`.dockerignore`** (soukromé klíče a lokální soubory webu se do image nedostanou, veřejné `*.pub` ano; dočasná data a `conf/database.conf` webů ani testy enginu `PWE/t` se nedostanou do žádného image); **`docker-compose.yml`** (služba `fcgi` bere image z `PWE_FCGI_IMAGE` s výchozím `pwe-<profil>`, služby `fcgi` a `debugger` berou registr a tag z proměnných s výchozím `latest` a entrypoint nepřepisují, `debugger` má `init: true`); nástroje a šablony nezmiňují zrušené image `pwe` a `pwe-static` jinde než při jejich odmítnutí. Čte skutečný adresář `PWE/`: zapomenutý soubor přímo v něm (záloha editoru, `nytprof.out`) shodí kontrolu úplnosti `COPY` |
| `15-two-roots.t` | dva kořeny: fixture web `t/fixtures/app2` mimo engine, `core_*`, přebití modulu, statika, verze |
| `16-ui-templates.t` | sdílené šablony Bootstrap 5, přítomnost assetů |
| `17-performance.t` | cache `Template`, MIME statiky, ping interval, session bez druhého SELECTu, atomický zápis opts, limit reportů |
| `18-pwecreator.t` | `pweCreator` jen při `pwe.development` (jinak 401), pravidla na názvy modulů (400), vytvoření modulů nad fixture `app2` |
| `19-session.t` | `Services::Session::regenerate` (nové sid, přenos dat) a `cleanupExpired` (úklid expirovaných řádků) nad mock DAO |
| `20-debug-entry.t` | ladicí vstup `debug.cgi` nad fixture `app2`: CGI režim (shoda `SCRIPT_FILENAME` s názvem skriptu), spuštění relativní cestou, návratový kód při chybě startu, FastCGI server pod debuggerem (`perl -d`) a signál INT (server a klient FastCGI z `PWE::TestServer`) |
| `21-image-tools.t` | shellové nástroje kolem image (`tools/lib/images.sh`, `build-images.sh`, `run-tests.sh`, `perl-compile.sh`, `pwe-cgi.sh`, `run-webapp.sh`, `smoke-images.sh`), `Makefile` a pravidla `docker-bake.hcl` a `.github/workflows/images.yml`: tag = verze z `PWE/VERSION` bez gitu a bez ohledu na větev (`pwe_image_version`, shoda s `PWE::ToolEnv`), názvy image a závislostní image profilu (`pwe_image_names`, `pwe_profile_image`), kontrola `PWE_IMAGE_TAG`, rada při chybějícím image (cíl sestavení, zrušené image `pwe` a `pwe-static`), `build-images.sh` s devíti cíli, tagy `<verze>` a `latest`, pojistkou `--push`, odmítnutím zrušených cílů a upozorněním na neuložený základ vzorového cíle, hodnoty voleb, zámek pracovní kopie (i zbylá značka přebírání a opuštěný zámek, který nejde převzít), připojení `make cgi` jen ke stacku téhož webu, neznámý profil, varování a `PWE_FCGI_IMAGE` v `run-webapp.sh` (`static` → `pwe-base`), kouřové kontroly (závislostní image bez enginu a webu, image vzorových webů nad základem téhož tagu, srovnání obsahu s pracovní kopií, `--tree`/`--no-tree`, `SKIP`), recepty cílů `Makefile` (text vždy, `make -n` jen když je v image `make`, tedy ne v `pwe-base`), základ image připnutý na digest ve všech voláních bake, každý z 9 cílů bake s tagy `<verze>` a `latest`, vzorové cíle se základem z téhož volání (`contexts` odpovídá řádku `FROM` `Dockerfile` vzorového webu) a s popisky. Git a docker nahrazují falešné programy na začátku `PATH`; nástroje běží z kopie v dočasném stromu (s vlastním zámkem a vlastním `PWE/VERSION`, ne se zámkem vnějšího běhu). Jen moduly jádra Perlu. Změna receptu v `Makefile`, nový cíl nebo delší hlavička `make help` znamená upravit tabulky v testu |
| `22-k8s-tool.t` | `tools/k8s.sh` (cíle `make k8s-*`): bez `KUBE_CONTEXT` se ke clusteru nic nepřipojí, každý `helm`/`kubectl` dostane kontext výslovně, přepínače měnící cluster se odmítnou; nasazení podle digestu; **vzorové nasazení** z image vzorového webu (všechny čtyři `pwe-example-*`; registr a tag verze z `PWE/VERSION`, příkaz `image` nic nestaví, nesoulad `pweImage` s `pweWeb` nebo s profilem), **vyhrazené názvy** image PWE (i s cestou; názvy jen podobné projdou), neplatný název image a neznámý profil, a **vlastní web** (`K8S_REGISTRY`, výchozí tag `latest`, argumenty `docker buildx build` bez `PWE_ENGINE_TAG`, závislostní image podle profilu — `static` → `pwe-base` — a kontrola jeho platformy, odmítnutí `Dockerfile` ze starší šablony); ochrana hesel (chybějící soubor s hesly při nezjistitelném stavu clusteru, pojistka `delete`), hesla ze vzoru `secrets-<název>.example.yml`, `kubernetes/local.env`, kontrakt values souborů (`ghcr.io/kukam`, `latest`, `FCGI_SOCKET_PATH` `127.0.0.1:7779`, žádný `containerPort` 7779), `.gitignore`/`.dockerignore` pro místní nastavení a hesla. `helm`, `kubectl`, `docker`, `curl` a `openssl` nahrazují falešné programy — ke clusteru ani registru se test nepřipojuje; skript běží z kopie v dočasném stromu s vlastním `PWE/VERSION`; bez adresáře `kubernetes/` se přeskočí. Křížové kontroly: šablona generátoru (`webapps/example*.web/Dockerfile`) je pro skript přijatelná, stage v `PWE/docker/Dockerfile`, `pwe_image_names` z `images.sh` a varování o vzorovém webu z `PWE/docker/entrypoint.sh`, které cituje `kubernetes/README.md` |
| `23-dbversion-lock.t` | zámek migrace `Libs::MyDBI::checkDbversion` nad falešnou databází v paměti (bez skutečné DB): pořadí operací nad čistou databází, nic k migraci = žádný zápis, převzetí opuštěného zámku `lockid` (záporný hned, kladný až po `dbversion_legacy_lock_wait` beze změny), čekání na zámek spojení, režimy bez zámku spojení, dva současně startující procesy, tabulka bez řádku, chyba kroku a selhání zápisu verze, uvolnění zámků na všech cestách ven, `requestStop` při čekání, před migrací a mezi kroky, opakování připojení v `new()`. Každý scénář má hlídač času (`alarm`), takže návrat původní chyby sadu nezablokuje |
| `24-shutdown.t` | ukončování a socket `pwe.fcgi` nad **skutečným FastCGI serverem** (fixture `app2`): jednorázové CGI, `TERM` v nečinnosti, uprostřed requestu (odpověď celá, databáze připojená do konce requestu, socket zavřený hned, kód 0), těsně před čekáním na request a během startu (i přerušení `Libs::MyDBI` čekající na nedostupnou databázi — jen s `DBD::mysql`, v `pwe-base` se přeskočí), `USR1`, jiný signál, spojení držené webserverem, pomalý odesílatel, prázdná spojení; `FCGI_SOCKET_PATH=127.0.0.1:<port>`, unix socket s právy 0770, `FCGI_SOCKET_PERM`, neplatná hodnota, obsazený port. Čeká jen na události (`wait_for`), nikdy pevnou dobu |
| `25-pipeline.t` | workflow GitHub Actions: skripty kroků se vyjmou z YAML a spustí v `bash` s prostředím, jaké jim dává GitHub — krok *Meta* (kdo publikuje: výchozí větev, proměnná `PUBLISH_BRANCHES`, pull request, gitový tag; verze z `PWE/VERSION`), krok *Branch head* (s falešným `git`) a tři kroky s bake z `images.yml` i sestavení v `tests.yml` (s falešným `docker` a `jq`: všech 9 cílů, platforma, mezipaměť, připnutý základ, místní jména `arm64`, anotace každého image, stejné proměnné pro bake ve všech voláních, porušení pravidla cílů a tagů = nic se nestaví); přesný seznam 9 cílů v `BAKE_TARGETS` a jeho shoda se skupinou `default` v `docker-bake.hcl`, zákaz `pwe-static` a samostatného image `pwe`; podmínky přihlašovacích a publikačních kroků vyhodnocené pro `pull_request`, `push` i `workflow_dispatch`; job nemá `if`, pořadí kroků, akce připnuté na SHA, časové limity; bake dostává jen `REGISTRIES`, `VERSION`, `SOURCE`, `REVISION`, `CREATED` (žádný tag podle větve), cesty `on.push.paths` = `on.pull_request.paths` = `IMAGE_PATHS` včetně vzorových webů (pod některou z nich leží každý zdroj `COPY` v `Dockerfile` vzorových webů), seznamy cest Images a Tests se nepřekrývají. Nic nestaví a k registru se nepřipojuje; bez `.github/workflows` se přeskočí |

Fixture weby: `PWE/t/fixtures/app/` (web uvnitř enginu, jeden kořen) a `PWE/t/fixtures/app2/`
(web mimo engine, dva kořeny). Dočasná data jdou do `PWE/t/fixtures/app*/ramdisk/`. Stránka
`tPage2` webu `app2` má jen pro testy ukončování akce `slow` (pomalý request řízený značkami
v `ramdisk/`) a `plen` (délka přijatého těla).

> `11-smoke-example.t`, `14-tools.t` a `16-ui-templates.t` pracují se vzorovými weby ve
> `webapps/example*.web`; bez nich se příslušné testy přeskočí (`skip_all`, v `14-tools.t` jen
> kontroly vzorových webů), nebo je potřeba upravit na vlastní web. `14-tools.t`, `21-image-tools.t`,
> `22-k8s-tool.t` a `25-pipeline.t` čtou i soubory mimo adresář enginu (`.dockerignore`,
> `docker-compose.yml`, `docker-bake.hcl`, `Makefile`, `kubernetes/`, `.github/workflows/`,
> `webapps/example*.web/Dockerfile`); kde
> chybějí, příslušné kontroly přeskočí.

## Pomocný modul `PWE::TestEnv`

`PWE/t/lib/PWE/TestEnv.pm` postaví engine stejně jako `pwe.fcgi` a umožní simulovat request:

```perl
use lib "$FindBin::Bin/lib";
use PWE::TestEnv;

my $E = PWE::TestEnv->boot(app => PWE::TestEnv::app2(), core => PWE::TestEnv::root());   # web + engine (dva kořeny); root() = adresář enginu PWE/
# volitelně conf => { sekce => { klíč => hodnota } } přepíše hodnoty web.conf jen pro tento test (např. pwe.core_pages)
my $out = PWE::TestEnv::capture(sub {
    PWE::TestEnv::request($E, page => 'tPage2', func => 'default', params => {x => 1}, sid => $sid);
    $E->{'PAGES'}->callPageFunc('tPage2', 'default');
});
like($out, qr/<html/, 'stranka se vykreslila');
PWE::TestEnv::finish($E);                       # flush všech vrstev
```

`$E` obsahuje singletony (`CONF`, `LOG`, `USER`, `WEB`, `PAGES`, …). Pro CGI běh celého enginu
slouží `PWE::ToolEnv::run_cgi($app, query => '…', post => '…', cookie => '…', script => '…')` a
`parse_response($out)` (`status`, `headers`, `body`) — používá je `check-webapp.pl` i smoke test.

Test, který potřebuje **běžící server**, použije `PWE/t/lib/PWE/TestServer.pm`: spustí vstupní skript
enginu (`pwe.fcgi`, `debug.cgi`) jako samostatný proces se socketem z `FCGI_SOCKET_PATH` a posílá mu
requesty protokolem FastCGI stejně jako nginx (TCP i unix socket):

```perl
use PWE::TestServer qw(free_port port_open wait_for start_server alive exit_status fcgi_get);

my $port = free_port();
my $pid  = start_server(script => "$ROOT/pwe.fcgi", cwd => $APP2, err => "$TMP/server.err",
    env => { %ENV_BASE, 'FCGI_SOCKET_PATH' => ":$port" });
wait_for(sub { port_open($port) }, 20) or die "server nenastartoval";
my ($done, $out) = fcgi_get($port, 'page=tPage2&func=default');
kill('TERM', $pid);
wait_for(sub { !alive($pid) }, 10);
my $st = exit_status($pid);                     # { code => 0, signal => 0 }
```

Používají ho `20-debug-entry.t` a `24-shutdown.t`. `PWE/t/lib/PWE/ShutdownHooks.pm` je modul jen pro
`24-shutdown.t`: načítá se do serveru volbou `perl -MPWE::ShutdownHooks` a podle proměnných
`PWE_TEST_*` zdrží start, napodobí přerušení `Libs::MyDBI`, přidá falešné databázové spojení nebo
pošle `TERM` v přesně daném okamžiku.

## Jak psát test enginu

1. Nová fixture stránka/služba patří do `PWE/t/fixtures/app/` nebo `app2/` (stejné konvence
   jako reálný modul; `rb.tmpl` končí prázdným řádkem).
2. Engine postav přes `PWE::TestEnv->boot`, request simuluj `request(...)`, výstup zachyť
   `capture`, request ukonči `finish`.
3. Úspěšný výsledek `callPageFunc` je `undef`/`''` **nebo `200`** (metoda končí `print`).
4. Každá oprava chyby má regresní test (v názvu „regrese“).
5. Test se skutečným serverem (`PWE::TestServer`) nikdy nečeká pevnou dobu — na událost (port
   poslouchá, proces skončil, soubor vznikl) čeká přes `wait_for`. Unix sockety zakládá v dočasném
   adresáři (`File::Temp`, tedy `/tmp`), ne v mountovaném repozitáři.
6. Test nesmí záviset na čísle verze enginu ani na větvi gitu; testy nástrojů si proto do dočasného
   stromu dávají vlastní `PWE/VERSION`. Sada musí projít i v `pwe-base` — co potřebuje DB ovladač
   nebo `make`, se tam přeskakuje (`skip`).
7. Před dokončením musí projít `make test` i `make compile`; změna kontraktu = zvýšit
   `PWE/VERSION` a zapsat do `PWE/CHANGELOG.md`.

## Test vlastního webu

### Statická kontrola a smoke

```bash
make check WEB=<web>                                           # struktura, konvence, rb, perl -c, smoke (bez DB)
make check WEB=<web> ARGS='--request "page=kontakt&func=default"'
make cgi WEB=<web> Q='page=kontakt&func=default' | head -20    # hlavičky + HTML, log na STDERR
```

### Jednotkový test webu v Perlu

Web může mít vlastní `t/` a používat `PWE::TestEnv` z enginu (web bez DB jde takto otestovat
celý):

```perl
#!/usr/bin/env perl
use strict; use warnings; use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../PWE/t/lib", "$FindBin::Bin/../../../PWE/tools/lib";
use PWE::TestEnv;
use PWE::ToolEnv qw(run_cgi parse_response);

my $app = "$FindBin::Bin/..";
my ($out, $err) = run_cgi($app, query => 'page=default&func=default');
my $r = parse_response($out);
is($r->{'status'}, 200, 'uvodni stranka 200');
like($r->{'body'}, qr/Můj web/, 'titulek');
unlike($err, qr/\[E\]/, 'bez chyb v logu');
done_testing();
```

Spuštění v kontejneru: `docker run --rm -v "$PWD":/PWE -e PWE_CONF_pwe_home= -e FCGI_SOCKET_PATH= -w /PWE ghcr.io/kukam/pwe-debugger:latest prove -I/PWE/PWE webapps/<web>/t`
(nebo tag verze, jejíž image máš místně — [16 — Nástroje](16-nastroje.md#výběr-image)).

### Integrační test webu přes compose

Web s databází se testuje proti běžícímu stacku. Vzor nad vzorovým webem `example-db.web` — celý
průchod vlastního webu je stejný skript s `curl`, cookie jar a kontrolami textu a návratových kódů
(přihlášení, formuláře a AJAX se testují stejně: POST s `page`/`func` v těle, u AJAXu `ajax_request=1`):

```bash
make run WEB=example-db.web PROFILE=mariadb ARGS=-d
BASE=http://127.0.0.1:7778/; JAR=$(mktemp)
curl -s -c $JAR -b $JAR "$BASE?page=default&func=default" | grep -q '</html>'                 && echo OK uvodni stranka
curl -s -o /dev/null -w '%{http_code}\n' -b $JAR -c $JAR "$BASE?page=dbTableExamples&func=default"   # 200: stránka nad databází
curl -s -o /dev/null -w '%{http_code}\n' -b $JAR -c $JAR "$BASE?page=neexistuje"                     # 404
docker compose -p pwe logs --no-log-prefix fcgi | grep '\[E\]' | grep -v 'Not-defined input\|Invalid rule\|Invalid input\|connect_status:0'   # musí být prázdné
make down WEB=example-db.web PROFILE=mariadb ARGS=-v
```

Poznámky: řádky `[E] … connect_status:0 … Can't connect` hned po startu jsou čekání enginu na databázi,
která se při prvním spuštění teprve zakládá (proto je výpis vynechává); cookie domain je `127.0.0.1`; POST posílá `page`/`func` v těle; AJAX requesty mají
`ajax_request=1` a vrací JSON; validační chyby jsou v logu jako `[E]` z `Libs::Pages`, ostatní
`[E]` znamenají problém.

## CI

Testy enginu běží ve dvou workflow GitHub Actions
([17 — Nasazení](17-nasazeni.md#pipeline-github-actions)):

- **`.github/workflows/images.yml`** staví a publikuje image. Spouští se při `push` do libovolné
  větve (kromě `dependabot/**`) a u pull requestů, pokud mění vstupy image — `PWE/**` kromě `PWE/t/**`
  a `PWE/tools/**` (testy a nástroje v image nejsou; jejich změna spouští jen workflow Tests — kromě kouřových kontrol
  `PWE/tools/smoke-images.sh` a `PWE/tools/lib/images.sh`, které workflow Images spouštějí dál),
  `docker-bake.hcl`, `.dockerignore`, `LICENSE`, vzorové weby `webapps/example.web/**`
  a `webapps/example-db.web/**` (vznikají z nich image vzorových webů) nebo samotný workflow —, a ručně
  (*Run workflow*). Sestaví všech devět image pro `linux/amd64`, v čerstvém **`pwe-base`** (engine
  v něm není, nástroje montují checkout do `/PWE`) spustí testy a kompilaci a pak kouřové kontroly
  všech image (`PWE/tools/smoke-images.sh --tree`). **Publikuje
  jen běh nad výchozí větví repozitáře a nad větvemi z proměnné repozitáře `PUBLISH_BRANCHES`**
  (před publikací ještě sestaví a zkontroluje `linux/arm64`); ostatní větve a pull requesty po
  kontrolách končí.
- **`.github/workflows/tests.yml`** pouští tytéž testy pro změny, které sada čte, ale image z nich
  nevznikají: `docker-compose.yml`, `docker-compose/**`, `kubernetes/**`, `.gitignore` a `Makefile`.
  Sestaví jen `pwe-base` (jen na runneru) a nic nepublikuje. Seznamy cest obou workflow se
  nepřekrývají.

V obou případech:

```bash
PWE_TEST_IMAGE=<registr>/pwe-base:<tag> PWE/tools/run-tests.sh
PWE_TEST_IMAGE=<registr>/pwe-base:<tag> PWE/tools/perl-compile.sh
```

(`<tag>` je v Images verze z `PWE/VERSION`, v Tests `latest`.)

Testy v `pwe-base` (ne v `pwe-debugger`) hlídají dvě věci najednou: že engine funguje a že základ
obsahuje všechny knihovny, které engine k běhu potřebuje — test, který by vyžadoval DB ovladač nebo
ladicí nástroj, tam neprojde (nebo se musí přeskočit: část `24-shutdown.t` potřebuje `DBD::mysql`,
`make -n` v `21-image-tools.t` program `make`). Při chybě se image nepublikují. Stejnou kontrolu lze
pustit lokálně: `make images ARGS=base`
a `PWE_TEST_IMAGE="$(bash PWE/tools/lib/images.sh pwe_image pwe-base)" make test`, kouřové kontroly
po `make images` přes `make images-check`. Nový test, který čte soubor mimo vstupy image a mimo cesty
workflow Tests, znamená doplnit cestu do `.github/workflows/tests.yml`; pravidla obou workflow
(kdo publikuje, devět image a jejich cíle, cesty, proměnné pro bake) hlídá `25-pipeline.t`.

Pro vlastní web (má vlastní repozitář a CI) je doporučený job `PWE/tools/check-webapp.pl <web>`
a případně compose stack s `curl` průchodem. Testy nad skutečnou DB zatím nejsou (image nemá
`DBD::SQLite`); DAO je testováno nad mockem.
