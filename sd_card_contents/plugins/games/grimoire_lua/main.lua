-- main.lua - Grimoire spells launcher (CrossLua app).
--
-- Lists every top-level *.lua in sd:spells/ (the Grimoire spell folder on
-- the SD card), lets the user pick one with up/down, and runs it through
-- shim.lua.  A spell that errors shows an on-screen error (name + wrapped
-- message, press any key) and the launcher survives.  A spell that returns
-- simply exits back to this list, matching Grimoire's "returning IS exiting".
--
-- Quit the launcher with Back (or hold Back ~1s, which the firmware handles
-- and never delivers to us).

-- Memory: the launcher itself stays small. When the firmware has app.restart, a chosen spell runs in a FRESH VM
-- (run.lua: shim + spell only), so the launcher's code and tables are not resident while a spell needs RAM (the PNG
-- decoder needs a 46 KB block). Without app.restart the spell runs in this VM.
local HAS_RESTART = type(app.restart) == "function"

local FONT_HDR = "sans16"
local FONT_ROW = "ui"

-- ---------------------------------------------------------------------------
-- Spell list: top-level *.lua files in sd:spells/, sorted.  Subfolders are
-- excluded (spell libs live under sd:spells/lib/ - they never match *.lua at
-- top level, and any directory-looking name with a trailing '/' is skipped).
-- ---------------------------------------------------------------------------

local function listSpells()
    local names, err = fs.list("sd:spells")
    if not names then return {} end
    local spells = {}
    for _, n in ipairs(names) do
        if n:sub(-1) ~= "/" and n:sub(-4) == ".lua" then
            spells[#spells + 1] = n
        end
    end
    table.sort(spells)
    return spells
end

-- ---------------------------------------------------------------------------
-- Error screen: spell name + message wrapped to the screen width.
-- ---------------------------------------------------------------------------

local function showError(name, msg)
    local w, h = gfx.size()
    gfx.clear()
    gfx.text(10, 8, "Spell error: " .. name, FONT_HDR, "b")

    local y = 8 + gfx.line_height(FONT_HDR) + 10
    local font = "small"
    local bottomLimit = h - 24

    -- wrap: split on newlines, then word-wrap each paragraph
    local function drawLine(line)
        if line == "" then
            gfx.text(10, y, " ", font)
            y = y + gfx.line_height(font) + 4
            return
        end
        local out = ""
        for word in (line .. " "):gmatch("%S+") do
            local t = (out == "") and word or (out .. " " .. word)
            if gfx.text_width(t, font) > w - 20 and out ~= "" then
                gfx.text(10, y, out, font)
                y = y + gfx.line_height(font) + 4
                if y > bottomLimit then return false end
                out = word
            else
                out = t
            end
        end
        if out ~= "" then
            gfx.text(10, y, out, font)
            y = y + gfx.line_height(font) + 4
        end
        return y <= bottomLimit
    end

    for para in (tostring(msg) .. "\n"):gmatch("(.-)\n") do
        if not drawLine(para) then break end
    end

    gfx.text(10, h - 16, "Press any key to return", font, "")
    gfx.present("full")
    input.wait()   -- any short press dismisses
end

-- ---------------------------------------------------------------------------
-- Run one spell.  Returns true on clean exit, or false + error message.
-- ---------------------------------------------------------------------------

local function runSpell(name)
    gfx.clear()
    gfx.present()

    local shim = require("shim")
    local src, rerr = fs.read("sd:spells/" .. name)
    if not src then
        local msg = "can't read sd:spells/" .. name .. ": " .. tostring(rerr)
        showError(name, msg)
        return false, msg
    end

    collectgarbage("collect")

    local env = shim.newSpellEnv()
    shim.spellEnv = env          -- fs.dofile / spell require() use this env

    local ok, perr = pcall(function()
        local chunk, lerr = load(src, "@" .. name, "t", env)
        if not chunk then error(lerr, 0) end
        chunk()                  -- spell runs until it returns / errors
    end)

    shim.spellEnv = nil
    collectgarbage("collect")

    if not ok then
        showError(name, tostring(perr))
        return false, tostring(perr)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Main loop.
-- ---------------------------------------------------------------------------

local function main()
    local spells = listSpells()
    -- A spell that failed in its own VM left its error behind: show it once, then forget it.
    local errTxt = fs.read("data:error.txt")
    if errTxt then
        fs.remove("data:error.txt")
        local ename, emsg = errTxt:match("^([^\n]*)\n(.*)$")
        showError(ename or "?", emsg or errTxt)
    end
    if #spells == 0 then
        gfx.clear()
        gfx.text(12, 20, "No spells found in sd:spells/", FONT_ROW, "b")
        gfx.text(12, 60, "Copy your Grimoire .lua files to the", "small")
        gfx.text(12, 76, "SD card's spells/ folder and reopen.", "small")
        gfx.text(12, 120, "Press any key to exit.", "small")
        gfx.present("full")
        input.wait()
        return
    end

    local sel = 1
    local savedSel = tonumber(fs.read("data:sel.txt") or "")
    if savedSel and savedSel >= 1 and savedSel <= #spells then sel = math.floor(savedSel) end
    while true do
        local w, h = gfx.size()
        local rowH = gfx.line_height(FONT_ROW) + 6
        local y0 = 8 + gfx.line_height(FONT_HDR) + 10
        local visible = math.max(1, math.floor((h - y0 - 40) / rowH))

        -- keep sel visible
        local top = sel - math.floor(visible / 2)
        if top < 1 then top = 1 end
        if top + visible > #spells then top = math.max(1, #spells - visible + 1) end

        gfx.clear()
        gfx.text(12, 8, "Grimoire spells", FONT_HDR, "b")
        gfx.line(0, y0 - 6, w, y0 - 6, false)
        for i = top, math.min(#spells, top + visible - 1) do
            local y = y0 + (i - top) * rowH
            local focus = (i == sel)
            local label = i == sel and ("> " .. spells[i]) or ("  " .. spells[i])
            gfx.text(12, y, label, FONT_ROW, focus and "b" or "")
        end
        gfx.text(12, h - 16, "confirm: run    up/down: move    back: exit", "small")
        gfx.present("fast")

        local ev = input.wait()   -- blocks
        if ev == "up" then
            sel = sel - 1
            if sel < 1 then sel = #spells end
        elseif ev == "down" then
            sel = sel + 1
            if sel > #spells then sel = 1 end
        elseif ev == "confirm" then
            if HAS_RESTART then
                fs.write("data:sel.txt", tostring(sel))
                fs.write("data:spell.txt", spells[sel])
                local ok, why = app.restart("run.lua")   -- never returns on success
                showError(spells[sel], "cannot start the spell VM: " .. tostring(why))
            else
                runSpell(spells[sel])
            end
        elseif ev == "back" then
            return
        end
    end
end

if _G and _G.__GRIMOIRE_SHIM_TEST then
else
    main()
end

return { main = main, runSpell = runSpell, listSpells = listSpells }