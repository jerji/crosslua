# Grimoire spells — a Grimoire compatibility shim for CrossLua

Runs unmodified **Grimoire** spells (the other Lua runtime for the X4) on the **CrossLua** runtime as an ordinary CrossLua app.
A spell is a single `.lua` file the Grimoire launcher reads from `/spells` on
the SD card; this plugin does the same — it lists `sd:spells/*.lua` and runs
the file through a shim that rebuilds Grimoire's global API (`display`,
`input`, `fs`, `zip`, `time`, `system`, `wifi`, `ble`, `hid`, `net`, `image`,
Grimoire-style `require`) on top of the CrossLua API (`gfx`, `input`, `fs`,
`zip`, `time`, `wifi`, `http`, ...).

## Installing on a device

Copy the `grimoire_lua` folder into `/plugins` (enable Settings → Connectivity
→ Plugins first). The manifest requests `library` (to read `sd:spells/`) and
`network`. The launcher shows every top-level `*.lua` in `sd:spells/`
(skipping subfolders). Up/Down move, Confirm runs, Back exits. A spell that
errors shows the spell name + wrapped message on screen; any key returns to
the list — the launcher never crashes. "Returning from the spell" is exiting,
exactly like Grimoire.

Spells that use `require("lib.wifi")` read their network from
`/os/config.lua` on the SD card (the same file Grimoire's config writes). If
your card already has one from Grimoire, CrossLua just works with it (`sd:`
is read-only on CrossLua, but `/os/config.lua` is a read).

## How the shim maps the APIs

| Grimoire | CrossLua | Notes |
|---|---|---|
| `display.clear/pixel/line/text/refresh` | `gfx.clear/pixel/line/text/present` | `black=true` = black pixel, same on both. `text` size 1..4 → `small`,`ui`,`sans14`,`sans18`; `black=false` → white-text flag `w` |
| `display.rect(x,y,w,h,black,filled)` | `gfx.rect(x,y,w,h,filled,black)` | **argument order swaps** (Grimoire puts `black` 5th, CrossLua 6th) |
| `display.refreshWindow(x,y,w,h,full)` | `gfx.present(full and "full" or "fast")` | CrossLua has no partial-region refresh; approximated |
| `display.width()/height()` | `gfx.size()` | returns the live size (480×800 portrait on the X4) — spells hardcoding 800×480 look off |
| `display.bitmap(x,y,w,h,data,black)` | per-pixel `gfx.pixel` loop | Adafruit_GFX packed format, MSB-first, rows padded to whole bytes, mask semantics (bit 1 draws, bit 0 leaves alone). Slow on device; fine for small images |
| `input.poll()` | `input.wait(30)` | yields to the firmware, then the event is held as *pending* for exactly one poll cycle |
| `input.pressed/released(name)` | pending == mapped event | edge semantics for one poll cycle |
| `input.down(name)` | — | **always false** (CrossLua delivers releases only; no hold state) |
| button `volup`/`voldown` | `up`/`down` | CrossLua's only extra buttons |
| button `power` | — | never fires (hold-Power shuts down at firmware level) |
| `fs.read/exists` of `/abs` | `data:` copy first, then `sd:` | write-redirect shadowing |
| `fs.write/append/mkdir` of `/abs` | `data:` (flattened: `/os/x.cfg` → `data:os/x.cfg`) | CrossLua's `sd:` is read-only by design; SD writes can't and mustn't happen |
| `fs.list` | merged `data:` then `sd:` listing | names returned without trailing `/` |
| `fs.dofile(path)` | load + call in the spell's env | errors propagate like `dofile` |
| `zip.list/read/inflate` | `zip.list/read/inflate` | path mapped like `fs`; entries get `compressedSize=size, method=8` |
| `time.uptime/now/set` | `system.millis/time.now/time.set` | |
| `time.sync(server,timeout,gmt,dst)` | `time.sync(timeoutS)` | server/gmt/dst ignored — CrossLua syncs to its own clock config; returns `true` or `false,"sync failed"` |
| `system.info/batteryPercent` | `system.heap/system.battery` | version string `"crosslua"` |
| `system.radioOff/radioState` | `wifi.off` / `wifi.status()` | `"wifi"` when connected, else `"off"` — never `"ble"` |
| `system.reboot/sleep/startSdFlash` | — | return `false, "not supported on CrossLua"` |
| `system.SETTINGS/SHUTDOWN_INTERRUPT` | constants provided | the **gestures don't exist** on CrossLua: hold-Back ≥1s quits the app at firmware level and is never delivered to Lua |
| `wifi.connect(ssid,pass,timeout)` | `wifi.connect()` — **zero arguments** | security: credentials are swallowed; CrossLua joins the system's saved network (the X4's own WiFi flow). Spells should redraw after, as lib/wifi spells do |
| `wifi.request(method,url,body,headers)` | `http.request{...}` | returns `body, status`; status 0 on failure (like Grimoire) |
| `wifi.scan` | `wifi.scan()` | |
| `require("lib.x")` | loads `sd:spells/lib/x.lua` via the shim fs | dots→slashes, cached per boot, modules run in the **spell's** env, `_G.__loaded` mirror kept |
| spell stdlib | base + math/string/table/utf8/coroutine + print | no `io/os/package/debug/dofile/loadfile` — same sandbox as both runtimes |

