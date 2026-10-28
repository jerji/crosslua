-- engine.lua: the chess opponent, ported from crossplay's ChessEngine (C++).
--
-- Freestanding negamax with alpha-beta over chess.lua. Same shape as the C++:
-- MVV-LVA move ordering, piece-square tables, mate scores shrinking with
-- distance, and a node budget as the safety net. No heap surprises: the
-- per-ply move lists are preallocated once per search().
--
-- DEPTH CAP, sized for the device (VM-instruction counts measured on the
-- host at the spec'd 435k VM ops/s of the X4):
--
--   d1 from the opening:  0.2s    20 nodes
--   d2 from the opening:  2.2s   113 nodes     (NORMAL: the daily driver)
--   d2 middlegame:        4.9s   137 nodes
--   d3 from the opening: 15.1s  1035 nodes
--   d3 middlegame:       31.6s  1783 nodes
--
-- So MAX_DEPTH is 3 where the C++ caps at 4 -- its move generator is 10-30x
-- faster per node -- and the level map is the C++'s 1/3/4 scaled down one
-- ply: EASY 1, NORMAL 2, HARD 3. HARD is the deliberate-slow setting, the
-- same way depth 4 (already "a second or more" on the C3) is in the C++.
-- The node budget stays the C++ value (60000) as the backstop against a
-- position that blows up combinatorially: the search then stops early and
-- still returns its best move so far.

local chess = require("chess")
local engine = {}

engine.MATE = 30000
engine.MATE_THRESHOLD = engine.MATE - 1000
engine.MAX_DEPTH = 3
engine.NODE_BUDGET = 60000
-- easy, normal, hard
engine.DEPTH_BY_LEVEL = { 1, 2, 3 }

local band = chess.band

local PIECE_VALUE = { 0, 100, 320, 330, 500, 900, 20000 }

-- Piece-square tables, written from White's point of view with rank 1 first,
-- so index == square index (rank*8+file). Copied verbatim from ChessEngine.cpp.
local PST = {}
PST[chess.PAWN] = {
  0, 0, 0, 0, 0, 0, 0, 0,
  5, 10, 10, -20, -20, 10, 10, 5,
  5, -5, -10, 0, 0, -10, -5, 5,
  0, 0, 0, 20, 20, 0, 0, 0,
  5, 5, 10, 25, 25, 10, 5, 5,
  10, 10, 20, 30, 30, 20, 10, 10,
  50, 50, 50, 50, 50, 50, 50, 50,
  0, 0, 0, 0, 0, 0, 0, 0,
}
PST[chess.KNIGHT] = {
  -50, -40, -30, -30, -30, -30, -40, -50,
  -40, -20, 0, 5, 5, 0, -20, -40,
  -30, 5, 10, 15, 15, 10, 5, -30,
  -30, 0, 15, 20, 20, 15, 0, -30,
  -30, 5, 15, 20, 20, 15, 5, -30,
  -30, 0, 10, 15, 15, 10, 0, -30,
  -40, -20, 0, 0, 0, 0, -20, -40,
  -50, -40, -30, -30, -30, -30, -40, -50,
}
PST[chess.BISHOP] = {
  -20, -10, -10, -10, -10, -10, -10, -20,
  -10, 5, 0, 0, 0, 0, 5, -10,
  -10, 10, 10, 10, 10, 10, 10, -10,
  -10, 0, 10, 10, 10, 10, 0, -10,
  -10, 5, 5, 10, 10, 5, 5, -10,
  -10, 0, 5, 10, 10, 5, 0, -10,
  -10, 0, 0, 0, 0, 0, 0, -10,
  -20, -10, -10, -10, -10, -10, -10, -20,
}
PST[chess.ROOK] = {
  0, 0, 0, 5, 5, 0, 0, 0,
  -5, 0, 0, 0, 0, 0, 0, -5,
  -5, 0, 0, 0, 0, 0, 0, -5,
  -5, 0, 0, 0, 0, 0, 0, -5,
  -5, 0, 0, 0, 0, 0, 0, -5,
  -5, 0, 0, 0, 0, 0, 0, -5,
  5, 10, 10, 10, 10, 10, 10, 5,
  0, 0, 0, 0, 0, 0, 0, 0,
}
PST[chess.QUEEN] = {
  -20, -10, -10, -5, -5, -10, -10, -20,
  -10, 0, 5, 0, 0, 0, 0, -10,
  -10, 5, 5, 5, 5, 5, 0, -10,
  0, 0, 5, 5, 5, 5, 0, -5,
  -5, 0, 5, 5, 5, 5, 0, -5,
  -10, 0, 5, 5, 5, 5, 0, -10,
  -10, 0, 0, 0, 0, 0, 0, -10,
  -20, -10, -10, -5, -5, -10, -10, -20,
}
PST[chess.KING] = {
  20, 30, 10, 0, 0, 10, 30, 20,
  20, 20, 0, 0, 0, 0, 20, 20,
  -10, -20, -20, -20, -20, -20, -20, -10,
  -20, -30, -30, -40, -40, -30, -30, -20,
  -30, -40, -40, -50, -50, -40, -40, -30,
  -30, -40, -40, -50, -50, -40, -40, -30,
  -30, -40, -40, -50, -50, -40, -40, -30,
  -30, -40, -40, -50, -50, -40, -40, -30,
}
engine.PST = PST
engine.PIECE_VALUE = PIECE_VALUE

-- Static evaluation in centipawns, positive when the side to move is better.
function engine.evaluate(pos)
  local score = 0
  for sq = 0, 63 do
    local piece = pos.squares[sq + 1]
    if piece ~= 0 then
      local type_ = chess.pieceType(piece)
      local white = not chess.isBlack(piece)
      local tableIndex = sq
      if not white then
        tableIndex = (7 - math.floor(sq / 8)) * 8 + chess.fileOf(sq)
      end
      local value = PIECE_VALUE[type_] + PST[type_][tableIndex + 1]
      score = score + (white and value or -value)
    end
  end
  return pos.white and score or -score
end

-- Most Valuable Victim minus Least Valuable Attacker: tries PxQ before QxP.
local function moveScore(pos, mv)
  local score = 0
  local flags_ = chess.mvFlags(mv)
  if band(flags_, chess.F_CAP) ~= 0 then
    local victim
    if band(flags_, chess.F_EP) ~= 0 then
      victim = chess.PAWN
    else
      victim = chess.pieceType(pos.squares[chess.mvTo(mv) + 1])
    end
    local attacker = chess.pieceType(pos.squares[chess.mvFrom(mv) + 1])
    score = score + 10000 + PIECE_VALUE[victim] * 10 - PIECE_VALUE[attacker]
  end
  if band(flags_, chess.F_PROMO) ~= 0 then
    score = score + 9000 + PIECE_VALUE[chess.mvPromo(mv)]
  end
  return score
end

-- Selection-sort of the single best remaining move into place at `index`.
local function pickBestTo(pos, list, n, index)
  local bestIndex = index
  local bestScore = moveScore(pos, list[index])
  for i = index + 1, n do
    local s = moveScore(pos, list[i])
    if s > bestScore then
      bestScore = s
      bestIndex = i
    end
  end
  if bestIndex ~= index then
    list[index], list[bestIndex] = list[bestIndex], list[index]
  end
end

local function negamax(pos, depth, alpha, beta, ply, ctx)
  if ctx.budget ~= 0 and ctx.nodes >= ctx.budget then
    ctx.budgetExhausted = true
    return engine.evaluate(pos)
  end
  ctx.nodes = ctx.nodes + 1

  if depth <= 0 then return engine.evaluate(pos) end

  local list = ctx.plies[ply]
  local n = chess.genLegal(pos, list)
  if n == 0 then
    return chess.isInCheck(pos) and (-engine.MATE + ply) or 0
  end

  local best = -engine.MATE * 2
  local undo = {}
  for i = 1, n do
    pickBestTo(pos, list, n, i)
    local mv = list[i]
    chess.makeMove(pos, mv, undo)
    local score = -negamax(pos, depth - 1, -beta, -alpha, ply + 1, ctx)
    chess.unmakeMove(pos, mv, undo)
    if score > best then best = score end
    if best > alpha then alpha = best end
    if alpha >= beta then break end
    if ctx.budgetExhausted then break end
  end
  return best
end

-- Searches to `depth` for the side to move. `budget` caps the nodes (0 = no
-- cap). Returns { best=packed move, score, nodes, budgetExhausted, hasMove }.
-- hasMove == false only when the position has no legal moves.
function engine.search(pos, depth, budget)
  if depth < 1 then depth = 1 end
  if depth > engine.MAX_DEPTH then depth = engine.MAX_DEPTH end

  local plies = {}
  for p = 0, depth do plies[p] = {} end

  local root = plies[0]
  local rootN = chess.genLegal(pos, root)
  local result = { best = 0, score = 0, nodes = 0, budgetExhausted = false, hasMove = false }
  if rootN == 0 then return result end

  local ctx = { plies = plies, nodes = 0, budget = budget or 0, budgetExhausted = false }
  local alpha = -engine.MATE * 2
  local beta = engine.MATE * 2
  local undo = {}
  for i = 1, rootN do
    pickBestTo(pos, root, rootN, i)
    local mv = root[i]
    chess.makeMove(pos, mv, undo)
    local score = -negamax(pos, depth - 1, -beta, -alpha, 1, ctx)
    chess.unmakeMove(pos, mv, undo)
    if not result.hasMove or score > result.score then
      result.best = mv
      result.score = score
      result.hasMove = true
      if score > alpha then alpha = score end
    end
    if ctx.budgetExhausted then break end
  end
  result.nodes = ctx.nodes
  result.budgetExhausted = ctx.budgetExhausted
  return result
end

return engine