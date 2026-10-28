-- Deck files: plain text, one card per line, tab-separated:  front<TAB>back[<TAB>extra...]
--   * lines that are blank or start with '#' are ignored (Anki's "Notes in Plain Text" export starts with # headers)
--   * Anki HTML is cleaned (<br>, <div> -> line breaks; other tags dropped; common entities decoded; [sound:..] removed)
--   * cloze: a front containing {{c1::answer::hint}} is a cloze card: the question shows [...] (or [hint]), the answer
--     fills the hole in. Put new cards at the END of the file: progress is stored per line position.
-- Decks live in <app>/decks/ (read-only, ships with the app) or in the app's data folder data:decks/ (yours).
local M = {}

-- Decoded to plain ASCII where the X4's fonts have no glyph (arrows, dashes, curly quotes).
local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ", rarr = "->", larr = "<-",
                   harr = "<->", ndash = "-", mdash = "-", hellip = "...", lsquo = "'", rsquo = "'", ldquo = '"',
                   rdquo = '"', times = "x", middot = "-", bull = "*" }

function M.clean(s)
  s = s:gsub("%[sound:[^%]]*%]", "")
  s = s:gsub("<[bB][rR]%s*/?>", "\n")
  s = s:gsub("</[dD][iI][vV]>", "\n"):gsub("</[pP]>", "\n"):gsub("</[lL][iI]>", "\n")
  s = s:gsub("<[^>]*>", "")
  s = s:gsub("&#(%d+);", function(n) n = tonumber(n); return (n < 128 and string.char(n)) or (n < 0x110000 and utf8.char(n)) or "" end)
  s = s:gsub("&(%w+);", function(e) return ENTITIES[e] or ("&" .. e .. ";") end)
  s = s:gsub("[ \t]+\n", "\n"):gsub("\n\n\n+", "\n\n")
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Returns question, answer for one deck line (already cleaned of the line terminator). nil if not a card.
function M.parse_line(line)
  if line:sub(1, 1) == "#" then return nil end
  local front, back, extra = line:match("^([^\t]*)\t([^\t]*)\t?(.*)$")
  if not front or front == "" then return nil end
  if front:find("{{c%d+::") then
    local q = front:gsub("{{c%d+::(.-)}}", function(body)
      local hint = body:match("^.-::(.*)$")
      return "[" .. (hint or "...") .. "]"
    end)
    local a = front:gsub("{{c%d+::(.-)}}", function(body) return (body:match("^(.-)::") or body) end)
    local more = (back ~= "" and back or nil)
    return M.clean(q), M.clean(a .. (more and ("\n\n" .. back) or "")), true
  end
  local ans = M.clean(back)
  if extra and extra ~= "" then ans = ans .. "\n\n" .. M.clean(extra) end
  return M.clean(front), ans, false
end

-- All deck files: { {name=, path=} ... } sorted by name. `path` is an fs path spec ("app:decks/x.tsv").
function M.list()
  local out, seen = {}, {}
  for _, scope in ipairs({ "app:decks", "data:decks" }) do
    local names = fs.list(scope)
    if names then
      for _, n in ipairs(names) do
        local base, ext = n:match("^(.+)%.(%w+)$")
        if base and (ext == "tsv" or ext == "txt") and not seen[base] then
          seen[base] = true
          out[#out + 1] = { name = base, path = scope .. "/" .. n }
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  return out
end

return M
