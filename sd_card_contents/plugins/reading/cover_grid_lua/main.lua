-- Cover grid (read grant: Books): shows the .bmp / .jpg / .jpeg files in one folder as a grid of thumbnails.
-- gfx.image fits each picture into its box, so no separate thumbnail cache is written; the firmware decodes
-- each cover row by row, which keeps RAM flat. Confirm opens a cover full-screen. Back closes it / exits.

local COLS, ROWS = 3, 3
local ROOT = "Books"

local function covers(dir)
  local out = {}
  for _, f in ipairs(fs.list("sd:" .. dir) or {}) do
    local l = f:lower()
    if l:match("%.bmp$") or l:match("%.jpe?g$") then out[#out + 1] = f end
  end
  table.sort(out)
  return out
end

local function main()
  local W, H = gfx.size()
  local list = covers(ROOT)
  local cur, page_top = 1, 1
  local per = COLS * ROWS
  local cell_w, cell_h = (W - 20) // COLS, (H - 80) // ROWS
  local function draw()
    gfx.clear()
    gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "Covers: " .. ROOT, "ui12", "bw")
    if #list == 0 then gfx.text(14, 60, "no .bmp / .jpg covers in Books", "ui12") end
    for slot = 0, per - 1 do
      local i = page_top + slot
      if list[i] then
        local col, row = slot % COLS, slot // COLS
        local x = 10 + col * cell_w
        local y = 50 + row * cell_h
        gfx.image("sd:" .. ROOT .. "/" .. list[i], x + 4, y + 4, cell_w - 8, cell_h - 30)
        if i == cur then gfx.rect(x, y, cell_w, cell_h - 20, false) end
        gfx.text(x + 4, y + cell_h - 24, list[i]:sub(1, 16), "small")
      end
    end
    gfx.text(14, H - 34, "Arrows move, Confirm open, Back exit", "small")
    gfx.present()
  end
  draw()
  while true do
    local e = input.wait()
    if e == "back" then break
    elseif e == "left" then if cur > 1 then cur = cur - 1 end
    elseif e == "right" then if cur < #list then cur = cur + 1 end
    elseif e == "up" then if cur - COLS >= 1 then cur = cur - COLS end
    elseif e == "down" then if cur + COLS <= #list then cur = cur + COLS end
    elseif e == "confirm" and list[cur] then
      gfx.clear()
      gfx.image("sd:" .. ROOT .. "/" .. list[cur], 0, 0, W, H)
      gfx.text(14, H - 34, "Back = grid", "small")
      gfx.present()
      while input.wait() ~= "back" do end
      draw()
      goto continue
    end
    -- keep the selected cell on the visible page
    if cur < page_top then page_top = cur - ((cur - 1) % COLS) end
    if cur >= page_top + per then page_top = page_top + COLS end
    draw()
    ::continue::
  end
end

local ok, err = pcall(main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
