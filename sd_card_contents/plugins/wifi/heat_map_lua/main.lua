-- WiFi heat map (passive, receive only; biscuit BS-R11). You choose one AP, then walk a grid:
-- move the cursor to where you are standing, press Confirm, and the app samples that AP's beacon RSSI for
-- SAMPLE_MS and stores the average for the cell. The map is drawn as one character per cell (strongest = 9).
-- There is no GPS: the grid is your own floor plan, and cell positions are whatever you say they are.
-- Back saves data:heatmap_NNN.csv (row, col, avg_rssi, samples) and exits.

local CHANS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }
local DWELL_MS = 800
local SAMPLE_MS = 3000
local ROWS, COLS = 6, 8
local MAX_APS = 30
local LH = 22
local GRID_TOP, GRID_LEFT, CELL_W, CELL_H = 70, 24, 40, 40   -- on-screen grid geometry (also used for taps)

local W, H = 0, 0
local aps, ap_list = {}, {}
local ci, last_hop = 1, 0
local target = nil
local grid = {}          -- grid[r][c] = { sum, n }
local cur_r, cur_c = 1, 1
local status = ""

local function clip(s, n) return #s > n and s:sub(1, n) or s end

local function on_beacon(frame, ch, rssi)
  if #frame < 37 or (frame:byte(1) & 0xFC) ~= 0x80 then return end
  local bssid = frame:sub(17, 22)
  local ssid = ""
  local i = 37
  while i + 1 <= #frame do
    local tag, len = frame:byte(i), frame:byte(i + 1)
    if tag == 0 then ssid = frame:sub(i + 2, i + 1 + len); break end
    i = i + 2 + len
  end
  if not ssid:match("^[%g ]*$") then ssid = "" end
  local a = aps[bssid]
  if not a then
    if #ap_list >= MAX_APS then return end
    a = { bssid = bssid, ssid = ssid, ch = ch, rssi = rssi or -99 }
    aps[bssid] = a
    ap_list[#ap_list + 1] = a
  elseif ssid ~= "" then a.ssid = ssid end
  a.ch = ch
  if rssi then a.rssi = rssi end
end

-- scan until the user picks an AP; returns the AP or nil (back)
local function pick_ap()
  wifi.monitor_start({ channel = CHANS[ci] })
  last_hop = system.millis()
  local sel = 1
  while true do
    local frame, meta = wifi.monitor_recv()
    while frame do
      on_beacon(frame, (meta and meta.channel) or CHANS[ci], meta and meta.rssi)
      frame, meta = wifi.monitor_recv()
    end
    if system.millis() - last_hop >= DWELL_MS then
      ci = ci % #CHANS + 1
      wifi.monitor_channel(CHANS[ci]); last_hop = system.millis()
    end
    gfx.clear(); W, H = gfx.size()
    gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Heat map: pick AP", "ui12", "bw")
    local y = 56
    if #ap_list == 0 then gfx.text(14, y, "listening...", "ui12") end
    for i, a in ipairs(ap_list) do
      if y > H - 80 then break end
      local label = string.format("%-16s ch%-2d %d", clip(a.ssid ~= "" and a.ssid or "<hidden>", 16), a.ch, a.rssi)
      if i == sel then gfx.rect(10, y - 4, W - 20, LH + 4, true); gfx.text(16, y, label, "small", "w")
      else gfx.text(16, y, label, "small") end
      y = y + LH
    end
    gfx.text(14, H - 34, "Left/Right, Confirm or tap = pick, Back = quit", "small")
    gfx.present()
    local e = input.poll()
    -- grid mode (X4 Pro) sends left/right from the physical buttons, so accept both pairs
    if e == "up" or e == "left" then sel = sel > 1 and sel - 1 or math.max(1, #ap_list)
    elseif e == "down" or e == "right" then sel = sel < #ap_list and sel + 1 or 1
    elseif e == "confirm" and #ap_list > 0 then
      local px, py = input.pos()          -- a touch picks the row it landed on; a button picks the highlight
      if not px then return ap_list[sel] end
      local idx = (py - 56) // LH + 1
      if py >= 56 and idx >= 1 and idx <= #ap_list then return ap_list[idx] end
    elseif e == "back" then return nil end
    app.sleep(20)
  end
end

-- average the target's beacon RSSI for SAMPLE_MS on its channel
local function sample()
  wifi.monitor_channel(target.ch)
  local sum, n = 0, 0
  local t0 = system.millis()
  while system.millis() - t0 < SAMPLE_MS do
    local frame, meta = wifi.monitor_recv()
    while frame do
      if #frame >= 22 and (frame:byte(1) & 0xFC) == 0x80 and frame:sub(17, 22) == target.bssid and meta and meta.rssi then
        sum = sum + meta.rssi; n = n + 1
      end
      frame, meta = wifi.monitor_recv()
    end
    app.sleep(20)
  end
  return sum, n
end

local function band(avg)
  if not avg then return "." end
  local v = math.floor((avg + 100) / 6)   -- -100 dBm -> 0, -46 dBm -> 9
  return tostring(math.max(0, math.min(9, v)))
end

local function draw()
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, "Heat map: " .. clip(target.ssid ~= "" and target.ssid or "<hidden>", 18), "ui12", "bw")
  for r = 1, ROWS do
    for c = 1, COLS do
      local x, y = GRID_LEFT + (c - 1) * CELL_W, GRID_TOP + (r - 1) * CELL_H
      local cell = grid[r][c]
      local avg = cell and cell.n > 0 and (cell.sum / cell.n) or nil
      gfx.rect(x, y, CELL_W, CELL_H, false)
      if r == cur_r and c == cur_c then gfx.rect(x + 3, y + 3, CELL_W - 6, CELL_H - 6, false) end
      gfx.text(x + CELL_W // 2, y + 8, band(avg), "ui12", "c")
    end
  end
  local y = GRID_TOP + ROWS * CELL_H + 14
  local cell = grid[cur_r][cur_c]
  local detail = cell and cell.n > 0 and string.format("cell %d,%d  avg %d dBm  (%d samples)", cur_r, cur_c, cell.sum / cell.n, cell.n)
    or string.format("cell %d,%d  not sampled", cur_r, cur_c)
  gfx.text(14, y, detail, "small")
  gfx.text(14, y + 24, "digits: 9 strongest .. 0 weakest, . = none", "small")
  gfx.text(14, H - 60, status, "small")
  gfx.text(14, H - 34, "Left/Right walk the grid, Confirm or tap = sample, Back = save", "small")
  gfx.present()
end

local function save()
  local name
  for n = 1, 999 do
    local c = string.format("data:heatmap_%03d.csv", n)
    if not fs.exists(c) then name = c; break end
  end
  if not name then return nil end
  local rows = { "row,col,avg_rssi,samples" }
  for r = 1, ROWS do for c = 1, COLS do
    local cell = grid[r][c]
    if cell.n > 0 then rows[#rows + 1] = string.format("%d,%d,%.1f,%d", r, c, cell.sum / cell.n, cell.n) end
  end end
  fs.write(name, table.concat(rows, "\n") .. "\n")
  return name
end

local function main()
  device.input_mode("grid")
  W, H = gfx.size()
  for r = 1, ROWS do grid[r] = {}; for c = 1, COLS do grid[r][c] = { sum = 0, n = 0 } end end
  target = pick_ap()
  if not target then wifi.monitor_stop(); return end
  draw()
  -- Grid mode on X4 Pro: the two physical buttons send left/right only. Left/right walk the cells in
  -- reading order (row by row), so every cell is reachable; up/down still move one row when they arrive.
  local function step(d)
    local k = math.max(1, math.min(ROWS * COLS, (cur_r - 1) * COLS + cur_c + d))
    cur_r, cur_c = (k - 1) // COLS + 1, (k - 1) % COLS + 1
  end
  -- cell under a touch point, or nil if the touch missed the grid
  local function cell_at(x, y)
    local c = (x - GRID_LEFT) // CELL_W + 1
    local r = (y - GRID_TOP) // CELL_H + 1
    if x < GRID_LEFT or y < GRID_TOP or c > COLS or r > ROWS then return nil end
    return r, c
  end
  while true do
    local e = input.wait()
    if e == "back" then break
    elseif e == "left" then step(-1)
    elseif e == "right" then step(1)
    elseif e == "up" then if cur_r > 1 then cur_r = cur_r - 1 end
    elseif e == "down" then if cur_r < ROWS then cur_r = cur_r + 1 end
    elseif e == "confirm" then
      local px, py = input.pos()          -- a tap on a cell moves there first; a tap off the grid does nothing
      local skip = false
      if px then
        local r, c = cell_at(px, py)
        if r then cur_r, cur_c = r, c else skip = true end
      end
      if not skip then
        status = "sampling " .. (SAMPLE_MS // 1000) .. " s..."
        draw()
        local sum, n = sample()
        if n > 0 then
          local cell = grid[cur_r][cur_c]
          cell.sum = cell.sum + sum; cell.n = cell.n + n
          status = string.format("saved %d beacons at %d,%d", n, cur_r, cur_c)
        else
          status = "no beacons heard here; move closer or try again"
        end
      end
    end
    draw()
  end
  wifi.monitor_stop()
  local name = save()
  status = name and ("saved " .. name) or "could not save (no free name)"
end

local ok, err = pcall(main)
pcall(function() wifi.monitor_stop() end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
