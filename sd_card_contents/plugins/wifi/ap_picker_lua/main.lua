-- AP Picker (Ruby companion): live scan of nearby access points. Mark each one WHITELIST (W)
-- or BLACKLIST (B) and save the picks to app:ap_list.json for other apps to read.
-- Scan only: never transmits, no monitor, no tx.
--
-- Output app:ap_list.json (version 1). Empty lists are omitted:
--   {"version":1, "whitelist":[{"bssid":"AA:BB:..","ssid":"..","channel":6}, ...], "blacklist":[...]}
-- Marks survive rescans and relaunches. A rescan never drops a marked AP.
--
-- Controls: up/down move, OK cycles none -> W -> B -> none, Left rescans, Right saves, Back saves and exits.

local OUT = "app:ap_list.json"
local MAX_SCAN = 40
local MAX_LABEL = 16
local FONT = "ui12"

local W, H = gfx.size()
local known = {}   -- bssid -> {bssid, ssid, channel, rssi, auth}
local marks = {}   -- bssid -> "w" | "b"   (absent = unmarked)
local order = {}   -- bssids, strongest first, marked-but-absent last
local cur, top = 1, 1
local dirty = false
local status = ""

local function clip(s, n)
  if #s > n then return s:sub(1, n - 2) .. ".." end
  return s
end

local function rebuild_order()
  order = {}
  for b in pairs(known) do order[#order + 1] = b end
  table.sort(order, function(a, b)
    local ra, rb = known[a].rssi, known[b].rssi
    if ra ~= rb then
      if ra == nil then return false end
      if rb == nil then return true end
      return ra > rb
    end
    return a < b
  end)
  if cur > #order then cur = #order end
  if cur < 1 then cur = 1 end
end

local function load_saved()
  if not fs.exists(OUT) then return end
  local raw = fs.read(OUT)
  local data = raw and json.decode(raw)
  if type(data) ~= "table" then return end
  for _, key in ipairs({ "whitelist", "blacklist" }) do
    local list = data[key]
    if type(list) == "table" then
      for _, e in ipairs(list) do
        if type(e) == "table" and type(e.bssid) == "string" then
          known[e.bssid] = { bssid = e.bssid, ssid = tostring(e.ssid or ""),
                             channel = tonumber(e.channel) or 0 }
          marks[e.bssid] = (key == "whitelist") and "w" or "b"
        end
      end
    end
  end
end

local function scan()
  status = "scanning..."
  local list, err = wifi.scan(MAX_SCAN)
  if not list then
    status = "scan failed: " .. tostring(err)
    rebuild_order()
    return false
  end
  for _, ap in ipairs(list) do
    if type(ap.bssid) == "string" then
      local k = known[ap.bssid] or { bssid = ap.bssid }
      k.ssid = ap.hidden and "" or tostring(ap.ssid or "")
      k.channel = ap.channel or k.channel or 0
      k.rssi = ap.rssi
      k.auth = ap.auth
      known[ap.bssid] = k
    end
  end
  rebuild_order()
  status = #list .. " APs heard"
  return true
end

local function save()
  local keys, wl, bl = {}, {}, {}
  for b in pairs(marks) do keys[#keys + 1] = b end
  table.sort(keys)
  for _, b in ipairs(keys) do
    local a = known[b]
    local e = { bssid = b, ssid = a.ssid, channel = a.channel }
    if marks[b] == "w" then wl[#wl + 1] = e else bl[#bl + 1] = e end
  end
  local doc = { version = 1 }
  if #wl > 0 then doc.whitelist = wl end
  if #bl > 0 then doc.blacklist = bl end
  local s, err = json.encode(doc)
  if not s then status = "encode failed: " .. tostring(err); return false end
  local ok, werr = fs.write(OUT, s)
  if not ok then status = "save failed: " .. tostring(werr); return false end
  dirty = false
  status = "saved W:" .. #wl .. " B:" .. #bl
  return true
end

local function draw()
  W, H = gfx.size()
  gfx.clear()
  local lh = gfx.line_height(FONT)
  local rowh = lh + 6
  local y0 = lh + 16
  local foot_y = H - lh - 8
  local status_y = foot_y - lh - 4
  local rows_bottom = status_y - 6
  local rows = math.max(1, math.floor((rows_bottom - y0) / rowh))

  if cur < top then top = cur end
  if cur >= top + rows then top = cur - rows + 1 end
  if top < 1 then top = 1 end

  local nw, nb = 0, 0
  for _, m in pairs(marks) do
    if m == "w" then nw = nw + 1 else nb = nb + 1 end
  end
  gfx.text(8, 4, "AP Picker", "ui", "b")
  gfx.text(W - 8, 4, "W:" .. nw .. "  B:" .. nb, "ui", "r")
  gfx.line(0, lh + 8, W, lh + 8)

  if #order == 0 then
    gfx.text(8, y0, "No access points. Left = scan again.", FONT)
  end
  for i = top, math.min(#order, top + rows - 1) do
    local b = order[i]
    local a = known[b]
    local y = y0 + (i - top) * rowh
    local m = marks[b]
    local tag = (m == "w" and "[W]") or (m == "b" and "[B]") or "[ ]"
    local name = (a.ssid == "") and "<hidden>" or a.ssid
    local rssi = a.rssi and tostring(a.rssi) or "--"
    local line = tag .. " " .. clip(name, MAX_LABEL) .. "  ch" .. tostring(a.channel) .. "  " .. rssi
    local sel = (i == cur)
    if sel then gfx.rect(0, y, W, rowh, true) end
    gfx.text(8, y + 3, line, FONT, sel and "w" or "")
  end

  gfx.text(8, status_y, status, FONT)
  gfx.text(8, foot_y, "OK mark  L scan  R save  Back exit", FONT)
  gfx.present("fast")
end

local function main()
  load_saved()
  scan()
  draw()
  while true do
    local ev = input.wait()
    if ev == "up" then
      if cur > 1 then cur = cur - 1 end
    elseif ev == "down" then
      if cur < #order then cur = cur + 1 end
    elseif ev == "confirm" then
      if #order > 0 then
        local b = order[cur]
        local m = marks[b]
        if m == nil then marks[b] = "w"
        elseif m == "w" then marks[b] = "b"
        else marks[b] = nil end
        dirty = true
        status = "marked (unsaved)"
      end
    elseif ev == "left" then
      scan()
    elseif ev == "right" then
      save()
    elseif ev == "back" then
      if dirty then save() end
      app.exit()
    end
    draw()
  end
end

local ok, err = pcall(main)
if not ok then
  gfx.clear()
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b")
  gfx.present()
  while input.wait() ~= "back" do end
  app.exit()
end
