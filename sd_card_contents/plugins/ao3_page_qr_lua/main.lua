-- Page-as-QR: pick a recent book and show its saved reading position as a QR code.
-- Read-only: epub.recent() gives the shelf, epub.progress() gives the saved percent.
-- The firmware keeps progress per book (it is written when you leave the book), so the
-- QR shows the position as of your last exit, not the page you are on right now.

local TITLE_H = 44
local ROW_H = 60
local MAX_ROWS = 10
local MAX_PAYLOAD = 180

local W, H = gfx.size()
local books = {}
local cur = 1
local view = "list"   -- "list" or "qr"
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

-- Shorten a UTF-8 string to at most `n` bytes without cutting a character.
local function cut_bytes(s, n)
  if #s <= n then return s end
  local p = utf8.offset(s, n + 1)
  if not p then return s:sub(1, n) end
  return s:sub(1, p - 1)
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

-- The QR payload: one line, short enough to scan quickly.
local function payload(b)
  local pct = b.pct and (b.pct .. "%") or "no saved position"
  local who = (b.author ~= "") and (b.title .. " - " .. b.author) or b.title
  return cut_bytes("Reading position: " .. who .. " (" .. pct .. ")", MAX_PAYLOAD)
end

local function draw_list()
  gfx.clear()
  gfx.rect(0, 0, W, TITLE_H, true)
  gfx.text(14, 12, "Page as QR", "ui12", "bw")
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
    gfx.text(20, y + 6, clip(b.title, W - 48, "sans16"), "sans16", flags)
    local prog = b.pct and string.format("%d%% read", b.pct) or "no progress saved"
    gfx.text(20, y + 32, clip(prog, W - 48, "ui12"), "ui12", sub_flags)
    y = y + ROW_H
  end
  if msg then gfx.text(14, H - 56, clip(msg, W - 28, "ui12"), "ui12", "b") end
  gfx.text(14, H - 30, "Up/Down: pick   Confirm: make QR   Back: exit", "ui12")
end

local function draw_qr()
  local b = books[cur]
  gfx.clear()
  gfx.rect(0, 0, W, TITLE_H, true)
  gfx.text(14, 12, "Reading position", "ui12", "bw")
  local side = math.min(W - 40, H - 200)
  local text = payload(b)
  local x = math.floor((W - side) / 2)
  local ok = gfx.qr(text, x, TITLE_H + 16, side)
  local y = TITLE_H + 16 + side + 16
  gfx.text(16, y, clip(b.title, W - 32, "sans16"), "sans16", "b")
  y = y + 28
  if b.author ~= "" then
    gfx.text(16, y, clip(b.author, W - 32, "ui12"), "ui12")
    y = y + 22
  end
  local pct = b.pct and string.format("Saved position: %d%%", b.pct) or "No saved position yet"
  gfx.text(16, y, pct, "ui12", "b")
  y = y + 24
  gfx.text(16, y, "Saved when you leave the book, not live.", "ui12")
  if not ok then
    gfx.text(16, y + 28, "This position is too long for a QR code.", "ui12", "b")
  end
  gfx.text(14, H - 30, "Back: return to the shelf", "ui12")
end

local function draw()
  if view == "qr" then draw_qr() else draw_list() end
end

local function __main()
  load_shelf()
  draw(); gfx.present()
  while true do
    local e = input.wait()
    if view == "qr" then
      if e == "back" or e == "confirm" then view = "list" end
    else
      if e == "back" then break
      elseif #books > 0 and e == "up" then
        cur = (cur > 1) and (cur - 1) or #books
        msg = nil
      elseif #books > 0 and e == "down" then
        cur = (cur < #books) and (cur + 1) or 1
        msg = nil
      elseif #books > 0 and e == "confirm" then
        view = "qr"
        msg = nil
      end
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
