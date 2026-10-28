-- Go for the X4 (see docs/apps/go.md in crossplay). Area scoring, komi 7.5,
-- 9x9 or 13x13. Play two people on one device, or against the Lua engine at
-- three levels (gobrain.lua; NOT michi-c2).
--
-- Controls: arrows move the cursor. Confirm AIMS a stone on the cursor and a
-- second Confirm on the same point commits it; moving the cursor drops the
-- aim. A warning appears when the aim is a mistake (fills your own eye,
-- self-atari). Back opens the pause menu (pass, leave, give up).
local co = require("goco")
local brain = require("gobrain")
local nearby = require("nearby")
local wire = require("wire")
local GAME_ID = 0x0A02

local W, H = 480, 800
local HEADER, CAPSULE = 40, 48
local SQ = 448                     -- the same square for 9x9 and 13x13
local SAVE = "data:go.sav"

local prefs = { level = 2, mode = 1, you = 1, size = 9 }   -- mode 1 device, 2 two players
local stats = { won = 0, played = 0 }
local game = nil
local left, top, pitch = 0, 0, 0

local function layout()
  local n = game and game.st.n or prefs.size
  pitch = SQ // (n - 1)
  left = (W - (n - 1) * pitch) // 2
  top = HEADER + (H - HEADER - CAPSULE - SQ) // 2
end

local function xy(i, n)
  local r, c = (i - 1) // n, (i - 1) % n
  return left + c * pitch, top + r * pitch
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

