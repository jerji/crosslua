-- YAHTZEE
-- A CrossLua port of the crossplay Yahtzee, played solo against a simple
-- opponent. The scoring core is a straight port of the C++ core
-- (YahtzeeCore.h): the Joker is THREE separate rules, and they stay separate
-- here because conflating any two of them is the bug.
--
-- Controls (no touch on this device):
--   Back        abandon the game / leave the app (menu)
--   Confirm     act on the selected item (hold a die, ROLL, take a box)
--   Left/Right  move through the dice band (five dice + the ROLL capsule)
--   Up/Down     move through the thirteen boxes
-- PLAY NEARBY (crossplay docs/apps/yahtzee.md, spec play-nearby §4.3): two devices over
-- ESP-NOW; the cards and dice travel as the 40-byte game blob (wire.lua).

local nearby = require("nearby")
local wire = require("wire")

-- ============================================================ CORE
-- Rules ported one-for-one from the C++ core. Pure: no gfx, no input.
local UNSCORED = -1
local CATS = 13
local UPPER = 6            -- Ones..Sixes are categories 0..5
local ROLLS = 3
local BONUS_AT = 63
local BONUS = 35
local FH_SCORE, SS_SCORE, LS_SCORE, YZ_SCORE, YZ_BONUS = 25, 30, 40, 50, 100
local K3K, K4K, KH, KSS, KLS, KYZ, KCH = 6, 7, 8, 9, 10, 11, 12
local NAMES = { "ONES", "TWOS", "THREES", "FOURS", "FIVES", "SIXES",
  "THREE OF A KIND", "FOUR OF A KIND", "FULL HOUSE", "SMALL STRAIGHT",
  "LARGE STRAIGHT", "YAHTZEE", "CHANCE" }

local function newCard()
  local c = {}
  for i = 1, CATS do c[i] = UNSCORED end
  c.bonuses = 0              -- Yahtzees beyond the first, each worth YZ_BONUS
  return c
end

local function countFaces(die)
  local of = { 0, 0, 0, 0, 0, 0, 0 }
  for i = 1, 5 do
    local f = die[i]
    if f >= 1 and f <= 6 then of[f] = of[f] + 1 end
  end
  return of
end

local function pipTotal(die)
  return die[1] + die[2] + die[3] + die[4] + die[5]
end

local function isYahtzee(die)
  local of = countFaces(die)
  for f = 1, 6 do if of[f] == 5 then return true end end
  return false
end

local function longestRun(of)
  local best, run = 0, 0
  for f = 1, 6 do
    run = of[f] > 0 and run + 1 or 0
    if run > best then best = run end
  end
  return best
end

-- What `die` would score in `cat`, ignoring the Joker rules. `scoreFor` below
-- is the one callers want.
local function rawScore(die, cat)
  local of = countFaces(die)
  if cat < UPPER then
    local face = cat + 1
    return of[face] * face
  end
  if cat == K3K or cat == K4K then
    local need = cat == K3K and 3 or 4
    for f = 1, 6 do if of[f] >= need then return pipTotal(die) end end
    return 0
  end
  if cat == KH then
    -- Five of a kind IS a full house: three of them and two of them.
    local three, two = false, false
    for f = 1, 6 do
      if of[f] >= 3 and not three then
        three = true
        if of[f] == 5 then two = true end
      elseif of[f] >= 2 then
        two = true
      end
    end
    return three and two and FH_SCORE or 0
  end
  if cat == KSS then return longestRun(of) >= 4 and SS_SCORE or 0 end
  if cat == KLS then return longestRun(of) >= 5 and LS_SCORE or 0 end
  if cat == KYZ then return isYahtzee(die) and YZ_SCORE or 0 end
  return pipTotal(die)       -- Chance
end

local function scored(card, cat) return card[cat + 1] ~= UNSCORED end

-- Rule (1), and only rule (1): the 100-point bonus, owed the moment a Yahtzee
-- is rolled with the box holding 50, whatever box is then chosen. A zero in
-- the Yahtzee box earns nothing. Does NOT depend on rules (2) or (3).
local function yahtzeeBonusDue(card, die)
  if not isYahtzee(die) then return false end
  if not scored(card, KYZ) then return false end
  return card[KYZ + 1] ~= 0
end

-- Whether the Joker is live at all: a Yahtzee, and the box already filled
-- with anything (50 or zero). Rules (2) and (3) hang off this.
local function jokerLive(card, die)
  return isYahtzee(die) and scored(card, KYZ)
end

local function anyLowerFree(card)
  for i = K3K + 1, CATS do if card[i] == UNSCORED then return true end end
  return false
end

-- Whether rule (3) is in force: Joker live and the matching upper box gone,
-- so a lower box must take it and the shaped ones pay in full.
local function jokerApplies(card, die)
  if not jokerLive(card, die) then return false end
  return scored(card, die[1] - 1)
