-- Per-deck storage with O(1) memory: nothing about the deck's cards is held in Lua tables.
--   data:study/<slug>/index.bin   line offsets of the deck file ("IDX1", deckSize, count, then {offset u32, len u16}*)
--   data:study/<slug>/cards.bin   24-byte scheduling record per card ("CRD1", count, then records), updated IN PLACE
--   data:study/<slug>/meta.json   small settings/day counters
-- A 2000-card deck is ~12 KB of index + 48 KB of records on the SD card and a few hundred bytes of heap.
local deck = require("deck")
local sched = require("sched")

local M = {}
local IDX_HDR, IDX_ENT = 12, 6
local CRD_HDR, REC = 12, 24
local REC_FMT = "<BBHHi4i4Hff"   -- state step reps lapses due last dueMin s d  = 24 bytes

local function slug(name) return (name:lower():gsub("[^%w]+", "_")) end

local function pack_card(c)
  return REC_FMT:pack(c.state, c.step, c.reps, c.lapses, c.due, c.last, c.dueMin, c.s, c.d)
end
local function unpack_card(rec)
  local state, step, reps, lapses, due, last, dueMin, s, d = REC_FMT:unpack(rec)
  return { state = state, step = step, reps = reps, lapses = lapses, due = due, last = last, dueMin = dueMin, s = s, d = d }
end

