-- BLE beacons (bluetooth, ACTIVE: transmits). ble.start("raw") + ble.advertise({name, data}).
-- Presets: iBeacon layout (Apple company 0x004C, fixed generic UUID, editable major/minor/tx power),
-- a named beacon, and custom manufacturer data (company ID + one payload byte).
-- Beacons are non-connectable and transmit only while advertising is on; Back stops them.
-- Edits while advertising re-advertise immediately (ble.advertise replaces the advertisement).

local UUID_HEX = "E2C56DB5DFFB48D2B060D0F5A71096E0"  -- generic sample UUID, not tied to any vendor
local UUID = (UUID_HEX:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
local NAMES = { "BLE-Beacon", "Sensor-01", "Tracker", "Gadget" }
local INTERVAL_MS = 100

local PRESETS = {
  { id = "ibeacon", label = "iBeacon layout", fields = {
      { key = "major", label = "Major", min = 0, max = 65535 },
      { key = "minor", label = "Minor", min = 0, max = 65535 },
      { key = "tx", label = "Tx power", min = -127, max = 20 } } },
  { id = "name", label = "Named beacon", fields = {
      { key = "name", label = "Name", list = NAMES } } },
  { id = "mfr", label = "Custom manufacturer data", fields = {
      { key = "name", label = "Name", list = NAMES },
      { key = "company", label = "Company ID", min = 0, max = 65535 },
      { key = "payload", label = "Payload byte", min = 0, max = 255 } } },
}

local function new_state()
  return { major = 1, minor = 1, tx = -59, name = 1, company = 0x004C, payload = 0 }
end

-- Options for ble.advertise() from a preset and its values. Integers only; all bytes via string.char.
local function build(id, st)
  if id == "ibeacon" then
    local be16 = function(v) return string.char((v >> 8) & 0xFF, v & 0xFF) end
    -- 0x4C 0x00 = Apple company ID (little endian), 0x02 0x15 = iBeacon type and length
    local data = "\x4C\x00\x02\x15" .. UUID .. be16(st.major) .. be16(st.minor) .. string.char(st.tx & 0xFF)
    return { data = data, interval_ms = INTERVAL_MS }  -- 25 bytes: fits the 31-byte limit, no name
  elseif id == "name" then
    return { name = NAMES[st.name], interval_ms = INTERVAL_MS }
  else
    local data = string.char(st.company & 0xFF, (st.company >> 8) & 0xFF, st.payload & 0xFF)
    return { name = NAMES[st.name], data = data, interval_ms = INTERVAL_MS }
  end
end

local function value_text(f, st)
  if f.list then return f.list[st[f.key]] end
  if f.key == "company" then return string.format("0x%04X", st[f.key]) end
  return tostring(st[f.key])
end

-- Change one field by d (integers). Lists wrap; numbers clamp to their range.
local function change(f, st, d)
  if f.list then
    st[f.key] = ((st[f.key] - 1 + d) % #f.list) + 1
  else
    st[f.key] = math.max(f.min, math.min(f.max, st[f.key] + d))
  end
end

local function draw_editor(p, st, cur, adv, msg)
  gfx.clear()
  local W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, p.label, "ui12", "bw")
  local y = 60
  for i, f in ipairs(p.fields) do
    local sel = (i == cur)
    if sel then gfx.rect(10, y - 4, W - 20, 30, true) end
    gfx.text(18, y, f.label .. ": " .. value_text(f, st), "ui12", sel and "w" or "")
    y = y + 40
  end
  gfx.text(14, H - 108, adv and "ADVERTISING (transmitting)" or "stopped", "ui12", "b")
  if msg then gfx.text(14, H - 84, tostring(msg):sub(1, 44), "small") end
  gfx.text(14, H - 60, "left/right: field  up/down: value", "small")
  gfx.text(14, H - 42, "hold up/down: +/-10", "small")
  gfx.text(14, H - 24, "confirm: start/stop   back: menu", "small")
  gfx.present()
end

-- Returns when Back is pressed. Radio stays up; the caller stops it on exit.
local function editor(p, st)
  local cur, adv, msg = 1, false, nil
  local function push()
    local ok, err = ble.advertise(build(p.id, st))
    if not ok then adv, msg = false, err or "advertise failed" else adv, msg = true, nil end
  end
  while true do
    draw_editor(p, st, cur, adv, msg)
    local e = input.wait()
    if e == "back" then break
    elseif e == "left" then cur = (cur > 1) and (cur - 1) or #p.fields
    elseif e == "right" then cur = (cur % #p.fields) + 1
    elseif e == "up" or e == "down" or e == "up_hold" or e == "down_hold" then
      local d = (e:sub(1, 2) == "up") and 1 or -1
      if e:find("hold", 1, true) then d = d * 10 end
      change(p.fields[cur], st, d)
      if adv then push() end
    elseif e == "confirm" then
      if adv then
        ble.advertise_stop(); adv, msg = false, nil
      else
        push()
      end
    end
  end
  if adv then ble.advertise_stop() end
end

local function menu()
  local cur = 1
  local states = {}
  for _, p in ipairs(PRESETS) do states[p.id] = new_state() end
  while true do
    gfx.clear()
    local W, H = gfx.size()
    gfx.rect(0, 0, W, 40, true)
    gfx.text(14, 10, "BLE beacons", "ui12", "bw")
    local y = 60
    for i, p in ipairs(PRESETS) do
      local sel = (i == cur)
      if sel then gfx.rect(10, y - 4, W - 20, 30, true) end
      gfx.text(18, y, p.label, "ui12", sel and "w" or "")
      y = y + 40
    end
    gfx.text(14, H - 60, "up/down: choose   confirm: open", "small")
    gfx.text(14, H - 42, "Back = stop everything and exit", "small")
    gfx.present()
    local e = input.wait()
    if e == "back" then return
    elseif e == "up" then cur = (cur > 1) and (cur - 1) or #PRESETS
    elseif e == "down" then cur = (cur % #PRESETS) + 1
    elseif e == "confirm" then editor(PRESETS[cur], states[PRESETS[cur].id]) end
  end
end

local function warning()
  gfx.clear()
  local W, H = gfx.size()
  gfx.text(14, 16, "BLE beacons: ACTIVE", "ui12", "b")
  gfx.text(14, 56, "This app transmits Bluetooth LE advertisements that", "small")
  gfx.text(14, 74, "look like iBeacons or named devices. Use it on your", "small")
  gfx.text(14, 92, "own gear or for testing. Nearby phones will see them.", "small")
  gfx.text(14, H - 42, "confirm = continue   back = exit", "small")
  gfx.present()
  while true do
    local e = input.wait()
    if e == "confirm" then return true end
    if e == "back" then return false end
  end
end

local ok, err = pcall(function()
  if not warning() then return end
  local started, serr = ble.start("raw")
  if not started then error("ble.start: " .. tostring(serr)) end
  menu()
end)
pcall(function() ble.advertise_stop() end)
pcall(function() ble.stop() end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
