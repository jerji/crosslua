-- AO3 metadata scraper + folder indexer. Reads every .epub in the granted
-- Books/AO3 folder, scrapes AO3's title-page metadata (words, chapters,
-- rating, warnings, fandom, updated date) and keeps a fixed-record index in
-- data:ao3.idx (format: ao3/index.lua). Files whose size has not changed are
-- skipped, so a rescan is quick. Back stops a scan safely; the index stays
-- consistent. Failures go to data:index.log. No radio, no network.

local ui = require("ui")

local M = {}

local DIR = "sd:Books/AO3"
local LOG = "data:index.log"

local force = false     -- Up toggles: re-scrape even unchanged files
local msg = ""          -- result of the last scan, shown on the menu

local function draw_menu(st, entries)
  local W, H = gfx.size()
  gfx.clear()
  ui.header("AO3 indexer")
  local y = ui.TITLE_H + 22
  local function line(s)
    gfx.text(14, y, ui.clip(s, W - 28, "sans14"), "sans14")
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
    for _, l in ipairs(gfx.wrap(msg, W - 28, "sans14")) do
      gfx.text(14, y, l, "sans14")
      y = y + 26
    end
  end
  ui.footer("OK: scan     Back: menu")
  gfx.present()
end

local function draw_progress(seen, total, cur, s)
  local W = gfx.size()
  gfx.clear()
  ui.header("AO3 indexer")
  gfx.text(14, ui.TITLE_H + 18, "Scanning Books/AO3 ...", "sans14")
  local bx, by, bw, bh = 14, ui.TITLE_H + 56, W - 28, 24
  gfx.rect(bx, by, bw, bh)
  local fw = (total > 0) and ((bw - 4) * seen // total) or 0
  if fw > 0 then gfx.rect(bx + 2, by + 2, fw, bh - 4, true, true) end
  gfx.text(14, by + 34, seen .. " / " .. total .. " entries", "ui12")
  gfx.text(14, by + 66, "New " .. s.new .. "   Changed " .. s.changed
    .. "   Unchanged " .. s.same .. "   Failed " .. s.failed, "ui12")
  gfx.text(14, by + 96, ui.clip(cur or "", W - 28, "ui12"), "ui12")
  ui.footer("Back: stop")
  gfx.present("fast")
end

local function log(name, why)
  fs.append(LOG, name .. ": " .. tostring(why) .. "\n")
end

-- One .epub entry from the folder listing. Updates the stats in s.
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
    if slot then idx.seen(st, hash) end   -- keep the old record
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

-- Walk the folder in pages. Returns stats, or nil, err.
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

-- Returns to the caller on Back.
function M.run()
  local idx = require("ao3.index")
  local st, err = idx.open()
  if not st then error(err or "cannot open data:ao3.idx") end
  force, msg = false, ""

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
      return
    end
  end
end

return M
