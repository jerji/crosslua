-- Transit alert (passive, receive only): pick one AP you expect to be near (a train, bus or car hotspot).
-- It listens on all channels and shows GONE when that AP has been silent for GONE_MS, and BACK when it returns.
-- Alert state and an event log stay on screen; nothing is written to the card.

local CHANS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }
local DWELL_MS = 800
local GONE_MS = 30000
local MAX_APS = 40
local LH = 26

local W, H = 0, 0
local aps, ap_list = {}, {}
local target = nil
local last_seen = nil
local present = nil          -- nil until first seen
local events = {}
local ci, last_hop = 1, 0

local function clip(s, n) return #s > n and s:sub(1, n) or s end
local function event(s) table.insert(events, 1, s); if #events > 6 then table.remove(events) end end

local function on_beacon(frame, ch, rssi, now)
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
  elseif ssid ~= "" then a.ssid = ssid end
  a.ch = ch
  if rssi then a.rssi = rssi end
  if target and bssid == target.bssid then last_seen = now end
end

local function pick(now)
  local cur = 1
  while true do
    gfx.clear(); W, H = gfx.size()
    gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Transit alert: pick AP", "ui12", "bw")
    local y = 56
    if #ap_list == 0 then gfx.text(14, y, "listening... (back = quit)", "ui12") end
    for i, a in ipairs(ap_list) do
      if y > H - 70 then break end
      local label = string.format("%-16s ch%-2d %d", clip(a.ssid ~= "" and a.ssid or "<hidden>", 16), a.ch, a.rssi)
      if i == cur then gfx.rect(10, y - 4, W - 20, LH + 4, true); gfx.text(16, y, label, "small", "w")
      else gfx.text(16, y, label, "small") end
      y = y + LH
    end
    gfx.text(14, H - 34, "Up/Down, Confirm = watch, Back = quit", "small")
    gfx.present()
    local e = input.poll()
    if e == "up" then cur = cur > 1 and cur - 1 or math.max(1, #ap_list)
    elseif e == "down" then cur = cur < #ap_list and cur + 1 or 1
    elseif e == "confirm" and #ap_list > 0 then return ap_list[cur]
    elseif e == "back" then return nil end
    app.sleep(20)
  end
end

local function main()
  W, H = gfx.size()
  local ok, err = wifi.monitor_start({ channel = CHANS[ci] })
  if not ok then
    gfx.clear(); gfx.text(16, 60, "Could not start:", "ui12"); gfx.text(16, 90, tostring(err), "small"); gfx.present()
    while input.wait() ~= "back" do end
    return
  end
  last_hop = system.millis()
  local t = 0
  -- scan phase: pick the AP to watch
  while not target do
    local now = system.millis()
    local frame, meta = wifi.monitor_recv()
    while frame do
      on_beacon(frame, (meta and meta.channel) or CHANS[ci], meta and meta.rssi, now)
      frame, meta = wifi.monitor_recv()
    end
    if now - last_hop >= DWELL_MS then ci = ci % #CHANS + 1; wifi.monitor_channel(CHANS[ci]); last_hop = now end
    local pickd = pick(now)
    if pickd == nil then wifi.monitor_stop(); return end
    target = pickd
    last_seen = nil
    present = nil
    event("watching " .. clip(target.ssid ~= "" and target.ssid or "<hidden>", 18))
  end
  -- watch phase
  local last_draw = -1000
  while true do
    local now = system.millis()
    local frame, meta = wifi.monitor_recv()
    while frame do
      on_beacon(frame, (meta and meta.channel) or CHANS[ci], meta and meta.rssi, now)
      frame, meta = wifi.monitor_recv()
    end
    if now - last_hop >= DWELL_MS then ci = ci % #CHANS + 1; wifi.monitor_channel(CHANS[ci]); last_hop = now end
    local seen_recently = last_seen and (now - last_seen < GONE_MS)
    if seen_recently and present == false then event("BACK"); present = true
    elseif not seen_recently and present ~= false and last_seen then event("GONE"); present = false
    elseif seen_recently and present == nil then present = true end
    if now - last_draw >= 1000 then
      gfx.clear(); W, H = gfx.size()
      gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Transit alert", "ui12", "bw")
      gfx.text(14, 56, clip(target.ssid ~= "" and target.ssid or "<hidden>", 24), "ui12")
      local status = present == true and "IN RANGE" or (present == false and "GONE" or "waiting...")
      gfx.text(14, 96, status, "sans18")
      local y = 150
      for _, e in ipairs(events) do gfx.text(14, y, e, "small"); y = y + LH end
      gfx.text(14, H - 34, "Back = stop and exit", "small")
      gfx.present()
      last_draw = now
    end
    if input.poll() == "back" then break end
    app.sleep(10)
  end
  wifi.monitor_stop()
end

local ok, err = pcall(main)
if not ok then
  pcall(function() wifi.monitor_stop() end)
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
