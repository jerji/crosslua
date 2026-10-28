-- Bulletin board (ESP-NOW multi-hop flood): post a note; it is broadcast with a hop budget (TTL).
-- Every device running the board stores each note id once and rebroadcasts it with TTL-1 while TTL > 0,
-- so a note reaches devices beyond direct radio range. Board lives in RAM only.
-- Frame: "BB|<id>|<ttl>|<nick>|<text>". Dedupe by id stops loops.
-- TARGETING: broadcast flood by design (every relay is everyone). Single-device posting is not in this version.

local MAX_NOTES = 24
local DEFAULT_TTL = 3
local RELAY_GAP_MS = 400

local function txt(...) return input.text(...) or "" end

local function main()
  local W, H = gfx.size()
  local ok, mac = espnow.start({ channel = 1 })
  if not ok then error("espnow: " .. tostring(mac)) end
  local notes, seen = {}, {}
  local pending = {}           -- relays waiting to go out { due, frame }
  local last_draw = -1000
  local relayed = 0

  local function post(nick, text)
    local id = crypto.hex(crypto.random(4))
    local frame = string.format("BB|%s|%d|%s|%s", id, DEFAULT_TTL, nick, text)
    seen[id] = true
    espnow.send("broadcast", frame)
    return id
  end

  local function draw()
    gfx.clear(); W, H = gfx.size()
    gfx.rect(0, 0, W, 40, true)
    gfx.text(14, 10, "Bulletin board (flood)", "ui12", "bw")
    gfx.text(14, 50, string.format("%d notes   relayed %d   your MAC %s", #notes, relayed, tostring(mac)), "small")
    local y = 84
    for i = math.max(1, #notes - 11), #notes do
      local n = notes[i]
      gfx.text(14, y, string.format("%s [ttl %d] %s", n.nick:sub(1, 8), n.ttl, n.text:sub(1, 40)), "small")
      y = y + 24
    end
    gfx.text(14, H - 60, "Confirm = post a note", "small")
    gfx.text(14, H - 34, "Back = leave", "small")
    gfx.present()
  end

  local nick = txt("Your name", "pup", 12):gsub("|", "")
  draw()
  while true do
    local now = system.millis()
    local data = espnow.recv()
    while data do
      local id, ttl, n, text = data:match("^BB|(%x+)|(%d+)|([^|]*)|(.*)$")
      if id and not seen[id] then
        seen[id] = true
        if #notes >= MAX_NOTES then table.remove(notes, 1) end
        notes[#notes + 1] = { id = id, nick = n, text = text, ttl = tonumber(ttl) }
        local t = tonumber(ttl)
        if t > 0 then
          pending[#pending + 1] = { due = now + RELAY_GAP_MS, frame = string.format("BB|%s|%d|%s|%s", id, t - 1, n, text) }
        end
        draw()
      end
      data = espnow.recv()
    end
    -- send relays whose time has come
    for i = #pending, 1, -1 do
      if now >= pending[i].due then
        espnow.send("broadcast", pending[i].frame)
        relayed = relayed + 1
        table.remove(pending, i)
      end
    end
    if now - last_draw >= 2000 then draw(); last_draw = now end
    local e = input.poll()
    if e == "back" then break end
    if e == "confirm" then
      local text = txt("Note (max 80)", "", 80):gsub("|", "")
      if text ~= "" then
        local id = post(nick, text)
        notes[#notes + 1] = { id = id, nick = nick, text = text, ttl = DEFAULT_TTL }
      end
      draw()
    end
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
