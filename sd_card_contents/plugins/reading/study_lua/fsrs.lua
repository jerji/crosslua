-- FSRS-5 (the scheduler Anki uses when "FSRS" is on). Port of crossplay's StudyFsrs.cpp (MIT).
-- Pure math: no device APIs, so it is unit-tested on the host against golden output from the original C++.
--
--   memory = { s = stability (days to 90% recall), d = difficulty (1..10), learned = bool }
local M = {}

-- Anki's published FSRS-5 defaults (used when a deck ships no optimized parameters).
M.DEFAULT_PARAMS = { 0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192,
                     1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621 }

local DECAY = -0.5
local FACTOR = 0.9 ^ (1 / DECAY) - 1       -- 19/81: makes R(S) exactly 0.9
local MIN_S, MAX_S = 0.01, 36500.0

local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

-- Params live in a closure so apps can swap in per-deck optimized weights. w[i] is the C++ w_[i-1].
function M.new(params, retention, maxInterval)
  local w = params or M.DEFAULT_PARAMS
  retention = retention or 0.9
  maxInterval = maxInterval or 36500
  local f = {}

  local function initialStability(r) return clamp(w[r], MIN_S, MAX_S) end
  local function initialDifficulty(r) return clamp(w[5] - math.exp(w[6] * (r - 1)) + 1, 1, 10) end

  local function nextDifficulty(d, r)
    local delta = -w[7] * (r - 3)
    local damped = d + delta * ((10 - d) / 9)               -- linear damping towards the ceiling
    local reverted = w[8] * initialDifficulty(4) + (1 - w[8]) * damped   -- mean reversion
    return clamp(reverted, 1, 10)
  end

  local function shortTerm(s, r)                              -- same-day review
    local inc = math.exp(w[18] * (r - 3 + w[19]))
    if r >= 3 then if inc < 1 then inc = 1 end else if inc > 1 then inc = 1 end end
    return s * inc
  end

  local function recall(d, s, retr, r)
    local hard = (r == 2) and w[16] or 1
    local easy = (r == 4) and w[17] or 1
    return s * (1 + math.exp(w[9]) * (11 - d) * s ^ (-w[10]) * (math.exp((1 - retr) * w[11]) - 1) * hard * easy)
  end

  local function forget(d, s, retr)
    return w[12] * d ^ (-w[13]) * ((s + 1) ^ w[14] - 1) * math.exp((1 - retr) * w[15])
  end

  function f.retrievability(m, elapsedDays)
    if not m.learned or m.s <= 0 then return 1 end
    local t = elapsedDays < 0 and 0 or elapsedDays
    return (1 + FACTOR * t / m.s) ^ DECAY
  end

  -- Apply a review; returns the new memory. rating: 1 Again, 2 Hard, 3 Good, 4 Easy. elapsed = whole days since last review.
  function f.review(m, rating, elapsed)
    local out = { learned = true }
    if not m.learned then
      out.s, out.d = initialStability(rating), initialDifficulty(rating)
      return out
    end
    if elapsed <= 0 then
      out.s = shortTerm(m.s, rating)
    else
      local retr = f.retrievability(m, elapsed)
      if rating == 1 then
        local forgotten = forget(m.d, m.s, retr)
        out.s = forgotten < m.s and forgotten or m.s           -- a lapse must never be worth more than not lapsing
      else
        out.s = recall(m.d, m.s, retr, rating)
      end
    end
    out.s = clamp(out.s, MIN_S, MAX_S)
    out.d = nextDifficulty(m.d, rating)
    return out
  end

  -- Days until retrievability falls to the desired retention (inverse of the forgetting curve).
  function f.intervalDays(m)
    if not m.learned or m.s <= 0 then return 1 end
    local days = (m.s / FACTOR) * (retention ^ (1 / DECAY) - 1)
    local rounded = math.floor(days + 0.5)
    if rounded < 1 then return 1 end
    return rounded > maxInterval and maxInterval or rounded
  end

  return f
end

return M
