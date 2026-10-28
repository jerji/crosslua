-- Sea Salt & Paper — the opponent's brain (port of SeaSaltBrain.cpp).
--
-- It takes an Observation, never a Game. An Observation has no field for
-- the opponent's unrevealed hand -- the deck and that hand collapse into
-- the same fog -- so this cannot cheat by construction rather than by
-- discipline.
--
-- No search. The hard decisions in this game are not deep: they are "is
-- this card worth more to me than an average draw", asked at every step,
-- and "am I far enough ahead to bet", asked once. Both are questions about
-- the value of cards, so the whole brain is one marginal-value function and
-- a handful of comparisons against it.
--
-- The C++ decide() takes an rng it never uses (the whole brain is
-- deterministic); the Lua port drops the parameter.

local game = require("game")
local M = {}

local VIEW = game.VIEW
local QUARTER = 4  -- the value scale: 4 units per point

-- The mermaid chase. A mermaid's printed value is a colour group, but its
-- real value bends sharply upward as the collection grows, because the
-- fourth one is the whole game. Quarter-points on top of the colour math.
local MERMAID_CHASE = { 2, 6, 14, 400 }

local function countUnseen(obs, kind)
  local n = game.SUPPLY[kind + 1]
  for c = 1, game.CARDS do
    if game.kindOf(c) ~= kind then
      -- not this kind
    elseif obs.view[c] ~= VIEW.UNKNOWN then n = n - 1 end
  end
  return n
end

-- What one more card of `kind` would add to my score, in quarter-points.
function M.marginalValue(obs, card)
  local kind = game.kindOf(card)
  local quarters = 0

  if kind <= 2 then  -- crab, boat, fish
    local held = game.observeCountMine(obs, kind)
    -- An odd count completes a pair: a point plus the effect's card
    -- advantage. An even count starts one: worth about half.
    quarters = quarters + (held % 2 == 1 and 6 or 3)
    if kind == 1 and game.observeCountMine(obs, 10) > 0 then quarters = quarters + QUARTER end
    if kind == 2 and game.observeCountMine(obs, 11) > 0 then quarters = quarters + QUARTER end
  elseif kind == 3 then  -- swimmer
    quarters = quarters + (game.observeCountMine(obs, 4) > game.observeCountMine(obs, 3) and 6 or 3)
  elseif kind == 4 then  -- shark
    quarters = quarters + (game.observeCountMine(obs, 3) > game.observeCountMine(obs, 4) and 6 or 3)
  elseif kind == 5 then  -- shell
    local held = game.observeCountMine(obs, 5)
    quarters = quarters + (game.SHELL_SCORE[held + 2] - game.SHELL_SCORE[held + 1]) * QUARTER
    if held == 0 then quarters = quarters + 2 end  -- the first shell opens the ladder
  elseif kind == 6 then  -- octopus
    local held = game.observeCountMine(obs, 6)
    quarters = quarters + (game.OCTOPUS_SCORE[held + 2] - game.OCTOPUS_SCORE[held + 1]) * QUARTER
    if held == 0 then quarters = quarters + 2 end
  elseif kind == 7 then  -- penguin
    local held = game.observeCountMine(obs, 7)
    quarters = quarters + (game.PENGUIN_SCORE[held + 2] - game.PENGUIN_SCORE[held + 1]) * QUARTER
    if game.observeCountMine(obs, 12) > 0 then quarters = quarters + 2 * QUARTER end
  elseif kind == 8 then  -- sailor
    local held = game.observeCountMine(obs, 8)
    quarters = quarters + (game.SAILOR_SCORE[held + 2] - game.SAILOR_SCORE[held + 1]) * QUARTER
    if game.observeCountMine(obs, 13) > 0 then quarters = quarters + 3 * QUARTER end
  elseif kind == 9 then  -- mermaid
    local best = 0
    for i = 1, #game.COLOURS do
      local n = game.observeCountMineColour(obs, i - 1)
      if n > best then best = n end
    end
    quarters = quarters + best * QUARTER + MERMAID_CHASE[game.observeCountMine(obs, 9) + 1]
  elseif kind == 10 then
    quarters = quarters + game.observeCountMine(obs, 1) * QUARTER + 2
  elseif kind == 11 then
    quarters = quarters + game.observeCountMine(obs, 2) * QUARTER + 2
  elseif kind == 12 then
    quarters = quarters + 2 * game.observeCountMine(obs, 7) * QUARTER + 2
  elseif kind == 13 then
    quarters = quarters + 3 * game.observeCountMine(obs, 8) * QUARTER + 2
  end

  -- The colour tiebreak: a card that feeds my biggest group nudges the
  -- bonus and the mermaids. One unit, so it never outranks a real point.
  local inColour = game.observeCountMineColour(obs, game.colourOf(card))
  if inColour >= 2 then quarters = quarters + 1 end
  if inColour >= 2 and game.observeCountMine(obs, 9) > 0 then quarters = quarters + 1 end

  return quarters
