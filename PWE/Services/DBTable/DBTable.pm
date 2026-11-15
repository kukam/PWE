package Services::DBTable::DBTable;

=head1 NAME

Services::DBTable::DBTable - generator strankovanych a raditelnych tabulek z SQL dotazu (genTable)

=head1 POPIS

    Nastaveni tabulky (razeni, strana, pocet radku, dotaz) se uklada do DB podle session a nazvu tabulky,
    takze prezije dalsi requesty. Sablony pagination.html / orderby.html / pager.html jsou v adresari sluzby.

=cut

use strict;
use JSON;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

=head2 B<[Public] new($conf,$log,$validate,$dbi,$entities,$user,$web)>

    Sluzba generatoru strankovanych/raditelnych tabulek z SQL dotazu. Nastaveni tabulky
    se uklada do DB (entita DBTable) podle session a nazvu tabulky, takze razeni a strankovani
    prezije dalsi requesty. Do stranky se injektuje metodou Service_DBTable.

=cut

sub new {
    my ($class, $conf, $log, $validate, $dbi, $entities, $user, $web) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $WEB      = $web;
    $CONF     = $conf;
    $USER     = $user;
    $VALIDATE = $validate;
    $ENTITIES = $entities;

    my $self = {};

    bless $self, $class;
    return $self;
}

=head2 B<[Public] genTable(%opt)>

    Generator strankovane a raditelne tabulky z SQL dotazu. Zkratka za
    genTableData(genTableOptions(%opt)): nastaveni tabulky nacte/ulozi do tabulky dbtable
    (podle id nebo name a sid aktualni session), provede dotaz a vrati data pro sablonu.

    # VSTUP
    my $table = $TABLE->genTable(
        id          => "id zaznamu v tabulce dbtable (alternativa k name)",
        name        => "nazev tabulky = klic zaznamu v dbtable (spolu se sid session)",
        dbid        => "id databaze z conf, def db1",
        page        => "page, ktera se vola pri razeni/strankovani, def aktualni page",
        func        => "func, ktera se vola pri razeni/strankovani, def aktualni func",
        script      => "cesta pred nazvem skriptu v odkazech, def '/' (nazev skriptu doplni getScriptName)",
        appendurl   => "retezec pripojeny k URL odkazu, napr. 'uid=5&tab=1'",
        tmpl        => "cesta k sablone tabulky; metoda ji nerenderuje, jen ji vraci v klici tmpl (pro ajax_tmpl)",
        query       => "cast dotazu za SELECT, napr. '* FROM tabulka WHERE active = ?'",
        conditions  => ['hodnoty pro placeholdery ? v query'],
        groupby     => "cely SQL fragment vcetne klicoveho slova, napr. 'GROUP BY sloupec1,sloupec2'",
        ordercolumn => "sloupec, podle ktereho se radi",
        orderby     => "smer razeni ASC/DESC, def ASC",
        maxrow      => "maximalni pocet radku na strance, def 40",
        nlimit      => "kolik cisel stranek se zobrazi ve strankovani pod tabulkou, def 10",
        gopage      => "stranka, na ktere se zacne, def 1",
        reset       => "1/0 znovu nastavi gopage, query, conditions, appendurl a groupby; razeni, maxrow a nlimit zustavaji",
        resetall    => "1/0 znovu nastavi vsechny hodnoty z %opt (jako by zaznam v dbtable neexistoval)",
    );

    Pokud neni zadano id ani name, hleda se zaznam podle parametru requestu tableid/tablename.
    Odkazy ve strankovani a razeni (sablony pagination.html, pager.html, orderby.html) posilaji
    parametry tableid, gopage, ordercolumn, orderby, maxrow, nlimit, reset a resetall; ty se
    aplikuji jen na tabulku, jejiz id se shoduje s tableid.

    # VYSTUP - hash se vsemi sloupci dbtable (id, name, tmpl, gopage, endpage, rowcount, ...)
    # doplneny o rows (pole hashu = radky vysledku), pagelist (cisla stranek pro strankovani),
    # select (vysledny SQL pro ladeni), conditions (pole) a appendmap (hash z appendurl).
    print Dumper($table);

