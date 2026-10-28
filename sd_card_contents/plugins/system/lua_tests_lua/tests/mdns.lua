-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
local function __test()
print("== wifi")
local ok, why = wifi.connect()
print((ok and "PASS " or "FAIL ") .. "wifi.connect " .. tostring(why or ""))
if not ok then return end
-- net.mdns_query on-device test. Queries common service types; the test passes as long
-- as the function returns a valid table (it may be empty if nothing on the LAN advertises
-- that service type, which is fine).
local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  print((cond and "PASS " or "FAIL ") .. name .. (extra and (" " .. tostring(extra)) or ""))
end
local function now() return system.millis() end
local function heap() collectgarbage(); collectgarbage(); local f, m, b = system.heap(); return f, m, b end

print("== mdns_query basics")
-- Query http services over TCP
local t0 = now()
local r, err = net.mdns_query("http", "tcp")
local elapsed = now() - t0
check("mdns_query returns a table", type(r) == "table", type(r))
check("err is nil on success", err == nil, tostring(err))
check("result has numeric keys", type(r[1]) == "table" or #r == 0,
      ("#r=%d type(r[1])=%s"):format(#r, type(r[1])))
print(("  mDNS _http._tcp returned %d results in %d ms"):format(#r, elapsed))

-- Each result should have hostname, ip, port fields (if any results)
if #r > 0 then
  local item = r[1]
  check("result has hostname field", type(item.hostname) == "string", item.hostname)
  check("result has ip field", type(item.ip) == "string", item.ip)
  check("result has port field", type(item.port) == "number", tostring(item.port))
  check("result has instance_name field", type(item.instance_name) == "string", item.instance_name)
  for i = 1, math.min(3, #r) do
    print(("  [%d] %s (%s:%d) '%s'"):format(i, r[i].hostname, r[i].ip, r[i].port, r[i].instance_name))
  end
end

print("== different service type")
local t1 = now()
local r2 = net.mdns_query("ssh", "tcp")
print(("  mDNS _ssh._tcp returned %d results in %d ms"):format(#r2, now() - t1))
check("ssh query returns a table", type(r2) == "table", type(r2))

print("== udp proto")
local r3 = net.mdns_query("http", "udp")
check("udp proto returns a table", type(r3) == "table", type(r3))

print("== known service on this LAN (home assistant)")
local t2 = now()
local r6 = net.mdns_query("homeassistant", "tcp")
local el2 = now() - t2
print(("  mDNS _homeassistant._tcp returned %d results in %d ms"):format(#r6, el2))
if #r6 > 0 then
  local ha = r6[1]
  print(("  [1] %s (%s:%d)"):format(ha.hostname or "?", ha.ip or "?", ha.port or 0))
  check("homeassistant result has an ip", type(ha.ip) == "string" and #ha.ip > 6, tostring(ha.ip))
else
  print("INFO no _homeassistant._tcp on this LAN (query took " .. el2 .. " ms)")
end

print("== service auto-prefix (no leading _)")
local r4 = net.mdns_query("_http", "tcp")
local r5 = net.mdns_query("http", "tcp")
-- Both should give the same result; just check they don't crash
check("with- and without-underscore both work", type(r4) == "table" and type(r5) == "table")

print("== error cases (these must produce nil, err)")
local e1, e2 = net.mdns_query("", "tcp")
check("empty service returns nil, err", e1 == nil and type(e2) == "string", tostring(e2))
local e3, e4 = net.mdns_query("http", "")
check("empty proto returns nil, err", e3 == nil and type(e4) == "string", tostring(e4))
local e5, e6 = net.mdns_query("http", "bogus")
check("invalid proto returns nil, err", e5 == nil and type(e6) == "string", tostring(e6))

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "mDNS test", "ui12", "b")
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
-- this test used WiFi: leaving the app reboots the device (heap defrag), so the next test starts clean. Reopen the hub.
app.exit()