-- Murdle (v1): a case is generated on the device from a random seed (core.lua). Three screens, Left/Right switch:
--   CLUES  : the murder clue and the direct clues. Up/Down scroll.
--   MARKS  : a grid of suspects against weapons, and against locations. Up/Down pick a row, Left/Right a column,
--            Confirm cycles the mark (blank -> yes -> no -> blank).
--   ACCUSE : Up/Down pick the murderer, Confirm; then pick the weapon, Confirm; the murderer's location is the crime room.
-- Back returns to the tier menu, Back again exits. Cases are not saved in v1.
-- Tiers: ELEMENTARY (3x3), NOSY (4x4). HARD BOILED and IMPOSSIBLE are not in this build (see the crossplay doc, section 1).

local core = require("core")

local W, H = 0, 0
local SCREENS = { "CLUES", "MARKS", "ACCUSE" }
local TIERS = { { label = "ELEMENTARY (3x3)", tier = "elementary" }, { label = "NOSY (4x4)", tier = "nosy" } }

local function clip(s, n) return #s > n and s:sub(1, n) or s end

local function new_seed()
  local ok, b = pcall(crypto.random, 4)
  if ok and type(b) == "string" and #b == 4 then
    return b:byte(1) * 16777216 + b:byte(2) * 65536 + b:byte(3) * 256 + b:byte(4)
  end
  return math.random(1, 2000000000)
end

local function draw_menu(sel, note)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Murdle", "ui12", "bw")
  for i, t in ipairs(TIERS) do
    local y = 80 + (i - 1) * 40
    if i == sel then gfx.rect(10, y - 4, W - 20, 30, true); gfx.text(16, y, t.label, "ui12", "w")
    else gfx.text(16, y, t.label, "ui12") end
  end
  gfx.text(14, H - 60, note or "", "small")
  gfx.text(14, H - 34, "Up/Down choose, Confirm starts a new case, Back exits", "small")
  gfx.present()
end

local function header(case, screen_i)
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, "Murdle " .. (case.tier == "nosy" and "NOSY" or "ELEMENTARY"), "ui12", "bw")
  gfx.text(W - 14, 10, SCREENS[screen_i], "ui12", "rbw")
end

