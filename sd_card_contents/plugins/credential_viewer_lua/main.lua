-- Credential viewer (read grant: Captures): shows rows of the captive portal's CSV, scrollable.
-- Read-only. Passwords are shown in full because this is for reviewing your own test captures.

local ROW_H = 28
local FILE = "sd:Captures/portal_creds.csv"

local function rows()
  local body = fs.read(FILE, 0, 60000)
  if not body then return nil, "no capture file yet" end
  local out = {}
  for line in body:gmatch("[^\n]+") do out[#out + 1] = line end
  return out
end

local function main()
  local W, H = gfx.size()
  local data, err = rows()
  local top = 1
  while true do
    gfx.clear(); W, H = gfx.size()
    gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Captured credentials", "ui12", "bw")
    if not data then
      gfx.text(14, 60, tostring(err), "ui12")
    else
      local per = (H - 110) // ROW_H
      gfx.text(14, 52, (#data - 1) .. " rows", "small")
      local y = 76
      for i = top, math.min(#data, top + per - 1) do
        gfx.text(14, y, data[i]:sub(1, 52), "small")
        y = y + ROW_H
      end
    end
    gfx.text(14, H - 34, "up/down scroll, back = exit", "small")
    gfx.present()
    local e = input.wait()
    if e == "back" then break end
    if data then
      if e == "down" and top < #data then top = top + 1 end
      if e == "up" and top > 1 then top = top - 1 end
    end
  end
end

local ok, err2 = pcall(main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err2):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
