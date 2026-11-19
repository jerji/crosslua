-- Headless touch-tap check for totp_lua in grid mode (no device).
-- Usage: lua5.4 totp_grid_touch_harness.lua <app_dir> <head|zoned>
--   head  : firmware as committed at HEAD (every tap -> "confirm", grid mode or not)
--   zoned : firmware as in the uncommitted working tree (grid mode: top third -> up,
--           bottom third -> down, middle third -> confirm)
-- Physical buttons in grid mode: Up -> "left", Down -> "right" (both HEAD and working tree).
-- The vault is mocked (PIN "123456", three accounts); everything else in main.lua runs as shipped.
local appDir, MODE = arg[1] or ".", arg[2] or "head"
package.path = appDir .. "/?.lua;" .. package.path

local SCREEN_W, SCREEN_H = 480, 800
local TOP, ROW_H = 52, 96           -- main.lua list geometry
local DB = {accounts = {
  {name = "Alpha", issuer = "a", secret = "JBSWY3DPEHPK3PXP", digits = 6, period = 30, alg = "SHA1"},
  {name = "Bravo", issuer = "b", secret = "JBSWY3DPEHPK3PXP", digits = 6, period = 30, alg = "SHA1"},
  {name = "Charlie", issuer = "c", secret = "JBSWY3DPEHPK3PXP", digits = 6, period = 30, alg = "SHA1"},
}}

-- ---- firmware model -------------------------------------------------------
local grid, queue, pos_x, pos_y, trace, title, sel_row, titles_seen
local function tap_to_event(x, y)
  if not grid or MODE == "head" then return "confirm" end
  if y < SCREEN_H / 3 then return "up" end
  if y >= 2 * SCREEN_H / 3 then return "down" end
  return "confirm"
end
local function button_to_event(b)              -- physical buttons: Up/Down are left/right in grid mode
  if grid then return b == "up" and "left" or "right" end
  return b
end

-- ---- mocks ----------------------------------------------------------------
local registry, nreg = {}, 0
local function clone(t)
  if type(t) ~= "table" then return t end
  local o = {}; for k, v in pairs(t) do o[k] = clone(v) end; return o
end
json = {
  encode = function(t) nreg = nreg + 1; registry[nreg] = clone(t); return "J" .. nreg end,
  decode = function(s) local i = tonumber(tostring(s):match("^J(%d+)$")); return i and clone(registry[i]) or nil end,
}
crypto = {hmac_sha1 = function() return string.rep("\0", 20) end}   -- codes are not checked here
time = {now = function() return 59 end}
system = {millis = function() return 0 end}
fs = {read = function() return nil end, remove = function() end}
app = {exit = function() end}
device = {input_mode = function(m) grid = (m == "grid") end, caps = function() return {} end}
gfx = {
  size = function() return SCREEN_W, SCREEN_H end,
  clear = function() sel_row = nil; title = nil; titles = {} end,
  rect = function(x, y, w, h, fill)
    if x == 0 and w == 8 then sel_row = (y - TOP) // ROW_H + 1 end
  end,
  rounded_rect = function() end,
  text = function(x, y, s) if y == 14 and not title then title = s end end,
  text_width = function(s) return #s * 8 end,
  image = function() end,
  present = function()
    trace[#trace + 1] = {title = title, sel = (title == "Authenticator") and sel_row or nil}
    if title then titles_seen[title] = true end
  end,
}
input = {
  wait = function()
    local e = table.remove(queue, 1)
    if e == nil then return "back" end          -- queue drained: leave the app
    if type(e) == "table" then                  -- {tap = x, y}
      pos_x, pos_y = e.x, e.y
      return tap_to_event(e.x, e.y)
    end
    pos_x, pos_y = nil, nil
    if e == "PHYS_UP" then return button_to_event("up") end
    if e == "PHYS_DOWN" then return button_to_event("down") end
    return e
  end,
  text = function() return "123456" end,        -- PIN entry (only used by the vault mock)
  pos = function() return pos_x, pos_y end,
}
package.preload.vault = function()
  local V = {MIN_PIN = 4, MAX_PIN = 64}
  function V.exists() return true end
  function V.unlock()
    local v = {data = json.encode(DB)}
    function v.save() return true end
    function v.lock() end
    return v
  end
  return V
end

-- ---- run one scenario -----------------------------------------------------
local function run(events, forced_grid)
  grid = forced_grid; queue = events; trace = {}; titles_seen = {}; title, sel_row = nil, nil
  local f = assert(loadfile(appDir .. "/main.lua"))
  local ok, err = pcall(f)
  if not ok then print("  APP ERROR: " .. tostring(err)) end
  -- the list's selection is the last present while the list header is shown
  local last_sel
  for _, s in ipairs(trace) do if s.title == "Authenticator" and s.sel then last_sel = s.sel end end
  return {sel = last_sel, menu = titles_seen["Menu"] == true}
end

local fails = 0
local function check(name, got, want)
  local ok = got == want
  if not ok then fails = fails + 1 end
  print(string.format("%-62s got=%-8s want=%-8s %s", name, tostring(got), tostring(want), ok and "PASS" or "FAIL"))
end

local TAP_ROW3 = {x = 240, y = TOP + 2 * ROW_H + 40}   -- centre of row 3 on the list
local TAP_BOTTOM = {x = 240, y = 700}                   -- bottom third
local TAP_TOP = {x = 240, y = 100}                      -- top third
local TAP_MID = {x = 240, y = 400}                      -- middle third

print("== firmware model: " .. MODE .. " ==")

-- 1. nav mode (totp's shipped state): tap on row 3 is a confirm, not a select.
local r = run({{tap = TAP_ROW3.x, y = TAP_ROW3.y}}, false)
check("nav: tap on row 3 leaves row 1 selected", r.sel, 1)
check("nav: tap on row 3 opens the Menu instead", r.menu, true)

-- 2. grid mode forced (what the task asked for): tap bottom third twice.
r = run({{tap = TAP_BOTTOM.x, y = TAP_BOTTOM.y}, {tap = TAP_BOTTOM.x, y = TAP_BOTTOM.y}}, true)
local expect_bottom = (MODE == "zoned") and 3 or 1
check("grid: 2x tap bottom third -> selected row", r.sel, expect_bottom)

-- 3. grid mode: two bottom taps to row 3, then a top-third tap steps back to row 2.
r = run({{tap = TAP_BOTTOM.x, y = TAP_BOTTOM.y}, {tap = TAP_BOTTOM.x, y = TAP_BOTTOM.y}, {tap = TAP_TOP.x, y = TAP_TOP.y}}, true)
check("grid: bottom, bottom, top taps -> selected row", r.sel, (MODE == "zoned") and 2 or 1)

-- 3b. grid mode: physical Down (= right in grid mode) does not move the list.
check("grid: physical Down (=right) does not move the list", run({"PHYS_DOWN"}, true).sel, 1)

-- 4. grid mode: tap in the middle third opens the Menu, and keeps the row.
r = run({{tap = TAP_MID.x, y = TAP_MID.y}}, true)
check("grid: middle-third tap opens the Menu", r.menu, true)
check("grid: middle-third tap keeps row 1 selected", r.sel, 1)

-- 5. grid mode: no tap lands on a row number directly. Row 3's centre still only moves one step per tap.
r = run({{tap = TAP_ROW3.x, y = TAP_ROW3.y}}, true)
check("grid: tap on row 3 centre (middle third) -> Menu, not row 3", r.sel, 1)

print("FAILS: " .. fails)
