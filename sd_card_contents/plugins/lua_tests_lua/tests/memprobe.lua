-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
local function __test()
-- Heap cost of OPEN but idle sockets, and of one active conversation. DEVELOPMENT BUILD ONLY (system.dev_floor).
local SERVER = "192.168.1.67"
if not wifi.connect() then print("no wifi"); return end
system.dev_floor(12)
local function free() collectgarbage(); local f, m = system.heap(); return f, m end
local f0, m0 = free()
print(("WiFi up, no sockets: free %d  min-free %d"):format(f0, m0))
local hs, prev = {}, f0
for i = 1, 4 do
  hs[i] = net.connect(SERVER, 9099, { timeout_ms = 3000 })
  app.sleep(300)                                      -- let the server's greeting arrive and settle
  local f, m = free()
  print(("%d idle socket(s) open (greeting unread, %d queued): free %d (%+d for this one)  min-free %d"):format(
    i, net.available(hs[i] or 1), f, f - prev, m))
  prev = f
end
for i = 1, 4 do pcall(net.close, i) end
app.sleep(500)
local f1, m1 = free()
print(("all closed: free %d (%+d vs before)  min-free %d"):format(f1, f1 - f0, m1))
-- one active echo conversation with a small payload
local h = net.connect(SERVER, 9099, { timeout_ms = 3000 })
net.write(h, "ping\n"); app.sleep(300)
local f2, m2 = free()
print(("1 socket after a ping/echo: free %d (%+d vs before)  min-free %d"):format(f2, f2 - f0, m2))
net.close(h)
print("DONE")
wifi.off()
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
-- this test used WiFi: leaving the app reboots the device (heap defrag), so the next test starts clean. Reopen the hub.
app.exit()
