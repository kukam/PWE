#!/usr/bin/env perl
# Services::Session nad mock entitou: regenerate() (nove sid po prihlaseni - session fixation)
# a prilezitostny uklid expirovanych radku v newSession (cleanupExpired).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PWE::TestEnv;

my $ROOT = PWE::TestEnv::root();
my $APP2 = PWE::TestEnv::app2();
plan skip_all => 'chybi Template' unless (eval { require Template; 1 });

# --- mock DAO + "databaze" (hash radku podle sid) ------------------------------------------------------------
{
    package MockSessDAO;
    our $AUTOLOAD;
    my @COLS = qw(sid useragent ipaddres lang messenger expire admin updated created);
    # prazdny radek ma DB defaulty lang 'CZE' a admin 'f' (jako COLUMN_DEF v DAO mape)
    sub new { my ($c, $store) = @_; return bless {store => $store, data => {(map { $_ => undef } @COLS), lang => 'CZE', admin => 'f'}, changes => {}, pk => undef, calls => []}, $c; }
    sub load { my ($s, $row) = @_; $s->{'data'} = {%{$s->{'data'}}, %{$row}}; $s->{'pk'} = $row->{'sid'}; }
    sub getMirroredData { return {%{$_[0]->{'data'}}}; }
    sub getChangeList   { return [sort keys %{$_[0]->{'changes'}}]; }
    sub getPrimaryValue { return $_[0]->{'pk'}; }
    sub getTableName    { return 'session'; }
    sub error           { return 0; }
    sub logit           { push(@{$_[0]->{'calls'}}, 'logit'); }
    sub commit          { push(@{$_[0]->{'calls'}}, 'commit'); $_[0]->{'changes'} = {}; }
    sub rollback        { push(@{$_[0]->{'calls'}}, 'rollback'); $_[0]->{'changes'} = {}; }
    sub flush {
        my $s = shift;
        push(@{$s->{'calls'}}, 'flush');
        return unless (%{$s->{'changes'}});
        if (defined($s->{'pk'})) {
            push(@{$s->{'store'}->{'sql'}}, "UPDATE $s->{'pk'}");
        } else {
            die "duplicate sid $s->{'data'}->{'sid'}" if (exists($s->{'store'}->{'rows'}->{$s->{'data'}->{'sid'}}));
            $s->{'pk'} = $s->{'data'}->{'sid'};
            push(@{$s->{'store'}->{'sql'}}, "INSERT $s->{'pk'}");
        }
        $s->{'store'}->{'rows'}->{$s->{'pk'}} = {%{$s->{'data'}}};
    }
    sub DELETE_ROW {
        my $s = shift;
        push(@{$s->{'calls'}}, 'delete_row');
        push(@{$s->{'store'}->{'sql'}}, "DELETE_ROW " . (defined($s->{'pk'}) ? $s->{'pk'} : 'undef'));
        delete $s->{'store'}->{'rows'}->{$s->{'pk'}} if (defined($s->{'pk'}));
    }
    sub delete {
        my ($s, $stmt, $bind) = @_;
        push(@{$s->{'calls'}}, 'delete');
        push(@{$s->{'store'}->{'sql'}}, "DELETE $stmt [@{$bind}]");
        if ($stmt =~ /expire < \?/) {
            foreach my $sid (keys %{$s->{'store'}->{'rows'}}) {
                delete $s->{'store'}->{'rows'}->{$sid} if ($s->{'store'}->{'rows'}->{$sid}->{'expire'} < $bind->[0]);
            }
        }
    }
    sub DESTROY { }
    sub AUTOLOAD {
        my $self = shift;
        (my $n = $AUTOLOAD) =~ s/.*://;
        die "unknown column $n" unless (grep { $_ eq $n } @COLS);
        if (@_) {
            my $v   = shift;
            my $old = $self->{'data'}->{$n};
            $self->{'changes'}->{$n} = 1 if ((defined($old) ? $old : '') ne (defined($v) ? $v : ''));
            $self->{'data'}->{$n} = $v;
        }
        return $self->{'data'}->{$n};
    }

    package MockSessEntities;
    sub new { return bless {rows => {}, sql => [], created => 0}, shift; }
    sub createEntityObject {
        my ($s, $name, $opts) = @_;
        $s->{'created'}++;
        my $dao = MockSessDAO->new($s);
        if (ref($opts) eq 'HASH' and defined($opts->{'where'})) {
            my $sid = $opts->{'conds'}->[0];
            $dao->load($s->{'rows'}->{$sid}) if (exists($s->{'rows'}->{$sid}));
        }
        return $dao;
    }
    sub deletes { return scalar(grep { /^DELETE FROM/ } @{$_[0]->{'sql'}}); }
}

