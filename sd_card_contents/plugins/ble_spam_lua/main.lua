-- BLE spam: Swift Pair (bluetooth, ACTIVE: transmits). ble.start("raw") + ble.advertise({name, data}).
-- Swift Pair is Microsoft's pairing beacon: manufacturer data = company 0x0006 (LE 06 00), Microsoft beacon
-- type 0x03, scenario 0x00 (Swift Pair), reserved 0x80. The device name rides in the complete local name, so
-- Windows shows the name as a pairing prompt.
-- NOT here: Fast Pair. It needs a service-data AD (16-bit UUID 0xFE2C) and ble.advertise only sets manufacturer
-- data, so it waits on a core binding (see HANDOFF.md).
-- Non-connectable broadcast. Advertising runs only while toggled on; Back stops it and exits.

local MS_DATA = "\x06\x00\x03\x00\x80"  -- company 0x0006 (Microsoft), beacon 0x03, scenario 0x00, reserved 0x80
local INTERVAL_MS = 100
-- Generic device names. Keep each at most 16 bytes so the whole advert fits in 31 bytes.
local NAMES = { "Keyboard", "Mouse", "Headset", "Speaker", "Gamepad", "Stylus" }

-- Options for ble.advertise() for one name. Pure, so it is testable on the host.
local function swift_pair_options(name)
  return { name = name, data = MS_DATA, connectable = false, interval_ms = INTERVAL_MS }
end

local function draw_menu(cur, adv, msg)
  gfx.clear()
  local W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, "BLE spam: Swift Pair", "ui12", "bw")
  local y = 60
  for i, n in ipairs(NAMES) do
    local sel = (i == cur)
    if sel then gfx.rect(10, y - 4, W - 20, 30, true) end
    local tag = (adv and sel) and "  [on air]" or ""
    gfx.text(18, y, n .. tag, "ui12", sel and "w" or "")
    y = y + 40
  end
  gfx.text(14, H - 108, adv and "ADVERTISING (transmitting)" or "stopped", "ui12", "b")
  if msg then gfx.text(14, H - 84, tostring(msg):sub(1, 44), "small") end
  gfx.text(14, H - 60, "up/down: choose name", "small")
  gfx.text(14, H - 42, "confirm: start/stop   back: exit", "small")
  gfx.present()
end

-- Returns when Back is pressed. The radio stays up; the caller stops it.
local function menu()
  local cur, adv, msg = 1, false, nil
  local function push()
    local ok, err = ble.advertise(swift_pair_options(NAMES[cur]))
    if ok then adv, msg = true, nil else adv, msg = false, err or "advertise failed" end
  end
  while true do
    draw_menu(cur, adv, msg)
    local e = input.wait()
    if e == "back" then break
    elseif e == "up" then
      cur = (cur > 1) and (cur - 1) or #NAMES
      if adv then push() end  -- switching name while on air re-advertises at once
    elseif e == "down" then
      cur = (cur % #NAMES) + 1
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

local function warning()
  gfx.clear()
  local W, H = gfx.size()
  gfx.text(14, 16, "BLE spam: ACTIVE", "ui12", "b")
  gfx.text(14, 56, "This app transmits Swift Pair pairing", "small")
  gfx.text(14, 74, "beacons. Nearby Windows devices will show", "small")
  gfx.text(14, 92, "pairing prompts. Use it on your own gear or", "small")
  gfx.text(14, 110, "in an authorized test.", "small")
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
