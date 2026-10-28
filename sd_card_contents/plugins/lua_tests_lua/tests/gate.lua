-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
local function __test()
-- Pads the Lua heap until free RAM is ~90 KB (between the plain gate 80K and the TLS gate 96K), then checks both gates
-- and that plain TCP works and https fails cleanly. Needs a TCP echo test server on port 9099 (host IP in data:server.txt).
local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  print((cond and "PASS " or "FAIL ") .. name .. (extra and (" " .. tostring(extra)) or ""))
end
local ballast = {}
repeat ballast[#ballast + 1] = ("b"):rep(1000) .. #ballast until (system.heap()) < 90 * 1024
collectgarbage()
local free0 = system.heap()
print(("free heap before WiFi: %d KB"):format(free0 // 1024))
local ok, why = wifi.connect()
check("default wifi.connect() is refused (TLS needs 96K)", ok == false and why:find("WiFi %+ TLS") and why:find("need 96K"), why)
ok, why = wifi.connect({ tls = false })
check("wifi.connect{tls=false} joins", ok == true, tostring(why))
if not ok then print("ABORT"); return end
local free1, min1 = system.heap()
print(("after join: free %d KB, min-free %d KB, lua_mem %d"):format(free1 // 1024, min1 // 1024, system.lua_mem()))
local SERVER = assert((fs.read("data:server.txt") or ""):match("^%s*([%d%.]+)%s*$"), "put the test host's IP address in data:server.txt (File Transfer: /.crosslua/data/lua_tests_lua/server.txt)")
local h, err = net.connect(SERVER, 9099, { timeout_ms = 3000 })
check("plain TCP connect", h ~= nil, err)
if h then
  local got = ""
  local t0 = system.millis()
  while #got < 6 and system.millis() - t0 < 2000 do local d = net.read(h, 64); if d and #d > 0 then got = got .. d else app.sleep(10) end end
  check("greeting", got == "HELLO\n", ("%q"):format(got))
  net.write(h, "ping\n"); app.sleep(200)
  check("echo", net.read(h, 64) == "PING\n")
  net.close(h)
end
local body, herr = http.get("https://example.com/")
check("https fails cleanly (not a crash) at this heap", body == nil and type(herr) == "string", herr)
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
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
