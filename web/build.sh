#!/usr/bin/env bash
# Web edition and EPUB of the book, generated from the LaTeX sources with pandoc.
#
#   web/build.sh                     # -> build/web/ and build/asterion.epub
#   WEB_CHAPTERS=all web/build.sh    # every chapter (the default)
#   web/build.sh <out-dir> <epub>    # other output locations
#
# The output folder is self-contained and uses only relative links, so it can be served
# from any path: GitHub Pages (next to main.pdf, mobile.pdf and the EPUB, one level up)
# or copied into another website.
#
# The .tex files are the source of truth; nothing under build/ is edited by hand.
# How the conversion works: web/lib/preprocess.pl (what pandoc's LaTeX reader would drop),
# web/lib/labelmap.pl (\Cref targets), web/lib/asterion.lua (the pandoc filter).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB="$ROOT/web"
LIB="$WEB/lib"
OUT="${1:-$ROOT/build/web}"
EPUBFILE="${2:-$ROOT/build/asterion.epub}"
CHAPTERS="${WEB_CHAPTERS:-all}"   # slugs (see `labelmap.pl --chapters`) or "all"

die() { printf 'web/build.sh: %s\n' "$*" >&2; exit 1; }
for tool in pandoc perl; do command -v "$tool" >/dev/null || die "$tool not found"; done
IMG=""; command -v magick >/dev/null && IMG=magick || { command -v convert >/dev/null && IMG=convert; } || true

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT/assets/fonts" "$OUT/img"

# --- version: build date and commit, as on the PDF title page -------------------------
months=(ledna února března dubna května června července srpna září října listopadu prosince)
VERSION="verze $(date +%-d). ${months[$(( $(date +%-m) - 1 ))]} $(date +%Y)"
commit="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || true)"
[ -z "$commit" ] && [ -n "${GITHUB_SHA:-}" ] && commit="${GITHUB_SHA:0:7}"
[ -n "$commit" ] && VERSION="$VERSION ($commit)"

# --- chapters and labels -----------------------------------------------------------------
perl "$LIB/labelmap.pl" "$ROOT" > "$TMP/labelmap.lua"
perl "$LIB/labelmap.pl" "$ROOT" --chapters > "$TMP/chapters.tsv"
built=()
while IFS=$'\t' read -r file slug title; do
    if [ "$CHAPTERS" = all ] || [[ " $CHAPTERS " == *" $slug "* ]]; then built+=("$slug"); fi
done < "$TMP/chapters.tsv"
[ ${#built[@]} -gt 0 ] || die "no chapters selected (WEB_CHAPTERS=$CHAPTERS)"
BUILT="$(IFS=,; echo "${built[*]}")"
is_built() { [[ ",$BUILT," == *",$1,"* ]]; }

# --- preprocessing of every chapter (also the ones without a web page: the lists of terms
# cover the whole text). It anchors each \asp/\trk and lists the occurrences in <slug>.terms;
# the appendix lists of aspects and tricks are made from those (the PDF builds them in
# LuaLaTeX), then put into the chapter that holds them.
while IFS=$'\t' read -r file slug title; do
    SLUG="$slug" TERMS_FILE="$TMP/$slug.terms" \
        perl "$LIB/preprocess.pl" < "$ROOT/chapters/$file.tex" > "$TMP/$slug.tex"
done < "$TMP/chapters.tsv"
perl "$LIB/rejstrik.pl" "$TMP/chapters.tsv" "$BUILT" "$TMP"
while IFS=$'\t' read -r file slug title; do
    grep -q '\\vypisrejstrik' "$ROOT/chapters/$file.tex" || continue
    SLUG="$slug" REJSTRIK_DIR="$TMP" \
        perl "$LIB/preprocess.pl" < "$ROOT/chapters/$file.tex" > "$TMP/$slug.tex"
done < "$TMP/chapters.tsv"

# --- images: every \includegraphics of the built chapters, sized for the web -------------
echo "return {" > "$TMP/images.lua"
while IFS=$'\t' read -r file slug title; do
    is_built "$slug" || continue
    # pictures in the text (not in comments or `comment` blocks); a chapter may have none
    perl -0ne 's/\\begin\{comment\}.*?\\end\{comment\}//gs; s/(?<!\\)%[^\n]*//g;
              print "$1\n" while /\\(?:includegraphics(?:\[[^]]*\])?|iconitem)\{([^}]+)\}/g' \
        "$ROOT/chapters/$file.tex"
