-- Host-side checks for ao3_lua's pure logic (no device, no gfx/input).
-- Run from anywhere:  lua5.4 tests/host_test.lua
-- Covers: works.txt parsing, navigate-page chapter count, title, the index
-- record layout and hash, the EPUB scraper (zip stubbed), the UTF-8 clip, and
-- a headless walk of the home grid -> AO3 menu -> shelf -> QR path with stub
-- device globals.

local tests_dir = (arg[0]:match("^(.*)/[^/]*$")) or "."
local here = tests_dir .. "/.."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path

local fails, passes = 0, 0
local function check(name, cond, detail)
  if cond then passes = passes + 1
  else fails = fails + 1; print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or "")) end
end

-- ---- ao3/works.lua -------------------------------------------------------
do
  local W = require("ao3.works")
  local list = W.parse_works("12345\n# comment\n\nhttps://archiveofourown.org/works/777/chapters/1 | My fic\n12345\n  99 |  \n")
  check("works count", #list == 3, #list)
  check("works id", list[1].id == "12345" and list[1].label == nil)
  check("works url+label", list[2].id == "777" and list[2].label == "My fic")
  check("works trailing label empty", list[3].id == "99" and list[3].label == nil)
  check("navigate url", W.navigate_url("5"):find("/works/5/navigate", 1, true) ~= nil)
  check("download url", W.download_url("5") == "https://archiveofourown.org/downloads/5/work.epub")
  check("book path", W.book_path("5") == "sd:Books/AO3/5.epub")
  local html = "<a href='/works/5/chapters/1'>1</a> /works/5/chapters/2 /works/5/chapters/2 /works/6/chapters/9"
  check("chapter count dedupes and filters id", W.chapter_count(html, "5") == 2, W.chapter_count(html, "5"))
  check("work title", W.work_title('<h2 class="title heading">Fish &amp; Chips</h2>') == "Fish & Chips")
  check("work title missing", W.work_title("<p>none</p>") == nil)
end

-- ---- ao3/index.lua record layout ----------------------------------------
do
  local I = require("ao3.index")
  check("fnv1a empty", I.fnv1a("") == 0x811C9DC5)
  check("fnv1a 'a'", I.fnv1a("a") == 0xE40C292C, string.format("%x", I.fnv1a("a")))
  local rec = I.pack({ hash = 1, size = 2, words = 3, chapters = 4, completed = true,
    rating = "T", warning = "-", updated = "2026-01-02", title = string.rep("é", 40),
    author = "x", fandom = "y", name = "n.epub" })
  check("record is 256 bytes", #rec == 256, #rec)
  local hash, size, words, chapters, flags = string.unpack("<I4I4I4I2B", rec)
  check("record fields", hash == 1 and size == 2 and words == 3 and chapters == 4 and flags == 2)
end

-- ---- ui.lua clip_bytes ----------------------------------------------------
do
  -- ui.lua only touches gfx when a function is called, so it loads here.
  local ui = require("ui")
  check("clip_bytes ascii", ui.clip_bytes("abcdef", 4) == "abcd")
  check("clip_bytes keeps whole char", ui.clip_bytes(string.rep("é", 5), 3) == "é")
  check("clip_bytes short", ui.clip_bytes("ok", 10) == "ok")
end

-- ---- ao3/scrape.lua with a stubbed zip ---------------------------------
do
  local files = {
    ["book.epub"] = true,
  }
  local entries = {
    ["META-INF/container.xml"] = '<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>',
    ["OEBPS/content.opf"] = '<package><metadata><dc:title>Lamp &amp; Hat</dc:title>'
      .. '<dc:creator>Writer</dc:creator></metadata><manifest>'
      .. '<item id="t" href="title.xhtml"/><item id="c1" href="c1.xhtml"/></manifest>'
      .. '<spine><itemref idref="t"/><itemref idref="c1"/></spine></package>',
    ["OEBPS/title.xhtml"] = '<div class="preface"><p><strong>Rating:</strong> Teen And Up Audiences</p>'
      .. '<p><strong>Archive Warning:</strong> No Archive Warnings Apply</p>'
      .. '<p><strong>Fandoms:</strong> Star Wars</p><p><strong>Words:</strong> 12,345</p>'
      .. '<p><strong>Chapters:</strong> 3/3</p><p><strong>Updated:</strong> 2026-01-02</p></div>',
  }
  zip = { read = function(path, entry)
    if files[path] and entries[entry] then return entries[entry] end
    return nil, "no such entry"
  end }
  local S = require("ao3.scrape")
  local m, err = S.scrape("book.epub", "fallback")
  check("scrape ok", m ~= nil, err)
  if m then
    check("scrape title", m.title == "Lamp & Hat", m.title)
    check("scrape author", m.author == "Writer", m.author)
    check("scrape words", m.words == 12345, m.words)
    check("scrape chapters", m.chapters == 3 and m.completed == true, m.chapters)
    check("scrape rating", m.rating == "T", m.rating)
    check("scrape warning", m.warning == "-", m.warning)
    check("scrape fandom", m.fandom == "Star Wars", m.fandom)
    check("scrape updated", m.updated == "2026-01-02", m.updated)
  end
  local bad, why = S.scrape("nope.epub", "x")
  check("scrape rejects non-epub", bad == nil and why ~= nil)
  zip = nil
end

-- ---- headless UI walk ----------------------------------------------------
-- Stub the device, script button presses, and check the app ends cleanly
-- with no error screen. Path: hold Confirm (AO3 menu), open Continue
-- reading, Back, open Page as QR, Confirm (QR view), Back, Back (menu),
-- Back (grid), exit.
do
  local presses, drawn, exited = {}, {}, false
  local function feed(list) for _, e in ipairs(list) do presses[#presses + 1] = e end end
  local books = {
    { path = "sd:Books/a.epub", title = "Alpha", author = "A" },
    { path = "sd:Books/b.epub", title = "Beta", author = "" },
  }
  gfx = {
    size = function() return 480, 800 end,
    clear = function() drawn = {} end,
    rect = function() end,
    text = function(_, _, s) drawn[#drawn + 1] = tostring(s) end,
    text_width = function(s) return #tostring(s) * 8 end,
    line_height = function() return 20 end,
    wrap = function(s) return { tostring(s) } end,
    present = function() end,
    qr = function() return true end,
  }
  input = { wait = function()
    local e = table.remove(presses, 1)
    if not e then error("headless: input script exhausted") end
    return e
  end }
  app = { exit = function() exited = true end, open_book = function() return false, "stub" end }
  epub = {
    library = function(off, lim) return { books[1], books[2] }, 2 end,
    progress = function(p) return p == "sd:Books/a.epub" and 40.4 or nil, "none" end,
    recent = function() return books end,
  }
  feed({ "confirm_hold", "confirm", "back", "down", "confirm", "confirm", "back", "back", "back", "back" })
  local ok, err = pcall(dofile, here .. "/main.lua")
  check("headless walk no crash", ok, err)
  check("headless walk exits", exited)
  check("headless walk no error screen", (function()
    for _, s in ipairs(drawn) do if s:find("^err:") then return false end end
    return true
  end)())
  check("headless walk consumed script", #presses == 0, #presses)
end

print(string.format("%d passed, %d failed", passes, fails))
if fails > 0 then os.exit(1) end
