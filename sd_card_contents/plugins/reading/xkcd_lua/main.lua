-- xkcd_lua: the crossplay xkcd viewer, ported to CrossLua.
--
-- Reads the crossplay pack (index.dat / images.dat / text.dat) from the
-- /Xkcd folder on the SD card through a storage READ grant. There is no
-- network path in this port: the pack is copied to the card, exactly like
-- the bulk of the archive always is (the C++ app's wifi update flow is the
-- only part not ported).
--
-- The pack's artwork is NOT a PNG/BMP/JPEG file that gfx.image could open
-- directly: images.dat holds raw 1-bit rows (MSB first, a set bit is ink)
-- with no file header at all. So each visible slice is wrapped in a standard
-- 1-bit BMP (palette 0 = white, 1 = black, top-down; the firmware's Bitmap
-- reader maps 1-bit palettes natively with no dithering) and drawn with
-- gfx.image fitted 1:1 into the box place() computed. If that path ever
-- fails, the same rows are blitted with gfx.pixel -- the app never draws
-- nothing silently.
--
-- Controls (7 buttons, no touch on the X4; the C++ tap targets are mapped
-- to buttons):
--   menu    up/down move, confirm open, back exits
--   list    up/down cursor, confirm open, left/right page, back to menu
--   number  up/down spin digit, right append, left backspace, confirm GO
--   reader  up/down pan (spilling into prev/next comic at the ends),
--           left/right prev/next comic, confirm = reader menu
--           (WHOLE COMIC / PAGE VIEW toggle, ALT TEXT), back to menu

local core = require("xkcd_core")

local BASE = "sd:Xkcd"
local F_INDEX = BASE .. "/index.dat"
local F_IMAGES = BASE .. "/images.dat"
local F_TEXT = BASE .. "/text.dat"
local F_FRAME = "data:frame.bmp"
local F_READS = "data:reads.bin"

local PAGE_ROWS = 12
local BAR_H = 44
local MARGIN = 16
local ROW_H = 32
local CAP_ALT = 1024

-- --- state ----------------------------------------------------------------

local arch = nil            -- {count, maxNum, size, src} | nil
local indexSrc, textSrc = nil, nil
local comic = nil           -- the open record
local pos = 0               -- its position in the archive
local title, alt = "", ""
local at = { lens = core.LENS_ART, column = 0, row = 0, scrollY = 0 }
local view = "menu"
local cursor = 0            -- menu / reader-menu cursor
local listFirst, listSel = 0, 0
local typed = ""            -- go-to-number digits
local digit = 0
local readBits = ""
local readCount = 0
local exited = false
local markRead            -- forward declaration: loadComic calls it

local function readerW() return 480 end
local function readerH() return 800 - BAR_H end   -- 756

-- --- the pack -------------------------------------------------------------

local function makeSource(path)
  local size = fs.size(path)
  if not size then return nil end
  return {
    read = function(off, len) return fs.read(path, off, len) end,
    size = function() return size end,
  }
end

local function openArchive()
  arch = nil
  indexSrc, textSrc = nil, nil
  if not fs.exists(F_INDEX) or not fs.exists(F_IMAGES) or not fs.exists(F_TEXT) then
    return
  end
  indexSrc = makeSource(F_INDEX)
  textSrc = makeSource(F_TEXT)
  if not indexSrc then return end
  arch = core.archiveOpen(indexSrc)
  if not arch then indexSrc = nil end
end

local function readRecord(i)
  if not arch or i < 0 or i >= arch.count then return nil end
  local s = fs.read(F_INDEX, 16 + i * 40, 40)
  if not s or #s < 40 then return nil end
  local rec = core.decodeRecord(s)
  if not core.comicValid(rec) then return nil end
  return rec
end

