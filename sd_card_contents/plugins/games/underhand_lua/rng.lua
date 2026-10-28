-- underhand_lua/rng.lua
-- The crossplay port's Random::below, bit-exact: xorshift64* with the same
-- rejection sampling. A u64 is 8 u8 limbs (limb[1] = least significant).
-- All arithmetic stays in 0..2^31 so the same code runs on the 32-bit
-- device and a 64-bit host; comparisons that involve a possible high bit
-- are done on bytes, never on signed ints.
local M = {}

-- 0x2545F4914F6CDD1D, least significant byte first.
local C = { 0x1D, 0xDD, 0x6C, 0x4F, 0x91, 0xF4, 0x45, 0x25 }

local function shr(s, n)
  local r = { 0, 0, 0, 0, 0, 0, 0, 0 }
  if n >= 64 then return r end
  local limbs, bits = n // 8, n % 8
  for i = 1, 8 - limbs do r[i] = s[i + limbs] end
  if bits > 0 then
    local mask = (1 << bits) - 1
    for i = 1, 8 - limbs do
      local hi = (i + limbs < 8) and s[i + limbs + 1] or 0
      r[i] = (r[i] >> bits) | ((hi & mask) << (8 - bits))
    end
  end
  return r
end

local function shl(s, n)
  local r = { 0, 0, 0, 0, 0, 0, 0, 0 }
  if n >= 64 then return r end
  local limbs, bits = n // 8, n % 8
  for i = limbs + 1, 8 do
    local v = (s[i - limbs] << bits) & 0xFF
    if bits > 0 and i - limbs - 1 >= 1 then
      v = v | (s[i - limbs - 1] >> (8 - bits))
    end
    r[i] = v
  end
  return r
end

-- One xorshift64* step: mutates s in place, returns the 32-bit pattern
-- (state * C) >> 32 = product limbs 4..7.
local function xorshift(s)
  local t = shr(s, 12)
  for i = 1, 8 do s[i] = s[i] ~ t[i] end
  t = shl(s, 25)
  for i = 1, 8 do s[i] = s[i] ~ t[i] end
  t = shr(s, 27)
  for i = 1, 8 do s[i] = s[i] ~ t[i] end
  -- p[k+1] is product limb k (bits 8k..8k+7). The value returned is
  -- (product >> 32) & 0xFFFFFFFF = limbs 4..7 = p[5..8].
  local carry = 0
  local p = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
  for k = 0, 7 do
    local v = carry
    for j = 0, k do v = v + s[j + 1] * C[k - j + 1] end
    carry = v >> 8
    p[k + 1] = v & 0xFF
  end
  return p[5] | (p[6] << 8) | (p[7] << 16) | (p[8] << 24)
end

local function mod2p32(n) -- (2^32) mod n, by 32 doublings (n small in practice)
  local r = 1
  for _ = 1, 32 do r = (r * 2) % n end
  return r
end

local Rng = {}
Rng.__index = Rng

-- seed: nil (state 1), a 16-hex string (the saved state, most significant
-- byte first, matching stateHex), or a number (low 32 bits; 0 becomes 1,
-- as in the C++).
function Rng.new(seed)
  local s = { 1, 0, 0, 0, 0, 0, 0, 0 }
  if type(seed) == "string" then
    if #seed ~= 16 then error("rng: bad seed hex " .. tostring(seed)) end
    for i = 1, 8 do
      s[i] = tonumber(seed:sub(2 * (8 - i) + 1, 2 * (8 - i) + 2), 16)
    end
  elseif type(seed) == "number" then
    local v = math.floor(seed)
    if v == 0 then v = 1 end
    s[1] = v & 0xFF
    s[2] = (v >> 8) & 0xFF
    s[3] = (v >> 16) & 0xFF
    s[4] = (v >> 24) & 0xFF
  end
  return setmetatable({ s = s }, Rng)
end

function Rng:stateHex()
  local out = {}
  for i = 8, 1, -1 do out[#out + 1] = string.format("%02x", self.s[i]) end
  return table.concat(out)
end

-- in [0, n); 0 when n <= 1, WITHOUT advancing the state (as the C++ does).
function Rng:below(n)
  if n <= 1 then return 0 end
  local r2 = mod2p32(n) -- 2^32 mod n; r2 < n
  local function draw()
    local r = xorshift(self.s)
    local t = (r + r2) & 0xFFFFFFFF -- t = (r + 2^32 mod n) mod 2^32
    -- reject when r >= 2^32 - r2, i.e. t < r2 (r2 < 2^16 here, so the
    -- high half of t being nonzero means t >= r2 already).
    local reject = (t >> 16) & 0xFFFF == 0 and (t & 0xFFFF) < r2
    return r, reject
  end
  local r, reject = draw()
  while reject do r, reject = draw() end
  if r < 0 then return (r % n + r2) % n end
  return r % n
end

M.Rng = Rng
return M