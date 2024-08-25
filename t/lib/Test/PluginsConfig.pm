package Test::PluginsConfig;

use parent Serge::Config;

use strict;

use File::Basename;
use File::Spec::Functions qw/catfile rel2abs/;

our $REFERENCE_ERRORS_DIR = './reference-errors';
our $ERRORS_DIR = './errors';

#
# Initialize object
#
sub new {
    my ($class, $path) = @_;

    die "path not provided" unless $path;
    $path = rel2abs($path);

    # Load config file
    my $data;

    my $s = Config::Neat::Schema->new();
    $s->load(dirname(__FILE__).'/plugins_config_schema.serge');

    my $c = Config::Neat::Inheritable->new();
    $data = $c->parse_file($path);

    die "Config is not a hash\n" unless ref($data) eq 'HASH';

    $s->validate($data);

    # Check config validity

    my $self = {
        base_dir => dirname($path),
        data => $data,
    };
    bless $self, $class;

    return $self;
}

sub errors_path {
    my $self = shift;

    return catfile($self->{base_dir}, $ERRORS_DIR);
}

sub reference_errors_path {
    my $self = shift;

    return catfile($self->{base_dir}, $REFERENCE_ERRORS_DIR);
}

1;