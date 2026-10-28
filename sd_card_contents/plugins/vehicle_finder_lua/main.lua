-- Vehicle finder: when you park, save the strongest Wi-Fi APs heard there (BSSIDs + RSSI).
-- Later, walk around and rescan: the app follows those same APs and tells you hot / cold.
-- One device gives a direction hint, not a fix. Triangulation needs several readings, so this is hot/cold.
-- Receive only (wifi.scan). The saved spot lives in data:parked.json.

local FILE = "data:parked.json"
local KEEP = 12          -- strongest APs remembered at park time
local ALPHA = 0.5        -- smoothing: weight of each new scan (0..1)
local TREND_DB = 3       -- change in dB that counts as warmer / colder
local LH = 26
local W, H = 0, 0

-- strongest first: best smoothed RSSI at or above the threshold wins
local HOT = { { -50, "ON TOP OF IT" }, { -60, "very hot" }, { -70, "hot" }, { -80, "warm" } }

local parked = nil       -- { at = epoch, aps = { {bssid, ssid, rssi, ch}, ... } }
local menu_cur = 1

local function clip(s, n) return #s > n and s:sub(1, n) or s end

local function header(title)
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, title, "ui12", "bw")
end

local function footer(text) gfx.text(14, H - 34, text, "small") end

local function wait_back()
  while input.wait() ~= "back" do end
end

-- Show a screen of text lines and wait for Back.
local function show(title, lines, hint)
  gfx.clear(); W, H = gfx.size(); header(title)
  local y = 60
  for _, l in ipairs(lines) do
    gfx.text(14, y, l, "ui12")
    y = y + LH + 4
  end
  footer(hint or "Back = return")
  gfx.present()
  wait_back()
end

-- Yes/no question: confirm = yes, back = no.
local function ask(title, question)
  gfx.clear(); W, H = gfx.size(); header(title)
  gfx.text(14, 60, question, "ui12")
  footer("Confirm = yes    Back = no")
  gfx.present()
  while true do
    local e = input.wait()
    if e == "confirm" then return true end
    if e == "back" then return false end
  end
end

local function load_parked()
  local s = fs.read(FILE)
  if not s then return nil end
  local t = json.decode(s)
  if type(t) ~= "table" or type(t.aps) ~= "table" then return nil end
  return t
end

local function save_parked(aps)
  local body, jerr = json.encode({ at = time.now() or 0, aps = aps })
  if not body then return nil, jerr end
  return fs.write(FILE, body)
end

local function scan()
  local list, err = wifi.scan(40)
  if not list then return nil, err or "scan failed" end
  return list
end

