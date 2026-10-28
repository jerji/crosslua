-- OPDS browser: browse OPDS catalogues (Atom feeds) and download EPUBs to the
-- card's Books folder. Feeds: Project Gutenberg by default; add your own
-- (a Calibre server on your LAN, say) by writing data:feeds.txt, one
-- "Title|https://..." per line (see README.md).
--
-- RAM: wifi.connect and TLS want most of the heap, so feeds are streamed to
-- the card (save_to) and filtered line by line before xml.parse ever sees
-- them. The list only keeps the current feed; Back re-reads a cached copy.

local opds                     -- required inside __main so a load error hits the pcall

local DEFAULT_FEEDS = {
  { title = "Gutenberg: popular", url = "https://www.gutenberg.org/ebooks/search.opds/?sort_order=downloads" },
  { title = "Gutenberg: newest", url = "https://www.gutenberg.org/ebooks/search.opds/?sort_order=release_date" },
  { title = "Gutenberg: catalogue", url = "https://www.gutenberg.org/ebooks.opds/" },
}
local FEEDS_FILE = "data:feeds.txt"
local RAW = "data:opds_raw.xml"
local SAVE_DIR = "sd:Books/"
local HEAD_H = 46
local FOOT_H = 34
local ROW_H = 46
local MARGIN = 12

local W, H = 0, 0
local roots = {}
local cur = nil        -- { title, url, items, cursor, msg }
local stack = {}       -- { title, url, cursor } for each level above cur
local phase = "list"   -- "list" | "saved"
local saved_path = ""
local status = ""      -- one-line message in the footer

-- --- drawing --------------------------------------------------------------

-- Truncate s so it fits max_w px in font (char-safe for UTF-8).
local function fit(s, max_w, font, flags)
  if gfx.text_width(s, font, flags) <= max_w then return s end
  local n = utf8.len(s) or #s
  while n > 1 do
    n = n - 1
    local t = s:sub(1, utf8.offset(s, n + 1) - 1) .. "..."
    if gfx.text_width(t, font, flags) <= max_w then return t end
  end
  return "..."
end

local function header(title)
  gfx.rect(0, 0, W, HEAD_H, true, true)
  gfx.text(MARGIN, 13, fit(title, W - 2 * MARGIN, "sans16", "bw"), "sans16", "bw")
end

local function footer(hint)
  gfx.rect(0, H - FOOT_H, W, 1, true, true)
  local line = status ~= "" and status or hint
  gfx.text(MARGIN, H - FOOT_H + 9, fit(line, W - 2 * MARGIN, "ui12", "b"), "ui12", "b")
end

