#!/usr/bin/env perl

=head1 NAME

PWE/tools/smtp-test.pl - odesle jeden testovaci e-mail pres SMTP server z konfigurace webu (Libs::Send)

=head1 POUZITI

    Z korene repozitare (PWE/ je adresar enginu):
        PWE/tools/smtp-test.pl <web> [--to adresa] [--from adresa] [--server smtp_primary]
                                      [--env-file cesta] [--debug] [--dry-run]
        make smtp-test WEB=<web> ARGS='--to vas@email.cz'

    Nacte konfiguraci webu stejne jako engine (Libs::Config vcetne prepisu PWE_CONF_*), navic
    nacte promenne ze souboru --env-file (vychozi <web>/conf/local.env, pokud existuje - stejny
    soubor cte docker compose), vypise vysledne SMTP nastaveni (heslo maskovane) a posle kratky
    testovaci e-mail. --dry-run jen vypise nastaveni a nic neposila. --debug zapne vypis SMTP
    dialogu (Net::SMTP Debug) na STDERR - pozor, obsahuje AUTH.

    Odesilatel: --from, jinak web.email_from, web.company_email, web.email_admin.
    Prijemce:   --to, jinak web.email_admin.

    Navratovy kod 0 = odeslano (nebo dry-run), 1 = chyba (konfigurace, pripojeni, odmitnuti).
    Mimo kontejner se skript sam spusti v kontejneru s image nastroju (chybejici moduly; vychozi
    ghcr.io/kukam/pwe-debugger:<aktualni vetev>, zmena pres PWE_IMAGE_TAG / PWE_IMAGE_REGISTRY /
    PWE_TEST_IMAGE, viz PWE::ToolEnv::docker_image()), takze SMTP server musi byt dosazitelny
    z kontejneru - vyvojovy "mailpit" z compose site odtud dosazitelny neni, pro nej spustte skript
    uvnitr: docker compose exec fcgi perl /PWE/PWE/tools/smtp-test.pl /PWE/webapps/<web>

=cut

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Getopt::Long qw(GetOptions);
use POSIX qw(strftime);
use PWE::ToolEnv qw(core_root resolve_webapp webapp_name ensure_modules);

my %opt = (server => 'smtp_primary');
GetOptions(\%opt, 'to=s', 'from=s', 'server=s', 'env-file=s', 'debug', 'dry-run', 'help|h') or usage(1);
usage(0) if ($opt{'help'});
my $arg = shift(@ARGV) or usage(1);

ensure_modules('Net::SMTP', 'IO::Socket::SSL', 'Authen::SASL', 'Mail::RFC822::Address', 'Cz::Cstocs');

my $CORE = core_root();    # koren enginu (adresar PWE/ v repozitari)
my $APP  = resolve_webapp($arg);
die "Webapp $APP neexistuje nebo nema conf/web.conf\n" unless (-f "$APP/conf/web.conf");

