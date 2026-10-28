-- Text reader: browse sd:Books (read grant), open .txt / .md, turn pages, resume the last file.
-- Pages are laid out on demand from byte offsets, so a big file never sits in RAM.
-- Progress: data:last.txt holds the last path and byte offset.

local ROOT = "Books"
local LAST = "data:last.txt"
local FONT = "sans14"

local W, H = 0, 0
local LH = 0          -- line height in px
local LINES = 0       -- lines per page
local TEXT_W = 0      -- usable text width

local function clip(s, n) return #s > n and s:sub(1, n) or s end
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function header(title)
  gfx.rect(0, 0, W, 40, true)
  gfx.text(14, 10, clip(title, 30), "ui12", "bw")
end

-- ---------- layout: lay out up to `nlines` lines starting at byte offset `start` ----------
-- Returns the lines and the byte offset where the next page begins.
local function layout(path, start, nlines)
  local chunk = fs.read(path, start, 6000) or ""
  local n = #chunk
  local out, pos, cur, cur_start = {}, 1, "", 1
  while pos <= n and #out < nlines do
    local nl = chunk:find("\n", pos, true)
    local stop = nl and (nl - 1) or n
    local tp = pos
    while tp <= stop and #out < nlines do
      local ws, we = chunk:find("^[^%s]*[ \t]*", tp)
      if not ws or we < tp then break end
      local token = chunk:sub(tp, we)
      local cand = cur .. token
      if cur ~= "" and gfx.text_width(trim(cand), FONT) > TEXT_W then
        out[#out + 1] = trim(cur)
        cur, cur_start = token, tp
      else
        cur = cand
      end
      tp = we + 1
    end
    if #out >= nlines then break end
    if nl then
      out[#out + 1] = trim(cur)
      cur, cur_start = "", nl + 1
      pos = nl + 1
    else
      pos = n + 1
    end
  end
  if #out < nlines and cur ~= "" and pos > n then
    out[#out + 1] = trim(cur)
    cur_start = n + 1
  end
  return out, start + cur_start - 1
end

-- ---------- file picker ----------
local function list_dir(dir)
  local items, err = fs.list("sd:" .. dir, { detail = true, limit = 60 })
  if not items then return nil, err end
  local out = {}
  for _, it in ipairs(items) do
    if it.dir then
      out[#out + 1] = { name = it.name, dir = true }
    else
      local lower = it.name:lower()
      if lower:match("%.txt$") or lower:match("%.md$") then
        out[#out + 1] = { name = it.name, dir = false }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.dir ~= b.dir then return a.dir end
    return a.name:lower() < b.name:lower()
  end)
  return out
end

local function last_mark()
  local s = fs.read(LAST)
  if not s then return nil end
  local path, off = s:match("^(.-)\n(%d+)")
  if not path then return nil end
  return path, tonumber(off)
end

local function save_mark(path, off)
  fs.write(LAST, path .. "\n" .. tostring(off))
end

-- Picker: returns a file path (sd:...) or nil to quit.
local cur_dir, cur_idx = ROOT, 1
local function pick_file()
  while true do
    gfx.clear(); W, H = gfx.size()
    header("Books: " .. cur_dir)
    local items, err = list_dir(cur_dir)
    local y = 56
    local menu = {}
    local mpath, moff = last_mark()
    if mpath and cur_dir == ROOT then
      menu[#menu + 1] = { label = "Resume: " .. clip(mpath:match("([^/]+)$") or mpath, 22), resume = mpath, off = moff }
    end
    if cur_dir ~= ROOT then menu[#menu + 1] = { label = "../", up = true } end
    if not items then
      gfx.text(16, y, "Cannot list folder:", "ui12")
      gfx.text(16, y + 28, clip(tostring(err), 40), "small")
    end
    for _, it in ipairs(items or {}) do
      menu[#menu + 1] = { label = (it.dir and it.name .. "/" or it.name), dir = it.dir and it.name, file = (not it.dir) and it.name }
    end
    if #menu == 0 then gfx.text(16, y, "No .txt or .md files here.", "ui12") end
    if cur_idx > #menu then cur_idx = math.max(1, #menu) end
    for i, m in ipairs(menu) do
      if y > H - 70 then break end
      if i == cur_idx then
        gfx.rect(10, y - 4, W - 20, LH + 4, true); gfx.text(16, y, clip(m.label, 36), FONT, "w")
      else
        gfx.text(16, y, clip(m.label, 36), FONT)
      end
      y = y + LH + 6
    end
    gfx.text(14, H - 34, "Confirm open, Back exit", "small")
    gfx.present()
    local e = input.wait()
    if e == "up" then cur_idx = cur_idx > 1 and cur_idx - 1 or math.max(1, #menu)
    elseif e == "down" then cur_idx = cur_idx < #menu and cur_idx + 1 or 1
    elseif e == "confirm" and #menu > 0 then
      local m = menu[cur_idx]
      cur_idx = 1
      if m.up then cur_dir = ROOT
      elseif m.resume then return m.resume, m.off   -- stored with its sd: prefix already
      elseif m.dir then cur_dir = cur_dir .. "/" .. m.dir
      elseif m.file then return "sd:" .. cur_dir .. "/" .. m.file, 0
      end
    elseif e == "back" then
      if cur_dir ~= ROOT then cur_dir = ROOT; cur_idx = 1 else return nil end
    end
  end
end

-- ---------- reader ----------
local function read_book(path, offset)
  local stack = { offset }
  while true do
    gfx.clear(); W, H = gfx.size()
    local lines, nxt = layout(path, stack[#stack], LINES)
    local y = 8
    for _, l in ipairs(lines) do
      gfx.text(14, y, l, FONT)
      y = y + LH
    end
    gfx.text(14, H - 30, string.format("%s   %d bytes in", clip(path:match("([^/]+)$") or path, 22), stack[#stack]), "small")
    gfx.present()
    save_mark(path, stack[#stack])
    local e = input.wait()
    if e == "down" or e == "right" then
      if #lines > 0 and nxt > stack[#stack] then stack[#stack + 1] = nxt end
    elseif e == "up" or e == "left" then
      if #stack > 1 then stack[#stack] = nil end
    elseif e == "back" then
      return
    end
  end
end

local function main()
  W, H = gfx.size()
  LH = gfx.line_height(FONT) + 4
  TEXT_W = W - 28
  LINES = math.max(1, (H - 60) // LH)
  while true do
    local path, off = pick_file()
    if not path then return end
    read_book(path, off or 0)
  end
end

local ok, err = pcall(main)
if not ok then
  gfx.clear()
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b")
  gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
