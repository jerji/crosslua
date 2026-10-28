-- Picross (nonograms). Puzzles are NOT shipped with this app. The bank is a text file the user puts on the card at
--   Picross/puzzles.txt   (storage read grant on the folder Picross)
-- Format, one block per puzzle (blank lines between blocks are fine):
--   T <title>            the title is the puzzle name shown on the win screen
--   S <n>                square size, n rows of n characters
--   then n lines of n characters, '1' = solid cell, '0' = empty
-- Rule (crossplay docs/apps/picross.md, the classic rule): FILL a solid cell -> filled. FILL an empty cell -> MISTAKE,
-- locks in as an asterisk and is counted. MARK = free annotation, never a mistake, reversible.
-- Controls: up/down/left/right move the cursor. The top row is the MODE line: confirm there toggles FILL/MARK.
-- Confirm on a board cell acts with the current mode. Back returns to the picker; Back in the picker exits.

local W, H = 0, 0
local BANK_PATH = "sd:Picross/puzzles.txt"
local MAX_SIZE = 15

local function clip(s, n) return #s > n and s:sub(1, n) or s end

-- ---------- bank parsing ----------
local function parse_bank(text)
  local list = {}
  local cur = nil
  local rows_needed = 0
  for line in text:gmatch("[^\n]+") do
    line = line:gsub("\r$", "")
    local t = line:match("^T%s+(.+)$")
    local s = line:match("^S%s+(%d+)$")
    if t then cur = { title = t, rows = {} }; rows_needed = 0
    elseif s and cur then
      cur.size = tonumber(s)
      if cur.size >= 1 and cur.size <= MAX_SIZE then rows_needed = cur.size; cur.rows = {}
      else cur = nil end
    elseif cur and rows_needed > 0 and line:match("^[01]+$") and #line == cur.size then
      cur.rows[#cur.rows + 1] = line
      if #cur.rows == cur.size then
        list[#list + 1] = cur
        cur = nil; rows_needed = 0
      end
    end
  end
  table.sort(list, function(a, b)
    if a.size ~= b.size then return a.size < b.size end
    return a.title < b.title
  end)
  return list
end

-- ---------- clues (derived from the solution; they cannot disagree with it) ----------
local function runs(bits)
  local out, n = {}, 0
  for i = 1, #bits do
    if bits:sub(i, i) == "1" then n = n + 1
    elseif n > 0 then out[#out + 1] = n; n = 0 end
  end
  if n > 0 then out[#out + 1] = n end
  if #out == 0 then out[1] = 0 end
  return out
end

local function make_clues(p)
  local n = p.size
  p.row_clue, p.col_clue = {}, {}
  for r = 1, n do p.row_clue[r] = runs(p.rows[r]) end
  for c = 1, n do
    local col = {}
    for r = 1, n do col[r] = p.rows[r]:sub(c, c) end
    p.col_clue[c] = runs(table.concat(col))
  end
  p.solid = 0
  for r = 1, n do for c = 1, n do if p.rows[r]:sub(c, c) == "1" then p.solid = p.solid + 1 end end end
end

-- ---------- board state ----------
-- state[r][c]: 0 blank, 1 filled (correct), 2 mistake (locked), 3 marked (free)
local function new_board(p)
  local b = { state = {}, mistakes = 0, filled = 0 }
  for r = 1, p.size do b.state[r] = {} for c = 1, p.size do b.state[r][c] = 0 end end
  return b
end

local function is_solid(p, r, c) return p.rows[r]:sub(c, c) == "1" end

local function fill(p, b, r, c)
  local s = b.state[r][c]
  if s == 1 or s == 2 then return end
  if is_solid(p, r, c) then
    b.state[r][c] = 1; b.filled = b.filled + 1
  else
    b.state[r][c] = 2; b.mistakes = b.mistakes + 1
  end
end

local function mark(p, b, r, c)
  local s = b.state[r][c]
  if s == 1 or s == 2 then return end  -- a filled or mistake cell is not an annotation target
  b.state[r][c] = (s == 3) and 0 or 3
end

local function won(p, b) return b.filled == p.solid end

local function row_done(p, b, r)
  local f = 0
  for c = 1, p.size do if b.state[r][c] == 1 then f = f + 1 end end
  local solid = 0
  for c = 1, p.size do if is_solid(p, r, c) then solid = solid + 1 end end
  return f == solid
end

local function col_done(p, b, c)
  local f, solid = 0, 0
  for r = 1, p.size do
    if b.state[r][c] == 1 then f = f + 1 end
    if is_solid(p, r, c) then solid = solid + 1 end
  end
  return f == solid
end

-- ---------- drawing ----------
local function draw_board(p, b, cur, mode, note)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, clip(p.title, 30), "ui12", "bw")
  local n = p.size
  local gut_w = 70
  local gut_h = 90
  local cell = math.min((W - gut_w - 10) // n, (H - 40 - gut_h - 90) // n)
  if cell < 8 then cell = 8 end
  local ox = gut_w
  local oy = 40 + gut_h + 10
  -- mode row (cursor row 0)
  local mode_label = "MODE: " .. (mode == "fill" and "FILL" or "MARK") .. (cur.r == 0 and "  <" or "")
  gfx.text(14, 44, mode_label, "ui12", cur.r == 0 and "b" or nil)
  -- column clues
  for c = 1, n do
    local cl = p.col_clue[c]
    local done = col_done(p, b, c)
    for i, v in ipairs(cl) do
      gfx.text(ox + (c - 1) * cell + 4, oy - 14 * (#cl - i + 1) - 2, tostring(v), "small")
    end
  end
  -- row clues and grid
  for r = 1, n do
    local rc = p.row_clue[r]
    local done = row_done(p, b, r)
    local line = table.concat(rc, " ")
    gfx.text(4, oy + (r - 1) * cell + 4, clip(line, 9), "small")
    for c = 1, n do
      local x = ox + (c - 1) * cell
      local y = oy + (r - 1) * cell
      local st = b.state[r][c]
      gfx.rect(x, y, cell, cell, false)
      if st == 1 then gfx.rect(x + 2, y + 2, cell - 4, cell - 4, true)
      elseif st == 2 then gfx.text(x + cell // 2 - 4, y + cell // 2 - 8, "*", "ui12")
      elseif st == 3 then gfx.text(x + cell // 2 - 4, y + cell // 2 - 8, "x", "small") end
      if cur.r == r and cur.c == c then gfx.rect(x, y, cell, cell, false); gfx.rect(x + 1, y + 1, cell - 2, cell - 2, false) end
    end
  end
  gfx.text(14, H - 60, note or "", "small")
  gfx.text(14, H - 34, "Up/Down/Left/Right move, Confirm acts, Back exits", "small")
  gfx.present()
end

local function draw_picker(list, sel, msg)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Picross", "ui12", "bw")
  if #list == 0 then
    gfx.text(14, 80, "No puzzles found.", "ui12")
    gfx.text(14, 110, "Put puzzles.txt in the Picross folder on the card.", "small")
    gfx.text(14, 130, "Format: T <title> / S <n> / n rows of 0 and 1.", "small")
  else
    local y = 60
    for i, p in ipairs(list) do
      if i > 14 then break end
      local label = string.format("%dx%d  %s", p.size, p.size, clip(p.title, 32))
      if i == sel then gfx.rect(10, y - 4, W - 20, 30, true); gfx.text(16, y, label, "ui12", "w")
      else gfx.text(16, y, label, "ui12") end
      y = y + 32
    end
  end
  gfx.text(14, H - 60, msg or "", "small")
  gfx.text(14, H - 34, "Up/Down choose, Confirm open, Back exits", "small")
  gfx.present()
end

local function read_bank()
  local text = fs.read(BANK_PATH)
  if not text then return {} end
  local list = parse_bank(text)
  for _, p in ipairs(list) do make_clues(p) end
  return list
end

local function play(p)
  local b = new_board(p)
  local n = p.size
  local cur = { r = 1, c = 1 }
  local mode = "fill"
  local note = ""
  draw_board(p, b, cur, mode, note)
  while true do
    local e = input.wait()
    if e == "back" then return end
    if e == "up" then
      if cur.r > 0 then cur.r = cur.r - 1 else cur.r = n end
      note = ""
    elseif e == "down" then
      if cur.r < n then cur.r = cur.r + 1 else cur.r = 0 end
      note = ""
    elseif e == "left" then
      if cur.r > 0 then cur.c = cur.c > 1 and cur.c - 1 or n end
      note = ""
    elseif e == "right" then
      if cur.r > 0 then cur.c = cur.c < n and cur.c + 1 or 1 end
      note = ""
    elseif e == "confirm" then
      if cur.r == 0 then
        mode = (mode == "fill") and "mark" or "fill"
        note = "mode: " .. mode
      elseif mode == "fill" then
        fill(p, b, cur.r, cur.c)
        if b.state[cur.r][cur.c] == 2 then note = "mistake (counted: " .. b.mistakes .. ")"
        else note = "" end
      else
        mark(p, b, cur.r, cur.c)
        note = ""
      end
      if won(p, b) then
        draw_board(p, b, cur, mode, "Solved: " .. p.title .. ". Back to pick another.")
        while input.wait() ~= "back" do end
        return
      end
    end
    draw_board(p, b, cur, mode, note)
  end
end

local ok, err = pcall(function()
  W, H = gfx.size()
  local list = read_bank()
  local sel = 1
  draw_picker(list, sel, "")
  while true do
    local e = input.wait()
    if e == "back" then break
    elseif e == "up" and #list > 0 then sel = sel > 1 and sel - 1 or #list
    elseif e == "down" and #list > 0 then sel = sel < #list and sel + 1 or 1
    elseif e == "confirm" and #list > 0 then play(list[sel])
    end
    draw_picker(list, sel, "")
  end
end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
