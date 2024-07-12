package Serge::Sync::Plugin::VCS::p4;

use 5.10.0;
use strict;
use warnings;

use parent 'Serge::Sync::Plugin::Base::VCS';

use File::Spec::Functions qw(catfile);
use File::Temp qw(tempfile);
use Serge::Util qw(subst_macros);
use YAML::XS qw(LoadFile DumpFile);

# General strategy:
# We set Perforce's SubmitOptions and Options in the client spec so that all
# files are writable and clobberable by default.  We then use p4 reconcile to
# open changed files for edit and add new files.

# Perforce doesn't have concepts of repos or roots.  Local directories can
# contain files from any location in the depo.  In practice there is a common
# root (eg. //projects/my_fancy_pants_project).  But that information is never
# recorded by Perforce.  So we record it in the file below in each local_path.
# Note that this plugin never points p4 to this file.  It's only used to store
# the repo path for later use, and the client name for debugging purposes.
my $SERGE_P4RC_FILENAME = '.p4rc_serge';

sub name {
    return 'Perforce sync plugin';
}

sub init {
    my $self = shift;

    $self->SUPER::init(@_);

    $self->merge_schema({
        p4_cmd             => 'STRING',
        client_name        => 'STRING',
        client_owner       => 'STRING',
        client_description => 'STRING',
        client_filespecs   => 'ARRAY',
    });

    return;
}

sub validate_data {
    my $self = shift;

    $self->SUPER::validate_data;

    foreach my $key (qw/ client_name client_owner /) {
        if(!exists $self->{data}{$key}) {
            die "'$key' is not defined.";
        }
    }

    # We use a few variables in nearly every command.  Assign them once here
    # so they are slightly easier to read later.
    $self->{p4_cmd}    = $self->{data}{p4_cmd} // 'p4';
    $self->{p4_client} = $self->{data}{client_name};

    return;
}

sub support_branch_switching {
    return 0;
}

sub init_repo {
    my ($self, $local_path, $remote_path, $branch) = @_;

    my $p4rc_file = catfile($local_path, $SERGE_P4RC_FILENAME);
    if(-f $p4rc_file) {
        die "It appears a Perforce client has already been configured at '$local_path'.  Please rerun the command after deleting the client and directory.";
    }

    my $client_name           = $self->{data}{client_name}  || die "client_name is not defined in Serge config.";
    my $client_owner          = $self->{data}{client_owner} || die "client_owner is not defined in Serge config.";
    my $client_root_filespec  = $remote_path;
    my $client_filespecs      = $self->{data}{client_filespecs} || ['...'];
    my $desc                  = $self->{data}{client_description} || 'Created automatically by Serge';

    my $view_mapping = join("\n", map { "\t$client_root_filespec$_ //$client_name/$_" } @$client_filespecs);
    # Ignore our local state file.
    $view_mapping .= "\n\t-$client_root_filespec$SERGE_P4RC_FILENAME //$client_name/$SERGE_P4RC_FILENAME";

    my $clientspec_fn = do {
        my $template = <<"_TEMPLATE_";
Client:         $client_name
Owner:          $client_owner
Description:
    $desc
Root:           $local_path
Options:        allwrite clobber nocompress unlocked nomodtime rmdir
SubmitOptions:  revertunchanged
LineEnd:        local
View:
    $view_mapping
_TEMPLATE_

        my ($clientspec_fh, $clientspec_fn) = tempfile('p4_clientspec_XXXXX', TMPDIR => 1, UNLINK =>1);
        print $clientspec_fh $template;
        close $clientspec_fh;

        $clientspec_fn;
    };

    _save_p4rc($local_path, $client_root_filespec, $client_name, $client_owner);

    $self->run_in($local_path, qq|$self->{p4_cmd} client -i < $clientspec_fn|);
    $self->run_in($local_path, qq|$self->{p4_cmd} -c $self->{p4_client} sync -f|);

    return;
}

sub get_remote_url {
    my ($self, $local_path) = @_;
    return _read_p4rc_setting($local_path, 'CLIENT_ROOT');
}

sub checkout {
    my ($self, $local_path, $remote_path, $branch) = @_;
    $self->run_in($local_path, qq|$self->{p4_cmd} -c $self->{p4_client} sync -f $remote_path...|);
    return;
}

sub add_unversioned {
    my ($self, $local_path) = @_;
    $self->run_in($local_path, qq|$self->{p4_cmd} -c $self->{p4_client} reconcile -a|, 0, 1);
    return;
}

sub delete_unversioned {
    my ($self, $local_path) = @_;
    $self->run_in($local_path, qq|$self->{p4_cmd} -c $self->{p4_client} clean|, 1, 1);
    return;
}

sub commit {
    my ($self, $local_path, $original_remote_path, $message) = @_;

    $self->run_in($local_path, qq|$self->{p4_cmd} -c $self->{p4_client} reconcile -e|, 0, 0);

    # We still have to check this even though we just reconciled above because Serge might have called
    # add_unversioned() and we have brand new files to submit.
    my $opened_output = $self->run_in($local_path, qq|$self->{p4_cmd} -c $self->{p4_client} opened|, 1, 0);
    if($opened_output !~ m/(add|edit) default change/) {
        print "Nothing to submit.\n";
        return;
    }

    my $description = do {
        my $desc = $self->run_in($local_path, qq|$self->{p4_cmd} -c $self->{p4_client} change -o|, 1, 0);
        $desc =~ s/<enter description here>/$message/;
        $desc;
    };

    my $description_fn = do {
        my ($desc_fh, $desc_fn) = tempfile('p4_submit_descXXXXX', TMPDIR => 1, UNLINK =>0);
        print $desc_fh $description;
        close $desc_fh;
        $desc_fn;
    };

    $self->run_in($local_path, qq|$self->{p4_cmd} -c $self->{p4_client} submit -i < $description_fn|);

    return;
}

sub _save_p4rc {
    my ($local_path, $client_root, $client_name, $client_owner) = @_;

    my $p4rc_file = catfile($local_path, $SERGE_P4RC_FILENAME);

    open my $p4rc_fh, '>', $p4rc_file or die "Couldn't open $p4rc_file: $!";
    print $p4rc_fh "# Created by Sereg\n";
    print $p4rc_fh "# CLIENT_ROOT=$client_root\n"; # Comment this one out because it's not a real Perforce setting.
    print $p4rc_fh "P4USER=$client_owner\n";
    print $p4rc_fh "P4CLIENT=$client_name\n";
    close $p4rc_fh;

    return;
}

sub _read_p4rc_setting {
    my ($local_path, $key) = @_;

    my $p4rc_file = catfile($local_path, $SERGE_P4RC_FILENAME);
    if(!-f $p4rc_file) {
        return;
    }

    my $contents = do {
        local $/;
        open my $p4rc_fh, '<', $p4rc_file or die "Couldn't open $p4rc_file: $!";
        <$p4rc_fh>
    };
    my ($value) = $contents =~ m/$key=(.+)$/m or die "Couldn't find '$key' in '$p4rc_file'.";

    return $value;
}


1;