-- ---------------------------------------------------------------- board
local function drawBoard(g)
  local n = g.st.n
  local last = (n - 1) * pitch
  for k = 0, n - 1 do
    gfx.line(left, top + k * pitch, left + last, top + k * pitch, true)
    gfx.line(left + k * pitch, top, left + k * pitch, top + last, true)
  end
  for _, r in ipairs(n == 9 and { 3, 7 } or { 4, 10 }) do
    for _, c in ipairs(n == 9 and { 3, 7 } or { 4, 10 }) do
      local x, y = left + (c - 1) * pitch, top + (r - 1) * pitch
      gfx.rect(x - 3, y - 3, 7, 7, true)
    end
  end
  local mid = n == 9 and 5 or 7
  local mx, my = left + (mid - 1) * pitch, top + (mid - 1) * pitch
  gfx.rect(mx - 3, my - 3, 7, 7, true)

  local b = g.st.b
  local d = pitch - 6
  for i = 1, n * n do
    local v = b[i]
    if v ~= 0 then
      local x, y = xy(i, n)
      if v == 1 then
        gfx.rounded_rect(x - d // 2, y - d // 2, d, d, d // 2, true, true)
      else
        gfx.rounded_rect(x - d // 2, y - d // 2, d, d, d // 2, true, false)
        gfx.rounded_rect(x - d // 2, y - d // 2, d, d, d // 2, false, true)
      end
      if g.last == i then
        gfx.rect(x - 2, y - 2, 5, 5, true, v == 2)
      end
    end
  end
  if g.aim then
    local x, y = xy(g.aim, n)
    gfx.rounded_rect(x - d // 2 - 4, y - d // 2 - 4, d + 8, d + 8, (d + 8) // 2, false, true)
  end
  local cx, cy = xy(g.cur, n)
  gfx.rect(cx - pitch // 2 + 1, cy - pitch // 2 + 1, pitch - 2, pitch - 2, false, true)
  gfx.rect(cx - pitch // 2 + 2, cy - pitch // 2 + 2, pitch - 4, pitch - 4, false, true)
end

-- ---------------------------------------------------------------- persistence
local function save()
  local cells = (game and not game.finished) and co.pack(game.st) or "-"
  local turn, passes, ko, you = 1, 0, 0, prefs.you
  if game and not game.finished then
    turn, passes, ko = game.st.turn, game.st.passes, game.st.ko
  end
  fs.write(SAVE, string.format("v1 %s %d %d %d %d %d %d %d %d %d",
    cells, turn, passes, ko, you, prefs.level, prefs.mode, prefs.size,
    stats.won, stats.played))
end

local function load()
  local raw = fs.read(SAVE)
  if not raw then return end
  local cells, turn, passes, ko, you, level, mode, size, won, played =
    raw:match("^v1 (%S+) (%d+) (%d+) (%d+) (%d+) (%d+) (%d+) (%d+) (%d+) (%d+)")
  if not cells then return end
  you, level, mode, size = tonumber(you), tonumber(level), tonumber(mode), tonumber(size)
  if you == 1 or you == 2 then prefs.you = you end
  if level and level >= 1 and level <= #brain.LEVELS then prefs.level = level end
  if mode == 1 or mode == 2 then prefs.mode = mode end
  if size == 9 or size == 13 then prefs.size = size end
  stats.won = tonumber(won) or 0
  stats.played = tonumber(played) or 0
  if cells == "-" then return end
  local n2 = #cells
  local n = math.floor(math.sqrt(n2) + 0.5)
  if (n ~= 9 and n ~= 13) or n * n ~= n2 then return end
  local st = co.newState(n)
  for i = 1, n2 do
    local v = cells:byte(i) - 48
    if v < 0 or v > 2 then return end
    st.b[i] = v
  end
  turn = tonumber(turn)
  if turn ~= 1 and turn ~= 2 then return end
  st.turn = turn
  st.passes = tonumber(passes) or 0
  st.ko = tonumber(ko) or 0
  -- The superko history does not travel in the save: a resumed game only
  -- remembers its current position. Simple ko still holds.
  game = { st = st, cur = math.floor(n * n / 2) + 1, aim = nil, last = nil, finished = false, winner = nil }
end

-- ---------------------------------------------------------------- game
local function newGame()
  local st = co.newState(prefs.size)
  game = { st = st, cur = math.floor(prefs.size * prefs.size / 2) + 1, aim = nil, last = nil, finished = false, winner = nil }
  layout()
  save()
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

local function scoreText()
  local black, white = co.area(game.st.b, game.st.n)
  return string.format("BLACK %d   WHITE %d + %.1f", black, white, co.KOMI)
end

local function playMove(i)
  local st = game.st
  if i == "pass" then
    local done = co.pass(st)
    game.last = nil
    if done then
      finish(co.margin(st.b, st.n) > 0 and 1 or 2)
      return true
    end
  else
    if not co.apply(st, i, st.turn) then return false end
    game.last = i
  end
  game.aim = nil
  save()
  return true
end

local function drawGame(status)
  gfx.clear()
  local right = prefs.mode == 1 and ("VS " .. brain.LEVELS[prefs.level].name) or "TWO PLAYERS"
  header(string.format("GO %dx%d", game.st.n, game.st.n), right)
  drawBoard(game)
  gfx.text(W // 2, top + (game.st.n - 1) * pitch + 16, scoreText(), "sans12", "c")
  local turnName = game.st.turn == 1 and "BLACK" or "WHITE"
  capsule(status or (turnName .. " TO PLAY"))
  gfx.present()
end

local function computerMove()
  drawGame("THE DEVICE IS THINKING")
  local mv = brain.choose(game.st, game.st.turn, brain.LEVELS[prefs.level])
  if mv == "pass" then
    playMove("pass")
  else
    playMove(mv)
  end
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
    elseif ev == "back" then return nil end
  end
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

local function howTo()
  gfx.clear()
  header("HOW TO PLAY")
  local lines = {
    "Black and White take turns placing stones.",
    "Surround empty points to make them yours.",
    "Captured groups are removed; a stone with no liberties dies.",
    "Score = your stones + your territory. White gets 7.5 komi.",
    "Two passes in a row end the game.",
    "Arrows move. Confirm aims; Confirm again places.",
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
  local rows = { "CONTINUE", "PASS", "LEAVE (GAME IS SAVED)", "GIVE UP" }
  local sel = 1
  while true do
    local pick = menu("PAUSED", rows, sel, "Confirm picks; Back also continues.")
    if pick == nil or pick == 1 then return "continue" end
    if pick == 2 then return "pass" end
    if pick == 3 then return "leave" end
    if pick == 4 then return "giveup" end
    sel = pick
  end
end

local function resultScreen()
  gfx.clear()
  header("GO", prefs.mode == 1 and ("VS " .. brain.LEVELS[prefs.level].name) or "TWO PLAYERS")
  drawBoard(game)
  local margin = co.margin(game.st.b, game.st.n)
  local w = game.winner
  local name = w == 1 and "BLACK" or "WHITE"
  local text = string.format("%s WINS BY %.1f", name, math.abs(margin))
  if prefs.mode == 1 then
    text = (w == prefs.you) and string.format("YOU WIN BY %.1f", math.abs(margin))
      or string.format("THE DEVICE WINS BY %.1f", math.abs(margin))
  end
  gfx.text(W // 2, top + (game.st.n - 1) * pitch + 16, scoreText(), "sans12", "c")
  capsule(text .. "   Confirm: new   Back: menu")
  gfx.present()
  while true do
    local ev = input.wait()
    if ev == "confirm" then return "new" end
    if ev == "back" then return "menu" end
  end
end

-- What a Confirm on the cursor point would be told, before it is played.
local function warningFor(i)
  local st = game.st
  if i == st.ko then return "KO: YOU MAY NOT RETAKE YET" end
  if not co.legal(st, i, st.turn) then return "NOT LEGAL HERE (SUICIDE OR REPEAT)" end
  if co.fillsOwnEye(st.b, st.n, i, st.turn) then return "THAT FILLS YOUR OWN EYE" end
  if co.selfAtari(st.b, st.n, i, st.turn) then return "THAT STONE WOULD BE IN ATARI" end
  return nil
end

local function playLoop()
  while true do
    if game.finished then return resultScreen() end
    local st = game.st
    if prefs.mode == 1 and st.turn ~= prefs.you then
      computerMove()
    else
      local msg = nil
      if game.aim then
        msg = "CONFIRM AGAIN TO PLAY, OR MOVE TO CHANGE"
        local w = warningFor(game.aim)
        if w then msg = w end
      end
      drawGame(msg)
      local ev = input.wait()
      local n = st.n
      local r, c = (game.cur - 1) // n, (game.cur - 1) % n
      local moved = false
      if ev == "up" and r > 0 then game.cur = game.cur - n moved = true
      elseif ev == "down" and r < n - 1 then game.cur = game.cur + n moved = true
      elseif ev == "left" and c > 0 then game.cur = game.cur - 1 moved = true
      elseif ev == "right" and c < n - 1 then game.cur = game.cur + 1 moved = true
      elseif ev == "confirm" then
        if st.b[game.cur] == 0 then
          if game.aim == game.cur then
            playMove(game.cur)
          else
            game.aim = game.cur
          end
        end
      elseif ev == "back" then
        local choice = pauseMenu()
        if choice == "leave" then
          save()
          return "menu"
        elseif choice == "pass" then
          playMove("pass")
          if game.finished then return resultScreen() end
        elseif choice == "giveup" then
          finish(co.other(st.turn))
          return resultScreen()
        end
      end
      if moved then game.aim = nil end
    end
  end
end

-- ---------------------------------------------------------------- front door
local linkedPlay  -- defined with PLAY NEARBY below
local function frontRows()
  local rows = {}
  if game and not game.finished then rows[#rows + 1] = "RESUME GAME" end
  rows[#rows + 1] = "PLAY VS THE DEVICE"
  rows[#rows + 1] = "TWO PLAYERS"
  rows[#rows + 1] = "PLAY NEARBY"
  rows[#rows + 1] = "LEVEL: " .. brain.LEVELS[prefs.level].name
  rows[#rows + 1] = "YOU PLAY: " .. (prefs.you == 1 and "BLACK" or "WHITE")
  rows[#rows + 1] = "BOARD: " .. prefs.size .. "x" .. prefs.size
  rows[#rows + 1] = "HOW TO PLAY"
  return rows
end

local function frontDoor()
  local sel = 1
  while true do
    local rows = frontRows()
    local record = string.format("PLAYED %d   WON %d", stats.played, stats.won)
    local pick = menu("GO", rows, sel, record)
    if pick == nil then return "quit" end
    sel = pick
    local label = rows[pick]
    if label == "RESUME GAME" then return "resume"
    elseif label == "PLAY VS THE DEVICE" then prefs.mode = 1 return "new"
    elseif label == "TWO PLAYERS" then prefs.mode = 2 return "new"
    elseif label == "PLAY NEARBY" then linkedPlay()
    elseif label:sub(1, 6) == "LEVEL:" then
      prefs.level = prefs.level % #brain.LEVELS + 1
      save()
    elseif label:sub(1, 8) == "YOU PLAY" then
      prefs.you = co.other(prefs.you)
      save()
    elseif label:sub(1, 6) == "BOARD:" then
      prefs.size = prefs.size == 9 and 13 or 9
      save()
    elseif label == "HOW TO PLAY" then howTo()
    end
  end
end

-- ---------------------------------------------------------------- PLAY NEARBY
-- Two devices over ESP-NOW (nearby.lua). The whole game travels as the 192-byte
-- blob (wire.lua), the layout of GoCore.h. Black moves first in a round; the
-- first mover flips each round, and both devices flip on the same rematch.
-- The board size is the one the match opened with: a device that receives a
-- move takes the size from it. Back asks once (Confirm then passes); Back again
-- leaves. While linked, `game` is the match, so the board helpers draw it; the
-- saved solo game is put back when the match ends.

-- A position as the board record the helpers read.
local function adoptPosition(ng, cur)
  local n = ng.st.n
  if not cur or cur > n * n then cur = math.floor(n * n / 2) + 1 end
  local lg = { st = ng.st, cur = cur, aim = nil, last = nil, finished = ng.finished, winner = nil }
  if lg.finished then lg.winner = co.margin(ng.st.b, n) > 0 and co.BLACK or co.WHITE end
  return lg
end

-- One linked session, from the search screen to leaving. Returns to the menu.
function linkedPlay()
  local solo = game
  local S = nearby.new(GAME_ID, "PUP " .. string.sub(system.mac(), 16, 17))
  local ok, err = S:start()
  if not ok then
    gfx.clear()
    header("GO")
    gfx.text(16, 100, "RADIO WILL NOT START", "sans16", "b")
    gfx.text(16, 130, tostring(err):sub(1, 60), "ui12", "b")
    capsule("Back: menu")
    gfx.present()
    while input.wait() ~= "back" do end
    return
  end

  local mode = "search"          -- search | board | result | linkend
  local meFirst, me = false, co.BLACK
  local size = prefs.size
  local lg = nil
  local leaving = false          -- Back pressed once: Confirm passes, Back leaves
  local myAgain = false
  local dirty = true

  local function newRound()
    me = meFirst and co.BLACK or co.WHITE
    lg = adoptPosition({ st = co.newState(size), finished = false }, lg and lg.cur)
    game = lg
    layout()
    leaving, myAgain = false, false
    S:newRound()
    mode = "board"
    dirty = true
  end

  -- A position from the other device becomes the board; its size wins.
  local function adopt(ng)
    lg = adoptPosition(ng, lg and lg.cur)
    size = ng.st.n
    game = lg
    layout()
    mode = lg.finished and "result" or "board"
    dirty = true
  end

  -- Our move (a point, or "pass"), then the whole position goes to them.
  local function play(kind)
    local st = lg.st
    local done
    if kind == "pass" then
      done = co.pass(st)
    else
      if not co.apply(st, kind, st.turn) then return false end
      done = st.moves >= co.MOVE_LIMIT(st.n)
    end
    lg.aim, leaving = nil, false
    lg.finished = done
    if done then lg.winner = co.margin(st.b, st.n) > 0 and co.BLACK or co.WHITE end
    S:sendState(system.millis(), wire.pack(lg))
    mode = done and "result" or "board"
    dirty = true
    return true
  end

  local function draw(status)
    lg.last = lg.st.last
    gfx.clear()
    header(string.format("GO %dx%d", lg.st.n, lg.st.n), "PLAY NEARBY")
    drawBoard(lg)
    gfx.text(W // 2, top + (lg.st.n - 1) * pitch + 16, scoreText(), "sans12", "c")
    capsule(status)
    gfx.present()
  end

  local function boardStatus()
    if leaving then return "CONFIRM = PASS    BACK AGAIN = LEAVE" end
    if lg.st.turn ~= me then return "THEIR MOVE" end
    if lg.aim then return warningFor(lg.aim) or "CONFIRM AGAIN TO PLAY, OR MOVE TO CHANGE" end
    return "YOUR MOVE"
  end

  local function drawResult()
    lg.last = lg.st.last
    gfx.clear()
    header("GO", "PLAY NEARBY")
    drawBoard(lg)
    local margin = co.margin(lg.st.b, lg.st.n)
    local text = string.format(lg.winner == me and "YOU WIN BY %.1f" or "THEY WIN BY %.1f", math.abs(margin))
    local tail = "Confirm: again   Back: leave"
    if myAgain then tail = "WAITING FOR THEM"
    elseif S.peerAgain then tail = "THEY WANT ANOTHER GAME" end
    gfx.text(W // 2, top + (lg.st.n - 1) * pitch + 16, scoreText(), "sans12", "c")
    capsule(text .. "   " .. tail)
    gfx.present()
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
        adopt(ng)
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
        header("GO", "PLAY NEARBY")
        gfx.text(W // 2, 220, "LOOKING FOR A PLAYER", "sans18", "bc")
        gfx.text(W // 2, 256, "Turn on PLAY NEARBY on the other device.", "ui12", "c")
        capsule("Back: cancel")
        gfx.present()
      elseif mode == "board" then
        draw(boardStatus())
      elseif mode == "result" then
        drawResult()
      else
        draw(S.reason == "lost" and "LOST CONNECTION   Back: menu" or "THEY LEFT   Back: menu")
      end
    end

    local ev = input.wait(100)
    if ev == "back" then
      if mode == "board" and not leaving then
        leaving = true
        dirty = true
      else
        break
      end
    elseif ev == "up" or ev == "down" or ev == "left" or ev == "right" then
      leaving = false
      if mode == "board" then
        local n = lg.st.n
        local r, c = (lg.cur - 1) // n, (lg.cur - 1) % n
        local moved = false
        if ev == "up" and r > 0 then lg.cur = lg.cur - n moved = true
        elseif ev == "down" and r < n - 1 then lg.cur = lg.cur + n moved = true
        elseif ev == "left" and c > 0 then lg.cur = lg.cur - 1 moved = true
        elseif ev == "right" and c < n - 1 then lg.cur = lg.cur + 1 moved = true end
        if moved then lg.aim = nil end
        dirty = true
      end
    elseif ev == "confirm" then
      if mode == "board" and lg.st.turn == me then
        if leaving then
          play("pass")
        elseif lg.st.b[lg.cur] == 0 then
          if lg.aim == lg.cur then play(lg.cur) else lg.aim = lg.cur end
          dirty = true
        end
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
  game = solo
  if game then layout() end
end

-- ---------------------------------------------------------------- entry
local function __main()
  math.randomseed(system.millis())
  W, H = gfx.size()
  load()
  if game then layout() end
  while true do
    local action = frontDoor()
    if action == "quit" then break end
    if action == "new" then newGame() end
    local ended = playLoop()
    while ended == "new" do
      newGame()
      ended = playLoop()
    end
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
