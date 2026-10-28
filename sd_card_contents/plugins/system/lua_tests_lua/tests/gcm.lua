-- hub test: crypto.aes_gcm on the real device (mbedtls GCM). Pure logic, NIST vectors, no big strings.
local function __test()
print("== aes_gcm")
local W, H = gfx.size()
local lines, fails = {}, 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  local l = (cond and "PASS " or "FAIL ") .. name
  lines[#lines + 1] = l
  print(l .. (extra and (" " .. tostring(extra)) or ""))
end

local hex, U = crypto.hex, crypto.unhex
local k0, n0 = U("00000000000000000000000000000000"), U("000000000000000000000000")
local s0 = crypto.aes_gcm_encrypt(k0, n0, "")
check("empty pt (NIST #1)", hex(s0) == "58e2fccefa7e3061367f1d57a4e7455a")
check("empty roundtrip", crypto.aes_gcm_decrypt(k0, n0, s0) == "")
local s1 = crypto.aes_gcm_encrypt(k0, n0, U("00000000000000000000000000000000"))
check("16B pt (NIST #2)", hex(s1) == "0388dace60b6a392f328c2b971b2fe78ab6e47d42cec13bdf53a67b21257bddf")
local k2, n2 = U("feffe9928665731c6d6a8f9467308308"), U("cafebabefacedbaddecaf888")
local aad2 = U("feedfacedeadbeeffeedfacedeadbeefabaddad2")
local s2 = crypto.aes_gcm_encrypt(k2, n2, U("d9313225f88406e5a55909c5aff5269a"), aad2)
check("AAD (NIST #4)", hex(s2) == "42831ec2217774244b7221b784d0d49cd9f20ea917428bc48f586f2936d0fddf")
check("AAD roundtrip", hex(crypto.aes_gcm_decrypt(k2, n2, s2, aad2)) == "d9313225f88406e5a55909c5aff5269a")
local bad = s1:sub(1, -2) .. string.char(s1:byte(-1) ~ 1)
check("tamper rejected", crypto.aes_gcm_decrypt(k0, n0, bad) == nil)
local _, e = crypto.aes_gcm_encrypt("k", n0, "")
check("bad key len refused", e == "key must be 16, 24 or 32 bytes", e)

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "aes_gcm test", "ui12", "b"); gfx.line(0, 44, W - 1, 44)
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