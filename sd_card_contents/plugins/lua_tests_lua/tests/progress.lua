-- hub test: epub.progress on the real firmware (happy path is device-only: a real book's progress.bin).
local function __test()
print("== epub.progress")
local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  local l = (cond and "PASS " or "FAIL ") .. name
  print(l .. (extra and (" " .. tostring(extra)) or ""))
end

-- missing book: the firmware's -1 maps to nil, "no saved progress for this book"
local p, e = epub.progress("sd:Books/__crosslua_no_such_book__.epub")
check("missing book -> nil,err", p == nil and type(e) == "string", tostring(e) or "")

-- bad extension gate
local g, ge = epub.progress("sd:Books/__x__.txt")
check("bad ext -> nil,err", g == nil and ge == "not a .epub or .xtc book", tostring(ge))

-- a real book (if any) returns a number 0..100 or a clean nil,err
local ok, books = pcall(fs.list, "sd:Books")
local found = false
if ok and books then
  for _, f in ipairs(books) do
    local lf = f:lower()
    if lf:sub(-5) == ".epub" or lf:sub(-4) == ".xtc" then
      found = true
      local pp, ee = epub.progress("sd:Books/" .. f)
      if pp ~= nil then
        check("real book -> percent " .. tostring(pp), type(pp) == "number" and pp >= 0 and pp <= 100, f)
      else
        check("real book (no progress) -> nil,err", type(ee) == "string", f .. " / " .. tostring(ee))
      end
      break
    end
  end
end
if not found then print("  (no .epub/.xtc in sd:Books on this device)") end

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, (fails == 0 and "epub.progress OK" or "epub.progress FAILED"), "ui12", "b")
if found then
  local ls = books
  local any = "no books"
  for _, f in ipairs(ls or {}) do local lf = f:lower(); if lf:sub(-5) == ".epub" then any = f; break end end
  if any ~= "no books" then
    local pp = epub.progress("sd:Books/" .. any)
    gfx.text(16, 44, any:sub(1, 30), "small")
    gfx.text(16, 76, "progress = " .. tostring(pp), "small")
  end
end
gfx.present("full")
while input.wait() ~= "back" do end
end
local _ok2, _err = pcall(__test)
if not _ok2 then
  print("[hub] ERROR: " .. tostring(_err))
  gfx.clear(); gfx.text(10, 10, "Test error", "ui12", "b"); gfx.text(10, 50, tostring(_err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
app.restart("main.lua")