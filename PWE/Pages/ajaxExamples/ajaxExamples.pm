package Pages::ajaxExamples::ajaxExamples;

=head1 NAME

Pages::ajaxExamples::ajaxExamples - ukazky AJAX volani (nahrada HTML, presmerovani, chyby)

=cut

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

=head2 B<[Public] new($self,$conf,$log,$validate,$dbi,$entities,$user,$web)>

    Ukazkova stranka AJAX volani (spoluprace s assets/javascript/pwe.js): nahrada HTML
    jednoho/vice elementu, presmerovani z AJAXu a chybove stavy s messengerem.

=cut

sub new {
    my ($class, $self, $conf, $log, $validate, $dbi, $entities, $user, $web) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $CONF     = $conf;
    $USER     = $user;
    $WEB      = $web;
    $VALIDATE = $validate;
    $ENTITIES = $entities;

    $self->{'func'}->{'default'}                = [];
    $self->{'func'}->{'replaceHTMLSimple'}      = [];
    $self->{'func'}->{'replaceHTML'}            = [];
    $self->{'func'}->{'redirectAjax'}           = [];
    $self->{'func'}->{'redirectAjax2'}          = [];
    $self->{'func'}->{'replaceHTMLSimpleError'} = [];
    $self->{'func'}->{'replaceHTMLError'}       = [];

    bless $self, $class;
    return $self;
}

=head2 B<[Private] Site_Default($site)>

    Injektaz vzhledu Default (vola loader).

=cut

sub Site_Default {
    my ($self, $input) = @_;
    $WEB = $input;
    return undef;
}

=head2 B<[Private] KOMODO()>

    Mrtvy kod pro IDE (Komodo/VS Code), aby umelo doplnit typy globalnich promennych.
    Nikdy se nevola - prvni prikaz je return.

=cut

# KOMODO-IDE/KOMODO-EDIT
sub KOMODO {
    return;
    require Libs::Config;
    require Libs::Log;
    require Libs::Validate;
    require Libs::DBI;
    require Libs::Entities;
    require Libs::User;
    require Sites::Default::Default;
    $CONF     = new Libs::Config;
    $LOG      = new Libs::Log;
    $VALIDATE = new Libs::Validate;
    $DBI      = new Libs::DBI;
    $ENTITIES = new Libs::Entities;
    $USER     = new Libs::User;
    $WEB      = new Sites::Default::Default;
}

=head2 B<[Public] default()>

    Vykresli Pages/ajaxExamples/main.html s tlacitky pro jednotlive ukazky.

=cut

sub default {
    my $self = shift;

    my $idp = "ajaxExamples";

    # SET ID Page
    $WEB->setIDP($idp);
    $WEB->printHttpHeader();
    $WEB->printHtmlHeader();
    $WEB->printHtmlLayout(html_main => "Pages/ajaxExamples/main.html",);
}

=head2 B<[Public] replaceHTMLSimple()>

    Jednoduchy AJAX: vrati holy HTML fragment (bez JSON), klient ho vlozi do elementu.

=cut

sub replaceHTMLSimple {
    my $self = shift;

    $WEB->printHttpHeader();
    print $self->getRandomSpan();
}

=head2 B<[Public] replaceHTML()>

    Plny AJAX: printAjaxLayout s ajax_id/ajax_html nahradi obsah dvou elementu najednou.

=cut

sub replaceHTML {
    my $self = shift;

    $WEB->printHttpHeader('type' => 'ajax');
    $WEB->printAjaxLayout(
        ajax_id => ['replaceHTML_I', 'replaceHTML_II'],
        ajax_html => [$self->getRandomSpan(), $self->getRandomSpan(), $self->getRandomSpan(), $self->getRandomSpan()]
    );
}

=head2 B<[Public] redirectAjax()>

    AJAX presmerovani (hlavicka AjaxRedirect) na hlavni stranku.

=cut

sub redirectAjax {
    my $self = shift;
    $WEB->printHttpHeader('type' => 'ajax_redirect', 'redirect_link' => $WEB->getScriptName());
}

=head2 B<[Public] redirectAjax2()>

    AJAX presmerovani s nastavenym messengerem (zprava se zobrazi po presmerovani).

=cut

sub redirectAjax2 {
    my $self = shift;
    $WEB->setMessenger("Pages/ajaxExamples/msg.html", msg_allright => ['ok_redirect2']);
    $WEB->printHttpHeader('type' => 'ajax_redirect', 'redirect_link' => $WEB->getScriptName());
}

=head2 B<[Public] replaceHTMLSimpleError()>

    Ukazka chyby: nastavi messenger a vrati 500 (pwe.fcgi zavola errorPage e500).

=cut

sub replaceHTMLSimpleError {
    my $self = shift;

    $WEB->setMessenger("Pages/ajaxExamples/msg.html", msg_error => ['error_replaceHtmlSimple']);

    return 500;
}

=head2 B<[Public] replaceHTMLError()>

    Ukazka chyby pro plny AJAX: nastavi messenger a vrati 500.

=cut

sub replaceHTMLError {
    my $self = shift;

    $WEB->setMessenger("Pages/ajaxExamples/msg.html", msg_error => ['error_replaceHtml']);

    return 500;
}

=head2 B<[Private] getRandomSpan()>

    Vraci <span> s nahodnou Bootstrap 5 tridou badge text-bg-* a aktualnim casem (testovaci obsah).

=cut

sub getRandomSpan {
    my $self = shift;
    my $map  = {
        1 => "text-bg-secondary",
        2 => "text-bg-primary",
        3 => "text-bg-success",
        4 => "text-bg-info",
        5 => "text-bg-warning",
        6 => "text-bg-danger"
    };
    return '<span class="badge ' . $map->{(int(rand(6)) + 1)} . '">' . time() . '</span>';
}

1;
