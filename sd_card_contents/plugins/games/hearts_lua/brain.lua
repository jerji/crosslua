-- brain.lua — the three opponents, a Lua port of HeartsBrain.h/.cpp.
--
-- IT TAKES AN OBSERVATION, NEVER A GAME. An Observation has no field for
-- anybody else's hand, so a brain cannot cheat by construction rather than
-- by discipline. It matters more here than in a two-player game: three of
-- the four seats at this table are brains running in one process, and one
-- brain that could see all four hands would turn a game of incomplete
-- information into a solved one.
--
-- Each seat gets its own observation, rebuilt per decision from what that
-- seat is entitled to know: its cards, the table, the cards already played,
-- and who has shown void in what. All of that is public at a real table.
--
-- No search. Hearts rewards bookkeeping rather than depth: duck under the
-- trick, remember who is void, do not hand anyone the queen, notice a moon.
-- Those are rules over a value function.
--
-- Two settings rather than a slider. A ROOKIE follows suit, ducks under a
-- trick when it can, and sheds its highest card when it is void — it never
-- gets caught winning a trick it could have ducked, and it also never sheds
-- low, so by the last few tricks it holds the aces and takes the points
-- with them. A SHARP counts what has gone, reads a void seat as one that
-- will dump the queen, eats a point trick to stop somebody shooting, and
-- will shoot the moon itself.

local cards = require("cards")
local hearts = require("hearts")

local M = {}
M.ROOKIE, M.SHARP = 1, 2

local function cardIndex(c) return cards.suitOf(c) * 13 + cards.rankOf(c) end

