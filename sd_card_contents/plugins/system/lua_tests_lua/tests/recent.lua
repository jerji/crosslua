-- hub test: epub.recent() surfaces the ereader's own shelf; then epub.progress() on a real recent book.
local function __test()
print("== epub.recent + progress")
local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  print((cond and "PASS " or "FAIL ") .. name .. (extra and (" " .. tostring(extra)) or ""))
end

local r = epub.recent()
check("returns a table", type(r) == "table", "count=" .. tostring(#r))
for i, b in ipairs(r) do
  print("  [" .. i .. "] " .. tostring(b.path) .. " | " .. tostring(b.title) .. " | " .. tostring(b.author))
  check("book " .. i .. " path is sd:", type(b.path) == "string" and b.path:sub(1, 3) == "sd:", tostring(b.path))
  check("book " .. i .. " title is string", type(b.title) == "string", tostring(b.title))
end

-- chained: progress on the first recent book (the real happy path)
if #r > 0 then
  local p, e = epub.progress(r[1].path)
  if p ~= nil then
    check("first recent book percent " .. tostring(p), type(p) == "number" and p >= 0 and p <= 100, r[1].path)
  else
    check("first recent book (no progress) -> nil,err", type(e) == "string", tostring(e))
  end
end

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, (fails == 0 and "epub.recent OK" or "epub.recent FAILED"), "ui12", "b")
for i, b in ipairs(r) do
  if i <= 10 then gfx.text(12, 30 + (i - 1) * 24, (b.title or "?"):sub(1, 34), "small") end
end
gfx.present("full")
while input.wait() ~= "back" do end
end
local _o, _e = pcall(__test); if not _o then print("ERR " .. tostring(_e)) end
app.restart("main.lua")