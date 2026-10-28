-- core.lua -- Jaipur rules engine, ported from crossplay's JaipurCore.
--
-- Pure Lua, no device namespaces: the 64-byte shared state (also the wire
-- format), all derived quantities, the Observation an AI is allowed to see,
-- and the link turn logic. Two devices rebuild the same deck from the seed
-- that travels in the state, which is what keeps 52 cards out of the packet.
--
-- Indexing: everything that maps to the C++ struct is 0-based -- market[0..4],
-- hand[seat][0..5], sold[0..5], goodsDepth[0..5], goodsTakenBy0[0..5],
-- bonusTakenBy0[0..2], bonusDepth[0..2]. Cards are goods 0..5, CAMEL = 6,
-- EMPTY = 7 (a slot the deck could not refill), UNKNOWN = 8 (a refilled slot
-- the AI has not seen). A Game table holds exactly the documented 64 bytes of
-- stored state; the deck is rebuilt from seed on demand and never stored.

local core = {}

core.GOODS = { "DIAMOND", "GOLD", "SILVER", "CLOTH", "SPICE", "LEATHER" }
core.SHORT = { "DI", "GO", "SV", "CL", "SP", "LE" }
core.GOOD_COUNT = 6
core.SUPPLY = { 6, 6, 6, 8, 8, 10 }       -- cards of each good
core.CAMEL_SUPPLY = 11
core.PILE_DEPTH = { 5, 5, 5, 7, 7, 9 }    -- tokens per good, taken top first
core.TOKENS = {
  { 7, 7, 5, 5, 5 },
  { 6, 6, 5, 5, 5 },
  { 5, 5, 5, 5, 5 },
  { 5, 3, 3, 2, 2, 1, 1 },
  { 5, 3, 3, 2, 2, 1, 1 },
  { 4, 3, 2, 1, 1, 1, 1, 1, 1 },
}
core.BONUS_DEPTH = { 7, 6, 5 }            -- 3 sold, 4 sold, 5+ sold
core.BONUS_TOKENS = {
  { 1, 1, 2, 2, 2, 3, 3 },
  { 4, 4, 5, 5, 6, 6 },
  { 8, 8, 9, 10, 10 },
}
core.CAMEL_TOKEN = 5
core.SEALS_TO_WIN = 2
core.CAMEL = 6
core.EMPTY = 7
core.UNKNOWN = 8
core.HAND_LIMIT = 7
core.MARKET_SLOTS = 5
core.DECK_CARDS = 52
core.OPENING_CAMELS = 3
core.NO_MOVE = 0xFF

core.PLAYING, core.ROUND_OVER, core.GAME_OVER = 0, 1, 2
core.TAKE_ONE, core.TAKE_CAMELS, core.EXCHANGE, core.SELL = 0, 1, 2, 3
core.SKILL_MERCHANT, core.SKILL_MAHARAJA = 0, 1

-- Diamonds, gold and silver never sell alone, even when one token is left.
function core.sells_in_pairs(g) return g <= 2 end

-- ------------------------------------------------------------------ RNG
-- One deterministic xorshift32 stream per seed. The device runs int32 Lua
-- where arithmetic wraps mod 2^32 by itself; on the 64-bit test host wrap32()
-- applies the same mod-2^32 wrap explicitly, and lsr() is pure uint32 logical
-- shift expressed in int32 arithmetic (sign-extended >> plus the top bits), so
-- both platforms produce the same stream for the same seed.
local HOST64 = math.maxinteger > 2147483647

local function wrap32(x)
  if not HOST64 then return x end
  local m = x % 4294967296.0
  m = math.tointeger(m)
  if m >= 2147483648 then m = m - 4294967296 end
  return m
end

local function lsr(v, n)
  if v >= 0 then return v >> n end
  -- int32 arithmetic shift right sign-fills; the uint32 result needs zeros in
  -- the top (32-n) bits instead, which is adding back 2^(32-n).
  return (v >> n) + (1 << (32 - n))
end

local function xorshift(state)
  local s = wrap32(state ~ wrap32(state << 13))
  s = wrap32(s ~ lsr(s, 17))
  return wrap32(s ~ wrap32(s << 5))
end

