-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
-- wifi.monitor: capture on channel 1 for 12 s (live polling), then capture ~10 s into a
-- PCAP file and check it grew.
local function __test()
print("== monitor")
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
local ok, e1 = wifi.monitor_start({channel = 1})
check("monitor_start", ok == true, tostring(ok) .. " " .. tostring(e1))
if not ok then return end
local after = heap("radio up")
print(("INFO monitor cost %d bytes of free heap"):format(before - after))
local i = wifi.monitor_info()
check("info", i and i.channel == 1 and i.captured == 0 and i.dropped == 0 and i.file == nil, tostring(i and i.channel))
print("Ready: capturing channel 1 for 12 s")
gfx.clear()
gfx.text(16, 10, "monitor test", "ui12", "b")
gfx.text(16, 70, "channel 1, 12 s", "ui12")
gfx.present("full")
local got, t0 = 0, system.millis()
local rssis = {}
while system.millis() - t0 < 12000 and input.poll() ~= "back" do
  local f, meta = wifi.monitor_recv()
  while f do
    got = got + 1
    rssis[#rssis + 1] = meta.rssi
    if got <= 5 then print(("RECV %d bytes rssi=%d ch=%d first=%02x"):format(#f, meta.rssi, meta.channel, f:byte(1) or 0)) end
    f, meta = wifi.monitor_recv()
  end
  app.sleep(20)
end
local i2 = wifi.monitor_info()
print(("INFO live capture: got %d, captured %d, dropped %d"):format(got, i2.captured, i2.dropped))
check("frames received", got >= 5, got)
check("captured counter", i2.captured >= got, i2.captured)
check("rssi looks sane", #rssis > 0 and rssis[1] > -100 and rssis[1] < 0, rssis[1])
local bytes0 = wifi.monitor_stop()
check("stop without a file writes 0 bytes", bytes0 == 0, bytes0)
local _, e2 = wifi.monitor_recv()
check("recv after stop refused", e2 ~= nil and e2:find("not running") ~= nil, tostring(e2))

-- now with a PCAP file
local ok2, e3 = wifi.monitor_start({channel = 1, file = "data:cap.pcap"})
check("monitor_start with file", ok2 == true, tostring(ok2) .. " " .. tostring(e3))
if not ok2 then return end
local i3 = wifi.monitor_info()
check("info reports the file", i3.file ~= nil and i3.bytes == 0, tostring(i3.file) .. " " .. tostring(i3 and i3.bytes))
check("file is the resolved data path", tostring(i3.file):find("^/%.crosslua/data/") ~= nil, tostring(i3.file))
print("Ready: capturing to data:cap.pcap for 10 s")
gfx.clear()
gfx.text(16, 10, "monitor test", "ui12", "b")
gfx.text(16, 70, "writing pcap, 10 s", "ui12")
gfx.present("full")
local got2, t1 = 0, system.millis()
while system.millis() - t1 < 10000 and input.poll() ~= "back" do
  local f = wifi.monitor_recv()
  while f do
    got2 = got2 + 1
    f = select(1, wifi.monitor_recv())
  end
  app.sleep(20)
end
local i4 = wifi.monitor_info()
print(("INFO pcap phase: got %d, captured %d, bytes %d"):format(got2, i4.captured, i4.bytes))
-- info.bytes counts bytes actually on the card; the writer buffers ~2 KB, so most of the file flushes at stop
local bytes = wifi.monitor_stop()
check("stop returns at least header + records", bytes >= 24 + got2 * 16, bytes)
local st = fs.stat("data:cap.pcap")
check("pcap exists on the card", st ~= nil and st.size == bytes, st and st.size)
-- the capture is left on the card (overwritten by the next run) so it can be pulled off and parsed with a real PCAP reader

-- channel hopping: frames must stop on ch6 and resume on ch1
local okh, eh = wifi.monitor_start({channel = 1})
check("monitor restart for hop phase", okh == true, tostring(eh))
if okh then
  -- count only frames carrying a "HOST-FRAME" marker in the body; ambient WiFi is ignored
  local function marker()
    local f = wifi.monitor_recv()
    while f do
      if f:find("HOST%-FRAME", 1, false) then return true end
      f = wifi.monitor_recv()
    end
    return false
  end
  wifi.monitor_channel(6)
  local t2 = system.millis()
  local got6 = 0
  while system.millis() - t2 < 5000 and input.poll() ~= "back" do
    if marker() then got6 = got6 + 1 end
    app.sleep(20)
  end
  wifi.monitor_channel(1)
  t2 = system.millis()
  local got1 = 0
  while system.millis() - t2 < 7000 and input.poll() ~= "back" do
    if marker() then got1 = got1 + 1 end
    app.sleep(20)
  end
  print(("INFO hop: %d marker frames on ch6 (want 0), %d on ch1"):format(got6, got1))
  check("hop away stops the injected frames", got6 == 0, got6)
  check("hop back resumes them", got1 >= 3, got1)
  wifi.monitor_stop()
end

heap("after stop")
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "monitor test", "ui12", "b")
gfx.text(16, 70, fails == 0 and "ALL PASSED" or (fails .. " FAILED"), "ui12")
gfx.text(16, 110, ("live %d, pcap %d B"):format(got, bytes), "small")
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
