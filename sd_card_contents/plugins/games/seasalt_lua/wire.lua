-- wire.lua — Sea Salt game blob for PLAY NEARBY (140 bytes, SeaSaltCore.h).
--
-- The blob is the C++ `seasalt::Game` struct, byte for byte, little-endian, no
-- padding (static_assert sizeof == 140 on the C++ side). A device that is not
-- the first mover sees the seats the other way round, so the blob is always
-- written in the FIRST MOVER's numbering: seat 0 there is whoever goes first.
-- `flip` = true converts between that numbering and this device's, where I am
-- always seat 0. The conversion is an involution, so one function serves both
-- directions.
--
--   0      seed u32            4..61   place[58]       62..119  seq[58]
--   120    seqNext  121 deckNext  122 score0  123 score1  124 turn
--   125 roundStarter  126 phase  127 step  128 round  129 ender
--   130 betWasLastChance  131 owedFinalTurns  132 drawn0  133 drawn1
--   134 pendingDiscard  135 crabPile  136 revealedMask  137 extraTurns
--   138 spare0  139 spare1
--
-- Card ids: the blob is 0-based (0..57, 0xFF = none); the Lua game is 1-based.
-- Seat, phase, step and place values use the same numbers on both sides.
local W = {}

local CARDS, NONE, NOSEAT = 58, 0xFF, 0xFF
local PLACE_FLIP = { [0] = 0, [1] = 2, [2] = 1, [3] = 4, [4] = 3, [5] = 5, [6] = 6, [7] = 7 }
local BODY = "<" .. string.rep("B", CARDS)
local TAIL = "<" .. string.rep("B", 20)

local function seatOut(v, flip) if flip then return v ~ 1 end return v end

local function bitsOut(m, flip)
  if not flip then return m end
  return ((m & 1) << 1) | ((m >> 1) & 1)
end

local function cardOut(c)  -- Lua card id (1..58, nil/NONE = none) -> blob id
  if c == nil or c == NONE then return NONE end
  return c - 1
end

local function cardIn(v)  -- blob id -> Lua card id
  if v == NONE then return NONE end
  return v + 1
end

-- Serialises `g` (the local game table) as the 140-byte blob.
function W.pack(g, flip)
  local place, seq = {}, {}
  for c = 1, CARDS do
    place[c] = flip and PLACE_FLIP[g.place[c]] or g.place[c]
    seq[c] = g.seq[c]
  end
  local score0, score1 = g.score[1], g.score[2]
  if flip then score0, score1 = score1, score0 end
  local ender = g.ender == NOSEAT and NOSEAT or seatOut(g.ender, flip)
  local tail = string.pack(TAIL,
    g.seqNext, g.deckNext, score0, score1,
    seatOut(g.turn, flip), seatOut(g.roundStarter, flip),
    g.phase, g.step, g.round, ender,
    g.bet, bitsOut(g.owed, flip),
    cardOut(g.drawn[1]), cardOut(g.drawn[2]), cardOut(g.pending), g.crabPile,
    bitsOut(g.revealed, flip), g.extraTurns, 0, 0)
  return string.pack("<I4", g.seed)
    .. string.pack(BODY, table.unpack(place))
    .. string.pack(BODY, table.unpack(seq))
    .. tail
end

-- Parses a blob into a local game table, or nil when it is not a legal shape.
-- Every field is checked against its range, and the deck must match the deal
-- cursor, so a frame from another build or a damaged frame is refused whole.
function W.unpack(s, flip)
  if type(s) ~= "string" or #s ~= 140 then return nil end
  local seed = string.unpack("<I4", s, 1)
  local raw = { string.unpack(BODY, s, 5) }
  local seqRaw = { string.unpack(BODY, s, 63) }
  local t = { string.unpack(TAIL, s, 121) }
  local seqNext, deckNext, score0, score1 = t[1], t[2], t[3], t[4]
  local turn, roundStarter, phase, step, round, ender = t[5], t[6], t[7], t[8], t[9], t[10]
  local bet, owed, drawn0, drawn1, pending, crabPile = t[11], t[12], t[13], t[14], t[15], t[16]
  local revealed, extraTurns = t[17], t[18]

  if seqNext < 1 or deckNext > CARDS then return nil end
  if turn > 1 or roundStarter > 1 then return nil end
  if ender ~= NOSEAT and ender > 1 then return nil end
  if phase > 3 or step > 5 then return nil end
  if bet > 1 or owed > 3 or revealed > 3 or crabPile > 1 then return nil end
  for _, v in ipairs({ drawn0, drawn1, pending }) do
    if v ~= NONE and v >= CARDS then return nil end
  end

  local place, seq, deck = {}, {}, 0
  for c = 1, CARDS do
    local p = raw[c]
    if p > 7 then return nil end
    if p == 0 then deck = deck + 1 end
    place[c] = flip and PLACE_FLIP[p] or p
    seq[c] = seqRaw[c]
  end
  if deck ~= CARDS - deckNext then return nil end  -- the deck is the cards not yet dealt

  if flip then score0, score1 = score1, score0 end
  local g = {
    seed = seed, place = place, seq = seq, seqNext = seqNext, deckNext = deckNext,
    score = { score0, score1 },
    turn = seatOut(turn, flip), roundStarter = seatOut(roundStarter, flip),
    phase = phase, step = step, round = round,
    ender = ender == NOSEAT and NOSEAT or seatOut(ender, flip),
    bet = bet, owed = bitsOut(owed, flip),
    drawn = { cardIn(drawn0), cardIn(drawn1) }, pending = cardIn(pending), crabPile = crabPile,
    revealed = bitsOut(revealed, flip), extraTurns = extraTurns,
  }
  return g
end

return W
