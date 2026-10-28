-- Play nearby: tic-tac-toe (the first game of the PLAY NEARBY set). Two e-readers on the same ESP-NOW channel.
-- Link layer: every move carries a sequence number and is retransmitted every second until the peer acks
-- it ("TK|seq"). A move is applied once (duplicates are re-acked and ignored).
-- Roles: the first device chooses HOST (plays X and moves first); the other chooses JOIN (O).
-- Frames: "TT|<game>|<seq>|<cell 1-9>" move, "TK|<game>|<seq>" ack, "TH|<game>" hello.
-- Not in this version: host election over the air (roles are chosen by the user), reconnect after drop,
-- the other 11 games, the Toybox widget kit, flag-plant (needs button hold, core #2).
-- TARGETING: the match is two devices; frames go to broadcast but only the matched game id is accepted.

local GAME = "TTT1"
local RETRY_MS = 1000
local MAX_TRIES = 12
local CELL = 3

local W, H = 0, 0
local board = {}               -- board[1..9] = "X" | "O" | nil
local me, them
local role
local cursor = 1
local my_seq = 0
local pending = nil            -- { seq, cell, tries, last }
local applied = {}             -- applied[seq] = true for the peer's moves
local status = ""

local function mark_at(cell) return board[cell] or "." end

local function winner()
  local L = { {1,2,3},{4,5,6},{7,8,9},{1,4,7},{2,5,8},{3,6,9},{1,5,9},{3,5,7} }
  for _, l in ipairs(L) do
    local a = board[l[1]]
    if a and a == board[l[2]] and a == board[l[3]] then return a end
  end
  for i = 1, 9 do if not board[i] then return nil end end
  return "draw"
end

local function turn_is_mine()
  local count = 0
  for i = 1, 9 do if board[i] then count = count + 1 end end
  local x_turn = (count % 2 == 0)
  return (role == "host") == x_turn
end

local function draw()
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, "Play nearby: tic-tac-toe", "ui12", "bw")
  local top, left, size = 90, 60, 300
  local step = size // CELL
  for r = 0, CELL - 1 do
    for c = 0, CELL - 1 do
      local i = r * CELL + c + 1
      local x, y = left + c * step, top + r * step
      gfx.rect(x, y, step, step, false)
      if i == cursor then gfx.rect(x + 4, y + 4, step - 8, step - 8, false) end
      local m = board[i]
      if m then gfx.text(x + step // 2, y + step // 2 - 12, m, "sans18", "c") end
    end
  end
  local w = winner()
  local line = status
  if w == "draw" then line = "draw game"
  elseif w then line = (w == (role == "host" and "X" or "O")) and "you won" or "they won"
  elseif turn_is_mine() then line = "your move" else line = "waiting for them" end
  gfx.text(14, top + size + 20, line .. "   you are " .. (role == "host" and "X" or "O"), "ui12")
  gfx.text(14, top + size + 52, status, "small")
  gfx.text(14, H - 60, "Up/Down/Left/Right move cursor, Confirm = play", "small")
  gfx.text(14, H - 34, "Back = leave", "small")
  gfx.present()
end

local function send_ack(seq)
  espnow.send("broadcast", "TK|" .. GAME .. "|" .. seq)
end

local function send_move(cell)
  my_seq = my_seq + 1
  pending = { seq = my_seq, cell = cell, tries = 0, last = -1000 }
  espnow.send("broadcast", string.format("TT|%s|%d|%d", GAME, my_seq, cell))
  pending.tries = 1
  pending.last = system.millis()
end

local function apply_their(cell)
  if board[cell] then return end
  board[cell] = (role == "host") and "O" or "X"
end

local function handle(data)
  local g, seq, cell = data:match("^TT|(%w+)|(%d+)|(%d)$")
  if g == GAME then
    seq = tonumber(seq); cell = tonumber(cell)
    send_ack(seq)
    if not applied[seq] then
      applied[seq] = true
      apply_their(cell)
      status = "they played " .. cell
    end
    return
  end
  local ga, aseq = data:match("^TK|(%w+)|(%d+)$")
  if ga == GAME and pending and tonumber(aseq) == pending.seq then
    board[pending.cell] = (role == "host") and "X" or "O"
    pending = nil
    status = ""
  end
end

local function main()
  W, H = gfx.size()
  local ok, mac = espnow.start({ channel = 1 })
  if not ok then error("espnow: " .. tostring(mac)) end
  local pick = input.text("Role: host (X, first) or join (O)", "host", 6) or "host"
  role = (pick == "join") and "join" or "host"
  status = "waiting for the other device..."
  draw()
  local last_draw = -1000
  while true do
    local now = system.millis()
    local data = espnow.recv()
    while data do handle(data); data = espnow.recv() end
    if pending and now - pending.last >= RETRY_MS then
      if pending.tries >= MAX_TRIES then
        status = "no ack from the other device; move dropped"
        board[pending.cell] = nil
        pending = nil
      else
        espnow.send("broadcast", string.format("TT|%s|%d|%d", GAME, pending.seq, pending.cell))
        pending.tries = pending.tries + 1
        pending.last = now
      end
    end
    if now - last_draw >= 500 then draw(); last_draw = now end
    local e = input.poll()
    if e == "back" then break
    elseif e == "up" then if cursor > CELL then cursor = cursor - CELL end
    elseif e == "down" then if cursor <= CELL * (CELL - 1) then cursor = cursor + CELL end
    elseif e == "left" then if cursor % CELL ~= 1 then cursor = cursor - 1 end
    elseif e == "right" then if cursor % CELL ~= 0 then cursor = cursor + 1 end
    elseif e == "confirm" then
      if pending then status = "wait for the last move to be acked"
      elseif board[cursor] then status = "cell taken"
      elseif winner() then status = "game over"
      elseif not turn_is_mine() then status = "not your move"
      else
        board[cursor] = (role == "host") and "X" or "O"
        send_move(cursor)
        status = "sent move " .. cursor
      end
    end
    draw()
    app.sleep(30)
  end
  espnow.stop()
end

local ok2, err = pcall(main)
pcall(function() espnow.stop() end)
if not ok2 then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
