# Grimoire spells — a Grimoire compatibility shim for CrossLua

Runs unmodified **Grimoire** spells (the other Lua runtime for the X4, in
`/root/x4/Grimoire`) on the **CrossLua** runtime as an ordinary CrossLua app.
A spell is a single `.lua` file the Grimoire launcher reads from `/spells` on
the SD card; this plugin does the same — it lists `sd:spells/*.lua` and runs
the file through a shim that rebuilds Grimoire's global API (`display`,
`input`, `fs`, `zip`, `time`, `system`, `wifi`, `ble`, `hid`, `net`, `image`,
Grimoire-style `require`) on top of the CrossLua API (`gfx`, `input`, `fs`,
`zip`, `time`, `wifi`, `http`, ...).

## Files

```
plugins/grimoire_lua/
    manifest.json   title + permissions (library, network)
    main.lua        launcher: lists sd:spells/*.lua, runs spells, error screen
    shim.lua        the compatibility layer (all the emulation tables)
    README.md       this file
test/lua_shim/
    fake_crosslua.lua     pure-Lua fake of the CrossLua API (headless tests)
    run_shim_tests.lua    the test suite driving every real spell
    run.sh                builds /tmp/lua5.4 if needed and runs the suite
```

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
- **`image.draw` of a PNG still cannot run inside the shim on the device.** Measured on the X4: sizeof(PNGdec) is 59.5 KB (the firmware build raises `PNG_MAX_BUFFERED_PIXELS` to 16416), so decoding needs a ~60 KB contiguous block; in a fresh per-spell VM with the shim loaded the largest block is 47 KB, and `gallery.lua` shows `not enough free RAM to decode (largest block 47K, need 62K)`. `gfx.image` itself works for lean apps (`imgtest_lua`: 91 KB block).
- **Each spell now runs in its own fresh VM when the firmware has `app.restart`** (`main.lua` writes the choice to `data:spell.txt` and restarts into `run.lua`, which loads the shim + spell only and restarts back into the launcher; a spell error is passed back through `data:error.txt`). Without `app.restart` (older firmware, the pure-Lua harness) the spell runs inside the launcher VM as before.
- **(Historical, measured before that change) `image.draw` needs RAM the single-VM design did not leave.** The PNG decoder allocates one ~44 KB block; with the launcher + shim + spell resident in one VM the Lua heap is ~49 KB, free RAM ~53 KB and the largest block 37 KB (measured on the X4 running `gallery.lua`), so `image.draw` raises `not enough free RAM to decode (largest block 37K, need 62K)` and gallery shows that on screen. It will work once spells get a fresh, lean VM (`app.restart(entry)`, see FEATURE_MATRIX.md); `gfx.image` itself works on the device for apps with a small heap (`imgtest_lua`).
- **`image.*`** — now implemented on `gfx.image` (PNG/JPEG decoded by the firmware). `image.open(path)` reads the PNG header for `width/height`; `image.draw(h, x, y, w?, h?)` fits the image into the w,h box (default: native size), never upscales and centres it in the box; Grimoire stretched to the box. JPEG files are not opened by `image.open` (PNG header only).
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

## Testing (headless, no device)

```
test/lua_shim/run.sh
```

`run.sh` builds `/tmp/lua5.4` from `/root/x4/lua-5.4.7` if needed, then runs
`run_shim_tests.lua` with the real interpreter. That script:

1. loads `fake_crosslua.lua` — a pure-Lua fake of the CrossLua API (gfx logs
   every call; input pops a scripted queue; fs is backed by real files under
   `$TMPDIR/grimoire_shim_test` with sd:/data:/app:/lib: scopes; wifi/http/
   zip/time return plausible data; `load` = real text-only load; the env
   handed to app code has **no io/os/package/debug/dofile/loadfile**, while
   the harness itself uses them freely);
2. builds a fake SD image: the **real** Grimoire spells + `lib/*.lua` copied
   from `/root/x4/Grimoire/sd_card_contents/spells/`, an `/os/config.lua`
   fixture, dummy `images/test.png`, and three harness-only fixture spells
   (`z_fs_write_test.lua`, `z_input_test.lua`, `z_wifi_creds_test.lua`,
   `z_gfx_stress.lua`) that can't ship — they're generated inside the harness;
3. loads the **real** `main.lua` + `shim.lua` from the plugin folder and runs
   every spell with a scripted input queue and a `debug.sethook` instruction
   budget (an infinite idle loop aborts deterministically and is recorded as
   "reached idle loop = OK");
4. drives the real launcher end-to-end twice (error-screen path, navigation
   path); and
5. runs the assertions below, plus **two mutation checks**: the shim is
   temporarily broken **in memory** (a string-mutated copy, never the shipped
   file) — (M1) forwarding wifi credentials, (M2) mapping fs writes onto
   `sd:` — and the suite proves the normal assertions catch both.

Assertions: (a) `example_spell.lua` / `library_demo.lua` draw and exit
cleanly on a scripted confirm; (b) `time_demo.lua` runs `time.sync` through
the shim; (c) `http_request_test.lua` reaches `wifi.request` (all 4
requests); (d) `gallery.lua`, `ble_*.lua`, `wifi_server_test.lua` fail
gracefully with a message containing "not supported on CrossLua" — never
"attempt to call a nil value"; (e) every coordinate passed to `gfx.*` is a
finite number (never nil/NaN); (f) a spell writing `/os/x.cfg` creates
`data:os/x.cfg` and never touches `sd:` (plus the read-back shadowing check);
(g) `wifi.connect` with credentials never forwards them — the fake records
the CrossLua-level call and asserts **zero arguments**, with the fixture
passing `("EvilCorp-WiFi", "hunter2secret")`.

`run.sh` prints a per-spell status table and `ALL SHIM TESTS PASSED` only if
every assertion held (exit 0; exit 1 otherwise). Current result: **53
assertions, 0 failures.**

## Notes on the CrossLua API docs (docs/lua/API.md)

- **`load` is documented as removed, but the shim depends on the new one.**
  `src/lua/LuaVm.cpp` still lists `load` in the removed globals; the shim
  requires the planned text-only `load(text, chunkname, "t", env)` (env
  honoured as `_ENV`, ≤64 KB). Until that lands in firmware, spells can't be
  loaded — this is the single hard dependency.
- `gfx.present` modes `fast|half|full` verified in `src/lua/LuaApi.cpp`
  (invalid modes raise an error).
- `fs.list` returns entries sorted with a trailing `/` on directories
  (verified in `LuaFs.cpp`); the launcher uses that to skip subfolders.
- `system.heap()` returns three values (free, min, largest) — the shim takes
  the first as `freeHeap`.
- Input is documented as *release*-delivered and `input.wait` yields to the
  firmware; the shim's poll design leans on both. Because the poll path can
  never see a press edge, `pressed`/`released` are indistinguishable — a
  doc-level consequence worth stating explicitly: **spells using
  `input.down()` or relying on press-vs-release edges will misbehave.**
- `wifi.connect()` hands the screen to the system WiFi flow: spells must
  redraw afterwards (lib/wifi spells already do).