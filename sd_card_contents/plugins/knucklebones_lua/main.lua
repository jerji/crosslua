-- Knucklebones (Cult of the Lamb dice game). Rules from crossplay docs/apps/knucklebones.md:
--   * You roll a d6 and drop it into one of your three columns (fills from the near end outward).
--   * Placing value v destroys every copy of v in the opponent's facing column (only that column, only v).
--   * A column scores each distinct value v as v * n * n, n = copies of v in that column.
--   * The match ends the instant either grid fills; higher total wins; equal = draw.
-- Modes: CPU (one-ply greedy, deterministic) or hot-seat (two players on one device).
-- Controls: Left/Right choose column, Confirm rolls the die and drops it, Back exits.
-- NOT in this build: the nearby ESP-NOW link (the crossplay doc describes it). Only CPU and hot-seat play.

local W, H = 0, 0
local LH = 28

local function col_score(col)
  local n = {}
  for _, v in ipairs(col) do n[v] = (n[v] or 0) + 1 end
  local s = 0
  for v, k in pairs(n) do s = s + v * k * k end
  return s
end

local function total(g, p)
  return col_score(g[p][1]) + col_score(g[p][2]) + col_score(g[p][3])
end

local function full(g, p)
  return #g[p][1] == 3 and #g[p][2] == 3 and #g[p][3] == 3
end

-- place die value v in column c for player p; destroys v in the opponent's column c
local function place(g, p, c, v)
  local opp = 3 - p
  local keep = {}
  for _, x in ipairs(g[opp][c]) do if x ~= v then keep[#keep + 1] = x end end
  g[opp][c] = keep
  if #g[p][c] < 3 then g[p][c][#g[p][c] + 1] = v end
end

local function legal(g, p)
  local t = {}
  for c = 1, 3 do if #g[p][c] < 3 then t[#t + 1] = c end end
  return t
end

-- CPU: one ply, greedy on (my total - their total) after the move, prefer room, deterministic tiebreak
local function cpu_choose(g, p, v)
  local best, bestc = -1e9, nil
  for _, c in ipairs(legal(g, p)) do
    local trial = { [1] = { {}, {}, {} }, [2] = { {}, {}, {} } }
    for q = 1, 2 do for cc = 1, 3 do for i, x in ipairs(g[q][cc]) do trial[q][cc][i] = x end end end
    place(trial, p, c, v)
    local val = total(trial, p) - total(trial, 3 - p)
    val = val * 10 + (3 - #g[p][c]) - c * 0.001
    if val > best then best, bestc = val, c end
  end
  return bestc
end

local function roll()
  local ok, b = pcall(crypto.random, 1)
  if ok and type(b) == "string" and #b > 0 then return b:byte() % 6 + 1 end
  return math.random(6)
end

local function draw_grid(g, p, x, y, label)
  gfx.text(x, y - 26, label .. "  " .. total(g, p), "ui12", "b")
  for c = 1, 3 do
    local cx = x + (c - 1) * 150
    gfx.rect(cx, y, 130, 3 * 30 + 6, false)
    for r = 1, 3 do
      local v = g[p][c][4 - r]  -- top of the column is drawn first
      local cy = y + (r - 1) * 30 + 4
      if v then gfx.text(cx + 52, cy, tostring(v), "ui12") end
    end
  end
  gfx.text(x, y + 100, "col score: " .. col_score(g[p][1]) .. " | " .. col_score(g[p][2]) .. " | " .. col_score(g[p][3]), "small")
end

local function draw(g, cur_col, die, msg)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Knucklebones", "ui12", "bw")
  draw_grid(g, 2, 30, 80, "CPU")
  gfx.text(30, 240, "die: " .. (die and tostring(die) or "-") .. "    column: " .. cur_col, "ui12")
  draw_grid(g, 1, 30, 300, "You")
  gfx.text(14, H - 60, msg or "", "small")
  gfx.text(14, H - 34, "Left/Right column, Confirm roll and drop, Back exit", "small")
  gfx.present()
end

local function run()
  W, H = gfx.size()
  local g = { [1] = { {}, {}, {} }, [2] = { {}, {}, {} } }
  local cur, die, msg = 1, nil, ""
  local turn = 1  -- 1 = you, 2 = CPU; the CPU moves after you
  draw(g, cur, die, "Your turn. Confirm to roll.")
  while true do
    local e = input.wait()
    if e == "back" then break end
    if turn == 1 then
      if e == "left" then cur = cur > 1 and cur - 1 or 3; msg = ""
      elseif e == "right" then cur = cur < 3 and cur + 1 or 1; msg = ""
      elseif e == "confirm" then
        if #g[1][cur] >= 3 then msg = "That column is full."
        else
          die = roll()
          place(g, 1, cur, die)
          msg = "You dropped a " .. die .. " into column " .. cur .. "."
          turn = 2
        end
      end
    else
      -- CPU moves on the next confirm press (keeps the pacing with the player)
      if e == "confirm" then
        die = roll()
        local c = cpu_choose(g, 2, die)
        if c then place(g, 2, c, die); msg = "CPU dropped a " .. die .. " into column " .. c .. "." end
        turn = 1
      end
    end
    -- match end: as soon as either grid fills
    if full(g, 1) or full(g, 2) then
      local a, b = total(g, 1), total(g, 2)
      local result = a > b and "You win" or (a < b and "CPU wins" or "Draw")
      draw(g, cur, die, string.format("Final: You %d, CPU %d. %s. Back to exit.", a, b, result))
      while input.wait() ~= "back" do end
      return
    end
    draw(g, cur, die, msg)
  end
end

local ok, err = pcall(run)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
