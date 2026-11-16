# 07 — Vzhled (Sites)

Vzhled (Site) je modul `Sites/<X>/<X>.pm`, který se do stránek injektuje metodou `Site_<X>`
a stránka přes něj renderuje (`$WEB->printHtmlHeader`, `printHtmlLayout`, …). Je to fasáda
nad render vrstvou enginu `Libs::Web`: drží cesty k layoutům, doplňuje výchozí proměnné
do každé šablony a rozhoduje, kam se ukládá messenger. **Každý web má vlastní `Sites/Default`**
— engine má v `PWE/Sites/Default` jen průchozí fasádu bez layoutů.

## Soubory vzhledu

```text
Sites/Default/
├── Default.pm            modul (kontrakt níže)
├── layout_header.html    <!DOCTYPE html><html><head>: meta, title, CSS, JS
├── layout_body.html      <body>: navigace, messenger, [% INCLUDE $html_main %], patička
├── layout_footer.html    patička (+ DataDump modal ve vývoji); includuje ho layout_body
├── rb.tmpl  rb_EN.tmpl   texty menu a titulky messengeru
```

Vlastní CSS a obrázky webu jsou ve `static/` (`static/css/site.css`, `static/images/`).

## Modul vzhledu

Konstruktor vzhledu má signaturu `($class, $conf, $log, $validate, $dbi, $entities, $user, $web)`
— na rozdíl od stránky **nedostává** předpřipravený `$self` a `$web` je `Libs::Web`. Takto
vypadá vzhled tutoriálového webu (web s databází; generátor `make new` vytvoří totéž):

