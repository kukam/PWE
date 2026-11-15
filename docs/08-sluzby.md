# 08 — Služby (Services)

Služba je singleton s business logikou: modul `Services/<X>/<X>.pm`, který engine vytvoří
jednou při startu a injektuje do stránek, vzhledů i jiných služeb metodou `Service_<X>`.
Do služby patří vše, co nepatří do controlleru: práce s entitami a transakcemi, výpočty,
komunikace s okolím, validační metody, přihlášení. Stránky pak zůstávají tenké.

## Kontrakt

```perl
package Services::Tasks::Tasks;

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

sub new {
    my ($class, $conf, $log, $validate, $dbi, $entities, $user, $web) = @_;

    $DBI = $dbi; $LOG = $log; $WEB = $web; $CONF = $conf;
    $USER = $user; $VALIDATE = $validate; $ENTITIES = $entities;

    my $self = {};                   # vlastní stav služby (konfigurace, cache); NE stav requestu
    bless $self, $class;
    return $self;
}

# Volitelné: závislost na jiné službě
sub Service_Session { my ($self, $input) = @_; $SESSION = $input; }

# Volitelné lifecycle hooky (volá engine, pokud existují)
sub autostart  { my $self = shift; ... }    # jednou po načtení všech služeb
sub newRequest { my $self = shift; ... }    # na začátku každého requestu (po $USER->newRequest)
sub flush      { my $self = shift; ... }    # na konci každého requestu

# Veřejné metody = API služby
sub addTask { my ($self, %task) = @_; ... return $id; }

# Validátor použitelný v 'rules' stránek: definovaná hodnota = OK, undef = chyba
sub is_task_id { my ($self, $id) = @_; ... }

sub KOMODO { return; ... }

1;
```

Rozdíly proti stránce: konstruktor **nedostává** `$self` (vytvoří si vlastní hash), `$USER` je
vždy `Libs::User` (služba účtu se do jiných služeb injektuje jako `Service_UserAccount`),
`$WEB` je `Libs::Web` (ne vzhled webu — služba renderuje jen fragmenty přes `genTmpl`, např.
e-mail).

### Načítání a injektáž

1. `Libs::Services` načte všechny služby (web, pak povolené z enginu podle `pwe.core_services`)
   v abecedním pořadí.
2. Pro každou zavolá metody `Service_<Nazev>` s instancí jiné služby — pořadí načtení nehraje
   roli, injektáž proběhne až po načtení všech. Neexistující služba = služba se odregistruje
   (a s ní stránky, které ji vyžadují).
3. Zavolá `autostart()` tam, kde existuje.

Služba je **singleton pro celý proces**: data v `$self` přežívají requesty. Stav requestu
(přihlášený uživatel, košík) patří do `$USER` (opts) nebo do session a v `flush()` se má
vynulovat.

### Hooky a pořadí

`newRequest()` služeb se volá po `$USER->newRequest` a po `newRequest()` vzhledů; `flush()` se
volá na konci requestu před `$WEB->flush` a `$USER->flush`. Mezi službami navzájem pořadí
hooků nespoléhej — když služba A v `newRequest` potřebuje výsledek služby B, ať si ho od B
vyžádá sama (tak dělá `UserAccount`, která volá `Session->newSession()`).

### Stav requestu ve službě

Služba je singleton: `lastError`, cache výsledků nebo načtený účet přežijí do dalšího requestu. Nuluj je
v hooku `newRequest()` (nebo `flush()`), jinak uživatel uvidí chybu z cizího requestu. Šablony renderované
ze služby přes `$WEB->genTmpl` dostanou jen automatické proměnné enginu — **ne** výchozí hodnoty vzhledu
(`csrf`, `account`, `company`, `cart_count`); co šablona potřebuje, předej explicitně.

### Chyby

