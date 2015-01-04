#!/usr/bin/perl

# Author: Daniel "Trizen" Șuteu
# License: GPLv3
# Date: 04 January 2015
# Website: http://github.com/trizen

#
## Analyze your Perl code and see whether you are or not a true Perl hacker!
#

# More info about this script:
# http://trizenx.blogspot.com/2015/01/perl-code-analyzer.html

use utf8;
use 5.010;
use strict;
use warnings;

use IPC::Open3 qw(open3);
use Encode qw(decode_utf8);
use Getopt::Long qw(GetOptions);
use Algorithm::Diff qw(LCS_length);

my $strict_level = 1;
my %ignored_types;

sub help {
    my ($code) = @_;
    print <<"HELP";
usage: $0 [options] [file] [...]

options:
    --strict [level]   : sets the strictness level (default: $strict_level)

Valid strict levels:
    >= 1   : ignores strings, PODs, comments, spaces and semicolons
    >= 2   : ignores round parentheses
    >= 3   : ignores here-documents, (q|qq|qw|qx) quoted strings
    >= 4   : ignores hex and binary literal numbers

If level=0, any stricture will be disabled.
HELP
    exit($code // 0);
}

GetOptions('strict=i' => \$strict_level,
           'help|h'   => sub { help(0) },)
  or die("Error in command line arguments\n");

@ARGV || help(2);

if ($strict_level >= 1) {
    @ignored_types{
        qw(
          pod
          DATA
          comment
          vertical_space
          horizontal_space
          other_space
          end_of_statement
          double_quoted_string
          single_quoted_string
          )
    } = ();
}

if ($strict_level >= 2) {
    @ignored_types{
        qw(
          parenthese_beg
          parenthese_end
          )
    } = ();
}

if ($strict_level >= 3) {
    @ignored_types{
        qw(
          heredoc
          heredoc_beg
          q_string
          qq_string
          qw_string
          qx_string
          )
    } = ();
}

if ($strict_level >= 4) {
    @ignored_types{
        qw(
          hex_number
          binary_number
          )
    } = ();
}

sub deparse {
    my ($code) = @_;

    local (*CHLD_OUT, *CHLD_ERR);
    my $pid = open3(undef, \*CHLD_OUT, \*CHLD_ERR, $^X, '-MO=Deparse', '-T', '-e', $code);

    waitpid($pid, 0);
    my $child_exit_status = $? >> 8;
    if ($child_exit_status != 0) {
        die "B::Deparse failed with code: $child_exit_status\n";
    }

    decode_utf8(
                do { local $/; <CHLD_OUT> }
               );
}

sub tokenize {
    my ($code) = @_;
    my $tokenizer = PTokenizer->new();
    $tokenizer->tokenize($code);
}

sub identify {
    my ($tokens) = @_;
    grep { not exists $ignored_types{$_} } map { keys %{$_} } @{$tokens};
}

package PTokenizer {

    no if $] >= 5.018, warnings => "experimental::smartmatch";

    sub new {
        my (undef, %opts) = @_;
        bless \%opts, __PACKAGE__;
    }

    sub _make_esc_delim {
        if ($_[0] ne '\\') {
            my $delim = quotemeta shift;
            return qr{$delim([^$delim\\]*+(?>\\.|[^$delim\\]+)*+)$delim}s;
        }
        else {
            return qr{\\(.*?)\\}s;
        }
    }

    sub _make_end_delim {
        if ($_[0] ne '\\') {
            my $delim = quotemeta shift;
            return qr{[^$delim\\]*+(?>\\.|[^$delim\\]+)*+$delim}s;
        }
        else {
            return qr{.*?\\}s;
        }
    }

    sub _get_delim_pairs {
        return [qw~< >~], [qw~( )~], [qw~{ }~], [qw~[ ]~];
    }

    my %bdelims;
    {
        local $" = q{};
        foreach my $d (_get_delim_pairs()) {
            my @ed = map { quotemeta } @{$d};

            $bdelims{$d->[0]} = qr{
            $ed[0]
            (?>
                [^$ed[0]$ed[1]\\]+
                    |
                \\.
                    |
                (??{$bdelims{$d->[0]}})
            )*
            $ed[1]
          }xs;
        }
    }

    # string - single quote
    my $str_sq = _make_esc_delim(q{'});

    # string - double quote
    my $str_dq = _make_esc_delim(q{"});

    # backtick - backquote
    my $str_bq = _make_esc_delim(q{`});

    # regex - //
    my $match_re = _make_esc_delim(q{/});

    # glob/readline
    my $glob = $bdelims{'<'};

    # Double pairs
    my $dpairs = qr{
    (?=
      (?(?<=\s)
                (.)
                       |
                (\W)
     )
    )
        (??{$bdelims{$+} // _make_esc_delim($+)})
    }x;

    # Double pairs -- comments
    my $dcomm = qr{
        \s* (?>(?<=\s)\# (?-s:.*) \s*)*
    }x;

    # Quote-like balanced (q{}, m//)
    sub _make_single_q_balanced {
        my $name = shift;
        qr{
            $name
            $dcomm
            $dpairs
        }x;
    }

    # Quote-like balanced (q{}, m//)
    my %single_q;
    foreach my $name (qw(q qq qr qw qx m)) {
        $single_q{$name} = _make_single_q_balanced($name);
    }

    # First of balanced pairs
    my $bbpair = qr~[<\[\{\(]~;

    sub _make_double_q_balanced {
        my $name = shift;
        qr{
             $name
             $dcomm

            (?(?=$bbpair)                     # balanced pairs (e.g.: s{}//)
                   $dpairs
                      $dcomm
                   $dpairs
                        |                     # or: single delims (e.g.: s///)
                   $dpairs
                  (??{_make_end_delim($+)})
            )
        }x;
    }

    # Double quote-like balanced (s{}{}, s///)
    my %double_q;
    foreach my $name (qw(tr s y)) {
        $double_q{$name} = _make_double_q_balanced($name);
    }

    my $number     = qr{(?=[0-9]|\.[0-9])[0-9_]*(?:\.(?!\.)[0-9_]*)?(?:[Ee](?:[+-]?[0-9_]+))?};
    my $hex_num    = qr{0x[_0-9A-Fa-f]*};
    my $binary_num = qr{0b[_01]*};

    #my $var_name = qr{\b\w+(?>::\w+)*\b};
    my $var_name    = qr{(?>\w+|(?>::)+|'(?=\w))++};
    my $bracket_var = qr~(?=\s*\{)(?!\h*\{\h*[{}]\})~;
    my $vstring     = qr{\b(?:v[0-9]+(?>\.[0-9][0-9_]*+)*+ | [0-9][0-9_]*(?>\.[0-9][0-9_]*){2,})\b}x;

    # HERE-DOC beginning
    my $bhdoc = qr{
        <<(?>\h*(?>$str_sq|$str_dq)|\\?+(\w+))
    }x;

    my $tr_flags             = qr{[rcds]*};
    my $match_flags          = qr{[msixpogcdual]*};
    my $substitution_flags   = qr{[msixpogcerdual]*};
    my $compiled_regex_flags = qr{[msixpodual]*};

    my @prec_operators     = qw ( ... .. -> ++ -- =~ <=> \\ ? ~~ ~ : );
    my @asigment_operators = qw( && || // ** ! % ^ & * + - = | / . << >> < > );

    my $operators = do {
        local $" = '|';
        qr{@{[map{quotemeta} @prec_operators, @asigment_operators]}};
    };

    my $asigment_operators = do {
        local $" = '|';
        qr{@{[map{"\Q$_=\E"} @asigment_operators]}};
    };

    my @special_var_names = (qw( \\ | + / ~ ! @ $ % ^ & * ( ) } < > : ; " ` ' ? = - [ ] . ), '#', ',');
    my $special_var_names = do {
        local $" = '|';
        qr{@{[map {quotemeta} @special_var_names]}};
    };

    my $perl_keywords = qr{(?>(a(?:bs|ccept|larm|nd|tan2)|b(?:in(?:mode|d)|les
    s|reak)|c(?:aller|h(?:dir|mod|o(?:mp|wn|p)|r(?:oot)?)|lose(?:dir)?|mp|o(?:
    n(?:nect|tinue)|s)|rypt)|d(?:bm(?:close|open)|e(?:f(?:ault|ined)|lete)|ie|
    ump|o)|e(?:ach|ls(?:if|e)|nd(?:grent|hostent|netent|p(?:rotoent|went)|serv
    ent)|of|val|x(?:ec|i(?:sts|t)|p)|q)|f(?:c(?:ntl)?|ileno|lock|or(?:(?:each|
    m(?:at|line)|k))?)|g(?:e(?:t(?:gr(?:ent|gid|nam)|host(?:by(?:addr|name)|en
    t)|login|net(?:by(?:addr|name)|ent)|p(?:eername|grp|pid|r(?:iority|oto(?:b
    yn(?:ame|umber)|ent))|w(?:ent|nam|uid))|s(?:erv(?:by(?:name|port)|ent)|ock
    (?:name|opt))|c))?|iven|lob|mtime|oto|rep|t)|hex|i(?:mport|n(?:dex|t)|octl
    |sa|f)|join|k(?:eys|ill)|l(?:ast|c(?:first)?|e(?:ngth)?|i(?:nk|sten)|o(?:c
    (?:al(?:time)?|k)|g)|stat|t)|m(?:ap|kdir|sg(?:ctl|get|rcv|snd)|y)|n(?:e(?:
    xt)?|ot?)|o(?:ct|pen(?:dir)?|rd?|ur)|p(?:ack(?:age)?|ipe|o[ps]|r(?:intf?|o
    totype)|ush)|quotemeta|r(?:and|e(?:ad(?:(?:dir|lin[ek]|pipe))?|cv|do|name|
    quire|set|turn|verse|winddir|f)|index|mdir)|s(?:ay|calar|e(?:ek(?:dir)?|le
    ct|m(?:ctl|get|op)|nd|t(?:grent|hostent|netent|p(?:grp|r(?:iority|otoent)|
    went)|s(?:ervent|ockopt)))|h(?:ift|m(?:ctl|get|read|write)|utdown)|in|leep
    |o(?:cket(?:pair)?|rt)|p(?:li(?:ce|t)|rintf)|qrt|rand|t(?:ate?|udy)|ub(?:s
    tr)?|y(?:mlink|s(?:call|open|read|seek|tem|write)))|t(?:ell(?:dir)?|i(?:ed
    ?|mes?)|runcate)|u(?:c(?:first)?|mask|n(?:def|l(?:ess|ink)|pack|shift|ti[e
    l])|se|time)|v(?:alues|ec)|w(?:a(?:it(?:pid)?|ntarray|rn)|h(?:en|ile)|rite
    )|xor|BEGIN|END|INIT|CHECK)) \b }x;

    my $perl_filetests = qr{\-[ABCMORSTWXbcdefgkloprstuwxz]};

    sub tokenize {
        my ($self, $code) = @_;

        my $variable      = 0;
        my $flat          = 0;
        my $regex         = 1;
        my $canpod        = 1;
        my $proto         = 0;
        my $format        = 0;
        my $expect_format = 0;
        my @heredoc_eofs;

        my $bracket    = 0;
        my $cbracket   = 0;
        my $parenthese = 0;

        local $SIG{__WARN__} = sub {
            $self->{debug} && print STDERR @_;
        };

        my @result;
        given ($code) {
            {
                when ($expect_format == 1 && m{\G(?=\n)}) {
                    if (m{.*?\n\.\h*(?=\n|\z)}gsc) {
                        push @result, {vertical_space => [$-[0], $-[0] + 1]};
                        push @result, {format => [$-[0] + 1, $+[0]]};
                        $expect_format = 0;
                        $canpod        = 1;
                        $regex         = 1;
                    }
                    else {
                        warn "Invalid format! Position: ", pos;
                        m{\G.}gcs ? redo : exit -1;
                    }
                    redo;
                }
                when ($#heredoc_eofs >= 0 && m{\G(?=\n)}) {
                    my $token = shift @heredoc_eofs;
                    if (m{\G.*?\n\Q$token\E(?=\n|\z)}sgc) {
                        push @result, {vertical_space => [$-[0], $-[0] + 1]};
                        push @result, {heredoc => [$-[0] + 1, $+[0]]};
                    }
                    else {
                        warn "Invalid here-doc! Position: ", pos;
                    }
                    redo;
                }
                when (($regex == 1 || m{\G(?!<<[0-9])}) && m{\G$bhdoc}gc) {
                    push @result, {heredoc_beg => [$-[0], $+[0]]};
                    push @heredoc_eofs, $+;
                    $regex  = 0;
                    $canpod = 0;
                    redo;
                }
                when ($canpod == 1 && m{\G(?<=\n)=[a-zA-Z]}gc) {
                    m{\G.*?\n=cut\h*(?=\n|z)}sgc || m{\G.*\z}gcs;
                    push @result, {pod => [$-[0] - 2, $+[0]]};
                    redo;
                }
                when (m{\G(?=\s)}) {
                    when (m{\G\h+}gc) {
                        push @result, {horizontal_space => [$-[0], $+[0]]};
                        redo;
                    }
                    when (m{\G\v+}gc) {
                        push @result, {vertical_space => [$-[0], $+[0]]};
                        redo;
                    }
                    when (m{\G\s+}gc) {
                        push @result, {other_space => [$-[0], $+[0]]};
                        redo;
                    }
                }
                when ($variable > 0) {
                    when ((m{\G$var_name}gco || m{\G(?<=\$)\#$var_name}gco)) {
                        push @result, {var_name => [$-[0], $+[0]]};
                        $regex    = 0;
                        $variable = 0;
                        $canpod   = 0;
                        $flat     = m~\G(?=\s*\{)~ ? 1 : 0;
                        redo;
                    }
                    when ((m{\G(?<=[\$\%\@\*])} && m{\G(?!\$+$var_name)}o && m{\G(?:\^\w|$special_var_names)}gco)
                          || m~\G\h*\{\h*[{}]\}~gc) {
                        push @result, {special_var_name => [$-[0], $+[0]]};
                        $regex    = 0;
                        $canpod   = 0;
                        $variable = 0;
                        $flat     = m~\G(?=\s*\{)~ ? 1 : 0;
                        redo;
                    }
                    continue;
                }
                when (m{\G#.*}gc) {
                    push @result, {comment => [$-[0], $+[0]]};
                    redo;
                }
                when ($regex == 1 or m{\G(?=[\@\$])}) {
                    when (m{\G\$}gc) {
                        push @result, {scalar_sign => [$-[0], $+[0]]};
                        /\G$bracket_var/o || ++$variable;
                        $regex  = 0;
                        $canpod = 0;
                        $flat   = 1;
                        redo;
                    }
                    when (m{\G\@}gc) {
                        push @result, {array_sign => [$-[0], $+[0]]};
                        /\G$bracket_var/o || ++$variable;
                        $regex  = 0;
                        $canpod = 0;
                        $flat   = 1;
                        redo;
                    }
                    when (m{\G\%}gc) {
                        push @result, {hash_sign => [$-[0], $+[0]]};
                        /\G$bracket_var/o || ++$variable;
                        $regex  = 0;
                        $canpod = 0;
                        $flat   = 1;
                        redo;
                    }
                    when (m{\G\*}gc) {
                        push @result, {glob_sign => [$-[0], $+[0]]};
                        /\G$bracket_var/o || ++$variable;
                        $regex  = 0;
                        $canpod = 0;
                        $flat   = 1;
                        redo;
                    }
                    continue;
                }
                when ($proto == 1 && m{\G\(.*?\)}gcs) {
                    push @result, {sub_proto => [$-[0], $+[0]]};
                    $proto  = 0;
                    $canpod = 0;
                    $regex  = 0;
                    redo;
                }
                when (m{\G\(}gc) {
                    push @result, {parenthese_beg => [$-[0], $+[0]]};
                    ++$parenthese;
                    $regex  = 1;
                    $flat   = 0;
                    $canpod = 0;
                    redo;
                }
                when (m{\G\)}gc) {
                    push @result, {parenthese_end => [$-[0], $+[0]]};
                    $parenthese >= 1
                      ? --$parenthese
                      : warn "Unbalanced parentheses! Position: ", pos;
                    $regex  = 0;
                    $canpod = 0;
                    $flat   = 0;
                    redo;
                }
                when (m~\G\{~gc) {
                    push @result, {cbracket_beg => [$-[0], $+[0]]};
                    ++$cbracket;
                    $regex = 1;
                    $proto = 0;
                    redo;
                }
                when (m~\G\}~gc) {
                    push @result, {cbracket_end => [$-[0], $+[0]]};
                    $flat = 0;
                    $cbracket >= 1
                      ? --$cbracket
                      : warn "Unbalanced curly brackets! Position: ", pos;
                    redo;
                }
                when (m~\G\[~gc) {
                    push @result, {bracket_beg => [$-[0], $+[0]]};
                    ++$bracket;
                    $regex  = 1;
                    $flat   = 0;
                    $canpod = 0;
                    redo;
                }
                when (m~\G\]~gc) {
                    push @result, {bracket_end => [$-[0], $+[0]]};
                    $regex  = 0;
                    $canpod = 0;
                    $flat   = 0;
                    $bracket >= 1
                      ? --$bracket
                      : warn "Unbalanced square brackets! Position: ", pos;
                    redo;
                }
                when ($proto == 0) {
                    when ($canpod == 1 && m{\Gformat\b}gc) {
                        push @result, {keyword => [$-[0], $+[0]]};
                        $regex  = 0;
                        $canpod = 0;
                        $format = 1;
                        redo;
                    }
                    when (
                          (
                           $flat == 0
                             || (
                                 $flat == 1
                                 && (
                                     /\G(?!\w+\h*\})/
                                     && ($#result >= 0
                                         && !exists $result[-1]{dereference_operator})
                                    )
                                )
                          )
                            && m{\G$perl_keywords}gco
                      ) {
                        $canpod = 0;
                        push @result, {keyword => [$-[0], $+[0]]};

                        if ($1 eq 'sub') {
                            $proto = 1;
                            $regex = 0;
                        }
                        else {
                            $regex = 1;
                        }

                        redo;
                    }
                    continue;
                }
                when (/\G(?!(?>tr|[ysm]|q[rwxq]?)\h*=>)/) {

                    /\G(?=[a-z]+\h*\})/ && $flat == 1 ? continue : ();

                    when (m{\G $double_q{s} $substitution_flags }gcxo) {
                        push @result, {substitution => [$-[0], $+[0]]};
                        $regex  = 0;
                        $canpod = 0;
                        redo;
                    }
                    when (m{\G (?> $double_q{tr} | $double_q{y} ) $tr_flags }gxco) {
                        push @result, {translation => [$-[0], $+[0]]};
                        $regex  = 0;
                        $canpod = 0;
                        redo;
                    }
                    when ((m{\G $single_q{m} $match_flags }gcxo || ($regex == 1 && m{\G $match_re $match_flags }gcxo))) {
                        push @result, {match_regex => [$-[0], $+[0]]};
                        $regex  = 0;
                        $canpod = 0;
                        redo;
                    }
                    when (m{\G $single_q{qr} $compiled_regex_flags }gcxo) {
                        push @result, {compiled_regex => [$-[0], $+[0]]};
                        $regex  = 0;
                        $canpod = 0;
                        redo;
                    }
                    when (m{\G$single_q{q}}gco) {
                        push @result, {q_string => [$-[0], $+[0]]};
                        $regex  = 0;
                        $canpod = 0;
                        redo;
                    }
                    when (m{\G$single_q{qq}}gco) {
                        push @result, {qq_string => [$-[0], $+[0]]};
                        $regex  = 0;
                        $canpod = 0;
                        redo;
                    }
                    when (m{\G$single_q{qw}}gco) {
                        push @result, {qw_string => [$-[0], $+[0]]};
                        $regex  = 0;
                        $canpod = 0;
                        redo;
                    }
                    when (m{\G$single_q{qx}}gco) {
                        push @result, {qx_string => [$-[0], $+[0]]};
                        $regex  = 0;
                        $canpod = 0;
                        redo;
                    }
                    continue;
                }
                when (m{\G$str_dq}gco) {
                    push @result, {double_quoted_string => [$-[0], $+[0]]};
                    $regex  = 0;
                    $canpod = 0;
                    $flat   = 0;
                    redo;
                }
                when (m{\G$str_sq}gco) {
                    push @result, {single_quoted_string => [$-[0], $+[0]]};
                    $regex  = 0;
                    $canpod = 0;
                    $flat   = 0;
                    redo;
                }
                when (m{\G$str_bq}gco) {
                    push @result, {backtick => [$-[0], $+[0]]};
                    $regex  = 0;
                    $canpod = 0;
                    $flat   = 0;
                    redo;
                }
                when (m{\G;}goc) {
                    push @result, {end_of_statement => [$-[0], $+[0]]};
                    $canpod = 1;
                    $regex  = 1;
                    $proto  = 0;
                    $flat   = 0;
                    redo;
                }
                when (m{\G=>}gc) {
                    if (@result and (exists $result[-1]{keyword} or exists $result[-1]{file_test})) {
                        $proto  = 0;
                        $format = 0;
                        $result[-1] = {unquoted_string => $result[-1]{keyword} // $result[-1]{file_test}};
                    }
                    push @result, {fat_comma_operator => [$-[0], $+[0]]};
                    $regex  = 1;
                    $canpod = 0;
                    $flat   = 0;
                    redo;
                }
                when (m{\G,}gc) {
                    push @result, {comma_operator => [$-[0], $+[0]]};
                    $regex  = 1;
                    $canpod = 0;
                    $flat   = 0;
                    redo;
                }
                when (m{\G$vstring}gco) {
                    push @result, {v_string => [$-[0], $+[0]]};
                    $regex  = 0;
                    $canpod = 0;
                    redo;
                }
                when (m{\G$perl_filetests\b}gco) {
                    push @result, {file_test => [$-[0], $+[0]]};
                    $regex  = 1;    # ambiguous, but possible
                    $canpod = 0;
                    redo;
                }
                when (m{\G(?=__)}) {
                    when (m{\G__(?>DATA|END)__\b.*\z}gcs) {
                        push @result, {DATA => [$-[0], $+[0]]};
                        redo;
                    }
                    when (m{\G__(?>SUB|FILE|PACKAGE|LINE)__\b}gc) {
                        push @result, {special_token => [$-[0], $+[0]]};
                        $canpod = 0;
                        $regex  = 0;
                        redo;
                    }
                    continue;
                }
                when ($regex == 1 && $] >= 5.017001 && m{\G$glob}gco) {    # perl bug, fixed in 5.17.1
                    push @result, {readline => [$-[0], $+[0]]};
                    $regex  = 0;
                    $canpod = 0;
                    redo;
                }
                when (m{\G$asigment_operators}gco) {
                    push @result, {assignment_operator => [$-[0], $+[0]]};
                    $regex  = 1;
                    $canpod = 0;
                    $flat   = 0;
                    redo;
                }
                when (m{\G->}gc) {
                    push @result, {dereference_operator => [$-[0], $+[0]]};
                    $regex  = 0;
                    $canpod = 0;
                    $flat   = 1;
                    redo;
                }
                when (m{\G$operators}gco || m{\Gx(?=[0-9\W])}gc) {
                    push @result, {operator => [$-[0], $+[0]]};
                    if ($format) {
                        if (substr($_, $-[0], ($+[0] - $-[0])) eq '=') {
                            $format        = 0;
                            $expect_format = 1;
                        }
                    }
                    $canpod = 0;
                    $regex  = 1;
                    $flat   = 0;
                    redo;
                }
                when (m{\G$hex_num}gco) {
                    push @result, {hex_number => [$-[0], $+[0]]};
                    $regex  = 0;
                    $canpod = 0;
                    redo;
                }
                when (m{\G$binary_num}gco) {
                    push @result, {binary_number => [$-[0], $+[0]]};
                    $regex  = 0;
                    $canpod = 0;
                    redo;
                }
                when (m{\G$number}gco) {
                    push @result, {number => [$-[0], $+[0]]};
                    $regex  = 0;
                    $canpod = 0;
                    redo;
                }
                when (m{\GSTD(?>OUT|ERR|IN)\b}gc) {
                    push @result, {special_fh => [$-[0], $+[0]]};
                    $regex  = 1;
                    $canpod = 0;
                    redo;
                }
                when (m{\G$var_name}gco) {
                    push @result, {($proto == 1 ? 'sub_name' : 'unquoted_string') => [$-[0], $+[0]]};
                    $regex  = 0;
                    $canpod = 0;
                    $flat   = 0;
                    redo;
                }
                when (m{\G\z}gc) {    # all done

                    if ($bracket != 0) {
                        warn "Unbalanced brackets <$bracket>: []";
                    }
                    if ($cbracket != 0) {
                        warn "Unbalanced curly brackets <$cbracket>: {}";
                    }
                    if ($parenthese != 0) {
                        warn "Unbalanced parentheses <$parenthese>: ()";
                    }
                    if ($variable != 0) {
                        warn "Variable count error: $variable";
                    }

                    warn "** Finished...\n";
                    break;
                }
                default {
                    warn "[!] Unknown sentence near ->>", substr($_, pos, index($_, "\n", pos) - pos), "\n";
                    /\G./sgc && redo;
                }
            }
        }

        return \@result;
    }
}

foreach my $script (@ARGV) {

    print STDERR "=> Analyzing: $script\n";

    my $code = do {
        open my $fh, '<:utf8', $script;
        local $/;
        <$fh>;
    };

    my $d_code = eval { deparse($code) };
    $@ && do { warn $@; next };

    my $tokens   = tokenize($code);
    my $d_tokens = tokenize($d_code);

    my @types   = identify($tokens);
    my @d_types = identify($d_tokens);

    if (@types == 0 or @d_types == 0) {
        warn "This script seems to be empty! Skipping...\n";
        next;
    }

    my $len = LCS_length(\@types, \@d_types) - abs(@types - @d_types);
    my $score = (100 - ($len / @types * 100));

    if ($score >= 60) {
        printf("WOW!!! We have here a score of %.2f! This is obfuscation, isn't it?\n", $score);
    }
    elsif ($score >= 40) {
        printf("Outstanding! This code seems to be written by a true legend! Score: %.2f\n", $score);
    }
    elsif ($score >= 20) {
        printf("Amazing! This code is very unique! Score: %.2f\n", $score);
    }
    elsif ($score >= 15) {
        printf("Excellent! This code is written by a true Perl hacker. Score: %.2f\n", $score);
    }
    elsif ($score >= 10) {
        printf("Awesome! This code is written by a Perl expert. Score: %.2f\n", $score);
    }
    elsif ($score >= 5) {
        printf("Just OK! We have a score of %.2f! This is production code, isn't it?\n", $score);
    }
    else {
        printf("What is this? I guess it is some baby Perl code, isn't it? Score: %.2f\n", $score);
    }
}
