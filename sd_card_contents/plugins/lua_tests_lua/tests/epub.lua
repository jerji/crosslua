-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
local function __test()
-- On-device checks for epub.meta (the firmware's metadata-only OPF parse) + the heap it costs.
local lines, fails = {}, 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  local l = (cond and "PASS " or "FAIL ") .. name
  lines[#lines + 1] = l
  print(l .. (extra and (" " .. tostring(extra)) or ""))
end
local function heap() local f, m, b = system.heap(); return f, b, m end   -- free, largest block, min free since boot

collectgarbage()
local f0, b0, m0 = heap()
print(("heap before: free %d, largest block %d, min free so far %d"):format(f0, b0, m0))
local t0 = system.millis()
local m, err = epub.meta("app:assets/book.epub")
local ms = system.millis() - t0
local f1, b1, m1 = heap()
print(("epub.meta took %d ms; heap after: free %d (%+d), largest block %d (%+d)"):format(ms, f1, f1 - f0, b1, b1 - b0))
print(("PEAK: min free fell from %d to %d => the parse needed up to %d bytes at its deepest"):format(m0, m1, math.max(0, m0 > m1 and f0 - m1 or 0)))
check("title decoded (UTF-8)", m and m.title == "\xC3\x89tude No. 1: Caf\xC3\xA9 \xC3\x9Cn\xC3\xAFcode", m and m.title or err)
check("author", m and m.author == "Ada Lovelace", m and m.author or err)

local m2, e2 = epub.meta("app:assets/bad.epub")
check("corrupt epub is nil, err", m2 == nil and e2 ~= nil, e2)
local m3, e3 = epub.meta("app:main.lua")
check("not an .epub is refused", m3 == nil and e3 == "not an .epub file", e3)
local m4, e4 = epub.meta("app:missing.epub")
check("missing file is nil, err", m4 == nil and e4 ~= nil, e4)
-- leak check: a per-call leak scales with the number of calls, uncollected Lua results do not.
-- Measure after a few warm-up rounds, then run 30 more rounds (ok + corrupt + missing + wrong type) and compare.
local function round()
  epub.meta("app:assets/book.epub"); epub.meta("app:assets/bad.epub"); epub.meta("app:missing.epub"); epub.meta("app:main.lua")
end
for _ = 1, 3 do round() end
collectgarbage(); collectgarbage()
local fA = heap()
for _ = 1, 30 do round() end
collectgarbage(); collectgarbage()
local fB = heap()
check("no leak over 30 rounds (120 calls)", fA - fB < 256, ("free %d -> %d (%+d)"):format(fA, fB, fB - fA))
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))

gfx.clear()
local W, H = gfx.size()
gfx.text(16, 10, "Epub test", "ui12", "b"); gfx.line(0, 44, W - 1, 44)
for i, s in ipairs(lines) do gfx.text(12, 52 + (i - 1) * 24, s, "small") end
gfx.text(12, 52 + #lines * 24 + 8, ("meta %d ms, heap %+d"):format(ms, f1 - f0), "small")
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
