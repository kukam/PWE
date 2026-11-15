package Pages::systemPage::systemPage;

=head1 NAME

Pages::systemPage::systemPage - servirovani statickych souboru a vypis adresaru (kdyz to nedela webserver)

=cut

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

# Content-Type podle pripony pro staticke soubory (file()). Co tu neni, se posila jako priloha
# (application/octet-stream + Content-disposition: attachment).
my %MIME = (
    'css'   => 'text/css; charset=UTF-8',
    'js'    => 'application/javascript; charset=UTF-8',
    'mjs'   => 'application/javascript; charset=UTF-8',
    'map'   => 'application/json; charset=UTF-8',
    'json'  => 'application/json; charset=UTF-8',
    'txt'   => 'text/plain; charset=UTF-8',
    'csv'   => 'text/csv; charset=UTF-8',
    'xml'   => 'application/xml; charset=UTF-8',
    'html'  => 'text/html; charset=UTF-8',
    'htm'   => 'text/html; charset=UTF-8',
    'svg'   => 'image/svg+xml',
    'png'   => 'image/png',
    'jpg'   => 'image/jpeg',
    'jpeg'  => 'image/jpeg',
    'gif'   => 'image/gif',
    'webp'  => 'image/webp',
    'avif'  => 'image/avif',
    'bmp'   => 'image/bmp',
    'ico'   => 'image/x-icon',
    'woff'  => 'font/woff',
    'woff2' => 'font/woff2',
    'ttf'   => 'font/ttf',
    'otf'   => 'font/otf',
    'eot'   => 'application/vnd.ms-fontobject',
    'pdf'   => 'application/pdf',
    'mp3'   => 'audio/mpeg',
    'mp4'   => 'video/mp4',
    'webm'  => 'video/webm',
    'wasm'  => 'application/wasm',
);

=head2 B<[Public] new($self,$conf,$log,$validate,$dbi,$entities,$user,$web)>

    Systemova stranka pro servirovani statickych souboru a vypis adresaru, kdyz pred enginem
    neni webserver, ktery by to delal sam (nginx/FastCGI primo). Vola ji pwe.fcgi, pokud
    SCRIPT_FILENAME ukazuje na existujici soubor (file) nebo adresar (folder) pod pwe.home.

=cut

