local M = require("sudoku_base")
local KALL = M._base.KALL
local arePeers = M._base.arePeers
local assign = M._base.assign
local bitFor = M._base.bitFor
local digitPlacedIn = M._base.digitPlacedIn
local isComplete = M._base.isComplete
local load = M._base.load
local lowestDigit = M._base.lowestDigit
local lowestIndex = M._base.lowestIndex
local newGrid = M._base.newGrid
local peers = M._base.peers
local popcount = M._base.popcount
local positionsOf = M._base.positionsOf
local units = M._base.units
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

-- internal helpers the game module needs
M._solve = { APPLY = APPLY, applyFish = applyFish, applyHiddenSingle = applyHiddenSingle, applyHiddenSubset = applyHiddenSubset, applyLockedCandidates = applyLockedCandidates, applyNakedSingle = applyNakedSingle, applyNakedSubset = applyNakedSubset, applyXYWing = applyXYWing, eliminate = eliminate, findHiddenSingle = findHiddenSingle, findNakedSingle = findNakedSingle, nextCombination = nextCombination, solve = solve }
return M
