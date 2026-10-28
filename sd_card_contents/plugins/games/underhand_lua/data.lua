-- underhand_lua/data.lua
-- Loads the game's two data files (gods.json, cards.json — the original
-- game's assets, verbatim, from the crossplay port's UnderhandOriginalData.h)
-- with a streaming JSON tokenizer fed by fs.read ranges, building a compact
-- card database: one whitespace-folded text pool, one packed 146-byte record
-- per card, and a 512-byte id->offset map. The raw JSON is never held whole.
local M = {}
local KON = 840

local RNAMES = { "relic", "money", "cultist", "food", "prisoner", "suspicion" }
local function rIdx(name)
  for i = 1, 6 do if RNAMES[i] == name then return i end end
end
local function isw(c) return c == 32 or c == 9 or c == 10 or c == 13 end
local function isblank(s)
  for k = 1, #s do if not isw(s:byte(k)) then return false end end
  return true
end
local function toI(v, isString)
  if isString then
    local n = tonumber(v)
    if not n then return 0 end
    return math.floor(n)
  end
  return v or 0
end
local function ure(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then return string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F)) end
  if cp < 0x10000 then
    return string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
  end
  return string.char(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
end

-- tokenizer: events receive (depth, keys); arrays add no object depth.
-- handlers as a fixed array: 1 onKey 2 onStr 3 onNum 4 onBool 5 unused
-- 6 onObjS 7 onObjE 8 onArrS 9 onArrE
local function tok(h)
  local buf, i = "", 1
  local stack, objDepth, keys = {}, 0, {}
  local expectKey, err = false, nil
  local function unescape(s)
    if not s:find("\\", 1, true) then return s end
    local out = {}
    local n, p = #s, 1
    while p <= n do
      local c = s:byte(p)
      if c == 92 and p < n then
        local e = s:byte(p + 1)
        if e == 117 then
          local cp = tonumber(s:sub(p + 2, p + 5), 16) or 0
          p = p + 6
          if cp >= 0xD800 and cp <= 0xDBFF then
            local lo = tonumber(s:sub(p + 2, p + 5), 16)
            if lo and lo >= 0xDC00 and lo <= 0xDFFF then
              cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
              p = p + 6
            end
          end
          out[#out + 1] = ure(cp)
        else
          local rep = { [34] = '"', [92] = "\\", [47] = "/", [110] = "\n", [116] = "\t", [114] = "\r", [98] = "\b", [102] = "\f" }
          out[#out + 1] = rep[e] or ("\\" .. string.char(e))
          p = p + 2
        end
      else
        out[#out + 1] = string.char(c)
        p = p + 1
      end
    end
    return table.concat(out)
  end
  local function drain()
    while true do
      if err then return end
      local a = buf:find("[^ \t\r\n]", i)
      if not a then i = #buf + 1 return end
      i = a
      local c, d = buf:byte(i), objDepth
      if c == 34 then
        local p, j = i
        while true do
          local q = buf:find('"', p + 1)
          if not q then return end
          local bs, k = 0, q - 1
          while k >= 1 and buf:byte(k) == 92 do bs = bs + 1; k = k - 1 end
          if bs % 2 == 0 then j = q break end
          p = q
        end
        local s = unescape(buf:sub(i + 1, j - 1))
        if expectKey then
          keys[d] = s
          h[1](d, keys)
        else
          h[2](s, d, keys)
        end
        i = j + 1
        expectKey = false
      elseif c == 123 then
        objDepth = objDepth + 1
        stack[#stack + 1] = "o"
        keys[objDepth] = ""
        h[6](objDepth, keys)
        i = i + 1
        expectKey = true
      elseif c == 125 then
        h[7](d, keys)
        stack[#stack] = nil
        objDepth = objDepth - 1
        i = i + 1
        expectKey = false
      elseif c == 91 then
        stack[#stack + 1] = "a"
        h[8](d, keys)
        i = i + 1
        expectKey = false
      elseif c == 93 then
        h[9](d)
        stack[#stack] = nil
        i = i + 1
        expectKey = false
      elseif c == 58 then
        i = i + 1
        expectKey = false
      elseif c == 44 then
        i = i + 1
        expectKey = stack[#stack] == "o"
      elseif c == 116 then
        if buf:sub(i, i + 3) == "true" then
          h[4](true, d, keys)
          i = i + 4
          expectKey = false
        else
          err = "malformed JSON"
        end
      elseif c == 102 then
        if buf:sub(i, i + 4) == "false" then
          h[4](false, d, keys)
          i = i + 5
          expectKey = false
        else
          err = "malformed JSON"
        end
      elseif c == 110 then
        if buf:sub(i, i + 3) == "null" then
          i = i + 4
          expectKey = false
        else
          err = "malformed JSON"
        end
      else
        local j = i
        while j <= #buf do
          local b8 = buf:byte(j)
          if not ((b8 >= 48 and b8 <= 57) or b8 == 46 or b8 == 101 or b8 == 69 or b8 == 43 or b8 == 45) then break end
          j = j + 1
        end
        if j > #buf then return end
        h[3](tonumber(buf:sub(i, j - 1)) or 0, d, keys)
        i = j
        expectKey = false
      end
    end
  end
  local function feed(chunk)
    if err then return end
    buf = buf .. chunk
    drain()
    if i > 4096 then
      buf = buf:sub(i)
      i = 1
    end
  end
  local function finish()
    drain()
    if err then return nil, err end
    if objDepth ~= 0 then return nil, "the file ends inside an object" end
    return true
  end
  return feed, finish
end

-- builder state
local pool, poolLen = "", 1
local err
local gods, godCount = {}, 0
local cardBuf, cardMap, cardCount = nil, nil, 0
local unlockGod, unlockCount, inArray = nil, 0, false
local cId, cWeight, cInitial, cRecurring = 0, 0, false, false
local cTitleOff, cTitleLen, cFlavorOff, cFlavorLen = 0, 0, 0, 0
local cOpts, cOptCount, cOptOpen = {}, 0, false

local function fail(why)
  if not err then err = why end
end

-- store with whitespace folding, like CardsReader::store; off 0 = absent
local function store(s)
  local n = #s
  local b = 1
  while b <= n and isw(s:byte(b)) do b = b + 1 end
  if b > n then return 0, 0 end
  local e = n
  while e >= b and isw(s:byte(e)) do e = e - 1 end
  local t, gap = {}, false
  for k = b, e do
    local c = s:byte(k)
    if isw(c) then
      gap = true
    else
      if gap then t[#t + 1] = " " end
      gap = false
      t[#t + 1] = string.char(c)
    end
  end
  local folded = table.concat(t)
  if poolLen + #folded + 1 > 60000 then
    fail("card text is larger than the text pool")
    return 0, 0
  end
  local off = poolLen
  pool = pool .. folded .. "\0"
  poolLen = poolLen + #folded + 1
  return off, #folded
end

local function godIndex(s)
  for gi = 1, godCount do
    local g = gods[gi]
    if g.nameLen == #s and pool:sub(g.nameOff, g.nameOff + g.nameLen - 1) == s then return gi end
  end
end

local function blankOption()
  return {
    blank = true, textOff = 0, textLen = 0, outcomeOff = 0, outcomeLen = 0,
    cost = { 0, 0, 0, 0, 0, 0 }, gain = { 0, 0, 0, 0, 0, 0 },
    randomCost = 0, swap = false, lose = false, win = -1,
    hasForesight = false, canDiscard = false,
    ids = {}, idCount = 0, copies = {}, copyCount = 0, copiesScalar = 0,
    lowerBound = 999, upperBound = 999, rollRepeats = false, copiesIsList = false,
    adds = {}, addCount = 0, rollCount = 0, rollLow = 0, rollHigh = 0,
  }
end

local function godValue(depth, isString, s, n, keys)
  if depth ~= 2 then return end
  if keys[1] == "names" and isString then
    local gi = tonumber(keys[2] or "")
    if not gi or gi < 0 or gi > 7 then return fail("god index outside 0..7") end
    local off, len = store(s)
    if not err then
      gods[gi + 1] = { nameOff = off, nameLen = len, unlock = {} }
      if gi + 1 > godCount then godCount = gi + 1 end
    end
  elseif keys[1] == "unlocked_cards" and inArray and not isString and unlockGod then
    if unlockCount >= 2 then return fail("a god unlocks more than two cards") end
    local id = toI(isString and s or n, isString)
    if id < 1 or id > 255 then return fail("an unlock is not a card id") end
    gods[unlockGod].unlock[unlockCount + 1] = id
    unlockCount = unlockCount + 1
  end
end

local function cardValue(depth, isString, s, n, keys)
  if err then return end
  if depth == 2 then
    local k = keys[2]
    if k == "title" then
      cTitleOff, cTitleLen = store(s)
    elseif k == "flavortext" then
      cFlavorOff, cFlavorLen = store(s)
    elseif k == "isinitial" then
      cInitial = toI(isString and s or n, isString) ~= 0
    elseif k == "isrecurring" then
      cRecurring = toI(isString and s or n, isString) ~= 0
    elseif k == "weight" then
      local w = toI(isString and s or n, isString)
      if w < 1 or w > 255 then return fail("card weight outside 1..255") end
      cWeight = w
    end
    return
  end
  if not cOptOpen then return end
  local o = cOpts[cOptCount]
  if depth == 3 then
    local k = keys[3]
    if k == "optiontext" then
      o.blank = isblank(s)
      o.textOff, o.textLen = store(s)
    elseif k == "outputtext" then
      o.outcomeOff, o.outcomeLen = store(s)
    elseif k == "cultistequalsprisoner" then
      o.swap = toI(isString and s or n, isString) ~= 0
    elseif k == "randomrequirements" then
      local rr = toI(isString and s or n, isString)
      if rr < 0 or rr > 255 then return fail("randomrequirements outside 0..255") end
      o.randomCost = rr
    elseif k == "islose" then
      o.lose = toI(isString and s or n, isString) ~= 0
    elseif k == "iswin" and isString and not isblank(s) then
      local g = godIndex(s)
      if not g then return fail("an option summons a god missing from the gods file") end
      o.win = g - 1
    end
    return
  end
  if depth ~= 4 or isString then return end
  local v = toI(isString and s or n, isString)
  local k3 = keys[3]
  if k3 == "requirements" or k3 == "rewards" then
    local r = rIdx(keys[4])
    if not r then return fail("unknown resource name") end
    if v < 0 or v > KON then return fail("resource count outside 0..840") end
    local t = (k3 == "requirements") and o.cost or o.gain
    t[r] = v
  elseif k3 == "foresight" then
    if keys[4] == "hasforesight" then o.hasForesight = v ~= 0
    elseif keys[4] == "candiscard" then o.canDiscard = v ~= 0 end
  elseif k3 == "shuffle" then
    local k4 = keys[4]
    if k4 == "lowerbound" then
      o.lowerBound = v
    elseif k4 == "upperbound" then
      o.upperBound = v
    elseif k4 == "allowsdupes" then
      o.rollRepeats = v ~= 0
    elseif k4 == "specificids" and inArray then
      if o.idCount >= 2 then return fail("an option adds more card kinds than kMaxAdds") end
      if v < 1 or v > 255 then return fail("a shuffled-in id is not a card id") end
      o.ids[o.idCount + 1] = v
      o.idCount = o.idCount + 1
    elseif k4 == "numcards" then
      if inArray then
        if o.copyCount >= 2 then return fail("an option adds more card kinds than kMaxAdds") end
        if v < 1 or v > 255 then return fail("a shuffle count outside 1..255") end
        o.copies[o.copyCount + 1] = v
        o.copyCount = o.copyCount + 1
      else
        o.copiesScalar = v
      end
    end
  end
end

local function endOption()
  cOptOpen = false
  if cOpts[cOptCount].blank then
    cOpts[cOptCount] = nil
    cOptCount = cOptCount - 1
    return
  end
  local o = cOpts[cOptCount]
  for r = 1, 6 do
    if o.gain[r] == KON then return fail("840 means nothing in a reward") end
  end
  for i = 1, o.idCount do
    local copies = o.copiesIsList and (o.copies[i] or -1) or o.copiesScalar
    if type(copies) ~= "number" or copies < 1 or copies > 255 then return fail("a shuffled-in card has no copy count") end
    o.adds[i] = { o.ids[i], copies }
  end
  o.addCount = o.idCount
  if o.copiesIsList and o.copyCount ~= o.idCount then return fail("shuffle ids and counts differ in length") end
  if o.lowerBound ~= 999 then
    if o.copiesIsList then return fail("a random shuffle has a list of counts") end
    if o.lowerBound < 1 or o.upperBound > 255 or o.lowerBound > o.upperBound then return fail("bad random shuffle bounds") end
    if o.copiesScalar < 1 or o.copiesScalar > 4 then return fail("bad random shuffle count") end
    if not o.rollRepeats and o.upperBound - o.lowerBound + 1 < o.copiesScalar then
      return fail("a random shuffle without repeats asks for more cards than its range holds")
    end
    o.rollCount = o.copiesScalar
    o.rollLow = o.lowerBound
    o.rollHigh = o.upperBound
  end
  if cOptCount > 3 then return fail("a card has more than three options") end
end

-- fixed 146-byte records: 11-byte header + 3 x 45-byte option blocks
local function packCard()
  local b = { cId, cWeight, cInitial and 1 or 0, cRecurring and 1 or 0 }
  local function u16(v) b[#b + 1] = v & 0xFF; b[#b + 1] = (v >> 8) & 0xFF end
  u16(cTitleOff); b[#b + 1] = cTitleLen
  u16(cFlavorOff); b[#b + 1] = cFlavorLen
  b[#b + 1] = cOptCount
  for k = 1, cOptCount do
    local o = cOpts[k] or blankOption()
    u16(o.textOff); b[#b + 1] = o.textLen
    u16(o.outcomeOff); b[#b + 1] = o.outcomeLen
    for r = 1, 6 do u16(o.cost[r]) end
    for r = 1, 6 do u16(o.gain[r]) end
    b[#b + 1] = o.randomCost
    b[#b + 1] = o.swap and 1 or 0
    b[#b + 1] = o.hasForesight and 1 or 0
    b[#b + 1] = (o.hasForesight and o.canDiscard) and 1 or 0
    b[#b + 1] = o.lose and 1 or 0
    b[#b + 1] = (o.win + 1) & 0xFF
    b[#b + 1] = o.addCount
    b[#b + 1] = (o.adds[1] and o.adds[1][1]) or 0
    b[#b + 1] = (o.adds[1] and o.adds[1][2]) or 0
    b[#b + 1] = (o.adds[2] and o.adds[2][1]) or 0
    b[#b + 1] = (o.adds[2] and o.adds[2][2]) or 0
    b[#b + 1] = o.rollCount
    b[#b + 1] = o.rollLow
    b[#b + 1] = o.rollHigh
    b[#b + 1] = o.rollRepeats and 1 or 0
  end
  local rec = string.char(table.unpack(b))
  local off = cardBuf and (#cardBuf + 1) or 1
  cardBuf = (cardBuf or "") .. rec
  local at = 2 * cId - 1
  cardMap = cardMap:sub(1, at - 1) .. string.char(off & 0xFF, (off >> 8) & 0xFF) .. cardMap:sub(at + 2)
end

local function endCard()
  if err then return end
  if cId == 0 then return fail("a card without an id") end
  if cWeight == 0 then return fail("a card without a weight") end
  if cTitleOff == 0 then return fail("a card without a title") end
  if cOptCount == 0 then return fail("a card without options") end
  if cardMap:byte(2 * cId - 1) ~= 0 or cardMap:byte(2 * cId) ~= 0 then return fail("two cards share an id") end
  if cardCount >= 128 then return fail("more cards than kMaxCards") end
  packCard()
  cardCount = cardCount + 1
end

-- card parse is driven by these events (gods file: same shape)
local function ev(godsFile)
  return {
    -- 1 onKey (keys live in the shared keys table)
    function(d, keys) end,
    -- 2 onStr
    function(s, d, keys)
      if godsFile then godValue(d, true, s, nil, keys) else cardValue(d, true, s, nil, keys) end
    end,
    -- 3 onNum
    function(n, d, keys)
      if godsFile then godValue(d, false, nil, n, keys) else cardValue(d, false, nil, n, keys) end
    end,
    -- 4 onBool
    function(b, d, keys)
      if godsFile then godValue(d, false, nil, b and 1 or 0, keys) else cardValue(d, false, nil, b and 1 or 0, keys) end
    end,
    function() end,
    -- 6 onObjS
    function(depth, keys)
      if godsFile then return end
      if depth == 2 then
        cId = toI(keys[1] or "", true)
        cWeight, cInitial, cRecurring = 0, false, false
        cTitleOff, cTitleLen, cFlavorOff, cFlavorLen = 0, 0, 0, 0
        cOpts, cOptCount, cOptOpen = {}, 0, false
      elseif depth == 3 and (keys[2] or ""):sub(1, 6) == "option" then
        cOptCount = cOptCount + 1
        cOpts[cOptCount] = blankOption()
        cOptOpen = true
      end
    end,
    -- 7 onObjE
    function(depth)
      if godsFile then return end
      if depth == 3 and cOptOpen then endOption() end
      if depth == 2 then endCard() end
    end,
    -- 8 onArrS
    function(depth, keys)
      inArray = true
      if godsFile then
        if depth == 2 and keys[1] == "unlocked_cards" then
          local gi = godIndex(keys[2] or "")
          if not gi then return fail("unlocked_cards names a god missing from names") end
          unlockGod, unlockCount = gi, 0
        end
      elseif depth == 4 and keys[4] == "numcards" and cOptOpen then
        cOpts[cOptCount].copiesIsList = true
      end
    end,
    -- 9 onArrE
    function()
      inArray = false
      if godsFile and unlockGod then
        if unlockCount ~= 2 then fail("a god does not unlock exactly two cards") end
        unlockGod = nil
      end
    end,
  }
end


local function readChunks(path, feed)
  local off = 0
  while true do
    local data, rerr = fs.read(path, off, 16384)
    if not data then return nil, rerr or "read failed" end
    if #data == 0 then break end
    feed(data)
    off = off + #data
    if #data < 16384 then break end
  end
  return true
end

local function finishChecks(cardsFile)
  if cardsFile then
    if cardCount == 0 then return fail("no cards") end
    for id = 1, 255 do
      local c = M.card(id)
      if c then
        for k = 1, c.optCount do
          local o = c.opts[k]
          for a = 1, o.addCount do
            if not M.card(o.adds[a][1]) then return fail("an option shuffles in a card that does not exist") end
          end
          if o.rollCount > 0 then
            for rid = o.rollLow, o.rollHigh do
              if not M.card(rid) then return fail("a random shuffle's range includes a card that does not exist") end
            end
          end
        end
      end
    end
    for gi = 1, godCount do
      for _, uid in ipairs(gods[gi].unlock) do
        if not M.card(uid) then return fail("a god unlocks a card that does not exist") end
      end
    end
  else
    if godCount == 0 then return fail("no gods") end
    for gi = 1, godCount do
      if gods[gi].nameLen == 0 then return fail("a gap in the god list") end
    end
  end
  return true
end

local loaded = false
function M.load()
  if loaded then return true end
  pool, poolLen = "", 1
  err = nil
  gods, godCount = {}, 0
  cardBuf, cardCount = nil, 0
  cardMap = string.rep("\0", 512)
  do
    local feed, finish = tok(ev(true))
    local ok = readChunks("sd:Underhand/gods.json", feed)
    if ok then local ferr = finish(); if ferr then ok = ferr end end
    if ok ~= true then return nil, err or ok end
  end
  if not finishChecks(false) then return nil, err end
  do
    local feed, finish = tok(ev(false))
    local ok = readChunks("sd:Underhand/cards.json", feed)
    if ok then local ferr = finish(); if ferr then ok = ferr end end
    if ok ~= true then return nil, err or ok end
  end
  if not finishChecks(true) then return nil, err end
  loaded = true
  collectgarbage()
  return true
end

-- record layout: 1 id, 2 weight, 3 initial, 4 recurring, 5-6 titleOff
-- (u16 LE), 7 titleLen, 8-9 flavorOff, 10 flavorLen, 11 optCount, then at
-- 11+(k-1)*45: +0 textOff, +2 textLen, +3 outcomeOff, +5 outcomeLen,
-- +6 cost u16x6, +18 gain u16x6, +30 randomCost, +31 swap, +32 foresight,
-- +33 discard, +34 lose, +35 win+1, +36 addCount, +37 addId1, +38 addCop1,
-- +39 addId2, +40 addCop2, +41 rollCount, +42 rollLow, +43 rollHigh,
-- +44 rollRepeats.
local function unpackAt(off, id)
  -- records are packed in id order; the end is the next present id's offset
  local b = cardBuf
  local function u16(p) return b:byte(p) | (b:byte(p + 1) << 8) end
  local c = {
    id = b:byte(off), weight = b:byte(off + 1),
    initial = b:byte(off + 2) ~= 0, recurring = b:byte(off + 3) ~= 0,
    titleOff = u16(off + 4), titleLen = b:byte(off + 6),
    flavorOff = u16(off + 7), flavorLen = b:byte(off + 9),
    optCount = b:byte(off + 10), opts = {},
  }
  for k = 1, 3 do
    if k <= c.optCount then
      local p = off + 11 + (k - 1) * 45
      local o = {
        textOff = u16(p), textLen = b:byte(p + 2),
        outcomeOff = u16(p + 3), outcomeLen = b:byte(p + 5),
        randomCost = b:byte(p + 30), swap = b:byte(p + 31) ~= 0,
        foresight = b:byte(p + 32) ~= 0, discard = b:byte(p + 33) ~= 0,
        lose = b:byte(p + 34) ~= 0, win = b:byte(p + 35) - 1,
        addCount = b:byte(p + 36), adds = {},
        rollCount = b:byte(p + 41), rollLow = b:byte(p + 42),
        rollHigh = b:byte(p + 43), rollRepeats = b:byte(p + 44) ~= 0,
      }
      o.cost = { u16(p + 6), u16(p + 8), u16(p + 10), u16(p + 12), u16(p + 14), u16(p + 16) }
      o.gain = { u16(p + 18), u16(p + 20), u16(p + 22), u16(p + 24), u16(p + 26), u16(p + 28) }
      for a = 1, o.addCount do
        o.adds[a] = { b:byte(p + 36 + 2 * a - 1), b:byte(p + 37 + 2 * a - 1) }
      end
      c.opts[k] = o
    else
      c.opts[k] = {
        textOff = 0, textLen = 0, outcomeOff = 0, outcomeLen = 0,
        cost = { 0, 0, 0, 0, 0, 0 }, gain = { 0, 0, 0, 0, 0, 0 },
        randomCost = 0, swap = false, foresight = false, discard = false,
        lose = false, win = -1, addCount = 0, adds = {},
        rollCount = 0, rollLow = 0, rollHigh = 0, rollRepeats = false,
      }
    end
  end
  return c
end

function M.card(id)
  if not cardMap or id < 1 or id > 255 then return nil end
  local off = cardMap:byte(2 * id - 1) | (cardMap:byte(2 * id) << 8)
  if off == 0 then return nil end
  return unpackAt(off, id)
end

function M.count() return cardCount end
function M.godCount() return godCount end
function M.god(i) return gods[i] end

function M.text(off, len)
  if not off or off == 0 or not len or len == 0 then return "" end
  return pool:sub(off, off + len - 1)
end

function M.godName(i)
  local g = gods[i]
  if not g then return "" end
  return pool:sub(g.nameOff, g.nameOff + g.nameLen - 1)
end

function M.rulesFit()
  if not loaded then return false end
  for _, id in ipairs({ 71, 29, 56, 2, 27 }) do
    if not M.card(id) then return false end
  end
  for id, need in pairs({ [85] = 3, [106] = 3, [79] = 5, [57] = 5 }) do
    if not M.card(id) then return false end
  end
  if godCount > 8 then return false end
  return true
end

M.KON = KON
return M