-- hearts.lua — Hearts as pure rules, a Lua port of HeartsCore.h/.cpp.
--
-- Nothing here can draw and nothing here touches the device API, so the same
-- module runs on the panel and under plain lua5.4 in a logic test.
--
-- Four seats, 1-based: 1 = South (the human), 2 = West, 3 = North, 4 = East.
-- Clockwise is South -> West -> North -> East, which is also "the player on
-- your left". Cards are ids 0..51 from cards.lua and every height question
-- goes through cards.trickRank(), because the deck numbers the ace 0.
--
-- The rules, exactly as docs/apps/hearts.md states them: the two of clubs
-- opens the first trick, always; follow the led suit if you hold it, and
-- only the highest card OF THE LED SUIT wins; you may not LEAD a heart until
-- hearts are broken, unless hearts are all you hold; nothing that costs a
-- point may be played on the first trick unless you hold nothing else;
-- every heart costs 1 and the queen of spades 13, so exactly 26 leave the
-- table each hand; take all 26 and you score nothing while everyone else
-- scores 26 (no subtract-26 option); lowest score wins and the game ends
-- the moment anybody reaches 100. Before each hand everyone passes three
-- cards; the direction rotates left, right, across, then hold. The pass is
-- simultaneous: every seat's three cards are lifted before any are dealt in.

local cards = require("cards")

local M = {}

M.PHASE = { PASSING = 1, PLAYING = 2, TRICKTAKEN = 3, HANDOVER = 4, GAMEOVER = 5 }
M.PASS = { LEFT = 0, RIGHT = 1, ACROSS = 2, HOLD = 3 }
M.TARGET = 100
M.MOON = 26
M.SEAT_NAME = { "YOU", "WEST", "NORTH", "EAST" }
M.passName = { "PASS LEFT", "PASS RIGHT", "PASS ACROSS", "NO PASS" }

local function nextSeat(s) return s % 4 + 1 end
local function prevSeat(s) return (s + 2) % 4 + 1 end
local function acrossSeat(s) return (s + 1) % 4 + 1 end

function M.passTarget(seat, pass)
  if pass == M.PASS.LEFT then return nextSeat(seat)
  elseif pass == M.PASS.RIGHT then return prevSeat(seat)
  elseif pass == M.PASS.ACROSS then return acrossSeat(seat) end
  return seat -- Hold is the caller's problem; no valid answer.
end

-- The cycle repeats every four hands and the fourth is a hold, which is why
-- handNumber has to survive a save.
function M.passDirection(handNumber) return handNumber % 4 end

-- A tiny deterministic generator (xorshift32) so a deal is reproducible from
-- a seed. rng is a table { v = seed }: Lua has no by-reference scalars, and
-- the same table is threaded through every decision so a test holding a
-- fixed seed gets the same game every time. Never seeded zero: that is the
-- one fixed point and it would make every "random" deal identical.
function M.nextRandom(r)
  local v = r.v or 0x9E3779B9
  if v == 0 then v = 0x9E3779B9 end
  v = (v ~ ((v << 13) & 0xFFFFFFFF)) & 0xFFFFFFFF
  v = (v ~ (v >> 17)) & 0xFFFFFFFF
  v = (v ~ ((v << 5) & 0xFFFFFFFF)) & 0xFFFFFFFF
  r.v = v
  return v
end

-- ------------------------------------------------------------------ hands

-- Sort key: suit first, then trick rank ascending. A hand held this way
-- reads the way a person fans one, and "I am out of clubs" is a gap you see
-- rather than a list you scan.
local function sortKey(c) return cards.suitOf(c) * 16 + cards.trickRank(c) end
local function handSort(h)
  table.sort(h, function(a, b) return sortKey(a) < sortKey(b) end)
end

function M.hasCard(h, c)
  for _, x in ipairs(h) do if x == c then return true end end
  return false
end

function M.hasSuit(h, suit)
  for _, x in ipairs(h) do if cards.suitOf(x) == suit then return true end end
  return false
end

