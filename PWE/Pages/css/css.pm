package Pages::css::css;

=head1 NAME

Pages::css::css - vydani CSS webu (staticky soubor nebo preklad ze SCSS)

=cut

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

=head2 B<[Public] new($self,$conf,$log,$validate,$dbi,$entities,$user,$web)>

    Stranka vraci CSS webu: bud staticky soubor (conf css.src_css = "static", soubor css.static_css),
    nebo CSS prelozene ze SCSS (css.src_css = "scss": spusti css.scss_bin nad css.scss_src
    a vysledek ulozi do css.scss_out). Volat jako ?page=css&func=default&opt=0.

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

    $self->{'func'}->{'default'} = [];

    bless $self, $class;
    return $self;
}

=head2 B<[Private] Site_Default($site)>

    Injektaz vzhledu Default (vola loader).

=cut

sub Site_Default {
    my ($self, $input) = @_;
    $WEB = $input;
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

    Vytiskne hlavicku text/css a obsah CSS (viz popis stranky).

=cut

sub default {
    my $self = shift;

    $WEB->printHttpHeader('type' => 'css');

    my $out        = undef;
    my $home       = $CONF->getValue("pwe", "home");
    my $src_css    = $CONF->getValue("css", "src_css", "static");
    my $scss_bin   = $CONF->getValue("css", "scss_bin", "/usr/bin/sass -C --scss --style=compressed");
    my $scss_src   = $CONF->getValue("css", "scss_src", "/static/scss/site.scss");
    my $scss_out   = $CONF->getValue("css", "scss_out", "/static/css/site.css");
    my $static_css = $CONF->getValue("css", "static_css", "/static/css/site.css");

    if ($src_css eq "static") {

        open(CSS, "$home/$static_css") || die "Failed: $!\n";
        while (<CSS>) { print $_; }
        close(CSS);

    } elsif ($src_css eq "scss") {

        my $css = "";
        open($out, "$scss_bin $home$scss_src |") || die "Failed: $!\n";
        while (<$out>) {
            print $_;
            $css = "$css$_";
        }
        close($out);

        my $out = undef;
        open($out, "> $home/$scss_out") || die "Failed: $!\n";
        print $out $css;
        close($out);
    } else {
        print "Unknown src_css:$src_css !!!\n";
    }
}

1;
