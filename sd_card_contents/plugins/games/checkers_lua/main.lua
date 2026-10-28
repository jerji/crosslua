-- Checkers (English draughts) for the X4, ported from crossplay's checkers
-- (CheckersCore/CheckersBrain/CheckersFlow/CheckersScreens). You are LIGHT and
-- move first; the device plays DARK via the ported two-ply brain.
--
-- Seven-button controls: a cursor moves over the board, Confirm lifts the
-- piece under it and places it again on a marked landing, Back drops it.
-- The compulsory-capture rule is said out loud AND drawn: every piece with a
-- move gets corner marks (under a mandatory capture that set collapses to the
-- taking pieces only), the capsule reads "YOU MUST TAKE", and a rejected
-- Confirm does not repaint. A piece in hand shows a dot on each landing and
-- corner marks on every enemy that landing captures.
local ck = require("checkers")
local nearby = require("nearby")
local wire = require("wire")
local GAME_ID = 0x0601

local LIGHT, DARK = ck.LIGHT, ck.DARKSEAT
-- The seat this device plays, and whether the board is drawn from DARK's side.
-- Solo is always LIGHT and unflipped; a nearby match sets both per round.
local me, flipped = LIGHT, false

-- ---------------------------------------------------------------- geometry
local W, H = gfx.size()
local SQ = 56                      -- square px: eight of them = the 448px board
local BOARD = SQ * 8
local LEFT = (W - BOARD) // 2      -- 16
local TOP = 65                     -- below the 40px header band
local FRAME = 9

local function squareXY(i)
  local f, r = ck.fileOf(i), ck.rankOf(i)
  if flipped then f, r = 7 - f, 7 - r end
  return LEFT + f * SQ, TOP + r * SQ
end

local function dither(x, y, sq)
  for dy = 2, sq - 8, 8 do
    for dx = 2, sq - 8, 8 do gfx.pixel(x + dx, y + dy) end
  end
end