## Deliberate deviations (documented)

1. **Unsupported hardware APIs raise, they don't return `nil, err`.**
   `ble.*`, `hid.*`, `net.listen/accept/...`, `wifi.startAP/apIP/stopAP` (`image.*` now works: see below)
   call `error("not supported on CrossLua yet (<name>)")`. Rationale: the
   shipped spells never check the error value — `ble_client_test.lua` does
   `#ble.scan(5)` and would die with *"attempt to get length of a nil value"*,
   `wifi_server_test.lua` would show a generic *"Failed to start..."* with no
   explanation. Erroring at the call site gives the launcher's error screen a
   readable message and stops the spell immediately. `net.isConnected()` →
   `false` and `net.available()` → `0` keep returning values because shared
   event-loop libs probe them defensively.
2. **`input.down()` is always false** and **`pressed`/`released` fire
   together**: CrossLua only delivers button *releases* and the shim can't
   distinguish press from release edges. Spells that only use `pressed()`
   (all shipped ones) are unaffected.
3. **`refreshWindow` is a whole-panel `present`** (fast or full mode), not a
   partial region — CrossLua's gfx has no region refresh. Slower, never wrong.
4. **SD writes are impossible on CrossLua** (`sd:` read-only). Writes go to
   `data:` and reads see the `data:` copy first, so write-then-read spells
   work; anything the device writes never reaches the real SD card. `fs.list`
   merges `data:` over `sd:` so written files show up.
5. **`display.bitmap` is a Lua pixel loop** — correct, but slow for
   full-screen blits (hundreds of thousands of `gfx.pixel` calls). Fine for
   icons/partial blits; use `image.*` (backed by `gfx.image`) for
   full-screen images.

## What could NOT be emulated, and why

- **`ble.*`, `hid.*`** — needs a real BLE backend. CrossLua has none yet
  (planned). Stubs error with the readable message above.
- **`net.*` raw TCP** — CrossLua has no sockets yet (planned).
- **BMP works where PNG cannot:** `image.open/draw` accept `.bmp` (header read for width/height, top-down too), which needs only ~16 KB of RAM. Note `gallery.lua` itself lists only `*.png` names, so use a spell that opens the BMP path directly.
- **`image.draw` of a PNG still cannot run inside the shim on the device.** The PNG decoder needs a ~60 KB contiguous block; in a fresh per-spell VM with the shim loaded the largest block is ~47 KB, so `gallery.lua` shows `not enough free RAM to decode`. `gfx.image` itself works for lean apps.
- **Each spell runs in its own fresh VM when the firmware has `app.restart`** (`main.lua` writes the choice to `data:spell.txt` and restarts into `run.lua`, which loads the shim + spell only and restarts back into the launcher; a spell error is passed back through `data:error.txt`). Without `app.restart` (older firmware) the spell runs inside the launcher VM as before.
- **`image.*`** - implemented on `gfx.image` (PNG/JPEG decoded by the firmware). `image.open(path)` reads the PNG header for `width/height`; `image.draw(h, x, y, w?, h?)` fits the image into the w,h box (default: native size), never upscales and centres it in the box; Grimoire stretched to the box. JPEG files are not opened by `image.open` (PNG header only).
- **`wifi.startAP`/AP mode** — CrossLua only joins networks the user has
  configured; it can't create one.
- **`system.reboot/sleep/startSdFlash`** — flashing/rebooting is CrossLua
  firmware territory, not exposed to apps.
- **Send/wake gestures** (`SETTINGS_INTERRUPT`, `SHUTDOWN_INTERRUPT`) — the
  strings exist for compatibility, but holding Back on CrossLua quits the app
  and holding Power turns the device off; neither reaches Lua.
- **True `input.down()` / `power` events** — see deviations 2.
- **Partial-region e-ink refresh** — CrossLua gfx has no region API.
- **`time.sync` server selection** — CrossLua syncs only to its own NTP
  configuration.
- **`display.bitmap` for full-screen images** — works but impractically
  slow; a future CrossLua blit API (`gfx.bitmap`-like) would be the right
  fix and the shim's `display.bitmap` is the single seam to swap.

So: every shipped spell *runs*; four of them (gallery, ble_client_test,
ble_keyboard_test, wifi_server_test) stop immediately at the first unsupported
call with a readable message instead of working.

## Memory

The device's Lua heap is ~96 KB and the shim is written to stay lean: no big
tables, no per-call garbage in hot paths (`input.poll` allocates nothing),
`load` + fresh env per spell, and the launcher runs `collectgarbage("collect")`
between spells. Unsupported-API errors are thrown (no stack-table churn).