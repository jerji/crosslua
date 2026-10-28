-- SSID channel (covert, ACTIVE on send): a message is split into 18-byte chunks, each chunk base64-encoded
-- into a beacon SSID of the form "XC<idx>/<total>:<b64>" (max 32 chars). Receive listens for beacons and
-- reassembles any complete set. Transmits broadcast beacons only.
--
-- TARGETING: broadcast only. The channel is one-to-everyone by design.
-- MICRO-TARGETING NOT IMPLEMENTED: a beacon cannot be addressed to one station. A one-station variant would
-- need unicast frames (see ap_cloner_lua's per-station responses) and a shared pre-agreed station MAC.

local CHUNK = 18
local PREFIX = "XC"
local BEACON_MS = 102
local RATES = "\1\4\130\132\139\150"

local function beacon(ssid, bssid, ch)
  return "\128\0\0\0" .. string.rep("\255", 6) .. bssid .. bssid .. "\0\0"
    .. string.rep("\0", 8) .. "\100\0\1\0"
    .. string.char(0, #ssid) .. ssid .. RATES .. "\3\1" .. string.char(ch)
end

local function random_bssid()
  local b = crypto.random(6)
  return string.char((b:byte(1) & 0xFE) | 0x02) .. b:sub(2)
end

local function encode(msg)
  local ssids = {}
  local total = math.ceil(#msg / CHUNK)
  for i = 1, total do
    local chunk = msg:sub((i - 1) * CHUNK + 1, i * CHUNK)
    ssids[i] = string.format("%s%d/%d:%s", PREFIX, i, total, crypto.b64encode(chunk))
  end
  return ssids
end

local function send(ssids, ch)
  local frames = {}
  for i, s in ipairs(ssids) do frames[i] = beacon(s, random_bssid(), ch) end
  local ok, why = wifi.tx_start({ channel = ch })
  if not ok then return false, why end
  local i = 1
  while true do
    wifi.tx(frames[i])
    i = i % #frames + 1
    if input.poll() == "back" then break end
    app.sleep(BEACON_MS // #frames + 1)
  end
  wifi.tx_stop()
  return true
end

local function receive(ch)
  local chunks, total = {}, nil
  local got = 0
  local ok, why = wifi.monitor_start({ channel = ch })
  if not ok then return nil, why end
  local last_draw = -1000
  local message
  while true do
    local frame, meta = wifi.monitor_recv()
    while frame do
      -- beacon: 24-byte header + 12 fixed bytes, then tag 0 (SSID) at index 37, length at 38, text from 39
      if #frame >= 39 and (frame:byte(1) & 0xFC) == 0x80 and frame:byte(37) == 0 then
        local len = frame:byte(38)
        local ssid = frame:sub(39, 38 + len)
        local idx, tot, b64 = ssid:match("^XC(%d+)/(%d+):([A-Za-z0-9+/=]+)$")
        if idx and not chunks[tonumber(idx)] then
          idx = tonumber(idx); tot = tonumber(tot)
          total = tot
          chunks[idx] = b64
          got = got + 1
          if got == total then
            local parts = {}
            for k = 1, total do parts[k] = crypto.b64decode(chunks[k]) or "?" end
            message = table.concat(parts)
          end
        end
      end
      frame = wifi.monitor_recv()
    end
    local now = system.millis()
    if now - last_draw >= 1000 then
      gfx.clear(); local W, H = gfx.size()
      gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "SSID channel: receive", "ui12", "bw")
      gfx.text(14, 60, total and string.format("chunks %d / %d", got, total) or "listening...", "ui12")
      if message then gfx.text(14, 100, "message:", "ui12"); gfx.text(14, 130, message:sub(1, 200), "small") end
      gfx.text(14, H - 34, "Back = stop", "small")
      gfx.present()
      last_draw = now
    end
    if message then break end
    if input.poll() == "back" then break end
    app.sleep(10)
  end
  wifi.monitor_stop()
  return message
end

local function txt(...) return input.text(...) or "" end

local function main()
  gfx.clear(); gfx.text(14, 60, "1 = send a message, 2 = receive", "ui12"); gfx.present()
  local mode = txt("Mode: send or receive", "send", 8)
  local ch = math.tointeger(tonumber(txt("Channel 1-13", "6", 2))) or 6
  if ch < 1 or ch > 13 then ch = 6 end
  if mode == "receive" then
    local msg = receive(ch)
    gfx.clear(); gfx.text(14, 60, msg and ("received: " .. msg:sub(1, 200)) or "stopped", "ui12"); gfx.present()
    while input.wait() ~= "back" do end
  else
    local msg = txt("Message (max 1700 chars)", "", 1700)
    if msg == "" then return end
    local ssids = encode(msg)
    local ok, why = send(ssids, ch)
    if not ok then gfx.clear(); gfx.text(14, 60, "could not transmit: " .. tostring(why), "ui12"); gfx.present(); while input.wait() ~= "back" do end end
  end
end

local ok, err = pcall(main)
pcall(function() wifi.tx_stop() end)
pcall(function() wifi.monitor_stop() end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
