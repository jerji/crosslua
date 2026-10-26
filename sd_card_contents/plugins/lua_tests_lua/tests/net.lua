-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
local function __test()
-- Network diagnostics: connects, fetches over HTTP and HTTPS, downloads a file, and reports free RAM + the largest
-- free block at every step (also printed to the serial log). Confirm = run, Back = quit.
local W, H = gfx.size()
local lines = {}
local FONT = "small"
local LH = gfx.line_height(FONT) + 2
local MAXL = (H - 100) // LH

local function draw(hint)
  gfx.clear()
  gfx.text(16, 10, "Net test", "ui12", "b")
  gfx.line(0, 44, W, 44)
  local first = math.max(1, #lines - MAXL + 1)
  for i = first, #lines do gfx.text(12, 52 + (i - first) * LH, lines[i], FONT) end
  gfx.text(W // 2, H - 34, hint or "Confirm: run   Back: quit", FONT, "c")
  gfx.present("fast")
end

local function log(s)
  lines[#lines + 1] = s
  print(s)
  draw("working...")
end

local function mem(tag)
  collectgarbage()
  local free, minfree, big = system.heap()
  local used = system.lua_mem()
  log(("%s: free %dK min %dK big %dK lua %dK"):format(tag, free // 1024, minfree // 1024, big // 1024, used // 1024))
end

local function show(r, err)
  if not r then log("  FAIL: " .. tostring(err)); return false end
  log(("  status %d bytes %d %s"):format(r.status, r.bytes, r.body and ("body[1..40]=" .. r.body:sub(1, 40):gsub("%s+", " ")) or "(saved)"))
  return true
end

local function run()
  lines = {}
  mem("start")
  log("wifi.connect...")
  local ok, why = wifi.connect()
  draw("working...")
  if not ok then log("NOT CONNECTED: " .. tostring(why)); return end
  local st = wifi.status()
  log(("connected %s %s %ddBm"):format(st.ssid or "?", st.ip or "?", st.rssi or 0))
  mem("wifi up")

  log("GET http://example.com/")
  local t0 = system.millis()
  show(http.get("http://example.com/"))
  log(("  %d ms"):format(system.millis() - t0))
  mem("after http")

  log("GET https://example.com/")
  t0 = system.millis()
  show(http.get("https://example.com/"))
  log(("  %d ms"):format(system.millis() - t0))
  mem("after https")

  log("save https://www.gutenberg.org/ ... pg11.txt")
  t0 = system.millis()
  local r, err = http.get("https://www.gutenberg.org/cache/epub/11/pg11.txt", { save_to = "data:alice.txt" })
  show(r, err)
  log(("  %d ms, file %s bytes"):format(system.millis() - t0, tostring(fs.size("data:alice.txt"))))
  mem("after download")
  log("done. leaving the app reboots")
  log("the radio cleanly.")
end

-- Right: start a 3 MB download and press Back to cancel it (the transfer must stop and the app must carry on).
local function cancel_test()
  lines = {}
  mem("cancel test start")
  local ok, why = wifi.connect()
  if not ok then log("NOT CONNECTED: " .. tostring(why)); return end
  draw("working...")
  log("downloading 3 MB: press BACK now")
  local t0 = system.millis()
  local r, err = http.get("https://www.gutenberg.org/cache/epub/2600/pg2600.txt", { save_to = "data:big.txt" })
  log(("returned after %d ms:"):format(system.millis() - t0))
  if r then log(("  finished: status %d, %d bytes (not cancelled)"):format(r.status, r.bytes))
  else log("  nil, " .. tostring(err)) end
  log("big.txt exists after cancel: " .. tostring(fs.exists("data:big.txt")))
  log("part file left: " .. tostring(fs.exists("data:big.txt.part")))
  mem("after cancel")
  log("app is still alive.")
end

-- Left: can the X4 talk to AO3 (Cloudflare) at all? Fetch a real EPUB, retrying on 5xx like a real client must.
local function ao3_test()
  lines = {}
  mem("ao3 test start")
  local ok, why = wifi.connect()
  if not ok then log("NOT CONNECTED: " .. tostring(why)); return end
  draw("working...")
  local url = "https://archiveofourown.org/downloads/5000/Talk_About_the_Weather.epub?updated_at=1568019238"
  for try = 1, 5 do
    log("GET epub, try " .. try)
    local t0 = system.millis()
    local r, err = http.get(url, { save_to = "data:ao3.epub" })
    local dt = system.millis() - t0
    if not r then
      log(("  FAIL %s (%d ms)"):format(tostring(err), dt))
    else
      log(("  status %d, %d bytes (%d ms)"):format(r.status, r.bytes, dt))
      if r.status == 200 then break end
    end
    app.sleep(3000)
  end
  log("saved size: " .. tostring(fs.size("data:ao3.epub")))
  local head = fs.read("data:ao3.epub", 0, 4)
  log("starts with PK (zip): " .. tostring(head == "PK\3\4"))
  mem("ao3 test end")
end

draw("Confirm: run  Right: cancel  Left: AO3  Back: quit")
while true do
  local ev = input.wait()
  if ev == "back" then return end
  if ev == "confirm" then run(); draw("Back: quit (silent reboot)") end
  if ev == "right" then cancel_test(); draw("Back: quit (silent reboot)") end
  if ev == "left" then ao3_test(); draw("Back: quit (silent reboot)") end
end
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
app.restart("main.lua")