local function draw_clues(case, scroll, sid)
  gfx.clear(); W, H = gfx.size(); header(case, sid)
  local lines = { core.murder_text(case) }
  -- the rooms legend: the murder clue names a fixture, so every room's fixture has to be on screen
  local legend = {}
  for l = 1, case.k do legend[#legend + 1] = core.CAST.locations[l] .. " = " .. core.CAST.fixtures[l] end
  lines[#lines + 1] = "ROOMS: " .. table.concat(legend, ", ")
  for _, c in ipairs(case.clues) do lines[#lines + 1] = core.clue_text(c) end
  local y = 56
  for i = scroll, math.min(#lines, scroll + 11) do
    gfx.text(14, y, clip(i - 1 .. ". " .. lines[i], 56), "ui12")
    y = y + 34
  end
  gfx.text(14, H - 60, string.format("%d clues  (Up/Down scroll)", #case.clues), "small")
  gfx.text(14, H - 34, "Left/Right switch screen, Back returns to the menu", "small")
  gfx.present()
end

local function draw_marks(case, st, sid)
  gfx.clear(); W, H = gfx.size(); header(case, sid)
  local k = case.k
  local function table_at(base_row, title, names, mk)
    gfx.text(14, base_row, title, "small", "b")
    local cw = 104
    local x0 = 120
    for x = 1, k do gfx.text(x0 + (x - 1) * cw, base_row, clip(names[x], 9), "small") end
    for s = 1, k do
      local r = base_row + 22 + (s - 1) * 26
      gfx.text(14, r, clip(core.CAST.suspects[s], 8), "small")
      for x = 1, k do
        local v = mk[s][x]
        local label = (v == "y") and "YES" or (v == "n") and "no" or "."
        local cx = x0 + (x - 1) * cw
        local cursor = (st.row == (title == "WEAPONS" and s or (k + s))) and (st.col == x)
        if cursor then gfx.rect(cx - 3, r - 3, cw - 6, 22, true); gfx.text(cx, r, label, "small", "w")
        else gfx.text(cx, r, label, "small") end
      end
    end
  end
  table_at(56, "WEAPONS", core.CAST.weapons, st.sw)
  table_at(56 + 22 + k * 26 + 14, "LOCATIONS", core.CAST.locations, st.sl)
  gfx.text(14, H - 60, "Confirm cycles the mark. YES/no are yours, not checked.", "small")
  gfx.text(14, H - 34, "Up/Down row, Left/Right column, Left/Right switch screen", "small")
  gfx.present()
end

local function draw_accuse(case, st, sid, note)
  gfx.clear(); W, H = gfx.size(); header(case, sid)
  gfx.text(14, 56, "Who did it?", "ui12", "b")
  for s = 1, case.k do
    local y = 90 + (s - 1) * 34
    local label = core.CAST.suspects[s] .. ((st.suspect == s) and "  (chosen)" or "")
    if st.phase == "suspect" and st.cur == s then gfx.rect(10, y - 4, W - 20, 30, true); gfx.text(16, y, label, "ui12", "w")
    else gfx.text(16, y, label, "ui12") end
  end
  if st.phase == "weapon" or st.phase == "done" then
    gfx.text(14, 250, "With which weapon?", "ui12", "b")
    for w = 1, case.k do
      local y = 280 + (w - 1) * 34
      local label = core.CAST.weapons[w] .. ((st.weapon == w) and "  (chosen)" or "")
      if st.phase == "weapon" and st.cur == w then gfx.rect(10, y - 4, W - 20, 30, true); gfx.text(16, y, label, "ui12", "w")
      else gfx.text(16, y, label, "ui12") end
    end
  end
  gfx.text(14, H - 60, note or "", "small")
  gfx.text(14, H - 34, "Up/Down choose, Confirm to accuse, Left/Right switch screen", "small")
  gfx.present()
end

local function run_case(tier)
  local seed = new_seed()
  local case, why = core.generate(seed, tier)
  if not case then
    gfx.clear(); gfx.text(14, 80, "Could not build a case:", "ui12"); gfx.text(14, 110, tostring(why), "small"); gfx.present()
    while input.wait() ~= "back" do end
    return
  end
  local sw, sl = {}, {}
  for s = 1, case.k do sw[s], sl[s] = {}, {} end
  local st = { row = 1, col = 1, sw = sw, sl = sl, scroll = 1, phase = "suspect", cur = 1, suspect = nil, weapon = nil }
  local sid, scroll = 1, 1
  local note = ""
  local function redraw()
    if SCREENS[sid] == "CLUES" then draw_clues(case, scroll, sid)
    elseif SCREENS[sid] == "MARKS" then draw_marks(case, st, sid)
    else draw_accuse(case, st, sid, note) end
  end
  redraw()
  while true do
    local e = input.wait()
    if e == "back" then return end
    if e == "left" and SCREENS[sid] ~= "MARKS" or (e == "left" and SCREENS[sid] == "MARKS" and st.col == 1) then
      sid = sid > 1 and sid - 1 or #SCREENS
    elseif e == "right" and SCREENS[sid] ~= "MARKS" or (e == "right" and SCREENS[sid] == "MARKS" and st.col == case.k) then
      sid = sid < #SCREENS and sid + 1 or 1
    elseif SCREENS[sid] == "CLUES" then
      local total = #case.clues + 2
      if e == "up" then scroll = math.max(1, scroll - 1)
      elseif e == "down" then scroll = math.min(math.max(1, total - 11), scroll + 1) end
    elseif SCREENS[sid] == "MARKS" then
      if e == "up" then st.row = math.max(1, st.row - 1)
      elseif e == "down" then st.row = math.min(2 * case.k, st.row + 1)
      elseif e == "left" then st.col = math.max(1, st.col - 1)
      elseif e == "right" then st.col = math.min(case.k, st.col + 1)
      elseif e == "confirm" then
        local tab, s = (st.row <= case.k) and st.sw or st.sl, (st.row <= case.k) and st.row or (st.row - case.k)
        local v = tab[s][st.col]
        tab[s][st.col] = (v == nil) and "y" or ((v == "y") and "n" or nil)
      end
    else -- ACCUSE
      if st.phase == "suspect" then
        if e == "up" then st.cur = math.max(1, st.cur - 1)
        elseif e == "down" then st.cur = math.min(case.k, st.cur + 1)
        elseif e == "confirm" then st.suspect = st.cur; st.phase = "weapon"; st.cur = 1; note = "Now the weapon." end
      elseif st.phase == "weapon" then
        if e == "up" then st.cur = math.max(1, st.cur - 1)
        elseif e == "down" then st.cur = math.min(case.k, st.cur + 1)
        elseif e == "confirm" then
          st.weapon = st.cur
          local right = (st.suspect == case.murderer) and (st.weapon == case.sol.wp[case.murderer])
          st.phase = "done"
          note = right and "Correct. Case closed." or ("Wrong. The murderer was " .. core.CAST.suspects[case.murderer] .. ", with the " .. core.CAST.weapons[case.sol.wp[case.murderer]] .. ".")
        end
      end
    end
    redraw()
  end
end

local ok, err = pcall(function()
  W, H = gfx.size()
  local sel = 1
  draw_menu(sel, "")
  while true do
    local e = input.wait()
    if e == "back" then break
    elseif e == "up" then sel = sel > 1 and sel - 1 or #TIERS
    elseif e == "down" then sel = sel < #TIERS and sel + 1 or 1
    elseif e == "confirm" then run_case(TIERS[sel].tier)
    end
    draw_menu(sel, "")
  end
end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
