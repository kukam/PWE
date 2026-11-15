#!/usr/bin/env perl
# Services::Email::Email - fronta e-mailu nad mock entitou MailQueue (bez databaze a SMTP).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PWE::TestEnv;

# Mock entity MailQueue: zaznamenava volani setteru (AUTOLOAD) a chovani flush/commit.
package MockMailQueue;
our $AUTOLOAD;
sub new { return bless {set => {}, calls => []}, shift; }
sub flush    { push(@{$_[0]->{'calls'}}, 'flush') }
sub logit    { push(@{$_[0]->{'calls'}}, 'logit') }
sub commit   { push(@{$_[0]->{'calls'}}, 'commit') }
sub rollback { push(@{$_[0]->{'calls'}}, 'rollback') }
sub error    { $_[0]->{'fail'} ? 1 : 0 }
sub DESTROY  { }

sub AUTOLOAD {
    my $self = shift;
    (my $name = $AUTOLOAD) =~ s/.*://;
    $self->{'set'}->{$name} = $_[0] if (@_);
    return $self->{'set'}->{$name};
}

package MockEntities;
sub new { return bless {created => []}, shift; }
sub createEntityObject {
    my ($self, $entity, $opts) = @_;
    my $o = MockMailQueue->new;
    $o->{'entity'} = $entity;
    $o->{'opts'}   = $opts;
    push(@{$self->{'created'}}, $o);
    return $o;
}
sub last { $_[0]->{'created'}->[-1] }

package main;

my $E = PWE::TestEnv->core();
my ($CONF, $LOG, $V) = @{$E}{qw(CONF LOG VALIDATE)};

plan skip_all => 'chybi Archive::Tar / Net::SMTP' unless (eval { require Archive::Tar; require Net::SMTP; 1 });
require Services::Email::Email;

my $EN = MockEntities->new;
my $S  = Services::Email::Email->new($CONF, $LOG, $V, undef, $EN, undef, undef);

# --- addEmailToQueue -----------------------------------------------------------
ok($S->addEmailToQueue(to => 'a@b.cz', from => 'x@y.cz', subject => 'S', text => "\n\nT", textalt => "\n\nALT", cc => 'c@d.cz'), 'addEmailToQueue vraci 1');
my $Q = $EN->last;
is($Q->{'entity'}, 'MailQueue', 'vytvari entitu MailQueue');
is($Q->{'set'}->{'mailto'},   'a@b.cz', 'mailto');
is($Q->{'set'}->{'mailfrom'}, 'x@y.cz', 'mailfrom');
is($Q->{'set'}->{'subject'},  'S',      'subject');
is($Q->{'set'}->{'text'},     "\n\nT",  'text');
is($Q->{'set'}->{'textalt'},  "\n\nALT", 'textalt se uklada (regrese: klic se ignoroval)');
is($Q->{'set'}->{'cc'},       'c@d.cz', 'cc');
is($Q->{'set'}->{'started'},  'NOW()',  'started default NOW()');
ok(!exists($Q->{'set'}->{'attachment'}), 'bez attachments se priloha nenastavuje');
is_deeply($Q->{'calls'}, ['flush', 'logit', 'commit'], 'flush, logit, commit');

$S->addEmailToQueue(to => 'a@b.cz', from => 'x@y.cz', subject => 'S', text => 'T', started => '2030-01-01 00:00:00');
is($EN->last->{'set'}->{'started'}, '2030-01-01 00:00:00', 'started z parametru');

{
    no warnings 'redefine';
    local *MockMailQueue::error = sub { 1 };
    ok(!defined($S->addEmailToQueue(to => 'bad', from => 'x@y.cz', subject => 'S', text => 'T')), 'chyba entity -> undef');
    is($EN->last->{'calls'}->[-1], 'rollback', 'pri chybe rollback');
}

# priloha: existujici soubor se zabali do tar
{
    my $file = PWE::TestEnv::app() . "ramdisk/priloha.txt";
    open(my $fh, '>', $file) or die $!;
    print $fh "obsah";
    close($fh);
    ok($S->addEmailToQueue(to => 'a@b.cz', from => 'x@y.cz', subject => 'S', text => 'T', attachments => [$file, '/neexistuje/x.txt']), 'addEmailToQueue s prilohou');
    my $tar = $EN->last->{'set'}->{'attachment'};
    ok((defined($tar) and length($tar) > 0), 'attachment obsahuje tar archiv');
    like($tar, qr/priloha\.txt/, 'tar obsahuje nazev souboru');
}

# --- updateSendResult ------------------------------------------------------------
$S->updateSendResult(7, 'Y');
is($EN->last->{'opts'}, 7, 'updateSendResult nacita radek podle mid');
is($EN->last->{'set'}->{'sendstatus'}, 'Y', 'sendstatus = Y');
is($EN->last->{'calls'}->[-1], 'commit', 'updateSendResult commit');

# --- sendErrorEmail ----------------------------------------------------------------
$CONF->{'web'}->{'email_admin'} = 'admin@test.cz';
$S->sendErrorEmail({5 => 'u@test.cz', 9 => 'v@test.cz'});
my $R = $EN->last;
is($R->{'set'}->{'mailto'}, 'admin@test.cz', 'report jde na web.email_admin');
like($R->{'set'}->{'text'}, qr/id: 5 to: u\@test\.cz/, 'report obsahuje seznam e-mailu');
like($R->{'set'}->{'text'}, qr/UPDATE mailqueue SET sendstatus = 'N', started = NOW\(\) WHERE mid = 9;/, 'SQL pro vraceni do fronty pouziva tabulku mailqueue (regrese: mail_queue)');
unlike($R->{'set'}->{'text'}, qr/mail_queue/, 'zadny odkaz na neexistujici tabulku mail_queue');

# --- getValue ----------------------------------------------------------------------
is($S->getValue('timeout_for_result_E', 1), 3 * 24 * 3600, 'getValue atribut');
is($S->getValue('nope', 'd'), 'd', 'getValue default');

done_testing();
