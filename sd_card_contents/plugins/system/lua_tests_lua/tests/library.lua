-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
local function __test()
-- Diagnostics for the library API: sd: scope, zip, app.open_book.  Confirm = run, Right = open the sample in the reader.
-- Put an EPUB at /crosslua_test/sample.epub on the SD card first.
local W, H = gfx.size()
local lines = {}
local FONT = "small"
local LH = gfx.line_height(FONT) + 2
local MAXL = (H - 100) // LH
local BOOK = "sd:crosslua_test/sample.epub"

local function draw(hint)
  gfx.clear()
  gfx.text(16, 10, "Library test", "ui12", "b")
  gfx.line(0, 44, W - 1, 44)
  local first = math.max(1, #lines - MAXL + 1)
  for i = first, #lines do gfx.text(12, 52 + (i - first) * LH, lines[i], FONT) end
  gfx.text(W // 2, H - 34, hint or "Confirm: run   Right: open book   Back: quit", FONT, "c")
  gfx.present("fast")
end
local function log(s) lines[#lines + 1] = s; print(s); draw("working...") end
local function mem(tag)
  collectgarbage()
  local free, minfree, big = system.heap()
  log(("%s: free %dK min %dK big %dK lua %dK"):format(tag, free // 1024, minfree // 1024, big // 1024, system.lua_mem() // 1024))
end

local function run()
  lines = {}
  mem("start")
  local root = fs.list("sd:")
  if not root then log("fs.list(sd:) failed"); return end
  local dirs, files = 0, 0
  for _, n in ipairs(root) do if n:sub(-1) == "/" then dirs = dirs + 1 else files = files + 1 end end
  log(("sd: root has %d folders, %d files (no dot-names: %s)"):format(dirs, files, tostring(not table.concat(root, "|"):find("|%.") and root[1]:sub(1, 1) ~= ".")))
  -- the sandbox must refuse hidden paths on the REAL card
  log("hidden .crosspoint read: " .. tostring(select(2, fs.read("sd:.crosspoint/settings.json"))))
  log("write to sd: " .. tostring(select(2, fs.write("sd:crosslua_test/x.txt", "x"))))
  local list, total = zip.list(BOOK)
  if not list then log("zip.list failed: " .. tostring(total)); return end
  log(("zip: %d entries"):format(total))
  for i = 1, math.min(#list, 8) do log(("  %s (%d B)"):format(list[i].name, list[i].size)) end
  mem("after list")
  local cont, err = zip.read(BOOK, "META-INF/container.xml")
  log("container.xml: " .. (cont and (#cont .. " B") or tostring(err)))
  local opfPath = cont and cont:match('full%-path="([^"]+)"')
  log("opf path: " .. tostring(opfPath))
  local opf, err2 = opfPath and zip.read(BOOK, opfPath)
  if not opf then log("opf: " .. tostring(err2)); return end
  log(("opf: %d B, title=%s"):format(#opf, tostring(opf:match("<dc:title[^>]*>([^<]*)"))))
  log("creator=" .. tostring(opf:match("<dc:creator[^>]*>([^<]*)")))
  local subj = 0
  for _ in opf:gmatch("<dc:subject>") do subj = subj + 1 end
  log("subjects: " .. subj)
  -- first spine page = the AO3 preface with labeled tags
  local first = opf:match('<itemref idref="([^"]+)"')
  local href = first and opf:match('<item id="' .. first .. '" href="([^"]+)"')
  local page = href and zip.read(BOOK, href)
  if page then
    log(("preface %s: %d B"):format(href, #page))
    log("fandom: " .. tostring(page:match("Fandom:</dt>%s*<dd[^>]*>.-<a[^>]*>([^<]*)")))
    log("words: " .. tostring(page:match("Words:%s*([%d,]+)")) .. "  chapters: " .. tostring(page:match("Chapters:%s*([%d/%?]+)")))
  else
    log("preface read failed")
  end
  mem("end")
end

draw()
while true do
  local ev = input.wait()
  if ev == "back" then return end
  if ev == "confirm" then run(); draw("Confirm: again   Right: open book   Back: quit") end
  if ev == "right" then
    local ok, why = app.open_book(BOOK)       -- on success this never returns
    log("open_book failed: " .. tostring(why))
    draw()
  end
end
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
app.restart("main.lua")
