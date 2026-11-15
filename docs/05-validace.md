# 05 — Validace vstupů

PWE validuje vstupy **deklarativně**: stránka v konstruktoru popíše, co má být vyplněno,
jakého tvaru to má být a co má existovat v databázi. Engine (`Libs::Pages::checkInputData`)
to zkontroluje **před** zavoláním akce. Při chybě sestaví pole klíčů chyb a zavolá metodu
z `$self->{'error'}->{<akce>}` (nebo akci samotnou s polem chyb). Klíče se v šabloně flash
zprávy přeloží z resource bundle (`rb.msg.<klíč>`).

Pořadí vrstev je pevné; běh se zastaví na první, která vrátí chyby:

```
replace → defined → validate → rules → exist → unique
```

Každý atribut je hash klíčovaný **názvem akce**. Nevyplněné parametry se (kromě `defined`)
přeskakují — povinnost řeší `defined`.

## `defined` — povinné parametry

```perl
$self->{'defined'}->{'add'} = {parameters => ['title']};

$self->{'defined'}->{'profil'} = {
    parameters => ['surname||firm', 'email', 'if[customer="C"]ico'],   # || = stačí jeden; if[p="v"]x = x povinné jen když p == v
    different => {                                                      # vnořená podmínka: kontroluje se jen když přišel parametr 'different'
        prefix     => "different_",                                     # předřadí se všem parametrům uvnitř
        parameters => ['surname||firm', 'town'],
    },
};
```

Chyba: `error_exist__<prefix><parametr>` (u `a||b` pod prvním z nich). Kontroluje se
`$USER->isdefinedParam` — parametr musí přijít a nesmí být prázdný řetězec.

## `validate` — kontrola hodnot entitou

Hodnotu nechá zkontrolovat **metodou sloupce entity** — tedy stejnou validací, jakou by prošla
při zápisu do DB (typ a délka sloupce z DAO mapy + vlastní settery entity).

```perl
$self->{'validate'}->{'add'} = [
    {
        entity     => 'Entities::Task',
        parameters => ['title', 'note'],            # název parametru = název sloupce
    },
    {
        entity     => 'Entities::User',
        parameters => ['useremail#email'],           # parametr#sloupec, když se názvy liší
        prefix     => "u_",
    },
];
```

