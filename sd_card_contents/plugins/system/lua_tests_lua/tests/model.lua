-- hub test: device.caps().model (board tag, e.g. "x4") + a couple of adjacent caps fields.
local function __test()
print("== device.caps: model")
local c = device.caps()
local ok = type(c.model) == "string" and #c.model > 0 and c.model:find("[^%s]") ~= nil
ok = ok and type(c.width) == "number" and c.width > 0 and type(c.height) == "number" and c.height > 0
print((ok and "PASS" or "FAIL") .. " model=" .. tostring(c.model) ..
      " (" .. tostring(c.width) .. "x" .. tostring(c.height) .. ") touch=" .. tostring(c.touch))
print(ok and "ALL PASSED" or "FAILED")
gfx.clear()
gfx.text(16, 10, "model = " .. tostring(c.model), "ui12", "b")
gfx.text(16, 44, "screen " .. tostring(c.width) .. "x" .. tostring(c.height), "small")
gfx.text(16, 76, "touch=" .. tostring(c.touch) .. " haptic=" .. tostring(c.haptic), "small")
gfx.present("full")
while input.wait() ~= "back" do end
end
local _ok2, _err = pcall(__test)
if not _ok2 then
  print("[hub] ERROR: " .. tostring(_err))
  gfx.clear(); gfx.text(10, 10, "Test error", "ui12", "b"); gfx.text(10, 50, tostring(_err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
app.restart("main.lua")