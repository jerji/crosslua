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

local function eliminate(g, cell, bits)
  if g.v[cell] ~= 0 then return false end
  local before = g.c[cell]
  local after = before & ~bits
  if after == before then return false end
  g.c[cell] = after
  if after == 0 then g.broken = true end
  return true
end

local function findNakedSingle(g)
  for cell = 1, 81 do
    if g.v[cell] == 0 and popcount(g.c[cell]) == 1 then
      return cell, lowestDigit(g.c[cell])
    end
  end
  return 0
end

local function findHiddenSingle(g)
  for u = 1, 27 do
    for d = 1, 9 do
      if not digitPlacedIn(g, u, d) then
        local pos = positionsOf(g, u, d)
        if popcount(pos) == 1 then
          local only = units[u][lowestIndex(pos) + 1]
          -- A cell down to one candidate is ONLY DIGIT; calling it hidden
          -- would mis-grade one rung up. The ladder exhausts naked singles
          -- first, so this guards only direct callers.
          if popcount(g.c[only]) ~= 1 then return only, d, u end
        end
      end
    end
  end
  return 0
end

local function applyNakedSingle(g)
  local progress = false
  while true do
    local cell, digit = findNakedSingle(g)
    if cell == 0 then break end
    if not assign(g, cell, digit) then
      g.broken = true
      return true
    end
    progress = true
  end
  return progress
end

local function applyHiddenSingle(g)
  local cell, digit = findHiddenSingle(g)
  if cell == 0 then return false end
  if not assign(g, cell, digit) then g.broken = true end
  return true
end

