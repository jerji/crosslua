-- wire.lua — Connect Four game blob for PLAY NEARBY (46 bytes, spec §4.3, ConnectFourCore.h).
-- cell[column][row] column-major, row 0 at the bottom (values 0 empty, 1 light, 2 dark),
-- then lastColumn i8 (-1 none), lastRow i8, turn u8 (1 light / 2 dark), outcome u8
-- (0 running, 1 light wins, 2 dark wins, 3 draw). Local game4 uses 1-based indices.
local game4 = require("game4")

local W = {}

local OUTCOME_CODE = { running = 0, light = 1, dark = 2, draw = 3 }
local OUTCOME_NAME = { [0] = "running", "light", "dark", "draw" }

function W.pack(g)
  local cells = {}
  for c = 1, game4.COLS do
    for r = 1, game4.ROWS do
      cells[#cells + 1] = string.char(g.board[c][r])
    end
  end
  -- lastC/lastR are 1-based with 0 = none; the wire is 0-based with -1 = none
  return table.concat(cells) .. string.pack("<i1i1BB",
    g.lastC - 1, g.lastR - 1, g.turn, OUTCOME_CODE[g.outcome])
end

-- Returns a fresh game table, or nil when the blob is not a valid position.
function W.unpack(s)
  if type(s) ~= "string" or #s ~= 46 then return nil end
  local g = game4.newGame()
  for c = 1, game4.COLS do
    for r = 1, game4.ROWS do
      local v = s:byte((c - 1) * game4.ROWS + r)
      if v > 2 then return nil end
      g.board[c][r] = v
    end
  end
  local lc, lr, turn, outcome = string.unpack("<i1i1BB", s, 43)
  if (turn ~= game4.LIGHT and turn ~= game4.DARK) or outcome > 3 then return nil end
  g.lastC, g.lastR = lc + 1, lr + 1
  g.turn = turn
  g.outcome = OUTCOME_NAME[outcome]
  if g.outcome == "light" then g.line = game4.winningLine(g, game4.LIGHT) or {}
  elseif g.outcome == "dark" then g.line = game4.winningLine(g, game4.DARK) or {} end
  return g
end

return W