end

-- Rule (2): the matching upper box, if free, is compulsory. Rule (3): the
-- lower section, while any of it is open. Only when every lower box is also
-- filled may a zero go into an upper box.
local function canScore(card, die, cat)
  if cat < 0 or cat >= CATS then return false end
  if scored(card, cat) then return false end
  if not jokerLive(card, die) then return true end
  local matching = die[1] - 1
  if not scored(card, matching) then return cat == matching end
  if anyLowerFree(card) then return cat >= UPPER end
  return true
end

-- What taking `cat` with these dice puts in the box. Under a live rule (3)
-- the straights and the full house pay in full whatever the dice show.
local function scoreFor(card, die, cat)
  if not jokerApplies(card, die) then return rawScore(die, cat) end
  if cat == KH then return FH_SCORE end
  if cat == KSS then return SS_SCORE end
  if cat == KLS then return LS_SCORE end
  return rawScore(die, cat)
end

local function upperTotal(card)
  local t = 0
  for i = 1, UPPER do if card[i] ~= UNSCORED then t = t + card[i] end end
  return t
end

local function bonusEarned(card) return upperTotal(card) >= BONUS_AT and BONUS or 0 end

local function upperStillPossible(card)
  local b = upperTotal(card)
  for i = 1, UPPER do if card[i] == UNSCORED then b = b + i * 5 end end
  return b >= BONUS_AT
end

local function upperShortfall(card)
  local t = upperTotal(card)
  return t >= BONUS_AT and 0 or BONUS_AT - t
end

local function total(card)
  local t = bonusEarned(card) + card.bonuses * YZ_BONUS
  for i = 1, CATS do if card[i] ~= UNSCORED then t = t + card[i] end end
  return t
end

local function cardFull(card)
  for i = 1, CATS do if card[i] == UNSCORED then return false end end
  return true
end

local function over(g) return cardFull(g.card[1]) and cardFull(g.card[2]) end

local function canRoll(g) return not over(g) and g.rolls < ROLLS end

-- Roll every die that is not held. The first roll of a turn ignores held:
-- holding a die from the previous turn is not a thing the game has.
local function roll(g)
  if not canRoll(g) then return false end
  local first = g.rolls == 0
  for i = 1, 5 do
    if not first and (g.held & (1 << (i - 1))) ~= 0 then
      -- kept as is
    else
      g.die[i] = crypto.random(1):byte() % 6 + 1
    end
  end
  if first then g.held = 0 end
  g.rolls = g.rolls + 1
  return true
end

local function canHold(g) return g.rolls > 0 and g.rolls < ROLLS and not over(g) end

local function toggleHold(g, idx)
  if not canHold(g) or idx < 1 or idx > 5 then return false end
  g.held = g.held ~ (1 << (idx - 1))
  return true
end

-- Take a box and hand the turn over. The Yahtzee bonus is earned by ROLLING,
-- before the box is chosen and whatever box is chosen, so it is counted here
-- via yahtzeeBonusDue, not jokerApplies.
local function take(g, cat)
  if over(g) or g.rolls == 0 then return false end
  local card = g.card[g.turn + 1]
  if not canScore(card, g.die, cat) then return false end
  if yahtzeeBonusDue(card, g.die) then card.bonuses = card.bonuses + 1 end
  card[cat + 1] = scoreFor(card, g.die, cat)
  g.held = 0
  g.rolls = 0
  g.turn = 1 - g.turn
  return true
end

-- The opponent. `aiBox` is a port of the C++ takeValue/chooseBox: score,
-- plus upper-section credit while 63 is still reachable, minus what the box
-- would usually be worth later. `aiHold` is the plain greedy -- keep the
-- commonest face -- not the C++ exact-expectation search (too heavy for this
-- heap); it is the same opponent the C++ brain beats 26-4.
local BOX_WORTH = { 2, 4, 6, 8, 10, 12, 22, 13, 22, 29, 24, 17, 22 }

local function aiValue(card, die, cat)
  local s = scoreFor(card, die, cat)
  local v = s * 10
  if cat < UPPER then
    local b = upperTotal(card)
    for i = 1, UPPER do
      if card[i] == UNSCORED and i - 1 ~= cat then b = b + i * 5 end
    end
    b = b + s
    if b >= BONUS_AT then v = v + (s * 50) // 9 end
  end
  return v - BOX_WORTH[cat + 1] * 10
end

local function aiBox(card, die)
  local best, bestV = nil, 0
  for cat = 0, CATS - 1 do
    if canScore(card, die, cat) then
      local v = aiValue(card, die, cat)
      if best == nil or v > bestV then best, bestV = cat, v end
    end
  end
  return best
end

