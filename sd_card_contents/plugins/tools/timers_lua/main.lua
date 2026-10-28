-- Timers: a stopwatch with laps and a Pomodoro timer. No radio, no storage, nothing written.

local W, H = 0, 0
local menu_cur = 1

local function clock_str(ms)
  if ms < 0 then ms = 0 end
  local s = ms // 1000
  local h, m, sec = s // 3600, (s // 60) % 60, s % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, sec) end
  return string.format("%02d:%02d", m, sec)
end

local function header(t)
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, t, "ui12", "bw")
end

local function menu(items)
  while true do
    gfx.clear(); W, H = gfx.size()
    header("Timers")
    local y = 70
    for i, it in ipairs(items) do
      if i == menu_cur then
        gfx.rect(10, y - 4, W - 20, 30, true); gfx.text(18, y, it, "ui12", "w")
      else
        gfx.text(18, y, it, "ui12")
      end
      y = y + 44
    end
    gfx.text(14, H - 34, "Confirm open, Back exit", "small")
    gfx.present()
    local e = input.wait()
    if e == "up" then menu_cur = menu_cur > 1 and menu_cur - 1 or #items
    elseif e == "down" then menu_cur = menu_cur < #items and menu_cur + 1 or 1
    elseif e == "confirm" then return menu_cur
    elseif e == "back" then return nil end
  end
end

-- ---------- stopwatch ----------
local function stopwatch()
  local elapsed, running, t0 = 0, false, 0
  local laps = {}
  local last_draw = -1000
  while true do
    local now = system.millis()
    local total = elapsed + (running and (now - t0) or 0)
    if now - last_draw >= 1000 then
      gfx.clear(); W, H = gfx.size()
      header("Stopwatch")
      gfx.text(W // 2, 120, clock_str(total), "sans18", "c")
      gfx.text(14, 200, running and "running" or (elapsed > 0 and "stopped" or "ready"), "ui12")
      local y = 240
      for i = math.max(1, #laps - 7), #laps do
        gfx.text(16, y, string.format("lap %2d   %s", i, clock_str(laps[i])), "ui12")
        y = y + 30
      end
      gfx.text(14, H - 34, "Confirm start/stop, Down lap, Up reset, Back", "small")
      gfx.present()
      last_draw = now
    end
    local e = input.poll()
    if e == "confirm" then
      if running then elapsed = elapsed + (now - t0); running = false
      else t0 = now; running = true end
      last_draw = -1000
    elseif e == "down" and running then
      laps[#laps + 1] = total
      if #laps > 64 then table.remove(laps, 1) end
      last_draw = -1000
    elseif e == "up" and not running then
      elapsed, laps = 0, {}
      last_draw = -1000
    elseif e == "back" then
      return
    end
    app.sleep(40)
  end
end

-- ---------- pomodoro ----------
local WORK, SHORT, LONG = 25 * 60 * 1000, 5 * 60 * 1000, 15 * 60 * 1000
local function pomodoro()
  local phase, cycles = "work", 0          -- phase: work | break
  local length = WORK
  local remain, running, t0 = WORK, false, 0
  local last_draw = -1000
  local function next_phase()
    if phase == "work" then
      cycles = cycles + 1
      phase = "break"
      length = (cycles % 4 == 0) and LONG or SHORT
    else
      phase = "work"; length = WORK
    end
    remain = length
    running = false
  end
  while true do
    local now = system.millis()
    local left = running and (remain - (now - t0)) or remain
    if running and left <= 0 then
      remain = 0; running = false
      left = 0
      last_draw = -1000
    end
    if now - last_draw >= 1000 then
      gfx.clear(); W, H = gfx.size()
      header("Pomodoro")
      gfx.text(W // 2, 100, phase == "work" and "FOCUS" or "BREAK", "ui12", "c")
      gfx.text(W // 2, 150, clock_str(left), "sans18", "c")
      gfx.text(14, 260, string.format("cycle %d   next %s", cycles, phase == "work" and "break" or "focus"), "ui12")
      if left == 0 then
        gfx.text(14, 300, "Time is up. Confirm = next phase.", "ui12")
      end
      gfx.text(14, H - 34, "Confirm start/pause (or next), Up reset, Back", "small")
      gfx.present()
      last_draw = now
    end
    local e = input.poll()
    if e == "confirm" then
      if left == 0 then
        next_phase()
      elseif running then
        remain = left; running = false
      else
        remain = left; t0 = now; running = true
      end
      last_draw = -1000
    elseif e == "up" then
      phase, length, cycles = "work", WORK, 0
      remain, running = WORK, false
      last_draw = -1000
    elseif e == "back" then
      return
    end
    app.sleep(40)
  end
end

local function main()
  W, H = gfx.size()
  local items = { "Stopwatch", "Pomodoro (25/5)", "Quit" }
  while true do
    local pick = menu(items)
    if not pick or pick == 3 then break end
    if pick == 1 then stopwatch() else pomodoro() end
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
