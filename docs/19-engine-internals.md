# 19 — Vnitřní fungování enginu

Kapitola pro **údržbáře enginu** (`PWE/Libs/`, `PWE/pwe.fcgi`). Autoři webů ji nepotřebují.
Pravidla změn v enginu: každá oprava má regresní test v `PWE/t/`, `make test` a `make compile`
zelené, záznam v `PWE/CHANGELOG.md`, změna kontraktu = zvýšení `PWE/VERSION`.

Engine je celý v adresáři `PWE/` v kořeni repozitáře (v kontejneru `/PWE/PWE`). V kódu a konfiguraci
se tento adresář nazývá **kořen enginu** a nese historické jméno „core“: klíč `pwe.core`, proměnná
`PWE_CONF_pwe_core`, metody `getCore()`/`coreVersion()`, seznamy `pwe.core_pages` atd. Tyto názvy
jsou kontrakt a s názvem adresáře nesouvisejí.

## Vstupní bod a FastCGI smyčka

[`PWE/pwe.fcgi`](../PWE/pwe.fcgi):

- `dirname`/`basename` skriptu se odvodí ručně (kvůli relativnímu i absolutnímu spuštění, cronu).
- Kořeny: `pwe.home` (web) z `PWE_CONF_pwe_home` (jinak adresář skriptu), `pwe.core` (engine, adresář
  `PWE/`) z `PWE_CONF_pwe_core` (jinak adresář skriptu). `@INC` se seřadí tak, aby web byl před enginem
  (odstranění a `unshift`).
- `Libs::Config::checkCoreVersion` ověří `pwe.require_core` proti `PWE/VERSION`; při nesplnění
  skript skončí s chybou.
- `CGI::Fast` se socketem z `FCGI_SOCKET_PATH` (`socket_perm 0770`), limity uploadu z conf
  (`cgi_disableupload`, `cgi_maxfilesize`, `cgi_maxopentries`, `cgi_tmpdirectory`).
  Bez socketu obslouží jeden request z prostředí a skončí (CGI režim).
- `FCGI_DAEMONIZE` → `daemonize()` (fork + `setsid`); `SIGTERM` → `end()` → `disconnect` všech DB.
- Smyčka `while (my $CGI = CGI::Fast->new()) { … }`; po každém průchodu `undef @CGI::QUERY_PARAM`.

Vedle něj leží [`PWE/debug.cgi`](../PWE/debug.cgi): přes `require` načte tentýž `pwe.fcgi`, jen pod
jménem `debug.cgi` — slouží k ladění ve VS Code přes nginx location `/debug.cgi`
([16 — Nástroje a ladění](16-nastroje.md)).

Singletony se staví jednou a žijí po celou dobu procesu — proto stav requestu patří do `$USER`.

## Loadery (Pages / Sites / Services / Entities)

Společný vzor (`Libs::Pages::loadPages` apod.):

1. `findX()` — projde kořeny z `Libs::Config::getModuleRoots($typ)`: adresář webu (vše) a adresář
   enginu (jen názvy z `pwe.core_<typ>`; `"*"` = vše). Akceptuje jen `Dir/Dir.pm`, řadí abecedně,
   stejný název ve webu vítězí.
2. `loadX($name)` — `eval "require Pkg::Name::Name"` a `eval "… = new Pkg::Name::Name(...)"`
   (řetězcový eval s `local $SIG{__DIE__}`; lexikální kopie globálů se předávají jménem).
   Selhání → `error` + `unloadX`.
3. `Class::Inspector->methods(...,'full','public')` → seznam metod do `$self->{'methods'}->{$name}`.
4. Registrace závislostí: metody `Site_X` / `Service_X` → `callXMethod($name, "Service_Y", $OBJ)`.
   Neexistující závislost = modul se odregistruje.
5. `registerResourceBundle` (jen Pages): mapa rb souborů stránky (entity → injektované služby →
   injektovaný vzhled → stránka) do `Libs::Web::rb_map`, pro každý jazyk z `http.languages`
   (`rb.tmpl` = první jazyk, `rb_<LANG>.tmpl`).
