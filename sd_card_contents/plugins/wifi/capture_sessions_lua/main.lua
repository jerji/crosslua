-- Capture sessions: start/stop/list/delete WiFi PCAP sessions in data: (this app's own folder).
-- Receive-only: wifi.monitor_* only, never wifi.tx. Sessions are session_NNN.pcap, numbered by the next free slot.

local LH = 26
local ROW_H = 34
local MAX_CH = 13
local MAX_LIST = 64          -- detail entries read from data: (fs.list detail limit)
local REC_REFRESH_MS = 2000  -- status redraw period while recording (e-ink: keep it slow)

local W, H = 0, 0

local st = {
  chan = 1,          -- channel for the next new session (left/right on the list)
  sel = 1,           -- list cursor: 1 = "New capture", 2.. = sessions
  rows = {},         -- { {name, n, size}, ... } newest first
  free = nil,        -- SD free bytes (fs.volume), or nil
  confirm_del = nil, -- session name waiting for a second confirm
  status = "",
  recording = false, file = nil, rec_chan = 1, started = 0, last = nil,
}

-- ---------- helpers ----------
local function human(n)
  n = n or 0
  if n < 1024 then return n .. " B" end
  if n < 1024 * 1024 then return string.format("%.1f KB", n / 1024) end
  return string.format("%.1f MB", n / (1024 * 1024))
end

local function header(title)
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, title, "ui12", "bw")
end

local function footer(text)
  gfx.text(14, H - 34, text, "small")
end

