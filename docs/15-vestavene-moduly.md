# 15 — Vestavěné moduly enginu

Co je v adresáři enginu `PWE/` (v kořeni repozitáře; v kontejneru `/PWE/PWE`) k dispozici každému
webu, jak se to zapíná a co lze přebít. Web si moduly enginu zapíná v `conf/web.conf`
(`pwe.core_pages`, `core_sites`, `core_services`, `core_entities` — „core“ v názvech klíčů znamená
kořen enginu, tedy právě adresář `PWE/`); šablony a statika enginu jsou dostupné vždy. Modul nebo
šablona stejné cesty ve webu má přednost.

## Stránky (`PWE/Pages`)

| Stránka | Zapnout | Účel |
| --- | --- | --- |
| `css` | `core_pages` (výchozí) | `?page=css&func=default` vrací CSS webu — statický `css.static_css`, nebo SCSS přeložené přes `css.scss_bin` |
| `errorPage` | výchozí | chybové odpovědi `e400`, `e401`, `e404`, `e500`, `cgi_error` (413 při velkém uploadu); layouty `http.layout_error_*`, texty `rb.msg.error_*` |
| `systemPage` | výchozí | servírování souborů z `pwe.assets_dir`/`assets_file` (`file`; Content-Type podle přípony, cache) a výpis adresářů z `pwe.assets_browse_dir` (`folder`); volá ji engine, ne web |
| `pweCreator` | výchozí | generátor kostry stránky/služby/vzhledu/entity z prohlížeče (`?page=pweCreator`), jen skupina `admin` **a jen při `pwe.development => 1`** (akce zapisující soubory jinak vrací 401); názvy musí být identifikátory (písmeno, pak písmena/číslice/podtržítko, max. 64 znaků); stejné šablony jako `make module`. V produkčním webu ho z `core_pages` vyhoď |
| `formExamples` | `--examples` / ručně | ukázka formuláře s `defined`, uploadem a AJAX odpovědí |
| `ajaxExamples` | ručně | ukázka AJAX odkazů, náhrady více elementů, redirectu a chyb |
| `responsive` | ručně (+ `core_sites => ["Responsive"]`) | ukázka stránky v jiném vzhledu |

Chceš-li jinou chybovou stránku, vytvoř ve webu `Pages/errorPage/` (kopie z enginu + úpravy)
— web vyhraje. Stránky `*Examples` nepatří do produkce (smaž je z `core_pages`).

## Vzhledy (`PWE/Sites`)

| Vzhled | Účel |
| --- | --- |
| `Default` | tenká fasáda nad `Libs::Web` bez layoutů; použije se jen tehdy, když web nemá vlastní `Sites/Default` (pak se renderuje holým `templates/LayoutHeader.html`/`LayoutBody.html`) |
| `Responsive` | ukázkový vzhled s vlastními layouty (`layout_header.html`, `layout_body.html`) a CSS `assets/css/responsive.css`; `getDefaultTemplateValues`, `printHtmlHeader`, `printHtmlLayout` jako vzor vlastního vzhledu |

Každý reálný web má vlastní `Sites/Default` (generátor ho vytvoří) — [07 — Vzhled](07-vzhled-site.md).

## Služby (`PWE/Services`)

| Služba | Závislosti | Účel |
| --- | --- | --- |
| `Session` | entita `Session`, tabulka `session` | DB session uživatele (`newSession`, `getValue`, `setValue`, `flush`) |
| `UserAccount` | `Session` | **ukázka**: každému dá skupinu `admin`; weby mají vlastní (generátor) |
| `DBTable` | entita `DBTable`, tabulka `dbtable` | stránkované a řaditelné tabulky (`genTable`) + šablony `pagination.html`, `pager.html`, `orderby.html` |
| `Email` | entita `MailQueue`, tabulka `mailqueue`, `pwe.smtp_servers` | fronta e-mailů (`addEmailToQueue`, `sendAllEmail`) |

API: [08 — Služby](08-sluzby.md), [14 — API reference](14-api-reference.md).

## Entity (`PWE/Entities`)

| Entita | Tabulka | Poznámka |
| --- | --- | --- |
| `Entity.pm` | — | základní třída všech entit (`use base qw(Entities::Entity)`): DAO delegace, automatická razítka |
| `Session` | `session` | setter `messenger` zhušťuje HTML |
| `DBTable` | `dbtable` | nastavení tabulek `Services::DBTable` |
| `MailQueue` | `mailqueue` | validace `mailto`/`mailfrom`, stavy `sendstatus` Y/N/E, příloha base64 (tar) |