```perl
package Sites::Default::Default;

use strict;

our ($AUTOLOAD);

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB, $SESSION, $ACCOUNT);

sub new {
    my ($class, $conf, $log, $validate, $dbi, $entities, $user, $web) = @_;

    $DBI = $dbi; $LOG = $log; $WEB = $web; $CONF = $conf;
    $USER = $user; $VALIDATE = $validate; $ENTITIES = $entities;

    my $self = {
        'web_site'      => "default",
        'web_index'     => "/default",
        'layout_header' => "Sites/Default/layout_header.html",
        'layout_body'   => "Sites/Default/layout_body.html",
    };

    bless $self, $class;
    return $self;
}

# Vzhled smí dostat služby stejně jako stránka
sub Service_Session     { my ($self, $input) = @_; $SESSION = $input; }   # messenger do DB session
sub Service_UserAccount { my ($self, $input) = @_; $ACCOUNT = $input; }   # přihlášený účet pro menu

# Výchozí proměnné pro KAŽDOU šablonu (layout i AJAX fragmenty): sem patří vše, co potřebuje menu/patička
sub getDefaultTemplateValues {
    my $self = shift;
    return (
        'web_site'    => $self->{'web_site'},
        'web_index'   => $self->{'web_index'},
        'layout_body' => $self->{'layout_body'},
        'account'     => $ACCOUNT->getAccount(),      # { login => 'admin' } nebo {}
    );
}

sub printHtmlHeader {
    my ($self, %tmpl) = @_;
    $tmpl{'layout_header'} = $self->{'layout_header'} unless (exists($tmpl{'layout_header'}));
    $tmpl{'css'} = $CONF->getValue("css", "src_css", "static");
    $WEB->printHtmlHeader(%tmpl);
}

sub printHtmlLayout {
    my ($self, %tmpl) = @_;
    my %def = $self->getDefaultTemplateValues();
    foreach my $key (keys %def) {
        $tmpl{$key} = $def{$key} unless (exists($tmpl{$key}));
    }
    $tmpl{'messenger'} = $self->getMessenger() if ($self->existMessenger());
    $WEB->printHtmlLayout(%tmpl);
}

sub printAjaxLayout {
    my ($self, %tmpl) = @_;
    if ((ref($tmpl{'ajax_tmpl'}) eq "ARRAY") and (ref($tmpl{'ajax_id'}) eq "ARRAY")) {
        my %defvalue = $self->getDefaultTemplateValues();
        if (ref($tmpl{'ajax_data'}) ne "ARRAY") {
            if (ref($tmpl{'ajax_data'}) eq "HASH") {
                $tmpl{'ajax_data'} = [$tmpl{'ajax_data'}];
            } else {
                $LOG->error("Invalid set AjaxLayout data !");
                $tmpl{'ajax_data'} = [{}];
            }
        }
        foreach my $hash (@{$tmpl{'ajax_data'}}) {
            foreach my $key (keys %defvalue) {
                $hash->{$key} = $defvalue{$key} unless (exists($hash->{$key}));
            }
        }
    }
    $self->setAjax('messenger', $self->getMessenger()) if ($self->existMessenger());
    $WEB->printAjaxLayout(%tmpl);
}

# Messenger v DB session (web s databází). Web bez DB tyto tři metody nemá a používá Libs::Web (opts soubor).
sub setMessenger   { my ($self, $msg, %tmpl) = @_; $SESSION->setValue('messenger', $WEB->genTmpl($msg, %tmpl)); }
sub getMessenger   { my $self = shift; my $msg = $SESSION->getValue('messenger'); $SESSION->setValue('messenger', undef); return $msg; }
sub existMessenger { my $self = shift; return $SESSION->existKeyValue('messenger'); }

# Zbytek API deleguje na Libs::Web
sub genTmpl               { my $self = shift; return $WEB->genTmpl(@_); }
sub printHttpHeader       { my $self = shift; return $WEB->printHttpHeader(@_); }
sub setIDP                { my $self = shift; return $WEB->setIDP(@_); }
sub getIDP                { my $self = shift; return $WEB->getIDP(@_); }
sub setAjax               { my $self = shift; return $WEB->setAjax(@_); }
sub renderReplaceJSON     { my $self = shift; return $WEB->renderReplaceJSON(@_); }
sub getScriptName         { my $self = shift; return $WEB->getScriptName(@_); }
sub getValue              { my $self = shift; return $WEB->getValue(@_); }
sub convertToRewrite      { my $self = shift; return $WEB->convertToRewrite(@_); }
sub getResourceBundleList { my $self = shift; return $WEB->getResourceBundleList(@_); }

sub AUTOLOAD {
    my $self = shift;
    my $name = $AUTOLOAD;
    $name =~ s/.*://;
    return if ($name =~ /^DESTROY$/);
    return $WEB->$name(@_);
}

sub KOMODO { return; ... }    # mrtvý kód pro IDE, viz kapitola 04

1;
```

Co z toho plyne:

- **`getDefaultTemplateValues`** je místo pro data, která potřebuje každá stránka (přihlášený
  uživatel, položky menu z DB, počet položek v košíku). Doplňují se do layoutu i do AJAX
  fragmentů, stránka je může přebít vlastním klíčem.
- Vzhled smí mít injektované **služby** (`Service_X`) i jiné **vzhledy** (`Site_X`) a hooky
  `autostart`, `newRequest`, `flush` (volá je `Libs::Sites`).
- Messenger: web **s DB** ho ukládá do DB session (tyto tři metody), web **bez DB** metody
  vynechá a `AUTOLOAD` je deleguje na `Libs::Web` (opts soubor).
- Proxy metody jsou vypsané explicitně kvůli čitelnosti a IDE; `AUTOLOAD` zajistí, že vzhled má
  celé API `Libs::Web` ([14 — API reference](14-api-reference.md)).
- Vzhled může přijímat **vlastní volby** z `printHtmlLayout(%tmpl)` — jsou to obyčejné proměnné šablony. E-shop
  E-shop tak může mít `full_width => 1` (homepage bez `.container`): v `layout_body.html` stačí
  `[% IF full_width %]…[% ELSE %]<div class="container">…[% END %]`.
- `printAjaxLayout` přijme buď `ajax_tmpl`, nebo `ajax_html` (ne obojí); výchozí proměnné vzhledu se do
  fragmentů doplňují jen ve větvi `ajax_tmpl` — pro odznak košíku je proto lepší mini-šablona než `ajax_html`.

