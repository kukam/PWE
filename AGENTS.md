# AGENTS.md — pokyny pro AI asistenty pracující s PWE

Tento soubor čtou AI nástroje (Claude Code, Cursor, Copilot, …) automaticky. Slouží
jako rychlá a závazná příručka pro generování a úpravu kódu nad **PWE (Perl Web
Engine)**. Plná dokumentace je ve složce [`docs/`](docs/README.md).

> **Co je co v repozitáři:**
>
> - [`PWE/`](PWE/README.md) = **engine** — adresář `PWE/` v kořeni repozitáře (`pwe.fcgi`,
>   `debug.cgi` = tentýž engine pod jiným jménem pro ladění ve VS Code přes nginx `/debug.cgi`,
>   `Libs/`, `templates/`, `assets/`, sdílené `Pages/ Sites/ Services/ Entities/`, `tools/`,
>   `t/`, `VERSION`). Neupravuje se kvůli jednomu webu; opravy chyb jen s regresním testem.
>   Cesty v tomto souboru jsou relativní ke kořeni repozitáře (ten se po `git clone` obvykle
>   jmenuje také `PWE`); v kontejneru je repozitář v `/PWE`, engine tedy v `/PWE/PWE/`.
> - [`webapps/`](webapps/README.md) = **písek**: konkrétní weby, každý v `webapps/<nazev>/`.
>   Web **neobsahuje kód enginu ani symlinky na něj** — engine ho najde přes
>   `PWE_CONF_pwe_home` a to, co si web z enginu bere, vyjmenovává jeho `conf/web.conf`
>   (`pwe.core_pages`, `core_sites`, `core_services`, `core_entities`); `pwe.require_core`
>   hlídá verzi enginu. Stejný název modulu ve webu i v enginu = platí web.
>   Slovo `core` v těchto názvech (i v `PWE_CONF_pwe_core`, `getCore()`) znamená „kořen
>   enginu“ = adresář `PWE/`; adresář jménem `core` v repozitáři není a názvy klíčů se nemění.
> - `webapps/example.web` (bez DB) a `webapps/example-db.web` (s DB) jsou vzorové weby,
>   `webapps-example/` historické weby (mimo git) — **vše jen ke čtení**.
> - Vlastní weby nejsou v tomto gitu (`.gitignore: webapps/*`) — mají vlastní repozitář.
>
> Detailně: [`docs/01-uvod.md`](docs/01-uvod.md) a [`docs/03-struktura-webu.md`](docs/03-struktura-webu.md).

---

## 0. Typický úkol: nový web podle zadání

Postup, nástroje a kontrolní seznamy jsou v
[`docs/21-novy-web-podle-zadani.md`](docs/21-novy-web-podle-zadani.md). Ve zkratce
(engine běží v kontejneru z image `ghcr.io/kukam/pwe-*` s tagem verze enginu z `PWE/VERSION`; `make` volá
skripty v `PWE/tools/` — skripty `*.pl` spouští hostitelský Perl, stačí jádro, a zbytek si odbaví
v kontejneru):

```bash
make new WEB=mujweb.web ARGS='--title "Můj web" --lang CZE,EN [--db mariadb] [--examples]'
make module TYPE=page WEB=mujweb.web NAME=kontakt ARGS='--site Default --services UserAccount'
make check WEB=mujweb.web                          # konvence, perl -c, smoke requesty
make cgi WEB=mujweb.web Q='page=kontakt&func=default'   # jeden request v CGI režimu
make run WEB=mujweb.web PROFILE=static|mariadb     # celý stack: http://127.0.0.1:7778/
```

`make new` a `make module` vyžadují `WEB` zadaný výslovně (výchozí `example-db.web` je vzorový web
jen ke čtení); znak dolaru se v `ARGS` a `Q` píše zdvojeně (`$$`).

1. Ze zadání odvoď: databáze ano/ne, seznam stránek, jazyky, přihlášení, e-maily.
2. Vygeneruj kostru webu a stránek nástroji výše (ne ručně, ne kopírováním vzorového webu).
3. Piš jen do `webapps/<nazev>/`. Vzhled = `Sites/Default/layout_*.html` +
   `static/css/site.css`; texty = `rb*.tmpl`; logika = `Pages/`, `Services/`, `Entities/`;
   co se bere z enginu = `conf/web.conf` (`pwe.core_*`).