-- Random stream: pass a table {v = <int32>}; core.roll mutates and returns
-- the next value. Deterministic for a given starting value.
function core.roll(r)
  r.v = xorshift(r.v)
  return r.v
end

-- 0x9E3779B9 as an int32 (264...9 minus 2^32); the constant used to split one
-- seed into independent streams (deck, then one per bonus stack).
local GOLDEN = -1640531527

function core.stream_for(seed, stream)
  local s = wrap32(seed ~ (GOLDEN * (stream + 1)))
  if s == 0 then s = 19088743 end -- 0x01234567: xorshift dies on zero
  return s
end

-- Four bytes -> signed int32, exact integer arithmetic on 32- and 64-bit Lua.
function core.bytes_to_i32(b1, b2, b3, b4)
  local hi = b1 * 256 + b2
  if hi >= 32768 then hi = hi - 65536 end
  return hi * 65536 + b3 * 256 + b4
end

-- ----------------------------------------------------------------- deck
local deck_cache = {}
function core.build_deck(seed)
  local d = deck_cache[seed]
  if d then return d end
  local cards = {}
  local n = 0
  for g = 0, core.GOOD_COUNT - 1 do
    for _ = 1, core.SUPPLY[g + 1] do cards[n] = g; n = n + 1 end
  end
  for _ = 1, core.CAMEL_SUPPLY - core.OPENING_CAMELS do cards[n] = core.CAMEL; n = n + 1 end
  local st = { v = core.stream_for(seed, 0) }
  for i = n - 1, 1, -1 do
    local j = core.roll(st) % (i + 1)
    cards[i], cards[j] = cards[j], cards[i]
  end
  deck_cache[seed] = cards
  return cards
end

local bonus_cache = {}
function core.build_bonus(seed, stack)
  local c = bonus_cache[seed]
  if not c then
    c = {}
    for b = 0, 2 do
      local t = {}
      local depth = core.BONUS_DEPTH[b + 1]
      for i = 1, depth do t[i - 1] = core.BONUS_TOKENS[b + 1][i] end
      local st = { v = core.stream_for(seed, b + 1) }
      for i = depth - 1, 1, -1 do
        local j = core.roll(st) % (i + 1)
        t[i], t[j] = t[j], t[i]
      end
      c[b] = t
    end
    bonus_cache[seed] = c
  end
  return c[stack]
end

-- ------------------------------------------------------------ game state
function core.game_new()
  local g = {
    seed = 0, deckTaken = 0,
    market = {}, hand = {}, herd = { [0] = 0, [1] = 0 },
    sold = {}, goodsTakenBy0 = {}, goodsDepth = {},
    bonusTakenBy0 = {}, bonusDepth = {},
    lastKind = core.NO_MOVE, lastCard = 0, lastCount = 0, lastValue = 0,
    seals = { [0] = 0, [1] = 0 }, turn = 0, roundStarter = 0, phase = core.PLAYING, round = 1,
  }
  g.hand[0] = {}
  g.hand[1] = {}
  for i = 0, core.MARKET_SLOTS - 1 do g.market[i] = core.EMPTY end
  for s = 0, 1 do for gg = 0, 5 do g.hand[s][gg] = 0 end end
  for gg = 0, 5 do g.sold[gg] = 0; g.goodsTakenBy0[gg] = 0; g.goodsDepth[gg] = 0 end
  for b = 0, 2 do g.bonusTakenBy0[b] = 0; g.bonusDepth[b] = 0 end
  return g
end

