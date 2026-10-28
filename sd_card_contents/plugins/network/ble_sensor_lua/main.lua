-- BLE sensor reader (bluetooth): pick a nearby connectable device, connect as a GATT client,
-- then show its readable characteristics (polled every few seconds with ble.read) and its
-- notifying ones (subscribed with ble.notify, drained with ble.notifs). Standard GATT
-- characteristics (battery, temperature, humidity, pressure) are decoded; anything else is shown as hex.
--
-- The radio is used in two steps: raw mode to find devices (ble.observe), then gatt mode to connect
-- (ble.stop + ble.start("gatt")). Back exits, which disconnects and reboots the device cleanly.

local LH = 26

local function s16(d, i)
  local v = d:byte(i) | (d:byte(i + 1) << 8)
  if v >= 0x8000 then v = v - 0x10000 end
  return v
end
local SCAN_REFRESH_MS = 1500
local POLL_MS = 2000
local CONNECT_TIMEOUT_MS = 15000

local STD = {
  ["2a19"] = { "Battery", function(d) return string.format("%d %%", d:byte(1)) end },
  ["2a6e"] = { "Temperature", function(d)
    return string.format("%.2f C", s16(d, 1) / 100) end },
  ["2a6f"] = { "Humidity", function(d)
    return string.format("%.2f %%RH", (d:byte(1) | (d:byte(2) << 8)) / 100) end },
  ["2a6d"] = { "Pressure", function(d)
    local v = d:byte(1) | (d:byte(2) << 8) | (d:byte(3) << 16) | (d:byte(4) << 24)
    return string.format("%.1f kPa", v / 10000) end },
}

function s16(d, i)
  local v = d:byte(i) | (d:byte(i + 1) << 8)
  if v >= 0x8000 then v = v - 0x10000 end
  return v
end

