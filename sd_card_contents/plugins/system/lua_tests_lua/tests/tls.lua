-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
-- TLS client sockets. Needs a TLS echo server on :8443 that answers "TLS_PONG <line>" and three files next to this
-- plugin: app:tls_target.txt (the host's IP), app:tls_ca.pem (the CA that signed the server) and app:tls_wrongca.pem
-- (an unrelated CA). Without them the LAN part is skipped and only the argument checks and the internet insecure check
-- run. Heap is printed at every stage: it is the point of this test.
local function __test()
print("== wifi")
local ok, why = wifi.connect()
print((ok and "PASS " or "FAIL ") .. "wifi.connect " .. tostring(why or ""))
if not ok then return end

local fails = 0
local function check(name, cond, extra)
  if not cond then fails = fails + 1 end
  print((cond and "PASS " or "FAIL ") .. name .. (extra and (" " .. tostring(extra)) or ""))
end
local function heap(tag)
  local f, m, l = system.heap()
  print(("HEAP %-22s free=%d min=%d largest=%d"):format(tag, f, m, l))
end
local function now() return system.millis() end

-- send one line over a TLS socket and read the reply line (or nil, err)
local function exchange(h, line, waitMs)
  local w, werr = net.write(h, line)
  if not w then return nil, "write: " .. tostring(werr) end
  local got, t0 = "", now()
  while now() - t0 < waitMs do
    local chunk, rerr = net.read(h, 256)
    if chunk == nil then return #got > 0 and got or nil, rerr end
    if #chunk > 0 then got = got .. chunk end
    if got:find("\n", 1, true) then return got end
    if #chunk == 0 then app.sleep(20) end
  end
  return #got > 0 and got or nil, "timeout"
end

heap("after wifi")
print("== argument rules (no network)")
local _, e1 = net.connect("example.com", 443, {tls = true})
check("tls without ca/insecure refused", e1 and e1:find("tls needs ca=") ~= nil, e1)
local _, e2 = net.connect("example.com", 443, {insecure = true})
check("insecure without tls refused", e2 == "ca and insecure only apply with tls=true", e2)
local _, e3 = net.connect("example.com", 443, {tls = true, insecure = true, ca = "app:tls_ca.pem"})
check("ca + insecure refused", e3 == "pass either ca or insecure, not both", e3)

local target
if fs.exists("app:tls_target.txt") then target = (fs.read("app:tls_target.txt") or ""):gsub("%s+", "") end
if target and target ~= "" and fs.exists("app:tls_ca.pem") then
  print("== LAN server " .. target .. ":8443 (verified with the pinned CA)")
  heap("before verified connect")
  local t0 = now()
  local h, err = net.connect(target, 8443, {tls = true, ca = "app:tls_ca.pem", timeout_ms = 15000})
  local ms = now() - t0
  check("verified tls connect", h ~= nil, tostring(h or err) .. " (" .. ms .. " ms)")
  if h then
    heap("tls session open")
    local reply, rerr = exchange(h, "hello-x4\n", 5000)
    check("encrypted round trip", reply == "TLS_PONG hello-x4\n", ("%q %s"):format(tostring(reply), tostring(rerr)))
    local h2, e4 = net.connect(target, 8443, {tls = true, insecure = true})
    check("second tls socket refused", h2 == nil and e4 and e4:find("only one TLS socket") ~= nil, tostring(h2 or e4))
    check("net.close on the tls socket", net.close(h) == true)
    heap("tls session closed")
  end

  if fs.exists("app:tls_wrongca.pem") then
    local hw, ew = net.connect(target, 8443, {tls = true, ca = "app:tls_wrongca.pem", timeout_ms = 15000})
    check("wrong CA is REFUSED (no connection)", hw == nil, tostring(hw or ew))
    if hw then net.close(hw) end
    heap("after wrong-ca attempt")
  end

  local hi, ei = net.connect(target, 8443, {tls = true, insecure = true, timeout_ms = 15000})
  check("insecure tls connect (reopen after close)", hi ~= nil, tostring(hi or ei))
  if hi then
    local reply = exchange(hi, "again\n", 5000)
    check("insecure round trip", reply == "TLS_PONG again\n", ("%q"):format(tostring(reply)))
    net.close(hi)
  end
else
  print("SKIP LAN part: no app:tls_target.txt / app:tls_ca.pem on the card")
end

print("== internet (insecure: encrypted, unauthenticated)")
heap("before internet")
local hx, ex = net.connect("example.com", 443, {tls = true, insecure = true, timeout_ms = 15000})
if hx then
  local reply = exchange(hx, "GET / HTTP/1.0\r\nHost: example.com\r\n\r\n", 8000)
  check("https GET over a raw tls socket", reply ~= nil and reply:find("^HTTP/1%.") ~= nil, tostring(reply and reply:sub(1, 20)))
  net.close(hx)
else
  print("INFO internet tls connect failed: " .. tostring(ex) .. " (not a failure: the LAN may have no internet)")
end
heap("end")

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "tls test", "ui12", "b")
gfx.text(16, 60, fails == 0 and "ALL PASSED" or (fails .. " FAILED"), "ui12")
gfx.text(16, 100, "see the serial log for details", "small")
gfx.present("full")
app.sleep(1500)
end
local __ok, __err = pcall(__test)
if not __ok then
  print("[hub] ERROR: " .. tostring(__err))
  gfx.clear(); gfx.text(10, 10, "Test error (see serial log)", "ui12", "b"); gfx.text(10, 50, tostring(__err):sub(1, 48), "small"); gfx.present()
  while input.wait() ~= "back" do end
end
-- the radio was used: reboot back to the hub (frees the ~57 KB WiFi allocation)
app.exit()
