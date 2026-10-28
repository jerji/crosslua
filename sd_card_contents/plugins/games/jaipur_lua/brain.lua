-- brain.lua -- the Jaipur opponent, ported from crossplay's JaipurBrain.
--
-- It is handed an Observation, never a Game: the observation has no field for
-- the opponent's hand composition, only opponentHandSize, so this cannot cheat
-- by construction. What it knows is what a person sitting opposite would know.
-- No search -- one ply and an evaluation that knows what a Jaipur position is
-- worth. Moves are visited rather than collected; nothing is materialised.

local core = require("core")

local brain = {}

local function hand_size(obs)
  local n = 0
  for g = 0, core.GOOD_COUNT - 1 do n = n + obs.hand[g] end
  return n
end

local function market_camels(obs)
  local n = 0
  for i = 0, core.MARKET_SLOTS - 1 do
    if obs.market[i] == core.CAMEL then n = n + 1 end
  end
  return n
end

local function popcount(v)
  local n = 0
  while v ~= 0 do v = v & (v - 1); n = n + 1 end
  return n
end

-- Every way to give `need` goods out of the hand, skipping the types the
-- market is giving back. Recursive over the six types, at most six deep.
local function give_combinations(obs, taken, first_good, need, move, fn)
  if need == 0 then fn(move); return end
  if first_good >= core.GOOD_COUNT then return end
  local g = first_good
  local most = 0
  if (taken[g] or 0) == 0 then
    most = obs.hand[g] < need and obs.hand[g] or need
  end
  for n = 0, most do
    move.give[g] = n
    give_combinations(obs, taken, g + 1, need - n, move, fn)
  end
  move.give[g] = 0
end

-- Visits every legal move from the observation: take one, take all camels,
-- sell, and every exchange. fn(move) receives a fresh table per call.
local function for_each_legal_move(obs, fn)
  local held = hand_size(obs)

  -- A: take one good, and only with room in hand.
  if held < core.HAND_LIMIT then
    for i = 0, core.MARKET_SLOTS - 1 do
      if obs.market[i] < core.GOOD_COUNT then -- not camel/empty/unknown
        fn({ kind = core.TAKE_ONE, slot = i })
      end
    end
  end

  -- B: take every camel. All or nothing, never mixed with goods.
  if market_camels(obs) > 0 then
    fn({ kind = core.TAKE_CAMELS })
  end

  -- C: sell. Diamonds, gold and silver need two.
  for g = 0, core.GOOD_COUNT - 1 do
    local lowest = core.sells_in_pairs(g) and 2 or 1
    for n = lowest, obs.hand[g] do
      fn({ kind = core.SELL, good = g, count = n })
    end
  end

  -- D: exchange. Every market subset of two or more goods against every way
  -- of paying for it out of the hand and the herd.
  for mask = 0, (1 << core.MARKET_SLOTS) - 1 do
    local want = 0
    local taken = {}
    local usable = true
    for i = 0, core.MARKET_SLOTS - 1 do
      if ((mask >> i) & 1) ~= 0 then
        local card = obs.market[i]
        -- Camels can be given in an exchange but never taken in one; an
        -- empty or unseen slot holds nothing to take.
        if card >= core.GOOD_COUNT then usable = false; break end
        taken[card] = (taken[card] or 0) + 1
        want = want + 1
      end
    end
    if usable and want >= 2 then
      local max_camels = obs.herd[obs.seat]
      if want < max_camels then max_camels = want end
      for camels = 0, max_camels do
        -- Giving camels grows the hand, so the limit is checked on the result.
        if held + camels <= core.HAND_LIMIT then
          local move = {
            kind = core.EXCHANGE, marketMask = mask, giveCamels = camels, give = {},
          }
          give_combinations(obs, taken, 0, want - camels, move, fn)
        end
      end
    end
  end
end

-- What the cards in hand are worth if sold right now: token piles only go
-- down, so today's price is the only honest one.
local function hand_value(obs)
  local total = 0
  for g = 0, core.GOOD_COUNT - 1 do
    local depth = obs.goodsDepth[g]
    for _ = 1, obs.hand[g] do
      if depth >= core.PILE_DEPTH[g + 1] then break end
      total = total + core.TOKENS[g + 1][depth + 1]
      depth = depth + 1
    end
  end
  return total
end

-- The mean value still sitting in a bonus stack: its face is down, so a mean
-- is all anyone can use.
local function mean_bonus(stack)
  local total = 0
  for i = 1, core.BONUS_DEPTH[stack + 1] do
    total = total + core.BONUS_TOKENS[stack + 1][i]
  end
  return total // core.BONUS_DEPTH[stack + 1]