## Layouty

`layout_header.html` — CSS a JS se berou z enginu (`assets/…`), vlastní styl ze `static/`:

```html
<!DOCTYPE html>
<html lang="[% IF use_language == 'EN' %]en[% ELSE %]cs[% END %]" data-bs-theme="light">
  <head>
    [% PROCESS templates/resource_bundle.tmpl %]
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="description" content="[% conf_description %]">
    <meta name="keywords" content="[% conf_keywords %]">
    <title>[% IF title %][% title | html %] | [% ELSE %][% END %][% conf_title | html %]</title>
    <link rel="stylesheet" href="assets/css/bootstrap-5.3.8/bootstrap.min.css" />
    <link rel="stylesheet" href="assets/css/fontawesome-free-6.4.2/all.min.css" />
    [% IF css == "static" %]
    <link rel="stylesheet" href="static/css/site.css?v=[% start_time %]" />
    [% ELSE %]
    <link rel="stylesheet" href="[% script_name %]?page=css&func=default&random=[% random_number %]" />
    [% END %]
    <script src="assets/javascript/jquery-4.0.0/jquery-4.0.0.min.js"></script>
    <script src="assets/javascript/bootstrap-5.3.8/bootstrap.bundle.min.js"></script>
    <script src="assets/javascript/ajaxprogress.js"></script>
    <script src="assets/javascript/pwe.js"></script>
  </head>
```

`layout_body.html` — navigace, messenger, tělo stránky, patička:

```html
<body>
[% PROCESS templates/resource_bundle.tmpl %]
<nav class="navbar navbar-expand-lg bg-body-tertiary border-bottom mb-4">
  <div class="container">
    <a class="navbar-brand" href="[% script_name %]">[% rb.site_brand %]</a>
    <button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#pwe-navbar" aria-controls="pwe-navbar" aria-expanded="false" aria-label="Toggle navigation">
      <span class="navbar-toggler-icon"></span>
    </button>
    <div class="collapse navbar-collapse" id="pwe-navbar">
      <ul class="navbar-nav me-auto">
        <li class="nav-item"><a class="nav-link[% IF idp == "default" %] active[% END %]" href="[% script_name %]?page=default&func=default">[% rb.menu_home %]</a></li>
        <li class="nav-item"><a class="nav-link[% IF idp == "ukoly" %] active[% END %]" href="[% script_name %]?page=ukoly&func=default">[% rb.menu_tasks %]</a></li>
      </ul>
      <ul class="navbar-nav ms-auto">
        [% IF account.login %]
        <li class="nav-item"><span class="nav-link disabled"><i class="fa-solid fa-user"></i> [% account.login %]</span></li>
        <li class="nav-item"><a class="nav-link[% IF idp == "pweCreator" %] active[% END %]" href="[% script_name %]?page=pweCreator&func=default">pweCreator</a></li>
        <li class="nav-item"><a class="nav-link" href="[% script_name %]?page=prihlaseni&func=logout">[% rb.menu_logout %]</a></li>
        [% ELSE %]
        <li class="nav-item"><a class="nav-link[% IF idp == "prihlaseni" %] active[% END %]" href="[% script_name %]?page=prihlaseni&func=default">[% rb.menu_login %]</a></li>
        [% END %]
        [% IF languages.size > 1 %][% FOREACH l IN languages %]<li class="nav-item"><a class="nav-link[% IF use_language == l %] active fw-bold[% END %]" href="[% script_name %]?page=default&func=setlanguage&lang=[% l %]">[% l %]</a></li>[% END %][% END %]
        [% IF conf_development %]<li class="nav-item"><a class="nav-link" href="#" data-bs-toggle="modal" data-bs-target="#DumpData">DataDump</a></li>[% END %]
      </ul>
    </div>
  </div>
</nav>

<div class="container">
  <div id="messenger">[% messenger %]</div>
  [% IF html_main %][% INCLUDE $html_main %][% ELSIF print_main %][% print_main %][% END %]
</div>

[% INCLUDE Sites/Default/layout_footer.html %]
</body>
</html>
```

