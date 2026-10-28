-- Beacon test (ACTIVE, transmits): broadcast 802.11 beacon frames for the SSIDs you type.
-- Use it to test scanners, client auto-join behaviour and your own lab gear. Runs until Back.
--
-- TARGETING: broadcast only.
-- MICRO-TARGETING NOT IMPLEMENTED: a beacon is addressed to everyone (destination ff:ff:ff:ff:ff:ff), so
-- there is no way to aim it at one station. One-station targeting exists in ap_cloner_lua (probe/auth/assoc
-- answers to a chosen client MAC). If you want one-station beacons, that needs a station-addressed frame type
-- that the client expects (for example, a unicast probe response), which is what ap_cloner_lua already does.

-- keyboard read that treats a cancel (nil) as an empty string
local function txt(...) return input.text(...) or "" end

local CHANNEL_DEFAULT = 6
local BEACON_MS = 102
local RATES = "\1\4\130\132\139\150"
local TS = string.rep("\0", 8)

local function hdr(fc, dst, src, bssid)
  return string.char(fc, 0) .. "\0\0" .. dst .. src .. bssid .. "\0\0"
end

local function beacon(ssid, bssid, ch)
  return hdr(0x80, string.rep("\255", 6), bssid, bssid) .. TS .. "\100\0" .. "\1\0"
    .. string.char(0, #ssid) .. ssid .. RATES .. "\3\1" .. string.char(ch)
end

local function parse_mac(s)
  local h = s:gsub("[:%-%s]", "")
  if #h ~= 12 or h:find("[^%x]") then return nil end
  return crypto.unhex(h)
end

local function random_bssid()
  local b = crypto.random(6)
  return string.char((b:byte(1) & 0xFE) | 0x02) .. b:sub(2)
end

local function setup()
  local ssids_text = txt("SSIDs, comma separated", "", 200)
  if not ssids_text or ssids_text == "" then return nil end
  local ssids = {}
  for s in ssids_text:gmatch("[^,]+") do
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if #s > 0 and #s <= 32 then ssids[#ssids + 1] = s end
  end
  if #ssids == 0 then return nil end
  local ch = math.tointeger(tonumber(txt("Channel 1-13", tostring(CHANNEL_DEFAULT), 2))) or CHANNEL_DEFAULT
  if ch < 1 or ch > 13 then ch = CHANNEL_DEFAULT end
  local bt = txt("BSSID (blank = random)", "", 17) or ""
  local bssid = random_bssid()
  if bt ~= "" then bssid = parse_mac(bt) or bssid end
  return { ssids = ssids, ch = ch, bssid = bssid }
end

local function run(cfg)
  local ok, err = wifi.tx_start({ channel = cfg.ch })
  if not ok then return false, err end
  local frames = {}
  for i, s in ipairs(cfg.ssids) do
    -- one BSSID per SSID: the chosen one for the first, random for the rest
    local b = (i == 1) and cfg.bssid or random_bssid()
    frames[i] = beacon(s, b, cfg.ch)
  end
  local i, last_draw = 1, -1000
  while true do
    local now = system.millis()
    wifi.tx(frames[i])
    i = i % #frames + 1
    if now - last_draw >= 1000 then
      local info = wifi.tx_info()
      gfx.clear(); local W, H = gfx.size()
      gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Beacon test (ACTIVE)", "ui12", "bw")
      gfx.text(14, 60, string.format("%d SSIDs on ch %d", #cfg.ssids, cfg.ch), "ui12")
      gfx.text(14, 90, "sent " .. (info and info.sent or 0), "ui12")
      gfx.text(14, 120, cfg.ssids[1]:sub(1, 30), "small")
      gfx.text(14, H - 34, "Back = stop", "small")
      gfx.present()
      last_draw = now
    end
    if input.poll() == "back" then break end
    app.sleep(BEACON_MS // #frames)
  end
  wifi.tx_stop()
  return true
end

local ok, err = pcall(function()
  local cfg = setup()
  if not cfg then return end
  local started, why = run(cfg)
  if not started then
    gfx.clear(); gfx.text(14, 60, "could not start: " .. tostring(why), "ui12"); gfx.present()
    while input.wait() ~= "back" do end
  end
end)
pcall(function() wifi.tx_stop() end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
