-- Trivia core: the on-card pack reader, per-question state, chooser, options
-- and answer matching. A faithful port of crossplay's TriviaCore.{h,cpp}; every
-- binary constant below is from docs/apps/trivia-pack-format.md.
--
-- Pure Lua (string/table/math/utf8 only, no gfx/input) so it runs under the
-- host lua5.4 with a stubbed `fs`. File access goes through the global `fs`
-- exactly like on the device: ranged reads, size, write_at. Nothing is held in
-- RAM except the pack header and one question at a time -- the C++ rule that
-- the index is never resident is kept.
--
-- Integer care: the device build wraps int32 and Lua's >> is zero-fill, so the
-- xorshift32 RNG below reproduces the C++ (uint32) sequence on both hosts.

local M = {}

local MAGIC = "XTRIVIA\0"
local MAX_RECORD = 448          -- kMaxRecordBytes: oversized records are REJECTED, never truncated
local MAX_ALTERNATES = 4
local MAX_DISTRACTORS = 6
local kOptions = 4              -- one right, three wrong
local DIFFICULTIES = 5

M.SEEN = 0x01
M.FLAGGED = 0x02
M.kOptions = kOptions
M.DIFFICULTIES = DIFFICULTIES

local US_CENTRIC = 0x80
local DIFF_MASK = 0x7F

-- 32-bit masks. On the int32 device 0xFFFFFFFF is -1 and x & -1 is identity
-- (the hardware already wraps); on the 64-bit host it trims to 32 bits. One
-- spelling works on both.
local M32 = 0xFFFFFFFF

-- Little-endian reads. Values in play (counts, byte offsets into the pack) are
-- far below 2^31, so the bitwise form is exact on both 32- and 64-bit builds.
local function u16(s, i) return s:byte(i) | (s:byte(i + 1) << 8) end
local function u32(s, i)
  local a, b, c, d = s:byte(i), s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
  return a | (b << 8) | (c << 16) | (d << 24)
end

-- Header: magic, version, flags, resv, count, then (count+1) u32 index entries.
-- Returns count, index_bytes, base (blob start). nil, reason on anything wrong.
function M.parse_header(raw)
  if not raw or #raw < 16 then return nil, "short header" end
  if raw:sub(1, 8) ~= MAGIC then return nil, "not a trivia pack" end
  if u16(raw, 9) ~= 1 then return nil, "unknown format version" end
  local count = u32(raw, 13)
  if count == 0 then return nil, "empty pack" end
  return count, (count + 1) * 4, 16 + (count + 1) * 4
end

