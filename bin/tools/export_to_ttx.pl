#!/usr/bin/env perl

use strict;

use utf8;

# Make script find the plugins properly
# no matter what directory it is running from

BEGIN {
    use Cwd qw(abs_path);
    use File::Basename;
    use File::Spec::Functions qw(catfile);
    unshift(@INC, catfile(dirname(abs_path(__FILE__)), '../../lib'));
}

use IO::File;
use Digest::MD5 qw(md5_hex);
use Encode qw(encode_utf8);
use File::Path;

use Serge::Util::WordStats qw/get_wordcount_chunks count_words/;
use Serge::DB;
my $db = Serge::DB->new();

# determining the current directory where the script is located

my $SCRIPT_DIR = dirname(abs_path(__FILE__));

# Initializing output

$| = 1; # autoflush output
binmode(STDOUT, ':utf8'); # to avoid 'Wide character in print' warning

# reading input parameters

my $known_params = {
    'database'         => { 'min_length' => 1, 'max_length' => 1, 'optional' => 1 },
    'languages'        => { 'min_length' => 1 },
    'namespaces'       => { 'min_length' => 1 },
    'items'            => { 'min_length' => 1 },
    'exclude-items'    => { 'min_length' => 1 },
    'files'            => { 'min_length' => 1 },
    'exclude-files'    => { 'min_length' => 1 },
    'match'            => { 'min_length' => 1 },
    'help'             => { 'max_length' => 0 },
    'list'             => { 'max_length' => 0 },
    'include-fuzzy'    => { 'max_length' => 0 },
    'include-empty'    => { 'max_length' => 0 },
    'force-translated' => { 'max_length' => 0 },
    'force-duplicate'  => { 'max_length' => 0 },
    'output-format'    => { 'min_length' => 1, 'max_length' => 1, 'optional' => 1 },
    'mask'             => { 'min_length' => 1, 'max_length' => 1 },
};

my $param = {};

foreach my $arg (@ARGV) {
    if ($arg =~ /^--(\w+.*)$/) {
        my ($key, $val) = split('=', $1, 2);
        my @values = split(',', $val);
        $param->{$key} = \@values;
    } else {
        $param->{''} = [] unless exists $param->{''};
        push (@{$param->{''}}, $arg);
    }
}

my $ttx_format = 1;
if (exists $param->{'output-format'}) {
    my $f = $param->{'output-format'}->[0];
    if ($f eq 'ttx') {
        # nothing, use defaults
    } elsif ($f eq 'tmx') {
        $ttx_format = undef;
    } else {
        print "Unknown output format: '$f'\n";
        print "Available formats: 'ttx', 'tmx'\n";
        exit(1);
    }
}

