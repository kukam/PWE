# 10 — AJAX

PWE má lehkou AJAX vrstvu bez frameworku: server vrátí buď **HTML fragment**, nebo **JSON
s instrukcemi „nahraď obsah elementu #ID tímto HTML“**, klient (`PWE/assets/javascript/pwe.js`,
závisí na jQuery 4 a `ajaxprogress.js`) odpověď aplikuje, zobrazí messenger a zvládne
přesměrování i chyby.

## Princip

1. Klient přidá k requestu parametr `ajax_request=1` (dělají to funkce `pwe.js` samy).
2. Stránka podle `$USER->getParam("ajax_request", 0, undef)` odpoví AJAX hlavičkou a obsahem
   místo celé stránky.
3. Klient podle `Content-Type` a hlaviček odpověď zpracuje.

## Serverová strana

### JSON `REPLACE` (doporučený způsob)

```perl
$WEB->printHttpHeader('type' => 'ajax');                 # Content-Type: text/xml (historicky; tělo je JSON)
$WEB->printAjaxLayout(
    ajax_id   => ['tasks-list', 'stats'],                # cílové elementy (#tasks-list, #stats)
    ajax_tmpl => ['Pages/ukoly/table.html', 'Pages/ukoly/stats.html'],   # šablona pro každý z nich…
    ajax_data => [{table => $table}, {stats => $stats}], # …a její data (jeden hash = pro všechny)
);
# nebo hotové HTML:
$WEB->printAjaxLayout(ajax_id => ['box'], ajax_html => ['<b>hotovo</b>']);
# nebo jen messenger (bez změny obsahu):
$WEB->printAjaxLayout();
```

Výstup je `{"REPLACE":[{"ID":"tasks-list","HTML":"…"},{"ID":"messenger","HTML":"…"}]}`. Volání přijme buď `ajax_tmpl`
(+ `ajax_data`), nebo `ajax_html`, ne obojí; výchozí proměnné vzhledu (`csrf`, `account`, …) se doplňují jen
do `ajax_tmpl` fragmentů.
Messenger nastavený přes `setMessenger` vzhled přidá automaticky pod ID `messenger`; když
v odpovědi není, klient `#messenger` vyprázdní. Vzhled do `ajax_data` doplní své výchozí
proměnné (`getDefaultTemplateValues`), takže fragment má k dispozici `account`, `group`, `rb`
atd. stejně jako celá stránka.

### HTML fragment

```perl
sub detail {
    my $self = shift;
    $WEB->printHttpHeader();                              # běžná HTML hlavička
    print $WEB->genTmpl("Pages/ukoly/detail.html", task => $TASKS->getTask($USER->getParam('id', 0, 0)));
}
```

Klient (`replaceHTMLSimple`) vloží odpověď do zadaného elementu.

### Přesměrování z AJAXu

```perl
$WEB->setMessenger("Pages/ukoly/msg.html", msg_allright => ['ok_saved']);
$WEB->printHttpHeader('type' => 'ajax_redirect', 'redirect_link' => $WEB->getScriptName() . '?page=ukoly&func=default');
```

Server pošle hlavičku `AjaxRedirect`, klient provede `window.location`; messenger se zobrazí
na cílové stránce.

### Chyby

Chybová metoda vrátí status kód; engine vykreslí chybovou stránku a klient z ní vyjme
`#messenger-body` do `#messenger`:

```perl
sub error {
    my ($self, $error) = @_;
    $WEB->setMessenger("Pages/ukoly/msg.html", msg_error => $error);
    return 400 if ($USER->getParam("ajax_request", 0, undef));   # 400 / 401 / 404 / 500
    $self->default();
}
```

Totéž se stane při 401 (práva), 404, 413 (velký upload) a 500 (pád).

### Jedna akce pro AJAX i klasický request

```perl
sub add {
    my $self = shift;
    my $id = $TASKS->addTask(title => $USER->getParam("title", 0, ""));
    $WEB->setMessenger("Pages/ukoly/msg.html", $id ? (msg_allright => ['ok_added']) : (msg_error => ['error_db']));
    $self->default();                      # default() sám rozliší ajax_request a vrátí buď JSON s tabulkou, nebo celou stránku
}
```

Tento vzor (změna → `default()`) drží jednu cestu renderu pro formulář, odkazy v tabulce
i klasický reload.

## Klientská strana (`pwe.js`)

Načtení (v `layout_header.html`): jQuery → Bootstrap bundle → `ajaxprogress.js` → `pwe.js`.

### Odkazy

