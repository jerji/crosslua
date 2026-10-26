-- gfx.save_bmp on-device check. Phase 1: draw a pattern, save it, verify the file. Confirm: redraw the saved BMP.
local W, H = gfx.size()
local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  print((cond and "PASS " or "FAIL ") .. name .. (extra and (" " .. tostring(extra)) or ""))
end

gfx.clear()
gfx.text(16, 10, "SCREENSHOT TEST", "ui12", "b")
gfx.line(0, 44, W - 1, 44)
gfx.rect(20, 80, 200, 120, true)                  -- a filled block (top left)
gfx.rect(W - 160, H - 220, 140, 180, false)       -- an outline (bottom right)
for i = 0, 9 do gfx.line(20 + i * 40, 300, 20 + i * 40, 300 + 20 * (i + 1)) end   -- a staircase of vertical bars
gfx.text(20, 560, "left-top block, bottom-right frame", "small")
gfx.text(20, 600, "bars grow to the right", "small")
gfx.present("full")

local f0 = system.heap()
local t0 = system.millis()
local ok, err = gfx.save_bmp("data:shot.bmp")
local ms = system.millis() - t0
print(("save_bmp took %d ms"):format(ms))
check("save_bmp returns true", ok == true, err)

local size = fs.size("data:shot.bmp")
local hdr = fs.read("data:shot.bmp", 0, 62) or ""
local w, h = string.unpack("<i4i4", hdr, 19)
local bpp = string.unpack("<I2", hdr, 29)
check("file is a BMP", hdr:sub(1, 2) == "BM")
check("480 x 800 in portrait, 1 bit", w == 480 and math.abs(h) == 800 and bpp == 1, ("%dx%d %d-bit"):format(w, h, bpp))
check("size = 62 + 60*800", size == 62 + 60 * 800, size)

check("non-.bmp refused", select(2, gfx.save_bmp("data:x.png")) == "path must end in .bmp")
check("app: is read-only", gfx.save_bmp("app:x.bmp") == nil)
check("sd: needs a write grant", gfx.save_bmp("sd:x.bmp") == nil)

collectgarbage(); collectgarbage()
local fA = system.heap()
for _ = 1, 20 do gfx.save_bmp("data:shot.bmp") end
collectgarbage(); collectgarbage()
local fB = system.heap()
check("no leak over 20 saves", fA - fB < 256, ("free %d -> %d"):format(fA, fB))
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))

-- Confirm: redraw the saved file at 1:1 so both screens can be compared pixel by pixel
while true do
  local e = input.wait()
  if e == "confirm" then
    gfx.clear()
    local rw, rh, rerr = gfx.image("data:shot.bmp", 0, 0)
    print("redraw:", rw, rh, rerr)
    gfx.present("full")
  elseif e == "back" then break end
end
