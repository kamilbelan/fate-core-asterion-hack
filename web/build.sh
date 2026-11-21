#!/usr/bin/env bash
# Web edition and EPUB of the book, generated from the LaTeX sources with pandoc.
#
#   web/build.sh                     # -> build/web/ and build/asterion.epub
#   WEB_CHAPTERS=all web/build.sh    # every chapter (default: the prototype chapters)
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
CHAPTERS="${WEB_CHAPTERS:-akce predmety}"   # slugs (see `labelmap.pl --chapters`) or "all"

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
for i in "${!order[@]}"; do
    slug="${order[$i]}"; is_built "$slug" || continue
    IFS=$'\t' read -r file _ title < <(awk -F'\t' -v s="$slug" '$2==s' "$TMP/chapters.tsv")
    perl "$LIB/preprocess.pl" < "$ROOT/chapters/$file.tex" > "$TMP/$slug.tex"

    next=""
    for j in "${order[@]:$((i + 1))}"; do
        if is_built "$j"; then
            next="<a href=\"$j.html\" rel=\"next\">$(awk -F'\t' -v s="$j" '$2==s{print $3}' "$TMP/chapters.tsv")</a>"; break
        fi
    done

    pandoc -f latex -t html5 -s "${common[@]}" "${page_vars[@]}" -M page="$slug" \
        --toc --toc-depth=3 -M pagetitle="$title" \
        -V nav="$(nav_html "$slug")" -V prev="$prev" -V next="$next" \
        "$TMP/$slug.tex" -o "$OUT/$slug.html" 2> "$TMP/$slug.err" || die "pandoc failed on $file"
    if [ -s "$TMP/$slug.err" ]; then cat "$TMP/$slug.err" >&2; status=1; fi
    prev="<a href=\"$slug.html\" rel=\"prev\">$title</a>"

    # nothing may get lost on the way: count the book's constructs in source and output
    body="$(sed -n '/\\begin{document}/,/\\end{document}/p' "$ROOT/chapters/$file.tex" | sed 's/\([^\\]\)%.*/\1/; s/^%.*//')"
    html="$(cat "$OUT/$slug.html")"
    check() {                                                 # name, source count, output count
        if [ "$2" != "$3" ]; then printf '  %-16s %-12s source %3s, web %3s  <-- MISMATCH\n' "$slug" "$1" "$2" "$3"; status=1; fi
    }
    for kind in pravidlo predmet povolani Real specialita prozatimni; do
        check "$kind" "$(grep -o "\\\\begin{$kind}" <<< "$body" | wc -l)" \
                      "$(grep -o "class=\"box box-$(tr '[:upper:]' '[:lower:]' <<< "$kind")\"" <<< "$html" | wc -l)"
    done
    for term in asp dov trk akc per; do
        check "\\$term" "$(grep -o "\\\\$term{" <<< "$body" | wc -l)" "$(grep -o "class=\"$term\"" <<< "$html" | wc -l)"
    done
    check "iconitem" "$(grep -o '\\iconitem{' <<< "$body" | wc -l)" "$(grep -o 'class="ikona"' <<< "$html" | wc -l)"
    check "sidenote" "$(grep -oE '\\sidenote(mark)?\b' <<< "$body" | wc -l)" "$(grep -o 'class="sidenote"' <<< "$html" | wc -l)"
    printf '  %-28s -> %s\n' "chapters/$file.tex" "${OUT#"$ROOT"/}/$slug.html"
done

# --- contents page -------------------------------------------------------------------------
{
    printf '# Fate Core: Asterion Hack\n\n'
    printf 'Pravidla Fate Core upravená pro svět Asterionu. Webová verze je zatím **prototyp**: '
    printf 'převedené kapitoly jsou odkazy, ostatní najdete v PDF.\n\n'
    printf '## Obsah\n\n'
    while IFS=$'\t' read -r file slug title; do
        if is_built "$slug"; then printf -- '- [%s](%s.html)\n' "$title" "$slug"
        else printf -- '- %s *(jen v PDF)*\n' "$title"; fi
    done < "$TMP/chapters.tsv"
    printf '\n## Ke stažení\n\n'
    printf -- '- [PDF (A4)](../main.pdf)\n- [PDF pro mobil](../mobile.pdf)\n- [EPUB](../asterion.epub)\n'
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
    -M title="Fate Core: Asterion Hack" -M author="Mosche Haus a kol." -M date="$VERSION" \
    --toc --toc-depth=2 --split-level=1 --css="$WEB/assets/epub.css" \
    --epub-cover-image="$ROOT/figures/logo.png" --resource-path="$OUT" \
    "${epub_in[@]}" -o "$EPUBFILE" 2> "$TMP/epub.err" || die "pandoc failed on the EPUB"
if [ -s "$TMP/epub.err" ]; then cat "$TMP/epub.err" >&2; status=1; fi
printf '  %-28s -> %s\n' "(EPUB)" "${EPUBFILE#"$ROOT"/}"

[ "$status" -eq 0 ] || die "finished with warnings (see above): something may be missing in the output"
