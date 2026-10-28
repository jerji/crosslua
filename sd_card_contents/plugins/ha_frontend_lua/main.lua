-- Home Assistant front end (network). A small list of entities you choose, with their state.
-- Confirm toggles switch-like entities (light, switch, input_boolean, fan) and opens/closes covers.
-- Everything else is read-only. Nothing is hardcoded: the server URL, access token and entity list are typed
-- once and kept in data:ha.vault (vault.lua: PIN + device key, AES-256 + HMAC).
--
-- The token is a Home Assistant long-lived access token (Profile -> Security). Put it in once; the app
-- never displays it.
-- Limits: requests are one entity at a time (small bodies, low RAM). Refresh with Up/Down or the Refresh key.
-- Plain http:// works if your HA is http; https needs a TLS-capable WiFi connection (wifi.connect with tls).

local vault = require("vault")
local PATH = "data:ha.vault"
local TOGGLE = { light = true, switch = true, input_boolean = true, fan = true }
local COVER = { cover = true }
local LH = 26

local W, H = 0, 0
local cfg = nil       -- { url, token, entities = { {id, name}, ... } }
local rows = {}       -- { id, name, state, err }
local cur = 1

local function txt(...) return input.text(...) or "" end
local function clip(s, n) return #s > n and s:sub(1, n) or s end
local function domain(id) return id:match("^([^%.]+)%.") or "" end

local function parse_cfg(text)
  local c = { url = "", token = "", entities = {} }
  local first = true
  for line in text:gmatch("[^\n]+") do
    if first then
      c.url, c.token = line:match("^([^\t]*)\t(.*)$")
      first = false
    else
      local id, name = line:match("^([^\t]+)\t?(.*)$")
      if id then c.entities[#c.entities + 1] = { id = id, name = name ~= "" and name or id } end
    end
  end
  return c
end

local function write_cfg(c)
  local lines = { c.url .. "\t" .. c.token }
  for _, e in ipairs(c.entities) do lines[#lines + 1] = e.id .. "\t" .. e.name end
  return table.concat(lines, "\n")
end

local function message(lines, footer)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Home Assistant", "ui12", "bw")
  local y = 60
  for _, l in ipairs(lines) do gfx.text(14, y, clip(l, 50), "ui12"); y = y + LH end
  gfx.text(14, H - 34, footer or "Back", "small")
  gfx.present()
end

-- ---------- setup: URL, token, entities (typed once; stored in the vault) ----------
local function setup(v)
  local url = txt("Server URL (e.g. https://ha.example.com)", "", 200)
  if url == "" then return nil end
  url = url:gsub("/+$", "")
  local token = txt("Long-lived access token", "", 300, "password")
  if token == "" then return nil end
  local ids = txt("Entity IDs, comma separated (e.g. light.desk,switch.fan)", "", 400)
  local c = { url = url, token = token, entities = {} }
  for id in ids:gmatch("[^,%s]+") do
    if id:match("^[%w_]+%.[%w_]+$") then c.entities[#c.entities + 1] = { id = id, name = id } end
  end
  if #c.entities == 0 then return nil end
  v.data = write_cfg(c)
  local ok, err = v:save()
  if not ok then message({ "save failed: " .. tostring(err) }, "Back"); return nil end
  return c
end

local function open_vault()
  if vault.exists(PATH) then
    local pin = txt("Vault PIN", "", 64, "password")
    if pin == "" then return nil end
    local v, err = vault.unlock(PATH, pin)
    if not v then message({ tostring(err) }, "Back"); return nil end
    return v
  end
  local pin = txt("Choose a PIN (4-64 chars)", "", 64, "password")
  if pin == "" then return nil end
  local v, err = vault.create(PATH, pin, "")
  if not v then message({ tostring(err) }, "Back"); return nil end
  return v
end

-- ---------- HA calls ----------
local function headers(c) return { Authorization = "Bearer " .. c.token } end

local function fetch_state(c, id)
  local r, err = http.request({ url = c.url .. "/api/states/" .. id, headers = headers(c), max_body = 4096 })
  if not r then return nil, tostring(err) end
  if not r.ok then return nil, "HTTP " .. tostring(r.status) end
  local ok, body = pcall(json.decode, r.body)
  if not ok or type(body) ~= "table" then return nil, "bad reply" end
  return body.state or "?"
end

local function refresh(c)
  for i, e in ipairs(c.entities) do
    local st, err = fetch_state(c, e.id)
    rows[i] = { id = e.id, name = e.name, state = st, err = err }
    gfx.clear(); W, H = gfx.size()
    gfx.text(14, 60, "refreshing " .. i .. "/" .. #c.entities, "ui12"); gfx.present()
  end
end

local function toggle(c, row)
  local d = domain(row.id)
  local service
  if TOGGLE[d] then service = "toggle"
  elseif COVER[d] then service = (row.state == "open") and "close_cover" or "open_cover"
  else return "read-only entity type" end
  local body = json.encode({ entity_id = row.id })
  local r, err = http.request({
    url = c.url .. "/api/services/" .. d .. "/" .. service, method = "POST",
    headers = headers(c), body = body, content_type = "application/json", max_body = 2048,
  })
  if not r then return "failed: " .. tostring(err) end
  if not r.ok then return "HTTP " .. tostring(r.status) end
  return service .. " sent"
end

local function draw(note)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Home Assistant", "ui12", "bw")
  local y = 56
  for i, r in ipairs(rows) do
    local label = string.format("%s  %s", clip(r.name, 22), r.err and ("!" .. clip(r.err, 14)) or (r.state or "?"))
    if i == cur then gfx.rect(10, y - 4, W - 20, LH + 4, true); gfx.text(16, y, label, "ui12", "w")
    else gfx.text(16, y, label, "ui12") end
    y = y + LH + 6
    if y > H - 90 then break end
  end
  gfx.text(14, H - 60, note or "", "small")
  gfx.text(14, H - 34, "Confirm = toggle, R = refresh, Back = exit", "small")
  gfx.present()
end

local function main()
  W, H = gfx.size()
  local v = open_vault()
  if not v then return end
  if v.data and v.data ~= "" then cfg = parse_cfg(v.data) else cfg = setup(v) end
  if not cfg then v:lock(); return end
  message({ "Connecting to WiFi..." }, "")
  local ok, why = wifi.connect({ tls = cfg.url:sub(1, 5) == "https" })
  if not ok then message({ "WiFi failed:", tostring(why) }, "Back"); while input.wait() ~= "back" do end; v:lock(); return end
  message({ "Loading states..." }, "")
  refresh(cfg)
  local note = ""
  draw(note)
  while true do
    local e = input.wait()
    if e == "back" then break
    elseif e == "up" then cur = cur > 1 and cur - 1 or #rows; note = ""
    elseif e == "down" then cur = cur < #rows and cur + 1 or 1; note = ""
    elseif e == "confirm" and rows[cur] then
      note = toggle(cfg, rows[cur])
      refresh(cfg)
    elseif e == "left" or e == "right" then
      refresh(cfg); note = "refreshed"
    end
    draw(note)
  end
  v:lock()
end

local ok, err = pcall(main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