-- Fill an observation with what `seat` is entitled to know. The only
-- function that ever reads another seat's hand is this one, and it reads it
-- through the game's own `played` record to work out what is GONE — never
-- what is held. A card still face up on the table is VISIBLE, not gone: it
-- is deciding the trick in front of you, and treating it as spent hides it
-- from the one decision it is part of.
function M.observe(g, seat)
  local o = {
    me = seat,
    hand = {},
    trick = {
      played = { g.trick.played[1], g.trick.played[2], g.trick.played[3], g.trick.played[4] },
      leader = g.trick.leader,
      count = g.trick.count,
    },
    phase = g.phase,
    gone = {},
    showsVoid = {
      { false, false, false, false }, { false, false, false, false },
      { false, false, false, false }, { false, false, false, false },
    },
    total = { g.total[1], g.total[2], g.total[3], g.total[4] },
    taken = { g.taken[1], g.taken[2], g.taken[3], g.taken[4] },
    heartsBroken = g.heartsBroken,
    trickNumber = g.trickNumber,
    passDirection = hearts.passDirection(g.handNumber),
  }
  for _, c in ipairs(g.hands[seat]) do o.hand[#o.hand + 1] = c end
  for c = 0, 51 do
    if g.played[c + 1] then o.gone[c + 1] = true end
  end
  for s = 1, 4 do
    local c = g.trick.played[s]
    if c ~= cards.NO_CARD then o.gone[cardIndex(c) + 1] = false end
  end
  for s = 1, 4 do
    for su = 1, 4 do o.showsVoid[s][su] = g.voidShown[s][su] end
  end
  return o
end

local function wasPlayed(o, suit, rank) return o.gone[suit * 13 + rank + 1] == true end

function M.firstTrick(o) return o.trickNumber == 0 end

-- How many cards of `suit` are still unaccounted for from this seat's point
-- of view: not in my hand, not yet played, not on the table.
local function outstanding(o, suit)
  local held = 0
  for r = 0, 12 do
    if not wasPlayed(o, suit, r) then held = held + 1 end
  end
  for _, c in ipairs(o.hand) do
    if cards.suitOf(c) == suit then held = held - 1 end
  end
  return held < 0 and 0 or held
end

-- The highest card of the led suit currently on the table.
local function currentHigh(t)
  if t.count == 0 then return -1 end
  local led = cards.suitOf(t.played[t.leader])
  local best = -1
  for s = 1, 4 do
    local c = t.played[s]
    if c ~= cards.NO_CARD and cards.suitOf(c) == led then
      local r = cards.trickRank(c)
      if r > best then best = r end
    end
  end
  return best
end

local function holdsQueen(o) return hearts.hasCard(o.hand, cards.make(cards.SPADES, cards.QUEEN)) end

-- A seat that has shown void in a suit will throw whatever it likes on it —
-- the queen included. Knowing that is most of what separates a Sharp from
-- a Rookie.
local function anyoneVoidIn(o, suit)
  for s = 1, 4 do
    if s ~= o.me and o.showsVoid[s][suit + 1] then return true end
  end
  return false
end

-- HAS THE QUEEN FALLEN? Not the same question as "is she in `gone`":
-- observe() deliberately unmarks the cards lying face up in the current
-- trick, because for counting they are visible rather than spent. For "has
-- she come out yet" that is wrong — a Sharp fourth to play, with the queen
-- already thrown onto this very trick, still ducks to avoid drawing her.
local function queenGone(o)
  if wasPlayed(o, cards.SPADES, cards.QUEEN) then return true end
  for s = 1, 4 do
    local c = o.trick.played[s]
    if c ~= cards.NO_CARD and cards.isQueenOfSpades(c) then return true end
  end
  return false
end

-- Is the queen still a live danger to me? She is if she has not fallen and
-- I am not the one holding her.
local function queenLoose(o) return not queenGone(o) and not holdsQueen(o) end

local function lastToPlay(o) return o.trick.count == 3 end

local function trickPoints(t)
  local n = 0
  for s = 1, 4 do
    local c = t.played[s]
    if c ~= cards.NO_CARD then n = n + cards.penalty(c) end
  end
  return n
end

-- ------------------------------------------------------------- passing

-- How much this seat wants rid of `card` before a hand starts, in arbitrary
-- units where bigger means pass it.
function M.passUrgency(o, card)
  local suit = cards.suitOf(card)
  local rank = cards.trickRank(card)
  local len = hearts.countSuit(o.hand, suit)
  local want = 0

  if cards.isQueenOfSpades(card) then
    -- Thirteen points that only leave by being played. Keep her only behind
    -- a real wall: with five or more spades you can afford to duck under a
    -- lead twice before she is exposed.
    want = len >= 5 and 20 or 120
  elseif suit == cards.SPADES and rank > cards.trickRank(cards.make(cards.SPADES, cards.QUEEN)) then
    -- The ace and king of spades win tricks you do not want, and they draw
    -- the queen onto themselves. Short in spades, they are a liability.
    want = len >= 5 and 25 or 90 + rank
  elseif suit == cards.HEARTS then
    -- High hearts take heart tricks. Low ones are cheap protection.
    want = rank >= 9 and 55 + rank * 2 or rank * 2
    if len <= 2 then want = want + 10 end
  else
    -- Side suits: a high card is a trick you will be made to win. A short
    -- suit is worth emptying completely, because a void is a free discard
    -- all hand.
    want = rank * 3
    if len <= 3 then want = want + (4 - len) * 12 end
    -- Keep the low clubs: they are the safest cards in the deck early, and
    -- the two of clubs decides who opens.
    if suit == cards.CLUBS and rank <= 2 then want = want - 25 end
  end
  return want
end

-- The three cards `seat` passes. Writes three cards into `out`.
function M.decidePass(o, skill, rng, out)
  -- Score every card, then take the three keenest. A Rookie passes its
  -- three highest cards flat, which is exactly the naive thing a beginner
  -- does and leaves it holding short suits it cannot use.
  local score = {}
  for i, c in ipairs(o.hand) do
    local sc = (skill == M.SHARP) and M.passUrgency(o, c) or cards.trickRank(c) * 4
    -- A whisper of noise so two brains with the same hand do not pass the
    -- same three cards every single time.
    sc = sc + hearts.nextRandom(rng) % 5
    score[i] = sc
  end
  for i = 1, 3 do out[i] = cards.NO_CARD end
  if #o.hand < 3 then return end

  local used = {}
  for pick = 1, 3 do
    local best = -1
    for i = 1, #o.hand do
      if not used[i] and (best < 0 or score[i] > score[best]) then best = i end
    end
    if best < 0 then return end
    used[best] = true
    out[pick] = o.hand[best]
  end
end

-- ------------------------------------------------------------ the moon

-- AM I SHOOTING? True when this seat holds every point taken so far and
-- still holds the cards to finish the job. Deliberately hard to enter: a
-- shoot that fails hands you every point you collected on the way, so the
-- bar is "already committed and still holding the top cards", never a
-- hopeful start.
function M.shootingTheMoon(o)
  local me = o.me
  if o.taken[me] <= 0 then return false end
  for s = 1, 4 do
    if s ~= me and o.taken[s] > 0 then return false end -- somebody else has points: it is already dead
  end
  if o.taken[me] < 8 then return false end -- below this a "shoot" is just one early heart

  -- And still able to finish. Every point still out there has to come to
  -- me, so I need cards that win: count how many of my cards nothing
  -- outstanding beats.
  local commanding = 0
  for _, card in ipairs(o.hand) do
    local suit = cards.suitOf(card)
    local rank = cards.trickRank(card)
    local beatable = false
    for r = rank + 1, 12 do
      -- trickRank r maps back to the deck's numbering: 12 is the ace (0).
      local deckRank = (r == 12) and cards.ACE or r + 1
      if not wasPlayed(o, suit, deckRank) and not hearts.hasCard(o.hand, cards.make(suit, deckRank)) then
        beatable = true
        break
      end
    end
    if not beatable then commanding = commanding + 1 end
  end
  return commanding * 2 >= #o.hand
end

-- Is somebody about to shoot the moon? Returns that seat, or -1. A seat is
-- a threat when it holds every point taken so far and enough have been
-- taken that it is not just the first heart falling. Six from the fourth
-- trick on catches both a queen-led shoot and a hearts-only shoot while
-- still ignoring the single early heart that means nothing.
function M.moonThreat(o)
  local holder, held = -1, 0
  for s = 1, 4 do
    if o.taken[s] > 0 then
      if holder >= 0 then return -1 end -- points are split: nobody is shooting
      holder, held = s, o.taken[s]
    end
  end
  if holder < 0 or holder == o.me then return -1 end
  if held >= 10 or (held >= 6 and o.trickNumber >= 4) then return holder end
  return -1
end

-- -------------------------------------------------------------- decide

-- Pick the card that leads a trick.
local function chooseLead(o, skill, legal, rng)
  local shooting = skill == M.SHARP and M.shootingTheMoon(o)
  local bestAt, bestScore = 1, -1000000
  for i, card in ipairs(legal) do
    local suit = cards.suitOf(card)
    local rank = cards.trickRank(card)
    local score
    if shooting then
      -- Lead the cards nothing can beat, so the points keep coming to me.
      score = rank * 10 + hearts.nextRandom(rng) % 7
    else
      -- Leading low is the whole art: a low card wins nothing and gives
      -- nothing.
      score = (12 - rank) * 6
      if skill == M.SHARP then
        -- Hunt the queen. While she is out there and I am holding small
        -- spades, leading spades drags her out of somebody's hand onto a
        -- trick I am not going to win.
        if suit == cards.SPADES and queenLoose(o) then
          local qr = cards.trickRank(cards.make(cards.SPADES, cards.QUEEN))
          if rank < qr then
            score = score + 30
          else
            -- Leading a spade ABOVE the queen invites her straight onto my
            -- trick.
            score = score - 70
          end
        end
        -- Leading a suit somebody is void in hands them a free discard,
        -- and the queen is the discard they want to make.
        if anyoneVoidIn(o, suit) then score = score - 45 end
        -- Emptying a short suit early buys discards later.
        local len = hearts.countSuit(o.hand, suit)
        if len <= 2 and suit ~= cards.HEARTS then score = score + 18 end
        -- A card nobody can beat is a trick I am about to win for nothing.
        local unbeatable = true
        for r = rank + 1, 12 do
          local deckRank = (r == 12) and cards.ACE or r + 1
          if not wasPlayed(o, suit, deckRank) then unbeatable = false break end
        end
        if unbeatable and outstanding(o, suit) > 0 then score = score - 35 end
        -- Leading hearts pushes points around for no gain unless I am short
        -- of everything else.
        if suit == cards.HEARTS then score = score - 25 end
      end
      score = score + hearts.nextRandom(rng) % 7
    end
    if score > bestScore then bestScore, bestAt = score, i end
  end
  return legal[bestAt]
end

-- Pick the card that follows one.
local function chooseFollow(o, skill, legal, rng)
  local led = cards.suitOf(o.trick.played[o.trick.leader])
  local high = currentHigh(o.trick)
  local onTable = trickPoints(o.trick)
  local threat = (skill == M.SHARP) and M.moonThreat(o) or -1
  local shooting = skill == M.SHARP and M.shootingTheMoon(o)
  local last = lastToPlay(o)
  local bestAt, bestScore = 1, -1000000

  if skill == M.ROOKIE then
    -- The beginner's habit, and a real one: follow with your lowest card
    -- and dump your highest when you are void. It never gets caught
    -- winning a trick it could have ducked, but it also never SHEDS
    -- anything, so by the last few tricks it is holding the aces and takes
    -- the points with them.
    for i, card in ipairs(legal) do
      local following = cards.suitOf(card) == led
      local rank = cards.trickRank(card)
      local score = following and (400 - rank * 6) or (100 + rank * 6 + cards.penalty(card) * 9)
      score = score + hearts.nextRandom(rng) % 11
      if score > bestScore then bestScore, bestAt = score, i end
    end
    return legal[bestAt]
  end

  for i, card in ipairs(legal) do
    local suit = cards.suitOf(card)
    local rank = cards.trickRank(card)
    local following = suit == led
    local wouldLead = following and rank > high
    local score

    if shooting then
      -- EVERYTHING INVERTS. I need every remaining point, so I want to win
      -- this trick and I want it to be worth something.
      if following then
        score = wouldLead and (800 + rank * 6) or rank
      else
        score = 50 + (12 - rank) * 4 -- void: throw rubbish, keep the winners
      end
      score = score + hearts.nextRandom(rng) % 7
    else
      if following then
        if not wouldLead then
          -- Ducking. Play the HIGHEST card that still loses: it sheds a
          -- dangerous card for free, the single most valuable habit in
          -- Hearts.
          score = 600 + rank * 4
        else
          -- Taking it. How bad that is depends on what is on the table and
          -- on whether anyone can still pile on after me.
          score = 200 - rank * 5 - onTable * 12
          if last and onTable == 0 then
            -- Last to play, nothing at stake: winning is free.
            score = score + 260
          end
          if queenLoose(o) and led == cards.SPADES and
              rank > cards.trickRank(cards.make(cards.SPADES, cards.QUEEN)) then
            -- Beating the queen's rank with the queen still out is how you
            -- get handed thirteen points.
            score = score - 180
          end
        end
        -- Stop a moon by eating a point trick on purpose. This is the
        -- behaviour random play never has, and the one that makes the table
        -- feel like it is paying attention.
        if threat >= 0 and onTable > 0 and wouldLead then score = score + 420 end
      else
        -- Void in the led suit: this is a discard, so throw the most
        -- dangerous thing I own.
        score = 100
        if cards.isQueenOfSpades(card) then
          -- Getting rid of her is worth almost anything, unless the trick
          -- is already mine, in which case I would be giving myself
          -- thirteen.
          score = score + 500
        elseif suit == cards.SPADES and queenLoose(o) and
            rank > cards.trickRank(cards.make(cards.SPADES, cards.QUEEN)) then
          score = score + 220 -- shed the ace and king before she arrives
        elseif suit == cards.HEARTS then
          score = score + 60 + rank * 8 -- high hearts first
        else
          score = score + rank * 6
        end
        if threat >= 0 and cards.penalty(card) > 0 then
          -- Do not feed a shooter.
          score = score - 300
        end
      end
      score = score + hearts.nextRandom(rng) % 7
    end
    if score > bestScore then bestScore, bestAt = score, i end
  end
  return legal[bestAt]
end

-- The card to play. Always one the rules will accept: legality is asked of
-- the RULES, never re-derived here — a brain with its own opinion about
-- what it may play is a brain that will eventually disagree with the game
-- in a way no test of either one alone can catch.
function M.decidePlay(o, skill, rng)
  local legal = {}
  for _, c in ipairs(o.hand) do
    if hearts.isLegalCard(o.hand, o.trick, o.heartsBroken, M.firstTrick(o), c) then
      legal[#legal + 1] = c
    end
  end
  if #legal == 0 then return cards.NO_CARD end
  if #legal == 1 then return legal[1] end
  if o.trick.count == 0 then return chooseLead(o, skill, legal, rng) end
  return chooseFollow(o, skill, legal, rng)
end

return M