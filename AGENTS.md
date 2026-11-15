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
(engine běží v kontejneru z image `ghcr.io/kukam/pwe-*` s tagem podle větve gitu; `make` volá
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
  podle větve, engine běží z `/PWE/PWE`); vzorový web s DB přímo:
  `COMPOSE_PROFILES=mariadb docker compose up` (bez `PWE_IMAGE_TAG` bere image s tagem `master`).
- **Testy a kompilace spouštěj v kontejneru**, hostitelský Perl nemá závislosti:
  `make test` (sada `PWE/t/`), `make compile` (`perl -c` všech modulů i skriptů). Oba používají
  image `ghcr.io/kukam/pwe-debugger:<větev>` a mountují repozitář do `/PWE`. `make test` drží zámek
  pracovní kopie `PWE/t/.run-tests.lock`: souběžný běh nad stejnou kopií (i jediný test) čeká, až
  první skončí (nejvýš `PWE_TEST_LOCK_WAIT` s, výchozí 600; `0` = nečekat), pak končí kódem 2 —
  hlášku `[run-tests] … cekam, az skonci` neber jako chybu testů. Detaily a pravidla pro psaní testů:
  [`docs/18-testy.md`](docs/18-testy.md).
- **Image** (registr `ghcr.io/kukam`, všechny vycházejí z `pwe-base`; přehled v
  [`docs/17-nasazeni.md`](docs/17-nasazeni.md#image)):
  - `pwe-base` = jen běhové knihovny enginu, **bez kódu enginu** a bez DB ovladačů;
    `pwe` = základ + kód enginu v `/PWE/PWE` (nosič, z něj si engine kopíruje `Dockerfile` webu);
    `pwe-static|mariadb|mysql|postgres` = základ + DB ovladač profilu (v nich běží služba `fcgi`);
    `pwe-debugger` = základ + všechny ovladače + ladicí nástroje (služba `debugger` a **výchozí
    image nástrojů** `make test/compile/check/cgi/module/smtp-test`; `make new` běží na hostiteli).
  - **Tag = větev gitu** (znaky mimo `A–Z a–z 0–9 _ . -` → `-`); jen `pwe` má navíc tag verze
    z `PWE/VERSION`. Tag `latest` neexistuje. Tagy se přepisují — i tag verze, publikuje ho běh
    pipeline z kterékoli větve; přesný kód určuje jen digest nebo popisek
    `org.opencontainers.image.revision` image `pwe`
    ([`docs/17-nasazeni.md`](docs/17-nasazeni.md#registr-a-tagy)).
  - Výběr image: `PWE_IMAGE_REGISTRY` (výchozí `ghcr.io/kukam`), `PWE_IMAGE_TAG` (výchozí aktuální
    větev, bez gitu `master`; musí to být platný tag — nepřevedený název větve s `/` nástroje
    odmítnou), `PWE_TEST_IMAGE` (úplné přepsání image nástrojů). Nástroje použitý image vypisují
    (`[run-tests] image …`, `[run-webapp] … registr=… tag=…`) a když v místním Dockeru není, vypíšou
    radu včetně tagů téhož image, které místně jsou.
  - `pull access denied` / `manifest unknown`, u `ghcr.io` také `denied` nebo `403 Forbidden` = image
    pro větev nejsou v registru (nebo jsou balíčky soukromé a Docker není přihlášen) → `make images`
    (sestaví všech 7 lokálně; `make images ARGS='pwe debugger'` jen vybrané), nebo — jsou-li
    publikované image větve `master` — `PWE_IMAGE_TAG=master make …`.
  - Knihovna, kterou potřebuje jen web, patří do `Dockerfile` webu, ne do `pwe-base`. V `pwe-base`
    **nejsou** `LWP::UserAgent` (`libwww-perl`), `LWP::Protocol::https`, `Data::UUID`, `Data::GUID`,
    `Crypt::OpenSSL::X509` ani `curl` (ten je jen v `pwe-debugger`); HTTPS klient kódu webu je
    `HTTP::Tiny` + `IO::Socket::SSL`. Image běží v UTC (`tzdata` v image je); proměnná `TZ` platí jen
    při startu enginu — FastCGI v každém requestu nahradí prostředí, pásmo pro requesty proto předává
    webserver (`fastcgi_param TZ`) nebo `/etc/localtime` kontejneru. Sestavení image řídí `PWE/docker/Dockerfile` (stage = image, vše z balíčků Ubuntu — `cpanm` se
    při sestavení nepoužívá), `docker-bake.hcl` a pipeline `.github/workflows/images.yml` (testy
    v `pwe-base` a kouřové kontroly obou platforem, pak publikace; pull request nepublikuje);
    lehký `.github/workflows/tests.yml` pouští jen testy pro změny vzorových webů, compose,
    `kubernetes/` a `Makefile`. Kouřové kontroly místních image: `make images-check`
    (`PWE/tools/smoke-images.sh`). `make images ARGS=--push` odmítne odpojený `HEAD` bez
    `PWE_IMAGE_TAG` a necommitnuté změny (`--allow-dirty`), tag tvaru `X.Y.Z` odmítne vždy.
  - Image webu (`webapps/<web>/Dockerfile`, šablona generátoru): běh z `pwe-<profil>`, engine
    `COPY --from` image `pwe`, zapečené `PWE_CONF_pwe_home` a `PWE_PROFILE`, vlastní `LABEL`, pracovní
    adresáře a `conf/database.conf` založené při sestavení (`RUN`). Web **nemá vlastní
    `entrypoint.sh`** — image webu dědí `ENTRYPOINT` z `pwe-<profil>` (jediný zdroj
    `PWE/docker/entrypoint.sh`); nepřidávej ho do webu ani do `Dockerfile`. Nad lokálně sestavenými
    image (`make images`) stav prostým `docker build --build-arg PWE_IMAGE_TAG=<větev> …` — místní
    image vidí; `docker buildx build`
    staví vybraným builderem a s typem `docker-container` je nevidí (pak
    `--builder <builder s ovladačem docker> --load`). Soukromé klíče pod `conf/` webu (`*.pem`, `*.key`,
    `*.p12`, `*.pfx`) se do image nezapékají (`.dockerignore`) — kontejner je dostává mountem, viz
    [`docs/17-nasazeni.md`](docs/17-nasazeni.md#image-vlastního-webu).
- Všechny image mají zapečené jen `PWE_CONF_pwe_core=/PWE/PWE` (z `pwe-base`); `PWE_CONF_pwe_home`
  a `PWE_PROFILE` má zapečené až image konkrétního webu. `FCGI_SOCKET_PATH=:7779` v image není — mají ho až
  kontejnery compose stacku (z `docker-compose/docker-compose_common.env`). Skripty v `PWE/tools/` tyto proměnné
  nastavují nebo odstraňují samy; při ručním běhu nastav `PWE_CONF_pwe_home` na adresář webu
  a v kontejneru stacku navíc **odstraň** `FCGI_SOCKET_PATH` (`. vars` nebo
  `unset FCGI_SOCKET_PATH`), jinak engine místo jednoho CGI requestu začne poslouchat na socketu.
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
  k8s-deploy | k8s-status | k8s-test | k8s-logs | k8s-delete K8S=<název>` (`static` = `example.web`,
  `generic` = `example-db.web` + MariaDB; release `pwe-<název>`, skript `PWE/tools/k8s.sh`, chart
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
  shodný a web nesmí mít `entrypoint.sh` — hlídá to `PWE/t/14-tools.t`. Změna balíčků stage `base`
  znamená upravit i přesný seznam v `PWE/t/14-tools.t` a kontroly v `PWE/tools/smoke-images.sh`.
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
