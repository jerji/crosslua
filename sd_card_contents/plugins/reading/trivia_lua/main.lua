-- TRIVIA for CrossLua: a port of the crossplay trivia app.
--
-- The pack lives on the card at /trivia/pack.dat (the "Trivia" folder, read +
-- write storage grants). pack.state beside it is this device's record of what
-- has been served (SEEN) and rejected (FLAGGED); the difficulty byte is
-- /trivia/prefs, matching the C++ app's own files so the two apps can share a
-- card. Everything else is faithful to the C++ play loop:
--
--   QUIZMASTER  one clue, no options; confirm reveals the answer; the room
--               argues; NEXT deals another. HIDE (once the answer is showing)
--               flags the question so the chooser never serves it again and
--               offers WHY? (a reason) and UNDO.
--   SOLO        four options, scored; score resets on entry and dies with the
--               app -- a bar game's score belongs to the evening.
--   DIFFICULTY  cycles Any -> 1..5 on the front door, saved to /trivia/prefs.
--   SETTINGS    US QUESTIONS (on by default here is OFF, as in the C++: the
--               pack is international by default) and HIDDEN QUESTIONS.
--
-- Deviations from the C++ app, all deliberate:
--   * No GET THE QUESTIONS / SYNC: they need a hardcoded host and network, and
--     port rules forbid both. The no-pack screen says where to put a pack
--     instead, and the sample_pack.dat in this folder is a 6-question starter
--     to copy to Trivia/pack.dat.
--   * US QUESTIONS is a CrossPoint system setting in the C++ app; the Lua
--     sandbox has no settings API, so this port keeps its own copy in
--     data:trivia/us.
--   * No report queue: its header carries a pack id that only SYNC can ever
--     establish, so HIDE records the reason in data:trivia/reports.log
--     instead. The FLAGGED bit itself always lands in pack.state on the card.
--   * Buttons, not touch: confirm/left/right are the footer, up/down move
--     lists. The clue is set in sans18 (the reading serif does not exist in
--     the Lua font set) and wrapped by width.

