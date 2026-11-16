# 22 — Platební brána ČSOB (eAPI v1.9) v PWE

Kapitola popisuje, jak je v e-shopu nad PWE napojena **ČSOB platební brána** (eAPI v1.9) a jak se
s ní pracuje ve třech režimech: vestavěný **simulátor** (funguje hned, bez registrace a bez klíčů),
**integrační prostředí** ČSOB (iBrána, testovací karty) a **produkce**. Referenční implementace je
web Syrmex (`webapps/syrmex.web`): služba `Services/Payment`, stránka `Pages/brana` (simulátor),
stránka `Pages/cron` (dořešení plateb) a akce `navrat` stránky `objednavka`. Stejný vzor lze
použít v libovolném webu nad PWE.

Oficiální dokumentace ČSOB: <https://github.com/csob/platebnibrana/wiki> (eAPI v1.9), generátor
klíčů <https://iplatebnibrana.csob.cz/keygen/>, veřejné klíče bran
<https://github.com/csob/platebnibrana/tree/main/keys>.

## 1. Jak brána funguje v PWE

```text
 zákazník            e-shop (PWE)                                   ČSOB brána
 ────────            ──────────────────────────────────────         ───────────────────────
 odešle objednávku → Pages/objednavka::create
                       Services::Orders::createFromCart
                       Services::Payment::initPayment ─────────────→ POST payment/init (podepsaný JSON)
                                                      ←───────────── payId, paymentStatus 1 (podepsáno)
                       Orders::setPayment(pay_id, 1)
                     ← redirect na payment/process/<merchantId>/<payId>/<dttm>/<podpis>
 platí kartou ───────────────────────────────────────────────────→  stránka brány
                                                      ←───────────── GET returnUrl?payId&dttm&resultCode&paymentStatus&signature
                     Pages/objednavka::navrat
                       Services::Payment::handleReturn
                         ověří podpis návratu veřejným klíčem brány
                         GET payment/status/<merchantId>/<payId>/<dttm>/<podpis> ─→
                                                      ←───────────── paymentStatus (podepsáno)
                         paymentStatus 7|8 → Orders::setPaid (faktura, e-mail)
                     ← redirect na ?page=objednavka&func=dekujeme&no=&token= + messenger
```

Když se zákazník z brány nevrátí (zavře okno), platbu dořeší **cron**
(`?page=cron&func=platby` → `Services::Payment::checkStatus` → `payment/status`).

Role modulů:

| Modul | Vlastní | Co dělá |
| --- | --- | --- |
| `Services/Payment/Payment.pm` | web | podpis a ověření (SHA256withRSA), `payment/init`, `payment/process` URL, `payment/status`, návrat z brány, simulátor; zapisuje přes `Services::Orders` (`setPayment`, `setPaid`) |
| `Pages/brana/` | web | simulátor brány — jen v režimu `simulator`, jinak 404 |
| `Pages/cron/` | web | `mail` (fronta e-mailů), `platby` (dořešení plateb); chráněno `web.cron_key` |
| `Pages/objednavka/` | web | `create` (založí platbu a přesměruje), `navrat` (returnUrl), `dekujeme`, `platba` (zaplatit znovu) |
| `Services/Email`, `Entities/MailQueue` | engine | fronta e-mailů (potvrzení, platba přijata) |

Služba **nikdy nepíše do tabulky `orders` přímo** — stav platby ukládá výhradně přes API
`Services::Orders`, takže pravidla (přidělení čísla faktury, e-mail „platba přijata“,
idempotence) jsou na jednom místě.

## 2. Režimy (`csob.mode`)

| Režim | Klíče | API | Kdo „platí“ | Použití |
| --- | --- | --- | --- | --- |
| `simulator` | ne | žádné | stránka `?page=brana` (tlačítka Zaplatit / Zamítnout / Zrušit) | vývoj, `make run`, automatické testy — funguje bez registrace, **jen s `pwe.development = 1`** |
| `test` | ano (keygen) | `https://iapi.iplatebnibrana.csob.cz/api/v1.9` | testovací karty ČSOB | integrační testy proti skutečné bráně |
| `production` | ano (od ČSOB) | `https://api.platebnibrana.csob.cz/api/v1.9` | skutečné karty | provoz |

