package Services::DBTable::DBTable;

use strict;
use JSON;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

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

    Generator tabulky

    # VSTUP
    my $table = genTable(
        id => "vazba v tabulce dbtable",
        name => "vazba v tabulce dbtable",
        sid => "Cookie ID",
        page => "muzeme ovlivnit jaka page se bude volat pri sortovani/pagovani",
        func => "muzeme ovlivnit jaka funkce se bude volat pri sortovani/pagovani",
        tmpl => "pokud je zadana templejta pak se vraci jiz vytvorene html, ne jen data",
        query => "* FROM tabulka",
        conditions => ['podminka1'],
        ordercolumn => "jmeno sloupce, ktery setridime",
        orderby => "typ trideni ASC,DESC, def ASC",
        groupby => "jmeno sloupce(u) podle kterych budeme grupovat (jmena sloupcu odeluj carkou)",
        maxrow => "maximalni pocet radku v tabulce, def 40",
        nlimit => "kolik cisel se zobrazi v retezci pro strankovani def 10 (strankovani pod tabulkou)",
        script => "jmeno skriptu, def pwe.fcgi",
        appendurl => "pripojit do url tento string",
        gopage => "na ktere strance zacneme, def 1",
        resetall => "1/0 resetovat vsechny hodnoty, stejny ucinek jako zavolani metody $self->resetTableOptions(id | tablename)", 
        reset => "1/0 reset hodnot query,conditions,groupby ostatni zustava jak je nastaveno",
    );

    # VYSTUP
    print Dumper($table);	

=cut

sub genTable {
    my ($self, %opt) = @_;
    return $self->genTableData($self->genTableOptions(%opt));
}

=head2 B<[Public] genTableOptions(%opt)>

    S metodou se zachazi stejne jako s genTable, jen stim rozdilem,
    ze muzeme jeste v kodu pracovat s nastavovanim parametru.

    Ukazka rozireni prace s tabulkou, if je zde jen jako ukazka moznosti rozsireni logiky:

    my $TO = $self->genTableOptions({stejne_opts_jako_u_metody_genTable});
    if($TO->gopage() > 1) {
        $TO->gopage(5);
    }
    return $self->genTableData($TO);

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
        if (
            ($USER->existParam("maxrow") ne $TO->maxrow())
            or ($USER->existParam("nlimit") ne $TO->nlimit())
            or ($USER->existParam("ordercolumn") ne $TO->ordercolumn())
            or ($USER->existParam("orderby") ne $TO->orderby())
        ) { $TO->gopage(1); }

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

=head2 B<[Public] genTableData(%opt)>

    Precti si navod k metode genTableOptions pro spravne pochopeni zachazeni s touto metodou.

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
    if ($DBI->getDbDriver($TO->dbid()) eq "MySQL") {
        $select = $mirrorTO->{'query'} . " " . $mirrorTO->{'groupby'} . " " . ($mirrorTO->{'ordercolumn'} ? "ORDER BY " . $mirrorTO->{'ordercolumn'} . " " . $mirrorTO->{'orderby'} : "") . " LIMIT " . ($mirrorTO->{'maxrow'} * ($mirrorTO->{'gopage'} - 1)) . "," . $mirrorTO->{'maxrow'};
    } elsif ($DBI->getDbDriver($TO->dbid()) eq "Postgres") {
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

    Metoda vygeneruje pole obsahujici cislice ktere pouzijeme pro listovani stran.
    $gopage = aktualni stranka na ktere stojime,
    $endpage = max mozny pocet stran,
    $nlimit = jak dlohuy ma byt retezec.

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

    Metoda vraci objekt pro tableoptions, hleda se podle klice $id nebo $tablename

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

    Reset celeho nastaveni.

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

    Metoda vraci informaci o tom zdali existuji data k zadanemu id.

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
