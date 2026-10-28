-- Home Assistant browser (network). Path: MAIN MENU > ROOMS (areas) or TYPES (domains) > list > entity > action.
-- Back goes up one level; Back at the top exits. Up/Down move, Confirm opens or runs, Left/Right page a long list.
-- Setup (first run, or after the vault is reset): server URL and a long-lived token, stored in the vault (PIN).
-- Homelab mode: http and https are both allowed. https is only verified if HomeAssistant/ca.pem is on the card; the
-- screen shows a warning when it is not.
-- Entity lists come from the template endpoint, so the device reads only the short list it is showing.
local vault = require("vault")
local ha = require("ha")
local PATH = "data:ha.vault"

local W, H = 0, 0
local LH = 30
local PAGE = 10
local stack = {}          -- frames; the top one is shown
local cfg = nil
local note = ""           -- one-line status under the list

local function clip(s, n) return #s > n and s:sub(1, n) or s end
local function txt(...) return input.text(...) or "" end

local function busy(msg)
  gfx.clear(); W, H = gfx.size()
  gfx.text(14, 60, msg or "Loading...", "ui12")
  gfx.present()
end

local function draw()
  local f = stack[#stack]
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, clip(f.title, 40), "ui12", "bw")
  local top = 56
  if f.head then gfx.text(14, top, clip(f.head, 50), "small", "b"); top = top + 26 end
  local first = math.max(1, f.sel - PAGE + 1)
  if f.sel < PAGE then first = 1 end
  local y = top
  for i = first, math.min(#f.items, first + PAGE - 1) do
    local label = f.items[i].label
    if i == f.sel then gfx.rect(10, y - 4, W - 20, LH, true); gfx.text(16, y, clip(label, 42), "ui12", "w")
    else gfx.text(16, y, clip(label, 42), "ui12") end
    y = y + LH
  end
  if #f.items == 0 then gfx.text(16, y, "(nothing here)", "ui12") end
  gfx.text(14, H - 60, clip(note, 60), "small")
  if ha.warning then gfx.text(14, H - 84, clip(ha.warning, 60), "small", "b") end
  gfx.text(14, H - 34, "Up/Down move, Confirm open, Back up", "small")
  gfx.present()
end

local function push(title, items, head, kind, data)
  stack[#stack + 1] = { title = title, items = items or {}, sel = 1, head = head, kind = kind, data = data }
end

local function menu_frame()
  return { title = "Home Assistant", sel = 1, kind = "menu", head = nil,
    items = { { label = "Rooms", value = "rooms" }, { label = "Types", value = "types" } } }
end

local function list_items(names, valueKind)
  local out = {}
  for _, n in ipairs(names) do out[#out + 1] = { label = n, value = n, kind = valueKind } end
  return out
end

local function fail(msg) note = msg or "Failed." end

-- ---------- screens: each loader builds a frame; confirm on an item calls open() ----------
local function open_rooms()
  busy("Reading rooms...")
  local areas, err = ha.areas(cfg)
  if not areas then fail(err); return end
  table.sort(areas)
  push("Rooms", list_items(areas, "area"))
end

local function domains_in_entities(ids)
  local seen, out = {}, {}
  for _, id in ipairs(ids) do
    local d = ha.domain_of(id)
    if d ~= "" and not seen[d] then seen[d] = true; out[#out + 1] = d end
  end
  table.sort(out)
  return out
end

local function open_area(area)
  busy("Reading " .. area .. "...")
  local ids, err = ha.area_entities(cfg, area)
  if not ids then fail(err); return end
  local items = {}
  for _, d in ipairs(domains_in_entities(ids)) do
    local n = 0
    for _, id in ipairs(ids) do if ha.domain_of(id) == d then n = n + 1 end end
    items[#items + 1] = { label = d .. "  (" .. n .. ")", value = d, kind = "area_domain", area = area, ids = ids }
  end
  push(area, items, #ids .. " entities")
end

local function open_area_domain(area, domain, ids)
  local items = {}
  for _, id in ipairs(ids) do
    if ha.domain_of(id) == domain then items[#items + 1] = { label = id, value = id, kind = "entity" } end
  end
  push(area .. " / " .. domain, items)
end

local function open_types()
  local items = {}
  for _, d in ipairs(ha.TYPES) do items[#items + 1] = { label = d, value = d, kind = "type" } end
  push("Types", items)
end

local function open_type(domain)
  busy("Reading " .. domain .. "...")
  local ids, err = ha.domain_entities(cfg, domain)
  if not ids then fail(err); return end
  table.sort(ids)
  local items = {}
  for _, id in ipairs(ids) do items[#items + 1] = { label = id, value = id, kind = "entity" } end
  push(domain, items, #ids .. " entities")
end

-- entity screen: state at the top, one row per action the domain supports
local function open_entity(id)
  busy("Reading " .. id .. "...")
  local st, err = ha.state(cfg, id)
  if not st then fail(err); return end
  local acts = ha.ACTIONS[ha.domain_of(id)] or {}
  local items = {}
  for _, a in ipairs(acts) do items[#items + 1] = { label = a[2], value = a[1], kind = "action", entity = id } end
  if #items == 0 then items[1] = { label = "(read only: no actions for this type)", value = nil, kind = "none" } end
  push(clip(st.name, 40), items, "state: " .. st.state .. "   " .. id)
  stack[#stack].entity = id
end

local function run_action(item)
  local f = stack[#stack]
  busy("Sending " .. item.label .. "...")
  local ok, err = ha.call(cfg, ha.domain_of(item.entity), item.value, item.entity)
  if not ok then fail(err); return end
  -- refresh the state line: reopen the entity frame in place
  table.remove(stack)
  open_entity(item.entity)
  note = item.label .. " sent."
end

local function confirm()
  local f = stack[#stack]
  local it = f.items[f.sel]
  if not it then return end
  note = ""
  if f.kind == "menu" then
    if it.value == "rooms" then open_rooms() else open_types() end
  elseif it.kind == "area" then open_area(it.value)
  elseif it.kind == "area_domain" then open_area_domain(it.area, it.value, it.ids)
  elseif it.kind == "type" then open_type(it.value)
  elseif it.kind == "entity" then open_entity(it.value)
  elseif it.kind == "action" then run_action(it)
  end
end

local function setup()
  local url = txt("Server URL (https://...)", "", 200)
  if url == "" then return nil end
  local token = txt("Long-lived access token", "", 300, "password")
  if token == "" then return nil end
  local c = { url = (url:gsub("/+$", "")), token = token }
  return c
end

local function open_vault()
  if vault.exists(PATH) then
    local pin = txt("Vault PIN", "", 64, "password")
    if pin == "" then return nil end
    local v, err = vault.unlock(PATH, pin)
    if not v then busy("Vault: " .. tostring(err)); input.wait(); return nil end
    return v
  end
  local pin = txt("Choose a PIN (4-64 chars)", "", 64, "password")
  if pin == "" then return nil end
  local v, err = vault.create(PATH, pin, "")
  if not v then busy("Vault: " .. tostring(err)); input.wait(); return nil end
  return v
end

local function load_cfg(v)
  if v.data and v.data ~= "" then
    local url, token = v.data:match("^([^\t\n]*)\t([^\n]*)")
    if url and url ~= "" then return { url = url, token = token } end
  end
  local c = setup()
  if not c then return nil end
  v.data = c.url .. "\t" .. c.token .. "\n"
  local ok, err = v:save()
  if not ok then busy("Could not save: " .. tostring(err)); input.wait(); return nil end
  return c
end

local ok, err = pcall(function()
  W, H = gfx.size()
  local v = open_vault()
  if not v then return end
  cfg = load_cfg(v)
  if not cfg then v:lock(); return end
  local good, why = ha.check(cfg)
  if not good then
    busy(why)
    while input.wait() ~= "back" do end
    v:lock(); return
  end
  if ha.warning then note = ha.warning end
  stack[1] = menu_frame()
  draw()
  while true do
    local e = input.wait()
    local f = stack[#stack]
    if e == "back" then
      if #stack == 1 then break end
      table.remove(stack); note = ""
    elseif e == "up" then f.sel = f.sel > 1 and f.sel - 1 or math.max(1, #f.items); note = ""
    elseif e == "down" then f.sel = f.sel < #f.items and f.sel + 1 or 1; note = ""
    elseif e == "left" then f.sel = math.max(1, f.sel - PAGE)
    elseif e == "right" then f.sel = math.min(math.max(1, #f.items), f.sel + PAGE)
    elseif e == "confirm" then confirm()
    end
    draw()
  end
  v:lock()
end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
