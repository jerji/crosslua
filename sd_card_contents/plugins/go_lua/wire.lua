-- wire.lua — Go game blob for PLAY NEARBY (192 bytes, go::Game in GoCore.h).
-- Field order and offsets are the C++ struct's, little-endian, 0-based:
--   0   recent[8] u32   position keys of the last 8 positions, oldest first
--   32  capturedBy[3] u16  index by colour (0 unused, 1 black, 2 white)
--   38  komiHalves i16     15 = 7.5
--   40  moveNumber u16
--   42  ko u16             point index, 0xFFFF none
--   44  lastMove u16       point index, 0xFFFE pass, 0xFFFF none
--   46  cell[91]          two bits a point, row-major, 0 empty / 1 black / 2 white
--   137 dead[46]          one bit a point (dead-stone agreement; zero here)
--   183 size u8           9 or 13 (19 is not in the Lua engine)
--   184 toMove u8         1 black / 2 white
--   185 handicap u8       0
--   186 passes u8
--   187 recentCount u8
--   188 stage u8          0 Playing, 1 Scoring, 2 Over
--   189 accepted u8       bit per colour that agreed the count (3 when Over)
--   190..191 padding      zero
-- The Lua engine has no scoring stage: a game ends on two passes (Over) and
-- is counted by area with no dead stones. A Scoring blob from a C++ device is
-- read as over, with its dead-stone mask ignored.
local co = require("goco")

local W = {}

local SIZE = 192
local KOMI_HALVES = 15
local NO_POINT, PASS_POINT = 0xFFFF, 0xFFFE
local STAGE_PLAYING, STAGE_SCORING, STAGE_OVER = 0, 1, 2

-- g = { st = <goco state>, finished = bool }
function W.pack(g)
  local st = g.st
  local n = st.n
  local pts = n * n
  local out = {}

  for k = 1, 8 do out[#out + 1] = string.pack("<I4", st.recent[k] or 0) end
  out[#out + 1] = string.pack("<I2I2I2", 0, st.captured[1], st.captured[2])
  out[#out + 1] = string.pack("<i2", KOMI_HALVES)
  out[#out + 1] = string.pack("<I2", st.moves)
  out[#out + 1] = string.pack("<I2", st.ko ~= 0 and (st.ko - 1) or NO_POINT)
  local last = NO_POINT
  if st.last == "pass" then last = PASS_POINT
  elseif st.last then last = st.last - 1 end
  out[#out + 1] = string.pack("<I2", last)

  local cells = {}
  for k = 0, 90 do cells[k] = 0 end
  for p = 0, pts - 1 do
    cells[p >> 2] = cells[p >> 2] | (st.b[p + 1] << ((p & 3) * 2))
  end
  for k = 0, 90 do out[#out + 1] = string.char(cells[k]) end
  out[#out + 1] = string.rep("\0", 46)

  local stage = g.finished and STAGE_OVER or STAGE_PLAYING
  local accepted = g.finished and 3 or 0
  out[#out + 1] = string.pack("<BBBBBBB", n, st.turn, 0, st.passes, #st.recent, stage, accepted)
  out[#out + 1] = "\0\0"
  return table.concat(out)
end

-- Returns a game record { st, finished, stage } or nil for anything that is not
-- a legal Go position in a size this engine plays.
function W.unpack(s)
  if type(s) ~= "string" or #s ~= SIZE then return nil end
  local n, turn, handicap, passes, rcount, stage, accepted =
    string.unpack("<BBBBBBB", s, 184)
  if n ~= 9 and n ~= 13 then return nil end
  if turn ~= 1 and turn ~= 2 then return nil end
  if rcount > 8 or stage > STAGE_OVER then return nil end
  local pts = n * n
  local st = co.newState(n)
  for p = 0, pts - 1 do
    local v = (s:byte(47 + (p >> 2)) >> ((p & 3) * 2)) & 3
    if v > 2 then return nil end
    st.b[p + 1] = v
  end
  local captured1, captured2 = string.unpack("<I2I2", s, 35)
  local ko = string.unpack("<I2", s, 43)
  local last = string.unpack("<I2", s, 45)
  if ko ~= NO_POINT and ko >= pts then return nil end
  if last ~= NO_POINT and last ~= PASS_POINT and last >= pts then return nil end
  st.turn = turn
  st.passes = passes
  st.moves = string.unpack("<I2", s, 41)
  st.ko = (ko == NO_POINT) and 0 or (ko + 1)
  if last == PASS_POINT then st.last = "pass"
  elseif last ~= NO_POINT then st.last = last + 1 end
  st.lastPass = st.last == "pass"
  st.captured = { [1] = captured1, [2] = captured2 }
  for k = 1, rcount do st.recent[k] = string.unpack("<I4", s, (k - 1) * 4 + 1) end
  return {
    st = st,
    finished = stage ~= STAGE_PLAYING,
    stage = stage,
  }
end

return W
