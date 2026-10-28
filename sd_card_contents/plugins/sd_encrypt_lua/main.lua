-- SD file encryption (storage grant: Secure/). Encrypts or decrypts one file at a time, in place as a new
-- file: <name> -> <name>.enc, and back. Format: "XENC" | salt(16) | iv(16) | AES-256-CBC(ciphertext) | HMAC-SHA256(32).
-- Keys: PBKDF2-SHA256(passphrase, salt, 20000) -> 64 bytes: first 32 = AES key, last 32 = MAC key.
-- MAC is checked (constant time) before decrypting. Files up to 24 KB (crypto.aes limit and Lua heap).
-- The original plaintext file is NOT deleted; remove it yourself once you have checked the .enc file.

local MAGIC = "XENC"
local MAX_BYTES = 24 * 1024
local ITER = 20000

local function txt(...) return input.text(...) or "" end

local function keys(pass, salt)
  local k = crypto.pbkdf2_sha256(pass, salt, ITER, 64)
  return k:sub(1, 32), k:sub(33, 64)
end

local function show(lines)
  gfx.clear(); local W, H = gfx.size()
  gfx.rect(0, 0, W, 40, true); gfx.text(14, 10, "SD file encrypt", "ui12", "bw")
  local y = 60
  for _, l in ipairs(lines) do gfx.text(14, y, l, "ui12"); y = y + 28 end
  gfx.text(14, H - 34, "Back = exit", "small")
  gfx.present()
  while input.wait() ~= "back" do end
end

local function encrypt(path)
  local data = fs.read(path)
  if not data then return "cannot read " .. path end
  if #data > MAX_BYTES then return "file too large (max 24 KB)" end
  local pass = txt("Passphrase", "", 64, "password")
  if #pass < 8 then return "passphrase must be 8+ characters" end
  local salt, iv = crypto.random(16), crypto.random(16)
  local ek, mk = keys(pass, salt)
  local ct = crypto.aes_cbc_encrypt(ek, iv, data)
  if not ct then return "encryption failed" end
  local body = MAGIC .. salt .. iv .. ct
  local out = body .. crypto.hmac_sha256(mk, body)
  local ok, err = fs.write(path .. ".enc", out)
  if not ok then return "write failed: " .. tostring(err) end
  return "wrote " .. path .. ".enc (" .. #out .. " bytes)"
end

local function decrypt(path)
  local blob = fs.read(path)
  if not blob or #blob < 4 + 16 + 16 + 16 + 32 or blob:sub(1, 4) ~= MAGIC then return "not an XENC file" end
  local pass = txt("Passphrase", "", 64, "password")
  local salt, iv = blob:sub(5, 20), blob:sub(21, 36)
  local body, mac = blob:sub(1, #blob - 32), blob:sub(#blob - 31)
  local ek, mk = keys(pass, salt)
  if not crypto.equal(crypto.hmac_sha256(mk, body), mac) then return "wrong passphrase or damaged file" end
  local plain = crypto.aes_cbc_decrypt(ek, iv, body:sub(37))
  if not plain then return "decryption failed" end
  local out = path:gsub("%.enc$", ".dec")
  local ok, err = fs.write(out, plain)
  if not ok then return "write failed: " .. tostring(err) end
  return "wrote " .. out
end

local ok, err = pcall(function()
  local name = txt("File in Secure/ (name only)", "", 60)
  if name == "" or name:find("[/\\]") then show({ "use a plain file name inside Secure/" }); return end
  local path = "sd:Secure/" .. name
  local mode = txt("Mode: encrypt or decrypt", "encrypt", 8)
  if mode == "decrypt" then show({ decrypt(path) }) else show({ encrypt(path) }) end
end)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
end
app.exit()
