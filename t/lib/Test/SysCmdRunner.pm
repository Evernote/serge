package Test::SysCmdRunner;
use parent Serge::Interface::PluginHost;

use strict;
use warnings;

use JSON -support_by_pp; # -support_by_pp is used to make Perl on Mac happy
use Encode qw(decode encode_utf8 decode_utf8);
use File::Path;
use File::Spec::Functions qw(catfile);
use Cwd;
use Clone qw(clone);

our $UNIX_PATH_SEPARATOR = '/';
our $WINDOWS_PATH_SEPARATOR = '\\';

sub new {
    my ($class, $ts_command) = @_;

    my $self = {
        ts_command    => $ts_command,
        echo_output   => 1,
        echo_commands => 1,
        debug         => 1,
        init          => 0
    };

    bless $self, $class;

    return $self;
}

sub start {
    my ($self) = @_;

    $self->{env} = clone(\%ENV);

    if ($self->{init}) {
        $self->{commands} = [];

        return;
    }

    my $commands_path = './commands/';

    my $filename = catfile($commands_path, $self->{ts_command}.'.json');

    if (!open(TS, $filename)) {
        print "WARNING: Can't read $filename: $!\n";
        return;
    }
    binmode(TS);
    my $text = decode_utf8(join('', <TS>));
    close(TS);

    $self->{commands} = $self->parse_json($text);
}

sub run_cmd {
    my ($self, $command, $capture, $ignore_codes) = @_;

    my $expected_command;

    if (not $self->{init}) {
        # need for Windows, where path separator is '\'
        my $path_separator = catfile('', '');

        if ($path_separator eq $WINDOWS_PATH_SEPARATOR) {
            # Switching Windows path separator to Unix path separator.
            $command =~ s{\\}{/}g;
        }

        my $commands_ref = $self->{commands};


        die "'$command' not found" unless ref($commands_ref) eq 'ARRAY';

        my @commands = @$commands_ref;

        $expected_command = shift @commands;

        $self->{commands} = \@commands;

        die "$command not found" unless $expected_command;
        die "$command not found" unless $expected_command->{command};
        die "$command not found as expected (found $expected_command->{command})" if $expected_command->{command} ne $command;

        my $command_env = $expected_command->{env};

        my $env_diff = hash_diff($command_env, \%ENV);

        if (%$env_diff) {
            my @keys = keys %{ $env_diff };
            my $env_key = shift @keys;
            my $expected_value = $command_env->{$env_key};
            my $found_value = $ENV{$env_key};

            die "ENV $env_key not found as expected (expected '$expected_value' found '$found_value')";
        }
    } else {
        $expected_command = {
            command  => $command
        };

        my $env_diff = hash_diff(\%ENV, $self->{env});

        if ($env_diff) {
            $expected_command->{env} = $env_diff;
        }

        my $commands_ref = $self->{commands};

        my @commands = @$commands_ref;

        push @commands, $expected_command;

        $self->{commands} = \@commands;
    }

    my $result;
    if ($capture) {
        $result = '';
    } else {
        $result = 0;
    }

    if (not $self->{init}) {
        if ($capture) {
            $result = $expected_command->{output} if defined $expected_command->{output};

            print "\n--------------------\n$result\n--------------------\n" if $self->{echo_output};
        } else {
            $result = $expected_command->{result} if defined $expected_command->{result};
        }
    }

    my $error_code = 0;

    if (not $self->{init}) {
        $error_code = $expected_command->{error_code} if $expected_command->{error_code};

        if (($error_code > 0) && $ignore_codes && (ref(\$ignore_codes) eq 'SCALAR' || (grep ($_ eq $error_code, @$ignore_codes) > 0))) {
            print "Exit code: $error_code (ignored)\n" if $self->{debug};
            $error_code = 0;
        }

        die $result . "\nExit code: $error_code; last error: $!\n" if $error_code != 0;
    }

    return $result;
}

sub stop {
    my ($self) = @_;

    if (not $self->{init}) {
        return;
    }

    my $commands_ref = $self->{commands};

    if (ref($commands_ref) eq 'ARRAY') {
        my $commands_path = './commands/';

        eval { mkpath($commands_path) };
        die "Couldn't create $commands_path: $@" if $@;

        my $filename = catfile($commands_path, $self->{ts_command}.'.json');

        my $json = JSON->new;

        my $commands_json = $json->pretty->encode($commands_ref);

        open my $OUT, ">", $filename or die "Failed to open file [$filename] for writing: $!";
        binmode $OUT;
        print $OUT $commands_json;

        close $OUT;
    }
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

sub hash_diff {
    my ($first, $second) = @_;

    my $diff = {};

    if ($first) {
        foreach my $k (sort keys %{ $first }) {
            if (not exists $second->{$k} or not defined $second->{$k}) {
                $diff->{$k} = $first->{$k}
            } elsif ($first->{$k} ne $second->{$k}) {
                $diff->{$k} = $first->{$k}
            }
        }
    }

    return $diff;
}


1;