local function hex(d)
  local out = {}
  for i = 1, math.min(#d, 8) do out[#out + 1] = string.format("%02X", d:byte(i)) end
  return table.concat(out, " ") .. (#d > 8 and " ..." or "")
end

local function label_for(c)
  local std = STD[c.uuid]
  if std then return std[1] end
  return c.uuid
end

local function decode(c, data)
  if not data then return "--" end
  if #data == 0 then return "(empty)" end
  local std = STD[c.uuid]
  if std and #data >= 1 then
    local ok, s = pcall(std[2], data)
    if ok and s then return s end
  end
  return hex(data)
end

local function parse_name(data)
  local i = 1
  local name = nil
  while i <= #data do
    local len = data:byte(i)
    if not len or len == 0 then break end
    local t = data:byte(i + 1)
    if t == 0x09 or (t == 0x08 and not name) then name = data:sub(i + 2, i + len) end
    i = i + len + 1
  end
  return name
end

-- Raise to the top-level handler, which draws the message and waits for Back.
local function fail(msg)
  error(tostring(msg), 0)
end

-- Step 1: pick a device. Returns the chosen advert or nil (Back).
local function pick_device()
  local ok, err = ble.start("raw")
  if not ok then error("ble.start: " .. tostring(err)) end
  ble.observe(0, { active = true })      -- active: scan responses carry the names
  local list, cursor, last = {}, 1, nil
  local W, H = gfx.size()
  while true do
    local now = system.millis()
    if not last or now - last >= SCAN_REFRESH_MS then
      list = {}
      for _, a in ipairs(ble.adverts() or {}) do
        if a.connectable then
          list[#list + 1] = { addr = a.addr, addr_type = a.addr_type, rssi = a.rssi,
                              name = parse_name(a.data or "") }
        end
      end
      table.sort(list, function(a, b) return a.rssi > b.rssi end)
      if cursor > #list then cursor = math.max(1, #list) end
      gfx.clear()
      gfx.rect(0, 0, W, 40, true)
      gfx.text(14, 10, "Pick a BLE sensor", "ui12", "bw")
      local y = 52
      for i = 1, math.min(#list, (H - 110) // LH) do
        local d = list[i]
        local line = string.format("%4d  %s  %s", d.rssi, d.addr, (d.name or "(no name)"):sub(1, 14))
        if i == cursor then gfx.rect(8, y - 3, W - 16, LH, true); gfx.text(14, y, line, "small", "w")
        else gfx.text(14, y, line, "small") end
        y = y + LH
      end
      if #list == 0 then gfx.text(14, 60, "listening for connectable devices...", "ui12") end
      gfx.text(14, H - 52, "Up/Down move   Confirm connect", "small")
      gfx.text(14, H - 34, "Back = exit", "small")
      gfx.present()
      last = now
    end
    local e = input.poll()
    if e == "back" then return nil
    elseif e == "up" and cursor > 1 then cursor = cursor - 1; last = nil
    elseif e == "down" and cursor < #list then cursor = cursor + 1; last = nil
    elseif e == "confirm" and list[cursor] then
      ble.observe_stop()
      return list[cursor]
    end
    app.sleep(100)
  end
end

-- Step 2: connect as a GATT client and show the sensor values until Back.
local function run_sensor(dev)
  local ok, err = ble.start("gatt")
  if not ok then error("ble.start gatt: " .. tostring(err)) end
  ok, err = ble.connect(dev.addr, dev.addr_type == 1 and 1 or 0)
  if not ok then error("ble.connect: " .. tostring(err)) end

  local t0 = system.millis()
  while ble.state().link ~= "connected" do
    local st = ble.state()
    if st.link == "failed" then fail("connect failed: " .. tostring(st.reason or "?")) end
    if system.millis() - t0 > CONNECT_TIMEOUT_MS then fail("connect timed out") end
    if input.poll() == "back" then return end
    app.sleep(100)
  end

  local chars, err2 = ble.services()
  if not chars then fail(err2 or "service discovery failed") end
  for _, c in ipairs(chars) do c.uuid = string.lower(c.uuid) end

  -- Readable-and-not-notifying characteristics are polled; notifying ones are subscribed.
  local polled, subs = {}, {}
  for _, c in ipairs(chars) do
    local p = c.props or 0
    if p & 0x10 ~= 0 or p & 0x20 ~= 0 then
      if ble.notify(c.uuid, true) then subs[#subs + 1] = c end
    elseif p & 0x02 ~= 0 then
      polled[#polled + 1] = c
    end
  end
  local all = {}
  for _, c in ipairs(subs) do all[#all + 1] = { c = c, mode = "N" } end
  for _, c in ipairs(polled) do all[#all + 1] = { c = c, mode = "R" } end

  local values, last_poll, dirty = {}, nil, true
  local W, H = gfx.size()
  local function draw()
    gfx.clear()
    gfx.rect(0, 0, W, 40, true)
    gfx.text(14, 10, "BLE sensor: " .. (dev.name or dev.addr):sub(1, 20), "ui12", "bw")
    local st = ble.state()
    gfx.text(14, 48, "link: " .. tostring(st.link), "small")
    local y = 74
    local max_rows = (H - 130) // LH
    if #all == 0 then gfx.text(14, y, "no readable or notifying characteristics", "small") end
    for i = 1, math.min(#all, max_rows) do
      local e = all[i]
      local text = values[e.c.uuid] or "--"
      gfx.text(14, y, string.format("%s %s", e.mode, label_for(e.c)), "small", "b")
      gfx.text(200, y, text:sub(1, 26), "small")
      y = y + LH
    end
    gfx.text(14, H - 52, "N = notify, R = polled every 2 s", "small")
    gfx.text(14, H - 34, "Back = disconnect and exit", "small")
    gfx.present()
  end

  while true do
    local now = system.millis()
    if not last_poll or now - last_poll >= POLL_MS then
      for _, c in ipairs(polled) do
        local data = ble.read(c.uuid)
        local txt = decode(c, data)
        if not data then txt = "read error" end
        if values[c.uuid] ~= txt then values[c.uuid] = txt; dirty = true end
      end
      last_poll = now
    end
    for _, n in ipairs(ble.notifs() or {}) do
      local key = string.lower(n.uuid)
      values[key] = decode({ uuid = key }, n.data)
      dirty = true
    end
    if dirty then draw(); dirty = false end
    if input.poll() == "back" then break end
    app.sleep(100)
  end
  pcall(function() ble.disconnect() end)
end

local ok, err = pcall(function()
  local dev = pick_device()
  if dev then run_sensor(dev) end
  pcall(function() ble.stop() end)
end)
if not ok then
  pcall(function() ble.stop() end)
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
