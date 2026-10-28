-- Host scanner: TCP-connect sweep of a /24 on a list of ports.
-- Only opens and closes TCP connections (no data is sent). Results stay in RAM; nothing is written to the card.

local LH = 26            -- line step for ui12 text
local SCAN_TIMEOUT_MS = 400
local MAX_PORTS = 16
local MAX_RESULTS = 64   -- open hosts kept in RAM; the count still goes past this

local W, H = 0, 0

local function header(title)
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, title, "ui12", "bw")
end

local function footer(text)
  gfx.text(14, H - 34, text, "small")
end

-- Vertical menu: up/down move, confirm picks (returns index), back returns nil.
local menu_cur = 1   -- persists across menu() calls so actions don't reset the highlight
local function menu(title, items, hint)
  while true do
    gfx.clear()
    W, H = gfx.size()
    header(title)
    local y = 60
    for i, label in ipairs(items) do
      if i == menu_cur then
        gfx.rect(10, y - 4, W - 20, LH + 4, true)
        gfx.text(18, y, label, "ui12", "w")
      else
        gfx.text(18, y, label, "ui12")
      end
      y = y + LH + 8
    end
    footer(hint)
    gfx.present()
    local e = input.wait()
    if e == "up" then
      menu_cur = menu_cur > 1 and menu_cur - 1 or #items
    elseif e == "down" then
      menu_cur = menu_cur < #items and menu_cur + 1 or 1
    elseif e == "confirm" then
      return menu_cur
    elseif e == "back" then
      return nil
    end
  end
end

local function parse_ports(s)
  local ports, seen = {}, {}
  for part in s:gmatch("[^,%s]+") do
    local n = math.tointeger(tonumber(part))
    if not n or n < 1 or n > 65535 then return nil, "bad port: " .. part end
    if not seen[n] then
      seen[n] = true
      ports[#ports + 1] = n
    end
    if #ports > MAX_PORTS then return nil, "at most " .. MAX_PORTS .. " ports" end
  end
  if #ports == 0 then return nil, "no ports given" end
  return ports
end

local function ports_text(ports)
  local t = {}
  for i, p in ipairs(ports) do t[i] = tostring(p) end
  return table.concat(t, ",")
end

local function valid_base(s)
  local a, b, c = s:match("^(%d+)%.(%d+)%.(%d+)$")
  if not a then return false end
  for _, o in ipairs({ a, b, c }) do
    if tonumber(o) > 255 then return false end
  end
  return true
end

-- Sweep .1..254 of base. Returns found list, open count, and a stop reason if it did not finish.
local function scan(base, ports)
  local found, open_total, stop = {}, 0, nil
  for i = 1, 254 do
    local ip = base .. "." .. i
    if i % 8 == 1 then
      gfx.clear(); header("Scanning " .. base .. ".0/24")
      gfx.text(14, 60, ("host %s"):format(ip), "ui12")
      gfx.text(14, 60 + LH, ("open so far: %d"):format(open_total), "ui12")
      footer("Back = stop")
      gfx.present("fast")
    end
    if input.poll() == "back" then
      stop = "stopped by you"
      break
    end
    for _, p in ipairs(ports) do
      local h, err = net.connect(ip, p, { timeout_ms = SCAN_TIMEOUT_MS })
      if h then
        net.close(h)
        open_total = open_total + 1
        if #found < MAX_RESULTS then found[#found + 1] = { ip = ip, port = p } end
      elseif err == "cancelled" then
        stop = "stopped by you"
        break
      elseif err and err:find("RAM", 1, true) then
        stop = "out of RAM: " .. err
        break
      end
    end
    if stop then break end
  end
  return found, open_total, stop
end

local function show_results(base, found, open_total, stop)
  local top = 1
  while true do
    gfx.clear()
    W, H = gfx.size()
    header(("%d open  %s.0/24"):format(open_total, base))
    local per = (H - 130) // LH
    local y = 56
    if #found == 0 then
      gfx.text(14, y, "nothing answered", "ui12")
    end
    for r = top, math.min(#found, top + per - 1) do
      local f = found[r]
      gfx.text(14, y, ("%-15s :%d"):format(f.ip, f.port), "ui12")
      y = y + LH
    end
    if open_total > #found then
      gfx.text(14, y, ("+%d more not listed"):format(open_total - #found), "small")
    end
    if stop then gfx.text(14, H - 60, stop, "small") end
    footer("up/down scroll  ·  back = done")
    gfx.present()
    local e = input.wait()
    if e == "up" and top > 1 then
      top = top - 1
    elseif e == "down" and top + per <= #found then
      top = top + 1
    elseif e == "back" or e == "confirm" then
      return
    end
  end
end

local function __main()
  gfx.clear(); gfx.text(14, 14, "Connecting to WiFi...", "ui12"); gfx.present()
  local ok, why = wifi.connect({ tls = false })
  if not ok then
    gfx.clear(); gfx.text(14, 14, "WiFi failed:", "ui12", "b")
    gfx.text(14, 40, tostring(why), "ui12"); gfx.present()
    while input.wait() ~= "back" do end
    app.exit()
  end

  local info = net.info() or {}
  local base = info.ip and info.ip:match("^(%d+%.%d+%.%d+)%.%d+$")
  if not base then
    gfx.clear(); gfx.text(14, 14, "No IPv4 address yet; join WiFi first.", "ui12"); gfx.present()
    while input.wait() ~= "back" do end
    app.exit()
  end
  local ports = { 22, 80, 443, 8080 }

  while true do
    local pick = menu("Host Scanner", {
      "Scan " .. base .. ".0/24",
      "Ports: " .. ports_text(ports),
      "Change subnet",
    }, "confirm = pick  ·  back = exit")
    if not pick then break end

    if pick == 1 then
      local found, open_total, stop = scan(base, ports)
      show_results(base, found, open_total, stop)
    elseif pick == 2 then
      local s = input.text("Ports (comma list)", ports_text(ports), 64)
      if s then
        local p, err = parse_ports(s)
        if p then ports = p else
          gfx.clear(); gfx.text(14, 14, tostring(err), "ui12"); gfx.present()
          input.wait()
        end
      end
    elseif pick == 3 then
      local s = input.text("Subnet, first three octets", base, 15)
      if s then
        if valid_base(s) then base = s else
          gfx.clear(); gfx.text(14, 14, "not a valid a.b.c", "ui12"); gfx.present()
          input.wait()
        end
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
