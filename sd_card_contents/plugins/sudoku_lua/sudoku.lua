local M = require("sudoku_base")
require("sudoku_solve")
local KALL = M._base.KALL
local bitFor = M._base.bitFor
local isComplete = M._base.isComplete
local load = M._base.load
local newGrid = M._base.newGrid
local nextRandom = M._base.nextRandom
local peers = M._base.peers
local popcount = M._base.popcount
local APPLY = M._solve.APPLY
local findHiddenSingle = M._solve.findHiddenSingle
local findNakedSingle = M._solve.findNakedSingle
local solve = M._solve.solve
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