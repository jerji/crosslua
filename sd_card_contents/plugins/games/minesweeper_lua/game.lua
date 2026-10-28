-- game.lua — Minesweeper rules, pure Lua, no device calls.
--
-- A port of crossplay's MinesweeperCore.h: an 8x10 board with ten mines.
-- The properties are constructed rather than sampled for:
--   * The first dig is always safe and always floods. Mines are laid AFTER it,
--     excluding that cell and its eight neighbours.
--   * A flag stops the flood and cannot be torn off by it.
-- Chording (dig) reaches byte-for-byte the state of tapping the cells one at a
-- time: it just calls reveal() on each remaining neighbour. A chord whose flag
-- count is right and whose placement is not opens a mine and loses — through
-- reveal(), the only way to lose here. A count that does not match does
-- nothing and returns false.
--
-- Cells are one byte of bit flags: MINE=1, REVEALED=2, FLAGGED=4.
-- Storage is row-major: cells[row*COLS + col + 1].
--
-- Portability note: Lua is 32-bit integers on the X4 but 64-bit on this test
-- host. The xorshift RNG is written so that its LOW 31 bits are identical on
-- both (all rolls use only those bits), making a seeded game layout
-- deterministic across platforms. Bitwise ops on a 32-bit int reproduce the
-- C++ uint32 stream exactly in the low bits.

local COLS = 8
local ROWS = 10
local MINES = 10

local MINE = 1
local REVEALED = 2
local FLAGGED = 4

local FRESH = "fresh"
local PLAYING = "playing"
local WON = "won"
local LOST = "lost"

-- ------------------------------------------------------------------ helpers

local function outside(col, row)
  return col < 0 or col >= COLS or row < 0 or row >= ROWS
end

local function new(seed)
  -- seed: any integer; the game turns a nonzero state (the C++ guard swaps a
  -- zero state for the golden-ratio constant, which does not fit a 32-bit Lua
  -- integer; any nonzero seed has the same purpose).
  local cells = {}
  for i = 1, COLS * ROWS do cells[i] = 0 end
  return { cells = cells, rng = seed or 1, status = FRESH }
end

local function idx(col, row) return row * COLS + col + 1 end

local function cell(board, col, row) return board.cells[idx(col, row)] end

local function setCell(board, col, row, byte)
  board.cells[idx(col, row)] = byte
end

local function setStatus(board, status) board.status = status end

local function status(board) return board.status end

local function has(board, col, row, flag)
  if outside(col, row) then return false end
  return (board.cells[idx(col, row)] & flag) ~= 0
end

