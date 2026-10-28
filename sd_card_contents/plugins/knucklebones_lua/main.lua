-- Knucklebones (Cult of the Lamb dice game). Rules from crossplay docs/apps/knucklebones.md:
--   * You roll a d6 and drop it into one of your three columns (fills from the near end outward).
--   * Placing value v destroys every copy of v in the opponent's facing column (only that column, only v).
--   * A column scores each distinct value v as v * n * n, n = copies of v in that column.
--   * The match ends the instant either grid fills; higher total wins; equal = draw.
-- Modes: VS CPU (one-ply greedy, deterministic) or PLAY NEARBY (two devices over ESP-NOW,
-- crossplay's link: the grids travel as the 24-byte blob in wire.lua, spec play-nearby §4.3).
-- Controls: Left/Right choose column, Confirm rolls the die and drops it, Back leaves.

local nearby = require("nearby")
local wire = require("wire")
local GAME_ID = 0x0501

local W, H = 0, 0

local function col_score(col)
  local n = {}
  for _, v in ipairs(col) do n[v] = (n[v] or 0) + 1 end
  local s = 0
  for v, k in pairs(n) do s = s + v * k * k end
  return s
end

local function total(g, p)
  return col_score(g[p][1]) + col_score(g[p][2]) + col_score(g[p][3])
end

local function full(g, p)
  return #g[p][1] == 3 and #g[p][2] == 3 and #g[p][3] == 3
end

-- place die value v in column c for player p; destroys v in the opponent's column c
local function place(g, p, c, v)
  local opp = 3 - p
  local keep = {}
  for _, x in ipairs(g[opp][c]) do if x ~= v then keep[#keep + 1] = x end end
  g[opp][c] = keep
  if #g[p][c] < 3 then g[p][c][#g[p][c] + 1] = v end
end

local function legal(g, p)
  local t = {}
  for c = 1, 3 do if #g[p][c] < 3 then t[#t + 1] = c end end
  return t
end

-- CPU: one ply, greedy on (my total - their total) after the move, prefer room, deterministic tiebreak
local function cpu_choose(g, p, v)
  local best, bestc = -1e9, nil
  for _, c in ipairs(legal(g, p)) do
    local trial = { [1] = { {}, {}, {} }, [2] = { {}, {}, {} } }
    for q = 1, 2 do for cc = 1, 3 do for i, x in ipairs(g[q][cc]) do trial[q][cc][i] = x end end end
    place(trial, p, c, v)
    local val = total(trial, p) - total(trial, 3 - p)
    val = val * 10 + (3 - #g[p][c]) - c * 0.001
    if val > best then best, bestc = val, c end
  end
  return bestc
end

local function roll()
  local ok, b = pcall(crypto.random, 1)
  if ok and type(b) == "string" and #b > 0 then return b:byte() % 6 + 1 end
  return math.random(6)
end

local function newGrids() return { [1] = { {}, {}, {} }, [2] = { {}, {}, {} } } end

-- ------------------------------------------------------------- drawing
-- top grid = g[2], bottom grid = g[1]; link games relabel these THEM / YOU
local LAB = { top = "CPU", bottom = "You" }

local function draw_grid(g, p, x, y, label)
  gfx.text(x, y - 26, label .. "  " .. total(g, p), "ui12", "b")
  for c = 1, 3 do
    local cx = x + (c - 1) * 150
    gfx.rect(cx, y, 130, 3 * 30 + 6, false)
    for r = 1, 3 do
      local v = g[p][c][4 - r]  -- top of the column is drawn first
      local cy = y + (r - 1) * 30 + 4
      if v then gfx.text(cx + 52, cy, tostring(v), "ui12") end
    end
  end
  gfx.text(x, y + 100, "col score: " .. col_score(g[p][1]) .. " | " .. col_score(g[p][2]) .. " | " .. col_score(g[p][3]), "small")
end

local function draw(g, cur_col, die, msg, title, hint)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, title or "Knucklebones", "ui12", "bw")
  draw_grid(g, 2, 30, 80, LAB.top)
  gfx.text(30, 240, "die: " .. (die and tostring(die) or "-") .. "    column: " .. cur_col, "ui12")
  draw_grid(g, 1, 30, 300, LAB.bottom)
  gfx.text(14, H - 60, msg or "", "small")
  gfx.text(14, H - 34, hint or "Left/Right column, Confirm roll and drop, Back exit", "small")
end

local function drawMenu(sel, flash)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Knucklebones", "ui12", "bw")
  local rows = { "VS CPU", "PLAY NEARBY" }
  for i, label in ipairs(rows) do
    local y = 150 + (i - 1) * 60
    if sel == i then gfx.rect(60, y, W - 120, 46, true) end
    gfx.text(W // 2, y + 12, label, "ui12", sel == i and "bwc" or "bc")
  end
  gfx.text(W // 2, 300, "PLAY NEARBY: two devices in range, no setup.", "small", "c")
  if flash and flash ~= "" then gfx.text(W // 2, 360, flash, "small", "c") end
  gfx.text(14, H - 34, "Up/Down choose, Confirm select, Back exit", "small")
end

local function drawLinkWait()
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Knucklebones  PLAY NEARBY", "ui12", "bw")
  gfx.text(W // 2, 300, "LOOKING FOR A PLAYER", "sans18", "c")
  gfx.text(W // 2, 344, "Turn on PLAY NEARBY on the other device.", "small", "c")
  gfx.text(14, H - 34, "Back cancel", "small")
end

local function drawLinkEnd(reason)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Knucklebones  PLAY NEARBY", "ui12", "bw")
  gfx.text(W // 2, 300, reason == "lost" and "LOST CONNECTION" or "THEY LEFT", "sans18", "c")
  gfx.text(14, H - 34, "OK or Back: menu", "small")
end

-- ------------------------------------------------------ state
local screen = "menu"    -- menu | cpu | cpuend | linkwait | board | result | linkend
local menuSel = 1        -- 1 = VS CPU, 2 = PLAY NEARBY
local g, cur, die, msg, turn
local S = nil            -- PLAY NEARBY session, nil when playing the CPU
local mySeat = 0         -- seat 0 = the first mover; seats go over the wire (wire.lua)
local myAgain = false
local resultSel = 1
local flash = ""

local function resultText(a, b)
  if a == b then return "Draw" end
  return a > b and "You win" or "They win"
end

-- the grids in seat order, as the wire carries them
local function seatGrids()
  if mySeat == 0 then return { [0] = g[1], [1] = g[2] } end
  return { [0] = g[2], [1] = g[1] }
end

-- ------------------------------------------------------ PLAY NEARBY
local function leaveLink()
  if S then S:stop(system.millis()) end
  S = nil
  myAgain = false
  LAB = { top = "CPU", bottom = "You" }
  screen = "menu"
  flash = ""
end

local function startLink()
  S = nearby.new(GAME_ID, "PUP " .. string.sub(system.mac(), 16, 17))
  local ok, err = S:start()
  if not ok then
    S = nil
    flash = "RADIO WILL NOT START: " .. tostring(err):sub(1, 30)
    return
  end
  flash = ""
  LAB = { top = "THEM", bottom = "YOU" }
  screen = "linkwait"
end

-- a fresh match (or round): seat 0 opens, and the first mover flips each round
local function beginMatch()
  mySeat = S.iFirst and 0 or 1
  g = newGrids()
  cur, die, msg = 1, nil, ""
  turn = (mySeat == 0) and 1 or 2      -- 1 = mine, 2 = theirs
  myAgain = false
  screen = "board"
end

local function startRound()
  S.iFirst = not S.iFirst
  S:newRound()
  beginMatch()
end

-- the peer's grids arrive as a whole: map seats onto my YOU (g[1]) / THEM (g[2])
local function applyBlob(grids, turnSeat, dieV)
  g = { [1] = grids[mySeat], [2] = grids[1 - mySeat] }
  turn = (turnSeat == mySeat) and 1 or 2
  die = dieV ~= 0 and dieV or nil
  msg = (die and turn == 1) and ("They dropped a " .. die .. ".") or ""
  if full(g, 1) or full(g, 2) then
    resultSel = 1
    screen = "result"
  else
    screen = "board"
  end
end

local function pollLink()
  if not S then return end
  local now = system.millis()
  S:pump(now)
  S:tick(now)
  if S:takeMatch() then beginMatch() end
  local blob = S:takeState()
  if blob then
    local grids, turnSeat, dieV = wire.unpack(blob)
    if grids then
      -- on the result screen, a new move can only be round two's opening: the peer
      -- started it, so start it here too
      if screen == "result" then startRound() end
      applyBlob(grids, turnSeat, dieV)
    end
  end
  if screen == "result" and myAgain and S.peerAgain then startRound() end
  if S.phase == "ended" and screen ~= "linkend" then screen = "linkend" end
end

local function linkDrop()
  if turn ~= 1 then
    flash = "NOT YOUR TURN"
    return
  end
  if #g[1][cur] >= 3 then
    msg = "That column is full."
    return
  end
  die = roll()
  place(g, 1, cur, die)
  msg = "You dropped a " .. die .. " into column " .. cur .. "."
  turn = 2
  S:sendState(system.millis(), wire.pack(seatGrids(), 1 - mySeat, die))
  if full(g, 1) or full(g, 2) then
    resultSel = 1
    screen = "result"
  end
end

-- ------------------------------------------------------ CPU game (rules unchanged)
local function startCpu()
  LAB = { top = "CPU", bottom = "You" }
  g = newGrids()
  cur, die, turn = 1, nil, 1
  msg = "Your turn. Confirm to roll."
  screen = "cpu"
end

local function cpuKey(ev)
  if turn == 1 then
    if ev == "left" then cur = cur > 1 and cur - 1 or 3; msg = ""
    elseif ev == "right" then cur = cur < 3 and cur + 1 or 1; msg = ""
    elseif ev == "confirm" then
      if #g[1][cur] >= 3 then msg = "That column is full."
      else
        die = roll()
        place(g, 1, cur, die)
        msg = "You dropped a " .. die .. " into column " .. cur .. "."
        turn = 2
      end
    end
  else
    -- CPU moves on the next confirm press (keeps the pacing with the player)
    if ev == "confirm" then
      die = roll()
      local c = cpu_choose(g, 2, die)
      if c then place(g, 2, c, die); msg = "CPU dropped a " .. die .. " into column " .. c .. "." end
      turn = 1
    end
  end
  -- match end: as soon as either grid fills
  if full(g, 1) or full(g, 2) then
    screen = "cpuend"
  end
end

-- ------------------------------------------------------ rendering + input
local function drawResult()
  local a, b = total(g, 1), total(g, 2)
  if S then
    draw(g, cur, die, string.format("Final: You %d, They %d. %s.", a, b, resultText(a, b)),
      "Knucklebones  PLAY NEARBY", "Left/Right choose, Confirm select, Back leave")
    local label1 = (resultSel == 1 and "> " or "  ") .. "PLAY AGAIN"
    local label2 = (resultSel == 2 and "> " or "  ") .. "MENU"
    gfx.text(W // 2, H - 150, label1, "ui12", "bc")
    gfx.text(W // 2, H - 120, label2, "ui12", "bc")
    if myAgain then gfx.text(W // 2, H - 90, "WAITING FOR THEM TO SAY PLAY AGAIN", "small", "bc")
    elseif S.peerAgain then gfx.text(W // 2, H - 90, "THEY WANT ANOTHER GAME", "small", "bc") end
  end
end

-- every screen is drawn into the buffer first, then presented once
local function render()
  if screen == "menu" then drawMenu(menuSel, flash)
  elseif screen == "cpu" then draw(g, cur, die, msg)
  elseif screen == "cpuend" then
    local a, b = total(g, 1), total(g, 2)
    local result = a > b and "You win" or (a < b and "CPU wins" or "Draw")
    draw(g, cur, die, string.format("Final: You %d, CPU %d. %s. Back to menu.", a, b, result))
  elseif screen == "linkwait" then drawLinkWait()
  elseif screen == "board" then
    local hint = turn == 1 and "Left/Right column, Confirm drop, Back leave" or "Waiting for them, Back leave"
    draw(g, cur, die, msg, "Knucklebones  " .. (turn == 1 and "YOUR TURN" or "THEIR TURN"), hint)
  elseif screen == "result" then drawResult()
  elseif screen == "linkend" then drawLinkEnd(S and S.reason)
  end
  gfx.present()
end

local function handleKey(ev)
  if screen == "menu" then
    if ev == "up" or ev == "down" then
      menuSel = menuSel == 1 and 2 or 1
    elseif ev == "confirm" then
      if menuSel == 1 then startCpu() else startLink() end
    elseif ev == "back" then
      return "exit"
    end
  elseif screen == "cpu" then
    if ev == "back" then screen = "menu"; flash = ""
    else cpuKey(ev) end
  elseif screen == "cpuend" then
    if ev == "confirm" or ev == "back" then screen = "menu" end
  elseif screen == "linkwait" then
    if ev == "back" then leaveLink() end
  elseif screen == "linkend" then
    if ev == "confirm" or ev == "back" then leaveLink() end
  elseif screen == "board" then
    if ev == "left" then cur = cur > 1 and cur - 1 or 3; msg = ""
    elseif ev == "right" then cur = cur < 3 and cur + 1 or 1; msg = ""
    elseif ev == "confirm" then linkDrop()
    elseif ev == "back" then leaveLink() end
  elseif screen == "result" then
    if ev == "left" or ev == "right" then
      resultSel = resultSel == 1 and 2 or 1
    elseif ev == "confirm" then
      if resultSel == 1 then
        if not myAgain then
          myAgain = true
          S:say(system.millis(), nearby.NOTE_PLAY_AGAIN)
          if S.peerAgain then startRound() end
        end
      else
        leaveLink()
      end
    elseif ev == "back" then
      leaveLink()
    end
  end
  return nil
end

local function run()
  W, H = gfx.size()
  while true do
    pollLink()
    render()
    local ev
    if S then ev = input.wait(100) else ev = input.wait() end
    if ev and handleKey(ev) == "exit" then return end
  end
end

local ok, err = pcall(run)
if S then pcall(function() S:stop(system.millis()) end) end
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
