-- Sea Salt & Paper for CrossLua — a solo port of the crossplay game
-- (docs/apps/seasalt.md, SeaSaltActivity.cpp, SeaSaltScreens.cpp).
--
-- Rules live in game.lua (the core) and the opponent in brain.lua; this
-- file is only the chrome: three screens plus the board, driven by the
-- seven buttons (there is no touch on the X4, so the C++ touch tabs become
-- a flat cursor over one grid that always holds the pending decision).
--
--   Up/Down/Left/Right   move the cursor
--   Confirm              keep a drawn card, take a pile card, select a card
--                        of your hand, play a pair, or fire the focused pill
--   Back                 board -> menu, menu -> exit
--
-- The player's seat is always 0 and the AI (Navigator) is seat 1, exactly
-- like the C++ solo game. No network, no permissions: this is a local game.
--
-- Settled rules this implements (from the doc): mermaids stay in hand and
-- four of them win the match the moment the fourth arrives, by any route;
-- duo points count played or not; "your cards" is hand plus table; LAST
-- CHANCE pays the colour bonus one way or the other; a deck-out scores
-- nobody; the AI remembers both discard piles but never sees the deck or
-- your unrevealed hand.

local game = require("game")
-- The Navigator and the PLAY NEARBY modules load on first use: a radio session
-- needs most of the device's Lua heap, so a solo game does not carry them.
local brain, nearby, wire, linkturn
local function loadBrain()
  brain = brain or require("brain")
  return brain
end
local GAME_ID = 0x0901  -- SeaSalt in crossplay's GameId registry (LinkPlay.h)

local W, H = gfx.size()
local COLS, CELLW, CARDH = 6, 80, 88
local GRID_Y = 140
local HINT_H = 62
local presents = 0
local function present()
  presents = presents + 1
  gfx.present(presents % 8 == 0 and "half" or "fast")
end

local NAMES = { "CRAB", "BOAT", "FISH", "SWIMMER", "SHARK", "SHELL", "OCTOPUS",
  "PENGUIN", "SAILOR", "MERMAID", "LIGHTHOUSE", "SHOAL", "COLONY", "CAPTAIN" }

local HINTS = {
  "PAIRS WITH ANOTHER CRAB. THE PAIR DIGS ANY CARD OUT OF A PILE.",
  "PAIRS WITH ANOTHER BOAT. THE PAIR BUYS ANOTHER TURN.",
  "PAIRS WITH ANOTHER FISH. THE PAIR DRAWS A CARD.",
  "PAIRS WITH A SHARK. THE PAIR STEALS FROM THEIR HAND.",
  "PAIRS WITH A SWIMMER. THE PAIR STEALS FROM THEIR HAND.",
  "WORTH 0-2-4-6-8-10 AS YOU COLLECT 1 TO 6.",
  "WORTH 0-3-6-9-12 AS YOU COLLECT 1 TO 5.",
  "WORTH 1-3-5 AS YOU COLLECT 1 TO 3.",
  "TWO SAILORS ARE 5. THE CAPTAIN PAYS 3 EACH.",
  "SCORES YOUR BIGGEST COLOUR. HOLD ALL FOUR AND YOU WIN.",
  "1 POINT PER BOAT YOU HOLD.",
  "1 POINT PER FISH YOU HOLD.",
  "2 POINTS PER PENGUIN YOU HOLD.",
  "3 POINTS PER SAILOR YOU HOLD.",
}
local PAIR_HINTS = {
  "TWO CRABS. PLAY THEM TO DIG THROUGH A PILE.",
  "TWO BOATS. PLAYING THEM BUYS ANOTHER TURN.",
  "TWO FISH. PLAY THEM TO DRAW A CARD.",
  "SWIMMER AND SHARK. PLAY THEM TO STEAL A CARD.",
}

-- ------------------------------------------------------------------ state

local g
local screen = "menu"        -- menu | board | call | roundover | howto
local cur = 1                -- cursor over the item grid (board)
local sel = {}               -- up to two selected hand cards (ids)
local report = ""            -- narration of the last AI turn
local seed = 1
local has_save = false
local stats_counted = false
local played, won = 0, 0
local menu_sel, how_page, call_sel, ro_sel = 1, 1, 1, 1

-- PLAY NEARBY. `link` is nil when solo. Inside a match the local game always
-- has me as seat 0; `flip` maps the blob (first mover = seat 0) onto that.
-- `transport` = I hold the transport turn (may send); `again` = I said PLAY AGAIN.
local link = nil
local soloGame = nil  -- the solo game, kept aside while linked
local linkedPlay      -- defined with the PLAY NEARBY section; routeMenu calls it

local function myTurn() return g.turn == 0 and (link == nil or link.transport) end

-- ------------------------------------------------------------ persistence

local function loadStats()
  local raw = fs.read("data:seasalt.stats")
  if not raw then return end
  local ok, st = pcall(json.decode, raw)
  if ok and type(st) == "table" and type(st.played) == "number" and type(st.won) == "number" then
    played, won = st.played, st.won
  end
end

local function saveStats()
  local s = json.encode({ played = played, won = won })
  if s then fs.write("data:seasalt.stats", s) end
end

local function saveGame()
  if link then return end  -- a linked match never overwrites the solo save
  if not has_save or g.phase == game.PHASE.GAMEOVER then
    if fs.exists("data:seasalt.sav") then fs.remove("data:seasalt.sav") end
    return
  end
  local s = json.encode({
    v = 1, seed = g.seed, score = g.score, round = g.round,
    place = g.place, seq = g.seq, seqNext = g.seqNext, deckNext = g.deckNext,
    turn = g.turn, roundStarter = g.roundStarter, phase = g.phase, step = g.step,
    ender = g.ender, bet = g.bet, owed = g.owed,
    drawn = g.drawn, pending = g.pending, crabPile = g.crabPile,
    revealed = g.revealed, extraTurns = g.extraTurns,
  })
  if s then fs.write("data:seasalt.sav", s) end
end