-- Deals a fresh round in the rulebook's order: 3 camels open the market, the
-- remaining 52 shuffled, 5 each, 2 more to the market, dealt camels to herds.
function core.deal(g, seed, starter)
  g.seed = seed
  g.lastKind = core.NO_MOVE
  g.lastCard = 0
  g.lastCount = 0
  g.lastValue = 0
  for s = 0, 1 do
    g.herd[s] = 0
    for gg = 0, 5 do g.hand[s][gg] = 0 end
  end
  for gg = 0, 5 do
    g.sold[gg] = 0
    g.goodsTakenBy0[gg] = 0
    g.goodsDepth[gg] = 0
  end
  for b = 0, 2 do
    g.bonusTakenBy0[b] = 0
    g.bonusDepth[b] = 0
  end
  local deck = core.build_deck(seed)
  local at = 0
  for s = 0, 1 do
    for _ = 1, 5 do
      local card = deck[at]; at = at + 1
      if card == core.CAMEL then
        g.herd[s] = g.herd[s] + 1
      else
        g.hand[s][card] = g.hand[s][card] + 1
      end
    end
  end
  g.market[0] = core.CAMEL
  g.market[1] = core.CAMEL
  g.market[2] = core.CAMEL
  g.market[3] = deck[at]; at = at + 1
  g.market[4] = deck[at]; at = at + 1
  g.deckTaken = at
  g.turn = starter
  g.roundStarter = starter
  g.phase = core.PLAYING
end

-- A whole new match: seals cleared, round 1 dealt.
function core.new_game(g, seed, starter)
  g.seals[0] = 0
  g.seals[1] = 0
  g.round = 1
  core.deal(g, seed, starter)
end

-- Deals the next round, loser first (draw keeps the same starter). Only valid
-- in ROUND_OVER, by which time the seal is already banked.
function core.start_next_round(g, seed)
  if g.phase ~= core.ROUND_OVER then return end
  local winner = core.round_winner(g)
  local starter = g.roundStarter
  if winner >= 0 then starter = 1 - winner end
  g.round = g.round + 1
  core.deal(g, seed, starter)
end

-- ------------------------------------------------------------ derived
local function popcount(v)
  local n = 0
  while v ~= 0 do v = v & (v - 1); n = n + 1 end
  return n
end

function core.hand_size(g, seat)
  local n = 0
  for gg = 0, 5 do n = n + g.hand[seat][gg] end
  return n
end

function core.deck_remaining(g) return core.DECK_CARDS - g.deckTaken end

function core.market_camels(g)
  local n = 0
  for i = 0, core.MARKET_SLOTS - 1 do
    if g.market[i] == core.CAMEL then n = n + 1 end
  end
  return n
end

function core.empty_piles(g)
  local n = 0
  for gg = 0, 5 do
    if g.goodsDepth[gg] >= core.PILE_DEPTH[gg + 1] then n = n + 1 end
  end
  return n
end

function core.goods_rupees(g, seat, good)
  local total = 0
  local mine = seat == 0 and 1 or 0
  if good then
    for i = 0, g.goodsDepth[good] - 1 do
      if ((g.goodsTakenBy0[good] >> i) & 1) == mine then
        total = total + core.TOKENS[good + 1][i + 1]
      end
    end
    return total
  end
  for gg = 0, 5 do
    for i = 0, g.goodsDepth[gg] - 1 do
      if ((g.goodsTakenBy0[gg] >> i) & 1) == mine then
        total = total + core.TOKENS[gg + 1][i + 1]
      end
    end
  end
  return total
end

function core.goods_token_count(g, seat)
  local n = 0
  for gg = 0, 5 do
    local dug = (1 << g.goodsDepth[gg]) - 1
    local by_zero = g.goodsTakenBy0[gg] & dug
    if seat == 0 then
      n = n + popcount(by_zero)
    else
      n = n + popcount(dug & ~by_zero)
    end
  end
  return n
end

function core.bonus_token_count(g, seat)
  local n = 0
  for b = 0, 2 do
    local dug = (1 << g.bonusDepth[b]) - 1
    local by_zero = g.bonusTakenBy0[b] & dug
    if seat == 0 then
      n = n + popcount(by_zero)
    else
      n = n + popcount(dug & ~by_zero)
    end
  end
  return n
end

function core.bonus_rupees(g, seat)
  local total = 0
  local mine = seat == 0 and 1 or 0
  for b = 0, 2 do
    local tokens = core.build_bonus(g.seed, b)
    for i = 0, g.bonusDepth[b] - 1 do
      if ((g.bonusTakenBy0[b] >> i) & 1) == mine then
        total = total + tokens[i]
      end
    end
  end
  return total
end

-- 5 rupees to strictly more camels; equal camels means nobody takes it.
function core.camel_token_seat(g)
  if g.herd[0] > g.herd[1] then return 0 end
  if g.herd[1] > g.herd[0] then return 1 end
  return -1
