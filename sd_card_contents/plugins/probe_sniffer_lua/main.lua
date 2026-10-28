-- Probe sniffer (passive, receive only): hop 2.4 GHz and record probe requests:
-- which station (MAC) is asking for which network name (SSID). Confirm exports data:probes.csv.
-- Targeting view: every station, or filter the list to one SSID.

local CHANS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }
local DWELL_MS = 800
local MAX_PAIRS = 200
local LH = 26

local W, H = 0, 0
local pairs_seen = {}        -- key ssid .. "\0" .. mac6 -> { ssid, mac, count, ch }
local pair_list = {}
local ci, last_hop, last_draw = 1, 0, 0
local status = ""
local filter = nil           -- nil = all SSIDs, or an SSID string

local function clip(s, n) return #s > n and s:sub(1, n) or s end
local function mac(b) return string.format("%02x:%02x:%02x:%02x:%02x:%02x", b:byte(1, 6)) end

local function on_probe(frame, ch)
  if #frame < 26 or (frame:byte(1) & 0xFC) ~= 0x40 then return end
  local ssid_len = frame:byte(26)
  local ssid = frame:sub(27, 26 + ssid_len)
  if frame:byte(25) ~= 0 or ssid_len == 0 or not ssid:match("^[%g ]+$") then return end
  local sta = frame:sub(11, 16)
  local key = ssid .. "\0" .. sta
  local p = pairs_seen[key]
  if p then p.count = p.count + 1; return end
  if #pair_list >= MAX_PAIRS then return end
  p = { ssid = ssid, mac = sta, count = 1, ch = ch }
  pairs_seen[key] = p
  pair_list[#pair_list + 1] = p
end

local function export()
  local name
  for n = 1, 999 do
    local c = string.format("data:probes_%03d.csv", n)
    if not fs.exists(c) then name = c; break end
  end
  if not name then return "no free file name" end
  local rows = { "ssid,station,count,channel" }
  for _, p in ipairs(pair_list) do
    rows[#rows + 1] = string.format('"%s",%s,%d,%d', p.ssid:gsub('"', '""'), mac(p.mac), p.count, p.ch)
  end
  local ok, err = fs.write(name, table.concat(rows, "\n") .. "\n")
  if not ok then return "export failed: " .. tostring(err) end
  return "saved " .. name .. " (" .. #pair_list .. " rows)"
end

local function draw()
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, "Probe Sniffer", "ui12", "bw")
  gfx.text(14, 50, "filter: " .. (filter and clip(filter, 24) or "all SSIDs"), "small")
  gfx.text(14, 74, string.format("%d probe pairs  ch %d", #pair_list, CHANS[ci]), "small")
  local y = 100
  local shown = 0
  for _, p in ipairs(pair_list) do
    if not filter or p.ssid == filter then
      if y > H - 90 then break end
      gfx.text(14, y, clip(p.ssid, 18) .. "  " .. mac(p.mac) .. "  x" .. p.count, "small")
      y = y + LH
      shown = shown + 1
    end
  end
  if shown == 0 then gfx.text(14, y, "listening...", "ui12") end
  gfx.text(14, H - 60, status ~= "" and status or "Up/Down = next filter", "small")
  gfx.text(14, H - 34, "Confirm = export CSV, Back = exit", "small")
  gfx.present()
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
  draw()
  while true do
    local frame, meta = wifi.monitor_recv()
    while frame do
      on_probe(frame, (meta and meta.channel) or CHANS[ci])
      frame, meta = wifi.monitor_recv()
    end
    local now = system.millis()
    if now - last_hop >= DWELL_MS then
      ci = ci % #CHANS + 1
      wifi.monitor_channel(CHANS[ci])
      last_hop = now
    end
    local e = input.poll()
    if e == "back" then break
    elseif e == "confirm" then status = export(); draw()
    elseif e == "down" or e == "up" then
      -- cycle the filter through the SSIDs seen so far
      local names, seen = {}, {}
      for _, p in ipairs(pair_list) do if not seen[p.ssid] then seen[p.ssid] = true; names[#names + 1] = p.ssid end end
      if #names == 0 then filter = nil
      else
        local idx = 0
        for i, n in ipairs(names) do if n == filter then idx = i end end
        if e == "down" then idx = idx + 1 else idx = idx - 1 end
        if idx < 0 or idx > #names then filter = nil else filter = names[idx] end
      end
      draw()
    end
    if now - last_draw >= 1000 then draw(); last_draw = now end
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
