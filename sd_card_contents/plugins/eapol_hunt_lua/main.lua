-- EAPOL hunt: scan beacons on 1..13, pick a target AP, lock its channel and record
-- WPA 4-way handshake frames (EAPOL-Key) to a PCAP for offline checking. Receive only.
-- Uses only wifi.monitor_*: never transmits, never sends deauth.

local SCAN_MS = 15000        -- how long to hop the 2.4 GHz band collecting beacons
local DWELL_MS = 1000
local REFRESH_MS = 1000
local MAX_APS = 30
local LH = 26
local EAPOL_LLC = "\170\170\3\0\0\0\136\142"   -- AA AA 03 00 00 00 88 8E

local W, H = 0, 0
local aps, ap_list = {}, {}          -- aps[bssid6] = {ssid, ch, rssi}
local target = nil                   -- {bssid, ssid, ch}
local m = { [1] = 0, [2] = 0, [3] = 0, [4] = 0, seen_target = 0, eapol = 0 }
local pcap_file = nil

local function header(title)
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, title, "ui12", "bw")
end

local function footer(text) gfx.text(14, H - 34, text, "small") end

local function clip(s, n) return #s > n and s:sub(1, n) or s end

-- ---------- 802.11 parsing ----------
local function bssid_of(frame)  -- addr3 for beacons (mgmt), used as BSSID
  return frame:sub(17, 22)
end

