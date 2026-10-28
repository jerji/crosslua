-- Library grid: the firmware's full library index as a paged 3x4 grid.
-- Each cell carries a status glyph from the saved progress (epub.progress):
--   empty square = new (no progress saved), half-filled = reading,
--   filled square = finished (>= 99%). Confirm opens the book at its saved place.

local TITLE_H = 44
local COLS, ROWS = 3, 4
local PER = COLS * ROWS
local PAD = 8
local CELL_H = 160
local GRID_Y = TITLE_H + 8
local GLYPH = 16

local W, H = gfx.size()
local CELL_W = math.floor((W - 2 * PAD) / COLS)

local total = 0
local items = {}
local cur_page = -1
local sel = 1
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

local function status_of(pct)
  if pct == nil then return 0 end
  if pct >= 99 then return 2 end
  return 1
end

-- Load page p (0-based) of the library index into `items`.
local function load_page(p)
  local ok, lst, tot = pcall(epub.library, p * PER, PER)
  if not ok then
    msg = "Library error: " .. tostring(lst)
    items = {}
    return
  end
  if not lst then
    msg = tostring(tot or "library index unavailable")
    items = {}
    total = 0
    cur_page = p
    return
  end
  total = tonumber(tot) or total
  items = {}
  for i, b in ipairs(lst) do
    local pct = nil
    local ok2, v = pcall(epub.progress, b.path)
    if ok2 and type(v) == "number" then pct = math.floor(v) end
    items[i] = {
      path = b.path,
      title = (b.title and b.title ~= "") and b.title or "(untitled)",
      author = b.author or "",
      pct = pct,
      st = status_of(pct),
    }
  end
  cur_page = p
end

local function ensure_page()
  local p = (sel - 1) // PER
  if p ~= cur_page then load_page(p) end
end

-- Draw the status glyph at (x, y). `ink` = true for black marks.
local function glyph(x, y, st, ink)
  gfx.rect(x, y, GLYPH, GLYPH, false, ink)
  if st == 2 then
    gfx.rect(x, y, GLYPH, GLYPH, true, ink)
  elseif st == 1 then
    gfx.rect(x, y + GLYPH // 2, GLYPH, GLYPH // 2, true, ink)
  end
end

local function draw_cell(i, b, x, y)
  local w, h = CELL_W - 6, CELL_H - 10
  local here = (sel == (cur_page * PER + i))
  if here then
    gfx.rect(x, y, w, h, true, true)
  else
    gfx.rect(x, y, w, h, false, true)
  end
  local ink = not here
  local flags = here and "bw" or "b"
  local sub = here and "w" or ""
  glyph(x + 6, y + 6, b.st, ink)

  local lines = gfx.wrap(b.title, w - 12, "ui12", "b")
  local lh = gfx.line_height("ui12")
  local ty = y + 28
  for n = 1, math.min(#lines, 3) do
    local line = lines[n]
    if n == 3 and #lines > 3 then line = clip(line, w - 12, "ui12") end
    gfx.text(x + 6, ty, line, "ui12", flags)
    ty = ty + lh
  end

  if b.author ~= "" then
    gfx.text(x + 6, y + h - 42, clip(b.author, w - 12, "ui12"), "ui12", sub)
  end
  local status = (b.pct == nil) and "new" or (tostring(b.pct) .. "%")
  gfx.text(x + 6, y + h - 22, status, "ui12", sub)
end

local function draw()
  gfx.clear()
  gfx.rect(0, 0, W, TITLE_H, true)
  gfx.text(14, 12, "Library", "ui12", "bw")
  if total > 0 then
    gfx.text(W - 14, 12, sel .. " / " .. total, "ui12", "bwr")
  end

  if total == 0 and not msg then
    gfx.text(16, 100, "The library is empty.", "sans16", "b")
    gfx.text(16, 134, "Open the Library once to index your books.", "ui12")
  end

  for i = 1, #items do
    local c = (i - 1) % COLS
    local r = (i - 1) // COLS
    draw_cell(i, items[i], PAD + c * CELL_W, GRID_Y + r * CELL_H)
  end

  if msg then gfx.text(14, H - 106, clip(msg, W - 28, "ui12"), "ui12", "b") end
  gfx.text(14, H - 80, "Glyph: empty=new  half=reading  filled=finished", "ui12")
  gfx.text(14, H - 30, "Arrows: move   Confirm: open   Back: exit", "ui12")
end

local function __main()
  load_page(0)
  draw(); gfx.present()
  while true do
    local e = input.wait()
    if e == "back" then break end
    if total > 0 then
      local old = sel
      if e == "left" then sel = math.max(1, sel - 1)
      elseif e == "right" then sel = math.min(total, sel + 1)
      elseif e == "up" then sel = math.max(1, sel - COLS)
      elseif e == "down" then sel = math.min(total, sel + COLS)
      elseif e == "confirm" then
        local b = items[(sel - 1) % PER + 1]
        if b then
          -- open_book parks this app and never returns on success.
          local ok, err = app.open_book(b.path)
          msg = "Could not open: " .. tostring(err or (not ok and "unknown error"))
        end
      end
      if sel ~= old then
        msg = nil
        ensure_page()
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
