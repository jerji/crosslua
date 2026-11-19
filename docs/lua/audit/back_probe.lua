-- Static-host probe: runs one CrossLua app's main.lua against stubbed device APIs.
-- usage: lua5.4 probe2.lua <app_dir> <seed> <prefix_len> <back_budget>
-- Feeds a random nav prefix, then "back" events. Reports whether the app exits,
-- and how many back events were ignored (no exit, no screen change).
local appdir, seed, prefixLen, backBudget = arg[1], tonumber(arg[2]), tonumber(arg[3]), tonumber(arg[4])
math.randomseed(seed)
local SEQ, ev_i = {}, 0
local draw_hash = 0
local modes = {}
local function h(s)
  s = tostring(s)
  for i = 1, #s do draw_hash = (draw_hash * 31 + s:byte(i)) % 2147483647 end
end
local function mkns(name, extra)
  local t = extra or {}
  return setmetatable(t, { __index = function(_, k)
    return function(...) h(name .. "." .. tostring(k)); return 0 end
  end })
end
local gfx = mkns("gfx", {
  width = 480, height = 800,
  text = function(x, y, s) h("T" .. tostring(x) .. "," .. tostring(y) .. tostring(s)); return 10, 10 end,
  text_width = function(s) return #tostring(s) * 8 end,
  present = function() h("P") end,
  clear = function() h("C") end,
  size = function() return 480, 800 end,
  line_height = function() return 16 end,
  text_height = function() return 16 end,
  line = function() h("L") end,
})
local input = mkns("input", {
  wait = function() return coroutine.yield("need") end,
  poll = function() if ev_i < #SEQ then ev_i = ev_i + 1; return SEQ[ev_i] end return nil end,
  pos = function() return nil end,
  key = function() return nil end,
  text = function() return nil, "cancelled" end,
})
local app = mkns("app", {
  exit = function() io.stderr:write("EXIT TRACE\n", debug.traceback(), "\n"); coroutine.yield("exit") end,
  name = function() return "probe" end,
  dir = function() return appdir end,
  sleep = function() end,
})
local device = mkns("device", {
  caps = function() return { touch = true, width = 480, height = 800, model = "x4pro", vector_fonts = true, frontlight = false } end,
  input_mode = function(m) modes[#modes + 1] = m; return nil end,
})
local time = mkns("time", { millis = function() return 0 end, now = function() return 0 end })
_G.gfx, _G.input, _G.app, _G.device, _G.time = gfx, input, app, device, time
_G.print = print
for _, n in ipairs({ "fs", "json", "wifi", "http", "net", "zip", "epub", "crypto", "led", "system", "ble", "espnow", "mic", "audio", "tx", "monitor", "sock", "haptic" }) do
  _G[n] = mkns(n)
end
_G.fs = mkns("fs", { list = function() return {} end, exists = function() return false end, read = function() return nil end })
-- yieldable require: modules may call input.wait
_G.require = function(name)
  local p = appdir .. "/" .. (name:gsub("%.", "/")) .. ".lua"
  local f = loadfile(p)
  if not f then error("module not found: " .. name) end
  return f(name) or true
end

local nav = { "confirm", "left", "right", "up", "down" }
for _ = 1, prefixLen do SEQ[#SEQ + 1] = (arg[5] == "confirm") and "confirm" or nav[math.random(#nav)] end
for _ = 1, backBudget do SEQ[#SEQ + 1] = "back" end

local co = coroutine.create(function()
  local chunk, err = loadfile(appdir .. "/main.lua")
  if not chunk then error(err) end
  return chunk()
end)
debug.sethook(co, function() error("BUDGET: instruction limit") end, "", 5000000)

local result = { exit = false, err = nil, backs = 0, ignoredBacks = 0, backsToExit = nil }
local ok, kind = coroutine.resume(co)
local guard = 0
while true do
  guard = guard + 1
  if guard > 50000 then result.err = "driver guard"; break end
  if not ok then result.err = tostring(kind) .. " @ " .. debug.traceback(co); break end
  if coroutine.status(co) == "dead" then result.exit = true; break end
  if kind == "exit" then result.exit = true; break end
  if kind == "need" then
    if ev_i >= #SEQ then result.err = "stuck: waiting for input after queue end"; break end
    ev_i = ev_i + 1
    local e = SEQ[ev_i]
    local before = draw_hash
    if e == "back" then result.backs = result.backs + 1 end
    ok, kind = coroutine.resume(co, e)
    if e == "back" and ev_i > prefixLen then
      if kind ~= "exit" and coroutine.status(co) ~= "dead" and draw_hash == before then
        result.ignoredBacks = result.ignoredBacks + 1
      end
    end
    if e == "back" and result.backsToExit == nil and (kind == "exit" or coroutine.status(co) == "dead") then
      result.backsToExit = result.backs
    end
  else
    ok, kind = coroutine.resume(co)
  end
end
print(string.format("RESULT exit=%s err=%s backsSent=%d ignoredBacks=%d backsToExit=%s modes=%s",
  tostring(result.exit), tostring(result.err), result.backs, result.ignoredBacks,
  tostring(result.backsToExit), table.concat(modes, ",")))