local function scan_beacon(frame, rssi, ch)
  if #frame < 37 or (frame:byte(1) & 0xFC) ~= 0x80 then return end
  local key = bssid_of(frame)
  local ssid = nil
  local i = 37
  while i + 1 <= #frame do
    local tag, len = frame:byte(i), frame:byte(i + 1)
    if tag == 0 then ssid = frame:sub(i + 2, i + 1 + len); break end
    i = i + 2 + len
  end
  if not aps[key] then
    if #ap_list >= MAX_APS then return end
    aps[key] = { ssid = "", ch = ch, rssi = rssi or -99, bssid = key }
    ap_list[#ap_list + 1] = aps[key]
  end
  local a = aps[key]
  if ssid and #ssid > 0 and ssid:match("^[%g ]+$") then a.ssid = ssid end
  a.ch = ch
  a.rssi = rssi or a.rssi
end

-- EAPOL-Key message number from key-info bits (ACK 0x80, MIC 0x100, SECURE 0x200)
local function eapol_msg(ki)
  local ack, mic, secure = ki & 0x80 ~= 0, ki & 0x100 ~= 0, ki & 0x200 ~= 0
  if ack and not mic then return 1 end
  if ack and mic then return 3 end
  if mic and secure then return 4 end
  if mic then return 2 end
  return nil
end

local function handle_data(frame)
  local fc2 = frame:byte(2)
  local sub = (frame:byte(1) >> 4) & 15
  local hdr = 24
  if (fc2 & 0x03) == 0x03 then hdr = hdr + 6 end      -- WDS: 4 addresses
  if sub & 8 ~= 0 then hdr = hdr + 2 end             -- QoS control
  if frame:sub(hdr + 1, hdr + 8) ~= EAPOL_LLC then return end
  local a1, a2, a3 = frame:sub(5, 10), frame:sub(11, 16), frame:sub(17, 22)
  if not target then return end
  if a1 ~= target.bssid and a2 ~= target.bssid and a3 ~= target.bssid then return end
  m.seen_target = m.seen_target + 1
  -- EAPOL-Key body starts after LLC/SNAP: version(1) type(1) length(2) descriptor(1) keyinfo(2)
  -- body = index of last LLC byte; EAPOL starts at body+1: version(1) type(1) len(2) desc(1) keyinfo(2)
  local body = hdr + 8
  if frame:byte(body + 2) == 3 then
    local ki = (frame:byte(body + 6) << 8) | frame:byte(body + 7)
    local n = eapol_msg(ki)
    if n then m[n] = m[n] + 1; m.eapol = m.eapol + 1 end
  end
end

-- ---------- UI ----------
local menu_cur = 1
local function pick_ap()
  while true do
    gfx.clear(); W, H = gfx.size()
    header("EAPOL Hunt: pick target")
    if #ap_list == 0 then
      gfx.text(18, 60, "No networks heard.", "ui12")
    end
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

local function next_pcap_name()
  for n = 1, 999 do
    local name = string.format("data:eapol_%03d.pcap", n)
    if not fs.exists(name) then return name end
  end
end

local function scan()
  wifi.monitor_start({ channel = 1 })          -- no file during scan: beacons only
  local chans, ci, last_hop, t0 = { 1,2,3,4,5,6,7,8,9,10,11,12,13 }, 1, system.millis(), system.millis()
  while system.millis() - t0 < SCAN_MS do
    local frame, meta = wifi.monitor_recv()
    while frame do
      scan_beacon(frame, meta and meta.rssi, (meta and meta.channel) or 0)
      frame, meta = wifi.monitor_recv()
    end
    local now = system.millis()
    if now - last_hop >= DWELL_MS then
      ci = ci % #chans + 1
      wifi.monitor_channel(chans[ci])
      last_hop = now
    end
    gfx.clear(); W, H = gfx.size(); header("EAPOL Hunt: scanning")
    gfx.text(16, 60, string.format("Beacons heard: %d networks", #ap_list), "ui12")
    gfx.text(16, 90, string.format("Now on channel %d", chans[ci]), "ui12")
    footer("Back = cancel scan")
    gfx.present()
    if input.poll() == "back" then break end
    app.sleep(20)
  end
  wifi.monitor_stop()
end

local function hunt(t)
  target = t
  pcap_file = next_pcap_name()
  local ok, err = wifi.monitor_start({ channel = t.ch, file = pcap_file })
  if not ok then
    gfx.clear(); W, H = gfx.size(); header("EAPOL Hunt")
    gfx.text(16, 60, "Could not start:", "ui12")
    gfx.text(16, 90, clip(tostring(err), 60), "small")
    footer("Back"); gfx.present()
    while input.wait() ~= "back" do end
    return
  end
  local last_draw = 0
  while true do
    local frame = wifi.monitor_recv()
    while frame do handle_data(frame); frame = wifi.monitor_recv() end
    local now = system.millis()
    if now - last_draw >= REFRESH_MS then
      gfx.clear(); W, H = gfx.size(); header("EAPOL Hunt: locked")
      gfx.text(16, 56, clip(t.ssid ~= "" and t.ssid or "<hidden>", 26), "ui12")
      gfx.text(16, 56 + LH, string.format("ch %d  bssid %02x:%02x:%02x:%02x:%02x:%02x", t.ch,
        t.bssid:byte(1,6)), "small")
      gfx.text(16, 56 + 2*LH + 10, string.format("Target frames: %d", m.seen_target), "ui12")
      gfx.text(16, 56 + 3*LH + 10, string.format("EAPOL  M1 %d  M2 %d  M3 %d  M4 %d", m[1], m[2], m[3], m[4]), "ui12")
      footer("Back = stop and save")
      gfx.present()
      last_draw = now
    end
    if input.poll() == "back" then break end
    app.sleep(10)
  end
  local bytes = wifi.monitor_stop()
  gfx.clear(); W, H = gfx.size(); header("EAPOL Hunt: saved")
  gfx.text(16, 60, "M1 " .. m[1] .. "  M2 " .. m[2] .. "  M3 " .. m[3] .. "  M4 " .. m[4], "ui12")
  gfx.text(16, 90, clip(pcap_file .. " (" .. (bytes or 0) .. " bytes)", 40), "small")
  footer("Back to exit")
  gfx.present()
  while input.wait() ~= "back" do end
end

local function main()
  W, H = gfx.size()
  scan()
  local t = pick_ap()
  if t then hunt(t) end
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
