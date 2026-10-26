-- CrossLua on-device self-test. Runs every check, prints PASS/FAIL (screen + serial log), waits for Back.
local results, failed = {}, 0
local function check(name, fn)
  local ok, err = pcall(fn)
  if ok and err ~= false then
    results[#results + 1] = "PASS " .. name
  else
    failed = failed + 1
    results[#results + 1] = "FAIL " .. name .. " :: " .. tostring(err)
  end
  print(results[#results])
end
local function eq(a, b) if a ~= b then error(("expected %s got %s"):format(tostring(b), tostring(a)), 0) end end

check("fs write/read roundtrip", function()
  assert(fs.write("data:t/a.txt", "hello"))
  eq(fs.read("data:t/a.txt"), "hello")
  assert(fs.append("data:t/a.txt", " world"))
  eq(fs.read("data:t/a.txt"), "hello world")
  eq(fs.size("data:t/a.txt"), 11)
end)
check("fs atomic overwrite + no tmp left", function()
  assert(fs.write("data:t/b.txt", string.rep("x", 5000)))
  assert(fs.write("data:t/b.txt", "short"))
  eq(fs.read("data:t/b.txt"), "short")
  for _, n in ipairs(fs.list("data:t")) do assert(not n:find("~tmp", 1, true), n) end
end)
check("fs list sorted, dirs end in /", function()
  assert(fs.mkdir("data:t/sub"))
  local l = fs.list("data:t")
  eq(table.concat(l, ","), "a.txt,b.txt,sub/")
end)
check("fs sandbox rejects escapes", function()
  for _, p in ipairs({ "../x", "data:../../x", "/etc/x", "data:/x", "a//b" }) do
    local r, e = fs.read(p)
    assert(r == nil and e ~= "no such file", p)
  end
  local ok = fs.write("app:evil.txt", "x")
  assert(not ok)
end)
check("fs remove", function()
  assert(fs.remove("data:t/a.txt")); assert(fs.remove("data:t/b.txt")); assert(fs.remove("data:t/sub")); assert(fs.remove("data:t"))
  assert(not fs.exists("data:t"))
end)
check("json roundtrip + unicode", function()
  local s = json.encode({ name = "caf\xc3\xa9", list = { 1, 2.5, true }, n = json.null })
  local b = json.decode(s)
  eq(b.name, "caf\xc3\xa9"); eq(#b.list, 3); eq(b.list[2], 2.5); assert(b.n == json.null)
  eq(json.decode('"\\u00e9\\ud83d\\ude00"'), "\xc3\xa9\xf0\x9f\x98\x80")
  assert(json.decode("[1,") == nil)
end)
check("require from app dir (+cache)", function()
  local m = require("helper")
  eq(m.answer, 42); eq(m.who, "helper"); assert(require("helper") == m)
end)
check("all 7 fonts resolve + measure", function()
  for _, f in ipairs({ "ui", "ui12", "small", "sans12", "sans14", "sans16", "sans18" }) do
    assert(gfx.text_width("Hello", f) > 0, f); assert(gfx.line_height(f) > 0, f)
  end
end)
check("OOM is catchable and VM survives", function()
  local ok, err = pcall(function() local t = {} for i = 1, 1e6 do t[i] = { i } end end)
  assert(not ok and tostring(err):find("not enough memory"), tostring(err))
  collectgarbage()
  eq(#string.rep("ok", 100), 200)
end)
check("preempted busy loop still returns", function()
  local n = 0 for i = 1, 200000 do n = n + i % 7 end
  assert(n > 0)
end)
check("app.sleep(300) ~ 300 ms", function()
  local t0 = system.millis(); app.sleep(300); local dt = system.millis() - t0
  assert(dt >= 290 and dt < 900, dt)
end)
check("coroutines + pcall + string/utf8/math libs", function()
  local co = coroutine.wrap(function(a) local b = coroutine.yield(a + 1) return b * 2 end)
  eq(co(1), 2); eq(co(21), 42)
  eq(utf8.len("caf\xc3\xa9"), 4); eq(("%5.2f"):format(math.pi), " 3.14"); eq(math.type(3 // 2), "integer")
end)

-- speed benchmark: simple VM loop iterations per second
local t0 = system.millis()
local acc = 0
for i = 1, 300000 do acc = acc + (i & 255) end
local ms = math.max(1, system.millis() - t0)
local speed = ("bench: 300k loop iters in %d ms (~%dk/s)"):format(ms, 300000 // ms)
print(speed)
local used, peak, cap = system.lua_mem()
local free, minfree = system.heap()
local memline = ("lua %dK used / %dK peak / %dK cap | free %dK (min %dK)"):format(used // 1024, peak // 1024, cap // 1024, free // 1024, minfree // 1024)
print(memline)

local w, h = gfx.size()
local lh = gfx.line_height("small") + 2
gfx.clear()
gfx.text(w // 2, 10, failed == 0 and "ALL PASSED" or (failed .. " FAILED"), "ui12", "bc")
local y = 10 + gfx.line_height("ui12") + 10
for _, r in ipairs(results) do
  gfx.text(10, y, r:sub(1, 60), "small", r:sub(1, 4) == "FAIL" and "b" or "")
  y = y + lh
end
y = y + 6
gfx.text(10, y, speed, "small"); y = y + lh
gfx.text(10, y, memline, "small")
gfx.text(w // 2, h - 30, "Back: quit", "small", "c")
gfx.present("half")
while input.wait() ~= "back" do end
