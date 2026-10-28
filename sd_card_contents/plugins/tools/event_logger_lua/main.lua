-- Event logger (no radio): records every button press with a timestamp to data:events.log while it runs.
-- The log is rotated when it passes ROTATE_BYTES (kept as events.log.1). Confirm shows the last lines.
-- Only this app's own data folder is written; nothing else on the card is touched.

local LOG = "data:events.log"
local OLD = "data:events.log.1"
local ROTATE_BYTES = 16384
local TAIL_LINES = 10

local W, H = 0, 0
local count = 0

local function log(line)
  if fs.exists(LOG) and (fs.size(LOG) or 0) > ROTATE_BYTES then
    fs.remove(OLD)
    fs.rename(LOG, OLD)
  end
  fs.append(LOG, line .. "\n")
end

local function tail()
  local s = fs.read(LOG) or ""
  local lines = {}
  for l in s:gmatch("[^\n]+") do lines[#lines + 1] = l end
  local out = {}
  for i = math.max(1, #lines - TAIL_LINES + 1), #lines do out[#out + 1] = lines[i] end
  return out
end

local function draw(note)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Event Logger", "ui12", "bw")
  gfx.text(14, 52, "events this session: " .. count, "ui12")
  local y = 84
  for _, l in ipairs(tail()) do
    gfx.text(14, y, l:sub(1, 46), "small")
    y = y + 22
  end
  gfx.text(14, H - 60, note or "Confirm = show log, Back = exit", "small")
  gfx.text(14, H - 34, "Logging to data:events.log", "small")
  gfx.present()
end

local function main()
  log(string.format("%d start", system.millis()))
  draw()
  local last = 0
  while true do
    local e = input.wait(500)
    if e then
      if e == "back" then break end
      count = count + 1
      log(string.format("%d %s", system.millis(), e))
      draw("last: " .. e)
    end
  end
  log(string.format("%d stop", system.millis()))
end

local ok, err = pcall(main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
