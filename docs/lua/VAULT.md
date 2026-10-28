# Vault and authenticator: how secrets are kept

`totp_lua` (the Authenticator app) stores one-time-code secrets in a PIN-protected vault. The pieces are reusable by any app:

| file | what it is |
|---|---|
| `crypto.device_key(label)` | firmware binding (`LuaCrypto.cpp`): a 32-byte key bound to THIS device and THIS app, derived from the device secret upstream keeps in NVS. See `API.md`. |
| `plugins/totp_lua/vault.lua` | a PIN/passphrase-protected file: `vault.create / unlock`, `v:save() / change_pin() / lock()` |
| `plugins/totp_lua/totp.lua` | RFC 6238 codes (SHA1, SHA256; 6-8 digits; any period), base32, `otpauth://` links |
| `plugins/totp_lua/main.lua` | the app: digit-wheel PIN, account list with live codes, add by typing, import, delete, change PIN, auto-lock |

`require` finds modules in the app folder first, then in `/.crosslua/lib/`: an app that wants the vault can copy `vault.lua` next to
its `main.lua`, or the file can be shared from `/.crosslua/lib/` once a second app needs it.

## What protects a vault

```
pre    = HMAC-SHA256(crypto.device_key("vault-v1"), PIN)
master = PBKDF2-SHA256(pre, salt, 20000 iterations)          (about 1 s on the X4)
enc    = HMAC-SHA256(master, "vault-enc\1")     mac = HMAC-SHA256(master, "vault-mac\1")
file   = "XVLT" | version | iterations | salt(16) | iv(16) | AES-256-CBC(enc, iv, data) | HMAC-SHA256(mac, everything before)
```

* The MAC covers the header and the ciphertext and is checked in constant time **before** anything is decrypted.
* A new random IV is used on every save; a new salt when the PIN changes.
* The file format was checked byte for byte against an independent implementation (python `hmac`/`hashlib` + `openssl`).

## What it does and does not defend against

| attacker | result |
|---|---|
| copies the SD card (lost or stolen card, a shared card) | cannot open or even guess at the vault: the key also needs the device secret, which never touches the card |
| has the card and the powered-off device, no flash dump | the same: the device secret sits in NVS flash, and the app asks for the PIN |
| has the card AND a dump of the device's flash | the device key is recovered, so **only the PIN remains**. A numeric PIN of 6 digits is about a million guesses, minutes on a PC: use a long passphrase (left on the first digit of the wheel types one) when this matters |
| has the unlocked device | sees the codes, like the owner |
| flash erase / firmware reinstall that wipes NVS | the device secret is regenerated and **every vault becomes unreadable**: keep the original recovery codes elsewhere |

Deliberately **not** done:

* **No attempt counter or lockout.** Wrong PINs can be retried without limit (each try costs about a second). A counter would have to
  live in NVS or on the card, where an attacker with a flash dump or a card copy simply resets or ignores it, so it would only
  protect against someone holding the live, unmodified device: and it would let a thief (or a bug) lock the owner out for good.
* No flash encryption (an upstream build option, not a Lua feature).
* The plaintext lives in Lua RAM while the vault is open: `v:lock()` removes the references and collects, but Lua strings
  cannot be wiped.

## The Authenticator app

* **First start:** read the notice, choose a PIN twice. The PIN pad is a digit wheel (up/down spin the digit, right locks it
  and moves on, left erases the last digit, confirm submits, 4 to 12 digits). Left on the very first digit opens the keyboard
  for a passphrase (up to 64 characters). A passphrase and the digits it spells are the same string.
* **Codes:** the list shows the selected account highlighted, the code in groups (`123 456`), and the seconds left. The screen
  redraws when the soonest visible code changes, not every second (e-ink).
* **Adding accounts:** Menu → *Add an account* (type name, issuer, base32 secret; lower case, spaces and dashes are fine), or
  Menu → *Import*: copy a text file with one `otpauth://totp/...` link per line to `/.crosslua/data/totp_lua/import.txt`
  with File Transfer. The file is deleted after the import (it holds secrets in plain text; deleting does not wipe the flash,
  so treat them as exposed if the card was ever shared). SHA1 and SHA256, 6 to 8 digits, periods 1 to 300 s; 50 accounts at most.
* **Clock:** the app needs a trusted clock (`time.now()`); without one it says so and shows no codes. The X4 has no RTC: connect
  to WiFi once and the system syncs the time.
* **Locking:** two minutes without a key press locks it again; *Lock now* does it on demand.
* **Permissions:** none (no radio, no SD outside its own data folder).

## Tests

* host: `totp.lua` against the RFC 6238 vectors and python-generated codes; `vault.lua` against the python/openssl reference file,
  plus tamper, wrong-PIN, device-binding and validation cases; `crypto.device_key` against python HMAC vectors; the real
  `main.lua` driven through every flow with scripted keys and typed text. Mutation runs: `host-tools/mut_devkey.py` (14),
  `mut_vault.py` (29), `mut_totp.py` (34), `mut_app.py` (33): every mutant turns the suite red.
* device: `lua_tests_lua/tests/vaulttest.lua` (uses its own copy of `vault.lua`, which the host suite checks is identical to the app's; run it twice: the first run creates a vault and
  deep-sleeps, the second must open it, which proves the key survives a reboot).