-- ---------- data ----------
-- Re-read data: and keep only session_NNN.pcap files (sorted newest first).
local function refresh()
  local items = fs.list("data:", { detail = true, limit = MAX_LIST }) or {}
  local rows = {}
  for _, e in ipairs(items) do
    local digits = (not e.dir) and e.name:match("^session_(%d+)%.pcap$")
    if digits then
      rows[#rows + 1] = { name = e.name, n = tonumber(digits), size = e.size or 0 }
    end
  end
  table.sort(rows, function(a, b) return a.n > b.n end)
  st.rows = rows
  local v = fs.volume()
  st.free = v and v.free or nil
  if st.sel > #rows + 1 then st.sel = #rows + 1 end
  if st.sel < 1 then st.sel = 1 end
end

-- Next name: one above the highest number, skipping any that already exist.
local function next_name()
  local n = (st.rows[1] and st.rows[1].n or 0) + 1
  local name
  repeat
    name = string.format("data:session_%03d.pcap", n)
    n = n + 1
  until not fs.exists(name)
  return name
end

-- ---------- recording ----------
local function stop_session()
  local info = wifi.monitor_info()
  local bytes = wifi.monitor_stop() or 0
  st.recording = false
  local frames = info and info.captured or 0
  st.last = { frames = frames, dropped = info and info.dropped or 0 }
  st.status = string.format("Saved %s: %d frames, %s", st.file:sub(6), frames, human(bytes))
  st.file = nil
  refresh()
end

local function start_session()
  local name = next_name()
  local ok, err = wifi.monitor_start({ channel = st.chan, file = name })
  if not ok then
    st.status = "Start failed: " .. tostring(err)
    return
  end
  st.recording = true
  st.file = name
  st.rec_chan = st.chan
  st.started = system.millis()
  st.status = ""
end

local function draw_rec()
  gfx.clear()
  W, H = gfx.size()
  header("REC  " .. st.file:sub(6))
  local info = wifi.monitor_info() or {}
  local secs = math.floor((system.millis() - st.started) / 1000)
  local y = 56
  local function line(s, font)
    gfx.text(16, y, s, font or "ui12")
    y = y + LH + 8
  end
  line(string.format("Channel     %d  (left/right to hop)", st.rec_chan))
  line(string.format("Frames      %d", info.captured or 0))
  line(string.format("Dropped     %d", info.dropped or 0))
  line("On card     " .. human(info.bytes or 0))
  line(string.format("Elapsed     %02d:%02d", secs // 60, secs % 60))
  footer("confirm = stop+save   back = stop+save+list")
end

-- Runs until the user stops; drains the frame ring so the radio never backs up.
local function record()
  draw_rec(); gfx.present()
  local last_draw = system.millis()
  while st.recording do
    while wifi.monitor_recv() do end
    local now = system.millis()
    if now - last_draw >= REC_REFRESH_MS then
      draw_rec(); gfx.present()
      last_draw = now
    end
    local e = input.poll()
    if e == "left" or e == "right" then
      local d = (e == "right") and 1 or -1
      st.rec_chan = ((st.rec_chan - 1 + d) % MAX_CH) + 1
      wifi.monitor_channel(st.rec_chan)
      draw_rec(); gfx.present()
      last_draw = system.millis()
    elseif e == "confirm" then
      stop_session()
    elseif e == "back" then
      stop_session()
    end
    app.sleep(40)
  end
end

-- ---------- list screen ----------
local function draw_list()
  gfx.clear()
  W, H = gfx.size()
  header("Capture Sessions")
  local visible = math.max(1, (H - 52 - 120) // ROW_H)
  local total = #st.rows + 1
  local top = 1
  if st.sel > visible then top = st.sel - visible + 1 end

  local y = 52
  for i = top, math.min(total, top + visible - 1) do
    local label
    if i == 1 then
      label = string.format("+ New capture  (ch %d)", st.chan)
    else
      local r = st.rows[i - 1]
      label = string.format("%s  %s", r.name, human(r.size))
    end
    if i == st.sel then
      gfx.rect(10, y - 4, W - 20, ROW_H - 4, true)
      gfx.text(18, y, label, "ui12", "w")
    else
      gfx.text(18, y, label, "ui12")
    end
    y = y + ROW_H
  end
  if #st.rows == 0 then
    gfx.text(18, y + 8, "No sessions yet.", "small")
  end

  local bottom = H - 120
  if st.confirm_del then
    gfx.text(16, bottom, "Delete " .. st.confirm_del .. "?  confirm = yes, back = no", "small")
  elseif st.status ~= "" then
    gfx.text(16, bottom, st.status:sub(1, 60), "small")
  end
  local free = st.free and string.format("SD free %s", human(st.free)) or "SD free ?"
  footer(string.format("%d session(s)   %s", #st.rows, free))
end

local function handle_list(e)
  local total = #st.rows + 1
  if e == "up" then
    st.sel = st.sel > 1 and st.sel - 1 or total
    st.confirm_del = nil
  elseif e == "down" then
    st.sel = st.sel < total and st.sel + 1 or 1
    st.confirm_del = nil
  elseif e == "left" or e == "right" then
    local d = (e == "right") and 1 or -1
    st.chan = ((st.chan - 1 + d) % MAX_CH) + 1
    st.status = ""
  elseif e == "confirm" then
    if st.sel == 1 then
      st.confirm_del = nil
      start_session()
    else
      local r = st.rows[st.sel - 1]
      if st.confirm_del == r.name then
        local ok, err = fs.remove("data:" .. r.name)
        st.status = ok and ("Deleted " .. r.name) or ("Delete failed: " .. tostring(err))
        st.confirm_del = nil
        refresh()
      else
        st.confirm_del = r.name
      end
    end
  elseif e == "back" then
    if st.confirm_del then
      st.confirm_del = nil
      st.status = "Delete cancelled"
    else
      return true   -- leave the app
    end
  end
  return false
end

-- ---------- main ----------
local function main()
  refresh()
  while true do
    gfx.clear(); draw_list(); gfx.present()
    local e = input.wait()
    if handle_list(e) then return end
    if st.recording then
      record()
      refresh()
    end
  end
end

local ok, err = pcall(main)
if not ok then
  pcall(function() if st.recording then wifi.monitor_stop() end end)
  gfx.clear()
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b")
  gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
