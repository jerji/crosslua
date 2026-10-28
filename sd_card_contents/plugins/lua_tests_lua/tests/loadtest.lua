-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
local function __test()
-- On-device checks for the sandboxed load(). Prints PASS/FAIL per check to the log and the screen.
local W, H = gfx.size()
local lines, fails = {}, 0
local function check(name, cond)
  if not cond then fails = fails + 1 end
  lines[#lines + 1] = (cond and "PASS " or "FAIL ") .. name
  print((cond and "PASS " or "FAIL ") .. name)
end
local function draw()
  gfx.clear()
  gfx.text(16, 10, "load() test", "ui12", "b"); gfx.line(0, 44, W - 1, 44)
  for i, l in ipairs(lines) do gfx.text(12, 52 + (i - 1) * 24, l, "small") end
  gfx.text(W // 2, H - 34, fails == 0 and "ALL PASSED  (Back: quit)" or (fails .. " FAILED  (Back: quit)"), "small", "c")
  gfx.present("full")
end

local free0 = system.heap()
check("load exists", type(load) == "function")
check("dofile/loadfile still gone", dofile == nil and loadfile == nil)
check("basic", load("return 1 + 2")() == 3)
check("env honoured", load("return x", "=c", "t", {x = 42})() == 42)
check("env isolates", load("return print", "=c", "t", {})() == nil)
local e = {}; load("y = 5", "=c", "t", e)(); check("writes go to env", e.y == 5 and y == nil)
local f, err = load("x = = 1", "=bad"); check("syntax error is nil,err", f == nil and err:find("bad:1:", 1, true) ~= nil)
f, err = load(string.dump(function() return 1 end)); check("bytecode refused", f == nil and err:find("precompiled", 1, true) ~= nil)
f, err = load("return 1", "=c", "b"); check("binary mode refused", f == nil)
f, err = load(function() return nil end); check("reader fn refused", f == nil)
-- (testing the 64 KB limit itself needs a >130 KB heap just to build the string)
check("chunk can call fs/require when env allows", load("return type(fs.exists)", "=c", "t", {fs = fs, type = type})() == "function")
-- heap: compiling a big chunk fails cleanly or works, never crashes the device
local okb, big = pcall(string.rep, "x=1\n", 5000)
local f2, e2 = nil, "skipped"
if okb then f2, e2 = load(big, "=big") end
check("big compile clean (" .. tostring(f2 ~= nil) .. ")", f2 ~= nil or type(e2) == "string")
big = nil; f2 = nil; collectgarbage()
local free1 = system.heap()
check(("no leak: free %dK -> %dK"):format(free0 // 1024, free1 // 1024), free1 >= free0 - 4096)
check("yield inside loaded chunk", load("return input.wait(20)", "=c", "t", {input = input})() == nil)
draw()
while input.wait() ~= "back" do end
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
app.restart("main.lua")