-- Count `flag` among the eight neighbours of (col,row) of any cell array (a
-- board's cells or a saved board). The mirror pair neighbouringMines /
-- neighbouringFlags are the two counts chording bets agree.
local function countN(cells, col, row, flag)
  local n = 0
  for dc = -1, 1 do
    for dr = -1, 1 do
      if dc ~= 0 or dr ~= 0 then
        local nc, nr = col + dc, row + dr
        if not outside(nc, nr) and (cells[idx(nc, nr)] & flag) ~= 0 then
          n = n + 1
        end
      end
    end
  end
  return n
end

local function neighbouringMines(board, col, row)
  return countN(board.cells, col, row, MINE)
end

local function neighbouringFlags(board, col, row)
  return countN(board.cells, col, row, FLAGGED)
end

-- -------------------------------------------------------------------- RNG
-- xorshift32, the C++ stream, bit-exact on both the 32-bit X4 and the 64-bit
-- test host. On the X4 int32 ops wrap to uint32 naturally; on the host the low
-- 32 bits evolve exactly as uint32 because every op is position-local within
-- the word. Lua's >> is ARITHMETIC (it sign-fills) where C's uint32 >> is
-- logical: the & 0x7FFF mask on the shifted-down term restores logical
-- semantics (low 15 bits of a 17-bit shift are identical either way, so
-- masking off the sign fill makes the whole step uint32-exact).
local function nextRandom(board)
  local s = board.rng
  if s == 0 then s = 987654321 end -- xorshift must not stay at zero
  s = s ~ (s << 13)
  s = s ~ ((s >> 17) & 0x7FFF)
  s = s ~ (s << 5)
  board.rng = s
  return s
end

-- One roll of the layout RNG, as `nextRandom(rng) % kCells` in the C++.
-- The C++ rolls the full uint32; a 32-bit Lua int cannot hold bit 31 set as a
-- positive value (and 0xFFFFFFFF is a float literal on the X4), so the residue
-- is computed from parts: v = low31 + hi*2^31, hence v mod 80 =
-- (low31 mod 80 + hi*(2^31 mod 80)) mod 80, and 2^31 mod 80 == 48. All
-- operands stay within int32, on both the 32-bit X4 and the 64-bit host.
local function roll(board)
  local s = nextRandom(board)
  local low = s & 0x7FFFFFFF
  local hi = (s >> 31) & 1
  return (low % (COLS * ROWS) + hi * 48) % (COLS * ROWS)
end

-- ------------------------------------------------------------------- mines

-- Lay the mines avoiding (safeCol,safeRow) and everything touching it.
-- Called once, from the first reveal; excluding the neighbours as well as the
-- cell is what guarantees the opening is a flood.
local function layMines(board, safeCol, safeRow)
  local placed = 0
  while placed < MINES do
    local r = roll(board)
    local col = r % COLS
    local row = r // COLS
    if (board.cells[idx(col, row)] & MINE) == 0 then
      local dc, dr = col - safeCol, row - safeRow
      if not (dc >= -1 and dc <= 1 and dr >= -1 and dr <= 1) then
        board.cells[idx(col, row)] = board.cells[idx(col, row)] | MINE
        placed = placed + 1
      end
    end
  end
end

-- Reveal a cell, flooding outward through everything a zero touches.
-- Iterative (a full-board flood is 80 frames deep; recursion would burn the
-- Lua stack). A cell is marked revealed when it is PUSHED, not when it is
-- popped: that is what makes each cell enqueue at most once, and it is the
-- exact bug the crossplay board had (mark-at-pop double-enqueued cells,
-- overflowed the fixed queue, and silently truncated 41.8% of floods).
local function floodFrom(board, startCol, startRow)
  local cells = board.cells
  local i = idx(startCol, startRow)
  if (cells[i] & (REVEALED | FLAGGED)) ~= 0 then return end
  cells[i] = cells[i] | REVEALED
  local queue = { startCol, startRow } -- pairs, flat: c,r,c,r,...
  local head = 1
  while head <= #queue do
    local col, row = queue[head], queue[head + 1]
    head = head + 2
    if countN(cells, col, row, MINE) == 0 then
      for dc = -1, 1 do
        for dr = -1, 1 do
          if dc ~= 0 or dr ~= 0 then
            local nc, nr = col + dc, row + dr
            if not outside(nc, nr) then
              local ni = idx(nc, nr)
              -- A flag is the player saying "I believe there is a mine here".
              -- The flood stops at it rather than tearing it off.
              if (cells[ni] & (REVEALED | FLAGGED)) == 0 then
                cells[ni] = cells[ni] | REVEALED
                queue[#queue + 1] = nc
                queue[#queue + 1] = nr
              end
            end
          end
        end
      end
    end
  end
end

local function allSafeCellsRevealed(board)
  local cells = board.cells
  for row = 0, ROWS - 1 do
    for col = 0, COLS - 1 do
      local c = cells[idx(col, row)]
      if (c & MINE) == 0 and (c & REVEALED) == 0 then return false end
    end
  end
  return true
end

local function canReveal(board, col, row)
  if outside(col, row) then return false end
  if board.status == WON or board.status == LOST then return false end
  return (board.cells[idx(col, row)] & (REVEALED | FLAGGED)) == 0
end

-- Reveal, and settle the outcome. Returns false and changes nothing when the
-- tap is not legal, so a caller can route a tap straight here.
local function reveal(board, col, row)
  if not canReveal(board, col, row) then return false end
  if board.status == FRESH then
    layMines(board, col, row)
    board.status = PLAYING
  end
  local i = idx(col, row)
  if (board.cells[i] & MINE) ~= 0 then
    board.cells[i] = board.cells[i] | REVEALED
    board.status = LOST
    return true
  end
  floodFrom(board, col, row)
  if allSafeCellsRevealed(board) then board.status = WON end
  return true
end

-- Chording: tap a revealed number that already carries its flags and every
-- remaining neighbour opens at once. It is a shortcut, not a new kind of move:
-- it calls reveal() on each remaining neighbour in turn, so it reaches the
-- state that revealing those cells one at a time would. A wrong flag under a
-- right count opens a mine and loses, through reveal() — the only way to lose.
-- A count that does not match does NOTHING, and returns false to say so.
local function chord(board, col, row)
  if outside(col, row) then return false end
  if board.status ~= PLAYING then return false end
  if (board.cells[idx(col, row)] & REVEALED) == 0 then return false end
  if neighbouringFlags(board, col, row) ~= neighbouringMines(board, col, row) then
    return false
  end
  local changed = false
  for dc = -1, 1 do
    for dr = -1, 1 do
      if dc ~= 0 or dr ~= 0 then
        if reveal(board, col + dc, row + dr) then changed = true end
      end
    end
  end
  return changed
end

-- One tap of the DIG tool, wherever it lands: a covered cell opens, a revealed
-- number that already carries its flags chords, and anything else is refused.
local function dig(board, col, row)
  if reveal(board, col, row) then return true end
  return chord(board, col, row)
end

-- Plant or lift a flag. Never on a revealed cell, never once the game is
-- settled.
local function toggleFlag(board, col, row)
  if outside(col, row) then return false end
  if board.status == WON or board.status == LOST then return false end
  local i = idx(col, row)
  if (board.cells[i] & REVEALED) ~= 0 then return false end
  board.cells[i] = board.cells[i] ~ FLAGGED
  return true
end

local function flagCount(board)
  local n = 0
  for i = 1, COLS * ROWS do
    if (board.cells[i] & FLAGGED) ~= 0 then n = n + 1 end
  end
  return n
end

-- Mines minus flags planted. Goes negative when the player over-flags, which
-- is information rather than an error.
local function minesRemaining(board) return MINES - flagCount(board) end

local function over(board)
  return board.status == WON or board.status == LOST
end

return {
  COLS = COLS,
  ROWS = ROWS,
  MINES = MINES,
  MINE = MINE,
  REVEALED = REVEALED,
  FLAGGED = FLAGGED,
  new = new,
  cell = cell,
  setCell = setCell,
  setStatus = setStatus,
  status = status,
  neighboursOn = countN,
  neighbouringMines = neighbouringMines,
  neighbouringFlags = neighbouringFlags,
  layMines = layMines,
  floodFrom = floodFrom,
  reveal = reveal,
  chord = chord,
  dig = dig,
  toggleFlag = toggleFlag,
  flagCount = flagCount,
  minesRemaining = minesRemaining,
  over = over,
}