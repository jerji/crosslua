-- AP history (passive, receive only): track every access point heard while the app runs:
-- first/last seen (ms since app start), peak RSSI, beacon count. Written to data:ap_history.csv on exit.
-- Heat map is not here: it needs a position source the device does not have. Signal logs are per-AP only.

local CHANS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }
local DWELL_MS = 800
local MAX_APS = 150
local LH = 26

local W, H = 0, 0
local aps, ap_list = {}, {}
local ci, last_hop, t0 = 1, 0, 0

local function clip(s, n) return #s > n and s:sub(1, n) or s end
local function mac(b) return string.format("%02x:%02x:%02x:%02x:%02x:%02x", b:byte(1, 6)) end

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
    a = { bssid = bssid, ssid = ssid, ch = ch, peak = rssi or -99, count = 0, first = now, last = now }
    aps[bssid] = a
    ap_list[#ap_list + 1] = a
  end
  if ssid ~= "" then a.ssid = ssid end
  a.ch = ch
  a.count = a.count + 1
  a.last = now
  if rssi and rssi > a.peak then a.peak = rssi end
end

local function save()
  local name
  for n = 1, 999 do
    local c = string.format("data:ap_history_%03d.csv", n)
    if not fs.exists(c) then name = c; break end
  end
  if not name then return nil end
  local rows = { "bssid,ssid,channel,peak_rssi,beacons,first_ms,last_ms" }
  for _, a in ipairs(ap_list) do
    rows[#rows + 1] = string.format('%s,"%s",%d,%d,%d,%d,%d', mac(a.bssid), a.ssid:gsub('"', '""'), a.ch, a.peak, a.count, a.first, a.last)
  end
  fs.write(name, table.concat(rows, "\n") .. "\n")
  return name
end

local function draw(now)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, "AP History", "ui12", "bw")
  gfx.text(14, 50, string.format("%d APs logged  ch %d", #ap_list, CHANS[ci]), "ui12")
  local y = 86
  local list = {}
  for _, a in ipairs(ap_list) do list[#list + 1] = a end
  table.sort(list, function(x, y2) return x.last > y2.last end)
  for i = 1, math.min(#list, (H - 150) // LH) do
    local a = list[i]
    gfx.text(14, y, string.format("%-14s ch%-2d %4d  x%d", clip(a.ssid ~= "" and a.ssid or "<hidden>", 14), a.ch, a.peak, a.count), "small")
    y = y + LH
  end
  gfx.text(14, H - 34, "Back = save CSV and exit", "small")
  gfx.present()
end

local function main()
  W, H = gfx.size()
  t0 = system.millis()
  local ok, err = wifi.monitor_start({ channel = CHANS[ci] })
  if not ok then
    gfx.clear(); gfx.text(16, 60, "Could not start:", "ui12"); gfx.text(16, 90, tostring(err), "small"); gfx.present()
    while input.wait() ~= "back" do end
    return
  end
  last_hop = system.millis()
  local last_draw = -1000
  while true do
    local now = system.millis() - t0
    local frame, meta = wifi.monitor_recv()
    while frame do
      on_beacon(frame, (meta and meta.channel) or CHANS[ci], meta and meta.rssi, now)
      frame, meta = wifi.monitor_recv()
    end
    if system.millis() - last_hop >= DWELL_MS then
      ci = ci % #CHANS + 1
      wifi.monitor_channel(CHANS[ci])
      last_hop = system.millis()
    end
    if now - last_draw >= 1000 then draw(now); last_draw = now end
    if input.poll() == "back" then break end
    app.sleep(10)
  end
  wifi.monitor_stop()
  local name = save()
  gfx.clear(); gfx.text(16, 60, name and ("Saved " .. name) or "Could not save (no free name)", "ui12"); gfx.present()
  app.sleep(1500)
end

local ok, err = pcall(main)
if not ok then
  pcall(function() wifi.monitor_stop() end)
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