-- Take the KEEP strongest APs from a scan into the saved-spot shape.
local function strongest(list)
  table.sort(list, function(a, b) return (a.rssi or -127) > (b.rssi or -127) end)
  local aps = {}
  for i = 1, math.min(KEEP, #list) do
    local n = list[i]
    aps[#aps + 1] = { bssid = n.bssid, ssid = n.ssid or "", rssi = n.rssi, ch = n.channel }
  end
  return aps
end

local function park_flow()
  if parked and not ask("Park here", "Overwrite the saved spot?") then return end
  gfx.clear(); W, H = gfx.size(); header("Park here")
  gfx.text(14, 60, "Scanning for nearby APs...", "ui12")
  gfx.present("fast")
  local list, err = scan()
  if not list then return show("Park here", { "Scan failed:", tostring(err) }) end
  local aps = strongest(list)
  list = nil
  if #aps == 0 then return show("Park here", { "No APs heard here.", "Nothing saved." }) end
  local ok, werr = save_parked(aps)
  if not ok then return show("Park here", { "Could not save:", tostring(werr) }) end
  parked = { aps = aps }
  show("Park here", {
    "Spot saved: " .. #aps .. " APs",
    "Strongest: " .. clip(aps[1].ssid ~= "" and aps[1].ssid or "<hidden>", 20),
    string.format("%d dBm", aps[1].rssi or -127),
  })
end

local function forget_flow()
  if not parked then return show("Forget", { "No spot saved." }) end
  if not ask("Forget", "Delete the saved spot?") then return end
  fs.remove(FILE)
  parked = nil
  show("Forget", { "Saved spot deleted." })
end

local function warmth(v)
  if not v then return "nothing heard" end
  for _, t in ipairs(HOT) do
    if v >= t[1] then return t[2] end
  end
  return "cold"
end

local function trend(prev, cur)
  if not prev or not cur then return "" end
  if cur - prev >= TREND_DB then return "warmer" end
  if prev - cur >= TREND_DB then return "colder" end
  return "steady"
end

-- Draw the finder screen. smooth: bssid -> smoothed rssi (nil = not heard on this scan)
local function draw_find(best, prev_best, peak, smooth, status_line)
  gfx.clear(); W, H = gfx.size()
  header("Find my car")
  gfx.text(14, 50, warmth(best), "sans18", "b")
  local t = trend(prev_best, best)
  local line = best and string.format("best %d dBm  peak %d  %s", math.floor(best), math.floor(peak), t)
    or "no saved AP in range"
  gfx.text(14, 92, line, "ui12")
  gfx.text(14, 118, status_line or "", "small")

  local rows = {}
  for _, a in ipairs(parked.aps) do rows[#rows + 1] = a end
  table.sort(rows, function(x, y)
    local sx, sy = smooth[x.bssid], smooth[y.bssid]
    if sx and sy then return sx > sy end
    return sx ~= nil
  end)

  local y = 146
  for i = 1, math.min(#rows, (H - 200) // LH) do
    local a = rows[i]
    local s = smooth[a.bssid]
    gfx.text(14, y, clip(a.ssid ~= "" and a.ssid or "<hidden>", 13), "small")
    gfx.rect(150, y + 4, 200, 12, false)
    if s then
      local w = math.max(0, math.min(200, math.floor((s + 100) * 2.5)))
      if w > 0 then gfx.rect(150, y + 4, w, 12, true) end
      gfx.text(360, y, string.format("%d", math.floor(s)), "small")
    else
      gfx.text(360, y, "--", "small")
    end
    y = y + LH
  end
  footer("Walk, then watch. Back = menu")
  gfx.present()
end

local function find_flow()
  if not parked or #parked.aps == 0 then
    return show("Find my car", { "No spot saved yet.", "Park first." })
  end
  local smooth = {}
  local best, prev_best, peak = nil, nil, nil
  while true do
    gfx.clear(); W, H = gfx.size(); header("Find my car")
    gfx.text(14, 60, "Scanning...", "ui12")
    gfx.present("fast")

    local list, err = scan()
    local status_line
    if list then
      local seen = {}
      for _, n in ipairs(list) do seen[n.bssid] = n.rssi end
      list = nil
      local heard = 0
      for _, a in ipairs(parked.aps) do
        local r = seen[a.bssid]
        if r then
          heard = heard + 1
          local s = smooth[a.bssid]
          smooth[a.bssid] = s and (ALPHA * r + (1 - ALPHA) * s) or r
        else
          smooth[a.bssid] = nil
        end
      end
      prev_best = best
      best = nil
      for _, a in ipairs(parked.aps) do
        local s = smooth[a.bssid]
        if s and (not best or s > best) then best = s end
      end
      if best and (not peak or best > peak) then peak = best end
      status_line = heard .. " of " .. #parked.aps .. " saved APs heard"
    else
      status_line = "scan error: " .. tostring(err)
    end

    draw_find(best, prev_best, peak, smooth, status_line)
    local e = input.wait(1000)   -- short pause, then rescan
    if e == "back" then return end
  end
end

local MENU = { "Find my car", "Park here (save spot)", "Forget saved spot", "Exit" }

local function menu()
  while true do
    gfx.clear(); W, H = gfx.size(); header("Vehicle Finder")
    gfx.text(14, 48, parked and (#parked.aps .. " APs saved") or "no spot saved", "small")
    local y = 80
    for i, label in ipairs(MENU) do
      if i == menu_cur then
        gfx.rect(10, y - 4, W - 20, LH + 4, true)
        gfx.text(18, y, label, "ui12", "w")
      else
        gfx.text(18, y, label, "ui12")
      end
      y = y + LH + 8
    end
    footer("Up/Down move  Confirm select  Back exit")
    gfx.present()
    local e = input.wait()
    if e == "up" then
      menu_cur = menu_cur > 1 and menu_cur - 1 or #MENU
    elseif e == "down" then
      menu_cur = menu_cur < #MENU and menu_cur + 1 or 1
    elseif e == "confirm" then
      if menu_cur == 1 then find_flow()
      elseif menu_cur == 2 then park_flow()
      elseif menu_cur == 3 then forget_flow()
      else return end
    elseif e == "back" then
      return
    end
  end
end

local function main()
  W, H = gfx.size()
  parked = load_parked()
  menu()
end

local ok, err = pcall(main)
if not ok then
  pcall(function() wifi.off() end)
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  wait_back()
end
pcall(function() wifi.off() end)
app.exit()
