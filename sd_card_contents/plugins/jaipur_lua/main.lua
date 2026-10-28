-- Jaipur for the X4, ported from crossplay's JaipurCore/JaipurBrain/JaipurLink.
--
-- The two-player trading game (solo vs the Maharaja, or two devices over
-- ESP-NOW nearby). First to two seals wins the match; a round ends when three
-- goods piles are empty or the deck cannot refill the market.
--
-- Buttons (no touch on the X4): a cursor walks the board -- Left/Right move
-- across a row, Up/Down switch rows (market / hand / your herd / the action
-- capsule), OK acts on the cell under it. Building a move is selection, the
-- same three interactions as the touch version: tap a market good to take or
-- start an exchange, tap goods in your hand to give them (or press once to
-- sell), tap the camels to take them all. The capsule names the one action
-- the current selection means and is live when it is legal, dithered when not.
--
-- The opponent's move is reported under the score strip; the turn comes
-- straight back -- no tap-to-continue beat.
--
-- The AI is handed an Observation (core.observe), never the game, so it
-- cannot see your hand by construction. Nearby mode ships the 64-byte state
-- from core.pack; both devices rebuild the same deck from the seed.

local core = require("core")
local brain = require("brain")
local link = require("link")

local W, H = gfx.size()

-- Forward declarations: the screen loops reference each other (a finished
-- board delegates to the round screen, which deals back into the board).
local draw_board, round_loop, board_loop, start_solo

-- ------------------------------------------------------------- app state
local S = {
  mode = "solo",              -- "solo" | "nearby"
  seat = 0,                   -- my seat; solo the human is always 0
  game = core.game_new(),
  has_save = false,
  recorded = false,
  played = 0, won = 0,
  menu = 0,
  help = 0,
  cur_row = 0, cur_col = 0,   -- cursor: 0 market, 1 hand, 2 herd, 3 capsule
  sel = { mask = 0, hand = {}, camels = 0, camel_take = false },
  report = "",
  caps = "YOUR MOVE",
  can_commit = false,
  ai_rng = { v = 0 },
  deal_rng = { v = 0 },
  status = "",
  lk = { seq = 0, pending = nil, applied = {}, my_transport = false, role = "host" },
}
do
  for g = 0, 5 do S.sel.hand[g] = 0 end
end

local function popcount(v)
  local n = 0
  while v ~= 0 do v = v & (v - 1); n = n + 1 end
  return n
end

local function new_seed()
  local b = crypto.random(4)
  return core.bytes_to_i32(b:byte(1), b:byte(2), b:byte(3), b:byte(4))
end

local function my_turn()
  local g = S.game
  if g.phase ~= core.PLAYING then return false end
  if S.mode == "solo" then return g.turn == 0 end
  return core.link_action(g, S.seat, S.lk.my_transport) == "move"
end

local function selection_empty()
  if S.sel.mask ~= 0 or S.sel.camels ~= 0 or S.sel.camel_take then return false end
  for g = 0, 5 do if S.sel.hand[g] ~= 0 then return false end end
  return true
end

local function clear_selection()
  S.sel.mask = 0
  S.sel.camels = 0
  S.sel.camel_take = false
  for g = 0, 5 do S.sel.hand[g] = 0 end
end

-- ----------------------------------------------------------------- saves
local SAVE_VER = 1

local function save_game()
  if S.mode ~= "solo" then return end
  local g = S.game
  if not S.has_save or g.phase == core.GAME_OVER then
    if fs.exists("data:jaipur.sav") then fs.remove("data:jaipur.sav") end
    return
  end
  fs.write("data:jaipur.sav", SAVE_VER .. " " .. S.seat .. " " .. core.tohex(core.pack(g)))
end

local function load_game()
  local line = fs.read("data:jaipur.sav")
  if not line then return false end
  local ver, seat, hex = line:match("^(%d+) (%d) (%x+)$")
  if not ver or tonumber(ver) ~= SAVE_VER or not hex or #hex ~= 128 then return false end
  local g = core.unpack(core.fromhex(hex))
  -- A save that does not obey the rules came from another build: refuse it.
  local cards = core.hand_size(g, 0) + core.hand_size(g, 1) + g.herd[0] + g.herd[1] +
    core.deck_remaining(g)
  for i = 0, 4 do if g.market[i] ~= core.EMPTY then cards = cards + 1 end end
  for gg = 0, 5 do cards = cards + g.sold[gg] end
  if cards ~= 55 or core.hand_size(g, 0) > core.HAND_LIMIT or core.hand_size(g, 1) > core.HAND_LIMIT then
    fs.remove("data:jaipur.sav")
    return false
  end
  S.game = g
  S.seat = tonumber(seat) & 1
  return true
