-- totp_lua - an authenticator (RFC 6238 one-time codes) whose secrets live in a PIN-protected vault on the card.
-- vault.lua: AES-256 + HMAC, key = PIN + this device's secret (crypto.device_key). totp.lua: codes, base32, otpauth:// links.
-- No permissions: it needs no radio. The clock comes from the system (restored from flash, re-synced whenever WiFi connects).
local function __main()
local vault = require("vault")
local totp = require("totp")

local PATH, IMPORT = "data:vault.bin", "data:import.txt"
local LOCK_MS = 120000  -- lock after two idle minutes
local MAX_ACCOUNTS = 50
local W, H = gfx.size()
local ROW_H, TOP = 96, 52

local function T(x, y, s, font, bold) if bold then gfx.text(x, y, s, font, "b") else gfx.text(x, y, s, font) end end
local function trunc(s, n) s = tostring(s or ""); if #s > n then return s:sub(1, n - 1) .. "~" end return s end
local function header(title) gfx.clear(); gfx.rect(0, 0, W, 40, true); gfx.text(16, 14, title, "ui12", "w") end
local function footer(hint) gfx.rect(16, H - 44, W - 32, 2, true); T(16, H - 32, hint, "small") end
local function fmt_code(c)
  if #c == 6 then return c:sub(1, 3) .. " " .. c:sub(4) elseif #c == 8 then return c:sub(1, 4) .. " " .. c:sub(5) end
  return c
end