done < "$TMP/chapters.tsv" | sort -u | while read -r name; do
    src="$(ls "$ROOT/figures/$name".* 2>/dev/null | head -1 || true)"
    [ -n "$src" ] || { printf 'web/build.sh: warning: figure not found: %s\n' "$name" >&2; continue; }
    ext="${src##*.}"
    if [[ "$name" == *-ikona ]]; then                       # action icons: small, keep transparency
        out="img/$name.png"
        if [ -n "$IMG" ]; then $IMG "$src" -resize 128x128 -strip "$OUT/$out"; else cp "$src" "$OUT/$out"; fi
    else                                                     # illustrations: JPEG, at most 1400 px
        out="img/$name.jpg"
        if [ -n "$IMG" ]; then
            $IMG "$src" -background white -alpha remove -alpha off -resize '1400x1400>' \
                -strip -quality 82 -interlace JPEG "$OUT/$out"
        else out="img/$name.$ext"; cp "$src" "$OUT/$out"; fi
    fi
    printf '  ["%s"] = "%s",\n' "$name" "$out" >> "$TMP/images.lua"
done
echo "}" >> "$TMP/images.lua"

# --- navigation: every chapter of the book, the converted ones as links -------------------
nav_html() {                                                  # $1 = current slug
    while IFS=$'\t' read -r file slug title; do
        title="$(sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' <<< "$title")"   # inserted as raw HTML
        if is_built "$slug"; then
            cur=""; [ "$slug" = "$1" ] && cur=' aria-current="page"'
            printf '<li><a href="%s.html"%s>%s</a></li>' "$slug" "$cur" "$title"
        else
            printf '<li class="jen-pdf"><span>%s</span> <small>jen v PDF</small></li>' "$title"
        fi
    done < "$TMP/chapters.tsv"
}

common=(--lua-filter="$LIB/asterion.lua"
        -M labelmap="$TMP/labelmap.lua" -M images="$TMP/images.lua" -M built="$BUILT"
        -M lang=cs --citeproc --bibliography="$ROOT/preamble/bibliography.bib")
page_vars=(--template="$WEB/templates/page.html" -V lang=cs
           -V booktitle="Fate Core: Asterion Hack" -V version="$VERSION")

# --- chapter pages ------------------------------------------------------------------------
mapfile -t order < <(cut -f2 "$TMP/chapters.tsv")
prev=""; status=0
: > "$TMP/search.jsonl"                                     # full-text search index (asterion.lua)
for i in "${!order[@]}"; do
    slug="${order[$i]}"; is_built "$slug" || continue
    IFS=$'\t' read -r file _ title < <(awk -F'\t' -v s="$slug" '$2==s' "$TMP/chapters.tsv")

    next=""
    for j in "${order[@]:$((i + 1))}"; do
        if is_built "$j"; then
            next="<a href=\"$j.html\" rel=\"next\">$(awk -F'\t' -v s="$j" '$2==s{print $3}' "$TMP/chapters.tsv")</a>"; break
        fi
    done

    pandoc -f latex -t html5 -s "${common[@]}" "${page_vars[@]}" -M page="$slug" -V slug="$slug" \
        -M searchindex="$TMP/search.jsonl" --toc --toc-depth=3 -M pagetitle="$title" \
        -V nav="$(nav_html "$slug")" -V prev="$prev" -V next="$next" \
        "$TMP/$slug.tex" -o "$OUT/$slug.html" 2> "$TMP/$slug.err" || die "pandoc failed on $file"
    if [ -s "$TMP/$slug.err" ]; then cat "$TMP/$slug.err" >&2; status=1; fi
    prev="<a href=\"$slug.html\" rel=\"prev\">$title</a>"

    # nothing may get lost on the way: count the book's constructs in source and output
    # (without comments and without \todo{…}: to-dos are left out of the web on purpose)
    body="$(sed -n '/\\begin{document}/,/\\end{document}/p' "$ROOT/chapters/$file.tex" | sed 's/\([^\\]\)%.*/\1/; s/^%.*//' \
        | perl -0pe 's/\\todo(?:\[[^\]]*\])?(\{(?:[^{}]++|(?1))*\})//g')"
    html="$(cat "$OUT/$slug.html")"
    check() {                                                 # name, source count, output count
        if [ "$2" != "$3" ]; then printf '  %-16s %-12s source %3s, web %3s  <-- MISMATCH\n' "$slug" "$1" "$2" "$3"; status=1; fi
    }
    for kind in pravidlo predmet povolani Real specialita prozatimni; do
        check "$kind" "$(grep -o "\\\\begin{$kind}" <<< "$body" | wc -l)" \
                      "$(grep -o "class=\"box box-$(tr '[:upper:]' '[:lower:]' <<< "$kind")\"" <<< "$html" | wc -l)"
    done
    if ! grep -q '\\vypisrejstrik' <<< "$body"; then      # the lists of terms are generated
        for term in asp dov trk akc per; do
            check "\\$term" "$(grep -o "\\\\$term{" <<< "$body" | wc -l)" "$(grep -o "class=\"$term\"" <<< "$html" | wc -l)"
        done
    else
        check "list items" "$(grep -c '^\\item' "$TMP/rejstrik-asp.tex" "$TMP/rejstrik-trk.tex" | awk -F: '{s+=$2} END{print s}')" \
                           "$(grep -o 'class="asp"\|class="trk"' <<< "$html" | wc -l)"
    fi
    check "table" "$(grep -oE '\\begin\{(tblr|tabular)\}' <<< "$body" | wc -l)" "$(grep -o '<table' <<< "$html" | wc -l)"
    check "picture" "$(grep -oE '\\includegraphics' <<< "$(perl -0pe 's/\\begin\{comment\}.*?\\end\{comment\}//gs' <<< "$body")" | wc -l)" \
                    "$(perl -0ne '$n++ while /<img(?![^>]*class="ikona")[^>]*>/g; print $n+0' <<< "$html")"
    check "iconitem" "$(grep -o '\\iconitem{' <<< "$body" | wc -l)" "$(grep -o 'class="ikona"' <<< "$html" | wc -l)"
    check "sidenote" "$(grep -oE '\\sidenote(mark)?\b' <<< "$body" | wc -l)" "$(grep -o 'class="sidenote"' <<< "$html" | wc -l)"
    printf '  %-28s -> %s\n' "chapters/$file.tex" "${OUT#"$ROOT"/}/$slug.html"
