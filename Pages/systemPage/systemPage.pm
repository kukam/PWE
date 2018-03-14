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
    
    my $asset = $CONF->getValue('pwe','assets_dir','assets/');
    return 401 if($USER->getEnv('SCRIPT_FILENAME',undef) !~ /^[\.\/]?\Q$asset\E.*/);
    
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
    
    my $asset = $CONF->getValue('pwe','assets_browse_dir','assets/browsable/');
    my $home = $CONF->getValue('pwe','home','');
    my $dir = $USER->getEnv('SCRIPT_FILENAME',undef);
    return 401 if($dir !~ /^[\.\/]?\Q$asset\E.*/);
    
    my $table = {};
    opendir(LISTDIR, $home.$dir) || die "Can't open $dir: $!";
    while (readdir LISTDIR) {
        next if ($_ =~ m/^\./);
        my $size = 0;
        my $name = $_;
        my $type = "F";
        my $modified = localtime((stat $home.$dir.$name)[9]);
        if(-f $home.$dir.$_) {
            $size = scaledbytes((stat $home.$dir.$name)[7]);
        } else {
            $type = "D";
            $name .= "/";
        }
        push(@{$table->{'rows'}}, { name => "$name", type => $type, date => "$modified", size => "$size"});
    }
    closedir LISTDIR;

    # SET ID Page
    $WEB->setIDP('list_directory');
    $WEB->printHttpHeader();
    $WEB->printHtmlHeader(layout_header => "templates/LayoutHeader.html", title => $dir);
    $WEB->printHtmlLayout(layout_body => "templates/LayoutBody.html", html_main => "Pages/systemPage/list.html", basedir => "/".$asset, dir => $dir, table => $table);
    #$dname =~ s{\.[^.]+$}{};
    return 200;
}

sub scaledbytes {
   (sort { length $a <=> length $b }
   map { sprintf '%.3g%s', $_[0]/1024**$_->[1], $_->[0] }
   [" bytes"=>0],[KB=>1],[MB=>2],[GB=>3],[TB=>4],[PB=>5],[EB=>6])[0]
}

1;
