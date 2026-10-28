-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
local function __test()
-- Does gfx.image draw when offset down the screen and presented with "fast"?
local W, H = gfx.size()
gfx.clear()
local w, h, err = gfx.image("sd:spells/images/test.png", 0, 310, 480, 180)
print("draw at y=310 ->", w, h, err)
gfx.text(W // 2, 20, "A: y=310 box 480x180 (fast)", "small", "c")
gfx.present("fast")
local s1 = input.wait()
gfx.clear()
local w2, h2 = gfx.image("sd:spells/images/test.png", 0, 0, 480, 180)
print("draw at y=0 fast ->", w2, h2)
gfx.text(W // 2, 300, "B: y=0 box 480x180 (fast)", "small", "c")
gfx.present("fast")
input.wait()
gfx.clear()
local w3, h3 = gfx.image("sd:spells/images/test.png", 0, 310, 480, 180)
gfx.text(W // 2, 20, "C: y=310 (full)", "small", "c")
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
