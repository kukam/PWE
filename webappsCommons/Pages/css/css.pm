package Pages::css::css;

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

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

sub Site_Default {
    my ($self, $input) = @_;
    $WEB = $input;
}

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

sub default {
    my $self = shift;

    $WEB->printHttpHeader('type' => 'css');

    my $out        = undef;
    my $home       = $CONF->getValue("pwe", "home");
    my $src_css    = $CONF->getValue("css", "src_css", "static");
    my $scss_bin   = $CONF->getValue("css", "scss_bin", "/usr/bin/sass -C --scss --style=compressed");
    my $scss_src   = $CONF->getValue("css", "scss_src", "/assets/scss/main/main.less");
    my $scss_out   = $CONF->getValue("css", "scss_out", "/assets/css/less-out.css");
    my $static_css = $CONF->getValue("css", "static_css", "/assets/css/less-out.css");

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
