-- BLE scanner (bluetooth, passive): ble.start("raw") + ble.observe with active=false, so the
-- device sends nothing. Each advertisement's AD structures are walked (length, type, value) to pull
-- the complete/short local name (0x09/0x08) and the manufacturer company ID (0xFF).
-- Results are shown on screen only. Treat them as personal data: they are what any scanner hears.

local REFRESH_MS = 2000
local LH = 24

local function parse_ad(data)
  local name, company = nil, nil
  local i = 1
  while i <= #data do
    local len = data:byte(i)
    if not len or len == 0 then break end
    local t = data:byte(i + 1)
    local v = data:sub(i + 2, i + len)
    if t == 0x09 or (t == 0x08 and not name) then name = v
    elseif t == 0xFF and #v >= 2 then company = v:byte(1) | (v:byte(2) << 8) end
    i = i + len + 1
  end
  return name, company
end

local function draw(list)
  gfx.clear()
  local W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "BLE scanner (passive)", "ui12", "bw")
  table.sort(list, function(a, b) return a.rssi > b.rssi end)
  local y = 52
  for i = 1, math.min(#list, (H - 110) // LH) do
    local d = list[i]
    local name = d.name or "(no name)"
    local co = d.company and string.format(" co:%04X", d.company) or ""
    gfx.text(14, y, string.format("%4d  %s  %s%s", d.rssi, d.addr, name:sub(1, 16), co), "small")
    y = y + LH
  end
  if #list == 0 then gfx.text(14, 60, "listening...", "ui12") end
  gfx.text(14, H - 52, string.format("%d devices heard", #list), "small")
  gfx.text(14, H - 34, "Back = stop and exit", "small")
  gfx.present()
end

local ok, err = pcall(function()
  local started, serr = ble.start("raw")
  if not started then error("ble.start: " .. tostring(serr)) end
  ble.observe(0, { active = false })        -- 0 = until observe_stop
  local last = nil
  while true do
    local now = system.millis()
    if not last or now - last >= REFRESH_MS then
      local adverts = ble.adverts() or {}
      local list = {}
      for _, a in ipairs(adverts) do
        local name, company = parse_ad(a.data or "")
        list[#list + 1] = { addr = a.addr, rssi = a.rssi, name = name, company = company }
      end
      draw(list)
      last = now
    end
    if input.poll() == "back" then break end
    app.sleep(100)
  end
  ble.observe_stop()
  ble.stop()
end)
if not ok then
  pcall(function() ble.stop() end)
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
