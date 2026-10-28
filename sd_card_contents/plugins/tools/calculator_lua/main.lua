-- Calculator (no radio, no storage). Pad: 5 columns x 4 rows of keys. Arrows move the cursor (it wraps), Confirm presses.
-- Back exits. Arithmetic: dec.lua (exact decimal). Key rules: calc.lua (crossplay docs/apps/calculator.md).
local C = require("calc")

local W, H = 0, 0
local PAD = {
  { "C", "+/-", "%", "BS", "/" },
  { "7", "8", "9", "*", "-" },
  { "4", "5", "6", "+", "=" },
  { "1", "2", "3", "0", "." },
}
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
      local sel = (cur.r == r and cur.c == c)
      if sel then gfx.rect(x + 4, y + 4, KEY_W - 8, KEY_H - 8, true); gfx.text(x + KEY_W // 2, y + KEY_H // 2 - 10, k, "ui12", "cw")
      else gfx.text(x + KEY_W // 2, y + KEY_H // 2 - 10, k, "ui12", "c") end
    end
  end
  gfx.present()
end

local ok, err = pcall(function()
  W, H = gfx.size()
  local st = C.new()
  local cur = { r = 3, c = 5 }
  draw(st, cur)
  while true do
    local e = input.wait()
    if e == "back" then break
    elseif e == "up" then cur.r = cur.r > 1 and cur.r - 1 or 4
    elseif e == "down" then cur.r = cur.r < 4 and cur.r + 1 or 1
    elseif e == "left" then cur.c = cur.c > 1 and cur.c - 1 or 5
    elseif e == "right" then cur.c = cur.c < 5 and cur.c + 1 or 1
    elseif e == "confirm" then C.press(st, PAD[cur.r][cur.c]) end
    draw(st, cur)
  end
end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
