-- hub test: xml.parse on the real device (expat). Pure logic, no radio, no card.
local function __test()
print("== xml.parse")
local W, H = gfx.size()
local lines, fails = {}, 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  local l = (cond and "PASS " or "FAIL ") .. name
  lines[#lines + 1] = l
  print(l .. (extra and (" " .. tostring(extra)) or ""))
end

local r = xml.parse('<feed><title>My Feed</title><entry id="1"><title>Post</title><link href="http://x"/></entry></feed>')
check("root tag", r and r.tag == "feed", r and r.tag)
check("attrs table", type(r.attrs) == "table")
check("title child", r and r[1] and r[1].tag == "title" and r[1][1] == "My Feed")
check("entry attrs", r and r[2] and r[2].tag == "entry" and r[2].attrs.id == "1")
check("entry title", r and r[2] and r[2][1].tag == "title" and r[2][1][1] == "Post")
check("entry link", r and r[2] and r[2][2].tag == "link" and r[2][2].attrs.href == "http://x")
local m = xml.parse('<t>a<![CDATA[b]]>c</t>')
check("cdata merge", m.tag == "t" and m[1] == "abc")
local w = xml.parse('<t>line 1<b>bold</b>line 2</t>')
check("whitespace + nested", w[1] == "line 1" and w[3] == "line 2" and w[2].tag == "b" and w[2][1] == "bold")
local ok, err = xml.parse('<a><b></a>')
check("malformed -> nil,err", ok == nil and type(err) == "string", err)
local ok2, err2 = xml.parse('')
check("empty -> nil,err", ok2 == nil and type(err2) == "string", err2)

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "xml test", "ui12", "b"); gfx.line(0, 44, W - 1, 44)
for i, s in ipairs(lines) do gfx.text(12, 52 + (i - 1) * 24, s, "small") end
gfx.text(W // 2, H - 34, fails == 0 and "ALL PASSED  (Back: quit)" or (fails .. " FAILED  (Back: quit)"), "small", "c")
gfx.present("full")
while input.wait() ~= "back" do end
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
-- no radio used: back to the hub menu (no reboot)
app.restart("main.lua")