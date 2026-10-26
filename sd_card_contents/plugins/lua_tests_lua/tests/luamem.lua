-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
local function __test()
-- RAM regression check for the VM itself: Lua heap right after start, then after touching EVERY namespace.
-- Compare the two numbers across firmware builds (lazy namespaces must lower the first and leave the second about the same).
local function mem() collectgarbage(); collectgarbage(); return system.lua_mem() end
local f0 = (system.heap())
local a = mem()
print(("LUAMEM start: %d bytes (free heap %d)"):format(a, f0))
local names = { "fs", "json", "crypto", "time", "device", "led", "net", "zip", "epub", "wifi", "http", "coroutine", "utf8" }
local missing = {}
for _, n in ipairs(names) do if _G[n] == nil then missing[#missing + 1] = n end end
local b = mem()
print(("LUAMEM all namespaces touched: %d bytes (+%d)  missing: [%s]"):format(b, b - a, table.concat(missing, ",")))
print("DONE")
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
app.restart("main.lua")
