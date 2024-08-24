# ABSTRACT: Lingohub (https://www.lingohub.com) synchronization plugin for Serge

package Serge::Sync::Plugin::TranslationService::lingohub;
use parent Serge::Sync::Plugin::Base::TranslationService, Serge::Interface::SysCmdRunner;

use strict;

use File::Find qw(find);
use File::Spec::Functions qw(catfile abs2rel);
use Serge::Util qw(subst_macros);

use version;

our $VERSION = qv('0.904.5');

sub name {
    return 'Lingohub translation software (https://www.lingohub.com) synchronization plugin';
}

sub init {
    my $self = shift;

    $self->SUPER::init(@_);

    $self->{optimizations} = 1; # set to undef to disable optimizations

    $self->merge_schema({
        project                => 'STRING',
        root_directory         => 'STRING',
        resource_directory     => 'STRING',
        source_language        => 'STRING',
        target_languages       => 'ARRAY'
    });
}

sub validate_data {
    my ($self) = @_;

    $self->SUPER::validate_data;

    $self->{data}->{project} = subst_macros($self->{data}->{project});
    $self->{data}->{root_directory} = subst_macros($self->{data}->{root_directory});
    $self->{data}->{resource_directory} = subst_macros($self->{data}->{resource_directory});
    $self->{data}->{source_language} = subst_macros($self->{data}->{source_language});
    $self->{data}->{target_languages} = subst_macros($self->{data}->{target_languages});

    die "'project' not defined" unless defined $self->{data}->{project};
    die "'resource_directory' not defined" unless defined $self->{data}->{resource_directory};
    die "'root_directory', which is set to '$self->{data}->{root_directory}', does not point to a valid folder." unless -d $self->{data}->{root_directory};

    my $target_languages_count = 0;

    if (defined $self->{data}->{target_languages}) {
        $target_languages_count = scalar(@{$self->{data}->{target_languages}});
    }

    die "the list of target languages is empty" unless $target_languages_count != 0;

    $self->{data}->{source_language} = 'en' unless defined $self->{data}->{source_language};
}

sub pull_ts {
    my ($self, $langs) = @_;

    my $langs_to_pull = $self->get_all_langs($langs);

    foreach my $lang (@$langs_to_pull) {
        my $directory = catfile($self->{data}->{resource_directory}, $lang);
        my $cli_return = $self->run_lingohub_cli("resource:down --locale '$lang' --directory $directory --all");

        if ($cli_return != 0) {
            return $cli_return;
        }
    }

    return 0;
}

sub push_ts {
    my ($self, $langs) = @_;

    my $langs_to_push = $self->get_all_langs($langs);

    foreach my $lang (@$langs_to_push) {
        my $directory = catfile($self->{data}->{resource_directory}, $lang);

        my $lang_files_path = catfile($self->{data}->{root_directory}, $directory);
        my @files = $self->find_lang_files($lang_files_path);

        foreach my $file (@files) {
            my $resource = catfile($directory, $file);
            my $cli_return = $self->run_lingohub_cli("resource:up $resource --locale '$lang'");

            if ($cli_return != 0) {
                return $cli_return;
            }
        }
    }

    return 0;
}

sub run_lingohub_cli {
    my ($self, $action, $capture) = @_;

    my $cli_return = 0;

    my $command = $action;

    $command = 'lingohub '.$command;
    $command .= " --project '$self->{data}->{project}'";
    print "Running '$command ...\n";

    $cli_return = $self->run_in($self->{data}->{root_directory}, $command, $capture);

    return $cli_return;
}

sub get_all_langs {
    my ($self, $langs) = @_;

    if (!$langs) {
        $langs = $self->{data}->{target_languages};
    }

    my @all_langs = ($self->{data}->{source_language});

    push @all_langs, @$langs;

    return \@all_langs;
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