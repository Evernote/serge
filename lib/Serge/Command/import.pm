package Serge::Command::import;
use parent Serge::Command;

use strict;

use Getopt::Long;
use Serge::Config;
use Serge::Importer;
use Serge::Engine::Processor;
use Serge::Util qw(xml_escape_strref);
use Storable qw(dclone);

sub get_commands {
    return {
        import => {need_config => 1, handler => \&run, info => 'Import translations from already existing resource files'},
    }
}

sub init {
    my ($self, $command) = @_;

    $self->SUPER::init($command);

    GetOptions(
        "dry-run"                     => \$self->{dry_run},
        "lang|language|languages=s"   => \$self->{languages},
        "disambiguate-keys"           => \$self->{disambiguate_keys},
        "no-report"                   => \$self->{no_report},
        "as-fuzzy"                    => \$self->{as_fuzzy},
        "force-same"                  => \$self->{force_same},
    ) or die "Failed to parse some command-line parameters.";
}

sub run {
    my ($self, $command) = @_;

    my $importer = Serge::Importer->new();

    $importer->{dry_run} = 1 if $self->{dry_run};
    $importer->{save_report} = 1 unless $self->{no_report};
    $importer->{debug} = 1 if $self->{parent}->{debug};
    $importer->{disambiguate_keys} = 1 if $self->{disambiguate_keys};
    $importer->{as_fuzzy} = 1 if $self->{as_fuzzy};
    $importer->{force_same} = 1 if $self->{force_same};

    if ($self->{languages}) {
        my @l = split(/,/, $self->{languages});
        $importer->{limit_destination_languages} = \@l;
    }

    print "\n*** DRY RUN ***\n" if $self->{dry_run};

    map {
        print "\n*** $_ ***\n\n";

        my $config = Serge::Config->new($_);
        $config->chdir();
        my $processor = Serge::Engine::Processor->new($importer, $config);
        $processor->run();

    } $self->{parent}->get_config_files;

    if (!$self->{no_report}) {
        print "\nSaving reports:\n";
        foreach my $lang (sort keys %{$importer->{report}}) {
            my $filename = "serge-import-report-$lang.html";
            print "\t$filename...";

            my $html;
            my $error_totals = {};
            foreach my $key (sort keys %{$importer->{report}->{$lang}}) {
                $html .= qq|<tr><th colspan="2">$key</th></tr>\n|;
                my $file_data = $importer->{report}->{$lang}->{$key};
                foreach my $row_data (@$file_data) {
                    $error_totals->{$row_data->{error_status}}++ if $row_data->{error_status};
                    my $severity = $row_data->{severity};
                    my $key = $row_data->{key} ne '' ? $row_data->{key} : qq|<em>Empty key</em>|;
                    my $status = $row_data->{error_status} ne '' ? qq|<span class="status">$row_data->{error_status}</span| : '';

                    map {
                        $row_data->{$_} = xml_escape($row_data->{$_});
                        $row_data->{$_} = '&nbsp;' if $row_data->{$_} eq '';
                    } qw(key source translation);

                    my $class = qq| class="$severity"| if $severity ne '';
                    $html .= qq|
<tr class="key $severity">
    <td colspan="2">$key$status</td>
</tr>

<tr$class>
    <td>$row_data->{source}</td>
    <td>$row_data->{translation}</td>
</tr>
|;
                } # end foreach row

            } # end foreach key

            my $html_error_totals = '';
            my $class;
            map {
                $class = lc($1) if $_ =~ m/^SERGE_(.*?)_/;
                $html_error_totals .= qq|<tr class="$class"><td>$_</td><td>$error_totals->{$_}</td></tr>\n|;
            } sort severity_sort keys %$error_totals;

            $html = qq|
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
</head>
<style>
    \@import url(http://fonts.googleapis.com/css?family=Roboto:400,300,300italic);
    body {
        font-family: Roboto, sans-serif;
        font-weight: 300;
        text-align: center;
    }

    h1 {
        font-weight: 400;
        margin: 1.5em 0 0;
    }

    table {
        border-collapse: collapse;
    }

    td {
        vertical-align: top;
        padding: 0.4em;
        border: 1px solid #ccc;
    }

    table.summary {
        display: inline-block;
        margin-top: 3em;
    }

    table.summary tr td:last-child {
        text-align: right;
    }

    table.details {
        width: 100%;
    }

    .details th {
        padding: 3em 0 1em;
        font-weight: 400;
        font-size: 120%;
        color: #0af;
        word-break: break-word;
    }

    tr.notice td {
        background-color: #fea;
    }

    tr.key.notice td {
        background-color: #dc8;
        color: #000;
    }

    tr.warning td {
        background-color: #fcc;
    }

    tr.key.warning td {
        background-color: #daa;
        color: #000;
    }

    tr.error td {
        background-color: #c00;
        color: #fff;
    }

    tr.key.error td {
        background-color: #a00;
    }

    .details td {
        width: 50%;
        position: relative;
        word-break: break-word;
    }

    tr.key.status td {
        background: none;
        border: none;
        color: #999;
        font-style: italic;
        font-weight: bold;
        font-size: 100%;
    }

    tr.key.status.notice td {
        color: #c2ae60;
    }

    tr.key.status.error td {
        color: #f00;
    }

    td .status {
        font-style: italic;
        position: absolute;
        right: 0.4em;
    }

    .key td {
        font-size: 80%;
        color: #999;
        background: #f8f8f8;
        text-align: center;
    }

    p.footer {
        margin: 3em 0;
        font-style: italic;
        font-size: 80%;
        color: #999;
    }

    .br {
        font-size: 70%;
        background: #999;
        color: white;
        padding: 0 0.4em;
        margin-left: 0.2em;
        border-radius: 3px;
    }

    .br:before {
        content: "SEP"
    }

</style>
<body>

<h1>Import Report for '$lang' Language</h1>

<table class="summary">
$html_error_totals
<table>

<table class="details">
$html
</table>

<p class="footer">&mdash; end of document &mdash;</p>

</body>
</html>
|;

            open OUT, ">$filename" || die $!;
            binmode OUT, ":utf8";
            print OUT $html;
            close OUT;
            print " Done\n";
        } # end foreach lang
    } # end if

    print "\n";
    print "Statistics:\n";
    my $data = [
        ['Language', 'Files', 'Notices', 'Warnings', 'Errors']
    ];
    foreach my $lang (sort keys %{$importer->{stats}}) {
        my $stats = $importer->{stats}->{$lang};
        $lang = 'source language' if $lang eq '';
        push @$data, [$lang, $stats->{files}, $stats->{notices}, $stats->{warnings}, $stats->{errors}];
    }
    print_formatted_table($data);

    $importer->cleanup;

    return 0;
}

sub severity_sort {
    my $a_n = 0;
    $a_n = 1 if $a =~ m/^SERGE_WARNING_/;
    $a_n = 2 if $a =~ m/^SERGE_NOTICE_/;

    my $b_n = 0;
    $b_n = 1 if $b =~ m/^SERGE_WARNING_/;
    $b_n = 2 if $b =~ m/^SERGE_NOTICE_/;

    return $a_n <=> $b_n if $a_n != $b_n; # if priorities differ, sort by priority
    return $a cmp $b; # otherwise, sort alphabetically
}

sub xml_escape {
    my $s = shift;
    xml_escape_strref(\$s);
    $s =~ s/$Serge::Util::UNIT_SEPARATOR/<span class="br"><\/span><br\/>/sgi;
    $s =~ s/\n/<br\/>/sgi;
    return $s;
}

sub print_formatted_table {
    my ($data) = @_;

    $data = dclone($data); # clone data not to alter the original data passed by reference

    my @widths;
    foreach my $row (@$data) {
        for (0..$#$row) {
            my $len = length($row->[$_]);
            $widths[$_] = $len if $widths[$_] < $len;
        }
    }

    my @delim_row;
    map {
        push @delim_row, '-' x $_;
    } @widths;

    # insert delimiter row below the row of column names
    splice @$data, 1, 0, \@delim_row;
    # insert delimiter row above the row of column names
    unshift @$data, \@delim_row;
    # insert delimiter row at the end of the table
    push @$data, \@delim_row;

    foreach my $row (@$data) {
        for (0..$#$row) {
            print (($_ > 0) ? '    ' : '');
            print pad($row->[$_], $widths[$_]);
        }
        print "\n";
    }
}

# not a class method
sub pad {
    my ($s, $len) = @_;
    return $s . (' ' x ($len - length($s)));
}

1;