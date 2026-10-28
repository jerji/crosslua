-- Port knocker (network): join WiFi, then open and close a TCP connection to each port in a typed
-- sequence, in order, with a short gap. Only TCP connects are sent; no payload. Target and ports are typed.
-- Use it against hosts you run or are testing: a knock sequence is only meaningful to a listener you control.

local GAP_MS = 250
local TIMEOUT_MS = 1500

local function parse_ports(s)
  local out = {}
  for part in s:gmatch("[^,%s]+") do
    local n = math.tointeger(tonumber(part))
    if not n or n < 1 or n > 65535 then return nil, "bad port: " .. part end
    out[#out + 1] = n
  end
  if #out == 0 then return nil, "no ports" end
  return out
end

local function show(lines)
  gfx.clear()
  local W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Port knocker", "ui12", "bw")
  local y = 56
  for _, l in ipairs(lines) do gfx.text(14, y, l, "ui12"); y = y + 26 end
  gfx.text(14, H - 34, "Back = exit", "small")
  gfx.present()
end

local function main()
  show({ "Connecting to WiFi..." })
  local ok, why = wifi.connect({ tls = false })
  if not ok then show({ "WiFi failed:", tostring(why) }); while input.wait() ~= "back" do end; return end
  local host = input.text("Target host or IPv4", "", 60)
  if not host or host == "" then return end
  local ports_text = input.text("Knock ports, in order", "", 120)
  local ports, perr = parse_ports(ports_text or "")
  if not ports then show({ perr }); while input.wait() ~= "back" do end; return end
  local log = {}
  for i, p in ipairs(ports) do
    local h, err = net.connect(host, p, { timeout_ms = TIMEOUT_MS })
    if h then
      net.close(h)
      log[#log + 1] = string.format("%d. %d  open", i, p)
    else
      log[#log + 1] = string.format("%d. %d  %s", i, p, tostring(err))
    end
    show(log)
    app.sleep(GAP_MS)
  end
  log[#log + 1] = "sequence sent. Back to exit."
  show(log)
  while input.wait() ~= "back" do end
end

local ok, err = pcall(main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
