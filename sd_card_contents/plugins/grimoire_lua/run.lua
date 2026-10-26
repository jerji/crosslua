-- run.lua — runs ONE Grimoire spell in a fresh VM (started by main.lua via app.restart), then returns to the launcher.
-- The spell name comes from data:spell.txt. A spell error is stored in data:error.txt for the launcher to show.
local function back() app.restart("main.lua") end

local name = fs.read("data:spell.txt")
fs.remove("data:spell.txt")
if not name or not name:match("^[%w_%-%.]+%.lua$") or name:find("..", 1, true) then return back() end

local shim = require("shim")
local src, rerr = fs.read("sd:spells/" .. name)
local ok, perr
if not src then
    ok, perr = false, "can't read sd:spells/" .. name .. ": " .. tostring(rerr)
else
    local env = shim.newSpellEnv()
    shim.spellEnv = env          -- fs.dofile / spell require() use this env
    ok, perr = pcall(function()
        local chunk, lerr = load(src, "@" .. name, "t", env)
        src = nil
        if not chunk then error(lerr, 0) end
        chunk()                  -- the spell runs until it returns / errors
    end)
end
if not ok then fs.write("data:error.txt", name .. "\n" .. tostring(perr)) end
back()
