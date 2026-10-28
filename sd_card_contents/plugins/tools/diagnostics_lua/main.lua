-- Diagnostics (no radio): device heap, this app's Lua memory, battery, USB, MAC, last wake reason,
-- and the board capabilities. Values come straight from system.* / device.caps(); anything the firmware
-- does not expose yet (disk-free, uptime, panic info) is shown as "n/a" rather than guessed.
-- Confirm refreshes the readings.

local function try(f, ...)
  local ok, a, b, c = pcall(f, ...)
  if not ok then return nil end
  return a, b, c
end

local function readings()
  local lines = {}
  local free, min_free, largest = try(system.heap)
  lines[#lines + 1] = string.format("heap free %s  min %s  largest block %s",
    tostring(free or "n/a"), tostring(min_free or "n/a"), tostring(largest or "n/a"))
  local used, peak, budget = try(system.lua_mem)
  lines[#lines + 1] = string.format("lua used %s  peak %s  budget %s",
    tostring(used or "n/a"), tostring(peak or "n/a"), tostring(budget or "n/a"))
  lines[#lines + 1] = "battery " .. tostring(try(system.battery) or "n/a") .. "%"
  local usb = try(system.usb)
  lines[#lines + 1] = "usb cable " .. (usb == nil and "n/a" or (usb and "connected" or "not connected"))
  lines[#lines + 1] = "wifi mac " .. tostring(try(system.mac) or "n/a")
  lines[#lines + 1] = "last wake " .. tostring(try(system.last_wake) or "n/a")
  local caps = try(device.caps)
  if caps then
    lines[#lines + 1] = string.format("board %dx%d  frontlight %s  imu %s  rtc %s",
      caps.width or 0, caps.height or 0, tostring(caps.frontlight), tostring(caps.imu), tostring(caps.rtc))
  end
  lines[#lines + 1] = "uptime / disk-free / panic info: not exposed yet"
  return lines
end

local function draw(lines)
  gfx.clear()
  local W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Diagnostics", "ui12", "bw")
  local y = 56
  for _, l in ipairs(lines) do gfx.text(14, y, l, "small"); y = y + 30 end
  gfx.text(14, H - 34, "Confirm = refresh, Back = exit", "small")
  gfx.present()
end

local ok, err = pcall(function()
  draw(readings())
  while true do
    local e = input.wait()
    if e == "back" then break end
    if e == "confirm" then draw(readings()) end
  end
end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
