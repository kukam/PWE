package Libs::GoogleGraph;

use strict;

=head1 NAME

GoogleGrap.pm - Generator Google Grafu.

=head1 CONSTRUCTOR

    use LibsPerl::GoogleGrap;

    my $self = new LibsPerl::GoogleGrap( grid => "2,8");

    $self->SetOsa(name => 'x', data => ['1.1.2009', '2.2.2009', '3.4.2009', '7.7.2009'], tmpl => "", maxc => 5);
    $self->SetOsa(name => 'y', data => [], tmpl => "[**] kc" ); # TATO OSA SE AUTOMATICKY DOPOCITA PODLE VLOZENYCH DAT
    $self->SetOsa(name => 'r', data => [], tmpl => "kc [**]", maxc => 10); # TOTEZ CO U OSY 'y'

    $self->SetLine(color => "FF9900", data => ['-20', '123','230','310','123','234','400','300','212','218',115,180]);
    $self->SetLine(color => "FF99AD", data => ['-40','-20', '133','122','273','214','333','215']);
    $self->SetLine(color => "A9A9A9", data => ['400','400','320','-10','10','120']);

=head1 METODS

=cut

=head2 B<SetOsa(%opts)>
    
    TODO dopsat popis konstrukce obj.

=cut

sub new {
    my ($class, %opts) = @_;
    my $self = {

        # OPTION ATRIBUT
        link     => ($opts{'link'}     ? $opts{'link'}     : "http://chart.apis.google.com/chart?"),
        type     => ($opts{'type'}     ? $opts{'type'}     : "lc"),
        height   => ($opts{'height'}   ? $opts{'height'}   : "300"),
        width    => ($opts{'width'}    ? $opts{'width'}    : "600"),
        bgcolor  => ($opts{'bgcolor'}  ? $opts{'bgcolor'}  : "FFFFFF"),
        defcolor => ($opts{'defcolor'} ? $opts{'defcolor'} : "000000"),
        grid     => ($opts{'grid'}     ? $opts{'grid'}     : "1,5"),                                   # vzhled mrizky : prvni hodnota = delka vyplnene cary, druha hodnota = delka mezery
        shorten  => ($opts{'schorten'} ? $opts{'schorten'} : 0),                                       # Zaokrouhovat hodnoty na kolik desetinych mist
                                                                                                       # WORK ATRIBUT
        osaname  => [],
        osadata  => [],
        data     => [],
        minvalue => 9999999999999999999999999999,
        maxvalue => '-999999999999999999999999999',
        chds => [],                                                                                    # Minimalni a Maximalni hodnota dat
    };
    bless $self, $class;
    return $self;
}

=head2 B<SetOsa(%opts)>

    Metoda zapise nastaveni osy
    maxc 5 = pocet zobrazenych bodu na ose
         Default = automat, pocet bodu se upravi v zavislosti na sirce a vysce grafu

    $opts = {
    name => "Jmeno osy (x,y,r)"
    tmpl => " text [%%]"
    data => [ data ]
    maxc => 10
    }

=cut

sub SetOsa {
    my ($self, %opts) = @_;

    # GET
    my $name = $opts{'name'};
    my $data = $opts{'data'};
    my $tmpl = $opts{'tmpl'};
    my $maxv = $opts{'maxv'};

    # SET
    push(@{$self->{'osaname'}}, $name);
    push(@{$self->{'osadata'}}, $data);
    push(@{$self->{'osamaxv'}}, $maxv);
    push(@{$self->{'osatmpl'}}, $tmpl);
}

=head2 B<SetLink(%opts)>

    Metoda zapise data barvu a jine vlastnosti krivy,sloupce,kolace atd.

    $opts = {
    color => "HEX KEY COLOR"
    data => [ data ]
    }

=cut

sub SetLine {
    my ($self, %opts) = @_;

    # GET data
    my $color = $opts{'color'};
    my $data  = $opts{'data'};

    # SET
    push(@{$self->{'colorline'}}, ($color ? $color : $self->{'defcolorline'}));
    push(@{$self->{'data'}}, $data);
    $self->SetMinValue($data);    # min value
    $self->SetMaxValue($data);    # max value
}

=head2 B<GetLink()>

    Metoda vraci vygenerovany link

=cut

sub GetLink {
    my $self = shift;

    my @link;

    push(@link, "$self->{'link'}");
    push(@link, "chs=$self->{'width'}x$self->{'height'}");
    push(@link, "cht=$self->{'type'}");
    push(@link, "chco=" . join(",", @{$self->{'colorline'}}));
    push(@link, "chxt=" . join(",", @{$self->{'osaname'}}));

    # GENERATE OSA
    if ($self->{'type'} eq "lc") {
        push(@link, "chxl=" . $self->GetCHXL_LC());
    } else {
        return "UNKNOWN_CHT=$self->{'type'}";
    }

    push(@link, "chd=t:" . $self->GetCHD());                       # DATA
    push(@link, "chg=10,10,$self->{'grid'}");
    push(@link, "chds=$self->{'minvalue'},$self->{'maxvalue'}");

    return join("&amp;", @link);
}

