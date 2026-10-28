-- wire.lua — Yahtzee game blob for PLAY NEARBY (40 bytes, spec §4.3, YahtzeeCore.h).
-- card[seat]: 13 boxes as i8 (-1 unscored, else the score) then yahtzeeBonuses u8 (14 bytes a seat),
-- die[5] u8 (faces 1..6), held u8 (bit mask over the five dice), rollsUsed u8 (0..3),
-- turn u8 (the seat to move), rng u32 (carried as 0: the receiver never rolls).
-- Seat 0 is the first mover. The caller maps seats onto its own "mine / theirs" view.

local W = {}

-- cards[seat] = { [1..13] = score or -1, bonuses = n }
function W.pack(cards, die, held, rolls, turnSeat)
  local parts = {}
  for seat = 0, 1 do
    local c = cards[seat]
    for i = 1, 13 do parts[#parts + 1] = string.pack("<i1", c[i]) end
    parts[#parts + 1] = string.pack("<B", c.bonuses)
  end
  for i = 1, 5 do parts[#parts + 1] = string.pack("<B", die[i]) end
  parts[#parts + 1] = string.pack("<BBBI4", held, rolls, turnSeat, 0)
  return table.concat(parts)
end

-- Returns cards, die, held, rolls, turnSeat — or nil for anything not a legal position.
function W.unpack(s)
  if type(s) ~= "string" or #s ~= 40 then return nil end
  local cards = { [0] = {}, [1] = {} }
  local p = 1
  for seat = 0, 1 do
    local c = cards[seat]
    for i = 1, 13 do
      local v = string.unpack("<i1", s, p)
      p = p + 1
      if v < -1 or v > 50 then return nil end
      c[i] = v
    end
    c.bonuses = s:byte(p)
    p = p + 1
  end
  local die = {}
  for i = 1, 5 do
    local v = s:byte(p)
    p = p + 1
    if v < 1 or v > 6 then return nil end
    die[i] = v
  end
  local held, rolls, turnSeat = s:byte(p), s:byte(p + 1), s:byte(p + 2)
  if held > 31 or rolls > 3 or turnSeat > 1 then return nil end
  return cards, die, held, rolls, turnSeat
end

return W
