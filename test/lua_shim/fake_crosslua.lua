-- fake_crosslua.lua — a pure-Lua fake of the CrossLua app API, for headless
-- testing of the Grimoire shim (test/lua_shim).  NOT shipped to the device.
--
-- Emulates, per docs/lua/API.md, everything the shim/launcher touch:
--   gfx (records every call into M.gfx.log), input (pops a scripted queue),
--   app, system, fs (real files under temp dirs for sd:/data:/app:/lib:),
--   zip, time, wifi, http, json, load (text-only, env-honouring), require.
--
-- The harness runs this file with the REAL Lua interpreter, so it may use
-- io/os internally; the env handed to CrossLua code (M.makeEnv) exposes NO
-- io/os/package/debug/dofile/loadfile — exactly like the real sandbox.
--
-- Test-only escape hatches (all on M, none reachable from the app env):
--   * M.queueInput(name)              script a button release ('back','confirm',
--                                     'left','right','up','down') or
--                                     '__timeout__' (wait returns nil)
--   * M.calls.*                        recorded crosslua-level calls for
--                                     assertions (wifiConnect nargs, httpRequest,
--                                     timeSync, sdWriteAttempts, ...)
--   * M.failWifi / M.failSync / M.failHttp
--   * M.epoch / M.millis              scriptable clock
--   * M.fsRoots{hostRoot}             real dirs backing sd:/data:/app:/lib:

local M = { version = "fake_crosslua 1.0", calls = {} }

local function newCalls()
    return {
        wifiConnect = {},     -- { nargs = n, args = {...} } at crosslua level
        wifiOff = 0,
        httpRequest = {},     -- { url, method, body, headers }
        timeSync = 0,
        timeSet = 0,
        sdWriteAttempts = 0,  -- any write aimed at the read-only sd: scope
        sleeps = 0,
        zipRead = 0,
        jsonEnc = 0, jsonDec = 0,
    }
end
M.calls = newCalls()

-- ------------------------------------------------------------------ state

M.gfx = { log = {} }          -- { op="clear|pixel|...", ...raw args... }
M.inputQueue = {}             -- scripted events, consumed front-first
M.requireCache = {}
M.appExited = false
M.wifi = { connected = false, ssid = nil, ip = nil, rssi = 0 }
M.failWifi = false
M.failSync = false
M.failHttp = false
M.epoch = 1770000000          -- 2026-02-02-ish UTC
M.millis = 0
M.screenW, M.screenH = 480, 800   -- portrait, like the device
M.freeHeap = 200000
M.batteryPercent = 87
M.appEnv = nil
M.fsRoots = { hostRoot = nil, sd = nil, data = nil, app = nil, lib = nil }

function M.reset()
    M.gfx.log = {}
    M.inputQueue = {}
    M.requireCache = {}
    M.calls = newCalls()
    M.appExited = false
    M.wifi = { connected = false, ssid = nil, ip = nil, rssi = 0 }
    M.failWifi, M.failSync, M.failHttp = false, false, false
    M.epoch, M.millis = 1770000000, 0
    M.appEnv = nil
    M.fsRoots = { hostRoot = nil, sd = nil, data = nil, app = nil, lib = nil }
end

