# 14 — API reference

Přehled veřejných metod objektů, které má kód webu k dispozici. Zdrojem pravdy je POD ve zdrojácích
enginu v adresáři `PWE/` (v kontejneru `perldoc /PWE/PWE/Libs/Web.pm`); zde je výtah s tím, co stránky
a služby používají.
Signatury: `$x` skalár, `\@x` reference na pole, `%opt` seznam `klíč => hodnota`.

Jak se objekty dostanou do modulu ([04](04-stranky.md)):

| Proměnná | Třída | Stránka (`new`) | Služba / vzhled (`new`) | Entita (`new`) |
| --- | --- | --- | --- | --- |
| `$CONF` | `Libs::Config` | ano | ano | ano |
| `$LOG` | `Libs::Log` | ano | ano | ano |
| `$VALIDATE` | `Libs::Validate` | ano | ano | ano |
| `$DBI` | `Libs::MyDBI` | ano | ano | ano |
| `$ENTITIES` | `Libs::Entities` | ano | ano | — |
| `$USER` | `Libs::User` (ve stránce typicky nahrazen službou `UserAccount`) | ano | ano | ano |
| `$WEB` | `Libs::Web` (ve stránce nahrazen vzhledem přes `Site_X`) | ano | ano | ano |
| služby | `Services::X::X` | `Service_X` | `Service_X` | — |

## `$CONF` — `Libs::Config`

| Metoda | Popis |
| --- | --- |
| `getValue($sekce, $klic, $default)` | hodnota klíče; `undef` v konfiguraci = default, `0`/`''` se vrací; bez `$klic` celá sekce (hashref) |
| `isExistValue($sekce, $klic)` | 1/0 existence klíče (i s `undef`) |
| `getHome()`, `getCore()` | kořen webu (`pwe.home`) / kořen enginu (`pwe.core`, adresář `PWE/`) s koncovým lomítkem |
| `getRoots()` | seznam kořenů v pořadí hledání (web, engine) |
| `resolveFile($rel)`, `resolveDir($rel)` | kořen, ve kterém soubor/adresář existuje (web, pak engine), nebo `undef` |
| `getModuleRoots($typ)` | adresáře modulů `pages\|sites\|services\|entities` s povolenými názvy z `pwe.core_*` |
| `coreVersion()`, `checkCoreVersion()` | verze enginu, kontrola `pwe.require_core` |

## `$LOG` — `Libs::Log`

| Metoda | Popis |
| --- | --- |
| `error($msg)`, `warning($msg)`, `info($msg)`, `debug($msg)` | záznam `[E]`/`[W]`/`[I]`/`[D]` s balíčkem a řádkem volajícího; podle `log.loglevel` |
| `delay($key)`, `delay($key, $text)` | 1. volání uloží čas, 2. zapíše `[d]` s uplynulým časem a vrátí ho (jen při `log.log_delay`) |
| `getLogLevel()`, `setLogLevel($n)` | úroveň 0–4 |
| `setIP($ip)` | IP do záznamů (volá engine) |
| `sendErrorReport($typ, $kdo, $metoda, $chyba)` | e-mailový report (volají loadery; stejná chyba nejvýše jednou za `log.error_report_interval`) |

## `$VALIDATE` — `Libs::Validate`

| Metoda | Popis |
| --- | --- |
| `validate([$metoda, $klic_chyby, @args])` | spustí validátor; `undef` = OK, jinak `$klic_chyby` |
| `is_email($v)`, `is_language($v)`, `is_regx($v, $re)`, `isnot_regx($v, $re)`, `is_percent($v)`, `is_md5hex($v)`, `is_zipcode($null, $v)`, `validate_decimal_vat($v)`, `escape_jsinjection($v)` | vlastní validátory enginu |
| `is_integer`, `is_numeric`, `is_hex`, `is_oct`, `is_between($v,$min,$max)`, `is_greater_than($v,$n)`, `is_less_than($v,$n)`, `is_equal_to($v,$x)`, `is_even`, `is_odd`, `is_alphanumeric`, `is_printable` | z `Data::Validate` (v `rules`: `['is_between', 'err', 'parameter', 1, 99]`, meze včetně) |
| `is_int`, `is_tinyint`, `is_smallint`, `is_mediumint`, `is_bigint`, `is_float`, `is_double`, `is_decimal`, `is_char`, `is_varchar`, `is_enum`, `is_boolean`, `is_bit`, `is_binary`, `is_varbinary`, `is_tinyblob` | z `Data::Validate::MySQL` |
| `is_sql_int($driver,$v,$unsigned)`, `is_sql_tinyint`, `is_sql_varchar($driver,$v,$size)`, `is_sql_enum($driver,$v,\@vals)`, `is_sql_decimal($driver,$v,$p,$s,$unsigned)`, `is_sql_boolean($driver,$v)` | typy podle driveru (používá DAO) |
| `is_psql_boolean($v)` | Postgres boolean |