-- A save that breaks conservation came from another build: every card must
-- be in a real place, and the deck must match the deal cursor.
local function loadGame()
  local raw = fs.read("data:seasalt.sav")
  if not raw then return false end
  local ok, st = pcall(json.decode, raw)
  if not ok or type(st) ~= "table" or st.v ~= 1 then return false end
  if type(st.place) ~= "table" or #st.place ~= game.CARDS then return false end
  if type(st.seq) ~= "table" or #st.seq ~= game.CARDS then return false end
  if type(st.phase) ~= "number" or st.phase < 0 or st.phase > game.PHASE.GAMEOVER then return false end
  if type(st.step) ~= "number" or st.step < 0 or st.step > game.STEP.CRABPICK then return false end
  local deck = 0
  for c = 1, game.CARDS do
    if type(st.place[c]) ~= "number" or st.place[c] < 0 or st.place[c] > game.PLACE.DRAWN then return false end
    if st.place[c] == game.PLACE.DECK then deck = deck + 1 end
  end
  if deck ~= game.CARDS - st.deckNext then return false end
  g = game.newGame(1)
  g.seed, g.round = st.seed, st.round
  g.score[1], g.score[2] = st.score[1], st.score[2]
  for c = 1, game.CARDS do g.place[c] = st.place[c]; g.seq[c] = st.seq[c] end
  g.seqNext, g.deckNext = st.seqNext, st.deckNext
  g.turn, g.roundStarter = st.turn, st.roundStarter
  g.phase, g.step = st.phase, st.step
  g.ender, g.bet, g.owed = st.ender, st.bet, st.owed
  g.drawn[1], g.drawn[2] = st.drawn[1], st.drawn[2]
  g.pending, g.crabPile = st.pending, st.crabPile
  g.revealed, g.extraTurns = st.revealed, st.extraTurns
  return true
end

local function nextSeed()
  seed = (seed * 1664525 + 1013904223 + system.millis()) & 0x7FFFFFFF
  return seed | 1
end

-- ---------------------------------------------------------------- drawing

local function header(title, right)
  gfx.rect(0, 0, W, 44, true, true)
  gfx.text(14, 12, title, "ui", "bw")
  if right then gfx.text(W - 14, 12, right, "ui12", "bwr") end
  gfx.line(0, 44, W, 44)
end

