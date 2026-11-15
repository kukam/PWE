#!/usr/bin/env perl
# Libs::Send - konstrukce emailu bez skutecneho SMTP.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PWE::TestEnv;

PWE::TestEnv::clean_env();
require Libs::Send;

my $S = Libs::Send->new({host => 'smtp.example.test', hello => 'me.example.test', port => 2525, timeout => 3});
isa_ok($S, 'Libs::Send');
is($S->{'hello'}, 'me.example.test', 'hello se bere z klice hello (regrese: drive z host)');
is($S->{'port'}, 2525, 'port');
my $S2 = Libs::Send->new({host => 'h.example.test'});
is($S2->{'hello'}, 'h.example.test', 'hello bez klice hello = host');
is(Libs::Send->new({})->{'hello'}, 'localhost.localdomain', 'hello default');

# validace adres
ok($S->_validEmail('jan@example.cz'), '_validEmail');
ok($S->_validEmail('Jan Novak <jan@example.cz>'), '_validEmail se jmenem');
ok($S->_validEmail('a@b.museum'), '_validEmail dlouhe TLD (regrese {2,4})');
ok(!$S->_validEmail('neplatny'), '_validEmail neplatny');
ok(!$S->_validEmail('a@b'), '_validEmail bez TLD');

$S->setFrom('from@example.cz');
$S->setTo('to1@example.cz');
$S->setTo('to2@example.cz');
$S->setCc('cc@example.cz');
$S->setBcc('bcc@example.cz');
$S->setReplyTo('reply@example.cz');
$S->setReturnPath('rp@example.cz');
$S->setErrorTo('err@example.cz');
is_deeply($S->{'to'}, ['to1@example.cz', 'to2@example.cz'], 'setTo vicekrat');
ok(!defined($S->_findInvalidEmail()), '_findInvalidEmail vse platne');
$S->setCc('spatne');
is($S->_findInvalidEmail(), 'spatne', '_findInvalidEmail najde neplatnou');
like($S->send(), qr/^Invalid email address spatne/, 'send() s neplatnou adresou');
pop(@{$S->{'cc'}});

# subject
$S->setSubject('plain');
is($S->{'subject'}, 'plain', 'setSubject');
$S->setSubjectUTF8('ascii only');
is($S->{'subject'}, 'ascii only', 'setSubjectUTF8 ascii beze zmeny');
$S->setSubjectUTF8("P\x{c5}\x{99}\x{c3}\x{ad}li\x{c5}\x{a1}");
like($S->{'subject'}, qr/^=\?UTF-8\?Q\?.*\?=$/, 'setSubjectUTF8 non-ascii -> RFC2047 Q');
$S->setSubjectUTF8toASCI("P\x{c5}\x{99}\x{c3}\x{ad}li\x{c5}\x{a1}");
is($S->{'subject'}, 'Prilis', 'setSubjectUTF8toASCI');

# body
$S->setBodyPlainUTF8("Ahoj\n");
like($S->{'body'}->[0], qr{^Content-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: quoted-printable\n\n}, 'setBodyPlainUTF8 hlavicky');
$S->setBodyHtmlUTF8("<b>Ahoj</b>");
like($S->{'body'}->[1], qr{^Content-Type: text/html}, 'setBodyHtmlUTF8');
$S->setBody("Content-Type: text/plain\n\nRAW");
is(scalar(@{$S->{'body'}}), 3, 'setBody');
$S->setAttachment('/tmp/neexistuje.txt');
is_deeply($S->{'attachments'}, ['/tmp/neexistuje.txt'], 'setAttachment');

# pomocne metody
like($S->_boundry(), qr/^[a-z0-9]{29}$/, '_boundry 29 alfanumerickych znaku');
like($S->_messageID('From Name <from@example.cz>'), qr/^<\d{8}_\d{6}_\d{6}\.from\@example\.cz>$/, '_messageID');
like($S->_dateAndTime(), qr/^\w{3}, \d+ \w{3} \d{4} \d\d:\d\d:\d\d [+-]\d{4}$/, '_dateAndTime RFC format');
is($S->_encodeSubject('abc', 'UTF-8'), 'abc', '_encodeSubject ascii');

# send() bez From/To
my $S3 = Libs::Send->new({host => '127.0.0.1', port => 1, timeout => 1});
like($S3->send(), qr/From address is required/, 'send bez From');
$S3->setFrom('a@example.cz');
like($S3->send(), qr/To address is required/, 'send bez To');
$S3->setTo('b@example.cz');
like($S3->send(), qr/Could not connect to SMTP host/, 'send na nedostupny SMTP vraci chybu (ne die)');

done_testing();
