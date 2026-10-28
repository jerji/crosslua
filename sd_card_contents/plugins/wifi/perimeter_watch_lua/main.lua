-- Perimeter watch: learn the access points heard during a baseline phase, then watch for
-- changes: a NEW AP appearing, or a baseline AP going silent for GONE_MS. Receive only.

local LEARN_MS = 60000        -- baseline phase length
local GONE_MS = 120000        -- silent this long => "gone"
local DWELL_MS = 800
local REFRESH_MS = 1000
local MAX_APS = 80
local MAX_EVENTS = 6
local CHANS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }

local W, H = 0, 0
local known = {}              -- bssid6 -> {ssid, ch, last}
local known_count = 0
local events = {}
local phase = "learn"         -- learn | watch
local learn_t0 = 0
local ci, last_hop, last_draw = 1, 0, 0
local status = ""

local function clip(s, n) return #s > n and s:sub(1, n) or s end

local function mac(b) return string.format("%02x:%02x:%02x:%02x:%02x:%02x", b:byte(1, 6)) end

local function event(s)
  table.insert(events, 1, s)
  if #events > MAX_EVENTS then table.remove(events) end
end

local function on_beacon(frame, ch, now)
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
  local k = known[bssid]
  if k then
    if k.gone then
      k.gone = false
      event("BACK  " .. clip(k.ssid ~= "" and k.ssid or mac(bssid), 16))
    end
    k.last = now
    if ssid ~= "" then k.ssid = ssid end
    k.ch = ch
  elseif phase == "watch" then
    if known_count < MAX_APS then
      known[bssid] = { ssid = ssid, ch = ch, last = now, new = true }
      known_count = known_count + 1
      event("NEW   " .. clip(ssid ~= "" and ssid or mac(bssid), 16) .. " ch" .. ch)
    end
  elseif known_count < MAX_APS then
    known[bssid] = { ssid = ssid, ch = ch, last = now }
    known_count = known_count + 1
  end
end

local function check_gone(now)
  if phase ~= "watch" then return end
  for bssid, k in pairs(known) do
    if not k.gone and now - k.last > GONE_MS then
      k.gone = true
      event("GONE  " .. clip(k.ssid ~= "" and k.ssid or mac(bssid), 16))
    end
  end
end

local function draw(now)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, "Perimeter Watch", "ui12", "bw")
  local y = 56
  if phase == "learn" then
    local left = math.max(0, (LEARN_MS - (now - learn_t0)) // 1000)
    gfx.text(14, y, "Learning baseline...", "ui12")
    y = y + 30
    gfx.text(14, y, string.format("%d s left, %d APs so far", left, known_count), "ui12")
    y = y + 30
    gfx.text(14, y, "Stay put: these become the baseline.", "small")
  else
    local gone = 0
    for _, k in pairs(known) do if k.gone then gone = gone + 1 end end
    gfx.text(14, y, string.format("Known %d APs  |  gone %d", known_count, gone), "ui12")
    y = y + 30
    gfx.text(14, y, "Channel " .. CHANS[ci], "ui12")
    y = y + 40
    gfx.text(14, y, "Events:", "ui12")
    y = y + 26
    if #events == 0 then gfx.text(14, y, "none yet", "small") end
    for _, e in ipairs(events) do
      gfx.text(14, y, clip(e, 40), "small")
      y = y + 24
    end
  end
  gfx.text(14, H - 34, status ~= "" and status or "Back = stop and exit", "small")
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
  learn_t0 = system.millis()
  last_hop = learn_t0
  while true do
    local now = system.millis()
    local frame, meta = wifi.monitor_recv()
    while frame do
      on_beacon(frame, (meta and meta.channel) or CHANS[ci], now)
      frame, meta = wifi.monitor_recv()
    end
    if phase == "learn" and now - learn_t0 >= LEARN_MS then
      phase = "watch"
      status = "Baseline set: " .. known_count .. " APs"
    end
    check_gone(now)
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
