---@diagnostic disable: undefined-global  -- pandoc filter globals (pandoc, FORMAT)
-- pandoc filter: the book's LaTeX (after web/lib/preprocess.pl) -> web pages and EPUB.
--
-- Metadata (set by web/build.sh):
--   labelmap  path to the Lua table from labelmap.pl (label -> page, anchor, title)
--   images    path to a Lua table: \includegraphics name -> file in the output (img/…)
--   page      slug of the page being converted ("" for the EPUB, which is one document)
--   built     comma-separated slugs of the chapters that have a web page / are in the EPUB
--
-- Anything that is still TeX after conversion is reported on stderr: pandoc drops what it
-- does not understand, and a silent build must mean nothing was lost.

local MAP, IMAGES, PAGE, BUILT = {}, {}, "", {}
local EPUB = FORMAT:match("epub") ~= nil
local boxcount, notecount = 0, 0

local BOXES = {
  pravidlo   = "Pravidlo",
  predmet    = "Předmět",
  povolani   = "Povolání",
  Real       = "Realistické hraní",
  specialita = "Specialita",
  prozatimni = "Prozatímní pravidlo",
  ["poznámka"] = "Poznámka",
  ["příklad"]  = "Příklad",
}
local TERMS = { asp = true, dov = true, trk = true, akc = true, per = true }

local function slug(s)
  local map = { ["á"]="a", ["č"]="c", ["ď"]="d", ["é"]="e", ["ě"]="e", ["í"]="i", ["ň"]="n",
                ["ó"]="o", ["ř"]="r", ["š"]="s", ["ť"]="t", ["ú"]="u", ["ů"]="u", ["ý"]="y", ["ž"]="z" }
  s = pandoc.text.lower(s)
  s = s:gsub("[\195\196\197][\128-\191]", function(c) return map[c] or "" end)
  return (s:gsub("[^%w]+", "-"):gsub("^-+", ""):gsub("-+$", ""))
end

local function report(what, text)
  io.stderr:write("asterion.lua [" .. (PAGE ~= "" and PAGE or "epub") .. "]: " .. what .. ": " .. text .. "\n")
end

function Meta(m)
  MAP    = dofile(pandoc.utils.stringify(m.labelmap))
  IMAGES = dofile(pandoc.utils.stringify(m.images))
  PAGE   = pandoc.utils.stringify(m.page or "")
  for s in pandoc.utils.stringify(m.built or ""):gmatch("[^,]+") do BUILT[s] = true end
  m.labelmap, m.images, m.page, m.built = nil, nil, nil, nil
  return m
end

