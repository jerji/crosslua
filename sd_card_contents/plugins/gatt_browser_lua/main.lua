-- GATT browser (bluetooth). Discovery runs as a raw observer (ble.observe with active=true, so names
-- arrive); the stack is then restarted in gatt mode to connect (ble.scan/devices refuse in gatt mode).
-- You pick a device, browse its characteristics, read values, write a fixed test byte, and watch
-- notifications. Only ever connect to devices you own or are allowed to test: a GATT write changes
-- the device's state.

local SCAN_MS = 6000
local CONNECT_MS = 15000
local SERVICES_MS = 6000
local LH = 24
local SCREEN_W, SCREEN_H = gfx.size()

local P_READ, P_WRITE_NR, P_WRITE, P_NOTIFY, P_INDICATE = 0x02, 0x04, 0x08, 0x10, 0x20

local KNOWN = {
  ["1800"] = "Generic Access", ["1801"] = "Generic Attribute", ["180a"] = "Device Info",
  ["180d"] = "Heart Rate", ["180f"] = "Battery", ["2a00"] = "Device Name", ["2a01"] = "Appearance",
  ["2a19"] = "Battery Level", ["2a24"] = "Model", ["2a25"] = "Serial", ["2a26"] = "Firmware Rev",
  ["2a27"] = "Hardware Rev", ["2a28"] = "Software Rev", ["2a29"] = "Manufacturer", ["2a37"] = "Heart Rate",
}

local gatt_up = false
local devs_cache = nil

-- ---------- drawing ----------

local function header(title)
  gfx.rect(0, 0, SCREEN_W, 40, true)
  gfx.text(14, 10, title:sub(1, 30), "ui12", "bw")
end

local function footer(text)
  gfx.text(14, SCREEN_H - 30, text, "small")
end

