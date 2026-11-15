#!/usr/bin/env perl
# Sdilene UI sablony enginu (Bootstrap 5): messenger, DBTable pagination/pager/orderby, chybovy layout.
# Renderuje se pres Libs::Web::genTmpl nad fixture webem app2 (dva koreny -> sablony z PWE/).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use PWE::TestEnv;

my $ROOT = PWE::TestEnv::root();
plan skip_all => 'chybi Template' unless (eval { require Template; 1 });

my $E = PWE::TestEnv->boot(app => PWE::TestEnv::app2(), core => $ROOT);
my ($W, $P) = @{$E}{qw(WEB PAGES)};
PWE::TestEnv::request($E, page => 'tPage2', func => 'default');

my $bs3 = qr/btn-default|panel-|form-group|control-label|glyphicon|data-toggle=|data-dismiss=|sr-only|col-sm-offset|class="close"|class="pager"/;

# --- messenger.html ------------------------------------------------------------------------------
my $m = $W->genTmpl('templates/messenger.html', msg_error => ['error_x'], msg => {error_x => 'Spatne'});
like($m, qr/alert alert-danger alert-dismissible/, 'messenger error: Bootstrap 5 alert');
like($m, qr/btn-close/, 'messenger: tlacitko btn-close');
like($m, qr/data-bs-dismiss="alert"/, 'messenger: data-bs-dismiss');
like($m, qr/<li>Spatne<\/li>/, 'messenger: text zpravy');
unlike($m, $bs3, 'messenger: zadne tridy Bootstrap 3');
$m = $W->genTmpl('templates/messenger.html', msg_allright => ['ok_x'], msg => {ok_x => 'Dobre'});
like($m, qr/alert alert-success alert-dismissible/, 'messenger allright: Bootstrap 5 alert');
like($m, qr/<li>Dobre<\/li>/, 'messenger allright: text');
# regrese: titulek boxu z rb.messanger_*_title vzhledu (chybova vetev fallback nemela, uspesna testovala spatny klic)
$m = $W->genTmpl('templates/messenger.html', msg_error => ['error_x'], msg => {error_x => 'Spatne'}, rb => {messanger_error_title => 'TitulekChyby'});
like($m, qr/<strong>TitulekChyby<\/strong>/, 'messenger error: titulek z rb.messanger_error_title (fallback vzhledu)');
$m = $W->genTmpl('templates/messenger.html', msg_allright => ['ok_x'], msg => {ok_x => 'Dobre'}, rb => {messanger_allright_title => 'TitulekOK'});
like($m, qr/<strong>TitulekOK<\/strong>/, 'messenger allright: titulek z rb.messanger_allright_title');