end

local function save_stats()
  fs.write("data:jaipur.stats", "1 " .. S.played .. " " .. S.won .. "\n")
end

local function load_stats()
  local line = fs.read("data:jaipur.stats")
  if not line then return end
  local ver, played, won = line:match("^(%d+) (%d+) (%d+)")
  if ver and tonumber(ver) == 1 then
    S.played = tonumber(played)
    S.won = tonumber(won)
  end
end

local function record_result()
  if S.recorded then return end
  S.recorded = true
  S.played = S.played + 1
  if core.match_winner(S.game) == S.seat then S.won = S.won + 1 end
  save_stats()
end

-- ---------------------------------------------------------- moves / AI
local function selection_move()
  if S.sel.camel_take then return { kind = core.TAKE_CAMELS } end
  local market_picked = popcount(S.sel.mask)
  local hand_picked = 0
  local only_good = -1
  for g = 0, 5 do
    if S.sel.hand[g] > 0 then
      hand_picked = hand_picked + S.sel.hand[g]
      only_good = only_good < 0 and g or -2
    end
  end
  if market_picked == 1 and hand_picked == 0 and S.sel.camels == 0 then
    local slot = 0
    while ((S.sel.mask >> slot) & 1) == 0 do slot = slot + 1 end
    return { kind = core.TAKE_ONE, slot = slot }
  end
  if market_picked >= 1 then
    return { kind = core.EXCHANGE, marketMask = S.sel.mask, giveCamels = S.sel.camels, give = S.sel.hand }
  end
  if only_good >= 0 then
    return { kind = core.SELL, good = only_good, count = S.sel.hand[only_good] }
  end
  return nil
end

local function refresh_capsule()
  local g = S.game
  if g.phase ~= core.PLAYING then
    S.caps = "SEE SCORES"
    S.can_commit = true
    return
  end
  if not my_turn() then
    S.caps = S.mode == "solo" and "THE MAHARAJA IS TRADING" or "THEY ARE TRADING"
    S.can_commit = false
    return
  end
  if S.sel.camel_take then
    local n = core.market_camels(g)
    S.caps = "TAKE " .. n .. (n == 1 and " CAMEL" or " CAMELS")
    S.can_commit = true
    return
  end
  local market_picked = popcount(S.sel.mask)
  local hand_picked = 0
  local only_good = -1
  for gg = 0, 5 do
    if S.sel.hand[gg] > 0 then
      hand_picked = hand_picked + S.sel.hand[gg]
      only_good = only_good < 0 and gg or -2
    end
  end
  if market_picked == 1 and hand_picked == 0 and S.sel.camels == 0 then
    local slot = 0
    while ((S.sel.mask >> slot) & 1) == 0 do slot = slot + 1 end
    S.caps = "TAKE " .. core.card_name(g.market[slot])
    S.can_commit = true
    return
  end
  if market_picked >= 1 then
    -- Says what it would be even while it is short: the capsule teaches the
    -- rule (an exchange is at least 2 for 2).
    S.caps = "EXCHANGE " .. (hand_picked + S.sel.camels) .. " FOR " .. market_picked
    S.can_commit = true
    return
  end
  if only_good >= 0 then
    if core.sells_in_pairs(only_good) and S.sel.hand[only_good] < 2 then
      S.caps = core.GOODS[only_good + 1] .. " SELLS IN PAIRS"
      S.can_commit = false
      return
    end
    local value = core.sale_value(g, only_good, S.sel.hand[only_good])
    S.caps = "SELL " .. S.sel.hand[only_good] .. " " .. core.GOODS[only_good + 1] .. " -> " .. value
    S.can_commit = true
    return
  end
  S.caps = "YOUR MOVE"
  S.can_commit = false
end

-- The AI, seat 1, from an Observation -- never the game.
local function ai_turn()
  local g = S.game
  if g.phase ~= core.PLAYING or g.turn ~= 1 then return end
  local obs = core.observe(g, 1)
  local move = brain.choose_move(obs, core.SKILL_MAHARAJA, S.ai_rng)
  -- choose_move only ever returns a legal move (proven by the host tests
  -- move-for-move against the rules engine); this is the belt to that braces.
  if not core.is_legal(g, move) then
    local list = brain.legal_moves(obs)
    move = list[1]
  end
  if move and core.is_legal(g, move) and core.apply(g, move) then
    S.report = core.describe_last_move(g, 0)
  end
  refresh_capsule()
  draw_board()
