-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
-- wifi.softap: the X4 starts its OWN WiFi network and serves a page over net.listen/net.accept (the HTTP server is plain Lua).
-- Automatic part: start the hotspot, measure the RAM it costs, listen. Interactive part (optional, 90 s): join the network from a
-- phone/laptop and open the address shown on the screen; the test counts the request and answers it. Back ends the wait.
local SSID, PASS, PORT = "X4-AP-test", "x4testpass", 8080
local function __test()
print("== softap")
local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  print((cond and "PASS " or "FAIL ") .. name .. (extra and (" " .. tostring(extra)) or ""))
end
local function heap(tag)
  local f, m, l = system.heap()
  print(("HEAP %-24s free=%d min=%d largest=%d"):format(tag, f, m, l))
  return f
end
local function show(l1, l2, l3, l4)
  gfx.clear()
  gfx.text(16, 10, "hotspot test", "ui12", "b")
  if l1 then gfx.text(16, 70, l1, "ui12") end
  if l2 then gfx.text(16, 110, l2, "ui12") end
  if l3 then gfx.text(16, 150, l3, "ui12") end
  if l4 then gfx.text(16, 190, l4, "small") end
  gfx.present("full")
end

local before = heap("before softap")
local _, e0 = wifi.softap_info()
check("no hotspot before", e0 == "no hotspot running", tostring(e0))
local _, e1 = wifi.softap(SSID, {password = "short"})
check("short password refused", e1 ~= nil and e1:find("password must be 8..63") ~= nil, tostring(e1))

local ok, ip = wifi.softap(SSID, {password = PASS, channel = 6, max_clients = 2})
check("wifi.softap starts", ok == true, tostring(ok) .. " " .. tostring(ip))
if not ok then return end
local after = heap("hotspot up")
print(("INFO the hotspot cost %d bytes of free heap"):format(before - after))
check("ip is a private address", ip:match("^%d+%.%d+%.%d+%.%d+$") ~= nil, ip)

local info = wifi.softap_info()
check("softap_info", info and info.ssid == SSID and info.ip == ip and info.clients == 0, info and (info.ssid .. " " .. info.ip .. " " .. info.clients))
local n = net.info()
check("net.info reports the hotspot address", n and n.ip == ip, n and n.ip)
check("wifi.status is not 'connected' (no internet)", wifi.status().connected == false)
local h2, e2 = http.get("http://example.com/")
check("http.get refuses without internet", h2 == nil, tostring(e2))
local _, e3 = wifi.softap("again")
check("second softap refused", e3 ~= nil and e3:find("already running") ~= nil, tostring(e3))

local srv, serr = net.listen(PORT)
check("net.listen over the hotspot", srv ~= nil, tostring(srv or serr))
heap("listening")

if srv then
  print(("Ready: join '%s' (password %s), open http://%s:%d/"):format(SSID, PASS, ip, PORT))
  show("join WiFi: " .. SSID, "password: " .. PASS, ("open http://%s:%d/"):format(ip, PORT), "waiting 90 s (Back ends)")
  local served, t0 = 0, system.millis()
  local maxClients = 0
  while system.millis() - t0 < 90000 and input.poll() ~= "back" do
    local i = wifi.softap_info()
    if i and i.clients > maxClients then maxClients = i.clients; print("INFO clients joined: " .. i.clients) end
    local cl = net.accept(srv)
    if cl then
      local req, t1 = "", system.millis()
      while not req:find("\r\n\r\n", 1, true) and system.millis() - t1 < 2000 and #req < 2048 do
        local d = net.read(cl, 512)
        if d == nil then break end
        if #d == 0 then app.sleep(10) else req = req .. d end
      end
      local line = req:match("^([^\r\n]*)") or ""
      print("REQUEST " .. line)
      local body = ("<html><body><h1>hello from the X4</h1><p>%s</p><p>clients: %d</p></body></html>"):format(line, (wifi.softap_info() or {}).clients or 0)
      net.write(cl, "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\nContent-Length: " .. #body .. "\r\nConnection: close\r\n\r\n" .. body)
      app.sleep(50)
      net.close(cl)
      served = served + 1
      heap("after request " .. served)
      if served >= 2 then break end  -- a browser usually asks for the page and then /favicon.ico
    else
      app.sleep(50)
    end
  end
  if served > 0 then
    check("served a real client over the hotspot", true, served .. " request(s)")
  else
    print("INFO no client joined within 90 s: the interactive part was skipped (not a failure)")
  end
  net.close(srv)
end

wifi.off()
local _, e4 = wifi.softap_info()
check("wifi.off stops the hotspot", e4 == "no hotspot running", tostring(e4))

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
show("hotspot test", fails == 0 and "ALL PASSED" or (fails .. " FAILED"), nil, "see the serial log for details")
app.sleep(1500)
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
-- the radio was used: reboot back to the hub (frees the radio's RAM)
app.exit()