Režim čte `Services::Payment::mode()`; `isSimulator()` je pravdivé **jen** pro přesnou hodnotu
`simulator` **a zároveň** zapnutý vývojový režim enginu (`pwe.development` pravdivé). Simulátor je
tak svázaný s vývojem: v nasazení s `pwe.development = 0` se neotevře, i kdyby `csob.mode` zůstalo
na výchozím `simulator` — `initPayment` skončí `error_payment_config`, stránka `brana` vrací 404 a
`handleReturn`/`checkStatus` jdou do reálné větve, kde bez klíčů a podpisu selžou (fail closed).
Prázdný nebo neznámý `csob.mode` (překlep, prázdná proměnná `PWE_CONF_csob_mode`) se **nemapuje**
na simulátor, ale je to chyba konfigurace se stejným výsledkem. Chyba konfigurace tedy nikdy
neumožní „zaplatit“ bez skutečné platby.

## 3. Získání klíčů

Komunikace s bránou je podepsaná RSA klíči: požadavky e-shopu **privátním klíčem obchodníka**,
odpovědi a návratové parametry brány ověřuje e-shop **veřejným klíčem brány**.

1. **Pár klíčů obchodníka** vygenerujte na <https://iplatebnibrana.csob.cz/keygen/> (zadáte své
   `merchantId`, stáhnete `rsa_<merchantId>.key` = privátní klíč a `rsa_<merchantId>.pub`;
   veřejný klíč se registruje u ČSOB — pro integrační prostředí ho keygen nahraje sám).
   Privátní klíč uložte jako `conf/csob/private.pem` (práva `0600`, **nikdy do gitu**). Ve vývojovém
   stacku (`make run`) ho engine čte z pracovní kopie. **Do image webu se nezapéká** — kořenový
   `.dockerignore` soubory `*.pem`, `*.key`, `*.p12` a `*.pfx` z `conf/` webu vynechává — a kontejner
   z image webu ho dostává až za běhu (§10).
2. **Veřejný klíč brány** stáhněte z <https://github.com/csob/platebnibrana/tree/main/keys>:
   `mips_iplatebnibrana.csob.cz.pub` pro `test`, `mips_platebnibrana.csob.cz.pub` pro
   `production`. Uložte do `conf/csob/` a cestu nastavte v `csob.public_key`. Ponechte mu příponu
   `.pub` — veřejný klíč tajný není a do image webu patří, kdežto soubor `*.pem` by `.dockerignore`
   z image vynechal.
3. `merchantId` pro integrační prostředí vydá keygen; produkční dostanete při uzavření smlouvy.

Formáty: privátní klíč PEM (`BEGIN RSA PRIVATE KEY` i `BEGIN PRIVATE KEY`), veřejný klíč PEM
(`BEGIN PUBLIC KEY`). Oba načítá `Crypt::OpenSSL::RSA` i CLI `openssl`.

## 4. Konfigurace (`conf/web.conf`, sekce `csob`)

```perl
csob => {
    mode        => "simulator",                                       # simulator | test | production
    merchant_id => "",                                                # merchantId od ČSOB / keygen
    private_key => "conf/csob/private.pem",                           # privátní klíč obchodníka, relativně k pwe.home
    public_key  => "conf/csob/mips_iplatebnibrana.csob.cz.pub",       # veřejný klíč brány (test); produkce mips_platebnibrana.csob.cz.pub
    api_url     => "https://iapi.iplatebnibrana.csob.cz/api/v1.9",    # produkce https://api.platebnibrana.csob.cz/api/v1.9
    return_url  => "",                                                # test/production POVINNÉ (https://www.example.cz/pwe.fcgi?page=objednavka&func=navrat); prázdné jen v simulátoru
    # return_method => "GET",                                         # volitelné; výchozí GET (viz níže)
},
pwe => {
    development => 1,                                                 # 1 = vývoj (simulátor dostupný), produkce 0 (simulátor vypnutý)
},
web => {
    cron_key   => "zmente-tento-klic",                                # tajný klíč stránky cron (min. 8 znaků)
    shop_name  => "Syrmex",                                           # název v položce košíku na bráně (max 20 znaků i s číslem objednávky)
    currency   => "CZK",
},
```