if (($ttx_format && ((!exists $param->{languages}) || (!exists $param->{namespaces} && !exists $param->{items}))) && (!exists $param->{list}) || (exists $param->{help})) {
    print "\n";
    print "Usage: $0 --languages=<list> --namespaces=<list>\n";
    print "                      [--files=<list>] [--exclude-files=<list>]\n";
    print "                      [--items=<list>] [--exclude-items=<list>]\n";
    print "                      [--match=<list>]\n";
    print "                      [--include-fuzzy]\n";
    print "                      [--include-empty]\n";
    print "                      [--force-translated]\n";
    print "                      [--force-duplicate]\n";
    print "                      [--mask=<output_mask>]\n";
    print "                      [--database=<DBI:Driver:source>]\n";
    print "                      [--list|--help]\n";
    print "\n";
    print "  --languages:        A comma-separated list of target languages\n";
    print "\n";
    print "  --namespaces:       A comma-separated list of target namespaces\n";
    print "\n";
    print "  --files:            A comma-separated list of file paths that should only be included\n";
    print "                      (within given namespaces)\n";
    print "\n";
    print "  --exclude-files:    A comma-separated list of file paths that should be excluded\n";
    print "                      (within given namespaces)\n";
    print "\n";
    print "  --items:            A comma-separated list of item IDs that should only be included\n";
    print "                      (within given namespaces)\n";
    print "\n";
    print "  --exclude-items:    A comma-separated list of item IDs that should be excluded\n";
    print "                      (within given namespaces)\n";
    print "\n";
    print "  --match:            A comma-separated list of substrings to match items' comments against;\n";
    print "                      only strings whose comments match any of the pattern will be included\n";
    print "\n";
    print "  --include-fuzzy:    Also export translated strings which are marked as fuzzy. Has no effect\n";
    print "                      with --force-translated\n";
    print "\n";
    print "  --include-empty:    Also export translated strings with blank translations. Has no effect\n";
    print "                      with --force-translated\n";
    print "\n";
    print "  --force-translated: Force export strings even if they are translated already\n";
    print "\n";
    print "  --force-duplicate:  Force export duplicate strings\n";
    print "\n";
    print "  --mask:             An output file naming pattern.\n";
    print "                      Default: 'serge-%DATETIME%-%LANG%'\n";
    print "\n";
    print "                      %DATETIME% is optional and will be substituted\n";
    print "                      with the current timestamp\n";
    print "\n";
    print "                      %LANG% is optional (will be appended automatically\n";
    print "                      if exporting to more than one language)\n";
    print "\n";
    print "  --database:         Optional path to a database file\n";
    print "                      Default: value of 'L10N_DATABASE' environment variable\n";
    print "\n";
    print "  --output-format:    Optional file format ('ttx' or 'tmx')\n";
    print "                      Default: ttx\n";
    print "\n";
    print "  --list:             List available namespaces and languages, and exit\n";
    print "\n";
    print "  --help:             Show this help and exit\n";
    print "\n";
    exit(1);
}

my $db_source = $param->{database}->[0] || $ENV{L10N_DATABASE};
die "Neither --database parameter nor 'L10N_DATABASE' environment variable provided\n" unless $db_source;

# TODO: support specifying database username and password
print "Using database file $db_source\n";
$db->open($db_source);

if (exists $param->{list}) {
    list_namespaces();
    list_languages();
    exit;
}

foreach my $key (keys %$param) {
    if (!exists($known_params->{$key})) {
        die "Unknown parameter '$key'\n";
    }

    my $n = scalar(@{$param->{$key}});
    my $min = $known_params->{$key}->{min_length};
    my $max = $known_params->{$key}->{max_length};

    my $prefix = ($key eq '') ? 'Default list of parameters' : "Parameter '$key'";

    if (($n == 0) && ($known_params->{$key}->{type} eq 'array')) {
        die "$prefix expects at least one value\n";
    }
    if (($n > 0) && ($known_params->{$key}->{type} eq 'flag')) {
        die "$prefix expects no value\n";
    }
    if (exists $known_params->{$key}->{min_length} && ($n < $min)
            && !($n == 0 && exists $known_params->{$key}->{optional})) {
        if ($min == 1) {
            die "$prefix expects at least one value\n";
        } else {
            die "$prefix expects at least $min values\n";
        }
    }
    if (exists $known_params->{$key}->{max_length} && ($n > $max)) {
        if ($max == 0) {
            die "$prefix expects no values\n";
        } elsif ($max == 1) {
            die "$prefix expects exactly one value\n";
        } else {
            die "$prefix expects no more than $max values\n";
        }
    }
}

delete $param->{'include-fuzzy'} if exists $param->{'force-translated'};
delete $param->{'include-empty'} if exists $param->{'force-translated'};

my @languages = @{$param->{languages}};

my $OUT_PATH = $param->{mask}->[0] || "serge-%DATETIME%-%LANG%";

if ((scalar(@languages) > 1) && ($OUT_PATH !~ m/%LANG%/)) {
    $OUT_PATH .= '-%LANG%';
}

check_languages();
check_namepspaces();
#check_files();
check_items();

print "Using output path mask: $OUT_PATH\n";

foreach my $lang (@languages) {
    print "Exporting data for lang '$lang'\n";
    do_export($lang, $ttx_format ? \&ttx_export_callback : \&tmx_export_callback);
}

