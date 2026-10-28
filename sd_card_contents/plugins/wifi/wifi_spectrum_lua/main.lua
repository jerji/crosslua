-- WiFi spectrum: hop 2.4 GHz channels 1..13 receive-only, show the strongest beacon RSSI per channel,
-- and export the access points heard to CSV (confirm). Never transmits.

local DWELL_MS = 700
local REFRESH_MS = 1000
local MAX_APS = 60
local CHANS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }

local W, H = 0, 0
local chan_max, chan_count = {}, {}     -- per channel: strongest rssi, beacons seen
local aps, ap_list = {}, {}             -- aps[bssid6] = {ssid, ch, rssi}
local ci, last_hop, last_draw = 1, 0, 0
local status = ""

local function clip(s, n) return #s > n and s:sub(1, n) or s end

local function parse_beacon(frame, ch, rssi)
  if #frame < 37 or (frame:byte(1) & 0xFC) ~= 0x80 then return end
  chan_count[ch] = (chan_count[ch] or 0) + 1
  if rssi and (chan_max[ch] == nil or rssi > chan_max[ch]) then chan_max[ch] = rssi end
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
    a = { ssid = ssid, ch = ch, rssi = rssi or -99, bssid = bssid }
    aps[bssid] = a
    ap_list[#ap_list + 1] = a
  else
    if ssid ~= "" then a.ssid = ssid end
    a.ch = ch
    if rssi then a.rssi = rssi end
  end
end

local function hex_mac(b)
  return string.format("%02X:%02X:%02X:%02X:%02X:%02X", b:byte(1, 6))
end

local function csv_field(s)
  return '"' .. s:gsub('"', '""') .. '"'
end

local function export_csv()
  local name
  for n = 1, 999 do
    local p = string.format("data:spectrum_%03d.csv", n)
    if not fs.exists(p) then name = p; break end
  end
  if not name then return nil, "no free file name" end
  local rows = { "bssid,ssid,channel,rssi" }
  for _, a in ipairs(ap_list) do
    rows[#rows + 1] = table.concat({ hex_mac(a.bssid), csv_field(a.ssid), a.ch, a.rssi }, ",")
  end
  local ok, err = fs.write(name, table.concat(rows, "\n") .. "\n")
  if not ok then return nil, err end
  return name, #ap_list
end

local function draw()
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, "WiFi Spectrum", "ui12", "bw")
  local base = H - 120
  local colw = math.floor((W - 20) / #CHANS)
  for c = 1, 13 do
    local x = 10 + (c - 1) * colw
    local r = chan_max[c]
    local h = 0
    if r then h = math.max(0, math.min(300, (r + 100) * 3)) end
    if h > 0 then gfx.rect(x + 4, base - h, colw - 8, h, true) end
    gfx.text(x + 4, base + 6, tostring(c), "small")
  end
  gfx.line(10, base, W - 10, base)
  local y = 56
  gfx.text(14, y, string.format("%d networks heard", #ap_list), "ui12")
  y = y + 30
  local top = {}
  for _, a in ipairs(ap_list) do top[#top + 1] = a end
  table.sort(top, function(a, b) return a.rssi > b.rssi end)
  for i = 1, math.min(3, #top) do
    local a = top[i]
    gfx.text(14, y, string.format("%-18s ch%-2d %d", clip(a.ssid ~= "" and a.ssid or "<hidden>", 18), a.ch, a.rssi), "small")
    y = y + 24
  end
  gfx.text(14, H - 60, status ~= "" and status or "Confirm = export CSV", "small")
  gfx.text(14, H - 34, "Back = stop and exit", "small")
  gfx.present()
end

local function main()
  W, H = gfx.size()
  local ok, err = wifi.monitor_start({ channel = CHANS[1] })
  if not ok then
    gfx.clear(); gfx.text(16, 60, "Could not start:", "ui12")
    gfx.text(16, 90, clip(tostring(err), 60), "small"); gfx.present()
    while input.wait() ~= "back" do end
    return
  end
  last_hop = system.millis()
  draw()
  while true do
    local frame, meta = wifi.monitor_recv()
    while frame do
      parse_beacon(frame, (meta and meta.channel) or CHANS[ci], meta and meta.rssi)
      frame, meta = wifi.monitor_recv()
    end
    local now = system.millis()
    if now - last_hop >= DWELL_MS then
      ci = ci % #CHANS + 1
      wifi.monitor_channel(CHANS[ci])
      last_hop = now
    end
    local e = input.poll()
    if e == "back" then break end
    if e == "confirm" then
      local name, n = export_csv()
      status = name and string.format("Saved %d APs to %s", n, name) or ("Export failed: " .. tostring(n))
      draw()
    end
    if now - last_draw >= REFRESH_MS then
      draw()
      last_draw = now
    end
    app.sleep(10)
  end
  wifi.monitor_stop()
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
