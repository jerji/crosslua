-- hub test: system.language + system.battery on the real device (trivial getters, one pass).
local function __test()
print("== language/battery")
local W, H = gfx.size()
local lines, fails = {}, 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  local l = (cond and "PASS " or "FAIL ") .. name
  lines[#lines + 1] = l
  print(l .. (extra and (" " .. tostring(extra)) or ""))
end

local lang = system.language()
check("language is a non-empty string", type(lang) == "string" and #lang > 0, lang)
local pct = system.battery()
check("battery is a number 0..100 or -1", type(pct) == "number" and pct >= -1 and pct <= 100, pct)

print("  language=" .. tostring(lang) .. " battery=" .. tostring(pct))
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "language/battery test", "ui12", "b"); gfx.line(0, 44, W - 1, 44)
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