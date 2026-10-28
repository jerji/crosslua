-- Host test for ble_spam_lua: stubs the device namespaces, replays a scripted button
-- sequence through both menus, and asserts on the actual advertise payloads.
-- NOT shipped logic — verification only (see WRITING_APPS.md §7).

local fails = 0
local function assert_eq(a, b, what)
  if a ~= b then
    print("FAIL: " .. tostring(what) .. " -> got " .. tostring(a) .. ", want " .. tostring(b))
    fails = fails + 1
  end
end

-- Byte-exact expected advert options, computed independently.
local function hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

-- Stub namespaces ------------------------------------------------------------
local adv_calls = {}   -- list of option tables passed to ble.advertise
local stopped = 0
local started, stop_called = false, false

ble = {}
function ble.start(mode)
  assert_eq(mode, "raw", "ble.start mode")
  started = true
  return true
end
function ble.stop()
  stop_called = true
  return true
end
function ble.advertise(opt)
  table.insert(adv_calls, opt)
  return true
end
function ble.advertise_stop()
  stopped = stopped + 1
  return true
end
function ble.advertising() return started end

gfx = {}
local function gfx_noop() end
gfx.clear, gfx.present, gfx.rect, gfx.text = gfx_noop, gfx_noop, gfx_noop, gfx_noop
function gfx.size() return 480, 800 end

-- Scripted input: a queue of events consumed by input.wait().
local queue = {}
input = {}
function input.wait()
  local e = table.remove(queue, 1)
  assert(e, "input queue drained unexpectedly")
  return e
end

app = {}
function app.exit() app.exited = true end
function app.uptime() return 1234 end

math.randomseed(42)

-- Load the app ---------------------------------------------------------------
local chunk = assert(loadfile("main.lua"))

-- Sequence: warning -> protocol menu -> Fast Pair -> advertise Bose -> stop ->
-- switch down twice (re-advertise) -> back to protocol -> Swift Pair -> advertise
-- "Mouse" -> back -> back (exit).
queue = {
  "confirm",            -- warning: continue
  "confirm",            -- protocol: open Fast Pair
  "confirm",            -- fastpair: advertise Bose NC 700 (first item)
  "confirm",            -- stop
  "down", "confirm",    -- move to JBL Buds Pro, advertise
  "down", "confirm",    -- move to JBL Live 300TWS, advertise
  "back",               -- fastpair menu -> protocol menu
  "down", "confirm",    -- protocol: open Swift Pair
  "down", "confirm",    -- swift: move to "Mouse", advertise
  "back",               -- swift menu -> protocol menu
  "back",               -- protocol menu -> exit
}
chunk()

-- Assertions ------------------------------------------------------------------
assert_eq(started, true, "ble.start raw was called")
assert_eq(stop_called, true, "ble.stop was called")
assert_eq(app.exited, true, "app.exit was reached")
assert_eq(stopped, 4, "advertise_stop count (fastpair off, swift off, and teardown pcall)")

-- Ad 1: Fast Pair Bose NC 700, Tx Power 0
local a1 = adv_calls[1]
assert_eq(a1.service_uuid, 0xFE2C, "fastpair service_uuid")
assert_eq(hex(a1.service_data), "cd825600", "fastpair Bose service_data (model BE + tx 0)")
assert_eq(a1.connectable, false, "fastpair not connectable")
assert_eq(a1.interval_ms, 100, "fastpair interval")
assert_eq(a1.name, nil, "fastpair sends no name")

-- Ads 2 and 3: JBL Buds Pro, JBL Live 300TWS
assert_eq(hex(adv_calls[2].service_data), "f5249400", "fastpair JBL Buds Pro service_data")
assert_eq(hex(adv_calls[3].service_data), "718fa400", "fastpair JBL Live 300TWS service_data")

-- Ad 4: Swift Pair "Mouse"
local a4 = adv_calls[4]
assert_eq(a4.name, "Mouse", "swift pair name")
assert_eq(hex(a4.data), "0600030080", "swift pair manufacturer data")
assert_eq(a4.connectable, false, "swift pair not connectable")
assert_eq(a4.service_uuid, nil, "swift pair has no service data")

-- Random-model entry: load the app's builders in isolation (strip the trailing run) and check
-- that random_model_id + fastpair_options always emit a valid 4-byte payload with a nonzero ID.
local src = {}
for line in io.lines("main.lua") do src[#src + 1] = line end
local builders = table.concat(src, "\n")
local cut = builders:find("%-%- UI ")          -- everything up to the UI section is pure builders
-- Load the pure builder section with its own environment so the locals are reachable via
-- load(...)(env) semantics: in Lua 5.4 the chunk runs with _ENV bound to the first upvalue,
-- so wrap the source in a function taking `env` as _ENV.
local bchunk = assert(load(
  "local _ENV = ...; " .. builders:sub(1, cut - 1)
    .. " return { swift_pair_options = swift_pair_options, fastpair_options = fastpair_options,"
    .. " random_model_id = random_model_id }",
  "=builders"
))
local env = setmetatable({}, { __index = _G })
env = bchunk(env)  -- the builders chunk returns its exported functions
for i = 1, 50 do
  local id = env.random_model_id()
  assert(id ~= 0, "random_model_id never yields 0x000000")
  assert(id < 0x1000000, "random_model_id fits 24 bits")
  local o = env.fastpair_options(id, 0x0A)
  assert_eq(#o.service_data, 4, "random fastpair service_data is 4 bytes")
  local m = id % 0x1000000
  local want = string.char((m >> 16) & 0xFF, (m >> 8) & 0xFF, m & 0xFF, 0x0A)
  assert_eq(o.service_data, want, "random fastpair service_data bytes, iter " .. i)
  assert_eq(o.service_uuid, 0xFE2C, "random fastpair service_uuid")
end
-- fastpair_options truncates an oversized ID to 24 bits.
local o24 = env.fastpair_options(0x1234567, 0)
assert_eq(hex(o24.service_data), "23456700", "fastpair_options masks to 24 bits")
-- swift_pair_options shape.
local so = env.swift_pair_options("Headset")
assert_eq(so.name, "Headset", "swift_pair_options name")
assert_eq(hex(so.data), "0600030080", "swift_pair_options data")
