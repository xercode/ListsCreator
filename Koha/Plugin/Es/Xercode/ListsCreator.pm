package Koha::Plugin::Es::Xercode::ListsCreator;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use C4::Context;
use C4::Members;
use C4::Biblio;
use C4::Auth;
use C4::Reports::Guided;
use Koha::DateUtils;
use MARC::Record;
use JavaScript::Minifier qw(minify);
use File::Copy;
use File::Temp;
use File::Basename;
use Pod::Usage;
use Text::CSV::Encoded;
use Spreadsheet::Read; #hay que asegurarse que está instalado
use Spreadsheet::XLSX;

use constant ANYONE => 2;

BEGIN {
    use Config;
    use C4::Context;

    my $pluginsdir  = C4::Context->config('pluginsdir');
}

our $VERSION = "1.0.0";

our $metadata = {
    name            => 'Lists Creator',
    author          => 'Xercode Media Software S.L.',
    description     => 'Lists Creator Plugin',
    date_authored   => '2020-07-06',
    date_updated    => '2020-07-11',
    minimum_version => '18.11',
    maximum_version => undef,
    version         => $VERSION,
};

our $dbh = C4::Context->dbh();


sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;
    
    my $self = $class->SUPER::new($args);

    return $self;
}

sub tool {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    
    my $excelfile = $cgi->param('excelfile');
    unless ($excelfile){
        $self->tool_step1();
    }else{
        $self->tool_step2();
    }
}

sub tool_step1 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template( { file => 'tool-step1.tt' } );

    if ( $self->retrieve_data('enabled') ) {
        $template->param(enabled => 1);
    }

    print $cgi->header(
        {
            -type     => 'text/html',
            -charset  => 'UTF-8',
            -encoding => "UTF-8"
        }
    );
    print $template->output();
}

sub tool_step2 {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $userid = C4::Context->userenv ? C4::Context->userenv->{number} : undef;
    my $template = $self->get_template( { file => 'tool-step2.tt' } );

    if ( $self->retrieve_data('enabled') ) {
        $template->param(enabled => 1);
    }
    
    my $filename = $cgi->param("excelfile");
    my ( $name, $path, $extension ) = fileparse( $filename, ('xls', 'xlsx') );
    
    if ($extension ne ""){
        
        my $upload_dir        = '/tmp';
        my $upload_filehandle = $cgi->upload("excelfile");
        open( UPLOADFILE, '>', "$upload_dir/$filename" ) or warn "$!";
        binmode UPLOADFILE;
        while (<$upload_filehandle>) {
            print UPLOADFILE;
        }
        close UPLOADFILE;
        open my $test_in, '<', "$upload_dir/$filename" or warn "Can't open file: $!";

        my $books  = ReadData ("$upload_dir/$filename", attr => 1);

        foreach my $book (@{$books}) {

            unless ($book->{label}) {
                next;
            }
            
            my @messages;
            my @biblios_add;
            my @biblios_exists;
            my @biblios_notexists;
            my @biblios_error;
            my $continue = 1;
            my $maxrow = $book->{maxrow};
            my $f = 2;
            
            my $shelfname = $book->{cell}[1][1];
            my $shelfnumber = undef;
            # Check if the list exists by its name
            my $shelf = undef;
            my $shelfs_exists = 0;
            my $_shelf = GetShelfByName($shelfname);
            unless ($_shelf){
                my $sortfield = $self->retrieve_data('sortfield');
                my $category = $self->retrieve_data('category');
                my $allow_changes_from = $self->retrieve_data('allow_changes_from');
                
                $shelf = Koha::Virtualshelf->new(
                    {   shelfname          => $shelfname,
                        sortfield          => $sortfield,
                        category           => $category || 1,
                        allow_change_from_owner => $allow_changes_from > 0,
                        allow_change_from_others => $allow_changes_from == ANYONE,
                        owner              => $userid,
                    }
                );
                $shelf->store;
                $shelfnumber = $shelf->shelfnumber;
                
            }else{
                $shelfnumber = $_shelf->{shelfnumber};
                $shelf = Koha::Virtualshelves->find($shelfnumber);
                $shelfs_exists = 1;
            }
            
            while ($continue)	{
                
                my ($biblionumber) = $book->{cell}[1][$f] =~ /biblionumber=([0-9]+)/;
                if (defined $biblionumber){
                    my $biblio = Koha::Biblios->find( $biblionumber );

                    if ($biblio){
                        my $added = eval { $shelf->add_biblio( $biblionumber, $userid ); };
                        if ($@) {
                            push @messages, { biblionumber => $biblionumber, type => 'alert', code => ref($@), text => $@ };
                            push @biblios_error, $biblionumber;
                        } elsif ( $added ) {
                            push @messages, { biblionumber => $biblionumber, type => 'message', code => 'success_on_add_biblio' };
                            push @biblios_add, $biblionumber;
                        } else {
                            push @messages, { biblionumber => $biblionumber, type => 'message', code => 'error_on_add_biblio' };
                            push @biblios_exists, $biblionumber;
                        }
                    }else{
                        push @messages, { biblionumber => $biblionumber, type => 'message', code => 'biblio_does_not_exists' };
                        push @biblios_notexists, $biblionumber;
                    }
                }
                
                $f++;

                if($f > $maxrow){
                    $continue = 0;
                }
            }

            $template->param(shelf_exists => $shelfs_exists);
            $template->param(shelfnumber => $shelfnumber);
            $template->param(messages => \@messages);

            my $table_log = $self->get_qualified_table_name('log');
            $dbh->do(
                qq{
                    INSERT INTO $table_log (`borrowernumber`, `shelfnumber`, `shelf_already_exists`, `filename`, `biblios_add`, `biblios_exists`, `biblios_notexists`, `biblios_error` ) VALUES ( ?, ?, ?, ?, ?, ?, ?, ? );
                    }
                , undef, ( $userid, $shelfnumber, $shelfs_exists, $filename, join(',', @biblios_add), join(',', @biblios_exists), join(',', @biblios_notexists), join(',', @biblios_error) ));
            };
        
        $template->param(message => "ok");
    }else{
        $template->param(error => "not_an_excel_file");
    }

    print $cgi->header(
        {
            -type     => 'text/html',
            -charset  => 'UTF-8',
            -encoding => "UTF-8"
        }
    );
    print $template->output();

}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    
    if ( $cgi->param('save') ) {
        my $enabled = $cgi->param('enabled') ? 1 : 0;
        my $database_internal_use = $cgi->param('database_internal_use') ? 1 : 0;
        $self->store_data(
            {
                enabled            => $enabled,
                sortfield          => $cgi->param('sortfield'),
                allow_changes_from => $cgi->param('allow_changes_from'),
                category           => $cgi->param('category')
            }
        );
        $self->go_home();
    }
    else {
        my $template = $self->get_template( { file => 'configure.tt' } );

        $template->param(
            enabled               => $self->retrieve_data('enabled'),
            sortfield             => $self->retrieve_data('sortfield'),
            allow_changes_from    => $self->retrieve_data('allow_changes_from'),
            category              => $self->retrieve_data('category'),
        );
        
        print $cgi->header(
            {
                -type     => 'text/html',
                -charset  => 'UTF-8',
                -encoding => "UTF-8"
            }
        );
        print $template->output();
    }
}