# --- Services/DBTable/pagination.html ------------------------------------------------------------------
my %table = (id => 5, gopage => 2, endpage => 3, pagelist => [1, 2, 3], nlimit => 10, script => 'pwe.fcgi?page=x&func=default', appendurl => '', ordercolumn => 'uid', orderby => 'ASC');
my $pg = $W->genTmpl('Services/DBTable/pagination.html', table => \%table);
like($pg, qr/<ul class="pagination">/, 'pagination: ul.pagination');
my $items = () = $pg =~ /class="page-item/g;
is($items, 5, 'pagination: 5 polozek (zpet, 1, 2, 3, dal)');
like($pg, qr/class="page-item active" aria-current="page">.*?gopage=2/s, 'pagination: aktivni strana 2');
like($pg, qr/visually-hidden/, 'pagination: visually-hidden misto sr-only');
unlike($pg, $bs3, 'pagination: zadne tridy Bootstrap 3');
$table{'gopage'} = 1;
$pg = $W->genTmpl('Services/DBTable/pagination.html', table => \%table);
like($pg, qr/page-item disabled".*?&laquo;/s, 'pagination: na prvni strane je "zpet" disabled');
$table{'endpage'} = 1;
$pg = $W->genTmpl('Services/DBTable/pagination.html', table => \%table);
unlike($pg, qr/pagination/, 'pagination: jedna strana -> nic');

# --- Services/DBTable/pager.html ---------------------------------------------------------------------------
%table = (id => 5, gopage => 2, endpage => 3, script => 'pwe.fcgi?page=x&func=default', appendurl => '');
my $pager = $W->genTmpl('Services/DBTable/pager.html', table => \%table);
like($pager, qr/<ul class="pagination justify-content-between">/, 'pager: Bootstrap 5 pagination (BS5 nema .pager)');
my $links = () = $pager =~ /class="page-link"/g;
is($links, 2, 'pager: dva odkazy');
like($pager, qr/gopage=1.*gopage=3/s, 'pager: odkazy na predchozi a dalsi stranu');
unlike($pager, qr/disabled/, 'pager: uprostred nic neni disabled');
$table{'gopage'} = 3;
$pager = $W->genTmpl('Services/DBTable/pager.html', table => \%table);
like($pager, qr/page-item disabled".*?&rarr;/s, 'pager: na posledni strane je "dalsi" disabled');

# --- Services/DBTable/orderby.html -------------------------------------------------------------------------
%table = (id => 5, script => 'pwe.fcgi?page=x&func=default', appendurl => '', ordercolumn => 'uid', orderby => 'ASC');
my $ob = $W->genTmpl('Services/DBTable/orderby.html', table => \%table, thname => 'UID', ordercolumn => 'uid');
like($ob, qr/fa-solid fa-sort-up/, 'orderby: ikona Font Awesome pro aktivni sloupec');
like($ob, qr/orderby=DESC/, 'orderby: odkaz prepina razeni');
unlike($ob, qr/glyphicon/, 'orderby: bez glyphicons');
$ob = $W->genTmpl('Services/DBTable/orderby.html', table => \%table, thname => 'NAME', ordercolumn => 'name');
unlike($ob, qr/fa-sort/, 'orderby: neaktivni sloupec bez ikony');

# --- chybova stranka (LayoutErrorHeader/Body) -------------------------------------------------------------------
PWE::TestEnv::request($E, page => 'errorPage', func => 'e404', env => {REQUEST_URI => '/nic'});
my ($out) = PWE::TestEnv::capture(sub { $P->callPageFunc('errorPage', 'e404') });
like($out, qr/bootstrap-5\.3\.8\/bootstrap\.min\.css/, 'errorPage: Bootstrap 5.3.8 css');
like($out, qr/jquery-4\.0\.0\/jquery-4\.0\.0\.min\.js/, 'errorPage: jQuery 4.0.0');
like($out, qr/<div class="container py-4">/, 'errorPage: telo v kontejneru');
unlike($out, $bs3, 'errorPage: zadne tridy Bootstrap 3');
PWE::TestEnv::finish($E);

# --- pwe.js: AjaxFormAppender po uspechu neodroluje nepodminene (regrese: kazde "Do kosiku" skocilo nahoru) ---
{
    open(my $fh, '<', "$ROOT/assets/javascript/pwe.js") or die $!;
    local $/;
    my $js = <$fh>;
    close($fh);
    my ($done) = $js =~ /function AjaxFormAppender[\s\S]*?\.done\(function\s*\([^)]*\)\s*\{([\s\S]*?)\}\);/;
    ok(defined($done), 'pwe.js: AjaxFormAppender ma .done() handler');
    unlike($done || '', qr/scrollToMessenger\(\)/, 'AjaxFormAppender .done(): zadny nepodmineny scrollToMessenger (scroll ridi success handler podle messengeru)');
    like($done || '', qr/\.reset\(\)/, 'AjaxFormAppender .done(): formular se vynuluje');
    like($js, qr/disablescrolltomessenger/, 'pwe.js: success handler respektuje #disablescrolltomessenger');
}

# --- assety enginu existuji -----------------------------------------------------------------------------------
ok(-f "$ROOT/assets/css/bootstrap-5.3.8/bootstrap.min.css", 'PWE/assets: bootstrap-5.3.8 css');
ok(-f "$ROOT/assets/javascript/bootstrap-5.3.8/bootstrap.bundle.min.js", 'PWE/assets: bootstrap-5.3.8 bundle js');
ok(-f "$ROOT/assets/javascript/jquery-4.0.0/jquery-4.0.0.min.js", 'PWE/assets: jquery-4.0.0');
ok(-f "$ROOT/assets/css/fontawesome-free-6.4.2/all.min.css", 'PWE/assets: Font Awesome 6.4.2');
ok(!-e "$ROOT/assets/css/bootstrap-3.2.0" && !-e "$ROOT/assets/javascript/jquery-1.11.1", 'stare knihovny odstraneny');
ok(!-e "$ROOT/Pages/NewBootstrap523" && !-e "$ROOT/Sites/NewBootstrap523", 'NewBootstrap523 odstranen');

done_testing();
