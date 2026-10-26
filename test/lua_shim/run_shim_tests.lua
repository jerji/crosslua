-- run_shim_tests.lua — headless test suite for the Grimoire-on-CrossLua
-- shim (plugins/grimoire_lua).  Run with the real Lua 5.4 interpreter:
--     /tmp/lua5.4 run_shim_tests.lua     (or ./run.sh)
--
-- What it does:
--   * loads fake_crosslua.lua (a pure-Lua fake of the CrossLua API)
--   * builds a fake SD image under $TMPDIR/grimoire_shim_test: the REAL
--     Grimoire spells + libs copied from /root/x4/Grimoire/, an /os/config.lua
--     fixture, dummy images/, and harness-only fixture spells (z_*.lua) that
--     exercise fs redirection, input mapping and credential hygiene
--   * loads the REAL main.lua + shim.lua from the plugin folder and runs
--     every spell headlessly with a scripted input queue and a hard
--     instruction budget (debug.sethook count hook) so infinite idle loops
--     abort deterministically instead of hanging
--   * asserts (a)-(g) from the task + 2 mutation checks
-- Prints a per-spell status table and 'ALL SHIM TESTS PASSED' only if every
-- assertion held.  Exits 0 on success, 1 on failure.

local PLUGIN_DIR      = "/root/x4/crosspoint-lua/sd_card_contents/plugins/grimoire_lua"
local GRIMOIRE_SPELLS = "/root/x4/Grimoire/sd_card_contents/spells"
local HOST_ROOT       = (os.getenv("TMPDIR") or "/tmp") .. "/grimoire_shim_test"

local INSTRUCTION_BUDGET = 3000000   -- count hook granularity for spell runs
local LAUNCHER_BUDGET    = 8000000   -- for driving the launcher end-to-end

local fake = assert(dofile("fake_crosslua.lua"))
assert(fake and fake.version, "fake_crosslua.lua failed to load")

-- ------------------------------------------------------------- utilities

local function shellquote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function rmTree(d) os.execute("rm -rf " .. shellquote(d)) end
local function mkTree(d) os.execute("mkdir -p " .. shellquote(d)) end

