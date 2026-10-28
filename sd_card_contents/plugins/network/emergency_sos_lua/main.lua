-- Emergency SOS (ESP-NOW leg, ACTIVE on send): repeats an SOS frame every 3 s and shows SOS frames heard
-- from other devices. Target: BROADCAST (everyone in range) or ONE device, picked from the devices heard.
--
-- NOT IMPLEMENTED: the softAP status-page leg (roadmap CORE #19: softAP + ESP-NOW coexistence). This build
-- sends only the ESP-NOW beacon leg.

local SEND_MS = 3000
local MAX_HEARD = 12
local LH = 24

local function txt(...) return input.text(...) or "" end

local function parse(data)
  local tag, nick, text, seq = data:match("^SOS|([^|]*)|([^|]*)|(%d+)$")
  if not tag then return nil end
  return { nick = nick, text = text, seq = tonumber(seq) }
end

local function main()
  local W, H = gfx.size()
  local nick = txt("Your name", "pup", 12):gsub("|", "")
  local text = txt("SOS message", "I need help", 60):gsub("|", "")
  local ok, mac = espnow.start({ channel = 1 })
  if not ok then error("espnow: " .. tostring(mac)) end

  -- target: nil = broadcast; otherwise a MAC from the heard list
  local heard, heard_order = {}, {}
  local target = nil
  local seq = 0
  local last_send = -1000
  local last_draw = -1000
  local cur = 1

  local function draw()
    gfx.clear(); W, H = gfx.size()
    gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Emergency SOS (ACTIVE)", "ui12", "bw")
    gfx.text(14, 52, "target: " .. (target and target or "ALL (broadcast)"), "small")
    gfx.text(14, 76, "sent " .. seq .. "   your MAC " .. tostring(mac), "small")
    local y = 104
    gfx.text(14, y, "heard SOS:", "ui12"); y = y + 28
    local n = 0
    for _, m in ipairs(heard_order) do
      if n >= MAX_HEARD then break end
      local h = heard[m]
      gfx.text(14, y, string.format("%s  %s  #%d", m, h.nick:sub(1, 10), h.seq), "small")
      y = y + LH; n = n + 1
    end
    if n == 0 then gfx.text(14, y, "(none yet)", "small") end
    gfx.text(14, H - 60, "Up/Down = pick target (broadcast / heard device)", "small")
    gfx.text(14, H - 34, "Back = stop", "small")
    gfx.present()
  end

  draw()
  while true do
    local now = system.millis()
    if now - last_send >= SEND_MS then
      seq = seq + 1
      local frame = string.format("SOS|%s|%s|%d", nick, text, seq)
      if target then espnow.send(target, frame) else espnow.send("broadcast", frame) end
      last_send = now
    end
    local data, from = espnow.recv()
    while data do
      local m = parse(data)
      if m and from then
        if not heard[from] then heard_order[#heard_order + 1] = from end
        heard[from] = m
      end
      data, from = espnow.recv()
    end
    if now - last_draw >= 1000 then draw(); last_draw = now end
    local e = input.poll()
    if e == "back" then break end
    if e == "down" or e == "up" then
      local opts = { false }                  -- false = broadcast
      for _, m in ipairs(heard_order) do opts[#opts + 1] = m end
      cur = cur + (e == "down" and 1 or -1)
      if cur < 1 then cur = #opts elseif cur > #opts then cur = 1 end
      target = opts[cur] or nil
      draw()
    end
    app.sleep(20)
  end
  espnow.stop()
end

local ok2, err = pcall(main)
pcall(function() espnow.stop() end)
if not ok2 then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