-- ---------------------------------------------------------------- pieces
local function discAt(cx, cy, d, filled)
  gfx.rounded_rect(cx - d // 2, cy - d // 2, d, d, d // 2, true, true)
  gfx.rounded_rect(cx - d // 2, cy - d // 2, d, d, d // 2, true, filled)
end

-- A round piece at square (x0,y0) of size s. Filled = dark, same convention as
-- the rest of the fork; a king carries the concentric ring of the stacked
-- second piece.
local function pieceAt(x0, y0, s, c)
  local cx, cy = x0 + s // 2, y0 + s // 2
  local d = math.floor(s * 46 / 56 + 0.5)
  local filled = ck.isDark(c)
  discAt(cx, cy, d, filled)
  if ck.isKing(c) then
    discAt(cx, cy, d // 2, not filled)
    discAt(cx, cy, math.max(d // 2 - 6, 2), filled)
  end
end

-- Corner marks on the edges of square (x,y): the movable-piece bracket, the
-- "this landing takes THAT piece" bracket, and the in-hand mark.
local function cornerMarks(x, y, sq, len, thick)
  local h = len - thick
  gfx.rect(x, y, h, thick, true)
  gfx.rect(x, y, thick, h, true)
  gfx.rect(x + sq - h, y, h, thick, true)
  gfx.rect(x + sq - thick, y, thick, h, true)
  gfx.rect(x, y + sq - thick, h, thick, true)
  gfx.rect(x, y + sq - h, thick, h, true)
  gfx.rect(x + sq - h, y + sq - thick, h, thick, true)
  gfx.rect(x + sq - thick, y + sq - h, thick, h, true)
end

-- The selection frame, drawn OUTSIDE its square so the piece is not eaten.
local function frameCursor(x, y, t)
  gfx.rect(x - t, y - t, SQ + 2 * t, t, true)
  gfx.rect(x - t, y + SQ, SQ + 2 * t, t, true)
  gfx.rect(x - t, y - t, t, SQ + 2 * t, true)
  gfx.rect(x + SQ, y - t, t, SQ + 2 * t, true)
end

local function miniBoard(left, top, cell, cells)
  local side = cell * 8
  gfx.rect(left - 6, top - 6, side + 12, side + 12, true)
  for i = 1, 64 do
    local x, y = left + ck.fileOf(i) * cell, top + ck.rankOf(i) * cell
    gfx.rect(x, y, cell, cell, true, false)
    if ck.playable(ck.fileOf(i), ck.rankOf(i)) then dither(x, y, cell) end
    local c = cells[i]
    if c ~= 0 then pieceAt(x, y, cell, c) end
  end
end

-- ---------------------------------------------------------------- utilities
local function wrap(s, n)
  local out, line = {}, ""
  for word in s:gmatch("[^ ]+") do
    if line == "" then line = word
    elseif #line + 1 + #word <= n then line = line .. " " .. word
    else out[#out + 1] = line line = word end
  end
  if line ~= "" then out[#out + 1] = line end
  return out
end

local function packCells(g)
  local s = {}
  for i = 1, 64 do s[i] = string.format("%x", g.cell[i]) end
  return table.concat(s)
end

local function unpackCells(s)
  local t = {}
  for i = 1, 64 do t[i] = tonumber(s:sub(i, i), 16) end
  return t
end

-- ---------------------------------------------------------------- persistence
local STATS_PATH = "data:checkers_stats.json"
local stats = { played = 0, won = 0, last = nil }
do
  local raw = fs.read(STATS_PATH)
  local st = raw and json.decode(raw)
  if type(st) == "table" then
    if type(st.played) == "number" then stats.played = st.played end
    if type(st.won) == "number" then stats.won = st.won end
    if type(st.last) == "table" and type(st.last.cells) == "string" and #st.last.cells == 64 then
      stats.last = st.last
    end
  end
end
local function saveStats()
  fs.write(STATS_PATH, json.encode({
    played = stats.played, won = stats.won,
    last = stats.last and { cells = stats.last.cells, outcome = stats.last.outcome,
                            you = stats.last.you, them = stats.last.them } or nil,
  }))
end

-- ---------------------------------------------------------------- header
local function header(title)
  gfx.rect(0, 0, W, 40, true)
  gfx.text(16, 11, title, "sans16", "bw")
end

local function capsule(text)
  gfx.rect(0, H - 48, W, 48, true)
  gfx.text(W // 2, H - 38, text, "sans16", "cwb")
end

-- ---------------------------------------------------------------- menu
local function menu()
  local sel = 0
  local rows = { "PLAY", "PLAY NEARBY", "HOW TO PLAY" }
  while true do
    gfx.clear()
    header("CHECKERS")
    gfx.text(16, 56, string.format("%d PLAYED   %d WON", stats.played, stats.won), "ui12", "b")
    gfx.rect(16, 78, W - 32, 2, true)
    -- the last game's final position (or the opening, when none is recorded),
    -- held where the eye rests, with one line saying how it ended
    if stats.last then
      miniBoard((W - 272) // 2, 130, 34, unpackCells(stats.last.cells))
      local cap = "LAST GAME: A DRAW"
      local margin = stats.last.you - stats.last.them
      if stats.last.outcome == "light" then
        cap = margin > 0 and string.format("LAST GAME: WON BY %d", margin) or "LAST GAME: WON"
      elseif stats.last.outcome == "dark" then
        cap = margin < 0 and string.format("LAST GAME: LOST BY %d", -margin) or "LAST GAME: LOST"
      end
      gfx.text(W // 2, 402 + 16, cap, "ui12", "c")
    else
      miniBoard((W - 272) // 2, 130, 34, ck.start().cell)
      gfx.text(W // 2, 402 + 16, "ENGLISH DRAUGHTS", "ui12", "c")
    end
    for i = 1, #rows do
      local y = H - 220 + (i - 1) * 48
      local selected = i - 1 == sel
      if selected then gfx.rounded_rect(48, y, W - 96, 40, 8, true) end
      gfx.text(W // 2, y + 9, rows[i], "sans16", selected and "cwb" or "cb")
    end
    gfx.text(W // 2, H - 84, "Up/Down = choose   Confirm = open   Back = exit", "small", "c")
    gfx.present()
    local ev = input.wait()
    if ev == "back" then return nil end
    if ev == "up" then sel = (sel - 1) % #rows
    elseif ev == "down" then sel = (sel + 1) % #rows
    elseif ev == "confirm" then return ({ "play", "nearby", "howto" })[sel + 1] end
  end
end

-- ---------------------------------------------------------------- how to play
local function howTo()
  local page = 0
  local titles = { "MEN AND CROWNS", "TAKING", "KINGS" }
  local caps = {
    "MEN STEP DIAGONALLY FORWARD. REACH THE FAR ROW AND A MAN IS CROWNED.",
    "IF YOU CAN TAKE, YOU MUST. A CHAIN OF JUMPS IS ONE MOVE.",
    "A CROWNED PIECE MOVES BOTH WAYS. NO MOVES LEFT MEANS YOU HAVE LOST.",
  }
  while true do
    gfx.clear()
    header("HOW TO PLAY")
    gfx.text(W - 16, 11, string.format("%d OF %d", page + 1, #titles), "ui12", "bwr")
    gfx.text(W // 2, 66, titles[page + 1], "sans18", "bc")
    -- the lesson, a 3x3 window of the live board's own language
    local cell, top = 88, 130
    local side = cell * 3
    local left = (W - side) // 2
    local darkParity = page == 0 and 1 or 0
    for row = 0, 2 do
      for col = 0, 2 do
        local x, y = left + col * cell, top + row * cell
        gfx.rect(x, y, cell, cell, true, false)
        if ((col + row) & 1) == darkParity then dither(x, y, cell) end
        gfx.rect(x, y, cell, cell, false)
      end
    end
    local function put(col, row, c) pieceAt(left + col * cell, top + row * cell, cell, c) end
    local function dot(col, row)
      discAt(left + col * cell + cell // 2, top + row * cell + cell // 2, math.floor(cell * 18 / 56 + 6), true)
    end
    local function marks(col, row) cornerMarks(left + col * cell, top + row * cell, cell, 20, 4) end
    if page == 0 then
      put(1, 2, ck.PIECE) put(1, 0, ck.PIECE | ck.KING)
      dot(0, 1) dot(2, 1)
    elseif page == 1 then
      put(0, 2, ck.PIECE) put(1, 1, ck.PIECE | ck.DARK)
      marks(1, 1)
      dot(2, 0)
    else
      put(1, 1, ck.PIECE | ck.KING)
      dot(0, 0) dot(2, 0) dot(0, 2) dot(2, 2)
    end
    local lines = wrap(caps[page + 1], 34)
    for i, l in ipairs(lines) do
      gfx.text(W // 2, top + side + 24 + (i - 1) * 17, l, "ui12", "c")
    end
    local dotY = H - 110
    for i = 1, #titles do
      local dx = W // 2 - (#titles * 14 + (#titles - 1) * 10) // 2 + (i - 1) * 24
      if i - 1 == page then gfx.rect(dx, dotY, 14, 14, true) else gfx.rect(dx, dotY, 14, 14, false) end
    end
    gfx.text(W // 2, dotY + 30,
             page + 1 == #titles and "Confirm = finish   Back = menu" or "Confirm = next   Back = menu", "small", "c")
    gfx.present()
    local ev = input.wait()
    if ev == "back" then return end
    if ev == "confirm" then
      if page + 1 == #titles then return end
      page = page + 1
    end
  end
end

-- ---------------------------------------------------------------- the board
local function stripRow(cy, label, n, filled)
  gfx.text(LEFT, cy - 9, label, "ui12", "b")
  for i = 0, n - 1 do
    local cx = LEFT + 72 + 11 + i * 28
    discAt(cx, cy, 22, true)
    discAt(cx, cy, 18, filled)
  end
end

-- One draw of the playing board. ml is the single move list the capsule and
-- the movable marks both read, so they cannot disagree.
local function drawBoard(g, cursor, picked, hint, busy)
  gfx.clear()
  header("CHECKERS")
  gfx.rect(LEFT - FRAME, TOP - FRAME, BOARD + FRAME * 2, BOARD + FRAME * 2, true)
  for i = 1, 64 do
    local x, y = squareXY(i)
    gfx.rect(x, y, SQ, SQ, true, false)
    if ck.playable(ck.fileOf(i), ck.rankOf(i)) then dither(x, y, SQ) end
    local c = g.cell[i]
    if c ~= 0 then pieceAt(x, y, SQ, c) end
  end

  -- Corner marks on every piece that CAN move, whenever nothing is in hand.
  -- Under a compulsory capture that set collapses to the taking pieces, so
  -- the board demonstrates the rule instead of describing it.
  local ml = nil
  if not busy and g.turn == me and not ck.over(g) then ml = ck.moves(g) end
  if ml and not picked then
    for i = 1, #ml do
      local x, y = squareXY(ml[i].from)
      cornerMarks(x, y, SQ, 14, 3)
    end
  end

  -- A piece in hand: a dot on each landing, corner marks on each enemy that
  -- landing captures, and the in-hand mark on the piece itself.
  if picked then
    for _, d in ipairs(ck.destinations(g, picked)) do
      local x, y = squareXY(d.to)
      discAt(x + SQ // 2, y + SQ // 2, 18, true)
      for k = 1, #d.taken do
        local tx, ty = squareXY(d.taken:byte(k) + 1)
        cornerMarks(tx, ty, SQ, 18, 4)
      end
    end
    local x, y = squareXY(picked)
    cornerMarks(x, y, SQ, 20, 5)
  end

  -- The cursor frame, thicker while it sits on the piece in hand.
  local cx, cy = squareXY(cursor)
  frameCursor(cx, cy, picked and picked == cursor and 6 or 4)

  -- The material strips: remaining pieces, theirs nearest the board, yours
  -- nearest you. Am I up or down is answered by which row is longer.
  local stripTop = TOP + BOARD + FRAME + 20
  stripRow(stripTop, "THEM", ck.pieceCount(g, 1 - me), true)
  stripRow(stripTop + 38, "YOU", ck.pieceCount(g, me), false)

  local status
  if busy then
    status = "THINKING..."
  elseif g.turn ~= me then
    status = "THEIR MOVE"
  else
    status = (ml and #ml > 0 and #ml[1].taken > 0) and "YOU MUST TAKE" or "YOUR MOVE"
  end
  capsule(status)
  if hint then gfx.text(W // 2, stripTop + 100, hint, "small", "c") end
  gfx.present()
end

local function moveCursor(c, ev)
  if flipped then ev = ({ up = "down", down = "up", left = "right", right = "left" })[ev] or ev end
  local f0, r0 = ck.fileOf(c), ck.rankOf(c)
  if ev == "up" then r0 = (r0 + 7) % 8
  elseif ev == "down" then r0 = (r0 + 1) % 8
  elseif ev == "left" then f0 = (f0 + 7) % 8
  else f0 = (f0 + 1) % 8 end
  return ck.indexOf(f0, r0)
end

-- One game against the device. Returns the finished game, or nil when the
-- player abandoned it back to the menu.
local function playGame()
  me, flipped = LIGHT, false
  local g = ck.start()
  local cursor, picked = 41, nil   -- (0,5): a movable man on the first turn
  local aiTurn, dirty = false, true
  while true do
    if ck.over(g) then return g end
    if aiTurn then
      drawBoard(g, cursor, nil, nil, true)
      local bm = ck.chooseMove(g)
      if bm then ck.apply(g, bm) end
      aiTurn = false
      dirty = true
    end
    if dirty then
      dirty = false
      drawBoard(g, cursor, picked,
                picked and "Confirm = place   Back = drop" or "Confirm = lift a piece   Back = menu")
    end
    local ev = input.wait()
    if ev == "back" then
      if picked then
        picked = nil
        dirty = true
      else
        return nil
      end
    elseif ev == "up" or ev == "down" or ev == "left" or ev == "right" then
      cursor = moveCursor(cursor, ev)
      dirty = true
    elseif ev == "confirm" then
      if not picked then
        -- No piece and no legal move: rejected tap, nothing changes, and
        -- nothing repaints (a refresh that changes nothing is what a bug
        -- looks like).
        if ck.canPick(g, cursor) then picked = cursor dirty = true end
      else
        local m = ck.moveBetween(g, picked, cursor)
        if m then
          ck.apply(g, m)
          picked = nil
          dirty = true
          if not ck.over(g) then aiTurn = true end
        end
      end
    end
  end
end

-- ---------------------------------------------------------------- result
local function resultScreen(g)
  local oc = ck.outcome(g)
  local won, draw = oc == "light", oc == "draw"
  local you, them = ck.pieceCount(g, LIGHT), ck.pieceCount(g, DARK)
  stats.played = stats.played + 1
  if won then stats.won = stats.won + 1 end
  stats.last = { cells = packCells(g), outcome = oc, you = you, them = them }
  saveStats()
  while true do
    gfx.clear()
    header(draw and "A DRAW" or (won and "YOU WIN" or "THEY WIN"))
    -- the finished game is the thing you want to look at
    miniBoard((W - 320) // 2, 56, 40, g.cell)
    gfx.text(W // 2, 56 + 320 + 28, string.format("%d - %d", you, them), "sans18", "bc")
    if draw then
      local lines = wrap("FORTY MOVES EACH WITH NOTHING TAKEN.", 30)
      for i, l in ipairs(lines) do
        gfx.text(W // 2, 56 + 320 + 74 + (i - 1) * 17, l, "ui12", "c")
      end
    end
    gfx.text(W // 2, H - 100, "Confirm = play again   Back = menu", "small", "c")
    gfx.present()
    local ev = input.wait()
    if ev == "back" then return false end
    if ev == "confirm" then return true end
  end
end

-- ---------------------------------------------------------------- PLAY NEARBY
-- Two devices over ESP-NOW (nearby.lua). The whole board travels as the 67-byte
-- game blob (wire.lua), so a move is the board after it. The side that moves
-- first in a round plays LIGHT; the first mover flips each round, and both
-- devices flip on the same rematch exchange.

local function linkWaitScreen()
  gfx.clear()
  header("CHECKERS")
  gfx.text(W // 2, 220, "LOOKING FOR A PLAYER", "sans18", "bc")
  gfx.text(W // 2, 256, "Turn on PLAY NEARBY on the other device.", "ui12", "c")
  capsule("BACK = CANCEL")
  gfx.present()
end

local function linkEndScreen(S)
  gfx.clear()
  header("CHECKERS")
  gfx.text(W // 2, 220, S.reason == "lost" and "LOST CONNECTION" or "THEY LEFT", "sans18", "bc")
  capsule("CONFIRM OR BACK: MENU")
  gfx.present()
end

local function linkResultScreen(g, sel, myAgain, peerAgain)
  gfx.clear()
  local oc = ck.outcome(g)
  local title
  if oc == "draw" then title = "A DRAW"
  elseif (oc == "light") == (me == LIGHT) then title = "YOU WIN"
  else title = "THEY WIN" end
  header(title)
  miniBoard((W - 320) // 2, 56, 40, g.cell)
  gfx.text(W // 2, 56 + 320 + 28, string.format("%d - %d", ck.pieceCount(g, me), ck.pieceCount(g, 1 - me)), "sans18", "bc")
  if myAgain then
    gfx.text(W // 2, 56 + 320 + 62, "WAITING FOR THEM", "ui12", "c")
  elseif peerAgain then
    gfx.text(W // 2, 56 + 320 + 62, "THEY WANT ANOTHER GAME", "ui12", "c")
  end
  gfx.text(W // 2, H - 118, (sel == 1 and "> " or "  ") .. "PLAY AGAIN", "sans16", "c")
  gfx.text(W // 2, H - 88, (sel == 2 and "> " or "  ") .. "LEAVE", "sans16", "c")
  gfx.present()
end

-- One linked session, from the search screen to leaving. Returns to the menu.
local function linkedPlay()
  local S = nearby.new(GAME_ID, "PUP " .. string.sub(system.mac(), 16, 17))
  local ok, err = S:start()
  if not ok then
    gfx.clear()
    header("CHECKERS")
    gfx.text(16, 100, "RADIO WILL NOT START", "sans16", "b")
    gfx.text(16, 130, tostring(err):sub(1, 60), "ui12", "b")
    capsule("BACK = MENU")
    gfx.present()
    while input.wait() ~= "back" do end
    return
  end

  local mode = "search"          -- search | board | result | linkend
  local meFirst = false          -- I move first this round
  local g, cursor, picked = nil, 41, nil
  local resultSel, myAgain = 1, false
  local dirty = true

  local function newRound()
    me = meFirst and LIGHT or DARK
    flipped = me == DARK
    g = ck.start()
    cursor = me == LIGHT and 41 or 18
    picked = nil
    resultSel, myAgain = 1, false
    S:newRound()
    mode = "board"
    dirty = true
  end

  while true do
    local now = system.millis()
    S:pump(now)
    S:tick(now)
    if S:takeMatch() then
      meFirst = S.iFirst
      newRound()
    end
    local blob = S:takeState()
    if blob and mode ~= "search" then
      local ng = wire.unpack(blob)
      if ng then
        -- their first move of a new round can land before my own flip for
        -- that round: start the round here, then take the move
        if mode == "result" and not ck.over(ng) then
          meFirst = not meFirst
          newRound()
        end
        g, picked = ng, nil
        mode = ck.over(g) and "result" or "board"
        dirty = true
      end
    end
    if S.phase == "ended" and mode ~= "linkend" then
      mode = "linkend"
      dirty = true
    end
    -- both said PLAY AGAIN: start the next round, the first mover flipping
    if mode == "result" and myAgain and S.peerAgain then
      meFirst = not meFirst
      newRound()
    end

    if dirty then
      dirty = false
      if mode == "search" then
        linkWaitScreen()
      elseif mode == "board" then
        local hint = "Back = leave"
        if picked then hint = "Confirm = place   Back = drop" end
        drawBoard(g, cursor, picked, hint, false)
      elseif mode == "result" then
        linkResultScreen(g, resultSel, myAgain, S.peerAgain)
      else
        linkEndScreen(S)
      end
    end

    local ev = input.wait(100)
    if ev == "back" then
      if mode == "board" and picked then
        picked = nil
        dirty = true
      else
        break
      end
    elseif ev == "up" or ev == "down" or ev == "left" or ev == "right" then
      if mode == "board" then
        cursor = moveCursor(cursor, ev)
        dirty = true
      elseif mode == "result" and (ev == "left" or ev == "right") then
        resultSel = 3 - resultSel
        dirty = true
      end
    elseif ev == "confirm" then
      if mode == "board" and g.turn == me and not ck.over(g) then
        if not picked then
          if ck.canPick(g, cursor) then
            picked = cursor
            dirty = true
          end
        else
          local m = ck.moveBetween(g, picked, cursor)
          if m then
            ck.apply(g, m)
            picked = nil
            S:sendState(system.millis(), wire.pack(g))
            mode = ck.over(g) and "result" or "board"
            dirty = true
          end
        end
      elseif mode == "result" then
        if resultSel == 1 then
          if not myAgain then
            myAgain = true
            S:say(system.millis(), nearby.NOTE_PLAY_AGAIN)
            dirty = true
          end
        else
          break
        end
      elseif mode == "linkend" then
        break
      end
    end
  end
  S:stop(system.millis())
  me, flipped = LIGHT, false
end

-- ---------------------------------------------------------------- entry
local function __main()
  W, H = gfx.size()
  while true do
    local choice = menu()
    if choice == nil then break end
    if choice == "howto" then
      howTo()
    elseif choice == "nearby" then
      linkedPlay()
    else
      local g = playGame()
      while g do
        if not resultScreen(g) then break end
        g = playGame()
      end
    end
  end
  saveStats()
  app.exit()
end
local ok, err = pcall(__main)
if not ok then
  gfx.clear() gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b") gfx.present()
  while input.wait() ~= "back" do end
  app.exit()
end