-- Pointing and claiming: a digit's remaining homes in a box lie on one line
-- (or in a line they lie in one box), so it leaves the rest of the other.
local function applyLockedCandidates(g)
  for box = 1, 9 do
    local unit = 18 + box
    for d = 1, 9 do
      if not digitPlacedIn(g, unit, d) then
        local pos = positionsOf(g, unit, d)
        if popcount(pos) >= 2 then
          local row, column, sameRow, sameColumn = -1, -1, true, true
          for s = 1, 9 do
            if (pos & (1 << (s - 1))) ~= 0 then
              local cell = units[unit][s]
              local cr, cc = (cell - 1) // 9, (cell - 1) % 9
              if row < 0 then row = cr elseif cr ~= row then sameRow = false end
              if column < 0 then column = cc elseif cc ~= column then sameColumn = false end
            end
          end
          local progress = false
          if sameRow then
            for i = 1, 9 do
              local cell = row * 9 + i
              if (cell - 1) % 9 // 3 ~= (box - 1) % 3 or (cell - 1) // 9 // 3 ~= (box - 1) // 3 then
                if eliminate(g, cell, bitFor(d)) then progress = true end
              end
            end
          end
          if sameColumn then
            for i = 0, 8 do
              local cell = i * 9 + column + 1
              if (cell - 1) // 9 // 3 ~= (box - 1) // 3 or (cell - 1) % 9 // 3 ~= (box - 1) % 3 then
                if eliminate(g, cell, bitFor(d)) then progress = true end
              end
            end
          end
          if progress then return true end
        end
      end
    end
  end

  for line = 1, 18 do
    local isRow = line <= 9
    for d = 1, 9 do
      if not digitPlacedIn(g, line, d) then
        local pos = positionsOf(g, line, d)
        if popcount(pos) >= 2 then
          local box, sameBox = -1, true
          for s = 1, 9 do
            if (pos & (1 << (s - 1))) ~= 0 then
              local cell = units[line][s]
              local b = ((cell - 1) // 9 // 3) * 3 + ((cell - 1) % 9 // 3)
              if box < 0 then box = b elseif b ~= box then sameBox = false end
            end
          end
          if not sameBox or box < 0 then goto noline end
          local progress = false
          local t = units[18 + box + 1]
          for s = 1, 9 do
            local cell = t[s]
            local onLine = isRow and ((cell - 1) // 9) == (line - 1)
                or (not isRow) and ((cell - 1) % 9) == (line - 10)
            if not onLine then
              if eliminate(g, cell, bitFor(d)) then progress = true end
            end
          end
          if progress then return true end
        end
      end
      ::noline::
    end
  end
  return false
end

local function nextCombination(idx, k, n)
  local i = k
  while i >= 1 and idx[i] == n - k + i do i = i - 1 end
  if i < 1 then return false end
  idx[i] = idx[i] + 1
  for j = i + 1, k do idx[j] = idx[j - 1] + 1 end
  return true
end

-- `size` cells of a unit whose candidates span exactly `size` digits. Those
-- digits are spoken for, so they leave every other cell of the unit.
local function applyNakedSubset(g, size)
  for u = 1, 27 do
    local open = {}
    local count = 0
    for s = 1, 9 do
      local cell = units[u][s]
      if g.v[cell] == 0 then count = count + 1 open[count] = cell end
    end
    if count > size then
      local idx = {}
      for i = 1, size do idx[i] = i end
      repeat
        local spanned, usable = 0, true
        for i = 1, size do
          local cand = g.c[open[idx[i]]]
          local n = popcount(cand)
          if n < 2 or n > size then usable = false break end
          spanned = spanned | cand
        end
        if usable and popcount(spanned) == size then
          local progress = false
          for o = 1, count do
            local inSub = false
            for i = 1, size do if idx[i] == o then inSub = true end end
            if not inSub and eliminate(g, open[o], spanned) then progress = true end
          end
          if progress then return true end
        end
      until not nextCombination(idx, size, count)
    end
  end
  return false
end

-- The mirror: `size` digits confined to exactly `size` cells; those cells are
-- spoken for, so everything else leaves them.
local function applyHiddenSubset(g, size)
  for u = 1, 27 do
    local digits, where, count = {}, {}, 0
    for d = 1, 9 do
      if not digitPlacedIn(g, u, d) then
        local pos = positionsOf(g, u, d)
        local n = popcount(pos)
        if n >= 2 and n <= size then
          count = count + 1
          digits[count], where[count] = d, pos
        end
      end
    end
    if count >= size then
      local idx = {}
      for i = 1, size do idx[i] = i end
      repeat
        local covered, wanted = 0, 0
        for i = 1, size do
          covered = covered | where[idx[i]]
          wanted = wanted | bitFor(digits[idx[i]])
        end
        if popcount(covered) == size then
          local progress = false
          for s = 1, 9 do
            if (covered & (1 << (s - 1))) ~= 0 then
              if eliminate(g, units[u][s], KALL & ~wanted) then progress = true end
            end
          end
          if progress then return true end
        end
      until not nextCombination(idx, size, count)
    end
  end
  return false
end

-- A fish: `size` lines whose homes for a digit span exactly `size` crossings.
-- Size two is the x-wing, size three the swordfish; one observation at two
-- widths, written once.
local function applyFish(g, size)
  for orient = 0, 1 do
    for d = 1, 9 do
      local lines, crosses, found = {}, {}, 0
      for i = 1, 9 do
        local unit = orient == 0 and i or (9 + i)
        if not digitPlacedIn(g, unit, d) then
          local pos = positionsOf(g, unit, d)
          local n = popcount(pos)
          if n >= 2 and n <= size then
            found = found + 1
            lines[found], crosses[found] = i, pos
          end
        end
      end
      if found >= size then
        local idx = {}
        for i = 1, size do idx[i] = i end
        repeat
          local covered = 0
          for i = 1, size do covered = covered | crosses[idx[i]] end
          if popcount(covered) == size then
            local progress = false
            for s = 1, 9 do
              if (covered & (1 << (s - 1))) ~= 0 then
                for i = 1, 9 do
                  local inFish = false
                  for k = 1, size do if lines[idx[k]] == i then inFish = true end end
                  if not inFish then
                    local cell = orient == 0 and ((i - 1) * 9 + s) or ((s - 1) * 9 + i)
                    if eliminate(g, cell, bitFor(d)) then progress = true end
                  end
                end
              end
            end
            if progress then return true end
          end
        until not nextCombination(idx, size, found)
      end
    end
  end
  return false
end

-- A pivot holding {a, b}, two pincers holding {a, c} and {b, c}: whichever way
-- the pivot falls one pincer becomes c, so c leaves every cell that sees both.
local function applyXYWing(g)
  for pivot = 1, 81 do
    if g.v[pivot] == 0 and popcount(g.c[pivot]) == 2 then
      local a = lowestDigit(g.c[pivot])
      local b = lowestDigit(g.c[pivot] & ~bitFor(a))
      for i = 1, 20 do
        local first = peers[pivot][i]
        if g.v[first] ~= 0 or popcount(g.c[first]) ~= 2 then goto nextpeer end
        local hasA = (g.c[first] & bitFor(a)) ~= 0
        local hasB = (g.c[first] & bitFor(b)) ~= 0
        if hasA == hasB then goto nextpeer end
        local shared = hasA and a or b
        local other = hasA and b or a
        local third = lowestDigit(g.c[first] & ~bitFor(shared))
        if third == other or third == 0 then goto nextpeer end
        local wanted = bitFor(other) | bitFor(third)
        for j = 1, 20 do
          local second = peers[pivot][j]
          if second == first then goto nextsecond end
          if g.v[second] ~= 0 or g.c[second] ~= wanted then goto nextsecond end
          local progress = false
          for cell = 1, 81 do
            if cell ~= pivot and cell ~= first and cell ~= second then
              if arePeers(cell, first) and arePeers(cell, second) then
                if eliminate(g, cell, bitFor(third)) then progress = true end
              end
            end
          end
          if progress then return true end
          ::nextsecond::
        end
        ::nextpeer::
      end
    end
  end
  return false
end

local APPLY = {
  applyNakedSingle,
  applyHiddenSingle,
  applyLockedCandidates,
  function(g) return applyNakedSubset(g, 2) end,
  function(g) return applyHiddenSubset(g, 2) end,
  function(g) return applyNakedSubset(g, 3) end,
  function(g) return applyHiddenSubset(g, 3) end,
  function(g) return applyFish(g, 2) end,
  applyXYWing,
  function(g) return applyFish(g, 3) end,
}

-- Drive the position as far as techniques up to `ceiling` will take it,
-- always applying the cheapest that fires and restarting, so `hardest` is a
-- measurement of what the puzzle genuinely needed.
local function solve(g, ceiling)
  local rep = { solved = false, broken = false, hardest = 0, steps = 0 }
  while rep.steps < 4096 do
    if isComplete(g) then rep.solved = true return rep end
    local progress = false
    for rung = 1, ceiling do
      g.broken = false
      if not APPLY[rung](g) then goto nextrung end
      rep.steps = rep.steps + 1
      if rung > rep.hardest then rep.hardest = rung end
      if g.broken then rep.broken = true return rep end
      progress = true
      break
      ::nextrung::
    end
    if not progress then return rep end
  end
  return rep
end
M.solve = solve

-- ------------------------------------------------------------------ grader
-- level index (0..3) of a completed puzzle, or nil when the clues contradict
-- each other or do not determine a full solution.
function M.grade(given)
  local g = newGrid()
  if not load(g, given) then return nil end
  local rep = solve(g, 10)
  if not rep.solved or rep.broken then return nil end
  return M.levelOf(rep.hardest)
end

function M.solvableAt(given, ceiling)
  local g = newGrid()
  if not load(g, given) then return false end
  local rep = solve(g, ceiling)
  return rep.solved and not rep.broken
end

-- -------------------------------------------------------------- generator
local function fits(value, cell, digit)
  local t = peers[cell]
  for i = 1, 20 do
    if value[t[i]] == digit then return false end
  end
  return true
end

local function solvableWith(probe, given, ceiling)
  if not load(probe, given) then return false end
  local rep = solve(probe, ceiling)
  return rep.solved and not rep.broken
end

function M.newWork()
  local work = { order = {}, next = {}, value = {}, grid = newGrid(), probe = newGrid() }
  for cell = 1, 81 do work.order[cell] = {} end
  return work
end

local function fillComplete(solution, work, rng)
  for cell = 1, 81 do
    local order = work.order[cell]
    for i = 1, 9 do order[i] = i end
    for i = 9, 2, -1 do
      local j = nextRandom(rng) % i + 1
      order[i], order[j] = order[j], order[i]
    end
    work.next[cell] = 1
    work.value[cell] = 0
  end
  local cell = 1
  local guard = 0
  while cell <= 81 do
    guard = guard + 1
    if guard > 200000 then return false end
    local placed = false
    while work.next[cell] <= 9 do
      local digit = work.order[cell][work.next[cell]]
      work.next[cell] = work.next[cell] + 1
      if fits(work.value, cell, digit) then
        work.value[cell] = digit
        placed = true
        break
      end
    end
    if placed then
      cell = cell + 1
    else
      work.next[cell] = 1
      work.value[cell] = 0
      if cell == 1 then return false end
      cell = cell - 1
      work.value[cell] = 0
    end
  end
  for i = 1, 81 do solution[i] = work.value[i] end
  return true
end
M.fillComplete = fillComplete

-- Carve one puzzle out of a full grid and grade it; the level is an OUTPUT.
-- Clues come out in 180-degree rotational pairs, removed only while the rest
-- still drives the bounded solver to a finish, so the dig is maximal and the
-- grade below is the truth about what was made.
local function carve(out, solution, work, rng)
  out.given = out.given or {}
  out.solution = out.solution or {}
  for i = 1, 81 do
    out.given[i] = solution[i]
    out.solution[i] = solution[i]
  end
  local leader = {}
  for i = 1, 41 do leader[i] = i end
  for i = 41, 2, -1 do
    local j = nextRandom(rng) % i + 1
    leader[i], leader[j] = leader[j], leader[i]
  end
  for i = 1, 41 do
    local a = leader[i]
    local b = 82 - a
    local keptA, keptB = out.given[a], out.given[b]
    out.given[a], out.given[b] = 0, 0
    if not solvableWith(work.probe, out.given, 10) then
      out.given[a], out.given[b] = keptA, keptB
    end
  end
  load(work.grid, out.given)
  local rep = solve(work.grid, 10)
  if not rep.solved or rep.broken then return false end
  out.hardest = rep.hardest
  out.level = M.levelOf(rep.hardest)
  out.clues = 0
  for i = 1, 81 do if out.given[i] ~= 0 then out.clues = out.clues + 1 end end
  return true
end
M.carve = carve

-- fillComplete plus carve, discarding puzzles that do not grade as `level`.
-- The measured distribution of the symmetric dig is ~83% EASY, ~10% MEDIUM,
-- ~3% HARD, ~4% EXPERT, so EASY costs about one attempt and HARD about thirty.
function M.generate(out, level, work, rng, attempts)
  attempts = attempts or 24
  for attempt = 1, attempts do
    local attemptSeed = rng.s
    local solution = {}
    if not fillComplete(solution, work, rng) then
      -- no base grid from this seed; try another
    elseif not carve(out, solution, work, rng) then
      -- dug but could not grade; try another
    elseif out.level ~= level then
      -- a perfectly good puzzle, just not this level; try another
    else
      out.seed = attemptSeed
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------- the hint
-- Name a cell the player could fill right now and the rule that proves it.
-- Checks first for an entry that disagrees with the answer: any deduction made
-- past a wrong digit is a lie.
function M.nextHint(given, ceiling)
  local hint = { found = false, cell = 0, digit = 0, technique = 0, unit = 0 }
  local g = newGrid()
  if not load(g, given) then return hint end
  local hardest = 0
  for guard = 1, 4096 do
    if isComplete(g) then return hint end
    local cell, digit, unit, via = 0, 0, 0, 0
    cell, digit = findNakedSingle(g)
    if cell ~= 0 then
      via = 1
    else
      cell, digit, unit = findHiddenSingle(g)
      if cell ~= 0 then via = 2 end
    end
    if via ~= 0 then
      hint.found = true
      hint.cell = cell
      hint.digit = digit
      hint.technique = hardest > via and hardest or via
      hint.unit = unit
      return hint
    end
    local progress = false
    for rung = 3, ceiling do
      g.broken = false
      if APPLY[rung](g) then
        if g.broken then return hint end
        if rung > hardest then hardest = rung end
        progress = true
        break
      end
    end
    if not progress then return hint end
  end
  return hint
end

-- ------------------------------------------------------------------- game
-- The player's game on top of the rules: their entries, notes, undo ring,
-- armed digit and clock. A note is never edited by anything but the player;
-- visibleNotes hides what a cell can no longer take, computed at draw time.

local UNDO_DEPTH = 24

function M.newGame()
  local g = {
    puzzle = nil,
    entry = {}, note = {},
    undo = {}, undoCount = 0, undoNext = 1,
    armed = 1,
    hintCell = 0, hintDigit = 0, hintTech = 0, hintsUsed = 0,
    solvedFlag = false,
    elapsedMs = 0,
  }
  return g
end

function M.valueAt(g, cell)
  return g.puzzle.given[cell] ~= 0 and g.puzzle.given[cell] or (g.entry[cell] or 0)
end
function M.isGiven(g, cell) return g.puzzle.given[cell] ~= 0 end

function M.takenAround(g, cell)
  local taken = 0
  local t = peers[cell]
  for i = 1, 20 do
    local v = M.valueAt(g, t[i])
    if v ~= 0 then taken = taken | bitFor(v) end
  end
  return taken
end

function M.visibleNotes(g, cell)
  if M.valueAt(g, cell) ~= 0 then return 0 end
  return (g.note[cell] or 0) & ~M.takenAround(g, cell)
end

function M.isClashing(g, cell)
  local value = M.valueAt(g, cell)
  if value == 0 then return false end
  local t = peers[cell]
  for i = 1, 20 do
    if M.valueAt(g, t[i]) == value then return true end
  end
  return false
end

function M.emptyCount(g)
  local count = 0
  for i = 1, 81 do if M.valueAt(g, i) == 0 then count = count + 1 end end
  return count
end

function M.placedCount(g, digit)
  local count = 0
  for i = 1, 81 do if M.valueAt(g, i) == digit then count = count + 1 end end
  return count
end

-- The first cell whose digit disagrees with the answer, or 0. Only HINT reads
-- this: the board never marks it, because a game that tells you which digit
-- is wrong the moment you write it solves itself.
function M.firstWrong(g)
  for i = 1, 81 do
    local e = g.entry[i] or 0
    if e ~= 0 and e ~= g.puzzle.solution[i] then return i end
  end
  return 0
end

function M.isSolved(g)
  for i = 1, 81 do
    if M.valueAt(g, i) ~= g.puzzle.solution[i] then return false end
  end
  return true
end

local function pushUndo(g, cell)
  g.undo[g.undoNext] = { cell = cell, entry = g.entry[cell] or 0, note = g.note[cell] or 0 }
  g.undoNext = g.undoNext % UNDO_DEPTH + 1
  if g.undoCount < UNDO_DEPTH then g.undoCount = g.undoCount + 1 end
end

function M.canUndo(g) return g.undoCount > 0 end

function M.undoOnce(g)
  if g.undoCount == 0 then return false end
  g.undoNext = g.undoNext - 1
  if g.undoNext == 0 then g.undoNext = UNDO_DEPTH end
  local ch = g.undo[g.undoNext]
  g.entry[ch.cell] = ch.entry
  g.note[ch.cell] = ch.note
  g.undoCount = g.undoCount - 1
  g.solvedFlag = false
  return true
end

local function clearHintIfSpent(g)
  if g.hintCell ~= 0 and M.valueAt(g, g.hintCell) ~= 0 then
    g.hintCell = 0
    g.hintDigit = 0
  end
end

-- One function changes a cell, and every case does something: a clue picks
-- the digit up, your own same digit clears it, your own different digit is
-- overwritten, an empty cell takes the armed digit.
function M.tapCell(g, cell)
  if M.isGiven(g, cell) then
    g.armed = g.puzzle.given[cell]
    return
  end
  pushUndo(g, cell)
  if g.entry[cell] == g.armed then
    g.entry[cell] = 0
  else
    g.entry[cell] = g.armed
  end
  g.note[cell] = 0
  clearHintIfSpent(g)
  if M.isSolved(g) then g.solvedFlag = true end
end

-- The pencil mark: toggle the armed digit's note in the cell, or pick a clue
-- digit up. Nothing but the player ever edits a note.
function M.holdCell(g, cell)
  if M.isGiven(g, cell) then
    g.armed = g.puzzle.given[cell]
    return
  end
  pushUndo(g, cell)
  g.entry[cell] = 0
  g.note[cell] = (g.note[cell] or 0) ~ bitFor(g.armed)
  g.solvedFlag = false
end

function M.startGame(g, puzzle)
  local fresh = M.newGame()
  g.entry, g.note, g.undo = fresh.entry, fresh.note, fresh.undo
  g.undoCount, g.undoNext = 0, 1
  g.hintCell, g.hintDigit, g.hintTech, g.hintsUsed = 0, 0, 0, 0
  g.solvedFlag = false
  g.elapsedMs = 0
  g.puzzle = puzzle
  -- The scarcest digit is the one worth starting on.
  local scarcest, fewest = 1, 10
  for d = 1, 9 do
    local placed = M.placedCount(g, d)
    if placed < fewest then fewest = placed scarcest = d end
  end
  g.armed = scarcest
end

-- The front door's offer, DERIVED rather than latched: 0 fresh, 1 resume,
-- 2 solved, 3 other level. The label and the door read the same fact.
function M.menuOffer(g, hasGame, menuLevel)
  if not hasGame or not g or not g.puzzle then return 0 end
  if menuLevel ~= g.puzzle.level then return 3 end
  return g.solvedFlag and 2 or 1
end

-- Resume is the ONLY offer that opens the saved grid; every other one carves
-- a new puzzle over it.
function M.canResume(g, hasGame, menuLevel)
  return M.menuOffer(g, hasGame, menuLevel) == 1
end

-- What the player has finished, per level; outlives the puzzle it was set on.
function M.newRecord()
  return { solved = { 0, 0, 0, 0 }, best = { 0, 0, 0, 0 }, hintsTaken = 0 }
end

function M.recordSolve(rec, level, elapsedMs, hintsUsed)
  local index = level + 1
  if rec.solved[index] < 0xFFFF then rec.solved[index] = rec.solved[index] + 1 end
  -- A solve leaning on hints does not set a best time.
  if hintsUsed == 0 and (rec.best[index] == 0 or elapsedMs < rec.best[index]) then
    rec.best[index] = elapsedMs
  end
  rec.hintsTaken = rec.hintsTaken + hintsUsed
end

function M.totalSolved(rec)
  return rec.solved[1] + rec.solved[2] + rec.solved[3] + rec.solved[4]
end

M.KALL = KALL
M.bitFor = bitFor
M.popcount = popcount
M.nextRandom = nextRandom
M.newRng = function(seed) return { s = seed & 0xFFFFFFFF } end

return M