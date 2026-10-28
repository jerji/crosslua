-- hub test: fs.volume on the real device (real SD capacity). Sanity checks only — actual byte counts vary per card.
local function __test()
print("== fs.volume")
local W, H = gfx.size()
local lines, fails = {}, 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  local l = (cond and "PASS " or "FAIL ") .. name
  lines[#lines + 1] = l
  print(l .. (extra and (" " .. tostring(extra)) or ""))
end

local v = fs.volume()
check("returns a table", type(v) == "table")
check("total > 0", type(v.total) == "number" and v.total > 0, v.total)
check("used >= 0", type(v.used) == "number" and v.used >= 0, v.used)
check("free >= 0", type(v.free) == "number" and v.free >= 0, v.free)
check("free <= total", v.free <= v.total)
check("free == total - used (float tol)", math.abs((v.total - v.used) - v.free) <= math.max(1024, v.total * 1e-6))
check("total < 4 TB", v.total < 4e12)

print("  total=" .. string.format("%.0f", v.total) .. " used=" .. string.format("%.0f", v.used) .. " free=" .. string.format("%.0f", v.free))
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "fs.volume test", "ui12", "b"); gfx.line(0, 44, W - 1, 44)
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