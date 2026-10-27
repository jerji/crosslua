-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
-- wifi.tx: inject raw 802.11 frames on channel 1; the host adapter (monitor mode, tools/espnow_peer.py with --no-inject) verifies
-- them on the air. Also checks monitor coexistence: the injector adopts the sniffer's channel, and frames sent while the sniffer
-- runs are captured by our own monitor_recv (the radio hears its own transmissions).
local function __test()
print("== tx")
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

local _, e0 = wifi.tx(("d"):rep(26))
check("send before start refused", e0 ~= nil and e0:find("not running") ~= nil, tostring(e0))
local ok, e1 = wifi.tx_start{channel = 1}
check("tx_start", ok == true, tostring(ok) .. " " .. tostring(e1))
if not ok then return end
local c, ec = wifi.connect{tls = false}
check("wifi.connect refused while tx runs", c == false and ec:find("injector") ~= nil, tostring(ec))

-- raw 802.11 management action frame (subtype 13), category 127 + Espressif OUI + vendor type 4: the same shape the
-- host-side peer tool (tools/espnow_peer.py) parses, so it can verify our frames byte for byte.
local function espnowish(payload, seq)
  local fc = "\xd0\x00"
  local dur = "\x00\x00"
  local a1 = "\xff\xff\xff\xff\xff\xff"
  local a2 = "\xf8\x5b\x1b\x5b\xa6\xa8"  -- this device's MAC (the host tool reports it)
  local a3 = "\xff\xff\xff\xff\xff\xff"
  local seqc = string.char(seq % 256, math.floor(seq / 256) % 256)
  local body = "\x7f\x18\xfe\x34\x00\x00\x00\x00\xdd" .. string.char(#payload + 5) .. "\x18\xfe\x34\x04\x01" .. payload
  return fc .. dur .. a1 .. a2 .. a3 .. seqc .. body
end

print("Ready: injecting 15 frames on channel 1")
gfx.clear()
gfx.text(16, 10, "tx test", "ui12", "b")
gfx.text(16, 70, "injecting, channel 1", "ui12")
gfx.present("full")
local sent = 0
for i = 1, 15 do
  local ok2, err2 = wifi.tx(espnowish(("X4-TX-%03d"):format(i), i * 16))
  if ok2 then sent = sent + 1 else print("send failed: " .. tostring(err2)) end
  app.sleep(700)
end
local i = wifi.tx_info()
check("frames accepted by the radio", sent == 15 and i.sent == 15, tostring(sent) .. "/" .. tostring(i.sent))
check("info channel", i.channel == 1, i.channel)

-- coexistence with the sniffer: no channel given -> adopts channel 1; our own frames should come back on monitor_recv
local ok3 = wifi.monitor_start()
check("monitor coexists with the injector", ok3 == true, tostring(ok3))
if ok3 then
  print("Ready: sniffing our own frames for 6 s")
  gfx.clear()
  gfx.text(16, 10, "tx test", "ui12", "b")
  gfx.text(16, 70, "sniffing own frames", "ui12")
  gfx.present("full")
  local got, t0 = 0, system.millis()
  local nextTx = t0
  while system.millis() - t0 < 6000 and input.poll() ~= "back" do
    if system.millis() >= nextTx then
      sent = sent + 1
      wifi.tx(espnowish(("X4-TX-%03d"):format(sent), sent * 16))
      nextTx = nextTx + 700
    end
    local f, meta = wifi.monitor_recv()
    while f do
      got = got + 1
      if got <= 3 then print(("RECV %d bytes rssi=%d"):format(#f, meta.rssi)) end
      f, meta = wifi.monitor_recv()
    end
    app.sleep(20)
  end
  print(("INFO loopback capture: %d frames"):format(got))
  wifi.monitor_stop()
end
local i2 = wifi.tx_info()
print(("INFO sent %d total"):format(i2.sent))
heap("after the loop")
wifi.tx_stop()
local _, e4 = wifi.tx_info()
check("stop gives the radio back", e4 ~= nil and e4:find("not running") ~= nil, tostring(e4))

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "tx test", "ui12", "b")
gfx.text(16, 70, fails == 0 and "ALL PASSED" or (fails .. " FAILED"), "ui12")
gfx.text(16, 110, ("sent %d"):format(i2.sent), "small")
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
