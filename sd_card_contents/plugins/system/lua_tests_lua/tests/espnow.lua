-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
-- espnow.*: start the radio on channel 1, broadcast a numbered frame every 500 ms for 25 s, and report every frame that arrives.
-- A monitor-mode adapter on channel 1 can capture the X4's frames and inject frames at it.
local function __test()
print("== espnow")
local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  print((cond and "PASS " or "FAIL ") .. name .. (extra and (" " .. tostring(extra)) or ""))
end
local function heap(tag)
  local f, m, l = system.heap()
  print(("HEAP %-24s free=%d min=%d largest=%d"):format(tag, f, m, l))
  return f
end

local before = heap("before start")
local _, e0 = espnow.info()
check("not started yet", e0 ~= nil and e0:find("not started") ~= nil, tostring(e0))
local _, e1 = espnow.send(nil, "x")
check("send before start refused", e1 ~= nil and e1:find("not started") ~= nil, tostring(e1))

local ok, mac = espnow.start({channel = 1})
check("espnow.start", ok == true, tostring(ok) .. " " .. tostring(mac))
if not ok then return end
local after = heap("radio up")
print(("INFO espnow cost %d bytes of free heap"):format(before - after))
local info = espnow.info()
check("info", info and info.mac == mac and info.channel == 1 and info.dropped == 0, info and (info.mac .. " ch" .. info.channel))
check("mac looks like a mac", mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil, mac)
local w, ew = wifi.softap("nope")
check("hotspot refused while espnow runs", w == false, tostring(ew))
local c, ec = wifi.connect({tls = false})
check("wifi.connect refused while espnow runs", c == false and ec ~= nil and ec:find("espnow is running") ~= nil, tostring(ec))
local _, e2 = espnow.send("aa:bb", "x")
check("bad mac refused", e2 ~= nil and e2:find("mac must be") ~= nil, tostring(e2))

print("MAC " .. mac)
print("Ready: broadcasting on channel 1 for 25 s")
gfx.clear()
gfx.text(16, 10, "espnow test", "ui12", "b")
gfx.text(16, 70, "channel 1, broadcasting", "ui12")
gfx.text(16, 110, mac, "ui12")
gfx.text(16, 150, "25 s (Back ends)", "small")
gfx.present("full")

local sent, got, t0 = 0, 0, system.millis()
local nextSend = t0
local seen = {}
while system.millis() - t0 < 25000 and input.poll() ~= "back" do
  if system.millis() >= nextSend then
    sent = sent + 1
    local ok2, err2 = espnow.send(nil, ("X4-FRAME-%03d"):format(sent))
    if not ok2 then print("send failed: " .. tostring(err2)) end
    nextSend = nextSend + 500
  end
  local d, from = espnow.recv()
  while d do
    got = got + 1
    seen[#seen + 1] = from
    print(("RECV from %s (%d bytes): %s"):format(from, #d, d:gsub("[^%g ]", "?")))
    d, from = espnow.recv()
  end
  app.sleep(20)
end
local fin = espnow.info()
print(("INFO sent %d, received %d, dropped %d"):format(sent, got, fin and fin.dropped or -1))
heap("after the loop")
check("sent frames", sent >= 40, sent)
if got == 0 then print("INFO no frame was received (a peer is needed for that half)") end
espnow.stop()
local _, e3 = espnow.info()
check("stop gives the radio back", e3 ~= nil and e3:find("not started") ~= nil, tostring(e3))

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "espnow test", "ui12", "b")
gfx.text(16, 70, fails == 0 and "ALL PASSED" or (fails .. " FAILED"), "ui12")
gfx.text(16, 110, ("sent %d, received %d"):format(sent, got), "small")
gfx.present("full")
app.sleep(1500)
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
-- the radio was used: reboot back to the hub (frees the radio's RAM)
app.exit()