local function wrap(s, maxw)
  local out, line = {}, ""
  for word in s:gmatch("%S+") do
    local probe = line == "" and word or (line .. " " .. word)
    if gfx.text_width(probe, "small") > maxw and line ~= "" then
      out[#out + 1] = line
      line = word
    else
      line = probe
    end
  end
  if line ~= "" then out[#out + 1] = line end
  return out
end

-- dashed border for the hint box, same rhythm as the C++ (6 on, 4 off)
local function dashedBox(x, y, w, h)
  local function dash(ax, ay, bx, by)
    local len = math.max(math.abs(bx - ax), math.abs(by - ay))
    local step = 10
    local i = 0
    while i < len do
      local seg = math.min(6, len - i)
      if ax == bx then gfx.line(ax, ay + i, ax, ay + i + seg)
      else gfx.line(ax + i, ay, ax + i + seg, ay) end
      i = i + step
    end
  end
  dash(x, y, x + w, y)
  dash(x, y + h, x + w, y + h)
  dash(x, y, x, y + h)
  dash(x + w, y, x + w, y + h)
end

local function tableList(seat, handToo)
  local parts = {}
  for k = 0, 13 do
    local n = handToo and game.countHeld(g, seat, k) or 0
    if n > 0 then parts[#parts + 1] = NAMES[k + 1] .. " X" .. n end
  end
  if #parts == 0 then return "-" end
  return table.concat(parts, "  ")
end

local function facts()
  -- line 1: deck and piles
  local l1 = "DECK " .. game.deckRemaining(g)
  for p = 0, 1 do
    local top = game.pileTop(g, p)
    if top == game.NO_CARD then
      l1 = l1 .. "   " .. (p == 0 and "A" or "B") .. " --"
    else
      l1 = l1 .. "   " .. (p == 0 and "A" or "B") .. " " .. NAMES[game.kindOf(top) + 1] .. " X" .. game.pileSize(g, p)
    end
  end
  gfx.text(14, 52, l1, "small", "b")
  -- line 2: mermaids, biggest colour, your points
  local best, bestAt = 0, 0
  for i = 1, #game.COLOURS do
    local n = game.countHeldColour(g, 0, i - 1)
    if n > best then best, bestAt = n, i - 1 end
  end
  local l2 = "MERMAIDS " .. game.mermaidsHeld(g, 0) .. "/4   TOP " .. game.COLOUR_MARKS[bestAt + 1] .. " " .. best
  l2 = l2 .. "   YOU " .. game.cardPoints(g, 0) .. " PTS"
  gfx.text(14, 70, l2, "small", "b")
  -- lines 3-4: tables
  gfx.text(14, 88, "YOURS: " .. tableList(0, false), "small")
  if (g.revealed >> 1) & 1 == 1 then
    gfx.text(14, 106, "THEIRS: " .. tableList(1, true), "small")
  else
    gfx.text(14, 106, "THEIRS: " .. tableList(1, false) .. "  (HAND " .. game.handSize(g, 1) .. ")", "small")
  end
end

local function ruleLine()
  local st = g.step
  if link and not myTurn() then
    gfx.text(W // 2, 126, "THEIR TURN. THE BOARD MOVES WHEN THEY DO.", "small", "bc")
    return
  end
  if report ~= "" and g.turn == 0 then
    gfx.text(W // 2, 126, report, "small", "bc")
    return
  end
  if st == game.STEP.TAKE then
    if game.canTake(g) then
      gfx.text(W // 2, 126, "TAKE A CARD. DECK DEALS TWO, PILES SHOW WHAT YOU GET.", "small", "bc")
    else
      gfx.text(W // 2, 126, "NOTHING LEFT TO TAKE. END YOUR TURN.", "small", "bc")
    end
  elseif st == game.STEP.CHOOSEKEEP then
    gfx.text(W // 2, 126, "TWO FROM THE DECK. KEEP ONE.", "small", "bc")
  elseif st == game.STEP.CHOOSEPILE then
    gfx.text(W // 2, 126, "THE " .. NAMES[game.kindOf(g.pending) + 1] .. " GOES FACE UP. CHOOSE A PILE.", "small", "bc")
  elseif st == game.STEP.CRABPILE then
    gfx.text(W // 2, 126, "THE CRABS DIG. CHOOSE A PILE TO SEARCH.", "small", "bc")
  elseif st == game.STEP.CRABPICK then
    gfx.text(W // 2, 126, "TAKE ANY ONE CARD FROM THIS PILE.", "small", "bc")
  else
    gfx.text(W // 2, 126, "CHOOSE A PAIR TO PLAY, OR END THE TURN.", "small", "bc")
  end
end

-- ------------------------------------------------------- board item list

local function buildItems()
  local items = {}
  local st = g.step
  if st == game.STEP.CHOOSEKEEP then
    for i = 1, 2 do
      if g.drawn[i] ~= game.NO_CARD then items[#items + 1] = { t = "drawn", i = i } end
    end
  elseif st == game.STEP.CHOOSEPILE then
    items[#items + 1] = { t = "info", card = g.pending }
    items[#items + 1] = { t = "pile", pile = 0 }
    items[#items + 1] = { t = "pile", pile = 1 }
  elseif st == game.STEP.CRABPICK then
    local where = game.PLACE.PILEA + g.crabPile
    for c = 1, game.CARDS do
      if g.place[c] == where then items[#items + 1] = { t = "card", card = c } end
    end
  elseif st == game.STEP.CRABPILE then
    items[#items + 1] = { t = "pile", pile = 0 }
    items[#items + 1] = { t = "pile", pile = 1 }
  else
    -- TAKE or PLAY: the grid is the hand
    for c = 1, game.CARDS do
      if g.place[c] == game.PLACE.HAND0 then items[#items + 1] = { t = "card", card = c } end
    end
    if myTurn() then
      if st == game.STEP.TAKE then
        if game.canTake(g) then
          items[#items + 1] = { t = "pill", act = "deck", label = "DRAW DECK" }
          for p = 0, 1 do
            if game.pileTop(g, p) ~= game.NO_CARD then
              items[#items + 1] = { t = "pill", act = "pile" .. p, label = p == 0 and "PILE A" or "PILE B" }
            end
          end
        else
          items[#items + 1] = { t = "pill", act = "endturn", label = "END TURN" }
        end
      elseif st == game.STEP.PLAY then
        if g.phase == game.PHASE.PLAYING and game.mayEndRound(g, 0) then
          items[#items + 1] = { t = "pill", act = "call", label = "CALL " .. game.cardPoints(g, 0) }
        end
        local label, doPair = "END TURN", false
        if #sel == 2 and game.isPair(sel[1], sel[2]) then label, doPair = "PLAY PAIR", true end
        items[#items + 1] = { t = "pill", act = "endturn", label = label, pair = doPair }
      end
    end
  end
  return items
end

local function drawCardTile(x, y, card, selected, label)
  local kind = game.kindOf(card)
  gfx.rect(x + 2, y + 2, CELLW - 4, CARDH - 4, true, false)
  gfx.text(x + 6, y + 6, "X" .. game.SUPPLY[kind + 1], "small", "b")
  gfx.text(x + CELLW - 6, y + 6, game.COLOUR_MARKS[game.colourOf(card) + 1], "small", "br")
  gfx.text(x + CELLW // 2, y + 36, label or NAMES[kind + 1], "ui12", "bc")
  gfx.text(x + CELLW - 6, y + 66, tostring(game.groupPoints(g, card, 0)), "ui12", "br")
  if selected then
    gfx.rect(x, y, CELLW, 3, true, true)
    gfx.rect(x, y + CARDH - 3, CELLW, 3, true, true)
    gfx.rect(x, y, 3, CARDH, true, true)
    gfx.rect(x + CELLW - 3, y, 3, CARDH, true, true)
  end
end

local function drawPileTile(x, y, pile)
  local top = game.pileTop(g, pile)
  local name, depth = "EMPTY", 0
  if top ~= game.NO_CARD then name, depth = NAMES[game.kindOf(top) + 1], game.pileSize(g, pile) end
  gfx.rect(x + 2, y + 2, CELLW - 4, CARDH - 4, true, false)
  gfx.text(x + CELLW // 2, y + 30, (pile == 0 and "PILE A" or "PILE B"), "ui12", "bc")
  gfx.text(x + CELLW // 2, y + 52, name .. " X" .. depth, "small", "bc")
end

local function drawPill(x, y, label)
  gfx.rounded_rect(x + 8, y + 24, CELLW - 16, 40, 8, true, false)
  gfx.text(x + CELLW // 2, y + 36, label, "ui12", "bc")
end

local function drawGrid(items)
  local rows = math.max(1, math.ceil(#items / COLS))
  local maxRows = (H - HINT_H - GRID_Y - 4) // CARDH
  local top = GRID_Y + math.max(0, (maxRows - rows)) * CARDH // 2
  for i, it in ipairs(items) do
    local col, row = (i - 1) % COLS, (i - 1) // COLS
    local x, y = col * CELLW, top + row * CARDH
    if it.t == "card" then
      drawCardTile(x, y, it.card, sel[1] == it.card or sel[2] == it.card, nil)
    elseif it.t == "drawn" then
      local card = g.drawn[it.i]
      gfx.rect(x + 2, y + 2, CELLW - 4, CARDH - 4, true, false)
      local kind = game.kindOf(card)
      gfx.text(x + 6, y + 6, "X" .. game.SUPPLY[kind + 1], "small", "b")
      gfx.text(x + CELLW - 6, y + 6, game.COLOUR_MARKS[game.colourOf(card) + 1], "small", "br")
      gfx.text(x + CELLW // 2, y + 36, NAMES[kind + 1], "ui12", "bc")
      gfx.text(x + CELLW // 2, y + 60, "KEEP?", "small", "bc")
      if it.i == 1 then gfx.text(x + CELLW // 2, y + 6, "1", "ui12", "bc")
      else gfx.text(x + CELLW // 2, y + 6, "2", "ui12", "bc") end
    elseif it.t == "info" then
      gfx.rect(x + 2, y + 2, CELLW - 4, CARDH - 4, true, false)
      gfx.text(x + CELLW // 2, y + 36, NAMES[game.kindOf(it.card) + 1], "ui12", "bc")
      gfx.text(x + CELLW // 2, y + 60, "PLACE IT", "small", "bc")
    elseif it.t == "pile" then
      drawPileTile(x, y, it.pile)
    elseif it.t == "pill" then
      drawPill(x, y, it.label)
    end
  end
  -- cursor
  local col, row = (cur - 1) % COLS, (cur - 1) // COLS
  local x, y = col * CELLW, top + row * CARDH
  gfx.rect(x, y, CELLW, 3, true, true)
  gfx.rect(x, y + CARDH - 3, CELLW, 3, true, true)
  gfx.rect(x, y, 3, CARDH, true, true)
  gfx.rect(x + CELLW - 3, y, 3, CARDH, true, true)
end

local function hintText()
  local st = g.step
  if link and not myTurn() then return report ~= "" and report or "THEIR TURN. WAIT FOR THEM TO FINISH." end
  if st == game.STEP.CHOOSEKEEP then return "TAP (CONFIRM) THE ONE YOU KEEP. THE OTHER GOES ON A PILE." end
  if st == game.STEP.CHOOSEPILE then return "THE REJECTED CARD IS PUBLIC. CHOOSE WHICH PILE COVERS." end
  if st == game.STEP.CRABPILE then return "CRABS DIG THROUGH A PILE WITHOUT SHUFFLING IT." end
  if st == game.STEP.CRABPICK then return "TAKE ANY ONE CARD FROM THE PILE, WITHOUT SHOWING IT." end
  if st == game.STEP.PLAY and #sel == 2 then
    if game.isPair(sel[1], sel[2]) then
      local k = game.kindOf(sel[1])
      return PAIR_HINTS[k >= 3 and 4 or k + 1]  -- swimmer and shark share one hint
    end
    return "THESE TWO DO NOT PAIR. A PAIR IS TWO ALIKE, OR SWIMMER AND SHARK."
  end
  if st == game.STEP.PLAY and #sel == 1 then return HINTS[game.kindOf(sel[1]) + 1] end
  if st == game.STEP.PLAY then
    return "A PAIR IS TWO ALIKE, OR SWIMMER AND SHARK. DUO POINTS COUNT PLAYED OR NOT."
  end
  return "KEEP YOUR EYE ON THE PILES: THE OPPONENT REMEMBERS THEM ALL."
end

local function hintBox()
  local y, h = H - HINT_H - 12, HINT_H
  dashedBox(8, y, W - 16, h)
  local lines = wrap(hintText(), W - 40)
  local n = math.min(#lines, 2)
  for i = 1, n do
    gfx.text(W // 2, y + 8 + (i - 1) * 24, lines[i], "small", "c")
  end
end

local function drawBoard()
  gfx.clear()
  header("SEA SALT", (g.phase == game.PHASE.LASTCHANCE and "LAST CHANCE  " or ("R" .. g.round .. "  ")) .. g.score[1] .. " - " .. g.score[2])
  facts()
  ruleLine()
  local items = buildItems()
  cur = math.min(cur, math.max(1, #items))
  drawGrid(items)
  hintBox()
  present()
end

-- ------------------------------------------------------------------ menu

local function menuItems()
  local items = {}
  if has_save then items[#items + 1] = { label = "CONTINUE", act = "continue" } end
  items[#items + 1] = { label = "NEW GAME", act = "new" }
  items[#items + 1] = { label = "PLAY NEARBY", act = "nearby" }
  items[#items + 1] = { label = "HOW TO PLAY", act = "how" }
  return items
end

local function drawMenu()
  gfx.clear()
  header("SEA SALT", played .. " PLAYED  " .. won .. " WON")
  gfx.text(16, 56, "THE DECK", "ui12", "b")
  gfx.line(16, 74, W - 16, 74)
  for k = 0, 13 do
    local col, row = k // 7, k % 7
    local x = 16 + col * (W // 2)
    local y = 84 + row * 26
    gfx.text(x, y, NAMES[k + 1], "small", "b")
    gfx.text(x + 150, y, "X" .. game.SUPPLY[k + 1], "small", "br")
  end
  local items = menuItems()
  menu_sel = math.min(menu_sel, #items)
  local my = 280
  for i, it in ipairs(items) do
    local y = my + (i - 1) * 56
    if i == menu_sel then gfx.rect(16, y, W - 32, 44, true, true) end
    gfx.text(36, y + 13, it.label, "ui12", i == menu_sel and "bw" or "b")
  end
  if has_save then
    gfx.text(16, my + #items * 56 + 6, "ROUND " .. g.round .. "  " .. g.score[1] .. " - " .. g.score[2], "small")
  end
  gfx.text(W // 2, H - 50, "FIRST TO 40 WINS. TIE GOES TO THE LAST TURN.", "small", "c")
  gfx.text(W // 2, H - 28, "Up/Down: move   Confirm: select   Back: exit", "small", "c")
  present()
end

-- ----------------------------------------------------------- call / rounds

local function drawCall()
  gfx.clear()
  header("CALL IT")
  gfx.text(W // 2, 110, "YOUR CARDS: " .. game.cardPoints(g, 0) .. " POINTS", "sans16", "bc")
  gfx.text(W // 2, 150, "FROM 7 POINTS YOU MAY END THE ROUND.", "small", "c")
  local opts = { { "STOP", "EVERYBODY BANKS THEIR CARDS." }, { "LAST CHANCE", "BET YOU HOLD THE MOST. THEY GET ONE MORE TURN." } }
  for i, o in ipairs(opts) do
    local y = 210 + (i - 1) * 110
    if i == call_sel then gfx.rect(24, y, W - 48, 92, true, true) end
    gfx.text(W // 2, y + 16, o[1], "sans16", i == call_sel and "bwc" or "bc")
    gfx.text(W // 2, y + 52, o[2], "ui12", i == call_sel and "bwc" or "bc")
  end
  gfx.text(W // 2, H - 40, "Back: keep playing", "small", "c")
  present()
end

local function roundOverOptions(over)
  if not link then return over and { "PLAY AGAIN", "MENU" } or { "NEXT ROUND", "MENU" } end
  if over then return { link.again and "WAITING FOR THEM" or "PLAY AGAIN", "LEAVE" } end
  return { linkturn.action(g, link.transport) == "deal" and "NEXT ROUND" or "WAITING FOR THEM", "LEAVE" }
end

local function drawRoundOver()
  gfx.clear()
  local over = g.phase == game.PHASE.GAMEOVER
  header(over and "GAME OVER" or ("ROUND " .. g.round .. " OVER"))
  local y = 84
  local function line(s, big)
    gfx.text(W // 2, y, s, big and "sans16" or "ui12", big and "bc" or "c")
    y = y + (big and 34 or 22)
  end
  local mermaidWin = game.mermaidsHeld(g, 0) == 4 or game.mermaidsHeld(g, 1) == 4
  if mermaidWin then
    line(game.mermaidsHeld(g, 0) == 4 and "FOUR MERMAIDS - YOU WIN!" or "FOUR MERMAIDS - THEY WIN!", true)
    y = y + 10
  elseif g.ender == game.NO_SEAT then
    line("THE DECK RAN OUT. NOBODY SCORES.", true)
    y = y + 10
  elseif g.bet == 0 then
    line(g.ender == 0 and "YOU CALLED STOP." or "THEY CALLED STOP.", true)
    y = y + 10
  elseif g.ender == 0 then
    line(game.betWon(g) and "LAST CHANCE - BET WON!" or "LAST CHANCE - BET LOST.", true)
    y = y + 10
  else
    line(game.betWon(g) and "THEY BET LAST CHANCE - AND WON." or "THEY BET LAST CHANCE - YOU PASSED THEM.", true)
    y = y + 10
  end
  local function side(seat, name)
    local cards, bonus = game.cardPoints(g, seat), game.colourBonus(g, seat)
    local banked = game.roundScore(g, seat)
    line(name .. ": " .. cards .. " CARDS + " .. bonus .. " BONUS = " .. banked, false)
  end
  side(0, "YOU")
  side(1, "THEM")
  gfx.line(40, y, W - 40, y)
  y = y + 12
  gfx.text(W // 2, y, "TOTALS  " .. g.score[1] .. " - " .. g.score[2], "sans16", "bc")
  y = y + 44
  if over then
    local w = game.matchWinner(g)
    gfx.text(W // 2, y, w == 0 and "YOU WIN THE MATCH" or (w == 1 and "THEY WIN THE MATCH" or "IT'S A TIE"), "sans16", "bc")
    y = y + 40
  end
  local opts = roundOverOptions(over)
  ro_sel = math.min(ro_sel, #opts)
  for i, o in ipairs(opts) do
    local yy = y + (i - 1) * 60
    if i == ro_sel then gfx.rect(24, yy, W - 48, 48, true, true) end
    gfx.text(W // 2, yy + 15, o, "ui12", i == ro_sel and "bwc" or "bc")
  end
  gfx.text(W // 2, y + 2 * 60 + 8, "Back: menu", "small", "c")
  if link and over and link.S.peerAgain and not link.again then
    gfx.text(W // 2, y + 2 * 60 + 34, "THEY WANT ANOTHER GAME", "ui12", "c")
  end
  present()
end

-- ----------------------------------------------------------------- howto

local HOWTO = {
  { "TAKE ONE CARD A TURN.",
    { "DRAW TWO FROM THE DECK AND KEEP ONE,", "OR TAKE THE TOP OF A DISCARD PILE.", "", "FIRST TO 40 POINTS WINS." } },
  { "PAIRS HAVE POWERS.",
    { "TWO BOATS: TAKE ANOTHER TURN.", "TWO FISH: DRAW A CARD.", "TWO CRABS: DIG THROUGH A PILE.", "", "PLAY A PAIR FACE UP TO FIRE ITS POWER.", "ITS POINT COUNTS PLAYED OR NOT." } },
  { "SWIMMER AND SHARK.",
    { "PLAY BOTH TOGETHER TO STEAL", "A RANDOM CARD FROM THEIR HAND.", "", "LIKE EVERY DUO, THE PAIR IS A POINT", "WHETHER PLAYED OR KEPT IN HAND." } },
  { "COLLECTORS GROW.",
    { "SHELLS PAY 0-2-4-6-8-10 AS THEY ADD UP.", "OCTOPI 0-3-6-9-12. PENGUINS 1-3-5.", "TWO SAILORS PAY 5.", "", "THE ONE-OFF CARDS MULTIPLY THEM:", "LIGHTHOUSE 1 PER BOAT. SHOAL 1 PER FISH.", "COLONY 2 PER PENGUIN. CAPTAIN 3 PER SAILOR." } },
  { "MERMAIDS COUNT COLOURS.",
    { "EACH MERMAID SCORES YOUR BIGGEST", "COLOUR GROUP, EACH A DIFFERENT ONE.", "", "HOLD ALL FOUR AND YOU WIN ON THE SPOT." } },
  { "ENDING A ROUND.",
    { "FROM 7 POINTS, ON YOUR TURN, CALL IT.", "", "STOP: EVERYBODY BANKS THEIR CARDS.", "LAST CHANCE: A BET THAT YOU HOLD THE MOST.", "THEY GET ONE MORE TURN. IF YOU STILL LEAD,", "YOU BANK CARDS PLUS YOUR COLOUR BONUS", "AND THEY BANK ONLY THEIR BONUS.", "IF THEY PASS YOU, IT IS REVERSED.", "", "IF THE DECK RUNS OUT, NOBODY SCORES." } },
}

local function drawHowTo()
  gfx.clear()
  header("HOW TO PLAY", how_page .. " OF " .. #HOWTO)
  local page = HOWTO[how_page]
  gfx.text(W // 2, 84, page[1], "sans16", "bc")
  local y = 130
  for _, ln in ipairs(page[2]) do
    if ln == "" then y = y + 12 else gfx.text(W // 2, y, ln, "ui12", "c") end
    y = y + 26
  end
  gfx.text(W // 2, H - 44, "Confirm/Right: next   Back: menu", "small", "c")
  present()
end

-- ------------------------------------------------------------------ flow

local function applyDecision(d)
  local t = d.act
  if t == "takeDeck" then return game.takeFromDeck(g) end
  if t == "takePile" then return game.takeFromPile(g, d.a) end
  if t == "keep" then return game.keepDrawn(g, d.a) end
  if t == "discardTo" then return game.discardTo(g, d.a) end
  if t == "layDuo" then
    local ka = d.kind == 3 and 3 or d.kind
    local kb = d.kind == 3 and 4 or d.kind
    local a, b = game.NO_CARD, game.NO_CARD
    for c = 1, game.CARDS do
      if g.place[c] == game.PLACE.HAND1 then
        local k = game.kindOf(c)
        if k == ka and a == game.NO_CARD then a = c
        elseif k == kb and b == game.NO_CARD and c ~= a then b = c end
      end
    end
    if a ~= game.NO_CARD and b ~= game.NO_CARD then return game.playDuo(g, a, b) end
    return false
  end
  if t == "endTurn" then return game.endTurn(g) end
  if t == "stop" then return game.endRound(g, false) end
  if t == "lastChance" then return game.endRound(g, true) end
  if t == "digPile" then return game.chooseCrabPile(g, d.a) end
  if t == "digCard" then return game.takeCrabCard(g, d.a) end
  return false
end

-- Plays every decision the Navigator owes, then narrates the headline.
local function runAI()
  report = ""
  local laid, called, bet, stole = { 0, 0, 0, 0, 0 }, false, false, false
  local guard = 0
  while g.phase ~= game.PHASE.ROUNDOVER and g.phase ~= game.PHASE.GAMEOVER and
      g.turn == 1 and guard < 200 do
    guard = guard + 1
    local d = loadBrain().decide(game.observe(g, 1), "navigator")
    local ok = applyDecision(d)
    if not ok then break end
    if d.act == "layDuo" then
      laid[d.kind + 1] = laid[d.kind + 1] + 1
      if d.kind == 3 then stole = true end
    elseif d.act == "stop" then
      called = true
    elseif d.act == "lastChance" then
      called, bet = true, true
    end
  end
  if called then
    report = bet and "THEY BET LAST CHANCE. ONE MORE TURN, MAKE IT COUNT." or "THEY CALLED STOP."
  elseif stole then
    report = "SWIMMER AND SHARK. THEY STOLE FROM YOUR HAND."
  elseif laid[2] > 0 then
    report = "THEY PLAYED BOATS FOR EXTRA TURNS. YOUR MOVE NOW."
  elseif laid[1] > 0 then
    report = "THEY PLAYED TWO CRABS AND DUG THROUGH A PILE."
  elseif laid[3] > 0 then
    report = "THEY PLAYED TWO FISH AND DREW A CARD."
  else
    report = "THEY TOOK A CARD. YOUR MOVE."
  end
end

-- Over a link, my transport turn goes on when the game turn leaves me or the
-- round does: that state is the packet. A boat pair keeps the turn, so nothing
-- is sent and I keep playing, which is the rulebook's extra turn.
local function linkSend()
  link.S:sendState(system.millis(), wire.pack(g, link.flip))
  link.transport = false
end

-- Shared exit of a successful human action: re-derive the view, and hand
-- the turn to the brain when it is theirs.
local function countMatchEnd()
  if stats_counted then return end
  stats_counted = true
  played = played + 1
  if game.matchWinner(g) == 0 then won = won + 1 end
  saveStats()
end

local function afterHumanAction()
  sel = {}
  report = ""
  local ph = g.phase
  if link then
    if g.turn ~= 0 or ph == game.PHASE.ROUNDOVER or ph == game.PHASE.GAMEOVER then linkSend() end
    if ph == game.PHASE.GAMEOVER then countMatchEnd() end
    if ph == game.PHASE.ROUNDOVER or ph == game.PHASE.GAMEOVER then
      screen = "roundover"
      ro_sel = 1
      drawRoundOver()
    else
      screen = "board"
      cur = 1
      drawBoard()
    end
    return
  end
  if ph == game.PHASE.ROUNDOVER or ph == game.PHASE.GAMEOVER then
    if ph == game.PHASE.GAMEOVER then countMatchEnd() end
    screen = "roundover"
    ro_sel = 1
    drawRoundOver()
    return
  end
  if g.turn == 1 then
    runAI()
    if g.phase == game.PHASE.ROUNDOVER or g.phase == game.PHASE.GAMEOVER then
      if g.phase == game.PHASE.GAMEOVER then countMatchEnd() end
      screen = "roundover"
      ro_sel = 1
      drawRoundOver()
      return
    end
  end
  cur = 1
  screen = "board"
  drawBoard()
end

local function nextRound()
  -- The player after the one who ended the previous round starts the new
  -- one; a deck run-out passes it on from whoever started it.
  local starter = g.ender ~= game.NO_SEAT and (g.ender ~ 1) or (g.roundStarter ~ 1)
  local s0, s1 = g.score[1], g.score[2]
  local rd = g.round
  game.deal(g, nextSeed(), starter)
  g.score[1], g.score[2] = s0, s1
  g.round = rd + 1
  afterHumanAction()
end

local function goToMenu()
  has_save = g.phase ~= game.PHASE.GAMEOVER
  saveGame()
  sel = {}
  menu_sel = 1
  screen = "menu"
  drawMenu()
end

local function startNewGame()
  g = game.newGame(nextSeed(), 0)
  stats_counted = false
  has_save = true
  sel = {}
  report = ""
  cur = 1
  screen = "board"
  drawBoard()
end

local function continueGame()
  sel = {}
  report = ""
  if g.phase == game.PHASE.ROUNDOVER or g.phase == game.PHASE.GAMEOVER then
    screen = "roundover"
    ro_sel = 1
    drawRoundOver()
  else
    -- A restored game can owe the AI a turn (or a last-chance final turn).
    afterHumanAction()
  end
end

-- ------------------------------------------------------------------ input

local function moveCursor(delta, items)
  local n = #items
  if n == 0 then return end
  cur = ((cur - 1 + delta) % n) + 1
end

local function activateItem(it)
  if link and not myTurn() then return end  -- their turn: the board only shows
  if it.t == "card" then
    local st = g.step
    if st == game.STEP.CRABPICK then
      if game.takeCrabCard(g, it.card) then afterHumanAction() end
    elseif st == game.STEP.PLAY then
      -- Toggle selection; a third card replaces the older pick.
      if sel[1] == it.card then
        sel[1] = sel[2]
        sel[2] = nil
      elseif sel[2] == it.card then
        sel[2] = nil
      elseif sel[1] == nil then
        sel[1] = it.card
      elseif sel[2] == nil then
        sel[2] = it.card
      else
        sel[1] = sel[2]
        sel[2] = it.card
      end
      cur = math.min(cur, #buildItems())
      drawBoard()
    end
    return
  end
  if it.t == "drawn" then
    if game.keepDrawn(g, it.i) then afterHumanAction() end
    return
  end
  if it.t == "pile" then
    local st = g.step
    if st == game.STEP.TAKE then
      if game.takeFromPile(g, it.pile) then afterHumanAction() end
    elseif st == game.STEP.CHOOSEPILE then
      if game.discardTo(g, it.pile) then afterHumanAction() end
    elseif st == game.STEP.CRABPILE then
      if game.chooseCrabPile(g, it.pile) then cur = 1; drawBoard() end
    end
    return
  end
  if it.t == "pill" then
    if it.act == "deck" then
      if game.takeFromDeck(g) then afterHumanAction() end
    elseif it.act == "pile0" then
      if game.takeFromPile(g, 0) then afterHumanAction() end
    elseif it.act == "pile1" then
      if game.takeFromPile(g, 1) then afterHumanAction() end
    elseif it.act == "call" then
      call_sel = 1
      screen = "call"
      drawCall()
    elseif it.act == "endturn" then
      if #sel == 2 and game.isPair(sel[1], sel[2]) then
        if game.playDuo(g, sel[1], sel[2]) then afterHumanAction() end
      else
        if game.endTurn(g) then afterHumanAction() end
      end
    end
    return
  end
end

local function routeBoard(ev)
  if ev == "back" then
    goToMenu()
    return
  end
  local items = buildItems()
  local n = #items
  if ev == "left" or ev == "right" or ev == "up" or ev == "down" then
    local delta = (ev == "right" or ev == "down") and 1 or -1
    moveCursor(delta, items)
    drawBoard()
    return
  end
  if ev == "confirm" and n > 0 then
    activateItem(items[cur])
  end
end

local function routeMenu(ev)
  local items = menuItems()
  if ev == "up" then
    menu_sel = ((menu_sel - 2) % #items) + 1
    drawMenu()
  elseif ev == "down" then
    menu_sel = (menu_sel % #items) + 1
    drawMenu()
  elseif ev == "confirm" then
    local act = items[menu_sel].act
    if act == "continue" then
      continueGame()
    elseif act == "new" then
      startNewGame()
    elseif act == "nearby" then
      linkedPlay()
    else
      how_page = 1
      screen = "howto"
      drawHowTo()
    end
  elseif ev == "back" then
    saveGame()
    app.exit()
    return true
  end
end

local function routeCall(ev)
  if ev == "up" then
    call_sel = call_sel == 1 and 2 or 1
    drawCall()
  elseif ev == "down" then
    call_sel = call_sel == 1 and 2 or 1
    drawCall()
  elseif ev == "confirm" then
    if game.endRound(g, call_sel == 2) then afterHumanAction() end
  elseif ev == "back" then
    screen = "board"
    drawBoard()
  end
end

local function routeRoundOver(ev)
  if ev == "back" then
    goToMenu()
    return
  end
  local over = g.phase == game.PHASE.GAMEOVER
  if ev == "up" then
    ro_sel = over and (((ro_sel - 2) % 2) + 1) or (((ro_sel - 2) % 2) + 1)
    drawRoundOver()
  elseif ev == "down" then
    ro_sel = (ro_sel % 2) + 1
    drawRoundOver()
  elseif ev == "confirm" then
    if ro_sel == 1 then
      if over then startNewGame() else nextRound() end
    else
      goToMenu()
    end
  end
end

local function routeHowTo(ev)
  if ev == "confirm" or ev == "right" then
    if how_page < #HOWTO then
      how_page = how_page + 1
      drawHowTo()
    else
      screen = "menu"
      drawMenu()
    end
  elseif ev == "back" or ev == "left" then
    screen = "menu"
    drawMenu()
  end
end

-- ----------------------------------------------------------- PLAY NEARBY
-- Two devices over ESP-NOW (nearby.lua). The blob is the C++ Game (wire.lua),
-- always in the first mover's seat order. linkturn.lua says who may act; the
-- transport turn alternates strictly and is handed on by each send.

local function loadLink()
  nearby = nearby or require("nearby")
  wire = wire or require("wire")
  linkturn = linkturn or require("linkturn")
end

local function linkWaitScreen()
  gfx.clear()
  header("SEA SALT")
  gfx.text(W // 2, 220, "LOOKING FOR A PLAYER", "sans18", "bc")
  gfx.text(W // 2, 256, "Turn on PLAY NEARBY on the other device.", "ui12", "c")
  gfx.text(W // 2, H - 40, "Back: cancel", "small", "c")
  present()
end

local function linkEndScreen(S)
  gfx.clear()
  header("SEA SALT")
  gfx.text(W // 2, 220, S.reason == "lost" and "LOST CONNECTION" or "THEY LEFT", "sans18", "bc")
  gfx.text(W // 2, H - 40, "Confirm or Back: menu", "small", "c")
  present()
end

-- Their state arrived: adopt it, say what they did, and pass it on at once if
-- the rules have nothing for me (see linkturn.lua).
local function linkTake()
  local blob = link.S:takeState()
  if not blob then return false end
  -- At GAME OVER, what arrives is the next match, sent by its first mover: this
  -- device is the second mover. (A device that asked for the rematch set this itself.)
  if g.phase == game.PHASE.GAMEOVER then link.flip = true end
  local incoming = wire.unpack(blob, link.flip)
  if not incoming then
    link.S.phase, link.S.reason = "ended", "lost"  -- not a Sea Salt game: stop, do not guess
    return true
  end
  report = linkturn.describe(g, incoming, NAMES)
  g = incoming
  sel = {}
  cur = 1
  link.transport = true
  if g.phase == game.PHASE.PLAYING or g.phase == game.PHASE.LASTCHANCE then
    link.again, link.S.peerAgain = false, false  -- a new match is under way
  end
  if g.phase == game.PHASE.GAMEOVER then countMatchEnd() end
  if linkturn.action(g, true) == "pass" then linkSend() end
  if g.phase == game.PHASE.ROUNDOVER or g.phase == game.PHASE.GAMEOVER then
    screen = "roundover"
    ro_sel = 1
  else
    screen = "board"
  end
  return true
end

local function redrawLink()
  if screen == "roundover" then drawRoundOver() else drawBoard() end
end

-- Both said PLAY AGAIN: a new match. The device holding the transport turn
-- deals and sends first (the same rule C++ uses for onRematch).
local function maybeRematch()
  if g.phase ~= game.PHASE.GAMEOVER or not (link.again and link.S.peerAgain) then return end
  local youFirst = link.transport
  link.flip = not youFirst
  link.again, link.S.peerAgain = false, false
  link.transport = youFirst
  g = game.newGame(nextSeed(), 0)
  stats_counted = false
  sel = {}
  report = ""
  cur = 1
  screen = "board"
  if youFirst then linkSend() end
  drawBoard()
end

local function askAgain()
  if link.again then return end
  link.again = true
  link.S:say(system.millis(), nearby.NOTE_PLAY_AGAIN)
  maybeRematch()
  if link and screen == "roundover" then drawRoundOver() end
end

-- The round is banked and it is my transport turn: deal the next one and send.
local function nextLinkRound()
  local starter = g.ender ~= game.NO_SEAT and (g.ender ~ 1) or (g.roundStarter ~ 1)
  local s0, s1, rd = g.score[1], g.score[2], g.round
  game.deal(g, nextSeed(), starter)
  g.score[1], g.score[2], g.round = s0, s1, rd + 1
  report = ""
  sel = {}
  cur = 1
  screen = "board"
  linkSend()
  drawBoard()
end

local function leaveLink()
  link.S:stop(system.millis())
  link = nil
  g = soloGame or game.newGame(nextSeed(), 0)
  soloGame = nil
  stats_counted = g.phase == game.PHASE.GAMEOVER
  sel = {}
  report = ""
  screen = "menu"
  menu_sel = 1
  drawMenu()
end

local function linkRoute(ev)
  if screen == "search" then
    if ev == "back" then leaveLink() end
  elseif screen == "linkend" then
    if ev == "back" or ev == "confirm" then leaveLink() end
  elseif screen == "board" then
    if ev == "back" then leaveLink() else routeBoard(ev) end
  elseif screen == "call" then
    routeCall(ev)
  elseif screen == "roundover" then
    if ev == "back" then
      leaveLink()
    elseif ev == "up" or ev == "down" then
      ro_sel = 3 - ro_sel
      drawRoundOver()
    elseif ev == "confirm" then
      if ro_sel == 2 then
        leaveLink()
      elseif g.phase == game.PHASE.GAMEOVER then
        askAgain()
      elseif linkturn.action(g, link.transport) == "deal" then
        nextLinkRound()
      end
    end
  end
end

local function linkLoop()
  linkWaitScreen()
  while link do
    local now = system.millis()
    link.S:pump(now)
    link.S:tick(now)
    if link.S:takeMatch() then
      -- the first mover is seat 0 in the blob, and opens the match with a send
      link.flip = not link.S.iFirst
      link.transport = link.S.iFirst
      link.again = false
      g = game.newGame(nextSeed(), 0)
      stats_counted = false
      sel = {}
      report = ""
      cur = 1
      screen = "board"
      if link.transport then linkSend() end
      drawBoard()
    end
    if link.S.phase == "play" and linkTake() then redrawLink() end
    if link.S.phase == "play" then maybeRematch() end
    if link.S.phase == "ended" and screen ~= "linkend" then
      screen = "linkend"
      linkEndScreen(link.S)
    end
    local ev = input.wait(100)  -- never block: the peer must hear our heartbeat
    if ev and link then linkRoute(ev) end
  end
end

function linkedPlay()
  loadLink()
  local S = nearby.new(GAME_ID, "PUP " .. string.sub(system.mac(), 16, 17))
  local ok, err = S:start()
  if not ok then
    gfx.clear()
    header("SEA SALT")
    gfx.text(16, 100, "RADIO WILL NOT START", "sans16", "b")
    gfx.text(16, 130, tostring(err):sub(1, 60), "ui12", "b")
    gfx.text(16, 160, "Back: menu", "ui12", "b")
    present()
    while input.wait() ~= "back" do end
    return
  end
  soloGame = g
  link = { S = S, flip = false, transport = false, again = false }
  g = game.newGame(nextSeed(), 0)
  sel = {}
  report = ""
  screen = "search"
  linkLoop()
end

local function run()
  loadStats()
  has_save = loadGame()
  if not has_save then
    g = game.newGame(nextSeed(), 0)
  end
  screen = "menu"
  drawMenu()
  while true do
    local ev = input.wait()
    if ev == nil then ev = "" end
    if screen == "menu" then
      if routeMenu(ev) then return end
    elseif screen == "board" then
      routeBoard(ev)
    elseif screen == "call" then
      routeCall(ev)
    elseif screen == "roundover" then
      routeRoundOver(ev)
    elseif screen == "howto" then
      routeHowTo(ev)
    end
  end
end

local ok, err = pcall(run)
if not ok then
  gfx.clear()
  gfx.rect(0, 0, W, 44, true, true)
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 64), "ui12", "bw")
  gfx.present()
  while input.wait() ~= "back" do end
  app.exit()
end