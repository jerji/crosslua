-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
-- Back-cancel test for the blocking net.connect: connects to a blackhole IP (SYN never answered), and the OPERATOR
-- presses Back on the device during the 15 s wait.
-- Expected: nil, "cancelled"  (without the interrupt the call would end with "timed out" after the full 15 s).
local function __test()
print("== wifi")
local ok, why = wifi.connect()
print((ok and "PASS " or "FAIL ") .. "wifi.connect " .. tostring(why or ""))
if not ok then return end
local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  print((cond and "PASS " or "FAIL ") .. name .. (extra and (" " .. tostring(extra)) or ""))
end

-- 10.255.255.1 is a TEST-NET blackhole: packets leave the LAN and nothing ever answers the SYN.
print("== connect (operator: press Back now)")
local t0 = system.millis()
local h, err = net.connect("10.255.255.1", 80, { timeout_ms = 15000 })
local dt = system.millis() - t0
print(("  connect returned after %d ms"):format(dt))
check("connect returned nil", h == nil, tostring(h))
check("error is 'cancelled' (not the timeout)", err == "cancelled", tostring(err))
check("cancel came before the 15 s timeout", dt < 14000, dt)

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "connect cancel test", "ui12", "b")
gfx.text(16, 60, fails == 0 and "ALL PASSED" or (fails .. " FAILED"), "ui12")
gfx.text(16, 100, "see the serial log for details", "small")
gfx.present("full")
wifi.off()
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
-- this test used WiFi: leaving the app reboots the device (heap defrag). Reopen the hub.
app.exit()