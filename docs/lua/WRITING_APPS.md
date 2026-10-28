# Writing a CrossLua app

A CrossLua app is **a folder on the SD card** with a `manifest.json` and (usually) `main.lua`. That's it.
No firmware change, no build, no device needed to write one — the runtime finds it at `Home → Plugins`.

Read this top-to-bottom once, then keep [`API.md`](API.md) open while you code. API.md is the contract;
if it's not in there, the function does not exist (and do not invent one).

## 1. The minimal app

```
sd_card_contents/plugins/mycoolapp/
├── manifest.json      {"title": "My Cool App", "description": "One line, shows in Plugins"}
└── main.lua           entry point
```

Copy the skeleton — it is the same shape every bundled app uses (`demo_lua` belongs to you as a template, 54 lines):

```lua
local function __main()
  gfx.clear()
  gfx.text(16, 16, "Hello!", "sans18", "b")
  gfx.present()                 -- push the frame to the e-ink display
  while input.wait() ~= "back" do end   -- hold until Back
  app.exit()                    -- always exit explicitly
end
local ok, err = pcall(__main)
if not ok then
  gfx.clear(); gfx.text(10, 10, "err: " .. tostring(err):sub(1, 60), "ui12", "b"); gfx.present()
  while input.wait() ~= "back" do end
  app.exit()
end
```

The `pcall` + error-screen pattern is mandatory: a crashing app must draw the error and wait for `back`,
never hard-freeze the device. Copy it verbatim.

## 2. manifest.json

```json
{"title": "Name", "description": "One line.",
 "permissions": ["library", "network"],
 "storage": {"read": ["Books"], "write": ["mycoolapp"]}}
```

- `permissions` — gate the sensitive APIs. Each one that your app actually calls fires a native
  approval dialog the user must accept. List *only* what you use. Known values: `library`, `network`,
  `listen`, `audio`, `microphone`, `hotspot`, `espnow`, `monitor`, `tx`, `bluetooth`, `plugin_install`.
- `storage` — SD-card grants for *specific folders* without the whole-card `library` permission
  (`read` = folders you may read, `write` = folders you may write). Prefer this over `library`.

## 3. The API, by namespace (see API.md for exact signatures)

| namespace | what it gives you | needs |
|---|---|---|
| `gfx` | clear, rect, text, image, icons, present | — |
| `input` | `input.wait()` blocking, `input.poll()` | — |
| `app` | `app.exit()`, `app.open_book()`, settings get/set | — |
| `system` | heap, battery, reboot, sleep, version, panic_info | — |
| `fs` | sandboxed read/write/list/stat, `app:` scope, zip | storage grant or `library` |
| `time` | wall clock, sleep, timers | — |
| `crypto` | sha256/md5, hmac, aes, device_key, crc32, random | — |
| `json` | encode/decode | — |
| `wifi`/`http` | connect, scan, GET/POST, `ca=` pinning, save_to | `network` |
| `net` | raw TCP client, UDP, `net.listen`, mDNS | `network` |
| `sd` | library scope, `sd.zip`, `app.open_book` | `library` |
| `epub` | book metadata (no opening) | `library` |
| `audio` | play WAV | `audio` |
| `mic` | record | `microphone` |
| `espnow` | raw peer frames | `network` + `espnow` |
| `wifi.monitor` | passive capture + PCAP writer | `network` + `monitor` |
| `wifi.tx` | frame injection | `network` + `tx` |
| `ble` | BLE keyboard host / raw scan | `bluetooth` |

`require` loads sibling files (`require("totp")` loads `totp.lua` next to `main.lua`). It is how you
split a big app into modules — bundled apps ship their own deps, nothing is auto-installed.

## 4. RAM is the real limit

~107 KB free heap total, 32-bit Lua, per-app budget ~85 KB. Rules from the README:

- A radio mode (WiFi STA, softAP, BLE) costs **50–60 KB** — the single biggest line item. Never open two.
- An app that ever used the radio **reboots to Home on exit** to defragment; `wifi.off()` frees *some* heap.
- TLS / `https` needs ~96 KB free and ~40 KB contiguous (largest block matters), and only ~5 KB of live Lua
  data per request. For plain text without auth, prefer `http://` + `wifi.connect{tls=false}`.
- Keep the heap happy: release big tables, call the radio only once, and watch `system.heap()`.

## 5. The input/view loop

There is no touchscreen. Seven buttons; `input.wait()`/`input.poll()` return `"up" "down" "left" "right"`
`"confirm" "back"`. Button *hold* is not exposed to Lua yet. Build navigation as a simple menu: a cursor
variable, up/down to move it, confirm to select, back to go up a level. `gfx.present()` after every change
(the display is e-ink: you redraw the frame, then present it — no partial/streaming draws).

## 6. Persist state

Use the app's sandbox — `fs` writing under the `app:` scope — and never assume a folder on the card is yours
unless the user granted it. Secrets belong in `vault.lua` (PIN → device-bound key → AES), never in plaintext
files; see [`VAULT.md`](VAULT.md).

## 7. Verify without a device

When you cannot touch physical hardware (the normal case here), verify in this order:

1. **Syntax** — `lua5.4 -p main.lua` (or `luac -p`) on every file. Zero warnings accepted.
2. **API conformance** — walk every call in your app against API.md. If a name isn't there, it doesn't exist.
   Rename your code; do not add the API.
3. **Logic** — small pure functions (json, crypto formats, string parsing) can run under the system `lua5.4`
   for a sanity check *only if* you stub out the device namespaces it can't see (`gfx`, `input`, etc.).
   Provide the stubs; do not leave them in the shipped app.
4. **Self-review checklist** (run it before committing):
   - [ ] `pcall` + error screen wrapper present
   - [ ] ends in `app.exit()`, or loops until `back` then exits
   - [ ] `manifest.json` lists only the permissions the code actually calls
   - [ ] no radio without a `permissions` entry; never two radios at once
   - [ ] no invented API names; every call is in API.md
   - [ ] no hardcoded host paths, IPs, or LAN addresses in shipped files
   - [ ] `main.lua` ≤ 64 KB (script limit); deps stay inside the app folder

A real on-device run happens later (the test hub under `sd_card_contents/plugins/lua_tests_lua`), or via
`tools/x4ctl.py`/`tools/x4push.py` — which you must **not** touch here; that is for the core session.

## 8. Commit discipline

One commit per app: `feat(app): <name>`. Touch only `sd_card_contents/plugins/<app>/` (and your app's
test if you add one). Never modify `src/`, `platformio.ini`, `test/lua_host/`, `tools/`, or the workflows —
those belong to the core session and are off-limits.