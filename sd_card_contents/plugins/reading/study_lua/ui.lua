-- Small drawing helpers shared by apps (candidate for /.crosslua/lib/ once a second app uses it).
local M = {}

local FONT_ORDER = { "sans18", "sans16", "sans14", "sans12", "ui12", "small" }

-- Greedy word wrap. Returns an array of lines. Words wider than maxw are split by UTF-8 character.
function M.wrap(text, font, flags, maxw)
  local lines = {}
  local space = gfx.text_width(" ", font, flags)
  for para in (text .. "\n"):gmatch("(.-)\n") do
    if para == "" then
      lines[#lines + 1] = ""
    else
      local cur, curw = nil, 0
      for word in para:gmatch("%S+") do
        local ww = gfx.text_width(word, font, flags)
        if ww > maxw then                                  -- too long for one line: break by character
          if cur then lines[#lines + 1] = cur; cur, curw = nil, 0 end
          local piece, pw = "", 0
          for _, cp in utf8.codes(word, true) do
            local ch = utf8.char(cp)
            local cw = gfx.text_width(ch, font, flags)
            if pw + cw > maxw and piece ~= "" then lines[#lines + 1] = piece; piece, pw = "", 0 end
            piece, pw = piece .. ch, pw + cw
          end
          cur, curw = piece, pw
        elseif not cur then
          cur, curw = word, ww
        elseif curw + space + ww <= maxw then
          cur, curw = cur .. " " .. word, curw + space + ww
        else
          lines[#lines + 1] = cur
          cur, curw = word, ww
        end
      end
      if cur then lines[#lines + 1] = cur end
    end
  end
  return lines
end

-- Largest font from FONT_ORDER whose wrapped text fits maxh. Returns font, lines, lineHeight.
-- (Falls back to the smallest font and truncates with an ellipsis line.)
function M.fit(text, maxw, maxh, flags)
  local font, lines, lh
  for _, f in ipairs(FONT_ORDER) do
    lh = gfx.line_height(f) + 2
    lines = M.wrap(text, f, flags, maxw)
    font = f
    if #lines * lh <= maxh then return font, lines, lh end
  end
  local keep = math.max(1, maxh // lh)
  if #lines > keep then
    for i = #lines, keep + 1, -1 do lines[i] = nil end
    lines[keep] = lines[keep] .. " ..."
  end
  return font, lines, lh
end

-- Draw lines centred horizontally in [x, x+w), vertically centred in [y, y+h). Returns top y used.
function M.centered_block(lines, font, lh, x, y, w, h, flags)
  local top = y + math.max(0, (h - #lines * lh) // 2)
  for i, l in ipairs(lines) do gfx.text(x + w // 2, top + (i - 1) * lh, l, font, "c" .. (flags or "")) end
  return top
end

function M.left_block(lines, font, lh, x, y, flags)
  for i, l in ipairs(lines) do gfx.text(x, y + (i - 1) * lh, l, font, flags) end
end

-- Title bar with a hairline under it. `right` is small text on the right.
function M.header(title, right)
  local w = gfx.size()
  gfx.text(16, 10, title, "ui12", "b")
  if right and right ~= "" then gfx.text(w - 16, 14, right, "small", "r") end
  gfx.line(0, 44, w, 44)
  return 48
end

-- Four labels aligned to the four front buttons (Back, Confirm, Left, Right), optional small sub-labels under them.
M.HINT_H = 72
function M.hint_bar(labels, subs)
  local w, h = gfx.size()
  local cw = w // 4
  local y = h - M.HINT_H
  gfx.line(0, y, w, y)
  for i = 1, 4 do
    local x = (i - 1) * cw
    if labels[i] and labels[i] ~= "" then
      gfx.rect(x + 6, y + 8, cw - 12, M.HINT_H - 16)
      gfx.text(x + cw // 2, y + 14, labels[i], "ui12", "c")
      if subs and subs[i] then gfx.text(x + cw // 2, y + 14 + gfx.line_height("ui12") + 2, subs[i], "small", "c") end
    end
  end
end

-- A selectable list. items = { {title=, sub=} ... }; selected is 1-based; returns first visible index used.
function M.list(items, selected, top, bottom, rowh)
  local w = gfx.size()
  rowh = rowh or 66
  local rows = math.max(1, (bottom - top) // rowh)
  local first = math.max(1, math.min(selected - rows // 2, #items - rows + 1))
  for r = 0, rows - 1 do
    local it = items[first + r]
    if not it then break end
    local y = top + r * rowh
    local sel = (first + r == selected)
    if sel then gfx.rect(8, y + 2, w - 16, rowh - 4, true) end
    gfx.text(24, y + 8, it.title, "ui12", sel and "bw" or "b")
    if it.sub then gfx.text(24, y + 8 + gfx.line_height("ui12") + 4, it.sub, "small", sel and "w" or "") end
  end
  return first
end

return M