Metoda služby smí `die` — volání ze stránky je uvnitř `eval` stránky, takže spadne request
(500, report, reload stránky). Očekávané chyby (neplatná data, neexistující záznam) vracej
jako `undef` a nech stránku nastavit messenger. Zalogovat lze přes `$LOG->error/warning/info`.

### Služba jako validátor

Metoda služby se použije v pravidle `['Services::Tasks::is_task_id', 'error_task_id',
'parameter']` nebo v `replace`. Vrací definovanou hodnotu (OK) nebo `undef` (chyba). Pád
metody službu odregistruje a request skončí 500 ([05 — Validace](05-validace.md)).

### Transakce ve službě

Každá metoda si vytvoří vlastní instanci entity, zapíše a **sama commitne nebo rollbackne**:

```perl
sub setDone {
    my ($self, $id, $done) = @_;

    my $T = $ENTITIES->createEntityObject('Task', $id);
    return undef unless ($T->id);                  # neexistuje

    $T->done($done);
    $T->flush;
    $T->logit;                                     # zápis do logu (co se změnilo)
    if ($T->error) { $T->rollback; return undef; }
    $T->commit;
    return 1;
}
```

Detaily entit a nízkoúrovňového SQL jsou v [09 — Databáze a entity](09-databaze-a-entity.md).

## Vestavěné služby enginu

Web si je zapíná v `pwe.core_services` (a odpovídající entity v `pwe.core_entities`).

### `Session` — DB session uživatele

Entita `Session`, tabulka `session` (SQL v migracích generátoru). Drží data session aktuálního
requestu a na konci je uloží (jen při změně).

| Metoda | Účel |
| --- | --- |
| `newSession()` | načte/založí řádek podle `sid` z cookie, expirovaný smaže; aktualizuje IP a User-Agent, nastaví jazyk uživatele; vrací hash dat. Volá ji služba účtu v `newRequest` |
| `getValue($key, $default)` | hodnota sloupce session (`lang`, `admin`, `messenger`, `expire`, `ipaddres`, `useragent`) |
| `setValue($key, $value)` | nastaví hodnotu; **klíč musí být sloupec tabulky** (jinak chyba v logu při flush) |
| `existKey($key)`, `existKeyValue($key)` | existence klíče / klíče s definovanou hodnotou |
| `flush()` | zapíše změny (UPDATE + commit jen při změně) |
| ostatní | deleguje na `Libs::User` (`getSid`, `getParam`, …) |

Vlastní data v session = vlastní sloupce v tabulce `session` (přidej migrací). Expirace
`http.cookie_expire_guest` dní.

### `UserAccount` — účet a skupiny (ukázka)

Služba enginu `PWE/Services/UserAccount` je jen ukázka: každému návštěvníkovi dá skupinu
`admin`. Generátor `make new` vytváří ve webu **vlastní** `Services/UserAccount` nad `Session`
(ve vývojovém režimu admin pro všechny, jinak host) a tutoriál ji rozšiřuje o skutečné
přihlášení ([11 — Uživatelé a práva](11-uzivatele-a-prava.md)). API: `newRequest`, `getSession`,
`getAccount`, `getGroup`, `setLanguage`, `flush`; neznámé metody deleguje na `Session` → `Libs::User`,
proto ji stránky injektují do `$USER`.

### `DBTable` — stránkované a řaditelné tabulky

