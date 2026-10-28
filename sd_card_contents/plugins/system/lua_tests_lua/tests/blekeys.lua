-- hub test (interactive, needs a BLE keyboard): pick a keyboard, pair, then type into a notes pad.
--   Up/Down + Confirm pick a keyboard; Back quits. Once connected, whatever you type on the keyboard shows on screen.
--   Enter = new line, Backspace deletes, Esc quits, Ctrl+S saves to data:notes.txt (read back and verified).
-- Pairing: a keyboard that shows no number may ask for a PASSKEY: this screen shows it, type it on the keyboard, then Enter.
-- Put the keyboard in PAIRING mode first (its Bluetooth button, usually held a few seconds). Only HID devices are listed.
local function __test()
print("== blekeys")
local W, H = gfx.size()
local fails = 0
local function say(t1, t2, t3)
  gfx.clear()
  gfx.text(16, 10, "BLE keyboard", "ui12", "b")
  if t1 then gfx.text(16, 60, t1, "ui12") end
  if t2 then gfx.text(16, 100, t2, "ui12") end
  if t3 then gfx.text(16, 140, t3, "small") end
  gfx.present()
end

local ok, e = ble.start()
if not ok then say("cannot start bluetooth", tostring(e)); print("FAIL start: " .. tostring(e)); app.sleep(3000); app.exit(); return end
print("PASS start")

-- pick a keyboard: bonded ones first, then the scan
local picked
while not picked do
  ble.scan(6000)
  local t0 = system.millis()
  local list, sel = {}, 1
  while true do
    list = {}
    for _, p in ipairs(ble.paired()) do list[#list + 1] = {addr = p.addr, name = p.name .. " (paired)"} end
    for _, d in ipairs(ble.devices()) do
      local dup = false
      for _, x in ipairs(list) do if x.addr == d.addr then dup = true end end
      if not dup and d.hid then list[#list + 1] = {addr = d.addr, name = d.name .. "  " .. d.rssi .. " dBm"} end
    end
    gfx.clear()
    gfx.text(16, 10, "Pick a keyboard", "ui12", "b")
    gfx.text(16, 44, ble.state().scanning and "scanning..." or "scan done: Left = scan again", "small")
    if #list == 0 then gfx.text(16, 90, "none yet (pairing mode on?)", "ui12") end
    for i, x in ipairs(list) do
      gfx.text(16, 80 + (i - 1) * 40, (i == sel and "> " or "  ") .. x.name, "ui12")
    end
    gfx.present()
    local ev = input.wait(1500)
    if ev == "back" then ble.stop(); app.exit(); return end
    if ev == "up" and sel > 1 then sel = sel - 1 end
    if ev == "down" and sel < #list then sel = sel + 1 end
    if ev == "left" then break end
    if ev == "confirm" and list[sel] then picked = list[sel]; break end
  end
end

say("connecting to", picked.name)
ok, e = ble.connect(picked.addr)
if not ok then say("connect failed", tostring(e)); print("FAIL connect: " .. tostring(e)); app.sleep(3000); ble.stop(); app.exit(); return end
local t0 = system.millis()
local shownKey
while true do
  local s = ble.state()
  if s.link == "connected" then break end
  if s.link == "failed" then say("failed", s.reason or "?"); print("FAIL link: " .. tostring(s.reason)); app.sleep(3000); ble.stop(); app.exit(); return end
  if s.passkey and s.passkey ~= shownKey then
    shownKey = s.passkey
    say("type this on the keyboard:", string.format("%06d", s.passkey), "then press Enter on it")
  elseif not s.passkey and not shownKey then
    say("connecting to", picked.name, string.format("%d s", (system.millis() - t0) // 1000))
  end
  if system.millis() - t0 > 45000 then say("timed out"); print("FAIL connect timed out"); app.sleep(3000); ble.stop(); app.exit(); return end
  local ev = input.wait(500)
  if ev == "back" then ble.stop(); app.exit(); return end
end
print("PASS connected to " .. ble.state().name)

-- the notes pad
local text, typed, last = "", 0, "-"
local function draw()
  gfx.clear()
  gfx.text(16, 6, "Notes (Ctrl+S save, Esc quit)", "small")
  local y, line = 36, ""
  local function flush() gfx.text(16, y, line, "ui12"); y = y + 34; line = "" end
  for i = 1, #text do
    local c = text:sub(i, i)
    if c == "\n" then flush()
    else
      if gfx.text_width(line .. c, "ui12") > W - 32 then flush() end
      line = line .. c
    end
  end
  gfx.text(16, y, line .. "_", "ui12")
  gfx.text(16, H - 24, "last key: " .. last .. "   typed: " .. typed, "small")
  gfx.present()
end
draw()
local running = true
while running do
  local ev = input.wait(2000)
  local dirty = false
  while ev do
    if ev == "key" then
      local k = input.key()
      if k then
        typed = typed + 1
        last = (k.char or k.key or "?") .. (k.ctrl and "+ctrl" or "") .. (k.shift and "+shift" or "")
        if k.ctrl and k.char == "s" then
          local f = "data:notes.txt"
          local w, we = fs.write(f, text)
          local back = w and fs.read(f)
          local good = back == text
          print((good and "PASS " or "FAIL ") .. "ctrl+s saved " .. #text .. " bytes and read them back", we)
          if not good then fails = fails + 1 end
          last = good and "saved" or "SAVE FAILED"
        elseif k.key == "escape" then running = false
        elseif k.key == "backspace" then text = text:sub(1, #text - 1)
        elseif k.key == "enter" then text = text .. "\n"
        elseif k.key == "tab" then text = text .. "  "
        elseif k.char and not k.ctrl then text = text .. k.char end
        dirty = true
      end
    elseif ev == "back" then running = false end
    ev = input.poll()
  end
  if ble.state().link ~= "connected" then last = "link lost" end
  if dirty then draw() end
end
print("INFO typed " .. typed .. " key events, text length " .. #text)
print(fails == 0 and (typed > 0 and "ALL PASSED" or "NO KEYS TYPED") or ("FAILED: " .. fails))
ble.stop()
gfx.clear(); gfx.text(16, 10, "blekeys", "ui12", "b"); gfx.text(16, 70, typed .. " keys typed", "ui12"); gfx.present("full")
app.sleep(1500)
app.exit()
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
