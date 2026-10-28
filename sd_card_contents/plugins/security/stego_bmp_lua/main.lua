-- BMP steganography (storage grant: Stego/). Appends a hidden message after the end of a BMP. Image viewers
-- stop at the pixel data, so the picture looks normal. Trailer = message | "STG1" | length (4 bytes, big-endian).
-- Hide: reads Stego/<name>.bmp, writes Stego/<name>-out.bmp with the message appended.
-- Read : looks for a trailer at the end of Stego/<name>.bmp and prints the message if present.
-- Not encrypted: put a passphrase-encrypted message in with sd_encrypt_lua first if the message matters.

local MAGIC = "STG1"
local MAX_MSG = 8192

local function txt(...) return input.text(...) or "" end

local function show(lines)
  gfx.clear(); local W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "BMP stego", "ui12", "bw")
  local y = 60
  for _, l in ipairs(lines) do gfx.text(14, y, l:sub(1, 52), "small"); y = y + 22 end
  gfx.text(14, H - 34, "Back = exit", "small")
  gfx.present()
  while input.wait() ~= "back" do end
end

local function is_bmp(data)
  return data:sub(1, 2) == "BM"
end

local function hide(path, outpath, msg)
  local data = fs.read(path)
  if not data then return "cannot read " .. path end
  if not is_bmp(data) then return "not a BMP file" end
  if #msg > MAX_MSG then return "message too long (max 8 KB)" end
  local trailer = msg .. MAGIC .. string.pack(">I4", #msg)
  local ok, err = fs.write(outpath, data .. trailer)
  if not ok then return "write failed: " .. tostring(err) end
  return "hidden " .. #msg .. " bytes in " .. outpath
end

local function read_hidden(path)
  local data = fs.read(path)
  if not data then return nil, "cannot read " .. path end
  if #data < 8 then return nil, "no hidden data" end
  local tail = data:sub(-8)
  if tail:sub(1, 4) ~= MAGIC then return nil, "no hidden data here" end
  local n = string.unpack(">I4", tail, 5)
  if n > MAX_MSG or n > #data - 8 then return nil, "bad trailer" end
  return data:sub(#data - 8 - n + 1, #data - 8)
end

local ok, err = pcall(function()
  local name = txt("BMP name in Stego/ (e.g. photo.bmp)", "", 60)
  if name == "" or name:find("[/\\]") or not name:lower():match("%.bmp$") then
    show({ "need a plain .bmp file name inside Stego/" }); return
  end
  local mode = txt("Mode: hide or read", "read", 8)
  local path = "sd:Stego/" .. name
  if mode == "hide" then
    local msg = txt("Message to hide", "", 512)
    if msg == "" then return end
    local outname = name:gsub("%.[Bb][Mm][Pp]$", "-out.bmp")
    show({ hide(path, "sd:Stego/" .. outname, msg) })
  else
    local msg, why = read_hidden(path)
    if msg then show({ "hidden message:", msg }) else show({ why }) end
  end
end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
