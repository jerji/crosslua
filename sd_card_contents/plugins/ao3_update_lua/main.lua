-- AO3 update check + download. Reads the works you track from
-- sd:Books/AO3/works.txt, checks each work's chapter count on AO3, and
-- downloads the whole work as an EPUB when chapters are new. The reading
-- percentage comes from the firmware's own progress file (epub.progress).
-- Confirm: check all works. Right: download new/missing. Back: exit.

local AO3 = require("ao3")

local STATE = "data:state.json"
local W, H = gfx.size()
local TITLE_H = 44
local ROW_H = 64
local VIS = math.max(1, math.floor((H - TITLE_H - 90) / ROW_H))

local works = {}
local state = {}
local cur, top = 1, 1
local msg = nil

local function clip(s, px, font)
  if gfx.text_width(s, font) <= px then return s end
  while #s > 0 and gfx.text_width(s .. "...", font) > px do
    local p = utf8.offset(s, -1)
    if not p then break end
    s = s:sub(1, p - 1)
  end
  return s .. "..."
end

local function save_state()
  local text = json.encode(state)
  if text then fs.write(STATE, text) end
end

local function load()
  local text, err = fs.read(AO3.LIST)
  if not text then
    msg = "No list: " .. tostring(err)
  end
  works = AO3.parse_works(text)
  local raw = fs.read(STATE)
  local st = raw and json.decode(raw)
  state = type(st) == "table" and st or {}
  for _, w in ipairs(works) do
    w.st = state[w.id] or {}
    state[w.id] = w.st
  end
end

-- A book needs downloading when it is missing or its saved copy is older
-- than the last check (got = chapters in the file we hold).
local function needs(w)
  if not w.st.total then return false end
  if not fs.exists(AO3.book_path(w.id)) then return true end
  return (w.st.got or 0) < w.st.total
end

local function status(w)
  local s = w.st
  if s.err then return "error: " .. s.err end
  local path = AO3.book_path(w.id)
  if not fs.exists(path) then
    return s.total and ("not downloaded (" .. s.total .. " ch)") or "not checked yet"
  end
  if needs(w) then
    local new = s.total - (s.got or 0)
    return "NEW: +" .. new .. " ch (" .. s.total .. " total)"
  end
  local ok, p = pcall(epub.progress, path)
  if ok and type(p) == "number" then
    return string.format("%d%% read, %d ch", math.floor(p), s.total or 0)
  end
  return (s.total or 0) .. " ch, up to date"
end

local function busy(text)
  gfx.clear()
  gfx.rect(0, 0, W, TITLE_H, true)
  gfx.text(14, 12, "AO3 updates", "ui12", "bw")
  gfx.text(16, 100, clip(text, W - 32, "sans16"), "sans16", "b")
  gfx.present()
end

local function connect()
  busy("Connecting to WiFi...")
  local ok, why = wifi.connect()
  if not ok then return false, tostring(why) end
  return true
end

local function check_all()
  if #works == 0 then
    msg = "Add works to Books/AO3/works.txt first."
    return
  end
  local ok, why = connect()
  if not ok then
    msg = "WiFi: " .. why
    return
  end
  local cancelled = false
  for i, w in ipairs(works) do
    busy(string.format("Checking %d/%d  %s", i, #works, w.st.title or w.id))
    local r, err = http.get(AO3.navigate_url(w.id), { max_body = 40960 })
    if not r then
      if err == "cancelled" then cancelled = true; break end
      w.st.err = tostring(err)
    elseif not r.ok then
      w.st.err = "HTTP " .. tostring(r.status)
    else
      local body = r.body or ""
      local n = AO3.chapter_count(body, w.id)
      w.st.total = math.max(n, 1) -- no chapter index = single-chapter work
      w.st.title = AO3.work_title(body) or w.st.title
      w.st.err = nil
    end
    r = nil
    collectgarbage()
  end
  save_state()
  msg = cancelled and "Check cancelled." or ("Checked " .. #works .. " works.")
end

local function download_new()
  local todo = {}
  for _, w in ipairs(works) do
    if needs(w) then todo[#todo + 1] = w end
  end
  if #todo == 0 then
    msg = "Nothing new. Confirm checks first."
    return
  end
  local ok, why = connect()
  if not ok then
    msg = "WiFi: " .. why
    return
  end
  local done, failed = 0, 0
  for i, w in ipairs(todo) do
    local path = AO3.book_path(w.id)
    busy(string.format("Downloading %d/%d  %s", i, #todo, w.st.title or w.id))
    -- The old copy goes first: sd: has no rename, so a failed update
    -- leaves no file and the next run re-downloads it.
    if fs.exists(path) then fs.remove(path) end
    local r, err = http.request({ url = AO3.download_url(w.id), save_to = path })
    if r and r.ok then
      w.st.got = w.st.total
      w.st.err = nil
      done = done + 1
    else
      if fs.exists(path) then fs.remove(path) end
      w.st.err = tostring(err or ("HTTP " .. tostring(r and r.status)))
      failed = failed + 1
      if err == "cancelled" then
        save_state()
        break
      end
    end
    save_state()
  end
  msg = string.format("Downloaded %d, failed %d.", done, failed)
end

local function move(d)
  cur = cur + d
  if cur < 1 then cur = #works end
  if cur > #works then cur = 1 end
  if cur < top then top = cur end
  if cur > top + VIS - 1 then top = cur - VIS + 1 end
  if top < 1 then top = 1 end
end

local function draw()
  gfx.clear()
  gfx.rect(0, 0, W, TITLE_H, true)
  gfx.text(14, 12, "AO3 updates", "ui12", "bw")
  if #works > 0 then
    gfx.text(W - 14, 12, cur .. " / " .. #works, "ui12", "bwr")
  end

  if #works == 0 then
    gfx.text(16, 100, "No works to track yet.", "sans16", "b")
    gfx.text(16, 134, "Create Books/AO3/works.txt on the card:", "ui12")
    gfx.text(16, 158, "one AO3 work id per line, e.g. 12345", "ui12")
    gfx.text(16, 182, "or  12345 | My favourite fic", "ui12")
  end

  local y = TITLE_H + 12
  for i = top, math.min(#works, top + VIS - 1) do
    local w = works[i]
    local sel = (i == cur)
    if sel then gfx.rect(8, y, W - 16, ROW_H - 8, true) end
    local fl = sel and "bw" or "b"
    local sub = sel and "w" or ""
    local name = w.label or w.st.title or ("Work " .. w.id)
    gfx.text(20, y + 6, clip(name, W - 48, "sans16"), "sans16", fl)
    gfx.text(20, y + 34, clip(status(w), W - 48, "ui12"), "ui12", sub)
    y = y + ROW_H
  end

  if msg then gfx.text(14, H - 70, clip(msg, W - 28, "ui12"), "ui12", "b") end
  gfx.text(14, H - 34, clip("Up/Down pick  Confirm: check  Right: download  Back", W - 28, "ui12"), "ui12")
end

local function __main()
  load()
  draw(); gfx.present()
  while true do
    local e = input.wait()
    if e == "back" then break
    elseif #works > 0 and e == "up" then msg = nil; move(-1)
    elseif #works > 0 and e == "down" then msg = nil; move(1)
    elseif #works > 0 and e == "confirm" then check_all()
    elseif #works > 0 and e == "right" then download_new()
    end
    draw(); gfx.present()
  end
  app.exit()
end

local ok, err = pcall(__main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
  app.exit()
end
