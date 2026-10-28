-- mDNS browser: asks the LAN which devices advertise a service type (net.mdns_query).
-- Read-only: sends queries, stores results in RAM, writes nothing to the card.
-- net.mdns_query has no timeout parameter and blocks until the firmware gives up, so each query
-- draws a "searching" frame first.

local LH = 26
local MAX_RESULTS = 48

local SERVICES = {
  { "http", "tcp" }, { "https", "tcp" }, { "ssh", "tcp" }, { "smb", "tcp" },
  { "ipp", "tcp" }, { "printer", "tcp" }, { "airplay", "tcp" }, { "googlecast", "tcp" },
  { "homeassistant", "tcp" }, { "workstation", "tcp" }, { "device-info", "tcp" },
}

local W, H = 0, 0

local function header(title)
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, title, "ui12", "bw")
end

local function footer(text)
  gfx.text(14, H - 34, text, "small")
end

local function menu(title, items, hint)
  local cur = 1
  while true do
    gfx.clear(); W, H = gfx.size(); header(title)
    local y = 60
    for i, label in ipairs(items) do
      if i == cur then
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
    if e == "up" then cur = cur > 1 and cur - 1 or #items
    elseif e == "down" then cur = cur < #items and cur + 1 or 1
    elseif e == "confirm" then return cur
    elseif e == "back" then return nil end
  end
end

local function show_results(label, res, err)
  local top = 1
  while true do
    gfx.clear(); W, H = gfx.size(); header(("_%s  (%d found)"):format(label, res and #res or 0))
    local per = ((H - 120) // LH) // 2   -- each entry is two lines
    local y = 56
    if err then
      gfx.text(14, y, "query failed: " .. tostring(err), "ui12")
    elseif #res == 0 then
      gfx.text(14, y, "nothing answered for this service", "ui12")
    end
    if res then
      for r = top, math.min(#res, top + per - 1) do
        local s = res[r]
        gfx.text(14, y, (s.instance_name or "?"):sub(1, 40), "ui12", "b")
        y = y + LH
        gfx.text(24, y, ("%s  %s:%s"):format(tostring(s.hostname), tostring(s.ip), tostring(s.port)), "small")
        y = y + LH
        if y > H - 80 then break end
      end
    end
    footer("up/down scroll  ·  back = done")
    gfx.present()
    local e = input.wait()
    if e == "up" and top > 1 then top = top - 1
    elseif e == "down" and res and top + per <= #res then top = top + 1
    elseif e == "back" or e == "confirm" then return end
  end
end

local function search(label, service, proto)
  gfx.clear(); W, H = gfx.size(); header("mDNS Browser")
  gfx.text(14, 60, "searching _" .. label .. " ...", "ui12")
  gfx.text(14, 60 + LH, "(this can take a few seconds)", "small")
  gfx.present()
  local res, err = net.mdns_query(service, proto)
  if res then
    local trimmed = {}
    for i = 1, math.min(#res, MAX_RESULTS) do trimmed[i] = res[i] end
    res = trimmed
  end
  show_results(label, res, err)
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

  local items = {}
  for i, s in ipairs(SERVICES) do items[i] = "_" .. s[1] .. "._" .. s[2] end
  items[#items + 1] = "Custom service..."

  while true do
    local pick = menu("mDNS Browser", items, "confirm = search  ·  back = exit")
    if not pick then break end
    if pick <= #SERVICES then
      search(SERVICES[pick][1] .. "._" .. SERVICES[pick][2], SERVICES[pick][1], SERVICES[pick][2])
    else
      local name = input.text("Service name (no underscore)", "", 40)
      if name and name:match("^[%w%-]+$") then
        local proto = input.text("Protocol: tcp or udp", "tcp", 3)
        if proto == "tcp" or proto == "udp" then
          search(name .. "._" .. proto, name, proto)
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
