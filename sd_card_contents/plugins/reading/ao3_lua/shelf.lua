-- The ereader's recent-books shelf with saved progress, in two modes:
--   "continue": Confirm resumes the picked book in the reader at its saved place.
--   "qr":       Confirm shows the picked book's saved reading position as a QR code.
-- epub.recent() is the shelf (most recent first); epub.progress() is the saved
-- percent. The QR shows the position as of your last exit from the book.

local ui = require("ui")

local M = {}

local MAX_ROWS = 10
local ROW_H = 68
local MAX_PAYLOAD = 180

local function load_shelf()
  local ok, list = pcall(epub.recent)
  if not ok or type(list) ~= "table" then list = {} end
  local books = {}
  for i = 1, math.min(#list, MAX_ROWS) do
    local b = list[i]
    local pct = nil
    local ok2, p = pcall(epub.progress, b.path)
    if ok2 and type(p) == "number" then pct = math.floor(p) end
    local title = b.title or ""
    local author = b.author or ""
    books[#books + 1] = {
      path = b.path,
      title = (title ~= "") and title or "(untitled)",
      author = author,
      pct = pct,
    }
  end
  return books
end

-- The QR payload: one line, short enough to scan quickly.
local function payload(b)
  local pct = b.pct and (b.pct .. "%") or "no saved position"
  local who = (b.author ~= "") and (b.title .. " - " .. b.author) or b.title
  return ui.clip_bytes("Reading position: " .. who .. " (" .. pct .. ")", MAX_PAYLOAD)
end

local function draw_list(mode, books, cur)
  local W, H = gfx.size()
  gfx.clear()
  local title = (mode == "qr") and "Page as QR" or "Continue reading"
  ui.header(title, (#books > 0) and (cur .. " / " .. #books) or nil)
  if #books == 0 then
    gfx.text(16, 100, "No books on the shelf yet.", "sans16", "b")
    gfx.text(16, 134, "Open a book in the reader, then come back here.", "ui12")
  end
  local y = ui.TITLE_H + 16
  for i, b in ipairs(books) do
    local sel = (i == cur)
    if sel then gfx.rect(8, y, W - 16, ROW_H - 8, true, true) end
    local flags = sel and "bw" or "b"
    local sub = sel and "w" or ""
    gfx.text(20, y + 8, ui.clip(b.title, W - 48, "sans16", flags), "sans16", flags)
    local prog = b.pct and string.format("%d%% read", b.pct) or "no progress saved"
    local line2 = (b.author ~= "") and (b.author .. "  -  " .. prog) or prog
    gfx.text(20, y + 36, ui.clip(line2, W - 48, "ui12", sub), "ui12", sub)
    y = y + ROW_H
  end
  if mode == "qr" then
    ui.footer("Up/Down: pick   Confirm: make QR   Back: menu")
  else
    ui.footer("Up/Down: pick   Confirm: open   Back: menu")
  end
end

local function draw_qr(b)
  local W, H = gfx.size()
  gfx.clear()
  ui.header("Reading position")
  local side = math.min(W - 40, H - 200)
  local text = payload(b)
  local x = math.floor((W - side) / 2)
  local ok = gfx.qr(text, x, ui.TITLE_H + 16, side)
  local y = ui.TITLE_H + 16 + side + 16
  gfx.text(16, y, ui.clip(b.title, W - 32, "sans16", "b"), "sans16", "b")
  y = y + 28
  if b.author ~= "" then
    gfx.text(16, y, ui.clip(b.author, W - 32, "ui12"), "ui12")
    y = y + 22
  end
  local pct = b.pct and string.format("Saved position: %d%%", b.pct) or "No saved position yet"
  gfx.text(16, y, pct, "ui12", "b")
  y = y + 24
  gfx.text(16, y, "Saved when you leave the book, not live.", "ui12")
  if not ok then
    gfx.text(16, y + 28, "This position is too long for a QR code.", "ui12", "b")
  end
  ui.footer("Back: return to the shelf")
end

-- mode = "continue" or "qr". Returns on Back.
function M.run(mode)
  local books = load_shelf()
  local cur, view, msg = 1, "list", nil
  local function draw()
    if view == "qr" and books[cur] then draw_qr(books[cur]) else draw_list(mode, books, cur) end
    if msg then gfx.text(14, gfx.size() - 56, ui.clip(msg, gfx.size() - 28, "ui12"), "ui12", "b") end
  end
  draw(); gfx.present()
  while true do
    local e = input.wait()
    if view == "qr" then
      if e == "back" or e == "confirm" then view = "list" end
    elseif e == "back" then
      return
    elseif #books > 0 and e == "up" then
      cur = (cur > 1) and (cur - 1) or #books
      msg = nil
    elseif #books > 0 and e == "down" then
      cur = (cur < #books) and (cur + 1) or 1
      msg = nil
    elseif #books > 0 and e == "confirm" then
      if mode == "qr" then
        view = "qr"
        msg = nil
      else
        -- open_book parks this app and never returns on success.
        local ok, err = app.open_book(books[cur].path)
        msg = "Could not open: " .. tostring(err or (not ok and "unknown error"))
      end
    end
    draw(); gfx.present()
  end
end

return M
