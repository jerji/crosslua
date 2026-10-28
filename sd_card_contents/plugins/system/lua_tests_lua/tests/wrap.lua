-- hub test: gfx.wrap on the real fonts. Checks structural invariants (line width <= max, newline split,
-- empty, hard-break) rather than exact break points — the real proportional fonts differ from the host mock.
local function __test()
print("== gfx.wrap")
local W, H = gfx.size()
local lines, fails = {}, 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  local l = (cond and "PASS " or "FAIL ") .. name
  lines[#lines + 1] = l
  print(l .. (extra and (" " .. tostring(extra)) or ""))
end

local t = gfx.wrap("hello\nworld", 10000)
check("newline splits", #t == 2 and t[1] == "hello" and t[2] == "world", #t)

check("empty -> no lines", #gfx.wrap("", 100) == 0)

local src = "the quick brown fox jumps over the lazy dog near the river bank"
for _, mw in ipairs({30, 50, 80, 120}) do
  local ls = gfx.wrap(src, mw)
  local ok = #ls > 0
  for _, l in ipairs(ls) do
    if gfx.text_width(l) > mw then ok = false end
  end
  check("all lines <= " .. mw .. "px", ok, #ls)
end

local long = string.rep("W", 200)
local lw = gfx.wrap(long, 50)
local ok = #lw > 1  -- a 200-char word must break into several lines
for _, l in ipairs(lw) do
  if gfx.text_width(l) > 50 then ok = false end
end
check("over-long word hard-breaks", ok, #lw)

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "gfx.wrap test", "ui12", "b"); gfx.line(0, 44, W - 1, 44)
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