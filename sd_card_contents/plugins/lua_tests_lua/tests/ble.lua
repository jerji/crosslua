-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu.
-- ble: the Bluetooth LE central (keyboard mode) WITHOUT needing a keyboard: stack start/stop and its RAM cost, scan, an async
-- connect that is cancelled, radio exclusivity against WiFi, start/stop cycles for leaks. The typing path is blekeys.lua.
-- Ends with app.exit(): a Bluetooth session, like a WiFi one, reboots into a clean heap on the way out.
local function __test()
print("== ble")
local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  print((cond and "PASS " or "FAIL ") .. name .. (extra and (" " .. tostring(extra)) or ""))
end
local function free() collectgarbage(); return (system.heap()) end

local caps = device.caps()
print("INFO ble_keyboard cap: " .. tostring(caps.ble_keyboard))
local before = free()
print("INFO free before start: " .. before)

local st0 = ble.state()
check("state before start: stopped", st0.running == false and st0.link == "idle" and st0.scanning == false)
local ok, e = ble.scan()
check("scan before start refused", ok == nil and e:find("not running") ~= nil, e)
ok, e = ble.start("gatt")
check("an unknown mode is refused", ok == nil and e:find("keyboard") ~= nil, e)

ok, e = ble.start()
check("start", ok == true, e)
if not ok then
  print("[FAIL] cannot continue without the stack")
else
  local up = free()
  print("INFO free after start: " .. up .. " (stack cost " .. (before - up) .. " B)")
  local s = ble.state()
  check("state after start", s.running and s.mode == "keyboard" and s.link == "idle", s.link)
  ok, e = ble.start()
  check("second start refused", ok == nil and e:find("already running") ~= nil, e)

  -- exclusivity: WiFi refuses while the stack is up (and says so)
  local w, we = wifi.connect()
  check("wifi.connect refused while bluetooth is up", w == false and we ~= nil and we:find("bluetooth") ~= nil, we)
  local sc, se = wifi.scan()
  check("wifi.scan refused while bluetooth is up", sc == nil and se ~= nil and se:find("bluetooth") ~= nil, se)

  -- scan: starts, ends by itself, results are well-formed (a HID-only list: an empty room is a valid answer)
  ok, e = ble.scan(3000)
  check("scan starts", ok == true, e)
  local t0 = system.millis()
  local saw_scanning = ble.state().scanning
  while ble.state().scanning and system.millis() - t0 < 9000 do app.sleep(250) end
  check("scan ended by itself", ble.state().scanning == false, system.millis() - t0)
  local d = ble.devices()
  check("devices() is a table", type(d) == "table")
  print("INFO scan saw " .. #d .. " HID device(s), scanning was on at start: " .. tostring(saw_scanning))
  for i = 1, math.min(#d, 6) do
    local x = d[i]
    print(string.format("INFO  %s  %-24s rssi %d  connectable=%s hid=%s", x.addr, x.name, x.rssi, tostring(x.connectable), tostring(x.hid)))
  end
  local wf = true
  for _, x in ipairs(d) do
    if type(x.addr) ~= "string" or #x.addr ~= 17 or type(x.rssi) ~= "number" then wf = false end
  end
  check("every device has a 17-char address and a number rssi", wf)

  -- connect to an address that does not exist: it must start, report connecting, and be cancellable
  ok, e = ble.connect("00:11:22:33:44:55")
  check("connect starts", ok == true, e)
  app.sleep(500)
  local cs = ble.state()
  check("state is connecting (or already failed) right after", cs.link == "connecting" or cs.link == "failed", cs.link)
  ble.disconnect()
  app.sleep(500)
  local after_dc = ble.state()
  check("disconnect returns to idle", after_dc.link == "idle" or after_dc.link == "failed", after_dc.link)
  ok, e = ble.connect("not-an-address")
  check("a bad address never reaches the stack", ok == nil and e:find("addr must look like") ~= nil, e)
  ok, e = ble.forget("00:11:22:33:44:55")
  check("forget of an unknown peer is an error", ok == nil and e:find("not paired") ~= nil, e)
  local pr = ble.paired()
  print("INFO bonded keyboards: " .. #pr)

  ok = ble.stop()
  check("stop", ok == true)
  check("state after stop", ble.state().running == false)
  local down = free()
  print("INFO free after stop: " .. down .. " (not returned: " .. (before - down) .. " B)")

  -- the stack comes back and goes again without growing the loss (the reboot on exit defragments, but a leak per cycle would bite)
  local base
  for i = 1, 6 do
    local a = ble.start()
    app.sleep(300)
    ble.scan(500)
    app.sleep(700)
    ble.stop()
    local f = free()
    if i == 1 then base = f end  -- a single cycle can dip (scan buffers); a leak would show as a steady fall from cycle 1
    print("INFO cycle " .. i .. (a and "" or " (start FAILED)") .. " free after stop " .. f)
    if not a then fails = fails + 1 end
  end
  local last = free()
  check("no loss across cycles (last cycle >= first - 1.5 KB)", base and last >= base - 1536, base and (last - base) or "n/a")
end

print(fails == 0 and "ALL PASSED" or ("FAILED: " .. fails))
gfx.clear(); gfx.text(16, 10, "ble test", "ui12", "b"); gfx.text(16, 70, fails == 0 and "ALL PASSED" or ("FAILED: " .. fails), "ui12"); gfx.present("full")
app.sleep(2000)
app.exit()
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
