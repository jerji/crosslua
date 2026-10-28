-- underhand_lua/engine.lua
-- Port of the crossplay UnderhandEngine.cpp. A Game is a plain table; the
-- same random numbers are drawn in the same order (Random::below), so a seed
-- reproduces the same deck. Resource order is the C++ enum: 1 relic,
-- 2 money, 3 cultist, 4 food, 5 prisoner, 6 suspicion.
local M = {}

-- ids the rules name in code
M.TUTORIAL = 71
M.RUMORS = 29
M.RUMORS_DEPTH = 5
M.GREED = 56
M.POLICE = 2
M.DESPERATE = 27
M.ALWAYS_DEALT = { 27, 29, 57, 79, 85, 106 }
M.TIERS = { { 85, 3 }, { 106, 3 }, { 79, 5 }, { 57, 5 } }

M.CHOOSING, M.FORESIGHT, M.WON, M.LOST = 0, 1, 2, 3
M.LOSS_NONE, M.LOSS_CHOICE, M.LOSS_STUCK, M.LOSS_NOCARDS, M.LOSS_GAVEUP = 0, 1, 2, 3, 4
M.REL, M.MONEY, M.CULTIST, M.FOOD, M.PRISONER, M.SUS = 1, 2, 3, 4, 5, 6
M.PILE_CAP = 200
M.KON = 840 -- "payable only while you hold none"
M.KHALF = 420 -- "half of what you hold, rounded up"

local KON, KHALF = M.KON, M.KHALF
local function total(c)
  return c[1] + c[2] + c[3] + c[4] + c[5] + c[6]
end
local function min(a, b) if a < b then return a end return b end
local function isPunishment(id) return id == M.GREED or id == M.POLICE or id == M.DESPERATE end

local function alwaysDealt(id)
  for _, a in ipairs(M.ALWAYS_DEALT) do if a == id then return true end end
  return false
end

-- The three rolls' chances with this hand, in percent.
local function oddsFor(held)
  local function curve(n, threshold)
    if n < threshold then return 0 end
    local percent = 35 + 15 * (n - threshold)
    if percent < 100 then return percent end
    return 100
  end
  return curve(total(held), 16), curve(held[M.SUS], 5), held[M.FOOD] == 0 and 20 or 0
end

local function onTable(game, cards, k)
  local card = cards.card(game.card)
  return card ~= nil and k >= 1 and k <= card.optCount
end

local function satisfiable(game, cards, k)
  local card = cards.card(game.card)
  return M.satisfiability(game.cost[k], card.opts[k].swap, game.held) < 1 and total(game.held) >= card.opts[k].randomCost
end

local function drawTop(game, cards, random)
  if #game.draw == 0 then M.detail.reshuffle(game, cards, random) end
  if #game.draw == 0 then return 0 end
  return table.remove(game.draw)
end

local function anyAffordable(game, cards)
  local card = cards.card(game.card)
  for k = 1, card.optCount do
    if M.affordable(game, cards, k) then return true end
  end
  return false
end

