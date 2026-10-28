-- 2048 for the X4.  Left/Right/Up/Down = slide (Up/Down are the side buttons).  Confirm = undo.  Back = menu.
local game = require("game")

local W, H = gfx.size()
local HINT_H = 72
math.randomseed(system.millis())

local g = game.new()
local best = 0
local menu_open, over_shown = false, false

-- ---------------------------------------------------------------- persistence
local function save()
  fs.write("data:state.json", json.encode({ g = game.save_table(g), best = best }))
end

do
  local raw = fs.read("data:state.json")
  local st = raw and json.decode(raw)
  if type(st) == "table" then
    if math.type(st.best) == "integer" and st.best > 0 then best = st.best end
    if st.g and game.restore(g, st.g) then g.rng = math.random end
  end
end
if g.score > best then best = g.score end

-- ---------------------------------------------------------------- drawing
local presents = 0
local function present()
  presents = presents + 1
  gfx.present(presents % 12 == 0 and "half" or "fast")      -- a cleaner refresh every few moves
end

local GAP = 8
local BOARD = W - 32
local CELL = (BOARD - 5 * GAP) // 4
local BX, BY = 16, 84

local function tile(x, y, e)
  if e == 0 then gfx.rect(x + CELL // 2 - 2, y + CELL // 2 - 2, 4, 4, true); return end
  local v = 1 << e
  local label = tostring(v)
  local font = (v < 100 and "sans18") or (v < 1000 and "sans16") or "sans14"
  local filled = e >= 5                                       -- 32 and up are solid black
  gfx.rect(x, y, CELL, CELL, filled)
  if e >= 3 and not filled then gfx.rect(x + 3, y + 3, CELL - 6, CELL - 6) end   -- 8 and 16: double border
  if e >= 11 then gfx.rect(x + 4, y + 4, CELL - 8, CELL - 8, false, false) end   -- 2048+: white inner frame
  local lh = gfx.line_height(font)
  gfx.text(x + CELL // 2, y + (CELL - lh) // 2, label, font, (filled and "bwc" or "bc"))
end

local function draw()
  gfx.clear()
  gfx.text(16, 12, "2048", "ui", "b")
  gfx.text(W - 16, 8, "Score " .. g.score, "ui12", "br")
  gfx.text(W - 16, 8 + gfx.line_height("ui12") + 2, "Best " .. best, "small", "r")
  for r = 0, 3 do
    for c = 0, 3 do
      tile(BX + GAP + c * (CELL + GAP), BY + GAP + r * (CELL + GAP), g.b[r * 4 + c + 1])
    end
  end
  local ty = BY + BOARD + 14
  gfx.text(W // 2, ty, "Moves " .. g.moves, "small", "c")
  if g.over then
    gfx.text(W // 2, ty + 28, "No moves left!", "ui12", "bc")
    gfx.text(W // 2, ty + 56, "Confirm: new game", "small", "c")
  elseif g.just_won then
    gfx.text(W // 2, ty + 28, "You made 2048!", "ui12", "bc")
    gfx.text(W // 2, ty + 56, "Keep going - any move", "small", "c")
  end
  -- hint bar: Back, Confirm, Left, Right (the four front buttons)
  local y, cw = H - HINT_H, W // 4
  gfx.line(0, y, W, y)
  local labels = { "Menu", g.over and "New" or "Undo", "Left", "Right" }
  for i = 1, 4 do
    gfx.rect((i - 1) * cw + 6, y + 8, cw - 12, HINT_H - 16)
    gfx.text((i - 1) * cw + cw // 2, y + 22, labels[i], "ui12", "c")
  end
  gfx.text(W // 2, y - 22, "Up / Down: side buttons", "small", "c")
  present()
end

local function draw_menu(sel)
  gfx.clear()
  gfx.text(16, 12, "2048", "ui", "b")
  gfx.line(0, 44, W, 44)
  local items = { "Resume", "New game", "Exit" }
  for i, it in ipairs(items) do
    local y = 100 + (i - 1) * 70
    local on = i == sel
    if on then gfx.rect(16, y, W - 32, 56, true) end
    gfx.text(36, y + 14, it, "ui12", on and "bw" or "b")
  end
  gfx.text(W // 2, 100 + 3 * 70 + 10, "Best " .. best, "small", "c")
  local y, cw = H - HINT_H, W // 4
  gfx.line(0, y, W, y)
  local labels = { "Back", "Select", "Prev", "Next" }
  for i = 1, 4 do
    gfx.rect((i - 1) * cw + 6, y + 8, cw - 12, HINT_H - 16)
    gfx.text((i - 1) * cw + cw // 2, y + 22, labels[i], "ui12", "c")
  end
  present()
end

-- ---------------------------------------------------------------- main loop
local function new_game()
  g = game.new()
  save()
end

local MOVES = { left = "left", right = "right", up = "up", down = "down" }

draw()
while true do
  local ev = input.wait()
  if menu_open then
    local sel = menu_open
    if ev == "up" or ev == "left" then sel = (sel - 2) % 3 + 1
    elseif ev == "down" or ev == "right" then sel = sel % 3 + 1
    elseif ev == "back" then menu_open = false
    elseif ev == "confirm" then
      if sel == 1 then menu_open = false
      elseif sel == 2 then new_game(); menu_open = false
      else return end
    end
    if menu_open then menu_open = sel; draw_menu(sel) else draw() end
  else
    if MOVES[ev] then
      g.just_won = false
      if game.move(g, MOVES[ev]) then
        if g.score > best then best = g.score end
        save()
      end
      draw()
    elseif ev == "confirm" then
      if g.over then new_game() elseif game.undo(g) then save() end
      draw()
    elseif ev == "back" then
      menu_open = 1
      draw_menu(1)
    end
  end
end