Generuje je `templates/href.tmpl` ([06 — Šablony](06-sablony-a-i18n.md#odkazy-a-tlačítka-templateshreftmpl)):

```
<a [% INCLUDE templates/href.tmpl href="$script_name?page=ukoly&func=toggle&id=$t.id&done=t" ajaxjson=1 %]>…</a>
<a [% INCLUDE templates/href.tmpl href="$script_name?page=ukoly&func=detail&id=$t.id" ajaxhtml=1 dst="$('#detail')" %]>…</a>
```

| Funkce | Backend | Co udělá |
| --- | --- | --- |
| `replaceHTML(url, src)` | JSON `REPLACE` | nahradí obsah elementů podle ID, obslouží messenger |
| `replaceHTMLSimple(url, src, dst)` | HTML fragment | vloží odpověď do `dst` |

`src` je jQuery element, na kterém se zobrazí indikátor průběhu (typicky `$(this)`; musí mít
`id`, jinak se indikátor nezobrazí).

### Formuláře

```html
<script>$(function() { AjaxFormAppender($("#task-form")); });</script>
<form id="task-form" action="[% script_name %]?page=ukoly&func=add" method="POST">
  <input type="hidden" name="page" value="ukoly" />
  <input type="hidden" name="func" value="add" />
  …
  <input type="submit" class="btn btn-primary" name="save" value="[% rb.form_submit %]" />
</form>
```

`AjaxFormAppender` zachytí `submit`, přidá `ajax_request=1` a jméno/hodnotu stisknutého
tlačítka, zvolí kódování podle `enctype` (`multipart/form-data` pro upload — vždy POST,
`text/plain`, jinak `application/x-www-form-urlencoded`), ukazuje procenta uploadu a po úspěchu
formulář vynuluje. Odpověď zpracuje jako `replaceHTML`, včetně rolování: na `#messenger` odroluje
jen tehdy, když odpověď obsahuje položku `messenger` bez `disable_scrolltomessenger` — formulář
„Do košíku“ u karty dole na stránce tak s `setMessenger(..., disable_scrolltomessenger => 1)`
uživatele neodhodí na začátek stránky (do 2.2.0 klient po úspěchu roloval vždy). Chyby
validace (400) se zobrazí v `#messenger`. Formulář musí mít `id` a odesílací tlačítko musí být
`<input type="submit" name=… value=…>` — jméno a hodnotu stisknutého tlačítka bere klient z
`input[type=submit]:focus`, `<button type="submit">` nepozná (do dat přidá `undefined=undefined`).
Na stránce s mnoha formuláři (karty produktů) musí mít každý unikátní `id` a vlastní volání
`AjaxFormAppender`.

### Co klient dělá s odpovědí

| Odpověď | Chování |
| --- | --- |
| `Content-Type: text/html` | vloží tělo do cílového elementu |
| JSON `{"REPLACE":[…]}` | pro každou položku `$("#ID").html(HTML)`; bez položky `messenger` vyprázdní `#messenger`, s ní odroluje na messenger (pokud šablona neobsahuje `#disablescrolltomessenger` — `setMessenger(..., disable_scrolltomessenger => 1)`) |
| hlavička `AjaxRedirect` | `window.location.href = …` |
| status 400/401/404/413/500 | z HTML chybové stránky vyjme `#messenger-body` do `#messenger`, odroluje |
| status 0 | „Broken Pipe error“ v `#messenger` |

Stránka proto má mít prázdný `<div id="messenger"></div>` (layout vygenerovaného vzhledu ho má).
Ve vývojovém režimu klient navíc zapisuje odpověď do `#DATA_DUMPER` (modal DataDump).

## Typy HTTP hlaviček

`printHttpHeader(type => …)` vybere šablonu `templates/HttpHeader<Typ>.tmpl`; všechny kromě
`static` posílají session cookie a GMT datum.

| `type` | Šablona | Obsah |
| --- | --- | --- |
| (bez typu) | `HttpHeaderStandart.tmpl` | `text/html; charset=UTF-8`, no-cache |
| `ajax` | `HttpHeaderAjax.tmpl` | `text/xml; charset=UTF-8` — tělo je JSON, `pwe.js` podle této hlavičky pozná `REPLACE` |
| `ajax_redirect` + `redirect_link` | `HttpHeaderAjaxRedirect.tmpl` | hlavička `AjaxRedirect: <url>` |
| `redirect` + `redirect_link` | `HttpHeaderRedirect.tmpl` | `Status: 301`, `Location` |
| `css`, `js`, `plain` | `HttpHeaderCss/Javascript/Plain.tmpl` | `text/css`, `application/javascript`, `text/plain` |
| `svg_xml`, `font` + `font` | `HttpHeaderSVGXML/Font.tmpl` | obrázek SVG, font |
| `image` + `image => 'png'` | `HttpHeaderImage.tmpl` | `image/<typ>`, cache 7 dní |
| `file` + `filename` | `HttpHeaderOctetStream.tmpl` | `application/octet-stream`, `Content-disposition: attachment` |
| `csvdown` [+ `csv_filename`] | `HttpHeaderCsvDownload.tmpl` | `application/csv`, příloha `download.csv` |
| `static` + `content_type` | `HttpHeaderStatic.tmpl` | libovolný Content-Type, cache 7 dní, bez cookie (statika) |
| `400`, `401`, `404`, `500` | `HttpHeader4xx/500.tmpl` | `Status: <kód>`, HTML |
| `error` + `status` | `HttpHeaderError.tmpl` | libovolný `Status` |

Volba `log_output => 1` zapíše hlavičku do logu. Mapování typů na šablony je pevně
v `Libs::Web::printHttpHeader` (web může přebít obsah šablony, ne přidat nový typ); pro
netypické případy vytiskni hlavičky ručně (`print "Content-Type: …\n\n"`) nebo použij
`type => 'static'` s vlastním `content_type`.

## Ukázky v enginu

Stránky `ajaxExamples` (odkazy, náhrada více elementů, redirect, chyby) a `formExamples`
(AJAX formulář s uploadem) si web zapne přes `core_pages => [..., "ajaxExamples", "formExamples"]`
(`make new WEB=<web> ARGS=--examples`) a prohlédne na `?page=ajaxExamples&func=default`.