sub list_namespaces {
    my $sqlquery =
        "SELECT DISTINCT namespace ".
        "FROM files";
    my $sth = $db->prepare($sqlquery);
    $sth->execute || die $sth->errstr;

    print "\n";
    print "List of known namespaces:\n";
    print "\n";

    my @a;
    while (my $hr = $sth->fetchrow_hashref()) {
        push @a, $hr->{namespace};
    }
    $sth->finish;
    print "\t", join("\n\t", sort @a), "\n";
}

sub list_languages {
    my $sqlquery =
        "SELECT DISTINCT language ".
        "FROM translations";
    my $sth = $db->prepare($sqlquery);
    $sth->execute || die $sth->errstr;

    print "\n";
    print "List of known languages:\n";
    print "\n";

    my @a;
    while (my $hr = $sth->fetchrow_hashref()) {
        push @a, $hr->{language};
    }
    $sth->finish;
    print "\t", join("\n\t", sort @a), "\n";
}

sub _check_field {
    my ($param_name, $table, $field) = @_;

    if (exists $param->{$param_name}) {
        my $count = scalar(@{$param->{$param_name}});
        if ($count > 0) {
            my $placeholders = join(',', split('', '?' x $count));
            my $sqlquery = "SELECT $field FROM $table where $field IN ($placeholders)";
            my $sth = $db->prepare($sqlquery);
            my $n = 0;

            foreach my $file (@{$param->{$param_name}}) {
                $sth->bind_param(++$n, $file) || die $sth->errstr;
            }

            $sth->execute || die $sth->errstr;

            my %f;
            map { $f{$_} = 1 } @{$param->{$param_name}};

            while (my $hr = $sth->fetchrow_hashref()) {
                delete $f{$hr->{$field}};
            }

            if (scalar(keys %f) > 0) {
                foreach my $path (sort keys %f) {
                    print "ERROR: Unknown $table.$field value in '--$param_name' parameter: '$path'\n";
                }
                exit(1);
            }
        }
    }
}

sub check_languages {
    _check_field('languages', 'translations', 'language');
}

sub check_namepspaces {
    _check_field('namespaces', 'files', 'namespace');
}

#sub check_files {
#    _check_field('files', 'files', 'path');
#    _check_field('exclude-files', 'files', 'path');
#}

sub check_items {
    _check_field('items', 'items', 'id');
    _check_field('exclude-items', 'items', 'id');
}

