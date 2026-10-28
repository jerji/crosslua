-- Sudoku for the X4: a puzzle is exactly as hard as its label says, because
-- the dig is driven by the same bounded technique solver that grades it.
-- Cursor port of the touch game: Up/Down/Left/Right move, Confirm acts, Back
-- goes up a level. Hold-to-pencil has no Lua equivalent, so pencil is a
-- one-shot gesture: confirm an already-armed pad key, then confirm a cell.

local sudoku

local W, H = gfx.size()

-- ------------------------------------------------------------------ state
local screen = "menu"        -- menu | board | howto | result
local menuLevel = 0          -- 0 EASY .. 3 EXPERT
local menuSel = 3            -- 1 difficulty, 2 how to play, 3 play door
local howPage = 1            -- 1..5
local resultSel = 1
local game
local hasGame = false
local rec
local notice = nil
local pencil = false
local generating = false
local resultRecorded = false
local newBest = false
local curR, curC = 0, 0
local lastTick = 0

-- ------------------------------------------------------------ geometry
-- Grid: nine 50px cells starting at 88, pad row directly under the grid with
-- one key per column (keys and cells share geometry, so the cursor slides
-- between them), then the capsule, UNDO and HINT rows.
local GX, GY, CELL = 15, 88, 50
local GRID_B = GY + 9 * CELL            -- 538
local PAD_Y = GRID_B + 14               -- 552
local CAP_Y = PAD_Y + 52                -- 604
local UNDO_Y = CAP_Y + 46               -- 650
local HINT_Y = UNDO_Y + 46              -- 696
local ROWH = 40

local function rowY(r)
  if r < 9 then return GY + r * CELL end
  if r == 9 then return PAD_Y end
  if r == 10 then return CAP_Y end
  if r == 11 then return UNDO_Y end
  return HINT_Y
end

