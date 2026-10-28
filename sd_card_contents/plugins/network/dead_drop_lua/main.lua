-- Dead drop (ESP-NOW): "Leave" repeats a short message as a broadcast every 5 s until Back.
-- "Collect" listens for drop frames from anyone nearby; new ones are kept in RAM and saved to
-- sd:Drops/collected.txt on Back. The drop only survives while a device is running Collect nearby.
-- Plaintext on the air: anyone in range can read a drop.
-- TARGETING: broadcast (everyone) only. Single-device drops would need a chosen peer MAC; not included in this
-- version. To add it: take the peer from espnow.recv()'s mac and send with espnow.send(mac, frame).

local ROUND_MS = 5000
local MAX_DROPS = 32

local function txt(...) return input.text(...) or "" end

local function run_leave(nick, text)
  local ok, mac = espnow.start({ channel = 1 })
  if not ok then error("espnow: " .. tostring(mac)) end
  local id = crypto.hex(crypto.random(4))
  local frame = "DD|" .. id .. "|" .. nick .. "|" .. text
  local last, sent = -1000, 0
  local function draw()
    gfx.clear(); local W, H = gfx.size()
    gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Dead drop: leaving", "ui12", "bw")
    gfx.text(14, 60, "drop id " .. id, "ui12")
    gfx.text(14, 90, "repeating every 5 s, sent " .. sent, "ui12")
    gfx.text(14, 120, text:sub(1, 40), "small")
    gfx.text(14, H - 34, "Back = stop", "small")
    gfx.present()
  end
  draw()
  while true do
    local now = system.millis()
    if now - last >= ROUND_MS then
      espnow.send("broadcast", frame); sent = sent + 1; last = now; draw()
    end
    if input.poll() == "back" then break end
    app.sleep(50)
  end
  espnow.stop()
end

local function run_collect()
  local ok, mac = espnow.start({ channel = 1 })
  if not ok then error("espnow: " .. tostring(mac)) end
  local drops, seen = {}, {}
  local last_draw = -1000
  local function draw()
    gfx.clear(); local W, H = gfx.size()
    gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Dead drop: collecting", "ui12", "bw")
    gfx.text(14, 52, #drops .. " drops collected (RAM)", "ui12")
    local y = 84
    for i = math.max(1, #drops - 9), #drops do
      local d = drops[i]
      gfx.text(14, y, d.nick:sub(1, 10) .. ": " .. d.text:sub(1, 34), "small")
      y = y + 24
    end
    gfx.text(14, H - 34, "Back = save to Drops/ and stop", "small")
    gfx.present()
  end
  draw()
  while true do
    local data, from = espnow.recv()
    while data do
      local id, nick, text = data:match("^DD|(%x+)|([^|]*)|(.*)$")
      if id and not seen[id] and #drops < MAX_DROPS then
        seen[id] = true
        drops[#drops + 1] = { id = id, nick = nick, text = text, from = from }
        draw()
      end
      data, from = espnow.recv()
    end
    if system.millis() - last_draw >= 1000 then draw(); last_draw = system.millis() end
    if input.poll() == "back" then break end
    app.sleep(30)
  end
  espnow.stop()
  if #drops > 0 then
    local lines = {}
    for _, d in ipairs(drops) do lines[#lines + 1] = string.format('%s,%s,"%s"', d.id, d.from or "", (d.text:gsub('"', '""'))) end
    fs.append("sd:Drops/collected.txt", table.concat(lines, "\n") .. "\n")
  end
end

local ok, err = pcall(function()
  local pick = txt("Mode: leave or collect", "collect", 8)
  if pick == "leave" then
    local nick = txt("Your name", "pup", 12):gsub("|", "")
    local text = txt("Drop message", "", 80):gsub("|", "")
    if text == "" then return end
    run_leave(nick, text)
  else
    run_collect()
  end
end)
pcall(function() espnow.stop() end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
