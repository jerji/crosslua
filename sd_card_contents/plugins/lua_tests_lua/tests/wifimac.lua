-- hub test: wifi.set_mac / wifi.get_mac on the real radio. Key check: the runtime MAC really changes.
local function __test()
print("== wifimac")
local W, H = gfx.size()
local lines, fails = {}, 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  local l = (cond and "PASS " or "FAIL ") .. name
  lines[#lines + 1] = l
  print(l .. (extra and (" " .. tostring(extra)) or ""))
end

-- Validation gates (no radio yet).
check("multicast refused", wifi.set_mac("03:11:22:33:44:55") == nil)
check("all-zero refused", wifi.set_mac("00:00:00:00:00:00") == nil)
check("bad format refused", wifi.set_mac("hello") == nil)

-- The real rotation: set a fixed unicast MAC, read it back.
local target = "02:11:22:33:44:66"
local ok = wifi.set_mac(target)
check("set_mac ok", ok == true)
local m = wifi.get_mac()
check("runtime MAC reflects the change", m == target, m)

print("  set=" .. target .. " got=" .. tostring(m))
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "wifimac test", "ui12", "b"); gfx.line(0, 44, W - 1, 44)
for i, s in ipairs(lines) do gfx.text(12, 52 + (i - 1) * 24, s, "small") end
gfx.text(W // 2, H - 34, fails == 0 and "ALL PASSED  (Back: quit)" or (fails .. " FAILED  (Back: quit)"), "small", "c")
gfx.present("full")
while input.wait() ~= "back" do end
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
-- set_mac boots the WiFi driver; a WiFi test ends in a reboot to defragment the heap.
app.exit()