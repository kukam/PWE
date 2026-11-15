#!/usr/bin/env perl
# Regresni testy drobnych oprav napric enginem (MyDBI reconnect).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PWE::TestEnv;
use lib "$FindBin::Bin/../tools/lib";

my $E = PWE::TestEnv->core();
my ($CONF, $LOG, $V) = @{$E}{qw(CONF LOG VALIDATE)};

# --- Libs::MyDBI::reconnect: pocet pokusu = trayconnect a ping se kontroluje po kazdem pokusu ---
{
    package MockReconnectDriver;
    sub new { my ($c, %a) = @_; return bless {reconnects => 0, pings => 0, ok => 0, %a}, $c; }
    sub reconnect { $_[0]->{'reconnects'}++; 1 }
    sub ping      { $_[0]->{'pings'}++; return $_[0]->{'ok'}; }
    sub disconnect { 1 }
    package main;

    require Libs::MyDBI;
    my $M = Libs::MyDBI->new($CONF, $LOG, $V);
    $CONF->{'dbi'}->{'dbx'} = {trayconnect => 2};
    $CONF->{'log'}->{'log_delay'} = 1;    # delay() vraci skutecny cas, aby reconnect nespal zbytecne dlouho

    my $bad = MockReconnectDriver->new(ok => 0);
    $M->{'DBC'}->{'dbx'} = {0 => $bad};
    my $t0 = time();
    eval { $M->reconnect('dbx') };
    like($@, qr/Unable reconnect to dbx/, 'neuspesny reconnect skonci die');
    is($bad->{'reconnects'}, 2, 'presne trayconnect pokusu (regrese: trayconnect+1)');
    is($bad->{'pings'}, 2, 'kazdy pokus overen pingem (regrese: posledni pokus bez pingu)');

    my $good = MockReconnectDriver->new(ok => 1);
    $M->{'DBC'}->{'dbx'} = {0 => $good};
    eval { $M->reconnect('dbx') };
    is($@, '', 'uspesny reconnect bez die');
    is($good->{'reconnects'}, 1, 'uspesny reconnect na prvni pokus');

    delete $CONF->{'dbi'}->{'dbx'};
    $M->{'DBC'}->{'dbx'} = {0 => MockReconnectDriver->new(ok => 0)};
    eval { $M->reconnect('dbx') };
    like($@, qr/Unable reconnect/, 'bez trayconnect v conf = 1 pokus, pak die (regrese: die bez pingu)');
    is($M->{'DBC'}->{'dbx'}->{'0'}->{'pings'}, 1, 'i jediny pokus se overi pingem');
    delete $M->{'DBC'}->{'dbx'};
}

# --- pwe.fcgi: POST bez page/func v tele bere cil z query stringu (callbacky bran, webhooky) ---
{
    require PWE::ToolEnv;
    PWE::ToolEnv->import(qw(run_cgi parse_response));
    my $app2 = PWE::TestEnv::app2();
  SKIP: {
        skip 'chybi Template / CGI::Fast', 3 unless (eval { require Template; require CGI::Fast; 1 });
        my ($out) = run_cgi($app2, post => 'x=1', query => 'page=neexistuje&func=default');
        is(parse_response($out)->{'status'}, 404, 'POST bez page v tele: page z query stringu (regrese: driv default stranka 200)');
        ($out) = run_cgi($app2, post => 'x=1', query => 'page=tPage2&func=default');
        is(parse_response($out)->{'status'}, 200, 'POST: tPage2 z query stringu se zavola');
        ($out) = run_cgi($app2, post => 'page=tPage2&func=default', query => 'page=neexistuje');
        is(parse_response($out)->{'status'}, 200, 'page v tele POST ma prednost pred query stringem');
    }
}

done_testing();
