-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
-- TEST ARCHITECTURE:
--   1. X4 calls net.listen(9100) then loops polling net.accept().
--   2. A TCP client on the LAN (Hermes box, connect_to_x4.py) connects to X4:9100,
--      sends "SAMSON_PING\n", expects "X4_PONG\n" back.
--   3. The X4 accepts, verifies "SAMSON_PING\n", sends "X4_PONG\n", closes.
-- Run with: python3 /root/x4/connect_to_x4.py <X4_IP> 9100
-- (Look at the serial log or X4 screen for Ready at ... message.)
local function __test()
print("== wifi")
local ok, why = wifi.connect()
print((ok and "PASS " or "FAIL ") .. "wifi.connect " .. tostring(why or ""))
if not ok then return end
local MY_IP = (net.info() or {}).ip
if not MY_IP then print("ABORT: could not get own IP"); return end

local PORT = 9100
local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  print((cond and "PASS " or "FAIL ") .. name .. (extra and (" " .. tostring(extra)) or ""))
end
local function now() return system.millis() end
local function poll_accept(srv, ms)
  local t0 = now()
  while now() - t0 < ms do
    local cl = net.accept(srv)
    if cl ~= nil then return cl end
    app.sleep(50)
  end
  return nil
end

print("== listen")
local srv, err = net.listen(PORT)
check("net.listen returns a handle", srv ~= nil and type(srv) == "number", tostring(srv or err))
if not srv then print("ABORT: could not listen"); return end

print(("Ready at %s:%d"):format(MY_IP, PORT))

-- Poll for the external client connection (up to 15 s)
local peer = poll_accept(srv, 15000)
check("accept a connection from the host within 15s", peer ~= nil, tostring(peer))
if not peer then print("SKIP: no external client connected"); net.close(srv); return end

print("== external-client exchange")
-- Read the known payload "SAMSON_PING\n" (12 bytes)
local got = ""
local t0 = now()
while #got < 12 and now() - t0 < 3000 do
  local chunk, cerr = net.read(peer, 12 - #got)
  if cerr then print("  read error: " .. cerr); break end
  if chunk and #chunk > 0 then got = got .. chunk end
  if #chunk == 0 then app.sleep(20) end
end
check("received SAMSON_PING from host", got == "SAMSON_PING\n", ("%q"):format(got))

-- Send response
local w = net.write(peer, "X4_PONG\n")
check("sent X4_PONG response", w == 8, tostring(w))

-- Close the external client
net.close(peer)

print("== self-connect (informational: ESP32 lwIP does not loop back to the device's own IP)")
local cl, cerr = net.connect(MY_IP, PORT, { timeout_ms = 3000 })
if cl then
  print("PASS self-connect works on this radio stack")
  local self_peer = poll_accept(srv, 3000)
  if self_peer then
    net.write(cl, "hello_self")
    app.sleep(100)
    local echo = net.read(self_peer, 12)
    check("self-exchange data round-trips", echo == "hello_self", echo and ("%q"):format(echo) or "nil")
    net.close(cl)
    net.close(self_peer)
  else
    print("NOTE self-connect opened but accept saw nothing")
    net.close(cl)
  end
else
  print("INFO self-connect refused by lwIP loopback: " .. tostring(cerr) .. " (not a failure)")
end

print("== close server")
check("close server returns true", net.close(srv) == true)

-- Closed server: accept fails
local dead, derr = net.accept(srv)
check("accept on closed server returns nil, err", dead == nil and derr ~= nil, tostring(dead) .. " " .. tostring(derr))

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "Listen test", "ui12", "b")
gfx.text(16, 60, fails == 0 and "ALL PASSED" or (fails .. " FAILED"), "ui12")
gfx.text(16, 100, MY_IP .. ":" .. PORT, "small")
gfx.text(16, 130, "see serial log for details", "small")
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