-- \asp{…} etc. arrive as \textcolor{asp}{…}: a span with a colour style -> CSS class
function Span(el)
  local color = (el.attributes.style or ""):match("color:%s*([^;]+)")
  if not color then return nil end
  if TERMS[color] then
    return pandoc.Span(el.content, pandoc.Attr("", { color }))
  end
  local n = color:match("^policko%-(%d+)$")
  if n then                                               -- \policko{+1}{12}: 12 boxes
    local box = pandoc.utils.stringify(el.content)
    local out = {}
    for _ = 1, tonumber(n) do
      out[#out + 1] = pandoc.Span({ pandoc.Str(box) }, pandoc.Attr("", { "policko" }))
      out[#out + 1] = pandoc.Space()
    end
    return pandoc.Span(out, pandoc.Attr("", { "policka" }))
  end
  return pandoc.Span(el.content, pandoc.Attr("", { "poznamka" }))   -- \textcolor{gray}…
end

-- \Cref{…} -> a link with the target's title; a target without a web page yet stays text
function Link(el)
  local ref = el.attributes["reference"]
  if not ref then return nil end
  local t = MAP[ref]
  if not t then
    report("unresolved reference", ref)
    return pandoc.Emph({ pandoc.Str(ref) })
  end
  local text = { pandoc.Str(t.title) }
  if not BUILT[t.page] then return pandoc.Emph(text) end
  local url
  if EPUB then
    url = "#" .. (t.anchor ~= "" and t.anchor or ("kapitola-" .. t.page))
  elseif t.page == PAGE then
    url = t.anchor ~= "" and ("#" .. t.anchor) or "#"
  else
    url = t.page .. ".html" .. (t.anchor ~= "" and ("#" .. t.anchor) or "")
  end
  return pandoc.Link(text, url)
end

function Image(el)
  local name = el.src:gsub("^.*/", ""):gsub("%.%a+$", "")
  local file = IMAGES[name]
  if not file then
    report("missing image", el.src)
    return nil
  end
  el.src = file
  if name:match("%-ikona$") then
    el.classes:insert("ikona")
    el.caption = {}                          -- decorative: the action's name follows
    el.attributes.alt = ""
  else
    el.attributes.loading = "lazy"
  end
  if el.caption == nil or #el.caption == 0 then el.attributes.alt = "" end
  return el
end

-- margin notes: on the web a numbered note that sits in the margin on wide screens and opens
-- inline on a tap on phones (no JavaScript); in the EPUB ordinary footnotes
function Note(el)
  if EPUB then return nil end
  notecount = notecount + 1
  local id = "sn-" .. notecount
  local out = {
    pandoc.RawInline("html", '<label for="' .. id .. '" class="sidenote-number" aria-label="poznámka"></label>'
      .. '<input type="checkbox" id="' .. id .. '" class="margin-toggle"/><span class="sidenote">'),
  }
  for _, i in ipairs(pandoc.utils.blocks_to_inlines(el.content)) do out[#out + 1] = i end
  out[#out + 1] = pandoc.RawInline("html", "</span>")
  return out
end

function RawInline(el)
  if el.format ~= "latex" then return nil end
  -- a \cite becomes a Cite whose fallback text is the raw TeX; citeproc replaces it
  if el.text:match("^\\%a*cite") then return nil end
  report("unconverted TeX", el.text)
  return {}
end
function RawBlock(el)
  if el.format == "latex" then report("unconverted TeX", el.text:sub(1, 80)) end
  return {}
end

function Table(el)
  return pandoc.Div({ el }, pandoc.Attr("", { "tabulka" }))   -- scrolls inside itself on a phone
end

-- boxes: title from the @@BOX@@ marker paragraph, an id to link to, class per box type
function Div(el)
  local kind = el.classes[1]
  if kind == "akce" then return nil end
  local label = BOXES[kind]
  if not label then return nil end
  -- the name keeps its markup (e.g. "Možné výsledky \akc{Akcí}"): the marker paragraph's
  -- inlines without the leading "@@BOX@@"
  local name, body = nil, {}
  for _, b in ipairs(el.content) do
    if name == nil and (b.t == "Para" or b.t == "Plain")
        and pandoc.utils.stringify(b):sub(1, 7) == "@@BOX@@" then
      name = pandoc.List(b.content or {})
      local first = name[1]
      if first and first.t == "Str" then
        first.text = first.text:gsub("^@@BOX@@", "")
        if first.text == "" then name:remove(1) end
      end
    else
      body[#body + 1] = b
    end
  end
  boxcount = boxcount + 1
  local plain = name and pandoc.utils.stringify(name) or ""
  local id = slug(kind .. "-" .. (plain ~= "" and plain or tostring(boxcount)))
  local title = { pandoc.Strong({ pandoc.Str(label) }) }
  if plain ~= "" then
    title[#title + 1] = pandoc.Space()
    title[#title + 1] = pandoc.Str("(")
    title[#title + 1] = pandoc.Span(name, pandoc.Attr("", { "box-name" }))
    title[#title + 1] = pandoc.Str(")")
  end
  table.insert(body, 1, pandoc.Div({ pandoc.Plain(title) }, pandoc.Attr("", { "box-title" })))
  return pandoc.Div(body, pandoc.Attr(id, { "box", "box-" .. slug(kind) }))
end

-- in the EPUB, each chapter heading gets an id that cross-references can point to
function Header(el)
  if EPUB and el.level == 1 and el.identifier ~= "" then
    local t = MAP[el.identifier]
    if t then el.identifier = "kapitola-" .. t.page end
  end
  return el
end

-- no space before a note's number, as in LaTeX (`čepelí \sidenote{…}` sets the mark right
-- after the word); runs before the notes are converted
function Inlines(inlines)
  for i = #inlines - 1, 1, -1 do
    if inlines[i].t == "Space" and inlines[i + 1].t == "Note" then inlines:remove(i) end
  end
  return inlines
end

return {
  { Meta = Meta },
  { Inlines = Inlines },
  { Span = Span, Link = Link, Image = Image, Note = Note, RawInline = RawInline,
    RawBlock = RawBlock, Table = Table, Div = Div, Header = Header },
}
