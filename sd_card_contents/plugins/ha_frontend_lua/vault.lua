-- vault.lua — a PIN/passphrase-protected file for small secrets (TOTP seeds, API tokens).
--
--   local vault = require("vault")
--   local v, err = vault.create("data:vault.bin", pin, "initial text")   -- or vault.unlock(path, pin)
--   v.data = v.data .. "more"; v:save()                                  -- fresh IV each save, no key derivation
--   v:change_pin(new_pin); v:lock()
--
-- What protects the file (threat: someone copies the SD card):
--   * the key is derived from the PIN AND the device key (crypto.device_key: a per-app HMAC of the secret kept in the device's
--     NVS, never on the card), as  pre = HMAC-SHA256(device_key, pin);  master = PBKDF2-SHA256(pre, salt, iterations).
--     A copied card alone cannot be guessed at: the attacker also needs a flash dump of THIS device, and the vault will not open
--     on any other device. After a flash dump only the PIN stands in the way, so use a passphrase when it matters.
--   * AES-256-CBC + HMAC-SHA256 over header and ciphertext (encrypt-then-MAC, checked in constant time BEFORE decrypting).
--   * a new random IV on every save; a new salt when the PIN changes.
-- File format v1:  "XVLT" | version u8 | iterations u32 BE | salt 16 | iv 16 | ciphertext | mac 32.
-- NOT covered: the plaintext lives in Lua RAM while unlocked (Lua strings cannot be wiped: lock() drops the references and
-- collects); losing the device secret (a full flash erase) loses the vault, so keep the original recovery codes elsewhere.
local M = {}

local MAGIC, VERSION = "XVLT", 1
local DEFAULT_ITER, MIN_ITER, MAX_ITER = 20000, 1000, 20000  -- crypto.pbkdf2_sha256 caps the work at 20000 (about 1 s on the X4)
local SALT_LEN, IV_LEN, MAC_LEN, HEADER_LEN = 16, 16, 32, 41  -- 4 + 1 + 4 + 16 + 16
local MIN_PIN, MAX_PIN = 4, 64
local MAX_PLAINTEXT = 24 * 1024  -- crypto.aes_cbc_* take up to 32 KB; leave room for padding and the Lua heap
local KEY_LABEL = "vault-v1"

local function check_pin(pin)
  if type(pin) ~= "string" or #pin < MIN_PIN or #pin > MAX_PIN then
    return nil, "the PIN must be " .. MIN_PIN .. ".." .. MAX_PIN .. " characters"
  end
  return true
end

-- master key -> (encryption key, mac key), separated by label so neither can stand in for the other
local function derive(pin, salt, iter)
  local dk, err = crypto.device_key(KEY_LABEL)
  if not dk then return nil, err end
  local master, e2 = crypto.pbkdf2_sha256(crypto.hmac_sha256(dk, pin), salt, iter, 32)
  if not master then return nil, e2 end
  return crypto.hmac_sha256(master, "vault-enc\1"), crypto.hmac_sha256(master, "vault-mac\1")
end

local function seal(ek, mk, salt, iv, iter, plaintext)
  local ct, err = crypto.aes_cbc_encrypt(ek, iv, plaintext)
  if not ct then return nil, err end
  local body = MAGIC .. string.pack(">BI4", VERSION, iter) .. salt .. iv .. ct
  return body .. crypto.hmac_sha256(mk, body)
end

local V = {}
V.__index = V

