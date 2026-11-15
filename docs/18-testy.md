# 18 — Testy

Engine má sadu automatických testů v `PWE/t/` (23 souborů, přes 2100 testů), které se spouštějí
v kontejneru. Web se ověřuje nástroji `check-webapp.pl`, CGI požadavky a integračně přes
compose; vlastní testy webu lze psát stejným způsobem jako testy enginu.

`PWE/` je zde vždy adresář enginu v kořeni repozitáře (`PWE/t/`, `PWE/tools/`); v kontejneru, kde je
repozitář namountovaný do `/PWE`, je to `/PWE/PWE`.

## Testy enginu

```bash
make test                                   # celá sada: prove -r t v /PWE/PWE (kontejner z image pwe-debugger)
make test ARGS='-v t/06-pages.t'            # jeden soubor, podrobně (cesta relativně k adresáři enginu PWE/)
make compile                                # perl -c všech modulů enginu, pwe.fcgi, debug.cgi a skriptů v PWE/tools
PWE_IMAGE_TAG=master make test              # image větve master místo image aktuální větve
PWE_TEST_IMAGE=ghcr.io/kukam/pwe-base:master PWE/tools/run-tests.sh   # jiný image (takto testuje CI)
PWE_TEST_LOCK_WAIT=0 make test              # nečekat na jiný běžící běh testů (hned kód 2)
```

`prove` běží v kontejneru s pracovním adresářem `/PWE/PWE` (adresář enginu), proto se soubor testu
zadává jako `t/06-pages.t` — ne `PWE/t/06-pages.t` (takovou cestu by `prove` hledal až uvnitř adresáře
enginu, kde žádný podadresář `PWE/` není).

