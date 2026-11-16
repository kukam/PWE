# 13 — Cookbook

Hotové recepty na časté úkoly. Všechny vycházejí z ověřeného tutoriálového webu
([12](12-tutorial-ukolnicek.md)) nebo z ukázkových stránek enginu (`PWE/Pages/formExamples`,
`ajaxExamples`). Proměnné `$USER`, `$WEB`, `$ENTITIES`, `$DBI`, `$CONF`, `$LOG` jsou globály
stránky ([04](04-stranky.md)).

## 1. Formulář s validací a flash zprávou

```perl
# new()
$self->{'func'}->{'default'} = [];
$self->{'func'}->{'form'}    = [];
$self->{'defined'}->{'form'} = {parameters => ['email', 'fullname']};
$self->{'rules'}->{'form'}->{'email'} = [['is_email', 'error_email', 'parameter']];
$self->{'error'}->{'form'}   = "error";

sub form {
    my $self = shift;
    my $email    = $USER->getParam("email", 0, "");
    my $fullname = $USER->getParam("fullname", 0, "");
    ...                                                        # uložení přes službu
    $WEB->setMessenger("Pages/X/msg.html", msg_allright => ['ok_form'], fullname => $fullname);
    $self->default();                                          # default() řeší i ajax_request (viz tutoriál)
}

sub error {
    my ($self, $error) = @_;
    $WEB->setMessenger("Pages/X/msg.html", msg_error => $error);
    return 400 if ($USER->getParam("ajax_request", 0, undef));
    $self->default();
}
```

`rb.tmpl`: `rb.msg.error_exist__email`, `rb.msg.error_exist__fullname`, `rb.msg.error_email`,
`rb.msg.ok_form`. Formulář má skrytá pole `page`/`func` a pro AJAX
`<script>$(function(){ AjaxFormAppender($("#idformulare")); });</script>`.

## 2. Upload souboru

```perl
sub form {
    my $self = shift;
    my $home  = $CONF->getValue("pwe", "home");
    my $updir = $CONF->getValue("pwe", "upload_dir", "uploadfile/");

    my ($err, @files) = $USER->saveUploadFile('photo', $home, $updir, 1);   # (parametr, kořen, podadresář, přepsat existující)
    if ($err) {
        $WEB->setMessenger("Pages/X/msg.html", msg_error => [$err]);         # error_parameter_is_empty | error_file_is_exist | error_file_write
    } else {
        $WEB->setMessenger("Pages/X/msg.html", msg_allright => ['ok_upload'], files => \@files);
    }
    $self->default();
}
```

