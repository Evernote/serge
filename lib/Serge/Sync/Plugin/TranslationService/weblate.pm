# ABSTRACT: Weblate (https://weblate.org/) synchronization plugin for Serge

package Serge::Sync::Plugin::TranslationService::weblate;
use parent Serge::Sync::Plugin::Base::TranslationService, Serge::Interface::SysCmdRunner;

use strict;

use File::Find qw(find);
use File::Spec::Functions qw(catfile abs2rel);
use JSON -support_by_pp; # -support_by_pp is used to make Perl on Mac happy
use Serge::Util qw(subst_macros);
use version;
use Scalar::Util qw(reftype);
use File::Path qw(make_path);
use File::Basename;

our $VERSION = qv('0.900.6');

sub name {
    return 'Weblate translation software (https://weblate.org/) synchronization plugin';
}

sub init {
    my $self = shift;

    $self->SUPER::init(@_);

    $self->{optimizations} = 1; # set to undef to disable optimizations

    $self->merge_schema({
        root_directory   => 'STRING',
        project          => 'STRING',
        config_file      => 'STRING',
        languages        => 'ARRAY'
    });
}

sub validate_data {
    my ($self) = @_;

    $self->SUPER::validate_data;

    $self->{data}->{root_directory} = subst_macros($self->{data}->{root_directory});
    $self->{data}->{project} = subst_macros($self->{data}->{project});
    $self->{data}->{config_file} = subst_macros($self->{data}->{config_file});
    $self->{data}->{languages} = subst_macros($self->{data}->{languages});

    die "'root_directory', which is set to '$self->{data}->{root_directory}', does not point to a valid folder." unless -d $self->{data}->{root_directory};
    die "'config_file' not defined" unless defined $self->{data}->{config_file};
    die "'config_file', which is set to '$self->{data}->{config_file}', does not point to a valid file.\n" unless -f $self->{data}->{config_file};
    die "'project' not defined" unless defined $self->{data}->{project};

    if (!exists $self->{data}->{languages} or scalar(@{$self->{data}->{languages}}) == 0) {
        die "the list of destination languages is empty";
    }
}

sub pull_ts {
    my ($self, $langs) = @_;

    my $langs_to_push = $self->get_all_langs($langs);
    my %files = $self->translation_files($langs_to_push);

    foreach my $key (sort keys %files) {
        my $file = $files{$key};
        my $full_path = catfile($self->{data}->{root_directory}, $file);

        my ($file_name,$folder_path,$file_suffix) = fileparse($full_path);

        if (!(-d $folder_path)) {
            make_path($folder_path);
        }

        my $cli_return = $self->run_weblate_cli('download --output "'.$file.'" '.$key, 0);

        if ($cli_return != 0) {
            return $cli_return;
        }
    }

    return 0;
}

sub push_ts {
    my ($self, $langs) = @_;

    my $langs_to_push = $self->get_all_langs($langs);
    my %files = $self->translation_files($langs_to_push);

    foreach my $key (sort keys %files) {
        my $file = $files{$key};
        my $full_path = catfile($self->{data}->{root_directory}, $file);

        if (-f $full_path) {
            my $command = 'upload --overwrite --input "' . $file . '"';
            $command .= ' --method replace';
            if ($self->{data}->{fuzzy}) {
                $command .= ' --fuzzy '.$self->{data}->{fuzzy};
            }
            $command .= ' '.$key;

            my $cli_return = $self->run_weblate_cli($command, 0);

            if ($cli_return != 0) {
                return $cli_return;
            }
        }
    }

    return 0;
}

sub translation_files {
    my ($self, $langs) = @_;

    my $json_components = $self->run_weblate_cli('--format json list-components '.$self->{data}->{project}, 1);

    my $json_components_tree = $self->parse_json($json_components);
    my $json_components_list = $self->parse_list($json_components_tree);
    my @components = map { $_->{slug} } @$json_components_list;

    my %translations = ();

    my %langs_hash = map { $_ => 1 } @$langs;

    foreach my $component (@components) {
        my $json_translations = $self->run_weblate_cli('--format json list-translations '.$self->{data}->{project}.'/'.$component, 1);

        my $json_translations_tree = $self->parse_json($json_translations);
        my $json_translations_list = $self->parse_list($json_translations_tree);

        foreach my $translation (@$json_translations_list) {
            my $language = $translation->{language}->{code};
            my $filename = $translation->{filename};
            my $language_code = $translation->{language_code};

            if (exists $langs_hash{$language_code}) {
                $translations{$self->{data}->{project}.'/'.$component.'/'.$language} = $filename;
            }
        }
    }

    return %translations;
}

sub get_all_langs {
    my ($self, $langs) = @_;

    if (!$langs) {
        $langs = $self->{data}->{languages};
    }

    my @all_langs = ();

    push @all_langs, @$langs;

    return \@all_langs;
}

sub run_weblate_cli {
    my ($self, $action, $capture) = @_;

    my $cli_return = 0;

    my $command = 'wlc --config '.$self->{data}->{config_file}.' '.$action;

    print "Running $action ...\n";

    my $json_response = $self->run_in($self->{data}->{root_directory}, $command, 1);

    if ($capture) {
        return $json_response;
    }

    if ($json_response == '') {
        return 0;
    }

    return $self->parse_result($json_response);
}

sub parse_result {
    my ($self, $json_response) = @_;

    my $json_tree = $self->parse_json($json_response);

    if (reftype($json_tree) == 'ARRAY') {
        return 0;
    }

    my $result =  $json_tree->{result};

    if ($result == 'true') {
        return 0;
    }

    return 1;
}

sub parse_list {
    my ($self, $json_tree) = @_;

    if (reftype($json_tree) == 'ARRAY') {
        return $json_tree;
    }

    return $json_tree->{results};
}

sub find_lang_files {
    my ($self, $directory) = @_;

    my @files = ();

    find(sub {
        push @files, abs2rel($File::Find::name, $directory) if(-f $_);
    }, $directory);

    return @files;
}

sub parse_json {
    my ($self, $json) = @_;

    my $tree;
    eval {
        ($tree) = from_json($json, {relaxed => 1});
    };
    if ($@ || !$tree) {
        my $error_text = $@;
        if ($error_text) {
            $error_text =~ s/\t/ /g;
            $error_text =~ s/^\s+//s;
        } else {
            $error_text = "from_json() returned empty data structure";
        }

        die $error_text;
    }

    return $tree;
}

sub get_langs {
    my ($self, $langs) = @_;

    if (!$langs) {
        $langs = $self->{data}->{languages};
    }

    return $langs;
}

1;