Konvence: definovaná hodnota = OK, `undef` = chyba. Neznámá metoda → `die` (AUTOLOAD).
Podrobnosti v [05 — Validace](05-validace.md).

## `$USER` — `Libs::User`

Ve stránce je `$USER` obvykle služba `UserAccount`, která tyto metody deleguje a přidává své
(`login`, `logout`, `getAccount`, `getSession`, `getGroup`, `setLanguage`, `isLoggedIn`).

| Metoda | Popis |
| --- | --- |
| `getParam($k, $idx\|'all', $default)` | hodnota parametru (index, celé pole, nebo první) |
| `getParams()`, `getParamsList()` | hash `{ název => [hodnoty] }` / seznam názvů |
| `isdefinedParam($k)`, `existParam($k)` | neprázdný / přítomný |
| `setParameter($k, \@hodnoty)`, `setParameter($k, $v, $pos)` | přepsat parametr |
| `getLastParam($k, $idx, $default)`, `existLastParam($k)`, `existLastParams()` | parametry předchozího requestu (z opts) |
| `getPage()`, `getFunc()`, `getActivePage()`, `setPage($p)`, `setFunc($f)` | aktuální stránka a akce |
| `getRequestMethod()` | `GET`/`POST` (z CLI parametr `request_method`) |
| `getSid()`, `getIP()`, `getUserAgent()`, `getCGI()` | session id, IP, User-Agent, objekt CGI |
| `regenerateSid()` | nové session id (`C0`/`C1` + md5) uložené do objektu; vrací ho. Po přihlášení proti session fixation — web s DB session volá místo toho `Services::Session::regenerate()`. Cookie pošle další `printHttpHeader()` sám |
| `getValue($klic, $podklic, $default)` | atribut objektu (`env`, `HTTP_HOST`), `language`, `page`, … |
| `getUid()`, `setUid($uid)` | id přihlášeného uživatele (nastavuje aplikace) |
| `addGroup($g)`, `deleteGroup($g)`, `existGroup($g)`, `getGroup()` | skupiny (role) |
| `setLanguage($lang)` | jazyk (jen z `http.languages`), ukládá se do opts |
| `setOpts($data, $klic, $podklic)`, `getOpts($klic, $podklic, $default)`, `delOpts($klic, $podklic)` | data mezi requesty |
| `setMessenger($html)`, `getMessenger()`, `existMessenger()` | flash zpráva v opts (stránky používají `$WEB->setMessenger`) |
| `saveUploadFile($param, $home, $path, $rewrite)` | uloží nahrané soubory; vrací `($error, @names)` |
| `newRequest(...)`, `flush()` | volá engine |

## `$WEB` — `Libs::Web` (a vzhled)

Vzhled webu (`Sites/Default`) tyto metody buď deleguje, nebo obaluje (`printHtmlHeader`,
`printHtmlLayout`, `printAjaxLayout`, `setMessenger`, `getMessenger`, `existMessenger`) a přidává
`getDefaultTemplateValues()`.

