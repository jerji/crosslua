-- PIN lock with duress PIN. Two PINs: the normal one unlocks (shows "Unlocked", back exits). The duress PIN
-- shows a decoy reading screen and then wipes THIS app's data folder (data:) by overwriting each file with
-- zeros before removing it. It cannot touch other apps' data or anything outside the sandbox.
--
-- Storage: data:lock.bin = salt(16) | hash(normal, 32) | hash(duress, 32), where hash = PBKDF2-SHA256 of the PIN
-- (with a per-PIN salt). Checked with crypto.equal. Never stores a PIN.
-- Limits: wiping overwrites with zeros; on flash wear-levelled storage the old blocks may survive. Not a secure erase.

local FILE = "data:lock.bin"
local ITER = 5000
local DECOY = {
  "Chapter 1",
  "",
  "The morning came in grey over the hills, and the",
  "road the doctor had described was longer than it",
  "looked on the map. She counted the milestones...",
}

local W, H = 0, 0
local function txt(...) return input.text(...) or "" end

local function hash(pin, salt)
  return crypto.pbkdf2_sha256(pin, salt, ITER, 32)
end

local function setup()
  gfx.clear(); W, H = gfx.size()
  gfx.text(14, 60, "Set a normal PIN, then a duress PIN.", "ui12")
  gfx.text(14, 90, "Duress PIN shows a decoy and wipes this app.", "small")
  gfx.present()
  local p1 = txt("Normal PIN (4-32)", "", 32, "password")
  local p2 = txt("Duress PIN (4-32, different)", "", 32, "password")
  if #p1 < 4 or #p2 < 4 or p1 == p2 then return false, "PINs must be 4+ chars and differ" end
  local salt1, salt2 = crypto.random(16), crypto.random(16)
  local blob = salt1 .. hash(p1, salt1) .. salt2 .. hash(p2, salt2)
  local ok, err = fs.write(FILE, blob)
  if not ok then return false, tostring(err) end
  return true
end

local function wipe_own_data()
  local names = fs.list("data:") or {}
  local wiped = 0
  for _, n in ipairs(names) do
    if n:sub(-1) ~= "/" then
      local size = fs.size("data:" .. n) or 0
      if size > 0 and size <= 65536 then
        fs.write("data:" .. n, string.rep("\0", size))
      end
      fs.remove("data:" .. n)
      wiped = wiped + 1
    end
  end
  return wiped
end

local function decoy()
  gfx.clear(); W, H = gfx.size()
  local y = 40
  for _, l in ipairs(DECOY) do gfx.text(20, y, l, "ui12"); y = y + 28 end
  gfx.present()
  while input.wait() ~= "back" do end
end

local function main()
  W, H = gfx.size()
  if not fs.exists(FILE) then
    local ok, err = setup()
    if not ok then gfx.clear(); gfx.text(14, 60, "setup failed: " .. err, "ui12"); gfx.present(); while input.wait() ~= "back" do end; return end
  end
  local blob = fs.read(FILE)
  if not blob or #blob ~= 16 + 32 + 32 + 32 then
    gfx.clear(); gfx.text(14, 60, "lock file damaged; delete data:lock.bin to reset", "ui12"); gfx.present()
    while input.wait() ~= "back" do end
    return
  end
  local salt_n, h_n = blob:sub(1, 16), blob:sub(17, 48)
  local salt_d, h_d = blob:sub(49, 64), blob:sub(65, 96)
  -- three tries before a pause; no lockout counter is stored (it would be wiped by duress anyway)
  for attempt = 1, 99 do
    local pin = txt("PIN", "", 32, "password")
    if pin == "" then return end
    if crypto.equal(hash(pin, salt_n), h_n) then
      gfx.clear(); gfx.text(14, 60, "Unlocked.", "sans18"); gfx.text(14, 110, "Back = lock and exit", "small"); gfx.present()
      while input.wait() ~= "back" do end
      return
    elseif crypto.equal(hash(pin, salt_d), h_d) then
      local n = wipe_own_data()
      decoy()
      return
    else
      gfx.clear(); gfx.text(14, 60, "Wrong PIN (attempt " .. attempt .. ")", "ui12"); gfx.present()
      app.sleep(1200)
    end
  end
end

local ok, err = pcall(main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