local function __main()
  local W, H = gfx.size()
  local M, ASIDE_W, ASIDE_GAP, CHROME_H, FOOTER_H = 16, 132, 12, 44, 62
  local FOOTER_TOP = H - 104
  local core = require("core")

  local REASON_ROWS = {
    { label = "WRONG ANSWER", name = "wrong" },
    { label = "MAKES NO SENSE", name = "nonsense" },
    { label = "THE OPTIONS GIVE IT AWAY", name = "giveaway", soloOnly = true },
    { label = "MORE THAN ONE FITS", name = "ambiguous" },
    { label = "OUT OF DATE", name = "outdated" },
    { label = "BROKEN TEXT", name = "broken" },
    { label = "ONLY LOCALS KNOW", name = "regional" },
    { label = "THIS IS A US QUESTION", name = "us", usOnly = true },
    { label = "TOO HARD", name = "hard" },
    { label = "TOO EASY", name = "easy" },
  }

  -- ------------------------------------------------------------------ state
  local pack, st -- set at boot; nil means "no usable pack on the card"
  local difficulty, us_on
  local view = "menu"
  local cursor, s_cursor, r_cursor = 1, 1, 1
  local rng
  local question, current, choices -- current question, its index, solo options
  local revealed, chosen = false, -1
  local score = core.new_score()
  local notice -- {head, body, primary, pfn, second, sfn, third, tfn, back}
  local reason_index, flag_return
  local done = false

  local function load_diff()
    local b = fs.read("sd:Trivia/prefs", 0, 1)
    if b and #b == 1 and b:byte(1) <= core.DIFFICULTIES then return b:byte(1) end
    return 0 -- missing, or a corrupt/future byte: never filter everything out
  end
  local function save_diff(d) fs.write("sd:Trivia/prefs", string.char(d)) end
  local function load_us()
    local s = fs.read("data:trivia/us", 0, 4)
    return s ~= nil and s:sub(1, 1) == "1"
  end
  local function save_us(v) fs.write("data:trivia/us", v and "1" or "0") end
  -- The outbound report queue needs a pack id only SYNC can establish, and
  -- this port has no SYNC. The FLAGGED bit is the real effect; the reason is
  -- a local record so the WHY? tap does something.
  local function log_report(i, reason)
    fs.append("data:trivia/reports.log", tostring(i) .. "\t" .. reason .. "\n")
  end

  -- ------------------------------------------------------------------ boot
  local p, perr = core.open_pack("sd:Trivia/pack.dat")
  if p then
    local s, serr = core.open_state(p, "sd:Trivia/pack.state")
    if s then
      pack, st = p, s
    else
      print("TRIVIA: " .. tostring(serr))
    end
  else
    print("TRIVIA: " .. tostring(perr))
  end
  difficulty = load_diff()
  us_on = load_us()
  rng = core.rng(system.millis() | 1)

  if not pack then
    view = "notice"
    notice = {
      head = "NO QUESTIONS",
      body = "There is no question pack on the card yet. Put a pack.dat into the Trivia folder of the card; this app ships a 6-question sample_pack.dat in its own folder to copy over.",
      primary = "LEAVE",
      pfn = function() done = true end,
      back = "exit",
    }
  end

  -- ------------------------------------------------------------ text layout
  -- gfx.text does not wrap; the clue is prose, so wrap it by measured width
  -- and hard-split only the rare word that is wider than the box.
  local function wrap(str, font, maxw)
    local lines = {}
    local cur = ""
    for w in str:gmatch("%S+") do
      local trial = cur == "" and w or (cur .. " " .. w)
      if gfx.text_width(trial, font) <= maxw then
        cur = trial
      else
        if cur ~= "" then lines[#lines + 1] = cur end
        while gfx.text_width(w, font) > maxw do
          local p = ""
          for _, cp in utf8.codes(w) do
            local t = p .. utf8.char(cp)
            if gfx.text_width(t, font) > maxw then break end
            p = t
          end
          if p == "" then p = utf8.char(utf8.codepoint(w)) end
          lines[#lines + 1] = p
          w = w:sub(#p + 1)
          if w == "" then break end
        end
        cur = w
      end
    end
    if cur ~= "" then lines[#lines + 1] = cur end
    return lines
  end

  -- Draw wrapped lines into a box. The C++ ellipsis glyph does not exist in
  -- these fonts, so an overflowing tail is cut visibly with "...".
  local function draw_block(x, y, h, lines, font, centre, lh)
    local maxl = math.max(1, math.floor(h / lh))
    local truncated = #lines > maxl
    for i = 1, math.min(maxl, #lines) do
      local line = lines[i]
      if i == maxl and truncated then line = line .. "..." end
      if centre then gfx.text(x, y, line, font, "c") else gfx.text(x, y, line, font) end
      y = y + lh
    end
  end

  local function chrome(right)
    gfx.rect(0, 0, W, CHROME_H, true)
    gfx.text(16, 11, "TRIVIA", "sans16", "bw")
    if right then gfx.text(W - 16, 11, right, "sans14", "bwr") end
  end

  -- Difficulty as five pips, like the C++ app; none at "Any" (a filled count
  -- of zero would describe a question that is not being filtered).
  local function draw_pips(y)
    if difficulty <= 0 then return end
    local x = M
    for i = 1, 5 do
      if i <= difficulty then gfx.rect(x, y, 9, 9, true) else gfx.rect(x, y, 9, 9, false) end
      x = x + 16
    end
    gfx.text(x + 6, y - 4, "DIFFICULTY", "small")
  end

  -- --------------------------------------------------------------- footers
  -- The C++ app's hit boxes, mapped onto the buttons:
  --   primary  = confirm   (filled, left, wide)
  --   middle   = left      (outlined, beside the primary)
  --   aside    = right     (outlined, far right; END does not move)
  -- back means END on the play screens, per trivia::backFrom().
  local function footer_y() return FOOTER_TOP + 14 end
  local function draw_aside(label)
    local ax = M + (W - 2 * M) - ASIDE_W
    gfx.rect(ax, footer_y(), ASIDE_W, FOOTER_H, false)
    gfx.text(ax + ASIDE_W / 2, footer_y() + (FOOTER_H - 20) / 2, label, "small", "c")
  end
  local function draw_pair(primary, aside)
    local full = W - 2 * M
    local wide = full - ASIDE_W - ASIDE_GAP
    gfx.rect(M, footer_y(), wide, FOOTER_H, true)
    gfx.text(M + wide / 2, footer_y() + (FOOTER_H - 20) / 2, primary, "small", "cw")
    draw_aside(aside)
  end
  local function draw_trio(primary, middle, aside)
    local full = W - 2 * M
    local wide = full - 2 * ASIDE_W - 2 * ASIDE_GAP
    gfx.rect(M, footer_y(), wide, FOOTER_H, true)
    gfx.text(M + wide / 2, footer_y() + (FOOTER_H - 20) / 2, primary, "small", "cw")
    local mx = M + wide + ASIDE_GAP
    gfx.rect(mx, footer_y(), ASIDE_W, FOOTER_H, false)
    gfx.text(mx + ASIDE_W / 2, footer_y() + (FOOTER_H - 20) / 2, middle, "small", "c")
    draw_aside(aside)
  end

  -- ---------------------------------------------------------------- actions
  local function deal()
    revealed, chosen = false, -1
    question, current, choices = nil, nil, nil
    if pack then
      local solo = view == "solo"
      local i, q = core.choose_next(pack, st, rng,
        { requireChoice = solo, difficulty = difficulty, allowUsCentric = us_on })
      if i and q then
        current, question = i, q
        core.state_set(st, i, core.SEEN)
        if solo then choices = core.build_choices(q, rng) end
      end
    end
  end

  -- HIDE: offered only once the answer is showing -- a question cannot be
  -- called bad until you have seen what it claims. One tap files it.
  local function do_hide()
    if not question then return end
    core.state_set(st, current, core.FLAGGED)
    reason_index = current
    flag_return = view
    log_report(current, "none")
    notice = {
      head = "HIDDEN",
      body = "That question will not come back. " .. st.flagged .. " hidden so far.",
      primary = "NEXT QUESTION",
      pfn = function() view = flag_return; deal() end,
      second = "WHY?",
      sfn = function() view = "reason"; r_cursor = 1 end,
      third = "UNDO",
      tfn = function()
        core.state_clear(st, reason_index, core.FLAGGED)
        log_report(reason_index, "withdrawn")
        reason_index = nil
        view = flag_return
        deal()
      end,
      back = "menu",
    }
    view = "notice"
  end

  local function round_over()
    local body
    if score.asked == 0 then
      body = "No questions answered, so nothing to score."
    else
      body = "You got " .. score.right .. " of " .. score.asked .. "."
    end
    notice = {
      head = "ROUND OVER", body = body,
      primary = "BACK TO MENU", pfn = function() view = "menu"; cursor = 1 end,
      back = "menu",
    }
    view = "notice"
  end

  local function menu_pick()
    if cursor == 1 then
      view = "quizmaster"; deal()
    elseif cursor == 2 then
      score = core.new_score() -- reset on entering solo, never persisted
      view = "solo"; deal()
    elseif cursor == 3 then
      difficulty = (difficulty + 1) % (core.DIFFICULTIES + 1)
      save_diff(difficulty)
    elseif cursor == 4 then
      view = "settings"; s_cursor = 1
    end
  end

  local function settings_pick()
    if s_cursor == 1 then
      us_on = not us_on
      save_us(us_on)
    elseif s_cursor == 2 then
      if st and st.flagged > 0 then
        local cleared = core.state_clear_all(st)
        if cleared > 0 then log_report("unhide-all", tostring(cleared)) end
      end
    else
      view = "menu"; cursor = 1
    end
  end

  local function reason_rows()
    local rows = {}
    local solo = view == "solo" or flag_return == "solo"
    for _, r in ipairs(REASON_ROWS) do
      if not (r.soloOnly and not solo) and not (r.usOnly and us_on) then
        rows[#rows + 1] = r
      end
    end
    return rows
  end

  -- ------------------------------------------------------------------ draw
  local function draw_row(box, label, selected, value)
    if selected then
      gfx.rect(box.x, box.y, box.w, box.h, true)
      gfx.text(box.x + 16, box.y + (box.h - 20) / 2, label, "small", "bw")
      if value then gfx.text(box.x + box.w - 16, box.y + (box.h - 20) / 2, value, "small", "bwr") end
    else
      gfx.rect(box.x, box.y, box.w, box.h, false)
      gfx.text(box.x + 16, box.y + (box.h - 20) / 2, label, "small")
      if value then gfx.text(box.x + box.w - 16, box.y + (box.h - 20) / 2, value, "small", "r") end
    end
  end

  local function draw_menu()
    gfx.clear()
    chrome(nil)
    local top = CHROME_H + 16
    local rowsY = FOOTER_TOP - 62 * 2 - 12 - 18
    local cardH = math.floor((rowsY - top - 16 - 20) / 2)

    -- QUIZMASTER: the filled card; SOLO the outline. Selection is a ring
    -- around the card and a filled row for the two bottom rows.
    local qz = { x = M, y = top, w = W - 2 * M, h = cardH }
    if cursor == 1 then gfx.rect(qz.x - 3, qz.y - 3, qz.w + 6, qz.h + 6, false) end
    gfx.rect(qz.x, qz.y, qz.w, qz.h, true)
    gfx.text(W / 2, qz.y + qz.h / 2 - 34, "QUIZMASTER", "sans18", "bcw")
    gfx.text(W / 2, qz.y + qz.h / 2 + 8, "Read it out, argue, reveal", "small", "cw")

    local sol = { x = M, y = top + cardH + 16, w = W - 2 * M, h = cardH }
    if cursor == 2 then gfx.rect(sol.x - 3, sol.y - 3, sol.w + 6, sol.h + 6, false) end
    gfx.rect(sol.x, sol.y, sol.w, sol.h, false)
    gfx.text(W / 2, sol.y + sol.h / 2 - 34, "SOLO", "sans18", "bc")
    gfx.text(W / 2, sol.y + sol.h / 2 + 8, "Four options, scored", "small", "c")

    draw_row({ x = M, y = rowsY, w = W - 2 * M, h = 62 }, "DIFFICULTY", cursor == 3,
      difficulty == 0 and "Any difficulty" or ("Level " .. difficulty .. " of " .. core.DIFFICULTIES))
    draw_row({ x = M, y = rowsY + 62 + 12, w = W - 2 * M, h = 62 }, "SETTINGS", cursor == 4, nil)

    if pack then
      local line
      if st.seen == 0 then
        line = pack.count == 1 and "1 QUESTION ON THE CARD" or (pack.count .. " QUESTIONS ON THE CARD")
      else
        line = st.seen .. " OF " .. pack.count .. " SEEN"
      end
      gfx.text(W / 2, FOOTER_TOP + 18, line, "small", "c")
    end
    gfx.text(W / 2, H - 16, "UP/DOWN MOVE · CONFIRM · BACK LEAVES", "small", "c")
    gfx.present()
  end

  local function draw_quizmaster()
    gfx.clear()
    chrome(question and revealed and "ANSWER" or "QUESTION")
    draw_pips(CHROME_H + 20)
    local lh = gfx.line_height("sans18")
    local top = CHROME_H + 56
    local h = FOOTER_TOP - top - 24
    local msg = question and question.clue or "No question available. Try another difficulty."
    local lines = wrap(msg, "sans18", W - 2 * M)
    draw_block(W / 2, top, h, lines, "sans18", true, lh)
    if revealed and question then
      gfx.line(M, FOOTER_TOP - 88, W - M, FOOTER_TOP - 88)
      gfx.text(W / 2, FOOTER_TOP - 76, question.answer, "sans18", "bc")
    end
    if question and revealed then
      draw_trio("NEXT", "HIDE", "END")
    else
      draw_pair("REVEAL", "END")
    end
    gfx.text(W / 2, H - 16,
      question and revealed and "CONFIRM NEXT · LEFT HIDE · RIGHT/BACK END"
      or "CONFIRM REVEAL · RIGHT/BACK END", "small", "c")
    gfx.present()
  end

  local function draw_solo()
    gfx.clear()
    chrome(score.asked > 0 and (score.right .. "/" .. score.asked) or nil)
    draw_pips(CHROME_H + 18)
    local lh = gfx.line_height("sans18")
    local optionsH = 4 * 70
    local top = CHROME_H + 54
    local clueH = FOOTER_TOP - top - optionsH - 12
    local msg = question and question.clue or "No multiple-choice question available at this difficulty."
    draw_block(M, top, clueH, wrap(msg, "sans18", W - 2 * M), "sans18", false, lh)

    if question and choices then
      local y = FOOTER_TOP - optionsH
      for i = 1, 4 do
        local box = { x = M, y = y, w = W - 2 * M, h = 62 }
        local isCorrect = chosen >= 0 and i == choices.correct
        local isWrongPick = chosen == i and i ~= choices.correct
        if isCorrect then
          gfx.rect(box.x, box.y, box.w, box.h, true)
        else
          gfx.rect(box.x, box.y, box.w, box.h, false)
          if isWrongPick then gfx.rect(box.x - 2, box.y - 2, box.w + 4, box.h + 4, false) end
        end
        gfx.text(box.x + box.w / 2, box.y + (62 - 20) / 2, choices.options[i], "sans16",
          isCorrect and "cw" or "c")
        -- the player's own pick: a tab that cannot be missed (white on the
        -- solid correct box, black anywhere else)
        if chosen == i then
          if isCorrect then gfx.rect(box.x + 5, box.y + 5, 7, box.h - 10, true, false)
          else gfx.rect(box.x + 5, box.y + 5, 7, box.h - 10, true, true) end
        end
        y = y + 70
      end
    end

    if question and choices and chosen >= 0 then
      draw_trio("NEXT", "HIDE", "END")
    else
      draw_aside("END")
    end
    gfx.text(W / 2, H - 16,
      chosen >= 0 and "CONFIRM NEXT · LEFT HIDE · RIGHT/BACK END"
      or "UP/DOWN OPTION · CONFIRM PICK · RIGHT/BACK END", "small", "c")
    gfx.present()
  end

  local function draw_notice()
    gfx.clear()
    chrome(nil)
    local top = CHROME_H + 96
    gfx.text(W / 2, top, notice.head, "sans18", "bc")
    local lh = gfx.line_height("sans18")
    draw_block(W / 2, top + 88, 260, wrap(notice.body, "sans18", W - 2 * M), "sans18", true, lh)
    -- WHY?/UNDO on their OWN row above the primary, never beside it: the
    -- primary continues the round and must keep its rect and its centre.
    if notice.second or notice.third then
      local full = W - 2 * M
      local y = FOOTER_TOP - 60
      local w = (full - ASIDE_GAP) / 2
      if notice.second then
        gfx.rect(M, y, w, 52, false)
        gfx.text(M + w / 2, y + 16, notice.second, "small", "c")
      end
      if notice.third then
        gfx.rect(M + full - w, y, w, 52, false)
        gfx.text(M + full - w / 2, y + 16, notice.third, "small", "c")
      end
    end
    if notice.primary then
      gfx.rect(M, footer_y(), W - 2 * M, FOOTER_H, true)
      gfx.text(W / 2, footer_y() + (FOOTER_H - 20) / 2, notice.primary, "small", "cw")
    end
    gfx.text(W / 2, H - 16, "BACK", "small", "c")
    gfx.present()
  end

  local function draw_reason()
    gfx.clear()
    chrome("WHY?")
    local rows = reason_rows()
    local y = CHROME_H + 20
    local rowH = 44
    for i = 1, #rows do
      if r_cursor == i then
        gfx.rect(8, y - 4, W - 16, rowH, true)
        gfx.text(20, y, rows[i].label, "small", "bw")
      else
        gfx.text(20, y, rows[i].label, "small")
      end
      y = y + rowH + 6
    end
    gfx.line(M, y - 2, W - M, y - 2)
    if r_cursor == #rows + 1 then
      gfx.rect(8, y - 4, W - 16, rowH, true)
      gfx.text(20, y, "NO REASON", "small", "bw")
    else
      gfx.text(20, y, "NO REASON", "small")
    end
    gfx.text(W / 2, H - 16, "UP/DOWN · CONFIRM · BACK", "small", "c")
    gfx.present()
  end

  local function draw_settings()
    gfx.clear()
    chrome("SETTINGS")
    local rows = {
      { label = "US QUESTIONS", value = us_on and "ON" or "OFF",
        sub = "OFF HIDES CLUES ONLY A US PLAYER WOULD KNOW" },
      { label = "HIDDEN QUESTIONS", value = tostring(st.flagged),
        sub = st.flagged == 0 and "NOTHING IS HIDDEN ON THIS CARD" or "TAP TO SHOW THEM ALL AGAIN" },
      { label = "BACK TO MENU" },
    }
    local y = CHROME_H + 24
    for i, r in ipairs(rows) do
      local sel = s_cursor == i
      if sel then gfx.rect(8, y - 4, W - 16, 56, true) end
      gfx.text(20, y, r.label, "small", sel and "bw" or "")
      if r.value then gfx.text(W - 20, y, r.value, "small", sel and "bwr" or "r") end
      if r.sub then gfx.text(20, y + 22, r.sub, "small", sel and "w" or "") end
      y = y + 62
    end
    gfx.text(W / 2, H - 16, "UP/DOWN · CONFIRM · BACK", "small", "c")
    gfx.present()
  end

  local function draw()
    if view == "menu" then draw_menu()
    elseif view == "quizmaster" then draw_quizmaster()
    elseif view == "solo" then draw_solo()
    elseif view == "notice" then draw_notice()
    elseif view == "reason" then draw_reason()
    elseif view == "settings" then draw_settings() end
  end

  -- ---------------------------------------------------------------- events
  draw()
  while not done do
    local e = input.wait()
    if view == "menu" then
      if e == "up" then cursor = cursor > 1 and cursor - 1 or 4
      elseif e == "down" then cursor = cursor < 4 and cursor + 1 or 1
      elseif e == "confirm" then menu_pick()
      elseif e == "back" then break end
    elseif view == "quizmaster" then
      if e == "confirm" then
        if question then
          if revealed then deal() else revealed = true end
        end
      elseif e == "left" then
        if question and revealed then do_hide() end
      elseif e == "right" or e == "back" then
        view = "menu"; cursor = 1 -- quizmaster keeps no score: it is a person
      end                             -- reading to a room
    elseif view == "solo" then
      if e == "up" then
        if question and chosen < 0 then cursor = cursor > 1 and cursor - 1 or 4 end
      elseif e == "down" then
        if question and chosen < 0 then cursor = cursor < 4 and cursor + 1 or 1 end
      elseif e == "confirm" then
        if question and choices then
          if chosen < 0 then
            chosen = cursor
            core.record_score(score, cursor == choices.correct)
          else
            deal()
          end
        end
      elseif e == "left" then
        if question and chosen >= 0 then do_hide() end
      elseif e == "right" or e == "back" then
        round_over() -- ending the round IS the summary; the score must not be
      end             -- thrown away by an exit that skips it
    elseif view == "notice" then
      if e == "confirm" then
        if notice.pfn then notice.pfn() end
      elseif e == "left" then
        if notice.sfn then notice.sfn() end
      elseif e == "right" then
        if notice.tfn then notice.tfn() end
      elseif e == "back" then
        if notice.back == "exit" then break end
        view = "menu"; cursor = 1
      end
    elseif view == "reason" then
      local total = #reason_rows() + 1 -- the trailing NO REASON row
      if e == "up" then r_cursor = r_cursor > 1 and r_cursor - 1 or total
      elseif e == "down" then r_cursor = r_cursor < total and r_cursor + 1 or 1
      elseif e == "confirm" then
        local rows = reason_rows()
        if r_cursor <= #rows and reason_index then
          log_report(reason_index, rows[r_cursor].name)
        end
        view = "notice" -- the report (no reason or with one) is filed; back
      elseif e == "back" then view = "notice" end
    elseif view == "settings" then
      if e == "up" then s_cursor = s_cursor > 1 and s_cursor - 1 or 3
      elseif e == "down" then s_cursor = s_cursor < 3 and s_cursor + 1 or 1
      elseif e == "confirm" then settings_pick()
      elseif e == "back" then view = "menu"; cursor = 1 end
    end
    draw()
  end
end

local ok, err = pcall(__main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()