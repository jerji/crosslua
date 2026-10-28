-- Checkers (English draughts): the rules and the built-in opponent.
-- A port of crossplay's checkers core (CheckersCore.h, CheckersBrain.h) plus
-- its flow helpers (CheckersFlow.h). Pure Lua: no device namespaces, so a host
-- lua5.4 can run the whole module for tests.
--
-- Board: cell[1..64]; index = rank*8 + file + 1 with 0-based file and rank, and
-- only squares with an odd file+rank are playable, exactly like the C++.
-- A cell value is a bitmask: EMPTY 0, PIECE 1, DARK 2 (the dark side), KING 4.
-- Light moves first. A man steps diagonally forward one square, a king steps
-- both ways. Reaching the far row promotes. Capture is COMPULSORY: moves()
-- returns jumps only when any jump exists, so a quiet move cannot be expressed
-- while a capture is on. A jump chain is ONE move; promotion ends a chain (the
-- scratch board never promotes mid-chain, so a man on the last row has no
-- forward jump and the recursion stops -- the rule enforced by geometry).
--
-- Move = { from = index, to = index, taken = "byte string of captured squares" }.
-- taken stores square indices as bytes (0..63 fit one each) because the device
-- Lua is a 32-bit build and the C++'s 64-bit mask would not fit an integer.
-- An empty string means the move captures nothing; two chains that produce the
-- same from/to/taken are kept as separate entries, as in the C++.
--
-- Deviation from the C++: checkers::play() re-validates a move against the
-- legal list; M.apply() trusts the caller. Every caller here (the UI and the
-- brain) passes a Move taken straight from moves(), so replaying the search
-- would only double the opponent's cost without adding safety.

local M = {}

local kSize, kCells = 8, 64
local kMaxMoves, kIdleLimit = 48, 80
local EMPTY, PIECE, DARK, KING = 0, 1, 2, 4
local LIGHT, DARKSEAT = 0, 1
local kManValue, kKingValue = 10, 18
-- Reply nodes the opponent may evaluate per chooseMove. The C++ brain searches
-- the whole two-ply tree (up to 48 x 48 tries); Lua must stay shallow enough
-- to finish in a couple of seconds on the device, so the reply expansion is
-- capped and anything past the cap is scored by material alone. Still
-- deterministic: the same position always produces the same move.
local SEARCH_NODES = 1000

M.kSize = kSize M.kCells = kCells
M.EMPTY = EMPTY M.PIECE = PIECE M.DARK = DARK M.KING = KING
M.LIGHT = LIGHT M.DARKSEAT = DARKSEAT
M.kMaxMoves = kMaxMoves M.kIdleLimit = kIdleLimit

local function playable(f, r) return ((f + r) & 1) == 1 end
local function inside(f, r) return f >= 0 and f < kSize and r >= 0 and r < kSize end
local function indexOf(f, r) return r * kSize + f + 1 end
local function fileOf(i) return (i - 1) % kSize end
local function rankOf(i) return (i - 1) // kSize end

M.playable = playable M.indexOf = indexOf M.fileOf = fileOf M.rankOf = rankOf

local function isDark(c) return (c & DARK) ~= 0 end
local function isKing(c) return (c & KING) ~= 0 end
local function ownerOf(c) return isDark(c) and DARKSEAT or LIGHT end

M.isDark = isDark M.isKing = isKing M.ownerOf = ownerOf

-- ---------------------------------------------------------------- the board

function M.start()
  local cell = {}
  for i = 1, kCells do cell[i] = EMPTY end
  for r = 0, kSize - 1 do
    for f = 0, kSize - 1 do
      if playable(f, r) then
        local i = indexOf(f, r)
        if r < 3 then cell[i] = PIECE | DARK end
        if r > 4 then cell[i] = PIECE end
      end
    end
  end
  return { cell = cell, turn = LIGHT, idle = 0 }
end

local function copyCells(src)
  local t = {}
  table.move(src, 1, kCells, 1, t)
  return t
end

-- ---------------------------------------------------------------- move gen