Chyba: `error_validate__<parametr>`. V tutoriálu entita `Task` přepisuje setter `title`
(ořízne mezery, prázdný název odmítne) — validace to tak hlídá na jednom místě pro formulář
i pro zápis ([09 — Databáze a entity](09-databaze-a-entity.md#vlastní-validace-sloupce)).

## `rules` — pravidla nad parametry

Nejflexibilnější vrstva. Pro každý parametr pole pravidel; pravidlo je pole
`[ <metoda>, <klíč chyby>, 'parameter', <další argumenty> ]`. Řetězec `'parameter'` na
3. pozici engine nahradí hodnotou parametru (neměnit).

```perl
$self->{'rules'}->{'setlanguage'}->{'lang'} = [['is_language', 'error_language', 'parameter']];

$self->{'rules'}->{'toggle'}->{'id'}   = [['Services::Tasks::is_task_id', 'error_task_id', 'parameter']];
$self->{'rules'}->{'toggle'}->{'done'} = [['is_regx', 'error_done', 'parameter', qr/^[tf]$/]];

$self->{'rules'}->{'form'}->{'vek'} = [
    ['is_integer', 'error_vek_typ',    'parameter'],
    ['is_between', 'error_vek_rozsah', 'parameter', 18, 120],
];
```

Metoda se hledá podle prefixu:

| Zápis | Volá se |
| --- | --- |
| `is_email` (bez prefixu) | `$VALIDATE->is_email($hodnota, …)` — `Libs::Validate` |
| `Services::Tasks::is_task_id` | metoda služby `Tasks` |
| `Entities::Task::title` | setter sloupce entity (jako `validate`) |
| `Pages::jina::metoda` | metoda jiné (nebo téže) stránky |

Validátor vrací **definovanou hodnotu = OK, `undef` = chyba**. Při prvním neúspěšném pravidle
se zapamatuje jeho klíč a přejde se na další parametr. Vícehodnotové parametry se kontrolují
hodnota po hodnotě.

## `exist` — (ne)existence hodnoty v DB

```perl
$self->{'exist'}->{'register'} = [
    {
        entity     => 'Entities::User',
        parameters => ['login', 'useremail#email'],
        exist      => 1,    # 1 = chyba, když hodnota v DB existuje (error_exist__<p>); 0 = chyba, když neexistuje (error_not_exist__<p>)
    },
];
```

Hodnota se nejdřív protáhne setterem sloupce entity a pak dotazem `SELECT 1 FROM <tabulka>
WHERE <sloupec> = ?` přes DAO entity.

## `unique` — unikátnost v DB

```perl
$self->{'unique'}->{'save'} = [
    {
        entity     => 'Entities::User',
        primary    => 'uid',                        # parametr s primárním klíčem (při INSERT chybí → kontroluje se jako nový řádek)
        parameters => ['login', 'email'],
    },
];
```

Chyba: `error_validate_unique__<parametr>` při duplicitě, `error_validate__<parametr>` při
neplatné hodnotě. Při UPDATE se vlastní řádek (`primary`) z kontroly vynechá.

## `replace` — úprava vstupu před zpracováním

Protáhne hodnoty transformačními metodami a výsledek **zapíše zpět** do `$USER` — další
vrstvy i akce už pracují s upravenou hodnotou.

```perl
$self->{'replace'}->{'form'} = {
    '*ALL*' => ['escape_jsinjection'],            # všechny parametry: & < > → HTML entity
    'psc'   => ['Entities::Adresa::split_psc'],   # konkrétní parametr metodou entity
    'tel'   => ['escape_jsinjection', 'Services::Kontakty::normalize_phone'],
};
```

Stejné směrování metod jako u `rules`. Pád metody přidá chybu `InternalError_<metoda>`.

## Jak engine pravidla vyhodnocuje

- Validátor dostane hodnotu jako **druhý argument**: metoda služby/stránky má signaturu `($self, $value, @dalsi)`,
  kde `@dalsi` jsou argumenty za `'parameter'` v pravidle (`['is_between', 'err', 'parameter', 1, 99]` →
  `is_between($value, 1, 99)`; hranice jsou včetně).
- Pravidla (`rules`) se spouštějí **jen pro vyplněné parametry** — nepovinné pole stačí dát do `rules` bez `defined`.
  Povinnost řeší `defined`.
- Zástupné místo `'parameter'` na 3. pozici engine při každém requestu přepíše hodnotou (`splice`), tedy
  **pozice 2 pravidla patří enginu** — nikdy do ní nedávej vlastní argument a pravidla za běhu neměň. Jeden
  arrayref pravidla lze sdílet mezi více akcemi (např. CSRF).
- Validátor stránky (`Pages::X::metoda`) smí číst další parametry přes `$USER->getParam` — tak se dělá kontrola
  shody hesel:

```perl
$self->{'rules'}->{'register'}->{'password2'} = [['Pages::ucet::is_password2', 'error_password2', 'parameter']];

sub is_password2 {
    my ($self, $value) = @_;
    return (defined($value) and $value eq $USER->getParam("password", 0, "")) ? 1 : undef;
}
```

- Chybová metoda akci znovu vykresluje — pokud `default()` čte nepovinné parametry (filtr, stránka), musí si je
  sama očistit (neprošly validací, když byly prázdné nebo když `default` pravidla nemá).

## Chybová metoda

```perl
sub error {
    my ($self, $error) = @_;                       # $error = ['error_exist__title', 'error_validate__note', ...]

    $WEB->setMessenger("Pages/ukoly/msg.html", msg_error => $error);
    return 400 if ($USER->getParam("ajax_request", 0, undef));   # AJAX: klient vyzvedne messenger z chybové stránky
    $self->default();                                            # klasicky: znovu vykreslit stránku
}
```

Texty klíčů patří do `rb.tmpl` stránky:

```
[% SET rb.msg.error_exist__title = "Vyplňte název úkolu." %]
[% SET rb.msg.error_validate__title = "Název úkolu je prázdný nebo delší než 128 znaků." %]
[% SET rb.msg.error_task_id = "Úkol neexistuje." %]
```

Chybějící překlad se zobrazí jako `[msg.<klíč>]` — snadno se tak najde.

> Validační chyby engine loguje úrovní `[E]` (`Not-defined input parameter`, `Invalid rule`,
> `Invalid input parameter`). Jsou to chyby vstupu uživatele, ne pád enginu.

## Vestavěné validátory (`Libs::Validate`)

Volání z kódu: `$VALIDATE->is_email($v)` (vrací hodnotu nebo `undef`), nebo kontraktem pravidla
`$VALIDATE->validate(['is_email', 'error_email', $v])` (vrací `undef` při úspěchu, jinak klíč chyby).

| Validátor | Kontroluje |
| --- | --- |
| `is_email($v)` | e-mailová adresa (RFC 822 + rozumný tvar, TLD ≥ 2 znaky) |
| `is_language($v)` | jazyk z `http.languages` |
| `is_regx($v, $re)`, `isnot_regx($v, $re)` | odpovídá / neodpovídá regulárnímu výrazu (`qr//` nebo řetězec) |
| `is_percent($v)` | číslo s volitelným `%` |
| `is_md5hex($v)` | hex řetězec |
| `is_zipcode($null, $v)` | 5 číslic — **pozor na pořadí argumentů**, hodí se jen z entit |
| `validate_decimal_vat($v)` | sazba DPH jako koeficient (1.21) proti `web.access_vat` |
| `escape_jsinjection($v)` | pro `replace`: nahradí `& < >` entitami |
| `is_integer`, `is_numeric`, `is_hex`, `is_oct` | typ čísla (`Data::Validate`) |
| `is_between($v,$min,$max)`, `is_greater_than($v,$n)`, `is_less_than($v,$n)`, `is_equal_to($v,$x)` | rozsahy a rovnost |
| `is_even`, `is_odd`, `is_alphanumeric`, `is_printable` | další z `Data::Validate` |
| `is_int`, `is_tinyint`, `is_smallint`, `is_mediumint`, `is_bigint`, `is_float`, `is_double`, `is_decimal`, `is_char`, `is_varchar`, `is_enum`, `is_boolean`, `is_bit`, `is_binary`, `is_varbinary`, `is_tinyblob` | typy MySQL (`Data::Validate::MySQL`; signatury podle této knihovny) |
| `is_sql_int($driver,$v,$unsigned)`, `is_sql_tinyint`, `is_sql_varchar($driver,$v,$size)`, `is_sql_enum($driver,$v,\@values)`, `is_sql_decimal($driver,$v,$precision,$scale)`, `is_sql_boolean($driver,$v)` | typy podle DB driveru (používá DAO při zápisu) |

Neexistující validátor v `rules` → `Libs::Validate::AUTOLOAD` zaloguje chybu, pošle report a
`die` → 500. Překlep se tak projeví hned.

## Vlastní validátor

Nejčistší je metoda **služby** (má přístup k DB i konfiguraci) nebo **setter entity**:

```perl
# Services/Tasks/Tasks.pm — vrací $id při úspěchu, undef při chybě
sub is_task_id {
    my ($self, $id) = @_;
    return undef unless (defined($id) and $id =~ /^\d+$/);
    my $T = $ENTITIES->createEntityObject('Task', $id);
    return ($T->id ? $id : undef);
}
```

a v pravidle `['Services::Tasks::is_task_id', 'error_task_id', 'parameter']`. Validátor smí
dostat další argumenty (`'parameter', 1, 100`) — přijdou za hodnotou.

## Co validace neřeší

- **Escapování výstupu.** Hodnoty od uživatele vypisuj v šablonách přes filtr `| html`
  (`[% t.title | html %]`), nebo je nech upravit `replace => escape_jsinjection`.
- **Soubory.** Upload kontroluj po `saveUploadFile` (přípona, velikost přes `cgi_maxfilesize`).
- **Business pravidla** (např. „úkol nelze smazat, je-li hotový“) patří do služby, která vrátí
  `undef`, a akce nastaví messenger s vlastním klíčem.
