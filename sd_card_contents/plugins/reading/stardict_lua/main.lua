-- StarDict lookup (read grant: Dict/). Reads a StarDict dictionary: <name>.ifo, <name>.idx and either
-- <name>.dict or <name>.dict.dz (dictzip). Words are matched case-insensitively.
--
-- Index: the .idx is variable-length (word, NUL, 4-byte offset, 4-byte size, big-endian). A sparse index
-- (every 128th word, with its byte position) is built once per session and kept in RAM, then lookups
-- binary-search it and scan at most 128 entries. Dictzip: the gzip header's "RA" field gives chunk sizes;
-- each chunk is raw DEFLATE, decoded with zip.inflate, and cached as one chunk at a time.
-- Limits: definitions over 4 KB are truncated on screen.

local DIR = "sd:Dict/"
local STEP = 128
local CHUNK_CACHE_MAX = 2
local MAX_DEF = 4096
local LH = 24

local W, H = 0, 0
local dict = nil          -- { name, idx_path, dict_path, dz, chunk_len, chunk_off, sparse, count }

local function lower(s) return s:lower() end

local function txt(...) return input.text(...) or "" end

-- ---------- .ifo / paths ----------
local function list_dicts()
  local out = {}
  for _, f in ipairs(fs.list(DIR) or {}) do
    local base = f:match("^(.-)%.ifo$")
    if base then out[#out + 1] = base end
  end
  table.sort(out)
  return out
end

-- ---------- dictzip (gzip with RA extra field) ----------
local function parse_dictzip(path)
  local hdr = fs.read(path, 0, 12)
  if not hdr or hdr:byte(1) ~= 0x1f or hdr:byte(2) ~= 0x8b then return nil, "not gzip" end
  local flg = hdr:byte(4)
  if flg & 4 == 0 then return nil, "no dictzip extra field" end
  local xlen = string.unpack("<I2", hdr, 11)
  local extra = fs.read(path, 12, xlen)
  if not extra or #extra < xlen then return nil, "short extra field" end
  local pos = 1
  while pos + 3 <= #extra do
    local si1, si2 = extra:byte(pos), extra:byte(pos + 1)
    local slen = string.unpack("<I2", extra, pos + 2)
    if si1 == 82 and si2 == 65 then           -- "RA"
      local chlen, chcnt = string.unpack("<I2I2", extra, pos + 6)
      local sizes = {}
      for i = 0, chcnt - 1 do sizes[i + 1] = string.unpack("<I2", extra, pos + 10 + 2 * i) end
      local starts = { 12 + xlen + 1 }        -- 1-based file offset of the first compressed chunk
      for i = 2, chcnt do starts[i] = starts[i - 1] + sizes[i - 1] end
      return { chlen = chlen, sizes = sizes, starts = starts, count = chcnt }
    end
    pos = pos + 4 + slen
  end
  return nil, "no RA subfield"
end

local cache = {}          -- chunk index -> decoded string (small LRU by insertion)
local cache_order = {}

local function chunk_text(d, path, i)
  if cache[i] then return cache[i] end
  local raw = fs.read(path, d.starts[i + 1] - 1, d.sizes[i + 1])
  if not raw then return nil, "read failed" end
  local out, err = zip.inflate(raw)
  if not out then return nil, err end
  cache[i] = out
  cache_order[#cache_order + 1] = i
  if #cache_order > CHUNK_CACHE_MAX then cache[table.remove(cache_order, 1)] = nil end
  return out
end

local function read_dict(off, len)
  if dict.dz then
    local out = {}
    local pos, remaining = off, len
    while remaining > 0 do
      local i = pos // dict.dz.chlen
      local inner = pos % dict.dz.chlen
      local ct, err = chunk_text(dict.dz, dict.dict_path, i)
      if not ct then return nil, err end
      local take = math.min(remaining, #ct - inner)
      if take <= 0 then break end
      out[#out + 1] = ct:sub(inner + 1, inner + take)
      pos = pos + take; remaining = remaining - take
    end
    return table.concat(out)
  end
  return fs.read(dict.dict_path, off, len)
end

-- ---------- .idx sparse index ----------
local function read_idx_entries(fn, start)
  -- calls fn(word, offset, size, file_pos_of_entry) for each entry, from byte `start`; stops when fn returns false.
  -- buf is consumed through a cursor (bp) so no per-entry copying happens.
  local path = dict.idx_path
  local file_pos = start or 0      -- next byte of the file to fetch
  local buf, bp, base = "", 1, file_pos   -- base = file offset of buf[1]
  local function fill()
    local chunk = fs.read(path, file_pos, 8192)
    if not chunk or #chunk == 0 then return false end
    buf = buf:sub(bp) .. chunk
    base = base + bp - 1
    bp = 1
    file_pos = file_pos + #chunk
    return true
  end
  while true do
    local nul = buf:find("\0", bp, true)
    while not nul do
      if not fill() then return end
      nul = buf:find("\0", bp, true)
    end
    while #buf < nul + 8 do
      if not fill() then return end
      nul = buf:find("\0", bp, true)
    end
    local word = buf:sub(bp, nul - 1)
    local off, size = string.unpack(">I4I4", buf, nul + 1)
    if fn(word, off, size, base + bp - 1) == false then return end
    bp = nul + 9
  end
end

local function build_sparse()
  local sparse, n = {}, 0
  read_idx_entries(function(word, off, size, p)
    if n % STEP == 0 then sparse[#sparse + 1] = { word = lower(word), pos = p } end
    n = n + 1
  end)
  return sparse, n
end

-- find an exact (case-insensitive) match
local function find(q)
  q = lower(q)
  local sp = dict.sparse
  local lo, hi, start = 1, #sp, 1
  while lo <= hi do
    local mid = (lo + hi) // 2
    if sp[mid].word <= q then start = mid; lo = mid + 1 else hi = mid - 1 end
  end
  local start_pos = sp[start].pos
  local found
  local seen = 0
  read_idx_entries(function(word, off, size, p)
    seen = seen + 1
    if seen > STEP + 1 then return false end
    local lw = lower(word)
    if lw == q then found = { word = word, off = off, size = size }; return false end
    if lw > q then return false end
    return true
  end, start_pos)
  return found
end

-- ---------- UI ----------
local function show(lines)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "StarDict", "ui12", "bw")
  local y = 52
  for _, l in ipairs(lines) do
    if y > H - 50 then break end
    gfx.text(12, y, l:sub(1, 52), "small"); y = y + LH
  end
  gfx.text(14, H - 34, "Confirm = new word, Back = exit", "small")
  gfx.present()
end

local function open_dict(name)
  local ifo = fs.read(DIR .. name .. ".ifo") or ""
  local bookname = ifo:match("bookname=([^\r\n]*)") or name
  local dz_path, plain = DIR .. name .. ".dict.dz", DIR .. name .. ".dict"
  local d = { name = bookname, idx_path = DIR .. name .. ".idx" }
  if fs.exists(dz_path) then
    local info, err = parse_dictzip(dz_path)
    if not info then error(err) end
    d.dz = info; d.dict_path = dz_path
  elseif fs.exists(plain) then
    d.dict_path = plain
  else
    error("no .dict or .dict.dz for " .. name)
  end
  return d
end

local ok, err = pcall(function()
  W, H = gfx.size()
  local names = list_dicts()
  if #names == 0 then show({ "No StarDict (.ifo) in Dict/." }); while input.wait() ~= "back" do end; return end
  local name = names[1]
  if #names > 1 then
    name = txt("Dictionary: " .. table.concat(names, ", "), names[1], 40)
    if not name or name == "" then name = names[1] end
  end
  dict = open_dict(name)
  show({ "Indexing " .. dict.name .. " ..." })
  dict.sparse, dict.count = build_sparse()
  show({ dict.name, dict.count .. " words indexed", "", "Confirm to look up a word." })
  while true do
    local e = input.wait()
    if e == "back" then break end
    if e == "confirm" then
      local q = txt("Word", "", 40)
      if q ~= "" then
        local hit = find(q)
        if not hit then
          show({ "not found: " .. q })
        else
          local def, why = read_dict(hit.off, math.min(hit.size, MAX_DEF))
          local lines = { hit.word, "" }
          if def then
            for line in (def .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
          else
            lines[#lines + 1] = "cannot read definition: " .. tostring(why)
          end
          show(lines)
        end
      end
    end
  end
end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
