-- hub test: system.battery_info on the real device. Sanity checks — actual values vary with charge/charger.
local function __test()
print("== battery_info")
local W, H = gfx.size()
local lines, fails = {}, 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  local l = (cond and "PASS " or "FAIL ") .. name
  lines[#lines + 1] = l
  print(l .. (extra and (" " .. tostring(extra)) or ""))
end

local b = system.battery_info()
check("returns a table", type(b) == "table")
check("percent 0..100", b.percent == nil or (type(b.percent) == "number" and b.percent >= 0 and b.percent <= 100), b.percent)
check("millivolts 2000..5000", b.millivolts == nil or (type(b.millivolts) == "number" and b.millivolts >= 2000 and b.millivolts <= 5000), b.millivolts)
check("charging is boolean", b.charging == nil or type(b.charging) == "boolean", b.charging)
check("external_power is boolean", b.external_power == nil or type(b.external_power) == "boolean", b.external_power)
check("has percent (X4 has a battery)", b.percent ~= nil, b.percent)

print("  percent=" .. tostring(b.percent) .. " mV=" .. tostring(b.millivolts) .. " charging=" .. tostring(b.charging) .. " ext_pwr=" .. tostring(b.external_power))
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "battery_info test", "ui12", "b"); gfx.line(0, 44, W - 1, 44)
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
app.restart("main.lua")