-- Sea Salt & Paper — rules core for the CrossLua port.
--
-- A port of crossplay's SeaSaltCore.cpp + SeaSaltCards.h. Pure Lua: no gfx,
-- input, fs or system, so host Lua can run the logic tests against it
-- directly. Card ids are 1..58 (the C++ ids + 1); places, steps and phases
-- use the same numeric constants as the C++ enums.
--
-- The rule decisions this implements are the ones docs/apps/seasalt.md
-- records, including the two the port had to settle:
--   * mermaids never leave the hand, and holding all four wins the match the
--     moment the fourth arrives, however it arrived;
--   * the AI may remember both discard piles (observe shows them in full),
--     but never sees the deck or the opponent's unrevealed hand.
-- Everything else is the rulebook: duo points count played or not, "your
-- cards" is hand plus table, LAST CHANCE pays the colour bonus one way or the
-- other, a deck that runs out at the end of a turn scores nobody.

local M = {}

-- ---------------------------------------------------------------- identity

M.KINDS = {
  "CRAB", "BOAT", "FISH", "SWIMMER", "SHARK", "SHELL", "OCTOPUS",
  "PENGUIN", "SAILOR", "MERMAID", "LIGHTHOUSE", "SHOAL", "NEST", "CAPTAIN",
}
M.SUPPLY = { 9, 8, 7, 5, 5, 6, 5, 3, 2, 4, 1, 1, 1, 1 }
-- 34 duo + 16 collector + 4 mermaid + 4 multiplier = 58 (the doc's table).
M.COLOURS = {
  "D.BLUE", "L.BLUE", "BLACK", "YELLOW", "L.GREEN", "WHITE", "PURPLE",
  "L.GREY", "L.ORANGE", "L.PINK", "ORANGE",
}
-- Short marks for the tight tiles on the board.
M.COLOUR_MARKS = { "DB", "LB", "BK", "YE", "LG", "WH", "PU", "GR", "LO", "LP", "OR" }
M.COLOUR_SUPPLY = { 9, 9, 8, 8, 6, 4, 4, 4, 3, 2, 1 }
M.CARDS = 58
M.SEATS = 2
M.PILES = 2
M.TARGET = 40
M.MIN_END = 7
M.MERMAIDS_WIN = 4
M.NO_CARD = 255
M.NO_SEAT = 255

-- Kind / colour per card id, expanded from the supply counts. The expansion
-- loop replaces a hand-typed table and is checked against the counts below,
-- the same way the C++ static_asserts pin the hand-entered tables.
local CARD_KIND, CARD_COLOUR = {}, {}
do
  local colour_groups = {
    { 0, 0, 1, 1, 2, 3, 3, 4, 7 },  -- crab    2 d.blue 2 l.blue black 2 yellow l.green l.grey
    { 0, 0, 1, 1, 2, 2, 3, 3 },     -- boat    2 of each of the four big colours
    { 0, 0, 1, 2, 2, 3, 4 },        -- fish
    { 0, 1, 2, 3, 8 },              -- swimmer
    { 0, 1, 2, 4, 6 },              -- shark
    { 0, 1, 2, 3, 4, 7 },           -- shell
    { 1, 3, 4, 6, 7 },              -- octopus
    { 6, 8, 9 },                    -- penguin  purple, l.orange, l.pink
    { 9, 10 },                      -- sailor   l.pink, orange
    { 5, 5, 5, 5 },                 -- mermaid  all four white, white is nothing else
    { 6 },                          -- lighthouse     purple
    { 7 },                          -- shoal of fish  l.grey
    { 4 },                          -- nest           l.green
    { 8 },                          -- captain        l.orange
  }
  local id = 0
  for k = 1, #M.SUPPLY do
    for n = 1, M.SUPPLY[k] do
      id = id + 1
      CARD_KIND[id] = k - 1
      CARD_COLOUR[id] = colour_groups[k][n]
    end
  end
  assert(id == M.CARDS, "kind expansion must build 58 cards")
  local colour_count = {}
  for c = 1, M.CARDS do colour_count[CARD_COLOUR[c]] = (colour_count[CARD_COLOUR[c]] or 0) + 1 end
  for col = 1, #M.COLOUR_SUPPLY do
    assert((colour_count[col - 1] or 0) == M.COLOUR_SUPPLY[col], "colour expansion must match the distribution card")
  end
end

function M.kindOf(card) return CARD_KIND[card] end
function M.colourOf(card) return CARD_COLOUR[card] end
function M.kindName(kind) return M.KINDS[kind + 1] end

-- Collector payouts, indexed by held count + 1 (holding none = index 1).
M.SHELL_SCORE = { 0, 0, 2, 4, 6, 8, 10 }
M.OCTOPUS_SCORE = { 0, 0, 3, 6, 9, 12 }
M.PENGUIN_SCORE = { 0, 1, 3, 5 }
M.SAILOR_SCORE = { 0, 0, 5 }

-- ---------------------------------------------------------------- enums

M.PLACE = { DECK = 0, HAND0 = 1, HAND1 = 2, TABLE0 = 3, TABLE1 = 4, PILEA = 5, PILEB = 6, DRAWN = 7 }
M.PHASE = { PLAYING = 0, LASTCHANCE = 1, ROUNDOVER = 2, GAMEOVER = 3 }
M.STEP = { TAKE = 0, CHOOSEKEEP = 1, CHOOSEPILE = 2, PLAY = 3, CRABPILE = 4, CRABPICK = 5 }
M.VIEW = {
  UNKNOWN = 0, MYHAND = 1, MYTABLE = 2, THEIRHAND = 3, THEIRTABLE = 4,
  PILEA = 5, PILEB = 6, MYDRAWN = 7,
}

local function handOf(seat) return M.PLACE.HAND0 + seat end
local function tableOf(seat) return M.PLACE.TABLE0 + seat end
local function pileAt(pile) return M.PLACE.PILEA + pile end
local function otherSeat(seat) return seat ~ 1 end

-- ------------------------------------------------------------- the rng
-- The xorshift32 of SeaSaltCore.cpp, bit for bit: every step is masked back
-- to 32 bits, so the same seed deals the same deck here as on the C++ build.
-- A link relies on it: a device replaying a peer's move must draw the card
-- the C++ build would.
local M32 = 0xFFFFFFFF

local function nextRandom(state)
  state = (state ~ (state << 13)) & M32
  state = state ~ (state >> 17)
  state = (state ~ (state << 5)) & M32
  return state
end

local function streamFor(seed, stream)
  local s = (seed ~ ((0x9E3779B9 * (stream + 1)) & M32)) & M32
  return s ~= 0 and s or 0x1234567  -- xorshift dies on zero
end

-- The shark's steal must be a pure function of the state so the same game
-- state always steals the same card (only relevant to the link build; kept
-- for fidelity with the C++ port).
local function stealStream(g)
  local s = streamFor(g.seed, 64 + g.seqNext)
  s = (s ~ ((0x85EBCA6B * (g.deckNext + 1)) & M32)) & M32
  s = (s ~ ((0xC2B2AE35 * (g.turn + 1)) & M32)) & M32
  s = nextRandom(s)
  return s ~= 0 and s or 0x9E3779B9
end

-- ------------------------------------------------------------- set-up

function M.cardAt(g, index)  -- index 0-based from the deal cursor
  local order = {}
  for i = 1, M.CARDS do order[i] = i end
  local state = streamFor(g.seed, 0)
  for i = M.CARDS, 2, -1 do
    state = nextRandom(state)  -- the state advances every draw, as in the C++ (by reference)
    local j = (state % i) + 1
    order[i], order[j] = order[j], order[i]
  end
  return order[index + 1]
end

-- Deals a new round over the existing Game: everything the round owns is
-- reset, banked scores and the round counter are preserved (the caller owns
-- the round counter, exactly like the C++ activity does).
function M.deal(g, roundSeed, starter)
  g.seed = roundSeed
  for c = 1, M.CARDS do g.place[c] = M.PLACE.DECK; g.seq[c] = 0 end
  g.seqNext = 1
  g.deckNext = 0
  -- The first two cards turn face up as the two piles; no opening hands.
  for p = 0, M.PILES - 1 do
    local card = M.cardAt(g, g.deckNext)
    g.deckNext = g.deckNext + 1
    g.place[card] = pileAt(p)
    g.seq[card] = g.seqNext
    g.seqNext = g.seqNext + 1
  end
  g.turn = starter
  g.roundStarter = starter
  g.phase = M.PHASE.PLAYING
  g.step = M.STEP.TAKE
  g.ender = M.NO_SEAT
  g.bet = 0
  g.owed = 0
  g.drawn[1] = M.NO_CARD
  g.drawn[2] = M.NO_CARD
  g.pending = M.NO_CARD
  g.crabPile = 0
  g.revealed = 0
  g.extraTurns = 0
end

function M.newGame(roundSeed)
  local g = {
    seed = 0, place = {}, seq = {}, seqNext = 1, deckNext = 0,
    score = { 0, 0 }, turn = 0, roundStarter = 0,
    phase = M.PHASE.PLAYING, step = M.STEP.TAKE, round = 1,
    ender = M.NO_SEAT, bet = 0, owed = 0,
    drawn = { M.NO_CARD, M.NO_CARD }, pending = M.NO_CARD,
    crabPile = 0, revealed = 0, extraTurns = 0,
  }
  M.deal(g, roundSeed, 0)
  return g
end

-- ------------------------------------------------------------ counting

local function countIn(g, where, kind)
  local n = 0
  for c = 1, M.CARDS do
    if g.place[c] == where and CARD_KIND[c] == kind then n = n + 1 end
  end
  return n
end

M.countIn = countIn  -- exported for linkturn.lua (the table side of a transport line)

local function countPlace(g, where)
  local n = 0
  for c = 1, M.CARDS do
    if g.place[c] == where then n = n + 1 end
  end
  return n
end

function M.countHeld(g, seat, kind)
  return countIn(g, handOf(seat), kind) + countIn(g, tableOf(seat), kind)
end

function M.countHeldColour(g, seat, colour)
  local hand, table = handOf(seat), tableOf(seat)
  local n = 0
  for c = 1, M.CARDS do
    if (g.place[c] == hand or g.place[c] == table) and CARD_COLOUR[c] == colour then n = n + 1 end
  end
  return n
end

function M.handSize(g, seat) return countPlace(g, handOf(seat)) end
function M.tableSize(g, seat) return countPlace(g, tableOf(seat)) end
function M.pileSize(g, pile) return countPlace(g, pileAt(pile)) end

-- The top of a discard pile: the card with the highest pile-sequence.
function M.pileTop(g, pile)
  local w = pileAt(pile)
  local best, bestSeq = M.NO_CARD, 0
  for c = 1, M.CARDS do
    if g.place[c] == w and g.seq[c] >= bestSeq then
      bestSeq = g.seq[c]
      best = c
    end
  end
  return best
end

function M.deckRemaining(g) return M.CARDS - g.deckNext end

-- The cards of `kind` a seat holds anywhere that counts for scoring: hand
-- plus table. (countHeld is that; kept for API symmetry with the C++.)

-- ------------------------------------------------------------- scoring

function M.cardPoints(g, seat)
  local points = 0
  -- Duos score whether they were laid down or not; only the effect needed
  -- the laying. Crab, boat and fish pair with themselves; swimmer, shark.
  -- The count is hand PLUS table combined: a pair split across the two is
  -- still a pair.
  points = points + M.countHeld(g, seat, 0) // 2
  points = points + M.countHeld(g, seat, 1) // 2
  points = points + M.countHeld(g, seat, 2) // 2
  local swimmers = M.countHeld(g, seat, 3)
  local sharks = M.countHeld(g, seat, 4)
  points = points + (swimmers < sharks and swimmers or sharks)

  local shells = M.countHeld(g, seat, 5)
  local octos = M.countHeld(g, seat, 6)
  local penguins = M.countHeld(g, seat, 7)
  local sailors = M.countHeld(g, seat, 8)
  points = points + M.SHELL_SCORE[shells + 1]
  points = points + M.OCTOPUS_SCORE[octos + 1]
  points = points + M.PENGUIN_SCORE[penguins + 1]
  points = points + M.SAILOR_SCORE[sailors + 1]

  -- Multipliers count the cards they name and are never one of them.
  if M.countHeld(g, seat, 10) > 0 then points = points + M.countHeld(g, seat, 1) end
  if M.countHeld(g, seat, 11) > 0 then points = points + M.countHeld(g, seat, 2) end
  if M.countHeld(g, seat, 12) > 0 then points = points + 2 * penguins end
  if M.countHeld(g, seat, 13) > 0 then points = points + 3 * sailors end

  -- Each mermaid takes a colour, and no two may take the same one, so n
  -- mermaids take the n largest colour groups.
  local mermaids = M.countHeld(g, seat, 9)
  if mermaids > 0 then
    local perColour = {}
    for i = 1, #M.COLOURS do perColour[i] = M.countHeldColour(g, seat, i - 1) end
    for taken = 1, mermaids do
      local best, bestAt = 0, -1
      for i = 1, #M.COLOURS do
        if perColour[i] > best then best, bestAt = perColour[i], i end
      end
      if bestAt < 0 then break end  -- no colours left to claim
      points = points + best
      perColour[bestAt] = 0
    end
  end
  return points
end

-- 1 point per card of the colour held most. Only ever paid in a
-- LAST CHANCE round, to one side or the other.
function M.colourBonus(g, seat)
  local best = 0
  for i = 1, #M.COLOURS do
    local n = M.countHeldColour(g, seat, i - 1)
    if n > best then best = n end
  end
  return best
end

function M.mayEndRound(g, seat) return M.cardPoints(g, seat) >= M.MIN_END end

-- Did the ender's bet come off? Meaningless unless a bet was made. A tie is
-- the ender's, per the rulebook.
function M.betWon(g)
  if g.ender == M.NO_SEAT then return false end
  return M.cardPoints(g, g.ender) >= M.cardPoints(g, otherSeat(g.ender))
end

-- What the seat actually banks, given how the round ended. Valid once the
-- phase is RoundOver or GameOver.
function M.roundScore(g, seat)
  if g.ender == M.NO_SEAT then return 0 end  -- the deck ran out: nobody scores
  if g.bet == 0 then return M.cardPoints(g, seat) end
  local won = M.betWon(g)
  if seat == g.ender then
    return won and (M.cardPoints(g, seat) + M.colourBonus(g, seat)) or M.colourBonus(g, seat)
  end
  return won and M.colourBonus(g, seat) or M.cardPoints(g, seat)
end

-- Mermaids never leave the hand -- they are not duos and there is no way to
-- lay one down -- so holding all four is the win, and it fires the moment
-- the fourth arrives.
function M.mermaidsHeld(g, seat) return countIn(g, handOf(seat), 9) end

-- -1 until somebody has won.
function M.matchWinner(g)
  for s = 0, M.SEATS - 1 do
    if M.mermaidsHeld(g, s) == M.MERMAIDS_WIN then return s end
  end
  if g.phase ~= M.PHASE.GAMEOVER then return -1 end
  if g.score[1] == g.score[2] then
    -- A tie goes to whoever played last in the final round, which is
    -- whoever did not start it.
    return otherSeat(g.roundStarter)
  end
  return g.score[1] > g.score[2] and 0 or 1
end

-- The duo pairs a seat could lay from hand right now, per duo kind
-- (swimmer and shark pair with each other, so both entries carry the same
-- count).
function M.playablePairs(g, seat, kind)
  local hand = handOf(seat)
  if kind <= 2 then return countIn(g, hand, kind) // 2 end
  if kind == 3 or kind == 4 then
    local sw, sh = countIn(g, hand, 3), countIn(g, hand, 4)
    return sw < sh and sw or sh
  end
  return 0
end

function M.isPair(a, b)
  local ka, kb = CARD_KIND[a], CARD_KIND[b]
  if ka == kb then return ka <= 2 end  -- crab, boat, fish
  return (ka == 3 and kb == 4) or (ka == 4 and kb == 3)
end

-- What the kind-group of `card` currently scores for `seat`: the corner
-- number on every tile. For the mermaid it is her whole share (score with
-- her minus score without her).
function M.groupPoints(g, card, seat)
  local kind = CARD_KIND[card]
  local held = M.countHeld(g, seat, kind)
  if kind <= 2 then return held // 2 end
  if kind == 3 or kind == 4 then
    local sw, sh = M.countHeld(g, seat, 3), M.countHeld(g, seat, 4)
    return sw < sh and sw or sh
  end
  if kind == 5 then return M.SHELL_SCORE[held + 1] end
  if kind == 6 then return M.OCTOPUS_SCORE[held + 1] end
  if kind == 7 then return M.PENGUIN_SCORE[held + 1] end
  if kind == 8 then return M.SAILOR_SCORE[held + 1] end
  if kind == 10 then return M.countHeld(g, seat, 1) end
  if kind == 11 then return M.countHeld(g, seat, 2) end
  if kind == 12 then return 2 * M.countHeld(g, seat, 7) end
  if kind == 13 then return 3 * M.countHeld(g, seat, 8) end
  if kind == 9 then
    local total = M.cardPoints(g, seat)
    local keep = {}
    for c = 1, M.CARDS do keep[c] = g.place[c] end
    for c = 1, M.CARDS do
      if CARD_KIND[c] == 9 and (g.place[c] == handOf(seat) or g.place[c] == tableOf(seat)) then
        g.place[c] = M.PLACE.DECK
      end
    end
    local bare = M.cardPoints(g, seat)
    for c = 1, M.CARDS do g.place[c] = keep[c] end
    return total - bare
  end
  return 0
end

-- ------------------------------------------------------------- playing

local function moveToHand(g, card, seat)
  g.place[card] = handOf(seat)
  g.seq[card] = 0  -- no longer in a pile, so it has no pile order
end

-- Somebody just took a card. If it was the fourth mermaid the game is over
-- right now, mid-turn, before anything else happens.
local function checkMermaidWin(g, seat)
  if M.mermaidsHeld(g, seat) < M.MERMAIDS_WIN then return false end
  g.phase = M.PHASE.GAMEOVER
  return true
end

-- Banks the round and decides whether the match is over. Only called once
-- the last hand that owes a turn has played it.
local function bankRound(g)
  g.score[1] = g.score[1] + M.roundScore(g, 0)
  g.score[2] = g.score[2] + M.roundScore(g, 1)
  local reached = g.score[1] >= M.TARGET or g.score[2] >= M.TARGET
  g.phase = reached and M.PHASE.GAMEOVER or M.PHASE.ROUNDOVER
end

-- Each action is legal in exactly one step and returns false otherwise,
-- changing nothing. Seat 0 / pile 0 are 0-based like the C++ core (Lua
-- arrays are 1-based, but the enums are kept verbatim for clarity).

function M.takeFromDeck(g)
  if g.step ~= M.STEP.TAKE or M.deckRemaining(g) < 1 then return false end
  g.drawn[1] = M.cardAt(g, g.deckNext)
  g.deckNext = g.deckNext + 1
  g.place[g.drawn[1]] = M.PLACE.DRAWN
  if M.deckRemaining(g) >= 1 then
    g.drawn[2] = M.cardAt(g, g.deckNext)
    g.deckNext = g.deckNext + 1
    g.place[g.drawn[2]] = M.PLACE.DRAWN
    g.step = M.STEP.CHOOSEKEEP
    return true
  end
  -- One card left: nothing to reject, the choice collapses.
  g.drawn[2] = M.NO_CARD
  moveToHand(g, g.drawn[1], g.turn)
  g.drawn[1] = M.NO_CARD
  if not checkMermaidWin(g, g.turn) then g.step = M.STEP.PLAY end
  return true
end

function M.takeFromPile(g, pile)
  if g.step ~= M.STEP.TAKE or pile < 0 or pile >= M.PILES then return false end
  local card = M.pileTop(g, pile)
  if card == M.NO_CARD then return false end
  moveToHand(g, card, g.turn)
  if not checkMermaidWin(g, g.turn) then g.step = M.STEP.PLAY end
  return true
end

function M.keepDrawn(g, which)  -- which 1..2
  if g.step ~= M.STEP.CHOOSEKEEP or which < 1 or which > 2 then return false end
  if g.drawn[which] == M.NO_CARD then return false end
  local keep = g.drawn[which]
  local reject = g.drawn[which == 1 and 2 or 1]
  g.drawn[1], g.drawn[2] = M.NO_CARD, M.NO_CARD
  moveToHand(g, keep, g.turn)
  g.pending = reject
  if checkMermaidWin(g, g.turn) then return true end
  -- An empty pile takes the discard: the rulebook gives no choice there.
  for p = 0, M.PILES - 1 do
    if M.pileTop(g, p) == M.NO_CARD then return M.discardTo(g, p) end
  end
  g.step = M.STEP.CHOOSEPILE
  return true
end

function M.discardTo(g, pile)
  if g.pending == M.NO_CARD then return false end
  if g.step ~= M.STEP.CHOOSEKEEP and g.step ~= M.STEP.CHOOSEPILE then return false end
  if pile < 0 or pile >= M.PILES then return false end
  g.place[g.pending] = pileAt(pile)
  g.seq[g.pending] = g.seqNext
  g.seqNext = g.seqNext + 1
  g.pending = M.NO_CARD
  g.step = M.STEP.PLAY
  return true
end

function M.playDuo(g, a, b)
  if g.step ~= M.STEP.PLAY or a == b or a < 1 or a > M.CARDS or b < 1 or b > M.CARDS then return false end
  local mine = handOf(g.turn)
  if g.place[a] ~= mine or g.place[b] ~= mine then return false end
  local ka, kb = CARD_KIND[a], CARD_KIND[b]
  local matched = (ka == kb and ka <= 2) or (ka == 3 and kb == 4) or (ka == 4 and kb == 3)
  if not matched then return false end
  local table = tableOf(g.turn)
  g.place[a], g.place[b] = table, table
  g.seq[a], g.seq[b] = 0, 0
  local pair = ka == 4 and kb or ka
  if pair == 0 then
    -- Only worth a screen if there is something to dig through.
    if M.pileSize(g, 0) > 0 or M.pileSize(g, 1) > 0 then g.step = M.STEP.CRABPILE end
    return true
  elseif pair == 1 then
    g.extraTurns = g.extraTurns + 1
    return true
  elseif pair == 2 then
    if M.deckRemaining(g) > 0 then
      moveToHand(g, M.cardAt(g, g.deckNext), g.turn)
      g.deckNext = g.deckNext + 1
      checkMermaidWin(g, g.turn)
    end
    return true
  elseif pair == 3 then
    -- A revealed hand is out of reach: that is the whole protection the
    -- final turns of a LAST CHANCE round buy.
    local victim = otherSeat(g.turn)
    if g.revealed & (1 << victim) ~= 0 then return true end
    local held = M.handSize(g, victim)
    if held == 0 then return true end
    local state = stealStream(g)
    local wanted = nextRandom(state) % held
    local theirs = handOf(victim)
    for c = 1, M.CARDS do
      if g.place[c] == theirs then
        if wanted > 0 then
          wanted = wanted - 1
        else
          moveToHand(g, c, g.turn)
          checkMermaidWin(g, g.turn)
          break
        end
      end
    end
    return true
  end
  return true
end

function M.chooseCrabPile(g, pile)
  if g.step ~= M.STEP.CRABPILE or pile < 0 or pile >= M.PILES or M.pileSize(g, pile) == 0 then return false end
  g.crabPile = pile
  g.step = M.STEP.CRABPICK
  return true
end

function M.takeCrabCard(g, card)
  if g.step ~= M.STEP.CRABPICK or card < 1 or card > M.CARDS then return false end
  if g.place[card] ~= pileAt(g.crabPile) then return false end
  moveToHand(g, card, g.turn)
  if not checkMermaidWin(g, g.turn) then g.step = M.STEP.PLAY end
  return true
end

function M.canTake(g)
  if M.deckRemaining(g) > 0 then return true end
  for p = 0, M.PILES - 1 do
    if M.pileTop(g, p) ~= M.NO_CARD then return true end
  end
  return false
end

function M.endTurn(g)
  -- Step::Take is allowed here only when there is genuinely nothing to
  -- take, so a player can never skip the draw they owe.
  if g.step == M.STEP.TAKE and not M.canTake(g) then g.step = M.STEP.PLAY end
  if g.step ~= M.STEP.PLAY then return false end
  -- A boat pair buys another whole turn, taken before anybody else moves.
  if g.extraTurns > 0 then
    g.extraTurns = g.extraTurns - 1
    g.step = M.STEP.TAKE
    return true
  end
  -- A bet already on the table outranks the empty deck: the final turns are
  -- owed, they can still be taken off a pile, and the bet resolves.
  if g.phase == M.PHASE.LASTCHANCE then
    g.owed = g.owed & ~(1 << g.turn)
    g.revealed = g.revealed | (1 << g.turn)
    if g.owed == 0 then
      bankRound(g)
      return true
    end
    g.turn = otherSeat(g.turn)
    g.step = M.STEP.TAKE
    return true
  end
  -- "If the deck is empty at the end of a player's turn, the round ends
  -- immediately without scoring." ender stays unset, and that is what
  -- roundScore reads to pay nobody.
  if M.deckRemaining(g) == 0 then
    g.phase = M.PHASE.ROUNDOVER
    return true
  end
  g.turn = otherSeat(g.turn)
  g.step = M.STEP.TAKE
  return true
end

function M.endRound(g, lastChance)
  if g.step ~= M.STEP.PLAY or g.phase ~= M.PHASE.PLAYING then return false end
  if not M.mayEndRound(g, g.turn) then return false end
  g.ender = g.turn
  g.bet = lastChance and 1 or 0
  g.revealed = g.revealed | (1 << g.turn)
  if not lastChance then
    bankRound(g)
    return true
  end
  -- Every opponent owes one more full turn, and their hand is safe once
  -- taken.
  g.phase = M.PHASE.LASTCHANCE
  g.owed = 0
  for s = 0, M.SEATS - 1 do
    if s ~= g.ender then g.owed = g.owed | (1 << s) end
  end
  g.turn = otherSeat(g.turn)
  g.step = M.STEP.TAKE
  return true
end

-- --------------------------------------------------------- observation

-- What one seat is allowed to know: the game with every hidden place
-- collapsed to Unknown. Cards keep their identity wherever they are public,
-- so a pile is still a pile you can reason about; the deck and the
-- opponent's unrevealed hand collapse into the same fog.
function M.observe(g, seat)
  local obs = {
    seat = seat, phase = g.phase, step = g.step,
    view = {}, seq = {}, drawn = { M.NO_CARD, M.NO_CARD },
    pendingDiscard = M.NO_CARD, theirHandSize = M.handSize(g, otherSeat(seat)),
    deckRemaining = M.deckRemaining(g), score = { g.score[1], g.score[2] },
    extraTurns = g.extraTurns, theirRevealed = (g.revealed >> otherSeat(seat)) & 1,
    crabPile = g.crabPile, myTurn = g.turn == seat,
  }
  if obs.myTurn then
    obs.drawn[1], obs.drawn[2] = g.drawn[1], g.drawn[2]
    obs.pendingDiscard = g.pending
  end
  for c = 1, M.CARDS do
    local p = g.place[c]
    local v = M.VIEW.UNKNOWN
    if p == handOf(seat) then
      v = M.VIEW.MYHAND
    elseif p == tableOf(seat) then
      v = M.VIEW.MYTABLE
    elseif p == handOf(otherSeat(seat)) then
      v = obs.theirRevealed == 1 and M.VIEW.THEIRHAND or M.VIEW.UNKNOWN
    elseif p == tableOf(otherSeat(seat)) then
      v = M.VIEW.THEIRTABLE
    elseif p == M.PLACE.PILEA then
      v = M.VIEW.PILEA
      obs.seq[c] = g.seq[c]
    elseif p == M.PLACE.PILEB then
      v = M.VIEW.PILEB
      obs.seq[c] = g.seq[c]
    elseif p == M.PLACE.DRAWN and obs.myTurn then
      v = M.VIEW.MYDRAWN
    end
    obs.view[c] = v
  end
  return obs
end

function M.observeCountView(obs, where, kind)
  local n = 0
  for c = 1, M.CARDS do
    if obs.view[c] == where and CARD_KIND[c] == kind then n = n + 1 end
  end
  return n
end

function M.observeCountMine(obs, kind)
  return M.observeCountView(obs, M.VIEW.MYHAND, kind) + M.observeCountView(obs, M.VIEW.MYTABLE, kind)
end

function M.observeCountMineColour(obs, colour)
  local n = 0
  for c = 1, M.CARDS do
    if (obs.view[c] == M.VIEW.MYHAND or obs.view[c] == M.VIEW.MYTABLE) and CARD_COLOUR[c] == colour then n = n + 1 end
  end
  return n
end

-- My cards' worth, computed only from what I can see. For the observing
-- seat this must equal cardPoints exactly.
function M.observeMyPoints(obs)
  local points = 0
  points = points + M.observeCountMine(obs, 0) // 2
  points = points + M.observeCountMine(obs, 1) // 2
  points = points + M.observeCountMine(obs, 2) // 2
  local sw, sh = M.observeCountMine(obs, 3), M.observeCountMine(obs, 4)
  points = points + (sw < sh and sw or sh)
  local penguins = M.observeCountMine(obs, 7)
  local sailors = M.observeCountMine(obs, 8)
  points = points + M.SHELL_SCORE[M.observeCountMine(obs, 5) + 1]
  points = points + M.OCTOPUS_SCORE[M.observeCountMine(obs, 6) + 1]
  points = points + M.PENGUIN_SCORE[penguins + 1]
  points = points + M.SAILOR_SCORE[sailors + 1]
  if M.observeCountMine(obs, 10) > 0 then points = points + M.observeCountMine(obs, 1) end
  if M.observeCountMine(obs, 11) > 0 then points = points + M.observeCountMine(obs, 2) end
  if M.observeCountMine(obs, 12) > 0 then points = points + 2 * penguins end
  if M.observeCountMine(obs, 13) > 0 then points = points + 3 * sailors end
  local mermaids = M.observeCountMine(obs, 9)
  if mermaids > 0 then
    local perColour = {}
    for i = 1, #M.COLOURS do perColour[i] = M.observeCountMineColour(obs, i - 1) end
    for taken = 1, mermaids do
      local best, bestAt = 0, -1
      for i = 1, #M.COLOURS do
        if perColour[i] > best then best, bestAt = perColour[i], i end
      end
      if bestAt < 0 then break end
      points = points + best
      perColour[bestAt] = 0
    end
  end
  return points
end

return M