# promenne prostredi z lokalniho souboru (KEY=VALUE, # komentare), stejne jako compose env_file
my $envfile = (defined($opt{'env-file'}) ? $opt{'env-file'} : "$APP/conf/local.env");
if (-f $envfile) {
    open(my $fh, '<', $envfile) or die "Nelze cist $envfile: $!\n";
    while (my $line = <$fh>) {
        chomp($line);
        next if ($line =~ /^\s*(#|$)/);
        next unless ($line =~ /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/);
        my ($k, $v) = ($1, $2);
        $v =~ s/^(["'])(.*)\1$/$2/;
        $ENV{$k} = $v;
    }
    close($fh);
    print "---- promenne z $envfile nacteny\n";
} elsif (defined($opt{'env-file'})) {
    die "Soubor $envfile neexistuje\n";
}

$ENV{'PWE_CONF_pwe_home'} = "$APP/";
$ENV{'PWE_CONF_pwe_core'} = "$CORE/";

unshift(@INC, $CORE);
require Libs::Config;
require Libs::Send;

my $CONF = Libs::Config->new("$APP/", 'pwe.fcgi', 'conf/web.conf', 'conf/database.conf');

my $servers = $CONF->getValue('pwe', 'smtp_servers', []);
my $smtp    = $CONF->getValue($opt{'server'}, undef, undef);
die "Sekce '$opt{'server'}' v conf/web.conf neexistuje (pwe.smtp_servers = [" . join(', ', @{$servers}) . "])\n" unless (ref($smtp) eq 'HASH');
print "---- web: " . webapp_name($APP) . ", SMTP sekce: $opt{'server'}" . ((grep { $_ eq $opt{'server'} } @{$servers}) ? '' : " (POZOR: neni v pwe.smtp_servers, fronta Services::Email ji nepouzije)") . "\n";

my $from = $opt{'from'};
foreach my $key (qw(email_from company_email email_admin)) {
    last if (defined($from) and length($from));
    $from = $CONF->getValue('web', $key, undef);
}
my $to = (defined($opt{'to'}) ? $opt{'to'} : $CONF->getValue('web', 'email_admin', undef));
die "Chybi adresa prijemce (--to nebo web.email_admin)\n" unless (defined($to) and length($to));
die "Chybi adresa odesilatele (--from nebo web.email_from / company_email / email_admin)\n" unless (defined($from) and length($from));

foreach my $key (qw(host port ssl starttls authid authpw timeout hello debug)) {
    my $v = $smtp->{$key};
    $v = ($key eq 'authpw' and defined($v) and length($v)) ? ('*' x 8) : (defined($v) ? $v : '(nenastaveno)');
    printf("%-10s %s\n", "$key:", $v);
}
printf("%-10s %s\n%-10s %s\n", 'from:', $from, 'to:', $to);
print "POZOR: ssl i starttls zaroven - obvykle je spravne jen jedno (465 = ssl, 587 = starttls)\n" if ($smtp->{'ssl'} and $smtp->{'starttls'});
print "POZOR: authid bez hesla\n" if (defined($smtp->{'authid'}) and length($smtp->{'authid'}) and !(defined($smtp->{'authpw'}) and length($smtp->{'authpw'})));

if ($opt{'dry-run'}) {
    print "---- dry-run: nic se neodesila\n";
    exit(0);
}

my %conf = %{$smtp};
$conf{'debug'} = 1 if ($opt{'debug'});

my $send = Libs::Send->new(\%conf);
my $now  = strftime('%Y-%m-%d %H:%M:%S', localtime());
$send->setFrom($from);
$send->setTo($to);
$send->setSubjectUTF8("PWE test e-mail (" . webapp_name($APP) . ") $now");
$send->setBodyPlainUTF8("Testovací e-mail z enginu PWE.\n\nWeb: " . webapp_name($APP) . "\nSMTP: $smtp->{'host'}:$smtp->{'port'}" . ($smtp->{'ssl'} ? ' (SSL)' : '') . ($smtp->{'starttls'} ? ' (STARTTLS)' : '') . "\nČas: $now\n\nPokud tento e-mail čtete, odesílání z webu funguje.\n");
$send->setBodyHtmlUTF8("<p>Testovací e-mail z enginu <strong>PWE</strong>.</p><p>Web: " . webapp_name($APP) . "<br>SMTP: $smtp->{'host'}:$smtp->{'port'}<br>Čas: $now</p><p>Pokud tento e-mail čtete, odesílání z webu funguje.</p>");

print "---- odesilam ...\n";
my $result = $send->send();
if (defined($result)) {
    $result =~ s/\s+$//;
    print "FAIL $result\n";
    print "     Nejcastejsi priciny: spatny port/ssl/starttls, heslo (Gmail vyzaduje heslo aplikace), server neni z kontejneru dosazitelny.\n";
    exit(1);
}
print "OK   e-mail odeslan na $to pres $smtp->{'host'}:$smtp->{'port'}\n";
exit(0);

sub usage {
    my ($rc) = @_;
    print STDERR "Pouziti: PWE/tools/smtp-test.pl <web> [--to adresa] [--from adresa] [--server smtp_primary] [--env-file cesta] [--debug] [--dry-run]\n";
    exit($rc);
}
