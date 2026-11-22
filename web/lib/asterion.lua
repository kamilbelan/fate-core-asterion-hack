---@diagnostic disable: undefined-global  -- pandoc filter globals (pandoc, FORMAT)
-- pandoc filter: the book's LaTeX (after web/lib/preprocess.pl) -> web pages and EPUB.
--
-- Metadata (set by web/build.sh):
--   labelmap  path to the Lua table from labelmap.pl (label -> page, anchor, title)
--   images    path to a Lua table: \includegraphics name -> file in the output (img/…)
--   page      slug of the page being converted ("" for the EPUB, which is one document)
--   built     comma-separated slugs of the chapters that have a web page / are in the EPUB
--   prehledy  web: file to append this page's entries of the Přehledy to (see Pandoc below)
--
-- Anything that is still TeX after conversion is reported on stderr: pandoc drops what it
-- does not understand, and a silent build must mean nothing was lost.

local MAP, IMAGES, PAGE, BUILT = {}, {}, "", {}
local SEARCH                                   -- web: file to append this page's search entries to
local PREHLEDY                                 -- web: file to append this page's Přehledy entries to
local EPUB = FORMAT:match("epub") ~= nil
local boxcount, notecount = 0, 0
local USED_IDS = {}

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
  SEARCH = m.searchindex and pandoc.utils.stringify(m.searchindex) or nil
  PREHLEDY = m.prehledy and pandoc.utils.stringify(m.prehledy) or nil
  m.labelmap, m.images, m.page, m.built, m.searchindex, m.prehledy = nil, nil, nil, nil, nil, nil
  return m
end

-- \asp{…} etc. arrive as \textcolor{asp}{…}: a span with a colour style -> CSS class
function Span(el)
  local color = (el.attributes.style or ""):match("color:%s*([^;]+)")
  if not color then return nil end
  if TERMS[color] then
    return pandoc.Span(el.content, pandoc.Attr("", { color }))
  end
  local kind = color:match("^(%a+)%-[%w-]+%-%d+$")          -- asp-akce-3: an anchored occurrence
  if kind and TERMS[kind] then
    return pandoc.Span(el.content, pandoc.Attr(color, { kind }))
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
  if not ref then
    -- links between chapters ("akce.html", e.g. in the lists of terms): inside the EPUB they
    -- point to the chapter's heading in the same book
    if EPUB then
      local page, frag = el.target:match("^([%w-]+)%.html#?(.*)$")
      if page then el.target = "#" .. (frag ~= "" and frag or ("kapitola-" .. page)) end
    end
    return el
  end
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

-- the same box name can occur twice (e.g. a speciality of two povolání): keep ids unique,
-- which matters in the EPUB, where all chapters are one document
local function unique_id(base)
  local id, n = base, 1
  while USED_IDS[id] do n = n + 1; id = base .. "-" .. n end
  USED_IDS[id] = true
  return id
end

-- a marker paragraph (`@@BOX@@<name>`, `@@BOX:<list>@@<name>`, `@@PREHLED:<list>@@<name>`,
-- see preprocess.pl): its kind, its list (or ""), and the name's inlines; nil if b is none
local function marker(b)
  if not (b.t == "Para" or b.t == "Plain") then return nil end
  local first = b.content[1]
  if not (first and first.t == "Str") then return nil end
  local kind, list = first.text:match("^@@(%u+):?(%w*)@@")
  if not kind then return nil end
  local name = pandoc.List(b.content):clone()
  name[1] = pandoc.Str((first.text:gsub("^@@%u+:?%w*@@", "")))
  if name[1].text == "" then name:remove(1) end
  return kind, list, name
end

-- a name as LaTeX for the Přehledy page (prehledy.pl), terms as the `\textcolor{<class>}`
-- the web definitions make of them
local function to_tex(inlines)
  local ins = pandoc.Inlines(inlines):walk({
    Span = function(s)
      local c = s.classes[1]
      if not TERMS[c] then return nil end
      local out = pandoc.List({ pandoc.RawInline("latex", "\\textcolor{" .. c .. "}{") })
      out:extend(s.content)
      out:insert(pandoc.RawInline("latex", "}"))
      return out
    end,
  })
  return (pandoc.write(pandoc.Pandoc({ pandoc.Plain(ins) }), "latex", { wrap_text = "none" }):gsub("%s+$", ""))
end

-- an entry of the Přehledy, kept on the element until Pandoc() collects them in order
local function list_entry(el, list, tex)
  el.attributes["prehled"] = list
  el.attributes["prehled-tex"] = tex
end