function M.countSuit(h, suit)
  local n = 0
  for _, x in ipairs(h) do if cards.suitOf(x) == suit then n = n + 1 end end
  return n
end

local function onlyHearts(h)
  if #h == 0 then return false end
  for _, x in ipairs(h) do if not cards.isHeart(x) then return false end end
  return true
end

local function removeCard(h, c)
  for i, x in ipairs(h) do
    if x == c then table.remove(h, i); return true end
  end
  return false
end

-- --------------------------------------------------------------- the deal

function M.deal(g)
  -- Resets everything about a hand but NOT the running totals, which is
  -- exactly the boundary newGame (zeroes them once) and nextHand (keeps
  -- them) sit on, like the C++.
  for s = 1, 4 do
    g.hands[s] = {}
    g.taken[s] = 0
    g.tricksWon[s] = 0
    g.passing[s] = {}
    g.passingCount[s] = 0
    g.received[s] = {}
    g.receivedCount[s] = 0
    for su = 1, 4 do g.voidShown[s][su] = false end
  end
  for c = 0, 51 do g.played[c + 1] = false end

  local deck = {}
  for c = 0, 51 do deck[c + 1] = c end
  -- Fisher-Yates, downward, so every permutation is reachable.
  for i = 51, 1, -1 do
    local j = M.nextRandom(g.rng) % (i + 1)
    deck[i + 1], deck[j + 1] = deck[j + 1], deck[i + 1]
  end
  for i = 0, 51 do table.insert(g.hands[(i % 4) + 1], deck[i + 1]) end
  for s = 1, 4 do handSort(g.hands[s]) end

  g.trick = { played = { cards.NO_CARD, cards.NO_CARD, cards.NO_CARD, cards.NO_CARD }, leader = 1, count = 0 }
  g.heartsBroken = false
  g.trickNumber = 0
  -- Whoever ends up holding the two of clubs leads, and until the pass is
  -- committed we do not know who that will be — so the turn is set in
  -- commitPass(), not here.
  g.phase = M.PHASE.PASSING
  g.turn = 1
end

-- Start a whole new game: scores to zero, hand number to zero, then deal.
function M.newGame(seed, skills)
  local g = {
    rng = { v = seed or 1 },
    hands = { {}, {}, {}, {} },
    total = { 0, 0, 0, 0 },
    taken = { 0, 0, 0, 0 },
    tricksWon = { 0, 0, 0, 0 },
    voidShown = {
      { false, false, false, false }, { false, false, false, false },
      { false, false, false, false }, { false, false, false, false },
    },
    played = {},
    passing = { {}, {}, {}, {} },
    passingCount = { 0, 0, 0, 0 },
    received = { {}, {}, {}, {} },
    receivedCount = { 0, 0, 0, 0 },
    trick = { played = { cards.NO_CARD, cards.NO_CARD, cards.NO_CARD, cards.NO_CARD }, leader = 1, count = 0 },
    turn = 1,
    phase = M.PHASE.PASSING,
    heartsBroken = false,
    trickNumber = 0,
    handNumber = 0,
    lastHand = nil,
    skills = skills or { nil, 2, 2, 2 },
  }
  M.deal(g)
  return g
end

-- ------------------------------------------------------------- legality

