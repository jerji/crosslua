-- Learning steps on top of FSRS: the part of Anki that is not FSRS. Port of crossplay's StudyScheduler.cpp (MIT).
-- FSRS answers "how many days"; this answers "what happens in the next ten minutes".
--
--   card = { state = 0 new | 1 learning | 2 review | 3 relearning | 4 suspended,
--            step = index in the step list, due = day number, dueMin = minute of that day (learning cards only),
--            s, d = FSRS memory, reps, lapses, last = day of last review (-1 never) }
local fsrs_mod = require("fsrs")

local M = {}
M.AGAIN, M.HARD, M.GOOD, M.EASY = 1, 2, 3, 4
M.NEW, M.LEARNING, M.REVIEW, M.RELEARNING, M.SUSPENDED = 0, 1, 2, 3, 4

local MIN_PER_DAY = 1440

-- Anki's out-of-the-box steps, in minutes.
function M.default_steps() return { learn = { 1, 10 }, relearn = { 10 } } end

function M.new_card() return { state = 0, step = 0, due = 0, dueMin = 0, s = 0, d = 0, reps = 0, lapses = 0, last = -1 } end

local function stepMinutes(steps, index)
  local n = #steps
  if n == 0 then return 0 end
  local i = index < 0 and 0 or (index >= n and n - 1 or index)
  local minutes = math.floor(steps[i + 1] + 0.5)
  return minutes < 1 and 1 or minutes
end

-- Hard inside a step list is halfway to the next step (1.5x the step when it is the last): Anki's own rule.
local function hardStepMinutes(steps, index)
  local n = #steps
  if n == 0 then return 0 end
  local i = index < 0 and 0 or (index >= n and n - 1 or index)
  local cur = steps[i + 1]
  local delay = (i + 1 < n) and (cur + steps[i + 2]) / 2 or cur * 1.5
  local minutes = math.floor(delay + 0.5)
  return minutes < 1 and 1 or minutes
end

local function memory(card)
  return { s = card.s, d = card.d, learned = card.s > 0 and card.d > 0 }   -- never trust the state byte alone
end

function M.is_due(card, today, nowMinute)
  local st = card.state
  if st == 4 then return false end
  if st == 0 then return true end
  if st == 1 or st == 3 then
    if card.due ~= today then return card.due < today end
    return card.dueMin <= nowMinute
  end
  return card.due <= today
end

-- scheduler = M.new(steps?, fsrs?). answer() returns outcome = { card, delayMinutes, intervalDays, graduated }.
function M.new(steps, fsrs)
  steps = steps or M.default_steps()
  fsrs = fsrs or fsrs_mod.new()
  local sc = {}

  function sc.answer(card, rating, today, nowMinute)
    local out = { card = {}, delayMinutes = 0, intervalDays = 0, graduated = false }
    for k, v in pairs(card) do out.card[k] = v end
    local c = out.card

    local before = memory(card)
    local elapsed = card.last < 0 and 0 or (today - card.last)
    local after = fsrs.review(before, rating, elapsed)
    c.s, c.d = after.s, after.d
    c.last = today
    if c.reps < 65535 then c.reps = c.reps + 1 end

    local state = card.state
    local wasReview = state == 2
    local inRelearn = state == 3
    local inLearn = state == 1 or state == 0

    local useRelearn = inRelearn or (wasReview and rating == 1)
    local list = useRelearn and steps.relearn or steps.learn
    local count = #list

    local nextStep = -1                      -- -1 = graduate to day-scale review
    if wasReview then
      if rating == 1 then
        if c.lapses < 65535 then c.lapses = c.lapses + 1 end
        nextStep = count > 0 and 0 or -1
      end
    elseif inRelearn or inLearn then
      if rating == 1 then
        nextStep = count > 0 and 0 or -1
      elseif rating == 2 then
        nextStep = count > 0 and (state == 0 and 0 or card.step) or -1
      elseif rating == 3 then
        if state == 0 then nextStep = count > 1 and 1 or -1
        else nextStep = (card.step + 1 < count) and card.step + 1 or -1 end
      else
        nextStep = -1                        -- Easy always leaves the step list
      end
    end

    if nextStep < 0 then
      c.state, c.step = 2, 0
      out.intervalDays = fsrs.intervalDays(after)
      c.due = today + out.intervalDays
      c.dueMin = 0
      out.graduated = not wasReview
      return out
    end

    c.state = (wasReview or inRelearn) and 3 or 1
    c.step = nextStep
    out.delayMinutes = (rating == 2) and hardStepMinutes(list, nextStep) or stepMinutes(list, nextStep)
    local dueAt = nowMinute + out.delayMinutes
    c.due = today + dueAt // MIN_PER_DAY
    c.dueMin = dueAt % MIN_PER_DAY
    return out
  end

  -- What each of the four buttons would do (for the labels under them): returns { [1..4] = outcome }.
  function sc.preview(card, today, nowMinute)
    local o = {}
    for r = 1, 4 do o[r] = sc.answer(card, r, today, nowMinute) end
    return o
  end

  return sc
end

-- Anki-style delay label for a button: "10m", "3h", "1d", "21d", "2.5mo", "1.2y".
function M.format_delay(minutes, days)
  if minutes and minutes > 0 then
    if minutes < 60 then return minutes .. "m" end
    return ((minutes + 30) // 60) .. "h"
  end
  if days < 1 then return "1d" end
  if days < 31 then return days .. "d" end
  if days < 365 then return ("%.1fmo"):format(days / 30.4) end
  return ("%.1fy"):format(days / 365.0)
end

return M
