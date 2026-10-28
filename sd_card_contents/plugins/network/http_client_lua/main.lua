-- HTTP client: build a request (URL, method, headers, body), send it, read the response.
-- HTTPS is encrypted but the server certificate is NOT verified (firmware limit), so requests
-- carrying Authorization or Cookie headers are refused over https:// in this app.

local LH = 26
local MAX_HEADERS = 12
local MAX_BODY_CHARS = 256          -- input.text cap; the API allows 8 KB but typing is the limit here
local METHODS = { "GET", "POST", "PUT", "PATCH", "DELETE" }
local BODY_METHODS = { POST = true, PUT = true, PATCH = true }
local MAX_LINES = 300               -- wrapped response lines kept in RAM
local SECRET_HEADERS = { authorization = true, cookie = true, ["proxy-authorization"] = true }

local W, H = 0, 0

local function header(title)
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, title, "ui12", "bw")
end

local function footer(text)
  gfx.text(14, H - 34, text, "small")
end

local function screen(title, lines, hint)
  gfx.clear(); W, H = gfx.size(); header(title)
  local y = 52
  for _, l in ipairs(lines) do gfx.text(14, y, l, "ui12"); y = y + LH end
  footer(hint)
  gfx.present()
end

-- Vertical menu. Returns index on confirm, nil on back. `labels` is re-read each frame.
local menu_cur = 1   -- persists across menu() calls so actions don't reset the highlight
local function menu(title, labels_fn, hint)
  while true do
    local labels = labels_fn()
    if menu_cur > #labels then menu_cur = #labels end
    gfx.clear(); W, H = gfx.size(); header(title)
    local y = 60
    for i, label in ipairs(labels) do
      if i == menu_cur then
        gfx.rect(10, y - 4, W - 20, LH + 4, true)
        gfx.text(18, y, label, "ui12", "w")
      else
        gfx.text(18, y, label, "ui12")
      end
      y = y + LH + 6
    end
    footer(hint)
    gfx.present()
    local e = input.wait()
    if e == "up" then menu_cur = menu_cur > 1 and menu_cur - 1 or #labels
    elseif e == "down" then menu_cur = menu_cur < #labels and menu_cur + 1 or 1
    elseif e == "confirm" then return menu_cur
    elseif e == "back" then return nil end
  end
end

-- Greedy word wrap with measured pixel widths (ui12). Splits words wider than the line.
local function wrap(text, width)
  local out = {}
  local function push(s) if #out < MAX_LINES then out[#out + 1] = s end end
  for para in (text .. "\n"):gmatch("([^\n]*)\n") do
    para = para:gsub("\r", "")
    local line = ""
    for word in para:gmatch("%S+") do
      while gfx.text_width(word, "ui12") > width do
        local k = #word
        while k > 1 and gfx.text_width(word:sub(1, k), "ui12") > width do k = k - 1 end
        if line ~= "" then push(line); line = "" end
        push(word:sub(1, k))
        word = word:sub(k + 1)
      end
      local cand = line == "" and word or (line .. " " .. word)
      if gfx.text_width(cand, "ui12") <= width then
        line = cand
      else
        push(line)
        line = word
      end
    end
    push(line)
  end
  return out
end

local function printable(s)
  return (s:gsub("[^\32-\126\n]", "."))
end