local function readFile(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

local function writeFile(p, content)
    local f = io.open(p, "wb")
    assert(f, "cannot write " .. p)
    f:write(content)
    f:close()
end

local function copyFile(src, dst)
    local d = readFile(src)
    assert(d, "cannot read " .. src)
    writeFile(dst, d)
end

local function listDir(d)
    local out = io.popen("ls -1 " .. shellquote(d) .. " 2>/dev/null"):read("*a")
    local names = {}
    for line in out:gmatch("[^\n]+") do
        if line ~= "" then names[#names + 1] = line end
    end
    return names
end

-- ------------------------------------------------------- check framework

local nPass, nFail = 0, 0
local failures = {}

local function check(name, cond, detail)
    if cond then
        nPass = nPass + 1
    else
        nFail = nFail + 1
        failures[#failures + 1] = name
        print(string.format("  FAIL %-58s %s", name, detail or ""))
    end
end

-- ------------------------------------------------------- scenario setup

local FIXTURES = {}

FIXTURES["z_fs_write_test.lua"] = [[
-- TEST FIXTURE (harness-only, not a shipping spell): shim fs write
-- redirection + read-back shadowing.  Writes go to data:, reads see the
-- data: copy first, then fall back to sd:.
local ok = fs.mkdir("/os")
assert(ok == true, "mkdir /os failed")
local w = fs.write("/os/x.cfg", "SHIMWRITE")
assert(w == true, "fs.write returned " .. tostring(w))
local back = fs.read("/os/x.cfg")
assert(back == "SHIMWRITE", "read-back mismatch: " .. tostring(back))
assert(fs.exists("/os/x.cfg"), "exists() must see the data: copy")
fs.append("/os/x.cfg", "+more")
assert(fs.read("/os/x.cfg") == "SHIMWRITE+more", "append failed")
local l = fs.list("/os") or {}
local found = false
for _, n in ipairs(l) do if n == "x.cfg" then found = true end end
assert(found, "list(/os) must contain x.cfg (got " .. table.concat(l or {}, ",") .. ")")
local spell = fs.read("/spells/example_spell.lua")
assert(type(spell) == "string" and #spell > 50, "sd: fallback read failed")
fs.mkdir("/os/sub/mid/deep")
assert(fs.exists("/os/sub/mid/deep"), "mkdir did not create intermediates")
return
]]

FIXTURES["z_input_test.lua"] = [[
-- TEST FIXTURE (harness-only): shim input mapping + edge semantics.
-- Scripted queue: 'back' then 'confirm' (crosslua names).
input.poll()                                    -- pops 'back'
assert(input.pressed("back"), "pressed(back)")
assert(input.released("back"), "released(back)")
assert(not input.pressed("power"), "power must never fire")
assert(not input.pressed("volup"), "volup must not match pending 'back'")
assert(not input.pressed("voldown"), "voldown must not match pending 'back'")
assert(not input.down("back"), "down() must be false (documented limitation)")
input.poll()                                    -- pops 'confirm'
assert(input.pressed("confirm"), "pressed(confirm)")
assert(input.released("confirm"), "released(confirm)")
assert(not input.pressed("back"), "back edge must have expired after poll")
return
]]

FIXTURES["z_image_test.lua"] = [[
-- TEST FIXTURE (harness-only): image.* contract. Results are drawn as text so the harness can read them.
local a, ea = image.open("/spells/nope.png")
local b, eb = image.open("/spells/lib/format.lua")
local c = image.open("/spells/images/test.png")
local ok = image.draw(c, 10, 20, 200, 200)
image.close(c)
local ok2, e2 = pcall(image.draw, c, 0, 0)
display.text(0, 0,  "A:" .. tostring(a) .. ":" .. tostring(ea), 1, true)
display.text(0, 20, "B:" .. tostring(b) .. ":" .. tostring(eb), 1, true)
display.text(0, 40, "C:" .. image.width(c) .. "x" .. image.height(c) .. ":" .. tostring(ok), 1, true)
display.text(0, 60, "D:" .. tostring(ok2) .. ":" .. tostring(e2), 1, true)
local e1 = image.open("/spells/images/test.bmp")
display.text(0, 80, "E:" .. image.width(e1) .. "x" .. image.height(e1) .. ":" .. tostring(image.draw(e1, 0, 0)), 1, true)
local f1 = image.open("/spells/images/topdown.bmp")   -- negative height = top-down
display.text(0, 100, "F:" .. image.width(f1) .. "x" .. image.height(f1) .. ":" .. tostring(image.draw(f1, 0, 0)), 1, true)
]]

FIXTURES["z_wifi_creds_test.lua"] = [[
-- TEST FIXTURE (harness-only): credentials handed to wifi.connect() must
-- NEVER reach the firmware (CrossLua joins the system's saved network).
local ok = wifi.connect("EvilCorp-WiFi", "hunter2secret", 30)
assert(ok == true, "connect should succeed via the system network")
display.clear()
display.text(20, 20, "connected=" .. tostring(ok), 1, true)
display.refresh(true)
input.poll()
if not input.pressed("confirm") then
    repeat input.poll() until input.pressed("confirm")
end
return
]]

FIXTURES["z_gfx_stress.lua"] = [[
-- TEST FIXTURE (harness-only): exercises every display.* emulation path.
display.clear()
display.pixel(10, 10, true)
display.pixel(11, 11, false)
display.line(0, 0, 100, 0, true)
display.line(1, 1, 2, 2, false)
display.rect(0, 0, 20, 20, true, false)          -- outline, black
display.rect(30, 30, 40, 40, false, true)        -- filled, white
display.text(5, 5, "size1", 1, true)
display.text(5, 30, "size2", 2, true)
display.text(5, 60, "size3", 3, true)
display.text(5, 90, "size4", 4, false)           -- white text flag
-- bitmap: 9x4 -> ceil(9/8)*4 = 8 bytes, MSB-first, mask semantics
local data = string.char(0xFF, 0x80, 0xFF, 0x80, 0xFF, 0x80, 0xFF, 0x80)
display.bitmap(50, 50, 9, 4, data, true)
local W, H = display.width(), display.height()
assert(type(W) == "number" and W > 0 and type(H) == "number" and H > 0,
       "display.width/height bad")
display.refreshWindow(0, 0, 40, 40, false)
display.refresh(true)
display.clear()
display.text(0, 0, "done", 1, true)
display.refresh(true)
input.poll()
if not input.pressed("confirm") then
    repeat input.poll() until input.pressed("confirm")
end
return
]]

local CONFIG_LUA = [[
-- /os/config.lua (headless fixture).  On a real X4 this would be the user's
-- own Grimoire config on the SD card; the shim reads it through the same
-- fs.dofile path lib/wifi.lua uses, so a real card works unchanged.
return {
    read = function()
        return { wifi_ssid = "CrossLua-Fixture-Net", wifi_pass = "fixture-pass" }
    end,
}
]]

-- Sets up the fake SD image and returns (env, launcher module).
-- When autoRun is false the test flag is set so main.lua returns its module
-- instead of running main() (for direct spell runs).  When true, chunk()
-- must be called (by runLauncher) to drive the real launcher end-to-end.
local function setupScenario(autoRun)
    rmTree(HOST_ROOT)
    mkTree(HOST_ROOT)
    fake.reset()
    fake.fsRoots = {
        hostRoot = HOST_ROOT,
        sd       = HOST_ROOT .. "/sd",
        data     = HOST_ROOT .. "/data",
        app      = PLUGIN_DIR,
        lib      = HOST_ROOT .. "/lib",
    }
    mkTree(HOST_ROOT .. "/sd")
    mkTree(HOST_ROOT .. "/data")
    mkTree(HOST_ROOT .. "/lib")
    mkTree(HOST_ROOT .. "/sd/spells")
    mkTree(HOST_ROOT .. "/sd/spells/lib")
    mkTree(HOST_ROOT .. "/sd/spells/images")
    mkTree(HOST_ROOT .. "/sd/os")

    -- the REAL Grimoire spells + libs
    for _, f in ipairs(listDir(GRIMOIRE_SPELLS .. "/lib")) do
        if f:sub(-4) == ".lua" then
            copyFile(GRIMOIRE_SPELLS .. "/lib/" .. f, HOST_ROOT .. "/sd/spells/lib/" .. f)
        end
    end
    for _, f in ipairs(listDir(GRIMOIRE_SPELLS)) do
        if f:sub(-4) == ".lua" then
            copyFile(GRIMOIRE_SPELLS .. "/" .. f, HOST_ROOT .. "/sd/spells/" .. f)
        end
    end
    -- harness-only fixtures
    for name, src in pairs(FIXTURES) do
        writeFile(HOST_ROOT .. "/sd/spells/" .. name, src)
    end
    writeFile(HOST_ROOT .. "/sd/os/config.lua", CONFIG_LUA)
    do  -- the REAL test.png (800x300) so image.width/height read a genuine IHDR
        local rf = io.open("/root/x4/Grimoire/sd_card_contents/spells/images/test.png", "rb")
        writeFile(HOST_ROOT .. "/sd/spells/images/test.png", rf and rf:read("a") or "")
        local function bmp(w, h)   -- 62-byte header of a 1-bit BMP (+ pixel padding); only the header matters here
            return "BM" .. string.pack("<I4I2I2I4", 62 + 4 * math.abs(h), 0, 0, 62)
                .. string.pack("<I4i4i4I2I2I4I4i4i4I4I4", 40, w, h, 1, 1, 0, 0, 2835, 2835, 2, 2)
                .. string.rep("\0", 8) .. string.rep("\0", 4 * math.abs(h))
        end
        writeFile(HOST_ROOT .. "/sd/spells/images/test.bmp", bmp(40, 20))
        writeFile(HOST_ROOT .. "/sd/spells/images/topdown.bmp", bmp(12, -7))
        if rf then rf:close() end
    end

    local env = fake.makeEnv()
    fake.appEnv = env
    if autoRun then
        env.__GRIMOIRE_SHIM_TEST = nil
    else
        env.__GRIMOIRE_SHIM_TEST = true
    end

    local src = assert(readFile(PLUGIN_DIR .. "/main.lua"), "plugin main.lua missing")
    local chunk = assert(load(src, "@main.lua", "t", env), "main.lua syntax error")
    return env, chunk
end

-- Loads main.lua WITHOUT the test flag and drives the real launcher main()
-- with a scripted input queue.  Returns ok, err, aborted.
local function runLauncher(script)
    local env, chunk = setupScenario(true)
    fake.queueInputs(table.unpack(script))
    local aborted = false
    local function hook() aborted = true; error("__LAUNCHER_BUDGET__", 0) end
    debug.sethook(hook, "", LAUNCHER_BUDGET)
    local ok, err = pcall(chunk)
    debug.sethook()
    return ok, err, aborted
end

-- Runs one spell via the REAL launcher.runSpell with an instruction budget.
-- Returns status: "finished" | "error" | "reached-idle-loop" | "launcher-failed"
local function runSpellDirect(env, launcher, name, script)
    fake.queueInputs(table.unpack(script))
    local aborted = false
    local function hook() aborted = true; error("__INSTRUCTION_BUDGET__", 0) end
    debug.sethook(hook, "", INSTRUCTION_BUDGET)
    local ok, ran, msg = pcall(launcher.runSpell, name)
    debug.sethook()
    if not ok then return "launcher-failed", tostring(ran) end
    if aborted then return "reached-idle-loop", "__INSTRUCTION_BUDGET__" end
    if ran then return "finished", nil end
    return "error", msg
end

-- ---------------------------------------------------------------- helpers

local function gfxSince(startIdx)
    local out = {}
    for i = startIdx, #fake.gfx.log do
        out[#out + 1] = fake.gfx.log[i]
    end
    return out
end

local function drewSomething(log)
    local text, present = false, false
    for _, e in ipairs(log) do
        if e.op == "text" and type(e[3]) == "string" and #e[3] > 0 then text = true end
        if e.op == "present" then present = true end
        if text and present then return true end
    end
    return false
end

local function logTextMessages(log)
    local out = {}
    for _, e in ipairs(log) do
        if e.op == "text" and type(e[3]) == "string" then out[#out + 1] = e[3] end
    end
    return table.concat(out, "\n")
end

-- (e) coordinate validation: every numeric arg passed to gfx.* must be a
-- finite number; positional coordinates must not be nil.
local COORD_OPS = {
    pixel = { 1, 2 }, line = { 1, 2, 3, 4 }, rect = { 1, 2, 3, 4 },
    text = { 1, 2 }, rounded_rect = { 1, 2, 3, 4, 5 }, qr = { 2, 3 },
}
local gfxViolations = {}

local function scanGfxLog(log)
    for _, e in ipairs(log) do
        for i = 1, e.n do
            local v = e[i]
            if type(v) == "number" and (v ~= v or v == math.huge or v == -math.huge) then
                gfxViolations[#gfxViolations + 1] =
                    string.format("%s arg%d=%.17g", e.op, i, v)
            end
        end
        local coordIdx = COORD_OPS[e.op]
        if coordIdx then
            for _, i in ipairs(coordIdx) do
                local v = e[i]
                if type(v) ~= "number" then
                    gfxViolations[#gfxViolations + 1] =
                        string.format("%s coord arg%d is %s", e.op, i, tostring(v))
                end
            end
        end
        if e.op == "text" and type(e[3]) ~= "string" then
            gfxViolations[#gfxViolations + 1] = "text str is " .. tostring(e[3])
        end
    end
end

-- ------------------------------------------------------------- scenarios

local spellResults = {}   -- name -> { status, note }

local function note(name, status, extra)
    spellResults[name] = { status = status, extra = extra or "" }
end

-- ------------------------------------------------------------------ S1/S2
-- Direct runs of every real spell plus the fixtures, one scenario each so
-- per-spell assertions are isolated.
local function scenarioDirect(name, script)
    local env, chunk = setupScenario(false)
    local launcher = chunk()
    assert(type(launcher) == "table" and launcher.runSpell,
           "main.lua must export {main, runSpell, listSpells} when the test flag is set")
    local startIdx = #fake.gfx.log
    local status, msg = runSpellDirect(env, launcher, name, script)
    local log = gfxSince(startIdx)
    scanGfxLog(log)
    note(name, status, msg or "")
    return status, msg, log, launcher
end

local function runAllDirect()
    print("== S1: direct spell runs (real Grimoire spells + fixtures) ==")

    -- (a) example_spell / library_demo draw and exit cleanly on confirm
    local st, msg, log = scenarioDirect("example_spell.lua",
        { "__timeout__", "__timeout__", "confirm" })
    check("(a) example_spell exits cleanly", st == "finished",
          "status=" .. st .. " msg=" .. tostring(msg))
    check("(a) example_spell drew something", drewSomething(log), "empty gfx log")
    check("(a) example_spell saw the pending confirm (no idle abort)", st ~= "reached-idle-loop")

    st, msg, log = scenarioDirect("library_demo.lua", { "__timeout__", "confirm" })
    check("(a) library_demo exits cleanly", st == "finished",
          "status=" .. st .. " msg=" .. tostring(msg))
    check("(a) library_demo drew something", drewSomething(log), "empty gfx log")

    -- (b) time_demo runs through time.sync via the shim
    st, msg, log = scenarioDirect("time_demo.lua",
        { "__timeout__", "__timeout__", "back" })
    check("(b) time_demo exits cleanly", st == "finished",
          "status=" .. st .. " msg=" .. tostring(msg))
    check("(b) time_demo ran time.sync through the shim",
          fake.calls.timeSync >= 1, "timeSync calls=" .. fake.calls.timeSync)

    -- (c) http_request_test reaches wifi.request (4 requests in the fixture)
    st, msg, log = scenarioDirect("http_request_test.lua", { "__timeout__", "back" })
    check("(c) http_request_test exits cleanly", st == "finished",
          "status=" .. st .. " msg=" .. tostring(msg))
    check("(c) http_request_test reached wifi.request 4x",
          #fake.calls.httpRequest == 4,
          "http calls=" .. #fake.calls.httpRequest)

    -- (h) gallery.lua now works: image.* maps onto gfx.image (PNG header for dims, fit + centre, no upscale)
    do
        st, msg, log = scenarioDirect("gallery.lua", { "right", "back" })
        local img
        for _, e in ipairs(log) do if e.op == "image" then img = e break end end
        check("(h) gallery.lua did not error", st ~= "error", "status=" .. tostring(st) .. " msg=" .. tostring(msg))
        check("(h) gallery drew test.png through gfx.image", img ~= nil and tostring(img[1]):find("spells/images/test.png", 1, true) ~= nil,
              "image op=" .. tostring(img and img[1]))
        check("(h) drawn size fits the screen and keeps 800:300 aspect",
              img ~= nil and img[4] <= fake.screenW and img[5] <= fake.screenH
              and math.abs(img[4] / img[5] - 800 / 300) < 0.1,
              img and ("size " .. tostring(img[4]) .. "x" .. tostring(img[5])) or "no image op")
        note("gallery.lua", st, msg)
        -- image API contract (fixture spell): open errors are values, dims come from the IHDR, draw fits+centres
        st, msg, log = scenarioDirect("z_image_test.lua", {})
        local shown = logTextMessages(log)
        check("(h) image fixture finishes", st == "finished", "status=" .. tostring(st) .. " msg=" .. tostring(msg))
        check("(h) image.open missing file -> nil, err", shown:find("A:nil:", 1, true) ~= nil and shown:find("A:nil:nil", 1, true) == nil, shown:sub(1, 160))
        check("(h) image.open non-image -> nil, 'not a PNG or BMP file'", shown:find("B:nil:not a PNG or BMP file", 1, true) ~= nil, shown:sub(1, 160))
        check("(h) BMP header gives width/height (top-down BMP too) and draw works", shown:find("E:40x20:true", 1, true) ~= nil and shown:find("F:12x7:true", 1, true) ~= nil, shown:sub(1, 200))
        check("(h) width/height from the IHDR and draw succeeds", shown:find("C:800x300:true", 1, true) ~= nil, shown:sub(1, 160))
        check("(h) draw after close raises 'image is closed'", shown:find("D:false:image is closed", 1, true) ~= nil, shown:gsub("\n", " | "))
    end

    -- (r) app.restart mode: the launcher hands the spell to a FRESH VM (run.lua) and run.lua hands control back
    do
        local function runEntry(file, script, pre)
            fake.hasRestart = true
            local env = setupScenario(true)
            if pre then pre(env) end
            fake.queueInputs(table.unpack(script))
            local src = assert(readFile(PLUGIN_DIR .. "/" .. file), file .. " missing")
            local chunk = assert(load(src, "@" .. file, "t", env))
            debug.sethook(function() error("__LAUNCHER_BUDGET__", 0) end, "", LAUNCHER_BUDGET)
            local ok, err = pcall(chunk)
            debug.sethook()
            fake.hasRestart = false
            return ok, tostring(err), env
        end
        local ok, err, env = runEntry("main.lua", { "down", "confirm" })
        check("(r) launcher confirm -> app.restart('run.lua')", not ok and err == "__app_restart__:run.lua", err)
        local picked = env.fs.read("data:spell.txt")
        check("(r) launcher stored the chosen spell + selection for the next VM",
              picked == "ble_keyboard_test.lua" and env.fs.read("data:sel.txt") == "2", tostring(picked))
        ok, err, env = runEntry("run.lua", { "confirm" }, function(e) e.fs.write("data:spell.txt", "example_spell.lua") end)
        check("(r) run.lua runs the spell in its own VM then restarts main.lua", not ok and err == "__app_restart__:main.lua", err)
        check("(r) the spell actually drew", logTextMessages(fake.gfx.log):find("Hello from a spell!", 1, true) ~= nil)
        check("(r) data:spell.txt consumed", env.fs.read("data:spell.txt") == nil)
        ok, err, env = runEntry("run.lua", {}, function(e) e.fs.write("data:spell.txt", "ble_client_test.lua") end)
        local stored = env.fs.read("data:error.txt") or ""
        check("(r) a failing spell stores name + message for the launcher",
              err == "__app_restart__:main.lua" and stored:find("^ble_client_test.lua\n") ~= nil
              and stored:find("not supported on CrossLua", 1, true) ~= nil, stored:sub(1, 100))
        ok, err, env = runEntry("run.lua", {}, function(e) e.fs.write("data:spell.txt", "../etc.lua") end)
        check("(r) a hostile spell name in data: is ignored (back to the launcher, nothing read or run)",
              err == "__app_restart__:main.lua" and env.fs.read("data:error.txt") == nil and logTextMessages(fake.gfx.log) == "", err)
        ok, err, env = runEntry("main.lua", { "back", "back" }, function(e) e.fs.write("data:error.txt", "foo.lua\nboom message here") end)
        local shown = logTextMessages(fake.gfx.log)
        check("(r) launcher shows the stored error once and clears it",
              ok and shown:find("Spell error: foo.lua", 1, true) ~= nil and shown:find("boom message here", 1, true) ~= nil
              and env.fs.read("data:error.txt") == nil, tostring(err) .. " | " .. shown:sub(1, 120))
    end

    -- (d) gallery / ble_* / wifi_server fail GRACEFULLY with the readable
    -- message (never 'attempt to call a nil value')
    for _, sp in ipairs({
        "ble_client_test.lua",
        "ble_keyboard_test.lua", "wifi_server_test.lua",
    }) do
        st, msg, log = scenarioDirect(sp, {})
        check("(d) " .. sp .. " errored (unsupported API)", st == "error",
              "status=" .. st .. " msg=" .. tostring(msg))
        check("(d) " .. sp .. " message says 'not supported on CrossLua'",
              st == "error" and msg and msg:find("not supported on CrossLua", 1, true) ~= nil,
              "msg=" .. tostring(msg))
        check("(d) " .. sp .. " never 'attempt to call a nil value'",
              msg == nil or msg:find("attempt to call a nil value", 1, true) == nil,
              "msg=" .. tostring(msg))
        local shown = logTextMessages(log)
        check("(d) " .. sp .. " error screen drawn by the launcher (survives)",
              shown:find("Spell error:", 1, true) ~= nil and
              shown:find("not supported on CrossLua", 1, true) ~= nil,
              "screen text: " .. shown:sub(1, 120))
        note(sp, st, msg)
    end

    -- (f) fs write redirect: /os/x.cfg -> data:os/x.cfg, never sd:
    st, msg, log = scenarioDirect("z_fs_write_test.lua", {})
    check("(f) z_fs_write_test finishes", st == "finished",
          "status=" .. st .. " msg=" .. tostring(msg))
    local dCopy, dErr = fake.fs.read("data:os/x.cfg")
    check("(f) data:os/x.cfg created", dCopy == "SHIMWRITE+more",
          "data read: " .. tostring(dCopy) .. " err=" .. tostring(dErr))
    check("(f) sd:os/x.cfg never touched", fake.fs.exists("sd:os/x.cfg") == false, "")
    check("(f) no write ever aimed at sd:", fake.calls.sdWriteAttempts == 0,
          "sdWriteAttempts=" .. fake.calls.sdWriteAttempts)

    -- (g) wifi credentials never forwarded (fixture passes EvilCorp/hunter2secret)
    st, msg, log = scenarioDirect("z_wifi_creds_test.lua", { "confirm" })
    local evilFound, badArgs = false, nil
    for _, rec in ipairs(fake.calls.wifiConnect) do
        if rec.nargs ~= 0 then badArgs = badArgs or rec end
        for _, a in ipairs(rec.args or {}) do
            if type(a) == "string" and
               (a:find("EvilCorp", 1, true) or a:find("hunter2secret", 1, true)) then
                evilFound = true
            end
        end
    end
    check("(g) z_wifi_creds_test finishes", st == "finished",
          "status=" .. st .. " msg=" .. tostring(msg))
    check("(g) crosslua wifi.connect received ZERO arguments",
          badArgs == nil,
          badArgs and ("received " .. badArgs.nargs .. " args") or "")
    check("(g) no credential strings reached the firmware", not evilFound, "")
    -- time_demo/http_request also connect through lib/wifi (creds dropped there)
    st = select(1, scenarioDirect("time_demo.lua", { "back" }))
    local bad2 = false
    for _, rec in ipairs(fake.calls.wifiConnect) do
        if rec.nargs ~= 0 then bad2 = true end
    end
    check("(g) lib.wifi connect path also forwards nothing", not bad2,
          bad2 and "saw args" or "")

    -- input mapping fixture
    st, msg, log = scenarioDirect("z_input_test.lua", { "back", "confirm" })
    check("input: z_input_test finishes", st == "finished",
          "status=" .. st .. " msg=" .. tostring(msg))

    -- display coverage fixture
    st, msg, log = scenarioDirect("z_gfx_stress.lua", { "confirm" })
    check("gfx: z_gfx_stress finishes", st == "finished",
          "status=" .. st .. " msg=" .. tostring(msg))

    -- S2: idle loop budget — a spell that never gets its button must abort
    -- deterministically (that is the expected end state, recorded as OK)
    print("== S2: idle-loop budget ==")
    local env, ch2 = setupScenario(false)
    local launcher2 = ch2()
    local s2, m2 = runSpellDirect(env, launcher2, "example_spell.lua", {})
    check("idle loop aborted by instruction budget (OK)",
          s2 == "reached-idle-loop", "status=" .. s2 .. " msg=" .. tostring(m2))
    note("example_spell.lua (idle)", s2, m2)

    -- wifi failure path: spell must degrade, not crash
    print("== S3: wifi failure path ==")
    local env3, ch3 = setupScenario(false)
    fake.failWifi = true
    local launcher3 = ch3()
    local s3, m3 = runSpellDirect(env3, launcher3, "http_request_test.lua", { "confirm" })
    check("wifi-fail: spell degrades gracefully", s3 == "finished",
          "status=" .. s3 .. " msg=" .. tostring(m3))
    check("wifi-fail: time.sync not attempted",
          fake.calls.timeSync == 0, "timeSync=" .. fake.calls.timeSync)
end

-- ------------------------------------------------------------------ S4
-- The REAL launcher driven end-to-end through its own input loop.
local function runLauncherScenarios()
    print("== S4: launcher integration ==")

    -- L1: select the first spell (ble_client_test.lua, sorts first), which
    -- errors at ble.scan; the launcher must show the error screen, survive
    -- a key press, and exit on Back.
    local ok, err, aborted = runLauncher({ "confirm", "back", "back" })
    check("L1 launcher survived a crashing spell", ok and not aborted,
          "ok=" .. tostring(ok) .. " err=" .. tostring(err))
    local shown = logTextMessages(fake.gfx.log)
    check("L1 error screen shown with readable message",
          shown:find("Spell error:", 1, true) ~= nil and
          shown:find("not supported on CrossLua", 1, true) ~= nil,
          "screen text: " .. shown:sub(1, 160))

    -- L2: navigate down twice, run example_spell (clean exit on confirm),
    -- then Back to leave the launcher.
    ok, err, aborted = runLauncher({ "down", "down", "confirm", "confirm", "back" })
    check("L2 launcher navigation + clean spell exit", ok and not aborted,
          "ok=" .. tostring(ok) .. " err=" .. tostring(err))
    shown = logTextMessages(fake.gfx.log)
    check("L2 example_spell ran (no error screen)",
          shown:find("Spell error:", 1, true) == nil and
          shown:find("Hello from a spell!", 1, true) ~= nil,
          "screen text: " .. shown:sub(1, 160))
end

-- ------------------------------------------------------------------ S5/S6
-- Mutation checks: temporarily break the shim (in-memory copy, never the
-- shipped file) and show the normal assertions catch it.
local function mutationRuns()
    print("== S5/S6: mutation checks ==")
    local shimSrc = assert(readFile(PLUGIN_DIR .. "/shim.lua"), "shim.lua missing")

    -- M1: forwards wifi credentials to the firmware instead of dropping them
    local mutant1 = shimSrc:gsub("return wifi%.connect%(%)",
                                 "return wifi.connect(ssid, pass, timeout)")
    check("M1 mutation anchor found", mutant1 ~= shimSrc, "gsub did not match")
    if mutant1 ~= shimSrc then
        local env, chunk = setupScenario(false)
        local mchunk = assert(load(mutant1, "@shim-mut1.lua", "t", env))
        fake.requireCache.shim = mchunk()      -- launcher's require() gets the mutant
        local launcher = chunk()
        local st, msg = runSpellDirect(env, launcher, "z_wifi_creds_test.lua", { "confirm" })
        local leaked = 0
        for _, rec in ipairs(fake.calls.wifiConnect) do
            if rec.nargs > 0 then leaked = leaked + 1 end
        end
        check("M1: credential forwarding is CAUGHT by assertion (g)",
              leaked > 0, "the zero-arg assertion would have failed (nargs>0 recorded)")
        print(string.format(
            "  mutation 1 (forward creds): fake wifi.connect received %d call(s) with args; " ..
            "first=%s -> (g) assertion would FAIL on this shim, as it must",
            leaked,
            leaked > 0 and tostring(fake.calls.wifiConnect[1].nargs.." args") or "-"))
    end

    -- M2: writes mapped to sd: instead of data:
    local mutant2 = shimSrc:gsub('fs%.write%("data:" %.%. rel, content%)',
                                 'fs.write("sd:" .. rel, content)')
    check("M2 mutation anchor found", mutant2 ~= shimSrc, "gsub did not match")
    if mutant2 ~= shimSrc then
        local env, chunk = setupScenario(false)
        local mchunk = assert(load(mutant2, "@shim-mut2.lua", "t", env))
        fake.requireCache.shim = mchunk()
        local launcher = chunk()
        local st, msg = runSpellDirect(env, launcher, "z_fs_write_test.lua", {})
        local sdTouched = fake.calls.sdWriteAttempts > 0
        local dataCopy = fake.fs.read("data:os/x.cfg")
        check("M2: writes-to-sd: is CAUGHT by assertion (f)",
              sdTouched or dataCopy == nil,
              "sd writes attempted=" .. tostring(sdTouched) ..
              " data copy=" .. tostring(dataCopy))
        print(string.format(
            "  mutation 2 (writes->sd:): %d write(s) aimed at read-only sd:; " ..
            "data:os/x.cfg=%s -> (f) assertion would FAIL on this shim, as it must",
            fake.calls.sdWriteAttempts, tostring(dataCopy)))
    end
end

-- ------------------------------------------------------------------ main

local function report()
    print()
    print("== spell status table ==")
    print(string.format("%-32s %-22s %s", "spell", "status", "note"))
    print(string.rep("-", 90))
    local order = {}
    for name in pairs(spellResults) do order[#order + 1] = name end
    table.sort(order)
    for _, name in ipairs(order) do
        local r = spellResults[name]
        local noteStr = r.extra:gsub("\n", " ")
        if #noteStr > 52 then noteStr = noteStr:sub(1, 52) .. "..." end
        print(string.format("%-32s %-22s %s", name, r.status, noteStr))
    end

    -- (e) every gfx coordinate anywhere in the whole run
    check("(e) all gfx coordinates were numbers (never nil/NaN)",
          #gfxViolations == 0,
          #gfxViolations > 0 and (table.concat(gfxViolations, "; "):sub(1, 200)) or "")

    -- sandbox: the app env must not leak io/os/package/debug
    local env = fake.makeEnv()
    for _, banned in ipairs({ "io", "os", "package", "debug", "dofile", "loadfile" }) do
        check("sandbox: no '" .. banned .. "' in the app env",
              rawget(env, banned) == nil and env[banned] == nil, "")
    end

    print()
    print(string.format("assertions: %d passed, %d failed", nPass, nFail))
    if nFail == 0 then
        print("ALL SHIM TESTS PASSED")
        return true
    end
    print("FAILED: " .. table.concat(failures, "; "))
    return false
end

runAllDirect()
runLauncherScenarios()
mutationRuns()
scanGfxLog(fake.gfx.log)

if report() then
    os.exit(0)
else
    os.exit(1)
end