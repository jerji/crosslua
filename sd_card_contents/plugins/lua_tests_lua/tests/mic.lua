-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
-- mic.* on-device test. The X4 has no microphone: this verifies the ABSENCE path - every call reports
-- "no microphone on this board" (or the argument error) and never crashes, and no file is left behind.
-- On boards with a mic the record branch runs.
local function __test()
print("== mic (absence on X4)")
local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  print((cond and "PASS " or "FAIL ") .. name .. (extra and (" " .. tostring(extra)) or ""))
end

print("== argument errors come first (no hardware needed)")
local _, e1 = mic.record("data:t.mp3", 1)
check("non-wav path refused", e1 == "path must end in .wav", tostring(e1))
local _, e2 = mic.record("data:t.wav", 31)
check("seconds bound checked", e2 == "seconds must be an integer 1..30", tostring(e2))
local _, e3 = mic.level(5)
check("level ms bound checked", e3 == "ms must be an integer 10..2000", tostring(e3))
local _, e4 = mic.record("app:t.wav", 1)
check("app: is read-only", e4 and e4:find("read%-only") ~= nil, tostring(e4))

print("== backend absence")
local ok, err = mic.record("data:t.wav", 1)
check("record on X4 reports absence", ok == nil and err == "no microphone on this board", tostring(ok) .. " " .. tostring(err))
check("no file left behind", fs.exists("data:t.wav") == false)
local lv, lerr = mic.level()
check("level on X4 reports absence", lv == nil and lerr == "no microphone on this board", tostring(lv) .. " " .. tostring(lerr))

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "mic test", "ui12", "b")
gfx.text(16, 60, fails == 0 and "ALL PASSED" or (fails .. " FAILED"), "ui12")
gfx.text(16, 100, "see the serial log for details", "small")
gfx.present("full")
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
-- no radio used: back to the hub menu (no reboot)
app.restart("main.lua")