=cut

sub genTable {
    my ($self, %opt) = @_;
    return $self->genTableData($self->genTableOptions(%opt));
}

=head2 B<[Public] genTableOptions(%opt)>

    Prvni krok genTable: z %opt (stejne klice jako u genTable), z ulozeneho zaznamu v dbtable
    a z parametru requestu (tableid, gopage, ordercolumn, orderby, maxrow, nlimit, reset,
    resetall) sestavi objekt nastaveni tabulky - entitu Entities::DBTable. Do DB zatim nic
    neuklada, to dela az genTableData.

    Hodi se, kdyz je potreba nastaveni jeste upravit v kodu pred provedenim dotazu
    (if je zde jen ukazka moznosti rozsireni logiky):

    my $TO = $TABLE->genTableOptions(%opt);    # stejne klice jako u genTable
    if ($TO->gopage() > 1) {
        $TO->gopage(5);
    }
    my $table = $TABLE->genTableData($TO);

=cut

sub genTableOptions {
    my ($self, %opt) = @_;

    # PARAMETERS
    my $sid             = $USER->getSid();
    my $optid           = $opt{'id'};
    my $optname         = $opt{'name'};
    my $optreset        = $opt{'reset'};
    my $optresetall     = $opt{'resetall'};
    my $optconditions   = $opt{'conditions'}; 
    my $paramid         = $USER->getParam("tableid");
    my $paramname       = $USER->getParam("tablename");
    my $paramreset      = $USER->getParam("reset",0,0);
    my $paramresetall   = $USER->getParam("resetall",0,0);

    my $page            = ($opt{'page'} ? $opt{'page'} : $USER->getValue("page", undef, "unknown"));
    my $func            = ($opt{'func'} ? $opt{'func'} : $USER->getValue("func", undef, "unknown"));
    my $script          = ($opt{'script'} ? $opt{'script'} : "/");
    my $scriptname      = $WEB->getScriptName();
    my $appendurl       = ($opt{'appendurl'} ? $opt{'appendurl'} : undef);
    my $name            = (defined($opt{'name'}) ? $opt{'name'} : undef);
    my $dbid            = (defined($opt{'dbid'}) ? $opt{'dbid'} : "db1");
    my $query           = (defined($opt{'query'}) ? $opt{'query'} : "");
    my $groupby         = ($opt{'groupby'} ? $opt{'groupby'} : "");
    my $tmpl            = ($opt{'tmpl'} ? $opt{'tmpl'} : undef);
    my $orderby         = ($opt{'orderby'} ? $opt{'orderby'} : "ASC");
    my $ordercolumn     = ($opt{'ordercolumn'} ? $opt{'ordercolumn'} : undef);
    my $gopage          = ($opt{'gopage'} ? $opt{'gopage'} : 1);
    my $maxrow          = ($opt{'maxrow'} ? $opt{'maxrow'} : 40);
    my $nlimit          = ($opt{'nlimit'} ? $opt{'nlimit'} : 10);
    my $reset           = ($optreset ? $optreset : $paramreset);
    my $resetall        = ($optresetall ? $optresetall : $paramresetall);
    
    # TABLE OBJECT
    my $TO = $self->getTableOptions(
        (
            defined($optid) ? $optid
            : (
                defined($optname) ? $optname
                : (
                    defined($paramid) ? $paramid
                    : (
                        defined($paramname) ? $paramname
                        : undef
                    )
                )
            )
        )
    );

    if (defined($TO->id()) and $reset) {

        $TO->gopage($gopage);
        $TO->query($query);
        $TO->conditions(((ref($optconditions) eq 'ARRAY') ? to_json($optconditions, { 'utf8' => 1, 'pretty' => 0}) : '[]'));
        $TO->appendurl($appendurl ? $appendurl : "");
        $TO->groupby($groupby);
        $TO->rowcount(undef);

    } elsif (!defined($TO->id()) or (defined($TO->id()) and $resetall)) {

        $TO->sid($sid);
        $TO->name($name);
        $TO->page($page);
        $TO->func($func);
        $TO->script($script.$scriptname."?page=".$page."\&func=".$func);
        $TO->appendurl($appendurl ? $appendurl : "");
        $TO->conditions(((ref($optconditions) eq 'ARRAY') ? to_json($optconditions, { 'utf8' => 1, 'pretty' => 0}) : '[]'));
        $TO->dbid($dbid);
        $TO->query($query);
        $TO->groupby($groupby);
        $TO->tmpl($tmpl);
        $TO->gopage($gopage);
        $TO->maxrow($maxrow);
        $TO->nlimit($nlimit);
        $TO->orderby($orderby);
        $TO->ordercolumn($ordercolumn);
        $TO->rowcount(undef);

    }

    if(defined($paramid) and ($TO->id() eq $paramid)) {

        # PRESUNEME SE NA STRANKU 1, POKUD DOSLO KE ZMENE MAX. POCTU RADKU TRIDENI ATD.
        # (zmena = parametr prisel a lisi se od ulozene hodnoty)
        my $changed = sub {
            my ($name) = @_;
            my $new = $USER->getParam($name, 0, undef);
            my $old = $TO->$name();
            return 0 unless (defined($new) and length($new));
            return ((defined($old) ? $old : "") ne $new) ? 1 : 0;
        };
        if ($changed->("maxrow") or $changed->("nlimit") or $changed->("ordercolumn") or $changed->("orderby")) { $TO->gopage(1); }

        # SETNEME ZMENY POZADOVANE UZIVATELEM
        $TO->orderby("$1")          if ($USER->getParam("orderby")     =~ /^(ASC)$/);
        $TO->orderby("$1")          if ($USER->getParam("orderby")     =~ /^(DESC)$/);
        $TO->ordercolumn("$1")      if ($USER->getParam("ordercolumn") =~ /^([a-zA-Z0-9_\-]+)$/);
        $TO->gopage("$1")           if ($USER->getParam("gopage")      =~ /^(\d+)$/);
        $TO->maxrow("$1")           if ($USER->getParam("maxrow")      =~ /^(\d+)$/);
        $TO->nlimit("$1")           if ($USER->getParam("nlimit")      =~ /^(\d+)$/);

        $TO->appendurl($appendurl ? $appendurl : $TO->appendurl());

    } 

    return $TO;
}

