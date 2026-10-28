-- totp.lua — RFC 6238 one-time codes, base32 and otpauth:// links. Pure functions (no device calls except crypto.*), so the host
-- tests check it against the RFC's own vectors and an independent python implementation.
local M = {}

local B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
local B32IDX = {}
for i = 1, 32 do B32IDX[B32:byte(i)] = i - 1 end
local POW10 = {[6] = 1000000, [7] = 10000000, [8] = 100000000}  -- integers: the device's Lua floats are 32-bit

-- b32decode("JBSWY3DPEHPK3PXP") -> raw bytes | nil, err. Case-insensitive; spaces, dashes and "=" padding are ignored.
function M.b32decode(s)
  if type(s) ~= "string" then return nil, "not base32" end
  s = s:upper():gsub("[%s%-]", ""):gsub("=+$", "")
  if #s == 0 then return nil, "empty secret" end
  local r = #s % 8
  if r == 1 or r == 3 or r == 6 then return nil, "not base32" end  -- no whole number of bytes can end that way
  local bits, nbits, out = 0, 0, {}
  for i = 1, #s do
    local v = B32IDX[s:byte(i)]
    if not v then return nil, "not base32" end
    bits = ((bits << 5) | v) & 0xFFFF
    nbits = nbits + 5
    if nbits >= 8 then
      nbits = nbits - 8
      out[#out + 1] = string.char((bits >> nbits) & 0xFF)
      bits = bits & ((1 << nbits) - 1)
    end
  end
  return table.concat(out)
end

-- totp.code(secret_bytes, epoch_seconds [, {digits=6..8, period=1..300, alg="SHA1"|"SHA256"}]) -> "123456" | nil, err
function M.code(secret, t, opt)
  opt = opt or {}
  local digits, period, alg = opt.digits or 6, opt.period or 30, string.upper(opt.alg or "SHA1")
  if math.type(t) ~= "integer" or t < 0 then return nil, "time must be a non-negative integer" end
  if not POW10[digits] then return nil, "digits must be 6, 7 or 8" end
  if math.type(period) ~= "integer" or period < 1 or period > 300 then return nil, "period must be 1..300 seconds" end
  if type(secret) ~= "string" or #secret < 1 then return nil, "empty secret" end
  local msg = string.pack(">I4I4", 0, t // period)
  local h
  if alg == "SHA1" then h = crypto.hmac_sha1(secret, msg)
  elseif alg == "SHA256" then h = crypto.hmac_sha256(secret, msg)
  else return nil, "unsupported algorithm (SHA1 and SHA256 only)" end
  local o = h:byte(#h) & 15
  local n = ((h:byte(o + 1) & 0x7F) << 24) | (h:byte(o + 2) << 16) | (h:byte(o + 3) << 8) | h:byte(o + 4)
  return string.format("%0" .. digits .. "d", n % POW10[digits])
end

-- seconds until the current code changes (1..period)
function M.remaining(t, period) return (period or 30) - (t % (period or 30)) end

local function pdecode(s)
  return (s:gsub("%+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- totp.parse_uri("otpauth://totp/Issuer:name?secret=...&issuer=...&digits=6&period=30&algorithm=SHA1")
--   -> {name, issuer, secret (base32, normalised), digits, period, alg} | nil, err
function M.parse_uri(uri)
  if type(uri) ~= "string" then return nil, "not an otpauth://totp/ link" end
  uri = uri:gsub("^%s+", ""):gsub("%s+$", "")
  local rest = uri:match("^otpauth://totp/(.*)$")
  if not rest then return nil, "not an otpauth://totp/ link" end
  local label, query = rest:match("^([^?]*)%??(.*)$")
  label = pdecode(label)
  local p = {}
  for k, v in query:gmatch("([^&=]+)=([^&]*)") do p[k:lower()] = pdecode(v) end
  if not p.secret then return nil, "no secret in the link" end
  local secret = p.secret:upper():gsub("[%s%-=]", "")
  local raw, e = M.b32decode(secret)
  if not raw then return nil, e end
  local issuer, name = p.issuer, label
  local li, la = label:match("^(.-):%s*(.*)$")
  if li then issuer = issuer or li; name = la end
  local digits, period = tonumber(p.digits) or 6, tonumber(p.period) or 30
  if not POW10[digits] then return nil, "digits must be 6, 7 or 8" end
  if math.type(period) ~= "integer" or period < 1 or period > 300 then return nil, "period must be 1..300 seconds" end
  local alg = string.upper(p.algorithm or "SHA1")
  if alg ~= "SHA1" and alg ~= "SHA256" then return nil, "unsupported algorithm (SHA1 and SHA256 only)" end
  if name == "" then name = issuer or "account" end
  return {name = name, issuer = issuer or "", secret = secret, digits = digits, period = period, alg = alg}
end

return M