**Image pro testy.** Výchozí je `ghcr.io/kukam/pwe-debugger:<větev>` (registr `PWE_IMAGE_REGISTRY`,
tag `PWE_IMAGE_TAG`, jinak podle aktuální větve gitu); `PWE_TEST_IMAGE` přepíše celý název. Kód
enginu v žádném z těchto image není — testy běží nad pracovní kopií namountovanou do `/PWE`. Když
image pro větev neexistuje, `make images` ho sestaví lokálně
([16 — Nástroje](16-nastroje.md#výběr-image)). Skript na začátku vypíše, který image použil
(`[run-tests] image ghcr.io/kukam/pwe-debugger:pwe.ai`, u `make compile` `[perl-compile] image …`),
a když v místním Dockeru není, přidá radu, jak ho získat. Sada musí projít i v holém `pwe-base`
(bez DB ovladačů a ladicích nástrojů) — tak ji pouští pipeline, viz [CI](#ci).

Skripty před spuštěním odstraní proměnné prostředí `PWE_CONF_*` zapečené v image
(`PWE_CONF_pwe_core=/PWE/PWE` má `pwe-base` a všechny image z něj, image vlastního webu navíc
`PWE_CONF_pwe_home`), jinak by engine v testech četl cizí konfiguraci. Odstraní i `FCGI_SOCKET_PATH`
— v image zapečená není, ale mají ji kontejnery
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
  (běh zabitý uprostřed přebírání) je potřeba smazat ručně — hláška po vypršení čekání radí
  `rm -rf <cesta k zámku>`.
- Když zámek založit nejde (souborový systém jen pro čtení, práva), běh pokračuje bez zámku
  s varováním `POZOR: zamek … nejde zalozit … pokracuji bez zamku`.

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
| `10-drivers.t` | drivery MySQL/Postgre: chyby, pool lock, `prepare_cached`, ping |
| `11-smoke-example.t` | end-to-end vzorový web bez DB v CGI režimu |
| `12-email-service.t` | `Services::Email` nad mock entitou |
| `13-regressions.t` | drobné regrese (`reconnect`) |
| `14-tools.t` | `new-webapp.pl`, `new-module.pl`, `check-webapp.pl`, `smtp-test.pl --dry-run`: vygenerovaný web se zkompiluje a obslouží requesty; **názvy image** (`PWE::ToolEnv` proti shell funkcím `tools/lib/images.sh`, nástroje nemají název image napevno); **`Dockerfile` webu** (kontroly nad instrukcemi šablony: běh z `pwe-<profil>`, engine `COPY --from` image `pwe`, žádné `ENTRYPOINT`, `ADD`, `USER` ani `entrypoint.sh`, znovu deklarované `ARG`, `LABEL`, zapečený `PWE_PROFILE`, pořadí instrukcí; příkaz `RUN` šablony spuštěný přes `/bin/sh`; `Dockerfile` vzorových webů = výstup generátoru; web ani výpis generátoru `entrypoint.sh` nemají); **vstupní skript `docker/entrypoint.sh`** (symlink `conf/database.conf` podle `PWE_PROFILE`, dočasné adresáře, běh mimo adresář webu, varování na stderr, běh bez práv roota nad adresářem jen pro čtení); **`Dockerfile` enginu** (rodokmen stage, přesný seznam balíčků stage `base`, `curl` jen v `debugger`, `PERL_CPANM_OPT`, `ENTRYPOINT` jen v `base`); **`.dockerignore`** (soukromé klíče a lokální soubory webu se do image nedostanou, veřejné `*.pub` ano); **`docker-compose.yml`** (služby `fcgi` a `debugger` berou registr a tag z proměnných a entrypoint nepřepisují, `debugger` má `init: true`) |
| `15-two-roots.t` | dva kořeny: fixture web `t/fixtures/app2` mimo engine, `core_*`, přebití modulu, statika, verze |
| `16-ui-templates.t` | sdílené šablony Bootstrap 5, přítomnost assetů |
| `17-performance.t` | cache `Template`, MIME statiky, ping interval, session bez druhého SELECTu, atomický zápis opts, limit reportů |
| `18-pwecreator.t` | `pweCreator` jen při `pwe.development` (jinak 401), pravidla na názvy modulů (400), vytvoření modulů nad fixture `app2` |
| `19-session.t` | `Services::Session::regenerate` (nové sid, přenos dat) a `cleanupExpired` (úklid expirovaných řádků) nad mock DAO |
| `20-debug-entry.t` | ladicí vstup `debug.cgi` nad fixture `app2`: CGI režim (shoda `SCRIPT_FILENAME` s názvem skriptu), spuštění relativní cestou, návratový kód při chybě startu, FastCGI server pod debuggerem (`perl -d`) a signál INT |
| `21-image-tools.t` | shellové nástroje kolem image (`tools/lib/images.sh`, `build-images.sh`, `run-tests.sh`, `perl-compile.sh`, `pwe-cgi.sh`, `run-webapp.sh`) a pravidla `docker-bake.hcl`: tag podle větve a kontrola `PWE_IMAGE_TAG` (shoda s `PWE::ToolEnv`), pojistky `--push`, tag tvaru verze, hodnoty voleb, zámek pracovní kopie, připojení `make cgi` jen ke stacku téhož webu, neznámý profil a varování `run-webapp.sh`. Git a docker nahrazují falešné programy na začátku `PATH`; nástroje běží z kopie v dočasném stromu (s vlastním zámkem, ne se zámkem vnějšího běhu). Jen moduly jádra Perlu |
| `22-k8s-tool.t` | `tools/k8s.sh` (cíle `make k8s-*`): bez `KUBE_CONTEXT` se ke clusteru nic nepřipojí, každý `helm`/`kubectl` dostane kontext výslovně, přepínače měnící cluster se odmítnou; nasazení podle digestu, hesla ze vzoru `secrets-<název>.example.yml`, `kubernetes/local.env`, `.gitignore`/`.dockerignore` pro místní nastavení a hesla. `helm`, `kubectl`, `docker`, `curl` a `openssl` nahrazují falešné programy — ke clusteru ani registru se test nepřipojuje; bez adresáře `kubernetes/` se přeskočí |

Fixture weby: `PWE/t/fixtures/app/` (web uvnitř enginu, jeden kořen) a `PWE/t/fixtures/app2/`
(web mimo engine, dva kořeny). Dočasná data jdou do `PWE/t/fixtures/app*/ramdisk/`.

> `11-smoke-example.t`, `14-tools.t` a `16-ui-templates.t` pracují se vzorovými weby ve
> `webapps/example*.web`; bez nich se příslušné testy přeskočí (`skip_all`, v `14-tools.t` jen
> kontroly vzorových webů), nebo je potřeba upravit na vlastní web. `14-tools.t` čte i soubory mimo
> adresář enginu (`.dockerignore`, `docker-compose.yml`); kde chybějí, příslušné kontroly přeskočí.

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

## Jak psát test enginu

1. Nová fixture stránka/služba patří do `PWE/t/fixtures/app/` nebo `app2/` (stejné konvence
   jako reálný modul; `rb.tmpl` končí prázdným řádkem).
2. Engine postav přes `PWE::TestEnv->boot`, request simuluj `request(...)`, výstup zachyť
   `capture`, request ukonči `finish`.
3. Úspěšný výsledek `callPageFunc` je `undef`/`''` **nebo `200`** (metoda končí `print`).
4. Každá oprava chyby má regresní test (v názvu „regrese“).
5. Před dokončením musí projít `make test` i `make compile`; změna kontraktu = zvýšit
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

Spuštění v kontejneru: `docker run --rm -v "$PWD":/PWE -e PWE_CONF_pwe_home= -e FCGI_SOCKET_PATH= -w /PWE ghcr.io/kukam/pwe-debugger:master prove -I/PWE/PWE webapps/<web>/t`
(tag podle větve, jejíž image máš — [16 — Nástroje](16-nastroje.md#výběr-image)).

### Integrační test webu přes compose

Web s databází se testuje proti běžícímu stacku. Vzor (zkrácený) z tutoriálu — celý průchod
je skript s `curl`, cookie jar a kontrolami textu:

```bash
make run WEB=ukoly.web PROFILE=mariadb ARGS=-d
BASE=http://127.0.0.1:7778/; JAR=$(mktemp)
curl -s -c $JAR -b $JAR "$BASE?page=ukoly&func=default" | grep -q 'Seznam úkolů'            && echo OK seznam
curl -s -o /dev/null -w '%{http_code}\n' -b $JAR -c $JAR -X POST "$BASE" --data 'page=ukoly&func=add&title=x'   # 401 jako host
curl -s -b $JAR -c $JAR -X POST "$BASE" --data 'page=prihlaseni&func=login&login=admin&password=tajneheslo' -o /dev/null
curl -s -b $JAR -c $JAR -X POST "$BASE" --data 'page=ukoly&func=add&ajax_request=1' --data-urlencode 'title=Koupit mléko' | grep -q '"REPLACE"' && echo OK ajax
curl -s -o /dev/null -w '%{http_code}\n' -b $JAR -c $JAR -X POST "$BASE" --data 'page=ukoly&func=add&ajax_request=1&title='   # 400 validace
docker compose logs --no-log-prefix fcgi | grep '\[E\]' | grep -v 'Not-defined input\|Invalid rule\|Invalid input'   # musí být prázdné
make down WEB=ukoly.web PROFILE=mariadb ARGS=-v
```

Poznámky: cookie domain je `127.0.0.1`; POST posílá `page`/`func` v těle; AJAX requesty mají
`ajax_request=1` a vrací JSON; validační chyby jsou v logu jako `[E]` z `Libs::Pages`, ostatní
`[E]` znamenají problém.

## CI

Testy enginu běží ve dvou workflow GitHub Actions
([17 — Nasazení](17-nasazeni.md#pipeline-github-actions)):

- **`.github/workflows/images.yml`** staví a publikuje image. Spouští se při `push` do libovolné
  větve (kromě `dependabot/**`) a u pull requestů, pokud mění `PWE/**`, `docker-bake.hcl`,
  `.dockerignore`, `LICENSE` nebo samotný workflow, a ručně (*Run workflow*). Než cokoli nahraje do
  registru, sestaví image pro `linux/amd64`, v čerstvém **`pwe-base`** spustí testy a kompilaci
  a pak kouřové kontroly všech image (`PWE/tools/smoke-images.sh`, před publikací i pro
  `linux/arm64`).
- **`.github/workflows/tests.yml`** pouští tytéž testy pro změny, které sada čte, ale image z nich
  nevznikají: vzorové weby `webapps/example.web` a `webapps/example-db.web`, `docker-compose.yml`,
  `docker-compose/**`, `kubernetes/**` a `Makefile`. Sestaví jen `pwe-base` (jen na runneru) a nic
  nepublikuje.

V obou případech:

```bash
PWE_TEST_IMAGE=<registr>/pwe-base:<tag> PWE/tools/run-tests.sh
PWE_TEST_IMAGE=<registr>/pwe-base:<tag> PWE/tools/perl-compile.sh
```

Testy v `pwe-base` (ne v `pwe-debugger`) hlídají dvě věci najednou: že engine funguje a že základ
obsahuje všechny knihovny, které engine k běhu potřebuje — test, který by vyžadoval DB ovladač nebo
ladicí nástroj, tam neprojde. Při chybě se image nepublikují; pull request končí po testech
a kontrolách vždy bez publikace. Stejnou kontrolu lze pustit lokálně: `make images ARGS=base`
a `PWE_TEST_IMAGE="$(bash PWE/tools/lib/images.sh pwe_image pwe-base)" make test`, kouřové kontroly
po `make images` přes `make images-check`. Nový test, který čte soubor mimo `PWE/` a mimo cesty
workflow Tests, znamená doplnit cestu do `.github/workflows/tests.yml`.

Pro vlastní web (má vlastní repozitář a CI) je doporučený job `PWE/tools/check-webapp.pl <web>`
a případně compose stack s `curl` průchodem. Testy nad skutečnou DB zatím nejsou (image nemá
`DBD::SQLite`); DAO je testováno nad mockem.