| Klíč | Význam |
| --- | --- |
| `csob.mode` | režim, viz §2; prázdná hodnota = chyba konfigurace, ne simulátor |
| `pwe.development` | simulátor funguje jen při pravdivé hodnotě (viz §2); v produkci `0` |
| `csob.merchant_id` | identifikátor obchodníka; v `test`/`production` povinný |
| `csob.private_key`, `csob.public_key` | cesty ke klíčům; relativní cesta je vůči `pwe.home` (`$CONF->getHome()`), absolutní se použije tak, jak je; soubor musí existovat a být čitelný (jinak `error_payment_keys`) |
| `csob.api_url` | základ URL eAPI bez koncového lomítka |
| `csob.return_url` | návratová URL (absolutní, `http(s)://…`). V `test`/`production` **povinná** — prázdná hodnota znamená `error_payment_config` a platbu nelze založit. Z requestu se **neodvozuje**: hlavičku `Host` posílá klient (nginx bez `server_name` ji propustí) a útočník by bráně mohl podstrčit cizí návratovou adresu; navíc brána v produkci vyžaduje HTTPS. Jen v simulátoru se prázdná hodnota odvodí jako `http(s)://<HTTP_HOST>/pwe.fcgi?page=objednavka&func=navrat` (schéma podle `HTTP_X_FORWARDED_PROTO` nebo `HTTPS`, mimo HTTP request `http.base_url`). Max. 300 znaků. |
| `csob.return_method` | `GET` (výchozí) nebo `POST`. **Pozor:** při POST čte engine `page`/`func` jen z těla requestu (CGI.pm ignoruje query string), takže by návrat z brány nebyl směrován na stránku `objednavka`. Nechte `GET`. |
| `web.cron_key` | tajný parametr `key` stránky `cron`; prázdný nebo kratší než 8 znaků cron vypíná |

Tajemství (`merchant_id`, `cron_key`) patří do prostředí: `PWE_CONF_csob_merchant_id=…`,
`PWE_CONF_csob_mode=production`, `PWE_CONF_web_cron_key=…` ([03 — Konfigurace](03-struktura-webu.md)).

Závislosti jsou už v základu `pwe-base`, tedy ve všech image PWE: `libjson-perl` (JSON), `HTTP::Tiny` (součást Perlu),
`libio-socket-ssl-perl` + `libnet-ssleay-perl` (HTTPS), `libcrypt-openssl-rsa-perl` (podpis).
Bez `Crypt::OpenSSL::RSA` služba automaticky použije CLI `openssl dgst` s dočasnými soubory
v `<pwe.home>ramdisk/`; bez `IO::Socket::SSL` skončí reálný režim chybou `error_payment_ssl`.

## 5. Průběh platby krok za krokem

### 5.1 `payment/init` — založení platby (`initPayment($order, $lang)`)

Posílá se JSON (`HTTP::Tiny` POST, `Content-Type: application/json`):

| Pole | Hodnota |
| --- | --- |
| `merchantId` | `csob.merchant_id` |
| `orderNo` | `orders.order_no` (10 číslic `YYMMDDNNNN`) |
| `dttm` | `YYYYMMDDHHMMSS` |
| `payOperation`, `payMethod` | `payment`, `card` |
| `totalAmount` | celková částka objednávky **v haléřích** (celé číslo) |
| `currency` | `orders.currency` (`CZK`) |
| `closePayment` | `true` (jednokroková platba: autorizace i zúčtování) |
| `returnUrl`, `returnMethod` | viz §4 |
| `cart` | 1–2 položky: zboží `{name: "<shop_name> <order_no>" (max 20 znaků), quantity: 1, amount: zboží}` a dopravné `{name: "Doprava"/"Shipping", quantity: 1, amount}` jen když je > 0 |
| `language` | `cs` / `en` podle jazyka zákazníka |
| `signature` | SHA256withRSA, base64 |

**Řetězec k podpisu** = hodnoty oddělené `|` přesně v tomto pořadí; nepovinné parametry, které se
neposílají (`merchantData`, `customerId`, `ttlSec`, `logoVersion`, `colorSchemeVersion`,
`customExpiry`), se vynechávají **i s oddělovačem**:

```text
merchantId|orderNo|dttm|payOperation|payMethod|totalAmount|currency|closePayment|returnUrl|returnMethod|name|quantity|amount[|name|quantity|amount]|language
```

Odpověď `{payId, dttm, resultCode, resultMessage, paymentStatus, signature}` se ověří veřejným
klíčem brány nad řetězcem

```text
payId|dttm|resultCode|resultMessage|paymentStatus[|authCode][|merchantData][|statusDetail]
```

(opět jen přítomná pole). Při `resultCode == 0` služba zapíše `pay_id`/`pay_status` přes
`$ORDERS->setPayment` a vrátí `{ paid => 0, reused => 0, url => <payment/process URL>, pay_id,
status }` pro přesměrování zákazníka (v simulátoru `url` míří na `?page=brana`, `status` je 1).

#### Opakovaná platba („Zaplatit znovu“, akce `platba`)

Má-li objednávka už `pay_id`, `initPayment` **nezakládá slepě novou platbu** (přepsala by
`orders.pay_id`, zákazník by dokončil tu původní na bráně a návrat by skončil 404, objednávka
by zůstala `new`). Nejdřív zavolá `checkStatus($order)` a podle výsledku:

| Stav stávající platby | Co `initPayment` udělá | Návratová hodnota |
| --- | --- | --- |
| zaplacena (7, 8) | `checkStatus` už zavolal `setPaid` (faktura, e-mail); nový init se nedělá | `{ paid => 1, url => undef, pay_id => <stávající>, status, order => <čerstvý hash>, message => 'ok_payment_paid', cancelled => 0 }` — stránka přesměruje na `dekujeme` s `message` v messengeru (při `cancelled => 1` viz §5.3, `message` = `error_paid_cancelled`) |
| probíhá (1, 2, 4) | nový init se nedělá, zákazník se vrací na **stávající** platbu | `{ paid => 0, reused => 1, url => <URL>, pay_id => <stávající>, status }`; `url` je v `test`/`production` nově podepsaná `payment/process` URL pro stávající `payId` (podpis obsahuje nové `dttm`, lze ji vyrobit kdykoli), v simulátoru `?page=brana&func=default&payId=<stávající>` |
| zrušena / odvolána / zamítnuta / vrácena (3, 5, 6, 9, 10) nebo žádné `pay_id` | nový `payment/init` jako výše | `{ paid => 0, reused => 0, url, pay_id => <nové>, status }` |
| `checkStatus` selhal (brána neodpovídá, neplatný podpis…) | nic — stav původní platby není znám, nový init by ji mohl přepsat | `undef`, `lastError()` z `checkStatus` (např. `error_payment_http`, `error_payment_status`) |

Volající tedy testuje **nejdřív `$r->{'paid'}`**, teprve potom `$r->{'url'}`:

```perl
my $r = $PAYMENT->initPayment($order, $lang);
if ($r and $r->{'paid'}) {            # už zaplaceno (setPaid proběhl ve službě)
    $WEB->setMessenger("Pages/objednavka/msg.html", ($r->{'cancelled'} ? 'msg_error' : 'msg_allright') => [$r->{'message'}]);
    return $self->redirect('page=objednavka&func=dekujeme&' . $self->orderQuery($r->{'order'}));
}
if ($r and $r->{'url'}) {             # nová nebo probíhající platba
    $WEB->printHttpHeader('type' => 'redirect', 'redirect_link' => $r->{'url'});
    return 1;
}
# chyba: $PAYMENT->lastError()
```

### 5.2 `payment/process` — přesměrování na bránu

```text
<api_url>/payment/process/<merchantId>/<payId>/<dttm>/<urlencoded signature>     podpis = merchantId|payId|dttm
```

Stránka `objednavka::create` pošle `printHttpHeader(type => 'redirect', redirect_link => $url)`.

### 5.3 Návrat (`returnUrl`) — `handleReturn(\%params)`

Brána vrátí zákazníka na `returnUrl` s parametry `payId, dttm, resultCode, resultMessage,
paymentStatus, [authCode], [merchantData], [statusDetail], signature`. Akce `navrat` předá
`$USER->getParams()` službě, která:

1. ověří tvar `payId` a najde objednávku s tímto `pay_id` (jinak `error_payment_order`),
2. v režimu `test`/`production` **ověří podpis** návratových parametrů (stejný řetězec jako u
   odpovědi; bez platného podpisu `error_payment_signature` a nic se nezapíše),
3. **zavolá `payment/status`** a jeho `paymentStatus` má přednost (když status selže — výpadek
   sítě — použije podepsaný stav z návratu a zaloguje varování),
4. v režimu `simulator` návratové parametry **ignoruje** a stav čte z DB (`orders.pay_status`
   nastavený simulátorem),
5. při `paymentStatus` 7 nebo 8 zavolá `$ORDERS->setPaid($id, pay_id => …, pay_status => …)`,
   jinak u objednávky `new` aktualizuje `pay_status`,
6. vrátí `{ order, paid => 1|0, cancelled => 0|1, status => N, message => 'ok_payment_paid' |
   'error_paid_cancelled' | 'error_payment_*' }`.

`message` je klíč `rb.msg.*` přeložený v `Services/Payment/rb*.tmpl` — stránka ho dá přímo do
messengeru (`msg_allright => [$r->{message}]` při `paid` bez `cancelled`, jinak `msg_error`).
Stránka `navrat` **nevolá `setPaid` sama** — službě stačí výsledek (`setPaid` už proběhl).