-- Every legal move for the side to play, in the C++'s order: pieces in cell
-- order, forward direction before backward for kings, file -1 before +1.
local function moves(g)
  local cell, out = g.cell, {}
  local turn = g.turn
  local function mineAt(i) local c = cell[i] return c ~= EMPTY and ownerOf(c) == turn end

  -- Collect every jump chain starting at `index` on the scratch board `cell`,
  -- depth first. `cell` is a parameter, not the live board: each jump step
  -- recurses on a COPY with the captured man lifted, so a chain sees the board
  -- the way a player does and a half-finished jump is never recorded as a move.
  -- A chain is pushed only inside a jump branch, exactly like the C++: a node
  -- whose branch extended nothing is a finished chain (the seed itself is
  -- never a move), and the `before` count is read per branch so a node with
  -- several jumps records each of its finished chains once.
  local function collectJumps(cell, index, sofar)
    local f0, r0 = fileOf(index), rankOf(index)
    local me = cell[index]
    local owner = ownerOf(me)
    local fwd = owner == LIGHT and -1 or 1
    for d = 1, (isKing(me) and 2 or 1) do
      local dr = d == 2 and -fwd or fwd
      for df = -1, 1, 2 do
        local lf, lr = f0 + df * 2, r0 + dr * 2
        if inside(lf, lr) then
          local over = indexOf(f0 + df, r0 + dr)
          local land = indexOf(lf, lr)
          local oc = cell[over]
          -- No "already taken" check: the scratch board below lifts each
          -- captured man, so the occupancy test has already rejected it.
          if oc ~= EMPTY and ownerOf(oc) ~= owner and cell[land] == EMPTY then
            local before = #out
            local child = copyCells(cell)
            child[land] = child[index]
            child[index] = EMPTY
            child[over] = EMPTY
            -- Promotion ends a chain with no branch here: a man crowned on the
            -- last row has no forward square, so nothing extends it. The
            -- scratch board does not promote (apply() does), so the piece
            -- never gains king powers mid-chain.
            local chain = { from = sofar.from, to = land, taken = sofar.taken .. string.char(over - 1) }
            collectJumps(child, land, chain)
            if #out == before and #out < kMaxMoves then out[#out + 1] = chain end
          end
        end
      end
    end
  end

  for i = 1, kCells do
    if mineAt(i) then collectJumps(cell, i, { from = i, to = i, taken = "" }) end
  end
  if #out > 0 then return out end

  -- Quiet steps: no capture on the board, so any one-square diagonal step is
  -- legal.
  for i = 1, kCells do
    local c = cell[i]
    if c ~= EMPTY and ownerOf(c) == turn then
      local f0, r0 = fileOf(i), rankOf(i)
      local fwd = turn == LIGHT and -1 or 1
      for d = 1, (isKing(c) and 2 or 1) do
        local dr = d == 2 and -fwd or fwd
        for df = -1, 1, 2 do
          local tf, tr = f0 + df, r0 + dr
          if inside(tf, tr) and #out < kMaxMoves then
            local to = indexOf(tf, tr)
            if cell[to] == EMPTY then out[#out + 1] = { from = i, to = to, taken = "" } end
          end
        end
      end
    end
  end
  return out
end
M.moves = moves

-- ---------------------------------------------------------------- applying

-- Apply a move, promoting and handing over. Trusts the move to be legal (see
-- the header note); the UI only ever passes moves from moves().
function M.apply(g, m)
  local cell = g.cell
  -- Lifted before the square is cleared, because a multi-jump can END where it
  -- started: a four-capture cycle returns a king to its own square, and
  -- clearing `from` afterwards would delete the piece that just moved.
  local moving = cell[m.from]
  cell[m.from] = EMPTY
  local taken = m.taken
  for k = 1, #taken do cell[taken:byte(k) + 1] = EMPTY end
  cell[m.to] = moving

  local r = rankOf(m.to)
  local light = ownerOf(moving) == LIGHT
  if (light and r == 0) or (not light and r == kSize - 1) then cell[m.to] = moving | KING end

  -- Progress resets the clock: a capture, or a man moving. Only kings
  -- shuffling with nothing taken counts as idle.
  if #taken ~= 0 or not isKing(moving) then
    g.idle = 0
  elseif g.idle < 255 then
    g.idle = g.idle + 1
  end
  g.turn = g.turn == LIGHT and DARKSEAT or LIGHT
end

local function pieceCount(g, seat)
  local n = 0
  for i = 1, kCells do
    local c = g.cell[i]
    if c ~= EMPTY and ownerOf(c) == seat then n = n + 1 end
  end
  return n
end
M.pieceCount = pieceCount

-- How the game stands: "running", the winner ("light"/"dark"), or "draw".
-- One function rather than an over()/winner() pair, because a draw made
-- "no winner" mean two different things.
local function outcome(g)
  if g.idle >= kIdleLimit then return "draw" end
  -- The side to play has no move: a loss for them, whether by capture or by
  -- being blocked. Checkers treats both the same way.
  if #moves(g) == 0 then return g.turn == LIGHT and "dark" or "light" end
  return "running"
end
M.outcome = outcome
M.over = function(g) return outcome(g) ~= "running" end

-- ---------------------------------------------------------------- flow
-- The selection helpers the UI builds on, ported from CheckersFlow.h. A piece
-- with no legal move cannot be lifted, and a destination the rules did not
-- offer cannot be expressed at the boundary either.

function M.canPick(g, square)
  local c = g.cell[square]
  if c == EMPTY or ownerOf(c) ~= g.turn then return false end
  local list = moves(g)
  for i = 1, #list do if list[i].from == square then return true end end
  return false
end

function M.moveBetween(g, from, to)
  local list = moves(g)
  for i = 1, #list do
    if list[i].from == from and list[i].to == to then return list[i] end
  end
  return nil
end

-- Where a picked piece may land, and what each landing captures (the rules
-- already computed it; the UI brackets those enemies).
function M.destinations(g, from)
  local list = moves(g)
  local out = {}
  for i = 1, #list do
    if list[i].from == from then out[#out + 1] = { to = list[i].to, taken = list[i].taken } end
  end
  return out
end

function M.captureAvailable(g)
  local list = moves(g)
  return #list > 0 and #list[1].taken > 0
end

-- Every square holding a piece with a legal move, as a set (movable[i] = true).
-- This is how the compulsory-capture rule becomes visible: under a mandatory
-- capture the set collapses and the board demonstrates the rule.
function M.movableSquares(g)
  local list = moves(g)
  local mask = {}
  for i = 1, #list do mask[list[i].from] = true end
  return mask
end

-- ---------------------------------------------------------------- brain
-- Port of CheckersBrain.h. Two ply with a material evaluation: play every
-- legal move, let the opponent reply with their best, keep the move whose
-- worst case is best. The reply expansion is node-capped (see SEARCH_NODES);
-- past the cap a position is scored by material alone.
local function material(g, seat)
  local s = 0
  for i = 1, kCells do
    local c = g.cell[i]
    if c ~= EMPTY then
      local v = isKing(c) and kKingValue or kManValue
      if ownerOf(c) == seat then s = s + v else s = s - v end
    end
  end
  return s
end
M.material = material

local function copyGame(g)
  return { cell = copyCells(g.cell), turn = g.turn, idle = g.idle }
end

-- The move the opponent would play, or nil when it has none. Ties break toward
-- the earlier move in generation order, so the same position always plays the
-- same move -- a random tiebreak would make a match unreconstructible.
function M.chooseMove(g, nodes)
  local list = moves(g)
  if #list == 0 then return nil end
  local seat = g.turn
  local budget = nodes or SEARCH_NODES

  -- The opponent's best reply to a position, as a score for `seat`.
  local function worstReply(trial)
    if budget <= 0 then return material(trial, seat) end
    local reply = moves(trial)
    -- They have nothing: this position wins for whoever is not to move.
    if #reply == 0 then return trial.turn == seat and -1000 or 1000 end
    local worst = 2000
    for i = 1, #reply do
      if budget <= 0 then return material(trial, seat) end
      budget = budget - 1
      local t2 = copyGame(trial)
      M.apply(t2, reply[i])
      local score = material(t2, seat)
      if score < worst then worst = score end
    end
    return worst
  end

  local bestScore, best = -3000, nil
  for i = 1, #list do
    local trial = copyGame(g)
    M.apply(trial, list[i])
    local score = worstReply(trial)
    if score > bestScore then
      bestScore = score
      best = list[i]
    end
  end
  return best
end

return M