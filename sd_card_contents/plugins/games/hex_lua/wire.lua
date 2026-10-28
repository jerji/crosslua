-- wire.lua — Hex game blob for PLAY NEARBY (162 bytes, HexCore.h Game).
-- cell[31]: two bits a point, index = row*11 + col (0-based, C++ order); 0 empty,
--   1 black, 2 white. Lua board index i is the same point at i - 1.
-- parent[125]: the union-find forest over the 121 points plus TOP, BOTTOM, LEFT,
--   RIGHT (121..124). The receiver's win check reads it, so it is rebuilt here
--   from the stones. Connectivity is all that matters, not which node is a root.
-- toMove u8, winner u8 (0 none), lastMove u8 (255 none), reserved u8 (0),
-- moveNumber u16 little-endian (one per stone, Hex has no captures).
local core = require("hexcore")

local W = {}

local N, POINTS = core.N, core.POINTS
local TOP, BOTTOM, LEFT, RIGHT = 121, 122, 123, 124
local NODES = 125
local DR = { -1, -1, 0, 0, 1, 1 }
local DC = { 0, 1, -1, 1, -1, 0 }

function W.pack(g)
  local parent = {}
  for n = 0, NODES - 1 do parent[n] = n end
  local function find(x)
    while parent[x] ~= x do
      parent[x] = parent[parent[x]]
      x = parent[x]
    end
    return x
  end
  local function join(a, b)
    local ra, rb = find(a), find(b)
    if ra ~= rb then parent[rb] = ra end
  end

  local cells, stones = {}, 0
  for k = 0, 30 do cells[k] = 0 end
  for idx = 0, POINTS - 1 do
    local i = idx + 1
    local v = g.cells[i]
    if v ~= 0 then
      stones = stones + 1
      cells[idx // 4] = cells[idx // 4] | (v << ((idx % 4) * 2))
      local r, c = core.ROW[i], core.COL[i]
      for k = 1, 6 do
        local r2, c2 = r + DR[k], c + DC[k]
        if r2 >= 1 and r2 <= N and c2 >= 1 and c2 <= N then
          if g.cells[(r2 - 1) * N + c2] == v then
            join(idx, (r2 - 1) * N + c2 - 1)
          end
        end
      end
      if v == core.BLACK then
        if r == 1 then join(idx, TOP) end
        if r == N then join(idx, BOTTOM) end
      else
        if c == 1 then join(idx, LEFT) end
        if c == N then join(idx, RIGHT) end
      end
    end
  end

  local out = {}
  for k = 0, 30 do out[#out + 1] = string.char(cells[k]) end
  for n = 0, NODES - 1 do out[#out + 1] = string.char(parent[n]) end
  local last = g.last and (g.last - 1) or 255
  out[#out + 1] = string.pack("<BBBBI2", g.turn, g.winner or 0, last, 0, stones)
  return table.concat(out)
end

-- Returns a board record { cells, turn, last, winner, finished }, or nil for
-- anything that is not a legal Hex position shape.
function W.unpack(s)
  if type(s) ~= "string" or #s ~= 162 then return nil end
  local cells = {}
  for idx = 0, POINTS - 1 do
    local v = (s:byte(idx // 4 + 1) >> ((idx % 4) * 2)) & 3
    if v > 2 then return nil end
    cells[idx + 1] = v
  end
  for n = 0, NODES - 1 do
    if s:byte(32 + n) >= NODES then return nil end
  end
  local turn, winner, last = s:byte(157), s:byte(158), s:byte(159)
  if turn ~= 1 and turn ~= 2 then return nil end
  if winner > 2 then return nil end
  if last ~= 255 and last >= POINTS then return nil end
  return {
    cells = cells,
    turn = turn,
    last = last ~= 255 and (last + 1) or nil,
    winner = winner ~= 0 and winner or nil,
    finished = winner ~= 0,
  }
end

return W
