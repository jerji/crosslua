-- AO3 metadata scraper + folder indexer. Reads every .epub in the granted
-- Books/AO3 folder, scrapes AO3's title-page metadata (words, chapters,
-- rating, warnings, fandom, updated date) and keeps a fixed-record index in
-- data:ao3.idx (format: ao3/index.lua). Files whose size has not changed are
-- skipped, so a rescan is quick. Back stops a scan safely; the index stays
-- consistent. Failures go to data:index.log. No radio, no network.

local DIR = "sd:Books/AO3"
local LOG = "data:index.log"
local HEAD_H, FOOT_H, MARGIN = 46, 34, 12

local W, H = 0, 0
local force = false     -- Up toggles: re-scrape even unchanged files
local msg = ""          -- result of the last scan, shown on the menu

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
  gfx.text(MARGIN, 13, title, "sans16", "bw")
end

local function footer(hint)
  gfx.rect(0, H - FOOT_H, W, 1, true, true)
  gfx.text(MARGIN, H - FOOT_H + 9, fit(hint, W - 2 * MARGIN, "ui12", "b"), "ui12", "b")
end

local function draw_menu(st, entries)
  gfx.clear()
  header("AO3 Indexer")
  local y = HEAD_H + 22
  local function line(s)
    gfx.text(MARGIN, y, fit(s, W - 2 * MARGIN, "sans14", ""), "sans14")
    y = y + 30
  end
  line("Folder: Books/AO3")
  if entries then
    line("Entries in folder: " .. entries)
  else
    line("Folder not found. Create Books/AO3 and copy AO3 EPUBs in.")
  end
  line("Indexed books: " .. st.live)
  line("Force rescan: " .. (force and "ON" or "off") .. "   (Up toggles)")
  if msg ~= "" then
    y = y + 14
    for _, l in ipairs(gfx.wrap(msg, W - 2 * MARGIN, "sans14")) do
      gfx.text(MARGIN, y, l, "sans14")
      y = y + 26
    end
  end
  footer("OK: scan     Back: exit")
  gfx.present()
end

local function draw_progress(seen, total, cur, s)
  gfx.clear()
  header("AO3 Indexer")
  gfx.text(MARGIN, HEAD_H + 18, "Scanning Books/AO3 ...", "sans14")
  local bx, by, bw, bh = MARGIN, HEAD_H + 56, W - 2 * MARGIN, 24
  gfx.rect(bx, by, bw, bh)
  local fw = (total > 0) and ((bw - 4) * seen // total) or 0
  if fw > 0 then gfx.rect(bx + 2, by + 2, fw, bh - 4, true, true) end
  gfx.text(MARGIN, by + 34, seen .. " / " .. total .. " entries", "ui12")
  gfx.text(MARGIN, by + 66, "New " .. s.new .. "   Changed " .. s.changed
    .. "   Unchanged " .. s.same .. "   Failed " .. s.failed, "ui12")
  gfx.text(MARGIN, by + 96, fit(cur or "", W - 2 * MARGIN, "ui12", ""), "ui12")
  footer("Back: stop")
  gfx.present("fast")
end

local function log(name, why)
  fs.append(LOG, name .. ": " .. tostring(why) .. "\n")
end

-- One .epub entry from the folder listing. Returns nothing; updates stats.
local function index_one(st, idx, scrape, e, s)
  local name = e.name
  local path = DIR .. "/" .. name
  local hash = idx.fnv1a(path)   -- path is "sd:Books/AO3/<name>"
  local slot = idx.entry(st, hash)

  if slot and not force and idx.size_of(st, slot) == e.size then
    idx.seen(st, hash)
    s.same = s.same + 1
    return
  end

  local function fail(why)
    log(name, why)
    s.failed = s.failed + 1
    if slot then idx.seen(st, hash) end   -- keep the old record, like the native indexer
  end

  if #name > 96 then return fail("file name longer than 96 bytes") end

  local stem = (name:gsub("%.[Ee][Pp][Uu][Bb]$", ""))
  local meta, why = scrape.scrape(path, stem)
  if not meta then return fail(why) end

  meta.hash, meta.size, meta.name = hash, e.size, name
  local ok, perr = idx.put(st, hash, slot, idx.pack(meta))
  if not ok then return fail(perr) end
  if slot then s.changed = s.changed + 1 else s.new = s.new + 1 end
end

-- Walk the folder in pages. Returns stats, aborted, or nil, err.
local function scan(st)
  local idx = require("ao3.index")
  local scrape = require("ao3.scrape")
  local _, total = fs.list(DIR, { detail = true, limit = 1 })
  if type(total) ~= "number" then return nil, tostring(total) end

  if (fs.size(LOG) or 0) > 8192 then fs.remove(LOG) end
  local s = { new = 0, changed = 0, same = 0, failed = 0 }
  local seen, offset, aborted = 0, 0, false
  draw_progress(0, total, "", s)

  while true do
    local items, err = fs.list(DIR, { detail = true, offset = offset, limit = 32 })
    if not items then return nil, tostring(err) end
    for _, e in ipairs(items) do
      seen = seen + 1
      if not e.dir and e.name:lower():sub(-5) == ".epub" then
        index_one(st, idx, scrape, e, s)
        collectgarbage()
      end
      if seen % 4 == 0 then draw_progress(seen, total, e.name, s) end
      if input.poll() == "back" then aborted = true; break end
    end
    if aborted or #items < 32 then break end
    offset = offset + 32
  end

  -- Only a complete walk may tombstone records; a stopped one would
  -- wrongly drop the books it never reached.
  if not aborted then s.removed = idx.prune(st) else s.removed = 0 end
  s.aborted = aborted
  return s
end

local function summary(s)
  local head = s.aborted and "Scan stopped (Back). Index kept as far as it got. "
    or "Scan done. "
  local tail = string.format("New %d, changed %d, unchanged %d, failed %d, removed %d.",
    s.new, s.changed, s.same, s.failed, s.removed)
  if s.failed > 0 then tail = tail .. " Failures: data:index.log" end
  return head .. tail
end

local function __main()
  W, H = gfx.size()
  local idx = require("ao3.index")
  local st, err = idx.open()
  if not st then error(err or "cannot open data:ao3.idx") end

  while true do
    local items, total = fs.list(DIR, { detail = true, limit = 1 })
    draw_menu(st, items and total or nil)
    local ev = input.wait()
    if ev == "up" then
      force = not force
      msg = ""
    elseif ev == "confirm" then
      local s, e2 = scan(st)
      msg = s and summary(s) or ("Scan failed: " .. tostring(e2))
    elseif ev == "back" then
      break
    end
  end
  app.exit()
end

local ok, err = pcall(__main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
  app.exit()
end
