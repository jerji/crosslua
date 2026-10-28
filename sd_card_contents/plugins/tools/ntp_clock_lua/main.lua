-- NTP clock (network): join the saved WiFi (the system picks it), sync the clock with SNTP, then show
-- local time and date. Confirm re-syncs. Back exits. Uses wifi.connect{tls=false} because only SNTP is needed.

local DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local function show(lines, footer)
  gfx.clear()
  local W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "NTP clock", "ui12", "bw")
  local y = 110
  for _, l in ipairs(lines) do gfx.text(W // 2, y, l, "sans18", "c"); y = y + 60 end
  gfx.text(14, H - 34, footer or "Confirm = re-sync, Back = exit", "small")
  gfx.present()
end

local function sync()
  show({ "syncing..." }, "")
  local ok, why = wifi.connect({ tls = false })
  if not ok then return false, "wifi: " .. tostring(why) end
  local synced, err = time.sync(10)
  if not synced then return false, "sntp: " .. tostring(err) end
  return true
end

local function clock_lines()
  local now = time.now()
  if not now then return { "clock not set" } end
  local d = time.date(now)
  return {
    string.format("%02d:%02d:%02d", d.hour, d.min, d.sec),
    string.format("%s %04d-%02d-%02d", DAYS[d.wday], d.year, d.month, d.day),
  }
end

local ok, err = pcall(function()
  local synced, why = sync()
  if not synced then show({ why }, "Back = exit") end
  show(clock_lines())
  local last = system.millis()
  while true do
    local e = input.wait(1000)
    if e == "back" then break end
    if e == "confirm" then
      local s2, w2 = sync()
      if not s2 then show({ w2 }, "Back = exit") else show(clock_lines()) end
    elseif system.millis() - last >= 1000 then
      show(clock_lines())
      last = system.millis()
    end
  end
end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