-- boxes: title from the @@BOX@@ marker paragraph, an id to link to, class per box type
function Div(el)
  local kind = el.classes[1]
  if kind == "akce" then return nil end
  local label = BOXES[kind]
  if not label then return nil end
  -- the name keeps its markup (e.g. "Možné výsledky \akc{Akcí}"): the marker paragraph's
  -- inlines without the leading "@@BOX@@"
  local name, list, body = nil, "", {}
  for _, b in ipairs(el.content) do
    local mkind, mlist, mname = nil, nil, nil
    if name == nil then mkind, mlist, mname = marker(b) end
    if mkind == "BOX" then name, list = mname, mlist or ""
    else body[#body + 1] = b end
  end
  boxcount = boxcount + 1
  local plain = name and pandoc.utils.stringify(name) or ""
  local id = unique_id(slug(kind .. "-" .. (plain ~= "" and plain or tostring(boxcount))))
  local title = { pandoc.Strong({ pandoc.Str(label) }) }
  if plain ~= "" then
    title[#title + 1] = pandoc.Space()
    title[#title + 1] = pandoc.Str("(")
    title[#title + 1] = pandoc.Span(name, pandoc.Attr("", { "box-name" }))
    title[#title + 1] = pandoc.Str(")")
  end
  table.insert(body, 1, pandoc.Div({ pandoc.Plain(title) }, pandoc.Attr("", { "box-title" })))
  local box = pandoc.Div(body, pandoc.Attr(id, { "box", "box-" .. slug(kind) }))
  if list ~= "" then list_entry(box, list, plain ~= "" and to_tex(name) or label) end
  return box
end

-- a rule listed with \pravidlovprehledu (marker @@PREHLED:<list>@@<name>): the entry links to
-- the heading right before it, otherwise to an anchor at its place
function Blocks(blocks)
  for i = #blocks, 1, -1 do
    local kind, list, name = marker(blocks[i])
    if kind == "PREHLED" then
      local prev = blocks[i - 1]
      if prev and prev.t == "Header" and prev.identifier ~= "" then
        list_entry(prev, list, to_tex(name))
        blocks:remove(i)
      else
        local anchor = pandoc.Div({}, pandoc.Attr(unique_id(slug("prehled-" .. pandoc.utils.stringify(name))), {}))
        list_entry(anchor, list, to_tex(name))
        blocks[i] = anchor
      end
    end
  end
  return blocks
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

-- full-text search (web only): one entry per section (text up to the next heading) and one per
-- box, as JSON lines appended to SEARCH; build.sh joins them into assets/search.json.
--   p page, c chapter title, a anchor ("" = top of the page), t title, x plain text
local function plain(blocks)
  local doc = pandoc.Pandoc(blocks):walk({
    RawInline = function() return {} end,                   -- margin-note markup, not text
    RawBlock  = function() return {} end,
  })
  -- pandoc's plain-text writer keeps the spaces between list items, cells and paragraphs;
  -- list markers and table rules are dropped, whitespace collapsed
  local text = pandoc.write(doc, "plain", { wrap_text = "none" })
  text = ("\n" .. text):gsub("\n[ \t]*[%-%*]%s+", "\n"):gsub("\n[ \t]*%(?%w+[%.%)]%s+", "\n")
  text = text:gsub("%-%-%-+", " "):gsub("%s+", " ")
  return (text:gsub("^ ", ""):gsub(" $", ""))
end

local function is_box(b) return b.t == "Div" and b.classes:includes("box") and b.identifier ~= "" end

-- the Přehledy (lists after the contents in the PDF): the entries that Div and Blocks marked,
-- in document order, as TSV lines (list, page, anchor, name as LaTeX) appended to PREHLEDY;
-- prehledy.pl makes the page from them. The marks are removed from the output.
local function prehledy(doc)
  local lines = {}
  local function collect(el)
    local list = el.attributes["prehled"]
    if not list then return nil end
    lines[#lines + 1] = table.concat({ list, PAGE, el.identifier, (el.attributes["prehled-tex"]:gsub("%s+", " ")) }, "\t")
    el.attributes["prehled"], el.attributes["prehled-tex"] = nil, nil
    return el
  end
  doc = doc:walk({ Div = collect, Header = collect })
  if PREHLEDY and #lines > 0 then
    local f = assert(io.open(PREHLEDY, "a"))
    f:write(table.concat(lines, "\n"), "\n")
    f:close()
  end
  return doc
end

function Pandoc(doc)
  doc = prehledy(doc)
  if EPUB or not SEARCH then return doc end
  local entries, chapter, cur = {}, "", nil
  local function flush()
    if cur and cur.x ~= "" then entries[#entries + 1] = cur end
  end
  local function add_box(b)
    local title, body = "", {}
    for _, c in ipairs(b.content) do
      if c.t == "Div" and c.classes:includes("box-title") then title = plain(c.content)
      else body[#body + 1] = c end
    end
    entries[#entries + 1] = { p = PAGE, c = chapter, a = b.identifier, t = title, x = plain(body) }
  end
  for _, b in ipairs(doc.blocks) do
    if b.t == "Header" then
      flush()
      local title = plain({ pandoc.Plain(b.content) })
      if b.level == 1 then chapter = title end
      cur = { p = PAGE, c = chapter, a = (b.level == 1) and "" or b.identifier, t = title, x = "" }
    elseif is_box(b) then
      add_box(b)                                            -- its own result, not repeated in the section
    elseif b.t == "Figure" or (b.t == "Div" and b.classes:includes("rejstrik")) then
      -- illustrations: nothing to search (their caption is only the credit link "zdroj");
      -- the generated lists of aspects and tricks repeat what the chapters already contain
    else
      cur = cur or { p = PAGE, c = chapter, a = "", t = chapter, x = "" }
      b:walk({ Div = function(d) if is_box(d) then add_box(d) end end })   -- boxes inside lists
      local text = plain({ b })
      if text ~= "" then cur.x = (cur.x == "" and "" or cur.x .. " ") .. text end
    end
  end
  flush()
  local f = assert(io.open(SEARCH, "a"))
  for _, e in ipairs(entries) do f:write(pandoc.json.encode(e), "\n") end
  f:close()
  return doc
end

return {
  { Meta = Meta },
  { Inlines = Inlines },
  { Span = Span, Link = Link, Image = Image, Note = Note, RawInline = RawInline,
    RawBlock = RawBlock, Table = Table, Div = Div, Header = Header, Blocks = Blocks },
  { Pandoc = Pandoc },
}
