-- Player (no radio). A face is three words: hair, eyes, mouth. Each word has a 48 px row icon and a 120 px
-- portrait, drawn one on top of the other (base head, then the three parts). Art and word lists come from
-- crossplay's PlayerAvatarArt.h / PlayerAvatar.cpp, converted into faces.bin / faces.idx / words.txt here.
-- Bit convention (FreeInk Icon): bit 0 = draw black, bit 1 = transparent, rows MSB first.
--
-- Controls: Up/Down choose the slot, Left/Right change the word (wraps), Confirm saves the name to
-- data:name.txt, Back exits. A saved name is loaded next time.
-- Names are three word indices, not the crossplay wire format; the wire format is not in this build.

local N_WORDS = 14
local SLOTS = { "hair", "eyes", "mouth" }
local WORDS = {}           -- WORDS[slot] = { "BALD", ... }
local idx = {}             -- idx["hair_BALD_120"] = { w, h, off, len }
local SAVE = "data:name.txt"

local W, H = 0, 0

local function txt_or_nil(s) return s end

local function load_tables()
  local words = fs.read("app:words.txt") or ""
  for line in words:gmatch("[^\n]+") do
    local slot, rest = line:match("^(%S+) (.*)$")
    if slot then
      WORDS[slot] = {}
      for w in rest:gmatch("%S+") do WORDS[slot][#WORDS[slot] + 1] = w end
    end
  end
  local index = fs.read("app:faces.idx") or ""
  for line in index:gmatch("[^\n]+") do
    local key, w, h, off, len = line:match("^(%S+) (%d+) (%d+) (%d+) (%d+)$")
    if key then idx[key] = { w = tonumber(w), h = tonumber(h), off = tonumber(off), len = tonumber(len) } end
  end
end

-- draw one icon at (x, y) in its own size; `size` is 48 or 120
local function draw_layer(key, x, y)
  local e = idx[key]
  if not e then return end
  local bits = fs.read("app:faces.bin", e.off, e.len)
  if not bits then return end
  local rb = (e.w + 7) // 8
  for r = 0, e.h - 1 do
    local row = r * rb
    for c = 0, e.w - 1 do
      local byte = bits:byte(row + c // 8 + 1)
      if ((byte >> (7 - c % 8)) & 1) == 0 then gfx.pixel(x + c, y + r, true) end
    end
  end
end

local function draw_face(x, y, size, picks)
  draw_layer("base_" .. size, x, y)
  for s, slot in ipairs(SLOTS) do
    local word = WORDS[slot][picks[s]]
    if word then draw_layer(slot .. "_" .. word .. "_" .. size, x, y) end
  end
end

local function load_name()
  local s = fs.read(SAVE)
  if not s then return nil end
  local a, b, c = s:match("^(%d+)\n(%d+)\n(%d+)")
  if not a then return nil end
  return { tonumber(a) + 1, tonumber(b) + 1, tonumber(c) + 1 }
end

local function draw(picks, cur, note)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Player", "ui12", "bw")
  draw_face(40, 60, 120, picks)
  draw_face(260, 60, 48, picks)
  gfx.text(260, 130, "row size", "small")
  local y = 260
  for s, slot in ipairs(SLOTS) do
    local word = WORDS[slot][picks[s]] or "?"
    local label = string.format("%-6s %s", slot, word)
    if s == cur then gfx.rect(10, y - 4, W - 20, 30, true); gfx.text(18, y, label, "ui12", "w")
    else gfx.text(18, y, label, "ui12") end
    y = y + 40
  end
  gfx.text(14, H - 60, note or "", "small")
  gfx.text(14, H - 34, "Up/Down slot, Left/Right word, Confirm = save, Back = exit", "small")
  gfx.present()
end

local ok, err = pcall(function()
  W, H = gfx.size()
  load_tables()
  local picks = load_name() or { math.random(N_WORDS), math.random(N_WORDS), math.random(N_WORDS) }
  local cur, note = 1, ""
  draw(picks, cur, note)
  while true do
    local e = input.wait()
    if e == "back" then break
    elseif e == "up" then cur = cur > 1 and cur - 1 or #SLOTS; note = ""
    elseif e == "down" then cur = cur < #SLOTS and cur + 1 or 1; note = ""
    elseif e == "left" then picks[cur] = picks[cur] > 1 and picks[cur] - 1 or N_WORDS; note = ""
    elseif e == "right" then picks[cur] = picks[cur] < N_WORDS and picks[cur] + 1 or 1; note = ""
    elseif e == "confirm" then
      local ok2 = fs.write(SAVE, string.format("%d\n%d\n%d\n", picks[1] - 1, picks[2] - 1, picks[3] - 1))
      note = ok2 and "saved" or "could not save"
    end
    draw(picks, cur, note)
  end
end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
