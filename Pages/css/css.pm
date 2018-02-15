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
    my $less_bin   = $CONF->getValue("css", "less_bin", "/usr/bin/lessc");
    my $less_src   = $CONF->getValue("css", "less_src", "/assets/less/main/main.less");
    my $less_out   = $CONF->getValue("css", "less_out", "/assets/css/less-out.css");
    my $static_css = $CONF->getValue("css", "static_css", "/assets/css/less-out.css");

    if ($src_css eq "static") {

        open(CSS, "$home/$static_css") || die "Failed: $!\n";
        while (<CSS>) { print $_; }
        close(CSS);

    } elsif ($src_css eq "less") {

        my $css = "";
        open($out, "$less_bin $home$less_src |") || die "Failed: $!\n";
        while (<$out>) {
            print $_;
            $css = "$css$_";
        }
        close($out);

        my $out = undef;
        open($out, "> $home/$less_out") || die "Failed: $!\n";
        print $out $css;
        close($out);
    } else {
        print "Unknown src_css:$src_css !!!\n";
    }
}

1;
