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
- Limity uploadu z conf (`cgi_disableupload`, `cgi_maxfilesize`, `cgi_maxopentries`,
  `cgi_tmpdirectory`); `FCGI_DAEMONIZE` → `daemonize()` (fork + `setsid`).
- **Socket** otevírá engine sám, až po startu všech singletonů (`listen_socket`): `FCGI::OpenSocket`
  nad hodnotou `FCGI_SOCKET_PATH`, `chmod` jen unix socketu (`FCGI_SOCKET_PERM` čtená osmičkově,
  výchozí 0770; socket vzniká s maskou 0177) a request FastCGI předá do `$CGI::Fast::Ext_Request`.
  `CGI::Fast` to sám dělat nesmí: svůj parametr `socket_perm` i `FCGI_SOCKET_PERM` čte desítkově
  (`'0770'` = práva 1402) a `chmod` zkouší i u adresy `host:port`. Zda jde o adresu TCP, určuje
  `socket_is_tcp` stejným pravidlem jako knihovna FastCGI (za první dvojtečkou nenulové číslo portu).
  Bez `FCGI_SOCKET_PATH` engine převezme socket zděděný po webserveru (deskriptor 0), jinak obslouží
  jeden request z prostředí a skončí (CGI režim).
- **Smyčka** `while (my $CGI = next_request()) { … }`; po každém průchodu `undef @CGI::QUERY_PARAM`.
  `next_request` volá `CGI::Fast->new()` a rozlišuje, proč se vrátil bez requestu — výsledek `Accept`
  si pamatuje třída `PWE::Request` (potomek `FCGI`; `CGI::Fast` ho zahazuje): `EINTR` = jiný signál,
  zkusit znovu; `EAGAIN` = žádné spojení nečeká, počkat (`wait_connection`: `select` nejdéle 1 s);
  cokoli jiného = konec smyčky. Na Linuxu je naslouchající socket **neblokující**, takže knihovna
  v `accept()` nikdy nezůstane viset a příznak ukončení se zkontroluje nejpozději za sekundu — samotné
  přerušení `accept()` signálem nestačí (signál těsně před vstupem do `accept()` čekání nepřeruší
  a knihovna se po prázdném spojení vrací do `accept()` sama). Jinde zůstává socket blokující.