end

function core.score(g, seat)
  local total = core.goods_rupees(g, seat) + core.bonus_rupees(g, seat)
  if core.camel_token_seat(g) == seat then total = total + core.CAMEL_TOKEN end
  return total
end

-- What `viewer` may honestly total for `seat` mid-round: goods tokens and the
-- camel token are face up, their bonus tokens are face down (count only).
function core.visible_score(g, viewer, seat)
  local total = core.goods_rupees(g, seat)
  if core.camel_token_seat(g) == seat then total = total + core.CAMEL_TOKEN end
  if viewer == seat then total = total + core.bonus_rupees(g, seat) end
  return total
end

-- Rupees, then bonus tokens, then goods tokens, then camels; -1 = dead heat.
function core.round_winner(g)
  local a = core.score(g, 0)
  local b = core.score(g, 1)
  if a ~= b then return a > b and 0 or 1 end
  local ba = core.bonus_token_count(g, 0)
  local bb = core.bonus_token_count(g, 1)
  if ba ~= bb then return ba > bb and 0 or 1 end
  local ga = core.goods_token_count(g, 0)
  local gb = core.goods_token_count(g, 1)
  if ga ~= gb then return ga > gb and 0 or 1 end
  if g.herd[0] ~= g.herd[1] then return g.herd[0] > g.herd[1] and 0 or 1 end
  return -1
end

function core.match_winner(g)
  for s = 0, 1 do
    if g.seals[s] >= core.SEALS_TO_WIN then return s end
  end
  return -1
end

function core.next_token_value(g, good, depth)
  if depth < 0 or depth >= core.PILE_DEPTH[good + 1] then return 0 end
  return core.TOKENS[good + 1][depth + 1]
end

-- What a sale of `count` of `good` is worth in goods tokens right now.
function core.sale_value(g, good, count)
  local total = 0
  for i = 0, count - 1 do
    local depth = g.goodsDepth[good] + i
    if depth >= core.PILE_DEPTH[good + 1] then break end -- pile ran dry
    total = total + core.TOKENS[good + 1][depth + 1]
  end
  return total
end

-- ------------------------------------------------------------ legality
function core.is_legal(g, move)
  if g.phase ~= core.PLAYING then return false end
  local seat = g.turn
  local k = move.kind
  if k == core.TAKE_ONE then
    local slot = move.slot
    if slot < 0 or slot >= core.MARKET_SLOTS then return false end
    local card = g.market[slot]
    if card == core.CAMEL or card == core.EMPTY then return false end
    return core.hand_size(g, seat) < core.HAND_LIMIT
  elseif k == core.TAKE_CAMELS then
    return core.market_camels(g) > 0
  elseif k == core.EXCHANGE then
    local taken = {}
    local taken_count = 0
    for i = 0, core.MARKET_SLOTS - 1 do
      if ((move.marketMask >> i) & 1) ~= 0 then
        local card = g.market[i]
        if card == core.CAMEL or card == core.EMPTY then return false end
        taken[card] = (taken[card] or 0) + 1
        taken_count = taken_count + 1
      end
    end
    -- An exchange is always at least 2 for 2.
    if taken_count < 2 then return false end
    local given_sum = 0
    if move.giveCamels > g.herd[seat] then return false end
    for gg = 0, core.GOOD_COUNT - 1 do
      local give = move.give[gg] or 0
      if give > g.hand[seat][gg] then return false end
      -- The same goods type may not be both taken and given.
      if give > 0 and (taken[gg] or 0) > 0 then return false end
      given_sum = given_sum + give
    end
    if move.giveCamels + given_sum ~= taken_count then return false end
    -- Giving camels grows the hand, so the limit is checked on the result.
    local after_hand = core.hand_size(g, seat) + taken_count - given_sum
    return after_hand <= core.HAND_LIMIT
  elseif k == core.SELL then
    local good = move.good
    if good < 0 or good >= core.GOOD_COUNT then return false end
    if move.count < 1 then return false end
    if move.count > g.hand[seat][good] then return false end
    if core.sells_in_pairs(good) and move.count < 2 then return false end
    return true
  end
  return false
end

