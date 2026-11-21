#!/usr/bin/env perl
# The appendix lists of all aspects and tricks for the web and EPUB (the PDF builds them in
# LuaLaTeX, see preamble/user/rejstrik.lua; pandoc does not run that, so they are rebuilt here
# with the same rules). Writes rejstrik-asp.tex and rejstrik-trk.tex: LaTeX that
# preprocess.pl puts in place of \vypisrejstrik{asp|trk}.
#
#   perl web/lib/rejstrik.pl <chapters.tsv> <built,slugs> <dir>
#
# The source is <dir>/<slug>.terms, written by preprocess.pl for every chapter: one line per
# \asp/\trk occurrence (kind, anchor id, text). Each term is listed once, in Czech alphabetical
# order under letter headings, with links to every occurrence: the chapter name links to it if
# the term occurs there once, otherwise the chapter name is followed by numbered links.
use strict;
use warnings;
use utf8;
use open qw(:std :encoding(UTF-8));

my ($tsv, $built, $dir) = @ARGV;
die "usage: rejstrik.pl <chapters.tsv> <built,slugs> <dir>\n" unless defined $dir;
my %built = map { $_ => 1 } split /,/, $built;

open my $t, '<', $tsv or die "$tsv: $!\n";
my @chapters = map { chomp; [split /\t/] } <$t>;
my %title = map { $_->[1] => $_->[2] } @chapters;

my %terms;                     # kind -> lc term -> {term, at => [[slug, id], …]} (document order)
for my $ch (@chapters) {
    my $slug = $ch->[1];
    open my $fh, '<', "$dir/$slug.terms" or next;
    while (my $line = <$fh>) {
        chomp $line;
        my ($kind, $id, $text) = split /\t/, $line, 3;
        for my $term (split_terms($text)) {
            my $e = $terms{$kind}{lc $term} //= { term => $term, at => [] };
            push @{ $e->{at} }, [$slug, $id];
        }
    }
}

for my $kind (qw(asp trk)) {
    open my $o, '>', "$dir/rejstrik-$kind.tex" or die "$dir: $!\n";
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
        # occurrences grouped by chapter, chapters in document order
        my (@slugs, %ids);
        for my $at (@{ $e->{at} }) {
            push @slugs, $at->[0] unless $ids{ $at->[0] };
            push @{ $ids{ $at->[0] } }, $at->[1];
        }
        my @where;
        for my $s (@slugs) {
            my @ids = @{ $ids{$s} };
            if (!$built{$s})  { push @where, $title{$s} }
            elsif (@ids == 1) { push @where, "\\href{$s.html#$ids[0]}{$title{$s}}" }
            else {
                my $n = 0;
                push @where, "$title{$s} " . join(' ', map { "\\href{$s.html#$_}{" . ++$n . "}" } @ids);
            }
        }
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
# (in a BEGIN block: the lists above are written before execution would reach this point)
our (@alphabet, %weight, %base);
BEGIN {
    @alphabet = qw(a b c č d e f g h ch i j k l m n o p q r ř s š t u v w x y z ž);
    @weight{@alphabet} = (1 .. @alphabet);
    %base = (á => 'a', ď => 'd', é => 'e', ě => 'e', í => 'i', ň => 'n', ó => 'o', ť => 't',
             ú => 'u', ů => 'u', ý => 'y');
}
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