sub new {
    my ($class, $self, $conf, $log, $validate, $dbi, $entities, $user, $web) = @_;

    $DBI      = $dbi;
    $LOG      = $log;
    $WEB      = $web;
    $CONF     = $conf;
    $USER     = $user;
    $VALIDATE = $validate;
    $ENTITIES = $entities;

    $self->{'func'}->{'file'}   = [];
    $self->{'func'}->{'folder'} = [];

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

=head2 B<[Public] file()>

    Odesle soubor z SCRIPT_FILENAME. Povoleny jsou jen cesty z conf pwe.assets_dir (adresare)
    a pwe.assets_file (konkretni soubory), jinak 401. Soubor se hleda nejdrive ve webu
    (pwe.home), pak v enginu (pwe.core) - sdilena statika enginu (assets/) tak nemusi byt ve webu.
    Content-Type se urci podle pripony z mapy %MIME (css, js, obrazky, fonty, pdf, ...) a soubor se
    posle inline bez session cookie s cache hlavickou (templates/HttpHeaderStatic.tmpl); nezname
    pripony jdou jako priloha (application/octet-stream). Soubor se cte po 64 kB blocich. V produkci
    je lepsi nechat assets/ a static/ servirovat primo webserverem (viz docker-compose/docker-compose_nginx.conf).

=cut

sub file {
    my $self = shift;

    my $idp = "read_file";

    # SET ID Page
    $WEB->setIDP($idp);

    my $scriptname = $USER->getEnv('SCRIPT_FILENAME', undef);

    return 401 if (!$self->checkassets($scriptname, 'assets_dir') and !$self->checkassets($scriptname, 'assets_file'));

    # soubor se hleda ve webu (pwe.home), pak v enginu (pwe.core) - napr. assets/javascript/pwe.js
    my $home = $CONF->resolveFile($scriptname);
    return 404 unless (defined($home));

    my $file = $home . $scriptname;

    my $fshort = $file;
    $fshort =~ s{.*/}{};

    my ($ext) = ($fshort =~ /\.([A-Za-z0-9]+)$/);
    my $mime = (defined($ext) ? $MIME{lc($ext)} : undef);

    if ($mime) {
        # znamy typ: inline, bez cookie, s cache hlavickou (templates/HttpHeaderStatic.tmpl)
        $WEB->printHttpHeader('type' => 'static', 'content_type' => $mime);
    } else {
        # neznamy typ: ke stazeni jako priloha
        $WEB->printHttpHeader('type' => 'file', filename => $fshort);
    }

    if (open(my $fh, "<", $file)) {
        binmode($fh);
        my $buffer;
        while (read($fh, $buffer, 65536)) { print $buffer; }
        close($fh);
    } else {
        print "sorry, cannot open file!";
    }

}

=head2 B<[Public] folder()>

    Vypise obsah adresare (jmeno, typ, datum, velikost) sablonou Pages/systemPage/list.html.
    Povoleny jsou jen adresare z conf pwe.assets_browse_dir, jinak 401.

=cut

sub folder {
    my $self = shift;

    # SET ID Page
    $WEB->setIDP('list_directory');

    my $dir = $USER->getEnv('SCRIPT_FILENAME', undef);

    my $basedir = $self->checkassets($dir, 'assets_browse_dir');

    return 401 unless ($basedir);

    my $home = $CONF->resolveDir($dir);
    return 404 unless (defined($home));

    my $table = {};
    opendir(LISTDIR, $home . $dir) || die "Can't open $dir: $!";
    while (readdir LISTDIR) {
        next if ($_ =~ m/^\./);
        my $size     = 0;
        my $name     = $_;
        my $type     = "F";
        my $modified = localtime((stat $home . $dir . $name)[9]);
        if (-f $home . $dir . $_) {
            $size = scaledbytes((stat $home . $dir . $name)[7]);
        } else {
            $type = "D";
            $name .= "/";
        }
        push(@{$table->{'rows'}}, {name => "$name", type => $type, date => "$modified", size => "$size"});
    }
    closedir LISTDIR;

    $WEB->printHttpHeader();
    $WEB->printHtmlHeader(layout_header => "templates/LayoutHeader.html", title => $dir);
    $WEB->printHtmlLayout(layout_body => "templates/LayoutBody.html", html_main => "Pages/systemPage/list.html", basedir => "/$basedir", dir => $dir, table => $table);

    #$dname =~ s{\.[^.]+$}{};
    return 200;
}

=head2 B<[Private] scaledbytes($bytes)>

    Prevede pocet bajtu na citelny retezec (KB, MB, GB, ...).

=cut

sub scaledbytes {
    (
        sort { length $a <=> length $b }
        map { sprintf '%.3g%s', $_[0] / 1024**$_->[1], $_->[0] }[" bytes" => 0], [KB => 1], [MB => 2], [GB => 3], [TB => 4], [PB => 5], [EB => 6]
    )[0];
}

=head2 B<[Private] checkassets($path,$conf_key)>

    Overi, ze $path zacina nekterou z cest uvedenych v conf pwe.<conf_key> (oddelene carkou).
    Vraci odpovidajici polozku z conf, nebo undef.

=cut

sub checkassets {
    my ($self, $check, $asset_key) = @_;

    foreach my $asset (split(/\s*,\s*/, $CONF->getValue('pwe', $asset_key, ""))) {
        return $asset if ($check =~ /^[\.\/]?\Q$asset\E.*/);
    }
    return undef;
}

1;
