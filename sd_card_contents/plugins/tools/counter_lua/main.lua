-- Counter: Confirm (or tap) = +1, Left = -1, Right = +10, Tap the top strip = reset, Up = reset (keyboards / nav mode).
-- X4 Pro: grid mode, so physical buttons only send left/right; reset is reachable by touch. Back = quit.
-- State survives power-off.
device.input_mode("grid")
local store = require("store")

local w, h = gfx.size()
local state = store.load("state.json", { count = 0, launches = 0 })
state.launches = state.launches + 1
store.save("state.json", state)

local RESET_STRIP = 60  -- a tap above this y-pixel resets instead of +1

local function draw(note)
  gfx.clear()
  gfx.text(w // 2, 24, "Counter", "ui12", "bc")
  gfx.text(w // 2, h // 2 - 50, tostring(state.count), "sans18", "bc")
  gfx.text(w // 2, h // 2 + 40, "launched " .. state.launches .. " time(s)", "small", "c")
  if note then gfx.text(w // 2, h // 2 + 70, note, "small", "c") end
  gfx.text(w // 2, h - 40, "Tap +1   Left -1   Right +10   Top tap: reset   Back quit", "small", "c")
  gfx.present()
end

draw()
while true do
  local e = input.wait()
  if e == "back" then break end
  local changed = true
  if e == "confirm" then
    local _, y = input.pos()           -- nil for a button press, the tap position for a touch
    if y and y < RESET_STRIP then state.count = 0 else state.count = state.count + 1 end
  elseif e == "left" then state.count = state.count - 1
  elseif e == "right" then state.count = state.count + 10
  elseif e == "up" then state.count = 0
  else changed = false end             -- press/release/tap/etc: nothing to redraw or save
  if changed then
    local ok, err = store.save("state.json", state)
    if ok then draw() else draw("save failed: " .. tostring(err)) end  -- (not `ok and nil or x`: that is always x)
  end
end