end

local function averageUnseenValue(obs)
  local total, cards = 0, 0
  for kind = 0, 13 do
    local n = countUnseen(obs, kind)
    if n == 0 then
      -- skip
    else
      -- Value it as if *I* drew it: close enough for both uses, and
      -- honest -- valuing it for them would need their hand, the fog.
      local sample = 1
      for c = 1, game.CARDS do
        if game.kindOf(c) == kind then sample = c break end
      end
      total = total + n * M.marginalValue(obs, sample)
      cards = cards + n
    end
  end
  return cards > 0 and (total // cards) or 0
end

-- The top card of one of my piles and its marginal value.
local function myPileValue(obs, pileView)
  local best, bestAt, bestSeq = -1, game.NO_CARD, 0
  for c = 1, game.CARDS do
    if obs.view[c] ~= pileView then
      -- skip
    elseif obs.seq[c] < bestSeq then
      -- not the top
    else
      bestSeq = obs.seq[c]
      bestAt = c
    end
  end
  if bestAt ~= game.NO_CARD then best = M.marginalValue(obs, bestAt) end
  return best, bestAt
end

-- The Navigator's estimate of the opponent's card points: their table,
-- which is public, plus fog cards at what a drafted hand of that size is
-- actually worth (measured over 400 brain-vs-brain matches; see the doc).
function M.estimateTheirPoints(obs)
  local points = game.observeCountView(obs, VIEW.THERTABLE, 0) // 2
  points = points + game.observeCountView(obs, VIEW.THERTABLE, 1) // 2
  points = points + game.observeCountView(obs, VIEW.THERTABLE, 2) // 2
  local sw = game.observeCountView(obs, VIEW.THERTABLE, 3)
  local sh = game.observeCountView(obs, VIEW.THERTABLE, 4)
  points = points + (sw < sh and sw or sh)

  if obs.theirRevealed == 1 then
    -- Revealed is not fog: count their hand for real.
    points = points + game.SHELL_SCORE[game.observeCountView(obs, VIEW.THEIRHAND, 5) + 1]
    points = points + game.OCTOPUS_SCORE[game.observeCountView(obs, VIEW.THEIRHAND, 6) + 1]
    points = points + game.PENGUIN_SCORE[game.observeCountView(obs, VIEW.THEIRHAND, 7) + 1]
    points = points + game.SAILOR_SCORE[game.observeCountView(obs, VIEW.THEIRHAND, 8) + 1]
    points = points + game.observeCountView(obs, VIEW.THEIRHAND, 0) // 2
    points = points + game.observeCountView(obs, VIEW.THEIRHAND, 1) // 2
    points = points + game.observeCountView(obs, VIEW.THEIRHAND, 2) // 2
    return points
  end

  -- Fog cards at what a drafted hand of that size is actually worth. The
  -- shipped estimate: a drafted hand is worth roughly h(h+1)/6 up to eight
  -- cards, then about 1.7 per card after.
  local DRAFTED = { 0, 0, 1, 2, 4, 5, 7, 9, 11, 13, 15, 16, 18 }
  local h = obs.theirHandSize
  if h < 13 then
    points = points + DRAFTED[h + 1]
  else
    points = points + 18 + (17 * (h - 12)) // 10
  end
  return points
end

local function act(a, arg)
  return { act = a, a = arg or 0, kind = 0 }
end

-- The decision this opponent makes in the state the observation describes.
-- Always one the core will accept; the soak drives whole matches through
-- it and asserts exactly that. skill: "beachcomber" or "navigator".
function M.decide(obs, skill)
  local step = obs.step

  if step == game.STEP.TAKE then
    local best, topA, topB = -1, game.NO_CARD, game.NO_CARD
    local va, _ = myPileValue(obs, VIEW.PILEA)
    local vb, _ = myPileValue(obs, VIEW.PILEB)
    local pile
    if va > vb then best, pile = va, 0 else best, pile = vb, 1 end
    if va > vb then topA = _ end
    -- (top cards unused: piles are compared by value only, as in the C++)
    if obs.deckRemaining == 0 then
      if best < 0 then return act("endTurn") end  -- nothing to take
      return act("takePile", pile)
    end
    -- Drawing two and keeping the better is worth more than the average
    -- draw; five quarters of margin approximates that edge.
    if best >= averageUnseenValue(obs) + 5 then return act("takePile", pile) end
    return act("takeDeck")
  end

  if step == game.STEP.CHOOSEKEEP then
    local v0 = obs.drawn[1] ~= game.NO_CARD and M.marginalValue(obs, obs.drawn[1]) or -1
    local v1 = obs.drawn[2] ~= game.NO_CARD and M.marginalValue(obs, obs.drawn[2]) or -1
    return act("keep", v1 > v0 and 2 or 1)
  end

  if step == game.STEP.CHOOSEPILE then
    -- The discard becomes takeable, so put it where it covers the top the
    -- opponent would most want. Their want is fog; the honest proxy is the
    -- card's general value, which is mine.
    local coverA = myPileValue(obs, VIEW.PILEA)
    local coverB = myPileValue(obs, VIEW.PILEB)
    return act("discardTo", coverA >= coverB and 0 or 1)
  end

  if step == game.STEP.CRABPILE then
    -- The dig takes any card in the pile, so compare the piles by their
    -- best card, not their top.
    local bestA, bestB = -1, -1
    for c = 1, game.CARDS do
      if obs.view[c] == VIEW.PILEA then
        local v = M.marginalValue(obs, c)
        if v > bestA then bestA = v end
      elseif obs.view[c] == VIEW.PILEB then
        local v = M.marginalValue(obs, c)
        if v > bestB then bestB = v end
      end
    end
    return act("digPile", bestA >= bestB and 0 or 1)
  end

  if step == game.STEP.CRABPICK then
    -- Only the pile the dig chose is legal, and the observation says which
    -- one that is.
    local pile = obs.crabPile == 0 and VIEW.PILEA or VIEW.PILEB
    local bestCard, best = game.NO_CARD, -1
    for c = 1, game.CARDS do
      if obs.view[c] ~= pile then
        -- skip
      else
        local value = M.marginalValue(obs, c)
        if value > best then best, bestCard = value, c end
      end
    end
    return act("digCard", bestCard)
  end

  if step == game.STEP.PLAY then
    -- Lay every pair whose effect can fire: each one is card advantage and
    -- none of them moves the score. Boats first -- the extra turn compounds.
    if game.observeCountView(obs, VIEW.MYHAND, 1) >= 2 then
      local d = act("layDuo")
      d.kind = 1
      return d
    end
    if game.observeCountView(obs, VIEW.MYHAND, 2) >= 2 and obs.deckRemaining > 0 then
      local d = act("layDuo")
      d.kind = 2
      return d
    end
    local pilesHaveCards = myPileValue(obs, VIEW.PILEA) >= 0 or myPileValue(obs, VIEW.PILEB) >= 0
    if game.observeCountView(obs, VIEW.MYHAND, 0) >= 2 and pilesHaveCards then
      local d = act("layDuo")
      d.kind = 0
      return d
    end
    -- The steal, only when it will actually take something.
    if game.observeCountView(obs, VIEW.MYHAND, 3) >= 1 and game.observeCountView(obs, VIEW.MYHAND, 4) >= 1 and
        obs.theirHandSize > 0 and obs.theirRevealed == 0 then
      local d = act("layDuo")
      d.kind = 3  -- swimmer+shark
      return d
    end

    -- The round-ending decision. Only offered while the phase allows it.
    if obs.phase == game.PHASE.PLAYING then
      local mine = game.observeMyPoints(obs)
      if mine >= game.MIN_END then
        if skill == "beachcomber" then
          -- Stops when clearly worth banking; never bets.
          if mine >= 10 or obs.deckRemaining <= 6 then return act("stop") end
        else
          local theirs = M.estimateTheirPoints(obs)
          -- The deck running out wipes everybody, so a lead near the end
          -- is a lead you must bank now.
          if obs.deckRemaining <= 4 and mine > theirs then return act("stop") end
          -- Bet only with margin: the bet wins ties, but their final turn
          -- will grow their hand by a card or two.
          if mine >= theirs + 3 then return act("lastChance") end
          if mine >= theirs and mine >= 10 then return act("stop") end
        end
      end
      -- Behind with the deck dying: play toward the deck-out, which scores
      -- nobody and keeps a banked lead intact.
    end
    return act("endTurn")
  end

  return act("endTurn")
end

return M