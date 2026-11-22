# web/ — web edition and EPUB

Generates a web version (`build/web/`) and an EPUB (`build/asterion.epub`) of the book from
the same LaTeX sources as the PDFs, with pandoc.

    web/build.sh                     # every chapter (the default)
    WEB_CHAPTERS=all web/build.sh    # every chapter
    WEB_CHAPTERS="akce triky" web/build.sh

Needs `pandoc` (3.7) and `perl`; ImageMagick (`magick` or `convert`) is optional and only
resizes images. GitHub Actions runs it after the PDFs (`.github/workflows/latex.yml`).

**The `.tex` files are the source of truth**; nothing in `build/` is edited by hand.

## How it works

| file | role |
|---|---|
| `lib/labelmap.pl` | chapters in order (from `main.tex`) and every `\label` → page, anchor, title |
| `lib/preprocess.pl` | rewrites what pandoc's LaTeX reader would drop (see its header) |
| `lib/asterion.lua` | pandoc filter: terms, boxes, `\Cref` links, margin notes, tables, images; writes the full-text search index (`assets/search.json`, used by the search in `web.js`) |
| `lib/rejstrik.pl` | the appendix lists of all aspects and tricks, linking to every occurrence |
| `templates/page.html` | page template (header, contents drawer, theme switch, footer) |
| `assets/web.css`, `assets/web.js` | design of the web edition |
| `assets/epub.css` | plain styling for the EPUB (reader apps override most of it) |
| `fonts/` | EB Garamond and Source Sans, subset to Latin + Czech as WOFF2 (OFL) |

**pandoc drops what it does not recognise, silently, together with the argument.** So
`build.sh` counts the book's constructs (boxes of each kind, `\asp`/`\dov`/`\trk`/`\akc`/
`\per`, action icons, margin notes) in every chapter's source and in its web page, and
reports any mismatch; the filter reports any TeX left unconverted. A build without
messages means nothing was lost. A **new macro or environment** in the book needs a line in
`preprocess.pl` (a web definition) and, if it needs its own look, in `asterion.lua` and the
CSS — otherwise the counts or the "unconverted TeX" report will say so.

## Where it is published

The output uses only relative links: `web/` links to the downloads one level up
(`../main.pdf`, `../mobile.pdf`, `../asterion.epub`), so the site works in any folder.
The workflow assembles exactly the published files into `site/` (`index.html`, the PDFs,
the EPUB, `web/`) and deploys that folder to **https://kamilbelan.net/fate-asterion/**:
`rsync --delete` over SSH to `kb-vps` (89.167.19.41) into `/var/www/fate-asterion`, served
by Caddy (`handle_path /fate-asterion/*`). It uses a deploy key that can only write into
that folder (`rrsync` in `authorized_keys`), stored in the repository secrets
`DEPLOY_SSH_KEY` and `DEPLOY_KNOWN_HOSTS`; the step is skipped while the key is not set.
The folder is separate from the personal site's `public/`, so the site's own
`rsync --delete` deploy never touches it.

## Fonts

`fonts/*.woff2` are generated once and committed (like `~/Sites/site-theme/fonts`):

    pyftsubset <font>.otf --flavor=woff2 \
      --unicodes='U+0020-007E,U+00A0-017F,U+2010-2027,U+2030-203A,U+2190-2193,U+2212,U+2022,U+2026,U+20AC' \
      --layout-features='kern,liga,smcp,c2sc,onum,lnum,pnum,tnum'

from `EBGaramond-{Regular,Italic,Bold,BoldItalic}.otf` and
`SourceSansPro-{Regular,Semibold,Bold}.otf` (TeX Live). Both families are under the SIL Open
Font License 1.1.
