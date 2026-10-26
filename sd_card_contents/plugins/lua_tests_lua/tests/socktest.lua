-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
local function __test()
print("== wifi")
local ok, why = wifi.connect()
print((ok and "PASS " or "FAIL ") .. "wifi.connect " .. tostring(why or ""))
if not ok then return end
src = nil
-- net.* on-device test (loaded by main.lua after WiFi is up). Needs /root/x4/echo_server.py running on SERVER:9099.
local SERVER, PORT = "192.168.1.67", 9099
local BIG_SHA = "510b126e1d4ced49107fe4ab03ee54cb1c8e4caf6064e1dd29c48d4a3e74c38b"
local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  print((cond and "PASS " or "FAIL ") .. name .. (extra and (" " .. tostring(extra)) or ""))
end
local function heap() collectgarbage(); collectgarbage(); local f, m, b = system.heap(); return f, m, b end
local function now() return system.millis() end
local function readn(h, n, ms)
  local t0, parts, got = now(), {}, 0
  while got < n and now() - t0 < ms do
    local d, err = net.read(h, math.min(1024, n - got))
    if d == nil then return table.concat(parts), err end
    if #d == 0 then app.sleep(15) else parts[#parts + 1] = d; got = got + #d end
  end
  return table.concat(parts), nil
end

local info = net.info()
check("net.info", info and info.ip and info.gateway, info and (info.ip .. " gw " .. info.gateway .. " dns " .. info.dns))
local f0, m0 = heap()
print(("RAM baseline with WiFi up: free %d, min-free so far %d"):format(f0, m0))

print("== dns")
local t = now()
local ip, e1 = net.resolve("example.com")
check("resolve example.com", ip and ip:match("^%d+%.%d+%.%d+%.%d+$"), tostring(ip or e1) .. (" (%d ms)"):format(now() - t))
local nx, e2 = net.resolve("nonexistent.invalid")
check("resolve failure is nil, err", nx == nil and e2 ~= nil, e2)
check("literal passthrough", net.resolve(SERVER) == SERVER)

print("== tcp basics")
t = now()
local h, err = net.connect(SERVER, PORT, { timeout_ms = 3000 })
check("connect to the test server", h == 1, ("handle %s %s (%d ms)"):format(tostring(h), tostring(err), now() - t))
if not h then print("ABORT: server unreachable"); return end
local hello = readn(h, 6, 2000)
check("server greeting", hello == "HELLO\n", ("%q"):format(hello))
check("write returns the byte count", net.write(h, "ping\n") == 5)
local echo = readn(h, 5, 2000)
check("echo is uppercased", echo == "PING\n", ("%q"):format(echo))
check("connected / nothing pending", net.connected(h) and net.available(h) == 0 and net.read(h) == "")

print("== 64 KB streamed and hashed")
t = now()
net.write(h, "BIG\n")
local hh = crypto.hash("sha256")
local got, maxChunk, t1 = 0, 0, now()
while got < 65536 and now() - t1 < 15000 do
  local d, e = net.read(h, math.min(1024, 65536 - got))
  if d == nil then print("read error", e); break end
  if #d == 0 then app.sleep(5) else hh:update(d); got = got + #d; if #d > maxChunk then maxChunk = #d end end
end
local ms = now() - t
check("received 65536 bytes", got == 65536, got)
check("sha256 matches the server's", crypto.hex(hh:digest()) == BIG_SHA)
print(("big transfer: %d ms = %d KB/s, largest single read %d"):format(ms, 65536 * 1000 // 1024 // math.max(ms, 1), maxChunk))
check("trailer arrives intact", readn(h, 9, 2000) == "\nBIGDONE\n")

print("== slow sender")
net.write(h, "SLOW\n")
local slow = readn(h, 5, 3000)
check("5 bytes trickled in 100 ms steps", slow == "slow!", ("%q"):format(slow))

print("== peer closes")
net.write(h, "CLOSE\n")
app.sleep(300)
local d, ce = net.read(h)
check("read after the peer closed", d == nil and ce == "closed", tostring(d) .. " " .. tostring(ce))
check("connected() is false", net.connected(h) == false)
check("write to a closed peer fails", net.write(h, "x") == nil)
check("close returns true", net.close(h) == true)
check("closed handle is invalid", select(2, net.read(h)) == "not an open socket handle")

print("== failures and timings")
t = now()
local rh, re = net.connect(SERVER, 9, { timeout_ms = 3000 })
check("refused port fails", rh == nil, (tostring(re) .. " (%d ms)"):format(now() - t))
t = now()
local bh, be = net.connect("10.255.255.1", 80, { timeout_ms = 1500 })
local bms = now() - t
check("blackhole host times out near timeout_ms", bh == nil and bms >= 1000 and bms < 4000, (tostring(be) .. " (%d ms)"):format(bms))

print("== four idle sockets and the table limit")
local fA, mA = heap()
local hs = {}
for i = 1, 4 do hs[i] = net.connect(SERVER, PORT, { timeout_ms = 3000 }) end
check("4 handles", hs[1] and hs[2] and hs[3] and hs[4], table.concat({ hs[1] or "nil", hs[2] or "nil", hs[3] or "nil", hs[4] or "nil" }, ","))
app.sleep(300)
local fB, mB = heap()
print(("RAM: 4 open sockets cost %d bytes of free heap (%d each); min-free %d -> %d"):format(fA - fB, (fA - fB) // 4, mA, mB))
check("5th is refused by the table", select(2, net.connect(SERVER, PORT)) == "too many open sockets (max 4)")
for i = 1, 4 do net.close(hs[i]) end
app.sleep(300)
local fC = heap()
check("closing gives the heap back (within 2 KB)", fA - fC < 2048, ("%d -> %d"):format(fA, fC))

print("== leak: connect/read/close cycles (closed sockets sit in TIME_WAIT, which is bounded: measure the plateau)")
local function cycle() local x = net.connect(SERVER, PORT, { timeout_ms = 3000 }); if x then readn(x, 6, 1000); net.close(x) end return x ~= nil end
local fL0 = heap()
local okc = 0
for _ = 1, 40 do if cycle() then okc = okc + 1 end end      -- fills lwIP's TIME_WAIT table
local fL1 = heap()
print(("after 40 cycles: free %d (%+d vs start: TIME_WAIT entries)"):format(fL1, fL1 - fL0))
for _ = 1, 120 do if cycle() then okc = okc + 1 end end     -- a real leak would keep growing
local fL2, mL2 = heap()
check("160/160 cycles connected", okc == 160, okc)
check("plateau: the next 120 cycles cost under 256 bytes", fL1 - fL2 < 256, ("free %d -> %d (%+d), min-free %d"):format(fL1, fL2, fL2 - fL1, mL2))
print(("PEAK over the whole run: min-free fell from %d to %d"):format(m0, mL2))

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "Socket test", "ui12", "b")
gfx.text(16, 60, fails == 0 and "ALL PASSED" or (fails .. " FAILED"), "ui12")
gfx.text(16, 100, "see the serial log for timings + RAM", "small")
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