local function loadComic(i, atEnd)
  local rec = readRecord(i)
  if not rec then return false end
  comic = rec
  pos = i
  if textSrc then
    title = core.readTitle(textSrc, rec, 96)
    alt = core.readAlt(textSrc, rec, CAP_ALT)
  else
    title, alt = "", ""
  end
  local r = core.renditionFor(rec, core.LENS_ART)
  if atEnd then
    at = core.endOf(r, readerW(), readerH())
  else
    at = core.startOf(r, readerW())
  end
  at.lens = core.LENS_ART   -- always open as the artwork itself (shipped C++ behavior)
  markRead(rec.num)
  return true
end

-- --- read state -----------------------------------------------------------
-- The C++ keeps /xkcd/read.bin; here the grant is read-only, so the same
-- one-bit-per-comic bitmap lives in the app's own data: sandbox.

local function countBits(s)
  local n = 0
  for i = 1, #s do
    local c = s:byte(i)
    for b = 0, 7 do
      if (c >> b) & 1 == 1 then n = n + 1 end
    end
  end
  return n
end

local function loadReads()
  readBits = fs.read(F_READS) or ""
  readCount = countBits(readBits)
end

local function saveReads()
  return fs.write(F_READS, readBits)
end

local function isRead(num)
  local byte = num // 8
  if byte + 1 > #readBits then return false end
  return (readBits:byte(byte + 1) >> (num % 8)) & 1 == 1
end

markRead = function(num)
  local byte = num // 8
  local need = byte + 1
  if #readBits < need then readBits = readBits .. string.rep("\0", need - #readBits) end
  local b = readBits:byte(byte + 1)
  local bit = 1 << (num % 8)
  if (b & bit) == 0 then
    readBits = readBits:sub(1, byte) .. string.char(b | bit) .. readBits:sub(byte + 2)
    readCount = readCount + 1
    saveReads()
  end
end

-- --- text helpers ---------------------------------------------------------

local function truncate(s, maxW)
  if gfx.text_width(s) <= maxW then return s end
  while #s > 1 and gfx.text_width(s .. "...") > maxW do s = s:sub(1, -2) end
  return s .. "..."
end

