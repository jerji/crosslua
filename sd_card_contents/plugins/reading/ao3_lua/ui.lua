-- Shared drawing helpers for AO3 & Library. Pure helpers on top of gfx/input;
-- no app state lives here. Every screen in the app uses these.

local M = {}

M.TITLE_H = 44
local ROW = 44

-- Cut s to fit px pixels, adding "..." when it is cut (whole UTF-8 chars).
function M.clip(s, px, font, flags)
  s = tostring(s or "")
  flags = flags or ""
  if gfx.text_width(s, font, flags) <= px then return s end
  while #s > 0 do
    local p = utf8.offset(s, -1)
    if not p then break end
    s = s:sub(1, p - 1)
    if gfx.text_width(s .. "...", font, flags) <= px then break end
  end
  return s .. "..."
end

-- Longest prefix of s that is at most n bytes and ends on a whole UTF-8 char.
function M.clip_bytes(s, n)
  if #s <= n then return s end
  local i = n
  while i > 0 and (s:byte(i + 1) & 0xC0) == 0x80 do i = i - 1 end
  return s:sub(1, i)
end

function M.header(title, right)
  local W = gfx.size()
  gfx.rect(0, 0, W, M.TITLE_H, true, true)
  gfx.text(14, 12, M.clip(title, W - 150, "ui12", "bw"), "ui12", "bw")
  if right then gfx.text(W - 14, 12, right, "ui12", "bwr") end
end

function M.footer(hint)
  local W, H = gfx.size()
  gfx.text(14, H - 30, M.clip(hint, W - 28, "ui12"), "ui12")
end

function M.wait_back()
  while input.wait() ~= "back" do end
end

-- One line of status over a plain screen.
function M.busy(title, text)
  local W = gfx.size()
  gfx.clear()
  M.header(title)
  gfx.text(16, 100, M.clip(text, W - 32, "sans16", "b"), "sans16", "b")
  gfx.present()
end

-- Wrapped text lines under a header, with an optional footer hint.
function M.screen(title, lines, hint)
  local W, H = gfx.size()
  gfx.clear()
  M.header(title)
  local lh = gfx.line_height("sans14") + 6
  local y = M.TITLE_H + 16
  for _, l in ipairs(lines) do
    for _, part in ipairs(gfx.wrap(tostring(l), W - 28, "sans14")) do
      if y > H - 60 then break end
      gfx.text(16, y, part, "sans14")
      y = y + lh
    end
  end
  if hint then M.footer(hint) end
  gfx.present()
end

-- Scrolling list. Returns the picked index, or nil on Back.
function M.menu(title, items, hint)
  local cur, top = 1, 1
  while true do
    local W, H = gfx.size()
    local rows = math.max(1, (H - M.TITLE_H - 60) // ROW)
    gfx.clear()
    M.header(title)
    if #items == 0 then gfx.text(16, M.TITLE_H + 20, "(nothing here)", "sans14") end
    local y = M.TITLE_H + 12
    for i = top, math.min(#items, top + rows - 1) do
      local sel = (i == cur)
      if sel then gfx.rect(8, y, W - 16, ROW - 6, true, true) end
      local fl = sel and "bw" or ""
      gfx.text(16, y + 8, M.clip(items[i], W - 40, "sans16", fl), "sans16", fl)
      y = y + ROW
    end
    if hint then M.footer(hint) end
    gfx.present()

    local e = input.wait()
    if e == "back" then return nil end
    if #items > 0 then
      if e == "up" then cur = cur > 1 and cur - 1 or #items
      elseif e == "down" then cur = cur < #items and cur + 1 or 1
      elseif e == "confirm" then return cur end
      if cur < top then top = cur end
      if cur > top + rows - 1 then top = cur - rows + 1 end
    end
  end
end

-- Run fn; a runtime error shows on screen and waits for Back, never freezes.
function M.guard(fn)
  local ok, err = pcall(fn)
  if not ok then
    gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
    M.wait_back()
  end
end

return M
