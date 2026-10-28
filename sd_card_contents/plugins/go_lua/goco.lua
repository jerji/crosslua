-- Go rules for the X4: area scoring (Chinese), komi 7.5, captures, suicide
-- illegal, simple ko, and superko over the last eight positions (C++ parity:
-- go::repeatsPosition, the same FNV position key). Board sizes 9 and 13.
-- Points are 1..N*N, row-major, 0 empty / 1 black / 2 white.
local M = {}

M.BLACK, M.WHITE = 1, 2
M.KOMI = 7.5
M.RING = 8               -- positions the superko rule looks back over
M.MOVE_LIMIT = function(n) return n * n * 5 end

local function other(c) return c == 1 and 2 or 1 end
M.other = other

-- Neighbour of point i in direction d (1 up, 2 down, 3 left, 4 right), or 0.
local function nb(i, d, n)
  local r = (i - 1) // n
  local c = (i - 1) % n
  if d == 1 then if r == 0 then return 0 end return i - n
  elseif d == 2 then if r == n - 1 then return 0 end return i + n
  elseif d == 3 then if c == 0 then return 0 end return i - 1
  else if c == n - 1 then return 0 end return i + 1 end
end
M.nb = nb

-- Flood fill from i: returns the group (array of points) and its liberty count.
local lmark, lstamp = {}, 0
local gmark, gstamp = {}, 0
local function group(b, n, i)
  local c = b[i]
  gstamp = gstamp + 1
  lstamp = lstamp + 1
  local stones, ns = { i }, 1
  gmark[i] = gstamp
  local libs = 0
  local k = 1
  while k <= ns do
    local p = stones[k]
    for d = 1, 4 do
      local q = nb(p, d, n)
      if q ~= 0 then
        if b[q] == 0 then
          if lmark[q] ~= lstamp then
            lmark[q] = lstamp
            libs = libs + 1
          end
        elseif b[q] == c and gmark[q] ~= gstamp then
          gmark[q] = gstamp
          ns = ns + 1
          stones[ns] = q
        end
      end
    end
    k = k + 1
  end
  return stones, libs
end
M.group = group

-- Position key, the same FNV-1a the C++ build uses (go::positionKey): every
-- point's colour, then the side to move. The wire carries these keys, so the
-- two builds must agree on them exactly.
function M.positionKey(b, n, turn)
  local h = 2166136261
  for i = 1, n * n do
    h = ((h ~ b[i]) * 16777619) & 0xFFFFFFFF
  end
  return ((h ~ turn) * 16777619) & 0xFFFFFFFF
end

function M.newState(n)
  return {
    n = n, b = (function()
      local t = {}
      for i = 1, n * n do t[i] = 0 end
      return t
    end)(),
    turn = 1, ko = 0, passes = 0, lastPass = false,
    moves = 0,
    last = nil,              -- 1-based point of the last stone, "pass", or nil
    recent = {},             -- keys of the last RING positions, oldest first
    captured = { [1] = 0, [2] = 0 },
  }
end

-- Remember the position about to change (C++ rememberPosition, before a move).
local function remember(st)
  local ring = st.recent
  if #ring >= M.RING then table.remove(ring, 1) end
  ring[#ring + 1] = M.positionKey(st.b, st.n, st.turn)
end
M.remember = remember

-- Try to play colour c at i on a board copy. Returns the new board, the
-- resulting hash, the ko point (0 if none), and the number of captures,
-- or nil when the move is illegal under the basic rules (not superko).
function M.tryPlay(b, n, i, c)
  if b[i] ~= 0 then return nil end
  local nb2 = {}
  for k = 1, n * n do nb2[k] = b[k] end
  nb2[i] = c
  local e = other(c)
  local caps, ncap, capPoint = {}, 0, 0
  for d = 1, 4 do
    local q = nb(i, d, n)
    if q ~= 0 and nb2[q] == e then
      local stones, libs = group(nb2, n, q)
      if libs == 0 then
        for _, p in ipairs(stones) do
          if nb2[p] ~= 0 then
            nb2[p] = 0
            ncap = ncap + 1
            caps[#caps + 1] = p
            capPoint = p
          end
        end
      end
    end
  end
  local own, ownLibs = group(nb2, n, i)
  if ownLibs == 0 then return nil end          -- suicide
  local ko = 0
  if ncap == 1 and #own == 1 and ownLibs == 1 then ko = capPoint end
  return nb2, ko, ncap, caps
end

-- The full legality test a human move (and the root of the engine) uses:
-- basic rules, simple ko, and superko against the last RING positions.
function M.legal(st, i, c)
  if i == st.ko then return false end
  local nb2, ko, ncap = M.tryPlay(st.b, st.n, i, c)
  if not nb2 then return false end
  local key = M.positionKey(nb2, st.n, other(c))
  for _, r in ipairs(st.recent) do
    if r == key then return false end
  end
  return true, nb2, ko, ncap
end

-- Play a legal move on the state (the caller checked legality).
function M.apply(st, i, c)
  local ok, nb2, ko, ncap = M.legal(st, i, c)
  if not ok then return false end
  remember(st)
  st.b = nb2
  st.ko = ko
  st.turn = other(c)
  st.passes = 0
  st.lastPass = false
  st.last = i
  st.moves = st.moves + 1
  st.captured[c] = st.captured[c] + ncap
  return true
end

function M.pass(st)
  remember(st)
  st.ko = 0
  st.turn = other(st.turn)
  st.passes = st.passes + 1
  st.lastPass = true
  st.last = "pass"
  st.moves = st.moves + 1
  return st.passes >= 2
end

-- Area score: stones plus territory (an empty region touching one colour).
-- Returns black area, white area (komi not added).
function M.area(b, n)
  local nn = n * n
  local black, white = 0, 0
  local seen = {}
  for i = 1, nn do
    if b[i] == 1 then black = black + 1 elseif b[i] == 2 then white = white + 1 end
  end
  for i = 1, nn do
    if b[i] == 0 and not seen[i] then
      local stack, ns = { i }, 1
      seen[i] = true
      local touchB, touchW = false, false
      local k = 1
      while k <= ns do
        local p = stack[k]
        for d = 1, 4 do
          local q = nb(p, d, n)
          if q ~= 0 then
            local v = b[q]
            if v == 1 then touchB = true
            elseif v == 2 then touchW = true
            elseif not seen[q] then
              seen[q] = true
              ns = ns + 1
              stack[ns] = q
            end
          end
        end
        k = k + 1
      end
      if touchB and not touchW then black = black + ns
      elseif touchW and not touchB then white = white + ns end
    end
  end
  return black, white
end

-- Black margin: positive when black wins (komi 7.5, so never zero).
function M.margin(b, n)
  local black, white = M.area(b, n)
  return black - (white + M.KOMI)
end

-- True when placing c at i would fill one of c's own eyes (every neighbour
-- is c). A simple test: good enough to keep random playouts from suiciding
-- their own eyes, which is the whole reason it exists.
function M.fillsOwnEye(b, n, i, c)
  for d = 1, 4 do
    local q = nb(i, d, n)
    if q ~= 0 and b[q] ~= c then return false end
  end
  return true
end

-- Self-atari: after playing c at i, its group has exactly one liberty.
function M.selfAtari(b, n, i, c)
  local nb2 = M.tryPlay(b, n, i, c)
  if not nb2 then return false end
  local _, libs = group(nb2, n, i)
  return libs == 1
end

function M.pack(st)
  local t = {}
  for i = 1, st.n * st.n do t[i] = string.char(48 + st.b[i]) end
  return table.concat(t)
end

return M
