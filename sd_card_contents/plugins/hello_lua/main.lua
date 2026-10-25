-- CrossLua hello world / smoke test.
-- Left/Right: move the box. Confirm: full refresh. Back: quit (or hold Back 1s from anywhere).
local w, h = gfx.size()
local x, presses = 40, 0

local function draw()
  gfx.clear()
  gfx.text(w // 2, 24, "Hello from Lua!", "ui12", "bc")
  local f, minf = system.heap()
  local used, peak, budget = system.lua_mem()
  gfx.text(24, 90, "Lua heap: " .. used // 1024 .. "K used, " .. peak // 1024 .. "K peak, " .. budget // 1024 .. "K cap", "small")
  gfx.text(24, 90 + gfx.line_height("small") + 4, "Free RAM: " .. f // 1024 .. "K (min " .. minf // 1024 .. "K)   Battery: " .. system.battery() .. "%", "small")
  gfx.text(24, 150, "Presses: " .. presses .. "   Uptime: " .. system.millis() // 1000 .. "s", "ui")
  gfx.rect(x, h // 2, 80, 80, true)
  gfx.rect(24, h - 70, w - 48, 2, true)
  gfx.text(w // 2, h - 56, "Left/Right move   Confirm full refresh   Back quit", "small", "c")
  gfx.present()
end

draw()
while true do
  local e = input.wait(5000)         -- nil on timeout: refresh the stats
  if e == "back" then break end
  if e == "left" then x = math.max(0, x - 40) end
  if e == "right" then x = math.min(w - 80, x + 40) end
  if e then presses = presses + 1 end
  if e == "confirm" then gfx.clear() gfx.present("full") end
  draw()
end
