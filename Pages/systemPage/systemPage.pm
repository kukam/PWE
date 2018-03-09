package Pages::systemPage::systemPage;

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

sub new {
    my ($class, $self, $conf, $log, $validate, $dbi, $entities, $user, $web) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $WEB      = $web;
    $CONF     = $conf;
    $USER     = $user;
    $VALIDATE = $validate;
    $ENTITIES = $entities;

    $self->{'func'}->{'file'} = [];
    $self->{'func'}->{'folder'} = [];

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

sub file {
    my $self = shift;

    my $idp = "default";

    # SET ID Page
    $WEB->setIDP($idp);
    
    my $file = $CONF->getValue('pwe','home','').$USER->getEnv('SCRIPT_FILENAME',undef);
    
    my $fshort = $file;
    $fshort =~ s{.*/}{};
    
    if($file =~ /\.js$/) {
        $WEB->printHttpHeader('type' => 'js');
    } elsif ($file =~ /\.css$/) {
        $WEB->printHttpHeader('type' => 'css');
    } else {
        $WEB->printHttpHeader('type' => 'file', filename => $fshort);
    }
    
    if ( open (FILE, "<", $file)) {
        binmode FILE;
        print <FILE>;
        close (FILE);
    } else {
        print "sorry, cannot open file!"
    }

}

sub folder {
    my $self = shift;
    my $folder = $CONF->getValue('pwe','home','').$USER->getEnv('SCRIPT_FILENAME',undef);
    #$dname =~ s{\.[^.]+$}{};
    return 404;
}

1;