sub do_export {
    my ($lang, $render_callback) = @_;

    # reading the list of items with empty translations

    my ($namespaces_count, $namespaces_filter);
    if (exists $param->{namespaces}) {
        $namespaces_count = scalar(@{$param->{namespaces}});
        my $namespaces_placeholders = join(',', split('', '?' x $namespaces_count));
        $namespaces_filter = "AND files.namespace IN ($namespaces_placeholders) ";
    }

    my ($files_in_count, $files_like_count, $files_filter);
    my @files_in;
    my @files_like;
    if (exists $param->{files}) {
        foreach my $file (@{$param->{files}}) {
            if ($file =~ m/\*/) {
                push @files_like, _file_to_like_mask($file);
            } else {
                push @files_in, $file;
            }
        }

        my @files_filter_items;

        $files_in_count = scalar(@files_in);
        if ($files_in_count > 0) {
            my $files_placeholders = join(',', split('', '?' x $files_in_count));
            push @files_filter_items, "files.path IN ($files_placeholders)";
        }

        $files_like_count = scalar(@files_like);
        map {
            push @files_filter_items, "files.path LIKE ? ESCAPE '!'";
        } @files_like;

        $files_filter = (scalar @files_filter_items > 0) ? 'AND ('.join(' OR ', @files_filter_items).') ' : '';
    }

    my ($exclude_files_in_count, $exclude_files_like_count, $exclude_files_filter);
    my @exclude_files_in;
    my @exclude_files_like;
    if (exists $param->{'exclude-files'}) {
        foreach my $file (@{$param->{'exclude-files'}}) {
            if ($file =~ m/\*/) {
                push @exclude_files_like, _file_to_like_mask($file);
            } else {
                push @exclude_files_in, $file;
            }
        }

        my @exclude_files_filter_items;

        $exclude_files_in_count = scalar(@exclude_files_in);
        if ($exclude_files_in_count > 0) {
            my $exclude_files_placeholders = join(',', split('', '?' x $exclude_files_in_count));
            push @exclude_files_filter_items, "files.path IN ($exclude_files_placeholders)";
        }

        $exclude_files_like_count = scalar(@exclude_files_like);
        map {
            push @exclude_files_filter_items, "files.path LIKE ? ESCAPE '!'";
        } @exclude_files_like;

        $exclude_files_filter = (scalar @exclude_files_filter_items > 0) ? 'AND NOT ('.join(' OR ', @exclude_files_filter_items).') ' : '';
    }

    my ($items_count, $items_include_filter);
    if (exists $param->{items}) {
        $items_count = scalar(@{$param->{items}});
        my $items_placeholders = join(',', split('', '?' x $items_count));
        $items_include_filter = ($items_count > 0) ? "AND items.id IN ($items_placeholders) " : "";
    }

    my ($exclude_items_count, $exclude_items_filter);
    if (exists $param->{'exclude-items'}) {
        $exclude_items_count = scalar(@{$param->{'exclude-items'}});
        my $exclude_items_placeholders = join(',', split('', '?' x $exclude_items_count));
        $exclude_items_filter = ($exclude_items_count > 0) ? "AND items.id NOT IN ($exclude_items_placeholders) " : "";
    }

    my ($match_count, $match_filter);
    if (exists $param->{match}) {
        $match_count = scalar(@{$param->{match}});
        my $match_placeholders = join(',', split('', '?' x $match_count));
        $match_filter = '';
        if ($match_count > 0) {
            my @match_rules;
            map {
                push @match_rules, ("items.hint LIKE ?", "items.comment LIKE ?");
            } @{$param->{match}};
            $match_filter = "AND (" . join(' OR ', @match_rules) . ") ";
        }
    }

    my $translations_filter = '';

    if ($ttx_format) {
        $translations_filter .=  " OR translations.fuzzy = 1" if exists $param->{'include-fuzzy'};
        $translations_filter .=  " OR translations.string IS NULL" if exists $param->{'include-empty'};

        $translations_filter = "AND (translations.id IS NULL".$translations_filter.") ";
        $translations_filter = '' if exists $param->{'force-translated'};
    } else {
        # when exporting to TMX, only include non-empty translated units
        $translations_filter = "AND (translations.string IS NOT NULL) ";
    }

    my $sqlquery =
        "SELECT ".
        "items.id, ".
        "strings.string, strings.context, items.hint, ".
        "files.namespace, files.path, ".
        "translations.string AS translation ".
        "FROM items ".

        "JOIN strings ".
        "ON strings.id = items.string_id ".

        "LEFT OUTER JOIN translations ".
        "ON translations.item_id = items.id ".
        "AND translations.language = ? ".

        "JOIN files ".
        "ON files.id = items.file_id ".

        "WHERE items.orphaned = 0 ".
        "AND files.orphaned = 0 ".
        "AND strings.skip = 0 ".
        $translations_filter.
        $namespaces_filter.
        $files_filter.
        $exclude_files_filter.
        $items_include_filter.
        $exclude_items_filter.
        $match_filter.
        "ORDER BY ".
        "files.namespace, ".
        "files.path, ".
        "items.id ";

    #print "\n=================\n".$sqlquery."\n=================\n";

    my $sth = $db->prepare($sqlquery);
    my $n = 0;

    $sth->bind_param(++$n, $lang) || die $sth->errstr;
    #print "$n) $lang\n";

    if ($namespaces_count) {
        foreach my $ns (@{$param->{namespaces}}) {
            $sth->bind_param(++$n, $ns) || die $sth->errstr;
            #print "$n) $ns\n";
        }
    }

    if ($files_in_count) {
        foreach my $file (@files_in) {
            $sth->bind_param(++$n, $file) || die $sth->errstr;
            #print "$n) $file\n";
        }
    }

    if ($files_like_count) {
        foreach my $file (@files_like) {
            $sth->bind_param(++$n, $file) || die $sth->errstr;
            #print "$n) $file\n";
        }
    }

    if ($exclude_files_in_count) {
        foreach my $file (@exclude_files_in) {
            $sth->bind_param(++$n, $file) || die $sth->errstr;
            #print "$n) $file\n";
        }
    }

    if ($exclude_files_like_count) {
        foreach my $file (@exclude_files_like) {
            $sth->bind_param(++$n, $file) || die $sth->errstr;
            #print "$n) $file\n";
        }
    }

    if ($items_count) {
        foreach my $item (@{$param->{items}}) {
            $sth->bind_param(++$n, $item) || die $sth->errstr;
            #print "$n) $item\n";
        }
    }

    if ($exclude_items_count) {
        foreach my $item (@{$param->{'exclude-items'}}) {
            $sth->bind_param(++$n, $item) || die $sth->errstr;
            #print "$n) $item\n";
        }
    }

    if ($match_count) {
        foreach my $item (@{$param->{match}}) {
            $sth->bind_param(++$n, '%'.$item.'%') || die $sth->errstr;
            #print "$n) $item\n";
            $sth->bind_param(++$n, '%'.$item.'%') || die $sth->errstr;
            #print "$n) $item\n";
        }
    }

    $sth->execute || die $sth->errstr;

    my $ttx;
    my $html;

    my $locale = uc($lang); # e.g. RU-RU

    my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime(time);
    my $timestamp = sprintf("%04d-%02d-%02d-%02d-%02d-%02d", $year + 1900, $mon + 1, $mday, $hour, $min, $sec);

    &$render_callback(\$ttx, \$html, $lang, $locale, $sth, $timestamp);

    my $filename = $OUT_PATH;
    $filename =~ s/%LANG%/$lang/g;
    $filename =~ s/%DATETIME%/$timestamp/g;

    if ($filename =~ m|[\\/]|) {
        my $path = dirname($filename);
        if ($path ne '.') {
            eval { mkpath($path) };
            ($@) && die "Couldn't create $path: $@\n";
        }
    }

    my $ext = $ttx_format ? 'ttx' : 'tmx';

    open(TTX, ">$filename.$ext");
    binmode(TTX, ':utf8');
    print TTX $ttx;
    close(TTX);

    print "\tSaved $filename.$ext\n";

    open(HTML, ">$filename.html");
    binmode(HTML, ':utf8');
    print HTML $html;
    close(HTML);

    print "\tSaved HTML report to $filename.html\n";
}

