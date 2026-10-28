-- Hearts for CrossLua — a solo port of the crossplay game
-- (docs/apps/hearts.md, HeartsCore.h/.cpp, HeartsBrain.h/.cpp).
--
-- Four seats, one human: you are South, the device is West, North and
-- East. No link play by design — the radio seats two, and two humans plus
-- two brains is not a shape this ships in. Rules live in hearts.lua (the
-- core) and the opponents in brain.lua; this file is only the chrome: the
-- menu, the table, the pass, the scoring screens, driven by the seven
-- buttons (the X4 has no touch, so the C++ touch dither for an illegal
-- card becomes a dashed frame, and a refused tap names the rule that
-- refused it).
--
--   D-pad        move the cursor over your hand (and the pass pill)
--   Confirm      play the card, toggle a pass pick, commit the pass pill
--   Back         board -> menu (game is saved), menu -> exit
--
-- The rules are the doc's, exactly: the two of clubs opens, follow suit,
-- no heart lead until hearts are broken unless hearts are all you hold,
-- no point card on the first trick unless you hold nothing else, hearts 1
-- point each and the queen of spades 13 so 26 leave the table every hand,
-- shoot the moon scores 26 on everyone else (no subtract-26 option),
-- lowest score wins and the game ends the moment anybody reaches 100.
-- The pass rotates left, right, across, then a hold. It is simultaneous:
-- every seat's three cards are lifted before any are dealt in, so no hand
-- ever ends up with fourteen.

local cards = require("cards")
local hearts = require("hearts")
local brain = require("brain")

local W, H = gfx.size()
local presents = 0
local function present()
  presents = presents + 1
  gfx.present(presents % 8 == 0 and "half" or "fast")
end

-- ------------------------------------------------------------------ state

local g                 -- the live game
local screen = "menu"   -- menu | board | handover | gameover | howto
local cur = 1           -- cursor over the item list
local sel = {}          -- the human's pass picks (keyed by card id)
local note = ""         -- "you receive: ..." beat after the pass
local refuse = ""       -- the rule that refused the last tap
local seed = 1
local has_save = false
local menu_sel, how_page = 1, 1
local opp = brain.SHARP

local function selCount()
  local n = 0
  for _ in pairs(sel) do n = n + 1 end
  return n
end

-- ------------------------------------------------------------ navigation

