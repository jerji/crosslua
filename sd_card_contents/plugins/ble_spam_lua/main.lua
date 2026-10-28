-- BLE spam presets: Google Fast Pair + Microsoft Swift Pair (bluetooth, ACTIVE: transmits).
-- ble.start("raw") + ble.advertise(); Fast Pair uses the service-data AD (service_uuid 0xFE2C +
-- 24-bit model ID), Swift Pair uses manufacturer data (company 0x0006, beacon 0x03) plus a name.
-- Non-connectable broadcast. Advertising runs only while toggled on; Back stops it and exits.

local INTERVAL_MS = 100
local FASTPAIR_UUID = 0xFE2C  -- Google LLC

-- Swift Pair: Microsoft's pairing beacon. Manufacturer data = company 0x0006 (LE 06 00), Microsoft
-- beacon type 0x03, scenario 0x00 (Swift Pair), reserved 0x80. The device name rides in the complete
-- local name, so Windows shows the name as a pairing prompt.
local MS_DATA = "\x06\x00\x03\x00\x80"
-- Generic device names. Keep each at most 16 bytes so the whole advert fits in 31 bytes.
local NAMES = { "Keyboard", "Mouse", "Headset", "Speaker", "Gamepad", "Stylus" }

-- Fast Pair presets: 24-bit model IDs, big-endian in the payload. Genuine device IDs are public
-- (published in Google's Fast Pair guidance and crowdsourced lists); nearby Android devices show
-- that device's pairing popup.
local MODELS = {
  { name = "Bose NC 700",   id = 0xCD8256 },
  { name = "JBL Buds Pro",  id = 0xF52494 },
  { name = "JBL Live 300TWS", id = 0x718FA4 },
  { name = "JBL Flip 6",    id = 0x821F66 },
  { name = "Pixel Buds",    id = 0x92BBBD },
  { name = "Sony WF-1000XM4", id = 0x2D7A23 },
  { name = "Random model",  id = nil },   -- random ID every push; 3 bytes of noise
}

-- Pure builders, host-testable.

local function swift_pair_options(name)
  return { name = name, data = MS_DATA, connectable = false, interval_ms = INTERVAL_MS }
end

local function fastpair_options(model_id, tx_power)
  local m = model_id % 0x1000000
  -- service_data = 3-byte model ID big-endian + 1-byte Tx Power (0x0A type value rides in the
  -- service-data payload per the Fast Pair beacon format).
  local sd = string.char((m >> 16) & 0xFF, (m >> 8) & 0xFF, m & 0xFF, tx_power & 0xFF)
  return { service_uuid = FASTPAIR_UUID, service_data = sd, connectable = false, interval_ms = INTERVAL_MS }
end

local function random_model_id()
  -- Three random bytes, avoiding 0x000000 (reserved "unset" marker in the protocol).
  local b1, b2, b3
  repeat
    b1 = math.random(0, 255); b2 = math.random(0, 255); b3 = math.random(0, 255)
  until not (b1 == 0 and b2 == 0 and b3 == 0)
  return (b1 << 16) | (b2 << 8) | b3
end

-- UI ------------------------------------------------------------------------

local function draw_header(title, W)
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, title, "ui12", "bw")
end

local function draw_footer(adv, msg, hint, W, H)
  gfx.text(14, H - 108, adv and "ADVERTISING (transmitting)" or "stopped", "ui12", "b")
  if msg then gfx.text(14, H - 84, tostring(msg):sub(1, 44), "small") end
  gfx.text(14, H - 60, hint, "small")
  gfx.text(14, H - 42, "confirm: start/stop   back: exit", "small")
end

local function draw_swift_menu(cur, adv, msg)
  gfx.clear()
  local W, H = gfx.size()
  draw_header("Swift Pair (Windows)", W)
  local y = 60
  for i, n in ipairs(NAMES) do
    local sel = (i == cur)
    if sel then gfx.rect(10, y - 4, W - 20, 30, true) end
    local tag = (adv and sel) and "  [on air]" or ""
    gfx.text(18, y, n .. tag, "ui12", sel and "w" or "")
    y = y + 40
  end
  draw_footer(adv, msg, "up/down: choose name", W, H)
  gfx.present()
