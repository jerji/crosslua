-- Exact decimal arithmetic for the calculator. A value is { s = 1|-1, d = digit string (no leading zeros, "0" for
-- zero), e = exponent }, meaning s * d * 10^e. Working precision is 16 significant digits (decNumber's default is 16
-- for this app: the six guard digits are why (1/3)*3 reads 1). Rounding is half-up.
local M = {}
local P = 16

local function norm(s, d, e)
  d = d:gsub("^0+", "")
  if d == "" then return { s = 1, d = "0", e = 0 } end
  local tz = #(d:match("0*$"))
  if tz > 0 then d = d:sub(1, #d - tz); e = e + tz end
  if d == "" then d = "0" end
  return { s = s, d = d, e = e }
end

function M.parse(str)
  local sign = 1
  if str:sub(1, 1) == "-" then sign = -1; str = str:sub(2) end
  local int, frac = str:match("^(%d*)%.?(%d*)$")
  if not int then return nil end
  local digits = (int .. frac)
  if digits == "" then digits = "0" end
  return norm(sign, digits, -#frac)
end

-- big-integer helpers on digit strings (no leading zeros unless "0")
local function cmp(a, b)
  if #a ~= #b then return (#a < #b) and -1 or 1 end
  if a == b then return 0 end
  return (a < b) and -1 or 1
end
local function add_s(a, b)
  local out, carry = {}, 0
  local i, j = #a, #b
  while i > 0 or j > 0 or carry > 0 do
    local x = (i > 0) and tonumber(a:sub(i, i)) or 0
    local y = (j > 0) and tonumber(b:sub(j, j)) or 0
    local t = x + y + carry
    out[#out + 1] = tostring(t % 10); carry = t // 10
    i = i - 1; j = j - 1
  end
  return (table.concat(out):reverse():gsub("^0+", "")):gsub("^$", "0")
end
local function sub_s(a, b) -- a >= b
  local out, borrow = {}, 0
  local i, j = #a, #b
  while i > 0 do
    local x = tonumber(a:sub(i, i)) - borrow
    local y = (j > 0) and tonumber(b:sub(j, j)) or 0
    if x < y then x = x + 10; borrow = 1 else borrow = 0 end
    out[#out + 1] = tostring(x - y)
    i = i - 1; j = j - 1
  end
  return (table.concat(out):reverse():gsub("^0+", "")):gsub("^$", "0")
end
local function mul_s(a, b)
  local res = {}
  for i = 1, #a + #b do res[i] = 0 end
  for i = #a, 1, -1 do
    for j = #b, 1, -1 do
      local p = (tonumber(a:sub(i, i)) * tonumber(b:sub(j, j))) + res[i + j]
      res[i + j] = p % 10
      res[i + j - 1] = res[i + j - 1] + p // 10
    end
  end
  local s = table.concat(res):gsub("^0+", "")
  if s == "" then s = "0" end
  return s
end
-- integer division: floor(a / b), b > 0
local function div_s(a, b)
  local q, rem = {}, "0"
  for i = 1, #a do
    rem = (rem == "0") and a:sub(i, i) or (rem .. a:sub(i, i))
    rem = rem:gsub("^0+", ""); if rem == "" then rem = "0" end
    local dgt = 0
    while cmp(rem, b) >= 0 do rem = sub_s(rem, b); dgt = dgt + 1 end
    q[#q + 1] = tostring(dgt)
  end
  local s = table.concat(q):gsub("^0+", "")
  if s == "" then s = "0" end
  return s
end

local function round_sig(x, p)
  if #x.d <= p then return x end
  local keep = x.d:sub(1, p)
  local nextd = tonumber(x.d:sub(p + 1, p + 1))
  local drop = #x.d - p
  if nextd >= 5 then keep = add_s(keep, "1") end
  return norm(x.s, keep, x.e + drop)
end

local function align(a, b)
  local e = math.min(a.e, b.e)
  return a.d .. string.rep("0", a.e - e), b.d .. string.rep("0", b.e - e), e
end

function M.add(a, b)
  local da, db, e = align(a, b)
  if a.s == b.s then return round_sig(norm(a.s, add_s(da, db), e), 1000) end
  local c = cmp(da, db)
  if c == 0 then return norm(1, "0", 0) end
  if c > 0 then return round_sig(norm(a.s, sub_s(da, db), e), 1000) end
  return round_sig(norm(b.s, sub_s(db, da), e), 1000)
end

function M.neg(a) local r = norm(-a.s, a.d, a.e); if r.d == "0" then r.s = 1 end; return r end

function M.mul(a, b)
  return round_sig(norm(a.s * b.s, mul_s(a.d, b.d), a.e + b.e), P)
end

function M.is_zero(a) return a.d == "0" end

-- division to P significant digits; returns nil when b is zero (caller reports the error)
function M.div(a, b)
  if b.d == "0" then return nil end
  if a.d == "0" then return norm(1, "0", 0) end
  local k = P + 2 + #b.d - #a.d
  if k < 0 then k = 0 end
  local num = a.d .. string.rep("0", k)
  local q = div_s(num, b.d)
  local r = norm(a.s * b.s, q, a.e - b.e - k)
  return round_sig(r, P)
end

-- format for display with at most `shown` significant digits; large/small values use E notation
function M.format(x, shown)
  shown = shown or 10
  local v = round_sig(x, shown)
  local sign = (v.s < 0 and v.d ~= "0") and "-" or ""
  local digits, e = v.d, v.e
  local intdigits = #digits + e
  if intdigits > 10 or (intdigits < -6 and digits ~= "0") then
    local mant = digits:sub(1, 1)
    if #digits > 1 then mant = mant .. "." .. digits:sub(2) end
    local ex = intdigits - 1
    return sign .. mant .. "E" .. (ex >= 0 and "+" or "-") .. string.format("%02d", math.abs(ex))
  end
  if e >= 0 then return sign .. digits .. string.rep("0", e) end
  local point = #digits + e
  if point > 0 then return sign .. digits:sub(1, point) .. "." .. digits:sub(point + 1) end
  return sign .. "0." .. string.rep("0", -point) .. digits
end

function M.to_number(x) return tonumber(M.format(x, 16)) end

return M