local function rows_fit()
  return math.max(1, (SCREEN_H - 110) // LH)
end

local function wrap(text, width)
  local lines, line = {}, ""
  for word in tostring(text):gmatch("%S+") do
    if #line > 0 and #line + #word + 1 > width then
      lines[#lines + 1] = line
      line = word
    else
      line = (#line > 0) and (line .. " " .. word) or word
    end
  end
  if #line > 0 then lines[#lines + 1] = line end
  return lines
end

-- Scrollable read-only text. Back or confirm returns.
local function view(title, lines, hint)
  local top, rows = 1, rows_fit()
  while true do
    gfx.clear()
    header(title)
    for i = top, math.min(#lines, top + rows - 1) do
      gfx.text(14, 52 + (i - top) * LH, lines[i]:sub(1, 46), "small")
    end
    footer(hint or "up/down scroll   back = return")
    gfx.present()
    local e = input.wait()
    if e == "back" or e == "confirm" then return end
    if e == "down" and top + rows <= #lines then top = top + 1 end
    if e == "up" and top > 1 then top = top - 1 end
  end
end

local function message(title, text)
  view(title, wrap(text, 44), "back = return")
end

-- Selectable list. Returns "select", index | "right", index | "back", nil.
local function menu(title, items, hint, status)
  local cur, top, rows = 1, 1, rows_fit()
  while true do
    gfx.clear()
    header(title)
    if #items == 0 then gfx.text(14, 60, "nothing here", "ui12") end
    for i = top, math.min(#items, top + rows - 1) do
      local y = 52 + (i - top) * LH
      if i == cur then
        gfx.rect(8, y - 2, SCREEN_W - 16, LH, true)
        gfx.text(14, y, items[i]:sub(1, 44), "ui12", "w")
      else
        gfx.text(14, y, items[i]:sub(1, 44), "ui12")
      end
    end
    if status then gfx.text(14, SCREEN_H - 56, status, "small") end
    footer(hint)
    gfx.present()
    local e = input.wait()
    if e == "up" and cur > 1 then cur = cur - 1
    elseif e == "down" and cur < #items then cur = cur + 1
    elseif e == "confirm" and #items > 0 then return "select", cur
    elseif e == "right" then return "right", cur
    elseif e == "back" then return "back", nil end
    if cur < top then top = cur elseif cur >= top + rows then top = cur - rows + 1 end
  end
end

local function hexlines(s)
  local lines = {}
  if #s == 0 then return { "(empty value)" } end
  for i = 1, math.min(#s, 128), 8 do
    local chunk = s:sub(i, i + 7)
    local hx = (chunk:gsub(".", function(c) return string.format("%02X ", c:byte()) end))
    local asc = (chunk:gsub("[^%g ]", "."))
    lines[#lines + 1] = string.format("%03d %-24s %s", i - 1, hx, asc)
  end
  if #s > 128 then lines[#lines + 1] = string.format("... %d more bytes", #s - 128) end
  return lines
end

local function value_lines(s)
  local lines = hexlines(s)
  if #s == 1 then lines[#lines + 1] = "as uint8: " .. s:byte(1) end
  if #s == 2 then lines[#lines + 1] = "as uint16 LE: " .. (s:byte(1) | (s:byte(2) << 8)) end
  return lines
end

-- ---------- helpers ----------

local function short_uuid(u)
  if #u == 36 then return u:sub(1, 8) .. "..." end
  return u
end

local function char_name(c)
  return KNOWN[c.uuid:lower()] or ""
end

local function props_text(p)
  local t = ""
  if (p & P_READ) ~= 0 then t = t .. "R" end
  if (p & (P_WRITE | P_WRITE_NR)) ~= 0 then t = t .. "W" end
  if (p & P_NOTIFY) ~= 0 then t = t .. "N" end
  if (p & P_INDICATE) ~= 0 then t = t .. "I" end
  return t
end

-- AD structure walk: complete/short local name (0x09/0x08).
local function parse_name(data)
  local i = 1
  local short = nil
  while i <= #data do
    local len = data:byte(i)
    if not len or len == 0 then break end
    local t = data:byte(i + 1)
    local v = data:sub(i + 2, i + len)
    if t == 0x09 then return v end
    if t == 0x08 then short = v end
    i = i + len + 1
  end
  return short
end

-- NimBLE addr_type -> ble.connect addr_type (0 public, 1 random). Resolved private addresses (2, 3) are
-- mapped to their base type; the peer may then refuse the RPA, which shows up as a connect failure.
local function map_addr_type(t)
  if t == 1 or t == 3 then return 1 end
  return 0
end

-- ---------- radio ----------

-- Raw observer scan. Returns the connectable devices, strongest first. Back cancels the scan.
local function scan()
  ble.stop()
  gatt_up = false
  local ok, err = ble.start("raw")
  if not ok then return nil, "ble.start raw: " .. tostring(err) end
  local ok2, err2 = ble.observe(SCAN_MS, { active = true })
  if not ok2 then ble.stop(); return nil, "observe: " .. tostring(err2) end
  gfx.clear()
  header("Scanning BLE")
  gfx.text(14, 60, "listening for " .. (SCAN_MS // 1000) .. " s ...", "ui12")
  footer("back = cancel")
  gfx.present()
  local t0 = system.millis()
  local cancelled = false
  while system.millis() - t0 < SCAN_MS + 400 do
    if input.poll() == "back" then cancelled = true; break end
    app.sleep(200)
  end
  ble.observe_stop()
  local adverts = ble.adverts() or {}
  ble.stop()
  if cancelled then return {} end
  local devs = {}
  for _, a in ipairs(adverts) do
    if a.connectable then
      devs[#devs + 1] = {
        addr = a.addr, addr_type = map_addr_type(a.addr_type), rssi = a.rssi,
        name = parse_name(a.data or ""),
      }
    end
  end
  table.sort(devs, function(x, y) return x.rssi > y.rssi end)
  return devs
end

-- Brings the stack up in gatt mode (one radio: the raw scan must be stopped first, scan() does that).
local function ensure_gatt()
  if gatt_up then return true end
  local ok, err = ble.start("gatt")
  if not ok then
    ble.stop()
    app.sleep(400)
    ok, err = ble.start("gatt")
  end
  if not ok then return false, err end
  gatt_up = true
  return true
end

-- Connects and waits for the link. Back cancels. Returns true | false, reason.
local function connect(dev)
  local ok, err = ble.connect(dev.addr, dev.addr_type)
  if not ok then return false, err end
  gfx.clear()
  header("Connecting")
  gfx.text(14, 60, dev.addr, "ui12")
  gfx.text(14, 84, dev.name or "(no name)", "ui12")
  footer("back = cancel")
  gfx.present()
  local t0 = system.millis()
  while true do
    local st = ble.state()
    if st.link == "connected" then return true end
    if st.link == "failed" then return false, st.reason or "connect failed" end
    if system.millis() - t0 > CONNECT_MS then
      ble.disconnect()
      return false, "timed out after " .. (CONNECT_MS // 1000) .. " s"
    end
    if input.poll() == "back" then
      ble.disconnect()
      return false, "cancelled"
    end
    app.sleep(150)
  end
end

-- ble.services() triggers discovery and may return an empty list for a moment: poll until it fills.
local function load_services()
  local t0 = system.millis()
  while true do
    local list, err = ble.services()
    if not list then return nil, err end
    if #list > 0 then return list end
    if system.millis() - t0 > SERVICES_MS then return list end
    app.sleep(300)
  end
end

local function link_up()
  return ble.state().link == "connected"
end

-- ---------- browse ----------

local function live(subs)
  local log = {}
  local t0 = system.millis()
  local dirty = true
  while true do
    if dirty then
      gfx.clear()
      header("Notifications")
      if #log == 0 then gfx.text(14, 60, "waiting for notifications ...", "ui12") end
      for i = 1, math.min(#log, rows_fit()) do
        gfx.text(14, 52 + (i - 1) * LH, log[i]:sub(1, 46), "small")
      end
      footer("back = return")
      gfx.present()
      dirty = false
    end
    local e = input.poll()
    if e == "back" then return end
    local batch = ble.notifs() or {}
    for _, n in ipairs(batch) do
      local stamp = string.format("%5.1fs", (system.millis() - t0) / 1000)
      local hx = (n.data:sub(1, 8):gsub(".", function(c) return string.format("%02X ", c:byte()) end))
      table.insert(log, 1, string.format("%s %s %s", stamp, short_uuid(n.uuid), hx))
      if #log > 20 then table.remove(log) end
      dirty = true
    end
    if not link_up() then return end   -- browse() reports the lost link
    app.sleep(200)
  end
end

local function act_on(c, subs)
  local acts, kinds = {}, {}
  local function add(label, kind) acts[#acts + 1] = label; kinds[#kinds + 1] = kind end
  if (c.props & P_READ) ~= 0 then add("read", "read") end
  if (c.props & (P_WRITE | P_WRITE_NR)) ~= 0 then
    add("write 00", "w00")
    add("write 01", "w01")
    add("write FF", "wFF")
  end
  if (c.props & (P_NOTIFY | P_INDICATE)) ~= 0 then
    add(subs[c.uuid] and "notify off" or "notify on", "notify")
  end
  add("back", "back")
  local title = (char_name(c) ~= "" and char_name(c) or short_uuid(c.uuid))
  while true do
    local kind, idx = menu(title, acts, "confirm = run   back = return")
    if kind ~= "select" or kinds[idx] == "back" then return end
    local what = kinds[idx]
    if what == "read" then
      local v, err = ble.read(c.uuid)
      if v == nil then
        message("Read failed", tostring(err))
      else
        view("Value " .. short_uuid(c.uuid), value_lines(v))
      end
    elseif what == "notify" then
      local want = not subs[c.uuid]
      local ok, err = ble.notify(c.uuid, want)
      if ok then subs[c.uuid] = want or nil
      else message("Notify failed", tostring(err)) end
    else
      local byte = (what == "w00" and "\0") or (what == "w01" and "\1") or "\255"
      local nr = (c.props & P_WRITE) == 0
      local ok, err = ble.write(c.uuid, byte, { no_response = nr })
      if ok then message("Written", string.format("Wrote 1 byte (%s) to %s.", what:sub(2), short_uuid(c.uuid)))
      else message("Write failed", tostring(err)) end
    end
    if not link_up() then
      message("Link lost", "The device disconnected.")
      return "lost"
    end
  end
end

-- Returns when the user backs out or the link drops.
local function browse(dev)
  local ok, why = connect(dev)
  if not ok then message("Connect failed", why); return end
  local list, err = load_services()
  if not list then message("Services failed", tostring(err)); return end
  local subs = {}
  while true do
    if not link_up() then message("Link lost", "The device disconnected."); return end
    local labels = {}
    for i, c in ipairs(list) do
      local mark = subs[c.uuid] and "*" or " "
      local nm = char_name(c)
      labels[i] = string.format("%s%-8s %-14s %s", mark, short_uuid(c.uuid), nm:sub(1, 14), props_text(c.props))
    end
    local status = #list == 0 and "no services found" or nil
    local kind, idx = menu(dev.name or dev.addr, labels, "confirm = actions  right = live  back = disconnect", status)
    if kind == "back" then return end
    if kind == "right" then
      live(subs)
    elseif kind == "select" and list[idx] then
      if act_on(list[idx], subs) == "lost" then return end
    end
  end
end

-- ---------- main ----------

local function labels_for(devs)
  local out = {}
  for i, d in ipairs(devs) do
    out[i] = string.format("%4d  %s  %s", d.rssi, d.addr, (d.name or "(no name)"):sub(1, 14))
  end
  return out
end

local function main()
  while true do
    if not devs_cache then
      local devs, err = scan()
      if not devs then message("Scan failed", tostring(err)); return end
      devs_cache = devs
    end
    local labels = labels_for(devs_cache)
    local kind, idx = menu("GATT devices (" .. #devs_cache .. ")", labels,
      "confirm = connect  right = rescan  back = quit")
    if kind == "back" then return end
    if kind == "right" then
      devs_cache = nil
    elseif kind == "select" then
      local ok, err = ensure_gatt()
      if not ok then
        message("Bluetooth", "Could not start gatt mode: " .. tostring(err))
      else
        browse(devs_cache[idx])
      end
      -- Whatever happened, drop the link; the stack stays up for the next connect.
      ble.disconnect()
    end
  end
end

local ok, err = pcall(main)
pcall(function() ble.disconnect() end)
pcall(function() ble.stop() end)
if not ok then
  gfx.clear()
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b")
  gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
