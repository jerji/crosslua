-- AO3 title-page scraper. An EPUB is a zip: META-INF/container.xml -> OPF ->
-- spine. The first spine items carry AO3's metadata block (native AO3 <dl>
-- lists or FanFicFare's plain "Label: value" rows). Tags are flattened to
-- text, then each field is read from "Label: value" up to the next known
-- label. Pure string work: no network, no radio.

local M = {}

local ENTITY = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }

local function decode(s)
  return (s:gsub("&(#?%w+);", function(e)
    local v = ENTITY[e]
    if v then return v end
    local n
    if e:sub(1, 2) == "#x" or e:sub(1, 2) == "#X" then
      n = tonumber(e:sub(3), 16)
    elseif e:sub(1, 1) == "#" then
      n = tonumber(e:sub(2))
    end
    if n and n > 0 and n < 0x110000 then return utf8.char(n) end
    return "&" .. e .. ";"
  end))
end

-- Flatten HTML to one line of plain text (tags become spaces).
local function plain(html)
  html = html:gsub("<script.-</script>", " "):gsub("<style.-</style>", " ")
  html = html:gsub("<!%-%-.-%-%->", " "):gsub("<[^>]*>", " ")
  html = decode(html)
  return (html:gsub("%s+", " "):match("^%s*(.-)%s*$"))
end
M.plain = plain

-- Every label that can start a new field. A value ends at the next one.
local LABELS = {
  "Archive Warning:", "Warnings:", "Warning:", "Rating:", "Category:",
  "Fandoms:", "Fandom:", "Relationships:", "Relationship:", "Characters:",
  "Character:", "Additional Tags:", "Freeform:", "Language:", "Series:",
  "Stats:", "Published:", "Updated:", "Words:", "Chapters:", "Collections:",
  "Summary:", "Status:", "Comments:", "Kudos:", "Bookmarks:", "Hits:", "Notes:",
}

-- Value after the first occurrence of `label`, or nil when absent/empty.
local function value(text, label)
  local s = text:find(label, 1, true)
  if not s then return nil end
  local from = s + #label
  local to = math.min(#text, from + 299)
  for _, b in ipairs(LABELS) do
    local p = text:find(b, from, true)
    if p and p - 1 < to then to = p - 1 end
  end
  local v = text:sub(from, to):match("^%s*(.-)%s*$")
  if v == "" then return nil end
  return v
end

local function first_item(v)
  local s = v:match('^"?%s*([^,"]+)') or ""
  return (s:match("^(.-)%s*$"))
end

-- Fill every still-missing field from one plain-text title page.
local function fill(text, out)
  if not out.words then
    local w = value(text, "Words:")
    local n = w and tonumber((w:gsub("%D", "")):sub(1, 9))
    if n and n > 0 then out.words = n end
  end
  if out.chapters == nil then
    local c = value(text, "Chapters:") or ""
    local n, slash, m = c:match("^(%d+)%s*(/?)%s*(%d*)")
    if n then
      out.chapters = math.min(tonumber(n), 65535)
      if slash == "/" then
        out.completed = (m ~= "" and tonumber(m) == tonumber(n))
      else
        out.completed = not text:find("In-Progress", 1, true)
      end
    end
  end
  if not out.rating then
    local r = value(text, "Rating:")
    if r then
      out.rating = (r:find("General", 1, true) and "G")
        or (r:find("Teen", 1, true) and "T")
        or (r:find("Mature", 1, true) and "M")
        or (r:find("Explicit", 1, true) and "E")
        or "-"
    end
  end
  if not out.warning then
    local w = value(text, "Archive Warning:") or value(text, "Warnings:")
    if w then
      if w:find("Creator Chose Not To Use", 1, true) or w:find("Choose Not To Use", 1, true) then
        out.warning = "B"
      elseif w:find("No Archive Warnings", 1, true) then
        out.warning = "-"
      elseif #w > 3 then
        out.warning = "!"
      else
        out.warning = "-"
      end
    end
  end
  if not out.fandom then
    local f = value(text, "Fandoms:") or value(text, "Fandom:") or value(text, "Category:")
    if f then out.fandom = first_item(f) end
  end
  if not out.updated then
    local d = value(text, "Updated:") or value(text, "Published:") or ""
    out.updated = d:match("%d%d%d%d%-%d%d%-%d%d")
  end
end

local function unhref(h)
  return (h:gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end))
end

local function attr(tag, name)
  return tag:match("%s" .. name .. "%s*=%s*\"([^\"]*)\"")
    or tag:match("%s" .. name .. "%s*=%s*'([^']*)'")
end

-- Scrape one AO3 (or FanFicFare) EPUB at `path` (sd: or data: scope).
-- Returns { title, author, words, chapters, completed, rating, warning,
-- fandom, updated } or nil, reason. Success needs a word count > 0.
function M.scrape(path, fallback_title)
  local container, e1 = zip.read(path, "META-INF/container.xml", 8192)
  if not container then return nil, "not a readable EPUB (" .. tostring(e1) .. ")" end
  local opf_path = container:match("full%-path%s*=%s*[\"']([^\"']+)[\"']")
  container = nil
  if not opf_path then return nil, "no OPF in container.xml" end

  local opf, e2 = zip.read(path, opf_path, 65536)
  if not opf then return nil, "OPF unreadable (" .. tostring(e2) .. ")" end
  local base = opf_path:match("^(.*/)") or ""

  local manifest = {}
  for tag in opf:gmatch("<[%w:]*item%s[^>]*>") do
    local id, href = attr(tag, "id"), attr(tag, "href")
    if id and href then manifest[id] = href end
  end
  local spine = {}
  for tag in opf:gmatch("<[%w:]*itemref%s[^>]*>") do
    local r = attr(tag, "idref")
    if r and manifest[r] then spine[#spine + 1] = base .. unhref(manifest[r]) end
  end

  local out = {}
  local title = opf:match("<[%w:]*title[^>]*>(.-)</[%w:]*title>")
  local author = opf:match("<[%w:]*creator[^>]*>(.-)</[%w:]*creator>")
  out.title = (title and plain(title) ~= "" and plain(title)) or fallback_title or ""
  out.author = (author and plain(author)) or ""
  opf = nil
  collectgarbage()

  if #spine == 0 then return nil, "empty spine" end
  for i = 1, math.min(3, #spine) do
    do
      local html = zip.read(path, spine[i], 65536)
      if html then fill(plain(html), out) end
    end
    collectgarbage()
    if out.words and out.rating then break end
  end

  if not out.words then return nil, "no AO3 word count (not an AO3 or FanFicFare EPUB)" end
  out.rating = out.rating or "-"
  out.warning = out.warning or "-"
  out.fandom = out.fandom or ""
  out.updated = out.updated or ""
  out.chapters = out.chapters or 0
  out.completed = out.completed or false
  return out
end

return M