**Zaplaceno, ale objednávka je stornovaná** (`cancelled => 1`): správce objednávku stornoval
(`setCancelled`), zatímco ji zákazník platil na bráně, takže `setPaid` odmítne
(`error_order_cancelled`). Peníze jsou strženy, proto se platba nesmí ztratit: služba zavolá
`$ORDERS->markPaidAfterCancel($id, pay_id => …, pay_status => …)` (zapíše stav platby ke
stornované objednávce a upozorní správce, že je třeba vrátit peníze) a vrátí
`{ paid => 1, cancelled => 1, message => 'error_paid_cancelled', order, status }`. Stránka dá
`message` do `msg_error`. Tentýž výsledek vrací `checkStatus` (cron `platby` ho počítá do
`paid_cancelled`) i `initPayment` (přes `checkStatus`). Hlavnímu scénáři se předchází
v administraci: před stornem kartové objednávky s `pay_id` se zavolá `checkStatus` a zaplacenou
objednávku stornovat nelze.

### 5.4 `payment/status` — dotaz na stav (`checkStatus($order)`)

```text
GET <api_url>/payment/status/<merchantId>/<payId>/<dttm>/<urlencoded signature>     podpis = merchantId|payId|dttm
```

Odpověď má stejný tvar a ověření jako u `init`. `checkStatus` vrací stejný hash jako
`handleReturn` a při zaplaceno volá `setPaid`. Používá ho cron (§7), `initPayment` před
opakovanou platbou (§5.1) a lze jím kdykoli ověřit stav z administrace (např. před stornem).

## 6. Stavy platby (`paymentStatus`)

| Stav | Význam | Výsledek v e-shopu |
| --- | --- | --- |
| 1 | platba založena | čeká (`error_payment_pending`) |
| 2 | platba probíhá | čeká |
| 3 | platba zrušena (zákazník) | `error_payment_cancelled` — lze zaplatit znovu |
| 4 | platba potvrzena (autorizace bez zúčtování) | čeká — u `closePayment = true` nenastává |
| 5 | platba odvolána | `error_payment_cancelled` |
| 6 | platba zamítnuta | `error_payment_declined` — lze zaplatit znovu |
| **7** | **čeká na zúčtování** | **zaplaceno** → `setPaid`, `ok_payment_paid` |
| **8** | **zúčtována** | **zaplaceno** |
| 9 | vrácení probíhá | `error_payment_refunded` |
| 10 | vráceno | `error_payment_refunded` |

Zaplaceno = **7 nebo 8** (`Services::Payment::isPaidStatus`). Stav v DB je `orders.pay_status`,
`orders.status` mění jen `Orders::setPaid`. Popisky stavů pro šablony:
`rb.pay_status_1` … `rb.pay_status_10` (`[% SET k = "pay_status_" _ o.pay_status %][% rb.$k %]`),
dostupné na každé stránce s `Service_Payment`.

## 7. Cron: fronta e-mailů a dořešení plateb

Stránka `cron` odpovídá prostým textem (`type => 'plain'`), každá akce vyžaduje parametr `key`
rovný `web.cron_key` (porovnání v konstantním čase; chybí/nesedí → 401).

| Akce | Co dělá | Výstup |
| --- | --- | --- |
| `?page=cron&func=mail&key=…` | `Services::Email::sendAllEmail()` — odešle frontu `mailqueue`; poté smaže expirované řádky `session` (`DELETE FROM session WHERE expire < <teď>`) | `OK sent N, pending M` |
| `?page=cron&func=platby&key=…` | pro objednávky `status = new`, `payment_method = card`, s `pay_id`, mladší než 2 dny zavolá `checkStatus` | `OK checked N, paid M, paid_cancelled K, failed F` (`K` = platby přijaté ke stornované objednávce, viz §5.3) |

Úklid tabulky `session` je v akci `mail` záměrně: engine (`Services::Session`) maže prošlý řádek jen
tehdy, když se stejný `sid` znovu ohlásí. Každý návštěvník bez cookie — a každé volání cronu přes
HTTP, protože `curl` cookie neposílá — tak založí řádek, který by jinak zůstal navždy (~1440 řádků
denně při volání každou minutu). Sloupec `expire` je unixový čas, porovnání s `time()` je přenosné
mezi MariaDB i Postgres (`UNIX_TIMESTAMP()` na Postgresu neexistuje). Počet smazaných řádků
`Libs::MyDBI::delete` nevrací, do logu jde jen `[I] CRON mail: expired session rows purged`.

Příklad crontabu (každou minutu e-maily, každých 10 minut platby):

```cron
* * * * *    curl -fsS 'https://www.example.cz/pwe.fcgi?page=cron&func=mail&key=TAJNY_KLIC'   > /dev/null
*/10 * * * * curl -fsS 'https://www.example.cz/pwe.fcgi?page=cron&func=platby&key=TAJNY_KLIC' > /dev/null
```