4. Ověř `make check`, projdi stránky, zkontroluj log na `[E]`, doplň
   `webapps/<nazev>/README.md`. Před produkcí `pwe.development => 0`.

## 1. Zlatá pravidla (nikdy neporušuj)

1. **Jazyk komentářů a POD je čeština.** Veškeré nové komentáře, POD bloky
   (`=head2 B<[Public] nazev()>`) a dokumentaci piš česky — kvůli konzistenci se
   stávajícím kódem.
2. **Konvence názvů je striktní.** Modul `Foo` musí být v `Foo/Foo.pm` s balíčkem
   `Pages::Foo::Foo` (resp. `Services::`, `Entities::`, `Sites::`). Loadery
   ignorují vše, kde se název adresáře ≠ název `.pm` ≠ poslední část balíčku.
3. **Závislosti se nevyžadují přes `use`/`require`.** Engine je předává konstruktorem
   a injektory `Service_X` / `Site_Y`. Nikdy v Page/Service/Entity nepiš
   `use Libs::...;` na enginové třídy (výjimkou je mrtvý blok `KOMODO`).
4. **Každý modul musí mít blok `sub KOMODO { return; ... }`.** Je to mrtvý kód jen
   pro IDE (rozpozná `my ($CONF,$LOG,...)` globály). Nevynechávej ho, nevolej ho.
5. **Soubory `rb.tmpl` a `rb_<LANG>.tmpl` musí končit prázdným řádkem** (známý bug
   resource bundle parseru) a musí existovat pro každý jazyk z `http.languages`.
6. **Výchozí UI je Bootstrap 5.3.8 + jQuery 4.0.0 + Font Awesome 6.4.2** z `PWE/assets`
   (`assets/css/bootstrap-5.3.8/`, `assets/javascript/jquery-4.0.0/`). Piš Bootstrap 5 markup
   (`data-bs-*`, `btn-close`, `form-select`, `row/col`, `navbar-expand-lg`); Bootstrap 3 třídy
   (`btn-default`, `panel`, `form-group`, `glyphicon`, `data-toggle`) nepoužívej. Inline skripty
   spouštěj `$(function(){...})`, ne `$(window).load(...)` (jQuery 4 ho nemá).
7. **Pád metody není fatální.** Engine `die` odchytí, modul odregistruje, pošle
   e-mail report a znovu načte. Nepiš obranný kód „aby nespadl server“ — piš
   čitelný kód a chyby validuj přes atributy stránky.
8. **Injektovaná služba/vzhled musí být dostupná** — buď vlastní modul webu, nebo
   název uvedený v `pwe.core_services`/`core_sites`; jinak engine stránku odregistruje.

## 2. Než začneš generovat stránku

Použij `make module TYPE=page WEB=<web> NAME=<Nazev> ARGS='--site Default --services ...'`
(CLI, `PWE/tools/new-module.pl`) nebo vestavěnou stránku **`pweCreator`**
(`?page=pweCreator`, přístup jen pro skupinu `admin`). Oba generují ze stejných
kanonických šablon kostry: `PWE/Pages/pweCreator/page.tmpl`, `service.tmpl`,
`site.tmpl`, `entity.tmpl`. Teprve když ani jedno nejde, zkopíruj kostru z
existujícího sourozence.

## 3. Minimální kostra stránky (zkopíruj a uprav)

```perl
package Pages::mojeStranka::mojeStranka;

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

sub new {
    my ($class, $self, $conf, $log, $validate, $dbi, $entities, $user, $web) = @_;

    $DBI = $dbi; $LOG = $log; $CONF = $conf; $USER = $user;
    $WEB = $web; $VALIDATE = $validate; $ENTITIES = $entities;

    $self->{'func'}->{'default'} = [];          # ?page=mojeStranka&func=default

    bless $self, $class;
    return $self;
}

sub Site_Default {                              # injektuje vzhled (render API)
    my ($self, $input) = @_;
    $WEB = $input;
}

# KOMODO-IDE/KOMODO-EDIT
sub KOMODO {
    return;
    require Libs::Config; require Libs::Log; require Libs::Validate;
    require Libs::DBI; require Libs::Entities; require Libs::User;
    require Sites::Default::Default;
    $CONF = new Libs::Config; $LOG = new Libs::Log; $VALIDATE = new Libs::Validate;
    $DBI = new Libs::DBI; $ENTITIES = new Libs::Entities; $USER = new Libs::User;
    $WEB = new Sites::Default::Default;
}

sub default {
    my $self = shift;
    $WEB->setIDP("mojeStranka");
    $WEB->printHttpHeader();
    $WEB->printHtmlHeader();
    $WEB->printHtmlLayout(html_main => "Pages/mojeStranka/main.html");
}

1;
```

