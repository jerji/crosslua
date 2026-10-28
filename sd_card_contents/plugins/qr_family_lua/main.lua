-- QR family (no radio): three QR makers on the e-ink screen. Nothing is stored on the card.
--   Text      : any line you type
--   WiFi join : WIFI:T:WPA;S:<ssid>;P:<password>;;  (the separators are escaped as the format requires)
--   TOTP      : paste an otpauth:// link (for setting up an authenticator app on the phone)
-- Two-stage check: gfx.qr returns false when the text is too long for one code.

local W, H = 0, 0

local function escape_wifi(s)
  return (s:gsub("([\\;,:\"])", "\\%1"))
end

local function show(title, payload)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, title, "ui12", "bw")
  local side = math.min(W - 60, H - 150)
  local ok = gfx.qr(payload, (W - side) // 2, 60, side)
  if not ok then gfx.text(14, 120, "Too long for one QR code.", "ui12") end
  gfx.text(14, H - 34, "Back = return", "small")
  gfx.present()
  while input.wait() ~= "back" do end
end

local function main()
  W, H = gfx.size()
  local items = { "Text", "WiFi join", "TOTP setup link", "Quit" }
  local cur = 1
  while true do
    gfx.clear(); gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "QR family", "ui12", "bw")
    for i, it in ipairs(items) do
      local y = 70 + (i - 1) * 44
      if i == cur then gfx.rect(10, y - 4, W - 20, 30, true); gfx.text(18, y, it, "ui12", "w")
      else gfx.text(18, y, it, "ui12") end
    end
    gfx.present()
    local e = input.wait()
    if e == "up" then cur = cur > 1 and cur - 1 or #items
    elseif e == "down" then cur = cur < #items and cur + 1 or 1
    elseif e == "back" then break
    elseif e == "confirm" then
      if cur == 1 then
        local t = input.text("Text to encode", "", 200)
        if t and t ~= "" then show("Text QR", t) end
      elseif cur == 2 then
        local ssid = input.text("Network name", "", 32)
        if ssid and ssid ~= "" then
          local pass = input.text("Password (blank = open)", "", 63, "password") or ""
          local payload = pass == "" and ("WIFI:T:nopass;S:" .. escape_wifi(ssid) .. ";;")
            or ("WIFI:T:WPA;S:" .. escape_wifi(ssid) .. ";P:" .. escape_wifi(pass) .. ";;")
          show("WiFi join QR", payload)
        end
      elseif cur == 3 then
        local link = input.text("otpauth:// link", "otpauth://totp/", 256)
        if link and link:match("^otpauth://") then show("TOTP setup QR", link) end
      else break end
    end
  end
end

local ok, err = pcall(main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
