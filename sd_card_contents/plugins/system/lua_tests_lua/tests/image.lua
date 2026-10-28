-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
local function __test()
-- On-device checks for gfx.image. Needs /spells/images/test.png (800x300 PNG) on the SD card.
local W, H = gfx.size()
local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  print((cond and "PASS " or "FAIL ") .. name .. (extra and (" " .. tostring(extra)) or ""))
end
local function mem(tag)
  collectgarbage()
  local free, minf, big = system.heap()
  print(("MEM %s: free %dK min %dK big %dK lua %dK"):format(tag, free // 1024, minf // 1024, big // 1024, system.lua_mem() // 1024))
  return free, big
end

local f0, b0 = mem("start")
gfx.clear()
local t0 = system.millis()
local w, h, err = gfx.image("sd:spells/images/test.png", 0, 0)
local ms = system.millis() - t0
check("png drawn", w ~= nil, w and (w .. "x" .. h .. " in " .. ms .. " ms") or err)
check("fits the screen, keeps aspect", w and w <= W and h <= H and math.abs(w / h - 800 / 300) < 0.1, w and (w .. "x" .. h))
gfx.text(W // 2, H - 24, "gfx.image test: " .. (w and "drawn" or "FAILED"), "small", "c")
gfx.present("full")
local f1, b1 = mem("after png")
check("no heap leak after decode", f1 >= f0 - 2048, ("%dK -> %dK"):format(f0 // 1024, f1 // 1024))

local r, e = gfx.image("sd:spells/images/missing.png", 0, 0); check("missing file is nil,err", r == nil and e == "no such file", e)
r, e = gfx.image("sd:spells/example_spell.lua", 0, 0); check("lua file refused", r == nil and e:find("unsupported image type", 1, true), e)
r, e = gfx.image("sd:.crosspoint/x.png", 0, 0); check("hidden path refused", r == nil and e:find("hidden", 1, true), e)
r, e = gfx.image("sd:spells/images/test.png", W, 0); check("off-screen x refused", r == nil, e)
-- a tiny box: still decodes, just scaled down
local sw, sh = gfx.image("sd:spells/images/test.png", 10, 10, 120, 120)
check("small box scales down", sw ~= nil and sw <= 120 and sh <= 120, sw and (sw .. "x" .. sh) or "failed")
-- BMP: no decoder object, so it must work with little RAM (1-bit and 24-bit, scaled and not)
local bw, bh, be = gfx.image("sd:spells/images/test1bit.bmp", 0, 400)
check("1-bit bmp drawn (fits 480 wide, unscaled 400x150)", bw == 400 and bh == 150, bw and (bw .. "x" .. bh) or be)
local cw, ch, ce = gfx.image("sd:spells/images/test24.bmp", 0, 600, 200, 100)
check("24-bit bmp scaled into a 200x100 box", cw ~= nil and cw <= 200 and ch <= 100, cw and (cw .. "x" .. ch) or ce)
local nw, ne = gfx.image("sd:spells/images/missing.bmp", 0, 0); check("missing bmp is nil,err", nw == nil, ne)
gfx.present("fast")
local f2 = mem("end")
check("no leak after repeated draws", f2 >= f0 - 2048)
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
while input.wait() ~= "back" do end
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
app.restart("main.lua")
