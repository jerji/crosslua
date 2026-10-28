-- Home Assistant REST client for the browse app. Every request pins the server certificate to the PEM the user puts on
-- the card (ca = "sd:HomeAssistant/ca.pem"). Without that file the token is NOT sent: the API docs say a Home Assistant
-- long-lived token is admin and must not go in a request without a ca pin. Lists come from the template endpoint
-- (POST /api/template) so the device never downloads the whole state table.
local M = {}
local CA = "sd:HomeAssistant/ca.pem"

-- cfg = { url = "https://host:port", token = "..." }
function M.check(cfg)
  if not cfg or not cfg.url or cfg.url == "" then return nil, "No server URL saved." end
  if cfg.url:sub(1, 8) ~= "https://" then return nil, "Only https:// servers are allowed (the token must be pinned)." end
  local pem = fs.read(CA, 0, 16384)
  if not pem or #pem < 32 then return nil, "Put your server certificate at HomeAssistant/ca.pem on the card." end
  return true
end

local function request(cfg, method, path, body)
  local opts = {
    url = cfg.url .. path, method = method, ca = CA, max_body = 8192,
    headers = { Authorization = "Bearer " .. cfg.token },
  }
  if body then opts.body = json.encode(body); opts.content_type = "application/json" end
  local r, err = http.request(opts)
  if not r then return nil, tostring(err) end
  if not r.ok then return nil, "HTTP " .. tostring(r.status) end
  return r.body or ""
end
M.request = request

-- render a Jinja template on the server; returns the text
function M.template(cfg, tpl)
  return request(cfg, "POST", "/api/template", { template = tpl })
end

-- split a newline-separated reply into a list (drops blanks)
function M.lines(text)
  local out = {}
  for l in (text or ""):gmatch("[^\n]+") do
    l = l:gsub("\r", "")
    if l ~= "" then out[#out + 1] = l end
  end
  return out
end

-- area and entity names are typed on the server; refuse anything that would break a template string literal
local function safe(name)
  return name and not name:find('[\\"\'{}%%]') and name ~= ""
end
M.safe = safe

function M.areas(cfg)
  local t, err = M.template(cfg, "{{ areas() | join('\\n') }}")
  if not t then return nil, err end
  return M.lines(t)
end

function M.area_entities(cfg, area)
  if not safe(area) then return nil, "That area name cannot be used." end
  local t, err = M.template(cfg, '{{ area_entities("' .. area .. '") | join("\\n") }}')
  if not t then return nil, err end
  return M.lines(t)
end

function M.domain_entities(cfg, domain)
  local t, err = M.template(cfg, "{{ states." .. domain .. " | map(attribute='entity_id') | join('\\n') }}")
  if not t then return nil, err end
  return M.lines(t)
end

function M.state(cfg, entity)
  local body, err = request(cfg, "GET", "/api/states/" .. entity)
  if not body then return nil, err end
  local ok, d = pcall(json.decode, body)
  if not ok or type(d) ~= "table" then return nil, "bad reply" end
  return { state = d.state or "?", name = (d.attributes and d.attributes.friendly_name) or entity }
end

function M.call(cfg, domain, service, entity)
  local body, err = request(cfg, "POST", "/api/services/" .. domain .. "/" .. service, { entity_id = entity })
  if not body then return nil, err end
  return true
end

function M.domain_of(entity) return entity:match("^([^%.]+)%.") or "" end

-- actions the device offers per domain (service name, label)
M.ACTIONS = {
  light = { { "turn_on", "ON" }, { "turn_off", "OFF" }, { "toggle", "TOGGLE" } },
  switch = { { "turn_on", "ON" }, { "turn_off", "OFF" }, { "toggle", "TOGGLE" } },
  input_boolean = { { "turn_on", "ON" }, { "turn_off", "OFF" }, { "toggle", "TOGGLE" } },
  fan = { { "turn_on", "ON" }, { "turn_off", "OFF" }, { "toggle", "TOGGLE" } },
  cover = { { "open_cover", "OPEN" }, { "close_cover", "CLOSE" }, { "stop_cover", "STOP" } },
  lock = { { "lock", "LOCK" }, { "unlock", "UNLOCK" } },
  scene = { { "turn_on", "ACTIVATE" } },
  script = { { "turn_on", "RUN" } },
}
-- domains the browse screen offers under TYPES
M.TYPES = { "light", "switch", "cover", "fan", "lock", "input_boolean", "scene", "script",
  "sensor", "binary_sensor", "climate", "media_player" }

return M
