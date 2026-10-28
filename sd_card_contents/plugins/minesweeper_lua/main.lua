-- Minesweeper for CrossLua (8x10, ten mines) — a port of the crossplay game.
--
-- Rules live in game.lua (a port of crossplay's MinesweeperCore.h): the first
-- dig is always safe and always floods, a flag stops the flood and is never
-- torn off by it, chording is a plain confirm on a satisfied number, and a
-- wrong flag under a right count detonates.
--
-- Controls (seven-button board; there is no touch and no right button, and
-- Lua sees button events only on release, so the design doc's hold-to-flag
-- cannot exist here). The port keeps the doc's shape — two verbs on one cell,
-- the dangerous verb the default, the safe verb deliberate, the indicator at
-- the action — as a two-tool cursor:
--
--   Left/Right/Up/Down            move the cursor (wraps)
--   Confirm on a covered cell     DIG it (in FLAG tool: plant/lift the flag)
--   Confirm on a satisfied number CHORD — opens the rest; a wrong flag ends it
--   Confirm on revealed ground    switch DIG <-> FLAG tool
--   Back                          board -> menu; menu -> exit (the C++ Flow)
--
-- The armed tool is shown in the strip right under the grid, beside the
-- counter — at the action, not six hundred pixels away.

local game = require("game")

local W, H = gfx.size()
local COLS, ROWS, MINES = game.COLS, game.ROWS, game.MINES
local CELL = W // COLS -- 60px on the X4: the field is full-bleed 480px wide
local BOARD_H = CELL * ROWS

local HEADER_H = 44
local BOARD_Y = HEADER_H + 4

local cur = { c = 0, r = 0 }
local tool = "dig" -- "dig" | "flag"
local board
local wins, losses = 0, 0
local last_board -- nil | 80-byte array of the settled board
local has_history = false
local result_recorded = false

local presents = 0
local function present()
  presents = presents + 1
  gfx.present(presents % 8 == 0 and "half" or "fast")
end

-- ------------------------------------------------------------- persistence

local function load_record()
  local raw = fs.read("data:state.json")
  if not raw then return end
  local st = json.decode(raw)
  if type(st) ~= "table" then return end
  if type(st.wins) == "number" then wins = st.wins end
  if type(st.losses) == "number" then losses = st.losses end
  if type(st.board) == "table" then
    local ok = #st.board == COLS * ROWS
    if ok then
      for i = 1, COLS * ROWS do
        if type(st.board[i]) ~= "number" then ok = false break end
      end
    end
    if ok then
      last_board = st.board
      has_history = true
    end
  end
end

local function save_record()
  local s, err = json.encode({ wins = wins, losses = losses, board = last_board })
  if s then
    local ok, werr = fs.write("data:state.json", s)
    if not ok then print("MINE save:", werr) end
  end
end

-- --------------------------------------------------------------- drawing

local function cellRect(c, r)
  return c * CELL, BOARD_Y + r * CELL -- x, y
end

local function stroke(x, y, w, h)
  gfx.line(x, y, x + w - 1, y)
  gfx.line(x, y + h - 1, x + w - 1, y + h - 1)
  gfx.line(x, y, x, y + h - 1)
  gfx.line(x + w - 1, y, x, y + h - 1)
end

-- the C++ paints covered cells a dithered grey; e-ink has no dither brush, so
-- a sparse dot field stands in for it
local function dither(x, y, w, h, step)
  for yy = y + 8, y + h - 8, step do
    for xx = x + 8, x + w - 8, step do
      gfx.pixel(xx, yy, true)
    end
  end
end

-- A flag: pole, base, and a pennant hanging right (Lucide's idea: pennant and
-- pole must not sit at the same height, or no flag emerges at any size).
local function flagGlyph(x, y, s, black)
  local pole = math.max(2, s // 10)
  local px = x + s // 2 - s // 6
  local top = y + s // 6
  local ph = s - s // 3
  gfx.rect(px, top, pole, ph, true, black)
  gfx.rect(x + s // 6, y + s - s // 3 - pole, s - s // 3, pole, true, black)
  local w = s // 3
  local py = top
  while w > pole + 1 do
    gfx.rect(px + pole, py, w, pole, true, black)
    py = py + pole
    w = w - s // 9
  end
end

-- A mine: the pixel shape from crossplay's MinesweeperScreens.cpp — a disc of
-- stacked bars with four spikes. `s` scales it (60px cells and lesson fields).
local function mineGlyph(x, y, s, black)
  local scale = s / CELL
  local cx, cy = x + s // 2, y + s // 2
  local half = { 4, 7, 9, 10, 10, 9, 7, 4 }
  local barH = math.max(1, math.floor(2 * scale + 0.5))
  local step = math.max(1, math.floor(2 * scale + 0.5))
  local cy0 = cy - math.floor(9 * scale)
  for i = 1, 8 do
    local h = math.floor(half[i] * scale + 0.5)
    gfx.rect(cx - h, cy0 + (i - 1) * step, h * 2, barH, true, black)
  end
  local up, down = math.floor(16 * scale), math.floor(11 * scale)
  local v = math.max(1, math.floor(6 * scale + 0.5))
  gfx.rect(cx - 1, cy - up, 3, v, true, black)
  gfx.rect(cx - 1, cy + down - 1, 3, v, true, black)
  gfx.rect(cx - up, cy - 1, v, 3, true, black)
  gfx.rect(cx + down - 1, cy - 1, v, 3, true, black)
end

local function wrap(s, font, maxw)
  local out, line = {}, ""
  for word in s:gmatch("%S+") do
    local probe = line == "" and word or (line .. " " .. word)
    if gfx.text_width(probe, font) > maxw and line ~= "" then
      out[#out + 1] = line
      line = word
    else
      line = probe
    end
  end
  if line ~= "" then out[#out + 1] = line end
  return out
end

local function drawCell(c, r)
  local x, y = cellRect(c, r)
  local byte = game.cell(board, c, r)
  local revealed = (byte & game.REVEALED) ~= 0
  local flagged = (byte & game.FLAGGED) ~= 0
  local mine = (byte & game.MINE) ~= 0

  if not revealed then dither(x, y, CELL, CELL, 12) end
  stroke(x, y, CELL, CELL)

  if flagged then
    flagGlyph(x, y, CELL, true)
  elseif revealed and mine then
    gfx.rect(x, y, CELL, CELL, true, true)
    mineGlyph(x, y, CELL, false)
  elseif game.over(board) and mine then
    mineGlyph(x, y, CELL, true)
  elseif revealed then
    local n = game.neighbouringMines(board, c, r)
    if n > 0 then
      local lh = gfx.line_height("sans18")
      gfx.text(x + CELL // 2, y + (CELL - lh) // 2, tostring(n), "sans18", "bc")
    end
  end
end

local function drawCursor()
  local x, y = cellRect(cur.c, cur.r)
  local t = 4
  gfx.rect(x, y, CELL, t, true, true)
  gfx.rect(x, y + CELL - t, CELL, t, true, true)
  gfx.rect(x, y, t, CELL, true, true)
  gfx.rect(x + CELL - t, y, t, CELL, true, true)
  if tool == "flag" then
    local byte = game.cell(board, cur.c, cur.r)
    if (byte & game.REVEALED) == 0 and (byte & game.FLAGGED) == 0 then
      flagGlyph(x + CELL // 4, y + CELL // 4, CELL // 2, true) -- preview the arm
    end
  end
end

local function capsule(x, y, w, h, label, armed)
  if armed then
    gfx.rect(x, y, w, h, true, true)
  else
    gfx.rect(x, y, w, h, true, false)
    stroke(x, y, w, h)
  end
  local lh = gfx.line_height("ui12")
  gfx.text(x + w // 2, y + (h - lh) // 2, label, "ui12", armed and "bwc" or "bc")
end

local function hintBar(labels, note)
  local hy, hh = H - 74, 62
  gfx.line(0, hy, W, hy)
  if note then gfx.text(W // 2, hy - 20, note, "small", "c") end
  local cw = W // 4
  for i = 1, 4 do
    capsule((i - 1) * cw + 6, hy + 8, cw - 12, hh - 16, labels[i], false)
  end
  gfx.text(W // 2, hy - 40, "Up/Down: side buttons", "small", "c")
end

local function header(title, right)
  gfx.rect(0, 0, W, HEADER_H, true, true)
  gfx.text(14, 10, title, "ui", "bw")
  if right then gfx.text(W - 14, 10, right, "ui12", "bwr") end
  gfx.line(0, HEADER_H, W, HEADER_H)
end

local function drawStrip()
  local y = BOARD_Y + BOARD_H + 10
  local sh = 36
  if game.over(board) then
    -- the counter and the tool are questions; the game has just answered both
    local wl = gfx.text_width("CLEARED", "sans16", "b")
    local label = game.status(board) == "won" and "CLEARED" or "BOOM"
    capsule(W // 2 - wl // 2 - 28, y + 4, wl + 56, sh, label, true)
    hintBar({ "Menu", "Result", "Move", "Move" },
      game.status(board) == "won" and "The field is cleared" or "You hit a mine")
    return
  end
  local count = game.minesRemaining(board) .. " OF " .. MINES
  gfx.text(14, y + 8, count, "sans16", "b")
  flagGlyph(14 + gfx.text_width(count, "sans16", "b") + 8, y + 1, 26, true)
  capsule(W - W // 3 - 10, y, W // 3, sh, tool == "flag" and "FLAG" or "DIG", tool == "flag")
  hintBar({ "Menu", tool == "flag" and "Flag" or "Dig", "Move", "Move" },
    "Confirm on open ground: switch tool")
end

local function drawBoard()
  gfx.clear()
  header("MINESWEEPER")
  gfx.line(0, BOARD_Y - 2, W, BOARD_Y - 2)
  gfx.line(0, BOARD_Y + BOARD_H, W, BOARD_Y + BOARD_H)
  for r = 0, ROWS - 1 do
    for c = 0, COLS - 1 do drawCell(c, r) end
  end
  drawCursor()
  drawStrip()
  present()
end

local function lastGameLost()
  if not last_board then return false end
  for i = 1, COLS * ROWS do
    local byte = last_board[i]
    if (byte & game.MINE) ~= 0 and (byte & game.REVEALED) ~= 0 then return true end
  end
  return false
end

local menu_sel = 1

local function drawMenu()
  gfx.clear()
  header("MINESWEEPER")
  gfx.text(16, HEADER_H + 14, (wins + losses) .. " PLAYED   " .. wins .. " CLEARED", "ui12", "b")
  gfx.line(16, HEADER_H + 46, W - 16, HEADER_H + 46)
  local items = { "PLAY", "HOW TO PLAY" }
  for i, it in ipairs(items) do
    local y = HEADER_H + 60 + (i - 1) * 56
    if i == menu_sel then gfx.rect(16, y, W - 32, 44, true, true) end
    gfx.text(36, y + 13, it, "ui12", i == menu_sel and "bw" or "b")
  end
  if has_history and last_board then
    local mini = 34
    local bw, bh = mini * COLS, mini * ROWS
    local mx, my = (W - bw) // 2, HEADER_H + 60 + 2 * 56 + 18
    if my + bh < H - 60 then
      for r = 0, ROWS - 1 do
        for c = 0, COLS - 1 do
          local byte = last_board[r * COLS + c + 1]
          local x0, y0 = mx + c * mini, my + r * mini
          if (byte & game.MINE) ~= 0 then
            gfx.rect(x0, y0, mini, mini, true, true)
          elseif (byte & game.REVEALED) == 0 then
            dither(x0, y0, mini, mini, 9)
            stroke(x0, y0, mini, mini)
            if (byte & game.FLAGGED) ~= 0 then flagGlyph(x0, y0, mini, true) end
          else
            stroke(x0, y0, mini, mini)
            local n = game.neighboursOn(last_board, c, r, game.MINE)
            if n > 0 then
              local lh = gfx.line_height("sans12")
              gfx.text(x0 + mini // 2, y0 + (mini - lh) // 2, tostring(n), "sans12", "bc")
            end
          end
        end
      end
      stroke(mx - 2, my - 2, bw + 4, bh + 4)
      gfx.text(W // 2, my + bh + 12, lastGameLost() and "LAST GAME: BOOM" or "LAST GAME: CLEARED", "small", "c")
    end
  end
  hintBar({ "Exit", "Select", "Prev", "Next" }, "Best of .crossplay: first dig always safe")
  present()
end

local HOWTO = {
  {
    "A NUMBER COUNTS THE MINES TOUCHING IT, CORNERS INCLUDED.",
    { "M..", ".oM", "..M" },
  },
  {
    "MOVE WITH THE ARROWS. CONFIRM DIGS THE CELL THE CURSOR IS ON.",
    { "oF." },
  },
  {
    "YOUR FIRST DIG IS ALWAYS SAFE, AND ALWAYS OPENS A SPACE.",
    { "oo...", "oo**.", "ooo..", "ooo*." },
  },
  {
    "OPEN EVERY SAFE CELL AND THE FIELD IS CLEARED. FLAGS ARE NOTES: NONE ARE NEEDED TO WIN.",
    { "ooooo", "ooo*o", "ooooo", "ooFoo" },
  },
  {
    "FLAGS: CONFIRM ON OPEN GROUND SWITCHES TO FLAG, CONFIRM AGAIN PLANTS IT. A SATISFIED NUMBER CHORDS — A WRONG FLAG ENDS IT.",
    { ".F.", ".o.", "..." },
  },
}

-- a fragment of minefield from a picture-string (the C++ lessonField): '.'
-- covered, 'o' open, '*' a covered mine, 'F' a flag, 'M' a mine laid bare
local function lessonField(left, top, cell, rows)
  local function mineAt(c, r)
    if c < 0 or c >= #rows[1] or r < 0 or r >= #rows then return false end
    local m = rows[r + 1]:sub(c + 1, c + 1)
    return m == "*" or m == "F" or m == "M"
  end
  for r = 0, #rows - 1 do
    for c = 0, #rows[1] - 1 do
      local x0, y0 = left + c * cell, top + r * cell
      local m = rows[r + 1]:sub(c + 1, c + 1)
      if m ~= "o" and m ~= "M" then dither(x0, y0, cell, cell, 10) end
      stroke(x0, y0, cell, cell)
      if m == "F" then
        flagGlyph(x0, y0, cell, true)
      elseif m == "M" then
        gfx.rect(x0, y0, cell, cell, true, true)
        mineGlyph(x0, y0, cell, false)
      elseif m == "o" then
        local n = 0
        for dc = -1, 1 do
          for dr = -1, 1 do
            if (dc ~= 0 or dr ~= 0) and mineAt(c + dc, r + dr) then n = n + 1 end
          end
        end
        if n > 0 then
          local lh = gfx.line_height("sans16")
          gfx.text(x0 + cell // 2, y0 + (cell - lh) // 2, tostring(n), "sans16", "bc")
        end
      end
    end
  end
end

local function drawHowTo(page)
  gfx.clear()
  header("HOW TO PLAY", (page + 1) .. " OF " .. #HOWTO)
  local lines = wrap(HOWTO[page + 1][1], "ui12", W - 40)
  for i, ln in ipairs(lines) do
    gfx.text(W // 2, HEADER_H + 20 + (i - 1) * 26, ln, "ui12", "c")
  end
  local rows = HOWTO[page + 1][2]
  local dcols, drows = #rows[1], #rows
  local cell = dcols > 3 and 64 or 88
  local dw = cell * dcols
  lessonField((W - dw) // 2, HEADER_H + 40 + #lines * 26, cell, rows)
  capsule(W // 2 - 80, H - 78, 160, 48, page + 1 < #HOWTO and "NEXT" or "GOT IT", true)
  present()
end

local result_sel = 1

local function drawResult()
  gfx.clear()
  local won = game.status(board) == "won"
  header(won and "CLEARED" or "BOOM")
  gfx.text(W // 2, 120, won and "YOU CLEARED THE FIELD" or "YOU HIT A MINE", "sans18", "bc")
  local revealed, right = 0, 0
  for r = 0, ROWS - 1 do
    for c = 0, COLS - 1 do
      local byte = game.cell(board, c, r)
      if (byte & game.REVEALED) ~= 0 and (byte & game.MINE) == 0 then revealed = revealed + 1 end
      if (byte & game.FLAGGED) ~= 0 and (byte & game.MINE) ~= 0 then right = right + 1 end
    end
  end
  gfx.text(W // 2, 210, revealed .. " OF " .. (COLS * ROWS - MINES) .. " CELLS OPENED", "ui12", "c")
  gfx.text(W // 2, 250, right .. " OF " .. MINES .. " MINES FLAGGED", "ui12", "c")
  local items = { "PLAY AGAIN", "DONE" }
  for i, it in ipairs(items) do
    local y = 340 + (i - 1) * 64
    if i == result_sel then gfx.rect(16, y, W - 32, 48, true, true) end
    gfx.text(W // 2, y + 14, it, "ui12", i == result_sel and "bwc" or "bc")
  end
  present()
end

-- ------------------------------------------------------------------ flow

local function beginGame()
  board = game.new((system.millis() % 2147483647) + 1)
  cur.c, cur.r = 0, 0
  tool = "dig"
  result_recorded = false
end

local function recordResult()
  if result_recorded then return end
  local st = game.status(board)
  if st ~= "won" and st ~= "lost" then return end
  result_recorded = true
  last_board = {}
  for r = 0, ROWS - 1 do
    for c = 0, COLS - 1 do
      last_board[r * COLS + c + 1] = game.cell(board, c, r)
    end
  end
  has_history = true
  if st == "won" then wins = wins + 1 else losses = losses + 1 end
  save_record()
end

local function run()
  load_record()
  local screen = "menu"
  local how_page = 0

  drawMenu()
  while true do
    local ev = input.wait()

    if screen == "menu" then
      if ev == "up" then
        menu_sel = (menu_sel - 2) % 2 + 1
        drawMenu()
      elseif ev == "down" then
        menu_sel = menu_sel % 2 + 1
        drawMenu()
      elseif ev == "confirm" then
        if menu_sel == 1 then
          beginGame()
          screen = "board"
          drawBoard()
        else
          how_page = 0
          screen = "howto"
          drawHowTo(how_page)
        end
      elseif ev == "back" then
        app.exit() -- the menu is the only screen that leaves the app
        return
      end

    elseif screen == "howto" then
      if ev == "confirm" or ev == "right" then
        if how_page + 1 < #HOWTO then
          how_page = how_page + 1
          drawHowTo(how_page)
        else
          screen = "menu"
          drawMenu()
        end
      elseif ev == "back" or ev == "left" then
        screen = "menu"
        drawMenu()
      elseif ev == "up" then
        how_page = (how_page - 1 + #HOWTO) % #HOWTO
        drawHowTo(how_page)
      elseif ev == "down" then
        how_page = (how_page + 1) % #HOWTO
        drawHowTo(how_page)
      end

    elseif screen == "board" then
      if game.over(board) then
        -- the settled board stays, mines bared, wearing its verdict
        if ev == "confirm" then
          result_sel = 1
          screen = "result"
          drawResult()
        elseif ev == "back" then
          screen = "menu"
          drawMenu()
        end
      elseif ev == "left" then
        cur.c = (cur.c - 1) % COLS
        drawBoard()
      elseif ev == "right" then
        cur.c = (cur.c + 1) % COLS
        drawBoard()
      elseif ev == "up" then
        cur.r = (cur.r - 1) % ROWS
        drawBoard()
      elseif ev == "down" then
        cur.r = (cur.r + 1) % ROWS
        drawBoard()
      elseif ev == "confirm" then
        local c, r = cur.c, cur.r
        local changed = false
        if tool == "flag" then
          local byte = game.cell(board, c, r)
          if (byte & game.REVEALED) == 0 then
            changed = game.toggleFlag(board, c, r)
          else
            -- FLAG mode does not chord; a confirm on revealed ground switches back
            tool = "dig"
            changed = true
          end
        else
          changed = game.dig(board, c, r)
          if not changed then
            local byte = game.cell(board, c, r)
            if (byte & game.REVEALED) ~= 0 then
              -- the dig tool has nothing to do on open ground: switch to FLAG
              tool = "flag"
              changed = true
            end
          end
        end
        if game.over(board) then recordResult() end
        if changed or game.over(board) then drawBoard() end
      elseif ev == "back" then
        screen = "menu"
        drawMenu()
      end

    elseif screen == "result" then
      if ev == "up" then
        result_sel = (result_sel - 2) % 2 + 1
        drawResult()
      elseif ev == "down" then
        result_sel = result_sel % 2 + 1
        drawResult()
      elseif ev == "confirm" then
        if result_sel == 1 then
          beginGame()
          screen = "board"
          drawBoard()
        else
          screen = "menu"
          drawMenu()
        end
      elseif ev == "back" then
        screen = "menu"
        drawMenu()
      end
    end
  end
end

local ok, err = pcall(run)
if not ok then
  gfx.clear()
  gfx.rect(0, 0, W, HEADER_H, true, true)
  gfx.text(10, 8, "err: " .. tostring(err):sub(1, 60), "ui12", "bw")
  gfx.present()
  while input.wait() ~= "back" do end
  app.exit()
end