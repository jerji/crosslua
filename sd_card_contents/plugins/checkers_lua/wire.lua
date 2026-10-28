-- wire.lua — Checkers game blob for PLAY NEARBY (67 bytes, CheckersCore.h).
-- cell[0..63] one byte a square, index = rank*8 + file (0-based, row 0 = dark's
-- back rank): bitmask PIECE 1, DARK 2, KING 4, 0 empty. Then turn u8 (0 light,
-- 1 dark), idlePlies u8 (the draw counter), pad0 u8 (always 0).
-- Lua cell[] is 1-based; the blob is 0-based.
local W = {}

local PIECE, DARK, KING = 1, 2, 4

function W.pack(g)
  local t = {}
  for i = 1, 64 do t[i] = string.char(g.cell[i]) end
  return table.concat(t) .. string.pack("<BBB", g.turn, g.idle, 0)
end

-- Returns a game table, or nil when the blob is not a legal position shape.
function W.unpack(s)
  if type(s) ~= "string" or #s ~= 67 then return nil end
  local cell = {}
  for i = 1, 64 do
    local v = s:byte(i)
    if v ~= 0 and (v & PIECE) == 0 then return nil end
    if v > (PIECE | DARK | KING) then return nil end
    cell[i] = v
  end
  local turn, idle = s:byte(65), s:byte(66)
  if turn > 1 then return nil end
  return { cell = cell, turn = turn, idle = idle }
end

return W