end

local function draw_fastpair_menu(cur, adv, msg)
  gfx.clear()
  local W, H = gfx.size()
  draw_header("Fast Pair (Android)", W)
  local y = 48
  for i, m in ipairs(MODELS) do
    local sel = (i == cur)
    if sel then gfx.rect(10, y - 4, W - 20, 26, true) end
    local idtxt = m.id and ("0x" .. string.format("%06X", m.id)) or "random"
    local tag = (adv and sel) and " [on air]" or ""
    gfx.text(18, y, m.name .. tag, "ui12", sel and "w" or "")
    gfx.text(W - 130, y, idtxt, "small", sel and "w" or "")
    y = y + 30
  end
  draw_footer(adv, msg, "up/down: choose model", W, H)
  gfx.present()
end

-- Returns when Back is pressed. The radio stays up; the caller stops it.
-- draw(cur, adv, msg), options(cur) -> advertise options table.
local function menu(title, items, draw, options)
  local cur, adv, msg = 1, false, nil
  local function push()
    local opt = options(cur)
    local ok, err = ble.advertise(opt)
    if ok then adv, msg = true, nil else adv, msg = false, err or "advertise failed" end
  end
  while true do
    draw(cur, adv, msg)
    local e = input.wait()
    if e == "back" then break
    elseif e == "up" then
      cur = (cur > 1) and (cur - 1) or #items
      if adv then push() end  -- switching preset while on air re-advertises at once
    elseif e == "down" then
      cur = (cur % #items) + 1
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

local function swift_pair_menu()
  menu("Swift Pair", NAMES, draw_swift_menu, function(cur) return swift_pair_options(NAMES[cur]) end)
end

local function fastpair_menu()
  menu("Fast Pair", MODELS, draw_fastpair_menu, function(cur)
    local m = MODELS[cur]
    -- Tx Power: a plausible 0 dBm. Random presets get a fresh model ID on every (re)advertise.
    local id = m.id or random_model_id()
    return fastpair_options(id, 0)
  end)
end

-- Protocol chooser -----------------------------------------------------------

local function draw_protocol_menu(cur)
  gfx.clear()
  local W, H = gfx.size()
  draw_header("BLE spam presets", W)
  local protos = { "Google Fast Pair (Android)", "Microsoft Swift Pair (Windows)" }
  local y = 70
  for i, p in ipairs(protos) do
    local sel = (i == cur)
    if sel then gfx.rect(10, y - 6, W - 20, 34, true) end
    gfx.text(18, y, p, "ui12", sel and "w" or "")
    y = y + 46
  end
  gfx.text(14, H - 42, "confirm: open   back: exit", "small")
  gfx.present()
end

local function protocol_menu()
  local cur = 1
  while true do
    draw_protocol_menu(cur)
    local e = input.wait()
    if e == "back" then return false
    elseif e == "up" then cur = (cur > 1) and (cur - 1) or 2
    elseif e == "down" then cur = (cur % 2) + 1
    elseif e == "confirm" then
      if cur == 1 then fastpair_menu() else swift_pair_menu() end
    end
  end
end

local function warning()
  gfx.clear()
  local W, H = gfx.size()
  gfx.text(14, 16, "BLE spam: ACTIVE", "ui12", "b")
  gfx.text(14, 56, "This app transmits Fast Pair / Swift", "small")
  gfx.text(14, 74, "Pair beacons. Nearby Android/Windows", "small")
  gfx.text(14, 92, "devices show pairing prompts. Use it on", "small")
  gfx.text(14, 110, "your own gear or in an authorized test.", "small")
  gfx.text(14, H - 42, "confirm = continue   back = exit", "small")
  gfx.present()
  while true do
    local e = input.wait()
    if e == "confirm" then return true end
    if e == "back" then return false end
  end
end

local ok, err = pcall(function()
  math.randomseed(app.uptime())
  if not warning() then return end
  local started, serr = ble.start("raw")
  if not started then error("ble.start: " .. tostring(serr)) end
  protocol_menu()
end)
pcall(function() ble.advertise_stop() end)
pcall(function() ble.stop() end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
