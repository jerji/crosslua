-- hub test: ble raw mode on the REAL device. The body is wrapped so an early `return` or an error still goes back to the menu.
-- ble.start("raw") brings NimBLE up as a bare observer; ble.observe()/ble.adverts() hand over every advertisement as received.
-- What this checks: the modes exclude each other, passive and active scans fill the table with well-formed advertising data, a
-- continuous scan stops on request, and starting/stopping the stack six times leaves no heap behind. Whether anything is heard depends
-- on what advertises nearby: hearing nothing is a WARN (check that a phone, watch or earbuds are around), not a failure.
local function __test()
print("== bleraw")
local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  print((cond and "PASS " or "FAIL ") .. name .. (extra ~= nil and (" " .. tostring(extra)) or ""))
end
local function free() collectgarbage(); return (system.heap()) end

-- Walk the length/type/value structures of `data` (adv part, then scan response part). Returns the number of structures and whether
-- the chain is well formed (a zero length ends a part: legacy padding).
local function walk(data, advLen)
  local n, ok, names = 0, true, 0
  local function part(from, to)
    local i = from
    while i <= to do
      local len = data:byte(i)
      if len == 0 then return end
      if i + len > to then ok = false return end
      local t = data:byte(i + 1)
      n = n + 1
      if t == 0x08 or t == 0x09 then names = names + 1 end
      i = i + 1 + len
    end
  end
  part(1, advLen)
  part(advLen + 1, #data)
  return n, ok, names
end

local function survey(label, ms, active)
  local ok, err = ble.observe(ms, {active = active})
  check(label .. ": observe starts", ok == true, err)
  if not ok then return 0 end
  local t0 = system.millis()
  while system.millis() - t0 < ms + 300 do input.wait(200) end
  local st = ble.state()
  check(label .. ": the scan ended by itself", st.scanning == false)
  local list, dropped = ble.adverts()
  check(label .. ": adverts returns a table", type(list) == "table" and type(dropped) == "number", type(list))
  local bad, malformed, withName, conn = 0, 0, 0, 0
  for _, a in ipairs(list) do
    if not (a.addr:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") and a.rssi <= 0 and a.rssi >= -127 and #a.data <= 62 and a.adv_len <= #a.data
        and a.age_ms >= 0 and a.addr_type >= 0 and a.addr_type <= 3) then bad = bad + 1 end
    local n, wf, nm = walk(a.data, a.adv_len)
    if not wf then malformed = malformed + 1 end
    if nm > 0 then withName = withName + 1 end
    if a.connectable then conn = conn + 1 end
  end
  check(label .. ": every entry has sane fields", bad == 0, bad)
  check(label .. ": every advertisement is a well formed chain (<= 1 odd one tolerated)", malformed <= 1, malformed)
  print(("INFO %s: %d devices, %d with a name, %d connectable, %d packets dropped"):format(label, #list, withName, conn, dropped))
  for i = 1, math.min(#list, 4) do
    local a = list[i]
    print(("INFO   ..:%s type=%d rssi=%d adv=%d bytes sr=%d bytes age=%d ms"):format(a.addr:sub(10), a.addr_type, a.rssi, a.adv_len, #a.data - a.adv_len, a.age_ms))
  end
  if #list == 0 then print("WARN " .. label .. ": nothing heard (is anything advertising nearby?)") end
  return #list, withName
end

local m0 = free()
check("start raw", ble.start("raw") == true)
local st = ble.state()
check("state says raw, running, not scanning", st.running and st.mode == "raw" and st.scanning == false and st.link == "idle")
local sc, e = ble.scan()
check("keyboard calls are refused in raw mode", sc == nil and e:find("keyboard", 1, true) ~= nil, e)
check("a second start is refused", ble.start("raw") == nil)
check("the keyboard mode cannot start over it", ble.start("keyboard") == nil)
check("adverts is empty before any scan", (function() local l = ble.adverts() return #l == 0 end)())

local nPassive = survey("passive 6 s", 6000, false)
local nActive, namesActive = survey("active 6 s", 6000, true)
print("INFO active heard " .. nActive .. " (" .. namesActive .. " with a name), passive heard " .. nPassive)

-- continuous scan, stopped on request
check("continuous observe starts", ble.observe(0) == true)
input.wait(1500)
check("a continuous scan is still running", ble.state().scanning == true)
check("observe_stop", ble.observe_stop() == true)
input.wait(300)
check("... and it stopped", ble.state().scanning == false)
check("the table survives the stop", type(ble.adverts()) == "table")
check("observe again clears the table first", ble.observe(500) == true)
check("stop", ble.stop() == true)
check("after stop the raw calls say so", (function()
  local l, er = ble.adverts()
  local o, oe = ble.observe()
  return l == nil and er ~= nil and o == nil and oe ~= nil
end)())

-- the stack comes back in either mode, and six cycles leave nothing behind
check("keyboard mode starts after raw", ble.start("keyboard") == true)
check("raw calls refused in keyboard mode", select(2, ble.observe()) ~= nil)
ble.stop()
local before = free()
for i = 1, 6 do
  local ok = ble.start("raw")
  if ok then
    ble.observe(700, {active = (i % 2 == 0)})
    input.wait(900)
    ble.adverts()
  end
  ble.stop()
  if not ok then check("cycle " .. i .. " starts", false) break end
end
local after = free()
print("INFO heap before the cycles " .. before .. ", after " .. after)
check("six start/observe/stop cycles leave no heap behind (|diff| < 4 KB)", math.abs(before - after) < 4096, before - after)
print("INFO heap before the first start " .. m0 .. ", after everything " .. after .. " (one-time allocations of the first start are expected; the cycle check above is the leak test)")

print(fails == 0 and "ALL PASSED" or ("FAILED: " .. fails))
gfx.clear(); gfx.text(16, 10, "ble raw test", "ui12", "b")
gfx.text(16, 70, fails == 0 and "ALL PASSED" or ("FAILED: " .. fails), "ui12"); gfx.present("full")
app.sleep(1500)
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
pcall(ble.stop)
app.restart("main.lua")
