-- BLE Remote: find a connectable Bluetooth LE device, connect, and send the commands from commands.txt.
-- Scanning needs raw mode (ble.scan is keyboard-only), so the flow is:
-- raw observe -> pick device -> stop -> gatt connect -> write. Back leaves the current screen.

local CONNECT_TIMEOUT_MS = 15000
local SCAN_REFRESH_MS = 1500
local MAX_COMMANDS = 16
local LH = 26
local BASE_UUID_TAIL = "%-0000%-1000%-8000%-00805f9b34fb$"
local PROP_WRITE, PROP_WRITE_NR = 0x08, 0x04

local function short_uuid(u)
  u = u:lower()
  local short = u:match("^0000(%x%x%x%x)" .. BASE_UUID_TAIL)
  return short or u
end

local function parse_ad(data)
  local name = nil
  local i = 1
  while i <= #data do
    local len = data:byte(i)
    if not len or len == 0 then break end
    local t = data:byte(i + 1)
    if t == 0x09 or (t == 0x08 and not name) then name = data:sub(i + 2, i + len) end
    i = i + len + 1
  end
  return name
end

local function load_commands()
  local text = fs.read("app:commands.txt")
  local cmds = {}
  if not text then return cmds end
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    local s = line:match("^%s*(.-)%s*$")
    if s ~= "" and s:sub(1, 1) ~= "#" then
      local label, uuid, hex, mode = s:match("^([^|]+)|%s*([%x%-]+)%s*|%s*([%x ]*)|?%s*(%a*)%s*$")
      local digits = hex and hex:gsub("%s", "") or ""
      if label and uuid and #digits % 2 == 0 and #digits > 0 and #digits <= 488 then
        local bytes = digits:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)
        cmds[#cmds + 1] = {
          label = label:match("^(.-)%s*$"),
          uuid = short_uuid(uuid),
          data = bytes,
          nr = mode == "nr",
          hex = digits:upper(),
        }
        if #cmds >= MAX_COMMANDS then break end
      end
    end
  end
  return cmds
end

local function draw_frame(title)
  gfx.clear()
  local w = gfx.size()
  gfx.rect(0, 0, w, 40, true)
  gfx.text(14, 10, title, "ui12", "bw")
  return w
end

-- Shows a message until any button, then returns.
local function message(title, lines)
  draw_frame(title)
  local y = 60
  for _, l in ipairs(lines) do gfx.text(14, y, l, "small"); y = y + LH end
  gfx.text(14, y + 20, "Press any button", "small")
  gfx.present()
  input.wait()
end