-- LEGALITY over the public facts alone, split exactly like the C++ so the
-- brain can ask it from an Observation (which holds no Game) and the board
-- can mark "what would I be allowed to play" while the brains think. Every
-- caller goes through one implementation: the human's tap, the brain's
-- search and the tests. A second opinion about what is legal is how a game
-- ends up offering a move the rules then reject.
--
-- The rules it enforces, in the order they bite:
--   * the two of clubs leads the very first trick, and nothing else may;
--   * follow the led suit if you hold it;
--   * on the first trick, no penalty card (heart or queen of spades) unless
--     your hand is nothing but penalty cards;
--   * do not LEAD a heart until hearts are broken, unless hearts are all
--     you hold.
function M.isLegalCard(hand, trick, heartsBroken, firstTrick, card)
  if not M.hasCard(hand, card) then return false end

  local leading = trick.count == 0

  if firstTrick and leading then
    return card == cards.TWO_OF_CLUBS
  end

  if not leading then
    local led = cards.suitOf(trick.played[trick.leader])
    if M.hasSuit(hand, led) then
      if cards.suitOf(card) ~= led then return false end
    elseif firstTrick and cards.penalty(card) > 0 then
      -- Void in the led suit on the first trick: still no blood, unless
      -- blood is all that is left. onlyPenalty rather than onlyHearts,
      -- because a hand of twelve hearts plus the queen has no safe card
      -- either.
      local onlyPenalty = true
      for _, x in ipairs(hand) do
        if cards.penalty(x) == 0 then onlyPenalty = false break end
      end
      if not onlyPenalty then return false end
    end
    return true
  end

  -- Leading a later trick: hearts stay shut until somebody breaks them,
  -- unless hearts are the whole hand.
  if cards.isHeart(card) and not heartsBroken and not onlyHearts(hand) then return false end
  return true
end

function M.isLegalPlay(g, seat, card)
  if g.phase ~= M.PHASE.PLAYING then return false end
  if seat ~= g.turn then return false end
  return M.isLegalCard(g.hands[seat], g.trick, g.heartsBroken, g.trickNumber == 0, card)
end

