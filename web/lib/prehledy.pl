#!/usr/bin/env perl
# The Přehledy for the web and EPUB: the lists of rules, provisional rules, weapons and armour,
# and items that the PDF prints after the contents (`\contentsandlists` in
# preamble/layout/toc.tex, collected from the boxes by tcolorbox). Writes LaTeX for the page.
#
#   perl web/lib/prehledy.pl <toc.tex> <chapters.tsv> <prehledy.tsv> > prehledy.tex
#
# The lists, their titles and their order come from the `\tcblistof` lines of toc.tex. The
# entries come from prehledy.tsv, written by asterion.lua while converting the chapters: one
# line per listed box or `\pravidlovprehledu` (list, page, anchor, name as LaTeX), in document
# order. Each entry links to its place; the chapter it is in stands where the PDF has the page.
use strict;
use warnings;
use utf8;
use open qw(:std :encoding(UTF-8));

my ($toc, $tsv, $entries) = @ARGV;
die "usage: prehledy.pl <toc.tex> <chapters.tsv> <prehledy.tsv>\n" unless defined $entries;

my $src = slurp($toc);
$src =~ s/(?<!\\)%[^\n]*//g;                                 # comments
my ($title) = $src =~ /\\chapter\*\{([^}]*)\}/ or die "prehledy: no \\chapter* in $toc\n";
my @lists;                                                    # [name, title], in order
push @lists, [$1, $2] while $src =~ /\\tcblistof(?:\[[^\]]*\])?\{([^}]*)\}\{([^}]*)\}/g;
die "prehledy: no \\tcblistof in $toc\n" unless @lists;

my %chapter = map { my @f = split /\t/; $f[1] => $f[2] } split /\n/, slurp($tsv);

my %items;                                                    # list -> [[page, anchor, tex], …]
for (split /\n/, slurp($entries)) {
    my ($list, $page, $anchor, $tex) = split /\t/, $_, 4;
    warn "prehledy: entry in an unknown list '$list': $tex\n" unless grep { $_->[0] eq $list } @lists;
    push @{ $items{$list} }, [$page, $anchor, $tex];
}

print "\\chapter*{$title}\n\n";
for my $l (@lists) {
    my ($name, $heading) = @$l;
    next unless $items{$name};
    print "\\section*{$heading}\n\\begin{prehled}\n\\begin{itemize}\n";
    for my $e (@{ $items{$name} }) {
        my ($page, $anchor, $tex) = @$e;
        print "\\item \\href{$page.html#$anchor}{$tex} \\textcolor{gray}{$chapter{$page}}\n";
    }
    print "\\end{itemize}\n\\end{prehled}\n\n";
}

sub slurp {
    my ($f) = @_;
    open my $fh, '<', $f or die "prehledy: $f: $!\n";
    local $/; <$fh>;
}
