# 03 — Struktura webu a konfigurace

Web je adresář `webapps/<nazev>/`. Obsahuje **jen** vlastní kód a konfiguraci; engine (adresář
`PWE/` v kořeni repozitáře) je mimo něj a web ho dostane přes proměnné prostředí
`PWE_CONF_pwe_home` (kořen webu) a `PWE_CONF_pwe_core` (kořen enginu, tedy cesta k adresáři `PWE/`).
Tato kapitola popisuje každý soubor webu a kompletní referenci konfigurace.

## Anatomie webu

Tak vypadá web vytvořený `make new WEB=<nazev> ARGS='--db mariadb --lang CZE,EN'`:

```text
webapps/<nazev>/
├── conf/
│   ├── web.conf                   hlavní konfigurace (Perl hash) — viz reference níže
│   ├── database.conf              -> symlink na <driver>.conf (vytvoří generátor; v kontejneru ho podle PWE_PROFILE nastavuje entrypoint image; v .gitignore)
│   ├── mariadb.conf  mysql.conf  postgres.conf     připojení k DB pro jednotlivé drivery
│   └── mariadb.dbversion  mysql.dbversion  postgres.dbversion   migrace schématu (tabulky dbtable, session, …)
├── Pages/
│   └── default/                   úvodní stránka: default.pm, main.html, msg.html, rb.tmpl, rb_EN.tmpl
├── Sites/
│   └── Default/                   vzhled: Default.pm, layout_header.html, layout_body.html, layout_footer.html, rb*.tmpl
├── Services/
│   └── UserAccount/               účet a skupiny uživatele (UserAccount.pm, rb*.tmpl)
├── Entities/                      vlastní entity (tabulky webu); prázdné u webu bez DB
├── static/
│   ├── css/site.css               vlastní styly (Bootstrap, jQuery, Font Awesome a pwe.js jsou v enginu)
│   └── images/                    vlastní obrázky
├── ramdisk/  sessions/  uploadfile/  log/     dočasná data (v .gitignore; zakládá generátor, run-webapp.sh, sestavení image webu i entrypoint image)
├── Dockerfile                     image webu: běh z pwe-<profil> (včetně entrypointu), engine zkopírovaný z image pwe, + tento web
├── .htaccess                      Apache: zákaz přímého čtení .pm/.tmpl/.conf…
├── robots.txt                     servírován z kořene (pwe.assets_file)
├── vars                           proměnné pro ruční běh v CGI režimu (. vars)
└── README.md                      popis webu
```

Pravidla, která z toho plynou:

- **Konvence názvů je striktní.** Modul `X` je `Pages/X/X.pm` s balíčkem `Pages::X::X`
  (stejně `Sites::`, `Services::`, `Entities::`). Název adresáře, souboru i poslední část
  balíčku se musí shodovat, jinak loader modul přeskočí.
- Ke každému modulu patří `rb.tmpl` (výchozí jazyk = první v `http.languages`) a
  `rb_<LANG>.tmpl` pro každý další jazyk. Soubory **musí končit prázdným řádkem**.
- Šablony stránky leží vedle modulu (`Pages/X/main.html`, `msg.html`, další `.html`) a
  v kódu se adresují relativně ke kořeni: `"Pages/X/main.html"`.
- Vlastní statika je ve `static/`; v HTML se odkazuje `static/css/site.css`, engine ji
  servíruje přes `pwe.assets_dir` (v produkci ji může servírovat přímo webserver).
- Modul stejného jména ve webu **přebije** modul enginu (např. vlastní `Pages/errorPage`).
  Stejně tak šablona `templates/messenger.html` ve webu přebije šablonu enginu.

## `conf/web.conf`

Soubor je Perl hash (`{ sekce => { klic => hodnota } }`), načítá ho `Libs::Config` při startu.
V kódu se čte `$CONF->getValue("sekce", "klic", $default)`. Klíč s hodnotou `undef` se
považuje za nenastavený (vrátí se default), hodnoty `0` a `''` se vrací tak, jak jsou.

