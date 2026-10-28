-- Study: spaced-repetition flashcards (FSRS-5) for the X4. Decks are tab-separated text files; see deck.lua.
--   Review:  Confirm = show answer, Confirm = Good.  Back = Again, Left = Hard, Right = Easy.  (Up = Again, Down = Good)
local sched = require("sched")
local store = require("store")
local deck = require("deck")
local ui = require("ui")

local NEW_PER_DAY, REVIEWS_PER_DAY = 10, 100

-- Optional memory trace into the device log: create an (empty) file data:trace.flag on the card to turn it on.
local DEBUG = fs.exists("data:trace.flag")
local function dbg(tag)
  if not DEBUG then return end
  local used, peak, budget = system.lua_mem()
  local free, minfree = system.heap()
  print(("MEM %-12s lua %d/%d of %d | device free %d min %d"):format(tag, used, peak, budget, free, minfree))
end
local sc = sched.new()

-- ---------------------------------------------------------------- time
local function days_from_civil(y, m, d)                   -- days since 1970-01-01 (Howard Hinnant's algorithm)
  if m <= 2 then y = y - 1 end
  local era = (y >= 0 and y or y - 399) // 400
  local yoe = y - era * 400
  local doy = (153 * ((m + 9) % 12) + 2) // 5 + d - 1
  return era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
end

-- today (day number), minute of day, hasClock. Without a trusted clock the day is frozen at the last one we saw, so
-- review intervals stop advancing instead of corrupting; the header says "no clock".
local function clock(meta)
  local d = time.date()
  if d then
    local day = days_from_civil(d.year, d.month, d.day)
    meta.lastDay = day
    return day, d.hour * 60 + d.min, true
  end
  return meta.lastDay or 20000, (system.millis() // 60000) % 1440, false
end

-- ---------------------------------------------------------------- screens
local W, H = gfx.size()
local presents = 0
local function present()
  presents = presents + 1
  gfx.present(presents % 10 == 0 and "half" or "fast")     -- a cleaner refresh every few cards
end

local function message(title, lines, hints)
  gfx.clear()
  local y = ui.header(title)
  local mid = (H - ui.HINT_H - y) // 2 - (#lines * 30) // 2
  for i, l in ipairs(lines) do gfx.text(W // 2, y + mid + (i - 1) * 30, l, "ui12", "c") end
  ui.hint_bar(hints or { "Back", "", "", "" })
  present()
end

local function body_area() return 52, H - ui.HINT_H - 52 end  -- y, height of the card area

local function draw_card(h, num, q, a, showAnswer, counts, hasClock, preview)
  gfx.clear()
  local right = ("%d new  %d learn  %d due"):format(counts.new, counts.learn, counts.review)
  if not hasClock then right = "no clock  " .. right end
  ui.header(h.name, right)
  local by, bh = body_area()
  local pad = 24
  if not showAnswer then
    local font, lines, lh = ui.fit(q, W - 2 * pad, bh - 16)
    ui.centered_block(lines, font, lh, 0, by, W, bh)
    ui.hint_bar({ "Menu", "Show", "", "" })
  else
    -- question small on top, answer big below
    local qfont, qlines, qlh = ui.fit(q, W - 2 * pad, bh // 3, "i")
    ui.left_block(qlines, "sans12", gfx.line_height("sans12") + 2, pad, by + 4, "i")
    local qh = math.min(#qlines, 3) * (gfx.line_height("sans12") + 2)
    gfx.line(pad, by + qh + 14, W - pad, by + qh + 14)
    local ay = by + qh + 22
    local font, lines, lh = ui.fit(a, W - 2 * pad, bh - qh - 30)
    ui.centered_block(lines, font, lh, 0, ay, W, bh - qh - 30)
    local f = sched.format_delay
    ui.hint_bar({ "Again", "Good", "Hard", "Easy" },
      { f(preview[1].delayMinutes, preview[1].intervalDays), f(preview[3].delayMinutes, preview[3].intervalDays),
        f(preview[2].delayMinutes, preview[2].intervalDays), f(preview[4].delayMinutes, preview[4].intervalDays) })
  end
  present()
end

-- ---------------------------------------------------------------- one deck session
local function study(d)
  dbg("study-start")
  message(d.name, { "Opening deck..." })
  local h, err = store.open(d)
  dbg("opened")
  if not h then message("Error", { tostring(err) }) input.wait() return end
  local meta = h.meta
  local today, nowMin, hasClock = clock(meta)
  if not meta.newToday or meta.newToday.day ~= today then meta.newToday = { day = today, n = 0 } end
  local q = store.scan(h, today, nowMin, math.max(0, NEW_PER_DAY - meta.newToday.n), REVIEWS_PER_DAY)
  dbg("scanned")
  local pending = {}                                     -- {num, absDue} learning cards re-queued this session
  local reviewed = 0

  local function counts()
    return { new = #q.new, learn = #pending + #q.learn, review = #q.review }
  end

  while true do
    today, nowMin, hasClock = clock(meta)
    local nowAbs = today * 1440 + nowMin
    -- pick the next card: due learning > learning from before > reviews > new
    local num, source
    local best
    for i, p in ipairs(pending) do if p[2] <= nowAbs and (not best or p[2] < pending[best][2]) then best = i end end
    if best then num, source = pending[best][1], "pending"; table.remove(pending, best)
    elseif #q.learn > 0 then num, source = table.remove(q.learn, 1), "learn"
    elseif #q.review > 0 then num, source = table.remove(q.review, 1), "review"
    elseif #q.new > 0 then num, source = table.remove(q.new, 1), "new" end

    if not num then
      if #pending > 0 then                                -- only learning cards waiting for their delay
        local soonest = pending[1][2]
        for _, p in ipairs(pending) do soonest = math.min(soonest, p[2]) end
        message(h.name, { "Next card in " .. math.max(1, soonest - nowAbs) .. " min", "", "Confirm: study now" },
          { "Menu", "Now", "", "" })
        local ev = input.wait(30000)
        if ev == "back" then store.save_meta(h) return end
        if ev == "confirm" or ev == "down" then       -- study ahead: pull the soonest card forward
          local bi = 1
          for i, p in ipairs(pending) do if p[2] < pending[bi][2] then bi = i end end
          pending[bi][2] = nowAbs
        end
      else
        store.save_meta(h)
        message(h.name, { "All done for today!", reviewed .. " cards reviewed" }, { "Menu", "", "", "" })
        while input.wait() ~= "back" do end
        return
      end
    else
      local card = store.get(h, num)
      local qtext, atext = store.text(h, num)
      -- unreadable record or line: skip it rather than loop forever
      if card and qtext then
        local c = counts()                                  -- counts exclude the card in hand: add it back (Anki shows it)
        if source == "new" then c.new = c.new + 1 elseif source == "review" then c.review = c.review + 1
        else c.learn = c.learn + 1 end
        dbg("pre-draw")
        draw_card(h, num, qtext, atext, false, c, hasClock)
        dbg("drawn")
        local ev
        repeat ev = input.wait() until ev == "confirm" or ev == "down" or ev == "back"
        if ev == "back" then
          -- put it back where it was so nothing is lost, then leave
          store.save_meta(h)
          return
        end
        local preview = sc.preview(card, today, nowMin)
        draw_card(h, num, qtext, atext, true, c, hasClock, preview)
        local rating
        repeat
          ev = input.wait()
          rating = (ev == "back" or ev == "up") and 1 or (ev == "left") and 2 or (ev == "confirm" or ev == "down") and 3
              or (ev == "right") and 4 or nil
        until rating
        local out = preview[rating]
        local ok, perr = store.put(h, num, out.card)
        if not ok then message("Save failed", { tostring(perr) }) input.wait() return end
        reviewed = reviewed + 1
        if card.state == 0 then meta.newToday.n = meta.newToday.n + 1; store.save_meta(h) end
        if out.card.state == 1 or out.card.state == 3 then
          pending[#pending + 1] = { num, today * 1440 + nowMin + out.delayMinutes }
        end
      end
    end
  end
end

-- ---------------------------------------------------------------- deck list
local function deck_summary(d)
  local h = store.open(d)
  if not h then return "unreadable" end
  local today, nowMin = clock(h.meta)
  local nl = math.max(0, NEW_PER_DAY - ((h.meta.newToday and h.meta.newToday.day == today) and h.meta.newToday.n or 0))
  local q = store.scan(h, today, nowMin, nl, REVIEWS_PER_DAY)
  return ("%d new   %d learn   %d due   (%d cards)"):format(q.counts.new, q.counts.learn, q.counts.review, h.count)
end

dbg("loaded")
local decks = deck.list()
if #decks == 0 then
  message("Study", { "No decks found.", "Put .tsv files in", "/.crosslua/data/study_lua/decks/" })
  while input.wait() ~= "back" do end
  return
end

local sel = 1
local items
while true do
  if not items then
    items = {}
    message("Study", { "Loading decks..." })
    for i, d in ipairs(decks) do items[i] = { title = d.name, sub = deck_summary(d) } end
  end
  gfx.clear()
  local y = ui.header("Study", #decks .. (#decks == 1 and " deck" or " decks"))
  ui.list(items, sel, y + 4, H - ui.HINT_H - 4)
  ui.hint_bar({ "Exit", "Open", "Prev", "Next" })
  present()
  local ev = input.wait()
  if ev == "back" then return
  elseif ev == "up" or ev == "left" then sel = (sel - 2) % #decks + 1
  elseif ev == "down" or ev == "right" then sel = sel % #decks + 1
  elseif ev == "confirm" then
    study(decks[sel])
    items = nil
  end
end
