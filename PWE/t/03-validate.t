#!/usr/bin/env perl
# Libs::Validate - vestavene validatory, SQL validatory, validate([...]), AUTOLOAD.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PWE::TestEnv;

my $E = PWE::TestEnv->core();
my $V = $E->{'VALIDATE'};

# is_email
is($V->is_email('jan.novak@example.cz'), 'jan.novak@example.cz', 'is_email platny');
is($V->is_email('a+tag@example.online'), 'a+tag@example.online', 'is_email: plus v lokalni casti a dlouhe TLD (regrese {2,4})');
is($V->is_email('x@muzeum.museum'), 'x@muzeum.museum', 'is_email TLD .museum');
ok(!defined($V->is_email('neplatny')), 'is_email bez @');
ok(!defined($V->is_email('a@b')), 'is_email bez TLD');
ok(!defined($V->is_email('a b@c.cz')), 'is_email s mezerou');

# jednoduche validatory
is($V->is_md5hex('0123456789abcdefABCDEF'), 1, 'is_md5hex hex');
ok(!defined($V->is_md5hex('xyz')), 'is_md5hex nehex');
ok(!defined($V->is_md5hex(undef)), 'is_md5hex undef');
is($V->is_percent('15%'), '15%', 'is_percent 15%');
is($V->is_percent('1.21'), '1.21', 'is_percent cislo');
ok(!defined($V->is_percent('abc')), 'is_percent text');
is($V->is_regx('abc123', qr/^\w+$/), 'abc123', 'is_regx match');
ok(!defined($V->is_regx('abc 123', qr/^\w+$/)), 'is_regx nomatch');
is($V->isnot_regx('abc', qr/\d/), 'abc', 'isnot_regx bez cisla');
ok(!defined($V->isnot_regx('a1', qr/\d/)), 'isnot_regx s cislem');
is($V->is_language('EN'), 'EN', 'is_language z conf');
ok(!defined($V->is_language('DE')), 'is_language mimo conf');
is($V->is_zipcode(0, '12345'), 1, 'is_zipcode 5 cislic');
ok(!defined($V->is_zipcode(0, '1234')), 'is_zipcode 4 cislice');
ok(!defined($V->is_zipcode(0, '1234a')), 'is_zipcode pismeno');
is($V->is_zipcode(1, ''), 1, 'is_zipcode null povolen a prazdna hodnota');
is($V->escape_jsinjection('<b>&"x"</b>'), '&lt;b&gt;&amp;"x"&lt;/b&gt;', 'escape_jsinjection');
is($V->validate_decimal_vat('1.21'), 1, 'validate_decimal_vat 1.21 (conf access_vat 21)');
ok(!defined($V->validate_decimal_vat('1.33')), 'validate_decimal_vat 1.33');

# funkce exportovane z Libs::Validate::Data / MySQL jsou pouzitelne jako metody
is($V->is_numeric('12.5'), '12.5', 'is_numeric (Data export) jako metoda');
is($V->is_integer('42'), '42', 'is_integer jako metoda');
ok(!defined($V->is_integer('4.2')), 'is_integer desetinne');
is($V->length_is_between('abc', 1, 3), 'abc', 'length_is_between');
is($V->is_int('5'), '5', 'is_int (MySQL export) jako metoda');
ok(defined($V->is_date('2024-02-29')), 'is_date (MySQL export) jako metoda');
ok(!defined($V->is_date('neni datum')), 'is_date nesmysl');

# SQL validatory
foreach my $drv (qw(mysql mariadb)) {
    is($V->is_sql_int($drv, '-5', 0), 1, "$drv is_sql_int signed");
    ok(!defined($V->is_sql_int($drv, '-5', 1)), "$drv is_sql_int unsigned zaporne");
    ok(!defined($V->is_sql_int($drv, 'abc', 0)), "$drv is_sql_int text");
    is($V->is_sql_tinyint($drv, '127', 0), 1, "$drv is_sql_tinyint 127");
    ok(!defined($V->is_sql_tinyint($drv, '300', 0)), "$drv is_sql_tinyint 300 (regrese: drive volano is_tinyint se spatnymi argumenty)");
    is($V->is_sql_tinyint($drv, '200', 1), 1, "$drv is_sql_tinyint unsigned 200");
    is($V->is_sql_varchar($drv, 'abc', 3), 1, "$drv is_sql_varchar presne");
    ok(!defined($V->is_sql_varchar($drv, 'abcd', 3)), "$drv is_sql_varchar dlouhe");
    is($V->is_sql_enum($drv, 't', ['t', 'f']), 1, "$drv is_sql_enum platne");
    ok(!defined($V->is_sql_enum($drv, 'x', ['t', 'f'])), "$drv is_sql_enum neplatne");
    is($V->is_sql_decimal($drv, '12.50', 10, 2, 0), 1, "$drv is_sql_decimal");
    ok(!defined($V->is_sql_decimal($drv, 'x', 10, 2, 0)), "$drv is_sql_decimal text");
    is($V->is_sql_boolen($drv, 'true'), 1, "$drv is_sql_boolen true (drive TODO/undef)");
    is($V->is_sql_boolean($drv, '0'), 1, "$drv is_sql_boolean alias");
    ok(!defined($V->is_sql_boolean($drv, 'maybe')), "$drv is_sql_boolean neplatne");
}
is($V->is_sql_int('postgres', '7'), 1, 'postgres is_sql_int');
is($V->is_sql_varchar('postgres', 'ab', 2), 1, 'postgres is_sql_varchar');
is($V->is_sql_boolen('postgres', 'f'), 1, 'postgres is_sql_boolen f');
ok(!defined($V->is_sql_boolen('postgres', 'x')), 'postgres is_sql_boolen neplatne');
is($V->is_sql_tinyint('postgres', '5'), 1, 'postgres is_sql_tinyint');
ok(!defined($V->is_sql_int('oracle', '7')), 'neznamy driver -> undef');

# validate([...]) - vraci klic chyby nebo undef
ok(!defined($V->validate(['is_email', 'error_email', 'a@b.cz'])), 'validate OK -> undef');
is($V->validate(['is_email', 'error_email', 'xx']), 'error_email', 'validate chyba -> klic');
is($V->validate(['is_enum', 'error_enum', 'c', 'a', 'b']), 'error_enum', 'validate s extra argumenty (is_enum)');
ok(!defined($V->validate(['is_enum', 'error_enum', 'a', 'a', 'b'])), 'validate is_enum OK');

# neznama metoda -> AUTOLOAD -> die
eval { $V->is_neexistujici('x') };
like($@, qr/Internal error, unknown method name:is_neexistujici/, 'AUTOLOAD neznama metoda -> die');
eval { $V->validate(['is_neexistujici', 'err', 'x']) };
like($@, qr/Internal error, unknown method at validate/, 'validate() s neznamou metodou -> die');

done_testing();
