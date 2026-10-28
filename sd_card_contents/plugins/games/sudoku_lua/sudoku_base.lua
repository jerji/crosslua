-- sudoku.lua : the rules, pure. No device API, so it runs under plain lua5.4
-- for host tests and under the app for play. Port of the C++ SudokuCore.
--
-- The one promise: a puzzle is exactly as hard as its label says, by
-- construction. The dig is driven by a bounded technique solver, so a puzzle
-- can never need a technique above its band; carve() grades what it made and
-- generate() discards anything that does not grade as asked. Uniqueness is a
-- by-product: a puzzle a solver drove to completion was forced at every step.

local M = {}

local KALL = 0x1FF

local function bitFor(d) return 1 << (d - 1) end
local function popcount(m)
  local c = 0
  while m ~= 0 do m = m & (m - 1) c = c + 1 end
  return c
end
local function lowestDigit(m)
  for d = 1, 9 do if (m & bitFor(d)) ~= 0 then return d end end
  return 0
end
local function lowestIndex(m)
  for i = 0, 8 do if (m & (1 << i)) ~= 0 then return i end end
  return -1
end

-- xorshift32, masked to 32 bits so this 64-bit host and the device's int32
-- draw the same puzzles from the same seed.
local function nextRandom(r)
  local s = r.s
  if s == 0 then s = 0x9E3779B9 end
  s = (s ~ ((s << 13) & 0xFFFFFFFF)) & 0xFFFFFFFF
  s = (s ~ (s >> 17)) & 0xFFFFFFFF
  s = (s ~ ((s << 5) & 0xFFFFFFFF)) & 0xFFFFFFFF
  r.s = s
  return s
end

-- peers[cell] : the 20 cells sharing a row, column or box with `cell`.
local peers = {}
local function arePeers(a, b)
  if a == b then return false end
  local ar, ac = (a - 1) // 9, (a - 1) % 9
  local br, bc = (b - 1) // 9, (b - 1) % 9
  if ar == br or ac == bc then return true end
  return (ar // 3) * 3 + ac // 3 == (br // 3) * 3 + bc // 3
end
for c = 1, 81 do
  local t = {}
  for o = 1, 81 do if arePeers(c, o) then t[#t + 1] = o end end
  peers[c] = t
end

-- units[u] : the 9 cells of unit u (0..8 rows, 9..17 columns, 18..26 boxes).
local units = {}
for u = 0, 26 do
  local t = {}
  for s = 0, 8 do
    if u < 9 then
      t[s + 1] = u * 9 + s + 1
    elseif u < 18 then
      t[s + 1] = s * 9 + (u - 9) + 1
    else
      local box = u - 18
      local br, bc = (box // 3) * 3, (box % 3) * 3
      t[s + 1] = (br + s // 3) * 9 + (bc + s % 3) + 1
    end
  end
  units[u + 1] = t
end

-- ------------------------------------------------------------------ ladder
-- Eleven rungs? Ten here, in the order the C++ names them; the order IS the
-- difficulty scale: solve() always applies the cheapest technique that fires,
-- so the hardest one it ever needed is a measurement.
--   1 ONLY DIGIT  2 ONLY CELL  3 LOCKED  4 CELL PAIR  5 DIGIT PAIR
--   6 CELL TRIO   7 DIGIT TRIO 8 RECTANGLE (x-wing) 9 Y CHAIN (xy-wing)
--  10 SWORDFISH
M.TECH = { "NOTHING", "ONLY DIGIT", "ONLY CELL", "LOCKED", "CELL PAIR",
  "DIGIT PAIR", "CELL TRIO", "DIGIT TRIO", "RECTANGLE", "Y CHAIN", "SWORDFISH" }
M.LEVEL = { "EASY", "MEDIUM", "HARD", "EXPERT" }

-- The hardest technique a level may need. Expert is deliberately the widest
-- band: each of triples, fish and Y CHAIN is individually uncommon, and a
-- narrow band would make EXPERT roughly one-in-forty to generate.
function M.ceilingFor(level)
  return ({ 2, 3, 5, 10 })[level + 1] or 2
end

function M.levelOf(technique)
  if technique <= 2 then return 0 end
  if technique == 3 then return 1 end
  if technique <= 5 then return 2 end
  return 3
end

local function newGrid()
  return { v = {}, c = {}, broken = false }
end
M.newGrid = newGrid

local function clearGrid(g)
  for i = 1, 81 do
    g.v[i] = 0
    g.c[i] = KALL
  end
  g.broken = false
end

local function assign(g, cell, digit)
  if g.v[cell] ~= 0 then return false end
  if (g.c[cell] & bitFor(digit)) == 0 then return false end
  g.v[cell] = digit
  g.c[cell] = 0
  local bit = bitFor(digit)
  local ok = true
  for i = 1, 20 do
    local p = peers[cell][i]
    if g.v[p] == digit then
      ok = false
    elseif g.v[p] == 0 then
      g.c[p] = g.c[p] & ~bit
      if g.c[p] == 0 then ok = false end
    end
  end
  return ok
end

local function load(g, given)
  clearGrid(g)
  local ok = true
  for i = 1, 81 do
    if given[i] and given[i] ~= 0 then
      if not assign(g, i, given[i]) then ok = false end
    end
  end
  return ok
end
M.load = load

local function isComplete(g)
  for i = 1, 81 do if g.v[i] == 0 then return false end end
  return true
end

local function digitPlacedIn(g, unit, digit)
  local t = units[unit]
  for s = 1, 9 do if g.v[t[s]] == digit then return true end end
  return false
end

local function positionsOf(g, unit, digit)
  local mask = 0
  local t = units[unit]
  for s = 1, 9 do
    local cell = t[s]
    if g.v[cell] == 0 and (g.c[cell] & bitFor(digit)) ~= 0 then
      mask = mask | (1 << (s - 1))
    end
  end
  return mask
end


-- shared helpers for the solver and the game module
M._base = { KALL = KALL, arePeers = arePeers, assign = assign, bitFor = bitFor, clearGrid = clearGrid, digitPlacedIn = digitPlacedIn, isComplete = isComplete, load = load, lowestDigit = lowestDigit, lowestIndex = lowestIndex, newGrid = newGrid, nextRandom = nextRandom, peers = peers, popcount = popcount, positionsOf = positionsOf, units = units }
return M
