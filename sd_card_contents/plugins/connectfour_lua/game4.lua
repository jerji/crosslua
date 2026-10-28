-- game4.lua — Connect Four rules, pure Lua (no device calls).
-- Port of crossplay/src/apps_local/connectfour/ConnectFourCore.h.
-- Board storage: board[column][row], 1-based, row 1 at the BOTTOM (gravity
-- scans from row 1 up). Screen drawing flips the row.
-- Light always opens. drop() settles the outcome BEFORE handing the turn
-- over, so a win keeps the turn with the winner (C++ comment: a winner that
-- passed the turn on would announce the wrong name on the result screen).

local M = {}

local COLS, ROWS, LINE = 7, 6, 4
local EMPTY, LIGHT, DARK = 0, 1, 2

M.COLS, M.ROWS, M.LINE = COLS, ROWS, LINE
M.EMPTY, M.LIGHT, M.DARK = EMPTY, LIGHT, DARK

local function other(side) return side == LIGHT and DARK or LIGHT end

local function newGame()
  local board = {}
  for c = 1, COLS do
    board[c] = {}
    for r = 1, ROWS do board[c][r] = EMPTY end
  end
  return {
    board = board,
    turn = LIGHT,          -- light always opens
    lastC = 0, lastR = 0,  -- where the last disc landed (0 = none)
    outcome = "running",   -- "running" | "light" | "dark" | "draw"
    line = {},             -- the winning four as {{c,r}, ...} once settled
  }
end

local function inside(c, r)
  return c >= 1 and c <= COLS and r >= 1 and r <= ROWS
end

-- The row a disc dropped into `column` would land on, or 0 when full.
-- The only place gravity is expressed.
local function landingRow(g, c)
  if c < 1 or c > COLS then return 0 end
  for r = 1, ROWS do
    if g.board[c][r] == EMPTY then return r end
  end
  return 0
end

local function canDrop(g, c)
  if g.outcome ~= "running" then return false end
  return landingRow(g, c) ~= 0
end

-- The four cells of the line through (c, r) in direction (dc, dr) when they
-- are all `side`, or nil. Only called on success: never writes partials.
local function lineFrom(g, c, r, dc, dr, side)
  local cells = {}
  for step = 0, LINE - 1 do
    local cc = c + dc * step
    local rr = r + dr * step
    if not inside(cc, rr) or g.board[cc][rr] ~= side then return nil end
    cells[#cells + 1] = { cc, rr }
  end
  return cells
end

-- Four directions, not eight: a line and its reverse are the same line, and
-- scanning both would report every win twice and make "the winning line"
-- ambiguous when the app marks exactly one.
local DIRS = { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 1, -1 } }

local function winningLine(g, side)
  for c = 1, COLS do
    for r = 1, ROWS do
      if g.board[c][r] == side then
        for i = 1, #DIRS do
          local d = DIRS[i]
          local cells = lineFrom(g, c, r, d[1], d[2], side)
          if cells then return cells end
        end
      end
    end
  end
  return nil
end

local function boardFull(g)
  for c = 1, COLS do
    if g.board[c][ROWS] == EMPTY then return false end
  end
  return true
end

-- Drop a disc for the side to move. Returns false and changes nothing when
-- the column is full or the game is settled, so a caller can route a button
-- press straight here.
local function drop(g, c)
  if not canDrop(g, c) then return false end
  local r = landingRow(g, c)
  local side = g.turn
  g.board[c][r] = side
  g.lastC, g.lastR = c, r
  local wl = winningLine(g, side)
  if wl then
    g.outcome = side == LIGHT and "light" or "dark"
    g.line = wl
    return true
  end
  if boardFull(g) then
    g.outcome = "draw"
    return true
  end
  g.turn = other(side)
  return true
end

M.newGame = newGame
M.landingRow = landingRow
M.canDrop = canDrop
M.winningLine = winningLine
M.boardFull = boardFull
M.drop = drop

return M