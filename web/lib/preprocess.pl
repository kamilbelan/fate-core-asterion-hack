#!/usr/bin/env perl
# Prepare one chapter .tex for pandoc (web and EPUB). pandoc's LaTeX reader drops what it
# does not recognise -- silently, and together with the argument -- so everything the book
# defines itself is rewritten here into something pandoc keeps, and asterion.lua turns it
# into proper HTML:
#
#   1. Boxes (`pravidlo`, `predmet`, `povolani`, `Real`, `specialita`, `prozatimni`):
#      pandoc keeps an unknown environment as a Div with its name as the class, but throws
#      away the optional argument -- the box's name. It is moved into the body as a marker
#      paragraph (@@BOX@@<name>) that the filter turns into the box title.
#   2. `\sidenotemark` ... `\sidenotetext{...}` (the text comes later, e.g. after an `akce`
#      list): each text is moved to its mark, then all margin notes become `\footnote`;
#      the filter renders footnotes as margin notes on the web, as footnotes in the EPUB.
#   3. `akce` holds `\iconitem`s without a list around them: wrapped in an itemize.
#   4. `tblr` (tabularray) is unknown to pandoc: rewritten to a `tabular` with the same
#      number of columns; booktabs rules are understood.
#   5. Layout-only commands are removed: `multicols`, `\columnbreak`, the `\predmetlist`
#      switch, `\pravidlovprehledu`.
#   6. The book's own macros get web definitions (prepended): term styles become
#      `\textcolor{<class>}{...}` (pandoc keeps that as a styled span; the filter turns the
#      colour into a CSS class), `\todo` disappears (player edition), `\zdrojobrazku` becomes
#      the figure caption.
use strict;
use warnings;

my $tex = do { local $/; <STDIN> };

# only the document body of a subfile
$tex =~ s/\A.*?\\begin\{document\}//s;
$tex =~ s/\\end\{document\}.*\z//s;
$tex =~ s/(?<!\\)%[^\n]*//g;                                   # comments

# --- 1: box names ------------------------------------------------------------------
my $BOXES = qr/pravidlo|predmet|povolani|Real|specialita|prozatimni/;
$tex =~ s/\\begin\{($BOXES)\}\[([^\]]*)\]/\\begin{$1}\n\n\@\@BOX\@\@$2\n\n/g;

# --- 2: margin notes -----------------------------------------------------------------
my @texts;
while ($tex =~ /\\sidenotetext\s*(?:\[[^\]]*\])*\s*(?=\{)/g) {
    my $start = $-[0];
    my $open  = pos($tex);
    my $close = match_brace($tex, $open) // die "preprocess: unbalanced \\sidenotetext\n";
    push @texts, [$start, $close, substr($tex, $open + 1, $close - $open - 1)];
    pos($tex) = $close + 1;
}
for my $t (reverse @texts) {                                     # remove, back to front
    substr($tex, $t->[0], $t->[1] - $t->[0] + 1) = '';
}
my @queue = map { $_->[2] } @texts;
$tex =~ s/\\sidenotemark(?:\[[^\]]*\])?/@queue ? "\\footnote{" . shift(@queue) . "}" : ''/ge;
warn "preprocess: " . scalar(@queue) . " \\sidenotetext without a mark\n" if @queue;
$tex =~ s/\\sidenote(?:\[[^\]]*\])*\s*(?=\{)/\\footnote/g;

# --- 3: akce lists ------------------------------------------------------------------
$tex =~ s/\\begin\{akce\}/\\begin{akce}\\begin{itemize}/g;
$tex =~ s/\\end\{akce\}/\\end{itemize}\\end{akce}/g;

# --- 4: tabularray -> tabular -------------------------------------------------------
$tex =~ s/\\begin\{tblr\}\{((?:[^{}]|\{(?:[^{}]|\{[^{}]*\})*\})*)\}/tabular_head($1)/ge;
$tex =~ s/\\end\{tblr\}/\\end{tabular}/g;

# `\begin{tabular}{ll…}` with as many columns as the tblr colspec has
sub tabular_head {
    my ($opt) = @_;
    my $n = 0;
    if ($opt =~ /colspec=\{((?:[^{}]|\{[^{}]*\})*)\}/) {
        (my $c = $1) =~ s/\[[^\]]*\]//g;
        $n = () = $c =~ /[QXlcr]/g;
    }
    return "\\begin{tabular}{" . ('l' x ($n || 2)) . "}";
}

# --- 5: layout only -------------------------------------------------------------------
$tex =~ s/\\(?:begin|end)\{multicols\}(?:\{\d+\})?//g;
$tex =~ s/\\columnbreak//g;
$tex =~ s/\\renewcommand\*?\{\\predmetlist\}\{[^}]*\}//g;
$tex =~ s/\\pravidlovprehledu\{[^}]*\}//g;
$tex =~ s/\\begin\{sloppypar\}|\\end\{sloppypar\}//g;
$tex =~ s/\\RaggedRight//g;

# biblatex citations: pandoc keeps \autocite inside a note as raw TeX, but knows \cite
$tex =~ s/\\autocite/\\cite/g;

# --- 6: web definitions of the book's macros ------------------------------------------
my $defs = <<'TEX';
\newcommand{\asp}[1]{\textcolor{asp}{#1}}
\newcommand{\dov}[1]{\textcolor{dov}{#1}}
\newcommand{\trk}[1]{\textcolor{trk}{#1}}
\newcommand{\akc}[1]{\textcolor{akc}{#1}}
\newcommand{\per}[1]{\textcolor{per}{#1}}
\newcommand{\policko}[2]{\textcolor{policko-#2}{#1}}
\newcommand{\iconitem}[2]{\item \includegraphics{#1} #2}
\newcommand{\todo}[2][]{}
\newcommand{\zdrojobrazku}[1]{\caption{\href{#1}{zdroj}}}
% @@END-OF-WEB-DEFINITIONS@@
TEX

print $defs, $tex;

# index of the '}' matching the '{' at $i, or undef
sub match_brace {
    my ($s, $i) = @_;
    my $depth = 0;
    for my $j ($i .. length($s) - 1) {
        my $c = substr($s, $j, 1);
        next if $j > 0 && substr($s, $j - 1, 1) eq "\\";
        $depth++ if $c eq '{';
        if ($c eq '}') { $depth--; return $j if $depth == 0 }
    }
    return undef;
}