Bez webserveru (CGI režim enginu v kontejneru webu, [13 — Cookbook §9](13-cookbook.md)):

```bash
cd /PWE/webapps/syrmex.web && . vars && QUERY_STRING='page=cron&func=platby&key=TAJNY_KLIC' perl /PWE/PWE/pwe.fcgi
make cgi WEB=syrmex.web Q='page=cron&func=mail&key=TAJNY_KLIC'        # z hostitele ve vývoji
```

V simulátoru `platby` jen znovu vyhodnotí `pay_status` z DB (nic nevolá) — hodí se pro test cronu.

## 8. Simulátor (`?page=brana`)

Simulátor je dostupný **jen** při `csob.mode = simulator` **a** `pwe.development = 1`
(`isSimulator()`, §2). V tom případě vrátí `initPayment` URL `?page=brana&func=default&payId=SIM…`
a zapíše `pay_status = 1`; při opakované platbě probíhající objednávky vrátí tutéž URL se
stávajícím `payId` (§5.1). Stránka vypadá jako brána (obchodník, číslo objednávky, částka,
testovací karta) a má tři POST formuláře s CSRF tokenem:

| Akce | `pay_status` | Odpovídá na bráně |
| --- | --- | --- |
| `pay` | 7 | úspěšná platba |
| `decline` | 6 | zamítnutí (nedostatek prostředků, 3-D Secure…) |
| `cancel` | 3 | zákazník se vrátil bez placení |

Po zápisu (`simulatorResult`) následuje redirect na
`?page=objednavka&func=navrat&payId=…&dttm=…&resultCode=0&resultMessage=OK&paymentStatus=N&signature=SIMULATOR`
— stejná cesta jako u skutečné brány, takže `navrat` se testuje bez klíčů. `handleReturn`
v simulátoru parametry URL **nečte** (kromě `payId`), stav bere z DB; podvržený `paymentStatus`
v URL tedy nic nezmění. Už dokončenou platbu simulátor odmítne (`error_payment_closed`).
Mimo simulátor (jiný `mode`, prázdný `mode`, nebo `pwe.development = 0`) vrací stránka pro
všechny akce **404**.

## 9. API služby `Services::Payment`

| Metoda | Vrací |
| --- | --- |
| `mode()` | `'simulator'`, `'test'`, `'production'`, nebo `''`/neznámá hodnota (chyba konfigurace) |
| `isSimulator()` | 1 jen při `mode() eq 'simulator'` **a** `pwe.development` pravdivém |
| `isPaidStatus($n)` | 1 pro 7 a 8 |
| `initPayment($order, $lang)` | `{ paid => 0, reused => 0\|1, url, pay_id, status }` (přesměrovat na `url`), nebo `{ paid => 1, cancelled => 0\|1, url => undef, pay_id, status, order, message }` (už zaplaceno, nepřesměrovávat na bránu), nebo `undef` — podrobně §5.1 |
| `handleReturn(\%params)` | `{ order, paid, cancelled, status, message }` nebo `undef` |
| `checkStatus($order)` | totéž; používá cron a `initPayment` |
| `simulatorResult($pay_id, 'paid'\|'declined'\|'cancelled')` | hash objednávky nebo `undef` (jen simulátor) |
| `simulatorReturnUrl($order)` | URL návratu ze simulátoru |
| `getOrderByPayId($pay_id)` | hash objednávky (`Orders::getOrder`) nebo `undef` |
| `is_pay_id($v)` | validátor pro `rules`: `['Services::Payment::is_pay_id', 'error_pay_id', 'parameter']` |
| `lastError()` | klíč poslední chyby (`rb.msg.error_payment_*`), nuluje se na začátku requestu |

Klíče výsledku platby (`message`): `ok_payment_paid`, `error_payment_pending` (1, 2, 4),
`error_payment_cancelled` (3, 5), `error_payment_declined` (6), `error_payment_refunded` (9, 10),
`error_payment_failed`, `error_paid_cancelled` (zaplaceno ke stornované objednávce, §5.3).

Klíče chyb (`lastError`): `error_payment_order` (objednávka k payId neexistuje), `error_payment_state`
(není `new`), `error_payment_method` (není karta), `error_payment_closed` (simulátor: už
dokončeno), `error_payment_mode`, `error_payment_config` (`mode` prázdný/neznámý, `simulator`
bez `pwe.development`, `merchant_id`, `api_url`, prázdná nebo neabsolutní `return_url`),
`error_payment_keys` (klíče chybí), `error_payment_ssl` (bez `IO::Socket::SSL`),
`error_payment_http` (brána neodpovídá / ne-JSON), `error_payment_response` (bez podpisu),
`error_payment_signature` (neplatný podpis), `error_payment_sign` (podpis selhal),
`error_payment_init` (`resultCode != 0`), `error_payment_status`, `error_payment_return`,
`error_payment_db` (zápis přes Orders selhal), `error_payment_io`. Technický detail každé
chyby je v logu enginu (`[E] PAYMENT <klíč>: …`), na úrovni `log.loglevel = 4` i odeslané a
přijaté JSONy.

