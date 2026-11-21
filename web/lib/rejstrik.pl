#!/usr/bin/env perl
# The appendix lists of all aspects and tricks for the web and EPUB (the PDF builds them in
# LuaLaTeX, see preamble/user/rejstrik.lua; pandoc does not run that, so they are rebuilt here
# from the sources with the same rules). Writes rejstrik-asp.tex and rejstrik-trk.tex: LaTeX
# that preprocess.pl puts in place of \vypisrejstrik{asp|trk}.
#
#   perl web/lib/rejstrik.pl <repo-root> <chapters.tsv> <built,slugs> <out-dir>
#
# Each term once, in Czech alphabetical order under letter headings, followed by links to the
# chapters it appears in (instead of the PDF's page numbers).
use strict;
use warnings;
use utf8;
use open qw(:std :encoding(UTF-8));

my ($root, $tsv, $built, $out) = @ARGV;
die "usage: rejstrik.pl <repo-root> <chapters.tsv> <built,slugs> <out-dir>\n" unless defined $out;
my %built = map { $_ => 1 } split /,/, $built;

my (%terms, @order);                       # kind -> lc term -> {term, chapters => [slug…]}
open my $t, '<', $tsv or die "$tsv: $!\n";
my @chapters = map { chomp; [split /\t/] } <$t>;
my %title = map { $_->[1] => $_->[2] } @chapters;

for my $ch (@chapters) {
    my ($file, $slug) = @$ch;
    open my $fh, '<', "$root/chapters/$file.tex" or die "$file: $!\n";
    my $tex = do { local $/; <$fh> };
    $tex =~ s/\A.*?\\begin\{document\}//s;
    $tex =~ s/(?<!\\)%[^\n]*//g;
    $tex =~ s/\\begin\{comment\}.*?\\end\{comment\}//gs;
    $tex =~ s/\\todo(?:\[[^\]]*\])?(\{(?:[^{}]++|(?1))*\})//g;     # hidden on the web
    while ($tex =~ /\\(asp|trk)(\{((?:[^{}]++|(?2))*)\})/g) {
        my ($kind, $text) = ($1, $3);
        for my $term (split_terms($text)) {
            my $e = $terms{$kind}{lc $term} //= { term => $term, chapters => [] };
            push @{ $e->{chapters} }, $slug unless grep { $_ eq $slug } @{ $e->{chapters} };
        }
    }
}

for my $kind (qw(asp trk)) {
    open my $o, '>', "$out/rejstrik-$kind.tex" or die "$out: $!\n";
    my @entries = sort { before($a->{term}, $b->{term}) } values %{ $terms{$kind} // {} };
    print $o "\\begin{rejstrik}\n";
    my $group = '';
    for my $e (@entries) {
        my @u = units($e->{term});
        my $g = @u ? ($u[0] eq 'ch' ? 'Ch' : uc $u[0]) : '#';
        if ($g ne $group) {
            print $o "\\end{itemize}\n" if $group ne '';
            print $o "\\paragraph{$g}\n\\begin{itemize}\n";
            $group = $g;
        }
        my @where = map { $built{$_} ? "\\href{$_.html}{$title{$_}}" : $title{$_} } @{ $e->{chapters} };
        print $o "\\item \\textcolor{$kind}{$e->{term}} -- ", join(', ', @where), "\n";
    }
    print $o "\\end{itemize}\n" if $group ne '';
    print $o "\\end{rejstrik}\n";
}

# "A, B, C" in one \asp are several terms; split at ", " + uppercase letter only
# ("Hora, kde sídlí bohové" stays one term)
sub split_terms {
    my ($text) = @_;
    my @parts;
    for my $piece (split /, /, $text) {
        if (@parts && $piece =~ /^(\p{Lu})/) { push @parts, $piece }
        elsif (@parts)                      { $parts[-1] .= ", $piece" }
        else                                { push @parts, $piece }
    }
    return grep { /\S/ } map { s/^\s+|\s+$//gr } @parts;
}

# Czech collation: č ř š ž and "ch" are letters of their own; accents only break ties
my @alphabet = qw(a b c č d e f g h ch i j k l m n o p q r ř s š t u v w x y z ž);
my %weight; @weight{@alphabet} = (1 .. @alphabet);
my %base = (á => 'a', ď => 'd', é => 'e', ě => 'e', í => 'i', ň => 'n', ó => 'o', ť => 't',
            ú => 'u', ů => 'u', ý => 'y');
sub units {
    my $s = lc shift;
    $s =~ s/\\[a-zA-Z]+//g;                                 # macros inside a term
    my @u;
    while ($s =~ /\G(ch|.)/gs) {
        my $c = $base{$1} // $1;
        push @u, $c if $weight{$c};
    }
    return @u;
}
sub before {
    my @a = units($_[0]); my @b = units($_[1]);
    for my $i (0 .. ($#a < $#b ? $#a : $#b)) {
        return $weight{$a[$i]} <=> $weight{$b[$i]} if $a[$i] ne $b[$i];
    }
    return (@a <=> @b) || ($_[0] cmp $_[1]);
}