6. `autostart()` tam, kde existuje.

Pořadí buildu Entities → Services → Sites → Pages zaručuje, že závislost už existuje. Globální
proměnné modulů (`my ($CONF, …)`) se nastavují v `new()`; blok `KOMODO` je mrtvý kód pro IDE.

## Routing a volání stránky

`Libs::Pages::callPageFunc($page, $func)`:

```
isExistPage / isExistPageFunc     ne → 404
accessFunc                         ne → 401   (func->{f} neprázdný ? func->{f} : access; prázdné = každý)
checkInputData                     chyby → error->{f}($errors) nebo f($errors)
callPageMethod                     eval { local $SIG{__DIE__}='DEFAULT'; $obj->$f($arg) }
                                   die → log, unloadPage, sendErrorReport, reloadPage → 500
                                   návrat 1 → 200; jiné číslo se propaguje
```

`checkInputData`: `replace → defined → validate → rules → exist → unique`, každá další fáze jen
bez chyb předchozí. Metody `checkDefined`, `checkParameters` (validate), `checkRules`,
`checkExist`, `checkUnique`, `replaceInputParameters`; zápis `param#sloupec` řeší `getPnameCname`.
Validační chyby se logují jako `[E]`.

`reloadPage` po pádu znovu vytvoří objekt **a** zopakuje injektáž i registraci rb (bez toho by
stránka přišla o služby a texty). `require` už načteného modulu (`%INC`) kód nerekompiluje —
reload znamená jen novou instanci; oprava zdrojáku vyžaduje restart procesu.

## Samoléčení a reporty

Pád metody stránky/služby/vzhledu/entity/validátoru: `chomp $@` → `$LOG->error` → `unloadX` →
`$LOG->sendErrorReport(TYP, $name, $method, $error)` → reload → 500. Report (dump prostředí,
místo, chyba) jde e-mailem přes `Libs::Send` na `web.email_admin` přes servery z `pwe.smtp_servers`;
stejná chyba (`TYP:název:metoda`) nejvýše jednou za `log.error_report_interval` s, potlačené se
počítají do dalšího reportu.

## `Libs::User`

- `newRequest`: session id musí mít přesně tvar prefix `C0` (HTTP) / `C1` (HTTPS) + 32 hex znaků,
  jinak se vygeneruje `uc("C0|C1" . md5_hex(time . rand))` (`generateSid`). Do 2.2.0 stačil
  libovolný hex (`is_md5hex`), takže šla podstrčit cookie typu `C0ABC`. Nastaví IP do logu,
  skupinu `guest`, načte opts (`pwe.enable_opt`, `save_opt_to = file`: `Storable::retrieve`
  z `opts_dir/<3 znaky>/<sid>.bin`).
- `regenerateSid`: nové sid stejným postupem, uloží do objektu a vrátí; `printHttpHeader` bere
  `cookie_id` z `getSid()` při každém volání, takže novou cookie pošle sám. Opts se ve `flush`
  zapíší už pod nové sid (starý soubor zůstane do úklidu podle `pwe.expire_opts_time`).
- Opts: `lastpage`, `lastfunc`, `language`, `lastenv`, `lastparameters`, `options`, messenger.
  `flush` ukládá atomicky (`.tmp` + `rename`); hodnoty uploadů (`Fh`) se ukládají jen jako název
  (`exportParameters`). `save_opt_to = db` → perzistenci dělá `Services::Session`.
- `saveUploadFile` ořízne jméno od klienta na `basename`.
- `flush` na konci kompletně vynuluje stav requestu.

## `Libs::Web`