-- word-wrap lines to the screen width ("" stays a blank line)
local function wrap(lines, font, maxw)
  local out = {}
  for _, line in ipairs(lines) do
    if line == "" then out[#out + 1] = ""
    else
      local cur = ""
      for word in line:gmatch("%S+") do
        local try = cur == "" and word or (cur .. " " .. word)
        if cur == "" or gfx.text_width(try, font) <= maxw then cur = try else out[#out + 1] = cur; cur = word end
      end
      out[#out + 1] = cur
    end
  end
  return out
end

-- a screen with a few lines of text; any button closes it
local function message(title, lines, hint)
  header(title)
  for i, l in ipairs(wrap(lines, "ui12", W - 32)) do T(16, 56 + (i - 1) * 28, l, "ui12") end
  footer(hint or "any button: continue")
  gfx.present()
  input.wait()
end

local function busy(text)
  header("Authenticator")
  T(16, 70, text, "ui12")
  gfx.present()
end

-- pick one of a few entries; returns the index or nil (back)
local function choose(title, items, hint)
  local sel = 1
  while true do
    header(title)
    for i, it in ipairs(items) do
      local y = 56 + (i - 1) * 44
      if i == sel then gfx.rect(10, y - 6, W - 20, 38, false); T(20, y, "> " .. it, "ui12", true) else T(20, y, "  " .. it, "ui12") end
    end
    footer(hint or "up/down  select     confirm  ok     back  cancel")
    gfx.present()
    local ev = input.wait()
    if ev == "up" and sel > 1 then sel = sel - 1
    elseif ev == "down" and sel < #items then sel = sel + 1
    elseif ev == "confirm" then return sel
    elseif ev == "back" then return nil end
  end
end

-- PIN pad: a digit wheel (no keyboard pop-up). up/down spin the current digit, right locks it and moves on, left erases the
-- last one (at the start: type a passphrase instead), confirm submits, back cancels. Returns a string, "keyboard" or nil.
local WHEEL_MAX = 12
local function ask_digits(title)
  local digits, cur, note = {}, 0, nil
  while true do
    header(title)
    local n = #digits
    T(16, 56, "Spin each digit, then move to the next.", "small")
    for i = 1, WHEEL_MAX do
      local x = 20 + (i - 1) * 36
      if i <= n then T(x + 8, 150, "*", "sans18", true)
      elseif i == n + 1 then
        gfx.rect(x - 4, 120, 34, 76, false)
        T(x + 10, 98, "^", "ui12"); T(x + 4, 140, tostring(cur), "sans18", true); T(x + 10, 198, "v", "ui12")
      else T(x + 8, 150, "_", "sans18") end
    end
    T(16, 250, "up / down    spin the digit", "ui12")
    T(16, 284, "right        lock it, next digit", "ui12")
    T(16, 318, "left         erase the last digit", "ui12")
    T(16, 352, "             (first digit: use a passphrase)", "small")
    T(16, 392, "confirm      done (" .. vault.MIN_PIN .. "+ digits)", "ui12")
    T(16, 426, "back         cancel", "ui12")
    if note then T(16, 480, note, "ui12", true) end
    gfx.present()
    local ev = input.wait()
    note = nil
    if ev == "up" and n < WHEEL_MAX then cur = (cur + 1) % 10
    elseif ev == "down" and n < WHEEL_MAX then cur = (cur - 1) % 10
    elseif ev == "right" and n < WHEEL_MAX then digits[n + 1] = cur; cur = 0
    elseif ev == "left" then
      if n == 0 then return "keyboard" end
      cur = digits[n]; digits[n] = nil
    elseif ev == "confirm" then
      local all = {table.unpack(digits)}
      if n < WHEEL_MAX then all[#all + 1] = cur end
      if #all < vault.MIN_PIN then note = "At least " .. vault.MIN_PIN .. " digits." else return table.concat(all) end
    elseif ev == "back" then return nil end
  end
end

local function ask_pin(title)
  local r = ask_digits(title)
  if r == "keyboard" then return input.text(title .. " (passphrase)", "", vault.MAX_PIN, "password") end
  return r
end

-- first run: choose a PIN twice, create the vault. Returns the open vault or nil.
local function setup()
  message("Authenticator", {"First start.", "", "Your secrets are encrypted on the card with a", "PIN and a key only this device holds.", "",
    "Choose " .. vault.MIN_PIN .. " or more digits (a wheel: up/down", "spin, right next). At the first digit, left", "lets you type a passphrase instead.", "",
    "A passphrase is much stronger: if someone has", "the SD card AND a dump of this device's flash,", "only the PIN stands in the way.", "", "There is no recovery: forget it, lose it."})
  while true do
    local a = ask_pin("Choose a PIN")
    if not a then return nil end
    if #a < vault.MIN_PIN then
      message("PIN too short", {"Use at least " .. vault.MIN_PIN .. " characters."})
    else
      local b = ask_pin("Repeat the PIN")
      if not b then return nil end
      if a ~= b then
        message("PINs differ", {"The two entries do not match.", "Try again."})
      else
        busy("Creating the vault (about a second)...")
        local v, err = vault.create(PATH, a, json.encode({accounts = {}}))
        if v then return v end
        message("Could not create the vault", {tostring(err)})
        return nil
      end
    end
  end
end

-- ask for the PIN until it works or the user backs out. Returns the open vault or nil.
local function unlock()
  while true do
    local pin = ask_pin("Enter PIN")
    if not pin then return nil end
    busy("Unlocking...")
    local v, err = vault.unlock(PATH, pin)
    if v then return v end
    if err == "no vault" or err == "not a vault file" or err == "unsupported vault version" or err == "unsupported vault settings"
       or err == nil or err:find("device secret", 1, true) then
      message("Cannot open the vault", {tostring(err)})
      return nil
    end
    message("Wrong PIN", {"Wrong PIN, or the vault file is damaged.", "", "Try again."})
  end
end

local function open_vault()
  if vault.exists(PATH) then return unlock() else return setup() end
end

local function load_db(v)
  local db = json.decode(v.data)
  if type(db) ~= "table" or type(db.accounts) ~= "table" then return nil end
  return db
end

local function save_db(v, db)
  v.data = json.encode(db)
  local ok, err = v:save()
  if not ok then message("Could not save", {tostring(err)}) end
  return ok
end

local function add_account(db, acc)
  for _, a in ipairs(db.accounts) do
    if a.secret == acc.secret and a.name == acc.name and a.issuer == acc.issuer then return false, "already there" end
  end
  if #db.accounts >= MAX_ACCOUNTS then return false, "at most " .. MAX_ACCOUNTS .. " accounts" end
  db.accounts[#db.accounts + 1] = acc
  return true
end

local function add_typed(v, db)
  local name = input.text("Account name", "", 60)
  if not name or name == "" then return end
  local issuer = input.text("Issuer (optional)", "", 40)
  if not issuer then return end
  local secret = input.text("Secret (base32)", "", 128)
  if not secret or secret == "" then return end
  secret = secret:upper():gsub("[%s%-=]", "")
  local raw, e = totp.b32decode(secret)
  if not raw then message("Bad secret", {tostring(e), "", "Base32 uses the letters A-Z and the digits 2-7."}); return end
  local acc = {name = name, issuer = issuer, secret = secret, digits = 6, period = 30, alg = "SHA1"}
  local ok, why = add_account(db, acc)
  if not ok then message("Not added", {why}); return end
  if save_db(v, db) then message("Added", {name, "", "6 digits, 30 s, SHA1 (the usual defaults)."}) end
end

local function import_file(v, db)
  local text = fs.read(IMPORT)
  if not text then
    message("Import", {"Copy a text file with one otpauth:// link", "per line to the card with File Transfer:", "", "  /.crosslua/data/totp_lua/import.txt", "",
      "Then choose Import again. The file is deleted", "afterwards (it holds the secrets in plain text)."})
    return
  end
  local added, skipped, errors = 0, 0, {}
  for line in text:gmatch("[^\r\n]+") do
    if line:find("%S") then
      local acc, e = totp.parse_uri(line)
      if acc then
        local ok = add_account(db, acc)
        if ok then added = added + 1 else skipped = skipped + 1 end
      else
        skipped = skipped + 1
        if #errors < 3 then errors[#errors + 1] = tostring(e) end
      end
    end
  end
  if added > 0 and not save_db(v, db) then return end  -- keep import.txt when nothing was saved
  fs.remove(IMPORT)
  local lines = {("Added %d, skipped %d."):format(added, skipped), "", "import.txt was deleted from the card."}
  for _, e in ipairs(errors) do lines[#lines + 1] = "  skipped: " .. trunc(e, 40) end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Deleting does not wipe the flash: treat those secrets as exposed if the card was ever shared."
  message("Import", lines)
end

local function change_pin(v)
  local a = ask_pin("New PIN")
  if not a then return end
  if #a < vault.MIN_PIN then message("PIN too short", {"Use at least " .. vault.MIN_PIN .. " characters."}); return end
  local b = ask_pin("Repeat the new PIN")
  if not b then return end
  if a ~= b then message("PINs differ", {"Nothing changed."}); return end
  busy("Re-encrypting (about a second)...")
  local ok, err = v:change_pin(a)
  if ok then message("PIN changed", {"The vault is re-encrypted with the new PIN."}) else message("Could not change the PIN", {tostring(err)}) end
end

local function delete_account(v, db, i)
  local a = db.accounts[i]
  if not a then return end
  local pick = choose("Delete " .. trunc(a.name, 30) .. "?", {"Keep it", "Delete it (cannot be undone)"})
  if pick == 2 then
    table.remove(db.accounts, i)
    save_db(v, db)
  end
end

local function draw_list(db, sel, top, t)
  header("Authenticator")
  local y0 = TOP
  if not t then
    T(16, y0, "The clock is not set: no codes yet.", "ui12", true)
    T(16, y0 + 24, "Connect to WiFi once (it syncs the time).", "small")
    y0 = y0 + 56
  end
  local rows = (H - y0 - 60) // ROW_H
  if #db.accounts == 0 then
    T(16, y0 + 10, "No accounts yet.", "ui12", true)
    T(16, y0 + 40, "Press confirm for the menu:", "small")
    T(16, y0 + 60, "add a secret or import a file.", "small")
  end
  for i = top, math.min(#db.accounts, top + rows - 1) do
    local a = db.accounts[i]
    local y = y0 + (i - top) * ROW_H
    if i == sel then gfx.rect(0, y, 8, ROW_H - 8, true); gfx.rect(8, y, W - 16, ROW_H - 8, false) end
    T(24, y + 6, trunc(a.name, 26), "ui12", i == sel)
    if a.issuer ~= "" then T(24, y + 32, trunc(a.issuer, 32), "small") end
    if t then
      local code, e = totp.code(totp.b32decode(a.secret) or "", t, {digits = a.digits, period = a.period, alg = a.alg})
      T(24, y + 40, code and fmt_code(code) or ("error: " .. trunc(e, 20)), "sans18", true)
      T(W - 90, y + 48, totp.remaining(t, a.period) .. " s", "ui12")
    end
  end
  footer("up/down  select    confirm  menu    back  exit")
  gfx.present()
end

local function main_loop(v, db)
  local sel, top, idle_from = 1, 1, system.millis()
  local dirty = true
  while true do
    local t = time.now()
    local y0 = t and TOP or TOP + 56
    local rows = (H - y0 - 60) // ROW_H
    if sel < top then top = sel elseif sel > top + rows - 1 then top = sel - rows + 1 end
    if dirty then draw_list(db, sel, top, t); dirty = false end
    -- wake when the soonest visible code changes (a little after the boundary), but at least once a second
    local wait = 60000
    if t then
      for i = top, math.min(#db.accounts, top + rows - 1) do wait = math.min(wait, totp.remaining(t, db.accounts[i].period) * 1000 + 300) end
    end
    local ev = input.wait(math.max(1000, wait))
    local now = system.millis()
    if ev == nil then
      if now - idle_from >= LOCK_MS then return "lock" end
      dirty = true
    else
      idle_from = now
      if ev == "up" and sel > 1 then sel = sel - 1; dirty = true
      elseif ev == "down" and sel < #db.accounts then sel = sel + 1; dirty = true
      elseif ev == "back" then return "exit"
      elseif ev == "confirm" then
        local pick = choose("Menu", {"Add an account (type the secret)", "Import import.txt", "Delete the selected account", "Change PIN", "Lock now", "Back to the codes"})
        if pick == 1 then add_typed(v, db) elseif pick == 2 then import_file(v, db) elseif pick == 3 then delete_account(v, db, sel)
        elseif pick == 4 then change_pin(v) elseif pick == 5 then return "lock" end
        if sel > #db.accounts then sel = math.max(1, #db.accounts) end
        idle_from = system.millis()
        dirty = true
      end
    end
  end
end

while true do
  local v = open_vault()
  if not v then return end
  local db = load_db(v)
  if not db then
    message("Vault unreadable", {"The vault opened but its contents are not", "in the expected format."})
    v:lock()
    return
  end
  local why = main_loop(v, db)
  v:lock()
  db = nil
  if why == "exit" then return end
end
end

local ok, err = pcall(__main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "Authenticator error", "ui12", "b"); gfx.text(10, 50, tostring(err):sub(1, 60), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
