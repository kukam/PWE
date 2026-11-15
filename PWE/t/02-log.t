#!/usr/bin/env perl
# Libs::Log - urovne, filtry, delay, zapis do souboru a sendErrorReport bez padu.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PWE::TestEnv;

my $E   = PWE::TestEnv->core(loglevel => 4, logout => 'ramdisk/test.log');
my $APP = PWE::TestEnv::app();
my $LOG = $E->{'LOG'};
my $logfile = "${APP}ramdisk/test.log";

sub slurp { open(my $fh, '<', $logfile) or return ''; local $/; my $t = <$fh>; close $fh; return $t; }
sub reset_log { unlink($logfile); }

is($LOG->getLogLevel(), 4, 'getLogLevel');
$LOG->setLogLevel('abc');
is($LOG->getLogLevel(), 4, 'setLogLevel ignoruje necislo');
$LOG->setLogLevel(4);

reset_log();
$LOG->setIP('1.2.3.4');
$LOG->error('E1');
$LOG->warning('W1');
$LOG->info('I1');
$LOG->debug('D1');
my $t = slurp();
like($t, qr/\[E\] main:\d+ :: E1/, 'error zapsan s prefixem [E] a caller');
like($t, qr/\[W\] .*W1/, 'warning zapsan');
like($t, qr/\[I\] .*I1/, 'info zapsan');
like($t, qr/\[D\] .*D1/, 'debug zapsan');
like($t, qr/1\.2\.3\.4/, 'IP z setIP je v zaznamu');

reset_log();
$LOG->setLogLevel(1);
$LOG->error('E2'); $LOG->warning('W2'); $LOG->info('I2'); $LOG->debug('D2');
$t = slurp();
like($t, qr/E2/, 'loglevel 1: error prochazi');
unlike($t, qr/W2|I2|D2/, 'loglevel 1: warning/info/debug potlaceny');
$LOG->setLogLevel(4);

# filtry (whitelist) a exclude (blacklist) podle paketu volajiciho
{
    local $E->{'CONF'}->{'log'}->{'filter_list'} = ['Jiny::Paket'];
    reset_log();
    $LOG->error('FILTERED');
    unlike(slurp(), qr/FILTERED/, 'filter_list: jiny paket -> zahozeno');
    $E->{'CONF'}->{'log'}->{'filter_list'} = ['main'];
    reset_log();
    $LOG->error('ALLOWED');
    like(slurp(), qr/ALLOWED/, 'filter_list: main -> propusteno');
}
{
    local $E->{'CONF'}->{'log'}->{'error_exclude_list'} = ['main'];
    reset_log();
    $LOG->error('EXCL_ERR');
    $LOG->info('EXCL_INFO');
    my $x = slurp();
    unlike($x, qr/EXCL_ERR/, 'error_exclude_list: main -> error zahozen');
    like($x, qr/EXCL_INFO/, 'error_exclude_list se netyka info');
}

# delay
{
    local $E->{'CONF'}->{'log'}->{'log_delay'} = 1;
    local $E->{'CONF'}->{'log'}->{'log_delay_minimum'} = 0;
    reset_log();
    is($LOG->delay('k1'), 0, 'prvni delay() vraci 0');
    my $d = $LOG->delay('k1', 'text');
    like($d, qr/^\d+\.\d+$/, 'druhe delay() vraci cas');
    like(slurp(), qr/\[d\] .*k1 :: text \[ delay : /, 'delay zapsan do logu');
}
{
    local $E->{'CONF'}->{'log'}->{'log_delay'} = 0;
    ok(!defined($LOG->delay('k2')), 'delay vypnuty -> undef');
}

# sendErrorReport: SMTP na 127.0.0.1:1 odmitne spojeni - nesmi spadnout (drive preklep $self-- > info)
reset_log();
my $ok = eval { $LOG->sendErrorReport('PAGE', 'tPage', 'crash', "boom\nline2"); 1 };
ok($ok, 'sendErrorReport pri nedostupnem SMTP nespadne') or diag($@);
like(slurp(), qr/Trying send email to:admin\@test\.local FAIL/, 'selhani odeslani je zalogovano');

# smtp server bez konfigurace
{
    local $E->{'CONF'}->{'pwe'}->{'smtp_servers'} = ['smtp_neexistuje'];
    local $E->{"CONF"}->{"log"}->{"error_report_interval"} = 0;    # stejny klic PAGE:tPage:crash uz byl hlasen vyse
    reset_log();
    $LOG->sendErrorReport('PAGE', 'tPage', 'crash', 'x');
    like(slurp(), qr/smtp server 'smtp_neexistuje' config is not defined/, 'chybejici smtp sekce je zalogovana');
}

# --- otevreny log handle: dva zapisy za sebou, soubor smazan -> znovu vytvoren ---
{
    my $file = PWE::TestEnv::app() . "ramdisk/log-handle.log";
    unlink($file);
    my $E2 = PWE::TestEnv->core(loglevel => 3, logout => 'ramdisk/log-handle.log', keep_ramdisk => 1);
    my $L = $E2->{'LOG'};
    $L->info('prvni');
    $L->info('druhy');
    open(my $fh, '<', $file) or die "$file: $!"; my @l = <$fh>; close($fh);
    is(scalar(@l), 2, 'dva radky v logu pres jeden otevreny handle (autoflush)');
    like($l[1], qr/druhy/, 'poradi zapisu');
    unlink($file);
    $L->info('treti');
    ok(-f $file, 'po smazani (rotaci) logu se soubor znovu otevre');
    open($fh, '<', $file) or die; @l = <$fh>; close($fh);
    like($l[0], qr/treti/, 'zapis po znovuotevreni');
}

done_testing();