local function clockStr(ms)
  local s = ms // 1000
  if s // 3600 > 0 then return string.format("%d:%02d:%02d", s // 3600, (s // 60) % 60, s % 60) end
  return string.format("%d:%02d", s // 60, s % 60)
end

-- --------------------------------------------------------------- drawing
local function header(title, right)
  gfx.text(16, 14, title, "ui", "b")
  if right then gfx.text(W - 16, 14, right, "ui12", "br") end
  gfx.line(0, 44, W, 44)
end

local function frame(x, y, w, h, wt)
  gfx.rect(x, y, w, wt, true)
  gfx.rect(x, y + h - wt, w, wt, true)
  gfx.rect(x, y, wt, h, true)
  gfx.rect(x + w - wt, y, wt, h, true)
end

-- Four brackets at a cell's corners (white ink when `paper`).
local function cornerTicks(x, y, len, wt, paper)
  local black = not paper
  gfx.rect(x, y, len, wt, true, black); gfx.rect(x, y, wt, len, true, black)
  gfx.rect(x + CELL - len, y, len, wt, true, black); gfx.rect(x + CELL - wt, y, wt, len, true, black)
  gfx.rect(x, y + CELL - wt, len, wt, true, black); gfx.rect(x, y + CELL - len, wt, len, true, black)
  gfx.rect(x + CELL - len, y + CELL - wt, len, wt, true, black)
  gfx.rect(x + CELL - wt, y + CELL - len, wt, len, true, black)
end

local function capsule(y, text, filled)
  if filled then
    gfx.rect(GX, y, 9 * CELL, ROWH, true)
    gfx.text(W // 2, y + (ROWH - gfx.line_height("ui12")) // 2, text, "ui12", "bwc")
  else
    frame(GX, y, 9 * CELL, ROWH, 2)
    gfx.text(W // 2, y + (ROWH - gfx.line_height("ui12")) // 2, text, "ui12", "bc")
  end
end

local function rowButton(y, label, enabled)
  if enabled then
    gfx.rect(GX, y, 9 * CELL, ROWH, true)
    gfx.text(W // 2, y + (ROWH - gfx.line_height("ui12")) // 2, label, "ui12", "bwc")
  else
    frame(GX, y, 9 * CELL, ROWH, 1)
    gfx.text(W // 2, y + (ROWH - gfx.line_height("small")) // 2, label, "small", "c")
  end
end

local function drawBoard()
  gfx.clear()
  local hasP = game.puzzle ~= nil
  local lvlName = hasP and sudoku.LEVEL[game.puzzle.level + 1] or sudoku.LEVEL[menuLevel + 1]
  header("SUDOKU", lvlName)
  for r = 0, 8 do
    for c = 0, 8 do
      local cell = r * 9 + c + 1
      local x, y = GX + c * CELL, GY + r * CELL
      local value = hasP and sudoku.valueAt(game, cell) or 0
      local clash = hasP and sudoku.isClashing(game, cell) or false
      local clue = hasP and sudoku.isGiven(game, cell) or false
      if clash then
        gfx.rect(x, y, CELL, CELL, true)
      elseif clue then
        frame(x + 2, y + 2, CELL - 5, CELL - 5, 2)
      end
      if value ~= 0 then
        local lh = gfx.line_height("sans18")
        local flags = clash and "bwc" or (clue and "bc" or "c")
        gfx.text(x + CELL // 2, y + (CELL - lh) // 2, tostring(value), "sans18", flags)
        if value == game.armed and not clash then cornerTicks(x, y, 9, 2) end
      else
        local notes = hasP and sudoku.visibleNotes(game, cell) or 0
        if notes ~= 0 then
          local lh2 = gfx.line_height("small")
          for d = 1, 9 do
            if (notes & sudoku.bitFor(d)) ~= 0 then
              local cc, rr = (d - 1) % 3, (d - 1) // 3
              gfx.text(x + 5 + cc * 14 + 7, y + 4 + rr * 14 + (14 - lh2) // 2, tostring(d), "small", "c")
            end
          end
        end
      end
      if hasP and cell == game.hintCell then frame(x, y, CELL, CELL, 1) end
      if not generating and r == curR and c == curC then frame(x, y, CELL, CELL, 3) end
    end
  end
  -- The rules on top of the cells, so no cell can overdraw a line.
  for i = 1, 8 do
    local wt = (i % 3 == 0) and 2 or 1
    local off = i * CELL - wt // 2
    gfx.rect(GX + off, GY, wt, 9 * CELL, true)
    gfx.rect(GX, GY + off, 9 * CELL, wt, true)
  end
  -- Digit pad, one key per column, abutting like the cells above them.
  for d = 1, 9 do
    local x = GX + (d - 1) * CELL
    local spent = hasP and sudoku.placedCount(game, d) >= 9 or false
    local armed = d == game.armed
    if armed and not spent then
      gfx.rect(x, PAD_Y, CELL, CELL, true)
      gfx.text(x + CELL // 2, PAD_Y + (CELL - gfx.line_height("sans18")) // 2, tostring(d), "sans18", "bwc")
    else
      frame(x, PAD_Y, CELL, CELL, 1)
      local font = spent and "small" or "sans18"
      gfx.text(x + CELL // 2, PAD_Y + (CELL - gfx.line_height(font)) // 2, tostring(d), font, "c")
    end
    if not generating and curR == 9 and curC == d - 1 then frame(x, PAD_Y, CELL, CELL, 3) end
  end
  -- The status capsule. A readout while you solve, the door once it is over.
  local capText
  if generating then
    capText = "MAKING ONE"
  elseif game.solvedFlag then
    capText = "SOLVED"
  elseif notice then
    capText = notice
  else
    capText = (hasP and sudoku.emptyCount(game) or 81) .. " LEFT"
  end
  capsule(CAP_Y, capText, game.solvedFlag)
  if not generating and curR == 10 then frame(GX, CAP_Y, 9 * CELL, ROWH, 3) end
  rowButton(UNDO_Y, "UNDO", sudoku.canUndo(game) and not generating)
  if not generating and curR == 11 then frame(GX, UNDO_Y, 9 * CELL, ROWH, 3) end
  rowButton(HINT_Y, "HINT", not generating and not game.solvedFlag)
  if not generating and curR == 12 then frame(GX, HINT_Y, 9 * CELL, ROWH, 3) end
  gfx.text(W // 2, H - 44, "Move: all ways   Confirm: write   Back: menu", "small", "c")
  gfx.present()
end

-- The front door's ornament: the puzzle you have open, at a tenth the size.
local function mini(top)
  local side = math.min(W - 80, H - 44 - top)
  local cell = side // 9
  side = cell * 9
  local left = (W - side) // 2
  local top2 = top + ((H - 44 - top) - side) // 2
  for i = 1, 8 do
    local off = i * cell
    gfx.line(left, top2 + off, left + side, top2 + off)
    gfx.line(left + off, top2, left + off, top2 + side)
  end
  frame(left, top2, side, side, 1)
  if not hasGame or not game.puzzle then return end
  for i = 1, 81 do
    local r, c = (i - 1) // 9, (i - 1) % 9
    local x, y = left + c * cell, top2 + r * cell
    if sudoku.isGiven(game, i) then
      gfx.rect(x + 2, y + 2, cell - 4, cell - 4, true)
    elseif (game.entry[i] or 0) ~= 0 then
      frame(x + 2, y + 2, cell - 4, cell - 4, 2)
    end
  end
end

local function drawMenu()
  gfx.clear()
  header("SUDOKU", sudoku.LEVEL[menuLevel + 1])
  local offer = sudoku.menuOffer(game, hasGame, menuLevel)
  local rows = {
    "DIFFICULTY   " .. sudoku.LEVEL[menuLevel + 1],
    "HOW TO PLAY",
    offer == 1 and "RESUME" or "NEW PUZZLE",
  }
  -- The button and the caption are two renderings of ONE fact: the offer.
  for i = 1, 3 do
    local y = 100 + (i - 1) * 62
    if i == menuSel then gfx.rect(16, y, W - 32, 48, true) end
    gfx.text(32, y + 12, rows[i], "ui12", i == menuSel and "bw" or "b")
  end
  local state
  if offer == 1 then state = sudoku.emptyCount(game) .. " LEFT"
  elseif offer == 2 then state = "LAST ONE SOLVED"
  elseif offer == 3 then state = sudoku.LEVEL[menuLevel + 1] .. ", STARTING FRESH"
  else state = "NOT STARTED" end
  gfx.text(W // 2, 310, state, "ui12", "bc")
  local best = rec.best[menuLevel + 1]
  local line
  if best ~= 0 then
    line = sudoku.totalSolved(rec) .. " SOLVED   BEST " .. clockStr(best)
  else
    line = sudoku.totalSolved(rec) .. " SOLVED   NO " .. sudoku.LEVEL[menuLevel + 1] .. " TIME YET"
  end
  gfx.text(W // 2, 342, line, "small", "c")
  mini(390)
  gfx.text(W // 2, H - 44, "Up/Down move   Left/Right: difficulty   Back exits", "small", "c")
  gfx.present()
end

-- ------------------------------------------------------- how to play
-- Five lessons; a gesture is a change, so four of the pages show a small
-- board BEFORE and AFTER it, with an arrow between. '.' empty, '1'-'9' your
-- own digit, 'A'-'I' a printed clue, 'p' a pencilled cell, '!' a clash.
local LESSONS = {
  { title = "THE RULE", body = "EVERY ROW, COLUMN AND BOX HOLDS 1 TO 9.",
    detail = "NO DIGIT TWICE IN ANY OF THEM.", before = "123456789", after = nil, armed = 0 },
  { title = "WRITING", body = "PICK A DIGIT FROM THE PAD, THEN CONFIRM A CELL.",
    detail = "EVERY COPY OF IT IS MARKED.", before = "A.C.....I", after = "A.C.5...I", armed = 5 },
  { title = "CLEARING", body = "CONFIRM YOUR OWN DIGIT AGAIN TO RUB IT OUT.",
    detail = "CONFIRM A CLUE TO PICK ITS DIGIT UP.", before = "A.C.5...I", after = "A.C.....I", armed = 5 },
  { title = "PENCIL", body = "CONFIRM AN ARMED KEY TWICE, THEN CONFIRM A CELL.",
    detail = "CONFIRM AGAIN TO RUB IT OUT.", before = "A.C.....I", after = "A.C.p...I", armed = 0 },
  { title = "MISTAKES", body = "A DIGIT THAT CLASHES TURNS BLACK.",
    detail = "HINT NAMES A CELL YOU CAN SOLVE.", before = "A.C.5...I", after = "A.C!!...I", armed = 5 },
}

local function drawFace(ox, oy, side, face, armed)
  local cell = side // 3
  local grid = cell * 3
  local left = ox + (side - grid) // 2
  local top = oy + (side - grid) // 2
  for i = 0, 8 do
    local ch = face:sub(i + 1, i + 1)
    local x = left + (i % 3) * cell
    local y = top + (i // 3) * cell
    local clue = ch >= "A" and ch <= "I"
    local clash = ch == "!"
    if clash then
      gfx.rect(x, y, cell, cell, true)
    elseif clue then
      frame(x + 1, y + 1, cell - 2, cell - 2, 1)
    end
    frame(x, y, cell, cell, 1)
    local digit = ""
    if clue then
      digit = string.char(string.byte("1") + (ch:byte() - string.byte("A")))
    elseif ch >= "1" and ch <= "9" then
      digit = ch
    elseif clash then
      digit = tostring(armed)
    end
    if ch == "p" then
      local sub = cell // 3
      local lh2 = gfx.line_height("small")
      for _, d in ipairs({ 2, 6, 9 }) do
        local cc, rr = (d - 1) % 3, (d - 1) // 3
        gfx.text(x + 1 + cc * sub + sub // 2, y + 1 + rr * sub + (sub - lh2) // 2, tostring(d), "small", "c")
      end
    elseif digit ~= "" then
      local font = cell >= 32 and "sans18" or "ui12"
      gfx.text(x + cell // 2, y + (cell - gfx.line_height(font)) // 2, digit, font, clash and "bwc" or "bc")
      if armed ~= 0 and digit == tostring(armed) then
        local len = cell // 4
        gfx.rect(x, y, len, 2, true, not clash); gfx.rect(x, y, 2, len, true, not clash)
        gfx.rect(x + cell - len, y, len, 2, true, not clash); gfx.rect(x + cell - 2, y, 2, len, true, not clash)
        gfx.rect(x, y + cell - 2, len, 2, true, not clash); gfx.rect(x, y + cell - len, 2, len, true, not clash)
        gfx.rect(x + cell - len, y + cell - 2, len, 2, true, not clash)
        gfx.rect(x + cell - 2, y + cell - len, 2, len, true, not clash)
      end
    end
  end
end

local function drawHowTo()
  gfx.clear()
  local lesson = LESSONS[howPage]
  header("HOW TO PLAY", howPage .. " OF 5")
  gfx.text(W // 2, 84, lesson.title, "sans18", "bc")
  gfx.text(W // 2, 128, lesson.body, "ui12", "c")
  gfx.text(W // 2, 152, lesson.detail, "small", "c")
  local areaTop, areaBottom = 190, 690
  local roomH = areaBottom - areaTop
  if lesson.after then
    local arrow = 40
    local boardSide = math.min((roomH - arrow) // 2, W - 60)
    local left = (W - boardSide) // 2
    drawFace(left, areaTop, boardSide, lesson.before, lesson.armed)
    local midX, cy = W // 2, areaTop + boardSide
    gfx.rect(midX - 2, cy, 5, arrow // 2, true)
    for i = 0, 8 do
      gfx.rect(midX - (9 - i), cy + arrow // 2 + i, (9 - i) * 2, 1, true)
    end
    drawFace(left, areaTop + boardSide + arrow, boardSide, lesson.after, lesson.armed)
  else
    local side = math.min(roomH, W - 60)
    drawFace((W - side) // 2, areaTop + (roomH - side) // 2, side, lesson.before, lesson.armed)
  end
  gfx.rect(16, 708, W - 32, 48, true)
  gfx.text(W // 2, 708 + (48 - gfx.line_height("ui12")) // 2, howPage < 5 and "NEXT" or "GOT IT", "ui12", "bwc")
  gfx.text(W // 2, H - 44, "Confirm/Right: next   Left/Back: previous", "small", "c")
  gfx.present()
end

-- -------------------------------------------------------------- result
local function drawResult()
  gfx.clear()
  header("SOLVED", sudoku.LEVEL[game.puzzle.level + 1])
  gfx.text(W // 2, 100, clockStr(game.elapsedMs), "sans18", "bc")
  local under
  if game.hintsUsed > 0 then
    under = game.hintsUsed .. " HINT" .. (game.hintsUsed == 1 and "" or "S") .. ", SO NO TIME RECORDED"
  elseif newBest then
    under = "YOUR BEST " .. sudoku.LEVEL[game.puzzle.level + 1] .. " YET"
  elseif rec.best[game.puzzle.level + 1] ~= 0 then
    under = "YOUR BEST IS " .. clockStr(rec.best[game.puzzle.level + 1])
  else
    under = "UNAIDED"
  end
  gfx.text(W // 2, 160, under, "ui12", "bc")
  gfx.line(16, 200, W - 16, 200)
  gfx.text(W // 2, 220,
    string.format("%d CLUES   HARDEST %s   %d %s SOLVED", game.puzzle.clues,
      sudoku.TECH[game.puzzle.hardest + 1], rec.solved[game.puzzle.level + 1],
      sudoku.LEVEL[game.puzzle.level + 1]), "small", "c")
  for i = 1, 2 do
    local y = 264 + (i - 1) * 62
    local on = i == resultSel
    if on then gfx.rect(16, y, W - 32, 48, true) end
    gfx.text(W // 2, y + 12, i == 1 and "ANOTHER" or "BACK TO THE GRID", "ui12", on and "bwc" or "bc")
  end
  mini(414)
  gfx.present()
end

-- ------------------------------------------------------------ storage
-- One line of small integers, then the clues, then the player's digits, then
-- their marks as three hex digits each. The answer is not stored: the clues
-- determine it, so a save that cannot be solved is a corrupt save.
local function save()
  if not game.puzzle then return end
  local ok, err = pcall(function()
    local head = string.format("%d %d %d %d %d %d %d %d %d", 1, menuLevel, game.elapsedMs,
      game.hintsUsed, game.armed, game.hintCell, game.hintDigit, game.solvedFlag and 1 or 0,
      hasGame and 1 or 0)
    local recLine = string.format("%d %d %d %d %d %d %d %d %d",
      rec.solved[1], rec.solved[2], rec.solved[3], rec.solved[4],
      rec.best[1], rec.best[2], rec.best[3], rec.best[4], rec.hintsTaken)
    local clues, entries, notes = {}, {}, {}
    for i = 1, 81 do
      clues[i] = string.char(48 + game.puzzle.given[i])
      entries[i] = string.char(48 + (game.entry[i] or 0))
      notes[i] = string.format("%03X", game.note[i] or 0)
    end
    fs.write("data:sudoku.sav",
      head .. "\n" .. recLine .. "\n" .. table.concat(clues) .. "\n"
        .. table.concat(entries) .. "\n" .. table.concat(notes))
  end)
  if not ok then print("sudoku save:", tostring(err)) end
end

local function loadSave()
  local ok, raw = pcall(fs.read, "data:sudoku.sav")
  if not ok or type(raw) ~= "string" or #raw < 100 then return end
  local l1, l2, clues, entries, notes = raw:match("^(.-)\n(.-)\n(.-)\n(.-)\n(.-)\n?$")
  if not l1 or #clues ~= 81 or #entries ~= 81 or #notes ~= 243 then return end
  local h = {}
  for v in l1:gmatch("%d+") do h[#h + 1] = tonumber(v) end
  if #h ~= 9 or h[1] ~= 1 then return end
  local r2 = {}
  for v in l2:gmatch("%d+") do r2[#r2 + 1] = tonumber(v) end
  if #r2 ~= 9 then return end
  local given = {}
  for i = 1, 81 do
    local c = clues:byte(i) - 48
    if c < 0 or c > 9 then return end
    given[i] = c
  end
  -- Re-derive the answer: the puzzle has exactly one solution, so the clues
  -- determine it. A save that cannot be solved is discarded, not misread.
  local g = sudoku.newGrid()
  if not sudoku.load(g, given) then return end
  local rep = sudoku.solve(g, 10)
  if not rep.solved or rep.broken then return end
  local puzzle = { given = given, solution = {}, level = sudoku.levelOf(rep.hardest),
    hardest = rep.hardest, clues = 0 }
  for i = 1, 81 do
    puzzle.solution[i] = g.v[i]
    if given[i] ~= 0 then puzzle.clues = puzzle.clues + 1 end
  end
  local ng = sudoku.newGame()
  local entries2, notes2 = {}, {}
  for i = 1, 81 do
    local e = entries:byte(i) - 48
    if e < 0 or e > 9 then return end
    entries2[i] = given[i] ~= 0 and 0 or e
    local hx = tonumber(notes:sub(3 * i - 2, 3 * i), 16)
    notes2[i] = (hx or 0) & 0x1FF
  end
  -- Commit only at the end: a truncated file leaves a fresh app, not half a puzzle.
  ng.puzzle = puzzle
  ng.entry = entries2
  ng.note = notes2
  ng.elapsedMs = h[3] or 0
  ng.hintsUsed = h[4] or 0
  local armed = h[5] or 1
  ng.armed = (armed >= 1 and armed <= 9) and armed or 1
  local hc = h[6] or 0
  ng.hintCell = (hc >= 0 and hc <= 81) and hc or 0
  ng.hintDigit = h[7] or 0
  ng.solvedFlag = (h[8] or 0) ~= 0
  local nr = sudoku.newRecord()
  for i = 1, 4 do
    nr.solved[i] = r2[i] or 0
    nr.best[i] = r2[i + 4] or 0
  end
  nr.hintsTaken = r2[9] or 0
  game = ng
  hasGame = (h[9] or 0) ~= 0
  rec = nr
  resultRecorded = ng.solvedFlag
  local ml = h[2] or 0
  menuLevel = (ml >= 0 and ml <= 3) and ml or 0
  -- The menu opens on the level it is offering to resume; a level merely
  -- browsed before a restart is not worth carrying across one.
  if hasGame and not ng.solvedFlag then menuLevel = puzzle.level end
end

-- ------------------------------------------------------------ actions
local function recordResult()
  if resultRecorded then return end
  resultRecorded = true
  local level = game.puzzle.level
  local prevBest = rec.best[level + 1]
  sudoku.recordSolve(rec, level, game.elapsedMs, game.hintsUsed)
  newBest = game.hintsUsed == 0 and rec.best[level + 1] == game.elapsedMs and prevBest ~= game.elapsedMs
  save()
end

local function takeHint()
  local wrong = sudoku.firstWrong(game)
  if wrong ~= 0 then
    game.hintCell = wrong
    game.hintDigit = 0
    notice = "WRONG DIGIT"
    game.hintsUsed = game.hintsUsed + 1
    return
  end
  local board = {}
  for i = 1, 81 do board[i] = sudoku.valueAt(game, i) end
  local h = sudoku.nextHint(board, 10)
  if not h.found then
    notice = "NOTHING YET"
  else
    game.hintCell = h.cell
    game.hintDigit = h.digit
    game.hintTech = h.technique
    game.hintsUsed = game.hintsUsed + 1
    notice = sudoku.TECH[h.technique + 1]
  end
end

-- One door for RESUME and NEW PUZZLE: which one it is is a fact about the
-- save. Carving runs one pass of 24 attempts at a time, MAKING ONE on the
-- panel before the pass starts, so the main loop is never pinned for a whole
-- carve and Back cancels between passes.
local function beginGame()
  local level = menuLevel
  generating = true
  drawBoard()
  local out = {}
  local work = sudoku.newWork()
  while true do
    if sudoku.generate(out, level, work, rng, 24) then break end
    local ev = input.poll()
    if ev == "back" then
      generating = false
      screen = "menu"
      menuSel = 3
      drawMenu()
      return
    end
    app.sleep(40)
  end
  generating = false
  game = sudoku.newGame()
  sudoku.startGame(game, out)
  hasGame = true
  resultRecorded = false
  newBest = false
  curR, curC = 0, 0
  pencil = false
  notice = nil
  save()
  lastTick = system.millis()
  screen = "board"
  drawBoard()
end

local function handleBoard(ev)
  if ev == "up" then curR = math.max(0, curR - 1)
  elseif ev == "down" then curR = math.min(12, curR + 1)
  elseif ev == "left" then curC = math.max(0, curC - 1)
  elseif ev == "right" then curC = math.min(8, curC + 1)
  elseif ev == "confirm" then
    if curR <= 8 then
      local cell = curR * 9 + curC + 1
      if pencil then
        sudoku.holdCell(game, cell)
        pencil = false
        notice = nil
      else
        sudoku.tapCell(game, cell)
        notice = nil
        if game.solvedFlag then recordResult() end
      end
    elseif curR == 9 then
      local d = curC + 1
      if d == game.armed then
        if pencil then pencil = false notice = nil else pencil = true notice = "PENCIL" end
      else
        game.armed = d
        pencil = false
        notice = nil
      end
    elseif curR == 10 then
      if game.solvedFlag then screen = "result" resultSel = 1 drawResult() return end
    elseif curR == 11 then
      if sudoku.canUndo(game) then
        sudoku.undoOnce(game)
        notice = nil
      end
    elseif curR == 12 then
      if not game.solvedFlag then takeHint() end
    end
  elseif ev == "back" then
    save()
    screen = "menu"
    menuSel = 3
    drawMenu()
    return
  end
  drawBoard()
end

local function handleMenu(ev)
  if ev == "up" then
    menuSel = menuSel > 1 and menuSel - 1 or 3
  elseif ev == "down" then
    menuSel = menuSel < 3 and menuSel + 1 or 1
  elseif ev == "left" or ev == "right" then
    if menuSel == 1 then menuLevel = (menuLevel + (ev == "right" and 1 or 3)) % 4 end
  elseif ev == "confirm" then
    if menuSel == 1 then
      menuLevel = (menuLevel + 1) % 4
    elseif menuSel == 2 then
      howPage = 1
      screen = "howto"
      drawHowTo()
      return
    elseif sudoku.canResume(game, hasGame, menuLevel) then
      curR, curC = 0, 0
      pencil = false
      notice = nil
      lastTick = system.millis()
      screen = "board"
      drawBoard()
      return true
    else
      beginGame()
      return true
    end
  elseif ev == "back" then
    save()
    return false
  end
  drawMenu()
  return true
end

local function handleHowTo(ev)
  if ev == "confirm" or ev == "right" or ev == "down" then
    if howPage < 5 then howPage = howPage + 1 else screen = "menu" menuSel = 3 end
  elseif ev == "back" or ev == "left" or ev == "up" then
    if howPage > 1 then howPage = howPage - 1 else screen = "menu" menuSel = 3 end
  end
  if screen == "howto" then drawHowTo() else drawMenu() end
end

local function handleResult(ev)
  if ev == "up" then
    resultSel = 1
  elseif ev == "down" then
    resultSel = 2
  elseif ev == "confirm" then
    if resultSel == 1 then
      menuLevel = game.puzzle.level
      beginGame()
      return
    else
      screen = "board"
      drawBoard()
      return
    end
  elseif ev == "back" then
    screen = "board"
    drawBoard()
    return
  end
  drawResult()
end

-- ---------------------------------------------------------- entry point
local function seed()
  local ok, bytes = pcall(crypto.random, 4)
  if ok and type(bytes) == "string" and #bytes >= 4 then
    local s = 0
    for i = 1, 4 do s = ((s << 8) | bytes:byte(i)) & 0xFFFFFFFF end
    return s
  end
  return (system.millis() & 0xFFFFFFFF) | 1
end

local function __main()
  sudoku = require("sudoku")
  game = sudoku.newGame()
  rec = sudoku.newRecord()
  rng = sudoku.newRng(seed())
  loadSave()
  drawMenu()
  while true do
    local ev = input.wait()
    local now = system.millis()
    -- No clock is drawn while you solve; it is recorded and shown once, at the end.
    if screen == "board" and not generating and game.puzzle and not game.solvedFlag then
      game.elapsedMs = game.elapsedMs + (now - lastTick)
    end
    lastTick = now
    if screen == "board" then
      handleBoard(ev)
    elseif screen == "menu" then
      if not handleMenu(ev) then break end
    elseif screen == "howto" then
      handleHowTo(ev)
    else
      handleResult(ev)
    end
  end
  save()
end

local ok, err = pcall(__main)
if not ok then
  gfx.clear()
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b")
  gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()