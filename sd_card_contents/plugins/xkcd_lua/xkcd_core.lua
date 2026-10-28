-- xkcd_core.lua — the crossplay xkcd pack reader core, ported to Lua.
--
-- Port of /root/x4/crossplay/src/apps_local/xkcd/XkcdCore.{h,cpp} (the
-- "shelf" viewer). PURE: no device calls. Every byte arrives through a
-- ByteSource — a table with `read(offset, length) -> string | nil` and
-- `size() -> int` — so host tests can drive a real pack straight from files.
--
-- What this file does NOT do: it never decides how a comic is laid out. The
-- pack builder settled that (docs/apps/xkcd-pack-format.md, the nine-case
-- rule, computed by build_pack.py's layout()); the reader reads the STORED
-- width/height/sideways-flag and walks that. classifyPosture() and layout()
-- are kept here because they are that rule, stated in the form the doc
-- defines, and the logic suite checks them against the builder's own
-- implementation.
--
-- Implementation notes kept from the C++ (they explain quirks below):
--   * A position is a PANEL INDEX, not a pixel offset; the offset is a pure
--     function of it, so stepping forward and back is an exact inverse.
--   * Reading order is expressed in the COMIC's frame, not the stored
--     image's. A sideways comic is stored a quarter turn, so it starts at
--     the stored image's right-hand column and walks leftwards.

local M = {}

M.PANEL_WIDTH = 480
M.VIEWPORT_H = 756            -- panel height minus the reader's 44px bar
M.COLUMN_OVERLAP = 48
M.COLUMN_STEP = M.PANEL_WIDTH - M.COLUMN_OVERLAP     -- 432
M.MAX_COLUMNS = 8
M.MAX_ART_WIDTH = M.COLUMN_STEP * M.MAX_COLUMNS + M.COLUMN_OVERLAP   -- 3504
M.MAX_COMIC_HEIGHT = 16384
M.K_MAGIC = 0x44434B58        -- "XKCD" little-endian
M.FORMAT_VERSION = 3
M.INDEX_HEADER_BYTES = 16
M.INDEX_RECORD_BYTES = 40
M.SIDEWAYS = 1                -- record flag bit 0: stored rotated
M.GAP_INK_PERCENT = 3
M.GAP_INK_FLOOR = 12
M.MIN_GUTTER_ROWS = 4
M.GUTTER_PAD = 6
M.SNAP_TOLERANCE_NUM = 1
M.SNAP_TOLERANCE_DEN = 5      -- a snap may pull a step by at most 1/5 viewport
M.K_ROTATE_GAIN = 1.30        -- viewing-plan rotation constant (doc, host-side)
M.CLOSER_FLOOR = 0.80         -- viewing-plan closer floor (doc, host-side)

M.LENS_ART = "art"
M.LENS_WHOLE = "whole"

-- --- little-endian reads -------------------------------------------------

local function rd16(s, i) return s:byte(i) | (s:byte(i + 1) << 8) end

local function rd32(s, i)
  return s:byte(i) | (s:byte(i + 1) << 8) | (s:byte(i + 2) << 16) | (s:byte(i + 3) << 24)
end

-- --- records -------------------------------------------------------------

-- Decode one 40-byte index record. Returns nil for a short/garbage buffer.
function M.decodeRecord(s)
  if not s or #s < M.INDEX_RECORD_BYTES then return nil end
  return {
    num = rd16(s, 1), width = rd16(s, 3), height = rd16(s, 5), stride = rd16(s, 7),
    year = rd16(s, 9), month = s:byte(11), day = s:byte(12),
    imageOffset = rd32(s, 13), textOffset = rd32(s, 17),
    flags = s:byte(21),
    overviewWidth = rd16(s, 23), overviewHeight = rd16(s, 25),
    overviewStride = rd16(s, 27), overviewOffset = rd32(s, 29),
  }
end

function M.sideways(c) return c ~= nil and (c.flags & M.SIDEWAYS) ~= 0 or false end

function M.hasOverview(c)
  return c ~= nil and c.overviewWidth > 0 and c.overviewHeight > 0 and c.overviewStride > 0
end

-- The builder's guarantees, enforced at read time (Comic::valid):
--   * the page rendition is never wider than the panel, or sits on the
--     column grid (width = 432*N + 48) so no column reveals a sliver;
--   * the overview, when present, is at most a screenful;
--   * stride covers ceil(width/8) bytes per row.
function M.comicValid(c)
  if not c then return false end
  if not (c.num > 0 and c.width > 0 and c.height > 0 and c.stride > 0) then return false end
  if c.width > M.MAX_ART_WIDTH or c.height > M.MAX_COMIC_HEIGHT then return false end
  if c.stride < math.ceil(c.width / 8) then return false end
  if c.width > M.PANEL_WIDTH and (c.width - M.COLUMN_OVERLAP) % M.COLUMN_STEP ~= 0 then return false end
  if M.hasOverview(c) then
    if c.overviewWidth > M.PANEL_WIDTH or c.overviewHeight > M.MAX_COMIC_HEIGHT then return false end
    if c.overviewStride < math.ceil(c.overviewWidth / 8) then return false end
  end
  return true
end

-- --- the archive ----------------------------------------------------------

-- Parse the 16-byte header + sanity-check the count against the file size,
-- so a card pulled mid-write is rejected whole rather than misread.
function M.archiveOpen(src)
  if not src or not src.read or not src.size then return nil end
  local size = src.size()
  if size < M.INDEX_HEADER_BYTES then return nil end
  local head = src.read(0, M.INDEX_HEADER_BYTES)
  if not head or #head < M.INDEX_HEADER_BYTES then return nil end
  if rd32(head, 1) ~= M.K_MAGIC then return nil end
  if rd16(head, 5) ~= M.FORMAT_VERSION then return nil end
  local count = rd32(head, 9)
  local maxNum = rd32(head, 13)
  local available = (size - M.INDEX_HEADER_BYTES) // M.INDEX_RECORD_BYTES
  if count == 0 or count > available then return nil end
  return { count = count, maxNum = maxNum, size = size, src = src }
end

-- The i'th record in number order. i is a POSITION, not a comic number.
function M.archiveAt(arch, i)
  if not arch or i < 0 or i >= arch.count then return nil end
  local s = arch.src.read(M.INDEX_HEADER_BYTES + i * M.INDEX_RECORD_BYTES, M.INDEX_RECORD_BYTES)
  if not s or #s < M.INDEX_RECORD_BYTES then return nil end
  local rec = M.decodeRecord(s)
  if not M.comicValid(rec) then return nil end
  return rec
end

-- Binary search over the fixed-width records: ~12 seeks for the whole
-- archive. Returns the position, or -1. The archive has holes (404 is not a
-- comic), so find() asks the index, never the number range.
function M.archiveLowerBound(arch, num)
  local lo, hi = 0, arch.count
  while lo < hi do
    local mid = lo + (hi - lo) // 2
    local c = M.archiveAt(arch, mid)
    if not c then return -1 end
    if c.num < num then lo = mid + 1 else hi = mid end
  end
  return lo
end

function M.archiveFind(arch, num)
  local i = M.archiveLowerBound(arch, num)
  if i < 0 or i >= arch.count then return -1 end
  local c = M.archiveAt(arch, i)
  if not c then return -1 end
  return c.num == num and i or -1
end

-- --- strings (text.dat: title\0alt\0 per comic) ---------------------------

-- Copy the `which`'th NUL-terminated string starting at `offset`.
-- Reads in 128-byte blocks (an SD read costs the same for 1 or 128 bytes).
function M.readString(src, offset, which, cap)
  if not src or not src.read then return "" end
  local total = src.size()
  if offset >= total then return "" end
  local out, seen, pos = {}, 0, offset
  local wrote = 0
  while pos < total and wrote < cap do
    local want = 128
    if want > total - pos then want = total - pos end
    if want > cap - wrote then want = cap - wrote end
    local s = src.read(pos, want)
    if not s then break end
    for i = 1, #s do
      local b = s:byte(i)
      if b == 0 then
        if seen == which then return table.concat(out) end
        seen = seen + 1
      elseif seen == which and wrote < cap then
        out[#out + 1] = string.char(b)
        wrote = wrote + 1
      end
    end
    pos = pos + want
  end
  return table.concat(out)
end

function M.readTitle(src, c, cap) return M.readString(src, c.textOffset, 0, cap or 96) end

function M.readAlt(src, c, cap) return M.readString(src, c.textOffset, 1, cap or 1024) end

-- --- renditions -----------------------------------------------------------

-- Which image is on screen: the page rendition (Art) or the whole-comic
-- overview (Whole). Falls back to the page rendition when Whole is asked for
-- and there is none, so a caller out of step with the comic draws something
-- sensible rather than a zero-length image at offset zero.
function M.renditionFor(c, lens)
  local whole = lens == M.LENS_WHOLE and M.hasOverview(c)
  return {
    width = whole and c.overviewWidth or c.width,
    height = whole and c.overviewHeight or c.height,
    stride = whole and c.overviewStride or c.stride,
    offset = whole and c.overviewOffset or c.imageOffset,
    sideways = M.sideways(c),
  }
end

function M.renditionValid(r)
  return r ~= nil and r.width > 0 and r.height > 0 and
         r.stride >= math.ceil(r.width / 8) and r.stride > 0
end

function M.renditionBytes(r) return (r.stride or 0) * (r.height or 0) end

-- --- placing on the panel -------------------------------------------------

function M.maxScroll(r, viewportH)
  if viewportH <= 0 then return 0 end
  local over = r.height - viewportH
  return over > 0 and over or 0
end

function M.columnsIn(r, viewportW)
  if viewportW <= 0 then return 1 end
  local over = r.width - viewportW
  if over <= 0 then return 1 end
  -- Derived from the step the columns actually advance by (432), never from
  -- the viewport width: computing from the viewport was the bug that let the
  -- last column reveal a sliver.
  return 1 + math.ceil(over / M.COLUMN_STEP)
end

-- Where the image goes for a given position. Centred when it fits, pinned to
-- the scroll offset when it does not. Callers must derive their hit regions
-- and their map from what this returns.
function M.place(r, viewportW, viewportH, at)
  local p = { originX = 0, originY = 0, scrollX = 0, scrollY = 0, visibleW = 0, visibleH = 0, pans = false }
  if not M.renditionValid(r) or viewportW <= 0 or viewportH <= 0 then return p end

  local cols = M.columnsIn(r, viewportW)
  local column = at.column < 0 and 0 or (at.column >= cols and cols - 1 or at.column)
  p.scrollX = column * M.COLUMN_STEP
  local overX = r.width - viewportW
  if p.scrollX > overX then p.scrollX = overX < 0 and 0 or overX end
  p.visibleW = r.width - p.scrollX
  if p.visibleW > viewportW then p.visibleW = viewportW end
  p.originX = (viewportW - r.width) // 2
  if p.originX < 0 then p.originX = 0 end

  local maxS = M.maxScroll(r, viewportH)
  p.pans = maxS > 0 or cols > 1

  if maxS <= 0 then
    -- Fits down the page: centred, like a strip on newsprint.
    p.scrollY = 0
    p.visibleH = r.height
    p.originY = (viewportH - r.height) // 2
    if p.originY < 0 then p.originY = 0 end
    return p
  end
  p.scrollY = at.scrollY < 0 and 0 or (at.scrollY > maxS and maxS or at.scrollY)
  p.originY = 0
  p.visibleH = viewportH
  return p
end

-- --- walking in reading order ---------------------------------------------

local function firstColumn(r, viewportW) return r.sideways and M.columnsIn(r, viewportW) - 1 or 0 end
local function lastColumn(r, viewportW) return r.sideways and 0 or M.columnsIn(r, viewportW) - 1 end
local function columnAdvance(r) return r.sideways and -1 or 1 end

function M.startOf(r, viewportW)
  return { lens = M.LENS_ART, column = firstColumn(r, viewportW), row = 0, scrollY = 0 }
end

function M.endOf(r, viewportW, viewportH)
  local row = M.rowsIn(r, viewportH) - 1
  if row < 0 then row = 0 end
  return { lens = M.LENS_ART, column = lastColumn(r, viewportW), row = row,
           scrollY = M.evenTargetY(r, viewportH, row) }
end

function M.canStepBack(r, viewportW, viewportH, at)
  return at.row > 0 or at.column ~= firstColumn(r, viewportW)
end

function M.canStepForward(r, viewportW, viewportH, at)
  if at.column ~= lastColumn(r, viewportW) then return true end
  return at.row + 1 < M.rowsIn(r, viewportH)
end

-- Across the columns of the band left to right (right to left for a sideways
-- comic), then down to the next band and back to the band's starting side.
-- Step forward and step back are exact inverses: the offset is a pure
-- function of the panel index.
function M.stepForward(r, viewportW, viewportH, at, window)
  local nxt = { lens = at.lens, column = at.column, row = at.row, scrollY = at.scrollY }
  if at.column ~= lastColumn(r, viewportW) then
    nxt.column = at.column + columnAdvance(r)
    return nxt
  end
  if at.row + 1 < M.rowsIn(r, viewportH) then
    nxt.column = firstColumn(r, viewportW)
    nxt.row = at.row + 1
    nxt.scrollY = M.scrollYFor(r, viewportH, nxt.row, window)
  end
  return nxt
end

function M.stepBack(r, viewportW, viewportH, at, window)
  local prv = { lens = at.lens, column = at.column, row = at.row, scrollY = at.scrollY }
  if at.column ~= firstColumn(r, viewportW) then
    prv.column = at.column - columnAdvance(r)
    return prv
  end
  if at.row > 0 then
    prv.row = at.row - 1
    prv.scrollY = M.scrollYFor(r, viewportH, prv.row, window)
    prv.column = lastColumn(r, viewportW)
  end
  return prv
end

-- --- splitting the travel into panels -------------------------------------

-- The panels are counted up front and the travel divided EVENLY between
-- them: no fixed half-screen stride, so the last step is never a remainder.
function M.rowsIn(r, viewportH)
  local travel = M.maxScroll(r, viewportH)
  if travel <= 0 then return 1 end
  local stride = viewportH // 2
  if stride < 1 then stride = 1 end
  return 1 + math.ceil(travel / stride)
end

-- The even target for panel `row`: 0 at the top, exactly maxScroll at the
-- bottom (flush, never a remainder), evenly spaced in between.
function M.evenTargetY(r, viewportH, row)
  local rows = M.rowsIn(r, viewportH)
  local travel = M.maxScroll(r, viewportH)
  if rows <= 1 or travel <= 0 then return 0 end
  if row <= 0 then return 0 end
  if row >= rows - 1 then return travel end
  return (travel * row) // (rows - 1)
end

-- --- gaps in the artwork --------------------------------------------------

-- Ink pixels in [0, width): a set bit is ink, MSB first. Padding bits past
-- the width are masked off: the packer leaves them zero, but a pack built by
-- anything else may not, and one stray padding bit would hide gutters.
local NIBBLE = { 0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4 }

function M.rowInk(row, width)
  if not row or width <= 0 then return 0 end
  local ink = 0
  local full = width // 8
  for b = 1, full do
    local c = row:byte(b) or 0
    ink = ink + NIBBLE[(c & 0x0F) + 1] + NIBBLE[(c >> 4) + 1]
  end
  local rest = width % 8
  if rest ~= 0 then
    local c = row:byte(full + 1) or 0
    local masked = c & (0xFF << (8 - rest))
    ink = ink + NIBBLE[(masked & 0x0F) + 1] + NIBBLE[(masked >> 4) + 1]
  end
  return ink
end

-- A gap is a THRESHOLD, not emptiness: 20 of 30 sampled comics are drawn
-- inside a frame, so no row is ever empty. The floor does more work than the
-- percentage — a blank row's ink is a handful of vertical strokes, and that
-- count does not scale with width.
function M.rowIsGap(row, width)
  if not row or width <= 0 then return true end
  local budget = width * M.GAP_INK_PERCENT // 100
  if budget < M.GAP_INK_FLOOR then budget = M.GAP_INK_FLOOR end
  return M.rowInk(row, width) <= budget
end

-- The rows a step to panel `row` will consult. Sized from the same arithmetic
-- the window is derived from (the C++ once wrote 203 down as a constant for
-- a 480px viewport; the reader's viewport is 756, the real ask is 313, and
-- every pan silently fell back to a blind half-screen).
function M.gapWindowFor(r, viewportH, row)
  local tol = viewportH * M.SNAP_TOLERANCE_NUM // M.SNAP_TOLERANCE_DEN
  local target = M.evenTargetY(r, viewportH, row)
  local lo = target - tol + M.GUTTER_PAD - M.MIN_GUTTER_ROWS
  local hi = target + tol + M.GUTTER_PAD
  if lo < 0 then lo = 0 end
  if hi > r.height - 1 then hi = r.height - 1 end
  if hi < lo then return 0, 0 end
  return lo, hi - lo + 1
end

-- The largest window gapRowsFor() can ask for at a viewport, for sizing a
-- flag buffer.
function M.gapRowsFor(viewportH)
  local tol = viewportH * M.SNAP_TOLERANCE_NUM // M.SNAP_TOLERANCE_DEN
  return 2 * tol + M.GUTTER_PAD + M.MIN_GUTTER_ROWS + 1
end

-- The best landing row within tolerance of `target`, or `target` when the
-- window shows no gap worth stopping at. `window` is {firstRow=, flags={}}:
-- flags[i] is true when row firstRow+i-1 is a gap. A null window (or nil
-- flags) is legal and means no artwork available — the step falls back to
-- the plain even target, which is what should happen if the card hiccups.
local function snapToGap(r, viewportH, target, window)
  if not window or not window.flags or #window.flags <= 0 then return target end
  local tol = viewportH * M.SNAP_TOLERANCE_NUM // M.SNAP_TOLERANCE_DEN
  local best, bestDist, gapRun = target, -1, 0
  for i = 1, #window.flags do
    local y = window.firstRow + i - 1
    if y < 0 or y >= r.height then
      gapRun = 0
    elseif window.flags[i] then
      gapRun = gapRun + 1
    else
      -- y is the first inked row after `gapRun` gap rows; a run long enough
      -- offers a landing a little ABOVE the art that follows it.
      if gapRun >= M.MIN_GUTTER_ROWS then
        local landing = y - M.GUTTER_PAD
        if landing < 0 then landing = 0 end
        local d = landing > target and landing - target or target - landing
        if d <= tol and (bestDist < 0 or d < bestDist) then
          bestDist = d
          best = landing
        end
      end
      gapRun = 0
    end
  end
  return best
end

function M.scrollYFor(r, viewportH, row, window)
  local travel = M.maxScroll(r, viewportH)
  if travel <= 0 then return 0 end
  local rows = M.rowsIn(r, viewportH)
  if row <= 0 then return 0 end
  -- The last panel sits exactly flush; snapping it would demand one more tap
  -- to close a gap the reader can already see.
  if row >= rows - 1 then return travel end
  local target = M.evenTargetY(r, viewportH, row)
  local y = snapToGap(r, viewportH, target, window)
  if y < 0 then y = 0 end
  if y > travel then y = travel end
  return y
end

-- --- moving between the two views -----------------------------------------

-- The position in the other lens that shows the same part of the comic: the
-- two renditions are the same artwork at different scales, so the row under
-- the top of the screen maps by the ratio of their heights, rounded to the
-- nearest destination panel.
function M.mapAcross(c, viewportW, viewportH, at, to)
  if to == M.LENS_WHOLE and not M.hasOverview(c) then return at end
  local from = M.renditionFor(c, at.lens)
  local dest = M.renditionFor(c, to)
  if not M.renditionValid(from) or not M.renditionValid(dest) or from.height == 0 then return at end

  local out = M.startOf(dest, viewportW)
  out.lens = to
  local fromTravel = M.maxScroll(from, viewportH)
  local destTravel = M.maxScroll(dest, viewportH)
  local y = at.scrollY < 0 and 0 or (at.scrollY > fromTravel and fromTravel or at.scrollY)
  if destTravel > 0 then
    local scaled = math.floor((y * dest.height) / from.height)
    local rows = M.rowsIn(dest, viewportH)
    local row = 0
    if rows > 1 then row = math.floor((scaled * (rows - 1) + destTravel // 2) / destTravel) end
    if row < 0 then row = 0 end
    if row > rows - 1 then row = rows - 1 end
    out.row = row
    out.scrollY = M.evenTargetY(dest, viewportH, row)
  end
  return out
end

-- --- search ---------------------------------------------------------------

function M.foldChar(ch)
  if ch >= "A" and ch <= "Z" then return string.char(ch:byte() + 32) end
  return ch
end

-- Case-insensitive ASCII substring match, which is all the titles are (the
-- pack writer folds them the same way the fonts are subset).
function M.titleMatches(title, needle)
  if not title or not needle then return false end
  if needle == "" then return true end
  local t, n = title:lower(), needle:lower()
  return t:find(n, 1, true) ~= nil
end

-- --- the nine-case size rule (docs/apps/xkcd-pack-format.md) ---------------

-- The matrix, computed: each of the comic's two dimensions lands in one of
-- three bands against SHORT (480) and LONG (756), so there are nine cases
-- and no others. Returns posture ("portrait"|"turned") and what pans, in the
-- comic's own frame: "whole" (nothing), "across" (comic width), "down"
-- (comic height), "both".
--
-- Three rules produce the table:
--   1. Fewest panning axes wins: portrait axes = (W>480)+(H>756),
--      turned axes = (W>756)+(H>480). Six of the nine cells end here.
--   2. On a tie where the SAME axis pans either way, the axis that does not
--      pan goes on the smallest side that contains it, leaving the longer
--      side for the axis that does.
--   3. Anything still tied: fewest taps, then stay portrait.
function M.bandCase(w, h)
  local SHORT, LONG = M.PANEL_WIDTH, M.VIEWPORT_H
  local pA = (w > SHORT and 1 or 0) + (h > LONG and 1 or 0)
  local tA = (w > LONG and 1 or 0) + (h > SHORT and 1 or 0)
  local posture
  if pA < tA then
    posture = "portrait"
  elseif tA < pA then
    posture = "turned"
  else
    local wPansP, wPansT = w > SHORT, w > LONG
    local hPansP, hPansT = h > LONG, h > SHORT
    if wPansP and wPansT and not (hPansP or hPansT) then
      return "turned", "across"          -- cell: H fits the short side
    end
    if not (wPansP or wPansT) and hPansP and hPansT then
      return "portrait", "down"          -- cell: W fits the short side
    end
    -- Rule 3: fewest taps (columns*rows at the half-screen step), then
    -- stay portrait. Turning the device is a real cost and a tie means
    -- turning buys nothing.
    local function views(wside, hside)
      local c = w <= wside and 1 or 1 + math.ceil((w - wside) / (wside - M.COLUMN_OVERLAP))
      local r = h <= hside and 1 or 1 + math.ceil((h - hside) / (hside / 2))
      return c, r
    end
    local pc, pr = views(SHORT, LONG)
    local tc, tr = views(LONG, SHORT)
    if tc * tr < pc * pr then posture = "turned" else posture = "portrait" end
  end
  -- Name the pan in the comic's frame for the chosen posture. In turned,
  -- the width runs along the LONG side, so it pans when W > LONG.
  if posture == "portrait" then
    local a = w > SHORT and 1 or 0
    local d = h > LONG and 1 or 0
    if a + d == 0 then return "portrait", "whole" end
    if a + d == 2 then return "portrait", "both" end
    return "portrait", a == 1 and "across" or "down"
  end
  local a = w > LONG and 1 or 0
  local d = h > SHORT and 1 or 0
  if a + d == 0 then return "turned", "whole" end
  if a + d == 2 then return "turned", "both" end
  return "turned", a == 1 and "across" or "down"
end

-- The builder's production form of the same rule (build_pack.py layout(),
-- computed rather than tabulated): the scale aims at a target cap height
-- (over the comic's own measured lettering) and may fall to the floor --
-- about a sixth -- when that is what removes a panning axis.
-- `cap` is the comic's cap height in px (0/absent = unmeasurable lettering:
-- fit whole in whichever posture shows it larger). opts: {target_cap=12,
-- min_cap=10, max_upscale=3}. Returns posture, scale, pan.
local function posture(w, h, cap, across, down, o)
  local target, floor = o.target_cap / cap, o.min_cap / cap
  local s_w, s_h = across / w, down / h
  local fit = math.min(s_w, s_h)
  if fit >= floor then
    return 0, math.min(o.max_upscale, math.max(fit, floor)), "whole"
  end
  if s_w >= floor then return 1, math.min(o.max_upscale, s_w), "down" end
  if s_h >= floor then return 1, math.min(o.max_upscale, s_h), "across" end
  return 2, math.min(o.max_upscale, target), "both"
end

local function taps(w, h, s, across, down)
  local W = math.floor(w * s + 0.5)
  local H = math.floor(h * s + 0.5)
  local c = W <= across and 1 or 1 + math.ceil((W - across) / M.COLUMN_STEP)
  local r = H <= down and 1 or 1 + math.ceil((H - down) / (down / 2))
  return c * r
end

function M.layout(w, h, cap, opts)
  local o = opts or {}
  o.target_cap = o.target_cap or 12
  o.min_cap = o.min_cap or 10
  o.max_upscale = o.max_upscale or 3
  local SHORT, LONG = M.PANEL_WIDTH, M.VIEWPORT_H
  if not cap or cap <= 0 then
    local p = math.min(o.max_upscale, SHORT / w, LONG / h)
    local t = math.min(o.max_upscale, LONG / w, SHORT / h)
    if t > p then return "turned", t, "whole" end
    return "portrait", p, "whole"
  end
  local pa, ps, pw = posture(w, h, cap, SHORT, LONG, o)
  local ta, ts, tw = posture(w, h, cap, LONG, SHORT, o)
  if pa ~= ta then
    if pa < ta then return "portrait", ps, pw end
    return "turned", ts, tw
  end
  -- Tied, and the SAME axis pans either way: put the axis that does not pan
  -- on the smallest side that holds it.
  if pa == 1 and pw == tw then
    if pw == "across" then
      if math.floor(h * ts + 0.5) <= SHORT then return "turned", ts, tw end
      return "portrait", ps, pw
    end
    if math.floor(w * ps + 0.5) <= SHORT then return "portrait", ps, pw end
    return "turned", ts, tw
  end
  -- Still tied: fewest taps, then stay portrait.
  local pt = taps(w, h, ps, SHORT, LONG)
  local tt = taps(w, h, ts, LONG, SHORT)
  if pt <= tt then return "portrait", ps, pw end
  return "turned", ts, tw
end

return M