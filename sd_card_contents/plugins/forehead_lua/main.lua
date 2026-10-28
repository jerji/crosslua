-- FOREHEAD. The device is held against the forehead with the screen facing out, so the holder cannot see the word.
-- Everyone else gives clues. The holder presses:
--   Up   = GOT IT   (+1, next word)
--   Down = PASS     (no point, next word)
-- A round lasts 60 seconds. Back during a round ends it early and shows the score; Back on the score screen returns to
-- the category menu; Back on the menu exits. Words are read from words.txt in this app folder (category blocks
-- start with "@Title"); the words are curated from published party-game lists (see the crossplay doc, section 5).

local ROUND_MS = 60000
local TICK_MS = 1000

local categories = {}   -- { { title = "...", words = { ... } }, ... }

local function load_words()
  local text = fs.read("app:words.txt") or ""
  local cur = nil
  for line in text:gmatch("[^\n]+") do
    line = line:gsub("\r$", "")
    local t = line:match("^@(.+)$")
    if t then cur = { title = t, words = {} }; categories[#categories + 1] = cur
    elseif cur and line ~= "" then cur.words[#cur.words + 1] = line end
  end
end

local function rnd(n)
  local ok, b = pcall(crypto.random, 2)
  if ok and type(b) == "string" and #b == 2 then return (b:byte(1) * 256 + b:byte(2)) % n + 1 end
  return math.random(n)
end

local W, H = 0, 0

local function clip(s, n) return #s > n and s:sub(1, n) or s end

local function draw_menu(sel, note)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Forehead", "ui12", "bw")
  local y = 60
  for i, c in ipairs(categories) do
    if i > 15 then break end
    local label = clip(c.title, 26) .. "  (" .. #c.words .. ")"
    if i == sel then gfx.rect(10, y - 4, W - 20, 30, true); gfx.text(16, y, label, "ui12", "w")
    else gfx.text(16, y, label, "ui12") end
    y = y + 32
  end
  gfx.text(14, H - 60, note or "", "small")
  gfx.text(14, H - 34, "Up/Down choose, Confirm starts 60 seconds, Back exits", "small")
  gfx.present()
end

-- wrap a word into lines of at most `maxw` pixels, in sans18
local function wrap(word, maxw)
  local lines, cur = {}, ""
  for w in word:gmatch("%S+") do
    local try = (cur == "") and w or (cur .. " " .. w)
    if gfx.text_width(try, "sans18") <= maxw or cur == "" then cur = try
    else lines[#lines + 1] = cur; cur = w end
  end
  if cur ~= "" then lines[#lines + 1] = cur end
  return lines
end

local function draw_round(word, got, left_ms, note)
  gfx.clear(); W, H = gfx.size()
  gfx.text(14, 10, "GOT " .. got, "ui12", "b")
  local secs = math.max(0, math.floor(left_ms / 1000))
  gfx.text(W - 110, 10, string.format("%02d", secs) .. " s", "ui12", "b")
  gfx.rect(14, 44, W - 28, 10, false)
  local fillw = math.floor((W - 32) * (left_ms / ROUND_MS))
  if fillw > 0 then gfx.rect(16, 46, fillw, 6, true) end
  local lines = wrap(word or "", W - 40)
  local lh = gfx.line_height("sans18")
  local total = #lines * (lh + 8)
  local y = (H - total) // 2 - 40
  for _, l in ipairs(lines) do
    gfx.text(W // 2, y, l, "sans18", "c")
    y = y + lh + 8
  end
  gfx.text(14, H - 80, "UP = GOT IT          DOWN = PASS", "ui12", "b")
  gfx.text(14, H - 50, note or "", "small")
  gfx.text(14, H - 30, "Back ends the round early", "small")
  gfx.present()
end

local function draw_score(got, passed, cat_title)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Round over", "ui12", "bw")
  gfx.text(W // 2, 200, cat_title, "ui12", "c")
  gfx.text(W // 2, 280, "Got " .. got, "sans18", "c")
  gfx.text(W // 2, 340, "Passed " .. passed, "ui12", "c")
  gfx.text(14, H - 34, "Back returns to the menu", "small")
  gfx.present()
end

local function run_round(cat)
  local words = cat.words
  local used = {}
  local got, passed = 0, 0
  local function next_word()
    if #used >= #words then used = {} end
    local i
    repeat i = rnd(#words) until not used[i]
    used[i] = true
    return words[i]
  end
  local start = system.millis()
  local word = next_word()
  local note = ""
  while true do
    local elapsed = system.millis() - start   -- 31-bit wrap: subtraction is correct
    local left = ROUND_MS - elapsed
    if left <= 0 then break end
    draw_round(word, got, left, note)
    local e = input.wait(math.min(TICK_MS, left))
    if e == "back" then break
    elseif e == "up" then got = got + 1; word = next_word(); note = ""
    elseif e == "down" then passed = passed + 1; word = next_word(); note = ""
    end
  end
  draw_score(got, passed, cat.title)
  while input.wait() ~= "back" do end
end

local ok, err = pcall(function()
  W, H = gfx.size()
  load_words()
  if #categories == 0 then
    gfx.clear(); gfx.text(14, 80, "No words.txt found in the app.", "ui12"); gfx.present()
    while input.wait() ~= "back" do end
    return
  end
  local sel = 1
  draw_menu(sel, "")
  while true do
    local e = input.wait()
    if e == "back" then break
    elseif e == "up" then sel = sel > 1 and sel - 1 or #categories
    elseif e == "down" then sel = sel < #categories and sel + 1 or 1
    elseif e == "confirm" then run_round(categories[sel])
    end
    draw_menu(sel, "")
  end
end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
