-- shim.lua — Grimoire spell compatibility layer on top of CrossLua.
--
-- Grimoire (the other Lua runtime for the X4) gives spells a set of global
-- tables (display/input/fs/zip/time/system/wifi/ble/hid/net/image/require)
-- plus a base stdlib with no io/os/package/debug.  This file rebuilds that
-- surface on top of CrossLua's API (gfx/input/app/system/fs/zip/time/wifi/
-- http/json) so that unmodified Grimoire spells run as a CrossLua app.
--
-- Usage (see main.lua): call newSpellEnv() to get a fresh globals table for
-- one spell, load the spell with load(src, "@name", "t", env) and call it.
-- Returning from the chunk == spell exit, exactly like Grimoire.
--
-- Design rules:
--   * Every emulation table returns nil,err on failure rather than throwing,
--     matching both runtimes.  The ONE deliberate exception is the
--     not-yet-possible hardware APIs (ble/hid/net/image/wifi.startAP etc.):
--     those RAISE error("not supported on CrossLua yet (<name>)") because
--     real spells nil-dereference the result and then die with a confusing
--     "attempt to ..." message instead of a readable one.  net.isConnected /
--     net.available keep returning false / 0 since shared libs probe those
--     defensively.
--   * fs: reads of "/abs/path" hit 'sd:' (read-only whole SD); if a data:
--     copy exists it shadows the sd: copy (that's how write-then-read works
--     when sd: is read-only).  ALL writes/append/mkdir go to 'data:'.
--   * input: CrossLua delivers button RELEASES; Grimoire is poll-based with
--     edge events.  poll() = input.wait(30) (yields to the firmware), and
--     the event is held as 'pending' for exactly one poll cycle.
--   * require("lib.x") -> sd:spells/lib/x.lua, cached per load of this file
--     (per boot on device), modules run in the spell's env.

-- ---------------------------------------------------------------------------

local S = {}                      -- module returned to the launcher/tests

-- Readable error for hardware APIs CrossLua doesn't have yet (see the
-- "Hardware APIs" section below).
local function unsupported(name)
    error("not supported on CrossLua yet (" .. name .. ")", 0)
end

-- Grimoire maps its logical buttons to firmware pins and exposes logical
-- names: back confirm left right volup voldown power.  CrossLua delivers:
-- back confirm left right up down.  volup/voldown -> up/down; 'power' has no
-- equivalent and never fires (hold-Power is a firmware shutdown gesture).
local BTN = {
    back = "back",
    confirm = "confirm",
    left = "left",
    right = "right",
    volup = "up",
    voldown = "down",
}

-- Grimoire display.text(size) is an integer scale; CrossLua has fixed fonts.
local FONTS = { [1] = "small", [2] = "ui", [3] = "sans14", [4] = "sans18" }

-- ---------------------------------------------------------------------------
-- fs emulation.  Grimoire paths are absolute SD paths: "/spells/foo.lua".
-- ---------------------------------------------------------------------------

local function grimPath(p)
    if type(p) ~= "string" then return nil, "bad path" end
    local rel = p:gsub("^/+", "")
    if rel == "" then return nil, "bad path" end
    return rel
end

-- Path for a raw CrossLua read: the data: copy if one exists (write-redirect
-- shadowing), otherwise the read-only sd: location.
local function mappedPath(p)
    local rel = grimPath(p)
    if not rel then return nil, "bad path" end
    if fs.exists("data:" .. rel) then return "data:" .. rel end
    return "sd:" .. rel
end

local EmuFs = {}

function EmuFs.read(p)
    local rel = grimPath(p)
    if not rel then return nil, "bad path" end
    local d = fs.read("data:" .. rel)     -- "" is a valid 0-byte file
    if d then return d end
    return fs.read("sd:" .. rel)
end

function EmuFs.write(p, content)
    local rel = grimPath(p)
    if not rel then return false end
    return fs.write("data:" .. rel, content)   -- sd: is read-only by design
end

function EmuFs.append(p, content)
    local rel = grimPath(p)
    if not rel then return false end
    return fs.append("data:" .. rel, content)
end

function EmuFs.mkdir(p)
    local rel = grimPath(p)
    if not rel then return false end
    return fs.mkdir("data:" .. rel)
end

function EmuFs.exists(p)
    local rel = grimPath(p)
    if not rel then return false end
    return fs.exists("data:" .. rel) or fs.exists("sd:" .. rel)
end

