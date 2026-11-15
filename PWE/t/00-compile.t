#!/usr/bin/env perl
# Kompilace (perl -c) vsech modulu enginu (Libs, Entities, Services, Sites, Pages, tools/lib), pwe.fcgi
# a skriptu v tools/ - vse v adresari enginu PWE/ ($ROOT se odvozuje od umisteni testu, v kontejneru /PWE/PWE).
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Find;
use Cwd qw(abs_path);

my $ROOT = abs_path("$FindBin::Bin/..");
my @files = ("$ROOT/pwe.fcgi", "$ROOT/debug.cgi", glob("$ROOT/tools/*.pl"));
find({no_chdir => 1, wanted => sub { push(@files, $_) if (/\.pm$/) }}, map { "$ROOT/$_" } qw(Libs Entities Services Sites Pages tools/lib));
@files = sort @files;

plan tests => scalar(@files);

foreach my $f (@files) {
    my $rel = $f; $rel =~ s{^\Q$ROOT\E/}{};
    my $out = `$^X -I$ROOT -I$ROOT/tools/lib -c $f 2>&1`;
    ok($out =~ /syntax OK/, "perl -c $rel") or diag($out);
}