=head2 B<[Public] genTableData($TO)>

    Druhy krok genTable. $TO je entita Entities::DBTable z genTableOptions. Metoda zjisti
    celkovy pocet radku dotazu (rowcount) a pocet stran (endpage), nastaveni tabulky ulozi
    do dbtable (flush + commit) a provede vlastni SELECT s ORDER BY a LIMIT/OFFSET pro
    aktualni stranku (podporuje mysql/mariadb a postgres).

    Vraci hash s hodnotami vsech sloupcu dbtable doplneny o klice, ktere se do DB neukladaji:
    rows (pole hashu = radky vysledku), pagelist (cisla stranek z genTablePageList),
    select (vysledny SQL pro ladeni), conditions (pole misto JSON ulozeneho v DB)
    a appendmap (hash klic => hodnota rozparsovany z appendurl).

=cut

sub genTableData {
    my ($self, $TO) = @_;

    # CONDITIONS
    my $conditions = from_json($TO->conditions());

    # ZJISTIME SI MAX.POCET RADKU
    my $SQL = $DBI->select($TO->dbid(), "count(*) FROM (SELECT " . $TO->query() . " " . $TO->groupby() . ") mytemptablename", $conditions);
    $TO->rowcount($SQL->fetchrow_array());
    $SQL->finish;

    # ZAPISEME PAGELIST (moznost listovani)
    $TO->endpage(sprintf("%.0f", (($TO->rowcount() / $TO->maxrow()) + 0.4999999999)));

    # ULOZENI PARAMETRU TABULKY DO DB
    my $tableid = $TO->flush();
    $TO->commit();

    # MIRROROVANA DATA SE POUZIVAJI PRO DALSI PRACI V KODU
    my $mirrorTO = $TO->getMirroredData();

    # SELECT
    my $select = "";
    if (($DBI->getDbDriver($TO->dbid()) eq "mysql") or ($DBI->getDbDriver($TO->dbid()) eq "mariadb")) {
        $select = $mirrorTO->{'query'} . " " . $mirrorTO->{'groupby'} . " " . ($mirrorTO->{'ordercolumn'} ? "ORDER BY " . $mirrorTO->{'ordercolumn'} . " " . $mirrorTO->{'orderby'} : "") . " LIMIT " . ($mirrorTO->{'maxrow'} * ($mirrorTO->{'gopage'} - 1)) . "," . $mirrorTO->{'maxrow'};
    } elsif ($DBI->getDbDriver($TO->dbid()) eq "postgres") {
        $select = $mirrorTO->{'query'} . " " . $mirrorTO->{'groupby'} . " " . ($mirrorTO->{'ordercolumn'} ? "ORDER BY " . $mirrorTO->{'ordercolumn'} . " " . $mirrorTO->{'orderby'} : "") . " LIMIT " . $mirrorTO->{'maxrow'} . " OFFSET " . ($mirrorTO->{'maxrow'} * ($mirrorTO->{'gopage'} - 1));
    }

    #######################################
    ### TYTO DATA NEJSOU UKLADANA DO DB ###
    #######################################
    # NASYPEME OBSAH TABULKY DO ATRIBUTU 'rows'
    $mirrorTO->{'rows'} = [];
    my $SQL1 = $DBI->select($TO->dbid(), $select, $conditions);
    while (my $row = $SQL1->fetchrow_hashref) { push(@{$mirrorTO->{'rows'}}, $row); }
    $SQL1->finish;

    # POLE PRO SPRAVNE SESTROJENI PAGOVACIHO MECHANIZMU
    $mirrorTO->{'pagelist'} = $self->genTablePageList($mirrorTO->{'gopage'}, $mirrorTO->{'endpage'}, $mirrorTO->{'nlimit'});

    # PRO DEBUG ZAPISUJEME JESTE POHLED NA FINALNI SELECT KTERY SE PROVEDL
    $mirrorTO->{'select'} = $select;

    # CONDITIONS VRACIME V KLASICKEM POLI, NE JAKO DATA KTERA JSOU V DB (JSON)
    $mirrorTO->{'conditions'} = $conditions;

    # Vytvorime jednoduchou hash mapu appendru
    foreach my $url (split('&', $mirrorTO->{'appendurl'})) {
        my ($key, $value) = split('=', $url);
        $mirrorTO->{'appendmap'}->{$key} = $value;
    }
    
    # VRATIME DATA, PRO DALSI ZPRACOVANI
    return $mirrorTO;
}