-- ------------------------------------------------------------ applying
-- Applies a legal move, then tests the end of the round, then flips the turn.
-- The round ending completes the move in full first, which is why a sale that
-- empties the third pile still collects its bonus token. A round that ends
-- here also awards its seal here, and goes straight to GAME_OVER if that was
-- somebody's second.
function core.apply(g, move)
  if not core.is_legal(g, move) then return false end
  local seat = g.turn
  local refill_failed = false
  local bonus_before = core.bonus_token_count(g, seat)

  g.lastKind = move.kind | (seat << 7)
  g.lastCard = 0
  g.lastCount = 0
  g.lastValue = 0
  local k = move.kind
  if k == core.TAKE_ONE then
    g.lastCard = g.market[move.slot]
    g.lastCount = 1
  elseif k == core.TAKE_CAMELS then
    g.lastCount = core.market_camels(g)
  elseif k == core.EXCHANGE then
    local n = 0
    for i = 0, core.MARKET_SLOTS - 1 do
      if ((move.marketMask >> i) & 1) ~= 0 then n = n + 1 end
    end
    g.lastCount = n
  elseif k == core.SELL then
    g.lastCard = move.good
    g.lastCount = move.count
    g.lastValue = core.sale_value(g, move.good, move.count)
  end

  if k == core.TAKE_ONE then
    local slot = move.slot
    local card = g.market[slot]
    g.hand[seat][card] = g.hand[seat][card] + 1
    if g.deckTaken < core.DECK_CARDS then
      g.market[slot] = core.build_deck(g.seed)[g.deckTaken]
      g.deckTaken = g.deckTaken + 1
    else
      g.market[slot] = core.EMPTY
      refill_failed = true
    end
  elseif k == core.TAKE_CAMELS then
    -- All of them, each replaced one at a time; the first draw that finds an
    -- empty deck ends the round with the camels already taken.
    for i = 0, core.MARKET_SLOTS - 1 do
      if g.market[i] == core.CAMEL then
        g.herd[seat] = g.herd[seat] + 1
        if g.deckTaken < core.DECK_CARDS then
          g.market[i] = core.build_deck(g.seed)[g.deckTaken]
          g.deckTaken = g.deckTaken + 1
        else
          g.market[i] = core.EMPTY
          refill_failed = true
        end
      end
    end
  elseif k == core.EXCHANGE then
    -- Take first so the vacated slots are known, then refill them from what
    -- was surrendered: no card is drawn, the market is refilled by the trade.
    local slots = {}
    local slot_count = 0
    for i = 0, core.MARKET_SLOTS - 1 do
      if ((move.marketMask >> i) & 1) ~= 0 then
        g.hand[seat][g.market[i]] = g.hand[seat][g.market[i]] + 1
        slots[slot_count] = i
        slot_count = slot_count + 1
      end
    end
    local at = 0
    for gg = 0, 5 do
      for _ = 1, move.give[gg] or 0 do
        g.market[slots[at]] = gg
        at = at + 1
      end
      g.hand[seat][gg] = g.hand[seat][gg] - (move.give[gg] or 0)
    end
    for _ = 1, move.giveCamels do
      g.market[slots[at]] = core.CAMEL
      at = at + 1
    end
    g.herd[seat] = g.herd[seat] - move.giveCamels
  elseif k == core.SELL then
    local gg = move.good
    g.hand[seat][gg] = g.hand[seat][gg] - move.count
    g.sold[gg] = g.sold[gg] + move.count
    for _ = 1, move.count do
      if g.goodsDepth[gg] >= core.PILE_DEPTH[gg + 1] then break end
      if seat == 0 then
        g.goodsTakenBy0[gg] = g.goodsTakenBy0[gg] | (1 << g.goodsDepth[gg])
      end
      g.goodsDepth[gg] = g.goodsDepth[gg] + 1
    end
    -- 3+ earns a bonus, even when the pile came up short; 5+ draws from the
    -- same stack as 5.
    if move.count >= 3 then
      local stack = (move.count >= 5 and 5 or move.count) - 3
      if g.bonusDepth[stack] < core.BONUS_DEPTH[stack + 1] then
        if seat == 0 then
          g.bonusTakenBy0[stack] = g.bonusTakenBy0[stack] | (1 << g.bonusDepth[stack])
        end
        g.bonusDepth[stack] = g.bonusDepth[stack] + 1
      end
    end
  end

  if core.bonus_token_count(g, seat) > bonus_before then
    g.lastValue = g.lastValue | 0x80
  end

  -- The move is complete in full; only now does the round get to end.
  if refill_failed or core.empty_piles(g) >= 3 then
    local winner = core.round_winner(g)
    if winner >= 0 then g.seals[winner] = g.seals[winner] + 1 end
    g.phase = core.match_winner(g) >= 0 and core.GAME_OVER or core.ROUND_OVER
    return true
  end
  g.turn = 1 - seat
  return true
