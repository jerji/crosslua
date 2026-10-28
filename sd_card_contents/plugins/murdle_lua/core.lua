-- Murdle core: deterministic case generator, deduction solver, and clue text. No device API here, so the host tests
-- can drive it (scratch/murdle_logic.lua). Crossplay design: docs/apps/murdle.md (sections 1-2).
-- Model: k suspects, k weapons, k locations. Solution = (wp, lp), two permutations: suspect i has weapon wp[i] and is in
-- location lp[i]. The crime location is Lm (fixed by the murder clue); the murderer is the suspect with lp[i] == Lm.
-- Clue kinds (direct only in v1): SW(s,w,yes) "s had the w" / "s did not have the w"; SL(s,l,yes) likewise for location.
-- Murder clue: "The body was found in the room with <fixture of Lm>." Fixtures are fixed per location in CAST.

local M = {}

M.CAST = {
  suspects  = { "Ada", "Bram", "Cleo", "Dov" },
  weapons   = { "rope", "candlestick", "wrench", "poison" },
  locations = { "library", "kitchen", "garden", "study" },
  fixtures  = { "cold water", "peeling paint", "wet footprints", "a broken window" },
}

-- xorshift32 for deterministic generation from a seed
local function rng_new(seed)
  local s = seed & 0xFFFFFFFF
  if s == 0 then s = 0x9E3779B9 end
  return function(n)
    s = s ~ ((s << 13) & 0xFFFFFFFF); s = s ~ (s >> 17); s = s ~ ((s << 5) & 0xFFFFFFFF)
    return (s % n) + 1
  end
end

local function shuffle(rnd, t)
  for i = #t, 2, -1 do local j = rnd(i); t[i], t[j] = t[j], t[i] end
  return t
end

local function perms(k)
  local out, cur, used = {}, {}, {}
  local function rec(i)
    if i > k then local p = {}; for j = 1, k do p[j] = cur[j] end; out[#out + 1] = p; return end
    for v = 1, k do if not used[v] then used[v] = true; cur[i] = v; rec(i + 1); used[v] = false end end
  end
  rec(1)
  return out
end

-- a clue: { kind = "SW" | "SL", s = suspect, x = weapon or location index, yes = bool }
local function holds(clue, sol)
  local val
  if clue.kind == "SW" then val = (sol.wp[clue.s] == clue.x)
  else val = (sol.lp[clue.s] == clue.x) end
  return val == clue.yes
end

local function count_solutions(k, clues, limit, murder_loc)
  local P = perms(k)
  local n = 0
  for _, wp in ipairs(P) do
    for _, lp in ipairs(P) do
      local sol = { wp = wp, lp = lp }
      local ok = true
      for _, c in ipairs(clues) do if not holds(c, sol) then ok = false; break end end
      if ok then n = n + 1; if n >= limit then return n end end
    end
  end
  return n
end

-- propagation solver: returns true when pure deduction determines every SW and SL cell.
local function propagate_solves(k, clues)
  local SW, SL = {}, {}
  for s = 1, k do SW[s], SL[s] = {}, {} end
  local function set(M, s, x, v)
    if M[s][x] ~= nil and M[s][x] ~= v then return false end
    M[s][x] = v; return true
  end
  for _, c in ipairs(clues) do
    local M = (c.kind == "SW") and SW or SL
    if not set(M, c.s, c.x, c.yes) then return false end
  end
  local changed = true
  while changed do
    changed = false
    for _, M in ipairs({ SW, SL }) do
      -- row rule: a row with one candidate left is that candidate; a true cell clears its row and column
      for s = 1, k do
        local trues, cands = 0, {}
        for x = 1, k do
          if M[s][x] == true then trues = trues + 1
          elseif M[s][x] == nil then cands[#cands + 1] = x end
        end
        if trues == 0 and #cands == 1 then M[s][cands[1]] = true; changed = true end
        if trues > 0 then
          for x = 1, k do if M[s][x] == nil then M[s][x] = false; changed = true end end
        end
      end
      for x = 1, k do
        local trues, cands = 0, {}
        for s = 1, k do
          if M[s][x] == true then trues = trues + 1
          elseif M[s][x] == nil then cands[#cands + 1] = s end
        end
        if trues == 0 and #cands == 1 then M[cands[1]][x] = true; changed = true end
        if trues > 0 then
          for s = 1, k do if M[s][x] == nil then M[s][x] = false; changed = true end end
        end
      end
    end
  end
  for s = 1, k do for x = 1, k do
    if SW[s][x] == nil or SL[s][x] == nil then return false end
  end end
  return true
end

-- every direct clue that is TRUE under the solution, in a stable order
local function pool_for(k, sol)
  local pool = {}
  for s = 1, k do
    for x = 1, k do
      pool[#pool + 1] = { kind = "SW", s = s, x = x, yes = (sol.wp[s] == x) }
      pool[#pool + 1] = { kind = "SL", s = s, x = x, yes = (sol.lp[s] == x) }
    end
  end
  return pool
end

-- generate one case. tier: "elementary" (k=3) or "nosy" (k=4). Returns case or nil, reason.
function M.generate(seed, tier)
  local k = (tier == "nosy") and 4 or 3
  for attempt = 1, 64 do
    local rnd = rng_new(seed * 1000003 + attempt * 7919)
    local P = perms(k)
    local sol = { wp = P[rnd(#P)], lp = P[rnd(#P)] }
    local Lm = rnd(k)   -- crime location
    local pool = shuffle(rnd, pool_for(k, sol))
    local clues = {}
    local n_pool = #pool
    local i = 1
    while count_solutions(k, clues, 2) ~= 1 and i <= n_pool do
      clues[#clues + 1] = pool[i]; i = i + 1
    end
    if count_solutions(k, clues, 2) == 1 then
      -- prune: drop any clue the puzzle still solves without
      local j = 1
      while j <= #clues do
        local trial = {}
        for t = 1, #clues do if t ~= j then trial[#trial + 1] = clues[t] end end
        if count_solutions(k, trial, 2) == 1 then clues = trial else j = j + 1 end
      end
      if propagate_solves(k, clues) then
        -- murderer = the suspect in the crime location
        local murderer
        for s = 1, k do if sol.lp[s] == Lm then murderer = s end end
        return {
          k = k, tier = tier, seed = seed, sol = sol, clues = clues,
          crime_loc = Lm, murderer = murderer,
        }
      end
    end
  end
  return nil, "no case solvable by deduction within 64 attempts"
end

function M.clue_text(c)
  local s = M.CAST.suspects[c.s]
  if c.kind == "SW" then
    local w = M.CAST.weapons[c.x]
    return c.yes and (s .. " had the " .. w .. ".") or (s .. " did not have the " .. w .. ".")
  else
    local l = M.CAST.locations[c.x]
    return c.yes and (s .. " was in the " .. l .. ".") or (s .. " was not in the " .. l .. ".")
  end
end

function M.murder_text(case)
  return "The body was found in the room with " .. M.CAST.fixtures[case.crime_loc] .. "."
end

-- exposed for tests
M.holds = holds
M.count_solutions = count_solutions
M.propagate_solves = propagate_solves
M.perms = perms
return M
