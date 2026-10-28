-- Passive sniffer: receive-only 802.11 capture on channels 1..13 (hop), live counters, optional PCAP.
-- Never transmits: no wifi.tx, no frames sent. PCAPs go to data: (this app's own folder on the card).

local DWELL_MS = 1200          -- time on each channel before hopping
local REFRESH_MS = 1000        -- redraw period
local MAX_MACS = 200           -- unique transmitter MACs kept in RAM (raw 6-byte keys)
local MAX_SSIDS = 40          -- unique SSIDs kept in RAM
local LH = 26

local W, H = 0, 0

local MODES = {
  { label = "Hop 1-13, save PCAP", chans = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }, pcap = true },
  { label = "Hop 1-13, stats only", chans = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }, pcap = false },
  { label = "Hop 1/6/11, save PCAP", chans = { 1, 6, 11 }, pcap = true },
  { label = "Quit", quit = true },
}

-- ---------- drawing helpers ----------
local function header(title)
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, title, "ui12", "bw")
end

local function footer(text)
  gfx.text(14, H - 34, text, "small")
end

local menu_cur = 1
local function menu(title, items, hint)
  while true do
    gfx.clear()
    W, H = gfx.size()
    header(title)
    local y = 60
    for i, item in ipairs(items) do
      if i == menu_cur then
        gfx.rect(10, y - 4, W - 20, LH + 4, true)
        gfx.text(18, y, item.label, "ui12", "w")
      else
        gfx.text(18, y, item.label, "ui12")
      end
      y = y + LH + 8
    end
    footer(hint)
    gfx.present()
    local e = input.wait()
    if e == "up" then
      menu_cur = menu_cur > 1 and menu_cur - 1 or #items
    elseif e == "down" then
      menu_cur = menu_cur < #items and menu_cur + 1 or 1
    elseif e == "confirm" then
      return items[menu_cur]
    elseif e == "back" then
      return nil
    end
  end
end

-- ---------- frame parsing ----------
-- 802.11 header: fc(2) dur(2) addr1(6) addr2(6) addr3(6) seq(2). addr2 = transmitter, bytes 11..16.

-- Walk tagged parameters for tag 0 (SSID). start = 1-based index of the first tag.
local function find_ssid(frame, start)
  local i = start
  while i + 1 <= #frame do
    local tag, len = frame:byte(i), frame:byte(i + 1)
    if tag == 0 then
      if len == 0 then return nil end
      return frame:sub(i + 2, i + 1 + len)
    end
    i = i + 2 + len
  end
  return nil
end

local function printable(s)
  return s:match("^[%g ]+$") ~= nil
end

-- ---------- state ----------
local st = {
  running = false, channel = 0, chan_idx = 1, last_hop = 0, last_draw = 0,
  frames = 0, beacons = 0, probes = 0, data = 0, other = 0,
  macs = {}, mac_count = 0, ssids = {}, ssid_count = 0, recent = {},
  pcap_file = nil, status = "",
}

local function note_ssid(name)
  if st.ssids[name] then return end
  if st.ssid_count >= MAX_SSIDS then return end
  st.ssids[name] = true
  st.ssid_count = st.ssid_count + 1
  table.insert(st.recent, 1, name)
  if #st.recent > 4 then table.remove(st.recent) end
end

local function process(frame)
  st.frames = st.frames + 1
  if #frame < 16 then st.other = st.other + 1; return end
  local fc = frame:byte(1)
  local ftype, sub = (fc >> 2) & 3, (fc >> 4) & 15

  if st.mac_count < MAX_MACS then
    local m = frame:sub(11, 16)          -- raw 6-byte key, cheap in RAM
    if not st.macs[m] then
      st.macs[m] = true
      st.mac_count = st.mac_count + 1
    end
  end

  if ftype == 0 then
    if sub == 8 then
      st.beacons = st.beacons + 1
      local name = find_ssid(frame, 37)     -- 24 header + 12 fixed beacon params
      if name and printable(name) then note_ssid(name) end
    elseif sub == 4 then
      st.probes = st.probes + 1
      local name = find_ssid(frame, 25)     -- probe request: tags right after header
      if name and printable(name) then note_ssid(name) end
    else
      st.other = st.other + 1
    end
  elseif ftype == 2 then
    st.data = st.data + 1
  else
    st.other = st.other + 1
  end
