# ABSTRACT: Mojito (http://www.mojito.global/) synchronization plugin for Serge

package Serge::Sync::Plugin::TranslationService::mojito;

use parent Serge::Sync::Plugin::Base::TranslationService, Serge::Interface::SysCmdRunner;

use strict;

use Serge::Util qw(subst_macros culture_from_lang locale_from_lang);
use version;

our $VERSION = qv('0.907.5');

sub name {
    return 'Mojito translation server (http://www.mojito.global/) synchronization plugin';
}

sub init {
    my $self = shift;

    $self->SUPER::init(@_);

    $self->{optimizations} = 1;

    $self->merge_schema({
        repository_name        => 'STRING',
        application_properties => 'STRING',
        source_files_path      => 'STRING',
        source_locale          => 'STRING',
        localized_files_path   => 'STRING',
        import_translations    => 'BOOLEAN',
        inheritance_mode       => 'STRING',
        file_type              => 'STRING',
        status_equal_target    => 'STRING',
        status_pull            => 'STRING',
        destination_locales    => 'ARRAY'
    });
}

sub validate_data {
    my ($self) = @_;

    $self->SUPER::validate_data;

    $self->{data}->{application_properties} = subst_macros($self->{data}->{application_properties});
    $self->{data}->{repository_name} = subst_macros($self->{data}->{repository_name});
    $self->{data}->{source_files_path} = subst_macros($self->{data}->{source_files_path});
    $self->{data}->{localized_files_path} = subst_macros($self->{data}->{localized_files_path});
    $self->{data}->{import_translations} = subst_macros($self->{data}->{import_translations});
    $self->{data}->{source_locale} = subst_macros($self->{data}->{source_locale});
    $self->{data}->{inheritance_mode} = subst_macros($self->{data}->{inheritance_mode});
    $self->{data}->{file_type} = subst_macros($self->{data}->{file_type});
    $self->{data}->{status_equal_target} = subst_macros($self->{data}->{status_equal_target});
    $self->{data}->{status_pull} = subst_macros($self->{data}->{status_pull});
    $self->{data}->{destination_locales} = subst_macros($self->{data}->{destination_locales});

    die "'repository_name' not defined" unless defined $self->{data}->{repository_name};

    if ($self->{data}->{application_properties} ne '') {
        die "'application_properties', which is set to '$self->{data}->{application_properties}', does not point to a valid file.\n" unless -f $self->{data}->{application_properties};
    }

    die "'source_files_path' not defined" unless defined $self->{data}->{source_files_path};
    die "'source_files_path', which is set to '$self->{data}->{source_files_path}', does not point to a valid directory.\n" unless -d $self->{data}->{source_files_path};

    die "'localized_files_path' not defined" unless defined $self->{data}->{localized_files_path};
    die "'localized_files_path', which is set to '$self->{data}->{localized_files_path}', does not point to a valid directory.\n" unless -d $self->{data}->{localized_files_path};

    $self->{data}->{import_translations} = 1 unless defined $self->{data}->{import_translations};
    $self->{data}->{inheritance_mode} = 'REMOVE_UNTRANSLATED' unless defined $self->{data}->{inheritance_mode};
    $self->{data}->{status_pull} = 'ACCEPTED' unless defined $self->{data}->{status_pull};

    if (!defined $self->{data}->{destination_locales} or scalar(@{$self->{data}->{destination_locales}}) == 0) {
        die "the list of destination languages is empty";
    }
}

sub run_mojito_cli {
    my ($self, $action, $langs, $capture) = @_;

    my $command = $action;

    $command .= ' -r '.$self->{data}->{repository_name};
    $command .= ' -s '.$self->{data}->{source_files_path};
    if ($self->{data}->{application_properties} ne '') {
        $command .= ' --spring.config.location='.$self->{data}->{application_properties};
    }

    if (defined $self->{data}->{source_locale}) {
        $command .= ' -sl '.$self->{data}->{source_locale};
    }

    if ($langs) {
        my @locale_mapping = map {$self->get_mojito_locale_mapping($_)} @$langs;

        my $locale_mapping_as_string = join(',', @locale_mapping);

        $command .= ' --locale-mapping '.$locale_mapping_as_string;
    }

    if (defined $self->{data}->{file_type}) {
        $command .= ' -ft '.$self->{data}->{file_type};
    }

    $command = 'mojito '.$command;
    print "Running '$command'...\n";

    return $self->run_cmd($command, $capture);
}

sub get_mojito_locale_mapping {
    my ($self, $lang) = @_;

    my $locale = locale_from_lang($lang);

    my $bcp47_locale = culture_from_lang($lang);

    return $locale.':'.$bcp47_locale;
}

sub pull_ts {
    my ($self, $langs) = @_;

    my $action = 'pull --inheritance-mode '.$self->{data}->{inheritance_mode}.' -t '.$self->{data}->{localized_files_path};
    $action .= ' --status '.$self->{data}->{status_pull};

    return $self->run_mojito_cli($action, $self->get_langs($langs));
}

sub push_ts {
    my ($self, $langs) = @_;

    my $cli_return = $self->run_mojito_cli('push', ());

    if ($cli_return != 0) {
        return $cli_return;
    }

    if ($self->{data}->{import_translations}) {
        my $action = 'import -t '.$self->{data}->{localized_files_path};

        if ($self->{data}->{status_equal_target} ne '') {
            $action .= ' --status-equal-target '.$self->{data}->{status_equal_target};
        }

        $cli_return = $self->run_mojito_cli($action, $self->get_langs($langs));
    }

    return $cli_return;
}

sub get_langs {
    my ($self, $langs) = @_;

    if (!$langs) {
        $langs = $self->{data}->{destination_locales};
    }

    return $langs;
}

1;