Entita `DBTable`, tabulka `dbtable`. Z SQL dotazu udělá stránkovanou tabulku; nastavení
(řazení, strana, počet řádků) ukládá do DB podle session a názvu tabulky, takže přežije
requesty. Popis `genTable` včetně vstupů, výstupu a šablon je v
[09 — Databáze a entity](09-databaze-a-entity.md#stránkované-tabulky-servicesdbtable).

### `Email` — fronta e-mailů

Entita `MailQueue`, tabulka `mailqueue` (SQL v POD `PWE/Entities/MailQueue/MailQueue.pm`).
Zprávy se řadí do fronty a odesílají dávkově přes SMTP servery z `pwe.smtp_servers`.

| Metoda | Účel |
| --- | --- |
| `addEmailToQueue(to => …, from => …, subject => …, text => "Content-Type: text/plain; charset=UTF-8\n\nTEXT", %volitelne)` | zařadí e-mail (stav `N`); volitelně `textalt`, `cc`, `bcc`, `replyto`, `returnpath`, `errorto`, `attachments => [cesty]`, `started => 'YYYY-MM-DD HH:MM:SS'`; vrací 1 / `undef` |
| `sendAllEmail()` | odešle vše ve stavu `N`, jehož čas `started` nastal; po 3 dnech neúspěchů stav `E` a report adminovi. Volat periodicky (cron stránka) |
| `updateSendResult($mid, 'Y'\|'N'\|'E')` | ruční změna stavu |

Tělo `text` se posílá tak, jak je, hned za hlavičky zprávy — musí začínat MIME hlavičkou
`Content-Type` a prázdným řádkem. Pro HTML e-mail vyrenderuj šablonu přes `$WEB->genTmpl`
a dej `Content-Type: text/html; charset=UTF-8`. Ve vývojovém stacku je SMTP server `mailpit`
(UI <http://127.0.0.1:8025>): v `web.conf` nastav `smtp_primary => { host => "mailpit", port => 1025 }`
a frontu odešli `?page=cron&func=mail&key=…` (viz [13 — Cookbook §9](13-cookbook.md)). Přímé odeslání bez fronty umí `Libs::Send`
([14 — API reference](14-api-reference.md)).

**Skutečný SMTP účet** (testovací i produkční): sekce `smtp_primary` zná `host`, `port`, `timeout`,
`ssl` (SMTPS, typicky 465), `starttls` (typicky 587), `authid`, `authpw`, `hello`, `debug`. Hodnoty
nepište do `web.conf`, přepište je proměnnými `PWE_CONF_smtp_primary_<klíč>` (názvy sekcí
s podtržítkem fungují od enginu 2.2.0) — v compose stacku je čte soubor `webapps/<web>/conf/local.env`
(není v gitu, viz [17 — Nasazení](17-nasazeni.md#vývojový-stack-docker-composeyml)):

```bash
PWE_CONF_smtp_primary_host=smtp.gmail.com     # Seznam: smtp.seznam.cz, port 465, ssl=1, starttls=0
PWE_CONF_smtp_primary_port=587
PWE_CONF_smtp_primary_starttls=1
PWE_CONF_smtp_primary_authid=ucet@gmail.com
PWE_CONF_smtp_primary_authpw=heslo-aplikace   # Gmail: „heslo aplikace“, ne heslo k účtu
PWE_CONF_web_email_from=ucet@gmail.com        # odesílatel = adresa účtu, jinak server zprávu odmítne/přepíše
```

Nastavení ověří `make smtp-test WEB=<web> ARGS='--to vas@email.cz'` ([16 — Nástroje](16-nastroje.md#pwetoolssmtp-testpl--testovací-e-mail)).

## Kdy vytvořit službu

| Situace | Řešení |
| --- | --- |
| logika nad jednou tabulkou (CRUD, stavy) | služba `Services/<Entita>s` nad entitou (`Tasks` nad `Task`) |
| proces přes více tabulek (objednávka, platba) | služba s metodou, která vše udělá v jedné transakci na jedné entitě po druhé, nebo přes `$DBI` na poolu 0 s jedním `commit` |
| data pro každý request (přihlášený uživatel, košík) | služba s `newRequest`/`flush`, data v session/opts |
| opakovaná úloha (cron) | stránka s akcemi volaná z CLI, logika ve službě ([13 — Cookbook](13-cookbook.md#9-volání-stránky-z-příkazové-řádky-cron)) |
| validace závislá na DB | metoda služby použitá v `rules` |

Kostru služby vytvoří `make module TYPE=service WEB=<web> NAME=Tasks ARGS='--services Session'`
(šablona `PWE/Pages/pweCreator/service.tmpl`).
