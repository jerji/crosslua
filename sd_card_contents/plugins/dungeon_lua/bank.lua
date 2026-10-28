-- bank.lua - load the D&Diagrams dungeon bank. The bank is a data file
-- (bank.txt), converted from crossplay's DungeonPuzzles.h. Each line is
--   tier<TAB>size<TAB>rowclues(8)<TAB>colclues(8)<TAB>monsters<TAB>chests<TAB>walls<TAB>name
-- with the masks as 16 lowercase hex digits, bit r*8+c row-major from the
-- top-left, exactly the header's convention.
--
-- Lua integers are 32-bit on the device, so a 64-bit mask is kept as an
-- 8-byte binary string, byte 1 = the mask's least significant byte (row 0),
-- bit r*8+c, so bit-testing is byte(r+1), shift c. Nothing here
-- solves anything: the bank was verified host-side (every puzzle has exactly
-- one solution; the generator in crossplay refuses to emit the header
-- otherwise), so the device only ever compares against the stored solution.

local M = {}

-- 16 hex digits (MSB pair first, as written in DungeonPuzzles.h) -> 8 bytes,
-- least significant byte first.
local function hex2bytes(hex)
  local bytes = {}
  for i = 1, 8 do
    bytes[i] = string.char(tonumber(hex:sub(17 - i * 2, 18 - i * 2), 16))
  end
  return table.concat(bytes)
end
M.hex2bytes = hex2bytes

-- 8 bytes (LSB first) -> 16 hex digits in the header's order.
function M.bytes2hex(b)
  local out = {}
  for i = 8, 1, -1 do out[#out + 1] = string.format("%02x", b:byte(i)) end
  return table.concat(out)
end

-- text -> list of puzzles, or nil, err. P[1] is the tutorial (tier 0, 6x6).
-- Compact for the ~85 KB Lua heap: the 16 clue values ride in one 16-byte
-- string (bytes 1..8 row, 9..16 col; a clue fits in a byte), each mask is an
-- 8-byte string, and per-puzzle misc (glyph, fixed-cell mask) is derived on
-- demand rather than cached.
function M.parse(text)
  local list = {}
  for line in text:gmatch("[^\n]+") do
    local tier, size, rstr, cstr, mon, chest, walls, name =
      line:match("^(%d+)\t(%d+)\t([^\t]+)\t([^\t]+)\t(%x+)\t(%x+)\t(%x+)\t(.+)$")
    if not tier then return nil, "malformed bank line" end
    local row, col = {}, {}
    for v in rstr:gmatch("%d+") do row[#row + 1] = tonumber(v) end
    for v in cstr:gmatch("%d+") do col[#col + 1] = tonumber(v) end
    if #row ~= 8 or #col ~= 8 then return nil, "clue count != 8 in " .. name end
    list[#list + 1] = {
      tier = tonumber(tier), size = tonumber(size),
      clues = string.char(table.unpack(row)) .. string.char(table.unpack(col)),
      mon = hex2bytes(mon), chest = hex2bytes(chest), walls = hex2bytes(walls),
      name = name,
    }
  end
  return list
end

-- row clue i / col clue i (1..8): the packed clue string
function M.rowclue(p, i) return p.clues:byte(i) end
function M.colclue(p, i) return p.clues:byte(8 + i) end

-- Read Dungeon/bank.txt from the card (storage read grant on Dungeon; the bank is NOT shipped, see docs/apps/dungeon.md). A missing/empty file degrades to an
-- empty list (the app shows a message screen); a malformed file raises, which
-- the pcall wrapper in main.lua turns into the error screen.
function M.load()
  local text = fs.read("sd:Dungeon/bank.txt")
  if not text or text == "" then return {} end
  local list, err = M.parse(text)
  if not list then error("dungeon bank: " .. tostring(err)) end
  return list
end

return M