function M.queueInput(name)
    M.inputQueue[#M.inputQueue + 1] = name   -- '__timeout__' -> nil on pop
end

function M.queueInputs(...)
    for i = 1, select("#", ...) do M.queueInput((select(i, ...))) end
end

-- ------------------------------------------------------------------ utils

local function shellquote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function fileExists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local function isDir(path)
    return fileExists(path .. "/.")  -- POSIX trick (or use 'test -d')
end

local function hiddenComponent(rel)
    for part in rel:gmatch("[^/]+") do
        if part:sub(1, 1) == "." then return true end
    end
    return false
end

-- Split + validate a CrossLua path ('sd:Books/x.epub').  Returns scope, rel
-- or nil, err.  Same rules as the real firmware: clean relative path only
-- (no leading '/', no '..' / '.' / empty parts, no backslashes, no ':').
local function validate(p)
    if type(p) ~= "string" then return nil, "path must be a string" end
    local scope, rel = p:match("^([^:]+):(.*)$")
    if not scope then scope, rel = "app", p end
    if scope ~= "sd" and scope ~= "data" and scope ~= "app" and scope ~= "lib" then
        return nil, "unknown scope '" .. scope .. "'"
    end
    rel = rel:gsub("^/+", "")
    if rel:find("\\") then return nil, "backslash in path" end
    for part in rel:gmatch("[^/]+") do
        if part == ".." or part == "." or part == "" then
            return nil, "bad path component"
        end
    end
    if rel == "" then rel = "." end
    return scope, rel
end

local function phys(scope, rel)
    local base = M.fsRoots[scope] or (M.fsRoots.hostRoot and (M.fsRoots.hostRoot .. "/" .. scope))
    if not base then return nil end
    return base .. "/" .. rel
end

-- ------------------------------------------------------------ fs (fake)

local fs = {}

fs.read = function(p, off, len)
    local scope, rel = validate(p)
    if not scope then return nil, rel end
    if scope == "sd" and hiddenComponent(rel) then return nil, "hidden path" end
    local h = phys(scope, rel)
    local f = io.open(h, "rb")
    if not f then return nil, "not found" end
    local data = f:read("*a")
    f:close()
    if off then
        if off < 0 then off = 0 end
        if len == nil then
            data = data:sub(off + 1)
        else
            data = data:sub(off + 1, off + len)
        end
    end
    return data
end

local function writeRefused(scope)
    return nil, scope .. ": read-only"
end

fs.write = function(p, data)
    local scope, rel = validate(p)
    if not scope then return nil, rel end
    if scope ~= "data" then
        if scope == "sd" then M.calls.sdWriteAttempts = M.calls.sdWriteAttempts + 1 end
        return writeRefused(scope)
    end
    local h = phys("data", rel)
    local dir = h:match("^(.*)/[^/]+$")
    if dir then os.execute("mkdir -p " .. shellquote(dir)) end
    local f = io.open(h, "wb")
    if not f then return nil, "write failed" end
    f:write(data)
    f:close()
    return true
end

fs.append = function(p, data)
    local scope, rel = validate(p)
    if not scope then return nil, rel end
    if scope ~= "data" then
        if scope == "sd" then M.calls.sdWriteAttempts = M.calls.sdWriteAttempts + 1 end
        return writeRefused(scope)
    end
    local h = phys("data", rel)
    local dir = h:match("^(.*)/[^/]+$")
    if dir then os.execute("mkdir -p " .. shellquote(dir)) end
    local f = io.open(h, "ab")
    if not f then return nil, "append failed" end
    f:write(data)
    f:close()
    return true
end

fs.write_at = function(p, offset, data)
    local scope, rel = validate(p)
    if not scope then return nil, rel end
    if scope ~= "data" then return writeRefused(scope) end
    local h = phys("data", rel)
    local f = io.open(h, "r+b")
    if not f then return nil, "not found" end
    f:seek("set", offset)
    f:write(data)
    f:close()
    return true
end

fs.exists = function(p)
    local scope, rel = validate(p)
    if not scope then return false end
    if scope == "sd" and hiddenComponent(rel) then return false end
    return fileExists(phys(scope, rel))
end

fs.size = function(p)
    local scope, rel = validate(p)
    if not scope then return nil, rel end
    local h = phys(scope, rel)
    local f = io.open(h, "rb")
    if not f then return nil, "not found" end
    local n = f:seek("end")
    f:close()
    return n
end

fs.mkdir = function(p)
    local scope, rel = validate(p)
    if not scope then return nil, rel end
    if scope ~= "data" then return writeRefused(scope) end
    local h = phys("data", rel)
    os.execute("mkdir -p " .. shellquote(h))
    if isDir(h) then return true end   -- created, or already there
    return nil, "mkdir failed"
end

fs.remove = function(p)
    local scope, rel = validate(p)
    if not scope then return nil, rel end
    if scope ~= "data" then return writeRefused(scope) end
    local h = phys("data", rel)
    if os.remove(h) then return true end
    if isDir(h) and os.execute("rmdir " .. shellquote(h)) == 0 then return true end
    return nil, "remove failed"
end

fs.rename = function(p, q)
    local scope, rel = validate(p)
    local scope2, rel2 = validate(q)
    if not scope or not scope2 then return nil, "bad path" end
    if scope ~= "data" or scope2 ~= "data" then return writeRefused("data") end
    if os.rename(phys("data", rel), phys("data", rel2)) then return true end
    return nil, "rename failed"
end

-- Sorted names; directories get a trailing '/', exactly like the firmware.
fs.list = function(p)
    local scope, rel = validate(p)
    if not scope then return nil, rel end
    if scope == "sd" and hiddenComponent(rel) then return nil, "hidden path" end
    local h = phys(scope, rel)
    if not isDir(h) then return nil, "not found" end
    local out = io.popen("ls -1p " .. shellquote(h) .. " 2>/dev/null"):read("*a")
    local names = {}
    for line in out:gmatch("[^\n]+") do
        if scope == "sd" and line:sub(1, 1) == "." then
            -- hidden names don't exist on sd:
        else
            names[#names + 1] = line
        end
    end
    table.sort(names)
    return names
end

-- ------------------------------------------------------- gfx (fake log)

local gfx = {}

gfx.size = function() return M.screenW, M.screenH end

local function log(op, ...)
    local e = { op = op, n = select("#", ...) }
    for i = 1, select("#", ...) do e[i] = (select(i, ...)) end
    M.gfx.log[#M.gfx.log + 1] = e
end

local FONTW = { ui = 8, ui12 = 8, small = 6, sans12 = 7, sans14 = 8,
                sans16 = 10, sans18 = 12 }
local FONTH = { ui = 14, ui12 = 14, small = 10, sans12 = 13, sans14 = 15,
                sans16 = 18, sans18 = 21 }

gfx.clear = function(black) log("clear", black) end
gfx.pixel = function(x, y, black) log("pixel", x, y, black) end
gfx.line = function(x0, y0, x1, y1, black) log("line", x0, y0, x1, y1, black) end
gfx.rect = function(x, y, w, h, filled, black) log("rect", x, y, w, h, filled, black) end
gfx.text = function(x, y, str, font, flags) log("text", x, y, str, font, flags) end
gfx.text_width = function(str, font, flags)
    local w = FONTW[font] or 8
    return math.max(1, math.ceil((#(str or "")) * w * 0.72))
end
gfx.line_height = function(font) return FONTH[font] or 14 end
gfx.present = function(mode) log("present", mode) end
gfx.qr = function(text, x, y, side) log("qr", text, x, y, side) end
gfx.rounded_rect = function(x, y, w, h, r, filled, black)
    log("rounded_rect", x, y, w, h, r, filled, black)
end

-- ----------------------------------------------------- input (scripted)

local input = {}

input.wait = function(timeoutMs)
    if #M.inputQueue > 0 then
        local e = table.remove(M.inputQueue, 1)
        if e == "__timeout__" then return nil end
        return e
    end
    return nil   -- would block on device; headless: nil (timeout)
end

input.poll = function()
    if #M.inputQueue > 0 then
        local e = table.remove(M.inputQueue, 1)
        if e == "__timeout__" then return nil end
        return e
    end
    return nil
end

-- ------------------------------------------------------------- app

local app = {}
app.sleep = function(ms) M.calls.sleeps = M.calls.sleeps + 1 end
app.exit = function() M.appExited = true; error("__app_exit__", 0) end
app.name = function() return "grimoire_lua" end
app.dir = function() return "/plugins/grimoire_lua" end
app.open_book = function(path) return false, "not supported on CrossLua" end

-- ----------------------------------------------------------- system

local system = {}
system.millis = function() return M.millis end
system.heap = function() return M.freeHeap, 120000, 80000 end
system.lua_mem = function() return 0, 0, 0 end
system.battery = function() return M.batteryPercent end
system.mac = function() return "AA:BB:CC:DD:EE:FF" end
system.frontlight = function() return 0 end

-- ------------------------------------------------------------- time

local time = {}
time.now = function()
    if M.epoch == nil then return nil end
    return M.epoch
end
time.date = function(epoch)
    if (epoch == nil and M.epoch == nil) then return nil end
    local t = os.date("*t", epoch or M.epoch)
    if not t then return nil end
    return { year = t.year, month = t.month, day = t.day, hour = t.hour,
             min = t.min, sec = t.sec, wday = t.wday, yday = t.yday }
end
time.sync = function(timeoutS)
    M.calls.timeSync = M.calls.timeSync + 1
    if M.failSync then return false end
    if not M.wifi.connected then return false end
    M.epoch = 1770070000
    return true
end
time.set = function(epoch)
    M.calls.timeSet = M.calls.timeSet + 1
    M.epoch = epoch
    return true
end

-- ------------------------------------------------------------- wifi

local wifi = {}
wifi.connect = function(...)
    local nargs = select("#", ...)
    local rec = { nargs = nargs }
    if nargs > 0 then
        local args = { ... }
        rec.args = args
    end
    M.calls.wifiConnect[#M.calls.wifiConnect + 1] = rec
    if M.failWifi then return false, "simulated wifi failure" end
    if M.wifi.connected then return true end
    M.wifi.connected = true
    M.wifi.ssid = "CrossLua-Saved-Net"
    M.wifi.ip = "192.168.4.99"
    M.wifi.rssi = -40
    return true
end
wifi.status = function()
    if not M.wifi.connected then
        return { connected = false, ssid = nil, ip = nil, rssi = 0 }
    end
    return { connected = true, ssid = M.wifi.ssid, ip = M.wifi.ip, rssi = M.wifi.rssi }
end
wifi.off = function()
    M.calls.wifiOff = M.calls.wifiOff + 1
    M.wifi.connected = false
    M.wifi.ip = nil
    return true
end
wifi.scan = function(max)
    return { { ssid = "NetA", rssi = -45, encrypted = true },
             { ssid = "NetB", rssi = -70, encrypted = false } }, 2
end

-- ------------------------------------------------------------- http

local http = {}
http.request = function(o)
    if type(o) ~= "table" or type(o.url) ~= "string" then
        return nil, "bad http.request arguments"
    end
    local method = o.method or "GET"
    M.calls.httpRequest[#M.calls.httpRequest + 1] =
        { url = o.url, method = method, body = o.body, headers = o.headers }
    if M.failHttp then return nil, "simulated http failure" end
    local status = (method == "POST" or method == "PUT") and 405 or 200
    return { status = status, ok = status < 300, bytes = 32,
             body = "<html>fake crosslua answer for " .. o.url .. "</html>" }
end
http.get = function(url, opts)
    return http.request({ url = url, method = "GET", headers = opts and opts.headers })
end

-- -------------------------------------------------------------- zip

local zip = {}

-- Plausible fake: a file beginning with the PK magic parses; zip.read
-- returns a deterministic entry.  Real inflate isn't available in a pure
-- Lua fake — no shipped spell exercises zip.
zip.list = function(path, max)
    local data, err = fs.read(path)
    if not data then return nil, err end
    if not data:match("^PK") then return nil, "not a zip" end
    return { { name = "META-INF/container.xml", size = 13 } }, 1
end
zip.read = function(path, entry, maxBytes)
    M.calls.zipRead = M.calls.zipRead + 1
    local data, err = fs.read(path)
    if not data then return nil, err end
    if not data:match("^PK") then return nil, "not a zip" end
    return "<fake entry " .. entry .. ">"
end
zip.inflate = function(bytes, asZlib)
    -- identity: not real deflate; documented fake
    return bytes
end

-- -------------------------------------------------------------- json

local json = {}

local function jsonEncode(v, seen)
    local t = type(v)
    if v == json.null then return "null" end
    if t == "nil" then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if v ~= v then return "null" end
        if math.type(v) == "integer" then return tostring(v) end
        return string.format("%.7g", v)
    end
    if t == "string" then
        return '"' .. v:gsub('[%z\1-\31"\\]', function(c)
            if c == '"' then return '\\"'
            elseif c == "\\" then return "\\\\"
            elseif c == "\n" then return "\\n"
            elseif c == "\r" then return "\\r"
            elseif c == "\t" then return "\\t"
            else return string.format("\\u%04x", c:byte()) end
        end) .. '"'
    end
    if t == "table" then
        if seen[v] then return "null" end   -- cycle guard
        seen[v] = true
        local n = #v
        if n > 0 then
            local parts = {}
            for i = 1, n do
                parts[i] = jsonEncode(v[i], seen)
            end
            seen[v] = nil
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local parts = {}
        for k, val in pairs(v) do
            if type(k) == "string" then
                parts[#parts + 1] = jsonEncode(k, seen) .. ":" .. jsonEncode(val, seen)
            end
        end
        seen[v] = nil
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

json.encode = function(v)
    M.calls.jsonEnc = M.calls.jsonEnc + 1
    local ok, res = pcall(jsonEncode, v, {})
    if not ok then return nil, res end
    return res
end

local function jsonDecode(s)
    local pos = 1
    local function skip() 
        local _, e = s:find("^%s*", pos)
        pos = e + 1
    end
    local function parse()
        skip()
        local c = s:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            local t = {}
            skip()
            if s:sub(pos, pos) == "}" then pos = pos + 1 return t end
            while true do
                local k = parse()
                skip()
                if s:sub(pos, pos) ~= ":" then error("expected :") end
                pos = pos + 1
                t[k] = parse()
                skip()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "}" then return t end
                if d ~= "," then error("expected ,") end
            end
        elseif c == "[" then
            pos = pos + 1
            local t = {}
            skip()
            if s:sub(pos, pos) == "]" then pos = pos + 1 return t end
            local i = 1
            while true do
                t[i] = parse()
                i = i + 1
                skip()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "]" then return t end
                if d ~= "," then error("expected ,") end
            end
        elseif c == '"' then
            pos = pos + 1
            local out = {}
            while true do
                local ch = s:sub(pos, pos)
                if ch == '"' then pos = pos + 1 return table.concat(out) end
                if ch == "\\" then
                    pos = pos + 1
                    local e = s:sub(pos, pos)
                    if e == "n" then out[#out + 1] = "\n"
                    elseif e == "r" then out[#out + 1] = "\r"
                    elseif e == "t" then out[#out + 1] = "\t"
                    elseif e == "u" then
                        local hex = s:sub(pos + 1, pos + 4)
                        out[#out + 1] = string.char(tonumber(hex, 16))
                        pos = pos + 4
                    else out[#out + 1] = e end
                    pos = pos + 1
                else
                    out[#out + 1] = ch
                    pos = pos + 1
                end
            end
        else
            local word = s:match("^[%w%+%-%.]+", pos)
            if not word then error("unexpected char") end
            pos = pos + #word
            if word == "true" then return true
            elseif word == "false" then return false
            elseif word == "null" then return nil
            else
                local n = tonumber(word)
                if not n then error("bad number") end
                return n
            end
        end
    end
    local v = parse()
    return v
end

json.decode = function(s)
    M.calls.jsonDec = M.calls.jsonDec + 1
    if type(s) ~= "string" then return nil, "json.decode: string expected" end
    local ok, res = pcall(jsonDecode, s)
    if not ok then return nil, "msg: " .. res end
    return res
end
json.null = { __json_null = true }

-- --------------------------------------------------- load / require

-- The CrossLua load(): text chunks only (<=64KB), honouring env as _ENV,
-- standard Lua 5.4 semantics otherwise.
local function loadFn(text, chunkname, mode, env)
    if type(text) ~= "string" then return nil, "load: chunk must be a string" end
    if #text > 65536 then return nil, "script too big (max 64KB)" end
    return _G.load(text, chunkname or "?", "t", env)
end

-- The CrossLua require(): app folder then lib:, cached, clear error.
local function requireFn(name)
    if M.requireCache[name] then return M.requireCache[name] end
    if type(name) ~= "string" or not name:match("^[%w_%.]+$") then
        error("bad module name '" .. tostring(name) .. "'", 0)
    end
    local rel = name:gsub("%.", "/")
    local src, picked
    for _, cand in ipairs({ "app:" .. rel .. ".lua", "app:" .. rel .. "/init.lua",
                            "lib:" .. rel .. ".lua", "lib:" .. rel .. "/init.lua" }) do
        local d = fs.read(cand)
        if d then src, picked = d, cand break end
    end
    if not src then
        error("module '" .. name .. "' not found (searched app: and lib:)", 0)
    end
    local chunk, cerr = _G.load(src, "@" .. picked, "t", M.appEnv)
    if not chunk then error(cerr, 0) end
    local ok, res = pcall(chunk)
    if not ok then error(res, 0) end
    M.requireCache[name] = res
    return res
end

-- ------------------------------------------------- app/shim environment

-- The CrossLua sandbox: safe stdlib only.  NO io/os/package/debug/dofile/
-- loadfile/loadstring — spells can't reach them, same as on the device.
local SAFE = {}
for _, n in ipairs({
    "_VERSION", "assert", "collectgarbage", "coroutine", "error",
    "getmetatable", "ipairs", "math", "next", "pairs", "pcall", "print",
    "rawequal", "rawget", "rawlen", "rawset", "select", "setmetatable",
    "string", "table", "tonumber", "tostring", "type", "utf8", "warn",
    "xpcall",
}) do
    SAFE[n] = _G[n]
end

function M.makeEnv()
    local env = setmetatable({}, { __index = SAFE })
    env._G = env
    env.gfx = gfx
    env.input = input
    env.app = app
    env.system = system
    env.fs = fs
    env.zip = zip
    env.time = time
    env.wifi = wifi
    env.http = http
    env.json = json
    env.load = loadFn
    env.require = requireFn
    env.print = print
    return env
end

-- Harness can reach the raw API tables for assertions:
M.gfx = gfx
M.fs = fs
M.input = input
M.app = app
M.system = system
M.time = time
M.wifi_api = wifi
M.http_api = http
M.zip_api = zip
M.json_api = json
M.loadFn = loadFn
M.requireFn = requireFn
M.SAFE = SAFE

return M