Každý klíč lze **přepsat proměnnou prostředí** `PWE_CONF_<sekce>_<klic>` (např.
`PWE_CONF_log_loglevel=4`, `PWE_CONF_pwe_development=0`) a klíče databáze
`PWE_CONF_dbi_<dbid>_<klic>` (`PWE_CONF_dbi_db1_password=…`). Přepíše se jen klíč, který
v konfiguraci existuje — hesla tak nepatří do souborů, ale do prostředí.

### Sekce `pwe` — engine

| Klíč | Výchozí (generátor) | Význam |
| --- | --- | --- |
| `home` | doplní engine | kořen webu (z `PWE_CONF_pwe_home`); nenastavovat |
| `core` | doplní engine | kořen enginu = adresář `PWE/` (z `PWE_CONF_pwe_core`, jinak adresář skriptu `pwe.fcgi`; v kontejnerech `/PWE/PWE`); nenastavovat |
| `cgi_script_name` | doplní engine | název skriptu (`pwe.fcgi`); v šablonách `script_name` |
| `default_page`, `default_func` | `default`, `default` | stránka a akce bez parametrů `page`/`func` |
| `pages_dir`, `sites_dir`, `services_dir`, `entities_dir` | `Pages/`, `Sites/`, `Services/`, `Entities/` | adresáře modulů (relativně k oběma kořenům) |
| `require_core` | `">=<aktuální verze>"` | požadovaná verze enginu z `PWE/VERSION` (`>=1.2`, `=2.1` = řada 2.1.x, `>2.0`); při nesplnění engine nenastartuje |
| `core_pages` | `["css","errorPage","systemPage","pweCreator"]` | stránky enginu, které web používá |
| `core_sites` | `[]` | vzhledy enginu (web má vlastní `Sites/Default`); výchozí bez klíče `["Default"]` |
| `core_services` | `["DBTable","Session"]` s DB, `[]` bez DB | služby enginu (`Session`, `DBTable`, `Email`, `UserAccount`) |
| `core_entities` | `["DBTable","Session"]` s DB | entity enginu (`Session`, `DBTable`, `MailQueue`) |
| `enable_opt` | `1` | ukládat data uživatele mezi requesty (opts) |
| `save_opt_to` | `db` s DB, `file` bez DB | `file` = soubor v `opts_dir` (`Libs::User`), `db` = ukládá aplikace přes `Services::Session` |
| `opts_dir` | `sessions/` | adresář opts souborů (`<3 znaky sid>/<sid>.bin`) při `save_opt_to = file` |
| `upload_dir` | `uploadfile/` | cílový adresář `$USER->saveUploadFile` |
| `cgi_maxfilesize` | `100 * 1048576` | limit uploadu v bajtech (větší request → `errorPage/cgi_error`, 413) |
| `cgi_disableupload` | `0` | `1` = upload zakázán |
| `cgi_maxopentries`, `cgi_tmpdirectory` | `1000`, `ramdisk/` | parametry CGI.pm pro dočasné soubory uploadu |
| `assets_dir` | `"assets/, static/, uploadfile/"` | adresáře, ze kterých smí engine servírovat soubory (`assets/` = engine, `static/` = web, `uploadfile/` = nahrané soubory); čárkami oddělený řetězec. V compose je servíruje nginx přímo |
| `assets_file` | `"/favicon.ico, robots.txt"` | konkrétní soubory servírované z kořene |
| `assets_browse_dir` | `uploadfile/` | adresáře, jejichž obsah lze vypsat (`systemPage/folder`) |
| `development` | `1` | vývojový režim: v šablonách `conf_development` (DataDump v patičce); **v produkci 0** |
| `prettyhtml` | — | `1` = zjednodušit bílé znaky ve výstupu `printHtmlHeader` |
| `db_ping_interval` | `60` | jak často (s) ověřovat DB spojení pingem; `0` = každý request |
| `smtp_servers` | `[]` | seznam názvů sekcí SMTP (např. `["smtp_primary"]`) pro e-mailové reporty a `Services::Email` |
| `expire_opts_time`, `default_tmpl` | `48`, `templates/` | rezervované; engine je nečte |

Klíče `core`, `core_*` a `require_core` se jmenují podle pojmu „kořen enginu“ (core), ne podle
adresáře — engine leží v adresáři `PWE/`. Názvy klíčů jsou součást kontraktu a nemění se.

### Sekce `http` — HTTP a texty webu

