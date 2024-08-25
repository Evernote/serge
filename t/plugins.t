use strict;

# HOW TO USE THIS TEST
#
# By default, this test runs over all directories in t/data/plugins/.  To run
# the test only for specific directories, pass the directory names to this
# script or assign them to the environment variable SERGE_PLUGINS_TESTS as a
# comma-separated list.  The following two examples are equivalent:
#
# perl t/plugins.t mojito zanata
# SERGE_PLUGINS_TESTS=mojito,zanata prove t/engine.t

BEGIN {
    use Cwd qw(abs_path);
    use File::Basename;
    use File::Spec::Functions qw(catfile);
    map { unshift(@INC, catfile(dirname(abs_path(__FILE__)), $_)) } qw(lib ../lib);
}

use File::Copy::Recursive qw/dircopy/;
use File::Find qw(find);
use File::Path;
use File::Spec::Functions qw(catfile);
use Getopt::Long;
use Test::More;
use Serge::Interface::SysCmdRunner;
use Serge::Config;
use Test::PluginHost;
use Test::SysCmdRunner;
use Test::Diff;
use Test::PluginsConfig;

$| = 1; # disable output buffering

my $sys_cmd_runner;
my $init_commands;

# as the real command line interfaces cannot be invoked,
# we override the `run_cmd` function;
sub Serge::Interface::SysCmdRunner::run_cmd {
    my ($self, $command, $capture, $ignore_codes) = @_;

    die 'Undefined system command runner' unless $sys_cmd_runner;

    return $sys_cmd_runner->run_cmd($command, $capture, $ignore_codes);
}

sub output_errors {
    my ($error, $errors_path, $filename, $plugin) = @_;

    # cleanup error message to avoid having file paths that will differ across installations
    $error =~ s/\s+$//sg;
    $error =~ s/ at .*? line \d+\.$//s;
    $error =~ s/ \(\@INC contains: .*\)$//s;
    $error =~ s/\@INC.+$/\@INC/s;

    print "Plugin '$plugin' will be skipped: $error\n";

    eval { mkpath($errors_path) };
    die "Couldn't create $errors_path: $@" if $@;
    my $full_filename = catfile('./errors/', $filename);
    open(OUT, ">$full_filename");
    binmode(OUT, ':utf8');
    print OUT $error;
    close(OUT);
}

sub delete_directory {
    my ($path, $ignore_errors) = @_;

    my $err;

    if (-e $path) {
        rmtree($path, { error => \$err });
        if (@$err && !$ignore_errors) {
            my $err_text = '';

            map {
                foreach my $key (keys %$_) {
                    $err_text .= $key.': '.$_->{$key}."\n";
                }
            } @$err;

            BAIL_OUT("Directory '".$path."' couldn't be removed\n$err_text");
        }
    }
}

sub test_ts {
    my ($ts, $plugin, $cfg, $name, $command, $langs) = @_;

    my $ok = 1;

    $sys_cmd_runner = Test::SysCmdRunner->new($name);

    $sys_cmd_runner->{init} = $init_commands;

    $sys_cmd_runner->start();

    my $command_result = 1;

    eval {
        if ($langs) {
            $command_result = $ts->$command($langs);
        }
        else {
            $command_result = $ts->$command();
        }
    };

    output_errors($@, $cfg->errors_path, "$name.txt", $plugin) if $@;

    $sys_cmd_runner->stop();

    if (not $@) {
        $ok &= ok($command_result eq 0, "'$name'") unless $init_commands;
    }

    return $ok;
}

my $this_dir = dirname(abs_path(__FILE__));
my $tests_dir = catfile($this_dir, 'data', 'plugins');

my @confs;

GetOptions("init" => \$init_commands);

my @dirs = @ARGV;
if (my $env_dirs = $ENV{SERGE_PLUGINS_TESTS}) {
    push @dirs, split(/,/, $env_dirs);
}

unless (@dirs) {
    find(sub {
        push @confs, $File::Find::name if(-f $_ && /\.serge$/ && $_ ne 'common.serge');
    }, $tests_dir);
} else {
    for my $dir (@dirs) {
        find(sub {
            push @confs, $File::Find::name if(-f $_ && /\.serge$/ && $_ ne 'common.serge');
        }, catfile($tests_dir, $dir));
    }
}

my $plugin_host = Test::PluginHost->new();

for my $config_file (@confs) {

    subtest "Test config: $config_file" => sub {
        my $cfg = Test::PluginsConfig->new($config_file);

        SKIP: {
            my $ok = ok(defined $cfg, 'Config file read');

            $cfg->chdir;

            delete_directory($cfg->errors_path);
            if ($init_commands) {
                delete_directory($cfg->reference_errors_path);
            }

            my $ts;
            my $plugin = '';

            eval {
                $plugin = $cfg->{data}->{sync}->{ts}->{plugin};

                $ts = $plugin_host->load_plugin_from_node(
                    'Serge::Sync::Plugin::TranslationService',
                    $cfg->{data}->{sync}->{ts}
                );
            };

            output_errors($@, $cfg->errors_path, 'new.txt', $plugin) if $@;

            if (not $@ and $ts) {
                my $langs = $cfg->{data}->{sync}->{langs};

                $ok &= test_ts($ts, $plugin, $cfg, 'pull', 'pull_ts', $langs);

                $ok &= test_ts($ts, $plugin, $cfg, 'push', 'push_ts', $langs);
            }

            if ($init_commands) {
                ok(dircopy($cfg->errors_path, $cfg->reference_errors_path), "Initialized ".$cfg->reference_errors_path) if -e $cfg->errors_path;
            }
            else {
                $ok &= dir_diff($cfg->errors_path, $cfg->reference_errors_path, { base_dir => $cfg->{base_dir} }) if -e $cfg->reference_errors_path;
            }

            delete_directory($cfg->errors_path) if $ok;
        }
    }
}

done_testing();