-- Every legal card in `seat`'s hand.
function M.legalPlays(g, seat)
  local out = {}
  for _, c in ipairs(g.hands[seat]) do
    if M.isLegalPlay(g, seat, c) then out[#out + 1] = c end
  end
  return out
end

-- The rule that refuses `card`, for the board's "a refused tap names the
-- rule that refused it" line. nil when the card is legal.
function M.illegalReason(g, seat, card)
  if g.phase ~= M.PHASE.PLAYING then return "NOT YOUR TURN" end
  if seat ~= g.turn then return "NOT YOUR TURN" end
  local hand, trick = g.hands[seat], g.trick
  if not M.hasCard(hand, card) then return nil end
  local leading = trick.count == 0
  if g.trickNumber == 0 and leading then
    if card ~= cards.TWO_OF_CLUBS then return "THE 2 OF CLUBS OPENS" end
    return nil
  end
  if not leading then
    local led = cards.suitOf(trick.played[trick.leader])
    if M.hasSuit(hand, led) then
      if cards.suitOf(card) ~= led then return "MUST FOLLOW " .. cards.SUIT_NAME[led + 1] end
    elseif g.trickNumber == 0 and cards.penalty(card) > 0 then
      local onlyPenalty = true
      for _, x in ipairs(hand) do
        if cards.penalty(x) == 0 then onlyPenalty = false break end
      end
      if not onlyPenalty then
        if cards.isQueenOfSpades(card) then return "NO QUEEN ON TRICK 1" end
        return "NO HEARTS ON TRICK 1"
      end
    end
    return nil
  end
  if cards.isHeart(card) and not g.heartsBroken and not onlyHearts(hand) then
    return "HEARTS NOT BROKEN"
  end
  return nil
end

-- -------------------------------------------------------------- playing

function M.trickPoints(g)
  local n = 0
  for s = 1, 4 do
    local c = g.trick.played[s]
    if c ~= cards.NO_CARD then n = n + cards.penalty(c) end
  end
  return n
end

function M.trickWinner(g)
  local t = g.trick
  local led = cards.suitOf(t.played[t.leader])
  local bestSeat, bestRank = t.leader, -1
  for s = 1, 4 do
    local c = t.played[s]
    if c ~= cards.NO_CARD and cards.suitOf(c) == led then
      local r = cards.trickRank(c)
      if r > bestRank then bestRank, bestSeat = r, s end
    end
  end
  return bestSeat
end

-- Play `card` from g.turn. False (and no change) if it is not legal, which
-- is the only failure mode: the caller never has to check first.
-- Completing a trick moves to TRICKTAKEN WITHOUT sweeping it, so the panel
-- can show four cards; sweepTrick does the sweep.
function M.playCard(g, card)
  local seat = g.turn
  if not M.isLegalPlay(g, seat, card) then return false end

  -- Failing to follow shows the whole table that this seat is out of that
  -- suit. Recorded before the card lands, while the led suit is still the
  -- one this play was answering.
  if g.trick.count > 0 then
    local led = cards.suitOf(g.trick.played[g.trick.leader])
    if cards.suitOf(card) ~= led then g.voidShown[seat][led + 1] = true end
  end

  removeCard(g.hands[seat], card)
  g.played[card + 1] = true
  g.trick.played[seat] = card
  g.trick.count = g.trick.count + 1
  if cards.isHeart(card) then g.heartsBroken = true end

  if g.trick.count == 4 then
    g.phase = M.PHASE.TRICKTAKEN
  else
    g.turn = nextSeat(seat)
  end
  return true
end

-- Take the completed trick off the table, award it, and either start the
-- next trick or score the hand.
function M.sweepTrick(g)
  if g.phase ~= M.PHASE.TRICKTAKEN then return false end
  local w = M.trickWinner(g)
  g.taken[w] = g.taken[w] + M.trickPoints(g)
  g.tricksWon[w] = g.tricksWon[w] + 1

  g.trick = { played = { cards.NO_CARD, cards.NO_CARD, cards.NO_CARD, cards.NO_CARD }, leader = w, count = 0 }
  g.trickNumber = g.trickNumber + 1

  if g.trickNumber >= 13 then
    M.scoreHand(g)
    return true
  end
  g.turn = w
  g.phase = M.PHASE.PLAYING
  return true
end

-- Score the finished hand into totals, applying the moon. Called by
-- sweepTrick on the thirteenth trick; exposed for the tests.
function M.scoreHand(g)
  local shooter = nil
  for s = 1, 4 do
    if g.taken[s] == M.MOON then shooter = s end
  end
  local scored = { g.taken[1], g.taken[2], g.taken[3], g.taken[4] }
  local moon = false
  if shooter then
    moon = true
    -- take all 26 and you score nothing while everyone else scores 26.
    for s = 1, 4 do scored[s] = (s == shooter) and 0 or M.MOON end
  end
  for s = 1, 4 do g.total[s] = g.total[s] + scored[s] end
  g.lastHand = {
    taken = { g.taken[1], g.taken[2], g.taken[3], g.taken[4] },
    scored = scored,
    total = { g.total[1], g.total[2], g.total[3], g.total[4] },
    moon = moon,
    shooter = shooter,
  }
  local over = false
  for s = 1, 4 do
    if g.total[s] >= M.TARGET then over = true end
  end
  g.phase = over and M.PHASE.GAMEOVER or M.PHASE.HANDOVER
end

-- ----------------------------------------------------------------- pass

function M.setPass(g, seat, selection)
  if g.phase ~= M.PHASE.PASSING then return false end
  if #selection ~= 3 then return false end
  local hand = g.hands[seat]
  for i = 1, 3 do
    if not M.hasCard(hand, selection[i]) then return false end
    for j = 1, i - 1 do
      if selection[i] == selection[j] then return false end
    end
  end
  g.passing[seat] = { selection[1], selection[2], selection[3] }
  g.passingCount[seat] = 3
  return true
end

function M.passReady(g)
  if M.passDirection(g.handNumber) == M.PASS.HOLD then return true end
  for s = 1, 4 do
    if g.passingCount[s] ~= 3 then return false end
  end
  return true
end

local function holderOfTwoOfClubs(g)
  for s = 1, 4 do
    if M.hasCard(g.hands[s], cards.TWO_OF_CLUBS) then return s end
  end
  return 1 -- unreachable with a full deal
end

-- Move every seat's three cards to their target and start the hand.
--
-- The pass is SIMULTANEOUS: every seat's three cards are lifted before any
-- are dealt in, because done seat by seat a card passed left can be picked
-- up again by the next seat's own pass before it has left, and the hand
-- ends up with fourteen cards.
function M.commitPass(g)
  if g.phase ~= M.PHASE.PASSING or not M.passReady(g) then return false end
  local dir = M.passDirection(g.handNumber)
  if dir ~= M.PASS.HOLD then
    local lifted = { {}, {}, {}, {} }
    for s = 1, 4 do
      lifted[s] = { g.passing[s][1], g.passing[s][2], g.passing[s][3] }
      for i = 1, 3 do removeCard(g.hands[s], lifted[s][i]) end
    end
    for s = 1, 4 do
      local t = M.passTarget(s, dir)
      g.received[t] = { lifted[s][1], lifted[s][2], lifted[s][3] }
      g.receivedCount[t] = 3
      for i = 1, 3 do table.insert(g.hands[t], lifted[s][i]) end
    end
    for s = 1, 4 do handSort(g.hands[s]) end
  end
  for s = 1, 4 do g.passingCount[s] = 0 end
  -- Whoever holds the two of clubs leads, which after a pass can be anyone.
  local opener = holderOfTwoOfClubs(g)
  g.trick = { played = { cards.NO_CARD, cards.NO_CARD, cards.NO_CARD, cards.NO_CARD }, leader = opener, count = 0 }
  g.turn = opener
  g.phase = M.PHASE.PLAYING
  return true
end

-- Deal the next hand of the same game. Only valid in HANDOVER.
function M.nextHand(g)
  if g.phase ~= M.PHASE.HANDOVER then return false end
  g.handNumber = g.handNumber + 1
  M.deal(g)
  return true
end

-- ----------------------------------------------------------------- misc

-- Who is winning, for the game-over screen. Ties go to the lower seat
-- index, which is the human, and the screen says "tied" rather than
-- pretending.
function M.leader(g)
  local best = 1
  for s = 2, 4 do
    if g.total[s] < g.total[best] then best = s end
  end
  return best
end

function M.isTied(g)
  local b = g.total[M.leader(g)]
  local n = 0
  for s = 1, 4 do
    if g.total[s] == b then n = n + 1 end
  end
  return n > 1
end

-- IS THIS GAME INTERNALLY POSSIBLE?
--
-- The save is restored through here. A torn write leaves a file of exactly
-- the right length holding a mix of two states; what fails that is
-- arithmetic: a seat index out of range, a hand longer than thirteen, a
-- phase that is not one of the five, or — the one that catches almost
-- everything — a deck that does not add up to exactly 52 distinct cards
-- across the hands and what has been played.
--
-- A card ON THE TABLE is counted by `played`, not separately: playCard
-- records it there the moment it leaves the hand, so counting the table as
-- well makes every live trick look like a duplicated card.
function M.isConsistent(g)
  if g.phase < M.PHASE.PASSING or g.phase > M.PHASE.GAMEOVER then return false end
  if g.turn < 1 or g.turn > 4 then return false end
  if g.trick.leader < 1 or g.trick.leader > 4 then return false end
  if g.trick.count < 0 or g.trick.count > 4 then return false end
  if g.trickNumber < 0 or g.trickNumber > 13 then return false end

  local onTable = 0
  for s = 1, 4 do
    if #g.hands[s] > 13 then return false end
    if g.passingCount[s] > 3 then return false end
    if g.receivedCount[s] > 3 then return false end
    if g.total[s] < 0 or g.taken[s] < 0 or g.taken[s] > M.MOON then return false end
    if g.tricksWon[s] > 13 then return false end
    local c = g.trick.played[s]
    if c ~= cards.NO_CARD then
      if c < 0 or c > 51 then return false end
      if not g.played[c + 1] then return false end
      onTable = onTable + 1
    end
  end
  if onTable ~= g.trick.count then return false end

  local seen = {}
  for s = 1, 4 do
    for _, c in ipairs(g.hands[s]) do
      if type(c) ~= "number" or c < 0 or c > 51 then return false end
      seen[c] = (seen[c] or 0) + 1
    end
  end
  for c = 0, 51 do
    if g.played[c + 1] then seen[c] = (seen[c] or 0) + 1 end
    if seen[c] ~= 1 then return false end
  end
  return true
end

return M