| Klíč | Význam |
| --- | --- |
| `languages` | pole jazyků, první je výchozí (`rb.tmpl`), další mají `rb_<LANG>.tmpl`; validátor `is_language` |
| `cookie_name` | název session cookie — **unikátní pro každý web** |
| `http_host_path` | `path` cookie (`/`) |
| `cookie_expire_guest`, `cookie_expire_day` | expirace cookie ve dnech (`cookie_expire_day` má přednost); `cookie_expire_guest` používá i DB session (`Services::Session`) |
| `cookie_expire_user` | rezervováno pro vlastní kód |
| `name`, `title`, `keywords`, `description` | v šablonách `name_page`, `conf_title`, `conf_keywords`, `conf_description` |
| `base_url` | host použitý při generování URL mimo HTTP request (cron, CLI) |
| `layout_error_header`, `layout_error_body` | layouty chybových stránek (`errorPage`) |

### Sekce `web` — vlastní nastavení webu

| Klíč | Význam |
| --- | --- |
| `email_admin` | příjemce e-mailových reportů o pádech a o nedoručených e-mailech |
| `email_subtitle` | předmět reportů |
| `access_vat` | povolené sazby DPH pro `validate_decimal_vat` (např. `[21, 10]`) |
| *cokoli dalšího* | sekce je určena pro klíče aplikace (tutoriál zde má `admin_login`, `admin_password`); čtou se `$CONF->getValue("web", "klic", $default)` a přepisují `PWE_CONF_web_<klic>` |

### Sekce `css`

| Klíč | Význam |
| --- | --- |
| `src_css` | `static` = stránka `css` vrací soubor `static_css`; `scss` = přeloží `scss_src` příkazem `scss_bin` (výsledek uloží do `scss_out`) |
| `static_css` | `/static/css/site.css` |
| `scss_src`, `scss_out`, `scss_bin` | zdroj SCSS, výstup, příkaz (`/usr/bin/sass -C --scss --style=compressed`) |

Vzhled vkládá CSS buď přímo (`static/css/site.css`), nebo přes stránku enginu
`?page=css&func=default` — viz [07 — Vzhled](07-vzhled-site.md).

### Sekce `tmpl` — Template Toolkit

| Klíč | Výchozí | Význam |
| --- | --- | --- |
| `croot` | `ramdisk/templates/` | adresář kompilovaných šablon (relativně k `pwe.home`) |
| `cache` | `1` | zapne kompilační cache (přípona `c`) |
| `evalperl` | 1 | povolit `[% PERL %]` bloky |
| `postchomp`, `prechomp`, `trim` | 0 (pro `.html/.css/.js` šablony engine zapíná 1) | ořez bílých znaků |
| `recursion` | 1 | povolit rekurzivní `INCLUDE` |

### Sekce `log`

| Klíč | Význam |
| --- | --- |
| `loglevel` | `0` vypnuto, `1` error, `2` warning, `3` info, `4` debug (`[E]`, `[W]`, `[I]`, `[D]`; `[d]` = měření času) |
| `logout` | `STDERR`, `STDOUT`, cesta k souboru relativně k `pwe.home` (`log/pwe.log`), nebo `undef` = zahodit |
| `filter_list`, `<level>_filter_list` | whitelist balíčků (např. `["Pages::ukoly::ukoly"]`); prázdné = vše |
| `exclude_list`, `<level>_exclude_list` | blacklist balíčků |
| `log_delay`, `log_delay_minimum` | měření času `$LOG->delay()`; zapisuje se jen úsek ≥ minimum (s) |
| `error_report_interval` | stejnou chybu hlásit e-mailem nejvýše jednou za N s (výchozí 300, `0` = vždy) |

### Sekce `smtp_<nazev>`

Každý název ze `pwe.smtp_servers` je sekce s klíči pro `Libs::Send`: `host`, `port` (25),
`timeout` (30), `debug`, `hello`, `ssl` (1/0), `starttls` (1/0), `authid`, `authpw`.

### Sekce `dbi`

Zůstává prázdná; naplní ji `conf/database.conf`.

## `conf/database.conf` a `<driver>.conf`

