-- The Hex opponent: flat Monte Carlo with RAVE at the root. Each playout fills
-- the empty board at random (a full Hex board has exactly one winner, so no
-- legality or scoring pass is needed) and reads the winner with one BFS.
-- Root moves are scored by their own playout results blended with the AMAF
-- (RAVE) results for the same cell, so the 121 root moves share what the
-- playouts learned. This is a root-only search, not the crossplay tree (see
-- docs/apps/hex.md for what was ported and what was not).
local core = require("hexcore")

local M = {}

local BLACK, WHITE = core.BLACK, core.WHITE
local POINTS = core.POINTS

-- Levels: EASY sees few playouts and picks loosely among the top few;
-- MEDIUM and HARD run to a playout count or a clock, whichever binds first.
M.LEVELS = {
  { name = "EASY",   playouts = 120,  budget = nil,  pick = 5 },
  { name = "MEDIUM", playouts = 700,  budget = 2500, pick = 1 },
  { name = "HARD",   playouts = 4000, budget = 4000, pick = 1 },
}

local RAVE_K = 300       -- RAVE equivalence parameter
local EXPLORE = 0.5      -- UCB weight on the root

local function blendScore(own_w, own_n, rv_w, rv_n, total)
  local own = own_n > 0 and own_w / own_n or 0.5
  local rave = rv_n > 0 and rv_w / rv_n or 0.5
  local alpha = RAVE_K / (RAVE_K + own_n)
  local v = alpha * rave + (1 - alpha) * own
  return v + EXPLORE * math.sqrt(math.log(total + 1) / (own_n + 1))
end

-- Choose a point for colour `me` on board `b` (not modified). Returns the
-- point index, or nil when the board is full.
function M.choose(b, me, level)
  local empties, ne = {}, 0
  for i = 1, POINTS do
    if b[i] == 0 then
      ne = ne + 1
      empties[ne] = i
    end
  end
  if ne == 0 then return nil end

  -- Take a win now, and block the opponent's win, before any search.
  if level.playouts >= 700 then
    local w = core.winningPoint(b, me)
    if w then return w end
    local block = core.winningPoint(b, core.other(me))
    if block then return block end
  end

  local own_w, own_n, rv_w, rv_n = {}, {}, {}, {}
  for i = 1, POINTS do
    own_w[i], own_n[i], rv_w[i], rv_n[i] = 0, 0, 0, 0
  end

  local sim = {}
  local started = level.budget and system.millis() or nil
  local seq = {}          -- playout order of empties, shuffled per playout
  for k = 1, ne do seq[k] = empties[k] end

  local total = 0
  for _ = 1, level.playouts do
    if started and system.millis() - started >= level.budget then break end
    total = total + 1

    -- Select the root move.
    local best, bestScore = nil, -1
    for k = 1, ne do
      local m = empties[k]
      local s = blendScore(own_w[m], own_n[m], rv_w[m], rv_n[m], total)
      if s > bestScore then bestScore, best = s, m end
    end
    local m = best

    -- Playout from the position with m played by me.
    for i = 1, POINTS do sim[i] = b[i] end
    sim[m] = me
    local mine, nm = { m }, 1
    -- shuffle the empties (Fisher-Yates) and drop m
    local k2 = 0
    for k = 1, ne do
      if empties[k] ~= m then
        k2 = k2 + 1
        seq[k2] = empties[k]
      end
    end
    local nLeft = k2
    for k = nLeft, 2, -1 do
      local j = math.random(k)
      seq[k], seq[j] = seq[j], seq[k]
    end
    local colour = core.other(me)
    local mineLog = nm
    for k = 1, nLeft do
      local p = seq[k]
      sim[p] = colour
      if colour == me then
        mineLog = mineLog + 1
        mine[mineLog] = p
      end
      colour = core.other(colour)
    end

    local won = core.connected(sim, me) and 1 or 0
    own_n[m] = own_n[m] + 1
    own_w[m] = own_w[m] + won
    for k = 1, mineLog do
      local p = mine[k]
      rv_n[p] = rv_n[p] + 1
      rv_w[p] = rv_w[p] + won
    end
  end

  -- Pick the most-visited root move (robust choice).
  local ranked = {}
  for k = 1, ne do ranked[k] = empties[k] end
  table.sort(ranked, function(a, b2)
    if own_n[a] ~= own_n[b2] then return own_n[a] > own_n[b2] end
    return a < b2
  end)
  local pool = math.min(level.pick, ne)
  return ranked[math.random(pool)]
end

return M