SQL tabulek: `dbtable` a `session` zapisuje generátor do `conf/<driver>.dbversion`, `mailqueue`
je v POD `PWE/Entities/MailQueue/MailQueue.pm` (MySQL i Postgres).

## Šablony (`PWE/templates`)

| Šablona | Účel |
| --- | --- |
| `HttpHeaderStandart.tmpl`, `HttpHeaderAjax.tmpl`, `HttpHeaderAjaxRedirect.tmpl`, `HttpHeaderRedirect.tmpl`, `HttpHeaderCss.tmpl`, `HttpHeaderJavascript.tmpl`, `HttpHeaderPlain.tmpl`, `HttpHeaderFont.tmpl`, `HttpHeaderSVGXML.tmpl`, `HttpHeaderImage.tmpl`, `HttpHeaderOctetStream.tmpl`, `HttpHeaderCsvDownload.tmpl`, `HttpHeaderStatic.tmpl`, `HttpHeader400/401/404/500.tmpl`, `HttpHeaderError.tmpl` | HTTP hlavičky podle `type` v `printHttpHeader` |
| `LayoutHeader.html`, `LayoutBody.html` | výchozí holé layouty (bez vlastního vzhledu) |
| `LayoutErrorHeader.html`, `LayoutErrorBody.html` | layouty chybových stránek |
| `messenger.html` | flash zpráva (Bootstrap 5 alert) |
| `resource_bundle.tmpl` | načtení rb souborů (`rb_list`) |
| `href.tmpl` | odkaz klasický / AJAX JSON / AJAX HTML |
| `DumpData.tmpl` | výpis všech proměnných šablony (vývoj) |
| `niceprice.tmpl`, `taxprice.tmpl` | formátování ceny / ceny s DPH |

Přebití: stejná cesta ve webu (`webapps/<web>/templates/messenger.html`).

## Statika (`PWE/assets`)

| Cesta | Obsah |
| --- | --- |
| `assets/javascript/pwe.js`, `ajaxprogress.js` | klientská AJAX vrstva a indikátory průběhu |
| `assets/javascript/jquery-4.0.0/` | jQuery 4.0.0 |
| `assets/javascript/bootstrap-5.3.8/`, `assets/css/bootstrap-5.3.8/` | Bootstrap 5.3.8 (`bootstrap.bundle.min.js`, `bootstrap.min.css`) |
| `assets/css/fontawesome-free-6.4.2/`, `assets/fonts/fontawesome-free-6.4.2/` | Font Awesome 6.4.2 (CSS odkazuje na `/assets/fonts/...`) |
| `assets/css/responsive.css`, `assets/images/*.svg` | pro vzhled `Responsive` |
| `assets/images/ajax-loader.gif` | indikátor průběhu |
| `favicon.ico` (kořen enginu, `PWE/favicon.ico`) | výchozí favicon, web může mít vlastní |

Servíruje je nginx (compose) nebo engine (`systemPage`) z `assets/`; web je nekopíruje. Knihovny
třetích stran se neupravují; verze a zdroje jsou v [`PWE/README.md`](../PWE/README.md).

## Knihovny (`PWE/Libs`)

| Modul | Role |
| --- | --- |
| `Config`, `Log`, `Validate` (+ `Validate/Data`, `MySQL`, `Postgres`) | konfigurace, log, validátory |
| `User`, `Web` | stav requestu, render |
| `Pages`, `Sites`, `Services`, `Entities` | loadery a injektáž |
| `MyDBI` (+ `MyDBI/DAO`, `MyDBI/DRIVER/MySQL`, `MyDBI/DRIVER/Postgre`) | databáze |
| `Send` | SMTP e-mail (používá `Services::Email` a reporty) |
| `Pics` | ImageMagick (`identify`, `convert`) |

CPAN moduly dostupné webům ve všech image PWE (`JSON`, `HTTP::Tiny` + `IO::Socket::SSL`, `Crypt::OpenSSL::RSA`, `Image::Magick`, `Digest::SHA`, `URI`, …; DB ovladače jen v image profilu; `LWP::UserAgent`, `Data::UUID` ani `curl` v nich nejsou — web si je přidá ve svém `Dockerfile`): [17 — Nasazení](17-nasazeni.md#moduly-dostupné-kódu-webu).

Do `PWE/Libs` web nesahá ani je ne-`require`-uje; vše dostane konstruktorem a injektáží.

## Verze a kompatibilita

`PWE/VERSION` (semver) a `PWE/CHANGELOG.md`. Web říká `pwe.require_core => ">=2.2"`; nesplnění
= engine nenastartuje s jasnou chybou. Změna kontraktu stránky/vzhledu nebo sdílených šablon
zvyšuje major verzi.
