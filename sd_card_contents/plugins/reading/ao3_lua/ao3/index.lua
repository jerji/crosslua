-- AO3 library index: data:ao3.idx, one fixed-size record per AO3 EPUB.
-- All integers little-endian. Writes are in place (fs.write_at), so a power
-- cut can tear one record, never the whole file.
--
-- Header, 8 bytes:  "AO3Y" | version u8 (=1) | count u16 (slots used) | reserved u8
-- Record, 256 bytes, at offset 8 + slot*256:
--   hash u32     FNV-1a 32 of "sd:Books/AO3/<file>" (a renamed file is a new book)
--   size u32     file size when it was scraped (same size next scan = skip)
--   words u32
--   chapters u16
--   flags u8     bit0 = tombstone (file gone; slot is reused), bit1 = completed
--   rating c1    G / T / M / E / -
--   warning c1   B (creator chose not to use) / ! (warnings) / -
--   updated c10  YYYY-MM-DD or empty
--   title c64, author c32, fandom c24, name c96 (file name in Books/AO3), pad c13

local M = {}

local P = "data:ao3.idx"
local HDR = 8
local REC = 256
local MAX = 1000
local REC_FMT = "<I4I4I4I2Bc1c1c10c64c32c24c96c13"

-- FNV-1a, 32 bit. The 32-bit build wraps the same way as 64-bit; only the low
-- 32 bits matter, and string.pack("<I4") accepts either representation.
function M.fnv1a(s)
  local h = 0x811C9DC5
  for i = 1, #s do
    h = (h ~ s:byte(i)) * 0x01000193
  end
  return h & 0xFFFFFFFF
end

-- Longest prefix of s that is at most n bytes and ends on a whole UTF-8 char.
local function cut(s, n)
  s = s or ""
  if #s <= n then return s end
  s = s:sub(1, n)
  local i = #s
  while i > 0 and (s:byte(i) & 0xC0) == 0x80 do i = i - 1 end
  if i > 0 then
    local b = s:byte(i)
    local need = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC0 and 2) or 1
    if #s - i + 1 < need then s = s:sub(1, i - 1) end
  end
  return s
end

-- t: { hash, size, name, title, author, fandom, words, chapters, completed,
--      rating, warning, updated }
function M.pack(t)
  return string.pack(REC_FMT,
    t.hash,
    math.min(t.size or 0, 0x7FFFFFFF),
    math.min(t.words or 0, 0x7FFFFFFF),
    math.min(t.chapters or 0, 65535),
    t.completed and 2 or 0,
    t.rating or "-",
    t.warning or "-",
    cut(t.updated, 10),
    cut(t.title, 64),
    cut(t.author, 32),
    cut(t.fandom, 24),
    cut(t.name, 96),
    "")
end

local function header(count)
  return string.pack("<c4BI2B", "AO3Y", 1, count, 0)
end

-- Load the index state. Creates an empty index when none exists or the
-- header is not ours. Returns st or nil, err.
--   st.map[hash] = slot+1 (not seen this scan) or -(slot+1) (seen)
--   st.free      = tombstoned slots available for reuse
--   st.count     = slots used so far, st.live = live records
function M.open()
  local st = { map = {}, free = {}, count = 0, live = 0 }
  local hdr = fs.exists(P) and fs.read(P, 0, HDR) or nil
  local magic, ver, count
  if hdr and #hdr == HDR then magic, ver, count = string.unpack("<c4BI2", hdr) end
  if magic ~= "AO3Y" or ver ~= 1 or count > MAX then
    local ok, err = fs.write(P, header(0))
    if not ok then return nil, err or "cannot create data:ao3.idx" end
    return st
  end
  st.count = count
  local base = 0
  while base < count do
    local n = math.min(16, count - base)
    local data = fs.read(P, HDR + base * REC, n * REC) or ""
    for k = 0, n - 1 do
      local rec = data:sub(k * REC + 1, (k + 1) * REC)
      if #rec == REC then
        local hash, _, _, _, flags = string.unpack("<I4I4I4I2B", rec)
        local slot = base + k
        if (flags & 1) == 1 then
          st.free[#st.free + 1] = slot
        else
          st.map[hash] = slot + 1
          st.live = st.live + 1
        end
      end
    end
    base = base + n
  end
  return st
end

-- Slot of a live record for this hash, or nil.
function M.entry(st, hash)
  local v = st.map[hash]
  if v then return math.abs(v) - 1 end
  return nil
end

-- Stored file size of a slot, or nil.
function M.size_of(st, slot)
  local s = fs.read(P, HDR + slot * REC + 4, 4)
  if s and #s == 4 then return (string.unpack("<I4", s)) end
  return nil
end

-- Keep a record that is still on the card (it is not tombstoned by prune).
function M.seen(st, hash)
  local v = st.map[hash]
  if v and v > 0 then st.map[hash] = -v end
end

-- Write a packed record. slot = nil appends (or reuses a tombstone).
-- Returns slot, or nil, err.
function M.put(st, hash, slot, packed)
  local header_count
  if not slot then
    if #st.free > 0 then
      slot = table.remove(st.free)
    elseif st.count < MAX then
      slot = st.count
      header_count = st.count + 1
    else
      return nil, "index full (1000 books)"
    end
  end
  local ok, err = fs.write_at(P, HDR + slot * REC, packed)
  if not ok then return nil, err or "record write failed" end
  if header_count then
    ok, err = fs.write_at(P, 5, string.pack("<I2", header_count))
    if not ok then return nil, err or "header write failed" end
    st.count = header_count
  end
  if not st.map[hash] then st.live = st.live + 1 end
  st.map[hash] = -(slot + 1)
  return slot
end

-- Tombstone every live record that was not seen in this scan.
-- Returns the number removed. Call only after a complete scan.
function M.prune(st)
  local gone = {}
  for h, v in pairs(st.map) do
    if v > 0 then gone[#gone + 1] = h end
  end
  for _, h in ipairs(gone) do
    local slot = st.map[h] - 1
    local off = HDR + slot * REC + 14
    local b = fs.read(P, off, 1)
    if b and #b == 1 then
      fs.write_at(P, off, string.char(b:byte() | 1))
    end
    st.map[h] = nil
    st.free[#st.free + 1] = slot
    st.live = st.live - 1
  end
  return #gone
end

return M