Formulář musí mít `enctype="multipart/form-data"` (AJAX formulář to zvládne, ukazuje procenta).
Limit řídí `pwe.cgi_maxfilesize` (překročení → 413 přes `errorPage/cgi_error`). Název souboru je
`basename` od klienta; pro kontrolu přípony použij `rules` nad názvem (`is_regx`) nebo ověř
`@files` po uložení. Nahrané soubory jsou dostupné na `uploadfile/<soubor>` (adresář je
v `pwe.assets_dir`); výpis adresáře povoluje `pwe.assets_browse_dir`. Obrázky lze zmenšit přes
`Libs::Pics` (ImageMagick) — [14 — API reference](14-api-reference.md#libspics--obrázky-imagemagick).

## 3. Stránkovaná tabulka z databáze

Viz [09 — Stránkované tabulky](09-databaze-a-entity.md#stránkované-tabulky-servicesdbtable)
a kompletní `Pages/ukoly` v tutoriálu (`genTable` + `table.html` + AJAX překreslení).

## 4. Překreslení jednoho řádku / části stránky (AJAX)

```perl
sub toggle {
    my $self = shift;
    my $id = $USER->getParam('id', 0, 0);
    my $ok = $TASKS->setDone($id, $USER->getParam('done', 0, 'f'));
    $WEB->setMessenger("Pages/X/msg.html", $ok ? (msg_allright => ['ok_status'], disable_scrolltomessenger => 1) : (msg_error => ['error_status']));
    $WEB->printHttpHeader('type' => 'ajax');
    $WEB->printAjaxLayout(
        ajax_id   => ["row-$id"],                                  # <tr id="row-5"> / <td id="row-5">
        ajax_tmpl => ["Pages/X/row.html"],
        ajax_data => {task => $TASKS->getTask($id)},
    );
}
```

Odkaz v šabloně: `[% INCLUDE templates/href.tmpl href="$script_name?page=X&func=toggle&id=$t.id&done=t" ajaxjson=1 %]`.
Více elementů najednou: `ajax_id => ['a', 'b'], ajax_html => [$html_a, $html_b]`.

## 5. Přesměrování po akci

```perl
# klasický request (POST formuláře): 301 + Location, messenger se zobrazí na cílové stránce
$WEB->setMessenger("Pages/X/msg.html", msg_allright => ['ok_created']);
$WEB->printHttpHeader('type' => 'redirect', 'redirect_link' => $WEB->getScriptName() . '?page=X&func=default');

# AJAX request: klient provede window.location
$WEB->printHttpHeader('type' => 'ajax_redirect', 'redirect_link' => $WEB->getScriptName() . '?page=X&func=default');
```

## 6. Přepnutí jazyka

Vygenerovaná úvodní stránka to má hotové:

```perl
$self->{'func'}->{'setlanguage'} = [];
$self->{'rules'}->{'setlanguage'}->{'lang'} = [['is_language', 'error_language', 'parameter']];
$self->{'error'}->{'setlanguage'} = "error";

sub setlanguage {
    my $self = shift;
    my $default = $CONF->getValue("http", "languages", ["CZE"])->[0];
    $USER->setLanguage($USER->getParam("lang", 0, $default));    # UserAccount: do session i do Libs::User
    $self->default();
}
```

Odkazy: `?page=default&func=setlanguage&lang=EN`; texty v `rb_EN.tmpl` každého modulu.

## 7. Chráněná akce a podmíněné tlačítko

```perl
$self->{'func'}->{'remove'} = ['admin'];                    # 401 pro ostatní
```

```
[% IF group.admin %]<a class="btn btn-sm btn-outline-danger" href="…&func=remove&id=[% t.id %]" onclick="return confirm('[% rb.confirm_remove %]');">…</a>[% END %]
```

Jak se uživatel do skupiny `admin` dostane: [11 — Uživatelé a práva](11-uzivatele-a-prava.md).

## 8. Odeslání e-mailu

```perl
# conf/web.conf: pwe.smtp_servers => ["smtp_primary"], sekce smtp_primary => { host => "smtp.example.cz", port => 25, ... }
# core_services => [..., "Email"], core_entities => [..., "MailQueue"], tabulka mailqueue v dbversion (SQL v POD PWE/Entities/MailQueue/MailQueue.pm)

sub Service_Email { my ($self, $input) = @_; $EMAIL = $input; }

$EMAIL->addEmailToQueue(
    from    => $CONF->getValue('web', 'email_admin', 'root@localhost'),
    to      => $email,
    subject => 'Nový úkol',
    text    => "Content-Type: text/html; charset=UTF-8\n\n" . $WEB->genTmpl("Pages/X/email.html", task => $task),
);
```

E-mail se **zařadí do fronty**; odešle ho `$EMAIL->sendAllEmail()` — volej z cron akce (recept 9).
Přímé odeslání bez fronty umí `Libs::Send` (vytvoření objektu `new Libs::Send($CONF->getValue('smtp_primary'))`,
`setFrom/setTo/setSubjectUTF8/setBodyHtmlUTF8/send`), ale ve webu se preferuje služba `Email`.

## 9. Volání stránky z příkazové řádky (cron)

Engine spuštěný bez FastCGI socketu obslouží jeden request z prostředí a skončí:

```bash
# v kontejneru webu (např. docker exec do pwe-fcgi-1, nebo CMD cron kontejneru se stejným image)
cd /PWE/webapps/<web> && . vars && QUERY_STRING='page=cron&func=minute&request_method=POST' perl /PWE/PWE/pwe.fcgi
# z hostitele ve vývoji
make cgi WEB=<web> Q='page=cron&func=minute'
```

Stránka `cron` s akcemi (`minute`, `hour`, `day`) omezenými např. na IP nebo tajný parametr
(`rules` → `is_equal_to`) volá služby (`$EMAIL->sendAllEmail()`); výstup tiskni `type => 'plain'`.
Pro URL v generovaných textech bez HTTP requestu slouží `http.base_url`.

Callbacky externích systémů (platební brána, webhook) smějí mít cíl v URL (`?page=objednavka&func=navrat`)
i při POST s cizím tělem — engine vezme `page`/`func` z query stringu, když v těle nejsou ([04](04-stranky.md#post-formuláře)).

## 10. Vlastní chybová stránka

Web vytvoří `Pages/errorPage/errorPage.pm` (přebije modul enginu) — nejjednodušší je zkopírovat
`PWE/Pages/errorPage/` do webu a upravit šablony a `rb*.tmpl`. Nebo jen změň layout:
v `web.conf` `http.layout_error_header => "Sites/Default/layout_header.html"`,
`http.layout_error_body => "Sites/Default/layout_body.html"` — chyba se vykreslí v designu webu
(layout musí snést chybějící `html_main`). Z vlastní stránky chybu vyvoláš `return 404;`.

## 11. Data uživatele mezi requesty bez databáze

```perl
my $basket = $USER->getOpts("eshop", "basket", []);     # načtení (default [])
push(@{$basket}, {id => $pid, qty => 1});
$USER->setOpts($basket, "eshop", "basket");             # uloží se ve flush do opts souboru
$USER->delOpts("eshop", "basket");
```

S databází ukládej do session: `$USER->setValue('klic', $hodnota)` (služba účtu deleguje na
`Session`; klíč musí být sloupec tabulky `session`).

## 12. Čtení konfigurace a logování

```perl
my $per_page = $CONF->getValue("web", "tasks_per_page", 10);    # vlastní klíč v sekci web
$LOG->info("Imported $n rows");                                 # [I], loglevel >= 3
$LOG->error("Payment failed: $reason");                         # [E]
$LOG->debug(Dumper($data));                                     # [D], loglevel 4
$LOG->delay("import"); ...; $LOG->delay("import", "CSV import");   # [d] čas úseku (log.log_delay = 1)
```

## 13. Export do CSV / stažení souboru / JSON odpověď

```perl
$WEB->printHttpHeader('type' => 'csvdown', 'csv_filename' => 'ukoly.csv');
print join(";", 'id', 'title', 'done'), "\n";
my $SQL = $DBI->select("db1", "id, title, done FROM tasks ORDER BY id", []);
while (my @r = $SQL->fetchrow_array) { print join(";", map { s/"/""/g; qq("$_") } @r), "\n"; }
$SQL->finish;

$WEB->printHttpHeader('type' => 'file', 'filename' => 'export.zip');        # application/octet-stream, příloha
open(my $fh, '<', $path) or return 404; binmode($fh); print while (<$fh>); close($fh);

$WEB->printHttpHeader('type' => 'static', 'content_type' => 'application/json; charset=UTF-8');   # JSON API bez cookie
print JSON::to_json({total => $stats->{'total'}});                         # JSON je ve všech image PWE (use JSON; ve službě)
```

## 14. Vlastní validátor s přístupem do DB

```perl
# Services/Tasks/Tasks.pm
sub is_task_id {
    my ($self, $id) = @_;
    return undef unless (defined($id) and $id =~ /^\d+$/);
    my $T = $ENTITIES->createEntityObject('Task', $id);
    return ($T->id ? $id : undef);
}
# stránka
$self->{'rules'}->{'toggle'}->{'id'} = [['Services::Tasks::is_task_id', 'error_task_id', 'parameter']];
```

## 15. Načti-nebo-založ záznam

```perl
my $S = $ENTITIES->createEntityObject('Setting', {where => "name = ?", conds => [$name]});
$S->name($name) unless ($S->id);           # neexistuje → nový řádek
$S->value($value);
$S->flush; $S->logit; $S->error ? $S->rollback : $S->commit;
```

## 16. Druhý vzhled pro administraci

```bash
make module TYPE=site WEB=<web> NAME=Admin ARGS='--parent Default --services Session,UserAccount'
```

Uprav `Sites/Admin/layout_body.html` (jiné menu) a ve stránkách administrace použij
`sub Site_Admin { $WEB = $_[1] }` místo `Site_Default`. Stránka může mít oba injektory a vybrat
vzhled podle skupiny.

## 17. URL slug a formátování ceny

```perl
my $slug = $WEB->convertToRewrite("Příliš žluťoučký kůň");      # prilis_zlutoucky_kun
```

```
[% INCLUDE templates/niceprice.tmpl price = item.price round = 2 currency = "Kč" %]
```

## 18. Jednorázová inicializace a cache ve službě

```perl
sub autostart {                                  # jednou při startu procesu
    my $self = shift;
    $self->{'countries'} = $self->loadCountries();   # číselník do paměti (přežívá requesty)
}
```

Pozor: cache je per proces (compose spouští 3 procesy) a neví o změnách v DB — vhodné jen pro
neměnná data, nebo s invalidací podle času.

## 19. CSRF token pro změnové akce

Engine CSRF token nemá; vzor z e-shopu Syrmex: služba účtu drží token v DB session (sloupec `csrf`, při
chybějícím vygeneruje 32 hex) a nabízí validátor.

```perl
# Services/UserAccount/UserAccount.pm
sub csrfToken { my $self = shift; return $SESSION->getValue('csrf', ''); }
sub is_csrf   { my ($self, $token) = @_; my $t = $self->csrfToken(); return (defined($token) and length($t) and $self->constEq($token, $t)) ? $token : undef; }
# constEq = porovnání v konstantním čase (XOR po znacích, délka se porovná předem), ne `eq` – viz Syrmex UserAccount

# Sites/Default/Default.pm — token do každé šablony
sub getDefaultTemplateValues { ...; 'csrf' => $ACCOUNT->csrfToken(), ... }

# stránka — každá akce měnící stav
$self->{'defined'}->{'remove'} = {parameters => ['id', 'csrf']};
$self->{'rules'}->{'remove'}->{'csrf'} = [['Services::UserAccount::is_csrf', 'error_csrf', 'parameter']];
```

```html
<input type="hidden" name="csrf" value="[% csrf %]" />          <!-- formuláře -->
<a href="…&func=remove&id=[% t.id %]&csrf=[% csrf %]">…</a>     <!-- odkazy měnící stav -->
```

Po odhlášení token obnov. `error_csrf` přelož v rb („Formulář vypršel, zkuste to znovu.“).

## 20. Vlastní stránkování bez `DBTable`

```perl
my $per_page = 12;
my $strana   = int($USER->getParam("strana", 0, 1) || 1);
my $total    = $CATALOG->countProducts(category_slug => $slug, q => $q);
my $pages    = int(($total + $per_page - 1) / $per_page) || 1;
$strana = $pages if ($strana > $pages);
my $items = $CATALOG->getProducts(category_slug => $slug, q => $q, order => $razeni, limit => $per_page, offset => ($strana - 1) * $per_page);
$WEB->printHtmlLayout(html_main => "Pages/katalog/main.html", items => $items, strana => $strana, pages => $pages, query => {kategorie => $slug, q => $q, razeni => $razeni});
```

V šabloně generuj odkazy `?page=katalog&func=default&kategorie=[% query.kategorie | uri %]&q=[% query.q | uri %]&strana=[% n %]`
(filtr `| uri` v URL, `| html` v textu). `strana` validuj `is_integer`, řazení mapuj na pevné SQL fragmenty
([09](09-databaze-a-entity.md#vlastní-sql-stránkování-hledání-náhodné-pořadí)).

## 21. Upload obrázku s kontrolou obsahu

```perl
sub obrazek {
    my $self = shift;
    my ($err, @files) = $USER->saveUploadFile('image', $CONF->getHome(), 'uploadfile/products/', 1);   # adresář musí existovat (mkdir není rekurzivní – založ ho v autostart)
    return $self->fail('error_upload') if ($err or !@files);
    my $file = $CONF->getHome() . "uploadfile/products/$files[0]";
    my ($ext) = ($files[0] =~ /\.(jpe?g|png|webp|gif)$/i);
    my $ok = $ext && imageLooksValid($file);                 # magická hlavička + Image::Magick->Ping (je ve všech image PWE)
    unless ($ok) { unlink($file); return $self->fail('error_image_type'); }
    my $new = sprintf("%d-%d.%s", $id, time(), lc($ext));      # bezpečné jméno bez vstupu od uživatele
    rename($file, $CONF->getHome() . "uploadfile/products/$new");
    $CATALOG->setProductImage($id, $new);                     # do DB jen basename; starý soubor smaž
    ...
}
```

Formulář `enctype="multipart/form-data"` s `csrf`; v šabloně obrázek `uploadfile/products/[% p.image | uri %]`,
jinak placeholder `static/images/no-image.svg`. Nginx v compose servíruje `uploadfile/` přímo.

## 22. E-mail v jazyce objednávky

Při generování z administrace nebo cronu nemá request jazyk zákazníka. Šablona e-mailu si texty načte sama
([06](06-sablony-a-i18n.md#šablona-v-jiném-jazyce-než-má-uživatel-e-maily)) a předmět se renderuje stejně:

```perl
my %vars = (order => $order, shop_name => $CONF->getValue("web", "shop_name", "Shop"), lang => $order->{'lang'});
my $subject = $WEB->genTmpl("Pages/objednavka/email_subject.html", %vars, kind => 'confirm');
$subject =~ s/\s+/ /g; $subject =~ s/^\s+|\s+$//g;
$EMAIL->addEmailToQueue(from => $from, to => $order->{'email'}, subject => $subject,
    text => "Content-Type: text/html; charset=UTF-8\n\n" . $WEB->genTmpl("Pages/objednavka/email_confirm.html", %vars));
```

Absolutní odkazy v e-mailu neskládejte z `HTTP_HOST` (hlavičku určuje klient a e-mail může vzniknout
i mimo request, např. v cronu) — čtěte veřejnou URL enginu z konfigurace webu (v Syrmexu klíč
`web.shop_url`, např. `https://www.syrmex.cz/pwe.fcgi`, přepsatelný `PWE_CONF_web_shop_url`)
s fallbackem na `http.base_url` + `/pwe.fcgi`.

## 23. Externí HTTPS API a RSA podpis (platební brána)

Image enginu má `HTTP::Tiny` + `IO::Socket::SSL` (HTTPS), `JSON`, `Crypt::OpenSSL::RSA` a CLI `openssl`.
Vzor klienta brány (ČSOB eAPI) včetně podpisů, ověření odpovědi a vestavěného simulátoru je v e-shopu
Syrmex (`Services/Payment`) a popsaný v [22 — Platební brána ČSOB](22-platebni-brana-csob.md).

```perl
my $res = HTTP::Tiny->new(timeout => 30)->post("$api/payment/init", {content => to_json(\%req), headers => {'Content-Type' => 'application/json'}});
return $self->fail('error_gateway') unless ($res->{'success'});
my $data = from_json($res->{'content'});
```

Klíče a tajemství drž mimo git (`PWE_CONF_csob_*`), návratové parametry z prohlížeče nikdy nevěř bez ověření
podpisu a serverového dotazu na stav.

## 24. Společné přihlášení zákazníka i správce (jeden formulář, jedno odhlášení)

Vzor z e-shopu Syrmex: správce (jméno a heslo z `web.admin_login`/`web.admin_password`) i zákazník
(e-mail + heslo z tabulky `customers`) se přihlašují **jedním formulářem** `?page=ucet&func=default`;
po přihlášení správce přibudou v menu položky administrace a jediné tlačítko „Odhlásit se“ odhlásí
obě role.

```perl
# Services/UserAccount/UserAccount.pm
sub login {                                          # vraci 'admin' | 'customer' | undef (lastError)
    my ($self, $login, $password) = @_;
    my $ip = $USER->getIP();
    if ($self->loginLocked($ip)) { $self->{'error'} = 'error_login_locked'; return undef; }   # (a) zamek IP
    if ($self->verifyAdmin($login, $password)) {     # (b) obe porovnani constEq, vzdy obe (konstantni cas)
        $self->setAdminSession();                    #     session.admin = 't', skupina 'admin', regenerate + novy csrf
        $self->clearLoginFails($ip);
        return 'admin';
    }
    ...                                              # (c) zakaznik: Customer podle e-mailu, verifyPassword (PBKDF2)
    unless ($ok) { $self->loginFailed($ip); $self->{'error'} = 'error_login'; return undef; }   # (d)
    return 'customer';                               #     pocitadlo IP se u zakaznika NEnuluje
}
sub logout { ... customer_id = NULL, admin = 'f', novy csrf, skupiny -> guest ... }
```

Pravidla, která se osvědčila:

- parametr formuláře je `login` (`type="text"`, ne `type="email"` – správce zadává jméno), `rules`
  jen regulární výraz na tvar; na `password` **žádná** `rules` (engine by heslo zalogoval);
- `next` (`checkout|admin`) jen z whitelistu; po úspěchu redirect (PRG), po neúspěchu redirect zpět
  s messengerem – heslo se nikdy nevykresluje;
- chráněná stránka (`access => ['admin']`) má veřejnou jen akci `default`, která nepřihlášeného
  přesměruje na `?page=ucet&func=default&next=admin`; ostatní akce vrací engine 401;
- zámek proti hádání hesla **v DB** (tabulka `login_fails` klíčovaná IP, UPDATE → INSERT → při
  duplicitě znovu UPDATE), ne v paměti procesu (FastCGI běží ve více procesech) a bez `sleep`
  (blokování procesu je levný DoS); záznam maže jen úspěšné přihlášení správce;
- po každém přihlášení `Services::Session::regenerate()` + nový CSRF token;
- v layoutu jeden dropdown: `[% IF account.id OR account.is_admin %]` – položky zákazníka podle
  `account.id`, sekce administrace podle `account.is_admin`, dole jediné „Odhlásit se“.
