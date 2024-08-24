# ABSTRACT: Lokalise (https://lokalise.co/) synchronization plugin for Serge

package Serge::Sync::Plugin::TranslationService::lokalise;
use parent Serge::Sync::Plugin::Base::TranslationService, Serge::Interface::SysCmdRunner;

use strict;

use File::Find qw(find);
use File::Spec::Functions qw(catfile abs2rel);
use Serge::Util qw(subst_macros);
use version;

our $VERSION = qv('0.902.0');

sub name {
    return 'Lokalise translation software (https://lokalise.co/) synchronization plugin';
}

sub init {
    my $self = shift;

    $self->SUPER::init(@_);

    $self->{optimizations} = 1; 

    $self->merge_schema({
        config_file    => 'STRING',
        root_directory         => 'STRING',
        resource_directory => 'STRING',
        languages      => 'ARRAY',
        file_format    => 'STRING'
    });
}

sub validate_data {
    my ($self) = @_;

    $self->SUPER::validate_data;

    $self->{data}->{config_file} = subst_macros($self->{data}->{config_file});
    $self->{data}->{cleanup_mode} = subst_macros($self->{data}->{cleanup_mode});
    $self->{data}->{languages} = subst_macros($self->{data}->{languages});
    $self->{data}->{file_format} = subst_macros($self->{data}->{file_format});

    $self->{data}->{resource_directory} = subst_macros($self->{data}->{resource_directory});

    die "'config_file' not defined" unless defined $self->{data}->{config_file};
    die "'config_file', which is set to '$self->{data}->{config_file}', does not point to a valid file.\n" unless -f $self->{data}->{config_file};

    die "'resource_directory' not defined" unless defined $self->{data}->{resource_directory};
    die "'resource_directory', which is set to '$self->{data}->{resource_directory}', does not point to a valid folder.\n" unless -d $self->{data}->{resource_directory};
    
    die "'file_format' not defined" unless defined $self->{data}->{file_format};

    if (!defined $self->{data}->{languages} or scalar(@{$self->{data}->{languages}}) == 0) {
        die "the list of languages is empty";
    }
}

sub run_lokalise_cli {
    my ($self, $action) = @_;

    my $command = ' --config '.$self->{data}->{config_file}.' '.$action;

    $command = 'lokalise2 '.$command;
    print "Running '$command'...\n";
    return $self->run_cmd($command);
}

sub get_lokalise_lang {
    my ($self, $lang) = @_;

    $lang =~ s/-(\w+)$/'-'.uc($1)/e; # convert e.g. 'pt-br' to 'pt-BR'

    return $lang;
}

sub pull_ts {
    my ($self, $langs) = @_;

    my $action = 'file download --format '.$self->{data}->{file_format};
    $action .= ' --unzip-to '.$self->{data}->{resource_directory};

    if ($langs) {
        my @lokalise_langs = map {$self->get_lokalise_lang($_)} @$langs;

        my $langs_as_string = join(',', @lokalise_langs);

        $action .= ' --filter-langs '.$langs_as_string;
    }

    return $self->run_lokalise_cli($action);
}

sub push_ts {
    my ($self, $langs) = @_;

    my $langs_to_push = $self->get_langs($langs);

    foreach my $lang (@$langs_to_push) {
        my $action = 'file upload';

        my $lang_files_path = catfile($self->{data}->{resource_directory}, $lang);
        my @files = $self->find_lang_files($lang_files_path);

        foreach my $file (@files) {
            my $full_file_path = catfile($lang_files_path, $file);
            $action .= ' --file ' . $full_file_path . ' --lang-iso ' . $self->get_lokalise_lang($lang);

            my $cli_return = $self->run_lokalise_cli($action, ());

            if ($cli_return != 0) {
                return $cli_return;
            }
        }
    }

    return 0;
}

sub get_langs {
    my ($self, $langs) = @_;

    if (!$langs) {
        $langs = $self->{data}->{languages};
    }

    return $langs;
}

sub find_lang_files {
    my ($self, $directory) = @_;

    my @files = ();

    find(sub {
        push @files, abs2rel($File::Find::name, $directory) if(-f $_);
    }, $directory);

    return @files;
}

1;