sub ttx_export_callback {
    my ($ttxref, $htmlref, $lang, $locale, $sth, $timestamp) = @_;

    my $word_count = 0;
    my %found_namespaces;
    my %already_exported;

    while (my $hr = $sth->fetchrow_hashref()) {
        my $id = $hr->{id};
        my $string = $hr->{string};
        my $context = $hr->{context};
        my $hint = $hr->{context};
        my $translation = $hr->{translation} || $string;
        my $namespace = $hr->{namespace};
        my $path = $hr->{path};
        my $context_differs = $hint && $context && ($hint ne $context);

        # build a list of actual namespaces (which can be smaller than a list of provided ones)
        $found_namespaces{$namespace} = 1;

        # check if the sting was already exported, and skip it unless --force-duplicate mode is enabled
        if (exists $already_exported{$string} && !exists $param->{'force-duplicate'}) {
            next;
        }
        $already_exported{$string} = 1;

        my $chunks = get_wordcount_chunks($string);
        my $string_ttx = make_final_xml($chunks);

        my $translation_chunks = get_wordcount_chunks($translation);
        my $translation_ttx = make_final_xml($translation_chunks);

        my $string_html = make_final_xml($chunks, 1); # 1:for_html

        my $s_word_count = count_words($chunks);
        $word_count += $s_word_count;

        _xml_encode_ref(\$context);
        _xml_encode_ref(\$hint);

        _xml_encode_ref(\$namespace);
        _xml_encode_ref(\$path);

        my $hint_ttx = $hint ? qq{<ut Class="comment" DisplayText=\"hint\">$hint</ut>} : '';
        my $context_ttx = $context_differs ? qq{<ut Class="comment" DisplayText="context">$context</ut>} : '';

        my $hint_html = $hint ? qq{<div class="hint" title="hint">$hint</div>} : '';
        my $context_html = $context_differs ? qq{<div class="context" title="context">$context</div>} : '';

        $$ttxref .= <<__END__;
<ut Type="standalone" Style="external" RightEdge="angle">$id</ut>$hint_ttx$context_ttx
<Tu Origin="undefined"><Tuv Lang="EN-US">$string_ttx</Tuv><Tuv Lang="$locale">$translation_ttx</Tuv></Tu>
__END__

        $$htmlref .= <<__END__;
    <tr>
        <td>$namespace</td>
        <td>$path</td>
        <td>$id</td>
        <td>$string_html$hint_html$context_html</td>
        <td>$s_word_count</td>
    </tr>
__END__
    }
    $sth->finish;

    $$ttxref = <<__END__;
<?xml version='1.0'?>
<TRADOStag Version="2.0">
<FrontMatter><ToolSettings CreationDate="$timestamp" CreationTool="TTX Export Tool" CreationToolVersion="1.0"/>
<UserSettings DataType="XML" O-Encoding="UTF-8" SettingsName="Predefined HTML Settings"
SourceLanguage="EN-US" TargetLanguage="$locale"
TargetDefaultFont="Arial" PlugInInfo=""/>
</FrontMatter><Body><Raw>$$ttxref</Raw></Body></TRADOStag>
__END__

    my $namespaces_html = join(', ', sort keys %found_namespaces);

    $$htmlref = <<__END__;
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />

<style>
table {
    width: 100%;
    border-collapse: collapse;
}
th, td {
    padding: 4px;
    border: 1px solid #ccc;
    vertical-align: top;
}
th {
    text-align: left;
    font-size: 90%;
}
td strong {
    color: #c66;
}
.context, .hint {
    font-size: 90%;
    margin-top: 5px;
}
.context {
    color: #9ff;
}
.hint {
    color: #090;
}
.dont-count {
    color: #6c6;
}
</style>

</head>
<body style="font-family: sans-serif">

<h1>Export report: $lang</h1>
<h2>Namespaces: $namespaces_html</h2>
<h2>Word count: $word_count</h2>

<table>

    <tr>
        <th>Namespace</th>
        <th>Path</th>
        <th>ID</th>
        <th>String, context, hint</th>
        <th>Words</th>
    </tr>

$$htmlref
</table>
</body>
</html>
__END__

}

sub tmx_export_callback {
    my ($ttxref, $htmlref, $lang, $locale, $sth, $timestamp) = @_;

    my $word_count = 0;
    my %found_namespaces;
    my %already_exported;

    while (my $hr = $sth->fetchrow_hashref()) {
        my $id = $hr->{id};
        my $string = $hr->{string};
        my $context = $hr->{context};
        my $hint = $hr->{context};
        my $translation = $hr->{translation} || $string;
        my $namespace = $hr->{namespace};
        my $path = $hr->{path};
        my $context_differs = $hint && $context && ($hint ne $context);

        # build a list of actual namespaces (which can be smaller than a list of provided ones)
        $found_namespaces{$namespace} = 1;

        next if exists $already_exported{$string};
        $already_exported{$string} = 1;

        my $chunks = get_wordcount_chunks($string);
        my $string_ttx = make_final_xml($chunks);

        my $translation_chunks = get_wordcount_chunks($translation);
        my $translation_ttx = make_final_xml($translation_chunks);

        my $string_html = make_final_xml($chunks, 1); # 1:for_html

        my $s_word_count = count_words($chunks);
        $word_count += $s_word_count;

        _xml_encode_ref(\$context);
        _xml_encode_ref(\$hint);

        _xml_encode_ref(\$namespace);
        _xml_encode_ref(\$path);

        my $hint_ttx = $hint ? qq{\n    <note>$hint</note>} : '';
        my $context_ttx = $context_differs ? qq{\n    <prop type="x-context">$context</prop>} : '';

        my $hint_html = $hint ? qq{<div class="hint" title="hint">$hint</div>} : '';
        my $context_html = $context_differs ? qq{<div class="context" title="context">$context</div>} : '';

        $$ttxref .= <<__END__;
<tu tuid="$id">$hint_ttx$context_ttx
    <tuv xml:lang="EN-US"><seg>$string_ttx</seg></tuv>
    <tuv xml:lang="$locale"><seg>$translation_ttx</seg></tuv>
</tu>

__END__

        $$htmlref .= <<__END__;
    <tr>
        <td>$namespace</td>
        <td>$path</td>
        <td>$id</td>
        <td>$string_html$hint_html$context_html</td>
        <td>$s_word_count</td>
    </tr>
__END__
    }
    $sth->finish;

    $$ttxref = <<__END__;
<?xml version="1.0"?>
<tmx version="1.4">
    <header creationtool="TMX Export Tool"
        creationtoolversion="1.0"
        segtype="block"
        o-tmf="internal"
        adminlang="EN-US"
        srclang="EN-US"
        datatype="unknown" />
    <body>
$$ttxref
    </body>
</tmx>
__END__

    my $namespaces_html = join(', ', sort keys %found_namespaces);

    $$htmlref = <<__END__;
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />

<style>
table {
    width: 100%;
    border-collapse: collapse;
}
th, td {
    padding: 4px;
    border: 1px solid #ccc;
    vertical-align: top;
}
th {
    text-align: left;
    font-size: 90%;
}
td strong {
    color: #c66;
}
.context, .hint {
    font-size: 90%;
    margin-top: 5px;
}
.context {
    color: #9ff;
}
.hint {
    color: #090;
}
.dont-count {
    color: #6c6;
}
</style>

</head>
<body style="font-family: sans-serif">

<h1>Export report: $lang</h1>
<h2>Namespaces: $namespaces_html</h2>
<h2>Word count: $word_count</h2>

<table>

    <tr>
        <th>Namespace</th>
        <th>Path</th>
        <th>ID</th>
        <th>String, context, hint</th>
        <th>Words</th>
    </tr>

$$htmlref
</table>
</body>
</html>
__END__

}

sub make_final_xml {
    my ($aref, $for_html) = @_;

    my $xml;

    foreach my $chunk (@$aref) {
        my $s_ttx = $chunk->{string};
        _xml_encode_ref(\$s_ttx);

        my $s_html = $chunk->{string};
        _xml_encode_ref(\$s_html, 1);
        if ($for_html) {
            my $class = $chunk->{class};
            $class = $class ? qq{ class="$class"} : '';
            $xml .= ($chunk->{translate}) ? $s_html : qq{<strong$class>$s_html</strong>};
        } else {
            $xml .= ($chunk->{translate} || $chunk->{class} eq 'dont-count') ? $s_ttx : (
                $ttx_format ? qq{<ut Style="nonxlatable" DisplayText="$s_ttx">$s_ttx</ut>} :  qq{<hi>$s_ttx</hi>}
            );
        }
    }

    return $xml;
}


sub _xml_encode_ref {
    my ($strref, $for_html) = @_;
    $$strref =~ s/\&/&amp;/g;
    $$strref =~ s/\"/&quot;/g;
    $$strref =~ s/\</&lt;/g;
    $$strref =~ s/\>/&gt;/g;
    if ($for_html) {
        $$strref =~ s/\n/<br\/>/g;
    }
}

sub _file_to_like_mask {
    my $s = shift;

    # we use '!' as an escaping symbol

    $s =~ s/([%_!])/!$1/g;
    $s =~ s/\*/%/g;
    $s =~ s/\?/_/g;

    return $s;
}
