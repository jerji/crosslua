-- KOReader sync: push this reader's saved progress to a kosync server and read
-- back the server's copy. Speaks the same protocol as the firmware's own
-- KOReader client: x-auth-user / x-auth-key (= md5 of the password), the
-- partial-MD5 document id, GET/PUT /syncs/progress.
-- Push + fetch only: there is no binding to write a position back into the
-- firmware yet, so a remote position is shown, never applied.

local W, H = gfx.size()
local CFG = "data:kosync.txt"   -- line 1: server URL, line 2: username
local PW = "data:kosync.pw"     -- 12-byte nonce .. AES-GCM sealed password
local CA = "app:ca.pem"         -- optional: pins an https server's certificate
local DEV, DEV_ID = "CrossLua", "crosslua-reader"
local TITLE_H, ROW_H, MAX_ROWS = 44, 62, 10

local books, cur, msg = {}, 1, nil
local cfg = nil        -- {url, user}
local secret = nil     -- password, decrypted for this session only

local function clip(s, px, font)
  if gfx.text_width(s, font) <= px then return s end
  while #s > 0 and gfx.text_width(s .. "...", font) > px do
    local p = utf8.offset(s, -1)
    if not p then break end
    s = s:sub(1, p - 1)
  end
  return s .. "..."
end

local function load_cfg()
  local s = fs.read(CFG)
  if not s then return nil end
  local url, user = s:match("^([^\n]*)\n?([^\n]*)")
  if not url or url == "" then return nil end
  return { url = url, user = user or "" }
end

local function save_cfg(url, user, pw)
  local key = crypto.device_key("kosync-pw")
  if not key then return nil, "no device key" end
  local nonce = crypto.random(12)
  local sealed, err = crypto.aes_gcm_encrypt(key, nonce, pw)
  if not sealed then return nil, err or "encrypt failed" end
  local ok, e = fs.write(PW, nonce .. sealed)
  if not ok then return nil, e end
  return fs.write(CFG, url .. "\n" .. user)
end

-- The password only comes back on this device, for this app; tampering -> nil.
local function load_secret()
  if secret then return secret end
  local blob = fs.read(PW)
  local key = crypto.device_key("kosync-pw")
  if not blob or #blob < 12 + 16 or not key then return nil end
  secret = crypto.aes_gcm_decrypt(key, blob:sub(1, 12), blob:sub(13))
  return secret
end

-- KOReader partial-MD5 document id: 1024 bytes at offsets 0, 1024<<(2i) for i=0..10.
local function doc_id(path)
  local size, err = fs.size(path)
  if not size then return nil, err or "cannot read book" end
  local h = crypto.hash("md5")
  for i = -1, 10 do
    local off = (i < 0) and 0 or (1024 << (2 * i))
    if off < size then
      local chunk = fs.read(path, off, 1024)
      if not chunk then return nil, "read failed" end
      h:update(chunk)
    end
  end
  return crypto.hex(h:digest())
end

local function is_https() return cfg.url:sub(1, 8) == "https://" end

-- One request to the sync server. Returns the http result, or nil, err.
local function api(method, path, body)
  local pw = load_secret()
  if not cfg or not pw then return nil, "not set up (press Right)" end
  local opts = {
    url = cfg.url:gsub("/+$", "") .. path,
    method = method,
    headers = {
      Accept = "application/vnd.koreader.v1+json",
      ["x-auth-user"] = cfg.user,
      ["x-auth-key"] = crypto.hex(crypto.md5(pw)),
    },
    max_body = 2048,
  }
  if body then
    opts.body = body
    opts.content_type = "application/json"
  end
  if is_https() then
    -- Never send credentials to an unpinned https server (the API refuses it too).
    if not fs.exists(CA) then return nil, "https needs app:ca.pem to pin the server" end
    opts.ca = CA
  end
  return http.request(opts)
end

-- Bring the radio up with the right TLS mode, then run fn().
local function on_network(fn)
  local ok, why
  if is_https() then ok, why = wifi.connect() else ok, why = wifi.connect({ tls = false }) end
  if not ok then return nil, why or "wifi failed" end
  return fn()
end

local function busy(text)
  gfx.clear()
  gfx.text(14, 14, text, "sans18", "b")
  gfx.present()
end

local function draw()
  gfx.clear()
  gfx.rect(0, 0, W, TITLE_H, true)
  gfx.text(14, 12, "KOReader sync", "ui12", "bw")
  if cfg then
    gfx.text(W - 14, 12, clip(cfg.url, 200, "ui12"), "ui12", "bwr")
  end
  if not cfg then
    gfx.text(16, 90, "Not set up yet.", "sans16", "b")
    gfx.text(16, 124, "Press Right to enter the server,", "ui12")
    gfx.text(16, 144, "username and password.", "ui12")
  elseif #books == 0 then
    gfx.text(16, 90, "No books on the shelf yet.", "sans16", "b")
    gfx.text(16, 124, "Open a book in the reader first.", "ui12")
  end

  local y = TITLE_H + 12
  for i, b in ipairs(books) do
    if i > MAX_ROWS then break end
    local sel = (i == cur)
    if sel then gfx.rect(8, y, W - 16, ROW_H - 6, true) end
    local fl, sub = sel and "bw" or "b", sel and "w" or ""
    gfx.text(20, y + 6, clip(b.title, W - 48, "sans16"), "sans16", fl)
    local local_s = b.pct and (b.pct .. "%") or "none"
    local remote_s = b.remote and (string.format("%d%%", b.remote) .. (b.remote_dev and (" on " .. b.remote_dev) or ""))
      or "not checked"
    gfx.text(20, y + 34, clip("here " .. local_s .. "   server " .. remote_s, W - 48, "ui12"), "ui12", sub)
    y = y + ROW_H
  end

  if msg then gfx.text(14, H - 64, clip(msg, W - 28, "ui12"), "ui12", "b") end
  gfx.text(14, H - 30, "Confirm: push  Left: fetch  Right: setup  Back: exit", "ui12")
  gfx.present()