-- v:save() -> true | nil, err. Re-encrypts v.data under the same keys with a fresh IV and replaces the file (fs.write is atomic).
function V:save()
  if not self.ek then return nil, "the vault is locked" end
  if type(self.data) ~= "string" or #self.data > MAX_PLAINTEXT then
    return nil, "the vault holds at most " .. (MAX_PLAINTEXT // 1024) .. " KB"
  end
  local blob, err = seal(self.ek, self.mk, self.salt, crypto.random(IV_LEN), self.iter, self.data)
  if not blob then return nil, err end
  return fs.write(self.path, blob)
end

-- v:change_pin(new_pin) -> true | nil, err. New salt, fresh derivation (about a second on the device), file rewritten.
function V:change_pin(new_pin)
  if not self.ek then return nil, "the vault is locked" end
  local ok, e = check_pin(new_pin)
  if not ok then return nil, e end
  local salt = crypto.random(SALT_LEN)
  local ek, mk = derive(new_pin, salt, self.iter)
  if not ek then return nil, mk end
  local old_ek, old_mk, old_salt = self.ek, self.mk, self.salt
  self.ek, self.mk, self.salt = ek, mk, salt
  local saved, err = self:save()
  if not saved then self.ek, self.mk, self.salt = old_ek, old_mk, old_salt; return nil, err end
  return true
end

-- v:lock() drops the keys and the text. Lua cannot wipe memory; this removes every reference and collects.
function V:lock()
  self.ek, self.mk, self.salt, self.data = nil, nil, nil, nil
  collectgarbage()
  return true
end

function V:is_locked() return self.ek == nil end

function M.exists(path) return fs.exists(path) end

-- vault.create(path, pin, plaintext [, iterations]) -> v | nil, err. Refuses to overwrite an existing vault.
function M.create(path, pin, plaintext, iter)
  local ok, e = check_pin(pin)
  if not ok then return nil, e end
  plaintext = plaintext or ""
  iter = iter or DEFAULT_ITER
  if type(plaintext) ~= "string" or #plaintext > MAX_PLAINTEXT then return nil, "the vault holds at most " .. (MAX_PLAINTEXT // 1024) .. " KB" end
  if math.type(iter) ~= "integer" or iter < MIN_ITER or iter > MAX_ITER then return nil, "iterations must be " .. MIN_ITER .. ".." .. MAX_ITER end
  if fs.exists(path) then return nil, "a vault already exists there" end
  local salt = crypto.random(SALT_LEN)
  local ek, mk = derive(pin, salt, iter)
  if not ek then return nil, mk end
  local v = setmetatable({path = path, ek = ek, mk = mk, salt = salt, iter = iter, data = plaintext}, V)
  local saved, err = v:save()
  if not saved then return nil, err end
  return v
end

-- vault.unlock(path, pin) -> v | nil, err. A wrong PIN and a damaged file look the same on purpose (the MAC cannot tell them apart).
function M.unlock(path, pin)
  if type(pin) ~= "string" then return nil, "wrong PIN or damaged vault" end
  local blob, err = fs.read(path)
  if not blob then return nil, "no vault" end
  if #blob < HEADER_LEN + 16 + MAC_LEN or blob:sub(1, 4) ~= MAGIC then return nil, "not a vault file" end
  local ver, iter = string.unpack(">BI4", blob, 5)
  if ver ~= VERSION then return nil, "unsupported vault version" end
  if iter < MIN_ITER or iter > MAX_ITER then return nil, "unsupported vault settings" end
  local salt, iv = blob:sub(10, 25), blob:sub(26, 41)
  local body, mac = blob:sub(1, #blob - MAC_LEN), blob:sub(#blob - MAC_LEN + 1)
  local ek, mk = derive(pin, salt, iter)
  if not ek then return nil, mk end
  if not crypto.equal(crypto.hmac_sha256(mk, body), mac) then return nil, "wrong PIN or damaged vault" end
  local plaintext, e2 = crypto.aes_cbc_decrypt(ek, iv, body:sub(HEADER_LEN + 1))
  if not plaintext then return nil, "wrong PIN or damaged vault" end
  return setmetatable({path = path, ek = ek, mk = mk, salt = salt, iter = iter, data = plaintext}, V)
end

-- exposed for the host tests: build a vault file from fixed salt/iv (compared against an independent implementation)
function M._seal_for_test(pin, salt, iv, iter, plaintext)
  local ek, mk = derive(pin, salt, iter)
  if not ek then return nil, mk end
  return seal(ek, mk, salt, iv, iter, plaintext)
end

M.MIN_PIN, M.MAX_PIN, M.MAX_PLAINTEXT = MIN_PIN, MAX_PIN, MAX_PLAINTEXT
return M
