-- Breadcrumb (passive, receive only): on confirm, listen for a few seconds on 1..13, then append one
-- line to data:breadcrumbs.csv: time, label, and the strongest APs (BSSID:RSSI). A location trail built
-- from AP fingerprints, not GPS. Label is typed on the keyboard each time.

local CHANS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }
local LISTEN_MS = 6000
local DWELL_MS = 500
local TOP_N = 8
local LOG = "data:breadcrumbs.csv"

local W, H = 0, 0

local function mac(b) return string.format("%02x%02x%02x%02x%02x%02x", b:byte(1, 6)) end

local function snapshot()
  local best = {}          -- bssid -> { rssi }
  local ci, last_hop = 1, system.millis()
  local t0 = system.millis()
  wifi.monitor_start({ channel = CHANS[ci] })
  while system.millis() - t0 < LISTEN_MS do
    local frame, meta = wifi.monitor_recv()
    while frame do
      if #frame >= 22 and (frame:byte(1) & 0xFC) == 0x80 then
        local b = mac(frame:sub(17, 22))
        local r = meta and meta.rssi or -99
        if not best[b] or r > best[b] then best[b] = r end
      end
      frame, meta = wifi.monitor_recv()
    end
    if system.millis() - last_hop >= DWELL_MS then
      ci = ci % #CHANS + 1
      wifi.monitor_channel(CHANS[ci])
      last_hop = system.millis()
    end
    app.sleep(20)
  end
  wifi.monitor_stop()
  local list = {}
  for b, r in pairs(best) do list[#list + 1] = { b = b, r = r } end
  table.sort(list, function(a, b) return a.r > b.r end)
  return list
end

local function main()
  W, H = gfx.size()
  gfx.clear(); gfx.text(14, 14, "Label this spot (keyboard next):", "ui12"); gfx.present()
  local label = input.text("Breadcrumb label", "", 40)
  if not label then return end
  label = label:gsub('[",\r\n]', " ")
  gfx.clear(); gfx.text(14, 14, "Listening " .. (LISTEN_MS // 1000) .. " s ...", "ui12"); gfx.present()
  local list = snapshot()
  local parts = {}
  for i = 1, math.min(TOP_N, #list) do parts[#parts + 1] = list[i].b .. ":" .. list[i].r end
  local when = time.now() and tostring(time.now()) or "no-clock"
  local line = string.format('%s,"%s",%s\n', when, label, table.concat(parts, " "))
  if not fs.exists(LOG) then fs.write(LOG, "time,label,aps\n") end
  fs.append(LOG, line)
  gfx.clear(); gfx.text(14, 14, "Saved " .. #parts .. " APs to breadcrumbs.csv", "ui12"); gfx.present()
  while input.wait() ~= "back" do end
end

local ok, err = pcall(main)
if not ok then
  pcall(function() wifi.monitor_stop() end)
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
