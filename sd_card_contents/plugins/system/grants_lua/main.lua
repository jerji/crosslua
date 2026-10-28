-- On-device checks for per-folder storage grants. The manifest asks to READ /spells and WRITE /crosslua_grants and has NO
-- "library" permission: everything outside those two folders must stay out of reach.
local W, H = gfx.size()
local lines, fails = {}, 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  local l = (cond and "PASS " or "FAIL ") .. name
  lines[#lines + 1] = l
  print(l .. (extra and (" " .. tostring(extra)) or ""))
end

local d = "sd:crosslua_grants"
check("write inside the write grant", fs.write(d .. "/a.txt", "hello") == true)
check("read it back", fs.read(d .. "/a.txt") == "hello")
check("append inside the grant", fs.append(d .. "/a.txt", "!") == true and fs.read(d .. "/a.txt") == "hello!")
check("rename inside the grant", fs.rename(d .. "/a.txt", d .. "/b.txt") == true and fs.read(d .. "/b.txt") == "hello!")
local l = fs.list(d); check("list the granted folder", l and #l == 1 and l[1] == "b.txt", l and l[1])
check("read-only grant readable", fs.exists("sd:spells/example_spell.lua") and fs.read("sd:spells/example_spell.lua", 0, 8) ~= nil)
local ok, e = fs.write("sd:spells/evil.lua", "x"); check("read grant is not writable", ok == nil, e)
ok, e = fs.read("sd:crosslua_test/sample.epub"); check("other folder unreadable", ok == nil and e:find("outside the folders granted", 1, true), e)
ok, e = fs.list("sd:"); check("card root not listable", ok == nil, e)
ok, e = fs.read("sd:.crosspoint/settings.json"); check("hidden folder refused", ok == nil and e:find("hidden", 1, true), e)
ok, e = fs.write(d .. "/fw.bin", "x"); check("firmware image refused", ok == nil and e:find("firmware images", 1, true), e)
ok, e = fs.write("sd:plugins/evil/main.lua", "x"); check("plugins folder unreachable", ok == nil, e)
ok, e = fs.write("sd:crosslua_grantsX/z.txt", "x"); check("prefix boundary", ok == nil, e)
check("remove inside the grant", fs.remove(d .. "/b.txt") == true and not fs.exists(d .. "/b.txt"))
fs.remove(d)
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))

gfx.clear()
gfx.text(16, 10, "Grants test", "ui12", "b"); gfx.line(0, 44, W - 1, 44)
for i, s in ipairs(lines) do gfx.text(12, 52 + (i - 1) * 24, s, "small") end
gfx.text(W // 2, H - 34, fails == 0 and "ALL PASSED  (Back: quit)" or (fails .. " FAILED  (Back: quit)"), "small", "c")
gfx.present("full")
while input.wait() ~= "back" do end
