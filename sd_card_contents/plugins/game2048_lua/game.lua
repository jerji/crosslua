-- 2048 rules. Pure Lua, no device APIs (unit-tested on the host).
-- The board is 16 numbers, row-major, each the EXPONENT of the tile (0 = empty, 1 = "2", 2 = "4", ... 11 = "2048").
local G = {}

-- For each direction, the 4 lines of cell indices, ordered from the wall the tiles slide towards.
local LINES = { left = {}, right = {}, up = {}, down = {} }
for k = 0, 3 do
  LINES.left[k + 1] = { k * 4 + 1, k * 4 + 2, k * 4 + 3, k * 4 + 4 }
  LINES.right[k + 1] = { k * 4 + 4, k * 4 + 3, k * 4 + 2, k * 4 + 1 }
  LINES.up[k + 1] = { k + 1, k + 5, k + 9, k + 13 }
  LINES.down[k + 1] = { k + 13, k + 9, k + 5, k + 1 }
end

-- rng(n) -> integer 1..n (math.random by default); tests pass a scripted one.
function G.new(rng)
  local g = { b = {}, score = 0, moves = 0, rng = rng or math.random, won = false, over = false }
  for i = 1, 16 do g.b[i] = 0 end
  G.spawn(g)
  G.spawn(g)
  return g
end

function G.spawn(g)
  local empty, n = {}, 0
  for i = 1, 16 do
    if g.b[i] == 0 then n = n + 1; empty[n] = i end
  end
  if n == 0 then return false end
  g.b[empty[g.rng(n)]] = (g.rng(10) == 1) and 2 or 1     -- 90% "2", 10% "4"
  return true
end

-- Slide one line towards its start. Returns new line, points gained, whether anything changed.
-- Each tile merges at most once per move: [2,2,4,0] -> [4,4,0,0], [2,2,2,2] -> [4,4,0,0].
local function slide(l1, l2, l3, l4)
  local src, n = {}, 0
  for _, v in ipairs({ l1, l2, l3, l4 }) do
    if v ~= 0 then n = n + 1; src[n] = v end
  end
  local out, m, gained, i = {}, 0, 0, 1
  while i <= n do
    if src[i] == src[i + 1] then
      m = m + 1; out[m] = src[i] + 1; gained = gained + (1 << (src[i] + 1)); i = i + 2
    else
      m = m + 1; out[m] = src[i]; i = i + 1
    end
  end
  for j = m + 1, 4 do out[j] = 0 end
  return out, gained, (out[1] ~= l1 or out[2] ~= l2 or out[3] ~= l3 or out[4] ~= l4)
end
G.slide = slide

function G.can_move(g)
  local b = g.b
  for i = 1, 16 do
    if b[i] == 0 then return true end
    if i % 4 ~= 0 and b[i] == b[i + 1] then return true end
    if i <= 12 and b[i] == b[i + 4] then return true end
  end
  return false
end

-- Apply a move. Returns true if the board changed (a new tile is then spawned). Keeps ONE level of undo.
function G.move(g, dir)
  local lines = LINES[dir]
  if not lines or g.over then return false end
  local nb, gained, changed = {}, 0, false
  for _, ln in ipairs(lines) do
    local out, gn, ch = slide(g.b[ln[1]], g.b[ln[2]], g.b[ln[3]], g.b[ln[4]])
    for k = 1, 4 do nb[ln[k]] = out[k] end
    gained = gained + gn
    changed = changed or ch
  end
  if not changed then return false end
  g.prev = { b = g.b, score = g.score, moves = g.moves, won = g.won }
  g.b = nb
  g.score = g.score + gained
  g.moves = g.moves + 1
  G.spawn(g)
  if not g.won and G.max_exp(g) >= 11 then g.won = true; g.just_won = true end
  g.over = not G.can_move(g)
  return true, gained
end

function G.undo(g)
  if not g.prev then return false end
  g.b, g.score, g.moves, g.won = g.prev.b, g.prev.score, g.prev.moves, g.prev.won
  g.prev, g.over, g.just_won = nil, false, false
  return true
end

function G.max_exp(g)
  local m = 0
  for i = 1, 16 do if g.b[i] > m then m = g.b[i] end end
  return m
end

-- Saved form (small and validated on load: the file lives on a card anyone can edit).
function G.save_table(g) return { b = g.b, s = g.score, m = g.moves, w = g.won } end

function G.restore(g, t)
  if type(t) ~= "table" or type(t.b) ~= "table" or #t.b ~= 16 then return false end
  local sum = 0
  for i = 1, 16 do
    local v = t.b[i]
    if math.type(v) ~= "integer" or v < 0 or v > 17 then return false end
    sum = sum + v
  end
  if sum == 0 or math.type(t.s) ~= "integer" or t.s < 0 then return false end
  g.b, g.score = t.b, t.s
  g.moves = math.type(t.m) == "integer" and t.m or 0
  g.won = t.w == true
  g.prev, g.just_won = nil, false
  g.over = not G.can_move(g)
  return true
end

return G
