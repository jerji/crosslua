-- AirTag test (bluetooth, ACTIVE: transmits). ble.start("raw") + ble.advertise({data=..., interval_ms=...}).
-- Broadcasts the Apple Find My "offline finding" advertisement layout (company 0x004C, type 0x12, length 0x19):
--   4C 00 | 12 19 | status(1) | key(22) | key bits(1) | hint(1)
-- Keys are random test material (crypto.random). They are not tied to any Apple account or real tag, so this
-- is a detection / parser test signal, not a working tracker.
-- Mode "rotate" replaces the key every ROTATE_MS while advertising (Apple's cadence is ~15 min); "fixed" keeps one key.
-- The advertisement is replaced in place when the key rotates. Back stops the radio and exits.

local ROTATE_MS = 15 * 60 * 1000
local INTERVAL_MS = 2000       -- Find My offline advertisements go out about every 2 s
local TICK_MS = 1000           -- input.wait timeout, so rotation timing runs while idle
local MODES = { "rotate", "fixed" }

local function hex8(s)
  return (s:sub(1, 8):gsub(".", function(c) return string.format("%02X ", c:byte()) end))
end

-- Build the manufacturer data (company ID first) for one key. Random key: 28 bytes, the advertised key is bytes 7..28.
local function make_key()
  local full = crypto.random(28)
  return { key = full:sub(7, 28), bits = full:byte(1) >> 6, status = 0x00 }
end

local function payload(k)
  return "\x4C\x00\x12\x19" .. string.char(k.status) .. k.key .. string.char(k.bits) .. "\x00"
end

local function warning()
  gfx.clear()
  local _, H = gfx.size()
  gfx.text(14, 16, "AirTag test: ACTIVE", "ui12", "b")
  gfx.text(14, 56, "Transmits Apple Find My offline-finding adverts", "small")
  gfx.text(14, 74, "with random test keys. Not tied to any Apple", "small")
  gfx.text(14, 92, "account or real tag. Use on your own gear.", "small")
  gfx.text(14, H - 42, "confirm = continue   back = exit", "small")
  gfx.present()
  while true do
    local e = input.wait()
    if e == "confirm" then return true end
    if e == "back" then return false end
  end
end

local function draw(st, msg)
  gfx.clear()
  local W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, "AirTag test (Find My)", "ui12", "bw")
  local y = 60
  gfx.text(18, y, st.adv and "ADVERTISING (transmitting)" or "stopped", "ui12", "b"); y = y + 40
  gfx.text(18, y, "Mode: " .. (st.mode == "rotate" and "rotate every 15 min" or "fixed key"), "ui12"); y = y + 40
  gfx.text(18, y, "Key: " .. (st.k and hex8(st.k.key) or "(none yet)"), "ui12"); y = y + 40
  gfx.text(18, y, "Key bits: " .. (st.k and st.k.bits or 0) .. "   Rotations: " .. st.rotations, "ui12"); y = y + 40
  gfx.text(18, y, "Interval: " .. INTERVAL_MS .. " ms", "ui12"); y = y + 40
  if msg then gfx.text(14, H - 108, tostring(msg):sub(1, 44), "small") end
  gfx.text(14, H - 84, "left/right: mode (stopped)", "small")
  gfx.text(14, H - 66, "up: new key now", "small")
  gfx.text(14, H - 48, "confirm: start/stop", "small")
  gfx.text(14, H - 30, "back: stop and exit", "small")
  gfx.present()
end

local function run()
  local st = { adv = false, mode = "rotate", k = nil, rotations = 0, since = 0 }
  local msg = nil

  local function new_key()
    st.k = make_key()
    st.since = system.millis()
  end

  local function push()
    local ok, err = ble.advertise({ data = payload(st.k), interval_ms = INTERVAL_MS })
    if not ok then
      st.adv = false
      msg = err or "advertise failed"
      return false
    end
    st.adv = true
    msg = nil
    return true
  end

  local function stop()
    ble.advertise_stop()
    st.adv = false
  end

  draw(st, nil)
  while true do
    local e = input.wait(TICK_MS)
    local dirty = false
    if e == "back" then break
    elseif e == "left" or e == "right" then
      if not st.adv then
        st.mode = (st.mode == MODES[1]) and MODES[2] or MODES[1]
        dirty = true
      end
    elseif e == "up" then
      new_key(); st.rotations = st.rotations + 1
      if st.adv then push() end
      dirty = true
    elseif e == "confirm" then
      if st.adv then
        stop()
      else
        if st.mode == "rotate" or st.k == nil then new_key() end
        push()
      end
      dirty = true
    end
    -- Rotation check (wrap-safe subtraction on the 31-bit millis counter).
    if st.adv and st.mode == "rotate" and ((system.millis() - st.since) & 0x7FFFFFFF) >= ROTATE_MS then
      new_key(); st.rotations = st.rotations + 1
      push()
      dirty = true
    end
    if dirty then draw(st, msg) end
  end
  if st.adv then stop() end
end

local ok, err = pcall(function()
  if not warning() then return end
  local started, serr = ble.start("raw")
  if not started then error("ble.start: " .. tostring(serr)) end
  run()
end)
pcall(function() ble.advertise_stop() end)
pcall(function() ble.stop() end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
