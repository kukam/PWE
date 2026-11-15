package Pages::responsive::responsive;

=head1 NAME

Pages::responsive::responsive - ukazkova stranka ve vzhledu Responsive

=cut

use strict;

my ($CONF, $LOG, $VALIDATE, $DBI, $ENTITIES, $USER, $WEB);

=head2 B<[Public] new($self,$conf,$log,$validate,$dbi,$entities,$user,$web)>

    Ukazkova stranka s responzivnim vzhledem Sites::Responsive (Bootstrap 3).

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

=head2 B<[Private] Site_Responsive($site)>

    Injektaz vzhledu Responsive (vola loader) - stranka pouziva jiny vzhled nez Default.

=cut

sub Site_Responsive {
    my ($self, $input) = @_;
    $WEB = $input;
}

=head2 B<[Public] default()>

    Vykresli Pages/responsive/main.html ve vzhledu Responsive.

=cut

sub default {
    my $self = shift;

    my $idp = "responsive";

    # SET ID Page
    $WEB->setIDP($idp);
    $WEB->printHttpHeader();
    $WEB->printHtmlHeader();
    $WEB->printHtmlLayout(html_main => "Pages/responsive/main.html",);
}

1;