Ke stránce patří soubory ve stejném adresáři: `main.html`, `msg.html`,
`rb.tmpl` a `rb_<LANG>.tmpl` pro každý další jazyk z `conf` `http.languages`.

## 4. Co která globální proměnná umí (cheat sheet)

| Proměnná    | Třída              | Typické použití |
|-------------|--------------------|-----------------|
| `$USER`     | Libs::User         | `getParam($k,0,$def)`, `getSid()`, `setParameter()`, `getRequestMethod()`, `saveUploadFile()`, `setOpts/getOpts` |
| `$WEB`      | Sites::*/Libs::Web | `setIDP()`, `printHttpHeader()`, `printHtmlLayout()`, `printAjaxLayout()`, `setMessenger()`, `genTmpl()` |
| `$DBI`      | Libs::MyDBI        | `select($dbid,$sql,$bind)`, `insert`, `update`, `delete`, `commit`, `getDAO()` |
| `$ENTITIES` | Libs::Entities     | `createEntityObject('Name',$opts)`, `getEntityObject()` |
| `$VALIDATE` | Libs::Validate     | `validate(['is_email','err',$v])`, `is_*()` |
| `$CONF`     | Libs::Config       | `getValue('sekce','klic',$def)`, `getHome()`, `getCore()`, `resolveFile()` |
| `$LOG`      | Libs::Log          | `error()`, `info()`, `debug()`, `delay()` |

Služby (`$TABLE`, `$EMAIL`, …) získáš deklarací `sub Service_DBTable { $TABLE = $_[1] }`.

## 5. Validace vstupu — deklarativně, ne ručně

V `new()` nastav atributy a engine je spustí PŘED tvou funkcí; při chybě zavolá
metodu z `$self->{'error'}->{func}`:

```perl
$self->{'func'}->{'form'}  = [];
$self->{'error'}->{'form'} = "error";
$self->{'defined'} = { form => { parameters => ['email','fullname'] } };
$self->{'rules'}->{'form'}->{'email'} = [ ['is_email','error_email','parameter'] ];
```

Detaily: [`docs/05-validace.md`](docs/05-validace.md). Při POST musí být `page` a
`func` v těle formuláře (CGI.pm na POST ignoruje query string).

## 6. Kontroly při změnách

- PWE běží v Dockeru — viz [`docs/17-nasazeni.md`](docs/17-nasazeni.md).
  Libovolný web: `make run WEB=<web> PROFILE=<profil>` (compose dostane `PWE_WEBAPP` a tag image
  = verze z `PWE/VERSION`, engine běží z `/PWE/PWE`); vzorový web s DB přímo:
  `COMPOSE_PROFILES=mariadb docker compose up` (bez `PWE_IMAGE_TAG` bere image s tagem `latest`).
  Služba `fcgi` běží v závislostním image profilu `pwe-<profil>`, profil `static` v `pwe-base`
  (proměnná `PWE_FCGI_IMAGE`; `make run` ji nastavuje sám, přímé
  `COMPOSE_PROFILES=static docker compose up` potřebuje `PWE_FCGI_IMAGE=pwe-base`).
- **Testy a kompilace spouštěj v kontejneru**, hostitelský Perl nemá závislosti:
  `make test` (sada `PWE/t/`), `make compile` (`perl -c` všech modulů i skriptů). Oba používají
  image `ghcr.io/kukam/pwe-debugger:<verze>` a mountují repozitář do `/PWE`. `make test` drží zámek
  pracovní kopie `PWE/t/.run-tests.lock`: souběžný běh nad stejnou kopií (i jediný test) čeká, až
  první skončí (nejvýš `PWE_TEST_LOCK_WAIT` s, výchozí 600; `0` = nečekat), pak končí kódem 2 —
  hlášku `[run-tests] … cekam, az skonci` neber jako chybu testů; opuštěný zámek běh převezme sám.
  Detaily a pravidla pro psaní testů: [`docs/18-testy.md`](docs/18-testy.md).