end

-- Pull the book list once; percent comes from the firmware's own progress file.
local function load_shelf()
  local ok, list = pcall(epub.recent)
  if not ok or type(list) ~= "table" then list = {} end
  for i = 1, math.min(#list, MAX_ROWS) do
    local b = list[i]
    local pct = nil
    local ok2, p = pcall(epub.progress, b.path)
    if ok2 and type(p) == "number" then pct = math.floor(p) end
    books[#books + 1] = {
      path = b.path,
      title = (b.title ~= "" and b.title) or "(untitled)",
      pct = pct,
    }
  end
end

local function setup()
  local url = input.text("Server URL (http:// or https://)", cfg and cfg.url or "http://", 200)
  if not url or url == "" then msg = "Setup cancelled"; return end
  if not url:match("^https?://%S+$") then msg = "URL must start with http:// or https://"; return end
  local user = input.text("KOReader username", cfg and cfg.user or "", 64)
  if not user or user == "" then msg = "Setup cancelled"; return end
  local pw = input.text("KOReader password", "", 128, "password")
  if not pw or pw == "" then msg = "Setup cancelled"; return end
  url = url:gsub("/+$", "")
  local ok, err = save_cfg(url, user, pw)
  if not ok then msg = "Save failed: " .. tostring(err); return end
  cfg = { url = url, user = user }
  secret = nil
  busy("Checking login...")
  local res, why = on_network(function() return api("GET", "/users/auth") end)
  if not res then msg = "Login check: " .. tostring(why)
  elseif res.status == 200 then msg = "Logged in. Saved."
  elseif res.status == 401 then msg = "Saved, but the server rejected the login."
  else msg = "Saved. Login check returned " .. tostring(res.status) end
  if not is_https() then msg = msg .. " (http: password is sent in clear)" end
end

local function push(b)
  if not cfg then msg = "Not set up (press Right)"; return end
  if not b.pct then msg = "No local progress for this book"; return end
  busy("Uploading...")
  local doc, derr = doc_id(b.path)
  if not doc then msg = "Could not hash book: " .. tostring(derr); return end
  local body = json.encode({
    document = doc, progress = "", percentage = b.pct / 100,
    device = DEV, device_id = DEV_ID,
  })
  local res, why = on_network(function() return api("PUT", "/syncs/progress", body) end)
  if not res then msg = "Push failed: " .. tostring(why)
  elseif res.ok then msg = "Pushed " .. b.pct .. "% for " .. clip(b.title, 180, "ui12")
  elseif res.status == 401 then msg = "Push refused: wrong login"
  else msg = "Push failed: server " .. tostring(res.status) end
end

local function fetch(b)
  if not cfg then msg = "Not set up (press Right)"; return end
  busy("Checking server...")
  local doc, derr = doc_id(b.path)
  if not doc then msg = "Could not hash book: " .. tostring(derr); return end
  local res, why = on_network(function()
    return api("GET", "/syncs/progress/" .. doc .. "?position_kinds=locator,percentage")
  end)
  if not res then msg = "Fetch failed: " .. tostring(why); return end
  if res.status == 204 or res.status == 404 then
    b.remote, b.remote_dev = nil, nil
    msg = "No server progress for this book"
  elseif res.ok then
    local t = json.decode(res.body or "")
    if type(t) == "table" and type(t.percentage) == "number" then
      b.remote = math.floor(t.percentage * 100 + 0.5)
      b.remote_dev = type(t.device) == "string" and t.device or nil
      msg = "Server has " .. b.remote .. "% (display only; not applied)"
    else
      msg = "Server reply had no percentage"
    end
  elseif res.status == 401 then msg = "Fetch refused: wrong login"
  else msg = "Fetch failed: server " .. tostring(res.status) end
end

local function __main()
  cfg = load_cfg()
  load_shelf()
  draw()
  while true do
    local e = input.wait()
    if e == "back" then break
    elseif e == "up" and #books > 0 then cur = (cur > 1) and (cur - 1) or #books; msg = nil
    elseif e == "down" and #books > 0 then cur = (cur < #books) and (cur + 1) or 1; msg = nil
    elseif e == "confirm" and #books > 0 then push(books[cur])
    elseif e == "left" and #books > 0 then fetch(books[cur])
    elseif e == "right" then setup()
    end
    draw()
  end
  app.exit()
end

local ok, err = pcall(__main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
  app.exit()
end
