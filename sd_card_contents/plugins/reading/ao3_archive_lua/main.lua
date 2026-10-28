-- AO3 archive / restore. Archive packs every .epub in Books/AO3 into one zip in
-- Downloads; restore unpacks such a zip back into Books/AO3 (existing books are
-- skipped). The zip is written with method 0 (stored, no compression), so no
-- deflate is needed. Restore parses the zip itself, reading one header at a time.

local SRC = "sd:Books/AO3"
local DIR = "sd:Downloads"
local OUT = DIR .. "/ao3-archive.zip"
local CD_TMP = "data:ao3-cd.tmp"   -- central directory staging, keeps RAM flat
local CHUNK = 16384
local LH = 24

local W, H = 0, 0

local function clip(s, n) return #s > n and s:sub(1, n) or s end

local function screen(title, lines, footer)
  gfx.clear(); W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, clip(title, 30), "ui12", "bw")
  local y = 56
  for _, l in ipairs(lines) do
    gfx.text(16, y, clip(l, 46), "small"); y = y + LH
  end
  gfx.text(14, H - 34, footer or "", "small")
  gfx.present()
end

local function wait_back()
  while input.wait() ~= "back" do end
end

local function menu(title, items, footer)
  local cur = 1
  while true do
    gfx.clear(); W, H = gfx.size()
    gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, clip(title, 30), "ui12", "bw")
    if #items == 0 then gfx.text(14, 60, "(nothing here)", "small") end
    local y = 56
    for i, it in ipairs(items) do
      if y > H - 70 then break end
      if i == cur then
        gfx.rect(10, y - 4, W - 20, LH + 4, true); gfx.text(16, y, clip(it, 44), "small", "w")
      else
        gfx.text(16, y, clip(it, 44), "small")
      end
      y = y + LH
    end
    gfx.text(14, H - 34, footer, "small")
    gfx.present()
    local e = input.wait()
    if e == "up" then cur = cur > 1 and cur - 1 or math.max(1, #items)
    elseif e == "down" then cur = cur < #items and cur + 1 or 1
    elseif e == "confirm" and #items > 0 then return cur
    elseif e == "back" then return nil end
  end
end

-- CRC-32 of a whole file, read in chunks. Returns the integer value.
local function crc_of(path, size)
  local c = crypto.crc32("")
  local off = 0
  while off < size do
    local chunk = fs.read(path, off, CHUNK)
    if not chunk or #chunk == 0 then return nil, "short read" end
    c = crypto.crc32(chunk, c)
    off = off + #chunk
  end
  return (string.unpack(">I4", c))
end

-- Archive: stream each .epub as a stored entry, staging central-directory records in data:.
local function archive(progress)
  local total = nil
  local probe, t = fs.list(SRC, { limit = 1 })
  if not probe then return nil, "no Books/AO3 folder on the card" end
  total = t or 0

  if not fs.write(OUT, "") then return nil, "cannot write " .. OUT end
  fs.write(CD_TMP, "")

  local pos, count, bytes = 0, 0, 0
  local o = 0
  while o < total do
    local names = fs.list(SRC, { offset = o, limit = 64 })
    if not names or #names == 0 then break end
    for _, n in ipairs(names) do
      if n:lower():match("%.epub$") then
        local path = SRC .. "/" .. n
        local size = fs.size(path)
        if not size then return nil, "cannot stat " .. n end
        if size > 0xFFFFFFFF or #n > 255 then return nil, "unsupported entry " .. n end
        progress(string.format("%d  %s", count + 1, n))
        local crc, err = crc_of(path, size)
        if not crc then return nil, n .. ": " .. tostring(err) end

        local loff = pos
        local hdr = string.pack("<I4I2I2I2I2I2I4I4I4I2I2",
          0x04034b50, 10, 0, 0, 0, 0x21, crc, size, size, #n, 0) .. n
        if not fs.append(OUT, hdr) then return nil, "write failed" end
        local done = 0
        while done < size do
          local chunk = fs.read(path, done, CHUNK)
          if not chunk or #chunk == 0 then return nil, "read failed: " .. n end
          if not fs.append(OUT, chunk) then return nil, "write failed (card full?)" end
          done = done + #chunk
        end
        local cd = string.pack("<I4I2I2I2I2I2I2I4I4I4I2I2I2I2I2I4I4",
          0x02014b50, 20, 10, 0, 0, 0, 0x21, crc, size, size, #n, 0, 0, 0, 0, 0, loff) .. n
        fs.append(CD_TMP, cd)
        pos = pos + #hdr + size
        bytes = bytes + size
        count = count + 1
        if count > 65535 then return nil, "too many books for one zip" end
      end
    end
    o = o + 64
  end
  if count == 0 then return nil, "no .epub files in Books/AO3" end

  -- Copy the staged central directory after the entries, then the end record.
  local cdstart, cdsize = pos, 0
  local cdlen = fs.size(CD_TMP) or 0
  local p = 0
  while p < cdlen do
    local chunk = fs.read(CD_TMP, p, CHUNK)
    if not chunk or #chunk == 0 then return nil, "central directory read failed" end
    if not fs.append(OUT, chunk) then return nil, "write failed (card full?)" end
    p = p + #chunk
  end
  cdsize = cdlen
  fs.append(OUT, string.pack("<I4I2I2I2I2I4I4I2",
    0x06054b50, 0, 0, count, count, cdsize, cdstart, 0))
  fs.remove(CD_TMP)
  return count, bytes
end

local function le_read(path, off, len)
  local s, err = fs.read(path, off, len)
  if not s or #s < len then return nil, err or "archive truncated" end
  return s
end

-- Only plain book names: no folders, no dots-before-name tricks.
local function safe_name(n)
  return n:match("^[%w%._%-%(%) %[%]]+%.[eE][pP][uU][bB]$") ~= nil and not n:find("%.%.")
end

local function restore(zpath, progress)
  local size = fs.size(zpath)
  if not size or size < 22 then return nil, "not a zip archive" end
  local e, err = le_read(zpath, size - 22, 22)
  if not e then return nil, err end
  local sig, _, _, n, _, cdsize, cdoff, clen = string.unpack("<I4I2I2I2I2I4I4I2", e)
  if sig ~= 0x06054b50 or clen ~= 0 then return nil, "not a zip written by this app" end
  if n == 0 then return nil, "archive is empty" end

  local made, skipped, failed, refused = 0, 0, 0, 0
  local cp = cdoff
  for i = 1, n do
    local h, herr = le_read(zpath, cp, 46)
    if not h then return nil, herr end
    local hsig, method, crc, csize, nlen, elen, clen2, loff
    hsig, _, _, _, method, _, _, crc, csize, _, nlen, elen, clen2, _, _, _, loff =
      string.unpack("<I4I2I2I2I2I2I2I4I4I4I2I2I2I2I2I4I4", h)
    if hsig ~= 0x02014b50 then return nil, "bad central directory entry " .. i end
    local name, nerr = le_read(zpath, cp + 46, nlen)
    if not name then return nil, nerr end
    cp = cp + 46 + nlen + elen + clen2

    if method ~= 0 then
      refused = refused + 1
    elseif not safe_name(name) then
      refused = refused + 1
    else
      local dest = SRC .. "/" .. name
      if fs.exists(dest) then
        skipped = skipped + 1
      else
        progress(string.format("%d/%d  %s", i, n, name))
        local lh, lerr = le_read(zpath, loff, 30)
        if not lh then return nil, lerr end
        if string.unpack("<I4", lh) ~= 0x04034b50 then return nil, "bad local header " .. name end
        local lnlen, lelen = string.unpack("<I2I2", lh, 27)
        local dataoff = loff + 30 + lnlen + lelen
        local good = fs.write(dest, "") and true or false
        local c = crypto.crc32("")
        local done = 0
        while good and done < csize do
          local chunk = fs.read(zpath, dataoff + done, math.min(CHUNK, csize - done))
          if not chunk or #chunk == 0 or not fs.append(dest, chunk) then good = false; break end
          c = crypto.crc32(chunk, c)
          done = done + #chunk
        end
        if good and (string.unpack(">I4", c)) == crc then
          made = made + 1
        else
          fs.remove(dest)
          failed = failed + 1
        end
      end
    end
  end
  return made, skipped, failed, refused
end

local function main()
  W, H = gfx.size()
  while true do
    local pick = menu("AO3 Archive", {
      "Archive Books/AO3 to Downloads",
      "Restore a zip from Downloads",
      "Exit",
    }, "Confirm = choose, Back = exit")
    if not pick or pick == 3 then return end

    if pick == 1 then
      local count, bytes = archive(function(msg) screen("Archiving", { msg }, "") end)
      if not count then
        screen("Archive failed", { bytes }, "Back = menu"); wait_back()
      else
        screen("Archive done", {
          string.format("%d books, %d bytes of EPUB", count, bytes),
          OUT,
          "stored zip, no compression",
        }, "Back = menu"); wait_back()
      end
    else
      local zips = {}
      for _, f in ipairs(fs.list(DIR) or {}) do
        if f:lower():match("%.zip$") then zips[#zips + 1] = f end
      end
      local ci = menu("Restore from Downloads", zips, "Confirm = restore, Back = menu")
      if ci then
        local made, skipped, failed, refused = restore(DIR .. "/" .. zips[ci],
          function(msg) screen("Restoring", { msg }, "") end)
        if not made then
          screen("Restore failed", { skipped }, "Back = menu"); wait_back()
        else
          screen("Restore done", {
            string.format("restored %d, skipped %d (already there)", made, skipped),
            string.format("failed %d, refused %d (compressed or bad name)", failed, refused),
          }, "Back = menu"); wait_back()
        end
      end
    end
  end
end

local ok, err = pcall(main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  wait_back()
end
app.exit()
