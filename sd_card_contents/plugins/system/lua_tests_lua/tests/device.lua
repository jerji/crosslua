-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
local function __test()
-- Interactive check of the hardware-dependent APIs. Safe on every board: absent hardware reports itself, it never crashes.
local W, H = gfx.size()
local caps = device.caps()
local log = {}
local function note(s) log[#log + 1] = s; if #log > 9 then table.remove(log, 1) end; print(s) end

local names = { "touch", "haptic", "frontlight", "warmlight", "color", "audio", "ble_keyboard", "usb_msc",
                "imu", "gyro", "rtc", "temp_humidity", "buzzer", "mic", "led", "tls13" }
local capline = {}
for _, k in ipairs(names) do capline[#capline + 1] = k .. "=" .. (caps[k] and "yes" or "no") end
print("caps: " .. table.concat(capline, " ") .. " " .. caps.width .. "x" .. caps.height)

local function draw()
  gfx.clear()
  gfx.text(16, 8, "Device test", "ui12", "b"); gfx.line(0, 40, W - 1, 40)
  local y = 48
  for i = 1, #capline, 2 do
    gfx.text(12, y, capline[i] .. (capline[i + 1] and ("   " .. capline[i + 1]) or ""), "small"); y = y + 22
  end
  gfx.text(12, y, "usb cable: " .. tostring(system.usb()) .. "  size " .. caps.width .. "x" .. caps.height, "small"); y = y + 30
  gfx.text(12, y, "Up haptic  Down text  Confirm usb", "small"); y = y + 22
  gfx.text(12, y, "Left motion+env  Right tone+LEDs  Back quit", "small"); y = y + 24
  if caps.touch then gfx.text(12, y, "touch the screen: events below", "small"); y = y + 24 end
  gfx.line(0, y, W - 1, y); y = y + 6
  for _, l in ipairs(log) do gfx.text(12, y, l, "small"); y = y + 22 end
  gfx.present("fast")
end

draw()
while true do
  local e = input.wait()
  if e == "back" then break
  elseif e == "up" then
    local ok, why = device.haptic(80)
    note("haptic(80) -> " .. tostring(ok) .. (why and (" (" .. why .. ")") or ""))
  elseif e == "confirm" then
    note("usb cable: " .. tostring(system.usb()))
  elseif e == "left" then
    local m, err = device.motion()
    note(m and string.format("motion a=%.2f %.2f %.2f g=%.0f %.0f %.0f", m.ax, m.ay, m.az, m.gx, m.gy, m.gz) or ("motion: " .. tostring(err)))
    local t, h = device.environment()
    note(t and string.format("env %.1f C  %.0f %%RH", t, h) or ("env: " .. tostring(h)))
  elseif e == "right" then
    local ok, why = device.tone(880, 150)
    note("tone -> " .. tostring(ok) .. (why and (" (" .. why .. ")") or ""))
    local n = led.count()
    if n > 0 then
      for i = 1, n do led.set(i, 0, 80, 0) end
      app.sleep(300); led.off()
      note("led: flashed " .. n)
    else
      note("led: " .. select(2, led.set(1, 0, 0, 0)))
    end
  elseif e == "down" then
    local s, err = input.text("Type something", "hello", 40)
    note("text -> " .. (s and ('"' .. s .. '"') or ("nil, " .. tostring(err))))
    local p, perr = input.text("A password (masked)", "", 20, "password")
    note("password -> " .. (p and (#p .. " chars") or ("nil, " .. tostring(perr))))
  elseif e == "tap" or e == "press" or e == "long" or e == "release" then
    local x, y = input.pos()
    note(e .. " at " .. tostring(x) .. "," .. tostring(y))
  else
    note("event " .. tostring(e))
  end
  draw()
end
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
app.restart("main.lua")
