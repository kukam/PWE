#!/usr/bin/env perl

=head1 NAME

debug.cgi - vstupni bod enginu PWE pro ladeni (debugger ve VS Code, nginx location /debug.cgi)

=head1 POPIS

    Spusti presne tentyz kod jako pwe.fcgi, jen pod jmenem debug.cgi. Engine totiz povazuje
    request za stranku jen tehdy, kdyz se SCRIPT_FILENAME shoduje s nazvem spusteneho skriptu
    (basename $0) - jinak hleda staticky soubor. Vyvojovy nginx (docker-compose/docker-compose_nginx.conf)
    posila URL /debug.cgi do kontejneru pwe-debugger-1, kde tento skript bezi pod debuggerem
    a posloucha FastCGI na FCGI_SOCKET_PATH (:7779). Protoze se skript jmenuje debug.cgi,
    vedou i odkazy generovane na strankach (script_name) zpet na /debug.cgi, takze cele
    prochazeni webu zustava v ladenem procesu, zatimco /pwe.fcgi dal obsluhuji bezne procesy.

    Pouziti (viz docs/16-nastroje.md, Debugger ve VS Code):
        make run WEB=<web> PROFILE=<profil> ARGS=-d
        VS Code F5 (.vscode/launch.json: "program": "${workspaceFolder}/PWE/debug.cgi")
        http://127.0.0.1:7778/debug.cgi?page=<stranka>&func=<akce>

    Rucne v kontejneru (jeden request v CGI rezimu, z adresare webu). V kontejnerech compose
    stacku je nastavene FCGI_SOCKET_PATH, proto se musi odstranit - jinak by skript misto
    jednoho requestu zacal poslouchat na socketu:
        env -u FCGI_SOCKET_PATH SCRIPT_FILENAME=/debug.cgi REQUEST_METHOD=GET \
            QUERY_STRING='page=default' perl /PWE/PWE/debug.cgi

    Jak se lisi od primeho spusteni pwe.fcgi:
      - pwe.fcgi se nacita pres require s absolutni cestou, takze $0 zustava debug.cgi,
        debugger vidi pwe.fcgi pod skutecnou cestou a breakpointy nastavene v PWE/pwe.fcgi
        pred startem se aktivuji (perl vola DB::postponed jen pro require, ne pro do FILE);
        skript jde spustit odkudkoliv i relativni cestou (perl PWE/debug.cgi).
      - Jen pod debuggerem (perl -d, $^P): cekani na dalsi request (CGI::Fast->new) se po
        preruseni signalem INT zopakuje. VS Code posila ladenemu procesu INT pri kazdem
        pridani nebo odebrani breakpointu a pri Pause; FastCGI accept by se tim prerusil,
        smycka enginu by skoncila a ladeny server by se ukoncil. Signal TERM (a bez debuggeru
        i INT / Ctrl-C) ukoncuje server beze zmeny.

=cut

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;

my $engine = File::Spec->rel2abs(dirname(__FILE__)) . "/pwe.fcgi";
die "debug.cgi: engine $engine neexistuje nebo neni citelny\n" unless (-r $engine);

if ($^P) {
    require CGI::Fast;
    my $accept = \&CGI::Fast::new;
    no warnings 'redefine';
    *CGI::Fast::new = sub {
        my @args = @_;
        while (1) {
            my $interrupted = 0;
            my $debugger    = $SIG{'INT'};    # handler debuggeru (zastaveni / aktivace breakpointu)
            local $SIG{'INT'} = sub { $interrupted = 1; $debugger->(@_) if (ref($debugger) eq 'CODE'); };
            my $cgi = $accept->(@args);
            return $cgi if (defined($cgi) or !$interrupted);    # request, nebo skutecny konec (TERM)
        }
    };
}

require $engine;
