# Engine
$pdf_mode = 4;  # 4 = lualatex
$lualatex = 'lualatex -synctex=1 -interaction=nonstopmode -shell-escape %O %S';

# Output and bibliography
$out_dir    = 'build';
$bibtex_use = 2;        # use biber, rerun as needed
$biber      = 'biber --input-directory=build %O %B';

# Run limits
$max_repeat = 5;
$continuous = 0;

# Both editions: print/desktop (main.tex) and phone (mobile.tex, inputs main.tex)
@default_files = ('main.tex', 'mobile.tex');
