-- UDP discovery on port 8134, the companion protocol of CrossPoint's web server:
--   request : the text "hello" (sent to a LAN address)
--   reply   : "crosspoint (on <hostname>);<websocket port>"
-- Search mode sends "hello" and lists the replies. Responder mode answers "hello" from this device
-- and is a fake CrossPoint on your LAN: only run it on a network you control.

local PORT = 8134
local HELLO = "hello"
local SEARCH_MS = 3000
local LH = 26

local W, H = 0, 0

local function header(title)
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, title, "ui12", "bw")
end

local function footer(text)
  gfx.text(14, H - 34, text, "small")
end

-- `st` holds the cursor so each menu remembers its own row (this app has two menus)
local function menu(title, items, hint, st)
  while true do
    if st.cur > #items then st.cur = #items end
    gfx.clear(); W, H = gfx.size(); header(title)
    local y = 60
    for i, label in ipairs(items) do
      if i == st.cur then
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
    if e == "up" then st.cur = st.cur > 1 and st.cur - 1 or #items
    elseif e == "down" then st.cur = st.cur < #items and st.cur + 1 or 1
    elseif e == "confirm" then return st.cur
    elseif e == "back" then return nil end
  end
end

local function message(title, lines)
  gfx.clear(); W, H = gfx.size(); header(title)
  local y = 60
  for _, l in ipairs(lines) do gfx.text(14, y, l, "ui12"); y = y + LH end
  footer("back = return")
  gfx.present()
  while input.wait() ~= "back" do end
end

-- "crosspoint (on <host>);<port>" -> { host=, port= } or nil
local function parse_reply(data)
  local host, port = data:match("^crosspoint %(on ([^%)]*)%);(%d+)$")
  if not host then return nil end
  return { host = host, port = math.tointeger(tonumber(port)) }
end

-- Broadcast address of our /24-or-wider network from net.info(), or the limited broadcast.
local function broadcast_addr(info)
  local function quad(s)
    local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
  end
  local ip, mask = quad(info.ip or ""), quad(info.mask or "")
  if not ip or not mask then return "255.255.255.255" end
  local o = {}
  for i = 1, 4 do o[i] = ip[i] | (~mask[i] & 255) end
  return table.concat(o, ".")
end

local function search(info, target)
  local h, err = net.udp_open(0)
  if not h then return message("Search", { "cannot open UDP socket:", tostring(err) }) end

  local sent, serr = net.udp_send(h, target, PORT, HELLO)
  local found, seen = {}, {}
  local t0 = system.millis()
  local status = sent and ("sent 'hello' to " .. target .. ":" .. PORT) or ("send failed: " .. tostring(serr))

  local stop = false
  while not stop and system.millis() - t0 < SEARCH_MS do
    local r = net.udp_recv(h)
    if r and r.data then
      local parsed = parse_reply(r.data)
      local key = r.ip .. ":" .. tostring(r.port)
      if not seen[key] then
        seen[key] = true
        found[#found + 1] = {
          ip = r.ip,
          name = parsed and parsed.host or "(unknown reply)",
          ws = parsed and parsed.port or "?",
          raw = (not parsed) and r.data:sub(1, 40) or nil,
        }
      end
    end
    -- short wait so Back still works; nil means the wait ran out
    local e = input.wait(150)
    if e == "back" then stop = true end
  end
  net.udp_close(h)

  local top = 1
  while true do
    gfx.clear(); W, H = gfx.size(); header(("Search: %d replies"):format(#found))
    gfx.text(14, 52, status:sub(1, 52), "small")
    local y = 52 + LH
    if #found == 0 then
      gfx.text(14, y, "no replies (none on this network,", "ui12")
      gfx.text(14, y + LH, " or the target does not answer)", "ui12")
    end
    local per = (H - 150) // (LH * 2)
    for r = top, math.min(#found, top + per - 1) do
      local f = found[r]
      gfx.text(14, y, ("%s  ws:%s"):format(f.ip, tostring(f.ws)), "ui12", "b")
      gfx.text(24, y + LH, f.raw and ("raw: " .. f.raw) or ("name: " .. f.name), "small")
      y = y + LH * 2
    end
    footer("up/down scroll  ·  back = done")
    gfx.present()
    local e = input.wait()
    if e == "up" and top > 1 then top = top - 1
    elseif e == "down" and top + per <= #found then top = top + 1
    elseif e == "back" or e == "confirm" then return end
  end
end

local function responder(name, ws_port)
  local h, err = net.udp_open(PORT)
  if not h then
    return message("Responder", { "cannot bind UDP " .. PORT .. ":", tostring(err), "(another server may hold it)" })
  end
  local reply = ("crosspoint (on %s);%d"):format(name, ws_port)
  local answered = 0
  local last = ""
  while true do
    gfx.clear(); W, H = gfx.size(); header("Responder on UDP " .. PORT)
    gfx.text(14, 52, "answering 'hello' as:", "ui12")
    gfx.text(14, 52 + LH, reply, "ui12", "b")
    gfx.text(14, 52 + 3 * LH, ("answered %d"):format(answered), "ui12")
    gfx.text(14, 52 + 4 * LH, last, "small")
    footer("back = stop responder")
    gfx.present()
    local e = input.wait(300)     -- also services the socket every 300 ms
    if e == "back" then break end
    local r = net.udp_recv(h)
    while r do
      if r.data and r.data:match("^%s*hello%s*$") then
        net.udp_send(h, r.ip, r.port, reply)
        answered = answered + 1
        last = "last: " .. r.ip
      end
      r = net.udp_recv(h)
    end
  end
  net.udp_close(h)
end

local function __main()
  gfx.clear(); gfx.text(14, 14, "Connecting to WiFi...", "ui12"); gfx.present()
  local ok, why = wifi.connect({ tls = false })
  if not ok then return message("WiFi failed", { tostring(why) }) end

  local info = net.info() or {}
  local bcast = broadcast_addr(info)
  local main_cur = { cur = 1 }

  while true do
    local pick = menu("UDP Discovery", {
      "Search (broadcast " .. bcast:sub(1, 20) .. ")",
      "Search one IP...",
      "Responder: answer 'hello'",
    }, "confirm = pick  ·  back = exit", main_cur)
    if not pick then break end

    if pick == 1 then
      search(info, bcast)
    elseif pick == 2 then
      local ip = input.text("Target IPv4", "", 15)
      if ip and ip:match("^%d+%.%d+%.%d+%.%d+$") then
        search(info, ip)
      elseif ip then
        message("Search", { "not an IPv4 address" })
      end
    elseif pick == 3 then
      local ok_warn = menu("Responder: this device will answer as CrossPoint", { "Start", "Cancel" }, "confirm = pick", { cur = 1 })
      if ok_warn == 1 then
        local name = input.text("Name shown in replies", "crosspoint", 40) or "crosspoint"
        responder(name, 81)
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