end

local function commit_move()
  local g = S.game
  if g.phase ~= core.PLAYING then
    round_loop()
    return
  end
  if not my_turn() then return end
  local move = selection_move()
  if not move or not core.is_legal(g, move) then return end
  core.apply(g, move)
  S.report = core.describe_last_move(g, S.seat)
  clear_selection()
  refresh_capsule()
  draw_board() -- your own move reaches the panel first
  if S.mode == "nearby" then
    link.send_state(g, S.lk)
  else
    ai_turn()
  end
end

-- ------------------------------------------------------------- selection
local function tap_market(slot)
  local g = S.game
  local card = g.market[slot]
  if card == core.EMPTY then return end
  if card == core.CAMEL then
    -- All or nothing, and never part of a trade: tapping the camels takes
    -- the camel take and clears whatever was being built.
    local was = S.sel.camel_take
    clear_selection()
    S.sel.camel_take = not was
    return
  end
  if S.sel.camel_take then clear_selection() end
  S.sel.mask = S.sel.mask ~ (1 << slot)
  if S.sel.mask ~= 0 then
    for g = 0, 5 do S.sel.hand[g] = 0 end -- a take/drop, not a sale
    S.sel.camels = 0
  end
end

local function tap_hand(good)
  local g = S.game
  if S.sel.camel_take then clear_selection() end
  if g.hand[S.seat][good] == 0 then return end
  -- Pressing the same good again takes one more and wraps at the top: at
  -- everything you hold for a sale, at what the exchange needs.
  local most = g.hand[S.seat][good]
  if S.sel.mask ~= 0 then
    local wanted = popcount(S.sel.mask)
    if most > wanted then most = wanted end
  end
  local picked = S.sel.hand[good] or 0
  S.sel.hand[good] = picked >= most and 0 or picked + 1
  if S.sel.mask == 0 then
    for other = 0, 5 do if other ~= good then S.sel.hand[other] = 0 end end
    S.sel.camels = 0 -- building a sale: one goods type only
  end
end

local function tap_herd()
  local g = S.game
  if S.sel.camel_take then clear_selection() end
  if S.sel.mask == 0 then return end -- camels are only ever given, in a trade
  local most = g.herd[S.seat]
  local wanted = popcount(S.sel.mask)
  if most > wanted then most = wanted end
  S.sel.camels = S.sel.camels >= most and 0 or S.sel.camels + 1
end

local function cursor_act()
  if not my_turn() then return end
  local r, c = S.cur_row, S.cur_col
  if r == 0 then tap_market(c)
  elseif r == 1 then tap_hand(c)
  elseif r == 2 then tap_herd() end
  refresh_capsule()
  draw_board()
end

local ROW_LEN = { [0] = 5, [1] = 6, [2] = 1, [3] = 1 } -- rows: market, hand, herd, capsule
local function cursor_move(dx, dy)
  local r = S.cur_row + dy
  if r < 0 then r = 0 elseif r > 3 then r = 3 end
  S.cur_row = r
  local c = S.cur_col + dx
  if c < 0 then c = 0 elseif c > ROW_LEN[r] - 1 then c = ROW_LEN[r] - 1 end
  S.cur_col = c
  draw_board()
end

-- ---------------------------------------------------------------- layout
local BY = {}
local function layout()
  BY.market_y = math.floor(84 * H / 800)
  BY.market_h = math.max(72, math.floor(104 * H / 800))
  BY.piles_y = BY.market_y + BY.market_h + 10
  BY.piles_h = math.max(64, math.floor(94 * H / 800))
  BY.bonus_y = BY.piles_y + BY.piles_h + 8
  BY.hand_y = BY.bonus_y + 40
  BY.hand_h = math.max(72, math.floor(104 * H / 800))
  BY.herd_y = BY.hand_y + BY.hand_h + 10
  BY.herd_h = math.max(36, math.floor(46 * H / 800))
  BY.caps_y = H - 88
  BY.hint_y = H - 34
end

local function cols(n, x0, x1, gap)
  local w = ((x1 - x0) - (n - 1) * gap) // n
  local out = {}
  for i = 0, n - 1 do out[i] = { x = x0 + i * (w + gap), w = w } end
  return out
end

local function cursor_at(r, c)
  return S.cur_row == r and S.cur_col == c
end

