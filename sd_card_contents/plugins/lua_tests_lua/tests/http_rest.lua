-- hub test: the body is wrapped so an early `return` or an error still goes back to the menu (app.restart("main.lua")).
-- http.request for REST/JSON: methods, content_type, headers on POST, ca pinning, response_headers. Needs the host echo server:
--   python3 tools/http_test_server.py --ip <host ip> --dir /root/x4/tlsdemo      (https :8444, http :8081)
-- and app:tls_target.txt (the host's IP), app:tls_ca.pem, app:tls_wrongca.pem on the card (same files as the tls test).
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
  print(("HEAP %-24s free=%d min=%d largest=%d"):format(tag, f, m, l))
end

if not fs.exists("app:tls_target.txt") or not fs.exists("app:tls_ca.pem") then
  print("SKIP: no app:tls_target.txt / app:tls_ca.pem on the card (see the header of this file)")
  return
end
local host = (fs.read("app:tls_target.txt") or ""):gsub("%s+", "")
local S = "https://" .. host .. ":8444"
local P = "http://" .. host .. ":8081"
heap("after wifi")

local function echo(r) return r and r.body and json.decode(r.body) or nil end

print("== JSON POST over https, pinned CA, Authorization header, response headers")
local r, err = http.request{url = S .. "/api/services/light/turn_on", method = "POST", ca = "app:tls_ca.pem",
  headers = {Authorization = "Bearer token123", Accept = "application/json"},
  body = json.encode({entity_id = "light.kitchen"}), content_type = "application/json", response_headers = true}
check("request returns", r ~= nil, err)
heap("after https post")
local e = echo(r)
check("status 200", r and r.status == 200, r and r.status)
check("server saw POST", e and e.method == "POST", e and e.method)
check("server saw the JSON body", e and json.decode(e.body).entity_id == "light.kitchen", e and e.body)
check("content type is application/json", e and e.headers["content-type"] == "application/json", e and e.headers["content-type"])
check("Authorization header reached the server on a POST", e and e.headers["authorization"] == "Bearer token123",
  e and tostring(e.headers["authorization"]))
check("response header x-echo", r and r.headers and r.headers["x-echo"] == "1", r and r.headers and tostring(r.headers["x-echo"]))
check("repeated Set-Cookie joined", r and r.headers and r.headers["set-cookie"] == "a=1, b=2", r and r.headers and tostring(r.headers["set-cookie"]))
check("no headers table unless asked", (http.request{url = P .. "/x"} or {}).headers == nil)

print("== wrong CA is refused")
local rw, ew = http.request{url = S .. "/", ca = "app:tls_wrongca.pem"}
check("wrong ca -> nil, err", rw == nil and ew ~= nil, tostring(ew))
heap("after wrong ca")

-- drop everything held so far: what is measured below is the requests, not this test's own variables
r, e, rw, ew = nil, nil, nil, nil
collectgarbage()
heap("after releasing results")

print("== default (unpinned) https still works, and repeating it does not drift")
local first, last, okAll = nil, nil, true
for i = 1, 5 do
  local ri, ei = http.request{url = S .. "/default"}
  okAll = okAll and ri ~= nil and ri.status == 200
  if not (ri and ri.status == 200) then print("  request " .. i .. " failed: " .. tostring(ei)) end
  ri = nil
  collectgarbage()
  local f = system.heap()
  first = first or f
  last = f
  print(("  after request %d: free=%d"):format(i, f))
end
check("5 unpinned https GETs succeed", okAll)
check("free heap does not leak per request (drift <= 1500 bytes over 5)", first and last and first - last <= 1500, first and last and (first - last))

print("== methods over plain http")
for _, m in ipairs{"PUT", "PATCH"} do
  local rm, em = http.request{url = P .. "/m", method = m, body = '{"a":1}', content_type = "application/json"}
  local x = echo(rm)
  check(m .. " with a JSON body", x and x.method == m and x.body == '{"a":1}' and x.headers["content-type"] == "application/json", em or (x and x.method))
end
local rd = echo(http.request{url = P .. "/gone", method = "DELETE", headers = {["X-Custom"] = "yes"}})
check("DELETE with a custom header", rd and rd.method == "DELETE" and rd.headers["x-custom"] == "yes", rd and rd.method)
local rf = echo(http.request{url = P .. "/form", method = "POST", body = "a=1&b=2"})
check("POST body defaults to form-urlencoded", rf and rf.headers["content-type"] == "application/x-www-form-urlencoded", rf and rf.headers["content-type"])
local rg = echo(http.request{url = P .. "/plain", headers = {Accept = "text/plain"}})
check("plain GET keeps working", rg and rg.method == "GET" and rg.headers["accept"] == "text/plain", rg and rg.method)
local rh = http.request{url = P .. "/hdr", response_headers = true}
check("response_headers on plain http", rh and rh.headers and rh.headers["set-cookie"] == "a=1, b=2")

print("== argument errors")
local _, e1 = http.request{url = P .. "/", method = "POST", body = "x", headers = {["Content-Type"] = "text/plain"}}
check("Content-Type header with a body refused", e1 == "set content_type instead of a Content-Type header", e1)
local _, e2 = http.request{url = P .. "/", ca = "app:tls_ca.pem"}
check("ca on plain http refused", e2 == "ca only applies to https:// urls", e2)

heap("end")
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
gfx.clear()
gfx.text(16, 10, "http rest test", "ui12", "b")
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