done

# --- search index: one JSON array of all the entries ----------------------------------------
{ printf "["; paste -sd, "$TMP/search.jsonl"; printf "]\n"; } > "$OUT/assets/search.json"
printf '  %-28s -> %s (%s entries)\n' "(search index)" "${OUT#"$ROOT"/}/assets/search.json" "$(wc -l < "$TMP/search.jsonl")"

# --- contents page -------------------------------------------------------------------------
{
    printf '# Fate Core: Asterion Hack\n\n'
    printf -- '[↩︎ O textu a ke stažení](../)\n\n'
    printf 'Pravidla Fate Core upravená pro svět Asterionu. '
    printf 'Všechny kapitoly jsou níže, ke stažení jsou i verze v PDF a EPUB.\n\n'
    printf '## Obsah\n\n'
    while IFS=$'\t' read -r file slug title; do
        if is_built "$slug"; then printf -- '- [%s](%s.html)\n' "$title" "$slug"
        else printf -- '- %s *(jen v PDF)*\n' "$title"; fi
    done < "$TMP/chapters.tsv"
    printf '\n## Ke stažení\n\n'
	printf -- '- [pdf (A4)](../main.pdf)\n- [pdf (pro mobil))](../mobile.pdf)\n- [epub](../asterion.epub)\n'
} > "$TMP/index.md"
pandoc -f markdown -t html5 -s "${page_vars[@]}" -M pagetitle="Obsah" \
    -V nav="$(nav_html "")" -V next="<a href=\"${built[0]}.html\" rel=\"next\">$(awk -F'\t' -v s="${built[0]}" '$2==s{print $3}' "$TMP/chapters.tsv")</a>" \
    "$TMP/index.md" -o "$OUT/index.html"

# --- assets ----------------------------------------------------------------------------------
cp "$WEB/assets/web.css" "$WEB/assets/web.js" "$OUT/assets/"
cp "$WEB/fonts/"*.woff2 "$OUT/assets/fonts/"
printf '  %-28s -> %s\n' "(contents, assets)" "${OUT#"$ROOT"/}/"

# --- EPUB: the same chapters as one book ----------------------------------------------------
# one document: the web definitions of the macros once, then the chapters' bodies
for slug in "${built[@]}"; do
    if [ "$slug" = "${built[0]}" ]; then cat "$TMP/$slug.tex"
    else sed '1,/@@END-OF-WEB-DEFINITIONS@@/d' "$TMP/$slug.tex"; fi
    printf '\n'
done > "$TMP/epub.tex"
epub_in=("$TMP/epub.tex")
pandoc -f latex -t epub3 "${common[@]}" -M page="" \
    -M title="Fate Core: Asterion Hack" -M author="Racochejl a kol." -M date="$VERSION" \
    --toc --toc-depth=2 --split-level=1 --css="$WEB/assets/epub.css" \
    --epub-cover-image="$ROOT/figures/logo.png" --resource-path="$OUT" \
    "${epub_in[@]}" -o "$EPUBFILE" 2> "$TMP/epub.err" || die "pandoc failed on the EPUB"