my $E = PWE::TestEnv->boot(app => $APP2, core => $ROOT);
my ($C, $W, $U, $LOG, $V) = @{$E}{qw(CONF WEB USER LOG VALIDATE)};
require Services::Session::Session;

# --- regenerate(): nove sid, stary radek pryc, novy radek se stejnymi daty ---------------------------------
{
    my $EN = MockSessEntities->new;
    my $S  = Services::Session::Session->new($C, $LOG, $V, undef, $EN, $U, $W);

    PWE::TestEnv::request($E, page => 'tPage2', func => 'default');
    my $old = $U->getSid();
    $S->newSession();
    ok(exists($EN->{'rows'}->{$old}), 'newSession zalozila radek pod puvodnim sid');
    $S->setValue('admin', 't');    # prihlaseni - jeste neulozeno (ceka na flush)
    $S->setValue('lang',  'EN');

    my $new = $S->regenerate();
    like($new, qr/^C0[0-9A-F]{32}$/, 'regenerate vraci nove sid (C0 + md5hex)');
    isnt($new, $old, 'sid se zmenilo');
    is($U->getSid(), $new, '$USER->getSid vraci nove sid');
    ok(!exists($EN->{'rows'}->{$old}), 'stary radek session smazan (DELETE_ROW)');
    ok(exists($EN->{'rows'}->{$new}),  'novy radek session zalozen');
    is($EN->{'rows'}->{$new}->{'admin'},    't',        'data prenesena: vlastni sloupec webu (admin)');
    is($EN->{'rows'}->{$new}->{'lang'},     'EN',       'data prenesena: lang');
    is($EN->{'rows'}->{$new}->{'ipaddres'}, '10.0.0.1', 'data prenesena: ipaddres');
    is($EN->{'rows'}->{$new}->{'useragent'}, 'pwe-test', 'data prenesena: useragent');
    ok($EN->{'rows'}->{$new}->{'expire'} > time(), 'data prenesena: expire');
    is($S->getValue('sid'), $new, 'data session v objektu maji nove sid');
    ok($S->{'dao'} && $S->{'dao'}->{'pk'} eq $new, 'entita noveho radku je drzena pro flush');
    like(join(',', @{$EN->{'sql'}}), qr/DELETE_ROW \Q$old\E,INSERT \Q$new\E/, 'poradi: smazat stary, zalozit novy');

    my $hdr = PWE::TestEnv::capture(sub { $W->printHttpHeader() });
    like($hdr, qr/Set-Cookie: PWE-TEST2=\Q$new\E;/, 'printHttpHeader posle nove sid v Set-Cookie (cookie_id z getSid)');

    $S->setValue('messenger', '<p>x</p>');
    $S->flush();
    is($EN->{'rows'}->{$new}->{'messenger'}, '<p>x</p>', 'flush po regenerate aktualizuje novy radek (UPDATE)');
    is($EN->{'sql'}->[-1], "UPDATE $new", 'flush = UPDATE, ne druhy INSERT');
    ok(!exists($EN->{'rows'}->{$old}), 'stary radek se nevratil');
    PWE::TestEnv::finish($E);

    # dalsi request s novym sid nacte prenesena data
    PWE::TestEnv::request($E, page => 'tPage2', func => 'default', sid => $new);
    my $sess = $S->newSession();
    is($sess->{'admin'}, 't', 'dalsi request s novym sid: data session nactena');
    is($U->getValue('language'), 'EN', 'jazyk z prenesene session');

    # created/updated se neprenasi (nastavi je entita pri INSERT/UPDATE), regenerate bez predchozi zmeny
    $EN->{'rows'}->{$new}->{'created'} = '2026-01-01 00:00:00';
    $S->{'session'}->{'created'} = '2026-01-01 00:00:00';
    my $n2 = $S->regenerate();
    ok(exists($EN->{'rows'}->{$n2}) && !exists($EN->{'rows'}->{$new}), 'druha regenerace presune radek znovu');
    ok(!defined($EN->{'rows'}->{$n2}->{'created'}), 'created se neprenasi (doplni entita pri INSERT)');
    is($EN->{'rows'}->{$n2}->{'admin'}, 't', 'ostatni data prenesena i podruhe');
    $S->flush();
    PWE::TestEnv::finish($E);

    # regenerate bez newSession v requestu si session nacte sama
    PWE::TestEnv::request($E, page => 'tPage2', func => 'default', sid => $n2);
    ok(!$S->{'dao'}, 'pred newSession neni drzena entita');
    my $n3 = $S->regenerate();
    ok(exists($EN->{'rows'}->{$n3}) && !exists($EN->{'rows'}->{$n2}), 'regenerate bez newSession si session nacte a presune');
    is($EN->{'rows'}->{$n3}->{'admin'}, 't', 'data zachovana');
    $S->flush();
    PWE::TestEnv::finish($E);
}