-- Build the line-offset index by streaming the deck file in 4 KB ranges (never loads the whole deck).
local function build_index(path, idxPath)
  local size = fs.size(path)
  if not size then return nil, "cannot read deck" end
  assert(fs.write(idxPath, ("<c4I4I4"):pack("IDX1", size, 0)))
  local count, pos, carry, carryStart, batch = 0, 0, "", 0, {}
  local function flush() if #batch > 0 then assert(fs.append(idxPath, table.concat(batch))) batch = {} end end
  local function add(startOff, line)
    line = line:gsub("\r$", "")
    if line ~= "" and line:sub(1, 1) ~= "#" and line:find("\t", 1, true) then
      batch[#batch + 1] = ("<I4I2"):pack(startOff, math.min(#line, 4000))
      count = count + 1
      if #batch >= 64 then flush() end
    end
  end
  while pos < size do
    local chunk = fs.read(path, pos, 4096)
    if not chunk or chunk == "" then break end
    local data = carry .. chunk
    local base = pos - #carry
    local i = 1
    while true do
      local nl = data:find("\n", i, true)
      if not nl then break end
      add(base + i - 1, data:sub(i, nl - 1))
      i = nl + 1
    end
    carry = data:sub(i)
    pos = pos + #chunk
  end
  if carry ~= "" then add(size - #carry, carry) end
  flush()
  assert(fs.write_at(idxPath, 0, ("<c4I4I4"):pack("IDX1", size, count)))
  return count
end

local function read_index_header(idxPath)
  local h = fs.read(idxPath, 0, IDX_HDR)
  if not h or #h < IDX_HDR then return nil end
  local magic, size, count = ("<c4I4I4"):unpack(h)
  if magic ~= "IDX1" then return nil end
  return size, count
end

-- Create or extend cards.bin so it has `count` records (new cards appended; existing progress untouched).
local function ensure_cards(cardsPath, count)
  local have = 0
  local h = fs.read(cardsPath, 0, CRD_HDR)
  if h and #h == CRD_HDR then
    local magic, n = ("<c4I4I4"):unpack(h)
    if magic == "CRD1" then have = n end
  else
    assert(fs.write(cardsPath, ("<c4I4I4"):pack("CRD1", 0, 0)))
  end
  if count > have then
    local blank = pack_card(sched.new_card())
    local i = have
    while i < count do
      local n = math.min(40, count - i)
      assert(fs.append(cardsPath, blank:rep(n)))
      i = i + n
    end
    assert(fs.write_at(cardsPath, 0, ("<c4I4I4"):pack("CRD1", count, 0)))
  end
end

-- Open a deck {name=, path=}. Returns a handle or nil, err.
function M.open(d)
  local base = "data:study/" .. slug(d.name)
  local h = { name = d.name, path = d.path, idx = base .. "/index.bin", crd = base .. "/cards.bin", metaPath = base .. "/meta.json" }
  local size, count = read_index_header(h.idx)
  if size ~= fs.size(d.path) then
    local err
    count, err = build_index(d.path, h.idx)
    if not count then return nil, err end
  end
  if count > 65535 then return nil, "deck too large (max 65535 cards)" end
  h.count = count
  ensure_cards(h.crd, count)
  local m = fs.read(h.metaPath)
  h.meta = (m and json.decode(m)) or {}
  return h
end

function M.save_meta(h) return fs.write(h.metaPath, json.encode(h.meta)) end

-- Card text: question, answer, isCloze   (i is 1-based)
function M.text(h, i)
  local e = fs.read(h.idx, IDX_HDR + (i - 1) * IDX_ENT, IDX_ENT)
  if not e or #e < IDX_ENT then return nil end
  local off, len = ("<I4I2"):unpack(e)
  local line = fs.read(h.path, off, len)
  if not line then return nil end
  return deck.parse_line((line:gsub("\r$", "")))
end

function M.get(h, i)
  local rec = fs.read(h.crd, CRD_HDR + (i - 1) * REC, REC)
  return rec and #rec == REC and unpack_card(rec) or nil
end

function M.put(h, i, card)
  return fs.write_at(h.crd, CRD_HDR + (i - 1) * REC, pack_card(card))
end

-- Scan all records (in ranges) and return queues of card numbers.
--   learn: due learning cards (earliest first), review: the `reviewLimit` most overdue review cards, new: first `newLimit`
--   new cards, plus counts for the deck screen. Memory is bounded no matter how many cards are due: a review card is ONE
--   integer (due * 65536 + number, so sorting by it orders by due day then position) kept in a list that is trimmed as it grows.
local LEARN_CAP = 300
function M.scan(h, today, nowMin, newLimit, reviewLimit)
  local new, review, learnNum, learnAbs = {}, {}, {}, {}
  local counts = { new = 0, learn = 0, review = 0, total = h.count }
  local trimAt = reviewLimit * 2 + 16
  local nowAbs = today * 1440 + nowMin
  local CH = 64
  local i = 1
  while i <= h.count do
    local n = math.min(CH, h.count - i + 1)
    local blob = fs.read(h.crd, CRD_HDR + (i - 1) * REC, n * REC)
    if not blob then break end
    for k = 0, n - 1 do
      local state, _, _, _, due, _, dueMin = ("<BBHHi4i4H"):unpack(blob, k * REC + 1)
      if state == 0 then
        counts.new = counts.new + 1
        if #new < newLimit then new[#new + 1] = i + k end
      elseif state == 1 or state == 3 then
        local abs = due * 1440 + dueMin
        if abs <= nowAbs then
          counts.learn = counts.learn + 1
          if #learnNum < LEARN_CAP then learnNum[#learnNum + 1], learnAbs[#learnAbs + 1] = i + k, abs end
        end
      elseif state == 2 and due <= today then
        counts.review = counts.review + 1
        review[#review + 1] = due * 65536 + (i + k)
        if #review >= trimAt then
          table.sort(review)
          for j = #review, reviewLimit + 1, -1 do review[j] = nil end
        end
      end
    end
    i = i + n
  end
  table.sort(review)
  local r = {}
  for j = 1, math.min(#review, reviewLimit) do r[j] = review[j] & 0xFFFF end
  local order = {}
  for j = 1, #learnNum do order[j] = j end
  table.sort(order, function(a, b) return learnAbs[a] < learnAbs[b] end)
  local l = {}
  for j = 1, #order do l[j] = learnNum[order[j]] end
  counts.new = math.min(counts.new, newLimit)
  return { learn = l, review = r, new = new, counts = counts }
end

return M
