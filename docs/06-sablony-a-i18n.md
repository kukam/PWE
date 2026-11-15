# 06 — Šablony a texty (i18n)

Výstup se renderuje přes **Template Toolkit** (`[% … %]`). Šablony se adresují relativně
ke kořenům — engine je hledá nejdřív ve webu (`pwe.home`), pak v enginu (`pwe.core`, adresář `PWE/`):
`Pages/ukoly/main.html`, `Sites/Default/layout_body.html`, `templates/messenger.html`.
Implementace: `Libs::Web::genTmpl` / `genTemplateObject`.

## Typy šablon

| Přípona | Zacházení |
| --- | --- |
| `.html`, `.css`, `.js` | šablona ze souboru s ořezem bílých znaků (`PRE_CHOMP`, `POST_CHOMP`, `TRIM`) |
| `.tmpl` | „surová“ šablona bez ořezu — HTTP hlavičky, resource bundle |
| jiný řetězec | inline šablona: `$WEB->genTmpl("Ahoj [% name %]", name => "světe")` |

Volby Template Toolkitu řídí sekce `tmpl` v `web.conf` ([03](03-struktura-webu.md#sekce-tmpl--template-toolkit));
kompilované šablony se ukládají do `tmpl.croot` (`ramdisk/templates/`). `[% PERL %]` bloky jsou
povoleny (`tmpl.evalperl`).

## Layout pipeline

Stránka volá tři metody a každá odpovídá jedné šabloně:

```
printHttpHeader()   →  templates/HttpHeader<Typ>.tmpl        HTTP hlavičky (+ Set-Cookie)
printHtmlHeader()   →  Sites/Default/layout_header.html      <!DOCTYPE html><html><head>…</head>
printHtmlLayout()   →  Sites/Default/layout_body.html        <body>…[% INCLUDE $html_main %]…</body></html>
```

Které layouty se použijí, určuje vzhled (`Sites/Default/Default.pm`, atributy `layout_header`,
`layout_body`); stránka je může přebít parametrem (`printHtmlLayout(layout_body => "…")`).
Bez vlastního vzhledu platí výchozí `templates/LayoutHeader.html` a `templates/LayoutBody.html`
enginu (holé, bez CSS).

Tělo stránky (`html_main`) je obyčejný fragment HTML; layout ho vloží na své místo. Všechny
klíče předané `printHtmlLayout(%tmpl)` jsou v šabloně proměnné (`table`, `stats`, …).

## Automatické proměnné

`genTmpl` doplní do **každé** šablony (včetně fragmentů renderovaných přes `genTmpl` a AJAX):

| Proměnná | Obsah |
| --- | --- |
| `script_name` | `pwe.fcgi` — používej v `action` a odkazech: `[% script_name %]?page=x&func=y` |
| `idp` | id stránky ze `setIDP()` (aktivní menu, `rb.$idp.*`) |
| `script_page`, `script_func` | aktuální `page` a `func` |
| `parameters` | hash první hodnoty každého vstupního parametru (`parameters.email`) |
| `cookie_id`, `cookie_name`, `http_host_path` | session id a nastavení cookie |
| `group` | hash skupin uživatele (`[% IF group.admin %]`) |
| `use_language`, `languages`, `def_language` | jazyk uživatele, seznam jazyků, výchozí jazyk |
| `http_https`, `http_host`, `http_host_full`, `server_name`, `request_uri`, `http_referer`, `full_url` | URL kontext (`http_host` bez portu) |
| `name_page`, `conf_title`, `conf_keywords`, `conf_description` | z `http.name/title/keywords/description` |
| `conf_development` | `pwe.development` (podmíněný debug výstup) |
| `hostname`, `start_time`, `random_number` | jméno serveru, čas startu Apache (cache-busting), náhodné číslo |
| `rb_list` | seznam rb souborů pro `templates/resource_bundle.tmpl` |
| `messenger` | HTML flash zprávy (doplní `printHtmlLayout`) |

Proměnná `title` **není** automatická — nastavuje ji stránka přes `printHtmlHeader(title => …)` a layout ji
musí escapovat (`<title>[% title | html %]</title>`), protože často nese název z databáze.

Vzhled k nim přidává své (`web_site`, `web_index`, `layout_body`, `account`, `css`), stránka
cokoli dalšího. Celý obsah proměnných šablony zobrazí ve vývojovém režimu modal **DataDump**
(`templates/DumpData.tmpl`, odkaz v menu vygenerovaného vzhledu).

## Resource bundle — texty ve více jazycích

Každý modul (stránka, vzhled, služba, entita) může mít v adresáři:

```
rb.tmpl           výchozí jazyk = první v http.languages
rb_EN.tmpl        každý další jazyk z http.languages (název jazyka velkými písmeny)
```

Obsah jsou přiřazení do hashe `rb`:

```
[% # RESOURCE BUNDLE (CZE) %]

[% SET rb.ukoly_title = "Seznam úkolů" %]
[% SET rb.form_submit = "Přidat" %]
[% SET rb.msg.error_exist__title = "Vyplňte název úkolu." %]
[% SET rb.msg.ok_added = "Úkol byl přidán." %]

[% # POZOR: soubor rb*.tmpl musi koncit prazdnym radkem (bug parseru) %]

```

**Soubor musí končit prázdným řádkem** — poslední `[% SET %]` nesmí být na posledním řádku,
jinak se soubor nenačte. Generátory to hlídají komentářem na konci.

### Jak se texty dostanou do šablony

1. Při načtení stránky `Libs::Pages::registerResourceBundle` sestaví seznam rb souborů, které
   ke stránce patří: všechny **entity**, **injektované služby** (`Service_X`), **injektovaný
   vzhled** (`Site_X`) a adresář **stránky** — v tomto pořadí, takže stránka může přebít text
   vzhledu.
2. Při renderu `genTmpl` naplní `rb_list`: nejdřív soubory výchozího jazyka (fallback), pak
   jazyka uživatele.
3. Šablona musí na začátku zavolat
   ```
   [% PROCESS templates/resource_bundle.tmpl %]
   ```
   (smyčka `[% FOREACH rb_file IN rb_list %][% PROCESS $rb_file %][% END %]`). `PROCESS` sdílí
   proměnné, takže `rb` je pak dostupné v šabloně i ve všem, co z ní `INCLUDE`-uje. Fragment,
   který se renderuje **samostatně** (AJAX přes `ajax_tmpl`, `genTmpl`), musí mít řádek také.

Použití: `[% rb.ukoly_title %]`, `[% rb.msg.ok_added %]`. Klíč, který v žádném jazyce není,
se vyrenderuje jako prázdný řetězec (u messengeru jako `[msg.klíč]`).

### Texty sdílené více stránkami

Resource bundly **injektovaných služeb** se načítají do každé stránky, která službu injektuje — texty
společné pro několik stránek (stavy objednávky, klíče chyb služby) patří do `Services/<X>/rb*.tmpl`,
texty pro celý web do `Sites/Default/rb*.tmpl`.

### Šablona v jiném jazyce než má uživatel (e-maily)

`rb_list` sleduje jazyk aktuálního uživatele. E-mail zákazníkovi generovaný z administrace nebo cronu musí mít
jazyk objednávky, proto si šablona e-mailu texty načte sama a přepne `use_language`:

```
[% PROCESS Pages/objednavka/rb.tmpl %]
[% IF order.lang == 'EN' %][% PROCESS Pages/objednavka/rb_EN.tmpl %][% END %]
[% SET use_language = order.lang %]
[% WRAPPER Pages/objednavka/email_layout.html %] … tělo … [% END %]
```

(`WRAPPER` obalí tělo společnou HTML kostrou e-mailu; `INCLUDE_PATH` hledá šablony ve webu i v enginu.)

### Přepnutí jazyka

Vygenerovaná úvodní stránka má akci `setlanguage` s pravidlem `is_language`; menu vzhledu
nabízí odkazy `?page=default&func=setlanguage&lang=EN`. Jazyk se ukládá do opts / DB session a
platí pro další requesty. HTML atribut `lang` nastavuje layout podle `use_language`.

## Messenger (flash zprávy)

Flash zpráva se nastaví v akci, uloží se do opts (bez DB) nebo do DB session (přes vzhled
webu) a zobrazí se při nejbližším vykreslení — přežije tedy i redirect.

```perl
$WEB->setMessenger("Pages/ukoly/msg.html", msg_allright => ['ok_added']);            # zelený box
$WEB->setMessenger("Pages/ukoly/msg.html", msg_error => $error);                      # červený box, $error = pole klíčů
$WEB->setMessenger("Pages/ukoly/msg.html", msg_allright => ['ok_done'], disable_scrolltomessenger => 1);   # bez odrolování (AJAX)
$WEB->setMessenger("Pages/ukoly/msg.html", msg_allright => ['ok_saved'], title => $title);   # další proměnné pro šablonu
```

`Pages/X/msg.html`:

```
[% PROCESS templates/resource_bundle.tmpl %]
[% SET rb.msg.ok_saved = "Uloženo: $title" %]        [% # volitelně: text s proměnnými z setMessenger %]
[% INCLUDE templates/messenger.html %]
```

`templates/messenger.html` (engine, Bootstrap 5 `alert`) pro každý klíč `v` zobrazí
`msg.$v` → `rb.msg.$v` → `[msg.$v]`. Titulek boxu je `rb.messanger_allright_title` /
`rb.messanger_error_title` (vzhled je má v `Sites/Default/rb*.tmpl`; název s překlepem je
historický a záměrně ponechaný). Box má id `messenger-body`; layout ho vkládá do
`<div id="messenger">[% messenger %]</div>`, kam ho umisťuje i klient `pwe.js`.

## Odkazy a tlačítka: `templates/href.tmpl`

Generuje atribut odkazu podle toho, zda má jít o klasický přechod, nebo AJAX:

```
<a class="btn btn-sm btn-outline-success" [% INCLUDE templates/href.tmpl href="$script_name?page=ukoly&func=toggle&id=$t.id&done=t" ajaxjson=1 %]>…</a>
```

| Parametr | Výsledek |
| --- | --- |
| (nic) | `href="…"` — klasický odkaz |
| `ajaxjson=1` | `onclick="replaceHTML('…', $(this)); return false;"` — server vrací JSON `REPLACE` |
| `ajaxhtml=1 dst="$('#cil')"` | `onclick="replaceHTMLSimple('…', $(this), $('#cil')); return false;"` — server vrací HTML fragment |

Šablony enginu pro stránkování a řazení (`Services/DBTable/pagination.html`, `orderby.html`,
`pager.html`) tento mechanismus používají s parametrem `ajaxjson` / `enable_ajax`.

## Skládání šablon

```
[% INCLUDE Pages/ukoly/form.html formid = "task-form" %]       vloží fragment s lokálními proměnnými
[% INCLUDE $html_main %]                                        cesta v proměnné
[% PROCESS templates/resource_bundle.tmpl %]                    PROCESS sdílí proměnné s volajícím
[% INCLUDE Services/DBTable/orderby.html thname = rb.th_title ordercolumn = "title" ajaxjson = 1 %]
```

Užitečné filtry a konstrukce Template Toolkitu: `[% x | html %]` (escapování), `[% x | uri %]`,
`[% IF a == 'b' %]…[% ELSIF %]…[% ELSE %]…[% END %]`, `[% FOREACH t IN table.rows %]…[% END %]`
(uvnitř `loop.first`, `loop.last`, `loop.count`), `[% SET y = (cond ? 'a' : 'b') %]`,
`[% list.size %]`, `[% hash.keys.sort %]`.

## Záludnosti Template Toolkitu

Věci, které v TT fungují jinak, než by člověk čekal (všechny se projevily při psaní e-shopu):

| Zápis | Co se stane | Správně |
| --- | --- | --- |
| `[% # komentář` přes více řádků `%]` | `#` s mezerou za `[%` komentuje **jen zbytek řádku**; další řádky uvnitř direktivy se parsují jako kód a první `%]` v textu komentáře direktivu ukončí | víceřádkový komentář začíná `[%#` bez mezery (ignoruje se celá direktiva) a nesmí obsahovat `%]` — ukázky volání piš bez závorek: `INCLUDE Pages/x/y.html p = p` |
| `[% SET f = price \| format('%.2f') %]` | filtr se aplikuje na (prázdný) výstup direktivy, `f` zůstane neformátované | plugin: `[% USE fmt = format('%.2f') %][% SET f = fmt(price) %]`, nebo zachycení bloku `[% f = BLOCK %][% price \| format('%.2f') %][% END %]` |
| `"…$1…"` v dvojitých uvozovkách | TT interpoluje `$1` jako proměnnou → chyba parseru | řetězce s `$` piš v jednoduchých uvozovkách: `'$1 '` |
| `[% x \| replace('(\d)(?=(\d{3})+\.)', '$1 ') %]` | **filtr** `replace` zpětné odkazy nezná | **vmetoda** `x.replace('(\d)(?=(\d{3})+\.)', '$1 ')` zpětné odkazy `$1` podporuje (oddělovač tisíců: `1 299.50`) |
| `[% a %] [% b %]` (jen mezera mezi dvěma direktivami) | `.html` šablony se renderují s `PRE_CHOMP`/`POST_CHOMP`, mezera se odstraní → `751 22Osek` | mezi direktivy dej `&nbsp;`, text, nebo spoj hodnoty: `[% "${zip} ${city}" \| html %]`; mezera před tagem (`[% x %] <span>`) také zmizí — použij třídu `ms-1`/`me-1` |
| `[% date.format(...) %]` bez `USE` | neznámá proměnná, nic se nevypíše | `[% USE date %]` na začátku šablony (copyright rok: `[% date.format(date.now, '%Y') %]`) |
| `[% IF rb.klic %]` na neexistující klíč | v pořádku — prázdný řetězec; ale v `messenger.html` se chybějící klíč zobrazí jako `[msg.klíč]` | u textů s diakritikou drž klíče v obou `rb*.tmpl` |
| `[% PERL %] … $stash … [% END %]` | `$stash` je živý objekt TT; jeho změna (`delete`, přiřazení) ovlivní lokalizaci proměnných | ve `PERL` blocích `$stash` jen čti (`$stash->get('x')`), nikdy neměň; engine po renderu stash pro jistotu obnovuje |
| `[% IF cena == 0 %]`, `[% IF a != b %]` | `==`/`!=` porovnávají **řetězce** (`eq`); hodnota `DECIMAL` z DB je text `"0.00"`, takže se nerovná `0` | pro čísla používej `<`, `>`, `<=`, `>=` nebo porovnej s `"0.00"`; přepočty dělej v Perlu |
| `rb.klic` podle proměnné | tečková notace klíč nevyhodnotí | dynamický klíč: `[% SET k = "status_" _ order.status %][% rb.$k %]` (stejně `msg.$v` v messengeru) |
| text z `rb` potřebný v Perlu (titulek, předmět e-mailu) | `rb` existuje jen v šabloně | `$WEB->genTmpl('[% PROCESS templates/resource_bundle.tmpl %][% rb.title_katalog %]')` — inline šablona dostane `rb_list` aktivní stránky |

Formát ceny podle jazyka (vzor `Pages/katalog/price.html` e-shopu Syrmex): `[% USE f = format('%.2f') %][% SET s = f(price).replace('(\d)(?=(\d{3})+\.)', '$1 ') %][% IF use_language == 'EN' %][% s %] CZK[% ELSE %][% s.replace('\.', ',') %] Kč[% END %]` → `1 299,50 Kč` / `1 299.50 CZK`.

## Generování HTML mimo stránku

```perl
my $html = $WEB->genTmpl("Pages/ukoly/table.html", table => $table);   # fragment do proměnné (AJAX, e-mail, PDF…)
my $text = $WEB->genTmpl("Dobrý den [% name %],", name => $name);       # inline šablona
```

`genTmpl` aplikuje stejné automatické proměnné i resource bundle jako layout. Chyba šablony se
zaloguje (`[E]`) a vrátí se, co se stihlo vyrenderovat.

## Pomocné šablony enginu

| Šablona | Účel |
| --- | --- |
| `templates/resource_bundle.tmpl` | načtení textů (viz výše) |
| `templates/messenger.html` | flash zpráva |
| `templates/href.tmpl` | odkaz klasický / AJAX |
| `templates/DumpData.tmpl` | výpis všech proměnných šablony (vývoj) |
| `templates/niceprice.tmpl` | formátování ceny: `[% INCLUDE templates/niceprice.tmpl price=1234.5 round=2 currency="Kč" %]` |
| `templates/taxprice.tmpl` | cena s DPH |
| `templates/LayoutErrorHeader.html`, `LayoutErrorBody.html` | layouty chybových stránek (`http.layout_error_*`) |
| `templates/HttpHeader*.tmpl` | HTTP hlavičky podle `type` v `printHttpHeader` ([10 — AJAX](10-ajax.md#typy-http-hlaviček)) |

Kteroukoli z nich web přebije vlastním souborem stejné cesty (`webapps/<web>/templates/messenger.html`).
