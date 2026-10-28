-- Deauth detector: receive-only watch for 802.11 deauthentication (subtype 12) and
-- disassociation (subtype 10) management frames. Counts per channel and raises an alarm
-- when a burst crosses the threshold inside a sliding window. Never transmits.

local DWELL_MS = 1500          -- time on each channel before hopping
local REFRESH_MS = 500
local WINDOW_MS = 10000        -- sliding window for the burst alarm
local BURST = 5                -- frames inside WINDOW_MS that count as an attack
local CHANS = { 1, 6, 11, 2, 3, 4, 5, 7, 8, 9, 10, 12, 13 }
local MAX_EVENTS = 40          -- recent events kept for the log (RAM)

local W, H = 0, 0
local per_chan = {}            -- channel -> deauth/disassoc frame count
local recent = {}              -- rolling timestamps (ms) of hits, pruned to WINDOW_MS
local events = {}              -- short text log of recent alarms
local total = 0
local ci, last_hop, last_draw = 1, 0, 0
local alarm_until = 0
local alarm_text = ""

local function note_event(s)
  table.insert(events, 1, s)
  if #events > 6 then table.remove(events) end
end

local function clip(s, n) return #s > n and s:sub(1, n) or s end

local function mac(b)
  return string.format("%02x:%02x:%02x:%02x:%02x:%02x", b:byte(1, 6))
end

local function on_frame(frame, ch, rssi, now)
  if #frame < 24 then return end
  local fc = frame:byte(1)
  if (fc & 0x0C) ~= 0 then return end                  -- management frames only (type 0)
  local sub = (fc >> 4) & 15
  if sub ~= 12 and sub ~= 10 then return end            -- 12 = deauth, 10 = disassoc
  total = total + 1
  per_chan[ch] = (per_chan[ch] or 0) + 1
  recent[#recent + 1] = now
  local src = mac(frame:sub(11, 16))                    -- addr2 = transmitter
  local kind = sub == 12 and "DEAUTH" or "DISASSOC"
  note_event(string.format("ch%-2d %-8s %s %s", ch, kind, src, rssi and (tostring(rssi) .. "dBm") or ""))
  -- prune window and check the burst
  local keep = {}
  for _, t in ipairs(recent) do
    if now - t <= WINDOW_MS then keep[#keep + 1] = t end
  end
  recent = keep
  if #recent >= BURST then
    alarm_until = now + 4000
    alarm_text = string.format("BURST: %d in %ds", #recent, WINDOW_MS // 1000)
  end
end

local function draw(now)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, "Deauth Detector", "ui12", "bw")
  local y = 56
  gfx.text(14, y, string.format("Total frames seen: %d", total), "ui12")
  y = y + 30
  gfx.text(14, y, "Now on channel " .. CHANS[ci], "ui12")
  y = y + 30
  if now < alarm_until then
    gfx.rect(10, y, W - 20, 40, true)
    gfx.text(18, y + 10, alarm_text, "ui12", "w")
  else
    gfx.text(14, y + 10, "Quiet", "ui12")
  end
  y = y + 56
  gfx.text(14, y, "Per channel:", "ui12")
  y = y + 26
  local line = {}
  for c = 1, 13 do
    if per_chan[c] then line[#line + 1] = string.format("ch%d:%d", c, per_chan[c]) end
  end
  gfx.text(14, y, #line > 0 and table.concat(line, "  ") or "none yet", "small")
  y = y + 40
  gfx.text(14, y, "Log:", "ui12")
  y = y + 24
  for _, e in ipairs(events) do
    gfx.text(14, y, clip(e, 46), "small")
    y = y + 22
  end
  gfx.text(14, H - 34, "Back = stop and exit", "small")
  gfx.present()
end

local function main()
  W, H = gfx.size()
  local ok, err = wifi.monitor_start({ channel = CHANS[ci] })
  if not ok then
    gfx.clear(); gfx.text(16, 60, "Could not start:", "ui12")
    gfx.text(16, 90, clip(tostring(err), 60), "small"); gfx.present()
    while input.wait() ~= "back" do end
    return
  end
  last_hop = system.millis()
  draw(last_hop)
  while true do
    local now = system.millis()
    local frame, meta = wifi.monitor_recv()
    while frame do
      on_frame(frame, (meta and meta.channel) or CHANS[ci], meta and meta.rssi, now)
      frame, meta = wifi.monitor_recv()
    end
    if now - last_hop >= DWELL_MS then
      ci = ci % #CHANS + 1
      wifi.monitor_channel(CHANS[ci])
      last_hop = now
    end
    if input.poll() == "back" then break end
    if now - last_draw >= REFRESH_MS then
      draw(now)
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
