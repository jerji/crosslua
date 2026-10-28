-- DNS lookup: resolves a host name with the device's configured DNS server (net.resolve).
-- The firmware returns one IPv4 address per name; there is no reverse lookup or record-type query.

local LH = 26
local HISTORY_MAX = 10   -- lines kept (and shown) on screen

local W, H = 0, 0

local function header(title)
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, title, "ui12", "bw")
end

local function draw(lines, hint, dns)
  gfx.clear(); W, H = gfx.size()
  header("DNS Lookup")
  local y = 52
  for _, l in ipairs(lines) do gfx.text(14, y, l, "ui12"); y = y + LH end
  if dns then gfx.text(14, H - 60, "resolver: " .. dns, "small") end
  gfx.text(14, H - 34, hint, "small")
  gfx.present()
end

local function __main()
  gfx.clear(); gfx.text(14, 14, "Connecting to WiFi...", "ui12"); gfx.present()
  local ok, why = wifi.connect({ tls = false })
  if not ok then
    draw({ "WiFi failed:", tostring(why) }, "back = exit")
    while input.wait() ~= "back" do end
    app.exit()
  end

  local info = net.info() or {}
  local dns = info.dns
  local history = {}   -- newest last: "host -> ip" or "host -> error"

  while true do
    local lines = {}
    for i = math.max(1, #history - HISTORY_MAX + 1), #history do lines[#lines + 1] = history[i] end
    if #lines == 0 then lines[1] = "Confirm = type a host name." end
    draw(lines, "confirm = new lookup  ·  back = exit", dns)

    local e = input.wait()
    if e == "back" then break end
    if e == "confirm" then
      local host = input.text("Host name to resolve", "", 253)
      if host and host ~= "" then
        draw({ "resolving " .. host .. " ..." }, "please wait", dns)
        local ip, err = net.resolve(host)
        local line
        if ip then
          line = host .. " -> " .. ip
        else
          line = host .. " -> " .. tostring(err)
        end
        history[#history + 1] = line
        while #history > HISTORY_MAX do table.remove(history, 1) end
      end
    end
  end
  app.exit()
end

local ok, err = pcall(__main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
  app.exit()
end