end

local function draw()
  gfx.clear()
  W, H = gfx.size()
  header("Passive Sniffer")
  local y = 56
  local function line(s, font)
    gfx.text(16, y, s, font or "ui12")
    y = y + LH + 6
  end
  line(string.format("Channel %d   (%s)", st.channel, st.pcap_file and "PCAP" or "stats"))
  line(string.format("Frames  %d   dropped %d", st.frames, st.dropped or 0))
  line(string.format("Beacons %d   Probes %d", st.beacons, st.probes))
  line(string.format("Data %d   Other %d", st.data, st.other))
  line(string.format("Unique MACs %d%s", st.mac_count, st.mac_count >= MAX_MACS and "+" or ""))
  line(string.format("Unique SSIDs %d", st.ssid_count))
  y = y + 8
  line("Recent SSIDs:", "sans14")
  for _, n in ipairs(st.recent) do
    line("  " .. n:sub(1, 30), "small")
  end
  footer(st.status ~= "" and st.status or "Back = stop and exit")
  gfx.present()
end

local function next_pcap_name()
  for n = 1, 999 do
    local name = string.format("data:capture_%03d.pcap", n)
    if not fs.exists(name) then return name end
  end
  return nil
end

local function start_capture(mode)
  st.chan_idx = 1
  st.channel = mode.chans[1]
  st.pcap_file = nil
  local opts = { channel = st.channel }
  if mode.pcap then
    st.pcap_file = next_pcap_name()
    if not st.pcap_file then return nil, "no free capture name" end
    opts.file = st.pcap_file
  end
  local ok, err = wifi.monitor_start(opts)
  if not ok then return nil, err or "monitor_start failed" end
  st.running = true
  st.chans = mode.chans
  st.last_hop = system.millis()
  return true
end

local function hop_if_due(now)
  if #st.chans < 2 then return end
  if now - st.last_hop < DWELL_MS then return end
  st.chan_idx = st.chan_idx % #st.chans + 1
  st.channel = st.chans[st.chan_idx]
  st.last_hop = now
  wifi.monitor_channel(st.channel)
end

local function stop_capture()
  if not st.running then return end
  local bytes = wifi.monitor_stop()
  st.running = false
  if st.pcap_file then
    st.status = string.format("Saved %s (%d bytes)", st.pcap_file, bytes or 0)
  else
    st.status = "Stopped"
  end
end

local function run_capture(mode)
  st.frames, st.beacons, st.probes, st.data, st.other = 0, 0, 0, 0, 0
  st.macs, st.mac_count, st.ssids, st.ssid_count, st.recent = {}, 0, {}, 0, {}
  st.status = ""
  local ok, err = start_capture(mode)
  if not ok then
    gfx.clear(); W, H = gfx.size()
    header("Passive Sniffer")
    gfx.text(16, 60, "Could not start:", "ui12")
    gfx.text(16, 90, tostring(err):sub(1, 60), "small")
    footer("Back to menu")
    gfx.present()
    while input.wait() ~= "back" do end
    return
  end

  draw()
  while true do
    -- drain everything the ring has right now
    local frame, meta = wifi.monitor_recv()
    while frame do
      process(frame)
      frame, meta = wifi.monitor_recv()
    end
    local now = system.millis()
    hop_if_due(now)
    local e = input.poll()
    if e == "back" then
      break
    end
    if now - st.last_draw >= REFRESH_MS then
      local info = wifi.monitor_info()
      st.dropped = info and info.dropped or 0
      draw()
      st.last_draw = now
    end
    app.sleep(10)
  end
  stop_capture()
  draw()
  -- wait one more Back press so the saved-file message can be read
  while input.wait() ~= "back" do end
end

local function main()
  W, H = gfx.size()
  while true do
    local pick = menu("Passive Sniffer", MODES,
      "Receive only. Back = leave.")
    if not pick or pick.quit then break end
    run_capture(pick)
  end
  if st.running then stop_capture() end
end

local ok, err = pcall(main)
if not ok then
  pcall(function()
    if st.running then wifi.monitor_stop() end
  end)
  gfx.clear()
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b")
  gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