# Metoda pro vytvoreni osy x,y,r pro graf ve formatu LC
sub GetCHXL_LC {
    my $self = shift;

    my $c = 0;
    my $r = "";

    foreach my $a (@{$self->{'osadata'}}) {

        my @adata;

        # CREATE NEWARRAY DATA
        $a = $self->CreateNewArrayData($c, $a) if (@{$a} == 0);

        my $mxc = $self->GetMaxCount($c);

        foreach (my $i = 0; $i < @{$a}; $i++) {
            last if ($i > $mxc);
            push(@adata, $self->GenTmpl($c, @{$a}[$i]));
        }

        $r = $r . (($c > 0) ? "|$c:|" : "0:|") . join("|", @adata);
        $c++;
    }

    return $r;
}

# Metoda spracuje data do spravneho tvaru
sub GetCHD {
    my $self = shift;
    my ($c, $r);
    foreach my $a (@{$self->{'data'}}) {
        $r = $r . (($c > 0) ? "|" : "") . join(",", @{$a});
        $c++;
    }
    return $r;
}

# Vlozime hodnotu do sablony [**]
sub GenTmpl {
    my ($self, $row, $value) = @_;

    # VLOZIME data do sablony
    my $tmpl = @{$self->{'osatmpl'}}[$row];

    if ($tmpl) {
        $tmpl =~ s/\[\*\*\]/$value/;
        return $tmpl;
    } else {
        return $value;
    }
}

# Metoda vytvori nove hodnoty pro osu
sub CreateNewArrayData {
    my ($self, $count, $array) = @_;

    my $mxc = $self->GetMaxCount($count);
    my $dif = $self->GetDifValue();
    my $min = $self->GetMinValue();

    $dif = ($dif / $mxc);
    foreach (my $i = 0; $i < ($mxc + 1); $i++) {

        # Vlozime data do pole
        push(@{$array}, ($min + ($dif * $i)));
    }

    return $array;
}

# Metoda zapise nejmensi hodnotu v poli do atributu minvalue
sub SetMinValue {
    my ($self, $data) = @_;

    my $r = @{$data}[0];
    foreach (@{$data}) {
        $r = $_ if ($_ < $r);
    }
    $self->{'minvalue'} = $r       if ($r < $self->{'minvalue'});
    $self->{'minvalue'} = ($r - 1) if ($self->{'minvalue'} == $self->{'maxvalue'});
}

# Metoda zapise nejvesi hodnotu v poli do atributu maxvalue
sub SetMaxValue {
    my ($self, $data) = @_;
    my $r = 0;
    foreach (@{$data}) {
        $r = $_ if ($_ > $r);
    }
    $self->{'maxvalue'} = $r       if ($r > $self->{'maxvalue'});
    $self->{'minvalue'} = ($r - 1) if ($self->{'minvalue'} == $self->{'maxvalue'});
}

# Zjistime jak velka je hodnota (rozsah) mezi hodnotami min a max
# napr -300 az 700 = 1000
#         0 az 700 = 700
#       -10 az -70 = 60
sub GetDifValue {
    my $self = shift;
    my $min  = $self->{'minvalue'};
    my $max  = $self->{'maxvalue'};
    my $v    = ($min + (($max =~ /^-/) ? $max : "-$max"));
    $v =~ s/^-//;
    return $v;
}

# Metoda vraci maximalni povolene mnozstvi bodu na ose
sub GetMaxCount {
    my ($self, $count) = @_;

    my $yr = 10;    # def. max pocet na ose y,r
    my $x  = 5;     # def. max pocet na ose r

    my $v = @{$self->{'osamaxv'}}[$count];
    my $n = @{$self->{'osaname'}}[$count];

    if ($v) {
        return $v;
    } else {
        if ($n eq "y" or $n eq "r") {
            return $yr;
        } elsif ($n eq "x") {
            my $c = @{$self->{'osadata'}}[$count];
            return (($c < $x) ? $c : $x);
        } else {

            # Unknown osa
            return 0;
        }
    }
}

# Metoda vrazi minimalni hodnotu v grafu
sub GetMinValue {
    my $self = shift;

    # TODO : dopsat zaokrouhleni minvalue na nejakou peknou hodnotu
    return $self->{'minvalue'};
}

# Metoda vrazi maximalni hodnotu v grafu
sub GetMaxValue {
    my $self = shift;

    # TODO : dopsat zaokrouhleni maxvalue na nejakou peknou hodnotu
    return $self->{'maxvalue'};
}

# Metoda vraci delku nejdelsiho slova v poli.
sub GetMaxLength {
    my ($self, $data) = @_;
    my $r = 0;
    foreach (@{$data}) {
        $r = length($_) if ($r < length($_));
    }
    return $r;
}

1;
