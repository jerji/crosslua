-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
local function __test()
-- On-device checks for crypto.*: known-answer vectors (hashlib/openssl/RFC) plus timings of the heavy calls.
local W, H = gfx.size()
local lines, fails = {}, 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  local l = (cond and "PASS " or "FAIL ") .. name
  lines[#lines + 1] = l
  print(l .. (extra and (" " .. tostring(extra)) or ""))
end
local function timed(name, f)
  local t0 = system.millis(); local r = f(); local ms = system.millis() - t0
  print(("TIME %s: %d ms"):format(name, ms)); return r, ms
end
local hex = crypto.hex

check("sha256(abc)", hex(crypto.sha256("abc")) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
check("sha1(abc)", hex(crypto.sha1("abc")) == "a9993e364706816aba3e25717850c26c9cd0d89d")
check("hmac_sha256 RFC4231 #1", hex(crypto.hmac_sha256(("\11"):rep(20), "Hi There")) == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
check("hmac_sha1 quick fox", hex(crypto.hmac_sha1("key", "The quick brown fox jumps over the lazy dog")) == "de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9")

-- TOTP (RFC 6238, SHA1, 8 digits) built from hmac_sha1: the same construction the authenticator app uses
local function totp(secret, counter, digits)
  local h = crypto.hmac_sha1(secret, string.pack(">I4I4", 0, counter))
  local o = h:byte(20) & 15
  local n = ((h:byte(o + 1) & 0x7f) << 24) | (h:byte(o + 2) << 16) | (h:byte(o + 3) << 8) | h:byte(o + 4)
  return string.format("%0" .. digits .. "d", n % math.tointeger(10 ^ digits))
end
check("TOTP RFC6238 T=59", totp("12345678901234567890", 1, 8) == "94287082")

-- 100 KB through the incremental hash, as ten 10 KB chunks (one 100 KB string would not fit this device's Lua heap)
local chunk = ("0123456789"):rep(1000)
local h256, ms = timed("sha256 100 KB (incremental)", function()
  local h = crypto.hash("sha256"); for _ = 1, 10 do h:update(chunk) end; return hex(h:digest())
end)
check("sha256 100 KB", h256 == "aca9e593cc629cbaa94cd5a07dc029424aad93e5129e5d11f8dcd2f139c16cc0")
local pb, pms = timed("pbkdf2 4096 iterations", function() return hex(crypto.pbkdf2_sha256("password", "salt", 4096, 32)) end)
check("pbkdf2 RFC vector (4096)", pb == "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a", pms .. " ms")
local _, pms2 = timed("pbkdf2 20000 iterations", function() return crypto.pbkdf2_sha256("pw", "s", 20000, 32) end)
check("pbkdf2 20000 under 20 s", pms2 < 20000, pms2 .. " ms")

local key, iv = ("k"):rep(32), ("i"):rep(16)
local ct = timed("aes-256-cbc encrypt 8 KB", function() return crypto.aes_cbc_encrypt(key, iv, ("A"):rep(8192)) end)
local pt = timed("aes-256-cbc decrypt 8 KB", function() return crypto.aes_cbc_decrypt(key, iv, ct) end)
check("aes roundtrip 8 KB", pt == ("A"):rep(8192) and #ct == 8192 + 16)
check("aes-128-cbc known answer (openssl)", hex(crypto.aes_cbc_encrypt(("\0"):rep(16), ("\0"):rep(16), "")) == "0143db63ee66b0cdff9f69917680151e")  -- empty plaintext = one 0x10 pad block
check("aes bad padding is an error value", crypto.aes_cbc_decrypt(key, iv, ("x"):rep(16)) == nil)
local r1, r2 = crypto.random(32), crypto.random(32)
check("random 32 bytes, differs", #r1 == 32 and r1 ~= r2)
check("equal / unequal", crypto.equal("abc", "abc") and not crypto.equal("abc", "abd"))
check("b64 roundtrip", crypto.b64decode(crypto.b64encode("hello\0world")) == "hello\0world")
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))

gfx.clear()
gfx.text(16, 10, "Crypto test", "ui12", "b"); gfx.line(0, 44, W - 1, 44)
for i, s in ipairs(lines) do gfx.text(12, 52 + (i - 1) * 24, s, "small") end
gfx.text(W // 2, H - 34, fails == 0 and "ALL PASSED  (Back: quit)" or (fails .. " FAILED  (Back: quit)"), "small", "c")
gfx.present("full")
while input.wait() ~= "back" do end
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
app.restart("main.lua")
