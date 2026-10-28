-- wire.lua — Knucklebones game blob for PLAY NEARBY (24 bytes, spec §4.3, KnucklebonesCore.h).
-- grid[seat][column][row] (3x3 per seat, 0-based row 0 = the near end, 0 = empty), then
-- turn u8 (the seat whose turn it is), die u8 (the value rolled this turn, 0 = none),
-- rng u32 (carried as 0: the receiver never rolls, the die is already in the state).
-- Seat 0 is the first mover. The caller maps seats to its own "mine / theirs" view.

local W = {}

-- seatGrids[seat] = { [col] = { v1, v2, ... } } with v1 at the near end.
function W.pack(seatGrids, turnSeat, die)
  local out = {}
  for seat = 0, 1 do
    for col = 1, 3 do
      local column = seatGrids[seat][col]
      for row = 1, 3 do
        out[#out + 1] = string.char(column[row] or 0)
      end
    end
  end
  out[#out + 1] = string.char(turnSeat, die or 0)
  out[#out + 1] = string.pack("<I4", 0)
  return table.concat(out)
end

-- Returns seatGrids, turnSeat, die — or nil when the blob is not a legal position
-- (values out of 0..6, a gap under a die, or a turn/die out of range).
function W.unpack(s)
  if type(s) ~= "string" or #s ~= 24 then return nil end
  local seatGrids = { [0] = {}, [1] = {} }
  local i = 1
  for seat = 0, 1 do
    for col = 1, 3 do
      local column = {}
      local gap = false
      for row = 1, 3 do
        local v = s:byte(i)
        i = i + 1
        if v > 6 then return nil end
        if v == 0 then
          gap = true
        else
          if gap then return nil end   -- a column is always full from the near end up
          column[#column + 1] = v
        end
      end
      seatGrids[seat][col] = column
    end
  end
  local turnSeat, die = s:byte(19), s:byte(20)
  if turnSeat > 1 or die > 6 then return nil end
  return seatGrids, turnSeat, die
end

return W
