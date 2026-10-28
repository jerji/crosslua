-- underhand_lua/view.lua
-- What the screens show: the ways a choice can be paid (the crossplay
-- view::payments / keepChoices, ported), the chips for an option line, and
-- small text helpers. Rendering itself lives in main.lua.
local M = {}
local engine = require("engine")

-- OptionModel::satisfiability-free payment enumeration (view::payments):
-- every exact way to pay option k, relics making up the rest. Returns
-- all kept ways (up to 64) and the total found.
function M.payments(game, cards, k)
  if not engine.affordable(game, cards, k) then return {}, 0 end
  local card = cards.card(game.card)
  local o = card.opts[k]
  local need, held = game.cost[k], game.held
  local function upTo(a, b) if a < b then return a end return b end
  local shared = need[engine.CULTIST] + need[engine.PRISONER]
  local all, found = {}, 0
  for money = upTo(held[engine.MONEY], need[engine.MONEY]), 0, -1 do
    for food = upTo(held[engine.FOOD], need[engine.FOOD]), 0, -1 do
      for suspicion = upTo(held[engine.SUS], need[engine.SUS]), 0, -1 do
        local mostPrisoners = upTo(held[engine.PRISONER], o.swap and shared or need[engine.PRISONER])
        for prisoners = mostPrisoners, 0, -1 do
          local mostCultists = upTo(held[engine.CULTIST], o.swap and (shared - prisoners) or need[engine.CULTIST])
          for cultists = mostCultists, 0, -1 do
            local people
            if o.swap then
              people = shared - prisoners - cultists
            else
              people = (need[engine.CULTIST] - cultists) + (need[engine.PRISONER] - prisoners)
            end
            local relics = need[engine.REL]
              + (need[engine.MONEY] - money) + (need[engine.FOOD] - food)
              + (need[engine.SUS] - suspicion) + people
            if relics <= held[engine.REL] then
              if found < 64 then
                all[found + 1] = {
                  relics, money, cultists, food, prisoners, suspicion,
                }
              end
              found = found + 1
            end
          end
        end
      end
    end
  end
  -- Ways that spend a relic on suspicion go last; then fewest relics first,
  -- keeping the walk's order otherwise.
  local function later(a, b)
    local aS = need[engine.SUS] - a[engine.SUS]
    local bS = need[engine.SUS] - b[engine.SUS]
    if aS ~= bS then return aS > bS end
    return a[engine.REL] > b[engine.REL]
  end
  local kept = found < 64 and found or 64
  for i = 2, kept do
    local j = i
    while j > 1 and later(all[j - 1], all[j]) do
      all[j - 1], all[j] = all[j], all[j - 1]
      j = j - 1
    end
  end
  local out = {}
  for i = 1, kept do out[i] = all[i] end
  return out, found
end

