-- TCP ping: times a TCP handshake to host:port, once per round. A refused connection still
-- shows the host answered. Only opens and closes sockets; nothing is sent and nothing is stored.

local LH = 26
local MAX_COUNT = 50
local ROUND_GAP_MS = 1000
local CONNECT_TIMEOUT_MS = 2000

local W, H = 0, 0

local function header(title)
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, title, "ui12", "bw")
end

local function show_message(lines)
  gfx.clear(); W, H = gfx.size()
  header("TCP Ping")
  local y = 60
  for _, l in ipairs(lines) do gfx.text(14, y, l, "ui12"); y = y + LH end
  gfx.text(14, H - 34, "back = leave", "small")
  gfx.present()
  while input.wait() ~= "back" do end
end

local function ask(title, initial, max_len)
  local s = input.text(title, initial, max_len)
  if s == nil or s == "" then return nil end
  return s
end

-- Runs `count` rounds against ip:port. Returns once finished or the user pressed Back.
local function run(host, ip, port, count)
  local sent, got, sum, lo, hi = 0, 0, 0, nil, nil
  local recent, last_err = {}, nil

  local function draw(status)
    gfx.clear(); W, H = gfx.size()
    header(("%s:%d"):format(host, port))
    local loss = sent > 0 and math.floor((sent - got) * 100 / sent) or 0
    gfx.text(14, 52, ("sent %d/%d   connected %d   failed %d%%"):format(sent, count, got, loss), "ui12")
    if got > 0 then
      gfx.text(14, 52 + LH, ("rtt min %d / avg %d / max %d ms"):format(lo, sum // got, hi), "ui12")
    else
      gfx.text(14, 52 + LH, "rtt: no connects yet", "ui12")
    end
    local y = 52 + 3 * LH
    for _, r in ipairs(recent) do gfx.text(14, y, r, "ui12"); y = y + LH end
    if last_err and got < sent then gfx.text(14, H - 70, "last: " .. last_err:sub(1, 50), "small") end
    gfx.text(14, H - 34, status, "small")
    gfx.present()
  end

  for round = 1, count do
    local t0 = system.millis()
    local h, err = net.connect(ip, port, { timeout_ms = CONNECT_TIMEOUT_MS })
    local rtt = system.millis() - t0
    sent = sent + 1
    local line
    if h then
      net.close(h)
      got = got + 1
      sum = sum + rtt
      lo = lo and math.min(lo, rtt) or rtt
      hi = hi and math.max(hi, rtt) or rtt
      line = ("#%d  %d ms  connected"):format(round, rtt)
    elseif err == "cancelled" then
      sent = sent - 1
      draw("stopped")
      return
    else
      last_err = tostring(err)
      line = ("#%d  --  %s"):format(round, last_err:sub(1, 30))
    end
    recent[#recent + 1] = line
    if #recent > 8 then table.remove(recent, 1) end
    draw(round < count and "next round in 1s  ·  back = stop" or "done  ·  back = leave")

    if round < count then
      -- wait for Back during the gap; input.wait returns nil when the gap ends
      local e = input.wait(ROUND_GAP_MS)
      if e == "back" then
        draw("stopped")
        return
      end
    end
  end

  -- stay on the summary until Back
  while input.wait() ~= "back" do end
end

local function __main()
  gfx.clear(); gfx.text(14, 14, "Connecting to WiFi...", "ui12"); gfx.present()
  local ok, why = wifi.connect({ tls = false })
  if not ok then
    show_message({ "WiFi failed:", tostring(why) })
    app.exit()
  end

  local info = net.info() or {}
  local host = info.gateway or ""

  while true do
    local h = ask("Host (name or IPv4)", host, 253)
    if not h then break end
    host = h
    local p = ask("Port", "80", 5)
    if not p then break end
    local port = math.tointeger(tonumber(p))
    if not port or port < 1 or port > 65535 then
      show_message({ "bad port: " .. p })
      break
    end
    local c = ask("Rounds (1-" .. MAX_COUNT .. ")", "5", 3)
    if not c then break end
    local count = math.tointeger(tonumber(c))
    if not count or count < 1 or count > MAX_COUNT then
      show_message({ "bad count: " .. c })
      break
    end

    gfx.clear(); W, H = gfx.size(); header("TCP Ping")
    gfx.text(14, 60, "resolving " .. host .. " ...", "ui12"); gfx.present()
    local ip, rerr = net.resolve(host)
    if not ip then
      show_message({ "cannot resolve " .. host, tostring(rerr) })
      break
    end
    run(host, ip, port, count)
  end
  app.exit()
end

local ok, err = pcall(__main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
  app.exit()
end