local TILEW, TILEH, STEP = 64, 78, 66
local HAND_X0 = (W - 7 * STEP) // 2
local HANDY1, HANDY2 = 344, 428
local SEATINFO = {
  [1] = { name = "YOU",   x = (W - 64) // 2, y = 252, lx = W // 2, ly = 240, flag = "bc" },
  [2] = { name = "WEST",  x = 12,            y = 176, lx = 14,    ly = 160, flag = "b" },
  [3] = { name = "NORTH", x = (W - 64) // 2, y = 92,  lx = W // 2, ly = 78,  flag = "bc" },
  [4] = { name = "EAST",  x = W - 12 - 64,   y = 176, lx = W - 14, ly = 160, flag = "br" },
}
local H_PASS = { "LEFT TO WEST", "RIGHT TO EAST", "ACROSS TO NORTH", "HOLD" }

-- -------------------------------------------------------------- drawing

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

-- dashed border, the button-device stand-in for the C++ dither. On the
-- panel it means exactly one thing: the rules refuse this card.
local function dashedRect(x, y, w, h)
  local function dash(ax, ay, bx, by)
    local len = math.max(math.abs(bx - ax), math.abs(by - ay))
    local i = 0
    while i < len do
      local seg = math.min(5, len - i)
      if ax == bx then gfx.line(ax, ay + i, ax, ay + i + seg)
      else gfx.line(ax + i, ay, ax + i + seg, ay) end
      i = i + 9
    end
  end
  dash(x, y, x + w, y)
  dash(x, y + h, x + w, y + h)
  dash(x, y, x, y + h)
  dash(x + w, y, x + w, y + h)
end

-- A card face as a text tile. Diamonds and hearts are the red suits; on a
-- one-bit panel that is solid fill versus outline, as in the C++.
local function cardFace(id, x, y, w, h)
  local red = cards.isRed(id)
  local rank = cards.RANK[cards.rankOf(id) + 1]
  local suit = cards.SUIT[cards.suitOf(id) + 1]
  if red then
    gfx.rect(x, y, w, h, true, true)
    gfx.text(x + 6, y + 4, rank, "small", "bw")
    gfx.text(x + w // 2, y + h // 2 - 8, suit, "sans16", "bwc")
    gfx.text(x + w - 6, y + h - 18, suit, "small", "bwr")
  else
    gfx.rect(x + 1, y + 1, w - 2, h - 2, true, false)
    gfx.text(x + 6, y + 4, rank, "small", "b")
    gfx.text(x + w // 2, y + h // 2 - 8, suit, "sans16", "bc")
    gfx.text(x + w - 6, y + h - 18, suit, "small", "br")
  end
end

-- One of my thirteen (or fewer) hand tiles, with the two overlays the
-- game teaches with: illegal = dashed frame, picked for the pass = bar.
local function handTile(i)
  local x = HAND_X0 + ((i - 1) % 7) * STEP
  local y = (i <= 7) and HANDY1 or HANDY2
  local id = g.hands[1][i]
  cardFace(id, x, y, TILEW, TILEH)
  if g.phase == hearts.PHASE.PLAYING then
    -- Legality WITHOUT the turn: the led suit is settled once two cards
    -- are down, so you can see what you will be allowed to play while the
    -- brains think (the doc's reason for asking the rules without the turn).
    if not hearts.isLegalCard(g.hands[1], g.trick, g.heartsBroken, g.trickNumber == 0, id) then
      dashedRect(x - 2, y - 2, TILEW + 4, TILEH + 4)
    end
  end
  if sel[id] then gfx.rect(x, y + TILEH - 4, TILEW, 4, true, true) end
  if cur == i then
    gfx.rect(x - 2, y - 2, TILEW + 4, 3, true, true)
    gfx.rect(x - 2, y + TILEH - 1, TILEW + 4, 3, true, true)
    gfx.rect(x - 2, y - 2, 3, TILEH + 4, true, true)
    gfx.rect(x + TILEW - 1, y - 2, 3, TILEH + 4, true, true)
  end
end

local function drawSeat(s)
  local info = SEATINFO[s]
  local id = g.trick.played[s]
  gfx.text(info.lx, info.ly, info.name, "small", info.flag)
  if id ~= cards.NO_CARD then
    cardFace(id, info.x, info.y, 64, 78)
    if g.phase == hearts.PHASE.TRICKTAKEN and s == hearts.trickWinner(g) then
      gfx.rect(info.x - 2, info.y - 2, 68, 3, true, true)
      gfx.rect(info.x - 2, info.y + 78, 68, 3, true, true)
      gfx.rect(info.x - 2, info.y - 2, 3, 82, true, true)
      gfx.rect(info.x + 64, info.y - 2, 3, 82, true, true)
    end
  else
    gfx.rounded_rect(info.x, info.y, 64, 78, 6, false)
  end
end

local function centerStatus()
  local t = g.trick
  if g.phase == hearts.PHASE.PASSING then
    gfx.text(W // 2, 204, "EVERYONE PICKS BEFORE ANYONE RECEIVES.", "small", "bc")
    local d = hearts.passDirection(g.handNumber)
    if d == hearts.PASS.HOLD then
      gfx.text(W // 2, 226, "NO PASS THIS HAND.", "ui12", "bc")
    else
      gfx.text(W // 2, 226, "PASS " .. H_PASS[d + 1] .. ".", "ui12", "bc")
    end
  elseif t.count == 0 then
    local who = g.turn == 1 and "YOU LEAD" or (hearts.SEAT_NAME[g.turn] .. " LEADS")
    gfx.text(W // 2, 204, "LEAD A CARD - " .. who, "small", "bc")
  else
    local led = cards.SUIT_NAME[cards.suitOf(t.played[t.leader]) + 1]
    gfx.text(W // 2, 204, "LEAD: " .. led .. "   -   " .. hearts.trickPoints(g) .. " PTS", "small", "bc")
    gfx.text(W // 2, 226, "WAITING FOR " .. hearts.SEAT_NAME[g.turn], "ui12", "bc")
  end
  if g.phase == hearts.PHASE.TRICKTAKEN then
    gfx.text(W // 2, 226, hearts.SEAT_NAME[hearts.trickWinner(g)] .. " TAKES THE TRICK", "ui12", "bc")
  end
end

local function hintText()
  if g.phase == hearts.PHASE.PASSING then
    local d = hearts.passDirection(g.handNumber)
    if d == hearts.PASS.HOLD then
      return "NO PASS THIS HAND. CONFIRM A CARD TO START PLAY."
    end
    return "PASS " .. H_PASS[d + 1] .. ". DROP YOUR WORST THREE - HIGH CARDS WIN TRICKS YOU DO NOT WANT."
  end
  if g.phase == hearts.PHASE.PLAYING then
    if g.trick.count == 0 then
      if g.heartsBroken then return "HEARTS ARE BROKEN. ANY LEGAL CARD MAY LEAD." end
      return "HEARTS ARE NOT BROKEN - YOU MAY NOT LEAD ONE."
    end
    local led = cards.SUIT_NAME[cards.suitOf(g.trick.played[g.trick.leader]) + 1]
    return "FOLLOW " .. led .. " IF YOU HOLD IT. HIGHEST " .. led .. " CARD WINS; OFF-SUIT CANNOT."
  end
  if g.phase == hearts.PHASE.TRICKTAKEN then
    return "THE HIGHEST CARD OF THE LED SUIT TAKES THE TRICK AND LEADS NEXT."
  end
  return ""
end

local function buildItems()
  local items = {}
  if g.phase == hearts.PHASE.PASSING or g.phase == hearts.PHASE.PLAYING then
    for i = 1, #g.hands[1] do items[#items + 1] = { t = "card", i = i } end
    if g.phase == hearts.PHASE.PASSING and selCount() >= 3 then
      items[#items + 1] = { t = "pass" }
    end
  end
  return items
end

local function drawBoard()
  gfx.clear()
  header("HEARTS", "YOU " .. g.total[1] .. "  W " .. g.total[2] .. "  N " .. g.total[3] .. "  E " .. g.total[4])
  local sub
  if g.phase == hearts.PHASE.PASSING then
    sub = hearts.passName[hearts.passDirection(g.handNumber) + 1] .. "  -  CHOOSE 3 CARDS"
  else
    sub = "TRICK " .. (g.trickNumber + 1) .. " OF 13"
    if g.heartsBroken then sub = sub .. "  -  HEARTS BROKEN" end
  end
  gfx.text(W // 2, 50, sub, "small", "bc")
  gfx.line(8, 70, W - 8, 70)

  drawSeat(3)
  drawSeat(2)
  drawSeat(4)
  drawSeat(1)
  centerStatus()

  local items = buildItems()
  cur = math.min(cur, math.max(1, #items))
  for i = 1, #g.hands[1] do handTile(i) end

  -- status line: the refusal that named the rule beats everything
  local status = refuse
  if status == "" then status = note end
  if status == "" then
    if g.phase == hearts.PHASE.PASSING then
      status = "CHOOSE THREE TO PASS - SELECTED " .. selCount() .. "/3"
    elseif g.phase == hearts.PHASE.TRICKTAKEN then
      status = "TAP ANY BUTTON TO SWEEP THE TRICK"
    elseif g.phase == hearts.PHASE.PLAYING then
      status = g.turn == 1 and "YOUR TURN" or (hearts.SEAT_NAME[g.turn] .. " IS THINKING")
    end
  end
  gfx.text(W // 2, 516, status, "small", "bc")

  -- hint box
  local hy = 548
  gfx.rect(8, hy, W - 16, 96, false)
  local lines = wrap(hintText(), W - 40)
  for i = 1, math.min(#lines, 3) do
    gfx.text(W // 2, hy + 10 + (i - 1) * 24, lines[i], "small", "c")
  end

  -- pill row
  if g.phase == hearts.PHASE.PASSING and selCount() >= 3 then
    local px, py = (W - 220) // 2, 668
    gfx.rounded_rect(px, py, 220, 46, 8, true, false)
    gfx.text(W // 2, py + 14, "CONFIRM " .. hearts.passName[hearts.passDirection(g.handNumber) + 1], "ui12", "bc")
    if cur == #items then
      gfx.rect(px - 2, py - 2, 224, 3, true, true)
      gfx.rect(px - 2, py + 45, 224, 3, true, true)
      gfx.rect(px - 2, py - 2, 3, 50, true, true)
      gfx.rect(px + 220, py - 2, 3, 50, true, true)
    end
  elseif g.phase == hearts.PHASE.TRICKTAKEN then
    gfx.rounded_rect((W - 220) // 2, 668, 220, 46, 8, true, false)
    gfx.text(W // 2, 682, "CONTINUE", "ui12", "bc")
  end

  gfx.text(W // 2, 748, "D-PAD: MOVE   CONFIRM: PLAY   BACK: MENU", "small", "c")
  present()
end

-- ---------------------------------------------------------------- menu

local function menuItems()
  local items = {}
  if has_save then items[#items + 1] = { label = "CONTINUE", act = "continue" } end
  items[#items + 1] = { label = "NEW GAME", act = "new" }
  items[#items + 1] = { label = "OPPONENTS: " .. (opp == brain.SHARP and "SHARP" or "ROOKIE"), act = "skill" }
  items[#items + 1] = { label = "HOW TO PLAY", act = "how" }
  return items
end

local function drawMenu()
  gfx.clear()
  header("HEARTS")
  gfx.text(W // 2, 84, "FOUR SEATS. THREE OPPONENTS.", "sans16", "bc")
  gfx.text(W // 2, 116, "LOWEST SCORE WINS. FIRST TO 100 ENDS IT.", "small", "c")
  gfx.text(W // 2, 144, "EVERY HEART 1 PT. QUEEN OF SPADES 13.", "small", "c")
  local items = menuItems()
  menu_sel = math.min(menu_sel, #items)
  local my = 220
  for i, it in ipairs(items) do
    local y = my + (i - 1) * 58
    if i == menu_sel then gfx.rect(24, y, W - 48, 46, true, true) end
    gfx.text(W // 2, y + 14, it.label, "ui12", i == menu_sel and "bwc" or "bc")
  end
  gfx.text(W // 2, H - 44, "UP/DOWN: MOVE   CONFIRM: OPEN   BACK: EXIT", "small", "c")
  present()
end

-- --------------------------------------------------- hand & game over

local function drawHandOver()
  gfx.clear()
  header("HAND OVER", "HAND " .. (g.handNumber + 1))
  local lh = g.lastHand or {}
  local y = 92
  if lh.moon then
    gfx.text(W // 2, y, "SHOOT THE MOON - " .. hearts.SEAT_NAME[lh.shooter or 1] .. " TAKES NOTHING", "ui12", "bc")
    y = y + 26
    gfx.text(W // 2, y, "EVERYONE ELSE SCORES 26.", "small", "c")
    y = y + 30
  end
  for s = 1, 4 do
    local sc = (lh.scored and lh.scored[s]) or 0
    local tt = (lh.total and lh.total[s]) or g.total[s]
    gfx.text(30, y, hearts.SEAT_NAME[s] .. "   " .. sc .. " PTS", "small", "b")
    gfx.text(W - 30, y, "TOTAL " .. tt, "small", "br")
    y = y + 32
  end
  gfx.line(24, y + 4, W - 24, y + 4)
  y = y + 26
  gfx.text(W // 2, y, "THE HAND SCORED " .. (g.taken[1] + g.taken[2] + g.taken[3] + g.taken[4]) .. " PTS. 26 IN TOTAL.", "small", "c")
  y = y + 30
  gfx.text(W // 2, y, "CONFIRM: NEXT HAND   BACK: MENU", "small", "c")
  present()
end

local function drawGameOver()
  gfx.clear()
  header("GAME OVER")
  local tied = hearts.isTied(g)
  local ld = hearts.leader(g)
  local line1 = tied and "IT'S A TIE" or (hearts.SEAT_NAME[ld] .. (ld == 1 and " WIN" or " WINS"))
  gfx.text(W // 2, 100, line1, "sans16", "bc")
  gfx.text(W // 2, 132, "LOWEST SCORE WINS. GAME ENDS AT 100.", "small", "c")
  local y = 190
  for s = 1, 4 do
    gfx.text(30, y, hearts.SEAT_NAME[s], "small", "b")
    gfx.text(W - 30, y, tostring(g.total[s]) .. " PTS", "small", "br")
    y = y + 34
  end
  gfx.text(W // 2, y + 50, "CONFIRM: PLAY AGAIN   BACK: MENU", "small", "c")
  present()
end

-- --------------------------------------------------------------- howto

local HOWTO = {
  { "FOUR SEATS",
    { "YOU ARE SOUTH. WEST, NORTH AND EAST", "ARE THE DEVICE. PLAY CLOCKWISE:", "SOUTH, WEST, NORTH, EAST.", "",
      "13 CARDS EACH, 13 TRICKS PER HAND.", "LOWEST SCORE WINS, AND THE GAME", "ENDS THE MOMENT ANYBODY REACHES 100." } },
  { "THE PASS",
    { "BEFORE EACH HAND YOU PASS THREE", "CARDS. THE DIRECTION ROTATES:", "LEFT, RIGHT, ACROSS, THEN A HOLD.", "",
      "THE PASS IS SIMULTANEOUS: EVERYONE", "PICKS BEFORE ANYONE RECEIVES.", "CHOOSE THREE, THEN CONFIRM THE PILL." } },
  { "PLAYING TRICKS",
    { "THE TWO OF CLUBS OPENS, ALWAYS.", "FOLLOW THE LED SUIT IF YOU HOLD IT.", "THE HIGHEST CARD OF THE LED SUIT", "TAKES THE TRICK AND LEADS THE NEXT.", "AN OFF-SUIT CARD CANNOT WIN,", "HOWEVER HIGH IT IS." } },
  { "THE TWO RULES",
    { "YOU MAY NOT LEAD A HEART UNTIL", "ONE HAS BEEN DISCARDED ON ANOTHER", "SUIT - HEARTS ARE BROKEN.", "",
      "AND ON THE FIRST TRICK: NO HEARTS", "AND NO QUEEN OF SPADES, UNLESS", "YOU HOLD NOTHING ELSE." } },
  { "SCORING",
    { "EVERY HEART COSTS ONE POINT.", "THE QUEEN OF SPADES COSTS 13.", "EXACTLY 26 LEAVE THE TABLE", "EVERY HAND. LOWEST SCORE WINS.", "",
      "A CARD YOU MAY NOT PLAY IS DRAWN", "WITH A DASHED FRAME, AND A REFUSED", "TAP NAMES THE RULE THAT REFUSED IT." } },
  { "SHOOTING THE MOON",
    { "TAKE ALL 26 AND YOU SCORE NOTHING", "WHILE EVERYONE ELSE SCORES 26.", "THERE IS NO SUBTRACT-26 OPTION.", "",
      "A FAILED SHOOT IS BRUTAL: IT HANDS", "OVER EVERYTHING YOU COLLECTED", "ON THE WAY." } },
}

local function drawHowTo()
  gfx.clear()
  header("HOW TO PLAY", how_page .. " OF " .. #HOWTO)
  local page = HOWTO[how_page]
  gfx.text(W // 2, 84, page[1], "sans16", "bc")
  local y = 132
  for _, ln in ipairs(page[2]) do
    if ln == "" then
      y = y + 14
    else
      gfx.text(W // 2, y, ln, "ui12", "c")
    end
    y = y + 28
  end
  gfx.text(W // 2, H - 44, "CONFIRM/RIGHT: NEXT   BACK: MENU", "small", "c")
  present()
end

-- ---------------------------------------------------------- persistence

local function saveGame()
  if not g then return end
  if g.phase == hearts.PHASE.GAMEOVER then
    -- a finished game has nothing to come back to
    has_save = false
    if fs.exists("data:hearts.sav") then fs.remove("data:hearts.sav") end
    return
  end
  local st = {
    v = 1,
    rng = g.rng.v,
    handNumber = g.handNumber,
    phase = g.phase,
    turn = g.turn,
    trickNumber = g.trickNumber,
    heartsBroken = g.heartsBroken,
    total = { g.total[1], g.total[2], g.total[3], g.total[4] },
    taken = { g.taken[1], g.taken[2], g.taken[3], g.taken[4] },
    tricksWon = { g.tricksWon[1], g.tricksWon[2], g.tricksWon[3], g.tricksWon[4] },
    hands = { {}, {}, {}, {} },
    played = {},
    voidShown = { {}, {}, {}, {} },
    passing = { {}, {}, {}, {} },
    received = { {}, {}, {}, {} },
    trick = {
      played = { g.trick.played[1], g.trick.played[2], g.trick.played[3], g.trick.played[4] },
      leader = g.trick.leader,
      count = g.trick.count,
    },
    skills = { g.skills[2], g.skills[3], g.skills[4] },
    selIds = {},
    lastHand = g.lastHand,
  }
  for s = 1, 4 do
    for _, c in ipairs(g.hands[s]) do st.hands[s][#st.hands[s] + 1] = c end
    for su = 1, 4 do st.voidShown[s][su] = g.voidShown[s][su] end
    for i = 1, 3 do st.passing[s][i] = g.passing[s][i] or 0 end
    for i = 1, 3 do st.received[s][i] = g.received[s][i] or 0 end
  end
  for c = 0, 51 do
    if g.played[c + 1] then st.played[#st.played + 1] = c end
  end
  for id in pairs(sel) do st.selIds[#st.selIds + 1] = id end
  table.sort(st.selIds)
  local s = json.encode(st)
  if s then
    if fs.write("data:hearts.sav", s) then has_save = true end
  end
end

-- Restore a game and refuse it if it is not internally possible: a torn
-- write passes a version byte and a length check, and only the rules can
-- say whether the position is possible at all (the deck has to add up to
-- 52 distinct cards across the hands and what has been played).
local function loadGame()
  local raw = fs.read("data:hearts.sav")
  if not raw then return false end
  local ok, st = pcall(json.decode, raw)
  if not ok or type(st) ~= "table" or st.v ~= 1 then return false end
  if type(st.phase) ~= "number" or st.phase < 1 or st.phase > 5 then return false end
  if type(st.hands) ~= "table" or type(st.trick) ~= "table" then return false end

  local sk = { nil, opp, opp, opp }
  if type(st.skills) == "table" then
    for s = 2, 4 do
      local v = st.skills[s - 1]
      if v == brain.ROOKIE or v == brain.SHARP then sk[s] = v end
    end
  end
  local g2 = hearts.newGame(1, sk)
  g2.rng.v = tonumber(st.rng) or 1
  g2.handNumber = tonumber(st.handNumber) or 0
  g2.turn = tonumber(st.turn) or 1
  g2.trickNumber = tonumber(st.trickNumber) or 0
  g2.heartsBroken = (st.heartsBroken == true)
  g2.phase = st.phase
  g2.skills = sk
  for i = 1, 4 do
    if type(st.total) == "table" and type(st.total[i]) == "number" then g2.total[i] = st.total[i] end
    if type(st.taken) == "table" and type(st.taken[i]) == "number" then g2.taken[i] = st.taken[i] end
    if type(st.tricksWon) == "table" and type(st.tricksWon[i]) == "number" then g2.tricksWon[i] = st.tricksWon[i] end
  end
  for s = 1, 4 do
    if type(st.hands[s]) ~= "table" then return false end
    local h = {}
    for _, c in ipairs(st.hands[s]) do
      if type(c) ~= "number" or c < 0 or c > 51 then return false end
      h[#h + 1] = c
    end
    g2.hands[s] = h
  end
  for _, c in ipairs(st.played or {}) do
    if type(c) == "number" and c >= 0 and c <= 51 then g2.played[c + 1] = true end
  end
  if type(st.voidShown) == "table" then
    for s = 1, 4 do
      if type(st.voidShown[s]) == "table" then
        for su = 1, 4 do g2.voidShown[s][su] = (st.voidShown[s][su] == true) end
      end
    end
  end
  if type(st.passing) == "table" then
    for s = 1, 4 do
      if type(st.passing[s]) == "table" then
        local p = {}
        for _, c in ipairs(st.passing[s]) do
          if type(c) == "number" and c >= 0 and c <= 51 then p[#p + 1] = c end
        end
        g2.passing[s] = p
        g2.passingCount[s] = #p
      end
    end
  end
  if type(st.received) == "table" then
    for s = 1, 4 do
      if type(st.received[s]) == "table" then
        local r = {}
        for _, c in ipairs(st.received[s]) do
          if type(c) == "number" and c >= 0 and c <= 51 then r[#r + 1] = c end
        end
        g2.received[s] = r
        g2.receivedCount[s] = #r
      end
    end
  end
  local tl = st.trick.played
  if type(tl) ~= "table" then return false end
  for s = 1, 4 do
    local c = tl[s]
    if type(c) ~= "number" or (c ~= cards.NO_CARD and (c < 0 or c > 51)) then return false end
    g2.trick.played[s] = c
  end
  g2.trick.leader = tonumber(st.trick.leader) or 1
  g2.trick.count = tonumber(st.trick.count) or 0
  if type(st.lastHand) == "table" then g2.lastHand = st.lastHand end

  if not hearts.isConsistent(g2) then return false end
  g = g2
  for _, cid in ipairs(st.selIds or {}) do
    if type(cid) == "number" and hearts.hasCard(g.hands[1], cid) then sel[cid] = true end
  end
  return true
end

-- ----------------------------------------------------------------- flow

local function receivedNote()
  local rc = g.received[1]
  if #rc == 0 then return "" end
  local parts = {}
  for _, c in ipairs(rc) do parts[#parts + 1] = cards.label(c) end
  return "YOU RECEIVE: " .. table.concat(parts, " ")
end

local function persist() saveGame() end

-- The three AI seats choose their passes at deal time. Watching this does
-- not leak anything: each seat decides from its own observation.
local function aiPasses()
  for s = 2, 4 do
    local o = brain.observe(g, s)
    local out = {}
    brain.decidePass(o, g.skills[s], g.rng, out)
    hearts.setPass(g, s, out)
  end
end

-- Play every decision the brains owe, one card at a time so the table is
-- actually seen to fill (a fresh repaint per card, a pause between).
local function runAI()
  local guard = 0
  while guard < 200 and g.phase == hearts.PHASE.PLAYING and g.turn ~= 1 do
    guard = guard + 1
    local o = brain.observe(g, g.turn)
    local card = brain.decidePlay(o, g.skills[g.turn], g.rng)
    if card == cards.NO_CARD then break end
    if not hearts.playCard(g, card) then break end
    drawBoard()
    app.sleep(320)
  end
end

-- The shared exit of any play: a completed trick holds on the panel for a
-- beat (the doc's 900 ms, so the fourth card is actually seen), then
-- sweeps; afterwards the winner of the trick keeps leading, through the
-- brains if they are the ones who owe moves.
local function settle()
  if g.phase == hearts.PHASE.TRICKTAKEN then
    drawBoard()
    input.wait(900)
    if not hearts.sweepTrick(g) then drawBoard() return end
    persist()
    if g.phase == hearts.PHASE.HANDOVER then
      screen = "handover"
      drawHandOver()
    elseif g.phase == hearts.PHASE.GAMEOVER then
      screen = "gameover"
      drawGameOver()
    else
      if g.turn ~= 1 then
        runAI()
        settle()
        return
      end
      drawBoard()
    end
    return
  end
  if g.phase == hearts.PHASE.PLAYING and g.turn ~= 1 then
    runAI()
    settle()
    return
  end
  drawBoard()
end

-- Start a fresh deal: AI seats pass first, a hold pass commits straight
-- away, and play begins with whoever holds the two of clubs.
local function beginHand()
  aiPasses()
  if hearts.passDirection(g.handNumber) == hearts.PASS.HOLD then
    hearts.commitPass(g)
    note = ""
  end
  persist()
  settle()
end

local function nextSeed()
  seed = (seed * 1664525 + 1013904223 + system.millis()) & 0x7FFFFFFF
  return seed | 1
end

local function startNewGame()
  g = hearts.newGame(nextSeed(), { nil, opp, opp, opp })
  has_save = true
  sel, refuse, note = {}, "", ""
  cur = 1
  screen = "board"
  beginHand()
end

local function nextHand()
  if not hearts.nextHand(g) then return end
  sel, refuse, note = {}, "", ""
  cur = 1
  screen = "board"
  beginHand()
end

local function goToMenu()
  saveGame()
  sel, refuse, note = {}, "", ""
  menu_sel = 1
  screen = "menu"
  drawMenu()
end

local function continueGame()
  sel, refuse, note = {}, "", ""
  cur = 1
  screen = "board"
  if g.phase == hearts.PHASE.HANDOVER then
    screen = "handover"
    drawHandOver()
  elseif g.phase == hearts.PHASE.GAMEOVER then
    screen = "gameover"
    drawGameOver()
  elseif g.phase == hearts.PHASE.PASSING then
    drawBoard()
  else
    settle()
  end
end

-- ---------------------------------------------------------------- input

local function move(delta, n)
  if n == 0 then return end
  cur = ((cur - 1 + delta) % n) + 1
end

local function activate(it)
  local id = g.hands[1][it.i]
  if g.phase == hearts.PHASE.PASSING and it.t == "card" then
    if sel[id] then
      sel[id] = nil
    elseif selCount() >= 3 then
      refuse = "THREE CARDS ONLY - UNPICK ONE FIRST"
    else
      sel[id] = true
      refuse = ""
    end
    drawBoard()
    return
  end
  if g.phase == hearts.PHASE.PLAYING and it.t == "card" then
    if not hearts.isLegalPlay(g, 1, id) then
      refuse = hearts.illegalReason(g, 1, id) or "NOT LEGAL"
      drawBoard()
      return
    end
    refuse = ""
    note = ""
    if hearts.playCard(g, id) then settle() end
    return
  end
  if it.t == "pass" then
    local three = {}
    for cid in pairs(sel) do three[#three + 1] = cid end
    table.sort(three)
    if #three == 3 and hearts.setPass(g, 1, three) then
      sel = {}
      if hearts.commitPass(g) then
        note = receivedNote()
        persist()
        settle()
      end
    end
  end
end

local function routeBoard(ev)
  if ev == "back" then
    goToMenu()
    return
  end
  local items = buildItems()
  if ev == "left" or ev == "right" or ev == "up" or ev == "down" then
    move((ev == "right" or ev == "down") and 1 or -1, #items)
    refuse = ""
    drawBoard()
    return
  end
  if ev == "confirm" and #items > 0 then
    activate(items[cur])
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
    elseif act == "skill" then
      opp = (opp == brain.SHARP) and brain.ROOKIE or brain.SHARP
      drawMenu()
    else
      how_page = 1
      screen = "howto"
      drawHowTo()
    end
  elseif ev == "back" then
    -- the menu is the top of the tree: backing out of it leaves the app
    return true
  end
  return false
end

local function routeHandOver(ev)
  if ev == "confirm" then
    nextHand()
  elseif ev == "back" then
    goToMenu()
  end
end

local function routeGameOver(ev)
  if ev == "confirm" then
    startNewGame()
  elseif ev == "back" then
    goToMenu()
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

local function run()
  has_save = loadGame()
  if not has_save then
    g = hearts.newGame(nextSeed(), { nil, opp, opp, opp })
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
    elseif screen == "handover" then
      routeHandOver(ev)
    elseif screen == "gameover" then
      routeGameOver(ev)
    elseif screen == "howto" then
      routeHowTo(ev)
    end
  end
end

local ok, err = pcall(run)
if not ok then
  gfx.clear()
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b")
  gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()