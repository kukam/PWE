package Libs::Pics;

use strict;
use warnings;

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

=head2 B<getInfo()>

    Metoda vraci zjistene informace o obrazku.

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

=head2 B<convert()>

    Metoda upravuje velikost,rotaci kvalitu obrazku.
    Metoda pracuje s prikazem 'convert'. 

    my @error = $self->convert(
    f => "inputfile",
    o => "outputfile",
    -r => "-90%|180%", # rotace
    -h => "640", # velikost na vysku v px
    -w => "480", # velikost na sirku v px
    -g => "640x480", # velikost
    -q => "1-100", # kvalita obrazku (compression level),def = 100
    );

    Metoda vraci v poli informace o pripadnych chybach.
    Pokud je pole prazdne k chybe nedoslo.

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
