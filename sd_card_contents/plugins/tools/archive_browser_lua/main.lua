-- Archive browser (read grant: Books). Lists .zip files, their entries, and shows the start of a text
-- entry. Uses zip.list / zip.read only; nothing is extracted to the card.

local W, H = 0, 0
local LH = 24

local function clip(s, n) return #s > n and s:sub(1, n) or s end

local function menu(title, items, label_fn, footer)
  local cur = 1
  while true do
    gfx.clear(); W, H = gfx.size()
    gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, clip(title, 30), "ui12", "bw")
    if #items == 0 then gfx.text(14, 60, "(nothing here)", "ui12") end
    local y = 56
    for i, it in ipairs(items) do
      if y > H - 70 then break end
      if i == cur then gfx.rect(10, y - 4, W - 20, LH + 4, true); gfx.text(16, y, clip(label_fn(it), 40), "small", "w")
      else gfx.text(16, y, clip(label_fn(it), 40), "small") end
      y = y + LH
    end
    gfx.text(14, H - 34, footer, "small")
    gfx.present()
    local e = input.wait()
    if e == "up" then cur = cur > 1 and cur - 1 or math.max(1, #items)
    elseif e == "down" then cur = cur < #items and cur + 1 or 1
    elseif e == "confirm" and #items > 0 then return items[cur]
    elseif e == "back" then return nil end
  end
end

local function show_text(title, body)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, clip(title, 30), "ui12", "bw")
  local y = 52
  local n = 0
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    if n >= 26 then break end
    gfx.text(12, y, clip(line, 52), "small"); y = y + 22; n = n + 1
  end
  gfx.text(14, H - 34, "Back = return", "small")
  gfx.present()
  while input.wait() ~= "back" do end
end

local function main()
  W, H = gfx.size()
  while true do
    local files = {}
    for _, f in ipairs(fs.list("sd:Books") or {}) do
      if f:lower():match("%.zip$") then files[#files + 1] = f end
    end
    local zipname = menu("Zip archives in Books", files, function(f) return f end, "Confirm open, Back exit")
    if not zipname then return end
    local entries = zip.list("sd:Books/" .. zipname, 128) or {}
    while true do
      local e = menu(zipname, entries, function(x) return string.format("%s  (%d B)", x.name, x.size) end, "Confirm read, Back = files")
      if not e then break end
      if e.size > 65536 then show_text(e.name, "entry too large for the viewer") else
        local data, err = zip.read("sd:Books/" .. zipname, e.name, 4096)
        show_text(e.name, data or ("cannot read: " .. tostring(err)))
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
