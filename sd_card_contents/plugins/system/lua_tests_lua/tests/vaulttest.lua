-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu.
-- vault: crypto.device_key (the device secret kept in NVS) and lib vault.lua on the REAL device.
-- Uses lua_tests_lua/vault.lua: a copy of totp_lua/vault.lua (kept identical).
-- RUN IT TWICE: the first run creates a vault, saves a fingerprint of the device key and goes to deep sleep for 6 s (a reboot); the
-- second run must open that vault and see the same fingerprint (the key survives a reboot because it lives in NVS, not RAM/SD).
local function __test()
print("== vaulttest")
local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  print((cond and "PASS " or "FAIL ") .. name .. (extra and (" " .. tostring(extra)) or ""))
end
local function free() collectgarbage(); return (system.heap()) end

-- crypto.device_key
local k1, e1 = crypto.device_key("vaulttest")
check("device_key returns 32 bytes", k1 and #k1 == 32, e1)
check("device_key is stable within a run", crypto.device_key("vaulttest") == k1)
check("device_key differs per label", crypto.device_key("other") ~= k1)
local bad, be = crypto.device_key("")
check("empty label refused", bad == nil and be ~= nil, be)
local fp = crypto.hex(crypto.sha256(k1)):sub(1, 16)  -- a fingerprint of the key, not the key
print("INFO key fingerprint " .. fp)

local vault = require("vault")
local PATH = "data:vt.bin"
local FP = "data:vt_fp.txt"

if fs.exists(PATH) then
  -- second run (after the reboot): the same key must open the vault made before it
  local was = fs.read(FP)
  check("fingerprint saved by the first run matches after the reboot", was == fp, was)
  local t0 = system.millis()
  local v, e = vault.unlock(PATH, "2468")
  local dt = system.millis() - t0
  check("vault from the previous boot opens", v ~= nil and v.data == "survives a reboot", e)
  print("INFO unlock took " .. dt .. " ms (20000 PBKDF2 iterations)")
  check("a wrong PIN is refused", vault.unlock(PATH, "2469") == nil)
  fs.remove(PATH)
  fs.remove(FP)
else
  -- first run: the real work
  local m0 = free()
  local t0 = system.millis()
  local v, e = vault.create(PATH, "2468", "survives a reboot")
  local dt = system.millis() - t0
  check("create (20000 iterations)", v ~= nil, e)
  print("INFO create took " .. dt .. " ms; heap used while deriving " .. (m0 - (system.heap())) .. " B")
  check("create is about a second, not minutes (< 5 s)", dt < 5000, dt)
  if v then
    local s0 = system.millis()
    v.data = "survives a reboot"
    check("save", v:save() == true)
    local sd = system.millis() - s0
    print("INFO save took " .. sd .. " ms (no key derivation)")
    check("save needs no key derivation (< 400 ms)", sd < 400, sd)
    check("a second vault with the same PIN has its own salt", (function()
      local w = vault.create("data:vt2.bin", "2468", "x")
      local a, b = fs.read(PATH), fs.read("data:vt2.bin")
      fs.remove("data:vt2.bin")
      return w ~= nil and a:sub(10, 25) ~= b:sub(10, 25)
    end)())
    local u = vault.unlock(PATH, "2468")
    check("unlock round trip", u ~= nil and u.data == "survives a reboot")
    check("wrong PIN refused", vault.unlock(PATH, "1111") == nil)
    local blob = fs.read(PATH)
    fs.write("data:vt_bad.bin", blob:sub(1, #blob - 1) .. string.char(blob:byte(#blob) ~ 1))
    check("a flipped MAC bit is refused", vault.unlock("data:vt_bad.bin", "2468") == nil)
    fs.remove("data:vt_bad.bin")
    check("change_pin and back", u:change_pin("1357") == true and vault.unlock(PATH, "2468") == nil and vault.unlock(PATH, "1357") ~= nil
      and (vault.unlock(PATH, "1357")):change_pin("2468") == true)
    local back = free()
    print("INFO heap after the vault work: " .. back .. " (before " .. m0 .. ")")
    check("no heap left behind (|diff| < 4 KB)", math.abs(m0 - back) < 4096, m0 - back)
  end
  fs.write(FP, fp)
  print(fails == 0 and "FIRST RUN PASSED: sleeping 6 s, then run this test again" or ("FAILED: " .. fails))
  if fails == 0 then
    gfx.clear(); gfx.text(16, 10, "vault test", "ui12", "b"); gfx.text(16, 70, "run 1 passed: sleeping 6 s", "ui12", ""); gfx.text(16, 110, "then run this test again", "ui12"); gfx.present("full")
    app.sleep(1500)
    system.sleep(6)
  end
end
print(fails == 0 and "ALL PASSED" or ("FAILED: " .. fails))
gfx.clear(); gfx.text(16, 10, "vault test", "ui12", "b"); gfx.text(16, 70, fails == 0 and "ALL PASSED" or ("FAILED: " .. fails), "ui12"); gfx.present("full")
app.sleep(1500)
app.restart("main.lua")
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
app.restart("main.lua")
