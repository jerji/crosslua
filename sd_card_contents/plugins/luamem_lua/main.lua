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
