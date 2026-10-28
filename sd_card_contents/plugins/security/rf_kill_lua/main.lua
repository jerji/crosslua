-- RF kill (network, espnow): confirm turns off the WiFi client/hotspot (wifi.off) and stops ESP-NOW.
-- It does not wipe anything. Ghost-mode features (MAC rotation, dead-man wipe) are not here: they need
-- wifi.set_mac and the encrypted-log primitives, which are not in API.md yet.

local function show(lines, footer)
  gfx.clear()
  local W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "RF kill", "ui12", "bw")
  local y = 70
  for _, l in ipairs(lines) do gfx.text(16, y, l, "ui12"); y = y + 30 end
  gfx.text(14, H - 34, footer, "small")
  gfx.present()
end

local ok, err = pcall(function()
  show({ "Turns off WiFi, hotspot and ESP-NOW.", "Nothing on the card is changed." }, "Confirm = kill radios, Back = exit")
  while true do
    local e = input.wait()
    if e == "back" then break end
    if e == "confirm" then
      local lines = {}
      local ok1, e1 = pcall(wifi.off)
      lines[#lines + 1] = "WiFi/hotspot off: " .. (ok1 and "yes" or ("failed: " .. tostring(e1)))
      local ok2, e2 = pcall(espnow.stop)
      lines[#lines + 1] = "ESP-NOW stopped: " .. (ok2 and "yes" or ("failed: " .. tostring(e2)))
      lines[#lines + 1] = "Radios are off. Back to exit."
      show(lines, "Back = exit")
    end
  end
end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
