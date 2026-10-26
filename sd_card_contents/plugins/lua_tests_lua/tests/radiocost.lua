-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
local function __test()
-- Measures the WiFi driver's RAM cost and one 64 KB transfer for the wifi-tune candidate index this boot used
-- (the dev build auto-advances /.crosslua/data/wifi_tune/idx on every wifi init). Tiny on purpose.
local SERVER, BIG_SHA = "192.168.1.67", "510b126e1d4ced49107fe4ab03ee54cb1c8e4caf6064e1dd29c48d4a3e74c38b"
local f0, m0 = system.heap()
print(("RADIO before: free %d min %d"):format(f0, m0))
local ok, why = wifi.connect({ tls = false })
if not ok then print("RADIO join FAILED: " .. tostring(why)); wifi.off()
print("RADIODONE"); return end
local f1, m1 = system.heap()
print(("RADIO after: free %d min %d  cost %d"):format(f1, m1, f0 - f1))
local h = net.connect(SERVER, 9099, { timeout_ms = 3000 })
if not h then print("RADIO connect FAILED"); wifi.off()
print("RADIODONE"); return end
local skip, got, t0, hh = 6, 0, system.millis(), crypto.hash("sha256")
net.write(h, "BIG\n")
while got < 65536 and system.millis() - t0 < 15000 do
  local d = net.read(h, 1024)
  if d == nil then break end
  if #d == 0 then app.sleep(5) else
    if skip > 0 then local n = math.min(skip, #d); d = d:sub(n + 1); skip = skip - n end
    if #d > 0 then
      if got + #d > 65536 then d = d:sub(1, 65536 - got) end
      hh:update(d); got = got + #d
    end
  end
end
net.close(h)
local ms = system.millis() - t0
print(("RADIO xfer: %d bytes in %d ms = %d KB/s  hash %s  minfree %d"):format(got, ms, got * 1000 // 1024 // math.max(ms, 1),
  crypto.hex(hh:digest()) == BIG_SHA and "OK" or "BAD", system.heap()))
wifi.off()
print("RADIODONE")
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
-- this test used WiFi: leaving the app reboots the device (heap defrag), so the next test starts clean. Reopen the hub.
app.exit()
