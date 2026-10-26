-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
-- audio.* on-device test. The X4 has no speaker: everything here verifies the ABSENCE path — every call must return a
-- readable "no audio on this board" (or the argument error) and never crash. On a board with audio (Metalio/Murphy/M5)
-- the play branch actually runs and this test is UNTESTED ON HARDWARE there.
local function __test()
print("== audio (absence on X4)")
local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  print((cond and "PASS " or "FAIL ") .. name .. (extra and (" " .. tostring(extra)) or ""))
end

-- no .wav on the app, so every play below is expected to fail at the extension/absence stage.
-- The order of checks: .wav extension -> size -> backend. A valid path reaches the backend, which
-- reports "no audio on this board" on the X4.
local function write_wav(name)
  local ok = pcall(fs.write, "data:" .. name, "RIFF0000WAVEfmt \20\0\0\0\1\0\1\0\0x\1\0\0x\1\0\1\0\8\0data\0\0\0\0")
  return ok
end
write_wav("tone.wav")

print("== argument errors come first (no audio hardware needed)")
local _, e1 = audio.play("data:tone.txt")
check("non-wav extension refused", e1 == "not a .wav file", tostring(e1))

print("== backend absence")
local ok, err = audio.play("data:tone.wav")
check("play on X4 reports absence", ok == nil and err == "no audio on this board", tostring(ok) .. " " .. tostring(err))
check("stop still returns true", audio.stop() == true)
check("playing is false", audio.playing() == false)
local v, verr = audio.volume(50)
check("volume accepted (stored for when audio exists)", v == true, tostring(v) .. " " .. tostring(verr))
local v2, verr2 = audio.volume(101)
check("volume bound checked before the backend", v2 == nil and verr2 == "volume must be an integer 0..100", tostring(verr2))

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "audio test", "ui12", "b")
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