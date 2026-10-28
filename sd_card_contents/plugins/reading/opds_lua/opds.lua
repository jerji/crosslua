-- opds.lua: OPDS (Atom) feed model for the OPDS browser. Pure functions, no
-- device calls except the explicit fs handle passed to filter_file().

local M = {}

local ACQ_PREFIX = "http://opds-spec.org/acquisition"
local EPUB = "application/epub+zip"
local THUMB_MARK = 'href="data:'   -- inline base64 thumbnails: dropped before parsing
local CHUNK = 4096
local MAX_LINE = 16384

-- Resolve an href against the feed URL it came from (absolute, //host, /path, relative).
function M.resolve(base, href)
  if not href or href == "" then return nil end
  if href:match("^https?://") then return href end
  local scheme, host = base:match("^(https?)://([^/]+)")
  if not scheme then return nil end
  if href:sub(1, 2) == "//" then return scheme .. ":" .. href end
  if href:sub(1, 1) == "/" then return scheme .. "://" .. host .. href end
  local dir = base:match("^(https?://[^/]*/.*/)") or (scheme .. "://" .. host .. "/")
  return dir .. href
end

local function children(node, tag, out)
  out = out or {}
  for _, c in ipairs(node) do
    if type(c) == "table" and c.tag == tag then out[#out + 1] = c end
  end
  return out
end

local function child(node, tag)
  return children(node, tag)[1]
end

-- Direct text of an element, whitespace collapsed (nested elements ignored).
local function text(node)
  if not node then return "" end
  local parts = {}
  for _, c in ipairs(node) do
    if type(c) == "string" then parts[#parts + 1] = c end
  end
  local s = table.concat(parts):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  return s
end
M.text = text

local function short(s, n)
  if #s <= n then return s end
  return s:sub(1, n - 3) .. "..."
end

-- root: the xml.parse() result of a feed. base: the URL it was fetched from.
-- Returns { title, next, items = { {kind, title, sub, nav|acq} } }
-- kind "nav": open nav (a subsection or the next page)
-- kind "dl":  an EPUB acquisition link (acq = {href, length, title})
function M.model(root, base)
  local feed = { title = text(child(root, "title")), items = {} }
  for _, ln in ipairs(children(root, "link")) do
    if ln.attrs and ln.attrs.rel == "next" then
      feed.next = M.resolve(base, ln.attrs.href)
    end
  end

  local entries = children(root, "entry")
  local any_nav = false
  local rows = {}
  for _, e in ipairs(entries) do
    local row = { title = text(child(e, "title")), sub = short(text(child(e, "content")), 60), acq = {} }
    for _, ln in ipairs(children(e, "link")) do
      local a = ln.attrs or {}
      local rel = a.rel or ""
      if rel == "subsection" and not row.nav then
        row.nav = M.resolve(base, a.href)
      elseif rel:sub(1, #ACQ_PREFIX) == ACQ_PREFIX and a.type == EPUB then
        row.acq[#row.acq + 1] = {
          title = a.title or "EPUB",
          href = M.resolve(base, a.href),
          length = tonumber(a.length or ""),
        }
      end
    end
    if row.nav then any_nav = true end
    rows[#rows + 1] = row
  end

  if any_nav then
    -- A listing: entries open their own page (books, sub-catalogues).
    for _, row in ipairs(rows) do
      if row.nav then
        feed.items[#feed.items + 1] = { kind = "nav", title = row.title, sub = row.sub, nav = row.nav }
      end
    end
  else
    -- A book page: every EPUB format becomes its own download row.
    for _, row in ipairs(rows) do
      for _, acq in ipairs(row.acq) do
        feed.items[#feed.items + 1] = { kind = "dl", title = acq.title, sub = row.title, acq = acq }
      end
    end
  end

  if feed.next then
    feed.items[#feed.items + 1] = { kind = "nav", title = "Next page", sub = "", nav = feed.next }
  end
  return feed
end

-- A feed file name for the card cache, derived from the URL (djb2, 8 hex digits).
function M.cache_name(url)
  local h = 5381
  for i = 1, #url do
    h = (h * 33 + url:byte(i)) & 0x7fffffff
  end
  return string.format("feed_%08x.xml", h)
end

-- Make a FAT-safe ASCII base name from a book title. Returns "<name>.epub".
function M.filename(title)
  local s = (title or ""):gsub("[%c\\/:*?\"<>|]", " ")
  s = s:gsub("[\128-\255]", "_"):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  if #s > 72 then s = s:sub(1, 72) end
  if s == "" then s = "book" end
  return s .. ".epub"
end

-- "Name.epub" -> "Name (2).epub" until exists(path) is false. dir is "sd:Books/".
function M.unique(dir, name, exists)
  if not exists(dir .. name) then return name end
  local base = name:sub(1, -6)
  local n = 2
  while exists(dir .. base .. " (" .. n .. ").epub") do n = n + 1 end
  return base .. " (" .. n .. ").epub"
end

-- Copy src to dst, dropping every line that carries an inline data: thumbnail.
-- Streams in 4 KB pieces, so the whole feed never sits in the Lua heap.
-- fs_ is the fs namespace. Returns true, or nil, err.
function M.filter_file(fs_, src, dst)
  local size = fs_.size(src)
  if not size then return nil, "no feed was saved" end
  local ok, err = fs_.write(dst, "")
  if not ok then return nil, err or "cannot write the cache" end

  local out, outn = {}, 0
  local function add(s)
    out[#out + 1] = s
    outn = outn + #s
    if outn >= CHUNK then
      local good, e = fs_.append(dst, table.concat(out))
      if not good then return nil, e or "cannot write the cache" end
      out, outn = {}, 0
    end
    return true
  end

  local off, carry = 0, ""
  while off < size do
    local chunk, rerr = fs_.read(src, off, CHUNK)
    if not chunk then return nil, rerr or "cannot read the feed" end
    if #chunk == 0 then break end
    off = off + #chunk
    local buf = carry .. chunk
    local pos = 1
    while true do
      local nl = buf:find("\n", pos, true)
      if not nl then break end
      local line = buf:sub(pos, nl)
      if not line:find(THUMB_MARK, 1, true) then
        local a, e = add(line)
        if not a then return nil, e end
      end
      pos = nl + 1
    end
    carry = buf:sub(pos)
    if #carry > MAX_LINE then return nil, "feed line too long for the device" end
  end
  if carry ~= "" and not carry:find(THUMB_MARK, 1, true) then
    local a, e = add(carry)
    if not a then return nil, e end
  end
  if outn > 0 then
    local good, e = fs_.append(dst, table.concat(out))
    if not good then return nil, e or "cannot write the cache" end
  end
  return true
end

return M