end

-- ------------------------------------------------------------- narration
function core.card_name(card)
  if card == core.CAMEL then return "CAMEL" end
  if card == core.EMPTY then return "" end
  return core.GOODS[card + 1]
end

-- The last move in words, from the viewer's side of the table. One function,
-- so "YOU SOLD" and "THEY SOLD" cannot drift apart.
function core.describe_last_move(g, viewer)
  if (g.lastKind & 0x7F) == 0x7F then return "" end -- nothing played yet
  local who = (g.lastKind >> 7) == viewer and "YOU" or "THEY"
  local k = g.lastKind & 0x7F
  local n = g.lastCount
  local line
  if k == core.TAKE_ONE then
    line = who .. " TOOK A " .. core.card_name(g.lastCard)
  elseif k == core.TAKE_CAMELS then
    line = who .. " TOOK " .. n .. (n == 1 and " CAMEL" or " CAMELS")
  elseif k == core.EXCHANGE then
    line = who .. " TRADED " .. n .. " CARDS"
  else
    line = who .. " SOLD " .. n .. " " .. core.GOODS[g.lastCard + 1] ..
      " FOR " .. (g.lastValue & 0x7F)
  end
  if (g.lastValue & 0x80) ~= 0 then line = line .. " + BONUS" end
  return line
end

-- ---------------------------------------------------------------- link
-- Who may act, over a link. The transport turn and the game turn agree on
-- every move of a round and come apart at a round boundary (the loser starts
-- the next round, which is not necessarily the player who did not send). The
-- fix is the pass: a device holding the transport turn that the rules have
-- nothing for sends the state back unchanged.
function core.link_action(g, seat, my_transport_turn)
  if not my_transport_turn then return "wait" end
  if g.phase == core.GAME_OVER then
    return "wait"
  elseif g.phase == core.ROUND_OVER then
    return "deal"
  end
  if g.turn == seat then return "move" end
  return "pass"
end

-- -------------------------------------------------------- 64-byte state
-- The same layout the doc gives the C++ Game struct: seed, then every byte of
-- the position, then the four last* narration bytes and the match counters.
-- goodsTakenBy0 is uint16 per good; everything else is a byte. 64 bytes, no
-- padding, every byte compared/transmitted.

local HEXPAIR = {}
do
  for i = 0, 255 do HEXPAIR[i + 1] = string.format("%02x", i) end
end

function core.tohex(s)
  local t = {}
  for i = 1, #s do t[i] = HEXPAIR[s:byte(i) + 1] end
  return table.concat(t)
end

