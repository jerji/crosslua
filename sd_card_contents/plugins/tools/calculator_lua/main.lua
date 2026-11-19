-- Calculator (no radio, no storage). Pad: 5 columns x 4 rows of keys, cursor walks the keys in reading order.
-- X4 Pro (grid mode): Left/Right step through the keys (wrapping rows), Confirm presses. Up/Down (keyboard / nav
-- mode) jump a row. Touch: tap a key to press it directly. Back exits.
-- Arithmetic: dec.lua (exact decimal). Key rules: calc.lua (crossplay docs/apps/calculator.md).
device.input_mode("grid")
local C = require("calc")

local W, H = 0, 0
local PAD = {
  { "C", "+/-", "%", "BS", "/" },
  { "7", "8", "9", "*", "-" },
  { "4", "5", "6", "+", "=" },
  { "1", "2", "3", "0", "." },
}
local NKEYS = 20
local KEY_W, KEY_H = 90, 74
local PAD_X, PAD_Y = 0, 0

local function draw(st, cur)
  gfx.clear(); W, H = gfx.size()
  PAD_X = (W - 5 * KEY_W) // 2
  PAD_Y = H - 4 * KEY_H - 40
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Calculator", "ui12", "bw")
  if st.op then gfx.text(14, 52, "pending " .. st.op .. (st.acc and ("  " .. require("dec").format(st.acc, 10)) or ""), "small") end
  local shown = C.display(st)
  gfx.text(W - 16, 120, shown, "sans18", "r")
  for r = 1, 4 do
    for c = 1, 5 do
      local k = PAD[r][c]
      local x = PAD_X + (c - 1) * KEY_W
      local y = PAD_Y + (r - 1) * KEY_H
      gfx.rect(x + 4, y + 4, KEY_W - 8, KEY_H - 8, false)
      local sel = (cur.i == (r - 1) * 5 + c)
      if sel then gfx.rect(x + 4, y + 4, KEY_W - 8, KEY_H - 8, true); gfx.text(x + KEY_W // 2, y + KEY_H // 2 - 10, k, "ui12", "cw")
      else gfx.text(x + KEY_W // 2, y + KEY_H // 2 - 10, k, "ui12", "c") end
    end
  end
  gfx.present()
end

-- Key index (1..20, reading order) under a touch point, or nil when outside the pad.
local function touch_key(x, y)
  if x < PAD_X or y < PAD_Y then return nil end
  local c = (x - PAD_X) // KEY_W + 1
  local r = (y - PAD_Y) // KEY_H + 1
  if c < 1 or c > 5 or r < 1 or r > 4 then return nil end
  return (r - 1) * 5 + c
end

local ok, err = pcall(function()
  W, H = gfx.size()
  local st = C.new()
  local cur = { i = 15 }                       -- starts on "=" (row 3, col 5)
  draw(st, cur)
  while true do
    local e = input.wait()
    local changed = true
    if e == "back" then break
    elseif e == "left" then cur.i = cur.i > 1 and cur.i - 1 or NKEYS
    elseif e == "right" then cur.i = cur.i < NKEYS and cur.i + 1 or 1
    elseif e == "up" then cur.i = cur.i > 5 and cur.i - 5 or cur.i + 15
    elseif e == "down" then cur.i = cur.i < 16 and cur.i + 5 or cur.i - 15
    elseif e == "confirm" then
      local x, y = input.pos()                 -- nil for a button press
      if x and y then                          -- touch: a tap outside the pad (display, header) is ignored
        local tapped = touch_key(x, y)
        if not tapped then changed = false
        else cur.i = tapped end
      end
      if changed then
        local r, c = (cur.i - 1) // 5 + 1, (cur.i - 1) % 5 + 1
        C.press(st, PAD[r][c])
      end
    else
      changed = false                          -- press/release/tap: nothing to redraw
    end
    if changed then draw(st, cur) end
  end
end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