# --- cleanupExpired: pri 1. a kazde 20. nove session smazat expirovane radky ---------------------------------
{
    my $EN = MockSessEntities->new;
    my $S  = Services::Session::Session->new($C, $LOG, $V, undef, $EN, $U, $W);
    my $expired = 'C0' . ('A' x 32);
    my $valid   = 'C0' . ('B' x 32);
    my %row = (useragent => 'ua', ipaddres => '1.1.1.1', lang => 'CZE', admin => 'f');
    $EN->{'rows'}->{$expired} = {%row, sid => $expired, expire => time() - 10};
    $EN->{'rows'}->{$valid}   = {%row, sid => $valid,   expire => time() + 1000};


    PWE::TestEnv::request($E, page => 'tPage2', func => 'default');    # bez cookie = nova session
    $S->newSession();
    ok(!exists($EN->{'rows'}->{$expired}), 'prvni nova session v procesu: expirovany radek smazan');
    ok(exists($EN->{'rows'}->{$valid}),    'platny radek zustal');
    is($EN->deletes, 1, 'jeden DELETE');
    like($EN->{'sql'}->[0], qr/^DELETE FROM session WHERE expire < \? \[\d{10}\]$/, 'DELETE FROM session WHERE expire < ? s unixovym casem (prenositelne MariaDB i Postgres)');
    is($S->{'new_count'}, 1, 'pocitadlo novych session');
    $S->flush();
    PWE::TestEnv::finish($E);

    foreach my $i (2 .. 20) {
        PWE::TestEnv::request($E, page => 'tPage2', func => 'default');
        $S->newSession();
        $S->flush();
        PWE::TestEnv::finish($E);
    }
    is($EN->deletes, 1, '2. az 20. nova session neuklizi');
    is($S->{'new_count'}, 20, 'pocitadlo = 20');

    # existujici session neni nova -> pocitadlo se nehybe
    PWE::TestEnv::request($E, page => 'tPage2', func => 'default', sid => $valid);
    $S->newSession();
    $S->flush();
    PWE::TestEnv::finish($E);
    is($S->{'new_count'}, 20, 'existujici session pocitadlo nezvysi');
    is($EN->deletes, 1, 'existujici session neuklizi');

    $EN->{'rows'}->{$expired} = {%row, sid => $expired, expire => time() - 5};
    PWE::TestEnv::request($E, page => 'tPage2', func => 'default');
    $S->newSession();
    is($EN->deletes, 2, '21. nova session uklidi znovu');
    ok(!exists($EN->{'rows'}->{$expired}), 'expirovany radek smazan');
    ok(exists($EN->{'rows'}->{$U->getSid()}), 'nova session zalozena i po uklidu');
    $S->flush();
    PWE::TestEnv::finish($E);

    # vypnuti pres http.session_cleanup_every = 0
    local $C->{'http'}->{'session_cleanup_every'} = 0;
    my $EN0 = MockSessEntities->new;
    my $S0  = Services::Session::Session->new($C, $LOG, $V, undef, $EN0, $U, $W);
    $EN0->{'rows'}->{$expired} = {%row, sid => $expired, expire => time() - 5};
    PWE::TestEnv::request($E, page => 'tPage2', func => 'default');
    $S0->newSession();
    is($EN0->deletes, 0, 'session_cleanup_every = 0 -> uklid vypnuty');
    ok(exists($EN0->{'rows'}->{$expired}), 'expirovany radek zustal');
    $S0->flush();
    PWE::TestEnv::finish($E);
}

done_testing();