- **Ukončení** (`SIGTERM`, `SIGUSR1` → `terminate`): handler jen nastaví příznak `$STOP`, během startu
  zavolá `Libs::MyDBI::requestStop()`, zakáže knihovně další accept (`LastCall`) a zavře naslouchající
  socket. Rozpracovaný request doběhne (po dobu requestu mají handlery příznak `SA_RESTART`, aby signál
  nepřerušil čtení těla ani odesílání odpovědi — `signal_restart`), po smyčce se výslovně dokončí
  (`Ext_Request->Finish()`), pak `end()` (odpojení databází, lze volat opakovaně i před vznikem `$DBI`)
  a kód 0. Start `Libs::MyDBI->new` běží v `eval`: výjimka `Startup interrupted by termination request`
  po signálu = kód 0 (`startup_failed`), jiná chyba se vyhodí znovu beze změny. Handlery se nastavují
  už v bloku `BEGIN` před načtením `FCGI` — knihovna by si jinak na `TERM` a `USR1` pověsila vlastní.
  Chyba čekání na request = `[E]` a kód 1. Popis pro provozovatele:
  [17 — Běh procesu enginu](17-nasazeni.md#běh-procesu-enginu); testy `PWE/t/24-shutdown.t`.

Engine tím závisí na vnitřnostech `CGI::Fast` (`$CGI::Fast::Ext_Request`) a `FCGI` (dědění z třídy
`FCGI`, `FAIL_ACCEPT_ON_INTR`, `LastCall`); změnu jejich chování po aktualizaci balíčků odhalí
`24-shutdown.t`.

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
- `checkDbversion`: tabulka `dbversion(dbversion, lockid)`, příkazy s číslem > uložená verze
  vzestupně, commit po každém, při chybě rollback + die. Proti souběžné migraci chrání dva zámky —
  viz [Zámek migrace](#zámek-migrace-checkdbversion) níže.
- `requestStop()` / `stopRequested()` (funkce paketu, jdou volat i jako metody třídy): příznak
  „engine má při startu skončit“, který nastavuje handler `SIGTERM` v `pwe.fcgi`. Konstruktor ho
  kontroluje před každým pokusem o připojení (i opakovaným, mezi pokusy pak už nečeká),
  `checkDbversion` při čekání na zámek, před zápisem `lockid` a před každým krokem migrace — nikdy
  uprostřed kroku a ne po posledním kroku. Po úklidu zámků končí start přes
  `die "Startup interrupted by termination request\n"`; ten text je kontrakt s `pwe.fcgi`
  (`$Libs::MyDBI::STOP_MESSAGE`).

### Zámek migrace (`checkDbversion`)

Metoda je rozdělená na `dbversionSessionLock` (zámek spojení), `dbversionMigrate` (tabulka, `lockid`,
kroky) a pomocné `dbversionPending`, `dbversionDaoFromDb`, `dbversionLegacyWait`,
`dbversionLegacyLimit`, `dbversionNow`, `dbversionTableExists`, `dbversionRead`, `dbversionCountTry`.

1. **Zámek spojení** — `sessionLock($name, $timeout)` ovladače nad spojením pool 0, logické jméno
   `dbversion`. Vrací 1 (získán), 0 (drží ho jiné spojení) nebo `undef` (chyba, zámek není
   k dispozici); `sessionUnlock($name)` vrací 1/0. Server zámek uvolní sám, když spojení zanikne.
   - MySQL/MariaDB: `GET_LOCK('pwe.<jméno>.<databáze>', <čas>)` nad zapisovacím spojením `DBI_W`
     (tím, které provádí kroky migrace); jméno delší než 64 znaků se nahradí `pwe.<md5 hex>`. Po
     dobu držení zámku je vypnutý tichý reconnect ovladače (`mysql_auto_reconnect`), aby se ztracené
     spojení neobnovilo bez zámku.
   - PostgreSQL: poradní zámek úrovně session `pg_try_advisory_lock(k1, k2)` v cyklu po 0,2 s; klíč
     jsou dvě čísla z prvních 8 bajtů MD5 řetězce `pwe.<jméno>.<schema>`. `sessionUnlock` ve zrušené
     transakci (SQLSTATE 25P02) udělá rollback a zkusí to znovu. Před prvním získáním ověřuje
     v `pg_locks`, že serverové spojení zámek ještě nemá (pooler v režimu transaction pooling) —
     pak vrací `undef`.
   - Zámek není součástí transakce: commit ani rollback ho neuvolní, funguje s autocommitem
     zapnutým i vypnutým. Vlastní ovladač bez těchto metod, vypnutí klíčem
     `dbi.<dbid>.dbversion_session_lock => 0` a `undef` z ovladače = **režim bez zámku spojení**
     (chování starších verzí).
2. **Sloupec `dbversion.lockid`** se zapisuje a uvolňuje dál kvůli starším verzím enginu, které zámek
   spojení neznají — ale jen tehdy, když je co migrovat nebo uklidit. Znaménko říká, jak je majitel
   chráněn: proces se zámkem spojení zapisuje **záporné** číslo, proces bez něj **kladné** (starší
   verze porovnávají jen „nenulový a není můj“). Vlastní číslo není nikdy 0.

Po získání zámku spojení se při vypnutém autocommitu vždy ukončí transakce, ve které se o zámek
žádalo (rollback zámek úrovně session neuvolní) — čtení pod zámkem tak vidí aktuální stav i při
izolaci REPEATABLE READ. Pod zámkem spojení `dbversionMigrate` ověří a případně založí tabulku. Řádek do
tabulky bez řádku (právě založené i nalezené) doplní až po druhém prázdném čtení o `$DBVERSION_POLL`
později — řádek může současně vkládat starší verze enginu, která chybu svého `CREATE TABLE` ignoruje.
Cizí záporný `lockid` (a `NULL`) převezme hned — jeho majitel by musel držet zámek spojení,
který teď drží tento proces — a na cizí kladný čeká přes `dbversionLegacyWait`: sleduje dvojici
(`dbversion`, `lockid`) a převezme ji podmíněným `UPDATE … WHERE lockid = ? AND dbversion = ?` až po
`dbversion_legacy_lock_wait` sekundách beze změny (monotonní hodiny, výchozí 300, `0` = nikdy).
Dokud zámek spojení drží jiný proces, čeká se jen tehdy, když má tento proces co migrovat
(`dbversionPending`, jen čtení) nebo si po migraci čte mapu DAO z databáze (`dbversionDaoFromDb`);
stejné pravidlo platí pro čekání na cizí kladný `lockid`.
Bez zámku spojení se na cizí `lockid` čeká v cyklu po 1 s jako dřív. Oba zámky se uvolní na všech
cestách ven (`eval` + rollback + uvolnění); když zámek spojení nejde uvolnit dotazem, spojení pool 0
se zavře a při úspěšném startu znovu otevře. Selhání zápisu verze po provedeném kroku, nečitelná
tabulka `dbversion`, selhání `CREATE TABLE` pod zámkem spojení (není-li tabulka čitelná jinde),
20 neúspěšných zápisů `lockid` (`$DBVERSION_MAX_TRIES`) a rozbitý soubor migrací končí přes `die`
místo tichého pokračování nebo nekonečné smyčky.

Proměnné paketu pro testy: `$STOP_REQUESTED`, `$DBVERSION_POLL` (1 s), `$DBVERSION_LOG_INTERVAL`
(30 s), `$DBVERSION_MAX_TRIES` (20), `$DBVERSION_LEGACY_WAIT` (300 s), `$DBVERSION_CLOCK`. Hlášky
a provozní důsledky: [17 — Migrace schématu při startu](17-nasazeni.md#migrace-schématu-při-startu);
testy `PWE/t/23-dbversion-lock.t` (falešná databáze) a `PWE/t/10-drivers.t` (ovladače).

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

Hotovo z dřívějších námětů: základní image je připnutý na `ubuntu:26.04` (dřív plovoucí tag; pipeline
ho navíc připíná na digest) a image se publikují automaticky do `ghcr.io/kukam` s tagy `<verze>`
a `latest` — z výchozí větve repozitáře a z větví v proměnné `PUBLISH_BRANCHES`; uspořádání devíti
image (pět závislostních a čtyři image vzorových webů) popisuje [17 — Nasazení](17-nasazeni.md#image). Od 2.2.1 je vyřešené i ukončování na `SIGTERM`
a zámek migrace, který přežil pád procesu (dřívější známá omezení).

Historie oprav a změn enginu je v [`PWE/CHANGELOG.md`](../PWE/CHANGELOG.md).