function core.fromhex(h)
  local t = {}
  for i = 1, #h, 2 do
    t[#t + 1] = string.char(tonumber(h:sub(i, i + 1), 16))
  end
  return table.concat(t)
end

function core.pack(g)
  local t = {}
  local function w8(v) t[#t + 1] = string.char(v & 0xFF) end
  local s = g.seed
  w8(s >> 24); w8(s >> 16); w8(s >> 8); w8(s)
  w8(g.deckTaken)
  for i = 0, core.MARKET_SLOTS - 1 do w8(g.market[i]) end
  for seat = 0, 1 do for gg = 0, 5 do w8(g.hand[seat][gg]) end end
  for seat = 0, 1 do w8(g.herd[seat]) end
  for gg = 0, 5 do w8(g.sold[gg]) end
  for gg = 0, 5 do local v = g.goodsTakenBy0[gg]; w8(v >> 8); w8(v) end
  for gg = 0, 5 do w8(g.goodsDepth[gg]) end
  for b = 0, 2 do w8(g.bonusTakenBy0[b]) end
  for b = 0, 2 do w8(g.bonusDepth[b]) end
  w8(g.lastKind); w8(g.lastCard); w8(g.lastCount); w8(g.lastValue)
  for seat = 0, 1 do w8(g.seals[seat]) end
  w8(g.turn); w8(g.roundStarter); w8(g.phase); w8(g.round)
  return table.concat(t)
end

function core.unpack(bytes)
  assert(#bytes == 64, "jaipur state must be 64 bytes")
  local at = 1
  local function r8() local v = bytes:byte(at); at = at + 1; return v end
  local g = core.game_new()
  g.seed = core.bytes_to_i32(r8(), r8(), r8(), r8())
  g.deckTaken = r8()
  for i = 0, core.MARKET_SLOTS - 1 do g.market[i] = r8() end
  for seat = 0, 1 do for gg = 0, 5 do g.hand[seat][gg] = r8() end end
  for seat = 0, 1 do g.herd[seat] = r8() end
  for gg = 0, 5 do g.sold[gg] = r8() end
  for gg = 0, 5 do g.goodsTakenBy0[gg] = (r8() << 8) | r8() end
  for gg = 0, 5 do g.goodsDepth[gg] = r8() end
  for b = 0, 2 do g.bonusTakenBy0[b] = r8() end
  for b = 0, 2 do g.bonusDepth[b] = r8() end
  g.lastKind = r8(); g.lastCard = r8(); g.lastCount = r8(); g.lastValue = r8()
  for seat = 0, 1 do g.seals[seat] = r8() end
  g.turn = r8(); g.roundStarter = r8(); g.phase = r8(); g.round = r8()
  return g
end

-- ---------------------------------------------------------- observation
-- What a player is allowed to know. The opponent's hand composition is not a
-- field, so an AI built on this cannot cheat by construction.
function core.observe(g, seat)
  local them = 1 - seat
  local obs = {
    seat = seat,
    market = {}, hand = {},
    herd = { [0] = g.herd[0], [1] = g.herd[1] },
    opponentHandSize = core.hand_size(g, them),
    goodsDepth = {}, bonusDepth = {},
    deckRemaining = core.deck_remaining(g),
    unseen = {}, unseenCamels = 0,
    yourGoodsRupees = core.goods_rupees(g, seat),
    yourBonusRupees = core.bonus_rupees(g, seat),
    theirGoodsRupees = core.goods_rupees(g, them),
    yourBonusCount = core.bonus_token_count(g, seat),
    theirBonusCount = core.bonus_token_count(g, them),
    seals = { [0] = g.seals[0], [1] = g.seals[1] },
    emptyPiles = core.empty_piles(g),
  }
  for i = 0, core.MARKET_SLOTS - 1 do obs.market[i] = g.market[i] end
  for gg = 0, 5 do obs.hand[gg] = g.hand[seat][gg] end
  for gg = 0, 5 do obs.goodsDepth[gg] = g.goodsDepth[gg] end
  for b = 0, 2 do obs.bonusDepth[b] = g.bonusDepth[b] end
  -- Everything not yet seen: the deck plus their hand, derived from public
  -- facts only (total - market - yours - discarded).
  for gg = 0, 5 do
    local seen = obs.hand[gg] + g.sold[gg]
    for i = 0, core.MARKET_SLOTS - 1 do
      if g.market[i] == gg then seen = seen + 1 end
    end
    local left = core.SUPPLY[gg + 1] - seen
    obs.unseen[gg] = left > 0 and left or 0
  end
  local camels_seen = g.herd[0] + g.herd[1] + core.market_camels(g)
  local camel_left = core.CAMEL_SUPPLY - camels_seen
  obs.unseenCamels = camel_left > 0 and camel_left or 0
  return obs
end

-- The observation you would hold after playing `move` yourself. Refilled
-- market slots come back as UNKNOWN, because that is the honest answer --
-- nothing here may consult the deck.
function core.after(obs, move)
  local out = {
    seat = obs.seat,
    market = {}, hand = {},
    herd = { [0] = obs.herd[0], [1] = obs.herd[1] },
    opponentHandSize = obs.opponentHandSize,
    goodsDepth = {}, bonusDepth = {},
    deckRemaining = obs.deckRemaining,
    unseen = {}, unseenCamels = obs.unseenCamels,
    yourGoodsRupees = obs.yourGoodsRupees,
    yourBonusRupees = obs.yourBonusRupees,
    theirGoodsRupees = obs.theirGoodsRupees,
    yourBonusCount = obs.yourBonusCount,
    theirBonusCount = obs.theirBonusCount,
    seals = { [0] = obs.seals[0], [1] = obs.seals[1] },
    emptyPiles = obs.emptyPiles,
  }
  for i = 0, core.MARKET_SLOTS - 1 do out.market[i] = obs.market[i] end
  for gg = 0, 5 do out.hand[gg] = obs.hand[gg] end
  for gg = 0, 5 do out.goodsDepth[gg] = obs.goodsDepth[gg] end
  for b = 0, 2 do out.bonusDepth[b] = obs.bonusDepth[b] end
  for gg = 0, 5 do out.unseen[gg] = obs.unseen[gg] end

  local k = move.kind
  if k == core.TAKE_ONE then
    local card = obs.market[move.slot]
    if card < core.GOOD_COUNT then out.hand[card] = out.hand[card] + 1 end
    out.market[move.slot] = core.UNKNOWN
    if out.deckRemaining > 0 then out.deckRemaining = out.deckRemaining - 1 end
  elseif k == core.TAKE_CAMELS then
    for i = 0, core.MARKET_SLOTS - 1 do
      if obs.market[i] == core.CAMEL then
        out.herd[obs.seat] = out.herd[obs.seat] + 1
        out.market[i] = core.UNKNOWN
        if out.deckRemaining > 0 then out.deckRemaining = out.deckRemaining - 1 end
      end
    end
  elseif k == core.EXCHANGE then
    local slots = {}
    local slot_count = 0
    for i = 0, core.MARKET_SLOTS - 1 do
      if ((move.marketMask >> i) & 1) ~= 0 then
        local card = obs.market[i]
        if card < core.GOOD_COUNT then out.hand[card] = out.hand[card] + 1 end
        slots[slot_count] = i
        slot_count = slot_count + 1
      end
    end
    local at = 0
    for gg = 0, 5 do
      for _ = 1, move.give[gg] or 0 do
        out.market[slots[at]] = gg
        at = at + 1
      end
      out.hand[gg] = out.hand[gg] - (move.give[gg] or 0)
    end
    for _ = 1, move.giveCamels do
      out.market[slots[at]] = core.CAMEL
      at = at + 1
    end
    out.herd[obs.seat] = out.herd[obs.seat] - move.giveCamels
  elseif k == core.SELL then
    local gg = move.good
    out.hand[gg] = out.hand[gg] - move.count
    local paid = 0
    for _ = 1, move.count do
      if out.goodsDepth[gg] >= core.PILE_DEPTH[gg + 1] then break end
      paid = paid + core.TOKENS[gg + 1][out.goodsDepth[gg] + 1]
      out.goodsDepth[gg] = out.goodsDepth[gg] + 1
    end
    out.yourGoodsRupees = out.yourGoodsRupees + paid
    if move.count >= 3 then
      local stack = (move.count >= 5 and 5 or move.count) - 3
      if out.bonusDepth[stack] < core.BONUS_DEPTH[stack + 1] then
        out.bonusDepth[stack] = out.bonusDepth[stack] + 1
        out.yourBonusCount = out.yourBonusCount + 1
        -- The value is face down until scoring, so the mean of what is left in
        -- that stack is the honest estimate.
        local total = 0
        local n = 0
        for i = 0, core.BONUS_DEPTH[stack + 1] - 1 do
          total = total + core.BONUS_TOKENS[stack + 1][i + 1]
          n = n + 1
        end
        out.yourBonusRupees = out.yourBonusRupees + (n > 0 and (total // n) or 0)
      end
    end
  end

  out.emptyPiles = 0
  for gg = 0, 5 do
    if out.goodsDepth[gg] >= core.PILE_DEPTH[gg + 1] then out.emptyPiles = out.emptyPiles + 1 end
  end
  return out
end

return core