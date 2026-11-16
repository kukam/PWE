# 09 — Databáze a entity

Databázová vrstva má tři úrovně: **`Libs::MyDBI`** (připojení, pool, SQL s placeholdery),
**DAO** (`Libs::MyDBI::DAO`, jeden řádek tabulky s dynamickými metodami sloupců) a **entity**
(`Entities::<X>`, třída pro tabulku s vlastní validací sloupců). Ve webu se pracuje hlavně
s entitami; nízkoúrovňové SQL se hodí pro agregace a hromadné operace.

## Konfigurace a start

- Připojení je v `conf/database.conf` (symlink na `<driver>.conf`), klíč `db1` = `$dbid`
  ([03 — Struktura webu](03-struktura-webu.md#confdatabaseconf-a-driverconf)).
- Při startu engine pro každé `dbid` vytvoří `db_pool + 1` spojení, spustí migrace
  (`dbversion_file`) a načte **DAO mapu** — popis tabulek a sloupců z `information_schema`
  (typ, délka, NULL, default, unikátnost, primární klíč, hodnoty ENUM). Z ní se pak staví DAO
  objekty a validují hodnoty. Mapu lze cachovat do `daomap_file` (po změně schématu soubor smaž).
- Schéma se mění **jen migracemi** v `conf/<driver>.dbversion`
  ([03 — Migrace](03-struktura-webu.md#migrace-schématu-confdriverdbversion)). Web běží ve více
  procesech a všechny startují nad stejnou databází: migraci provede jen jeden, ostatní na něj
  počkají. Hlídá to zámek vázaný na databázové spojení (od 2.2.1), který server po pádu procesu
  uvolní sám — klíče `dbversion_session_lock` a `dbversion_legacy_lock_wait`
  ([03 — Zámek migrace](03-struktura-webu.md#zámek-migrace)).
- Proces, který při startu čeká na databázi nebo migruje, lze bezpečně ukončit signálem `SIGTERM`:
  start se přeruší mezi pokusy o připojení nebo mezi kroky migrace, rozběhnutý krok se vždy dokončí
  ([17 — Běh procesu enginu](17-nasazeni.md#běh-procesu-enginu)).

Podporované drivery: `mysql`/`mariadb` (`Libs::MyDBI::DRIVER::MySQL` — dvě spojení na pool:
čtecí s autocommit a zapisovací transakční) a `postgres` (`DRIVER::Postgre` — jedno spojení,
`schema`). Rozdíly dialektů (LIMIT/OFFSET, boolean) řeší engine; ve vlastním SQL je řeš podle
`$DBI->getDbDriver("db1")`.

### Šifrované spojení a volby DSN (`dsn_options`)

Engine skládá DSN z klíčů `database`, `host` a `port` (`dbi:mysql:dbname=…;host=…;port=…`, `dbi:Pg:…`).
Volitelný klíč **`dsn_options`** k němu připojí další volby ovladače oddělené středníkem — cokoli, co umí
`DBD::mysql` nebo `DBD::Pg`:

```perl
'db1' => {
    dbdriver    => "mysql",
    # … ostatní klíče beze změny
    dsn_options => "mysql_ssl=1",
},
```

| Příklad | Význam |
| --- | --- |
| `mysql_ssl=1` | MySQL/MariaDB: vždy TLS, bez ověření certifikátu serveru (server musí mít TLS zapnuté) |
| `mysql_ssl=1;mysql_ssl_ca_file=/cesta/ca.pem;mysql_ssl_verify_server_cert=1` | TLS s ověřením certifikátu a jména serveru podle dokumentace `DBD::mysql` — pro databázi mimo důvěryhodnou síť |
| `mysql_ssl=0` | nikdy TLS; vypne i automatický záložní pokus popsaný níže |
| `mysql_connect_timeout=5` | časový limit připojení v sekundách |
| `sslmode=require`, `connect_timeout=5` | PostgreSQL (parametry `libpq`) |

Bez `dsn_options` (výchozí stav) je DSN stejný jako ve starších verzích enginu a spojení **není šifrované**.
Výjimkou je MySQL 8 a novější: účty tam mají výchozí plugin `caching_sha2_password` a server plné ověření
hesla po nešifrovaném spojení odmítne (chyba 2061 `Authentication requires secure connection`). Ovladač
proto po této chybě pokus sám zopakuje s `mysql_ssl=1`. Server si ověřené heslo drží v paměti, takže další
spojení téhož účtu projdou i nešifrovaně (do restartu serveru nebo `FLUSH PRIVILEGES`) — které spojení poolu
je šifrované, tedy není dané předem. Kdo chce šifrovat vždy, nastaví `dsn_options => "mysql_ssl=1"`
(ověřeno i s MariaDB 13). MariaDB a MySQL s `mysql_native_password` chybu 2061 nevracejí a připojují se beze změny.

Když se připojit nepodaří, engine to zkouší `trayconnect`-krát po 1 s a do logu píše důvod:
`[E] … Connect to mysql dbid:db1 connect_status:0 error:<kód> <text chyby DBI>` (heslo v hlášce není).

## Nízkoúrovňové API (`$DBI`)

SQL se píše **bez úvodního klíčového slova** (doplní ho metoda), hodnoty přes placeholdery `?`.
Všechny metody pracují na **poolu 0** daného `dbid`.

```perl
# SELECT → DBI statement handle
my $SQL = $DBI->select("db1", "id, title FROM tasks WHERE done = ? ORDER BY created DESC", ['f']);
while (my $row = $SQL->fetchrow_hashref) { ... $row->{'title'} ... }
$SQL->finish;

# agregace jedním dotazem
my $SQL = $DBI->select("db1", "COUNT(*) AS total, SUM(CASE WHEN done = 't' THEN 1 ELSE 0 END) AS done FROM tasks", []);
my $stats = $SQL->fetchrow_hashref; $SQL->finish;

# INSERT / UPDATE / DELETE — zapisovací spojení je transakční: vždy commit nebo rollback
$DBI->insert("db1", "INTO tasks (title, done) VALUES (?, ?)", ["Nákup", 'f']);
my $id = $DBI->getLastInsertID("db1", "tasks");          # POZOR: před commit
my $n  = $DBI->update("db1", "tasks SET done = ? WHERE id = ?", ['t', $id]);   # počet řádků ("0E0" = žádný)
$DBI->delete("db1", "FROM tasks WHERE id = ?", [$id]);
if ($DBI->error("db1")) { $LOG->error($DBI->getErrorMsg("db1")); $DBI->rollback("db1"); }
else                    { $DBI->commit("db1"); }

# celý příkaz (DDL apod.)
$DBI->command("db1", "TRUNCATE TABLE cache");
```

| Metoda | Poznámka |
| --- | --- |
| `select($dbid, $sql, \@bind)` | vrací `$sth`; po přečtení zavolej `finish` |
| `insert`, `update`, `delete`, `command` | zápis; `update` vrací počet ovlivněných řádků |
| `getLastInsertID($dbid, $table)` | id posledního INSERTu — u transakčních spojení volat **před** `commit` |
| `commit($dbid)`, `rollback($dbid)` | transakce zapisovacího spojení poolu 0 |
| `error($dbid)`, `getError($dbid)`, `getErrorMsg($dbid)` | chyba poslední operace (1/0, hash `err/errstr/state`, text) |
| `getDbDriver($dbid)` | `mysql` / `mariadb` / `postgres` |
| `getDAOList($dbid)` | názvy tabulek z DAO mapy |
| `getDAO($dbid, $table, $id \| {where, conds})` | DAO objekt bez entity (viz níže) |

Při `log.loglevel >= 3` engine před každý dotaz vloží komentář s místem volání
(`/* DB:db1 Services/Tasks/Tasks.pm line 132 */`) — v DB logu je vidět, odkud dotaz přišel.

### Vlastní SQL: stránkování, hledání, náhodné pořadí

- **LIMIT/OFFSET** nedávej do placeholderu (`LIMIT ?` DBD::mysql ocituje jako řetězec) — hodnoty převeď `int()` a vlož
  do textu: `"… ORDER BY created DESC LIMIT " . int($limit) . " OFFSET " . int($offset)`. Zápis `LIMIT n OFFSET m`
  funguje v MariaDB/MySQL i Postgres.
- **Řazení z requestu** nikdy neinterpoluj přímo — mapuj povolené hodnoty na pevné SQL fragmenty
  (`my %order = (name => "name_cs ASC", price => "price ASC"); $order{$razeni} || $order{name}`).
- **Hledání LIKE**: escapuj `%`, `_` a `\` ve vstupu (`$q =~ s/([%_\\])/\\$1/g`), použij `LOWER(col) LIKE LOWER(?)`
  s hodnotou `"%$q%"` (Postgres rozlišuje velikost písmen, MySQL ne).
- **Náhodné pořadí**: `RAND()` (MySQL/MariaDB) vs `random()` (Postgres) — větvi podle `$DBI->getDbDriver($dbid)`.
- `$DBI->select` vrací statement handle i při chybě dotazu (nebo `undef`, když selže `prepare`) — po volání
  zkontroluj `$DBI->error($dbid)` (a `defined $SQL`) dřív, než začneš číst.

## Entity

Entita = třída pro jednu tabulku. Dědí z `Entities::Entity`, která drží DAO objekt a vše
nezachycené na něj deleguje. Entita přidává vlastní validaci sloupců a automatická časová
razítka.

### Definice

`Entities/Task/Task.pm` z tutoriálu (kostru vytvoří `make module TYPE=entity WEB=<web> NAME=Task ARGS='--table tasks'`):

```perl
package Entities::Task::Task;

use strict;
use base qw(Entities::Entity);

my ($CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB);

sub new {
    my ($class, $conf, $log, $validate, $dbi, $user, $web, $opts) = @_;

    $DBI = $dbi; $LOG = $log; $CONF = $conf; $USER = $user; $WEB = $web; $VALIDATE = $validate;

    my $self = new Entities::Entity($CONF, $LOG, $VALIDATE, $DBI, $USER, $WEB, "db1", "tasks", $opts);   # dbid, tabulka, $opts

    bless $self, $class;
    return $self;
}

# Vlastní validace sloupce: ořízne mezery, prázdný název odmítne
sub title {
    my $self = shift;
    if (@_) {
        my ($value) = @_;
        $value =~ s/^\s+|\s+$//g if (defined($value));
        unless (defined($value) and length($value)) {
            $self->SUPER::setErrorList("Invalid write data : column_name:title, value:empty");
            return undef;
        }
        return $self->SUPER::title($value);
    }
    return $self->SUPER::title();
}

sub KOMODO { return; ... }

1;
```

Tabulka `tasks` musí existovat (migrace), jinak se entita při startu nenačte (`Unknown DAO
MAP`). Loader `Libs::Entities` vytvoří jednu **sdílenou** instanci každé entity (pro validaci
a metadata); pro práci s daty se vytvářejí **nové instance**.

### Vytvoření instance

```perl
my $T = $ENTITIES->createEntityObject('Task');                                       # prázdný řádek → flush udělá INSERT
my $T = $ENTITIES->createEntityObject('Task', 42);                                   # podle primárního klíče
my $T = $ENTITIES->createEntityObject('Task', {where => "title = ?", conds => ["Nákup"]});   # podle podmínky (první řádek)
```

Pokud řádek neexistuje, objekt zůstane prázdný (do logu jde `info` „Couldn't load any row“) —
`$T->id` je `undef` a `flush` by provedl INSERT. Vzor „načti nebo založ“ tak nepotřebuje
zvláštní kód. Instance si půjčuje spojení z poolu a vrací ho při zániku — drž ji jen v lokální
proměnné, ne v atributu služby.

### Čtení a zápis

```perl
my $title = $T->title;                 # getter = název sloupce
$T->title("Nákup");                    # setter: validuje podle typu a délky sloupce (+ vlastní metoda entity)
$T->done('t');                         # ENUM: jen povolené hodnoty
my $data = $T->getMirroredData();      # { id => 1, title => ..., done => ..., created => ... } pro šablonu

my $id = $T->flush;                    # INSERT (bez PK) nebo UPDATE (s PK); vrací PK; undef při chybě
$T->logit;                             # zapíše do logu "INSERT DATA table:tasks id:1 title:Nákup(VARCHAR) ..." nebo chyby
if ($T->error) {                       # neplatná hodnota, duplicita, chyba DB
    $T->rollback;                      # vrátí transakci a vyčistí objekt
} else {
    $T->commit;                        # potvrdí; seznam změn se vyprázdní
}

$T->DELETE_ROW; $T->logit; $T->error ? $T->rollback : $T->commit;    # smazání podle PK
```

| Metoda | Účel |
| --- | --- |
| `<sloupec>()` / `<sloupec>($v)` | getter / setter s validací; neplatná hodnota → `undef` + chyba v objektu |
| `flush()` | zápis změněných sloupců; kontrola UNIQUE sloupců před zápisem |
| `commit()`, `rollback()` | transakce spojení entity |
| `error()` | 1, pokud je chyba (DB nebo validační) |
| `getErrorList()` | texty chyb; `existsUniqueError()` — šlo o duplicitu? |
| `logit($text)` | standardní log řádek o změně (volat po `flush`) |
| `DELETE_ROW()` | DELETE podle PK |
| `refreshTABLE($where, \@conds)` | znovu načíst řádek podle podmínky |
| `getMirroredData()` | hash všech sloupců |
| `getPrimaryValue()`, `getPrimaryColumnName()` | PK |
| `getChangeList()` | změněné sloupce od posledního načtení/commitu |
| `getValue($col, 'type'\|'size'\|'def'\|'null'\|'unique'\|'enumv')` | metadata sloupce |
| `setUniqueCheckValue(0)` | vypnout kontrolu unikátnosti při flush |
| `DAORef()` | podkladový DAO objekt |

Setter sám **nepadá** — zapíše chybu do objektu a vrátí `undef`; `flush` pak neproběhne a
`error()` je pravdivé. Hodnoty `'NULL'`, `undef` a `''` se zapisují jako `NULL` (resp. default
sloupce), `'NOW()'`/`'CURRENT_TIMESTAMP'` jako SQL výraz. Sloupec se nesmí jmenovat jako
metoda DAO (`flush`, `error`, `commit`, `select`, …) — konstruktor to odmítne.

### Na co si dát pozor u entit

- `error()` je pravdivé už po **neúspěšném setteru** (dřív než `flush`); po nastavení hodnot zkontroluj `error()` a
  při chybě udělej `rollback` — `flush` se s chybou v objektu stejně neprovede.
- `getErrorList()` vrací texty `"Invalid write data : column_name:<sloupec>, value:<hodnota>"` — služba z nich
  může odvodit klíč `error_validate__<sloupec>` pro messenger.
- `rollback()` objekt **resetuje** (hodnoty na defaulty, PK pryč). Při opakování zápisu (kolize UNIQUE, nové číslo
  objednávky) vytvoř novou instanci; `existsUniqueError()` volej před `rollback`.
- DAO validuje jen INT/TINYINT/VARCHAR/ENUM/DECIMAL/BOOLEAN; `TEXT`, `DATETIME`, `TIMESTAMP` projdou bez kontroly
  (`'NOW()'` je přípustná hodnota pro DATETIME).
- Metody `insert()`/`update()`/`delete()` entity jsou interní pro `flush` (insert přepíše PK objektu) — pro podřízené
  řádky použij vlastní entitu nebo `$DBI` na poolu 0.
- Více tabulek v jedné logické operaci (objednávka + položky) není jedna transakce — zapisuj hlavičku, pak položky, a
  při chybě položky kompenzačně smaž hlavičku, nebo použij `$DBI` na poolu 0 s jedním `commit`.

### Automatická časová razítka

`Entities::Entity::flush` před zápisem doplní sloupce, které uživatel sám nezměnil:
`updated` (TIMESTAMP s defaultem NULL) = `NOW()` při UPDATE, `created` (TIMESTAMP s defaultem)
= `NOW()` při INSERT, a každý sloupec s defaultem `CURRENT_TIMESTAMP`. Stačí tabulku
definovat jako v tutoriálu.

### Vlastní validace sloupce

Přepiš metodu sloupce (viz `title` výše). Vzor z enginu (`Entities/MailQueue`):

```perl
sub mailto {
    my $self = shift;
    if (@_) {
        my ($value) = @_;
        $value =~ s/.*<(.*)>.*/$1/;
        return ($VALIDATE->is_email($value) ? $self->SUPER::mailto(@_)
                                             : $self->SUPER::setErrorList("Invalid write data : column_name:mailto, value:$value"));
    }
    return $self->SUPER::mailto();
}
```

Stejná metoda se použije při deklarativní validaci stránky (`validate => [{entity =>
'Entities::Task', parameters => ['title']}]`) — pravidlo je tak na jednom místě pro formulář
i pro zápis.

### Sdílená instance

`$ENTITIES->getEntityObject('Task')` vrací sdílenou instanci nad poolem 0 — jen pro čtení
metadat (`getValue($col,'type')`, `getMethodList`) nebo validaci, **nikdy pro zápis**.

## DAO bez entity

Pro tabulku bez vlastní entity (např. číselník):

```perl
my $D = $DBI->getDAO("db1", "cities", 5);                                   # nebo {where => "code = ?", conds => ['PRG']} nebo nic
$D->name("Praha"); $D->flush; $D->error ? $D->rollback : $D->commit;
```

API je stejné jako u entity (entita na DAO deleguje), chybí jen vlastní validace a razítka.

## Transakce a pool spojení

- **Pool 0** je sdílené spojení pro `$DBI->select/insert/…`; `commit("db1")` potvrdí vše, co na
  něm v requestu proběhlo.
- Každá **entita** si půjčí vlastní spojení z poolu (`db_pool` kusů); její `commit` se týká
  jen jejího spojení. Při vyčerpaném poolu dostane pool 0 (zaloguje se varování).
- MySQL/MariaDB čtou přes zvláštní spojení s autocommitem, takže SELECT neotevírá transakci.
  Postgres má jedno spojení — po SELECTu bez zápisu není commit nutný, engine ho dělá sám tam,
  kde řádek načetl (session).
- Dvě entity, které mají být atomické, pracují na různých spojeních — pro skutečnou atomicitu
  použij `$DBI` na poolu 0 s jedním `commit`, nebo pořadí zápisů navrhni tak, aby dílčí selhání
  nevadilo.
- Při výpadku DB `testConnection` (každých `pwe.db_ping_interval` s) spojení obnoví; mezi pingy
  se výpadek projeví chybou dotazu (`error()`).

## Stránkované tabulky (`Services::DBTable`)

Služba `DBTable` (`core_services => ["DBTable"]`, entita a tabulka `dbtable`) vrátí z SQL dotazu
data pro stránkovanou, řaditelnou tabulku. Nastavení (řazení, strana, počet řádků) ukládá
do DB podle session a názvu tabulky, takže přežije další requesty.

```perl
sub Service_DBTable { my ($self, $input) = @_; $DBTABLE = $input; }

my $table = $DBTABLE->genTable(
    name        => 'tasks-list',                # klíč nastavení (se sid) = id elementu v HTML
    tmpl        => "Pages/ukoly/table.html",    # šablona tabulky — služba ji nerenderuje, jen vrací (pro ajax_tmpl)
    query       => "* FROM tasks WHERE done = ?",   # část za SELECT
    conditions  => ['f'],                       # bind hodnoty
    ordercolumn => "created",                   # výchozí řazení
    orderby     => "DESC",                      # ASC | DESC
    maxrow      => 10,                          # řádků na stránku (výchozí 40)
    # volitelně: dbid (db1), groupby ("GROUP BY col"), nlimit (čísel stránek, 10), gopage (1),
    #            page/func (cíl odkazů, výchozí aktuální), script, appendurl ("uid=5&tab=1"),
    #            reset (znovu nastaví dotaz/stranu), resetall (vše z %opt)
);
```

Vrácený hash (`$table`) obsahuje všechny sloupce `dbtable` plus:

| Klíč | Význam |
| --- | --- |
| `rows` | pole hashů = řádky aktuální stránky (`fetchrow_hashref`) |
| `rowcount`, `endpage`, `gopage` | celkem řádků, poslední strana, aktuální strana |
| `pagelist` | čísla stran pro stránkovací lištu |
| `maxrow`, `nlimit`, `ordercolumn`, `orderby` | aktuální nastavení |
| `name`, `id`, `tmpl`, `script`, `appendurl`, `appendmap` | identifikace a odkazy |
| `select` | výsledné SQL (ladění) |

Odkazy řazení a stránkování posílají parametry `tableid`, `gopage`, `ordercolumn`, `orderby`,
`maxrow`, `nlimit`, `reset`, `resetall`; služba je aplikuje jen na tabulku se shodným `tableid`.
Šablony enginu:

```
[% SET enable_ajax = 1 %]
<th>[% INCLUDE Services/DBTable/orderby.html thname = rb.th_title ordercolumn = "title" ajaxjson = "$enable_ajax" %]</th>
...
[% FOREACH t IN table.rows %] ... [% t.title | html %] ... [% END %]
...
[% IF table.endpage > 1 %][% INCLUDE Services/DBTable/pagination.html table = table ajaxjson = "$enable_ajax" %][% END %]
[% INCLUDE Services/DBTable/pager.html table = table %]          [% # jednoduché „zpět / další“ %]
```

AJAX překreslení jen tabulky (odkazy mají `ajaxjson=1`):

```perl
if ($USER->getParam("ajax_request", 0, undef)) {
    $WEB->printHttpHeader('type' => 'ajax');
    $WEB->printAjaxLayout(ajax_id => [$table->{'name'}], ajax_tmpl => [$table->{'tmpl'}], ajax_data => {table => $table});
} else {
    $WEB->printHttpHeader(); $WEB->printHtmlHeader();
    $WEB->printHtmlLayout(html_main => "Pages/ukoly/main.html", table => $table);
}
```

a v `main.html` obal `<div id="[% table.name %]">[% INCLUDE Pages/ukoly/table.html %]</div>`.
Šablona tabulky musí začínat `[% PROCESS templates/resource_bundle.tmpl %]`, protože se
renderuje i samostatně.

Poznámky k `genTable`:

- `ordercolumn` z requestu smí obsahovat jen `[A-Za-z0-9_-]` — u dotazů s JOIN sloupce **aliasuj**
  (`p.name_cs AS name_cs`) a řaď podle aliasu.
- Filtr (stav objednávky, kategorie) dej do **`name`** tabulky (`admin-orders-paid`) a do `appendurl`
  (`"stav=paid"`), jinak se uložená nastavení různých filtrů míchají a odkazy stránkování filtr ztratí.
- `query`/`conditions` se po prvním uložení pro danou session nemění bez `reset => 1` — dynamické podmínky
  (hledání) posílej vždy s `reset`.

Dvoukrokové API: `my $TO = $DBTABLE->genTableOptions(%opt);` (entita `DBTable` s nastavením —
lze upravit, např. `$TO->gopage(1)`) a `my $table = $DBTABLE->genTableData($TO);`. Dále
`getTableOptions($name)`, `existTableOptions($name)`, `resetTableOptions($name)`.

## Více databází a Postgres

- Druhá databáze = další klíč v `database.conf` (`db2`) a entity s `"db2"` v konstruktoru.
- Postgres: boolean sloupce přijímají `t/f`, `true/false`, `1/0` (DAO je převede); `schema`
  v konfiguraci; `getLastInsertID` potřebuje název tabulky (sekvence); ENUM typy DAO
  nevaliduje. SQL v `dbversion` piš pro každý driver zvlášť.

## Web bez databáze

Bez `database.conf` engine neotevře žádné spojení; entity a služby závislé na DB se nenačtou
(`core_services`/`core_entities` nech prázdné, `pwe.save_opt_to => "file"`). Data mezi requesty
drží `$USER->setOpts/getOpts` (soubor v `pwe.opts_dir`), obsah se bere ze šablon nebo souborů.