-- Names without trailing slashes, data: entries first, then sd: ones.
function EmuFs.list(p)
    local rel = grimPath(p)
    if not rel then return nil, "bad path" end
    local names, seen = {}, {}
    local d = fs.list("data:" .. rel)
    if d then
        for _, n in ipairs(d) do
            local nn = n:gsub("/$", "")
            if not seen[nn] then names[#names + 1] = nn; seen[nn] = true end
        end
    end
    local s = fs.list("sd:" .. rel)
    if s then
        for _, n in ipairs(s) do
            local nn = n:gsub("/$", "")
            if not seen[nn] then names[#names + 1] = nn; seen[nn] = true end
        end
    end
    if #names == 0 and not d and not s then return nil, "not found" end
    return names
end

-- Load and run a .lua file from the SD card, same semantics as dofile:
-- load errors and runtime errors both propagate.  Runs in the caller's
-- spell environment (S.spellEnv), like Grimoire where one env is shared by
-- a spell and everything it pulls in.
function EmuFs.dofile(p)
    local src, err = EmuFs.read(p)
    if not src then error("cannot open " .. p .. ": " .. tostring(err), 0) end
    local chunk, lerr = load(src, "@" .. p, "t", S.spellEnv or _ENV)
    if not chunk then error(lerr, 0) end
    return chunk()
end

-- ---------------------------------------------------------------------------
-- display emulation (Grimoire color convention: true = black pixel).
-- ---------------------------------------------------------------------------

local EmuDisplay = {}

function EmuDisplay.clear() gfx.clear() end

function EmuDisplay.pixel(x, y, black) gfx.pixel(x, y, black ~= false) end

function EmuDisplay.line(x0, y0, x1, y1, black)
    gfx.line(x0, y0, x1, y1, black ~= false)
end

-- Grimoire order: rect(x, y, w, h, black, filled) — note black is 5th!
function EmuDisplay.rect(x, y, w, h, black, filled)
    gfx.rect(x, y, w, h, filled or false, black ~= false)
end

function EmuDisplay.text(x, y, str, size, black)
    local font = FONTS[size] or FONTS[2]           -- size default 2
    local flags = (black == false) and "w" or ""   -- white text flag
    return gfx.text(x, y, str, font, flags)
end

function EmuDisplay.refresh(full) gfx.present(full and "full" or "fast") end

-- CrossLua has no partial-region refresh; approximate with a present mode.
function EmuDisplay.refreshWindow(x, y, w, h, full)
    gfx.present(full and "full" or "fast")
end

function EmuDisplay.width() local w = gfx.size(); return w end
function EmuDisplay.height() local w, h = gfx.size(); return h end

-- 1bpp blit, Adafruit_GFX packed format: MSB first, each row padded to a
-- whole byte, exactly ceil(w/8)*h bytes.  It's a MASK (bit 1 draws in
-- `black`'s color, bit 0 leaves the pixel alone), like Grimoire's.
function EmuDisplay.bitmap(x, y, w, h, data, black)
    if type(data) ~= "string" then error("bitmap: data must be a string", 0) end
    w, h = math.floor(w), math.floor(h)
    local bprow = math.ceil(w / 8)
    if #data < bprow * h then error("bitmap: data too short", 0) end
    local color = (black == false) and false or true
    for row = 0, h - 1 do
        local base = row * bprow
        for col = 0, w - 1 do
            local byte = data:byte(base + math.floor(col / 8) + 1)
            local on = (byte // (2 ^ (7 - col % 8))) % 2 == 1
            if on then gfx.pixel(x + col, y + row, color) end
        end
    end
end

-- ---------------------------------------------------------------------------
-- input emulation.  CrossLua only delivers button RELEASES; Grimoire spells
-- call poll() then query pressed()/released()/down() with edge semantics.
-- ---------------------------------------------------------------------------

local EmuInput = {}
local pending = nil   -- last CrossLua event, held for exactly one poll cycle

function EmuInput.poll()
    pending = input.wait(30)   -- yields to the firmware; nil on timeout
end

local function fired(name)
    local raw = BTN[name]
    return raw ~= nil and pending == raw
end

-- Edge-triggered: true for one poll cycle on press and on release (CrossLua
-- can't distinguish, so both fire together; down() can't be emulated).
function EmuInput.pressed(name) return fired(name) end
function EmuInput.released(name) return fired(name) end
function EmuInput.down(name) return false end   -- documented limitation

-- ---------------------------------------------------------------------------
-- time / system emulation
-- ---------------------------------------------------------------------------

local EmuTime = {}

function EmuTime.uptime() return system.millis() end
function EmuTime.now() return time.now() end
function EmuTime.set(epoch) return time.set(epoch) end

-- Grimoire passes (server, timeoutSeconds, gmtOffset, dstOffset); CrossLua
-- syncs against its own NTP configuration and takes only a timeout.
function EmuTime.sync(server, timeoutS, gmt, dst)
    if time.sync(timeoutS) then return true end
    return false, "sync failed"
end

local EmuSystem = {}

function EmuSystem.info()
    local free = system.heap()
    return { version = "crosslua", freeHeap = free }
end
function EmuSystem.batteryPercent() return system.battery() end
function EmuSystem.usbConnected() return false end
function EmuSystem.radioOff() wifi.off(); return true end
function EmuSystem.radioState()
    local st = wifi.status()
    if st and st.connected then return "wifi" end
    return "off"
end
function EmuSystem.reboot() return false, "not supported on CrossLua" end
function EmuSystem.sleep(seconds) return false, "not supported on CrossLua" end
function EmuSystem.startSdFlash(path) return false, "not supported on CrossLua" end

-- Sentinel strings exist for API compatibility, but CrossLua has no
-- Settings/Shutdown long-press gestures (hold-Back quits the app at the
-- firmware level and is never delivered to Lua).
EmuSystem.SETTINGS_INTERRUPT = "SETTINGS_INTERRUPT"
EmuSystem.SHUTDOWN_INTERRUPT = "SHUTDOWN_INTERRUPT"

-- ---------------------------------------------------------------------------
-- wifi / http emulation.  SECURITY: connect() ignores any ssid/password the
-- spell hands it — CrossLua joins the system's saved network with no
-- credentials, so a spell can never push credentials into the firmware.
-- ---------------------------------------------------------------------------

local EmuWifi = {}

function EmuWifi.connect(ssid, pass, timeout)
    -- SECURITY: never forward ssid/pass to the firmware — CrossLua joins
    -- the system's saved network with no credentials.
    return wifi.connect()
end

function EmuWifi.disconnect() wifi.off(); return true end

function EmuWifi.isConnected()
    local st = wifi.status()
    return (st and st.connected) or false
end

function EmuWifi.ip()
    local st = wifi.status()
    if st and st.connected then return st.ip end
    return nil
end

-- Grimoire: request(method, url, body, headers) -> body, statusCode.
-- CrossLua http.request returns {status, ok, bytes, body} | nil, err.
function EmuWifi.request(method, url, body, headers)
    local r, err = http.request{
        url = url,
        method = method or "GET",
        headers = headers or {},
        body = body,
    }
    if not r then
        if err == "cancelled" then return nil, 0 end
        return nil, 0   -- status 0 = no response, like Grimoire
    end
    return r.body or "", r.status
end

function EmuWifi.get(url, body, headers)
    return EmuWifi.request("GET", url, body, headers)
end

function EmuWifi.scan()
    local list = wifi.scan()   -- list, total | nil, err
    return list
end

-- AP mode doesn't exist on CrossLua (it only joins saved networks).
EmuWifi.startAP = function(ssid, password) return unsupported("startAP") end
EmuWifi.apIP = function() return unsupported("apIP") end
EmuWifi.stopAP = function() return unsupported("stopAP") end

-- ---------------------------------------------------------------------------
-- zip emulation (read-only archives).
-- ---------------------------------------------------------------------------

local EmuZip = {}

function EmuZip.list(p)
    local zp = mappedPath(p)
    if not zp then return nil end
    local entries, total = zip.list(zp, 128)
    if not entries then return nil, "not a zip" end
    local out = {}
    for _, e in ipairs(entries) do
        out[#out + 1] = { name = e.name, size = e.size,
                          compressedSize = e.size, method = 8 }
    end
    return out
end

function EmuZip.read(p, inner)
    local zp = mappedPath(p)
    if not zp then return nil, "bad path" end
    local data, err = zip.read(zp, inner)
    if not data then return nil, err end
    return data
end

function EmuZip.inflate(bytes, asZlib)
    local out, err = zip.inflate(bytes, asZlib)
    if not out then return nil, err end
    return out
end

-- ---------------------------------------------------------------------------
-- Hardware APIs CrossLua does not have yet (ble, hid, net, image, AP mode).
-- These RAISE a readable error instead of returning nil: shipped spells
-- crash on a nil return ("attempt to get length of a nil value" etc.)
-- before any of them check the error value, so returning nil,err produces
-- an unreadable failure while error() gives the launcher a clear message.
-- net.isConnected()/net.available() keep returning false/0 because shared
-- event-loop libs probe those defensively.
-- ---------------------------------------------------------------------------

S.UNSUPPORTED = {
    ble = { "scan", "stop", "connect", "disconnectClient", "isClientConnected",
            "findCharacteristic", "subscribeNotify", "pollNotify",
            "readCharacteristic", "writeCharacteristic" },
    hid = { "begin", "stop", "isConnected", "type", "key", "media" },
    net = { "listen", "accept", "closeServer", "connect", "read", "write",
            "close" },
    wifi = { "startAP", "apIP", "stopAP" },
}

local EmuBle, EmuHid, EmuNet = {}, {}, {}
for _, fn in ipairs(S.UNSUPPORTED.ble) do
    EmuBle[fn] = function() return unsupported(fn) end
end
for _, fn in ipairs(S.UNSUPPORTED.hid) do
    EmuHid[fn] = function() return unsupported(fn) end
end
for _, fn in ipairs(S.UNSUPPORTED.net) do
    EmuNet[fn] = function() return unsupported(fn) end
end
-- image.*: PNG/JPEG via gfx.image (decoded by the firmware, streamed, dithered to 1-bit). A handle is a tiny
-- table; width/height come from the PNG header (IHDR) so open() never decodes anything. gfx.image fits the image
-- into the w,h box (never upscales) and centres it, which is what spells like gallery.lua already ask for.
local EmuImage = {}
local PNG_SIG = "\137PNG\r\n\26\n"
function EmuImage.open(path)
    local rel, e = grimPath(path)
    if not rel then return nil, e end
    local p = "sd:" .. rel
    local hdr, err = fs.read(p, 0, 24)
    if not hdr then return nil, err or "cannot open image" end
    if #hdr < 24 or hdr:sub(1, 8) ~= PNG_SIG then return nil, "not a PNG file" end
    local w, h = string.unpack(">I4I4", hdr, 17)
    return { p = p, w = w, h = h }
end
function EmuImage.width(img) return img.w end
function EmuImage.height(img) return img.h end
function EmuImage.draw(img, x, y, w, h)
    if not img.p then return nil, "image is closed" end
    local dw, err = gfx.image(img.p, x, y, w or img.w, h or img.h)
    if not dw then return nil, err end
    return true
end
function EmuImage.close(img) img.p = nil end
EmuNet.isConnected = function() return false end
EmuNet.available = function() return 0 end

-- ---------------------------------------------------------------------------
-- require(): Grimoire's loader.  "lib.format" -> /spells/lib/format.lua,
-- dots become slashes.  Modules are cached (like Grimoire's _G.__loaded),
-- run in the CORRECT spell env, and errors if missing.
-- ---------------------------------------------------------------------------

local loaded = {}   -- per-boot module cache (this file loads once per boot)

local function doRequire(name)
    if type(name) ~= "string" then error("bad argument #1 to 'require' (string expected)", 0) end
    local mod = loaded[name]
    if mod then return mod end
    local file = "/spells/" .. name:gsub("%.", "/") .. ".lua"
    local src, err = EmuFs.read(file)
    if not src then
        error("module '" .. name .. "' not found (" .. file .. "): " .. tostring(err), 0)
    end
    local chunk, lerr = load(src, "@" .. file, "t", S.spellEnv or _ENV)
    if not chunk then error(lerr, 0) end
    local ok, res = pcall(chunk)
    if not ok then error(res, 0) end       -- module errors propagate
    loaded[name] = res
    -- Grimoire also records modules in the spell's _G.__loaded; mirror it so
    -- spells that inspect the cache still work.
    local env = S.spellEnv
    if env then
        if type(env.__loaded) ~= "table" then env.__loaded = {} end
        env.__loaded[name] = res
    end
    return res
end

-- ---------------------------------------------------------------------------
-- The spell globals.  Safe stdlib ONLY: base + math/string/table/utf8/
-- coroutine + print + unpack alias.  No io, os, package, debug, dofile,
-- loadfile, or load — matches both runtimes' sandbox.
-- ---------------------------------------------------------------------------

S.globals = {
    display = EmuDisplay,
    input = EmuInput,
    fs = EmuFs,
    zip = EmuZip,
    time = EmuTime,
    system = EmuSystem,
    wifi = EmuWifi,
    ble = EmuBle,
    hid = EmuHid,
    net = EmuNet,
    image = EmuImage,
    require = doRequire,
    -- stdlib
    math = math, string = string, table = table, utf8 = utf8,
    coroutine = coroutine,
    pcall = pcall, error = error, ipairs = ipairs, pairs = pairs,
    tostring = tostring, tonumber = tonumber, type = type, select = select,
    next = next, rawget = rawget, rawset = rawset, rawequal = rawequal,
    setmetatable = setmetatable, getmetatable = getmetatable,
    assert = assert, print = print, collectgarbage = collectgarbage,
    unpack = table.unpack or unpack, _VERSION = _VERSION,
}

-- Fresh globals table for one spell; __index chains to the shim tables.
function S.newSpellEnv()
    local env = {}
    env._G = env
    return setmetatable(env, { __index = S.globals })
end

-- The env of the spell currently running (for fs.dofile / require).  Set by
-- the launcher around chunk execution.
S.spellEnv = nil

return S