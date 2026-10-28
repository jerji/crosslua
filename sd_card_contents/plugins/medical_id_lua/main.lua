-- Medical ID: emergency details in data:medical.vault (vault.lua, PIN + device key). Fields are edited on the
-- keyboard and shown as a readable card. Nothing is written in plaintext on the card.
-- Edit: confirm on a field. Back = close the card (or leave, from the field list).

local vault = require("vault")
local PATH = "data:medical.vault"
local FIELDS = { "name", "blood type", "allergies", "conditions", "medications", "emergency contact", "notes" }
local LH = 26

local W, H = 0, 0
local v

local function txt(...) return input.text(...) or "" end
local function clip(s, n) return #s > n and s:sub(1, n) or s end

local function load_fields()
  local f = {}
  for line in (v.data or ""):gmatch("[^\n]+") do
    local k, val = line:match("^([^=]+)=(.*)$")
    if k then f[k] = val end
  end
  return f
end

local function save_fields(f)
  local lines = {}
  for _, k in ipairs(FIELDS) do lines[#lines + 1] = k .. "=" .. (f[k] or ""):gsub("[\n]", " ") end
  v.data = table.concat(lines, "\n")
  local ok, err = v:save()
  if not ok then error("save failed: " .. tostring(err)) end
end

local function card(f)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "MEDICAL ID", "ui12", "bw")
  local y = 56
  for _, k in ipairs(FIELDS) do
    gfx.text(14, y, k:upper(), "small")
    gfx.text(14, y + 16, clip(f[k] or "-", 40), "ui12")
    y = y + 52
    if y > H - 50 then break end
  end
  gfx.text(14, H - 34, "Back = return", "small")
  gfx.present()
  while input.wait() ~= "back" do end
end

local function open_pin()
  if vault.exists(PATH) then
    local pin = txt("PIN", "", 64, "password")
    if pin == "" then return nil end
    local got, err = vault.unlock(PATH, pin)
    if not got then gfx.clear(); gfx.text(14, 60, tostring(err), "ui12"); gfx.present(); while input.wait() ~= "back" do end; return nil end
    return got
  end
  local pin = txt("Choose a PIN (4-64 chars)", "", 64, "password")
  local again = txt("Repeat PIN", "", 64, "password")
  if pin == "" or pin ~= again then gfx.clear(); gfx.text(14, 60, "PINs did not match.", "ui12"); gfx.present(); while input.wait() ~= "back" do end; return nil end
  local created, err = vault.create(PATH, pin, "")
  if not created then gfx.clear(); gfx.text(14, 60, tostring(err), "ui12"); gfx.present(); while input.wait() ~= "back" do end; return nil end
  return created
end

local function main()
  W, H = gfx.size()
  v = open_pin()
  if not v then return end
  local cur = 1
  while true do
    local f = load_fields()
    gfx.clear(); W, H = gfx.size()
    gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Medical ID: edit", "ui12", "bw")
    local y = 56
    for i, k in ipairs(FIELDS) do
      local label = k .. ": " .. clip(f[k] or "-", 26)
      if i == cur then gfx.rect(10, y - 4, W - 20, LH + 4, true); gfx.text(16, y, label, "small", "w")
      else gfx.text(16, y, label, "small") end
      y = y + LH + 4
    end
    gfx.text(14, H - 60, "Confirm = edit field, Right = show card", "small")
    gfx.text(14, H - 34, "Back = lock and exit", "small")
    gfx.present()
    local e = input.wait()
    if e == "up" then cur = cur > 1 and cur - 1 or #FIELDS
    elseif e == "down" then cur = cur < #FIELDS and cur + 1 or 1
    elseif e == "right" then card(f)
    elseif e == "back" then break
    elseif e == "confirm" then
      local k = FIELDS[cur]
      local val = input.text(k, f[k] or "", 160)
      if val then f[k] = val; save_fields(f) end
    end
  end
  v:lock()
end

local ok, err = pcall(main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
if v then pcall(function() v:lock() end) end
app.exit()
