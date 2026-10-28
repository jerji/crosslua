-- Clock: large local time and date. No radio, no storage. If the device clock has never been
-- synced (time.now() is nil) it says so instead of showing a made-up time.

local DAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTHS = { "January", "February", "March", "April", "May", "June", "July",
  "August", "September", "October", "November", "December" }
local REFRESH_MS = 30000     -- e-ink: redraw about twice a minute, the minute is what matters

local function draw()
  gfx.clear()
  local W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, "Clock", "ui12", "bw")
  local now = time.now()
  if not now then
    gfx.text(W // 2, 220, "Clock not set", "ui12", "c")
    gfx.text(W // 2, 256, "Connect WiFi once (time sync)", "small", "c")
    gfx.text(W // 2, 280, "or set the time in Settings.", "small", "c")
  else
    local d = time.date(now)
    gfx.text(W // 2, 200, string.format("%02d:%02d", d.hour, d.min), "sans18", "c")
    gfx.text(W // 2, 300, DAYS[d.wday] .. ", " .. MONTHS[d.month] .. " " .. d.day, "ui12", "c")
    gfx.text(W // 2, 330, string.format("%d", d.year), "ui12", "c")
  end
  gfx.text(14, H - 34, "Back = exit", "small")
  gfx.present()
end

local function main()
  draw()
  local last = system.millis()
  while true do
    if input.poll() == "back" then break end
    if system.millis() - last >= REFRESH_MS then
      draw()
      last = system.millis()
    end
    app.sleep(200)
  end
end

local ok, err = pcall(main)
if not ok then
  gfx.clear()
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b")
  gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
