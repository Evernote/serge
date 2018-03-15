package Serge::Engine::Plugin::serialize_xliff;
use parent Serge::Engine::Plugin::Base::Serializer;

use strict;

use Unicode::Normalize;

use Serge;
use Serge::Util;
use Serge::Util qw(xml_escape_strref xml_unescape_strref);
use XML::Twig;
use XML::Tidy;

sub name {
    return '.XLIFF 1.2 Serializer';
}

sub init {
    my $self = shift;

    $self->SUPER::init(@_);

    $self->merge_schema({
        # specifies if the first line of the serge hint is to be used to determine the resname attribute of the xliff trans-unit
        # Useful for parsers that translate the key into the serge hint. Default YES
        use_hint_for_resname => 'BOOLEAN',
        # used to determine how to store serge context into xliff
        # extradata: (default) stores serge context on the extradata attribute of trans-unit
        # resname: stores serge context on the resname attribute of trans-unit. To be used when using parsers that always output serge context or when
        #          the translation provider does not support the extradata attribute
        # id: stores serge context on the id attribute of trans-unit after the serge key (so trans-unit id will be <serge.key>:<serge.context>). To be used as a last resort,
        #          when the translation provider does not support any additional attribute outside the id one.
        context_strategy => 'STRING',
        # specifies what are the state where a translation is considered translated. To be specified like a list of xliff 1.2 states separated by spaces.
        # If none are specified then all the states are valid
        valid_states => 'STRING',
        # xliff file file-datatype. Default x-unknown
        file_datatype => 'STRING',
        # xliff target state when the string is translated. Default 'translated'
        state_translated => 'STRING',
        # xliff target state when the string is not translated (empty). Default 'new'
        state_untranslated => 'STRING',
        # specifies how to deal with untranslated strings
        # emptytarget: (default) target element is present with empty text and state state_untranslated
        # notarget: target element is omitted
        # notransunit: trans-unit element is omitted. This should only be used with translation providers that are using a master file approach
        untranslated_strategy => 'STRING',
    });
}

sub validate_data {
    my $self = shift;

    $self->SUPER::validate_data;

    $self->{data}->{use_hint_for_resname} = 1 unless defined $self->{data}->{use_hint_for_resname};

    $self->{data}->{file_datatype} = 'x-unknown' unless defined $self->{data}->{file_datatype};

    $self->{data}->{context_strategy} = 'extradata' unless defined $self->{data}->{context_strategy};

    if (($self->{data}->{context_strategy} ne 'id') and ($self->{data}->{context_strategy} ne 'extradata') and ($self->{data}->{context_strategy} ne 'resname')) {
        die "'context_strategy', which is set to $self->{data}->{context_strategy}, is not one of the valid options: 'id' or 'extradata' or 'resname'";
    }

    $self->{data}->{state_translated} = 'translated' unless defined $self->{data}->{state_translated};

    $self->{data}->{state_untranslated} = 'new' unless defined $self->{data}->{state_untranslated};

    $self->{data}->{untranslated_strategy} = 'emptytarget' unless defined $self->{data}->{untranslated_strategy};

    if (($self->{data}->{untranslated_strategy} ne 'notarget') and ($self->{data}->{untranslated_strategy} ne 'emptytarget') and ($self->{data}->{untranslated_strategy} ne 'notransunit')) {
        die "'untranslated_strategy', which is set to $self->{data}->{untranslated_strategy}, is not one of the valid options: 'notarget' or 'emptytarget' or 'notransunit'";
    }
}