Závislosti služby: `Service_Orders` (`setPayment`, `setPaid`, `markPaidAfterCancel`, `getOrder`,
`lastError`); `$USER` je `Libs::User` (čte `env` pro návratovou URL v simulátoru), `$WEB` je
`Libs::Web` (`getScriptName`).

## 10. Přechod do produkce

- [ ] produkční `merchantId` a privátní klíč od ČSOB (`PWE_CONF_csob_merchant_id`, soubor s právy `0600`, mimo git **i mimo image webu**)
- [ ] privátní klíč předat kontejneru za běhu — mountem nebo secretem — a cestu nastavit absolutně přes `PWE_CONF_csob_private_key` (viz níže); v image webu klíč není a bez něj každá platba v `test`/`production` skončí chybou `error_payment_keys`
- [ ] `csob.public_key` = `mips_platebnibrana.csob.cz.pub`, `csob.api_url` = `https://api.platebnibrana.csob.cz/api/v1.9`
- [ ] `csob.mode = production` (`PWE_CONF_csob_mode`, hodnota nesmí být prázdná), ověřit, že `?page=brana&func=default&payId=x` vrací 404
- [ ] `csob.return_url` nastavit na veřejnou HTTPS adresu (`https://www.example.cz/pwe.fcgi?page=objednavka&func=navrat`) — v `test`/`production` je **povinná**, bez ní `initPayment` vrací `error_payment_config`; brána vyžaduje HTTPS
- [ ] `web.cron_key` změnit (`PWE_CONF_web_cron_key`) a nasadit cron `mail` (e-maily + úklid `session`) + `platby`
- [ ] web běží za HTTPS, `pwe.development = 0` (tím je simulátor vypnutý i kdyby `csob.mode` zůstalo `simulator`), `log.loglevel` ≤ 3 (na úrovni 4 se logují celé JSONy)
- [ ] ověřit opakovanou platbu: „Zaplatit znovu“ u probíhající platby vede na **stejný** `payId`, u zaplacené na `dekujeme` (§5.1)
- [ ] projít jeden nákup v režimu `test` s testovací kartou ČSOB (čísla karet jsou ve wiki ČSOB) včetně zamítnutí a zrušení
- [ ] zkontrolovat, že e-mail „platba přijata“ a faktura vznikají jen po `setPaid` (stav 7/8)

**Privátní klíč v kontejneru.** Image webu (`webapps/syrmex.web/Dockerfile`) privátní klíč neobsahuje:
kořenový `.dockerignore` vynechává z `conf/` webu soubory `*.pem`, `*.key`, `*.p12` a `*.pfx`, aby se
klíč nedostal do registru. Kontejneru ho dodejte až při spuštění a službě řekněte, kde je —
absolutní cestu `csob.private_key` použije tak, jak je:

```bash
docker run … \
    -v /srv/secrets/csob/private.pem:/run/secrets/csob_private.pem:ro \
    -e PWE_CONF_csob_private_key=/run/secrets/csob_private.pem \
    -e PWE_CONF_csob_mode=production -e PWE_CONF_csob_merchant_id=… \
    registry.example.com/syrmex-web:1.0
```

