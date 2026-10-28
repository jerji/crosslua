-- Mesh chat: broadcast text chat over ESP-NOW. Everyone on the same channel hears every message.
-- Frames are plaintext ("C1|nick|text"). Nothing is written to the card; history lives in RAM only.

local CHANNEL = 1
local MAX_LOG = 24
local H_STEP = 26

local W, H = 0, 0
local log = {}           -- { nick, text, mine }
local nick = "pup"
local my_mac = ""
local status = ""

local function clip(s, n) return #s > n and s:sub(1, n) or s end

local function add(n, t, mine)
  log[#log + 1] = { nick = n, text = t, mine = mine }
  if #log > MAX_LOG then table.remove(log, 1) end
end

local function on_frame(data, from)
  -- "C1|nick|text" ; nick never contains '|' (sanitised on send)
  local n, t = data:match("^C1|([^|]*)|(.*)$")
  if not n then return false end
  if t ~= nil and #t > 0 then add(n, t, false) end
  return true
end

local function draw()
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, "Mesh Chat  ch" .. CHANNEL, "ui12", "bw")
  gfx.text(W - 14, 12, "you: " .. nick, "small", "r")
  local rows = math.max(1, (H - 130) // H_STEP)
  local y = 56
  local first = math.max(1, #log - rows + 1)
  for i = first, #log do
    local m = log[i]
    local label = (m.mine and "> " or "") .. m.nick .. ": " .. m.text
    gfx.text(14, y, clip(label, 52), "small")
    y = y + H_STEP
  end
  if #log == 0 then gfx.text(14, 60, "Nobody has said anything yet.", "ui12") end
  gfx.text(14, H - 70, clip(status ~= "" and status or "Plaintext: anyone in range can read this.", 60), "small")
  gfx.text(14, H - 34, "Confirm = say something, Back = leave", "small")
  gfx.present()
end

local function drain()
  local got = false
  local data, from = espnow.recv()
  while data do
    if on_frame(data, from) then got = true end
    data, from = espnow.recv()
  end
  return got
end

local function say()
  local text = input.text("Say something", "", 120, "text")
  if not text or text == "" then return end
  -- ESP-NOW frame must stay <= 250 bytes; the chat line is "C1|nick|text"
  local safe_nick = nick:gsub("|", "")
  local frame = "C1|" .. safe_nick .. "|" .. text
  if #frame > 250 then frame = frame:sub(1, 250) end
  local ok, err = espnow.send("broadcast", frame)
  if ok then
    add(safe_nick, text, true)
    status = ""
  else
    status = "Send failed: " .. tostring(err)
  end
end

local function main()
  W, H = gfx.size()
  local n = input.text("Your name", "pup", 12, "text")
  if n and n ~= "" then nick = (n:gsub("|", "")) end   -- nick must not contain the frame separator
  local ok, mac = espnow.start({ channel = CHANNEL })
  if not ok then
    gfx.clear(); gfx.text(16, 60, "Could not start ESP-NOW:", "ui12")
    gfx.text(16, 90, clip(tostring(mac), 60), "small"); gfx.present()
    while input.wait() ~= "back" do end
    return
  end
  my_mac = mac or ""
  status = "Listening on channel " .. CHANNEL
  draw()
  local last = 0
  while true do
    local now = system.millis()
    local changed = drain()
    if changed or now - last >= 2000 then
      draw()
      last = now
    end
    local e = input.poll()
    if e == "confirm" then
      say()
      draw()
    elseif e == "back" then
      break
    end
    app.sleep(60)
  end
  espnow.stop()
end

local ok, err = pcall(main)
if not ok then
  pcall(function() espnow.stop() end)
  gfx.clear()
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b")
  gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
