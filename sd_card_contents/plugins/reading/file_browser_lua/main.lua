-- File browser (read grant: Books). Lists folders and files; text files show their first 4 KB,
-- .bmp / .jpg images are drawn with gfx.image. Read-only: nothing is written.

local W, H = 0, 0
local LH = 24
local ROOT = "Books"

local function clip(s, n) return #s > n and s:sub(1, n) or s end

local function list(dir)
  local items, err = fs.list("sd:" .. dir, { detail = true, limit = 60 })
  if not items then return nil, err end
  local out = {}
  for _, it in ipairs(items) do out[#out + 1] = { name = it.name, dir = it.dir, size = it.size } end
  table.sort(out, function(a, b)
    if a.dir ~= b.dir then return a.dir end
    return a.name:lower() < b.name:lower()
  end)
  return out
end

local function view_text(path)
  local body = fs.read(path, 0, 4096) or ""
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, clip(path:match("([^/]+)$") or path, 30), "ui12", "bw")
  local y, n = 52, 0
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    if n >= 27 then break end
    gfx.text(12, y, clip(line, 52), "small"); y = y + 22; n = n + 1
  end
  gfx.text(14, H - 34, "Back = return", "small")
  gfx.present()
  while input.wait() ~= "back" do end
end

local function view_image(path)
  gfx.clear(); W, H = gfx.size()
  local dw, dh, err = gfx.image(path, 0, 0)
  if not dw then gfx.text(14, 60, "cannot draw: " .. tostring(err), "ui12") end
  gfx.text(14, H - 34, "Back = return", "small")
  gfx.present()
  while input.wait() ~= "back" do end
end

local function main()
  W, H = gfx.size()
  local dir, cur, stack = ROOT, 1, {}
  while true do
    local items, err = list(dir)
    local rows = {}
    if dir ~= ROOT then rows[#rows + 1] = { name = "..", up = true } end
    for _, it in ipairs(items or {}) do rows[#rows + 1] = it end
    gfx.clear(); gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, clip(dir, 30), "ui12", "bw")
    if not items then gfx.text(14, 56, clip(tostring(err), 50), "small") end
    if cur > #rows then cur = math.max(1, #rows) end
    local y = 56
    for i, r in ipairs(rows) do
      if y > H - 70 then break end
      local label = (r.dir and (r.name .. "/") or r.name)
      if i == cur then gfx.rect(10, y - 4, W - 20, LH + 4, true); gfx.text(16, y, clip(label, 40), "small", "w")
      else gfx.text(16, y, clip(label, 40), "small") end
      y = y + LH
    end
    gfx.text(14, H - 34, "Confirm open, Back up/exit", "small")
    gfx.present()
    local e = input.wait()
    if e == "up" then cur = cur > 1 and cur - 1 or math.max(1, #rows)
    elseif e == "down" then cur = cur < #rows and cur + 1 or 1
    elseif e == "back" then
      if dir == ROOT then return end
      dir = dir:match("^(.*)/[^/]+$") or ROOT; cur = 1
    elseif e == "confirm" and rows[cur] then
      local r = rows[cur]
      if r.up then dir = dir:match("^(.*)/[^/]+$") or ROOT; cur = 1
      elseif r.dir then dir = dir .. "/" .. r.name; cur = 1
      else
        local path = "sd:" .. dir .. "/" .. r.name
        local lower = r.name:lower()
        if lower:match("%.bmp$") or lower:match("%.jpe?g$") then view_image(path)
        else view_text("sd:" .. dir .. "/" .. r.name) end
      end
    end
  end
end

local ok, err = pcall(main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