Důležité prvky: `<div id="messenger">` (sem patří flash zprávy, i z AJAXu), `[% INCLUDE
$html_main %]` (tělo stránky), odkazy přes `[% script_name %]?page=…`, aktivní položka podle
`idp`, podmínky podle `group.admin` / `account.login` / `conf_development`.

`layout_footer.html` obsahuje patičku a ve vývojovém režimu modal `DumpData`
(`[% INCLUDE templates/DumpData.tmpl %]`), který vypíše všechny proměnné šablony.

## CSS a statika

| Způsob | Nastavení | Kdy |
| --- | --- | --- |
| statický soubor | `css.src_css => "static"`, odkaz `static/css/site.css?v=[% start_time %]` | výchozí; soubor servíruje nginx (compose) nebo engine přes `pwe.assets_dir` |
| SCSS překlad | `css.src_css => "scss"`, `scss_src`, `scss_out`, `scss_bin` | vývoj se SCSS; stránka enginu `?page=css&func=default` ho přeloží při každém requestu a uloží do `scss_out` |

Vše ve `static/` (CSS, obrázky, fonty webu) se adresuje relativně (`static/images/logo.png`).
Sdílené knihovny jsou v enginu pod `assets/` a web je **nekopíruje** — do `Dockerfile`
ani do gitu webu nepatří. Vlastní favicon dej do kořene webu (`pwe.assets_file`).

Pravidla pro markup: Bootstrap **5.3.8** (`row/col-md-*`, `navbar-expand-lg`, `btn-primary`,
`data-bs-*`, `btn-close`, `form-select`, `text-bg-*` odznaky), ikony Font Awesome 6
(`<i class="fa-solid fa-check"></i>`), inline skripty spouštěj `$(function(){ … })`.
Knihovny v `PWE/assets` jsou cizí kód — neupravují se.

## Více vzhledů

Web může mít další vzhledy (administrace, tisková verze, jiná sekce webu):

```bash
make module TYPE=site WEB=mujweb.web NAME=Admin ARGS='--parent Default --services Session,UserAccount'
```

Vznikne `Sites/Admin/Admin.pm` s proxy metodami na rodičovský vzhled (`--parent`, jinak na
`Libs::Web`) — uprav mu `layout_*` a `getDefaultTemplateValues`. Stránka si vzhled vybere
injektorem `sub Site_Admin { $WEB = $_[1] }`. Jedna stránka může mít i dva vzhledy (dva
injektory do různých proměnných) a při renderu zvolit.

Engine obsahuje ukázkový druhý vzhled `Sites/Responsive` (vlastní layouty a
`assets/css/responsive.css`) se stránkou `Pages/responsive`; web si ho zapne přes
`core_sites => ["Responsive"]` a `core_pages => [..., "responsive"]`. Vzhled slouží jako
**náhled webu v rámečcích zařízení** (počítač, tablet 1024 × 768 / 768 × 1024, mobil 375 × 667 –
obrázky `assets/images/*.svg`): stránka načte web do `<iframe>` a přepínač mění jen CSS třídu
`#iframe-container`. Vlastní variantu stránky (výběr nahlížené stránky parametrem, přístup jen
pro správce nebo při `pwe.development`) si web napíše do svého `Pages/responsive/` – stejnojmenný
modul webu enginový přepíše, stačí pak jen `core_sites => ["Responsive"]`; vzor je v e-shopu.

## Chybové stránky

Chyby 400/401/404/500 renderuje stránka enginu `errorPage` s layouty z `http.layout_error_header`
a `http.layout_error_body` (výchozí `templates/LayoutErrorHeader.html`/`LayoutErrorBody.html` — holý
dokument s messengerem). Chceš-li chybu v designu webu, nastav v `web.conf`
`layout_error_header => "Sites/Default/layout_header.html"` a `layout_error_body =>
"Sites/Default/layout_body.html"` (layout musí zvládnout chybějící `html_main`), nebo vytvoř
vlastní `Pages/errorPage` ve webu ([13 — Cookbook](13-cookbook.md)).
