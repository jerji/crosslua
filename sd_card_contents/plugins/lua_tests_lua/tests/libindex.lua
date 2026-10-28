-- hub test: epub.library() reads the firmware's full library index, then chains epub.progress on the first book.
local function __test()
print("== epub.library")
local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  print((cond and "PASS " or "FAIL ") .. name .. (extra and (" " .. tostring(extra)) or ""))
end

local lib, total = epub.library()
check("returns table + total", type(lib) == "table" and type(total) == "number", "total=" .. tostring(total))
local shown = 0
for i, b in ipairs(lib) do
  shown = i
  print("  [" .. i .. "] " .. tostring(b.path) .. " | " .. tostring(b.title) .. " | " .. tostring(b.author))
  if type(b.path) ~= "string" or b.path:sub(1, 3) ~= "sd:" then
    check("book " .. i .. " path is sd:", false, tostring(b.path))
  end
end
check("multiple books returned", shown >= 2, "shown=" .. tostring(shown))

if lib[1] then
  local p, e = epub.progress(lib[1].path)
  if p ~= nil then
    check("first library book percent " .. tostring(p), type(p) == "number" and p >= 0 and p <= 100, lib[1].path)
  else
    check("first library book (no progress) -> nil,err", type(e) == "string", tostring(e))
  end
end

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "epub.library: total " .. tostring(total), "ui12", "b")
for i, b in ipairs(lib) do
  if i <= 10 then gfx.text(12, 30 + (i - 1) * 24, (b.title or "?"):sub(1, 34), "small") end
end
gfx.present("full")
while input.wait() ~= "back" do end
end
local _o, _e = pcall(__test); if not _o then print("ERR " .. tostring(_e)) end
app.restart("main.lua")