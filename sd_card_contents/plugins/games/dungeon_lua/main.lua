-- D&Diagrams (dungeon) for CrossLua - ported from crossplay (docs/apps/dungeon.md,
-- src/apps_local/dungeon). The 64 campaign dungeons plus the tutorial come from
-- DungeonPuzzles.h, converted into bank.txt: a data file, not code. Crossplay
-- verified every puzzle has exactly one solution on the host, so the device
-- renders the grid and names and compares the placed walls against the stored
-- solution - no solver, no rule engine on device (see DungeonCore.h's note).
--
-- Screens: the campaign map (the menu), the board, the win screen, and the
-- 8-page adventurer's guide that teaches on the tutorial. The tutorial itself
-- is never a level, exactly like the C++ (`kCampaignFirst`).
--
-- Controls (7 buttons, no touch): menu - arrows move the 8x8 map, Confirm
-- opens; Down from the last row reaches PLAY/RESUME and TUTORIAL. Board -
-- arrows move the cursor, Confirm cycles Unknown -> Wall -> Floor -> Unknown
-- (monster/chest cells are floor by definition and refuse), Down reaches
-- CLEAR/DUNGEONS. Back goes up a level; Back on the menu quits. Holding Back
-- always quits.
--
-- Deviations from the C++, all render-only: monster/chest tiles are ASCII
-- glyphs (the C++ ships 36px icon bitmaps); a clue over its count gets an
-- outlined chip instead of a dither fill; and the touch targets became
-- keypad focus zones. Progress and the in-progress board persist to
-- data:dungeon_progress.txt, the Lua stand-in for the C++ NVS save. No
-- permissions: nothing here touches the radio, and app:/data: need none.

local bank = require("bank")

local W, H = 0, 0
local P = {}              -- puzzles; P[1] = the tutorial, P[k+1] = campaign k
local SOLVED = {}         -- SOLVED[k] = true for campaign k (1..64)
local RESUME = nil        -- { idx = k, walls = bytes, floors = bytes }
local SAVE_FILE = "data:dungeon_progress.txt"
local ZERO8 = string.rep("\0", 8)

local GLYPHS = { "S", "G", "B", "W", "A", "*", "O", "X" } -- skull ghost bug worm bird flame eye bone
local CHEST = "C"

local STATE = {
  sel = 0, zone = "grid", bzone = 1,   -- menu
  p = nil, k = 0, brow = 0, bcol = 0,  -- board (k = campaign index)
  walls = nil, floors = nil,
  page = 1,                            -- guide 1..8
  wb = 1, winmore = false,             -- win
}

-- ---------------------------------------------------------------------------
-- small drawing helpers

local function lineh(font) return gfx.line_height(font) end

local function ctext(cx, y, s, font, flags)
  gfx.text(cx - gfx.text_width(s, font) / 2, y, s, font, flags)
end

local function header(title, right)
  gfx.rect(0, 0, W, 40, true)
  local y = 20 - lineh("ui12") / 2
  gfx.text(14, y, title, "ui12", "bw")
  if right then gfx.text(W - 14 - gfx.text_width(right, "ui12"), y, right, "ui12", "bw") end
end

-- Four corner marks around a rect; the port's selection mark.
local function brackets(x, y, w, h, arm, r)
  gfx.rect(x, y, arm, r, true)
  gfx.rect(x, y, r, arm, true)
  gfx.rect(x + w - arm, y, arm, r, true)
  gfx.rect(x + w - r, y, r, arm, true)
  gfx.rect(x, y + h - r, arm, r, true)
  gfx.rect(x, y + h - arm, r, arm, true)
  gfx.rect(x + w - arm, y + h - r, arm, r, true)
  gfx.rect(x + w - r, y + h - arm, r, arm, true)
end

local function btn(x, y, w, h, label, on)
  if on then
    gfx.rounded_rect(x, y, w, h, 12, true)
    ctext(x + w / 2, y + (h - lineh("ui12")) / 2, label, "ui12", "bw")
  else
    gfx.rounded_rect(x, y, w, h, 12, false)
    ctext(x + w / 2, y + (h - lineh("ui12")) / 2, label, "ui12", "b")
  end
end

-- ---------------------------------------------------------------------------
-- 64-bit masks as 8-byte strings; bit = r*8+c

local function bit_test(m, bit)
  return (m:byte(bit // 8 + 1) >> (bit % 8)) & 1 == 1
end

local function bit_set(m, bit)
  local i = bit // 8 + 1
  return m:sub(1, i - 1) .. string.char(m:byte(i) | (1 << (bit % 8))) .. m:sub(i + 1)
end

local function bit_clear(m, bit)
  local i = bit // 8 + 1
  return m:sub(1, i - 1) .. string.char(m:byte(i) & ~(1 << (bit % 8))) .. m:sub(i + 1)
end

local function popcount8(b)
  local n = 0
  while b > 0 do b = b & (b - 1); n = n + 1 end
  return n
end

local function row_walls(w, size, r)
  return popcount8(w:byte(r + 1) & ((1 << size) - 1))
end

local function col_walls(w, size, c)
  local n = 0
  for r = 0, size - 1 do
    if bit_test(w, r * 8 + c) then n = n + 1 end
  end
  return n
end

-- A save comes off the card, so it is treated as input: strip anything
-- standing on a monster or a chest (the C++ `restore`).
local function clean_masks(p, w, f)
  local wb, fb = {}, {}
  for i = 1, 8 do
    local fx = p.mon:byte(i) | p.chest:byte(i)
    local wv = w:byte(i) & ~fx
    wb[i] = wv
    fb[i] = f:byte(i) & ~fx & ~wv
  end
  return string.char(table.unpack(wb)), string.char(table.unpack(fb))
end

local function tap_cell(p, w, f, r, c)
  local b = r * 8 + c
  if bit_test(p.mon, b) or bit_test(p.chest, b) then return w, f end
  if bit_test(w, b) then return bit_clear(w, b), bit_set(f, b) end
  if bit_test(f, b) then return w, bit_clear(f, b) end
  return bit_set(w, b), f
end

-- ---------------------------------------------------------------------------
-- bank prep: a monster glyph per dungeon. The creature is a hash of the NAME
-- (not a rotation over the index) so the campaign map's rows do not stripe -
-- the same reasoning as DungeonScreens.cpp. Any stable name hash works; this
-- one stays under 2^31 so 32-bit and 64-bit builds agree. Derived on demand,
-- never cached, to keep the bank small in the Lua heap.
local function glyph_for(name)
  local h = 0
  for i = 1, #name do
    h = (h * 31 + name:byte(i)) % 65521
  end
  return GLYPHS[(h % #GLYPHS) + 1]
end

-- ---------------------------------------------------------------------------
-- persistence (data: scope, no permission needed)

local function solved_count()
  local n = 0
  for k = 1, 64 do if SOLVED[k] then n = n + 1 end end
  return n
end

local function next_unsolved()
  for k = 1, 64 do if not SOLVED[k] then return k end end
  return 64
end

local function more_to_play()
  return solved_count() < 64
end

local function save()
  local parts = {
    RESUME and tostring(RESUME.idx) or "-",
    RESUME and bank.bytes2hex(RESUME.walls) or "-",
    RESUME and bank.bytes2hex(RESUME.floors) or "-",
  }
  local sol = {}
  for k = 1, 64 do if SOLVED[k] then sol[#sol + 1] = tostring(k) end end
  parts[#parts + 1] = #sol > 0 and table.concat(sol, ",") or "-"
  fs.write(SAVE_FILE, table.concat(parts, "\n") .. "\n")
end

local function load_save()
  local s = fs.read(SAVE_FILE)
  if not s then return end
  local i1, w, f, sol = s:match("^([^\n]*)\n([^\n]*)\n([^\n]*)\n?([^\n]*)")
  if i1 and i1 ~= "-" and i1 ~= "" then
    local k = tonumber(i1)
    if k and k >= 1 and k <= 64 and w and f and #w == 16 and #f == 16 then
      RESUME = { idx = k, walls = bank.hex2bytes(w), floors = bank.hex2bytes(f) }
    end
  end
  if sol and sol ~= "-" then
    for v in sol:gmatch("%d+") do
      local k = tonumber(v)
      if k and k >= 1 and k <= 64 then SOLVED[k] = true end
    end
  end
end

-- ---------------------------------------------------------------------------
-- board surface shared by the board screen and the guide

local LANE_W, LANE_H, CLUE_GAP = 38, 42, 6

-- spot = { row, col, w, h, lanes } - what the guide brackets
local function board_surface(p, walls, floors, cell, gridX, yGrid, spot)
  local n = p.size
  local gridW, gridH = n * cell, n * cell
  local over = (cell - LANE_H) // 2
  local colLaneTop = yGrid - CLUE_GAP - LANE_H

  for i = 0, n - 1 do
    local placedR = row_walls(walls, n, i)
    local placedC = col_walls(walls, n, i)
    local rv, cv = bank.rowclue(p, i + 1), bank.colclue(p, i + 1)
    -- row clue: box in the left lane, chip against the row
    local rbx = gridX - CLUE_GAP - LANE_W
    local rby = yGrid + i * cell + over
    if placedR == rv then
      gfx.rect(rbx + 5, yGrid + i * cell, LANE_W - 10, cell, true)
    elseif placedR > rv then
      gfx.rect(rbx + 5, yGrid + i * cell, LANE_W - 10, cell, false)
    end
    if placedR == rv then
      ctext(rbx + LANE_W / 2, rby + (LANE_H - lineh("sans16")) / 2, tostring(rv), "sans16", "bw")
    else
      ctext(rbx + LANE_W / 2, rby + (LANE_H - lineh("sans16")) / 2, tostring(rv), "sans16", "b")
    end
    -- column clue: box above the column, chip spanning it
    local cbx = gridX + i * cell + (cell - LANE_H) // 2
    if placedC == cv then
      gfx.rect(gridX + i * cell, colLaneTop + 5, cell, LANE_H - 10, true)
    elseif placedC > cv then
      gfx.rect(gridX + i * cell, colLaneTop + 5, cell, LANE_H - 10, false)
    end
    if placedC == cv then
      ctext(cbx + LANE_H / 2, colLaneTop + (LANE_H - lineh("sans16")) / 2, tostring(cv), "sans16", "bw")
    else
      ctext(cbx + LANE_H / 2, colLaneTop + (LANE_H - lineh("sans16")) / 2, tostring(cv), "sans16", "b")
    end
  end

  -- frame (outside the play area) + hairline lattice
  gfx.rect(gridX - 2, yGrid - 2, gridW + 4, 2, true)
  gfx.rect(gridX - 2, yGrid + gridH, gridW + 4, 2, true)
  gfx.rect(gridX - 2, yGrid, 2, gridH, true)
  gfx.rect(gridX + gridW, yGrid, 2, gridH, true)
  for i = 1, n - 1 do
    gfx.line(gridX + i * cell, yGrid, gridX + i * cell, yGrid + gridH, true)
    gfx.line(gridX, yGrid + i * cell, gridX + gridW, yGrid + i * cell, true)
  end

  -- cells: walls merge edge to edge, floor notes are dots, furniture drawn last
  for r = 0, n - 1 do
    for c = 0, n - 1 do
      local b = r * 8 + c
      local x, y = gridX + c * cell, yGrid + r * cell
      local mon = bit_test(p.mon, b)
      local chst = bit_test(p.chest, b)
      if bit_test(walls, b) then
        gfx.rect(x, y, cell, cell, true)
      elseif bit_test(floors, b) and not mon and not chst then
        gfx.rounded_rect(x + cell / 2 - 5, y + cell / 2 - 5, 10, 10, 5, true)
      end
      if mon then
        ctext(x + cell / 2, y + (cell - lineh("sans18")) / 2, glyph_for(p.name), "sans18", "b")
      elseif chst then
        ctext(x + cell / 2, y + (cell - lineh("sans18")) / 2, CHEST, "sans18", "b")
      end
    end
  end

  if spot then
    if spot[5] then
      brackets(gridX + over - 4, colLaneTop - 4, gridW - 2 * over + 8, LANE_H + 8, 14, 2)
      brackets(gridX - CLUE_GAP - LANE_W - 4, yGrid + over - 4, LANE_W + 8, gridH - 2 * over + 8, 14, 2)
    elseif spot[3] then
      brackets(gridX + spot[2] * cell + 3, yGrid + spot[1] * cell + 3,
               spot[3] * cell - 6, spot[4] * cell - 6, 14, 2)
    end
  end
end

-- ---------------------------------------------------------------------------
-- the board screen

local function draw_board()
  local p, n = STATE.p, STATE.p.size
  local m = 10
  local cell = (W - 2 * m - LANE_W - CLUE_GAP) // n
  if cell > 64 then cell = 64 end
  local gridW = n * cell
  local gridX = m + LANE_W + CLUE_GAP
  local yBar = H - 12 - 46
  local yGrid = 40 + 30 + 8 + LANE_H + CLUE_GAP          -- header + name strip + col lane
  local avail = yBar - 10 - yGrid
  if n * cell > avail then cell = avail // n; gridW = n * cell end
  yGrid = yGrid + math.max(0, (avail - n * cell) // 2)

  gfx.clear()
  header("D&DIAGRAMS", tostring(solved_count()) .. "/64")
  ctext(W / 2, 44, p.name, "sans14", "b")               -- the name's own strip (long names)
  board_surface(p, STATE.walls, STATE.floors, cell, gridX, yGrid, nil)
  -- cursor
  if STATE.bzone == "grid" then
    local x = gridX + STATE.bcol * cell
    local y = yGrid + STATE.brow * cell
    brackets(x + 3, y + 3, cell - 6, cell - 6, 12, 2)
  end
  local bw = (W - 2 * m - 10) / 2
  btn(m, yBar, bw, 46, "CLEAR", STATE.bzone == "buttons" and STATE.bb == 1)
  btn(m + bw + 10, yBar, bw, 46, "DUNGEONS", STATE.bzone == "buttons" and STATE.bb == 2)
end

local function open_dungeon(k, fromResume)
  local pi = k + 1
  local p = P[pi] or P[2]
  if not P[pi] then k = 1 end
  STATE.p, STATE.k = p, k
  STATE.walls, STATE.floors = ZERO8, ZERO8
  STATE.brow, STATE.bcol = 0, 0
  STATE.bzone, STATE.bb = "grid", 1
  if fromResume and RESUME and RESUME.idx == k then
    STATE.walls, STATE.floors = clean_masks(p, RESUME.walls, RESUME.floors)
  end
end

local function board_loop()
  local p = STATE.p
  local n = p.size
  while true do
    draw_board()
    local e = input.wait()
    if not e then e = "none" end
    if STATE.bzone == "grid" then
      local r, c = STATE.brow, STATE.bcol
      if e == "back" then
        if STATE.walls ~= ZERO8 or STATE.floors ~= ZERO8 then
          RESUME = { idx = STATE.k, walls = STATE.walls, floors = STATE.floors }
          save()
        end
        return "menu"
      elseif e == "left" then c = (c + n - 1) % n
      elseif e == "right" then c = (c + 1) % n
      elseif e == "up" then r = (r + n - 1) % n
      elseif e == "down" then
        if r == n - 1 then STATE.bzone, STATE.bb = "buttons", 1 else r = r + 1 end
      elseif e == "confirm" then
        local w2, f2 = tap_cell(p, STATE.walls, STATE.floors, r, c)
        if w2 ~= STATE.walls or f2 ~= STATE.floors then
          STATE.walls, STATE.floors = w2, f2
          if w2 == p.walls then
            SOLVED[STATE.k] = true
            RESUME = nil
            STATE.winmore = more_to_play()
            save()
            STATE.wb = 1
            return "win"
          end
          if w2 ~= ZERO8 or f2 ~= ZERO8 then
            RESUME = { idx = STATE.k, walls = w2, floors = f2 }
          else
            RESUME = nil
          end
          save()
        end
      end
      STATE.brow, STATE.bcol = r, c
    else
      if e == "back" or e == "up" then
        STATE.bzone = "grid"; STATE.brow = n - 1
      elseif e == "left" or e == "right" then
        STATE.bb = STATE.bb == 1 and 2 or 1
      elseif e == "confirm" then
        if STATE.bb == 1 then
          STATE.walls, STATE.floors = ZERO8, ZERO8
          RESUME = nil
          save()
          STATE.bzone, STATE.brow, STATE.bcol = "grid", 0, 0
        else
          return "menu"
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- the campaign map (menu)

local function draw_menu()
  gfx.clear()
  header("D&DIAGRAMS", tostring(solved_count()) .. "/64")
  ctext(W / 2, 46, "TAP TO CHOOSE, THEN PLAY", "small", "b")
  local m, lane, gap = 12, 30, 5
  local yBar = H - 12 - 46
  local yBot = yBar - 12 - 44 - 8                         -- room for the name band
  local cell = (W - 2 * m - lane - 7 * gap) // 8
  local hcell = (yBot - 66 - 7 * gap) // 8
  if cell > hcell then cell = hcell end
  local extent = 8 * cell + 7 * gap
  local left = m + (W - 2 * m - lane - extent) // 2
  local gridX = left + lane
  local gridY = 66 + math.max(0, (yBot - 66 - extent) // 2)

  for t = 0, 7 do
    local rowY = gridY + t * (cell + gap)
    local done = true
    for slot = 1, 8 do if not SOLVED[t * 8 + slot] then done = false break end end
    local chip = { left, rowY, lane - 6, cell }
    if done then
      gfx.rect(left, rowY, lane - 6, cell, true)
      ctext(left + (lane - 6) / 2, rowY + (cell - lineh("ui12")) / 2, tostring(t + 1), "ui12", "bw")
    else
      ctext(left + (lane - 6) / 2, rowY + (cell - lineh("ui12")) / 2, tostring(t + 1), "ui12", "b")
    end
  end

  for pos = 0, 63 do
    local k = pos + 1
    local p = P[k + 1]
    local x = gridX + (pos % 8) * (cell + gap)
    local y = gridY + (pos // 8) * (cell + gap)
    local done = SOLVED[k]
    if done then
      gfx.rect(x, y, cell, cell, true)
    else
      gfx.rect(x, y, cell, cell, false)
    end
    ctext(x + cell / 2, y + (cell - lineh("sans16")) / 2, glyph_for(p.name), "sans16", done and "bw" or "b")
    if k == STATE.sel + 1 then brackets(x - 5, y - 5, cell + 10, cell + 10, 12, 2) end
  end

  -- name band: the selected dungeon's creature + name, TUTORIAL on the right
  local p = P[STATE.sel + 1]
  local ny = yBot + 8
  ctext(12 + 16, ny + (44 - lineh("sans18")) / 2, glyph_for(p.name), "sans18", "b")
  gfx.text(12 + 40, ny + (44 - lineh("small")) / 2, p.name, "small", "b")
  btn(W - 12 - 150, ny, 150, 44, "TUTORIAL", STATE.zone == "buttons" and STATE.bzone == 2)
  btn(m, yBar, W - 2 * m, 46, RESUME and "RESUME" or "PLAY", STATE.zone == "buttons" and STATE.bzone == 1)
end

local function menu_loop()
  while true do
    draw_menu()
    local e = input.wait()
    if not e then e = "none" end
    if e == "back" then
      if STATE.zone == "buttons" then
        STATE.zone = "grid"; STATE.sel = 56 + STATE.sel % 8
      else
        return nil
      end
    elseif STATE.zone == "grid" then
      local row, col = STATE.sel // 8, STATE.sel % 8
      if e == "left" then col = (col + 7) % 8
      elseif e == "right" then col = (col + 1) % 8
      elseif e == "up" then row = (row + 7) % 8
      elseif e == "down" then
        if row == 7 then STATE.zone, STATE.bzone = "buttons", 1 else row = row + 1 end
      elseif e == "confirm" then
        open_dungeon(STATE.sel + 1, false)
        return "board"
      end
      STATE.sel = row * 8 + col
    else
      if e == "left" or e == "right" then STATE.bzone = STATE.bzone == 1 and 2 or 1
      elseif e == "up" or e == "back" then -- handled back above; up returns to the grid
        STATE.zone = "grid"; STATE.sel = 56 + STATE.sel % 8
      elseif e == "confirm" then
        if STATE.bzone == 1 then
          if RESUME then open_dungeon(RESUME.idx, true) else open_dungeon(next_unsolved(), false) end
          return "board"
        else
          STATE.page = 1
          return "guide"
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- the win screen

local function draw_win()
  local p = STATE.p
  gfx.clear()
  header("CLEARED", tostring(solved_count()) .. "/64")
  ctext(W / 2, 66, p.name, "sans18", "b")
  local cell = 34
  local n = p.size
  local extent = n * cell
  local x0 = math.floor(W / 2 - extent / 2)
  local y0 = 160
  gfx.rect(x0 - 2, y0 - 2, extent + 4, 2, true)
  gfx.rect(x0 - 2, y0 + extent, extent + 4, 2, true)
  gfx.rect(x0 - 2, y0, 2, extent, true)
  gfx.rect(x0 + extent, y0, 2, extent, true)
  for r = 0, n - 1 do
    for c = 0, n - 1 do
      local b = r * 8 + c
      local x, y = x0 + c * cell, y0 + r * cell
      if bit_test(p.walls, b) then
        gfx.rect(x, y, cell, cell, true)
      elseif bit_test(p.mon, b) or bit_test(p.chest, b) then
        gfx.rounded_rect(x + cell / 2 - 6, y + cell / 2 - 6, 12, 12, 6, true)
      end
    end
  end
  local m = 12
  local yBar = H - 12 - 46
  if STATE.winmore then
    local bw = (W - 2 * m - 10) / 2
    btn(m, yBar, bw, 46, "NEXT", STATE.wb == 1)
    btn(m + bw + 10, yBar, bw, 46, "DUNGEONS", STATE.wb == 2)
  else
    btn(m, yBar, W - 2 * m, 46, "DUNGEONS", true)
  end
end

local function win_loop()
  while true do
    draw_win()
    local e = input.wait()
    if not e then e = "none" end
    if e == "back" then return "menu" end
    if STATE.winmore then
      if e == "left" or e == "right" then STATE.wb = STATE.wb == 1 and 2 or 1
      elseif e == "confirm" then
        if STATE.wb == 1 then
          open_dungeon(next_unsolved(), false)
          return "board"
        else
          return "menu"
        end
      end
    elseif e == "confirm" then
      return "menu"
    end
  end
end

-- ---------------------------------------------------------------------------
-- the adventurer's guide: the tutorial, one rule at a time.
-- Page rows use the C++ transcription: # wall, o floor-marked, . untouched.
-- A page's board is built from the text and cleaned against the furniture so
-- it can never disagree with the tutorial puzzle.

local GUIDE = {
  { title = "THE MAP",
    body = { "SOMEWHERE IN THIS GRID IS A DUNGEON. YOU FIND IT",
             "BY PLACING WALLS, USING NOTHING BUT LOGIC." },
    rows = { "......", "......", "......", "......", "......", "......" },
    spot = nil },
  { title = "THE NUMBERS",
    body = { "EACH NUMBER COUNTS THE WALLS IN ITS ROW OR",
             "COLUMN. TAP A SQUARE TO PLACE ONE." },
    rows = { "###...", "#.....", "......", "#.....", "#.....", "......" },
    spot = { 0, 0, 0, 0, true } },
  { title = "YOUR NOTES",
    body = { "TAP AGAIN TO MARK FLOOR, ONCE MORE TO CLEAR.",
             "THOSE MARKS ARE YOUR NOTES, NOT THE ANSWER." },
    rows = { "###ooo", "#ooooo", ".o....", "#.....", "#.....", "......" },
    spot = nil },
  { title = "TREASURE",
    body = { "A CHEST SITS IN A 3X3 ROOM OF FLOOR.",
             "ONE WAY IN, ONE CHEST, AND NOTHING LIVING IN IT." },
    rows = { "###ooo", "#ooooo", ".oooo.", "#.....", "#.....", "......" },
    spot = { 0, 3, 3, 3, false } },
  { title = "MONSTERS",
    body = { "EVERY MONSTER SITS IN A DEAD END, AND EVERY",
             "DEAD END HAS A MONSTER IN IT." },
    rows = { "###ooo", "#ooooo", ".oooo.", "#.####", "#....#", "..#..." },
    spot = { 2, 0, 1, 1, false } },
  { title = "ONE DUNGEON",
    body = { "ALL THE FLOOR JOINS UP. SQUARES THAT ONLY TOUCH",
             "AT A CORNER ARE NOT JOINED." },
    rows = { "###ooo", "#ooooo", ".oooo.", "#.####", "#o..##", "..#..." },
    spot = nil },
  { title = "CORRIDORS",
    body = { "CORRIDORS ARE ONE SQUARE WIDE. NO 2X2 OF OPEN",
             "FLOOR OUTSIDE A TREASURE ROOM." },
    rows = { "###ooo", "#ooooo", ".oooo.", "#.####", "#ooo#.", "..#..." },
    spot = { 3, 1, 2, 2, false } },
  { title = "YOUR TURN",
    body = { "THAT IS EVERY RULE. SIXTY-FOUR DUNGEONS ARE",
             "WAITING FOR YOU." },
    rows = { "###...", "#.....", "..#...", "#.####", "#...#.", "..#..." },
    spot = nil },
}

local function guide_board(rows)
  local w, f = ZERO8, ZERO8
  for r = 1, 6 do
    local row = rows[r]
    for c = 1, 6 do
      local ch = row:sub(c, c)
      local b = (r - 1) * 8 + (c - 1)
      if ch == "#" then
        w = bit_set(w, b)
      elseif ch == "o" then
        f = bit_set(f, b)
      end
    end
  end
  return clean_masks(P[1], w, f)
end

local function draw_guide()
  local page = STATE.page
  local g = GUIDE[page]
  local p = P[1]
  local walls, floors = guide_board(g.rows)
  gfx.clear()
  header(g.title, tostring(page) .. "/8")
  local m = 10
  local cell = 44
  local yBar = H - 12 - 46
  local yGrid = 48 + LANE_H + CLUE_GAP
  local capH = 2 * lineh("small") + 14
  local avail = yBar - 10 - yGrid - capH
  if 6 * cell > avail then cell = avail // 6 end
  local bbw = LANE_W + CLUE_GAP + 6 * cell
  local gridX = m + LANE_W + CLUE_GAP + math.max(0, (W - 2 * m - bbw) // 2)
  yGrid = yGrid + math.max(0, (avail - 6 * cell) // 2)

  board_surface(p, walls, floors, cell, gridX, yGrid, g.spot)
  local capY = yGrid + 6 * cell + 8
  ctext(W / 2, capY, g.body[1], "small", "b")
  ctext(W / 2, capY + lineh("small") + 2, g.body[2], "small", "b")

  local bw = (W - 2 * m - 10) / 2
  local leftL = page == 1 and "BACK" or "PREV"
  local rightL = page == 8 and "PLAY" or "NEXT"
  btn(m, yBar, bw, 46, leftL, false)
  btn(m + bw + 10, yBar, bw, 46, rightL, true)
end

local function guide_loop()
  while true do
    draw_guide()
    local e = input.wait()
    if not e then e = "none" end
    local page = STATE.page
    if e == "back" then return "menu" end
    local leftL = page == 1 and "back" or "prev"
    local rightL = page == 8 and "play" or "next"
    if e == "left" then
      if leftL == "back" then return "menu" else STATE.page = page - 1 end
    elseif e == "right" or e == "confirm" then
      if rightL == "play" then
        open_dungeon(next_unsolved(), false)
        return "board"
      else
        STATE.page = page + 1
      end
    end
  end
end

-- ---------------------------------------------------------------------------

local function __main()
  W, H = gfx.size()
  P = bank.load()
  if #P == 0 then
    gfx.clear()
    ctext(W / 2, H / 2, "D&Diagrams: no dungeon data.", "ui12", "b")
    gfx.present()
    while input.wait() ~= "back" do end
    return
  end
  load_save()
  STATE.sel = (RESUME and RESUME.idx or next_unsolved()) - 1
  local scr = "menu"
  while scr do
    if scr == "menu" then scr = menu_loop()
    elseif scr == "board" then scr = board_loop()
    elseif scr == "win" then scr = win_loop()
    elseif scr == "guide" then scr = guide_loop()
    end
  end
end

local ok, err = pcall(__main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()