sub serialize {
    my ($self, $units, $file, $lang) = @_;

    my $use_hint_for_resname = $self->{data}->{use_hint_for_resname};

    my $source_lang = $self->{parent}->{source_language};

    my $source_locale = locale_from_lang($source_lang);
    my $target_locale = locale_from_lang($lang);

    my $root_element = XML::Twig::Elt->new('xliff', {
            'xmlns' => "urn:oasis:names:tc:xliff:document:1.2",
            version => "1.2",
        });

    my $file_element = $root_element->insert_new_elt('file' => {original => $file, 'source-language' => $source_locale, datatype => $self->{data}->{file_datatype}}, '');

    if ($source_lang ne $lang) {
        $file_element->set_att('target-language' => $target_locale);
    }

    my $body_element = $file_element->insert_new_elt('body');

    my @reversed_units = reverse(@$units);

    foreach my $unit (@reversed_units) {
        if (not $unit->{target} and $self->{data}->{untranslated_strategy} eq 'notransunit') {
            next;
        }

        my $unit_element = $body_element->insert_new_elt('trans-unit' => {}, '');

        if ($source_lang ne $lang) {
            my $approved = $unit->{fuzzy} ? "no" : "yes";

            $unit_element->set_att(approved => $approved);
        }

        my $key = $unit->{key};

        if ($unit->{context} ne '') {
            if ($self->{data}->{context_strategy} eq 'extradata') {
                $unit_element->set_att('extradata' => $unit->{context});
            } elsif ($self->{data}->{context_strategy} eq 'resname') {
                $unit_element->set_att('resname' => $unit->{context});
            } elsif ($self->{data}->{context_strategy} eq 'id') {
                $key .= ':'.$unit->{context};
            }
        }

        $unit_element->set_att('id' => $key);

        my $dev_comment = $unit->{hint};

        if ($dev_comment ne '') {
            my @dev_comment_lines = split('\n', $dev_comment);

            if ($use_hint_for_resname and ($self->{data}->{context_strategy} eq 'extradata')) {
                my $resname = $dev_comment_lines[0];

                $unit_element->set_att('resname' => $resname);

                my $dev_comment_lines_size = scalar @dev_comment_lines;

                if ($dev_comment_lines_size > 1) {
                    shift(@dev_comment_lines);
                }
                else {
                    @dev_comment_lines = \();
                }
            }

            foreach my $dev_comment_line (reverse(@dev_comment_lines)) {
                $unit_element->insert_new_elt('note' => {'from' => 'developer'}, $dev_comment_line);
            }
        }

        if ($unit->{target} eq '' and $self->{data}->{untranslated_strategy} eq 'notarget') {
        } elsif ($source_lang ne $lang) {
            my $target_element = $unit_element->insert_new_elt('target' => {'xml:lang' => $target_locale}, $unit->{target});

            my $state = '';

            if ($self->{data}->{source_language} ne $lang) {
                if ($unit->{target} ne '') {
                    $state = $self->{data}->{state_translated};
                } else {
                    $state = $self->{data}->{state_untranslated};
                }
            }

            if ($state ne '') {
                $target_element->set_att('state' => $state);
            }
        }

        $unit_element->insert_new_elt('source' => {'xml:lang' => $source_locale}, $unit->{source});
    }

    my $tidy_obj = XML::Tidy->new('xml' => $root_element->sprint);

    $tidy_obj->tidy('    ');

    return $tidy_obj->toString();
}

sub deserialize {
    my ($self, $textref) = @_;

    my @valid_states = \();

    if ($self->{data}->{valid_states} ne '') {
        @valid_states = split(' ', $self->{data}->{valid_states});
    }

    my @units;

    my $tree;
    eval {
        $tree = XML::Twig->new()->parse($$textref);
        $tree->set_indent(' ' x 4);
    };
    if ($@) {
        my $error_text = $@;
        $error_text =~ s/\t/ /g;
        $error_text =~ s/^\s+//s;

        die $error_text;
    }

    my $version = $tree->root->att('version');
    ($version =~ m/^(\d+)/) && ($version = $1);

    die "Unsupported XLIFF version: '$version'" unless $version eq 1;

    my @tran_units = $tree->findnodes('//trans-unit');
    foreach my $tran_unit (@tran_units) {
        my $key = '';
        my $context = '';
        my $comment = '';

        if ($self->{data}->{context_strategy} eq 'extradata') {
            $key = $tran_unit->att('id');

            $context = $tran_unit->att('extradata');

            if ($tran_unit->att('resname') ne '') {
                $comment = $tran_unit->att('resname');
                $comment .= '\n';
            }
        }
        elsif ($self->{data}->{context_strategy} eq 'resname') {
            $key = $tran_unit->att('id');

            $context = $tran_unit->att('resname');
        } elsif ($self->{data}->{context_strategy} eq 'id') {
            my @id_parts = split(/:/, $tran_unit->att('id'));

            $key = shift @id_parts;

            my $id_parts_size = scalar @id_parts;

            if ($id_parts_size > 0) {
                $context = join(':', @id_parts);
            }
        }

        $comment .= $self->get_comment($tran_unit);

        my $source_element = $tran_unit->first_child('source');
        my $target_element = $tran_unit->first_child('target');

        my @flags = \();
        my $state = '';
        my $target = '';

        if ($target_element) {
            $state = $target_element->att('state');
            $target = $target_element->text;
        } else {
            print "\t\t? [missing target] for $key\n";
        }

        if ($state ne '') {
            push @flags, 'state-'.$state;
        }

        my $source = '';

        if ($source_element) {
            $source = $source_element->text;
        }

        my $fuzzy = $tran_unit->att('approved') eq "no";

        if ($key eq '') {
            print "\t\t? [empty key]\n";
            next;
        }

        if ($key ne generate_key($source, $context)) {
            print "\t\t? [bad key] $key for context $context\n";
            next;
        }

        if ($state ne '' and @valid_states) {
            my $is_valid_state = $state ~~ @valid_states;

            if (not $is_valid_state) {
                print "\t\t? [invalid state] for $key for with state $state\n";
                $target = '';
            }
        }

        next unless ($target or $comment);

        push @units, {
                key => $key,
                source => $source,
                context => $context,
                target => $target,
                comment => $comment,
                fuzzy => $fuzzy,
                flags => @flags,
            };
    }

    return \@units;
}

sub get_comment {
    my ($self, $node) = @_;

    my $first_note_node = $node->first_child('note');

    my @notes;

    if (defined $first_note_node) {
        map {
            push @notes, $_->text;
        } $node->children('note');
    }
    return join('\n', @notes);
}


1;