-- Continue reading: the ereader's own recent-books shelf, with saved progress.
-- epub.recent() gives the reading history (most recent first); epub.progress()
-- gives each book's saved percent. Confirm opens the selected book in the reader
-- at its saved place. The top entry is the book you were last reading.

local TITLE_H = 44
local ROW_H = 72
local MAX_ROWS = 10

local W, H = gfx.size()
local books = {}
local cur = 1
local msg = nil

-- Cut a UTF-8 string to fit `px` pixels, adding "..." when cut.
local function clip(s, px, font)
  if gfx.text_width(s, font) <= px then return s end
  while #s > 0 and gfx.text_width(s .. "...", font) > px do
    local p = utf8.offset(s, -1)
    if not p then break end
    s = s:sub(1, p - 1)
  end
  return s .. "..."
end

local function load_shelf()
  local ok, list = pcall(epub.recent)
  if not ok or type(list) ~= "table" then list = {} end
  for i = 1, math.min(#list, MAX_ROWS) do
    local b = list[i]
    local pct = nil
    local ok2, p = pcall(epub.progress, b.path)
    if ok2 and type(p) == "number" then pct = math.floor(p) end
    books[#books + 1] = {
      path = b.path,
      title = (b.title ~= "" and b.title) or "(untitled)",
      author = b.author or "",
      pct = pct,
    }
  end
end

local function draw()
  gfx.clear()
  gfx.rect(0, 0, W, TITLE_H, true)
  gfx.text(14, 12, "Continue reading", "ui12", "bw")
  if #books > 0 then
    gfx.text(W - 14, 12, cur .. " / " .. #books, "ui12", "bwr")
  end

  if #books == 0 then
    gfx.text(16, 100, "No books on the shelf yet.", "sans16", "b")
    gfx.text(16, 134, "Open a book in the reader, then come back here.", "ui12")
  end

  local y = TITLE_H + 16
  for i, b in ipairs(books) do
    local sel = (i == cur)
    if sel then gfx.rect(8, y, W - 16, ROW_H - 8, true) end
    local flags = sel and "bw" or "b"
    local sub_flags = sel and "w" or ""
    gfx.text(20, y + 8, clip(b.title, W - 48, "sans16"), "sans16", flags)
    local prog = b.pct and (string.format("%d%% read", b.pct)) or "no progress saved"
    local line2 = (b.author ~= "") and (b.author .. "  -  " .. prog) or prog
    gfx.text(20, y + 36, clip(line2, W - 48, "ui12"), "ui12", sub_flags)
    y = y + ROW_H
  end

  if msg then gfx.text(14, H - 56, clip(msg, W - 28, "ui12"), "ui12", "b") end
  gfx.text(14, H - 30, "Up/Down: pick   Confirm: open   Back: exit", "ui12")
end

local function __main()
  load_shelf()
  draw(); gfx.present()
  while true do
    local e = input.wait()
    if e == "back" then break
    elseif #books > 0 and e == "up" then
      cur = (cur > 1) and (cur - 1) or #books
      msg = nil
    elseif #books > 0 and e == "down" then
      cur = (cur < #books) and (cur + 1) or 1
      msg = nil
    elseif #books > 0 and e == "confirm" then
      -- open_book parks this app and never returns on success.
      local ok, err = app.open_book(books[cur].path)
      msg = "Could not open: " .. tostring(err or (not ok and "unknown error"))
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