sub install() {
    my ( $self, $args ) = @_;
    
    my $dbh = C4::Context->dbh;

    my $table_log = $self->get_qualified_table_name('log');
    $dbh->do(
        qq{
            CREATE TABLE `$table_log` (
              `id` int(11) NOT NULL AUTO_INCREMENT,
              `borrowernumber` int(11) NOT NULL,
              `date_time` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
              `shelfnumber` int(11) NOT NULL,
              `shelf_already_exists` tinyint(4) DEFAULT '0',
              `filename` varchar(50) COLLATE utf8mb4_unicode_ci,
              `biblios_add` MEDIUMTEXT DEFAULT NULL,
              `biblios_exists` MEDIUMTEXT DEFAULT NULL,
              `biblios_notexists` MEDIUMTEXT DEFAULT NULL,
              `biblios_error` MEDIUMTEXT DEFAULT NULL,
              PRIMARY KEY (`id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        }
    );
    
    return 1;
}

sub uninstall() {
    my ( $self, $args ) = @_;

    my $table_log = $self->get_qualified_table_name('log');
    C4::Context->dbh->do("DROP TABLE $table_log");
    
    return 1;
}

############################################
#                                          #
#              PLUGIN METHODS              #
############################################

sub GetShelfByName {
    my $shelfname = shift;

    my $query = qq(
        SELECT shelfnumber
        FROM   virtualshelves
        WHERE  shelfname = ?
    );
    my $sth = $dbh->prepare($query);
    $sth->execute($shelfname);
    
    return $sth->fetchrow_hashref;
}

1;

__END__

=head1 NAME

ListsCreator.pm - Lists Creator Koha Plugin.

=head1 SYNOPSIS

Lists Creator

=head1 DESCRIPTION

Lists Creator Plugin

=head1 AUTHOR

Juan Francisco Romay Sieira <juan.sieira AT xercode DOT es>

=head1 COPYRIGHT

Copyright 2020 Xercode Media Software S.L.

=head1 LICENSE

This file is part of Koha.

Koha is free software; you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later version.

You should have received a copy of the GNU General Public License along with Koha; if not, write to the Free Software Foundation, Inc., 51 Franklin Street,
Fifth Floor, Boston, MA 02110-1301 USA.

=head1 DISCLAIMER OF WARRANTY

Koha is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

=cut