end

-- What a position is worth to obs.seat, in rupees-ish units, scaled by 16 so
-- the fractional weights stay in integers. Banked rupees carry full weight;
-- everything else is a discount against them.
local function evaluate(obs)
  local me = obs.seat
  local them = 1 - me
  local score = (obs.yourGoodsRupees + obs.yourBonusRupees) * 16
  score = score - obs.theirGoodsRupees * 16
  -- Their bonus tokens are face down; the count is public and the stacks are
  -- known, so the mean of everything still unclaimed is the fair estimate.
  score = score - obs.theirBonusCount * ((mean_bonus(0) + mean_bonus(1) + mean_bonus(2)) // 3) * 16

  -- Cards in hand, worth what they would fetch discounted because turning
  -- them into rupees costs turns and the piles may fall first.
  score = score + hand_value(obs) * 11

  -- A run worth a bonus token. Three is the threshold that pays; the jump
  -- from four to five is the biggest in the game, so the reward is not linear.
  for g = 0, core.GOOD_COUNT - 1 do
    local n = obs.hand[g]
    if n >= 5 then
      score = score + mean_bonus(2) * 14
    elseif n == 4 then
      score = score + mean_bonus(1) * 12
    elseif n == 3 then
      score = score + mean_bonus(0) * 10
    elseif n == 2 and not core.sells_in_pairs(g) then
      score = score + 6 -- two of a cheap good is a start on a run
    end
  end

  -- The camel token and the trading power a herd represents. Ahead holds the
  -- 5 rupees; one behind is worth chasing, four behind is not.
  local lead = obs.herd[me] - obs.herd[them]
  if lead > 0 then
    score = score + core.CAMEL_TOKEN * 16
  elseif lead == 0 then
    score = score + core.CAMEL_TOKEN * 6
  elseif lead >= -2 then
    score = score + core.CAMEL_TOKEN * 3
  end
  local herd = obs.herd[me]
  if herd > 5 then herd = 5 end -- a huge herd is mostly dead weight
  score = score + herd * 4

  -- Room to manoeuvre: a full hand cannot take.
  score = score + (core.HAND_LIMIT - hand_size(obs)) * 3
  return score
end

-- Copies a move: the visited move tables are reused and mutated by
-- give_combinations, so anything retained (a collected list, the best move)
-- must be a fresh table, like the C++ value type.
local function copy_move(m)
  local give = {}
  for g = 0, core.GOOD_COUNT - 1 do give[g] = m.give and m.give[g] or 0 end
  return {
    kind = m.kind, slot = m.slot, good = m.good, count = m.count,
    marketMask = m.marketMask, giveCamels = m.giveCamels, give = give,
  }
end

-- Every legal move from an observation, collected (for tests and the UI).
function brain.legal_moves(obs)
  local out = {}
  for_each_legal_move(obs, function(m) out[#out + 1] = copy_move(m) end)
  return out
end

-- The move this opponent would play. Always legal against the game the
-- observation came from; falls back to the least bad legal move. rng is a
-- table {v = ...} that is mutated, so a fixed start value replays the match.
function brain.choose_move(obs, skill, rng)
  local best = nil
  local best_score = 0
  for_each_legal_move(obs, function(move)
    local next = core.after(obs, move)
    local score = evaluate(next)

    if skill == core.SKILL_MAHARAJA then
      -- Racing the round's end. Three empty piles stops it immediately, so
      -- emptying one is worth chasing when ahead and avoiding when behind.
      local ahead = (next.yourGoodsRupees + next.yourBonusRupees) - next.theirGoodsRupees
      if next.emptyPiles > obs.emptyPiles then
        score = score + (ahead > 0 and 40 or -40)
      end
      -- Leaving the market rich is a gift: what is on the table after this
      -- move is what the opponent gets to choose from.
      local gift = 0
      for i = 0, core.MARKET_SLOTS - 1 do
        local card = next.market[i]
        if card < core.GOOD_COUNT then
          local d = next.goodsDepth[card]
          local pd = core.PILE_DEPTH[card + 1]
          if d >= pd then d = pd - 1 end
          gift = gift + core.TOKENS[card + 1][d + 1]
        end
      end
      score = score - gift * 2
    end

    -- A deterministic opponent is a solved opponent by the third game. The
    -- jitter is small enough never to pick a clearly worse move.
    core.roll(rng)
    score = score + (rng.v % 7)

    if not best or score > best_score then
      best = copy_move(move)
      best_score = score
    end
  end)

  -- Every reachable position has a legal move; this is the belt to that
  -- braces.
  if not best then return { kind = core.TAKE_CAMELS } end
  return best
end

return brain