local function visible_rows()
  return math.max(1, (H - HEAD_H - FOOT_H) // ROW_H)
end

local function draw_list()
  gfx.clear()
  header(cur.title)
  local items = cur.items
  if #items == 0 then
    gfx.text(MARGIN, HEAD_H + 20, cur.msg or "Nothing here.", "sans14", "")
    footer("Back: up")
    gfx.present()
    return
  end
  local rows = visible_rows()
  local top = 1
  if cur.cursor > rows then top = cur.cursor - rows + 1 end
  for i = 0, rows - 1 do
    local idx = top + i
    local it = items[idx]
    if not it then break end
    local y = HEAD_H + i * ROW_H
    local sel = (idx == cur.cursor)
    if sel then gfx.rect(0, y, W, ROW_H, true, true) end
    local tcol = sel and "bw" or "b"
    local scol = sel and "w" or ""
    local tw = W - 2 * MARGIN - 70
    gfx.text(MARGIN, y + 4, fit(it.title or "", tw, "sans14", tcol), "sans14", tcol)
    if it.sub and it.sub ~= "" then
      gfx.text(MARGIN, y + 24, fit(it.sub, W - 2 * MARGIN - 70, "ui12", scol), "ui12", scol)
    end
    if it.kind == "nav" then
      gfx.text(W - MARGIN, y + 12, ">", "sans14", tcol .. "r")
    else
      local size = it.acq.length and string.format("%d KB", it.acq.length // 1024) or "EPUB"
      gfx.text(W - MARGIN, y + 14, size, "ui12", scol .. "r")
    end
  end
  local pos = string.format("%d/%d", cur.cursor, #items)
  footer(pos .. "   Confirm: open   Back: up")
  gfx.present()
end

local function draw_message(lines, hint)
  gfx.clear()
  header("OPDS Browser")
  local y = HEAD_H + 20
  for _, ln in ipairs(lines) do
    local wrapped = gfx.wrap(ln, W - 2 * MARGIN, "sans14")
    for _, w in ipairs(wrapped) do
      gfx.text(MARGIN, y, w, "sans14", "")
      y = y + gfx.line_height("sans14") + 4
    end
    y = y + 10
  end
  footer(hint)
  gfx.present()
end

local function busy(text)
  draw_message({ text }, "Back cancels")
end

-- --- wifi / network ---------------------------------------------------------

local function ensure_wifi()
  local s = wifi.status()
  if s and s.connected then return true end
  local ok, reason = wifi.connect()
  if ok then return true end
  return false, reason or "Wi-Fi was not joined"
end

-- --- feeds ------------------------------------------------------------------

local function load_roots()
  local text = fs.read(FEEDS_FILE)
  local list = {}
  if text then
    for line in text:gmatch("[^\r\n]+") do
      local s = line:gsub("^%s+", ""):gsub("%s+$", "")
      if s ~= "" and s:sub(1, 1) ~= "#" then
        local title, url = s:match("^(.-)|(https?://%S+)$")
        if not url then url = s:match("^(https?://%S+)$"); title = url end
        if url then list[#list + 1] = { kind = "nav", title = title, sub = url, nav = url } end
      end
    end
  end
  if #list == 0 then
    for _, f in ipairs(DEFAULT_FEEDS) do
      list[#list + 1] = { kind = "nav", title = f.title, sub = f.url, nav = f.url }
    end
  end
  return list
end

-- Fetch url to the card cache. Returns true or nil, message.
local function fetch_feed(url, cache)
  local ok, reason = ensure_wifi()
  if not ok then return nil, "Wi-Fi: " .. tostring(reason) end
  busy("Loading feed...")
  collectgarbage()
  local r, why = http.request({ url = url, save_to = RAW })
  if not r then return nil, "Could not reach the catalogue (" .. tostring(why) .. ")" end
  if not r.ok then
    fs.remove(RAW)
    return nil, "The catalogue answered HTTP " .. tostring(r.status)
  end
  local good, ferr = opds.filter_file(fs, RAW, cache)
  fs.remove(RAW)
  if not good then return nil, tostring(ferr) end
  return true
end

-- Parse a cached (filtered) feed into a model. Returns model or nil, message.
local function parse_feed(url, cache)
  local text = fs.read(cache)
  if not text then return nil, "The cached feed is missing." end
  if #text > 65536 then
    text = nil
    return nil, "This feed is too big for the device (over 64 KB)."
  end
  local root = xml.parse(text)
  text = nil
  collectgarbage()
  if not root then return nil, "The feed is not valid XML." end
  if root.tag ~= "feed" then
    return nil, "Not an OPDS feed (the server sent <" .. tostring(root.tag) .. ">)."
  end
  local model = opds.model(root, url)
  root = nil
  collectgarbage()
  return model
end

-- Load a feed level. fresh = fetch from the network even if cached.
local function load_level(title, url, cursor, fresh)
  local cache = "data:" .. opds.cache_name(url)
  if not fresh and fs.exists(cache) then
    local model = parse_feed(url, cache)
    if model then
      return { title = model.title ~= "" and model.title or title, url = url,
               items = model.items, cursor = cursor or 1 }
    end
  end
  local ok, msg = fetch_feed(url, cache)
  if not ok then
    return { title = title, url = url, items = {}, cursor = 1, msg = msg }
  end
  local model, perr = parse_feed(url, cache)
  if not model then
    return { title = title, url = url, items = {}, cursor = 1, msg = perr }
  end
  return { title = model.title ~= "" and model.title or title, url = url,
           items = model.items, cursor = 1 }
end

-- --- navigation -------------------------------------------------------------

local function push_and_open(it)
  local prev = { title = cur.title, url = cur.url, cursor = cur.cursor }
  local nxt = load_level(it.title, it.nav, 1, true)
  if nxt.msg then
    status = nxt.msg          -- stay on this list; the footer says why
    return
  end
  stack[#stack + 1] = prev
  cur = nxt
end

local function pop()
  local frame = stack[#stack]
  stack[#stack] = nil
  if not frame then return false end
  if not frame.url then
    cur = { title = "OPDS Browser", url = nil, items = roots, cursor = frame.cursor or 1 }
    return true
  end
  local lvl = load_level(frame.title, frame.url, frame.cursor, false)
  lvl.cursor = math.min(frame.cursor or 1, math.max(1, #lvl.items))
  cur = lvl
  status = ""
  return true
end

-- --- downloads --------------------------------------------------------------

local function download(it)
  local acq = it.acq
  local name = opds.unique(SAVE_DIR, opds.filename(it.sub ~= "" and it.sub or it.title), function(p)
    return fs.exists(p)
  end)
  local path = SAVE_DIR .. name
  local vol = fs.volume()
  local need = (acq.length or 0) + 1024 * 1024
  if vol and vol.free < need then
    status = "Not enough free space on the card."
    return
  end
  local ok, reason = ensure_wifi()
  if not ok then status = "Wi-Fi: " .. tostring(reason); return end
  if not fs.exists("sd:Books") then fs.mkdir("sd:Books") end
  busy("Downloading " .. name .. "...")
  collectgarbage()
  local r, why = http.request({ url = acq.href, save_to = path })
  if not r or not r.ok then
    fs.remove(path)
    status = "Download failed: " .. tostring(why or (r and r.status) or "error")
    return
  end
  saved_path = path
  phase = "saved"
end

-- --- main loop --------------------------------------------------------------

local function activate()
  local it = cur.items[cur.cursor]
  if not it then return end
  if it.kind == "nav" then
    push_and_open(it)
  else
    download(it)
  end
end

local function draw()
  if phase == "saved" then
    draw_message({ "Saved to " .. saved_path, "Confirm: read it now.  Back: keep browsing." },
                 "Confirm: open   Back: return")
  else
    draw_list()
  end
end

local function __main()
  opds = require("opds")
  W, H = gfx.size()
  roots = load_roots()
  cur = { title = "OPDS Browser", url = nil, items = roots, cursor = 1 }
  draw()
  while true do
    local ev = input.wait()
    status = ""                  -- footer messages live until the next input
    if phase == "saved" then
      if ev == "confirm" then app.open_book(saved_path); phase = "list"
      elseif ev == "back" then phase = "list" end
    elseif ev == "back" then
      if #stack == 0 then break end
      pop()
    elseif ev == "up" then
      cur.cursor = math.max(1, cur.cursor - 1)
    elseif ev == "down" then
      cur.cursor = math.min(math.max(1, #cur.items), cur.cursor + 1)
    elseif ev == "left" then
      cur.cursor = math.max(1, cur.cursor - visible_rows())
    elseif ev == "right" then
      cur.cursor = math.min(math.max(1, #cur.items), cur.cursor + visible_rows())
    elseif ev == "confirm" then
      if #cur.items > 0 then activate() end
    end
    draw()
  end
  app.exit()
end

local ok, err = pcall(__main)
if not ok then
  gfx.clear()
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b")
  gfx.present()
  while input.wait() ~= "back" do end
  app.exit()
end