-- One record. Returns {difficulty, us, year, altCount, wrongCount, clue,
-- answer, alts, wrongs, playableAsChoice} or nil when the record is torn or
-- oversized (rejected, never truncated -- same rule as the C++).
function M.parse_record(rec)
  local n = #rec
  if n < 5 then return nil, "short record" end
  local diffByte = rec:byte(1)
  local q = {
    difficulty = diffByte & DIFF_MASK,
    us = (diffByte & US_CENTRIC) ~= 0,
    year = u16(rec, 2),
    altCount = rec:byte(4),
    wrongCount = rec:byte(5),
  }
  local alt, wrong = q.altCount, q.wrongCount
  if alt > MAX_ALTERNATES or wrong > MAX_DISTRACTORS then return nil, "bad counts" end
  local fields = 2 + alt + wrong
  local pos = 6
  local out = {}
  for _ = 1, fields do
    if pos + 1 > n then return nil, "torn field" end
    local flen = u16(rec, pos)
    pos = pos + 2
    if pos + flen - 1 > n then return nil, "torn field" end
    out[#out + 1] = rec:sub(pos, pos + flen - 1)
    pos = pos + flen
  end
  q.clue, q.answer = out[1], out[2]
  q.alts, q.wrongs = {}, {}
  for i = 3, 2 + alt do q.alts[#q.alts + 1] = out[i] end
  for i = 3 + alt, fields do q.wrongs[#q.wrongs + 1] = out[i] end
  -- 3 stored distractors is the minimum for solo; fewer means quizmaster-only.
  q.playableAsChoice = wrong >= kOptions - 1
  return q
end

-- Open the pack file. Returns {path, count, base, size} or nil, err.
-- Validates header, index bounds and the blob sentinel; individual records are
-- validated when read (a torn record is skipped by the chooser, never fatal).
function M.open_pack(path)
  local size = fs.size(path)
  if not size then return nil, "no pack on the card" end
  local hdr = fs.read(path, 0, 16)
  if not hdr or #hdr < 16 then return nil, "cannot read the pack header" end
  local count, indexBytes, base = M.parse_header(hdr)
  if not count then return nil, base end
  if size < 16 + indexBytes then return nil, "pack index is torn" end
  local sentinel = fs.read(path, 16 + count * 4, 4)
  if not sentinel or #sentinel < 4 then return nil, "pack is missing its sentinel" end
  local blob = u32(sentinel, 1)
  if 16 + indexBytes + blob > size then return nil, "pack is torn at the tail" end
  return { path = path, count = count, base = base, size = size }
end

-- One question by index: two seek+reads (the index pair, then the record),
-- exactly like the C++ -- the index is never resident.
function M.read_question(pack, i)
  if i < 0 or i >= pack.count then return nil end
  local pair = fs.read(pack.path, 16 + i * 4, 8)
  if not pair or #pair < 8 then return nil end
  local start = u32(pair, 1)
  local finish = u32(pair, 5)
  if finish <= start then return nil end
  local len = finish - start
  if len > MAX_RECORD then return nil end -- reject, never truncate
  local rec = fs.read(pack.path, pack.base + start, len)
  if not rec or #rec ~= len then return nil end
  return M.parse_record(rec)
end

-- xorshift32, seedable and deterministic like C++ Rng (so a test can assert an
-- exact sequence). next() covers all 32 bits; on the device the int32 wrap and
-- Lua's zero-fill >> reproduce the C++ uint32 operations exactly.
function M.rng(seed)
  local s = seed or 1
  if s == 0 then s = 1 end
  return { s = s & M32 }
end

function M.rng_next(r)
  local x = r.s & M32
  x = (x ~ ((x << 13) & M32)) & M32
  x = (x ~ ((x >> 17) & M32)) & M32
  x = (x ~ ((x << 5) & M32)) & M32
  r.s = x
  return x
end

-- below(bound): UNSIGNED uint32 % bound. Lua's floor-mod of a negative int32
-- (sign bit set on the device) is not the same as (uint32) % bound, so the
-- 2^32 mod bound residue is added back -- fmod uses an exact power of two.
function M.rng_below(r, bound)
  if bound == 0 then return 0 end
  local x = M.rng_next(r)
  local res = x % bound
  if x < 0 then
    res = (res + math.fmod(2 ^ 32, bound)) % bound
  end
  return res
end

-- Copyright-safe ASCII case folding, same shape as C++ sameText().
function M.same_text(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
  for i = 1, #a do
    local ca, cb = a:byte(i), b:byte(i)
    if ca >= 65 and ca <= 90 then ca = ca + 32 end
    if cb >= 65 and cb <= 90 then cb = cb + 32 end
    if ca ~= cb then return false end
  end
  return true
end

-- Does `given` match the question? The answer or any alternate, case-insensitive.
-- Solo never calls this (options are tapped); it exists for the quizmaster
-- reading aloud and for tests.
function M.answer_matches(q, given)
  if M.same_text(q.answer, given) then return true end
  for _, a in ipairs(q.alts) do
    if M.same_text(a, given) then return true end
  end
  return false
end

-- pack.state: one byte per question at the question's own index, bit 0 SEEN,
-- bit 1 FLAGGED. Its length and the pack's count are the same fact written
-- twice: ANY disagreement means the pack was replaced and the file is rebuilt
-- from zero (a stale FLAGGED byte would hide a question nobody flagged).
function M.create_state(path, count)
  if not count or count == 0 then return false end
  fs.remove(path)
  local chunk = string.rep("\0", 4096)
  local first = math.min(4096, count)
  if not fs.write(path, chunk:sub(1, first)) then return false end
  local done = first
  while done < count do
    local n = math.min(4096, count - done)
    if not fs.append(path, chunk:sub(1, n)) then return false end
    done = done + n
  end
  return true
end

function M.open_state(pack, path)
  local size = fs.size(path)
  if size ~= pack.count then
    if not M.create_state(path, pack.count) then return nil, "cannot create pack.state" end
  end
  local st = { path = path, count = pack.count, seen = 0, flagged = 0, writable = true }
  -- Counts are scanned once at open, like C++ PackState::open: the front door
  -- wants the totals on every paint and a rescan per paint is a whole-file read.
  local at = 0
  while at < st.count do
    local n = math.min(4096, st.count - at)
    local chunk = fs.read(st.path, at, n)
    if not chunk or #chunk ~= n then return nil, "cannot read pack.state" end
    for i = 1, n do
      local b = chunk:byte(i)
      if b & M.SEEN ~= 0 then st.seen = st.seen + 1 end
      if b & M.FLAGGED ~= 0 then st.flagged = st.flagged + 1 end
    end
    at = at + n
  end
  return st
end

function M.state_flags(st, i)
  if i < 0 or i >= st.count then return 0 end
  local b = fs.read(st.path, i, 1)
  if not b or #b == 0 then return 0 end
  return b:byte(1)
end

function M.state_set(st, i, bit)
  if i < 0 or i >= st.count then return false end
  local cur = M.state_flags(st, i)
  local upd = cur | bit
  if upd == cur then return true end -- already set, no write
  if not fs.write_at(st.path, i, string.char(upd)) then
    st.writable = false
    return false
  end
  if bit & M.SEEN ~= 0 and cur & M.SEEN == 0 then st.seen = st.seen + 1 end
  if bit & M.FLAGGED ~= 0 and cur & M.FLAGGED == 0 then st.flagged = st.flagged + 1 end
  return true
end

function M.state_clear(st, i, bit)
  if i < 0 or i >= st.count then return false end
  local cur = M.state_flags(st, i)
  local upd = cur & (bit ~ 0xFF)
  if upd == cur then return true end
  if not fs.write_at(st.path, i, string.char(upd)) then
    st.writable = false
    return false
  end
  if bit & M.SEEN ~= 0 and cur & M.SEEN ~= 0 and st.seen > 0 then st.seen = st.seen - 1 end
  if bit & M.FLAGGED ~= 0 and cur & M.FLAGGED ~= 0 and st.flagged > 0 then st.flagged = st.flagged - 1 end
  return true
end

-- HIDE-all: clear every FLAGGED bit, chunked so a 50,000-question pack is a
-- dozen read+write pairs rather than a hundred thousand single-byte calls.
-- Returns how many were cleared.
function M.state_clear_all(st)
  local cleared = 0
  local at = 0
  while at < st.count do
    local n = math.min(4096, st.count - at)
    local chunk = fs.read(st.path, at, n)
    if not chunk or #chunk ~= n then break end
    local any = false
    for i = 1, n do
      if chunk:byte(i) & M.FLAGGED ~= 0 then any = true end
    end
    if any then
      local rep = {}
      for i = 1, n do
        local b = chunk:byte(i)
        if b & M.FLAGGED ~= 0 then
          b = b & (M.FLAGGED ~ 0xFF)
          cleared = cleared + 1
        end
        rep[i] = string.char(b)
      end
      if not fs.write_at(st.path, at, table.concat(rep)) then
        st.writable = false
        break
      end
    end
    at = at + n
  end
  st.flagged = st.flagged - cleared
  if st.flagged < 0 then st.flagged = 0 end
  return cleared
end

-- Picks the next question, preferring ones this device has not served.
-- A FRESH random start on every call (not a walked cursor: the pack is ordered
-- by game then category, so a cursor served runs of same-type clues), with a
-- forward scan for the filters -- flagged, seen (first pass), unreadable,
-- US-centric (unless allowed), missing options (solo), wrong difficulty.
-- Mirrors C++ Chooser::next exactly, including the two-pass prefer-unseen
-- behaviour that keeps play alive once the pack is exhausted.
function M.choose_next(pack, st, rng, opts)
  local count = pack.count
  local start = M.rng_below(rng, count)
  for pass = 0, 1 do
    for step = 0, count - 1 do
      local i = (start + step) % count
      local flags = M.state_flags(st, i)
      if flags & M.FLAGGED == 0 then
        if pass ~= 0 or flags & M.SEEN == 0 then
          local q = M.read_question(pack, i)
          if q then
            if opts.allowUsCentric or not q.us then
              if not opts.requireChoice or q.playableAsChoice then
                if opts.difficulty == 0 or q.difficulty == opts.difficulty then
                  return i, q
                end
              end
            end
          end
        end
      end
    end
  end
  return nil
end

-- Solo layout: the answer plus three of the (up to six) stored distractors,
-- drawn by partial Fisher-Yates so replaying a question gives different wrong
-- answers, then all four shuffled -- the stored order always has the answer
-- first, and without the final shuffle it would sit in slot one every time.
-- Returns {options={...}, correct} or nil for a quizmaster-only question.
function M.build_choices(q, rng)
  if not q or not q.playableAsChoice then return nil end
  local n = q.wrongCount
  local pool = {}
  for i = 1, n do pool[i] = i end
  for i = 1, kOptions - 1 do
    local j = i + M.rng_below(rng, n - i + 1)
    pool[i], pool[j] = pool[j], pool[i]
  end
  local opts = { q.answer, q.wrongs[pool[1]], q.wrongs[pool[2]], q.wrongs[pool[3]] }
  for i = kOptions, 2, -1 do
    local j = M.rng_below(rng, i) + 1
    opts[i], opts[j] = opts[j], opts[i]
  end
  local correct = 0
  for i = 1, kOptions do
    if M.same_text(opts[i], q.answer) then correct = i end
  end
  return { options = opts, correct = correct }
end

-- A round's tally. Deliberately not persisted: a bar game's score belongs to
-- the evening. Mirrors C++ Score.
function M.new_score()
  return { asked = 0, right = 0 }
end

function M.record_score(score, correct)
  score.asked = score.asked + 1
  if correct then score.right = score.right + 1 end
end

return M