- `genTmpl`: doplní automatické proměnné ([06](06-sablony-a-i18n.md)), sestaví `rb_list`
  (výchozí jazyk, pak jazyk uživatele), podle přípony zvolí volby TT. Objekt `Template` se drží
  v `template_cache` na kombinaci voleb po celou dobu procesu (dřív nový objekt na každý render —
  nejdražší část requestu). Po každém renderu `resetTemplateStash` vrátí objektu jeho kořenový stash — TT
  proměnné lokalizuje sám (`clone`/`declone`), ale šablona s `[% PERL %]` blokem mohla stash poškodit (historicky
  `DumpData.tmpl` mazal `_PARENT`) a proměnné by zůstaly ve sdíleném objektu pro další requesty.
- `genTemplateObject`: `INCLUDE_PATH` = kořeny (web, engine), `COMPILE_DIR` = `pwe.home + tmpl.croot`,
  `COMPILE_EXT c` při `tmpl.cache`, `EVAL_PERL`/`RECURSION` z conf.
- `printHttpHeader`: mapa `type` → `templates/HttpHeader*.tmpl`, GMT datum, expirace cookie
  (`http.cookie_expire_day`, jinak `cookie_expire_guest`, jinak 100 dní). Typ `static` bez cookie
  s cache hlavičkou.
- `printAjaxLayout` → `setAjax` → `renderReplaceJSON` (`{"REPLACE":[{ID,HTML}]}`), messenger pod `messenger`.
- `flush`: nuluje AJAX buffer a `idp` (cache šablon zůstává).

## `Libs::MyDBI`

- Pro každé `dbid` `db_pool + 1` spojení (`createConnection`); pool 0 zamčený (`setPoolLock(1)`)
  jako sdílený pro nízkoúrovňové dotazy; DAO si přes `createDAO` najde odemčený pool (jinak pool 0
  s varováním), zamkne ho a v `DESTROY` uvolní; `disable_db_pooler` = sdílený pool 0 (sdílené entity).
- `createConnection` loguje neúspěch včetně chyby DBI z `getError()` ovladače
  (`… connect_status:0 error:<kód> <text>`). Ovladač MySQL otevírá každé spojení přes `dbiConnect`:
  nejdřív DSN z `getDsn()` (klíče `database`, `host`, `port` a `dsn_options`), po chybě 2061 ještě
  jednou s `mysql_ssl=1` (pokud `dsn_options` neobsahují `mysql_ssl=`).
- `testConnection` pinguje nejvýše jednou za `pwe.db_ping_interval` s; při výpadku `reconnect`
  (až `trayconnect` pokusů po 1 s, pak `die` → restart procesu).
- Drivery: MySQL dvě handle (`DBI_R` autocommit pro SELECT, `DBI_W` transakční), Postgre jedno;
  `prepare_cached` pro SELECT/INSERT/UPDATE/DELETE; SQL komentář s místem volání jen při
  `log.loglevel >= 3` (jinak by každé místo volání rozbilo cache dotazů).
- `getDaoMetaData` čte `information_schema` (MySQL + `SHOW TABLE STATUS`/`DESCRIBE`, Postgres
  `information_schema.columns/constraint_column_usage`) → DAO mapa; `daomap_file` ji cachuje.
- `checkDbversion`: tabulka `dbversion(dbversion, lockid)`, zámek `lockid` (náhodné číslo),
  příkazy s číslem > uložená verze vzestupně, commit po každém, při chybě rollback + die.

## `Libs::MyDBI::DAO` a `Entities::Entity`

- Konstruktor z DAO mapy vytvoří popis sloupců (`type, size, null, def, unsig, unique, enumv, value`),
  odmítne sloupec pojmenovaný jako interní metoda.
- `AUTOLOAD`: getter / setter (`CheckValue` podle typu přes `Libs::Validate::is_sql_*`; `setValue`
  eviduje změnu jen při rozdílu, boolean normalizuje).
- `flush`: bez PK INSERT (`createInsertQuery`; `NULL`/`NOW()` speciální hodnoty), s PK UPDATE;
  před zápisem `CheckUniqueValue` nad UNIQUE sloupci. `commit` vyprázdní seznam změn (objekt lze
  držet přes request), `flush` ho nechává kvůli `logit`. `rollback` → `clearAllMethod`.