local function aiHold(die)
  local of = countFaces(die)
  local bestF = 1
  for f = 2, 6 do if of[f] > of[bestF] then bestF = f end end
  local mask = 0
  for i = 1, 5 do if die[i] == bestF then mask = mask | (1 << (i - 1)) end end
  return mask
end

local function aiStep(g)
  if over(g) or g.turn == 0 then return end
  local card = g.card[2]
  if canRoll(g) then
    if g.rolls > 0 then g.held = aiHold(g.die) end
    roll(g)
  else
    local box = aiBox(card, g.die)
    if box == nil then
      -- Safety net: there is always a legal box after a roll, but if the
      -- valuation declined every one, take the first legal in card order
      -- rather than stall the game.
      for cat = 0, CATS - 1 do
        if canScore(card, g.die, cat) then box = cat break end
      end
    end
    if box then take(g, box) end
  end
end
-- >8 CORE END

-- ============================================================ PERSISTENCE
-- played won best yahtzees yahtzeeFace, same five values the C++ keeps.
local history = { played = 0, won = 0, best = 0, yz = 0, face = 0 }

local function loadHistory()
  local raw = fs.read("data:yahtzee.sav")
  if not raw then return end
  local a, b, c, d, e = raw:match("^(%-?%d+) (%d+) (%d+) (%d+) (%d+)")
  if not a then return end
  history.played, history.won, history.best = tonumber(a), tonumber(b), tonumber(c)
  history.yz, history.face = tonumber(d), tonumber(e)
end

local function saveHistory()
  fs.write("data:yahtzee.sav",
    string.format("%d %d %d %d %d\n", history.played, history.won, history.best,
      history.yz, history.face))
end

-- ============================================================ SCREEN
local W, H = gfx.size()
local MARGIN = 12
local DICE_TOP = 56          -- top of the dice band, under the header rule
local DIE = 52
local DGAP = 10
local BAND_LEFT = (W - (6 * DIE + 5 * DGAP)) // 2   -- five dice + the ROLL tile
local TABLE_TOP = 136        -- top of the 15-line scorecard
local LH = 36
local BOXW = 60              -- score box width
local YOU_R = 340            -- right edge of the YOU score column
local THEM_R = W - 12        -- right edge of the THEM score column

local g = nil                -- the game, set by newGame()
local cursor = { zone = "band", slot = 5, cat = 0 }
local screen = "menu"
local menuSel = 1
local howtoPage = 1
local recorded = false
local GAME_ID = 0x0801
local S = nil            -- PLAY NEARBY session, nil when playing the device
local mySeat = 0         -- seat 0 = first mover (the wire is by seat, see wire.lua)
local myAgain = false    -- I have said PLAY AGAIN this round
local linkErr = ""       -- why PLAY NEARBY would not start

local function slotX(i) return BAND_LEFT + i * (DIE + DGAP) end
local function stageOf()
  if g.rolls == 0 then return "fresh" end
  return g.rolls < ROLLS and "rolling" or "spent"
end
local function lineY(cat) return TABLE_TOP + (cat < UPPER and cat or cat + 1) * LH end

local function newGame()
  g = { card = { newCard(), newCard() }, die = { 1, 1, 1, 1, 1 },
    held = 0, rolls = 0, turn = 0 }
  cursor.zone, cursor.slot, cursor.cat = "band", 5, 0
  recorded = false
end

-- The nine pip positions of a die face, as the die is printed. Bit 8 is the
-- top-left pip; the table, not six branches.
local PIPS = { 0, 0x10, 0x101, 0x111, 0x145, 0x155, 0x16D }

