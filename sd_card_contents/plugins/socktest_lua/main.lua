-- net.* on-device test launcher. wifi.connect() needs 96 KB free to start (sized for TLS), so this file stays tiny and the
-- real test (tests.lua) is loaded once the radio is up (the guard floor drops to 12 KB after a successful wifi.connect).
print("== wifi")
local ok, why = wifi.connect()
print((ok and "PASS " or "FAIL ") .. "wifi.connect " .. tostring(why or ""))
if not ok then return end
local src, err = fs.read("app:tests.lua")
local f, lerr = load(src or "", "=tests")
if not f then print("FAIL cannot load tests.lua: " .. tostring(lerr or err)); return end
src = nil
f()
while input.wait() ~= "back" do end