| Metoda | Popis |
| --- | --- |
| `setIDP($idp)`, `getIDP()` | id stránky (v šablonách `idp`; výchozí `unknownidp`) |
| `printHttpHeader(type => $typ, %tmpl)` | HTTP hlavička; typy v [10 — AJAX](10-ajax.md#typy-http-hlaviček); `log_output => 1` zaloguje |
| `printHtmlHeader(%tmpl)` | `<head>` z `layout_header` (z `%tmpl`, jinak atribut vzhledu); `title => …` |
| `printHtmlLayout(html_main => $cesta, %tmpl)` | tělo z `layout_body`; doplní `messenger` |
| `printAjaxLayout(ajax_id => \@ids, ajax_tmpl => \@tmpl \| ajax_html => \@html, ajax_data => \%data\|\@data)` | JSON `REPLACE` (+ messenger) |
| `setMessenger($tmpl, %tmpl)` | vyrenderuje šablonu a uloží jako flash zprávu |
| `existMessenger()` | je nastavena? |
| `genTmpl($src, %tmpl)` | render šablony (soubor podle přípony, nebo inline text) do řetězce |
| `genTemplateObject(%opt)` | objekt `Template` (cache per volby) — zřídka potřeba |
| `getScriptName()` | `pwe.fcgi` |
| `getParameters()` | hash prvních hodnot parametrů (v šablonách `parameters`) |
| `convertToRewrite($text)` | URL slug bez diakritiky |
| `setAjax($id, $html)`, `renderReplaceJSON()` | ruční skládání AJAX odpovědi |
| `getValue($klic, $default)` | atribut objektu (`idp`, `script_name`, `layout_body`) |
| `addResourceBundlePagePath`, `delResourceBundlePagePaths`, `getResourceBundleList($page, $lang)` | mapa rb souborů (používá engine) |
| `flush()` | volá engine |

Automatické proměnné šablon: [06 — Šablony](06-sablony-a-i18n.md#automatické-proměnné).

## `$DBI` — `Libs::MyDBI`

| Metoda | Popis |
| --- | --- |
| `select($dbid, $sql, \@bind)` | `SELECT` + `$sql`; vrací `$sth` (`fetchrow_hashref`, `fetchrow_array`, `finish`) |
| `insert($dbid, $sql, \@bind)` | `INSERT` + `$sql`; nic nevrací |
| `update($dbid, $sql, \@bind)` | `UPDATE` + `$sql`; počet řádků (`0E0` = 0, `undef` = chyba) |
| `delete($dbid, $sql, \@bind)` | `DELETE` + `$sql` |
| `command($dbid, $sql)` | celý příkaz (`do`) |
| `getLastInsertID($dbid, $table)` | id posledního INSERTu (před `commit`) |
| `commit($dbid)`, `rollback($dbid)` | transakce poolu 0 |
| `error($dbid)`, `getError($dbid)`, `getErrorMsg($dbid)` | chyba poslední operace |
| `getDAO($dbid, $table, $id\|{where, conds}\|{disable_db_pooler => 1})` | DAO objekt |
| `getDAOList($dbid)`, `getDaoMetaData($dbid)` | tabulky / struktura |
| `getDbDriver($dbid)`, `getDbidList()`, `getDbIdPoolList($dbid)`, `getDBIObject($dbid, $pool)` | informace o spojeních |
| `ping($dbid, $pool)`, `testConnection()`, `reconnect($dbid)`, `disconnect($dbid)` | správa spojení (volá engine) |

## `$ENTITIES` — `Libs::Entities`

| Metoda | Popis |
| --- | --- |
| `createEntityObject($nazev)`, `createEntityObject($nazev, $id)`, `createEntityObject($nazev, {where => "...", conds => [...]})` | nová instance entity (vlastní spojení z poolu) |
| `getEntityObject($nazev)` | sdílená instance (jen čtení metadat / validace) |
| `isExistEntity($nazev)`, `getLoadEntitiesList()` | načtené entity |

## Entita / DAO — `Entities::Entity`, `Libs::MyDBI::DAO`

| Metoda | Popis |
| --- | --- |
| `<sloupec>()`, `<sloupec>($v)` | getter / setter s validací (neplatná hodnota → `undef` + chyba) |
| `flush()` | INSERT/UPDATE změněných sloupců (+ razítka `created`/`updated`); vrací PK |
| `commit()`, `rollback()` | transakce spojení objektu; `commit` vyprázdní seznam změn |
| `logit($text)` | standardní log o změně (po `flush`) |
| `DELETE_ROW()` | DELETE podle PK |
| `refreshTABLE($where, \@conds)` | načíst řádek podle podmínky |
| `error()`, `getErrorList()`, `existsUniqueError()`, `getError()` | chyby |
| `getMirroredData()` | hash všech sloupců |
| `getPrimaryValue()`, `setPrimaryValue($v)`, `getPrimaryColumnName()` | PK |
| `getChangeList()`, `getMethodList()`, `getTableName()`, `getRewrite()` | metadata objektu |
| `getValue($col, 'value'\|'type'\|'size'\|'null'\|'def'\|'unsig'\|'unique'\|'enumv')` | atribut sloupce |
| `setUniqueCheckValue(1\|0)`, `getUniqueCheckValue()` | kontrola UNIQUE při flush |
| `setErrorList($text)`, `setErrorList({})` | zapsat / vyčistit chybu (použití v přepsaném setteru) |
| `clearAllMethod()` | reset objektu na výchozí hodnoty |
| `existsPublicMethodName($name)` | má tabulka sloupec? |
| `select($sql, \@bind)`, `insert`, `update`, `delete` | SQL nad spojením objektu (bez klíčového slova) |
| `getLastInsertID()`, `getRunDBMethod()` | po zápisu |
| `DAORef()` | (jen entita) podkladový DAO |

## Vestavěné služby

### `Services::Session`

`newSession()`, `getValue($k, $default)`, `setValue($k, $v)`, `existKey($k)`, `existKeyValue($k)`,
`regenerate()` (smaže řádek session, vygeneruje nové sid přes `$USER->regenerateSid()`, založí
nový řádek se stejnými daty včetně vlastních sloupců a drží ho pro `flush`; vrací nové sid — volat
po přihlášení), `flush()`; ostatní deleguje na `Libs::User`. `newSession` při založení nové
session příležitostně (každá `http.session_cleanup_every`-tá, výchozí 20.) smaže expirované řádky.

### `Services::UserAccount` (vygenerovaný ve webu; tutoriál přidává `login`, `logout`, `isLoggedIn`)

`newRequest()`, `setLanguage($lang)`, `getSession()`, `getAccount()`, `getGroup()`, `flush()`;
ostatní deleguje na `Session` → `Libs::User`.

### `Services::DBTable`

`genTable(%opt)`, `genTableOptions(%opt)`, `genTableData($TO)`, `getTableOptions($id\|$name)`,
`existTableOptions($id\|$name)`, `resetTableOptions($id\|$name)` — [09](09-databaze-a-entity.md#stránkované-tabulky-servicesdbtable).

### `Services::Email`

`addEmailToQueue(%mail)`, `sendAllEmail()`, `updateSendResult($mid, $stav)` — [08](08-sluzby.md#email--fronta-e-mailů).

## `Libs::Send` — přímé odeslání e-mailu

```perl
my $smtp = new Libs::Send($CONF->getValue("smtp_primary"));    # host, port, timeout, hello, ssl, starttls, authid, authpw
$smtp->setFrom($from); $smtp->setTo($to);                       # setTo/setCc/setBcc lze opakovat
$smtp->setSubjectUTF8($subject);
$smtp->setBodyPlainUTF8($text); $smtp->setBodyHtmlUTF8($html);  # více těl = multipart/alternative
$smtp->setAttachment("/cesta/soubor.pdf");
my $error = $smtp->send();                                       # undef = OK, jinak text chyby
```

Další: `setSubject`, `setSubjectUTF8toASCI`, `setReplyTo`, `setReturnPath`, `setErrorTo`, `setBody`
(vlastní MIME hlavičky). `Libs::Send` používá přímo jen engine (`Services::Email`, e-mailové
reporty) — moduly webu třídy enginu ne-`require`-ují, e-maily posílají přes frontu služby `Email`.

## `Libs::Pics` — obrázky (ImageMagick)

`new()`, `getInfo($file)` → `{ type, width, height, geometry, size, major, bad, msg }`,
`convert(f => $in, o => $out, w => $width, h => $height, q => $quality, r => $rotate, …)` — obálka
nad `/usr/bin/identify` a `/usr/bin/convert` (balíček `imagemagick` je v základu `pwe-base`, tedy ve
všech image enginu). Detail v POD `PWE/Libs/Pics.pm`.

## Loadery (`Libs::Pages`, `Libs::Sites`, `Libs::Services`, `Libs::Entities`)

Veřejné metody loaderů (`getLoadPagesList()`, `isExistPage($p)`, `isExistPageFunc($p, $f)`,
`getPageObject($p)`, `getLoadServicesList()`, `isExistService($s)`, `getServiceObject($s)`,
`getLoadSitesList()`, `isExistSite($s)`, `getSiteObject($s)`) používá `pwe.fcgi` a nástroje.
Moduly webu objekty loaderů nedostávají — závislosti mezi moduly se řeší výhradně injektáží
`Service_X` / `Site_X`.

## Klient `pwe.js`

| Funkce | Popis |
| --- | --- |
| `replaceHTML(url, src, dst)` | GET + `ajax_request=1`, odpověď JSON `REPLACE`; `src` = element s indikátorem průběhu |
| `replaceHTMLSimple(url, src, dst)` | GET, odpověď HTML do `dst` |
| `AjaxFormAppender($form)` | formulář odesílaný AJAXem (JSON `REPLACE`, 400 → messenger, upload s procenty); po úspěchu formulář vynuluje, odroluje jen podle messengeru v odpovědi (`disable_scrolltomessenger` respektuje) |
| `getAjaxAppender(src, dst)` | společné nastavení `$.ajax` (statusCode 400/401/404/413/500, `AjaxRedirect`) |
| `scrollToMessenger()` | odroluje na `#messenger` |
| `addprogress(dst, 'start'\|'end')`, `addpercent_progress(dst, pct)` | `ajaxprogress.js` — indikátory průběhu |

## Nástroje (`PWE/tools`)

Přehled skriptů, voleb a `make` cílů: [16 — Nástroje a ladění](16-nastroje.md).
