package Test::PluginHost;
use parent Serge::Interface::PluginHost;

use strict;

sub new {
    my ($class) = @_;

    my $self = {
        debug               => 1
    };

    bless $self, $class;

    return $self;
}

1;