local function show_response(res, err)
  if not res then
    screen("Response", { "request failed:", tostring(err) }, "back = edit request")
    while input.wait() ~= "back" do end
    return
  end
  local head = { ("HTTP %d  %s  (%d bytes)"):format(res.status or 0, res.ok and "ok" or "not ok", res.bytes or 0) }
  if res.headers then
    local names = {}
    for k in pairs(res.headers) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do
      head[#head + 1] = printable(k .. ": " .. tostring(res.headers[k])):sub(1, 60)
    end
  end
  head[#head + 1] = "----"
  local body = res.body or ""
  local lines = {}
  for _, l in ipairs(head) do lines[#lines + 1] = l end
  gfx.clear(); W, H = gfx.size()
  local width = W - 28
  for _, l in ipairs(wrap(printable(body), width)) do lines[#lines + 1] = l end

  local per = (H - 100) // LH
  local top = 1
  while true do
    gfx.clear(); W, H = gfx.size(); header("Response")
    local y = 52
    for r = top, math.min(#lines, top + per - 1) do
      gfx.text(14, y, lines[r], "ui12"); y = y + LH
    end
    footer(("line %d/%d  ·  up/down scroll  ·  back = edit"):format(top, #lines))
    gfx.present()
    local e = input.wait()
    if e == "up" and top > 1 then top = top - 1
    elseif e == "down" and top + per <= #lines then top = top + 1
    elseif e == "back" or e == "confirm" then return end
  end
end

local function send(req)
  local is_https = req.url:match("^https://") ~= nil
  if not req.url:match("^https?://") then
    return nil, "URL must start with http:// or https://"
  end
  if is_https then
    for _, h in ipairs(req.headers) do
      local name = h.name:lower()
      if SECRET_HEADERS[name] then
        return nil, "refused: " .. h.name .. " over https (server is not verified; use plain http)"
      end
    end
  end

  screen("Sending", { req.method .. " " .. req.url, "Loading... Back cancels" }, "please wait")
  local ok, why = nil, nil
  if is_https then
    ok, why = wifi.connect()            -- TLS needs the full RAM floor
  else
    ok, why = wifi.connect({ tls = false })
  end
  if not ok then return nil, "WiFi: " .. tostring(why) end

  local hdrs = {}
  for _, h in ipairs(req.headers) do hdrs[h.name] = h.value end
  local args = {
    url = req.url,
    method = req.method,
    headers = hdrs,
    max_body = is_https and 2048 or 4096,
    response_headers = true,
  }
  if BODY_METHODS[req.method] and req.body ~= "" then
    args.body = req.body
    args.content_type = req.content_type    -- nil leaves the API default in place
  end
  return http.request(args)
end

local function __main()
  local req = {
    url = "http://",
    method = "GET",
    headers = {},
    body = "",
    content_type = nil,   -- nil = the API default (application/x-www-form-urlencoded)
  }

  -- One list drives both the labels and the action, so the cursor can never map to the wrong row.
  local function items()
    local list = {
      { "URL: " .. (req.url == "http://" and "(not set)" or req.url):sub(1, 40), "url" },
      { "Method: " .. req.method, "method" },
      { ("Headers: %d / %d"):format(#req.headers, MAX_HEADERS), "headers" },
      { "Add header...", "add" },
      { "Clear headers", "clear" },
    }
    if BODY_METHODS[req.method] then
      list[#list + 1] = { "Body: " .. (req.body == "" and "(empty)" or #req.body .. " chars"), "body" }
      list[#list + 1] = { "Content-Type: " .. (req.content_type or "(default)"):sub(1, 30), "ctype" }
    end
    list[#list + 1] = { "Send", "send" }
    return list
  end

  while true do
    local list = items()
    local labels = {}
    for i, it in ipairs(list) do labels[i] = it[1] end
    local pick = menu("HTTP Client", function() return labels end, "confirm = change  ·  back = exit")
    if not pick then break end
    local action = list[pick][2]

    if action == "url" then
      local s = input.text("URL (http:// or https://)", req.url, 600)
      if s then req.url = s end
    elseif action == "method" then
      local idx = 1
      for i, m in ipairs(METHODS) do if m == req.method then idx = i end end
      req.method = METHODS[idx % #METHODS + 1]
    elseif action == "add" then
      if #req.headers >= MAX_HEADERS then
        screen("Headers", { "limit is " .. MAX_HEADERS }, "back")
        while input.wait() ~= "back" do end
      else
        local s = input.text("Header: Name: value", "", 200)
        if s then
          local name, value = s:match("^%s*([%w%-]+)%s*:%s*(.-)%s*$")
          if name then
            req.headers[#req.headers + 1] = { name = name, value = value }
          else
            screen("Headers", { "use the form Name: value" }, "back")
            while input.wait() ~= "back" do end
          end
        end
      end
    elseif action == "clear" then
      req.headers = {}
    elseif action == "ctype" then
      local s = input.text("Content-Type (blank = default)", req.content_type or "", 100)
      if s then req.content_type = s ~= "" and s or nil end
    elseif action == "body" then
      local s = input.text("Body (max " .. MAX_BODY_CHARS .. " chars)", req.body, MAX_BODY_CHARS)
      if s then req.body = s end
    elseif action == "send" then
      if req.url == "http://" then
        screen("Send", { "set a URL first" }, "back")
        while input.wait() ~= "back" do end
      else
        local res, err = send(req)
        show_response(res, err)
      end
    end
  end
  app.exit()
end

local ok, err = pcall(__main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
  app.exit()
end