`database.conf` je symlink na `mariadb.conf`, `mysql.conf` nebo `postgres.conf` (v pracovní kopii ho
vytvoří generátor, v image webu sestavení; v kontejneru ho podle `PWE_PROFILE` nasměruje vstupní skript
image `entrypoint.sh`). Obsah je hash databází; klíč (`db1`) je `$dbid`,
kterým se databáze adresuje v kódu (`$DBI->select("db1", …)`, entity).

```perl
{
    'db1' => {
        dbdriver       => "mariadb",                  # mysql | mariadb | postgres
        login          => "pwe",                      # přepis: PWE_CONF_dbi_db1_login
        password       => "pwe",                      # přepis: PWE_CONF_dbi_db1_password
        database       => "pwe",                      # přepis: PWE_CONF_dbi_db1_database
        host           => "mariadb",                  # název služby v docker-compose.yml
        port           => 3306,
        logfile        => "log/mariadb",
        loglevel       => 0,                          # trasování DBI do logfile (1 = jen ladění, viz tabulka)
        dao            => 1,                          # zapne DAO/Entity vrstvu (mapa tabulek)
        db_pool        => 3,                          # spojení navíc k poolu 0 (MySQL driver má 2 handle na pool)
        trayconnect    => 10,                         # počet pokusů o (re)připojení
        dsn_options    => "",                         # volitelné: doplňkové volby DSN ovladače, např. "mysql_ssl=1"
        daomap_file    => "conf/mariadb_daomap.dump", # volitelná cache mapy tabulek (pokud existuje, nečte se information_schema)
        dbversion_file => "conf/mariadb.dbversion",   # migrace schématu
    }
};
```

