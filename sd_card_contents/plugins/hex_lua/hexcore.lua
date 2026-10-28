-- Hex rules: 11x11 rhombus, no captures, no draws. Black (1) joins the top
-- edge (row 1) to the bottom edge (row 11); White (2) joins the left edge
-- (column 1) to the right edge (column 11). On a full board exactly one
-- colour has connected its two edges, so a win is a single BFS.
local M = {}

local N = 11
local POINTS = N * N
M.N, M.POINTS = N, POINTS
M.BLACK, M.WHITE = 1, 2

-- Neighbour offsets in (row, col) for a flat-top rhombus.
local DR = { -1, -1, 0, 0, 1, 1 }
local DC = { 0, 1, -1, 1, -1, 0 }

local ROW, COL = {}, {}
for i = 1, POINTS do
  ROW[i] = (i - 1) // N + 1
  COL[i] = (i - 1) % N + 1
end
M.ROW, M.COL = ROW, COL

local function index(r, c)
  return (r - 1) * N + c
end
M.index = index

-- Visited marks reused across BFS calls: a stamp per call, no allocation.
local mark, stamp = {}, 0
for i = 1, POINTS do mark[i] = 0 end

local function startEdge(i, p)
  if p == 1 then return ROW[i] == 1 end
  return COL[i] == 1
end

local function endEdge(i, p)
  if p == 1 then return ROW[i] == N end
  return COL[i] == N
end

-- True when colour p has joined its two edges on board b.
local function connected(b, p)
  stamp = stamp + 1
  local stack, n = {}, 0
  for i = 1, POINTS do
    if b[i] == p and startEdge(i, p) then
      n = n + 1
      stack[n] = i
      mark[i] = stamp
    end
  end
  while n > 0 do
    local i = stack[n]
    stack[n] = nil
    n = n - 1
    if endEdge(i, p) then return true end
    local r, c = ROW[i], COL[i]
    for k = 1, 6 do
      local r2, c2 = r + DR[k], c + DC[k]
      if r2 >= 1 and r2 <= N and c2 >= 1 and c2 <= N then
        local j = (r2 - 1) * N + c2
        if b[j] == p and mark[j] ~= stamp then
          mark[j] = stamp
          n = n + 1
          stack[n] = j
        end
      end
    end
  end
  return false
end
M.connected = connected

-- The first empty point that wins for colour p if p plays it, or nil.
function M.winningPoint(b, p)
  for i = 1, POINTS do
    if b[i] == 0 then
      b[i] = p
      local ok = connected(b, p)
      b[i] = 0
      if ok then return i end
    end
  end
  return nil
end

function M.newBoard()
  local b = {}
  for i = 1, POINTS do b[i] = 0 end
  return b
end

-- One-line save form: 121 digits, 0 empty / 1 black / 2 white.
function M.pack(b)
  local t = {}
  for i = 1, POINTS do t[i] = string.char(48 + b[i]) end
  return table.concat(t)
end

-- Returns a board, or nil when the text is not exactly a board.
function M.unpack(s)
  if type(s) ~= "string" or #s ~= POINTS then return nil end
  local b = {}
  for i = 1, POINTS do
    local v = s:byte(i) - 48
    if v < 0 or v > 2 then return nil end
    b[i] = v
  end
  return b
end

function M.other(p)
  return p == 1 and 2 or 1
end

return M
