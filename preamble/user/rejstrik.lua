---@diagnostic disable: undefined-global, lowercase-global  -- LuaTeX globals (tex, unicode)
-- Lists of all aspects (\asp) and tricks (\trk) used in the book, for the appendix.
--
-- Every \asp{..}/\trk{..} writes `\asteriontermin{<kind>}{<text>}{<page>}` to the .aux file;
-- when the .aux is read in the next run, `add` collects the terms here, and `print`
-- typesets them sorted in Czech alphabetical order with the pages they appear on.

asterion_rejstrik = asterion_rejstrik or { asp = {}, trk = {} }
local R = asterion_rejstrik
local ulower = unicode.utf8.lower
local uupper = unicode.utf8.upper

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function first_char(s)
    return s:match("^[%z\1-\127\194-\244][\128-\191]*") or ""
end

-- "A, B, C" lists several terms in one \asp; split at ", " followed by an uppercase letter
-- (a lowercase continuation belongs to the same term: "Hora, kde sídlí bohové")
local function split(text)
    local parts, current = {}, ""
    for piece in (text .. ", "):gmatch("(.-), ") do
        local c = first_char(piece)
        if current ~= "" and c ~= "" and c ~= ulower(c) then
            table.insert(parts, current)
            current = piece
        elseif current == "" then
            current = piece
        else
            current = current .. ", " .. piece
        end
    end
    if current ~= "" then table.insert(parts, current) end
    return parts
end

function R.add(kind, text, page)
    local list = R[kind]
    if not list then return end
    for _, term in ipairs(split(text)) do
        term = trim(term)
        if term ~= "" then
            local key = ulower(term)
            local e = list[key]
            if not e then
                e = { term = term, pages = {}, seen = {} }
                list[key] = e
            end
            if not e.seen[page] then
                e.seen[page] = true
                table.insert(e.pages, page)
            end
        end
    end
end

-- Czech collation: č, ř, š, ž and "ch" are letters of their own, accents (á, é, ě, í, ó, ú, ů,
-- ý, ď, ť, ň) only break ties; other characters are ignored for the primary order
local alphabet = { "a", "b", "c", "č", "d", "e", "f", "g", "h", "ch", "i", "j", "k", "l", "m",
                   "n", "o", "p", "q", "r", "ř", "s", "š", "t", "u", "v", "w", "x", "y", "z", "ž" }
local weight = {}
for i, l in ipairs(alphabet) do weight[l] = i end
local base = { ["á"] = "a", ["ď"] = "d", ["é"] = "e", ["ě"] = "e", ["í"] = "i", ["ň"] = "n",
               ["ó"] = "o", ["ť"] = "t", ["ú"] = "u", ["ů"] = "u", ["ý"] = "y" }

-- letters of a string as sort units ("ch" is one unit), each mapped to its base letter
local function units(s)
    local out, chars = {}, {}
    for _, cp in utf8.codes(ulower(s)) do table.insert(chars, utf8.char(cp)) end
    local i = 1
    while i <= #chars do
        local c = chars[i]
        if c == "c" and chars[i + 1] == "h" then
            table.insert(out, "ch"); i = i + 2
        else
            c = base[c] or c
            if weight[c] then table.insert(out, c) end
            i = i + 1
        end
    end
    return out
end

local function before(a, b)
    local ua, ub = units(a.term), units(b.term)
    for i = 1, math.min(#ua, #ub) do
        if ua[i] ~= ub[i] then return weight[ua[i]] < weight[ub[i]] end
    end
    if #ua ~= #ub then return #ua < #ub end
    return a.term < b.term
end

-- typeset one list: letter headings and entries `\asterionrejstrikpolozka{<style>}{<term>}{<pages>}`
function R.print(kind)
    local list, entries = R[kind] or {}, {}
    for _, e in pairs(list) do table.insert(entries, e) end
    if #entries == 0 then
        tex.print("\\asterionrejstrikprazdny")
        return
    end
    table.sort(entries, before)
    local group = nil
    for _, e in ipairs(entries) do
        local u = units(e.term)[1] or "#"
        local g = (u == "ch") and "Ch" or uupper(u)
        if g ~= group then
            tex.print("\\asterionrejstrikpismeno{" .. g .. "}")
            group = g
        end
        local pages = {}
        for _, p in ipairs(e.pages) do
            table.insert(pages, "\\hyperlink{page." .. p .. "}{" .. p .. "}")
        end
        tex.print("\\asterionrejstrikpolozka{" .. kind .. "}{" .. e.term .. "}{" .. table.concat(pages, ", ") .. "}")
    end
end