-- view::keepChoices: the ways worth offering.
function M.choices(game, cards, k)
  local all, found = M.payments(game, cards, k)
  local kept = found < 64 and found or 64
  local need, held = game.cost[k], game.held
  local option = cards.card(game.card).opts[k]
  local asked = need[engine.SUS] > 0 and need[engine.SUS] or 0
  local spendable = asked < held[engine.SUS] and asked or held[engine.SUS]
  local fewest = -1
  for i = 1, kept do
    if all[i][engine.SUS] >= spendable and (fewest < 0 or all[i][engine.REL] < fewest) then
      fewest = all[i][engine.REL]
    end
  end
  if fewest < 0 then return {} end
  -- An empty hand invites Desperate Measures wherever anything is rolled at
  -- all, which is neither in the tutorial nor after a punishment card.
  local _, _, des0 = engine.punishmentOdds(game, { 0, 0, 0, 0, 0, 0 })
  local rolled = des0 > 0 and option.win < 0 and not option.lose
  local function keepsOne(way)
    return held[engine.FOOD] - way[engine.FOOD] + game.gain[k][engine.FOOD] == 1
  end
  local foodRelics = -1
  if rolled and need[engine.FOOD] > 0 then
    local leavesFood = false
    for i = 1, kept do
      if all[i][engine.SUS] >= spendable and all[i][engine.REL] == fewest then
        if held[engine.FOOD] - all[i][engine.FOOD] + game.gain[k][engine.FOOD] >= 1 then
          leavesFood = true
          break
        end
      end
    end
    if not leavesFood then
      for i = 1, kept do
        if all[i][engine.SUS] >= spendable and all[i][engine.REL] > fewest and keepsOne(all[i]) then
          if foodRelics < 0 or all[i][engine.REL] < foodRelics then foodRelics = all[i][engine.REL] end
        end
      end
    end
  end
  local food = {}
  if foodRelics >= 0 then
    for i = 1, kept do
      if all[i][engine.SUS] >= spendable and all[i][engine.REL] == foodRelics and keepsOne(all[i]) then
        food[#food + 1] = all[i]
      end
    end
  end
  local out = {}
  for i = 1, kept do
    if all[i][engine.SUS] >= spendable and all[i][engine.REL] == fewest then
      out[#out + 1] = all[i]
    end
  end
  for i = 1, #food do out[#out + 1] = food[i] end
  return out
end

-- view::buysNothing: paying would spend relics and change nothing.
function M.buysNothing(game, cards, k)
  local card = cards.card(game.card)
  if not card or k < 1 or k > card.optCount then return false end
  local asked = game.cost[k][engine.SUS]
  if asked <= 0 or game.held[engine.SUS] > 0 then return false end
  local before = select(1, engine.punishmentOdds(game, game.held))
  if before > 0 then
    local pay = {}
    if not engine.suggest(game, cards, k, pay) then return false end
    local after = { game.held[1] - pay[1], game.held[2] - pay[2], game.held[3] - pay[3],
      game.held[4] - pay[4], game.held[5] - pay[5], game.held[6] - pay[6] }
    if select(1, engine.punishmentOdds(game, after)) < before then return false end
  end
  for r = 1, 6 do
    if game.gain[k][r] > 0 then return false end
  end
  local o = card.opts[k]
  return o.addCount == 0 and o.rollCount == 0 and not o.foresight and o.win < 0 and not o.lose
end

-- ---------------------------------------------------------------- display
local RES = { "R", "$", "C", "F", "P", "S" }
local RNAMES = { "relic", "money", "cultist", "food", "prisoner", "suspicion" }

function M.resSymbol(r) return RES[r] or "?" end
function M.resName(r) return RNAMES[r] or "?" end

-- "2 $", "1 R 1 $"; counts of 0 skipped. `plus` prefixes with +.
function M.countsStr(counts, plus)
  local parts = {}
  for r = 1, 6 do
    local n = counts[r]
    if n ~= 0 then
      local sign = ""
      if plus and n > 0 then sign = "+" end
      parts[#parts + 1] = sign .. n .. " " .. RES[r]
    end
  end
  return table.concat(parts, "  ")
end

-- The card's own cost as stated: "-1 C/P", "-2 $", "AT RANDOM n".
function M.costStr(game, cards, k)
  local card = cards.card(game.card)
  local o = card.opts[k]
  local cost = game.cost[k]
  local parts = {}
  for r = 1, 6 do
    local n = cost[r]
    if n > 0 and n ~= engine.KON then
      -- cultist and prisoner are shown once, combined, when swapped
      if not (o.swap and (r == engine.CULTIST or r == engine.PRISONER)) then
        parts[#parts + 1] = "-" .. n .. " " .. RES[r]
      end
    end
  end
  if o.swap then
    local n = 0
    for _, r in ipairs({ engine.CULTIST, engine.PRISONER }) do
      local c = cost[r]
      if c > 0 and c ~= engine.KON then n = n + c end
    end
    if n > 0 then parts[#parts + 1] = "-" .. n .. " C/P" end
  end
  if o.randomCost > 0 then parts[#parts + 1] = "AT RANDOM " .. o.randomCost end
  if #parts == 0 then
    -- a cost of none: only "ONLY WITH NO" can be shown; keep it wordless
    return ""
  end
  return table.concat(parts, "  ")
end

function M.gainStr(game, cards, k)
  local parts = {}
  for r = 1, 6 do
    local n = game.gain[k][r]
    if n > 0 then parts[#parts + 1] = "+" .. n .. " " .. RES[r] end
  end
  return table.concat(parts, "  ")
end

-- What else the option does, as the design's note line.
function M.noteStr(game, cards, k)
  local o = cards.card(game.card).opts[k]
  local parts = {}
  for a = 1, o.addCount do
    local title = cards.text(cards.card(o.adds[a][1]).titleOff, cards.card(o.adds[a][1]).titleLen)
    local n = o.adds[a][2]
    parts[#parts + 1] = "ADDS " .. n .. " x " .. title
  end
  if o.rollCount > 0 then parts[#parts + 1] = "ADDS 1 AT RANDOM" end
  if o.win >= 0 then parts[#parts + 1] = "SUMMONS " .. cards.godName(o.win + 1) end
  if o.lose then parts[#parts + 1] = "ENDS THE RUN" end
  if o.foresight then
    parts[#parts + 1] = o.discard and "SEE THE NEXT 3, DISCARD ANY" or "SEE THE NEXT 3 CARDS"
  end
  return table.concat(parts, "  ")
end

-- Word-wrap to a pixel width using the device font metrics.
function M.wrap(text, font, maxW)
  local out = {}
  local line = ""
  local lineW = 0
  local spaceW = 0
  for word in text:gmatch("%S+") do
    local w = gfx.text_width(word, font) or (#word * 8)
    if spaceW == 0 then spaceW = gfx.text_width(" ", font) or 8 end
    if lineW > 0 and lineW + spaceW + w > maxW then
      out[#out + 1] = line
      line = word
      lineW = w
    else
      if lineW > 0 then line = line .. " "; lineW = lineW + spaceW end
      line = line .. word
      lineW = lineW + w
    end
  end
  out[#out + 1] = line
  return out
end

return M