local function frame_card(x, y, w, h, selected, hollow)
  gfx.rounded_rect(x, y, w, h, 6, not hollow, false)
  gfx.rounded_rect(x, y, w, h, 6, false, true)
  if selected then gfx.rect(x + 2, y + 2, w - 4, h - 4, false) end
end

local function cursor_marks(x, y, w, h)
  gfx.rect(x + 4, y + 3, w - 8, 5, true)
  gfx.rect(x + 4, y + h - 8, w - 8, 5, true)
end

local function draw_market_card(x, y, w, h, card, selected, dim)
  if card == core.EMPTY then
    -- The deck could not refill this slot, so the round is ending.
    gfx.rounded_rect(x, y, w, h, 6, false, true)
    return
  end
  frame_card(x, y, w, h, selected, false)
  local label = card == core.CAMEL and "CAMEL" or core.GOODS[card + 1]
  gfx.text(x + w // 2, y + (h - 22) // 2, label, "sans16", "c")
end

local function draw_pile(x, y, w, h, good)
  local depth = S.game.goodsDepth[good]
  local left = core.PILE_DEPTH[good + 1] - depth
  frame_card(x, y, w, h, false, false)
  gfx.text(x + w // 2, y + 8, left > 0 and tostring(core.next_token_value(S.game, good, depth)) or "-", "sans16", "c")
  gfx.text(x + w // 2, y + 32, core.SHORT[good + 1], "small", "c")
  -- Depth pips: spent tokens hollow out, what is still on the pile stays
  -- solid, so the row reads as a stack being eaten from the top.
  local total = core.PILE_DEPTH[good + 1]
  local pip = (w - 12) // total
  if pip > 6 then pip = 6 end
  if pip < 2 then pip = 2 end
  local gap = 2
  local span = total * pip + (total - 1) * gap
  local sx = x + (w - span) // 2
  local py = y + h - pip - 6
  for i = 0, total - 1 do
    local px = sx + i * (pip + gap)
    if i < depth then
      gfx.rect(px, py, pip, pip, false)
    else
      gfx.rect(px, py, pip, pip, true)
    end
  end
end

local function draw_bonus(x, y, w, h, b)
  local left = core.BONUS_DEPTH[b + 1] - S.game.bonusDepth[b]
  frame_card(x, y, w, h, false, false)
  gfx.text(x + w // 2, y + (h - 18) // 2, string.format("%d+ x%d", b + 3, left), "ui12", "c")
end

local function draw_hand(x, y, w, h, good)
  local held = S.game.hand[S.seat][good]
  local picked = S.sel.hand[good] or 0
  frame_card(x, y, w, h, picked > 0, held == 0)
  gfx.text(x + w // 2, y + 10, picked > 0 and (picked .. "/" .. held) or tostring(held), "sans16", "c")
  gfx.text(x + w // 2, y + 36, core.SHORT[good + 1], "small", "c")
end

local function draw_herd(x, y, w, h)
  local camels = S.game.herd[S.seat]
  frame_card(x, y, w, h, S.sel.camels > 0, false)
  local label
  if S.sel.camels > 0 then
    label = "YOUR CAMELS " .. S.sel.camels .. "/" .. camels
  else
    label = camels == 1 and "YOUR 1 CAMEL" or ("YOUR " .. camels .. " CAMELS")
  end
  gfx.text(x + w // 2, y + (h - 18) // 2, label, "ui12", "c")
end

local function draw_theirs(x, y, w, h)
  local them = 1 - S.seat
  local camels = S.game.herd[them]
  frame_card(x, y, w, h, false, false)
  local label = string.format("THEM %d CARDS  %d %s", core.hand_size(S.game, them), camels,
    camels == 1 and "CAMEL" or "CAMELS")
  gfx.text(x + w // 2, y + (h - 18) // 2, label, "ui12", "c")
end

local function draw_capsule(label, live, selected)
  local y = BY.caps_y
  if live then
    gfx.rounded_rect(16, y, W - 32, 44, 10, true, true)
    gfx.text(W // 2, y + 12, label, "ui12", "cw")
  else
    gfx.rounded_rect(16, y, W - 32, 44, 10, true, false)
    gfx.rounded_rect(16, y, W - 32, 44, 10, false, true)
    gfx.text(W // 2, y + 12, label, "ui12", "c")
  end
  if selected then gfx.rect(18, y + 2, W - 36, 40, false) end
end

-- ---------------------------------------------------------------- board
draw_board = function()
  layout()
  gfx.clear()
  local g = S.game
  local them = 1 - S.seat

  gfx.rect(0, 0, W, 38, true)
  gfx.text(12, 9, "JAIPUR", "sans16", "bw")
  gfx.text(W - 12, 12, S.mode == "solo" and "SOLO" or (S.lk.role == "host" and "HOST" or "JOIN"), "ui12", "rw")

  local their_bonus = core.bonus_token_count(g, them)
  local suffix = their_bonus > 0 and ("+" .. their_bonus .. "?") or ""
  local line = string.format("SEALS %d-%d   YOU %d   THEM %d%s   DECK %d", g.seals[0], g.seals[1],
    core.visible_score(g, S.seat, S.seat), core.visible_score(g, S.seat, them), suffix, core.deck_remaining(g))
  gfx.text(W // 2, 44, line, "ui12", "c")
  gfx.text(12, 62, S.report == "" and " " or S.report, "small")

  local yours = my_turn()
  local hand_full = core.hand_size(g, S.seat) >= core.HAND_LIMIT
  local mc = cols(core.MARKET_SLOTS, 12, W - 12, 8)
  for i = 0, 4 do
    local card = g.market[i]
    local selected = card == core.CAMEL and S.sel.camel_take or (((S.sel.mask >> i) & 1) ~= 0)
    local dim = not yours or (card ~= core.CAMEL and hand_full and S.sel.mask == 0 and not S.sel.camel_take)
    draw_market_card(mc[i].x, BY.market_y, mc[i].w, BY.market_h, card, selected, dim)
    if cursor_at(0, i) and not dim then cursor_marks(mc[i].x, BY.market_y, mc[i].w, BY.market_h) end
  end

  local pc = cols(6, 12, W - 12, 5)
  for gg = 0, 5 do draw_pile(pc[gg].x, BY.piles_y, pc[gg].w, BY.piles_h, gg) end

  local bc = cols(3, 12, 12 + ((W - 24) * 3) // 5, 8)
  for b = 0, 2 do draw_bonus(bc[b].x, BY.bonus_y, bc[b].w, 32, b) end

  local hc = cols(6, 12, W - 12, 5)
  for gg = 0, 5 do
    draw_hand(hc[gg].x, BY.hand_y, hc[gg].w, BY.hand_h, gg)
    if cursor_at(1, gg) and yours then cursor_marks(hc[gg].x, BY.hand_y, hc[gg].w, BY.hand_h) end
  end

  local hw = (W - 32) // 2
  draw_herd(12, BY.herd_y, hw, BY.herd_h)
  draw_theirs(12 + hw + 8, BY.herd_y, hw, BY.herd_h)
  if cursor_at(2, 0) and yours and S.sel.mask ~= 0 then cursor_marks(12, BY.herd_y, hw, BY.herd_h) end

  draw_capsule(S.caps, S.can_commit, cursor_at(3, 0))
  if S.mode == "nearby" and S.status ~= "" then
    gfx.text(12, BY.caps_y + 50, S.status, "small")
  end
  gfx.text(W // 2, BY.hint_y,
    S.mode == "nearby" and "OK = select or play   Back = leave" or
      "L/R move   U/D row   OK act   Back clear or leave", "small", "c")
  gfx.present()
end

-- ------------------------------------------------------- round over
draw_round = function()
  gfx.clear()
  local g = S.game
  local them = 1 - S.seat

  gfx.rect(0, 0, W, 38, true)
  gfx.text(12, 9, "JAIPUR", "sans16", "bw")
  gfx.text(W - 12, 12, string.format("ROUND %d", g.round), "ui12", "rw")

  local winner = core.round_winner(g)
  local you_won = winner == S.seat
  local verdict
  if g.phase == core.GAME_OVER then
    verdict = you_won and "YOU WIN THE GAME" or "THEY WIN THE GAME"
  elseif winner < 0 then
    verdict = "A DEAD HEAT, NO SEAL"
  else
    verdict = you_won and "YOU TAKE THE SEAL" or "THEY TAKE THE SEAL"
  end
  gfx.text(W // 2, 46, verdict, "sans16", "c")

  local camel_seat = core.camel_token_seat(g)
  local rows = {}
  for gg = 0, 5 do
    rows[#rows + 1] = { label = core.SHORT[gg + 1],
      mine = core.goods_rupees(g, S.seat, gg), theirs = core.goods_rupees(g, them, gg) }
  end
  rows[#rows + 1] = { label = "BONUS", mine = core.bonus_rupees(g, S.seat), theirs = core.bonus_rupees(g, them) }
  rows[#rows + 1] = { label = "CAMEL", mine = camel_seat == S.seat and core.CAMEL_TOKEN or 0,
    theirs = camel_seat == them and core.CAMEL_TOKEN or 0 }

  local y = 84
  local col = (W - 60) // 2
  gfx.text(60, y, "YOU", "ui12")
  gfx.text(60 + col, y, "THEM", "ui12")
  y = y + 22
  gfx.rect(16, y, W - 32, 2, true)
  y = y + 10
  for _, r in ipairs(rows) do
    gfx.text(16, y, r.label, "ui12")
    gfx.text(60 + col // 2, y + 2, tostring(r.mine), "sans16", "c")
    gfx.text(60 + col + col // 2, y + 2, tostring(r.theirs), "sans16", "c")
    y = y + 36
  end
  gfx.rect(16, y, W - 32, 2, true)
  y = y + 10
  gfx.text(16, y, "RUPEES", "ui12")
  gfx.text(60 + col // 2, y + 2, tostring(core.score(g, S.seat)), "sans16", "c")
  gfx.text(60 + col + col // 2, y + 2, tostring(core.score(g, them)), "sans16", "c")
  y = y + 44

  -- Seals: two slots a side, filled as they are won.
  local pip = 22
  local span = core.SEALS_TO_WIN * pip + (core.SEALS_TO_WIN - 1) * 8
  local centers = { [0] = 60 + col // 2, [1] = 60 + col + col // 2 }
  for seat = 0, 1 do
    for i = 1, core.SEALS_TO_WIN do
      local px = centers[seat] - span // 2 + (i - 1) * (pip + 8)
      if i <= g.seals[seat] then
        gfx.rounded_rect(px, y, pip, pip, pip // 2, true, true)
      else
        gfx.rounded_rect(px, y, pip, pip, pip // 2, false, true)
      end
    end
  end

  -- The one control of the screen.
  local live = true
  local label
  if g.phase == core.GAME_OVER then
    label = "PLAY AGAIN"
    if S.mode == "nearby" then
      live = S.lk.my_transport -- the holder of the transport turn deals
      if not live then label = "PLAY AGAIN (THEY DEAL)" end
    end
  else
    label = "NEXT ROUND"
    if S.mode == "nearby" then
      live = S.lk.my_transport
      if not live then label = "WAITING FOR THEM TO DEAL" end
    end
  end
  draw_capsule(label, live, false)
  gfx.text(W // 2, H - 34, "OK = " .. (label:sub(1, 12)) .. "   Back = menu", "small", "c")
  gfx.present()
end

round_loop = function()
  refresh_capsule()
  draw_round()
  while true do
    local ev = input.wait()
    if ev == "back" then
      if S.mode == "solo" then
        save_game()
        if S.game.phase == core.GAME_OVER then record_result() end
      else
        link.stop()
        S.mode = "solo"
      end
      return
    elseif ev == "confirm" then
      local g = S.game
      if g.phase == core.GAME_OVER then
        record_result()
        if S.mode == "nearby" then
          if not S.lk.my_transport then
            S.status = "the other device deals the rematch"
            draw_round()
          else
            link.new_match(S.lk, S.seat)
            S.game = core.game_new()
            core.new_game(S.game, new_seed(), 0)
            link.send_state(S.game, S.lk)
            S.report = ""
            S.status = ""
            clear_selection()
            board_loop()
            return
          end
        else
          start_solo()
          board_loop()
          return
        end
      else
        -- NEXT ROUND: exactly one device deals (the one holding the transport
        -- turn over a link; the solo human always).
        if S.mode == "nearby" and not S.lk.my_transport then
          S.status = "they are dealing the next round"
          draw_round()
        else
          core.start_next_round(g, new_seed())
          if S.mode == "nearby" then link.send_state(g, S.lk) end
          S.report = ""
          clear_selection()
          refresh_capsule()
          if S.mode == "solo" then ai_turn() end
          board_loop()
          return
        end
      end
    end
  end
end

-- ---------------------------------------------------------------- link
local function adopt_state()
  local g = S.game
  S.report = core.describe_last_move(g, S.seat)
  S.lk.my_transport = true
  clear_selection()
  local act = core.link_action(g, S.seat, true)
  if act == "pass" then
    -- The rules have nothing for this device although the transport just
    -- handed it the turn: the loser starts a round. Send it back unchanged.
    link.send_state(g, S.lk)
  elseif act == "deal" then
    -- The round is scored and this device holds the deck: the round screen
    -- offers NEXT ROUND here (and only here).
    round_loop()
    return
  end
  refresh_capsule()
  draw_board()
end

board_loop = function()
  -- A solo game resumed mid-AI-turn, or one the AI opened.
  if S.mode == "solo" and S.game.phase == core.PLAYING and S.game.turn == 1 then ai_turn() end
  refresh_capsule()
  draw_board()
  while true do
    if S.mode == "nearby" then
      local now = system.millis()
      local data = espnow.recv()
      while data do
        link.handle_frame(data, S.lk, function(incoming)
          S.game = incoming
          adopt_state()
        end)
        data = espnow.recv()
      end
      if link.tick(S.lk, now) then
        S.status = "sending..."
      else
        S.status = ""
      end
    end
    local ev = input.wait(S.mode == "nearby" and 200 or nil)
    if ev == "back" then
      if not selection_empty() then
        clear_selection()
        refresh_capsule()
        draw_board()
      else
        if S.mode == "solo" then save_game() else link.stop(); S.mode = "solo" end
        return
      end
    elseif ev == "confirm" then
      if S.cur_row == 3 then
        commit_move()
      else
        cursor_act()
      end
    elseif ev == "left" then cursor_move(-1, 0)
    elseif ev == "right" then cursor_move(1, 0)
    elseif ev == "up" then cursor_move(0, -1)
    elseif ev == "down" then cursor_move(0, 1)
    elseif ev == nil and S.mode == "nearby" and S.status ~= "" then
      draw_board() -- retransmit state visible on the e-ink panel
    end
  end
end

-- ---------------------------------------------------------------- menu
local function menu_rows()
  local rows = {}
  if S.has_save then rows[#rows + 1] = "CONTINUE (ROUND " .. S.game.round .. ")" end
  rows[#rows + 1] = "NEW GAME"
  rows[#rows + 1] = "PLAY NEARBY"
  rows[#rows + 1] = "HOW TO PLAY"
  return rows
end

local function draw_menu()
  gfx.clear()
  gfx.rect(0, 0, W, 40, true)
  gfx.text(12, 9, "JAIPUR", "sans18", "bw")
  gfx.text(W - 12, 12, string.format("PLAYED %d   WON %d", S.played, S.won), "ui12", "rw")

  local rows = menu_rows()
  local y = 64
  for i, label in ipairs(rows) do
    local sel = (i - 1) == S.menu
    gfx.rounded_rect(24, y, W - 48, 42, 8, sel, sel)
    gfx.text(W // 2, y + 11, label, "ui12", sel and "cw" or "c")
    y = y + 52
  end

  -- The price list: what every good pays, best first, all of it. The numbers
  -- come out of the rules table so the menu cannot disagree with the board.
  local py = y + 6
  gfx.text(24, py, "WHAT EACH GOOD PAYS, BEST FIRST", "small")
  py = py + 22
  local deepest = 9
  local cell = (W - 120) // deepest
  for gg = 0, 5 do
    gfx.text(24, py, core.SHORT[gg + 1], "ui12")
    for i = 1, core.PILE_DEPTH[gg + 1] do
      gfx.text(84 + (i - 1) * cell, py, tostring(core.TOKENS[gg + 1][i]), "ui12", "c")
    end
    py = py + 30
  end

  gfx.text(W // 2, H - 30, "Up/Down choose   OK open   Back exit", "small", "c")
  gfx.present()
end

start_solo = function()
  S.mode = "solo"
  S.seat = 0
  S.report = ""
  S.status = ""
  S.recorded = false
  S.ai_rng = { v = new_seed() }
  S.game = core.game_new()
  core.new_game(S.game, new_seed(), 0)
  S.has_save = true
  clear_selection()
  S.cur_row, S.cur_col = 0, 0
  refresh_capsule()
end

local function start_nearby()
  local ok, err = link.start()
  if not ok then
    S.status = "espnow: " .. tostring(err)
    draw_menu()
    return false
  end
  local pick = input.text("Role: host deals first, join follows", "host", 6) or "host"
  S.lk.role = pick == "join" and "join" or "host"
  S.seat = S.lk.role == "join" and 1 or 0
  S.mode = "nearby"
  S.report = ""
  S.status = "waiting for the other device..."
  link.new_match(S.lk, S.seat)
  S.game = core.game_new()
  if S.seat == 0 then
    core.new_game(S.game, new_seed(), 0)
    link.send_state(S.game, S.lk)
    S.status = "sent the opening deal..."
  end
  clear_selection()
  S.cur_row, S.cur_col = 0, 0
  refresh_capsule()
  return true
end

local HELP = {
  { t = "THE GOAL",
    l = { "First trader to 2 SEALS wins the match.", "A round ends when 3 goods piles run out,", "or when the deck can't refill the market." } },
  { t = "TAKE OR SELL",
    l = { "Each turn you either TAKE cards or SELL", "cards - never both.", "You may hold at most 7 cards in hand;", "camels in your herd don't count." } },
  { t = "THREE WAYS TO TAKE",
    l = { "A: exchange 2+ market goods for the same", "number from hand or herd. Camels can be", "given, never taken; a good can't be on both", "sides.", "B: take one good; the deck refills it.", "C: take ALL market camels; each is", "replaced from the deck." } },
  { t = "HOW A SALE PAYS",
    l = { "Sell any number of ONE good. Tokens come", "off that pile's top, highest first. A pile", "that runs short pays what it has." } },
  { t = "THE BONUS",
    l = { "Sell 3+ cards and draw a bonus token -", "3, 4 or 5+ card stacks. You get the bonus", "even when the pile was short.", "DIAMOND, GOLD and SILVER must be sold", "2 at a time." } },
  { t = "CAMELS",
    l = { "Camels live in your herd: never in hand,", "never sold. Most camels at scoring takes", "the 5-rupee camel token; equal herds", "pay nobody." } },
  { t = "ROUND'S END",
    l = { "A round ends when 3 goods piles are empty", "or the deck can't refill the market - the", "move still finishes. The richer trader", "takes a Seal; 2 seals wins the match." } },
  { t = "THE SMALL PRINT",
    l = { "Trades are at least 2 for 2.", "Taking refills the market; trading doesn't.", "No card both taken and given in a trade.", "A short pile still pays its bonus.", "5+ sold draws from the 5+ stack.", "Equal herds pay nobody the camel token." } },
}

local function draw_help()
  gfx.clear()
  local page = HELP[S.help + 1]
  gfx.rect(0, 0, W, 40, true)
  gfx.text(12, 9, "HOW TO PLAY", "sans16", "bw")
  gfx.text(W - 12, 12, string.format("%d/%d", S.help + 1, #HELP), "ui12", "rw")
  local y = 64
  gfx.text(24, y, page.t, "ui12", "b")
  y = y + 30
  for _, line in ipairs(page.l) do
    gfx.text(24, y, line, "ui12")
    y = y + 26
  end
  -- Page dots
  local total = #HELP
  local dot = 8
  local span = total * dot + (total - 1) * 10
  local sx = (W - span) // 2
  for i = 1, total do
    if i - 1 == S.help then
      gfx.rounded_rect(sx + (i - 1) * (dot + 10), H - 64, dot, dot, dot // 2, true, true)
    else
      gfx.rounded_rect(sx + (i - 1) * (dot + 10), H - 64, dot, dot, dot // 2, false, true)
    end
  end
  gfx.text(W // 2, H - 40, S.help + 1 == #HELP and "OK back to menu" or "OK next page   Back menu", "small", "c")
  gfx.present()
end

local function help_loop()
  draw_help()
  while true do
    local ev = input.wait()
    if ev == "back" then return end
    if ev == "confirm" then
      if S.help + 1 < #HELP then
        S.help = S.help + 1
        draw_help()
      else
        return
      end
    end
  end
end

local function menu_loop()
  while true do
    draw_menu()
    local ev = input.wait()
    if ev == "back" then
      save_game()
      return
    end
    local rows = menu_rows()
    if ev == "up" then
      S.menu = S.menu > 0 and S.menu - 1 or 0
    elseif ev == "down" then
      if S.menu < #rows - 1 then S.menu = S.menu + 1 end
    elseif ev == "confirm" then
      local label = rows[S.menu + 1]
      if label:match("^CONTINUE") then
        if S.game.phase == core.PLAYING then
          board_loop()
        else
          round_loop()
        end
      elseif label == "NEW GAME" then
        start_solo()
        board_loop()
      elseif label == "PLAY NEARBY" then
        if start_nearby() then board_loop() end
      elseif label == "HOW TO PLAY" then
        S.help = 0
        help_loop()
      end
    end
  end
end

-- ----------------------------------------------------------------- main
local function __main()
  W, H = gfx.size()
  load_stats()
  S.has_save = load_game()
  S.deal_rng = { v = new_seed() }
  menu_loop()
end

local ok, err = pcall(__main)
if not ok then
  pcall(function() if S.mode == "nearby" then espnow.stop() end end)
  gfx.clear()
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b")
  gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()