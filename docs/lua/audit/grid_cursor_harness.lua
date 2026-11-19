-- Headless grid-mode cursor harness (no device). Usage: lua5.4 grid_cursor_harness.lua <app_dir>
-- Runs the app's main.lua against mocked device/gfx/input/app/system and checks the cursor.
local appDir = arg[1] or "."
package.path = appDir .. "/?.lua;" .. package.path

local queue, rrects, modes, drawn_y = {}, {}, {}, {}
local ev_log = {}
local screenMode = nil

device = { input_mode = function(m) modes[#modes + 1] = m end,
           caps = function() return {} end }
gfx = {
  size = function() return 480, 800 end,
  clear = function() rrects = {} end,
  present = function() end,
  rect = function() end,
  rounded_rect = function(x, y, w, h, r, a, b) rrects[#rrects + 1] = {x, y, w, h, r, a, b} end,
  text = function() end,
  text_width = function(s) return #s * 8 end,
  image = function() end,
}
input = {
  wait = function(_)
    local e = table.remove(queue, 1)
    if e == nil then return "back" end   -- queue drained: leave the app
    ev_log[#ev_log + 1] = e
    return e
  end,
  pos = function() return nil end,
}
app = { exit = function() end }
system = { millis = function() return 0 end }

-- Lip cursor: the selected column's disc is the only filled disc at the lip's y.
-- LIP row: lipTop=76, SLOT_H=42 -> cy=97, LIP_R=16 -> y=81, w=h=32; LEFT=(480-448)/2=16.
local LEFT, CELL, LIP_Y = 16, 64, 81
local function lipCursorCol()
  local found, ys = nil, {}
  for _, r in ipairs(rrects) do
    local x, y, w, h, rad, fill, border = table.unpack(r)
    if w == 32 and h == 32 and rad == 16 then
      ys[y] = true
      if fill and border then found = (x + 16 - LEFT - 32) // CELL + 1 end
    end
  end
  local n = 0; for _ in pairs(ys) do n = n + 1 end
  return found, n   -- column, number of distinct lip rows drawn (1 = no vertical movement)
end

local function run(events, label)
  queue = events; rrects = {}; ev_log = {}
  local f = assert(loadfile(appDir .. "/main.lua"))
  local trace = {}
  -- instrument: after each redraw we want the cursor; capture by wrapping present
  local present = gfx.present
  gfx.present = function()
    local c, nrows = lipCursorCol()
    trace[#trace + 1] = {c, nrows}
    present()
  end
  f()
  gfx.present = present
  return trace
end

local fails = 0
local function check(name, cond)
  print(string.format("%-58s %s", name, cond and "PASS" or "FAIL"))
  if not cond then fails = fails + 1 end
end

-- Start on the menu: confirm = PLAY (column cursor starts at 4).
local t = run({"confirm", "left", "left", "left", "left", "right", "right", "right", "back", "back"}, "left/right")
print("input_mode calls:", table.concat(modes, ","))
local function colAt(i) return t[i][1] end
check("device.input_mode('grid') is called", modes[1] == "grid")
-- trace[1] = menu, trace[2] = board after confirm (sel=4)
check("board opens with cursor on column 4", colAt(2) == 4)
check("left moves cursor left (4->3)", colAt(3) == 3)
check("left moves cursor left (3->2)", colAt(4) == 2)
check("left moves cursor left (2->1)", colAt(5) == 1)
check("left at column 1 wraps to 7 (documented wrap)", colAt(6) == 7)
check("right moves cursor right (7 wraps to 1)", colAt(7) == 1)
check("right moves cursor right (1->2)", colAt(8) == 2)
check("right moves cursor right (2->3)", colAt(9) == 3)
local vertical_ok = true
for i = 2, #t do if t[i][2] ~= 1 then vertical_ok = false end end
check("lip row never moves vertically (one lip row each frame)", vertical_ok)

-- Vertical events must not move the cursor (grid mode never delivers them on X4 Pro; still inert in app).
local t2 = run({"confirm", "up", "down", "up", "down", "back", "back"}, "vertical")
local stable = true
for i = 2, #t2 do if t2[i][1] ~= 4 then stable = false end end
check("up/down events leave the cursor on column 4", stable)

print(string.format("RESULT: %s (%d failing)", fails == 0 and "ALL PASS" or "FAILURES", fails))
os.exit(fails == 0 and 0 or 1)