if [ -s "$TMP/epub.err" ]; then cat "$TMP/epub.err" >&2; status=1; fi
printf '  %-28s -> %s\n' "(EPUB)" "${EPUBFILE#"$ROOT"/}"

# --- landing page: the site root, next to the PDFs and the EPUB ------------------------------
# Chapter list and file details (size, pages) are filled in from what was actually built; a
# file that does not exist is left out rather than offered as a dead link.
SITE="$(dirname "$OUT")"
REPO="https://github.com/kamilbelan/fate-core-asterion-hack"
total=$(wc -l < "$TMP/chapters.tsv")
partial=""; [ ${#built[@]} -lt "$total" ] && partial="zatím ${#built[@]} z $total kapitol"

mb()    { awk -v b="$(stat -c %s "$1")" 'BEGIN { s = sprintf("%.1f", b / 1048576); sub(/\./, ",", s); print s " MB" }'; }
pages() { command -v pdfinfo >/dev/null && pdfinfo "$1" 2>/dev/null | awk '/^Pages:/ { print " · " $2 " stran" }' || true; }
card() {   # href, title, meta, [extra class], [download name] -- the personal site's .soubor
    local dl="" cls="soubor"
    [ -n "${4:-}" ] && cls="soubor $4"
    [ -n "${5:-}" ] && dl=" download=\"$5\""
    printf '    <a class="%s" href="%s"%s>\n      <strong>%s</strong>\n      <span class="soubor-meta">%s</span>\n    </a>\n' \
        "$cls" "$1" "$dl" "$2" "$3"
}
files="$(
    card web/index.html "Číst online" "web${partial:+ · $partial}" soubor-hlavni
    [ -f "$SITE/main.pdf" ]   && card main.pdf "PDF pro počítač" "A4 · $(mb "$SITE/main.pdf")$(pages "$SITE/main.pdf")"
    [ -f "$SITE/mobile.pdf" ] && card mobile.pdf "PDF pro mobil" "$(mb "$SITE/mobile.pdf")$(pages "$SITE/mobile.pdf")"
    [ -f "$EPUBFILE" ]        && card "$(basename "$EPUBFILE")" "EPUB" "$(mb "$EPUBFILE")${partial:+ · $partial}" "" "fate-asterion-hack.epub"
    card "$REPO" "Zdrojový kód" "GitHub · LaTeX"
)"
chapters_html=""; appendices_html=""
while IFS=$'\t' read -r file slug title; do
    title="$(sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' <<< "$title")"
    if is_built "$slug"; then item="<li><a href=\"web/$slug.html\">$title</a></li>"
    else item="<li class=\"jen-pdf\">$title <small>(pdf)</small></li>"; fi
    if [[ "$slug" == dodatky-* ]]; then appendices_html+="    $item"$'\n'; else chapters_html+="    $item"$'\n'; fi
done < "$TMP/chapters.tsv"

# The landing page is a page of kamilbelan.net and uses its stylesheet. Its file name carries
# a content hash, so the current one is read from the live site and copied next to the page
# (a later redeploy of the personal site cannot break it); without network, the page still
# gets the shared /theme/theme.css and the adapter styles.
SITE_URL="https://kamilbelan.net"
sitecss=""
css_path="$(curl -fsS --max-time 20 "$SITE_URL/" 2>/dev/null | grep -o '/css/main\.min\.[0-9a-f]*\.css' | head -1 || true)"
if [ -n "$css_path" ] && curl -fsS --max-time 20 "$SITE_URL$css_path" -o "$OUT/assets/site.css" 2>/dev/null; then
    sitecss="web/assets/site.css"
else
    printf 'web/build.sh: warning: could not fetch the stylesheet of %s; landing page without it\n' "$SITE_URL" >&2
fi
pandoc -f markdown -t html5 --template="$WEB/templates/landing.html" -M pagetitle=landing \
    -V version="$VERSION" -V repo="$REPO" -V files="$files" -V sitecss="$sitecss" \
    -V chapters="$chapters_html" -V appendices="$appendices_html" \
    -V webnote="${partial:+převedeno ${#built[@]} z $total}" \
    /dev/null -o "$SITE/index.html"
printf '  %-28s -> %s\n' "(landing page)" "${SITE#"$ROOT"/}/index.html"

[ "$status" -eq 0 ] || die "finished with warnings (see above): something may be missing in the output"
