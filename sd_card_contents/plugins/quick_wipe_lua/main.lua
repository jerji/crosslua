-- Quick wipe: lists this app's own data files and, for one you pick (or all), overwrites it with zeros and
-- then removes it. Scope is the sandbox: data: only, which is this app's folder. It cannot reach the card.
-- Not a secure erase on wear-levelled flash: old blocks may survive. It reduces what a casual read reveals.

local function txt(...) return input.text(...) or "" end

local function wipe_file(name)
  local p = "data:" .. name
  local size = fs.size(p) or 0
  if size > 0 then
    local zero = string.rep("\0", 4096)
    local off = 0
    while off < size do
      local n = math.min(4096, size - off)
      fs.write_at(p, off, zero:sub(1, n))
      off = off + n
    end
  end
  return fs.remove(p)
end

local ok, err = pcall(function()
  local W, H = gfx.size()
  local names = fs.list("data:") or {}
  local files = {}
  for _, n in ipairs(names) do if n:sub(-1) ~= "/" then files[#files + 1] = n end end
  local cur = 1
  local status = ""
  while true do
    gfx.clear()
    gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Quick wipe (this app only)", "ui12", "bw")
    local y = 56
    if #files == 0 then gfx.text(14, y, "no data files for this app", "ui12") end
    for i, f in ipairs(files) do
      if y > H - 90 then break end
      if i == cur then gfx.rect(10, y - 4, W - 20, 30, true); gfx.text(16, y, f, "small", "w")
      else gfx.text(16, y, f, "small") end
      y = y + 28
    end
    gfx.text(14, H - 60, status, "small")
    gfx.text(14, H - 34, "Confirm = wipe selected, Left = wipe all, Back = exit", "small")
    gfx.present()
    local e = input.wait()
    if e == "back" then break
    elseif e == "up" then cur = cur > 1 and cur - 1 or math.max(1, #files)
    elseif e == "down" then cur = cur < #files and cur + 1 or 1
    elseif e == "confirm" and files[cur] then
      local f = files[cur]
      gfx.clear(); gfx.text(14, 60, "Wipe " .. f .. "? Confirm = yes, Back = no", "ui12"); gfx.present()
      if input.wait() == "confirm" then
        wipe_file(f); table.remove(files, cur); cur = math.max(1, math.min(cur, #files))
        status = "wiped " .. f
      else status = "cancelled" end
    elseif e == "left" then
      gfx.clear(); gfx.text(14, 60, "Wipe ALL " .. #files .. " files? Confirm = yes", "ui12"); gfx.present()
      if input.wait() == "confirm" then
        for _, f in ipairs(files) do wipe_file(f) end
        files = {}; cur = 1; status = "all wiped"
      end
    end
  end
end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
