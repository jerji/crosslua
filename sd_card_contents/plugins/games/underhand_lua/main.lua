-- underhand_lua/main.lua
-- Underhand: summon the seven gods. A port of the crossplay game (rules and
-- card text used with Spoopy Squad's permission; screens are new, text-only,
-- button-driven for the X4's seven buttons).
local engine = require("engine")
local rngmod = require("rng")
local data = require("data")
local save = require("save")
local view = require("view")

local W, H = gfx.size()

local function __main()
  if not data.load() then error("App data missing (gods.json / cards.json)") end
  if not data.rulesFit() then error("App data does not fit the rules") end

  -- state ------------------------------------------------------------------
  local profile = { summoned = 0, previous = -1, tutorialDone = false }
  local game = {}
  local rng = rngmod.Rng.new()
  local inRun = false
  local showOutcome = false
  local screen = "menu" -- menu card pay foresight outcome guide end giveup startover
  local cur = 1 -- cursor
  local payK = 1
  local payWays = {}
  local paySel = 1
  local payNone = false
  local payFoodNote = false
  local statusLine = ""
  local guidePage = 1
  local lastTurn = ""

  local loaded = save.load(data)
  if loaded then
    profile = loaded.profile
    if loaded.inRun then
      inRun = true
      game = loaded.game
      rng = rngmod.Rng.new(loaded.rng)
      showOutcome = loaded.showOutcome
    end
  end

  local function countBits(bits)
    local n = 0
    while bits ~= 0 do n = n + 1; bits = bits & (bits - 1) end
    return n
  end

  local function fresh()
    return profile.summoned == 0 and profile.previous == -1 and not profile.tutorialDone
  end

  local function persist()
    pcall(save.store, { profile = profile, inRun = inRun, showOutcome = showOutcome,
      rng = rng:stateHex(), game = inRun and game or nil })
  end

  local function endRunScreen()
    engine.finish(profile, game)
    inRun = false
    showOutcome = false
    screen = "end"
    cur = 1
    persist()
  end

  -- a run that ended without a choice (stuck / out of cards / a winning or
  -- losing option) moves to the end screen
  local function checkEnd()
    if inRun and (game.phase == engine.WON or game.phase == engine.LOST) then
      endRunScreen()
    end
  end

  local function startRun()
    rng = rngmod.Rng.new()
    game = {}
    engine.start(game, data, profile, rng)
    inRun = true
    showOutcome = false
    screen = "card"
    cur = 1
    statusLine = ""
    lastTurn = ""
    checkEnd()
    persist()
  end

  local function resCounts(held)
    local labels = { "R", "$", "C", "F", "P", "S" }
    local parts = {}
    for r = 1, 6 do parts[#parts + 1] = labels[r] .. " " .. held[r] end
    return table.concat(parts, "  ")
  end

  -- after a choice
  local function afterChoose()
    if game.phase == engine.CHOOSING or game.phase == engine.FORESIGHT then
      local said = game.addedCount > 0 or game.reshuffled
      for r = 1, 6 do if game.lost[r] > 0 then said = true end end
      showOutcome = game.phase == engine.CHOOSING and said
      local t, g = {}, {}
      for r = 1, 6 do
        if game.paid[r] > 0 then t[#t + 1] = "-" .. game.paid[r] .. " " .. view.resSymbol(r) end
        if game.gained[r] > 0 then g[#g + 1] = "+" .. game.gained[r] .. " " .. view.resSymbol(r) end
      end
      local both = {}
      for i = 1, #t do both[#both + 1] = t[i] end
      for i = 1, #g do both[#both + 1] = g[i] end
      lastTurn = table.concat(both, " ")
    else
      lastTurn = ""
    end
    checkEnd()
    persist()
  end

  local function deckSentence()
    if game.tutorial then
      if game.addedCount > 0 then
        local t = data.text(data.card(game.added[1][1]).titleOff, data.card(game.added[1][1]).titleLen)
        return t .. " goes on top of the deck."
      end
      return ""
    end
    if game.reshuffled then
      local top = game.draw[#game.draw]
      if top then
        local t = data.text(data.card(top).titleOff, data.card(top).titleLen)
        return "The deck was reshuffled and now holds " .. t .. "."
      end
      return "The deck was reshuffled."
    end
    local parts = {}
    for a = 1, game.addedCount do
      local c = game.added[a]
      local t = data.text(data.card(c[1]).titleOff, data.card(c[1]).titleLen)
      parts[#parts + 1] = (c[2] > 1 and (c[2] .. " x ") or "") .. t
    end
    if #parts == 0 then return "" end
    local joined = table.concat(parts, ", ")
    return joined .. " " .. (#parts == 1 and "joins" or "join") .. " the deck at the next shuffle."
  end

  -- menu rows, shared by the drawing and the input handler
  local function menuRows()
    local rows = {}
    rows[#rows + 1] = { id = "guide", label = "HOW TO PLAY" }
    if inRun then
      rows[#rows + 1] = { id = "giveup", label = "GIVE UP" }
    elseif not fresh() then
      rows[#rows + 1] = { id = "startover", label = "START OVER" }
    end
    rows[#rows + 1] = { id = "start", label = inRun and "CONTINUE" or (fresh() and "BEGIN" or "START") }
    return rows
  end

  local FONT_TITLE, FONT_BODY, FONT_SMALL = "sans18", "sans14", "ui12"

  -- rendering --------------------------------------------------------------
  local function fillRect(x, y, w, h)
    gfx.rect(x, y, w, h, true, true)
  end
  local function center(s, y, font, flags)
    local w = gfx.text_width(s, font or FONT_BODY)
    gfx.text((W - w) / 2, y, s, font or FONT_BODY, flags or "")
  end
  local function drawRow(y, label, selected)
    if selected then
      fillRect(20, y - 1, W - 40, 34)
      gfx.text(36, y + 5, label, FONT_BODY, "w")
    else
      gfx.text(36, y + 5, label, FONT_BODY, "")
    end
  end
  local function wrap(textStr, font, maxW)
    return view.wrap(textStr, font, maxW)
  end

  local function drawMenu()
    gfx.clear()
    local headline = inRun and string.format("TURN %d", game.turn) or (not profile.tutorialDone and "TUTORIAL" or "NEW RUN")
    center(headline, 26, FONT_TITLE, "b")
    center("Summon a god to win a run. Gods you summon stay.", 58, FONT_SMALL)
    gfx.text(24, 90, string.format("GODS SUMMONED  %d OF %d", countBits(profile.summoned), data.godCount()), FONT_SMALL)
    for i = 1, data.godCount() do
      local has = (profile.summoned >> (i - 1)) & 1 ~= 0
      gfx.text(48, 112 + (i - 1) * 26, (has and "* " or "- ") .. data.godName(i), FONT_BODY)
    end
    local rows = menuRows()
    local y = 300
    for i, row in ipairs(rows) do
      if i == #rows then
        if cur == i then
          fillRect(20, y - 1, W - 40, 34)
          center(row.label, y + 5, FONT_BODY, "w")
        else
          center(row.label, y + 5, FONT_BODY)
        end
      else
        drawRow(y, row.label, cur == i)
      end
      y = y + 38
    end
    gfx.text(24, H - 30, "BACK exits", FONT_SMALL)
  end

  local function optionState(k)
    if game.lockedMask & (1 << (k - 1)) ~= 0 then return 1 end
    if engine.affordable(game, data, k) then return 2 end
    return 0
  end

  local function whyNot(k)
    if game.lockedMask & (1 << (k - 1)) ~= 0 then return "ONLY WHEN NOTHING ELSE IS OPEN" end
    for r = 1, 6 do
      if game.cost[k][r] == engine.KON then return "ONLY WITH NO " .. view.resSymbol(r) end
    end
    return ""
  end

  local function costLine(k)
    local line = view.costStr(game, data, k)
    if optionState(k) == 2 then
      local ways = view.choices(game, data, k)
      if #ways > 0 then
        local chips = {}
        for i = 1, math.min(3, #ways) do
          chips[#chips + 1] = "[" .. view.countsStr(ways[i]) .. "]"
        end
        if #ways > 3 then chips[#chips + 1] = "CHOOSE" end
        line = line .. " " .. table.concat(chips, " ")
      end
    end
    local gain = view.gainStr(game, data, k)
    if gain ~= "" then line = line .. (line == "" and "" or "  ") .. gain end
    return line
  end

  local function noteLine(k)
    local o = data.card(game.card).opts[k]
    local why = whyNot(k)
    if why ~= "" then return why end
    local s = view.noteStr(game, data, k)
    local out = data.text(o.outcomeOff, o.outcomeLen)
    if out ~= "" then s = s .. (s == "" and "" or "  ") .. out end
    return s
  end

  local function drawCard()
    gfx.clear()
    local c = data.card(game.card)
    gfx.text(16, 10, "UNDERHAND", FONT_SMALL)
    local deck = string.format("DECK %d", #game.draw)
    gfx.text(W - 16 - gfx.text_width(deck, FONT_SMALL), 10, deck, FONT_SMALL, "b")
    local total = game.held[1] + game.held[2] + game.held[3] + game.held[4] + game.held[5] + game.held[6]
    gfx.text(16, 24, string.format("TURN %d   HELD %d", game.turn, total), FONT_SMALL)
    gfx.text(16, 46, data.text(c.titleOff, c.titleLen), FONT_TITLE, "b")
    local fy = 78
    if c.flavorLen > 0 then
      for _, l in ipairs(wrap(data.text(c.flavorOff, c.flavorLen), FONT_SMALL, W - 32)) do
        gfx.text(16, fy, l, FONT_SMALL)
        fy = fy + 16
      end
    else
      fy = fy + 16
    end
    local panelTop = 122
    local boxH = (H - panelTop - 100) / c.optCount
    if boxH > 132 then boxH = 132 end
    for k = 1, c.optCount do
      local o = c.opts[k]
      local y = panelTop + (k - 1) * (boxH + 6)
      if cur == k then
        fillRect(12, y, W - 24, boxH)
        gfx.text(22, y + 6, data.text(o.textOff, o.textLen), FONT_BODY, "w")
        local note = noteLine(k)
        if note ~= "" then gfx.text(22, y + boxH - 40, note, FONT_SMALL, "w") end
        gfx.text(22, y + boxH - 22, costLine(k), FONT_SMALL, "w")
      else
        gfx.text(22, y + 6, data.text(o.textOff, o.textLen), FONT_BODY)
        local note = noteLine(k)
        if note ~= "" then gfx.text(22, y + boxH - 40, note, FONT_SMALL) end
        gfx.text(22, y + boxH - 22, costLine(k), FONT_SMALL)
        gfx.rect(12, y, W - 24, boxH, false, false)
      end
    end
    local greed, police, desperate = engine.punishmentOdds(game)
    local dangers = {}
    if greed > 0 then dangers[#dangers + 1] = string.format("GREED %d%%", greed) end
    if police > 0 then dangers[#dangers + 1] = string.format("RAID %d%%", police) end
    if desperate > 0 then dangers[#dangers + 1] = string.format("DESPERATE %d%%", desperate) end
    local dangerStr = table.concat(dangers, "  ")
    if lastTurn ~= "" then dangerStr = dangerStr .. (dangerStr == "" and "" or "   ") .. "LAST " .. lastTurn end
    gfx.text(16, H - 76, dangerStr, FONT_SMALL)
    gfx.text(16, H - 48, resCounts(game.held), FONT_BODY, "b")
    if statusLine ~= "" then
      gfx.text(16, H - 26, statusLine, FONT_SMALL)
      statusLine = ""
    end
  end

  local function drawOutcome()
    gfx.clear()
    center("YOU CHOSE", 30, FONT_TITLE, "b")
    local c = data.card(game.played)
    if c then
      gfx.text(24, 70, data.text(c.titleOff, c.titleLen), FONT_BODY, "b")
      local o = c.opts[game.playedOption] or { textOff = 0, textLen = 0 }
      gfx.text(24, 96, data.text(o.textOff, o.textLen), FONT_BODY)
    end
    local y = 140
    local function lineOf(counts, sign)
      local parts = {}
      for r = 1, 6 do
        if counts[r] > 0 then parts[#parts + 1] = sign .. counts[r] .. " " .. view.resSymbol(r) end
      end
      return table.concat(parts, "  ")
    end
    local paid, lost, gained = lineOf(game.paid, "-"), lineOf(game.lost, "-"), lineOf(game.gained, "+")
    if paid ~= "" then
      gfx.text(24, y, "PAID  " .. paid, FONT_BODY)
      y = y + 28
    end
    if lost ~= "" then
      gfx.text(24, y, "LOST AT RANDOM  " .. lost, FONT_BODY)
      y = y + 28
    end
    if gained ~= "" then
      gfx.text(24, y, "GAINED  " .. gained, FONT_BODY)
      y = y + 28
    end
    local ds = deckSentence()
    if ds ~= "" then
      for _, l in ipairs(wrap(ds, FONT_BODY, W - 48)) do
        gfx.text(24, y, l, FONT_BODY)
        y = y + 26
      end
    end
    center("TAP TO CONTINUE", H - 60, FONT_SMALL)
  end

  local function drawForesight()
    gfx.clear()
    center("THE NEXT CARDS, IN ORDER", 28, FONT_TITLE, "b")
    if game.mayDiscard then
      gfx.text(24, 62, "TAP A CARD TO DISCARD IT", FONT_SMALL)
      gfx.text(24, 80, "DISCARDS RETURN AT A RESHUFFLE", FONT_SMALL)
    end
    for i = 1, game.seenCount do
      local y = 122 + (i - 1) * 118
      local c = data.card(game.seen[i])
      local out = game.discardMask & (1 << (i - 1)) ~= 0
      local sel = cur == i
      local flags = sel and "w" or ""
      if sel then fillRect(16, y, W - 32, 100) end
      gfx.text(28, y + 8, (out and "OUT " or "KEPT ") .. data.text(c.titleOff, c.titleLen), FONT_BODY, flags)
      if c.flavorLen > 0 then
        gfx.text(28, y + 34, wrap(data.text(c.flavorOff, c.flavorLen), FONT_SMALL, W - 56)[1] or "", FONT_SMALL, flags)
      end
    end
    local y = 122 + game.seenCount * 118 + 6
    if cur == game.seenCount + 1 then
      fillRect(16, y, W - 32, 40)
      center("CONTINUE", y + 8, FONT_BODY, "w")
    else
      center("CONTINUE", y + 8, FONT_BODY)
    end
  end

  local function drawPay()
    gfx.clear()
    center("PAY FOR", 30, FONT_TITLE, "b")
    local c = data.card(game.card)
    local o = c.opts[payK]
    gfx.text(24, 64, data.text(o.textOff, o.textLen), FONT_BODY, "b")
    gfx.text(24, 92, "COST  " .. view.costStr(game, data, payK), FONT_SMALL)
    if payFoodNote then
      gfx.text(24, 112, "A RELIC CAN PAY INSTEAD OF YOUR LAST FOOD", FONT_SMALL)
    end
    local y = 140
    if payNone or #payWays == 0 then
      gfx.text(24, y, "YOU HOLD NO SUSPICION: RELICS WOULD BUY NOTHING", FONT_BODY)
      gfx.text(24, H - 70, "BACK RETURNS", FONT_SMALL)
    else
      for i = 1, #payWays do
        drawRow(y, string.format("%d.  %s", i, view.countsStr(payWays[i])), cur == i)
        y = y + 38
      end
      local y2 = math.max(y + 10, H - 110)
      drawRow(y2, "PAY", cur == #payWays + 1)
      gfx.text(24, y2 + 40, "BACK CANCELS", FONT_SMALL)
    end
  end

  local function drawEnd()
    gfx.clear()
    if game.phase == engine.WON then
      local name = data.godName(game.god + 1):upper()
      center("SUMMONED", 32, FONT_SMALL)
      center(name, 60, FONT_TITLE, "b")
      local g = data.god(game.god + 1)
      local adds = {}
      for _, uid in ipairs(g.unlock) do
        adds[#adds + 1] = data.text(data.card(uid).titleOff, data.card(uid).titleLen)
      end
      gfx.text(24, 110, "The next run's deck adds:", FONT_BODY)
      gfx.text(24, 138, table.concat(adds, ", "), FONT_BODY)
    else
      center("THE CULT DISBANDS", 60, FONT_TITLE, "b")
      local line
      if game.loss == engine.LOSS_GAVEUP then
        line = "Given up. Gods you summon stay."
      elseif game.loss == engine.LOSS_CHOICE then
        local c = data.card(game.card)
        line = (c and data.text(c.titleOff, c.titleLen) or "?") .. " ended the run after " .. game.turn .. " turns."
      else
        line = "The cult fell on turn " .. game.turn .. "."
      end
      gfx.text(24, 110, line, FONT_BODY)
    end
    local y = H - 170
    drawRow(y, "PLAY AGAIN", cur == 1)
    drawRow(y + 44, "MENU", cur == 2)
  end

  local function drawGiveup()
    gfx.clear()
    center("GIVE UP?", 50, FONT_TITLE, "b")
    gfx.text(24, 100, string.format("The run on turn %d ends. It cannot be undone.", game.turn), FONT_BODY)
    drawRow(H - 150, "KEEP PLAYING", cur == 1)
    drawRow(H - 106, "GIVE UP", cur == 2)
  end

  local function drawStartover()
    gfx.clear()
    center("START OVER?", 50, FONT_TITLE, "b")
    gfx.text(24, 100, "Replay the tutorial and keep your gods, or forget", FONT_SMALL)
    gfx.text(24, 120, "everything and begin again.", FONT_SMALL)
    drawRow(H - 190, "REPLAY TUTORIAL", cur == 1)
    drawRow(H - 146, "FORGET ALL", cur == 2)
    drawRow(H - 102, "BACK", cur == 3)
  end

  local GUIDE = {
    { "A TURN", { "Each turn, one card. Pick one of its choices." } },
    { "WHAT YOU HOLD", { "R relic, $ money, C cultist, F food, P prisoner, S suspicion." } },
    { "A CHOICE", { "Pay what is on the left of a choice. Get what is on the right." } },
    { "TWO WAYS TO PAY", { "A choice may have several ways. Pick the one you want." } },
    { "RELICS", { "Relics pay for anything you lack." } },
    { "NOT ENOUGH", { "A choice you cannot pay for is closed. Get more resources first." } },
    { "DANGER", { "16+ held: GREED. 5+ suspicion: a POLICE RAID. No food: DESPERATE MEASURES." } },
    { "CHAINS", { "Some choices add cards to the deck. Follow a chain to a god." } },
    { "WINNING", { "Summon a god to win the run. Summoned gods stay, and bring new cards." } },
  }

  local function drawGuide()
    gfx.clear()
    center(GUIDE[guidePage][1], 46, FONT_TITLE, "b")
    local y = 110
    for _, l in ipairs(GUIDE[guidePage][2]) do
      for _, line in ipairs(wrap(l, FONT_BODY, W - 48)) do
        gfx.text(24, y, line, FONT_BODY)
        y = y + 30
      end
    end
    center(string.format("%d OF %d  -  TAP TO TURN THE PAGE", guidePage, #GUIDE), H - 50, FONT_SMALL)
  end

  -- input -------------------------------------------------------------------
  local function openPay(k)
    payK = k
    payWays = view.choices(game, data, k)
    payNone = view.buysNothing(game, data, k)
    payFoodNote = false
    if #payWays > 1 then
      local fewest = payWays[1][engine.REL]
      for i = 2, #payWays do
        if payWays[i][engine.REL] > fewest then payFoodNote = true break end
      end
    end
    screen = "pay"
    cur = 1
    paySel = 1
  end

  local function pay()
    local k = payK
    local offer = payWays[paySel] or payWays[1]
    engine.choose(game, data, k, offer, rng)
    afterChoose()
  end

  local function onCardConfirm()
    local c = data.card(game.card)
    local k = cur
    if k < 1 or k > c.optCount then return end
    if optionState(k) ~= 2 then
      statusLine = whyNot(k)
      return
    end
    local ways = view.choices(game, data, k)
    if #ways == 0 then
      if view.buysNothing(game, data, k) then
        openPay(k)
      else
        statusLine = whyNot(k)
      end
      return
    end
    if #ways == 1 then
      engine.choose(game, data, k, ways[1], rng)
      afterChoose()
    else
      openPay(k)
    end
  end

  local function screenMax()
    if screen == "card" then
      return data.card(game.card).optCount
    elseif screen == "pay" then
      return #payWays + 1
    elseif screen == "foresight" then
      return game.seenCount + 1
    elseif screen == "menu" then
      return #menuRows()
    elseif screen == "end" or screen == "giveup" then
      return 2
    elseif screen == "startover" then
      return 3
    end
    return 1
  end

  local function redraw()
    if screen == "menu" then
      drawMenu()
    elseif screen == "card" then
      drawCard()
    elseif screen == "pay" then
      drawPay()
    elseif screen == "foresight" then
      drawForesight()
    elseif screen == "outcome" then
      drawOutcome()
    elseif screen == "end" then
      drawEnd()
    elseif screen == "giveup" then
      drawGiveup()
    elseif screen == "startover" then
      drawStartover()
    elseif screen == "guide" then
      drawGuide()
    end
    gfx.present()
  end

  local function menuAct(id)
    if id == "start" then
      if inRun then
        screen = (game.phase == engine.FORESIGHT) and "foresight" or "card"
        cur = 1
      else
        startRun()
      end
    elseif id == "guide" then
      guidePage = 1
      screen = "guide"
    elseif id == "giveup" then
      screen = "giveup"
      cur = 1
    elseif id == "startover" then
      screen = "startover"
      cur = 1
    end
  end

  local function loop()
    while true do
      local ev = input.wait()
      if ev == "back" then
        if screen == "menu" then
          app.exit()
          return
        elseif screen == "outcome" then
          showOutcome = false
          screen = "card"
          persist()
        elseif screen == "end" or screen == "giveup" or screen == "startover" or screen == "guide" then
          screen = "menu"
          cur = 1
        else
          screen = "menu"
          cur = 1
          persist()
        end
        redraw()
      elseif ev == "confirm" then
        if screen == "menu" then
          local rows = menuRows()
          menuAct(rows[cur] and rows[cur].id or "start")
        elseif screen == "guide" then
          if guidePage < #GUIDE then guidePage = guidePage + 1 else screen = "menu" end
        elseif screen == "card" then
          onCardConfirm()
        elseif screen == "pay" then
          if not payNone and #payWays > 0 then
            pay()
          end
        elseif screen == "foresight" then
          if cur == game.seenCount + 1 then
            engine.endForesight(game, data, rng)
            showOutcome = false
            lastTurn = ""
            checkEnd()
            persist()
          elseif game.mayDiscard then
            engine.toggleDiscard(game, cur - 1)
          end
        elseif screen == "outcome" then
          showOutcome = false
          screen = "card"
          cur = 1
          persist()
        elseif screen == "giveup" then
          if cur == 2 then
            engine.giveUp(game)
            endRunScreen()
          else
            screen = "menu"
            cur = 1
          end
        elseif screen == "startover" then
          if cur == 1 then
            engine.replayTutorial(profile)
            persist()
            screen = "menu"
            cur = 1
          elseif cur == 2 then
            engine.startOver(profile)
            persist()
            screen = "menu"
            cur = 1
          else
            screen = "menu"
            cur = 1
          end
        elseif screen == "end" then
          if cur == 1 then
            startRun()
          else
            screen = "menu"
            cur = 1
          end
        end
        redraw()
      elseif ev == "up" or ev == "left" then
        cur = math.max(1, cur - 1)
        if screen == "pay" and cur <= #payWays then paySel = cur end
        redraw()
      elseif ev == "down" or ev == "right" then
        cur = math.min(screenMax(), cur + 1)
        if screen == "pay" and cur <= #payWays then paySel = cur end
        redraw()
      end
    end
  end

  if inRun then
    screen = (game.phase == engine.FORESIGHT) and "foresight" or "card"
  end
  redraw()
  loop()
end

local ok, err = pcall(__main)
if not ok then
  gfx.clear()
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 70), "ui12", "b")
  gfx.present()
  while input.wait() ~= "back" do end
  app.exit()
end