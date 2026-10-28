-- Network change detector. Uses wifi.scan (blocking, no monitor mode).
-- The first non-empty scan sets the baseline. After that, every SCAN_GAP_MS the app
-- scans again and reports what changed:
--   NEWAP   a new BSSID claims an SSID we already know (roaming AP, or a possible twin)
--   !OPEN   same as NEWAP, but the new BSSID is open while the SSID was secured before
--   CHAN    a known BSSID moved to another channel
--   !DOWN   a known BSSID's security was downgraded (e.g. wpa2 -> open)
--   GONE    a known BSSID was missing for GONE_SCANS scans in a row
--   BACK    a GONE BSSID came back
--   NEWSSID an SSID never seen before
-- Every event is appended to data:network_change.log. Receive only.

local SCAN_GAP_MS = 20000
local GONE_SCANS = 3
local MAX_APS = 64
local MAX_SCAN = 32
local MAX_EVENTS = 12
local LOG = "data:network_change.log"
-- Higher = stronger. Anything lower than before is a downgrade.
local RANK = { open = 0, wep = 1, wpa = 2, wpa2 = 3, ["wpa2/wpa3"] = 4, wpa3 = 5, enterprise = 5 }

local W, H = 0, 0
local known = {}          -- bssid -> {ssid, ch, auth, miss, gone}
local n_known = 0
local ssid_secure = {}   -- ssid -> true once any secured BSSID carried it
local ssid_known = {}    -- ssid -> true once seen at all
local events = {}        -- newest first, for the screen
local scans = 0
local baseline = false
local t0 = 0
local last_scan = -1000000
local status = "Starting..."
local alert = false

local function clip(s, n) return #s > n and s:sub(1, n) or s end

local function rank(a) return RANK[a or ""] or 3 end

local function label(ssid, bssid)
  return ssid ~= "" and ssid or bssid
end

local function stamp()
  local t = time.now()
  if t then return tostring(t) end
  return string.format("+%ds", (system.millis() - t0) // 1000)
end

local function event(bad, text)
  table.insert(events, 1, { bad = bad, text = text })
  if #events > MAX_EVENTS then table.remove(events) end
  if bad then alert = true end
  local ok, err = fs.append(LOG, stamp() .. (bad and " !! " or " ") .. text .. "\n")
  if not ok then status = "log failed: " .. tostring(err) end
end

-- Compare one scan against what we know. Learns silently during the baseline.
local function process(list)
  local seen = {}
  for _, a in ipairs(list) do
    local bssid = a.bssid
    if type(bssid) == "string" and not seen[bssid] then
      seen[bssid] = true
      local ssid = a.hidden and "" or (a.ssid or "")
      local auth = a.auth or "?"
      local k = known[bssid]
      if k then
        local name = label(k.ssid, bssid)
        if k.gone then
          k.gone = false
          event(false, "BACK  " .. clip(name, 26))
        end
        k.miss = 0
        if k.ch ~= a.channel then
          if baseline then
            event(false, string.format("CHAN  %s ch%s>ch%s", clip(name, 18), tostring(k.ch), tostring(a.channel)))
          end
          k.ch = a.channel
        end
        if k.auth ~= auth then
          if baseline then
            event(rank(auth) < rank(k.auth), string.format("%s %s %s>%s", rank(auth) < rank(k.auth) and "!DOWN" or "AUTH ", clip(name, 14), k.auth, auth))
          end
          k.auth = auth
        end
      elseif n_known < MAX_APS then
        known[bssid] = { ssid = ssid, ch = a.channel, auth = auth, miss = 0, gone = false }
        n_known = n_known + 1
        if ssid ~= "" then
          if baseline and ssid_known[ssid] then
            local open_twin = (auth == "open") and ssid_secure[ssid]
            event(open_twin, string.format("%s %s %s ch%s %s", open_twin and "!OPEN" or "NEWAP ",
              clip(ssid, 14), bssid, tostring(a.channel), auth))
          elseif baseline then
            event(false, "NEWSSID " .. clip(ssid, 30))
          end
          ssid_known[ssid] = true
          if auth ~= "open" then ssid_secure[ssid] = true end
        end
      end
    end
  end
  for bssid, k in pairs(known) do
    if not seen[bssid] then
      k.miss = k.miss + 1
      if k.miss == GONE_SCANS and not k.gone then
        k.gone = true
        if baseline then event(false, "GONE  " .. clip(label(k.ssid, bssid), 26)) end
      end
    end
  end
end

local function draw()
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, "Network Change", "ui12", "bw")
  local y = 52
  if alert then
    gfx.rect(0, y, W, 30, true)
    gfx.text(14, y + 6, "!! CHANGE - confirm clears", "small", "bw")
    y = y + 40
  end
  gfx.text(14, y, string.format("%d APs known  scans %d", n_known, scans), "ui12")
  y = y + 34
  gfx.text(14, y, baseline and "Watching" or "Learning baseline...", "ui12")
  y = y + 40
  gfx.text(14, y, "Events:", "ui12")
  y = y + 26
  if #events == 0 then gfx.text(14, y, "none yet", "small") end
  for _, e in ipairs(events) do
    gfx.text(14, y, clip(e.text, 40), "small", e.bad and "b" or nil)
    y = y + 24
  end
  gfx.text(14, H - 60, clip(status, 50), "small")
  gfx.text(14, H - 34, "Confirm = scan now   Back = exit", "small")
  gfx.present()
end

local function scan_once()
  status = "Scanning..."
  draw()
  local list, err = wifi.scan(MAX_SCAN)
  scans = scans + 1
  last_scan = system.millis()
  if not list then
    status = "scan failed: " .. tostring(err)
    return
  end
  if #list == 0 then
    status = "no networks heard, retrying"
    return
  end
  process(list)
  if not baseline then
    baseline = true
    status = "Baseline set: " .. n_known .. " APs"
  elseif n_known >= MAX_APS then
    status = "AP table full (" .. MAX_APS .. ")"
  else
    status = "Scan " .. scans .. " ok"
  end
end

local function main()
  W, H = gfx.size()
  t0 = system.millis()
  scan_once()
  draw()
  while true do
    local k = input.poll()
    if k == "back" then break end
    if k == "confirm" then
      alert = false
      scan_once()
      draw()
    elseif system.millis() - last_scan >= SCAN_GAP_MS then
      scan_once()
      draw()
    end
    app.sleep(100)
  end
end

local ok, err = pcall(main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
