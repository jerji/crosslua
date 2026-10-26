-- Hub for on-device test scripts: every .lua in app:tests/ appears in this menu; adding a test is dropping a file there.
-- Selecting one does app.restart("tests/<name>.lua"): the test runs in a FRESH VM (lean heap, nothing left over from the
-- menu or the previous test) and restarts back here when it ends (each test file is wrapped to do that, also after an
-- early return or an error). The menu remembers the last selection in data:last.txt. Back exits to Home.
local files = fs.list("app:tests") or {}
local names = {}
for _, n in ipairs(files) do
  if type(n) == "string" and n:sub(-4) == ".lua" then names[#names + 1] = n end
end
table.sort(names)
local w, h = gfx.size()
if #names == 0 then
  gfx.clear(); gfx.text(10, 10, "Lua tests: no test files", "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
  return
end
local sel = 1
local last = fs.read("data:last.txt")
if last then
  last = last:gsub("%s+$", "")
  for i, n in ipairs(names) do if n == last then sel = i end end
end
local function draw(note)
  gfx.clear()
  gfx.text(w // 2, 20, "Lua tests (" .. #names .. ")", "ui12", "bc")
  if note then gfx.text(w // 2, h - 70, note, "small", "c") end
  gfx.text(w // 2, h - 40, "up/down choose   confirm run   back exit", "small", "c")
  local lh = gfx.line_height("ui12")
  for i = 1, #names do
    local y = 60 + (i - 1) * (lh + 10)
    if y > h - 110 then gfx.text(w // 2, h - 100, "...", "ui12", "c"); break end
    gfx.text(24, y, ((i == sel) and "> " or "  ") .. names[i]:sub(1, -5), "ui12", i == sel and "b" or "")
  end
  gfx.present()
end
draw()
while true do
  local e = input.wait()
  if e == "back" then break end
  if e == "up" and sel > 1 then sel = sel - 1; draw()
  elseif e == "down" and sel < #names then sel = sel + 1; draw()
  elseif e == "confirm" then
    fs.write("data:last.txt", names[sel])
    print("[hub] restart into tests/" .. names[sel])
    local ok, err = app.restart("tests/" .. names[sel])
    if not ok then draw("restart failed: " .. tostring(err)) end
  end
end
