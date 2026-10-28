-- Password manager: logins stored in data:passwords.vault, encrypted by vault.lua (PIN + device key).
-- Each entry is one line "name<TAB>user<TAB>password". Plaintext exists only while unlocked (see VAULT.md).
-- Confirm = open an entry. Up on an open entry = delete it (with a second confirm). Back = lock and exit.

local vault = require("vault")
local PATH = "data:passwords.vault"
local LH = 26

local W, H = 0, 0
local v

local function clip(s, n) return #s > n and s:sub(1, n) or s end
local function txt(...) return input.text(...) or "" end

local function entries()
  local out = {}
  for line in (v.data or ""):gmatch("[^\n]+") do
    local name, user, pass = line:match("^([^\t]*)\t([^\t]*)\t(.*)$")
    if name then out[#out + 1] = { name = name, user = user, pass = pass } end
  end
  return out
end

local function store(list)
  local lines = {}
  for _, e in ipairs(list) do lines[#lines + 1] = e.name .. "\t" .. e.user .. "\t" .. e.pass end
  v.data = table.concat(lines, "\n")
  local ok, err = v:save()
  if not ok then error("save failed: " .. tostring(err)) end
end

local function message(lines, footer)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Password manager", "ui12", "bw")
  local y = 60
  for _, l in ipairs(lines) do gfx.text(14, y, l, "ui12"); y = y + LH end
  gfx.text(14, H - 34, footer or "Back = return", "small")
  gfx.present()
  while input.wait() ~= "back" do end
end

local function open_pin()
  if vault.exists(PATH) then
    local pin = txt("Vault PIN", "", 64, "password")
    if pin == "" then return nil end
    local got, err = vault.unlock(PATH, pin)
    if not got then message({ tostring(err) }, "Back = try again"); return nil end
    return got
  end
  local pin = txt("Choose a PIN (4-64 chars)", "", 64, "password")
  local again = txt("Repeat PIN", "", 64, "password")
  if pin == "" or pin ~= again then message({ "PINs did not match, or empty." }); return nil end
  local created, err = vault.create(PATH, pin, "")
  if not created then message({ tostring(err) }); return nil end
  return created
end

local function show_entry(e, idx)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, clip(e.name, 28), "ui12", "bw")
  gfx.text(14, 70, "user:     " .. clip(e.user, 36), "ui12")
  gfx.text(14, 100, "password: " .. clip(e.pass, 36), "ui12")
  gfx.text(14, H - 60, "Up = delete this entry (confirm again)", "small")
  gfx.text(14, H - 34, "Back = list", "small")
  gfx.present()
  local ev = input.wait()
  if ev == "up" then
    gfx.clear(); gfx.text(14, 60, "Delete " .. clip(e.name, 30) .. "?", "ui12"); gfx.text(14, 90, "Confirm = yes, Back = no", "small"); gfx.present()
    if input.wait() == "confirm" then
      local list = entries()
      table.remove(list, idx)
      store(list)
      return "deleted"
    end
  end
end

local function main()
  W, H = gfx.size()
  v = open_pin()
  if not v then return end
  local cur = 1
  while true do
    local list = entries()
    local items = { "+ add entry" }
    for _, e in ipairs(list) do items[#items + 1] = e.name .. "  (" .. e.user .. ")" end
    items[#items + 1] = "lock and quit"
    gfx.clear(); W, H = gfx.size()
    gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Password manager", "ui12", "bw")
    local y = 56
    for i, label in ipairs(items) do
      if y > H - 60 then break end
      if i == cur then gfx.rect(10, y - 4, W - 20, LH + 4, true); gfx.text(16, y, clip(label, 40), "small", "w")
      else gfx.text(16, y, clip(label, 40), "small") end
      y = y + LH
    end
    gfx.text(14, H - 34, "Confirm = open, Back = lock and exit", "small")
    gfx.present()
    local e = input.wait()
    if e == "up" then cur = cur > 1 and cur - 1 or #items
    elseif e == "down" then cur = cur < #items and cur + 1 or 1
    elseif e == "back" then break
    elseif e == "confirm" then
      if cur == 1 then
        local name = txt("Name (site or service)", "", 40)
        if name ~= "" then
          local user = txt("User / email", "", 60)
          local pass = txt("Password", "", 120, "password")
          name = name:gsub("[\t\n]", " "); user = user:gsub("[\t\n]", " "); pass = pass:gsub("[\t\n]", " ")
          list[#list + 1] = { name = name, user = user, pass = pass }
          store(list)
        end
      elseif cur == #items then break
      else
        local idx = cur - 1
        local res = show_entry(list[idx], idx)
        if res == "deleted" then cur = 1 end
      end
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