local function run_scan()
  local ok, err = ble.start("raw")
  if not ok then return nil, "ble.start: " .. tostring(err) end
  ble.observe(0, { active = true })
  local list, cursor, last = {}, 1, nil
  local result = nil
  while true do
    local now = system.millis()
    if not last or now - last >= SCAN_REFRESH_MS then
      local adverts = ble.adverts() or {}
      list = {}
      for _, a in ipairs(adverts) do
        if a.connectable then
          list[#list + 1] = { addr = a.addr, addr_type = a.addr_type, rssi = a.rssi, name = parse_ad(a.data or "") }
        end
      end
      table.sort(list, function(x, y) return x.rssi > y.rssi end)
      if cursor > #list then cursor = math.max(1, #list) end

      local w, h = gfx.size()
      draw_frame("BLE Remote: pick a device")
      if #list == 0 then gfx.text(14, 60, "Scanning... nothing connectable yet", "small") end
      local y = 60
      for i = 1, math.min(#list, (h - 130) // LH) do
        local d = list[i]
        local line = string.format("%4d  %s  %s", d.rssi, d.addr, (d.name or "(no name)"):sub(1, 16))
        if i == cursor then
          gfx.rect(8, y - 2, w - 16, LH, true)
          gfx.text(14, y, line, "small", "w")
        else
          gfx.text(14, y, line, "small")
        end
        y = y + LH
      end
      gfx.text(14, h - 56, "Up/Down select, Confirm connect", "small")
      gfx.text(14, h - 34, "Back = quit", "small")
      gfx.present()
      last = now
    end
    local e = input.wait(200)
    if e == "up" and cursor > 1 then cursor = cursor - 1; last = nil
    elseif e == "down" and cursor < #list then cursor = cursor + 1; last = nil
    elseif e == "confirm" and list[cursor] then result = list[cursor]; break
    elseif e == "back" then break end
  end
  ble.observe_stop()
  ble.stop()
  return result
end

-- Returns true, or false and a reason.
local function run_connect(dev)
  local ok, err = ble.start("gatt")
  if not ok then return false, "ble.start: " .. tostring(err) end
  ok, err = ble.connect(dev.addr, dev.addr_type)
  if not ok then return false, tostring(err) end
  local started = system.millis()
  draw_frame("Connecting")
  gfx.text(14, 60, dev.addr, "small")
  gfx.text(14, 60 + LH, dev.name or "(no name)", "small")
  gfx.text(14, 60 + 2 * LH, "Back = cancel", "small")
  gfx.present()
  while true do
    local st = ble.state()
    if st.link == "connected" then return true end
    if st.link == "failed" then return false, st.reason or "connection failed" end
    if system.millis() - started > CONNECT_TIMEOUT_MS then
      ble.disconnect()
      return false, "timed out"
    end
    if input.wait(300) == "back" then
      ble.disconnect()
      return false, "cancelled"
    end
  end
end

-- Returns a map from short UUID to its properties, or nil and a reason.
local function discover()
  local chars, err
  for _ = 1, 20 do
    chars, err = ble.services()
    if not chars then return nil, tostring(err) end
    if #chars > 0 then break end
    app.sleep(300)
  end
  local map = {}
  for _, c in ipairs(chars or {}) do map[short_uuid(c.uuid)] = c.props end
  return map
end

local function send(cmd, map)
  if ble.state().link ~= "connected" then return false, "link lost" end
  local props = map[cmd.uuid]
  if not props then return false, "characteristic not found on this device" end
  local nr = false
  if cmd.nr and (props & PROP_WRITE_NR) ~= 0 then nr = true
  elseif (props & PROP_WRITE) == 0 then
    return false, (props & PROP_WRITE_NR) ~= 0 and "device wants write-no-response: use nr" or "not writable"
  end
  local ok, err = ble.write(cmd.uuid, cmd.data, { no_response = nr })
  if not ok then return false, tostring(err) end
  return true
end

local function draw_remote(cmds, map, dev, cursor, status)
  local w, h = gfx.size()
  draw_frame("Remote: " .. (dev.name or dev.addr):sub(1, 24))
  local y = 56
  for i, cmd in ipairs(cmds) do
    local text = cmd.label .. (map[cmd.uuid] == nil and "  (missing)" or "")
    if i == cursor then
      gfx.rect(8, y - 2, w - 16, LH, true)
      gfx.text(14, y, text:sub(1, 40), "small", "w")
    else
      gfx.text(14, y, text:sub(1, 40), "small")
    end
    y = y + LH
  end
  gfx.text(14, h - 74, status:sub(1, 52), "small")
  gfx.text(14, h - 52, "Confirm sends the command", "small")
  gfx.text(14, h - 30, "Back = disconnect", "small")
  gfx.present()
end

-- Returns when Back is pressed. Redraws only on a button press, never on a timeout (e-ink).
local function run_remote(cmds, map, dev)
  local cursor, status = 1, "ready"
  draw_remote(cmds, map, dev, cursor, status)
  while true do
    local e = input.wait(1000)
    if e == "up" and cursor > 1 then cursor = cursor - 1
    elseif e == "down" and cursor < #cmds then cursor = cursor + 1
    elseif e == "confirm" then
      local ok, err = send(cmds[cursor], map)
      status = ok and ("sent: " .. cmds[cursor].label) or ("failed: " .. tostring(err))
    elseif e == "back" then return
    else goto continue end
    draw_remote(cmds, map, dev, cursor, status)
    ::continue::
  end
end

local ok, err = pcall(function()
  local cmds = load_commands()
  if #cmds == 0 then
    message("BLE Remote", {
      "No commands yet.",
      "Edit commands.txt in this app's folder:",
      "label | characteristic UUID | hex | mode",
    })
    return
  end

  while true do
    local dev, serr = run_scan()
    if serr then error(serr) end
    if not dev then break end

    local linked, why = run_connect(dev)
    if linked then
      local map, derr = discover()
      if map then
        run_remote(cmds, map, dev)
      else
        message("Discovery failed", { tostring(derr) })
      end
    else
      message("Could not connect", { dev.addr, tostring(why) })
    end
    ble.disconnect()
    ble.stop()
  end
end)

if not ok then
  pcall(function() ble.disconnect() end)
  pcall(function() ble.observe_stop() end)
  pcall(function() ble.stop() end)
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
pcall(function() ble.stop() end)
app.exit()