V Kubernetes je to Secret namountovaný jako soubor a stejná proměnná v `env`. Jde i namountovat klíč
přímo na výchozí cestu `/PWE/webapps/syrmex.web/conf/csob/private.pem` — pak se `csob.private_key`
nemění. Veřejný klíč brány (`*.pub`) v image je. Obecně o tajných údajích a image webu:
[17 — Nasazení](17-nasazeni.md#image-vlastního-webu).

## 11. Bezpečnost

- **Nikdy nevěř návratovým parametrům bez podpisu.** `paymentStatus` v URL si může napsat kdokoli;
  služba nejdřív ověří podpis veřejným klíčem brány a navíc se zeptá `payment/status`. V simulátoru
  parametry ignoruje a čte DB. Stránka `navrat` nikdy nevolá `setPaid` sama — jen přes službu.
- **Odpovědi brány se ověřují** stejným mechanismem (`verifyResponse`); neověřená odpověď = chyba.
- **Platbu lze založit jen pro objednávku `new` s platbou kartou**; zaplacená/odeslaná/stornovaná
  objednávka skončí `error_payment_state`. `setPaid` je idempotentní.
- **Privátní klíč nikdy neopouští server** a není v gitu ani v image webu (`.dockerignore`;
  kontejner ho dostává mountem, §10); cesta je v konfiguraci, obsah se čte při každém podpisu
  (změna klíče nevyžaduje restart).
- **CLI fallback** spouští `openssl` bez shellu (seznam argumentů), dočasné soubory mají náhodný
  název v `ramdisk/` a mažou se hned po použití; výstup příkazu se čte, aby nic neuteklo do
  HTTP odpovědi.
- **Simulátor** je dostupný jen v `csob.mode = simulator` **a** `pwe.development = 1` (bez
  vývojového režimu je vypnutý — výchozí `simulator` v `web.conf` tak v produkci nikdy neotevře
  „platbu zdarma“), jeho změnové akce jsou POST s CSRF tokenem (`Services::UserAccount::is_csrf`)
  a `payId` prochází validátorem `is_pay_id`.
- **Návratová URL** se v `test`/`production` bere výhradně z konfigurace (`csob.return_url`), nikdy
  z hlavičky `Host` requestu — útočník by jinak mohl bráně podstrčit cizí návratovou adresu.
- **Opakovaná platba nepřepíše rozpracovanou ani zaplacenou platbu** — `initPayment` nejdřív ověří
  stav stávajícího `payId` (§5.1); když stav nelze zjistit, novou platbu odmítne.
- **Cron** porovnává klíč v konstantním čase a odmítá prázdný/krátký klíč; neúspěch loguje s IP.
- **TLS**: `HTTP::Tiny` s `verify_SSL => 1` (ověření certifikátu brány), timeout 30 s.
- Do logu nejde privátní klíč ani podpisy v čitelné podobě; na `loglevel 4` ano celé JSONy —
  v produkci nepoužívat.

## 12. Řešení problémů

| Projev | Příčina / řešení |
| --- | --- |
| `error_payment_keys` | soubor klíče chybí nebo nemá práva; relativní cesta je vůči `pwe.home`. V kontejneru z image webu privátní klíč není (do image se nezapéká) → dodat mountem a nastavit `PWE_CONF_csob_private_key` (§10) |
| `error_payment_ssl` | v image chybí `IO::Socket::SSL`/`Net::SSLeay` (`pwe-base` a všechny image z něj je mají) |
| `error_payment_signature` u `init` | špatný veřejný klíč brány (test vs. produkce) nebo jiné `api_url` |
| `error_payment_init` s `resultCode 110` | neplatný podpis požadavku — privátní klíč nepatří k `merchantId`, nebo nesedí pořadí polí |
| `error_payment_init` s `resultCode 100` | chybný parametr (např. `returnUrl` není HTTPS v produkci, `orderNo` není číslo) |
| návrat z brány skončí na úvodní stránce | `return_method = POST` — engine čte `page`/`func` jen z těla; použijte `GET` |
| platba zaplacená na bráně, objednávka stále `new` | zákazník se nevrátil; spusťte `?page=cron&func=platby&key=…` |
| `error_payment_config` s `csob.return_url is empty` | v `test`/`production` je `csob.return_url` povinná — nastavte `PWE_CONF_csob_return_url` |
| `error_payment_config` s `csob.mode is empty` / `requires pwe.development` | prázdná proměnná `PWE_CONF_csob_mode`, nebo `simulator` v nasazení s `pwe.development = 0` (záměr: simulátor jen pro vývoj) |
| stránka `brana` vrací 404 | `csob.mode` není přesně `simulator`, nebo `pwe.development = 0` (obojí záměr v provozu), nebo `payId` neexistuje |
| „Zaplatit znovu“ skončí chybou `error_payment_status`/`error_payment_http` | stav stávající platby nešlo u brány ověřit; nová platba se nezakládá, aby nepřepsala rozpracovanou — zkuste znovu nebo spusťte cron `platby` |
| zaplaceno, ale objednávka je `cancelled` (`error_paid_cancelled`) | správce stornoval během platby; `markPaidAfterCancel` zapsal `pay_id`/`pay_status`, je třeba vrátit peníze (v administraci ČSOB) |

Související kapitoly: [04 — Stránky](04-stranky.md), [08 — Služby](08-sluzby.md) (fronta
e-mailů), [13 — Cookbook §9](13-cookbook.md) (volání stránky z cronu), [17 — Nasazení](17-nasazeni.md).