local function drawDie(x, y, s, face, held, selected)
  if selected then
    gfx.rect(x, y, s, s, true)
  else
    gfx.rect(x, y, s, s, true, false)   -- white fill
    gfx.rect(x, y, s, s, false)         -- outline
  end
  if face < 1 or face > 6 then face = 1 end
  local pip = s // 6
  local xs = { x + 9, x + s // 2 - pip // 2, x + s - 9 - pip }
  local ys = { y + 9, y + s // 2 - pip // 2, y + s - 9 - pip }
  local bits = PIPS[face]
  for row = 0, 2 do
    for col = 0, 2 do
      if (bits & (1 << (8 - (row * 3 + col)))) ~= 0 then
        if selected then
          gfx.rect(xs[col + 1], ys[row + 1], pip, pip, true, false)
        else
          gfx.rect(xs[col + 1], ys[row + 1], pip, pip, true)
        end
      end
    end
  end
  -- A held die is framed OUTSIDE its own edge, with a gap so the two strokes
  -- do not merge into one thick rule.
  if held and not selected then
    local inset = 7
    gfx.rect(x - inset, y - inset, s + 2 * inset, s + 2 * inset, false)
  end
end

local function rollLabel()
  if g.turn ~= 0 then return "THEIR TURN" end
  local stage = stageOf()
  local jf = g.rolls > 0 and yahtzeeBonusDue(g.card[1], g.die)
    and not scored(g.card[1], g.die[1] - 1)
  if stage == "spent" then
    return jf and "YAHTZEE! TAKE THE MARKED BOX" or "TAKE A BOX"
  end
  if jf then return "YAHTZEE! ONE BOX ONLY" end
  local left = ROLLS - g.rolls
  return left == ROLLS and "ROLL" or ("ROLL AGAIN (" .. left .. ")")
end

local function drawRollTile()
  local x = slotX(5)
  local selected = g.turn == 0 and cursor.zone == "band" and cursor.slot == 5
  local active = g.turn == 0 and g.rolls < ROLLS and not over(g)
  local label = rollLabel()
  local ly = DICE_TOP + (DIE - gfx.line_height("ui12")) // 2
  if selected then
    gfx.rect(x, DICE_TOP, DIE, DIE, true)
    gfx.text(x + DIE // 2, ly, label, "ui12", "bwc")
  elseif active then
    gfx.rect(x, DICE_TOP, DIE, DIE, true, false)
    gfx.rect(x, DICE_TOP, DIE, DIE, false)
    gfx.text(x + DIE // 2, ly, label, "ui12", "bc")
  else
    gfx.rect(x, DICE_TOP, DIE, DIE, false)
    gfx.text(x + DIE // 2, ly, label, "ui12", "c")
  end
end

local function drawHints(caption, c1, c2, c3, c4)
  gfx.text(W // 2, H - 96, caption, "small", "c")
  gfx.line(0, H - 76, W, H - 76)
  local cw = (W - 2 * MARGIN - 3 * 8) / 4
  for i = 1, 4 do
    local x = MARGIN + (i - 1) * (cw + 8)
    gfx.rect(x, H - 68, cw, 56, false)
    local label = ({ c1, c2, c3, c4 })[i]
    gfx.text(x + cw // 2, H - 68 + (56 - gfx.line_height("ui12")) // 2, label, "ui12", "bc")
  end
end

local function drawMenu()
  gfx.clear()
  gfx.rect(0, 0, W, 44, true)
  gfx.text(16, 10, "YAHTZEE", "sans18", "bw")
  gfx.line(0, 46, W, 46)
  gfx.text(MARGIN, 62, string.format("%d PLAYED   %d WON", history.played, history.won), "small")
  gfx.line(MARGIN, 62 + gfx.line_height("small") + 8, W - MARGIN, 62 + gfx.line_height("small") + 8)
  for i = 1, 3 do
    local y = 96 + (i - 1) * 52
    local label = ({ "PLAY", "PLAY NEARBY", "HOW TO PLAY" })[i]
    if menuSel == i then gfx.rect(MARGIN, y, W - 2 * MARGIN, 44, true) end
    gfx.text(28, y + 10, label, "ui12", menuSel == i and "bw" or "b")
  end
  gfx.text(MARGIN, 250, "PERSONAL BEST", "small")
  gfx.text(MARGIN, 268, tostring(history.best), "sans18", "b")
  if history.yz > 0 and history.face >= 1 and history.face <= 6 then
    local hs = 40
    local lx = (W - (5 * hs + 4 * 8)) // 2
    local ty = 330
    for i = 1, 5 do drawDie(lx + (i - 1) * (hs + 8), ty, hs, history.face, false, false) end
    gfx.text(W // 2, ty + hs + 10, history.yz .. " YAHTZEES ROLLED", "small", "c")
  end
  drawHints("UP/DOWN: MOVE   CONFIRM: SELECT", "Exit", "Select", "", "")
  if linkErr ~= "" then gfx.text(MARGIN, H - 130, linkErr, "small") end
  gfx.present()
end

local HOWTO = {
  { lines = { "ROLL FIVE DICE. KEEP THE ONES YOU", "WANT AND ROLL AGAIN, UP TO THREE", "ROLLS A TURN." },
    hand = { 5, 5, 2, 5, 3 }, held = 0x0B },
  { lines = { "THEN PUT THE HAND IN ONE BOX ON", "YOUR CARD. EVERY BOX IS USED", "EXACTLY ONCE." },
    hand = { 5, 5, 5, 5, 1 }, held = 0x0F },
  { lines = { "SIXTY-THREE IN THE TOP HALF EARNS", "THIRTY-FIVE MORE.", "THIRTEEN TURNS EACH." },
    hand = { 4, 4, 4, 4, 4 }, held = 0x1F },
  { lines = { "A SECOND YAHTZEE SCORES 100 MORE,", "AND MAY FORCE THE ONE MARKED BOX." } },
}

local PAY = {
  { "THREE OF A KIND", "ALL FIVE DICE" },
  { "FOUR OF A KIND", "ALL FIVE DICE" },
  { "FULL HOUSE", "25" },
  { "SMALL STRAIGHT", "30" },
  { "LARGE STRAIGHT", "40" },
  { "YAHTZEE", "50" },
  { "CHANCE", "ALL FIVE DICE" },
}

local function drawHowTo()
  gfx.clear()
  gfx.rect(0, 0, W, 44, true)
  gfx.text(16, 10, "HOW TO PLAY", "sans18", "bw")
  gfx.text(W - 16, 10, howtoPage .. " OF 4", "ui12", "bwr")
  gfx.line(0, 46, W, 46)
  local page = HOWTO[howtoPage]
  local y = 66
  for _, ln in ipairs(page.lines) do
    gfx.text(W // 2, y, ln, "ui12", "c")
    y = y + 24
  end
  if page.hand then
    local hs = 44
    local lx = (W - (5 * hs + 4 * 8)) // 2
    local ty = y + 8
    for i = 1, 5 do
      drawDie(lx + (i - 1) * (hs + 8), ty, hs, page.hand[i],
        (page.held & (1 << (i - 1))) ~= 0, false)
    end
  else
    local py = y + 10
    for i, row in ipairs(PAY) do
      if i > 1 then gfx.line(MARGIN, py - 2, W - MARGIN, py - 2) end
      gfx.text(MARGIN, py, row[1], "ui12")
      gfx.text(W - MARGIN, py, row[2], "ui12", "r")
      py = py + 26
    end
  end
  drawHints("UP/DOWN: PAGE   CONFIRM: BACK", "Menu", "", "", "")
  gfx.present()
end

local function drawCard()
  gfx.clear()
  gfx.rect(0, 0, W, 44, true)
  gfx.text(16, 10, "YAHTZEE", "sans18", "bw")
  gfx.line(0, 46, W, 46)

  local yourTurn = g.turn == 0
  local stage = stageOf()
  local mine, theirs = g.card[1], g.card[2]

  -- ---- the dice band. Before the first roll of a turn the dice on screen
  -- belong to the previous turn and mean nothing, so they are not drawn.
  if stage == "fresh" then
    gfx.text(W // 2, DICE_TOP + DIE // 2 - gfx.line_height("ui12") // 2,
      yourTurn and "ROLL TO START YOUR TURN" or "THEY ARE ROLLING", "ui12", "bc")
  else
    for i = 1, 5 do
      local sel = yourTurn and cursor.zone == "band" and cursor.slot == i - 1
      drawDie(slotX(i - 1), DICE_TOP, DIE, g.die[i],
        (g.held & (1 << (i - 1))) ~= 0, sel)
    end
  end
  drawRollTile()

  -- ---- column headers
  gfx.text(YOU_R, TABLE_TOP - 20, "YOU", "small", "r")
  gfx.text(THEM_R, TABLE_TOP - 20, "THEM", "small", "r")

  -- ---- the fifteen-line card: 13 categories, the bonus, the total
  local lh = gfx.line_height("small")
  for cat = 0, CATS - 1 do
    local y = lineY(cat)
    local on = yourTurn and cursor.zone == "card" and cursor.cat == cat
    if on then gfx.rect(MARGIN, y, 200, LH, true) end
    gfx.text(MARGIN + 8, y + (LH - lh) // 2, NAMES[cat + 1], "small",
      on and "bw" or "b")

    local takeable = yourTurn and g.rolls > 0 and canScore(mine, g.die, cat)
    if mine[cat + 1] ~= UNSCORED then
      gfx.text(YOU_R - 8, y + (LH - lh) // 2, tostring(mine[cat + 1]), "small", "r")
    elseif takeable then
      -- The preview is the game: what this box would take, drawn inside the
      -- printed box. Committed numbers have no box, so the two never look
      -- alike, and a zero is a real score.
      gfx.rect(YOU_R - BOXW, y + 4, BOXW, LH - 8, false)
      gfx.text(YOU_R - 8, y + (LH - lh) // 2, tostring(scoreFor(mine, g.die, cat)), "small", "r")
    else
      gfx.rect(YOU_R - BOXW, y + 4, BOXW, LH - 8, false)
    end

    if theirs[cat + 1] ~= UNSCORED then
      gfx.text(THEM_R - 8, y + (LH - lh) // 2, tostring(theirs[cat + 1]), "small", "r")
    else
      gfx.rect(THEM_R - BOXW, y + 4, BOXW, LH - 8, false)
    end
  end

  -- ---- the bonus line does the arithmetic
  local by = TABLE_TOP + UPPER * LH
  gfx.line(MARGIN, by, W - MARGIN, by)
  gfx.text(MARGIN + 8, by + 6, "BONUS", "small", "b")
  for col = 1, 2 do
    local card = col == 1 and mine or theirs
    local right = col == 1 and YOU_R or THEM_R
    local cell
    if bonusEarned(card) > 0 then
      cell = "+" .. BONUS
    elseif upperStillPossible(card) then
      cell = upperShortfall(card) .. " MORE"
    else
      cell = "GONE"
    end
    gfx.text(right - 8, by + 6, cell, "small", "r")
  end

  -- ---- the Yahtzee bonus, on the Yahtzee row, when there is one
  if mine.bonuses > 0 or theirs.bonuses > 0 then
    gfx.text(YOU_R - BOXW - 12, lineY(KYZ) + (LH - lh) // 2,
      "+" .. (mine.bonuses + theirs.bonuses) * YZ_BONUS, "small", "r")
  end

  -- ---- the total, under a rule, in the heavier face
  local ty = TABLE_TOP + (CATS + 1) * LH
  gfx.rect(MARGIN, ty, W - 2 * MARGIN, 3, true)
  gfx.text(MARGIN + 8, ty + 8, "TOTAL", "ui12", "b")
  gfx.text(YOU_R - 8, ty + 8, tostring(total(mine)), "ui12", "br")
  gfx.text(THEM_R - 8, ty + 8, tostring(total(theirs)), "ui12", "br")

  -- ---- hint bar with the live action label
  if yourTurn then
    local act = ""
    if cursor.zone == "band" then
      if cursor.slot == 5 then
        act = g.rolls < ROLLS and "Roll" or ""
      else
        act = canHold(g) and ((g.held & (1 << cursor.slot)) ~= 0 and "Release" or "Hold") or ""
      end
    else
      act = g.rolls > 0 and canScore(mine, g.die, cursor.cat) and "Take" or ""
    end
    drawHints("UP/DOWN: CARD   LEFT/RIGHT: DICE", "Menu", act, "<", ">")
  else
    drawHints("THEIR TURN", "Menu", "Step", "", "")
  end
  gfx.present()
end

local function drawResult()
  gfx.clear()
  local mine, theirs = g.card[1], g.card[2]
  local m, t = total(mine), total(theirs)
  local title = m == t and "A TIE" or (m > t and "YOU WIN" or "THEY WIN")
  gfx.rect(0, 0, W, 44, true)
  gfx.text(16, 10, title, "sans18", "bw")
  gfx.line(0, 46, W, 46)
  gfx.text(W // 2, 96, string.format("%d - %d", m, t), "sans18", "bc")
  gfx.text(MARGIN, 150, "BIGGEST SWINGS", "small")
  local used = {}
  local y = 178
  for shown = 1, 3 do
    local bi, bg = nil, 0
    for i = 1, CATS do
      if not used[i] then
        local sz = math.abs(mine[i] - theirs[i])
        if bi == nil or sz > bg then bi, bg = i, sz end
      end
    end
    if bi == nil or bg == 0 then break end
    used[bi] = true
    gfx.text(MARGIN + 8, y, NAMES[bi], "small", "b")
    gfx.text(W - MARGIN, y, string.format("%d - %d", mine[bi], theirs[bi]), "small", "r")
    y = y + LH
  end
  if bonusEarned(mine) ~= bonusEarned(theirs) then
    gfx.text(MARGIN + 8, y, "TOP HALF BONUS", "small", "b")
    gfx.text(W - MARGIN, y,
      string.format("%d - %d", bonusEarned(mine), bonusEarned(theirs)), "small", "r")
  end
  local caption = "CONFIRM: PLAY AGAIN"
  if S then caption = myAgain and "WAITING FOR THEM TO SAY PLAY AGAIN" or "CONFIRM: PLAY AGAIN" end
  drawHints(caption, "Menu", "Again", "", "")
  gfx.present()
end

-- ============================================================ RECORD
local function rememberYahtzee()
  local d = g.die
  if d[1] == d[2] and d[2] == d[3] and d[3] == d[4] and d[4] == d[5] then
    history.face = d[1]
  end
end

local function recordResult()
  if recorded then return end
  recorded = true
  local mine, theirs = g.card[1], g.card[2]
  local m, t = total(mine), total(theirs)
  history.played = history.played + 1
  if m > t then history.won = history.won + 1 end
  if m > history.best then history.best = m end
  if mine[KYZ + 1] == YZ_SCORE then history.yz = history.yz + 1 end
  history.yz = history.yz + mine.bonuses
  saveHistory()
end

-- ============================================================ PLAY NEARBY
-- The link (nearby.lua) carries the whole state after every change of mine: roll, hold,
-- or box. My card is g.card[1] and g.turn 0 is my turn; the wire is by seat, so both
-- sides map through mySeat (seat 0 is the first mover, and it flips each round).

local function drawLinkWait()
  gfx.clear()
  gfx.rect(0, 0, W, 44, true)
  gfx.text(16, 10, "YAHTZEE  PLAY NEARBY", "sans18", "bw")
  gfx.line(0, 46, W, 46)
  gfx.text(W // 2, 300, "LOOKING FOR A PLAYER", "sans18", "c")
  gfx.text(W // 2, 344, "Turn on PLAY NEARBY on the other device.", "small", "c")
  drawHints("WAITING FOR A PARTNER", "Cancel", "", "", "")
  gfx.present()
end

local function drawLinkEnd()
  gfx.clear()
  gfx.rect(0, 0, W, 44, true)
  gfx.text(16, 10, "YAHTZEE  PLAY NEARBY", "sans18", "bw")
  gfx.line(0, 46, W, 46)
  gfx.text(W // 2, 300, (S and S.reason == "lost") and "LOST CONNECTION" or "THEY LEFT", "sans18", "c")
  drawHints("THE MATCH IS OVER", "Menu", "", "", "")
  gfx.present()
end

local function seatCards()
  if mySeat == 0 then return { [0] = g.card[1], [1] = g.card[2] } end
  return { [0] = g.card[2], [1] = g.card[1] }
end

local function sendLink()
  local turnSeat = (g.turn == 0) and mySeat or (1 - mySeat)
  S:sendState(system.millis(), wire.pack(seatCards(), g.die, g.held, g.rolls, turnSeat))
end

local function applyBlob(cards, die, held, rolls, turnSeat)
  g.card = { cards[mySeat], cards[1 - mySeat] }
  g.die, g.held, g.rolls = die, held, rolls
  g.turn = (turnSeat == mySeat) and 0 or 1
end

local function leaveLink()
  if S then S:stop(system.millis()) end
  S = nil
  myAgain = false
  screen = "menu"
  drawMenu()
end

local function startLink()
  S = nearby.new(GAME_ID, "PUP " .. string.sub(system.mac(), 16, 17))
  local ok, err = S:start()
  if not ok then
    S = nil
    linkErr = "RADIO WILL NOT START: " .. tostring(err):sub(1, 30)
    drawMenu()
    return
  end
  linkErr = ""
  screen = "linkwait"
  drawLinkWait()
end

-- a fresh match or round; seat 0 opens. The caller redraws.
local function beginMatch()
  mySeat = S.iFirst and 0 or 1
  newGame()
  g.turn = (mySeat == 0) and 0 or 1
  myAgain = false
  screen = "card"
end

local function startRound()
  S.iFirst = not S.iFirst
  S:newRound()
  beginMatch()
end

local function redraw()
  if screen == "menu" then drawMenu()
  elseif screen == "card" then drawCard()
  elseif screen == "result" then drawResult()
  elseif screen == "linkwait" then drawLinkWait()
  elseif screen == "linkend" then drawLinkEnd()
  end
end

-- Every pass: pump the radio, apply a match, the peer's state, a rematch, a peer
-- leaving. Redraws only when something changed.
local function pollLink()
  if not S then return end
  local now = system.millis()
  S:pump(now)
  S:tick(now)
  local dirty = false
  if S:takeMatch() then
    beginMatch()
    dirty = true
  end
  local blob = S:takeState()
  if blob then
    local cards, die, held, rolls, turnSeat = wire.unpack(blob)
    if cards then
      -- a state while I am on the result screen can only open round two (the peer
      -- started it, which needs my PLAY AGAIN note)
      if screen == "result" then startRound() end
      applyBlob(cards, die, held, rolls, turnSeat)
      if over(g) then
        if not recorded then recordResult() end
        screen = "result"
      else
        screen = "card"
      end
      dirty = true
    end
  end
  if screen == "result" and myAgain and S.peerAgain then
    startRound()
    dirty = true
  end
  if S.phase == "ended" and screen ~= "linkend" then
    screen = "linkend"
    dirty = true
  end
  if dirty then redraw() end
end

-- My turn on the card: the same keys as the device game, and every change goes over the air.
local function linkCardKey(ev)
  if g.turn ~= 0 or over(g) then return end
  if g.rolls == 0 then cursor.zone, cursor.slot = "band", 5 end
  local stage = stageOf()
  if ev == "up" or ev == "down" then
    if stage ~= "fresh" then
      if cursor.zone == "band" then
        cursor.zone = "card"
        cursor.cat = 0
      else
        cursor.cat = (cursor.cat + (ev == "up" and -1 or 1) + CATS) % CATS
      end
      drawCard()
    end
  elseif ev == "left" or ev == "right" then
    if cursor.zone == "card" then
      cursor.zone = "band"
      drawCard()
    elseif stage ~= "fresh" then
      cursor.slot = (cursor.slot + (ev == "left" and -1 or 1) + 6) % 6
      drawCard()
    end
  elseif ev == "confirm" then
    local acted = false
    if cursor.zone == "band" then
      if cursor.slot < 5 then
        acted = toggleHold(g, cursor.slot + 1)
      elseif g.rolls < ROLLS then
        acted = roll(g)
      end
    else
      if take(g, cursor.cat) then
        rememberYahtzee()
        acted = true
      end
    end
    if acted then
      cursor.zone, cursor.slot = "band", 5
      sendLink()
      if over(g) then
        recordResult()
        screen = "result"
        drawResult()
      else
        drawCard()
      end
    end
  end
end

-- Result screen in a match: confirm asks for another game (both must), back leaves.
local function linkResultKey(ev)
  if ev == "confirm" then
    if not myAgain then
      myAgain = true
      S:say(system.millis(), nearby.NOTE_PLAY_AGAIN)
      if S.peerAgain then startRound() end
      redraw()
    end
  elseif ev == "back" then
    leaveLink()
  end
end

-- ============================================================ MAIN
local function __main()
  loadHistory()
  newGame()
  drawMenu()
  while true do
    pollLink()
    -- while linked, wake every 100 ms so the radio keeps moving; "none" = a quiet tick
    local ev
    if S then ev = input.wait(100) else ev = input.wait() end
    ev = ev or "none"
    if screen == "menu" then
      if ev == "up" then
        menuSel = (menuSel - 2) % 3 + 1
        drawMenu()
      elseif ev == "down" then
        menuSel = menuSel % 3 + 1
        drawMenu()
      elseif ev == "confirm" then
        if menuSel == 1 then
          newGame()
          screen = "card"
          drawCard()
        elseif menuSel == 2 then
          startLink()
        else
          howtoPage = 1
          screen = "howto"
          drawHowTo()
        end
      elseif ev == "back" then
        app.exit()
        return
      end
    elseif screen == "howto" then
      if ev == "up" then
        howtoPage = howtoPage == 1 and 4 or howtoPage - 1
        drawHowTo()
      elseif ev == "down" then
        howtoPage = howtoPage % 4 + 1
        drawHowTo()
      elseif ev == "confirm" or ev == "back" then
        screen = "menu"
        drawMenu()
      end
    elseif screen == "card" then
      if ev == "back" then
        if S then
          leaveLink()
        else
          screen = "menu"
          drawMenu()
        end
      elseif screen == "card" and S then
        linkCardKey(ev)
      elseif g.turn == 1 and not over(g) then
        -- The opponent moves one step per key press, so its turn is watchable.
        aiStep(g)
        if over(g) then
          recordResult()
          screen = "result"
          drawResult()
        else
          drawCard()
        end
      elseif over(g) then
        recordResult()
        screen = "result"
        drawResult()
      else
        -- ---- the human's turn
        if g.rolls == 0 then cursor.zone, cursor.slot = "band", 5 end
        local stage = stageOf()
        if ev == "up" or ev == "down" then
          if stage ~= "fresh" then
            if cursor.zone == "band" then
              cursor.zone = "card"
              cursor.cat = 0
            else
              cursor.cat = (cursor.cat + (ev == "up" and -1 or 1) + CATS) % CATS
            end
            drawCard()
          end
        elseif ev == "left" or ev == "right" then
          if cursor.zone == "card" then
            cursor.zone = "band"
            drawCard()
          elseif stage ~= "fresh" then
            cursor.slot = (cursor.slot + (ev == "left" and -1 or 1) + 6) % 6
            drawCard()
          end
        elseif ev == "confirm" then
          local acted = false
          if cursor.zone == "band" then
            if cursor.slot < 5 then
              if toggleHold(g, cursor.slot + 1) then acted = true end
            elseif g.rolls < ROLLS then
              if roll(g) then acted = true end
            end
          else
            if take(g, cursor.cat) then
              rememberYahtzee()
              acted = true
            end
          end
          if acted then
            cursor.zone, cursor.slot = "band", 5
            if over(g) then
              recordResult()
              screen = "result"
              drawResult()
            else
              drawCard()
            end
          end
        end
      end
    elseif screen == "linkwait" then
      if ev == "back" then leaveLink() end
    elseif screen == "linkend" then
      if ev == "confirm" or ev == "back" then leaveLink() end
    elseif screen == "result" and S then
      linkResultKey(ev)
    elseif screen == "result" then
      if ev == "confirm" then
        newGame()
        screen = "card"
        drawCard()
      elseif ev == "back" then
        screen = "menu"
        drawMenu()
      end
    end
  end
end

local ok, err = pcall(__main)
if not ok then
  gfx.clear()
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b")
  gfx.present()
  while input.wait() ~= "back" do end
  app.exit()
end