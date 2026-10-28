-- The Go opponent for the X4: a Lua stand-in for michi-c2. Random playouts
-- with RAVE at the root, the same shape as the Hex brain. Playouts avoid
-- filling their own eyes and capture when they can. Area scoring decides
-- each playout. It is NOT michi-c2 (see docs/apps/go.md): the Lua runtime has
-- no native bridge for it, and this engine is far weaker.
local co = require("goco")

local M = {}

M.LEVELS = {
  { name = "EASY",   playouts = 60,  budget = nil,  pick = 4 },
  { name = "MEDIUM", playouts = 250, budget = 2500, pick = 1 },
  { name = "HARD",   playouts = 800, budget = 4000, pick = 1 },
}

local RAVE_K = 300
local EXPLORE = 0.5

local function copy(b, nn)
  local t = {}
  for i = 1, nn do t[i] = b[i] end
  return t
end

-- One random playout from board b0 after `me` plays m. Fills `mine` with the
-- points me played (for RAVE). Returns true when me wins on area.
local function playout(b0, n, toMove, m, me, mine)
  local nn = n * n
  local cur, ko = co.tryPlay(b0, n, m, me)
  if not cur then return nil end
  mine[1] = m
  local nm = 1
  local turn = co.other(me)
  local passes = 0
  for _ = 1, nn * 2 do
    local start = math.random(nn)
    local played = false
    for k = 0, nn - 1 do
      local p = (start + k - 1) % nn + 1
      if cur[p] == 0 and p ~= ko and not co.fillsOwnEye(cur, n, p, turn) then
        local nb3, ko3 = co.tryPlay(cur, n, p, turn)
        if nb3 then
          cur, ko = nb3, ko3
          played = true
          if turn == me then
            nm = nm + 1
            mine[nm] = p
          end
          break
        end
      end
    end
    if played then
      passes = 0
    else
      passes = passes + 1
      if passes >= 2 then break end
    end
    turn = co.other(turn)
  end
  local margin = co.margin(cur, n)
  local won = (me == 1 and margin > 0) or (me == 2 and margin < 0)
  return won, nm
end

-- Choose a move for colour `me` in state st. Returns a point index or "pass".
function M.choose(st, me, lvl)
  local n = st.n
  local nn = n * n
  local cands = {}
  for p = 1, nn do
    if st.b[p] == 0 and not co.fillsOwnEye(st.b, n, p, me) and co.legal(st, p, me) then
      cands[#cands + 1] = p
    end
  end
  if #cands == 0 then return "pass" end

  -- Pass only when the opponent just passed and we already win on area.
  local margin = co.margin(st.b, n)
  if st.lastPass and ((me == 1 and margin > 0) or (me == 2 and margin < 0)) then
    return "pass"
  end

  local own_w, own_n, rv_w, rv_n = {}, {}, {}, {}
  for p = 1, nn do own_w[p], own_n[p], rv_w[p], rv_n[p] = 0, 0, 0, 0 end

  local started = lvl.budget and system.millis() or nil
  local mine = {}
  local total = 0
  for _ = 1, lvl.playouts do
    if started and system.millis() - started >= lvl.budget then break end
    total = total + 1
    local best, bestScore = nil, -1
    for _, m in ipairs(cands) do
      local own = own_n[m] > 0 and own_w[m] / own_n[m] or 0.5
      local rave = rv_n[m] > 0 and rv_w[m] / rv_n[m] or 0.5
      local alpha = RAVE_K / (RAVE_K + own_n[m])
      local s = alpha * rave + (1 - alpha) * own
              + EXPLORE * math.sqrt(math.log(total + 1) / (own_n[m] + 1))
      if s > bestScore then bestScore, best = s, m end
    end
    local won, nm = playout(st.b, n, st.turn, best, me, mine)
    if won ~= nil then
      local w = won and 1 or 0
      own_n[best] = own_n[best] + 1
      own_w[best] = own_w[best] + w
      for k = 1, nm do
        local p = mine[k]
        rv_n[p] = rv_n[p] + 1
        rv_w[p] = rv_w[p] + w
      end
    end
  end

  -- Robust choice: the most-visited candidate (ties by point index).
  local ranked = copy(cands, #cands)
  table.sort(ranked, function(a, b)
    if own_n[a] ~= own_n[b] then return own_n[a] > own_n[b] end
    return a < b
  end)
  local pool = math.min(lvl.pick, #ranked)
  return ranked[math.random(pool)]
end

return M
