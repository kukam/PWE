#!/usr/bin/env perl
# Services::DBTable::DBTable - ciste pomocne metody (bez DB).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PWE::TestEnv;

my $E = PWE::TestEnv->core();
require Services::DBTable::DBTable;
my $T = Services::DBTable::DBTable->new($E->{'CONF'}, $E->{'LOG'}, $E->{'VALIDATE'}, undef, undef, undef, undef);
isa_ok($T, 'Services::DBTable::DBTable');

is_deeply($T->genTablePageList(1, 1, 10), [1], 'jedna stranka');
is_deeply($T->genTablePageList(1, 25, 10), [1 .. 10], 'zacatek: 1..10');
is_deeply($T->genTablePageList(15, 25, 10), [9 .. 20], 'uprostred: okno kolem aktualni stranky');
is_deeply($T->genTablePageList(30, 25, 10), [19 .. 25], 'gopage > endpage se orizne na endpage');
is_deeply($T->genTablePageList('x', 5, 10), [1 .. 5], 'nenumericky gopage -> 1');
is_deeply($T->genTablePageList(1, 0, 0), [1], 'nulovy endpage/nlimit -> 1');
is_deeply($T->genTablePageList(3, 3, 1), [2, 3], 'nlimit 1: predchozi + aktualni stranka');

done_testing();