- **Image** (registr `ghcr.io/kukam`, celkem 9; přehled v
  [`docs/17-nasazeni.md`](docs/17-nasazeni.md#image)):
  - **Závislostní image** (5, stage v `PWE/docker/Dockerfile`) — **bez kódu enginu a bez webu**:
    `pwe-base` = jen běhové knihovny enginu, bez DB ovladačů (základ image webu bez databáze, běží
    v něm služba `fcgi` profilu `static`);
    `pwe-mariadb|mysql|postgres` = `pwe-base` + DB ovladač profilu (základ image webu s databází, běží
    v nich služba `fcgi`; engine i web dostávají mountem repozitáře);
    `pwe-debugger` = `pwe-base` + všechny ovladače + ladicí nástroje (služba
    `debugger` a **výchozí image nástrojů** `make test/compile/check/cgi/module/smtp-test`;
    `make new` běží na hostiteli).
  - **Image vzorových webů** (4, staví je přímo `Dockerfile` vzorového webu): `pwe-example-static` =
    `pwe-base` + engine + `webapps/example.web`; `pwe-example-mariadb|mysql|postgres` = `pwe-<profil>`
    + engine + `webapps/example-db.web`. Jsou samy spustitelné, ale jen jako ukázka — každý návštěvník
    vzorového webu je ve skupině `admin` včetně generátoru kódu `pweCreator`; pro veřejný provoz určené
    nejsou (vstupní skript na to při startu serveru upozorní: `[entrypoint] VAROVANI: bezi vzorovy web …`).
  - Image `pwe` (samotný engine) a `pwe-static` z verze 2.2.0 byly zrušeny.
  - **Každý image má právě dva tagy: `<verze>`** (obsah `PWE/VERSION`, tvar `X.Y.Z`) **a `latest`.**
    Tagy podle větve gitu neexistují (žádné `master`, `pwe.ai`, `pr-N`). Oba tagy se přepisují každým
    sestavením a publikací; přesný kód určuje jen digest nebo popisek
    `org.opencontainers.image.revision` image vzorových webů (závislostní image ho nemají)
    ([`docs/17-nasazeni.md`](docs/17-nasazeni.md#registr-a-tagy)).
  - Výběr image: `PWE_IMAGE_REGISTRY` (výchozí `ghcr.io/kukam`), `PWE_IMAGE_TAG` (výchozí verze
    z `PWE/VERSION` — na gitu ani větvi nezávisí; musí to být platný tag, hodnotu s `/` nástroje
    odmítnou; typicky `latest`), `PWE_TEST_IMAGE` (úplné přepsání image nástrojů). Nástroje použitý
    image vypisují (`[run-tests] image …`, `[run-webapp] … registr=… tag=…`) a když v místním Dockeru
    není, vypíšou radu včetně tagů téhož image, které místně jsou.
  - `pull access denied` / `manifest unknown`, u `ghcr.io` také `denied` nebo `403 Forbidden` = image
    této verze nejsou v registru (typicky po zvýšení `PWE/VERSION`, nebo jsou balíčky soukromé
    a Docker není přihlášen) → `make images` (sestaví všech 9 lokálně s tagy `<verze>` a `latest`;
    `make images ARGS='base debugger'` jen vybrané — cíle `base mariadb mysql postgres debugger
    example-static example-mariadb example-mysql example-postgres`), nebo — jsou-li image publikované —
    `PWE_IMAGE_TAG=latest make …`. `PWE_IMAGE_TAG` se při `make images` nepoužívá.
  - Knihovna, kterou potřebuje jen web, patří do `Dockerfile` webu, ne do `pwe-base`. V `pwe-base`
    **nejsou** `LWP::UserAgent` (`libwww-perl`), `LWP::Protocol::https`, `Data::UUID`, `Data::GUID`,
    `Crypt::OpenSSL::X509` ani `curl` (ten je jen v `pwe-debugger`); HTTPS klient kódu webu je
    `HTTP::Tiny` + `IO::Socket::SSL`. Image běží v UTC (`tzdata` v image je); proměnná `TZ` platí jen
    při startu enginu — FastCGI v každém requestu nahradí prostředí, pásmo pro requesty proto předává
    webserver (`fastcgi_param TZ`) nebo `/etc/localtime` kontejneru. Sestavení image řídí `PWE/docker/Dockerfile` (závislostní image: stage = image, vše z balíčků Ubuntu — `cpanm` se
    při sestavení nepoužívá; z kontextu sestavení bere jen `PWE/docker/entrypoint.sh`), `Dockerfile`
    vzorových webů (image `pwe-example-*`),
    `docker-bake.hcl` (proměnná `VERSION` povinná, každý z 9 cílů s tagy `<verze>` a `latest`; vzorový
    cíl si základ sestaví sám, uloží se ale jen tehdy, je-li také mezi cíli) a pipeline
    `.github/workflows/images.yml` (testy v `pwe-base` a kouřové kontroly, pak publikace obou
    platforem). **Publikuje jen push a ruční spuštění nad výchozí větví repozitáře a nad větvemi
    z proměnné repozitáře `PUBLISH_BRANCHES`**; ostatní větve a pull requesty image jen sestaví
    a otestují. Vstupy image jsou `PWE/**` kromě `PWE/t/**` a `PWE/tools/**` (testy a nástroje v image
    nejsou), `docker-bake.hcl`, `.dockerignore`, `LICENSE` a vzorové
    weby `webapps/example*.web/**`; lehký `.github/workflows/tests.yml` pouští jen testy pro změny
    `PWE/t/**`, `PWE/tools/**`, compose, `kubernetes/` a `Makefile` — změna skriptu nebo testu tedy
    image nesestaví ani nepublikuje. Kouřové kontroly místních image: `make images-check`
    (`PWE/tools/smoke-images.sh`). `make images ARGS=--push` odmítne necommitnuté změny
    (`--allow-dirty`).
  - Image webu (`webapps/<web>/Dockerfile`, šablona generátoru) = závislostní image + engine + web:
    **jediný `FROM`** `pwe-<profil>:<tag>`, u webu bez databáze `pwe-base:<tag>` (výchozí
    `PWE_IMAGE_TAG=latest`; žádný image `pwe`, `COPY --from` ani `PWE_ENGINE_TAG`), engine zkopírovaný
    z kontextu sestavení (`COPY --link` položek `PWE/` kromě `PWE/t`, `PWE/docker` a `PWE/tools` do `/PWE/PWE`), web
    do `/PWE/webapps/<web>`, zapečené `PWE_CONF_pwe_home` a `PWE_PROFILE`, vlastní `LABEL`,
    pracovní adresáře a `conf/database.conf` založené při sestavení (jediný `RUN`). **Sestavuje se vždy
    z kořene repozitáře**; verzi enginu v image určuje pracovní kopie, `PWE_IMAGE_TAG` vybírá jen
    závislostní image. `make check` na `Dockerfile` ze starší šablony upozorní (`WARN Dockerfile je ze
    stare sablony …`); nový dá `PWE/tools/new-webapp.pl <web> [--db <profil>] --dir <dočasný adresář>`
    (převzít z výsledku `Dockerfile`). Web **nemá vlastní
    `entrypoint.sh`** — image webu dědí `ENTRYPOINT` ze závislostního image (jediný zdroj
    `PWE/docker/entrypoint.sh`); nepřidávej ho do webu ani do `Dockerfile`. Nad lokálně sestavenými
    image (`make images`) stav prostým `docker build [--build-arg PWE_IMAGE_TAG="$(cat PWE/VERSION)"] …`
    — místní image vidí; `docker buildx build`
    staví vybraným builderem a s typem `docker-container` je nevidí (pak
    `--builder <builder s ovladačem docker> --load`). Soukromé klíče pod `conf/` webu (`*.pem`, `*.key`,
    `*.p12`, `*.pfx`) se do image nezapékají (`.dockerignore`) — kontejner je dostává mountem, viz
    [`docs/17-nasazeni.md`](docs/17-nasazeni.md#image-vlastního-webu).
- Všechny image mají zapečené `PWE_CONF_pwe_core=/PWE/PWE` (z `pwe-base`); `PWE_CONF_pwe_home`
  a `PWE_PROFILE` má zapečené až image webu — konkrétního webu i vzorového (`pwe-example-*`);
  závislostní image je nemají.
  `FCGI_SOCKET_PATH=:7779` v image není — mají ho až
  kontejnery compose stacku (z `docker-compose/docker-compose_common.env`). Skripty v `PWE/tools/` tyto proměnné
  nastavují nebo odstraňují samy; při ručním běhu nastav `PWE_CONF_pwe_home` na adresář webu
  a v kontejneru stacku navíc **odstraň** `FCGI_SOCKET_PATH` (`. vars` nebo
  `unset FCGI_SOCKET_PATH`), jinak engine místo jednoho CGI requestu začne poslouchat na socketu.
- Běh procesu (od 2.2.1, [`docs/17-nasazeni.md`](docs/17-nasazeni.md#běh-procesu-enginu)):
  `FCGI_SOCKET_PATH` je `:7779`, `127.0.0.1:7779` nebo cesta k unix socketu (práva
  `FCGI_SOCKET_PERM` osmičkově, výchozí 0770); `SIGTERM` ukončí engine pořádaně s kódem 0
  (rozpracovaný request doběhne); migraci schématu při startu chrání zámek vázaný na databázové
  spojení (klíče `dbversion_session_lock`, `dbversion_legacy_lock_wait` v `conf/<profil>.conf`).
- Engine lze spustit jako jednorázové CGI bez FastCGI socketu (ladění, smoke test):
  `make cgi WEB=<web> Q='page=X&func=default'` (k síti a databázi compose stacku se připojí jen
  tehdy, když stack běží pro **týž** web; běží-li stack jiného webu, web s databází skončí kódem 2 —
  spusť `make run WEB=<web>`), ručně v kontejneru z adresáře webu
  `PWE_CONF_pwe_home=$PWD/ PWE_CONF_pwe_core=/PWE/PWE/ SCRIPT_FILENAME=/pwe.fcgi REQUEST_METHOD=GET QUERY_STRING='page=X' perl /PWE/PWE/pwe.fcgi`.
- Po vygenerování stránky ověř `make check WEB=<web>` a dostupnost na
  `http://127.0.0.1:7778/?page=<jmeno>&func=default` (změna `.pm` vyžaduje `make restart`).
  `make run` odmítne neznámý profil (`Neznamy profil nebo prikaz`) a varuje (`[run-webapp] POZOR`,
  `[entrypoint] VAROVANI`), když profil neodpovídá `conf/` webu — web bez databáze spouštěj
  s `PROFILE=static`.
- **Kubernetes** ([`kubernetes/README.md`](kubernetes/README.md)): `make k8s-image | k8s-template |
  k8s-deploy | k8s-status | k8s-test | k8s-logs | k8s-delete K8S=<název>` (vzorová nasazení berou
  hotové image vzorových webů z registru: `static` = `pwe-example-static` s `example.web`, `generic` =
  `pwe-example-mariadb` s `example-db.web` + MariaDB — nic se nestaví; `make k8s-image` je jen pro
  vlastní web a staví jeho `Dockerfile` nad `pwe-<profil>`, bez databáze nad `pwe-base`; release
  `pwe-<název>`, skript `PWE/tools/k8s.sh`, chart
  `nxs-universal-chart` 3.2.2, hodnoty `kubernetes/values-<název>.yml`). **Nikdy bez `KUBE_CONTEXT`**
  — skript aktuální kontext `kubectl` nepoužije a bez něj nic nenasadí; **nikdy `kubectl` bez
  `--context <kontext>`** (ani `helm` bez `--kube-context`), ani pro čtení — na stroji mohou být
  kontexty cizích clusterů. `make k8s-template` se ke clusteru nepřipojuje; `k8s-deploy`
  a `k8s-delete` spouštěj jen na výslovný pokyn uživatele. `kubernetes/local.env` a
  `kubernetes/secrets-*.yml` (hesla, mimo git) nečti a necommituj.
- Každá oprava chyby v enginu má mít regresní test v `PWE/t/`; před dokončením práce
  musí projít `make test` i `make compile`. Změna kontraktu stránky/Site = zvýšit `PWE/VERSION`.

## 7. Kam sahat a kam ne

| Smíš upravovat | Needitovat bez vyžádání |
|----------------|--------------------------|
| `webapps/<nazev>/` **nového** webu, na kterém pracuješ (Pages, Services, Entities, Sites, conf, static, README) | `PWE/Libs/`, `PWE/pwe.fcgi`, `PWE/templates/Http*.tmpl` (jádro enginu) |
| `PWE/Pages/`, `PWE/Sites/`, `PWE/Services/`, `PWE/Entities/` (sdílené moduly) — jen opravy chyb s testem | `webapps/example.web`, `webapps/example-db.web` (referenční vzory) |
| `PWE/t/`, `PWE/tools/`, `docs/`, `AGENTS.md`, `Makefile`, `docker-compose.yml`, `docker-compose/` | `webapps-example/*` (historické weby, jen ukázky použití; nejsou v gitu) |
| `PWE/docker/`, `docker-bake.hcl`, `.github/` (sestavení a publikace image) — jen změny, které platí pro všechny weby | `kubernetes/local.env`, `kubernetes/secrets-*.yml` (místní nastavení a hesla, mimo git — ani nečíst) |
| `kubernetes/` (`values-*.yml`, vzory `*.example.yml`, `README.md`), `PWE/tools/k8s.sh` — jen nasazení, které platí obecně; nasazovat jen na pokyn | |

- Weby ve `webapps-example/` jsou **reálné aplikace dříve provozované nad enginem**
  (`apitea`, `cler`, `knihy`, `lz`, `presence`). Čti je, když potřebuješ vidět skutečné
  použití API (mapování požadavků na konstrukce PWE je v [`docs/21`](docs/21-novy-web-podle-zadani.md)),
  ale neupravuj je a nespouštěj — nemají svou databázi a používají starý režim se symlinky.
- **Image se neupravují kvůli jednomu webu.** Knihovnu, kterou potřebuje jen web, přidej do
  `webapps/<nazev>/Dockerfile`; do stage `base` v `PWE/docker/Dockerfile` patří jen to, bez čeho
  neběží engine (pipeline v `pwe-base` pouští testy enginu). Po změně `PWE/docker/` nebo
  `docker-bake.hcl` ověř `make images`, `make images-check` a `make test`. Vstupní skript image je
  jen `PWE/docker/entrypoint.sh` (dědí ho všechny image včetně image webu, web vlastní kopii nemá)
  a šablona `Dockerfile` webu je jen v `PWE/tools/new-webapp.pl` (funkce `gen_dockerfile`):
  `Dockerfile` vzorových webů (`webapps/example*.web/Dockerfile`) s výstupem generátoru musí zůstat
  shodný a web nesmí mít `entrypoint.sh` — hlídá to `PWE/t/14-tools.t`. Šablona vyjmenovává položky
  adresáře `PWE/` (kromě `t`, `docker` a `tools`): nová položka přímo v `PWE/` znamená doplnit `COPY` do
  šablony a `Dockerfile` vzorových webů vygenerovat znovu (i to hlídá `PWE/t/14-tools.t`). Změna
  balíčků stage `base`
  znamená upravit i přesný seznam v `PWE/t/14-tools.t` a kontroly v `PWE/tools/smoke-images.sh`.
  Engine a vzorové weby jsou součástí image vzorových webů `pwe-example-*`: po změně v `PWE/`, ve
  vzorovém webu nebo ve vstupním skriptu sestav image znovu (`make images`), jinak `make images-check`
  ohlásí rozdíl (srovnává seznam i obsah souborů).
- **Necommituj** a nepushuj, pokud o to uživatel výslovně nepožádá.

## 8. Dokumentace v kódu (POD)

- Každá metoda má POD blok těsně nad `sub`: `=head2 B<[Public] nazev($arg,...)>` nebo
  `[Private]`, odsazený popis (4 mezery), `=cut`. Každý modul začíná `=head1 NAME`.
- Text POD a komentářů je **česky bez diakritiky** (ASCII), stejně jako stávající kód;
  diakritika patří do `docs/*.md`, `README.md` a do textů v `rb*.tmpl`.
- `[Public]` = součást API pro stránky/služby, `[Private]` = interní (loadery, pomocné).
- Kontrola: `podchecker <soubor>` v kontejneru (varování „=head2 without preceding
  higher level“ je v pořádku jen u vendorovaných modulů).

Plný rozcestník dokumentace: [`docs/README.md`](docs/README.md).
