-- Counter: Confirm = +1, Left = -1, Right = +10, Up = reset. Back = quit. State survives power-off.
local store = require("store")

local w, h = gfx.size()
local state = store.load("state.json", { count = 0, launches = 0 })
state.launches = state.launches + 1
store.save("state.json", state)

local function draw(note)
  gfx.clear()
  gfx.text(w // 2, 24, "Counter", "ui12", "bc")
  gfx.text(w // 2, h // 2 - 50, tostring(state.count), "sans18", "bc")
  gfx.text(w // 2, h // 2 + 40, "launched " .. state.launches .. " time(s)", "small", "c")
  if note then gfx.text(w // 2, h // 2 + 70, note, "small", "c") end
  gfx.text(w // 2, h - 40, "Confirm +1   Left -1   Right +10   Up reset   Back quit", "small", "c")
  gfx.present()
end

draw()
while true do
  local e = input.wait()
  if e == "back" then break end
  if e == "confirm" then state.count = state.count + 1
  elseif e == "left" then state.count = state.count - 1
  elseif e == "right" then state.count = state.count + 10
  elseif e == "up" then state.count = 0 end
  local ok, err = store.save("state.json", state)
  if ok then draw() else draw("save failed: " .. tostring(err)) end  -- (not `ok and nil or x`: that is always x)
end
