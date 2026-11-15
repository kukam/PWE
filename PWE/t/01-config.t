#!/usr/bin/env perl
# Libs::Config - nacteni konfigurace, getValue, isExistValue, prepis pres ENV.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PWE::TestEnv;

PWE::TestEnv::clean_env();
require Libs::Config;

my $APP = PWE::TestEnv::app();

{
    $ENV{'PWE_CONF_http_name'}        = 'FROM ENV';
    $ENV{'PWE_CONF_http_neexistuje'}  = 'ignorovat';
    $ENV{'PWE_CONF_dbi_db1_login'}    = 'ignorovat-bez-dbi';
    my $C = Libs::Config->new($APP, 'pwe.fcgi', 'conf/web.conf', 'conf/database.conf');
    isa_ok($C, 'Libs::Config');
    like($C->getValue('pwe', 'home'), qr{/$}, 'home konci lomitkem');
    is($C->getValue('pwe', 'cgi_script_name'), 'pwe.fcgi', 'cgi_script_name doplnen');
    is($C->getValue('http', 'name'), 'FROM ENV', 'ENV PWE_CONF_http_name prepsal hodnotu');
    ok(!$C->isExistValue('http', 'neexistuje'), 'ENV s neznamym klicem se neaplikuje');
    ok(!exists($C->{'dbi'}) || !exists($C->{'dbi'}->{'db1'}), 'ENV pro dbi bez sekce dbi se neaplikuje');
    delete @ENV{qw(PWE_CONF_http_name PWE_CONF_http_neexistuje PWE_CONF_dbi_db1_login)};
}

{
    # regrese: sekce s podtrzitkem v nazvu (smtp_primary apod.) nesla prepsat z ENV, protoze se
    # jmeno delilo na prvnim podtrzitku (sekce 'smtp', klic 'test_host')
    $ENV{'PWE_CONF_smtp_test_host'}         = 'env.smtp.example';
    $ENV{'PWE_CONF_smtp_test_hello'}        = 'env.hello';
    $ENV{'PWE_CONF_smtp_test_neexistuje'}   = 'ignorovat';
    $ENV{'PWE_CONF_smtp_neexistuje_host'}   = 'ignorovat';
    $ENV{'PWE_CONF_log_log_delay'}          = '1';
    my $C = Libs::Config->new($APP, 'pwe.fcgi', 'conf/web.conf', 'conf/database.conf');
    is($C->getValue('smtp_test', 'host'),  'env.smtp.example', 'ENV prepsal klic v sekci s podtrzitkem (smtp_test.host)');
    is($C->getValue('smtp_test', 'hello'), 'env.hello',        'ENV prepsal dalsi klic sekce s podtrzitkem');
    ok(!$C->isExistValue('smtp_test', 'neexistuje'), 'neznamy klic v sekci s podtrzitkem se neaplikuje');
    ok(!exists($C->{'smtp'}) && !exists($C->{'smtp_neexistuje'}), 'neznama sekce se nezaklada');
    is($C->getValue('log', 'log_delay'), '1', 'klic s podtrzitkem v jednoslovne sekci funguje dal (log.log_delay)');
    delete @ENV{qw(PWE_CONF_smtp_test_host PWE_CONF_smtp_test_hello PWE_CONF_smtp_test_neexistuje PWE_CONF_smtp_neexistuje_host PWE_CONF_log_log_delay)};
}

{
    my $C = Libs::Config->new($APP, 'pwe.fcgi', 'conf/web.conf', 'conf/database.conf');
    is($C->getValue('http', 'title'), 'PWE TEST', 'getValue sekce/klic');
    is($C->getValue('http', 'nic', 'def'), 'def', 'getValue neexistujici klic -> default');
    is($C->getValue('nic', 'nic', 'def'), 'def', 'getValue neexistujici sekce -> default');
    is($C->getValue('pwe', 'development', 1), 0, 'hodnota 0 v conf NENI nahrazena defaultem (regrese)');
    is($C->getValue('http', 'keywords', 'def'), '', 'prazdny retezec v conf NENI nahrazen defaultem');
    is($C->getValue('log', 'logout', 'def'), 'def', 'undef v conf -> default');
    is(ref($C->getValue('http', 'languages', [])), 'ARRAY', 'getValue vraci referenci');
    is(ref($C->getValue('smtp_test', undef, undef)), 'HASH', 'getValue bez podklice vraci celou sekci');
    ok($C->isExistValue('pwe', 'home'), 'isExistValue existujici');
    ok(!$C->isExistValue('pwe', 'xxx'), 'isExistValue neexistujici');
    ok(!$C->isExistValue('xxx', 'xxx'), 'isExistValue neexistujici sekce');
}

{
    eval { Libs::Config->new($APP, 'pwe.fcgi', 'conf/neexistuje.conf', 'conf/database.conf'); };
    like($@, qr/not exist/, 'chybejici hlavni conf -> die');
}

done_testing();