=head2 B<[Private] genTablePageList($gopage,$endpage,$nlimit)>

    Vygeneruje pole cisel stranek, ktera se zobrazi ve strankovani pod tabulkou.
    $gopage  = aktualni stranka (neplatna hodnota se bere jako 1, vetsi nez $endpage jako $endpage),
    $endpage = celkovy pocet stran,
    $nlimit  = kolik cisel stranek se ma zobrazit (delka bloku).
    Vraci referenci na pole cisel od (start - 1) do (start + $nlimit), kde
    start = int($gopage / $nlimit) * $nlimit; cisla mensi nez 1 nebo vetsi nez $endpage se vynechaji.

=cut

sub genTablePageList {
    my ($self, $gopage, $endpage, $nlimit) = @_;

    $gopage  = 1        if ($gopage !~ /^\d+$/);
    $endpage = 1        if (!$endpage);
    $nlimit  = 1        if (!$nlimit);
    $gopage  = $endpage if ($gopage > $endpage);

    my $start = int($gopage / $nlimit) * $nlimit;
    my $end   = ($start + $nlimit) + 1;

    my @return;
    for (my $i = ($start > 1 ? $start - 1 : 1); $i < $end; $i++) {
        last if ($i > $endpage);
        push(@return, $i);
    }

    return \@return;
}

