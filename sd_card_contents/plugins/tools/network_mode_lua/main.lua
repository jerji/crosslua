-- Network modes (status only): one radio at a time. Shows the live state of each mode it can read
-- and the exclusivity rules from API.md. It does not start or stop anything.

local function try(f, ...)
  local ok, a, b = pcall(f, ...)
  if ok then return a, b end
  return nil, a
end

local function status_lines()
  local lines = {}
  local st = try(wifi.status)
  lines[#lines + 1] = "WiFi client: " .. ((st and st.connected) and "connected" or "off / not joined")
  local info = try(wifi.softap_info)
  lines[#lines + 1] = "Hotspot: " .. (info and ("up, " .. tostring(info.clients) .. " clients") or "not running")
  local ei = try(espnow.info)
  lines[#lines + 1] = "ESP-NOW: " .. (ei and ("ch " .. tostring(ei.channel)) or "not running")
  return lines
end

local RULES = {
  "Rule 1: WiFi client, hotspot, ESP-NOW, sniffer, injector and BLE",
  "  share the radio: starting one refuses while another holds it.",
  "Rule 2: sniffer and injector may run together on one channel.",
  "Rule 3: leaving an app that used the radio reboots to Home.",
}

local function draw(lines)
  gfx.clear()
  local W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Network modes", "ui12", "bw")
  local y = 56
  for _, l in ipairs(lines) do gfx.text(14, y, l, "ui12"); y = y + 28 end
  y = y + 14
  for _, l in ipairs(RULES) do gfx.text(14, y, l, "small"); y = y + 22 end
  gfx.text(14, H - 34, "Confirm = refresh, Back = exit", "small")
  gfx.present()
end

local ok, err = pcall(function()
  draw(status_lines())
  while true do
    local e = input.wait()
    if e == "back" then break end
    if e == "confirm" then draw(status_lines()) end
  end
end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
