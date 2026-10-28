-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
-- fs.stat and fs.list{detail, offset, limit} on the real card. No WiFi needed. The mtime values are PRINTED, not asserted:
-- the firmware sets no FAT timestamp callback, so what a file written on the device carries is exactly what this test reports.
local function __test()
print("== fs.stat / fs.list detail")
local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  print((cond and "PASS " or "FAIL ") .. name .. (extra and (" " .. tostring(extra)) or ""))
end

-- start clean (an earlier aborted run may have left files)
for _, n in ipairs(fs.list("data:st") or {}) do
  if n:sub(-1) == "/" then
    for _, m in ipairs(fs.list("data:st/" .. n:sub(1, -2)) or {}) do fs.remove("data:st/" .. n .. m) end
  end
  fs.remove("data:st/" .. n)
end

check("write a.txt", fs.write("data:st/a.txt", "12345") == true)
check("write b.txt", fs.write("data:st/b.txt", "xyz") == true)
check("write sub/x.txt", fs.write("data:st/sub/x.txt", "q") == true)

print("== fs.stat")
local a = fs.stat("data:st/a.txt")
check("stat a.txt size/dir", a and a.size == 5 and a.dir == false, a and ("size=" .. a.size .. " dir=" .. tostring(a.dir)))
print("INFO a.txt mtime = " .. tostring(a and a.mtime) .. "  (time.now() = " .. tostring(time.now()) .. ")")
local d = fs.stat("data:st/sub")
check("stat folder", d and d.dir == true and d.size == 0, d and ("size=" .. d.size))
local nf, nerr = fs.stat("data:st/missing")
check("stat missing", nf == nil and nerr == "no such file", tostring(nerr))
local ro = fs.stat("app:main.lua")
check("stat app:main.lua matches fs.size", ro and ro.size == fs.size("app:main.lua") and ro.dir == false, ro and ro.size)
print("INFO app:main.lua mtime = " .. tostring(ro and ro.mtime))
local sd = fs.stat("data:")
check("stat data: is a folder", sd and sd.dir == true)

print("== fs.list")
local plain = fs.list("data:st")
check("plain list unchanged (sorted, folders end in /)", table.concat(plain, ",") == "a.txt,b.txt,sub/", table.concat(plain, ","))
local t, total = fs.list("data:st", {detail = true})
check("detail window", #t == 3 and total == 3 and t[1].name == "a.txt" and t[1].size == 5 and t[2].size == 3
  and t[3].name == "sub" and t[3].dir == true, #t .. "/" .. tostring(total))
local w, wt = fs.list("data:st", {offset = 1, limit = 1})
check("names window", #w == 1 and w[1] == "b.txt" and wt == 3, tostring(w[1]) .. "/" .. tostring(wt))

print("== paging a 40-entry folder")
for i = 0, 39 do fs.write(("data:st/p/f%02d"):format(i), tostring(i)) end
local p1, tot = fs.list("data:st/p", {detail = true})
check("first page = 32 of 40", #p1 == 32 and tot == 40 and p1[1].name == "f00" and p1[32].name == "f31", #p1 .. "/" .. tostring(tot))
local p2 = fs.list("data:st/p", {detail = true, offset = 32})
check("second page = last 8", #p2 == 8 and p2[1].name == "f32" and p2[8].name == "f39", #p2)
check("detail sizes are real", p2[3].size == 2 and p1[1].size == 1)
local before = system.heap()
local big = fs.list("data:st/p", {detail = true, limit = 64})
local after = system.heap()
check("limit 64 returns all 40", #big == 40)
print(("INFO heap while holding a 40-entry detail table: %d -> %d (%d bytes)"):format(before, after, before - after))

print("== option errors")
local _, e1 = fs.list("data:st", {limit = 65, detail = true})
check("detail limit capped at 64", e1 == "limit must be an integer 1..64", tostring(e1))
local _, e2 = fs.list("data:st", {colour = 1})
check("unknown option refused", e2 == "unknown option 'colour'", tostring(e2))

-- clean up
for i = 0, 39 do fs.remove(("data:st/p/f%02d"):format(i)) end
fs.remove("data:st/p")
fs.remove("data:st/sub/x.txt"); fs.remove("data:st/sub"); fs.remove("data:st/a.txt"); fs.remove("data:st/b.txt"); fs.remove("data:st")
check("cleaned up", fs.exists("data:st") == false)

print("== fs.rmdir (recursive)")
fs.write("data:st/nest/a.txt", "a")
fs.write("data:st/nest/deep/b.txt", "b")
fs.write("data:st/keep.txt", "keep")
check("nest exists (2 levels deep)", fs.exists("data:st/nest") and fs.exists("data:st/nest/deep/b.txt"))
local rm, rmerr = fs.remove("data:st/nest")
check("fs.remove refuses non-empty", rm == nil and rmerr == "cannot remove (directories must be empty)", tostring(rmerr))
check("fs.rmdir recursive", fs.rmdir("data:st/nest") == true)
check("nest gone, keep intact", fs.exists("data:st/nest") == false and fs.exists("data:st/keep.txt") == true)
local _, e3 = fs.rmdir("data:st/keep.txt")
check("rmdir on a file refused", e3 == "not a directory (use fs.remove)", tostring(e3))
local _, e4 = fs.rmdir("data:st/nope")
check("rmdir missing", e4 == "no such file or directory", tostring(e4))
fs.remove("data:st/keep.txt")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "fs.stat test", "ui12", "b")
gfx.text(16, 60, fails == 0 and "ALL PASSED" or (fails .. " FAILED"), "ui12")
gfx.text(16, 100, "see the serial log for details", "small")
gfx.present("full")
app.sleep(1200)
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
-- no radio used: back to the hub menu (no reboot)
app.restart("main.lua")