-- After a choice: foresight discards, then the played card, then the next.
local function advance(game, cards, random)
  local above = 0
  if game.tutorial and game.seenCount > 0 then
    for a = 1, game.addedCount do above = above + game.added[a][2] end
  end
  local removed = 0
  for i = 0, game.seenCount - 1 do
    if game.discardMask & (1 << i) ~= 0 then
      local at0 = #game.draw - 1 - above - (i - removed) -- 0-based from bottom
      if at0 >= 0 then game.discard[#game.discard + 1] = table.remove(game.draw, at0 + 1) end
      removed = removed + 1
    end
  end
  game.seenCount = 0
  game.discardMask = 0
  if cards.card(game.card).recurring then game.discard[#game.discard + 1] = game.card end
  M.detail.nextCard(game, cards, random)
end

M.detail = {}

-- DeckModel::reshuffle. The remaining draw pile joins the discard pile, the
-- pool is shuffled (Fisher-Yates, below(n - i) each), then rebuilt one pick
-- at a time with chance proportional to weight; the first pick is the
-- bottom of the new draw pile.
function M.detail.reshuffle(game, cards, random)
  local pool = {}
  local draw = game.draw
  local moved = min(#draw, M.PILE_CAP - #game.discard)
  for i = 1, moved do pool[i] = draw[i] end
  for i = 1, #game.discard do pool[moved + i] = game.discard[i] end
  game.discard = pool
  game.draw = {}
  local n = #pool
  for i = 1, n - 1 do
    local j = i + random:below(n - i + 1)
    pool[i], pool[j] = pool[j], pool[i]
  end
  local weight = 0
  for i = 1, #pool do weight = weight + cards.card(pool[i]).weight end
  local ndraw = {}
  while #pool > 0 do
    local r = random:below(weight)
    local sum, pick = 0, 1
    for i = 1, #pool do
      sum = sum + cards.card(pool[i]).weight
      if sum > r then pick = i break end
    end
    weight = weight - cards.card(pool[pick]).weight
    table.insert(ndraw, 1, table.remove(pool, pick))
  end
  game.draw = ndraw
  game.reshuffled = true
end

-- DeckController::resolvePunishments: at most one, on top of the deck.
function M.detail.punish(game, random)
  local greed, police, desperate = oddsFor(game.held)
  if greed > 0 and random:below(100) < greed then
    game.draw[#game.draw + 1] = M.GREED
  elseif police > 0 and random:below(100) < police then
    game.draw[#game.draw + 1] = M.POLICE
  elseif desperate > 0 and random:below(100) < desperate then
    game.draw[#game.draw + 1] = M.DESPERATE
  end
end

-- DeckController::createOptionModelFromOption, for each option on the card:
-- resolve sentinel costs, roll the random shuffles, lock losing options
-- while another can be paid.
function M.detail.resolve(game, cards, random)
  local card = cards.card(game.card)
  for k = 1, 3 do
    game.cost[k] = { 0, 0, 0, 0, 0, 0 }
    game.gain[k] = { 0, 0, 0, 0, 0, 0 }
    game.rolled[k] = { 0, 0, 0, 0 }
    if k <= card.optCount then
      local o = card.opts[k]
      for r = 1, 6 do
        local heldR = game.held[r]
        local cost = o.cost[r]
        if cost == KON then
          cost = heldR > 0 and KON or 0
        elseif cost == KHALF then
          cost = (heldR + 1) // 2
        end
        game.cost[k][r] = cost
        game.gain[k][r] = o.gain[r] == KHALF and ((heldR + 1) // 2) or o.gain[r]
      end
      local span = o.rollHigh - o.rollLow + 1
      for j = 0, o.rollCount - 1 do
        local id = o.rollLow + random:below(span)
        if not o.rollRepeats then
          local again = 0
          while again < j do
            if game.rolled[k][again + 1] == id then
              id = o.rollLow + random:below(span)
              again = 0
            else
              again = again + 1
            end
          end
        end
        game.rolled[k][j + 1] = id
      end
    end
  end
  local open = {}
  for k = 1, card.optCount do open[k] = satisfiable(game, cards, k) end
  game.lockedMask = 0
  for k = 1, card.optCount do
    if card.opts[k].lose then
      local other = false
      for j = 1, card.optCount do if j ~= k and open[j] then other = true break end end
      if other then
        game.cost[k] = { KON, KON, KON, KON, KON, KON }
        open[k] = false
        game.lockedMask = game.lockedMask | (1 << (k - 1))
      end
    end
  end
end

-- DeckController::nextEventCard.
function M.detail.nextCard(game, cards, random)
  if game.card ~= 0 and not game.tutorial and not isPunishment(game.card) then
    M.detail.punish(game, random)
  end
  game.card = drawTop(game, cards, random)
  game.phase = M.CHOOSING
  if game.card == 0 then
    game.phase = M.LOST
    game.loss = M.LOSS_NOCARDS
    return
  end
  M.detail.resolve(game, cards, random)
  game.turn = game.turn + 1
  if not anyAffordable(game, cards) then
    game.phase = M.LOST
    game.loss = M.LOSS_STUCK
  end
end

-- OptionModel::satisfiability: 0 when offer pays cost exactly, below 0 when
-- it pays too much, 1 when it falls short.
function M.satisfiability(cost, swap, offer)
  local need = { cost[1], cost[2], cost[3], cost[4], cost[5], cost[6] }
  if swap then
    need[M.CULTIST] = need[M.CULTIST] + need[M.PRISONER]
    need[M.PRISONER] = 0
    offer = { offer[1], offer[2], offer[3], offer[4], offer[5], offer[6] }
    offer[M.CULTIST] = offer[M.CULTIST] + offer[M.PRISONER]
    offer[M.PRISONER] = 0
  end
  for r = M.MONEY, M.SUS do need[r] = need[r] - offer[r] end
  -- relics pay a relic cost first, then any shortfall, in resource order
  local relics = offer[M.REL]
  for r = 1, 6 do
    if relics > 0 and need[r] > 0 then
      local use = min(need[r], relics)
      need[r] = need[r] - use
      relics = relics - use
    end
  end
  need[M.REL] = need[M.REL] - relics
  local sum = 0
  for r = 1, 6 do
    if need[r] > 0 then return 1 end
    sum = sum + need[r]
  end
  return sum -- 0 exact, < 0 overpaid
end

-- A new run: starting hand, the deck dealt, the first card drawn.
function M.start(game, cards, profile, random)
  game.held = { 0, 0, 0, 0, 0, 0 }
  game.draw = {}
  game.discard = {}
  game.cost = { { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0 } }
  game.gain = { { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0 } }
  game.rolled = { { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 } }
  game.lockedMask = 0
  game.card = 0
  game.phase = M.CHOOSING
  game.loss = M.LOSS_NONE
  game.god = -1
  game.seen = { 0, 0, 0 }
  game.seenCount = 0
  game.discardMask = 0
  game.mayDiscard = false
  game.played = 0
  game.playedOption = -1
  game.paid = { 0, 0, 0, 0, 0, 0 }
  game.lost = { 0, 0, 0, 0, 0, 0 }
  game.gained = { 0, 0, 0, 0, 0, 0 }
  game.added = {}
  game.addedCount = 0
  game.reshuffled = false
  game.turn = 0
  game.tutorial = not profile.tutorialDone
  if not game.tutorial then
    game.held = { 0, 2, 2, 2, 2, 0 }
  end
  -- DeckController::compileDeck, with StartupController::init's tiers
  local gods = 0
  local bits = profile.summoned
  while bits ~= 0 do gods = gods + 1; bits = bits & (bits - 1) end
  local coin, sure = {}, {}
  for id = 1, 255 do
    local c = cards.card(id)
    if c then
      local dealt = c.initial
      for _, tier in ipairs(M.TIERS) do
        if tier[1] == id and gods >= tier[2] then dealt = true end
      end
      if dealt then
        if alwaysDealt(id) then sure[#sure + 1] = id else coin[#coin + 1] = id end
      end
    end
  end
  if profile.previous >= 0 and profile.previous < cards.godCount() then
    local g = cards.god(profile.previous + 1)
    if g then
      for _, uid in ipairs(g.unlock) do sure[#sure + 1] = uid end
    end
  end
  profile.previous = -1
  -- DeckModel::init
  for i = 1, #coin do
    if random:below(2) == 0 then game.draw[#game.draw + 1] = coin[i] end
  end
  for i = 1, #sure do game.draw[#game.draw + 1] = sure[i] end
  M.detail.reshuffle(game, cards, random)
  game.reshuffled = false
  local at = #game.draw - random:below(M.RUMORS_DEPTH)
  if at < 0 then at = 0 end
  table.insert(game.draw, at + 1, M.RUMORS)
  if game.tutorial then game.draw[#game.draw + 1] = M.TUTORIAL end
  M.detail.nextCard(game, cards, random)
end

local function punishmentOddsFor(game, hand)
  if game.tutorial or isPunishment(game.card) then return 0, 0, 0 end
  return oddsFor(hand)
end

function M.punishmentOdds(game, hand)
  return punishmentOddsFor(game, hand or game.held)
end

function M.affordable(game, cards, k)
  return game.phase == M.CHOOSING and onTable(game, cards, k) and satisfiable(game, cards, k)
end

function M.exact(game, cards, k, offer)
  if not M.affordable(game, cards, k) then return false end
  for r = 1, 6 do
    if offer[r] < 0 or offer[r] > game.held[r] then return false end
  end
  return M.satisfiability(game.cost[k], cards.card(game.card).opts[k].swap, offer) == 0
end

function M.suggest(game, cards, k, out)
  if not M.affordable(game, cards, k) then return false end
  local need, held = game.cost[k], game.held
  local p = { 0, 0, 0, 0, 0, 0 }
  local function take(r, want)
    local t = min(held[r], want)
    p[r] = p[r] + t
    return want - t
  end
  local shortfall = 0
  local o = cards.card(game.card).opts[k]
  if o.swap then
    shortfall = shortfall + take(M.CULTIST, take(M.PRISONER, need[M.CULTIST] + need[M.PRISONER]))
  else
    shortfall = shortfall + take(M.CULTIST, need[M.CULTIST])
    shortfall = shortfall + take(M.PRISONER, need[M.PRISONER])
  end
  shortfall = shortfall + take(M.MONEY, need[M.MONEY])
  shortfall = shortfall + take(M.FOOD, need[M.FOOD])
  shortfall = shortfall + take(M.SUS, need[M.SUS])
  p[M.REL] = need[M.REL] + shortfall
  for r = 1, 6 do out[r] = p[r] end
  return true
end

function M.choose(game, cards, k, offer, random)
  if not M.exact(game, cards, k, offer) then return false end
  local o = cards.card(game.card).opts[k]
  for r = 1, 6 do game.held[r] = game.held[r] - offer[r] end
  game.played = game.card
  game.playedOption = k
  game.paid = { offer[1], offer[2], offer[3], offer[4], offer[5], offer[6] }
  game.lost = { 0, 0, 0, 0, 0, 0 }
  game.gained = { 0, 0, 0, 0, 0, 0 }
  game.added = {}
  game.addedCount = 0
  game.reshuffled = false
  for n = 1, o.randomCost do
    if total(game.held) <= 0 then break end
    local r
    repeat
      r = random:below(6) + 1
    until game.held[r] >= 1
    game.held[r] = game.held[r] - 1
    game.lost[r] = game.lost[r] + 1
  end
  for r = 1, 6 do
    game.held[r] = game.held[r] + game.gain[k][r]
    game.gained[r] = game.gain[k][r]
  end
  if o.win >= 0 then
    game.phase = M.WON
    game.god = o.win
    return true
  end
  if o.lose then
    game.phase = M.LOST
    game.loss = M.LOSS_CHOICE
    return true
  end
  if o.foresight then
    if #game.draw < 3 then M.detail.reshuffle(game, cards, random) end
    game.seenCount = min(3, #game.draw)
    for i = 0, game.seenCount - 1 do game.seen[i + 1] = game.draw[#game.draw - i] end
    game.discardMask = 0
    game.mayDiscard = o.discard
  end
  local into = game.draw
  if not game.tutorial then into = game.discard end
  for a = 1, o.addCount do
    for c = 1, o.adds[a][2] do into[#into + 1] = o.adds[a][1] end
    game.addedCount = game.addedCount + 1
    game.added[game.addedCount] = { o.adds[a][1], o.adds[a][2] }
  end
  for j = 0, o.rollCount - 1 do
    into[#into + 1] = game.rolled[k][j + 1]
    game.addedCount = game.addedCount + 1
    game.added[game.addedCount] = { game.rolled[k][j + 1], 1 }
  end
  if o.foresight then
    game.phase = M.FORESIGHT
    return true
  end
  advance(game, cards, random)
  return true
end

function M.toggleDiscard(game, i)
  if game.phase ~= M.FORESIGHT or not game.mayDiscard or i < 0 or i >= game.seenCount then return end
  game.discardMask = game.discardMask ~ (1 << i)
end

function M.endForesight(game, cards, random)
  if game.phase ~= M.FORESIGHT then return end
  game.phase = M.CHOOSING
  advance(game, cards, random)
end

function M.giveUp(game)
  if game.phase ~= M.CHOOSING and game.phase ~= M.FORESIGHT then return end
  game.phase = M.LOST
  game.loss = M.LOSS_GAVEUP
end

function M.replayTutorial(profile)
  profile.tutorialDone = false
end

function M.startOver(profile)
  profile.summoned = 0
  profile.previous = -1
  profile.tutorialDone = false
end

function M.finish(profile, game)
  profile.previous = -1
  if game.phase ~= M.WON or game.god < 0 then return end
  profile.summoned = profile.summoned | (1 << game.god)
  profile.previous = game.god
  if game.tutorial then profile.tutorialDone = true end
end

-- Whether a Game read back from storage is one these cards can continue.
function M.valid(game, cards)
  if #game.draw > M.PILE_CAP or #game.discard > M.PILE_CAP then return false end
  for _, pile in ipairs({ game.draw, game.discard }) do
    for _, id in ipairs(pile) do
      if not cards.card(id) then return false end
    end
  end
  for r = 1, 6 do
    if game.held[r] < 0 then return false end
  end
  if game.phase == M.CHOOSING or game.phase == M.FORESIGHT then
    if not cards.card(game.card) then return false end
  elseif game.phase == M.WON then
    if game.god < 0 or game.god >= cards.godCount() then return false end
  elseif game.phase == M.LOST then
    if game.loss == M.LOSS_NONE or game.loss > M.LOSS_GAVEUP then return false end
  else
    return false
  end
  if game.seenCount > 3 then return false end
  for i = 1, game.seenCount do
    if not cards.card(game.seen[i]) then return false end
  end
  for k = 1, 3 do
    for j = 1, 4 do
      if game.rolled[k][j] and game.rolled[k][j] ~= 0 and not cards.card(game.rolled[k][j]) then return false end
    end
  end
  if game.played ~= 0 and not cards.card(game.played) then return false end
  if game.playedOption < -1 or game.playedOption > 3 then return false end
  if game.addedCount > 6 then return false end
  for a = 1, game.addedCount do
    if not cards.card(game.added[a][1]) then return false end
  end
  return true
end

-- Checks the card data holds every card the rules name.
function M.rulesFit(cards)
  for _, id in ipairs({ M.TUTORIAL, M.RUMORS, M.GREED, M.POLICE, M.DESPERATE }) do
    if not cards.card(id) then return false end
  end
  for _, tier in ipairs(M.TIERS) do
    if not cards.card(tier[1]) then return false end
  end
  if cards.godCount() > 8 then return false end
  return true
end

return M