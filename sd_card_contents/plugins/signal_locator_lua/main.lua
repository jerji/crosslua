-- Signal locator: hop 1..13 to list visible APs, pick one, lock its channel and follow its beacon
-- RSSI on a smoothed meter with peak hold (walk toward the strongest reading). Receive only.

local SCAN_MS = 12000
local DWELL_MS = 800
local REFRESH_MS = 400
local MAX_APS = 30
local LH = 26
local CHANS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }

local W, H = 0, 0
local aps, ap_list = {}, {}
local ci, last_hop = 1, 0
local target = nil                  -- {bssid, ssid, ch}
local smooth, peak, seen_ticks = nil, nil, 0
local menu_cur = 1

local function clip(s, n) return #s > n and s:sub(1, n) or s end

local function header(title)
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, title, "ui12", "bw")
end

local function footer(t) gfx.text(14, H - 34, t, "small") end

-- beacon -> BSSID (addr3), SSID (tag 0), channel and RSSI from the radio metadata
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

-- ---- scan + pick ----
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
    local now = system.millis()
    if now - last_hop >= DWELL_MS then
      ci = ci % #CHANS + 1
      wifi.monitor_channel(CHANS[ci])
      last_hop = now
    end
    gfx.clear(); W, H = gfx.size(); header("Signal Locator: scanning")
    gfx.text(16, 60, string.format("%d networks heard", #ap_list), "ui12")
    gfx.text(16, 90, "Channel " .. CHANS[ci], "ui12")
    footer("Confirm = pick now, Back = quit")
    gfx.present()
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
    gfx.clear(); W, H = gfx.size(); header("Signal Locator: pick")
    if #ap_list == 0 then gfx.text(18, 60, "No networks heard.", "ui12") end
    local y = 56
    for i, a in ipairs(ap_list) do
      local label = string.format("%-16s ch%-2d %d", clip(a.ssid ~= "" and a.ssid or "<hidden>", 16), a.ch, a.rssi)
      if i == menu_cur then
        gfx.rect(10, y - 4, W - 20, LH + 4, true); gfx.text(16, y, label, "small", "w")
      else
        gfx.text(16, y, label, "small")
      end
      y = y + LH
      if y > H - 60 then break end
    end
    footer("Up/Down pick, Confirm lock, Back cancel")
    gfx.present()
    local e = input.wait()
    if e == "up" then menu_cur = menu_cur > 1 and menu_cur - 1 or #ap_list
    elseif e == "down" then menu_cur = menu_cur < #ap_list and menu_cur + 1 or 1
    elseif e == "confirm" and #ap_list > 0 then return ap_list[menu_cur]
    elseif e == "back" then return nil end
  end
end

-- ---- locked tracking ----
local function bar(n, width)
  local v = math.max(0, math.min(width, ((n + 100) * width) // 60))  -- -100 dBm .. -40 dBm
  return string.rep("#", v) .. string.rep(".", width - v)
end

local function track()
  local ok, err = wifi.monitor_start({ channel = target.ch })
  if not ok then
    gfx.clear(); gfx.text(16, 60, "Could not start:", "ui12")
    gfx.text(16, 90, clip(tostring(err), 60), "small"); gfx.present()
    while input.wait() ~= "back" do end
    return
  end
  local last_draw = 0
  while true do
    local frame, meta = wifi.monitor_recv()
    while frame do
      if #frame >= 22 and (frame:byte(1) & 0xFC) == 0x80 and frame:sub(17, 22) == target.bssid and meta and meta.rssi then
        seen_ticks = seen_ticks + 1
        smooth = smooth and (smooth * 0.7 + meta.rssi * 0.3) or meta.rssi
        if not peak or meta.rssi > peak then peak = meta.rssi end
      end
      frame, meta = wifi.monitor_recv()
    end
    local now = system.millis()
    if now - last_draw >= REFRESH_MS then
      gfx.clear(); W, H = gfx.size(); header("Signal Locator: locked")
      gfx.text(16, 56, clip(target.ssid ~= "" and target.ssid or "<hidden>", 24), "ui12")
      gfx.text(16, 56 + LH, string.format("ch %d   beacons %d", target.ch, seen_ticks), "small")
      if smooth then
        gfx.text(16, 56 + 3 * LH, string.format("Now   %4d dBm", math.floor(smooth)), "ui12")
        gfx.text(16, 56 + 4 * LH, bar(math.floor(smooth), 30), "ui12")
      else
        gfx.text(16, 56 + 3 * LH, "Waiting for beacons...", "ui12")
      end
      if peak then gfx.text(16, 56 + 6 * LH, string.format("Peak  %4d dBm", peak), "ui12") end
      footer("Confirm = reset peak, Back = stop and exit")
      gfx.present()
      last_draw = now
    end
    local e = input.poll()
    if e == "back" then break end
    if e == "confirm" then peak = nil end
    app.sleep(10)
  end
  wifi.monitor_stop()
end

local function main()
  W, H = gfx.size()
  local ok = scan()
  if not ok then return end
  local t = pick()
  if not t then return end
  target = t
  track()
end

local ok, err = pcall(main)
if not ok then
  pcall(function() wifi.monitor_stop() end)
  gfx.clear()
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b")
  gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
