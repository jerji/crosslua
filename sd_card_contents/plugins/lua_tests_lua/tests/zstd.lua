-- hub test: zip.zstd on the real device (zstd decompressor cross-compiled, plain + trained-dict frames from data:).
local function __test()
print("== zip.zstd")
local W, H = gfx.size()
local lines, fails = {}, 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  local l = (cond and "PASS " or "FAIL ") .. name
  lines[#lines + 1] = l
  print(l .. (extra and (" " .. tostring(extra)) or ""))
end

local plain_src = fs.read("data:plain.txt")
local frame = fs.read("data:plain.zst")
local out, oerr = zip.zstd(frame)
check("frame magic intact", frame:byte(1) == 0x28 and frame:byte(2) == 0xB5, tostring(frame and #frame))
check("plain frame round-trip", out == plain_src, "out=" .. tostring(out and #out) .. " src=" .. tostring(plain_src and #plain_src) .. " err=" .. tostring(oerr))

local dict = fs.read("data:dict.bin")
local dframe = fs.read("data:dict.zst")
local dsrc = fs.read("data:dictplain.txt")
check("dict size", dict and #dict == 4096, tostring(dict and #dict))
local d, derr = zip.zstd(dframe, dict)
check("dict frame round-trip", d == dsrc, "d=" .. tostring(d and #d) .. " src=" .. tostring(dsrc and #dsrc) .. " err=" .. tostring(derr))

local _, err = zip.zstd(dframe)  -- the dict is REQUIRED
check("dict required (refused without it)", err == "zstd decompression failed", err)

local _, e2 = zip.zstd("\0\1")   -- bad magic
check("bad magic refused", e2 == "not a valid zstd frame", e2)

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "zip.zstd test", "ui12", "b"); gfx.line(0, 44, W - 1, 44)
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