- `Entities::Entity`: `flush` doplní razítka (`autoUpdateTimestamp`), `AUTOLOAD` deleguje na DAO a
  nastaví `setWhoCallingMe` (místo volání do SQL komentáře).

## `Services::Session`

`newSession` načte/založí řádek podle sid (expirovaný smaže a založí znovu), aktualizuje IP a
User-Agent, nastaví jazyk; entitu drží do konce requestu, `flush` ji použije bez dalšího SELECTu
a UPDATE + commit dělá jen při změně hodnoty.

`regenerate` (ochrana proti session fixation, volá služba účtu po přihlášení): bez `newSession`
v requestu ji zavolá; smaže starý řádek (`DELETE_ROW` + commit), nechá `Libs::User` vygenerovat nové
sid, založí nový řádek ze stejných dat (`$self->{'session'}` včetně vlastních sloupců webu; `created`/
`updated` doplní entita, `sid` nové) a drží ho pro `flush`. Vrací nové sid.

`cleanupExpired` (volá `newSession` při zakládání nového řádku): počítadlo nových session v objektu
služby; při první a pak každé `http.session_cleanup_every`-té (výchozí 20, `0` = vypnuto) provede
`DELETE FROM session WHERE expire < ?` s unixovým časem (přenositelné MariaDB/Postgres) přes spojení
entity a commit. Bez toho zůstávaly řádky návštěvníků bez cookie v tabulce navždy — `newSession`
mazala expirovaný řádek jen při návratu stejného sid.

## `Libs::Log`

Úrovně 0–4, `who` = balíček:řádek volajícího, filtry whitelist/blacklist podle balíčku,
`delay` měření, výstup STDOUT/STDERR/soubor (handle drží otevřený, znovu otevře po rotaci).

## Bezpečnostní pojistky

- session cookie jen přesně `C0`/`C1` + 32 hex s prefixem vázaným na HTTP/HTTPS; výměnu sid po
  přihlášení (session fixation) musí zavolat služba účtu webu (`Services::Session::regenerate`,
  `Libs::User::regenerateSid`) — engine neví, kdy k přihlášení došlo;
- `pweCreator` zapisuje soubory jen při `pwe.development` (jinak 401) a jen s názvy-identifikátory
  (`rules`), takže z parametru nejde složit cesta mimo adresář modulů;
- routing odmítne `..` v `SCRIPT_FILENAME` (401), statiku servíruje jen z `pwe.assets_dir`/`assets_file`;
- `escape_jsinjection` přes `replace`, TT filtr `| html`;
- konfigurace přepsatelná jen pro existující klíče (`PWE_CONF_*`), tajné hodnoty mimo soubory;
- pád modulu izolován, report s omezením četnosti.

## Náměty na další vývoj

- CI: pipeline `.github/workflows/images.yml` už před publikací image spouští `run-tests.sh`
  a `perl-compile.sh` v `pwe-base` ([18 — Testy](18-testy.md#ci)); zbývá `check-webapp.pl` na
  vygenerovaném webu a integrační průchod přes compose.
- Testy nad skutečnou DB (service container MariaDB nebo `DBD::SQLite` v image).
- Postupné zapnutí `use warnings` v `Libs/`.
- `Perl::Critic`/`Perl::Tidy` jsou v image `pwe-debugger`; zbývá je zapojit do CI.
- Sdílená služba účtů v enginu (tabulka uživatelů, hash hesla), aby ji weby jen linkovaly.
- Logovat validační chyby vstupu úrovní `warning` místo `error`.

Hotovo z dřívějších námětů: základní image je připnutý na `ubuntu:26.04` (dřív plovoucí tag) a image
se publikují automaticky do `ghcr.io/kukam` s tagem podle větve — uspořádání sedmi image popisuje
[17 — Nasazení](17-nasazeni.md#image).

Historie oprav a změn enginu je v [`PWE/CHANGELOG.md`](../PWE/CHANGELOG.md).