=head2 B<[Public] getTableOptions($id|$tablename)>

    Vraci objekt nastaveni tabulky (entita Entities::DBTable). Ciselny argument se hleda
    jako id, jiny neprazdny retezec jako name - vzdy spolu se sid aktualni session.
    Bez argumentu (nebo pokud zaznam neexistuje) vraci prazdnou entitu, kterou flush ulozi
    jako novy radek.

=cut

sub getTableOptions {
    my ($self, $ident) = @_;

    my $sid = $USER->getSid();

    if ($ident =~ /^\d+$/) {
        return $ENTITIES->createEntityObject('DBTable', {where => "id = ? AND sid = ?", conds => [$ident, $sid]});
    } elsif ($ident) {
        return $ENTITIES->createEntityObject('DBTable', {where => "name = ? AND sid = ?", conds => [$ident, $sid]});
    } else {
        return $ENTITIES->createEntityObject('DBTable');
    }
}

=head2 B<[Public] resetTableOptions($id|$tablename)>

    Smaze ulozene nastaveni tabulky z dbtable (db1) podle id (ciselny argument) nebo name,
    vzdy jen pro sid aktualni session. Pri dalsim genTable se nastaveni zalozi znovu z %opt.
    Bez argumentu neudela nic. Nic nevraci.

=cut

sub resetTableOptions {
    my ($self, $ident) = @_;
    my $sid = $USER->getSid();
    if ($ident =~ /^\d+$/) {
        my $SQL = $DBI->delete("db1", "FROM dbtable WHERE id = ? AND sid = ?", [$ident, $sid]);
        $SQL->finish;
    } elsif ($ident) {
        my $SQL = $DBI->delete("db1", "FROM dbtable WHERE name = ? AND sid = ?", [$ident, $sid]);
        $SQL->finish;
    }
}

=head2 B<[Public] existTableOptions($id|$tablename)>

    Vraci 1, pokud v dbtable existuje nastaveni tabulky pro zadane id (ciselny argument)
    nebo name a sid aktualni session; jinak undef.

=cut

sub existTableOptions {
    my ($self, $ident) = @_;
    my $sid    = $USER->getSid();
    my $select = "";
    if ($ident =~ /^\d+$/) {
        $select = "1 FROM dbtable WHERE id = ? AND sid = ?";
    } elsif ($ident) {
        $select = "1 FROM dbtable WHERE name = ? AND sid = ?";
    } else {
        return undef;
    }
    my $SQL = $DBI->select("db1", $select, [$ident, $sid]);
    my $result = $SQL->fetchrow_array();
    $SQL->finish;
    return $result;
}

=head2 B<[Private] KOMODO()>

    Mrtvy kod pro IDE (Komodo/VS Code), aby umelo doplnit typy globalnich promennych.
    Nikdy se nevola - prvni prikaz je return.

=cut

# KOMODO-IDE/KOMODO-EDIT
sub KOMODO {
    return;
    require Libs::Config;
    require Libs::Log;
    require Libs::Validate;
    require Libs::DBI;
    require Libs::Entities;
    require Libs::User;
    require Libs::Web;

    $CONF     = new Libs::Config;
    $LOG      = new Libs::Log;
    $VALIDATE = new Libs::Validate;
    $DBI      = new Libs::DBI;
    $ENTITIES = new Libs::Entities;
    $USER     = new Libs::User;
    $WEB      = new Libs::Web;
}

1;
