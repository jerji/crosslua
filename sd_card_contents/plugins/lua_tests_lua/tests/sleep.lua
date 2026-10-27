-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
-- system.sleep: first run reports the wake cause (power-on) and sleeps 12 s; the timer wakes the device and it reboots.
-- Run the test a SECOND time: it must then report "timer" and pass. The power button also wakes the device.
local function __test()
print("== sleep")
local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  print((cond and "PASS " or "FAIL ") .. name .. (extra and (" " .. tostring(extra)) or ""))
end
local wake = system.last_wake()
print("INFO last wake: " .. wake)
check("wake cause is a known string", wake == "timer" or wake == "button" or wake == "power-on" or wake == "other", wake)
if wake == "timer" then
  check("woke by the timer", true)
  print("ALL PASSED")
  gfx.clear(); gfx.text(16, 10, "sleep test", "ui12", "b"); gfx.text(16, 70, "ALL PASSED (timer wake)", "ui12"); gfx.present("full")
  app.sleep(1500)
  app.exit()
  return
end
-- first run: validate, then sleep
local _, e1 = system.sleep(0)
check("zero seconds refused", e1 ~= nil and e1:find("1..604800") ~= nil, tostring(e1))
local _, e2 = system.sleep("60")
check("non-number refused", e2 ~= nil, tostring(e2))
print("Ready: sleeping 12 s (the timer wakes the device)")
gfx.clear()
gfx.text(16, 10, "sleep test", "ui12", "b")
gfx.text(16, 70, "deep sleep in 2 s", "ui12")
gfx.present("full")
app.sleep(2000)
print("PASS sleeping now")
system.sleep(12)
-- unreachable on the device; the host aborts here
print("FAIL sleep did not enter deep sleep")
app.exit()
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
