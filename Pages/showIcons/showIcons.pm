package Pages::showIcons::showIcons;

use strict;
use JSON;

=Zavislost

    * bootstrap.css / less
    * icomoon.css / less
    * entypo.css / less

    * jquery.js
    * bootstrap.js
    * pwe.js

=cut

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

    $self->{'access'} = ['admin'];

    $self->{'func'}->{'default'}               = [];
    $self->{'func'}->{'awesome_674_20150914'}  = [];

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

    my $idp = "showIcons";

    # SET ID Page
    $WEB->setIDP($idp);
    $WEB->printHttpHeader();
    $WEB->printHtmlHeader();
    $WEB->printHtmlLayout(html_main => "Pages/showIcons/main.html");
}

sub awesome_674_20150914 {
    my $self = shift;

    my $idp = "showIcons_awesome_674_20150914";

    my $home = $CONF->getValue("pwe", "home", "/tmp");
    my $map = $self->getJSONHash($home . "/assets/less/awesome_674_20150914/map.json");
    
    $WEB->printHttpHeader('type' => 'ajax');
    $WEB->printAjaxLayout(
        ajax_id   => ['awesome_674_20150914'],
        ajax_tmpl => ["Pages/showIcons/list.html"],
        ajax_data => {
            class_prefix => "fa",
            map          => $map,
        }
    );
}

sub getJSONHash {
    my ($self, $file) = @_;
    
    unless(-f $file) {
        $LOG->error("Json file not exist!");
        return {};
    } else {
        $LOG->info("Read json file: ".$file);
        local $/;    #Enable 'slurp' mode
        open my $fh, "<", $file;
        my $json = <$fh>;
        close $fh;
        return decode_json($json);
    }
}

1;