-- Word wrap for 480px screens: the fonts are proportional, so measure with
-- gfx.text_width and break at word boundaries, never by character counts.
local function wrapLines(s, maxW)
  local lines, line = {}, ""
  for word in s:gmatch("%S+") do
    local add = line == "" and word or (line .. " " .. word)
    if gfx.text_width(add) > maxW then
      if line ~= "" then
        lines[#lines + 1] = line
        line = word
      else
        lines[#lines + 1] = word
        line = ""
      end
    else
      line = add
    end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end

-- --- drawing --------------------------------------------------------------
-- (drawMosaic lives above drawMenu: it is the menu's own ornament and
-- drawMenu calls it.)

-- The menu ornament: every recent comic as a rectangle at its own aspect
-- ratio, filled if read, outlined if not. Made of the app's own material
-- carrying the app's own data.
local function drawMosaic()
  if not arch then return end
  local cellH, gap = 26, 4
  local n = math.min(240, arch.count)
  local first = arch.count - n
  local data = fs.read(F_INDEX, 16 + first * 40, n * 40)
  if not data then return end
  local x, y, placed = MARGIN, 200, 0
  for i = 0, n - 1 do
    local rec = core.decodeRecord(data:sub(i * 40 + 1, (i + 1) * 40))
    if core.comicValid(rec) then
      local w = rec.height > 0 and (cellH * rec.width) // rec.height or cellH
      if w < 3 then w = 3 end
      if w > 440 then w = 440 end
      if x + w > 480 - MARGIN then
        x = MARGIN
        y = y + cellH + gap
        if y + cellH > 772 then break end
      end
      if isRead(rec.num) then
        gfx.rect(x, y, w, cellH, true, true)
      else
        gfx.rect(x, y, w, cellH, false, true)
      end
      x = x + w + gap
      placed = placed + 1
    end
  end
end

local function drawMenu()
  gfx.clear()
  gfx.text(MARGIN, 24, "XKCD", "sans18", "b")
  local y = 60
  local rows = {}
  if arch then
    local newest = readRecord(arch.count - 1)
    local head = "#" .. arch.maxNum
    if newest then
      local t = textSrc and core.readTitle(textSrc, newest, 96) or ""
      head = "#" .. newest.num .. "  " .. t
    end
    rows = {
      { label = truncate(head, 440), act = "latest" },
      { label = "BROWSE", act = "browse" },
      { label = "GO TO NUMBER", act = "number" },
      { label = "RANDOM", act = "random" },
    }
  else
    rows = {
      { label = "NO ARCHIVE", act = nil },
      { label = "The xkcd pack is not on this card.", act = nil },
      { label = "Copy index.dat, images.dat and text.dat", act = nil },
      { label = "into the /Xkcd folder, then reopen.", act = nil },
    }
  end
  for i, row in ipairs(rows) do
    if i - 1 == cursor and row.act then
      gfx.rect(MARGIN, y, 448, ROW_H - 6, true, true)
      gfx.text(MARGIN + 8, y + 7, row.label, "sans18", "w")
    else
      gfx.text(MARGIN + 8, y + 7, row.label, "sans18")
    end
    y = y + ROW_H
  end
  if arch then drawMosaic() end
  if arch then
    gfx.text(MARGIN, 800 - 18, ("%d COMICS   %d READ"):format(arch.count, readCount), "ui12")
  else
    gfx.text(MARGIN, 800 - 18, "This build reads the card only (no wifi update).", "ui12")
  end
  gfx.present()
end

local function drawList()
  gfx.clear()
  gfx.text(MARGIN, 16, "BROWSE", "sans18", "b")
  gfx.text(480 - MARGIN, 16, ("%d OF %d"):format(listFirst + 1, arch.count), "ui12", "r")
  local y = 52
  for i = 0, PAGE_ROWS - 1 do
    local p = arch.count - 1 - (listFirst + i)
    if p < 0 then break end
    local rec = readRecord(p)
    if not rec then break end
    local label = truncate(("#%d  %s"):format(rec.num, textSrc and core.readTitle(textSrc, rec, 96) or ""), 356)
    local mark = isRead(rec.num) and "READ" or ""
    if i == listSel then
      gfx.rect(MARGIN, y, 448, ROW_H - 6, true, true)
      gfx.text(MARGIN + 8, y + 7, label, "sans18", "w")
      if mark ~= "" then gfx.text(464, y + 7, mark, "ui12", "wr") end
    else
      gfx.text(MARGIN + 8, y + 7, label, "sans18")
      if mark ~= "" then gfx.text(464, y + 7, mark, "ui12", "r") end
    end
    y = y + ROW_H
  end
  gfx.text(MARGIN, 780, "left/right: page   back: menu", "ui12")
  gfx.present()
end

local function drawNumber()
  gfx.clear()
  gfx.text(MARGIN, 24, "GO TO NUMBER", "sans18", "b")
  local shown = typed
  if #typed < 5 then shown = shown .. digit end
  gfx.text(0, 90, "#" .. shown, "sans18", "bc")
  local firstRec = arch.count > 0 and readRecord(0) or nil
  local first = firstRec and firstRec.num or 1
  gfx.text(0, 140, ("%d to %d   (%d comics on the card)"):format(first, arch.maxNum, arch.count), "ui12", "c")
  gfx.text(0, 200, "up/down: digit   right: enter   left: erase", "ui12", "c")
  gfx.text(0, 226, "confirm: go   back: cancel", "ui12", "c")
  gfx.present()
end

local function drawNotice(head, body)
  gfx.clear()
  gfx.text(MARGIN, 24, head, "sans18", "b")
  local y = 70
  for _, line in ipairs(wrapLines(body, 448)) do
    gfx.text(MARGIN, y, line, "sans18")
    y = y + 30
    if y > 760 then break end
  end
  gfx.text(0, 780, "back: menu", "ui12", "c")
  gfx.present()
end

local function showNotice(head, body)
  view = "notice"
  drawNotice(head, body)
end

-- --- the reader -----------------------------------------------------------

local function currentRendition() return core.renditionFor(comic, at.lens) end

-- One pack row -> one BMP row string. The pack's MSB-first ink=1 bits map
-- straight onto the 1-bit BMP (palette entry 1 is black); the Bitmap reader
-- never reads bits past the image width, so the trailing mask is just for
-- cleanliness. Top-down file, so rows are emitted in reading order.
local function rowToBmp(row, bitOff, bw, bmpStride)
  local out
  if bitOff % 8 == 0 then
    local byteStart = bitOff // 8
    local bwBytes = math.ceil(bw / 8)
    out = row:sub(byteStart + 1, byteStart + bwBytes)
    local rest = bw % 8
    if rest ~= 0 and #out >= bwBytes then
      local last = out:byte(bwBytes) or 0
      last = last & (0xFF << (8 - rest))
      out = out:sub(1, bwBytes - 1) .. string.char(last)
    end
  else
    -- General path: slice starting mid-byte.
    local bytes, acc, n = {}, 0, 0
    local total = bitOff + bw
    local s = row:sub(1, math.ceil(total / 8))
    for i = 1, #s do
      local b = s:byte(i)
      for k = 0, 7 do
        local idx = (i - 1) * 8 + k
        if idx >= bitOff and idx < total then
          acc = (acc << 1) | ((b >> (7 - k)) & 1)
          n = n + 1
          if n == 8 then bytes[#bytes + 1] = acc; acc = 0; n = 0 end
        end
      end
    end
    if n > 0 then bytes[#bytes + 1] = acc << (8 - n) end
    out = string.char(table.unpack(bytes))
  end
  local pad = bmpStride - #out
  if pad > 0 then out = out .. string.rep("\0", pad) end
  return out
end

-- Write the visible slice as a 1-bit BMP (header .. rows, top-down) and
-- let gfx.image draw it. Rows are read a band at a time so the Lua heap
-- never holds the whole frame. Returns true | nil, err.
local function buildFrame(r, p)
  local bw, bh = p.visibleW, p.visibleH
  if bw < 1 or bh < 1 then return true end
  local bmpStride = (bw + 31) // 32 * 4
  local dataSize = bmpStride * bh
  local fileSize = 62 + dataSize
  local hdr = string.pack("<I2I4I2I2I4", 0x4D42, fileSize, 0, 0, 62)
      .. string.pack("<I4i4i4I2I2I4I4i4i4I4I4", 40, bw, -bh, 1, 1, 0, dataSize, 2835, 2835, 2, 0)
      .. string.char(0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00)
  local bandRows = math.max(1, math.min(512, 24000 // r.stride))
  local row0, written = p.scrollY, false
  local y = row0
  while y < row0 + bh do
    local n = math.min(bandRows, row0 + bh - y)
    local data = fs.read(F_IMAGES, r.offset + y * r.stride, n * r.stride)
    if not data then return nil, "artwork read failed" end
    local chunk = {}
    for row = 1, n do
      local rs = data:sub((row - 1) * r.stride + 1, row * r.stride)
      chunk[#chunk + 1] = rowToBmp(rs, p.scrollX, bw, bmpStride)
    end
    local body = table.concat(chunk)
    if not written then
      if not fs.write(F_FRAME, hdr .. body) then return nil, "frame write failed" end
      written = true
    else
      if not fs.append(F_FRAME, body) then return nil, "frame append failed" end
    end
    y = y + n
  end
  if not written then return nil, "nothing to draw" end
  return true
end

-- Fallback blit, so a refused frame file still shows the comic.
local function blitPixels(r, p)
  local bandRows = math.max(1, math.min(256, 16000 // r.stride))
  local y = p.scrollY
  while y < p.scrollY + p.visibleH do
    local n = math.min(bandRows, p.scrollY + p.visibleH - y)
    local data = fs.read(F_IMAGES, r.offset + y * r.stride, n * r.stride)
    if not data then return end
    for row = 1, n do
      local rs = data:sub((row - 1) * r.stride + 1, row * r.stride)
      local sy = p.originY + (y - p.scrollY) + row - 1
      for x = 0, p.visibleW - 1 do
        local ix = p.scrollX + x
        local byte = rs:byte((ix // 8) + 1)
        if byte and ((byte >> (7 - (ix % 8))) & 1) == 1 then
          gfx.pixel(p.originX + x, sy)
        end
      end
    end
    y = y + n
  end
end

-- The 40x26 map at the bar's right end: the comic's own outline at its own
-- aspect, with the part you are looking at filled inside it.
local function drawMap(p)
  local r = currentRendition()
  local boxW, boxH, boxX = 40, 26, 480 - 46
  local boxY = readerH() + (BAR_H - boxH) // 2
  local w, h = boxW, boxH
  if r.width > 0 and r.height > 0 then
    if r.width * boxH > r.height * boxW then
      h = math.max(1, (boxW * r.height) // r.width)
    else
      w = math.max(1, (boxH * r.width) // r.height)
    end
  end
  if w < 3 then w = 3 end
  if h < 3 then h = 3 end
  if w > boxW then w = boxW end
  if h > boxH then h = boxH end
  local ox, oy = boxX + boxW - w, boxY + (boxH - h) // 2
  gfx.rect(ox, oy, w, h, false, false)                     -- white outline
  local vw2 = math.max(2, (w * p.visibleW) // r.width)
  local vh2 = math.max(2, (h * p.visibleH) // r.height)
  local vx = (w * p.scrollX) // r.width
  local vy = (h * p.scrollY) // r.height
  if vx + vw2 > w then vx = w - vw2 end
  if vy + vh2 > h then vy = h - vh2 end
  gfx.rect(ox + vx, oy + vy, vw2, vh2, true, false)        -- white block
end

local function drawReader()
  gfx.clear()
  local r = currentRendition()
  if core.renditionValid(r) then
    local p = core.place(r, readerW(), readerH(), at)
    local ok = buildFrame(r, p)
    if ok then
      gfx.image(F_FRAME, p.originX, p.originY, p.visibleW, p.visibleH)
    else
      blitPixels(r, p)
    end
    gfx.rect(0, readerH(), 480, BAR_H, true, true)              -- the bar
    local label = truncate(("#%d  %s"):format(comic.num, title), 328)
    gfx.text(8, readerH() + 14, label, "ui12", "w")
    if core.sideways(comic) then
      gfx.text(232, readerH() + 14, "TURN DEVICE", "ui12", "w")
    end
    if core.hasOverview(comic) then
      gfx.text(480 - 46 - 56, readerH() + 14, at.lens == core.LENS_WHOLE and "READ" or "ALL", "ui12", "w")
      drawMap(p)
    end
  else
    gfx.rect(0, readerH(), 480, BAR_H, true, true)
    gfx.text(8, readerH() + 14, "unreadable comic", "ui12", "w")
  end
  gfx.present()
end

local function drawAlt()
  gfx.clear()
  gfx.text(MARGIN, 24, ("#%d  %s"):format(comic.num, truncate(title, 440)), "sans18", "b")
  local y = 64
  local body = alt == "" and "(no alt text)" or alt
  for _, line in ipairs(wrapLines(body, 448)) do
    gfx.text(MARGIN, y, line, "sans18")
    y = y + 30
    if y > 760 then break end
  end
  gfx.text(0, 780, "back: the comic", "ui12", "c")
  gfx.present()
end

local function readerMenuRows()
  local rows = {}
  if core.hasOverview(comic) then
    rows[#rows + 1] = at.lens == core.LENS_WHOLE and "PAGE VIEW" or "WHOLE COMIC"
  end
  rows[#rows + 1] = "ALT TEXT"
  return rows
end

local function drawReaderMenu()
  gfx.clear()
  gfx.text(MARGIN, 24, ("#%d"):format(comic.num), "sans18", "b")
  local rows = readerMenuRows()
  local y = 80
  for i, row in ipairs(rows) do
    if i - 1 == cursor then
      gfx.rect(MARGIN, y, 448, ROW_H - 6, true, true)
      gfx.text(MARGIN + 8, y + 7, row, "sans18", "w")
    else
      gfx.text(MARGIN + 8, y + 7, row, "sans18")
    end
    y = y + ROW_H
  end
  gfx.text(0, 780, "back: the comic", "ui12", "c")
  gfx.present()
end

-- --- stepping -------------------------------------------------------------

-- The rows a step to `targetRow` will judge, as a flags array (one byte per
-- row, not the pixels: a 300-row window as pixels would be 19 KB per tap).
-- A failed read hands the step a nil window, which is legal input: the walk
-- falls back to a plain half-screen.
local function buildGapWindow(r, targetRow)
  local firstRow, rowCount = core.gapWindowFor(r, readerH(), targetRow)
  if rowCount <= 0 then return nil end
  local flags = {}
  local bandRows = math.max(1, 24000 // r.stride)
  local done = 0
  while done < rowCount do
    local n = math.min(bandRows, rowCount - done)
    local data = fs.read(F_IMAGES, r.offset + (firstRow + done) * r.stride, n * r.stride)
    if not data then return nil end
    for row = 1, n do
      local rs = data:sub((row - 1) * r.stride + 1, row * r.stride)
      flags[#flags + 1] = core.rowIsGap(rs, r.width)
    end
    done = done + n
  end
  return { firstRow = firstRow, flags = flags }
end

local function step(down)
  local r = currentRendition()
  local target = down and at.row + 1 or at.row - 1
  local window = buildGapWindow(r, target)
  if down then
    at = core.stepForward(r, readerW(), readerH(), at, window)
  else
    at = core.stepBack(r, readerW(), readerH(), at, window)
  end
end

local function openComicAt(i, atEnd)
  if not loadComic(i, atEnd) then
    showNotice("MISSING", "That comic is not in the pack on this card.")
    return
  end
  view = "reader"
  drawReader()
end

local function nextComic()
  if arch and pos + 1 < arch.count then openComicAt(pos + 1, false) end
end

local function prevComic()
  if arch and pos > 0 then
    -- At its END, not its start: backing off the top of one comic shows the
    -- bottom of the one before, like a reader's chapter boundary.
    openComicAt(pos - 1, true)
  end
end

-- --- input ----------------------------------------------------------------

local function toMenu()
  view = "menu"
  cursor = 0
  drawMenu()
end

local function menuAction(row)
  if row == "latest" then
    openComicAt(arch.count - 1, false)
  elseif row == "browse" then
    listFirst, listSel = 0, 0
    view = "list"
    drawList()
  elseif row == "number" then
    typed, digit = "", 0
    view = "number"
    drawNumber()
  elseif row == "random" then
    openComicAt(system.millis() % arch.count, false)
  end
end

local function handleBack()
  if view == "menu" then
    exited = true
  elseif view == "list" or view == "number" or view == "notice" then
    toMenu()
  elseif view == "reader" then
    toMenu()
  elseif view == "alt" or view == "rmenu" then
    view = "reader"
    drawReader()
  end
end

local function handleUp()
  if view == "menu" then
    cursor = cursor - 1
    if cursor < 0 then cursor = 3 end
    drawMenu()
  elseif view == "list" then
    if listSel > 0 then listSel = listSel - 1 end
    drawList()
  elseif view == "number" then
    local lo = #typed == 0 and 1 or 0
    digit = digit - 1
    if digit < lo then digit = 9 end
    drawNumber()
  elseif view == "rmenu" then
    cursor = cursor - 1
    if cursor < 0 then cursor = #readerMenuRows() - 1 end
    drawReaderMenu()
  end
end

local function handleDown()
  if view == "menu" then
    cursor = cursor + 1
    if cursor > 3 then cursor = 0 end
    drawMenu()
  elseif view == "list" then
    if listSel < PAGE_ROWS - 1 then listSel = listSel + 1 end
    drawList()
  elseif view == "number" then
    local lo = #typed == 0 and 1 or 0
    digit = digit + 1
    if digit > 9 then digit = lo end
    drawNumber()
  elseif view == "rmenu" then
    cursor = cursor + 1
    if cursor >= #readerMenuRows() then cursor = 0 end
    drawReaderMenu()
  end
end

local function handleConfirm()
  if view == "menu" then
    if arch then
      menuAction(({ "latest", "browse", "number", "random" })[cursor + 1])
    end
  elseif view == "list" then
    local p = arch.count - 1 - (listFirst + listSel)
    if p >= 0 then openComicAt(p, false) end
  elseif view == "number" then
    if typed ~= "" then
      local n = tonumber(typed)
      local i = n and core.archiveFind(arch, n) or -1
      if i >= 0 then
        openComicAt(i, false)
      else
        showNotice("NOT HERE", ("#%d is not in the pack on this card."):format(n))
      end
    end
  elseif view == "reader" then
    cursor = 0
    view = "rmenu"
    drawReaderMenu()
  elseif view == "rmenu" then
    local rows = readerMenuRows()
    local act = rows[cursor + 1]
    if act == "ALT TEXT" then
      view = "alt"
      drawAlt()
    elseif act == "WHOLE COMIC" or act == "PAGE VIEW" then
      local to = at.lens == core.LENS_WHOLE and core.LENS_ART or core.LENS_WHOLE
      at = core.mapAcross(comic, readerW(), readerH(), at, to)
      view = "reader"
      drawReader()
    end
  elseif view == "alt" or view == "notice" then
    toMenu()
  end
end

local function handleLeft()
  if view == "list" then
    listFirst = listFirst - PAGE_ROWS
    if listFirst < 0 then listFirst = 0 end
    listSel = 0
    drawList()
  elseif view == "number" then
    typed = typed:sub(1, -2)
    if typed == "" then digit = 0 end
    drawNumber()
  elseif view == "reader" then
    prevComic()
  end
end

local function handleRight()
  if view == "list" then
    if listFirst + PAGE_ROWS < arch.count then listFirst = listFirst + PAGE_ROWS end
    listSel = 0
    drawList()
  elseif view == "number" then
    if #typed < 5 then
      local lo = #typed == 0 and 1 or 0
      if digit >= lo then typed = typed .. digit end
    end
    drawNumber()
  elseif view == "reader" then
    nextComic()
  end
end

-- --- main -----------------------------------------------------------------

local function __main()
  openArchive()
  loadReads()
  view = "menu"
  cursor = 0
  drawMenu()
  while true do
    local e = input.wait()
    if e == "back" then
      handleBack()
      if exited then break end
    elseif e == "confirm" then
      handleConfirm()
    elseif e == "up" then
      if view == "reader" then
        local r = currentRendition()
        if core.canStepBack(r, readerW(), readerH(), at) then
          step(false)
          drawReader()
        else
          prevComic()
        end
      else
        handleUp()
      end
    elseif e == "down" then
      if view == "reader" then
        local r = currentRendition()
        if core.canStepForward(r, readerW(), readerH(), at) then
          step(true)
          drawReader()
        else
          nextComic()
        end
      else
        handleDown()
      end
    elseif e == "left" then
      handleLeft()
    elseif e == "right" then
      handleRight()
    end
  end
  app.exit()
end

local ok, err = pcall(__main)
if not ok then
  gfx.clear()
  gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b")
  gfx.present()
  while input.wait() ~= "back" do end
  app.exit()
end