| Klíč | Význam |
| --- | --- |
| `dbdriver` | `mysql`/`mariadb` → `Libs::MyDBI::DRIVER::MySQL` (dvě spojení: čtecí s autocommit, zapisovací transakční), `postgres` → `DRIVER::Postgre` |
| `login`, `password`, `database`, `host`, `port` | připojení; `schema` navíc pro Postgres (výchozí `public`) |
| `autocommit` | zapisovací spojení: výchozí vypnuto = transakce, po zápisu je nutný `commit` |
| `logfile`, `loglevel` | trasování DBI: `loglevel` 1 a víc zapisuje každé SQL včetně vázaných hodnot (e-maily, hashe hesel) do `logfile`, bez rotace — jen pro ladění (`PWE_CONF_dbi_db1_loglevel=1` v `conf/local.env`). Generátor od 2.2.0 zakládá `0`; starší weby mají `1` |
| `dao` | `1` = při startu načíst strukturu tabulek a zpřístupnit DAO/entity |
| `db_pool` | počet spojení navíc; pool 0 je sdílený pro nízkoúrovňové dotazy, ostatní si půjčují entity |
| `trayconnect` | pokusy o připojení při startu a při výpadku (po 1 s), pak engine skončí |
| `dsn_options` | volitelné doplňkové volby DSN ovladače oddělené středníkem; připojí se za `dbi:mysql:dbname=…;host=…;port=…` (resp. `dbi:Pg:…`), např. `"mysql_ssl=1"`, `"mysql_connect_timeout=5"`, `"sslmode=require"`. Výchozí prázdné = DSN jako ve starších verzích. Přepis přes `PWE_CONF_dbi_db1_dsn_options` funguje jen tehdy, když klíč v konfiguraci existuje (stačí prázdný). Podrobnosti: [09 — Šifrované spojení a volby DSN](09-databaze-a-entity.md#šifrované-spojení-a-volby-dsn-dsn_options) |
| `daomap_file` | pokud soubor existuje, mapa tabulek se čte z něj (rychlejší start, ale po změně schématu ho smaž) |
| `dbversion_file` | soubor migrací; bez něj se migrace nespouští |

Více databází = více klíčů (`db1`, `db2`, …). Bez sekce `dbi` (web bez `database.conf`) běží
engine bez databáze; entity a služby závislé na DB se pak nenačtou.

## Migrace schématu: `conf/<driver>.dbversion`

Soubor je Perl hash `{ číslo => "SQL příkaz", … }`. Při startu engine (pro každé `dbid`
s `dbversion_file`):

1. založí tabulku `dbversion (dbversion int, lockid int)`, pokud neexistuje,
2. vezme zámek (`lockid`; souběžné procesy čekají),
3. provede **vzestupně** všechny příkazy s číslem **větším** než uložená verze, po každém
   zapíše novou verzi a commitne,
4. při chybě SQL udělá rollback, uvolní zámek a skončí s chybou (proces se nespustí).

```perl
{
    1 => "CREATE TABLE `dbtable` ( ... )",      # nastavení stránkovaných tabulek (Services::DBTable)
    2 => "CREATE TABLE `session` ( ... )",      # DB session (Services::Session)
    3 => "
        CREATE TABLE `tasks` (
          `id` int(8) unsigned NOT NULL AUTO_INCREMENT,
          `title` varchar(128) NOT NULL,
          `note` text DEFAULT NULL,
          `done` enum ('t', 'f') NOT NULL DEFAULT 'f',
          `updated` timestamp NULL DEFAULT NULL ON UPDATE CURRENT_TIMESTAMP,
          `created` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
          PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb3 COLLATE=utf8mb3_czech_ci;
    ",
    4 => "ALTER TABLE `tasks` ADD COLUMN `priority` tinyint NOT NULL DEFAULT 0",
};
```

Pravidla:

- Každá změna schématu = **nové číslo**; už aplikované příkazy nikdy neměň (neprovedou se znovu).
- Jeden příkaz na klíč (`command` volá `do()`); více příkazů = více klíčů.
- Udržuj soubor pro každý driver, který web podporuje (syntaxe SQL se liší).
- Sloupce `created TIMESTAMP DEFAULT CURRENT_TIMESTAMP` a `updated TIMESTAMP NULL` entity
  vyplňují automaticky ([09 — Databáze](09-databaze-a-entity.md)).
- Tabulky `dbtable` a `session` potřebují služby `DBTable` a `Session`; `mailqueue` služba
  `Email` (SQL je v POD `PWE/Entities/MailQueue/MailQueue.pm`).
- Vývojový stack má databázi pro každý web zvlášť (pojmenované volumes); `make down … ARGS=-v`
  ji smaže a migrace se při dalším startu spustí znovu.

## `Dockerfile`, `vars` a vstupní skript

`Dockerfile` (generátor ho vytvoří; všechny weby mají stejnou šablonu, liší se názvem webu a profilem).
Začíná komentářem s popisem image a příkazy sestavení; za ním následuje (zde pro web s MariaDB,
`<nazev>` = název webu, přesně jako `webapps/example-db.web/Dockerfile`):

```dockerfile
ARG PWE_IMAGE_REGISTRY=ghcr.io/kukam
ARG PWE_IMAGE_TAG=master
ARG PWE_ENGINE_TAG=${PWE_IMAGE_TAG}
ARG PWE_PROFILE=mariadb

FROM ${PWE_IMAGE_REGISTRY}/pwe:${PWE_ENGINE_TAG} AS engine
FROM ${PWE_IMAGE_REGISTRY}/pwe-${PWE_PROFILE}:${PWE_IMAGE_TAG}
ARG PWE_IMAGE_REGISTRY
ARG PWE_IMAGE_TAG
ARG PWE_PROFILE

COPY --from=engine /PWE/PWE /PWE/PWE
COPY --from=engine /PWE/LICENSE /PWE/LICENSE

# PWE_CONF_pwe_core=/PWE/PWE nastavuje uz zakladni image pwe-base. PWE_PROFILE = profil, pro ktery je image
# sestaveny. Za behu ho lze prepsat (-e PWE_PROFILE=...) jen na profil, jehoz ovladac image obsahuje:
# pwe-mariadb a pwe-mysql umi mariadb i mysql (engine pro oba pouziva DBD::mysql), pwe-postgres jen
# postgres, pwe-static zadnou databazi. Entrypoint pak conf/database.conf presmeruje na novy profil.
ENV PWE_CONF_pwe_home=/PWE/webapps/<nazev> \
    PWE_PROFILE=${PWE_PROFILE}

# Popisky image webu. Jinak by se zdedily popisky behoveho image (nazev pwe-<profil>, popis "bez kodu
# enginu", repozitar a licence enginu), ktere o image webu neplati. source a licenses jsou proto prazdne -
# dopln adresu repozitare a licenci webu; base.name = behovy image, ze ktereho je image sestaveny.
LABEL org.opencontainers.image.title="<nazev>" \
      org.opencontainers.image.description="Web <nazev> nad PWE (Perl Web Engine): engine v /PWE/PWE, web v /PWE/webapps/<nazev>" \
      org.opencontainers.image.source="" \
      org.opencontainers.image.licenses="" \
      org.opencontainers.image.base.name="${PWE_IMAGE_REGISTRY}/pwe-${PWE_PROFILE}:${PWE_IMAGE_TAG}"

WORKDIR /PWE/webapps/

COPY webapps/<nazev> <nazev>

WORKDIR /PWE/webapps/<nazev>

# Pracovni adresare a conf/database.conf (symlink na konfiguraci profilu, pokud ji web ma) vznikaji uz pri
# buildu: image tak bezi i s korenovym souborovym systemem jen pro cteni (pracovni adresare pak jako tmpfs
# nebo volume). Entrypoint dela totez pri startu - kvuli prepsani PWE_PROFILE a mountum pres adresar webu.
RUN set -eu; \
    mkdir -p ramdisk/templates sessions uploadfile log; \
    if [ -f "conf/${PWE_PROFILE}.conf" ] && { [ -L conf/database.conf ] || [ ! -e conf/database.conf ]; }; then \
        ln -sfn "${PWE_PROFILE}.conf" conf/database.conf; \
    fi

# ENTRYPOINT se dedi z behoveho image (/usr/local/bin/entrypoint.sh z pwe-base), web vlastni nema.
CMD ["perl", "/PWE/PWE/pwe.fcgi"]
```

Image webu se skládá ze tří částí: **běhové prostředí** z image `pwe-<profil>` (Perl, knihovny,
DB ovladač a vstupní skript; `PWE_PROFILE` je `mariadb`, `mysql`, `postgres`, nebo `static` u webu bez
databáze), **engine** zkopírovaný z image `pwe` do `/PWE/PWE` a **web** v `/PWE/webapps/<nazev>`.
Proměnnou `PWE_CONF_pwe_core=/PWE/PWE` má už základ `pwe-base`, proto v `Dockerfile` webu není.
`PWE_PROFILE` je argument sestavení i proměnná prostředí hotového image (proto jsou `ARG` za druhým
`FROM` deklarované znovu); kontejner ji předávat nemusí, za běhu ji lze přepsat (`-e PWE_PROFILE=…`)
na profil, jehož ovladač image obsahuje. `LABEL` dá image webu vlastní popisky (`source` a `licenses`
doplň podle repozitáře webu). `RUN` založí pracovní adresáře a symlink `conf/database.conf` už při
sestavení, takže image běží i s kořenovým souborovým systémem jen pro čtení.

```bash
# z kořene repozitáře; z image aktuální větve (tak je označuje make images i pipeline)
docker build --build-arg PWE_IMAGE_TAG="$(bash PWE/tools/lib/images.sh pwe_image_tag)" \
    -t muj-web -f webapps/<nazev>/Dockerfile .
docker build -t muj-web -f webapps/<nazev>/Dockerfile .                                    # image větve master
docker build --build-arg PWE_IMAGE_TAG="$(bash PWE/tools/lib/images.sh pwe_image_tag)" \
    --build-arg PWE_ENGINE_TAG="$(cat PWE/VERSION)" -t muj-web:1.0 -f webapps/<nazev>/Dockerfile .   # engine připnutý na verzi
```

Staví se z kořene repozitáře, protože `COPY` kopíruje `webapps/<nazev>`; kořenový `.dockerignore`
přitom vynechá `conf/local.env`, `conf/database.conf`, soukromé klíče pod `conf/` (`*.pem`, `*.key`,
`*.p12`, `*.pfx` — kontejner je dostává až za běhu mountem), dočasné adresáře a `.git` webu.
`docker build` bere image enginu z místního Dockeru, a když tam nejsou, z registru: nad image
sestavenými jen lokálně (`make images`) proto stačí předat jejich tag
(`--build-arg PWE_IMAGE_TAG=<větev>`, první příkaz). Jen `docker buildx build` staví vybraným
builderem, který místní image vidět nemusí — pak `--builder <builder s ovladačem docker> --load`.
To, argumenty sestavení, přidání vlastní knihovny a registr image:
[17 — Nasazení](17-nasazeni.md#image-vlastního-webu).

**Vstupní skript** web nemá. `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]` dědí image webu z běhového
image `pwe-<profil>`; jediný zdroj je `PWE/docker/entrypoint.sh` a stejný skript mají všechny image
enginu i služby `fcgi` a `debugger` vývojového stacku (nový skript se do image webu dostane se
sestavením nad novým běhovým image). Spouští se v adresáři webu (`WORKDIR` image, `working_dir`
služby v compose) a před spuštěním příkazu:

1. podle `PWE_PROFILE` (`mariadb`, `mysql`, `postgres`) nasměruje symlink `conf/database.conf` na
   `<profil>.conf`, pokud tento soubor existuje. Existující symlink nahradí (atomicky), běžný soubor
   `conf/database.conf` — vlastní konfiguraci webu — nepřepíše. Bez `PWE_PROFILE` nebo s hodnotou
   `static` se `conf/database.conf` nemění (existující symlink zůstane);
2. založí `ramdisk/templates`, `sessions/`, `uploadfile/` a `log/`;
3. spustí příkaz (`exec "$@"`, výchozí `perl /PWE/PWE/pwe.fcgi`).

Chyby zápisu ignoruje (web namountovaný jen pro čtení start neshodí); mimo adresář webu, tedy bez
`conf/web.conf` v aktuálním adresáři, jen spustí příkaz. Start nikdy nepřeruší, ale když `PWE_PROFILE`
neodpovídá webu (neznámá hodnota, databázový profil u webu bez `conf/<profil>.conf`, symlink nejde
nastavit, profil `static` se zbylým symlinkem), vypíše jednořádkové varování
`[entrypoint] VAROVANI: …` ([17 — Nasazení](17-nasazeni.md#co-je-v-pwe-base)). Web vytvořený starší
šablonou měl vlastní kopii `entrypoint.sh` — smaž ji a `Dockerfile` nahraď výstupem generátoru.

Soubor `vars` nastaví proměnné pro ruční běh enginu v CGI režimu uvnitř kontejneru
(`. vars; QUERY_STRING='page=default' perl /PWE/PWE/pwe.fcgi`).

Proměnné prostředí, které engine čte mimo `PWE_CONF_*`: `FCGI_SOCKET_PATH` (`:7779` = TCP
port FastCGI; bez něj engine obslouží jeden request z prostředí a skončí), `FCGI_DAEMONIZE`
(odpojit od terminálu), `PWE_PROFILE` (jen pro vstupní skript). Image běží v UTC; proměnná `TZ`
platí jen při startu enginu, ne během požadavků (FastCGI při každém požadavku nahradí prostředí
parametry od webserveru) — viz [17 — Časové pásmo](17-nasazeni.md#časové-pásmo).

## Co je v gitu

Kořenový `.gitignore` ignoruje `webapps/*` (kromě `README.md`, `.htaccess` a vzorových webů
`example.web` a `example-db.web`) — **vlastní web má svůj git repozitář**, naklonovaný do
`webapps/<nazev>/`. Uvnitř webu patří do gitu vše kromě dočasných
dat (`ramdisk/`, `sessions/`, `uploadfile/`, `log/`, `conf/database.conf`, `conf/*_daomap.dump`)
a lokálních tajných údajů (`conf/local.env`, soukromé klíče). Dočasné adresáře, `conf/database.conf`,
`conf/local.env` a soukromé klíče pod `conf/` (`*.pem`, `*.key`, `*.p12`, `*.pfx`) vynechává i kořenový
`.dockerignore`, takže se nedostanou ani do image webu
([17 — Nasazení](17-nasazeni.md#image-vlastního-webu)).
Stejný adresář pak funguje dvěma způsoby: ve vývoji ho spouští kořenový `docker-compose.yml`
s enginem z pracovní kopie (adresář `PWE/` repozitáře, v kontejneru `/PWE/PWE`); v produkci má
vlastní `Dockerfile`, který si engine zkopíruje z image `ghcr.io/kukam/pwe` (tamtéž, `/PWE/PWE`).
