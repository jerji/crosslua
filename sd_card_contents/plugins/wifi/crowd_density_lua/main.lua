-- Crowd density: hop 2.4 GHz, count distinct transmitter MACs heard in a rolling window.
-- Locally-administered MACs (bit 0x02 of the first octet) are usually randomized phones.
-- Receive only; never transmits; nothing is written to the card.

local WINDOW_MS = 60000
local DWELL_MS = 800
local REFRESH_MS = 1000
local MAX_MACS = 300
local CHANS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }

local W, H = 0, 0
local seen = {}                 -- raw 6-byte MAC -> last seen ms
local frames_window = {}        -- timestamps of frames (for frames/s)
local ci, last_hop, last_draw = 1, 0, 0
local dropped_full = 0            -- new MACs refused because RAM cap was full

local function prune(now)
  local n = 0
  for mac, t in pairs(seen) do
    if now - t > WINDOW_MS then
      seen[mac] = nil
    else
      n = n + 1
    end
  end
  local keep = {}
  for _, t in ipairs(frames_window) do
    if now - t <= 1000 then keep[#keep + 1] = t end
  end
  frames_window = keep
end

local function on_frame(frame, now)
  if #frame < 16 then return end
  frames_window[#frames_window + 1] = now
  local mac = frame:sub(11, 16)                       -- transmitter (addr2)
  if not seen[mac] then
    local n = 0
    for _ in pairs(seen) do n = n + 1; if n >= MAX_MACS then break end end
    if n >= MAX_MACS then dropped_full = dropped_full + 1; return end
  end
  seen[mac] = now
end

local function counts()
  local total, random = 0, 0
  for mac in pairs(seen) do
    total = total + 1
    if mac:byte(1) & 0x02 ~= 0 then random = random + 1 end
  end
  return total, random
end

local function draw(now)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, "Crowd Density", "ui12", "bw")
  local total, random = counts()
  gfx.text(14, 60, "Transmitters, last 60 s", "ui12")
  gfx.text(14, 100, tostring(total) .. (total >= MAX_MACS and "+" or ""), "sans18")
  gfx.text(14, 150, string.format("Randomized (phones): %d", random), "ui12")
  gfx.text(14, 180, string.format("Fixed (APs + others): %d", total - random), "ui12")
  gfx.text(14, 230, string.format("Frames/s: %d", #frames_window), "ui12")
  gfx.text(14, 270, "Channel " .. CHANS[ci], "ui12")
  gfx.text(14, 320, "Phones rotate MACs, so this is a", "small")
  gfx.text(14, 344, "lower bound on people, not a census.", "small")
  gfx.text(14, H - 34, "Back = stop and exit", "small")
  gfx.present()
end

local function main()
  W, H = gfx.size()
  local ok, err = wifi.monitor_start({ channel = CHANS[ci] })
  if not ok then
    gfx.clear(); gfx.text(16, 60, "Could not start:", "ui12")
    gfx.text(16, 90, tostring(err):sub(1, 60), "small"); gfx.present()
    while input.wait() ~= "back" do end
    return
  end
  last_hop = system.millis()
  while true do
    local now = system.millis()
    local frame = wifi.monitor_recv()
    while frame do
      on_frame(frame, now)
      frame = wifi.monitor_recv()
    end
    if now - last_hop >= DWELL_MS then
      ci = ci % #CHANS + 1
      wifi.monitor_channel(CHANS[ci])
      last_hop = now
    end
    if now - last_draw >= REFRESH_MS then
      prune(now)
      draw(now)
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
  gfx.clear()
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b")
  gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
