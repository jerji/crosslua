-- Hex for the X4 (see docs/apps/hex.md in crossplay). Eleven by eleven, no
-- captures, no draws. Black joins the top and bottom edges, White joins the
-- left and right. You play against a flat Monte Carlo search at three levels,
-- or pass the device across for two players.
--
-- Controls: the arrows move the cursor over the cells, Confirm places a stone
-- on the cursor (one tap, no second tap), Back opens the pause menu.
local core = require("hexcore")
local brain = require("brain")
local nearby = require("nearby")
local wire = require("wire")
local GAME_ID = 0x0B01

local W, H = gfx.size()
local HEADER, CAPSULE = 40, 48
local R = 23                        -- vertex radius of a cell (centre to corner)
local S3 = 0.8660254                -- sqrt(3) / 2
local X0, Y0                        -- centre of cell 1 (top left of the board)
local VX, VY = {}, {}               -- the six corners, relative to a centre
local COLS = core.N

local SAVE = "data:hex.sav"
local prefs = { level = 2, mode = 1, you = 1 }    -- mode 1 computer, 2 two players
local stats = { won = 0, played = 0 }
local game = nil

-- ---------------------------------------------------------------- geometry
local function layout()
  R = math.min(R, (W - 16) // 17)
  local boardH = 27.7 * R
  local top = HEADER + math.floor((H - HEADER - CAPSULE - boardH) / 2)
  Y0 = top + S3 * R
  X0 = (W - 17 * R) // 2 + R
  local ang = { 0, 60, 120, 180, 240, 300 }
  for k = 1, 6 do
    local a = math.rad(ang[k])
    VX[k - 1] = R * math.cos(a)
    VY[k - 1] = R * math.sin(a)
  end
end

local function centre(i)
  local r, c = core.ROW[i] - 1, core.COL[i] - 1
  return X0 + 1.5 * R * c, Y0 + 2 * S3 * R * r + S3 * R * c
end

-- Outline of a flat-top hexagon of radius rr at (cx, cy); `t` = thickness.
local function outline(cx, cy, rr, black, t)
  local f = rr / R
  for d = 0, (t or 1) - 1 do
    for k = 0, 5 do
      local k2 = (k + 1) % 6
      gfx.line(cx + VX[k] * f + d, cy + VY[k] * f + d,
               cx + VX[k2] * f + d, cy + VY[k2] * f + d, black)
    end
  end
end

-- Filled hexagon: one horizontal line per row, half-width from the flat-top
-- geometry (vertex at +-rr, flat edges at +-S3*rr).
local function fillHex(cx, cy, rr, black)
  local hv = math.floor(S3 * rr)
  for dy = -hv, hv do
    local hw = rr - math.abs(dy) / 1.7320508
    gfx.line(math.floor(cx - hw), math.floor(cy + dy), math.floor(cx + hw), math.floor(cy + dy), black)
  end
end

-- The two edges each colour joins are drawn thick, so the board says which
-- way each colour is playing without a legend.
local function edges(second, cx, cy)
  for _, pair in ipairs(second) do
    local a, b = pair[1], pair[2]
    for d = -1, 1 do
      gfx.line(cx + VX[a] + d, cy + VY[a], cx + VX[b] + d, cy + VY[b], true)
      gfx.line(cx + VX[a], cy + VY[a] + d, cx + VX[b], cy + VY[b] + d, true)
    end
  end
end

local BLACK_EDGE = { { 4, 5 } }       -- top, drawn on row 1
local BLACK_EDGE_BOTTOM = { { 1, 2 } } -- bottom, drawn on row 11
local WHITE_EDGE_LEFT = { { 2, 3 }, { 3, 4 } }
local WHITE_EDGE_RIGHT = { { 5, 0 }, { 0, 1 } }

local function drawBoard(g)
  local b = g.cells
  for i = 1, core.POINTS do
    local cx, cy = centre(i)
    outline(cx, cy, R, true, 1)
    if b[i] == core.BLACK then
      fillHex(cx, cy, R - 3, true)
    elseif b[i] == core.WHITE then
      outline(cx, cy, R - 4, true, 2)
    end
    if g.last == i and b[i] ~= 0 then
      fillHex(cx, cy, 5, b[i] == core.WHITE)
    end
  end
  for c = 1, COLS do
    local cx, cy = centre(core.index(1, c))
    edges(BLACK_EDGE, cx, cy)
    cx, cy = centre(core.index(COLS, c))
    edges(BLACK_EDGE_BOTTOM, cx, cy)
  end
  for r = 1, COLS do
    local cx, cy = centre(core.index(r, 1))
    edges(WHITE_EDGE_LEFT, cx, cy)
    cx, cy = centre(core.index(r, COLS))
    edges(WHITE_EDGE_RIGHT, cx, cy)
  end
  -- cursor: two rings outside the cell, so a stone under it stays readable
  local cx, cy = centre(g.cur)
  outline(cx, cy, R + 1, true, 2)
end

-- ---------------------------------------------------------------- text
local function header(title, right)
  gfx.rect(0, 0, W, HEADER, true)
  gfx.text(16, 11, title, "sans16", "bw")
  if right then gfx.text(W - 16, 13, right, "sans12", "rw") end
end

local function capsule(text)
  gfx.rect(0, H - CAPSULE, W, CAPSULE, true)
  gfx.text(W // 2, H - CAPSULE + 14, text, "sans14", "cwb")
end

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

-- ---------------------------------------------------------------- persistence
local function save()
  local cells = (game and not game.finished) and core.pack(game.cells) or "-"
  local turn = game and game.turn or 1
  fs.write(SAVE, string.format("v1 %s %d %d %d %d %d %d", cells, turn,
    prefs.you, prefs.level, prefs.mode, stats.won, stats.played))
end

local function load()
  local raw = fs.read(SAVE)
  if not raw then return nil end
  local cells, turn, you, level, mode, won, played =
    raw:match("^v1 (%S+) (%d+) (%d+) (%d+) (%d+) (%d+) (%d+)")
  if not cells then return nil end
  turn, you, level, mode = tonumber(turn), tonumber(you), tonumber(level), tonumber(mode)
  if you ~= 1 and you ~= 2 then you = 1 end
  if level and level >= 1 and level <= #brain.LEVELS then prefs.level = level end
  if mode == 1 or mode == 2 then prefs.mode = mode end
  prefs.you = you
  stats.won = tonumber(won) or 0
  stats.played = tonumber(played) or 0
  local b = core.unpack(cells)
  if not b or (turn ~= 1 and turn ~= 2) then return nil end
  return { cells = b, turn = turn, cur = core.index(6, 6), finished = false, winner = nil, last = nil }
end

-- ---------------------------------------------------------------- game
local function newGame()
  game = { cells = core.newBoard(), turn = 1, cur = core.index(6, 6), finished = false, winner = nil, last = nil }
  save()
end

local function computerColour()
  return core.other(prefs.you)
end

local function finish(winner)
  game.finished = true
  game.winner = winner
  if prefs.mode == 1 then
    stats.played = stats.played + 1
    if winner == prefs.you then stats.won = stats.won + 1 end
  end
  save()
end

local function place(i)
  local g = game
  g.cells[i] = g.turn
  g.last = i
  if core.connected(g.cells, g.turn) then
    finish(g.turn)
  else
    g.turn = core.other(g.turn)
    save()
  end
end

local function moveText()
  local g = game
  local who = g.turn == core.BLACK and "BLACK" or "WHITE"
  local goal = g.turn == core.BLACK and "top to bottom" or "left to right"
  if prefs.mode == 1 then
    if g.turn == prefs.you then return who .. " TO PLAY: JOIN " .. goal end
    return "THE DEVICE IS THINKING"
  end
  return who .. " TO PLAY: JOIN " .. goal
end

local function drawGame(status)
  gfx.clear()
  local right = prefs.mode == 1 and ("VS " .. brain.LEVELS[prefs.level].name) or "TWO PLAYERS"
  header("HEX", right)
  drawBoard(game)
  capsule(status or moveText())
  gfx.present()
end

local function computerMove()
  drawGame("THE DEVICE IS THINKING")
  local i = brain.choose(game.cells, game.turn, brain.LEVELS[prefs.level])
  if i then place(i) end
end

-- ---------------------------------------------------------------- menus
local function menu(title, rows, sel, footer)
  while true do
    gfx.clear()
    header(title)
    local y = HEADER + 28
    for k, label in ipairs(rows) do
      local rowH = 52
      if k == sel then
        gfx.rect(16, y, W - 32, rowH - 6, true)
        gfx.text(32, y + 14, label, "sans16", "bw")
      else
        gfx.rect(16, y, W - 32, rowH - 6, false)
        gfx.text(32, y + 14, label, "sans16", "b")
      end
      y = y + rowH
    end
    if footer then gfx.text(W // 2, H - 92, footer, "ui12", "c") end
    gfx.present()
    local ev = input.wait()
    if ev == "up" then sel = sel > 1 and sel - 1 or #rows
    elseif ev == "down" then sel = sel < #rows and sel + 1 or 1
    elseif ev == "confirm" then return sel
    elseif ev == "back" then return nil, sel end
  end
end

local function howTo()
  gfx.clear()
  header("HOW TO PLAY")
  local lines = {
    "Black joins the TOP edge to the BOTTOM edge.",
    "White joins the LEFT edge to the RIGHT edge.",
    "Stones never move and are never taken.",
    "The first to connect their edges wins.",
    "Arrows move the cursor. Confirm places a stone.",
    "Back opens the pause menu.",
  }
  local y = HEADER + 28
  for _, s in ipairs(lines) do
    for _, l in ipairs(wrap(s, 36)) do
      gfx.text(24, y, l, "ui12", "b")
      y = y + 20
    end
    y = y + 8
  end
  capsule("Back = menu")
  gfx.present()
  while input.wait() ~= "back" do end
end

local function pauseMenu()
  local rows = { "CONTINUE", "LEAVE (GAME IS SAVED)", "GIVE UP" }
  local sel = 1
  while true do
    local pick, _ = menu("PAUSED", rows, sel, "Confirm picks; Back also continues.")
    if pick == nil or pick == 1 then return "continue" end
    if pick == 2 then return "leave" end
    if pick == 3 then return "giveup" end
    sel = pick
  end
end

local function resultScreen()
  gfx.clear()
  header("HEX", prefs.mode == 1 and ("VS " .. brain.LEVELS[prefs.level].name) or "TWO PLAYERS")
  drawBoard(game)
  local w = game.winner
  local name = w == core.BLACK and "BLACK" or "WHITE"
  local text = name .. " WINS"
  if prefs.mode == 1 then
    text = (w == prefs.you) and "YOU WIN" or "THE DEVICE WINS"
  end
  capsule(text .. "   Confirm: new   Back: menu")
  gfx.present()
  while true do
    local ev = input.wait()
    if ev == "confirm" then return "new" end
    if ev == "back" then return "menu" end
  end
end

local function playLoop()
  while true do
    if game.finished then
      return resultScreen()
    end
    if prefs.mode == 1 and game.turn == computerColour() then
      computerMove()
    else
      drawGame()
      local ev = input.wait()
      local g = game
      local r, c = core.ROW[g.cur], core.COL[g.cur]
      if ev == "up" and r > 1 then g.cur = core.index(r - 1, c)
      elseif ev == "down" and r < COLS then g.cur = core.index(r + 1, c)
      elseif ev == "left" and c > 1 then g.cur = core.index(r, c - 1)
      elseif ev == "right" and c < COLS then g.cur = core.index(r, c + 1)
      elseif ev == "confirm" then
        if g.cells[g.cur] == 0 then place(g.cur) end
      elseif ev == "back" then
        local choice = pauseMenu()
        if choice == "leave" then return "menu"
        elseif choice == "giveup" then
          finish(core.other(g.turn))
          return resultScreen()
        end
      end
    end
  end
end

-- ---------------------------------------------------------------- front door
local function frontRows()
  local rows = {}
  if game and not game.finished then rows[#rows + 1] = "RESUME GAME" end
  rows[#rows + 1] = "PLAY VS THE DEVICE"
  rows[#rows + 1] = "TWO PLAYERS"
  rows[#rows + 1] = "PLAY NEARBY"
  rows[#rows + 1] = "LEVEL: " .. brain.LEVELS[prefs.level].name
  rows[#rows + 1] = "YOU PLAY: " .. (prefs.you == 1 and "BLACK" or "WHITE")
  rows[#rows + 1] = "HOW TO PLAY"
  return rows
end

local function frontDoor()
  local sel = 1
  while true do
    local rows = frontRows()
    local record = string.format("PLAYED %d   WON %d", stats.played, stats.won)
    local pick = menu("HEX", rows, sel, record)
    if pick == nil then return "quit" end
    sel = pick
    local label = rows[pick]
    if label == "RESUME GAME" then
      return "resume"
    elseif label == "PLAY VS THE DEVICE" then
      prefs.mode = 1
      return "new"
    elseif label == "TWO PLAYERS" then
      prefs.mode = 2
      return "new"
    elseif label == "PLAY NEARBY" then
      linkedPlay()
    elseif label:sub(1, 6) == "LEVEL:" then
      prefs.level = prefs.level % #brain.LEVELS + 1
      save()
    elseif label:sub(1, 8) == "YOU PLAY" then
      prefs.you = core.other(prefs.you)
      save()
    elseif label == "HOW TO PLAY" then
      howTo()
    end
  end
end

-- ---------------------------------------------------------------- PLAY NEARBY
-- Two devices over ESP-NOW (nearby.lua). The whole board travels as the 162-byte
-- blob (wire.lua), the layout of HexCore.h. Black moves first in a round; the
-- first mover flips each round, both devices on the same rematch exchange.
-- The linked game lives in its own table, so a saved solo game is untouched.

local function linkedScreen(view, status)
  gfx.clear()
  header("HEX", "PLAY NEARBY")
  drawBoard(view)
  capsule(status)
  gfx.present()
end

-- One linked session, from the search screen to leaving. Returns to the menu.
local function linkedPlay()
  local S = nearby.new(GAME_ID, "PUP " .. string.sub(system.mac(), 16, 17))
  local ok, err = S:start()
  if not ok then
    gfx.clear()
    header("HEX")
    gfx.text(16, 100, "RADIO WILL NOT START", "sans16", "b")
    gfx.text(16, 130, tostring(err):sub(1, 60), "ui12", "b")
    capsule("Back: menu")
    gfx.present()
    while input.wait() ~= "back" do end
    return
  end

  local mode = "search"          -- search | board | result | linkend
  local meFirst = false          -- I am black this round
  local me = core.BLACK
  local lg = nil                 -- the shared game record
  local cur = core.index(6, 6)   -- my cursor: local, never sent
  local myAgain = false
  local dirty = true

  local function newRound()
    me = meFirst and core.BLACK or core.WHITE
    lg = { cells = core.newBoard(), turn = core.BLACK, finished = false, winner = nil, last = nil }
    myAgain = false
    S:newRound()
    mode = "board"
    dirty = true
  end

  local function view()
    return { cells = lg.cells, last = lg.last, cur = cur }
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
        if mode == "result" and not ng.finished then
          meFirst = not meFirst
          newRound()
        end
        lg = ng
        mode = lg.finished and "result" or "board"
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
        gfx.clear()
        header("HEX", "PLAY NEARBY")
        gfx.text(W // 2, 220, "LOOKING FOR A PLAYER", "sans18", "bc")
        gfx.text(W // 2, 256, "Turn on PLAY NEARBY on the other device.", "ui12", "c")
        capsule("Back: cancel")
        gfx.present()
      elseif mode == "board" then
        local status
        if lg.turn == me then
          status = "YOUR MOVE: JOIN " .. (me == core.BLACK and "TOP TO BOTTOM" or "LEFT TO RIGHT")
        else
          status = "THEIR MOVE"
        end
        linkedScreen(view(), status)
      elseif mode == "result" then
        local won = lg.winner == me
        local tail = "Confirm: again   Back: leave"
        if myAgain then tail = "WAITING FOR THEM"
        elseif S.peerAgain then tail = "THEY WANT ANOTHER GAME" end
        linkedScreen(view(), (won and "YOU WIN" or "THEY WIN") .. "   " .. tail)
      else
        linkedScreen(view(), S.reason == "lost" and "LOST CONNECTION   Back: menu" or "THEY LEFT   Back: menu")
      end
    end

    local ev = input.wait(100)
    if ev == "back" then
      break
    elseif ev == "up" or ev == "down" or ev == "left" or ev == "right" then
      if mode == "board" then
        local r, c = core.ROW[cur], core.COL[cur]
        if ev == "up" and r > 1 then cur = core.index(r - 1, c)
        elseif ev == "down" and r < core.N then cur = core.index(r + 1, c)
        elseif ev == "left" and c > 1 then cur = core.index(r, c - 1)
        elseif ev == "right" and c < core.N then cur = core.index(r, c + 1) end
        dirty = true
      end
    elseif ev == "confirm" then
      if mode == "board" and lg.turn == me and not lg.finished and lg.cells[cur] == 0 then
        lg.cells[cur] = me
        lg.last = cur
        if core.connected(lg.cells, me) then
          lg.finished = true
          lg.winner = me
        else
          lg.turn = core.other(me)
        end
        S:sendState(system.millis(), wire.pack(lg))
        mode = lg.finished and "result" or "board"
        dirty = true
      elseif mode == "result" and not myAgain then
        myAgain = true
        S:say(system.millis(), nearby.NOTE_PLAY_AGAIN)
        dirty = true
      elseif mode == "linkend" then
        break
      end
    end
  end
  S:stop(system.millis())
end

-- ---------------------------------------------------------------- entry
local function __main()
  math.randomseed(system.millis())
  W, H = gfx.size()
  layout()
  local saved = load()
  if saved then game = saved end
  while true do
    local action = frontDoor()
    if action == "quit" then break end
    if action == "new" then newGame() end
    local ended = playLoop()
    while ended == "new" do
      newGame()
      ended = playLoop()
    end
    -- "menu": the game is already saved; drop a finished one from memory
    if game and game.finished then game = nil end
  end
  save()
  app.exit()
end

local ok, err = pcall(__main)
if not ok then
  gfx.clear() gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b") gfx.present()
  while input.wait() ~= "back" do end
  app.exit()
end
