-- File manager over the hotspot: starts an open or WPA2 hotspot, serves a file list and downloads for this
-- app's data: folder over HTTP on port 80. Read-only: no upload, no delete (upload needs multipart parsing
-- and an overwrite policy, not in this version). Runs until Back.
-- TARGETING: all clients on the hotspot (the SDK admits any station; one-client filtering is not in the API).

local PORT = 80
local MAX_DOWNLOAD = 128 * 1024

local function txt(...) return input.text(...) or "" end

local function read_req(h)
  local buf, deadline = "", system.millis() + 2000
  while system.millis() < deadline do
    local d = net.read(h, 1024)
    if d == nil then break end
    if d ~= "" then buf = buf .. d end
    if buf:find("\r\n\r\n", 1, true) then break end
    app.sleep(10)
  end
  return buf
end

local function send(h, status, ctype, body, extra)
  local head = "HTTP/1.1 " .. status .. "\r\nContent-Type: " .. ctype .. "\r\nContent-Length: " .. #body
    .. "\r\nConnection: close\r\n" .. (extra or "") .. "\r\n"
  local data = head .. body
  local sent = 0
  while sent < #data do
    local n = net.write(h, data:sub(sent + 1))
    if not n then break end
    sent = sent + n
  end
  net.close(h)
end

local function unescape(s)
  return (s:gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end))
end

local function listing()
  local names = fs.list("data:") or {}
  local rows = {}
  for _, n in ipairs(names) do
    if n:sub(-1) ~= "/" then
      rows[#rows + 1] = string.format('<li><a href="/get?name=%s">%s</a> (%d bytes)</li>', n, n, fs.size("data:" .. n) or 0)
    end
  end
  return "<!doctype html><html><body><h3>Files</h3><ul>" .. table.concat(rows, "") .. "</ul></body></html>"
end

local function handle(h)
  local req = read_req(h)
  local line = req:match("^(%S+ %S+)") or ""
  local path, query = line:match("^GET (/[^?%s]*)%??(%S*)")
  if not path then send(h, "405 Method Not Allowed", "text/plain", "GET only"); return end
  if path == "/" then send(h, "200 OK", "text/html", listing()); return end
  if path == "/get" then
    local name = unescape(query:match("name=([^&]+)") or "")
    if name == "" or name:find("[/\\]") or name:find("%.%.") then send(h, "400 Bad Request", "text/plain", "bad name"); return end
    local size = fs.size("data:" .. name)
    if not size or size > MAX_DOWNLOAD then send(h, "404 Not Found", "text/plain", "no such file or too large"); return end
    local body = fs.read("data:" .. name) or ""
    send(h, "200 OK", "application/octet-stream", body, 'Content-Disposition: attachment; filename="' .. name .. '"\r\n')
    return
  end
  send(h, "404 Not Found", "text/plain", "not found")
end

local function main()
  local W, H = gfx.size()
  local ssid = txt("Hotspot name", "Files", 32)
  if ssid == "" then ssid = "Files" end
  local pw = txt("Password (blank = OPEN)", "", 63, "password")
  local opts = {}
  if pw ~= "" then
    if #pw < 8 then error("password must be 8-63 characters") end
    opts.password = pw
  end
  gfx.clear(); gfx.text(14, 60, "Starting hotspot...", "ui12"); gfx.present()
  local ok, ip = wifi.softap(ssid, opts)
  if not ok then error("hotspot: " .. tostring(ip)) end
  local server = net.listen(PORT)
  if not server then error("could not listen on port " .. PORT) end
  local served, last = 0, -1000
  while true do
    local c = net.accept(server)
    if c then handle(c); served = served + 1 end
    local now = system.millis()
    if now - last >= 1000 then
      gfx.clear()
      gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "File manager (hotspot)", "ui12", "bw")
      gfx.text(14, 60, "join " .. ssid, "ui12")
      gfx.text(14, 90, "open http://" .. ip .. "/ in a browser", "ui12")
      gfx.text(14, 120, "requests served: " .. served, "ui12")
      gfx.text(14, H - 34, "Back = stop", "small")
      gfx.present()
      last = now
    end
    if input.poll() == "back" then break end
    app.sleep(20)
  end
  net.close(server)
  wifi.off()
end

local ok2, err = pcall(main)
pcall(function() wifi.off() end)
if not ok2 then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
