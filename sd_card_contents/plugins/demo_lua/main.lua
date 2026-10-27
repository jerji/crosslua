-- demo_lua — a one-screen tour of CrossLua for the README. Draws, hashes, checks the radio, times and battery.
local function __main()
  local f, min = system.heap()
  local wifi = wifi.status()
  local bat = system.battery and system.battery() or nil
  local now = time.date()

  gfx.clear()
  -- header band
  gfx.rect(0, 0, 480, 40, true)  -- filled black header band
  gfx.text(16, 14, "CrossLua  ·  Lua apps on your e-reader", "ui12", "w")

  local y = 56
  gfx.text(16, y, "Hello from Lua!", "sans18", "b")
  y = y + 40
  gfx.text(16, y, ("heap %d KB free (low %d KB)"):format(f // 1024, min // 1024), "ui12")
  y = y + 26
  if wifi and wifi.connected then
    gfx.text(16, y, ("wifi %s  rssi %d dBm"):format(wifi.ssid or "?", wifi.rssi or 0), "ui12")
  else
    gfx.text(16, y, "wifi off (this shot was taken offline)", "ui12")
  end
  y = y + 26
  if bat then
    gfx.text(16, y, ("battery %d%%"):format(bat), "ui12")
    y = y + 26
  end
  gfx.text(16, y, ("clock %04d-%02d-%02d %02d:%02d"):format(now.year, now.month, now.day, now.hour, now.min), "ui12")

  -- what an app can do, in two short columns of text
  y = y + 44
  gfx.text(16, y, 'crypto.sha256("pup")', "small")
  local h = crypto.sha256("pup")
  local hex = ""
  for i = 1, 8 do hex = hex .. string.format("%02x", h:byte(i)) end
  gfx.text(16, y + 20, hex, "ui12")
  gfx.text(250, y, "raw radio, in Lua", "small")
  gfx.text(250, y + 20, "net.listen · udp", "small")
  gfx.text(250, y + 44, "espnow · sniff · inject", "small")
  gfx.text(16, y + 70, "TLS, HTTP, JSON, mDNS, files, audio and mic — all from Lua.", "small")

  gfx.rect(16, 620, 448, 4, true)
  gfx.text(16, 640, "Everything above is one small Lua app.", "small")
  gfx.text(16, 664, "Permissions are granted per app, with a dialog.", "small")
  gfx.present("full")
  while input.wait() ~= "back" do end
  app.exit()
end
local ok, err = pcall(__main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "demo error: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
  app.exit()
end
