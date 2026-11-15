package Libs::Pics;

=head1 NAME

Libs::Pics - informace o obrazcich a jejich konverze pres externi nastroje ImageMagick (identify, convert)

=cut

use strict;
use warnings;

=head2 B<[Public] new()>

    Konstruktor obalky nad ImageMagick nastroji /usr/bin/identify a /usr/bin/convert
    (volaji se jako externi prikazy).

=cut

sub new {
    my $class = shift;
    my $self  = {
        'identify' => "/usr/bin/identify",
        'convert'  => "/usr/bin/convert",
        'output'   => undef,
    };
    bless $self, $class;
    return $self;
}

=head2 B<[Public] getInfo($file)>

    Metoda zjisti informace o obrazku $file pomoci prikazu 'identify' a vraci je jako hashref:

    {
        file     => "cesta/k/souboru",
        type     => "jpeg",        # typ obrazku (mala pismena)
        width    => 640,           # sirka v px
        height   => 480,           # vyska v px
        geometry => "640x480",
        size     => 12345,         # velikost souboru v bajtech (undef, pokud ji nelze zjistit)
        major    => "width",       # delsi strana: 'width' nebo 'height'
        bad      => 0,
        msg      => "...",         # puvodni vystup prikazu identify
    }

    Pokud se vystup identify nepodari rozparsovat (neexistujici soubor, soubor neni obrazek,
    chybi /usr/bin/identify), vraci { file => $file, errormsg => "...", bad => 1 }.

=cut

sub getInfo {
    my ($self, $file) = @_;
    my $msg = join("", $self->_exec($self->{'identify'}, $file));
    if ($msg =~ /\.*\s+(\S+)\s+(\d+)x(\d+)/) {
        my $size = (stat($file))[7];
        return {
            file     => $file,
            type     => lc($1),
            width    => $2,
            height   => $3,
            geometry => "$2x$3",
            size     => ($size ? $size : undef),
            bad      => 0,
            major    => (($2 >= $3) ? 'width' : 'height'),
            msg      => $msg,
        };
    } else {
        return {
            file     => $file,
            errormsg => $msg,
            bad      => 1,
        };
    }
}

=head2 B<[Public] convert(%opt)>

    Metoda upravi velikost, rotaci nebo kvalitu obrazku pomoci prikazu 'convert'.

    my @error = $PICS->convert(
        f    => "vstupni_soubor",    # nebo file => ...
        o    => "vystupni_soubor",   # nebo outfile => ...
        '-r' => "90",                # rotace ve stupnich (-rotate)
        '-h' => "640",               # vyska v px (-geometry x640)
        '-w' => "480",               # sirka v px (-geometry 480x)
        '-g' => "640x480",           # rozmer (-geometry 640x480)
        '-q' => "1-100",             # kvalita / komprese (-quality), vychozi 100
    );

    Ostatni klice zacinajici na '-' se predaji prikazu convert beze zmeny jako "klic hodnota";
    klice bez pomlcky (krome f/file a o/outfile) se ignoruji.

    Metoda vraci pole radku, ktere prikaz convert vypsal (chybova hlaseni).
    Prazdne pole = k chybe nedoslo.

=cut

sub convert {
    my ($self, %opt) = @_;

    my ($file, $outfile, @opt);

    # DEF. HODNOTY
    unless ($opt{'-quality'} or $opt{'-q'}) {
        $opt{'-quality'} = 100;
    }

    foreach my $key (keys %opt) {
        if ($key =~ /^f$/ or $key =~ /^file$/) {
            $file = $opt{$key};
            next;
        } elsif ($key =~ /^o$/ or $key =~ /^outfile$/) {
            $outfile = $opt{$key};
            next;
        } elsif ($key =~ /^\-r$/) {
            push(@opt, "-rotate $opt{$key}");
        } elsif ($key =~ /^\-h$/) {

            # TODO: Dopsat kontrolu, zdali dana velikost neni jiz mensi nez kterou chceme, tak abychom nezvetsovali obrazek za jeho rozmer
            push(@opt, "-geometry x$opt{$key}");
        } elsif ($key =~ /^\-w$/) {

            # TODO: Dopsat kontrolu, zdali dana velikost neni jiz mensi nez kterou chceme, tak abychom nezvetsovali obrazek za jeho rozmer
            push(@opt, "-geometry $opt{$key}x");
        } elsif ($key =~ /^\-g$/) {

            # TODO: Dopsat kontrolu, zdali dana velikost neni jiz mensi nez kterou chceme, tak abychom nezvetsovali obrazek za jeho rozmer
            push(@opt, "-geometry $opt{$key}");
        } elsif ($key =~ /^\-q$/) {
            push(@opt, "-quality $opt{$key}");
        } elsif ($key !~ /^\-/) {
            next;
        } else {
            push(@opt, "$key $opt{$key}");
        }
    }

    my @msg = $self->_exec($self->{'convert'}, join(" ", @opt) . " $file $outfile");

    if (@msg) {
        return @msg;
    } else {
        return qw();
    }

}

=head2 B<[Private] _exec($command,$args)>

    Spusti externi prikaz a vrati jeho vystup jako pole radku. Pokud prikaz neni spustitelny,
    vrati jeden radek s chybou "[!] Can't exec".

=cut

sub _exec {
    my ($self, $command, $args) = @_;

    my @output;
    my $out = $self->{'output'};

    if ($args) { $args = " " . $args; }

    if (not -x $command) { push(@output, "[!] Can't exec: '$command'"); return @output; }

    open($out, "$command$args |") || die "Failed: $!\n";
    while (<$out>) { push(@output, $_); }
    close($out);

    return @output;
}

1;
