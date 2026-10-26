-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
local function __test()
print("== wifi")
local ok, why = wifi.connect()
print((ok and "PASS " or "FAIL ") .. "wifi.connect " .. tostring(why or ""))
if not ok then return end
-- net.* on-device UDP test. Needs /root/x4/udp_server.py running on SERVER:9098.
local SERVER, PORT = "192.168.1.67", 9098
local BIG1400_SHA = "6c4e97a2e94daf14c26f7c3212f2d8c7e1fc14dc5a87050624f2ad70fd05fd1c"
local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  print((cond and "PASS " or "FAIL ") .. name .. (extra and (" " .. tostring(extra)) or ""))
end
local function heap() collectgarbage(); collectgarbage(); local f, m, b = system.heap(); return f, m, b end
local function now() return system.millis() end

-- Poll net.udp_recv up to ~2 s for a datagram.
local function poll_recv(h, ms)
  local t0 = now()
  while now() - t0 < ms do
    local r = net.udp_recv(h)
    if r ~= nil then return r end
    app.sleep(10)
  end
  return nil
end

print("== udp basics")
local h = net.udp_open(0)
check("udp_open returns a handle", h ~= nil and type(h) == "number", tostring(h))
if not h then print("ABORT: could not open UDP socket"); return end

local sent = net.udp_send(h, SERVER, PORT, "ping")
check("udp_send ping returns 4", sent == 4, tostring(sent))

local reply = poll_recv(h, 2000)
check("udp_recv returns a table", type(reply) == "table")
check("udp_recv .data == PONG", reply and reply.data == "PONG", reply and reply.data or "nil")
check("udp_recv .ip matches SERVER", reply and reply.ip == SERVER, reply and reply.ip or "nil")
check("udp_recv .port == 9098", reply and reply.port == PORT, reply and tostring(reply.port) or "nil")

local idle = net.udp_recv(h)
check("nothing pending returns nil", idle == nil, tostring(idle))

print("== echo roundtrip (300 bytes)")
local payload = string.rep("X", 300)
net.udp_send(h, SERVER, PORT, "ECHO " .. payload)
local echo_reply = poll_recv(h, 2000)
check("ECHO reply arrived", echo_reply ~= nil)
if echo_reply then
  check("ECHO data length is 300", #echo_reply.data == 300, #echo_reply.data)
  check("ECHO data matches payload", echo_reply.data == payload)
end

print("== big datagram (BIG 1400)")
net.udp_send(h, SERVER, PORT, "BIG 1400")
local big_reply = poll_recv(h, 2000)
check("BIG 1400 reply arrived", big_reply ~= nil)
if big_reply then
  check("BIG 1400 data length is 1400", #big_reply.data == 1400, #big_reply.data)
  local hh = crypto.hash("sha256")
  hh:update(big_reply.data)
  local got = crypto.hex(hh:digest())
  check("BIG 1400 sha256 matches", got == BIG1400_SHA, got)
end

print("== close")
local closed = net.close(h)
check("close returns true", closed == true, tostring(closed))

print("== send on closed handle")
local sent2, err2 = net.udp_send(h, SERVER, PORT, "ping")
check("send on closed returns nil", sent2 == nil, tostring(sent2))
check("send on closed error is not an open socket handle", err2 == "not an open socket handle", tostring(err2))

print("== two sockets")
local a = net.udp_open(0)
local b = net.udp_open(0)
check("handle a is a number", a ~= nil and type(a) == "number", tostring(a))
check("handle b is a number", b ~= nil and type(b) == "number", tostring(b))
check("handles differ", a ~= b, ("%d vs %d"):format(a or 0, b or 0))
if a and b and a ~= b then
  net.udp_send(a, SERVER, PORT, "ping")
  local ra = poll_recv(a, 2000)
  check("socket a receives", ra and ra.data == "PONG", ra and ra.data or "nil")
  net.udp_send(b, SERVER, PORT, "ping")
  local rb = poll_recv(b, 2000)
  check("socket b receives", rb and rb.data == "PONG", rb and rb.data or "nil")
  net.close(a)
  net.close(b)
end

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "UDP test", "ui12", "b")
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