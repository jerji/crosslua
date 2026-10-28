# CrossLua app API (v0.23)

An app is a plugin folder containing `main.lua`, in any plugin root
(`/plugins`, `/.plugins`, `/.crosspoint/plugins`):

```
/plugins/hello_lua/
    main.lua        required — the app
    manifest.json   optional — {"title": "...", "description": "..."} (shown in Home → Plugins)
    README.md       optional
```
Enable **Settings → Connectivity → Plugins**, then open **Home → Plugins**. Lua apps are listed
with a `>` and a "Lua app" subtitle unless the manifest gives a description.

**Quit:** `return` from the main chunk, call `app.exit()`, or *hold Back for 1 s* (always works,
even if the app is stuck in a loop). A runtime error shows an on-screen error + traceback; Back returns.

## Namespaces are built on first use

Only `gfx` (including `gfx.image` and `gfx.save_bmp`), `input`, `app`, `system`, `print`, `require` and `load` exist at start. `time`, `device`, `led`, `fs`, `json`, `wifi`, `http`, `net`, `zip`, `epub`, `crypto`, `coroutine` and `utf8` are built the first time a script reads the global (`crypto.sha1(...)` just works). Measured on the X4: Lua heap at start 19,278 B before this change, 11,577 B after (free heap +10.9 KB); touching every namespace costs 17,356 B in total, still below the old figure. Consequences: `pairs(_G)` does not list namespaces nobody has used yet, `rawget(_G, "crypto")` is nil until first use, and `_G` has a protected metatable, so `setmetatable(_G, ...)` fails with "cannot change a protected metatable". The first touch of a namespace needs a little free Lua heap (about 0.1-1 KB each); if that is not available you get a normal `not enough memory` error and the same access works again once memory is free.

## Language / sandbox
Lua 5.4.7, **32-bit** build: integers are `int32`, floats are single precision. Use `//` for integer division.
Libraries: base, `string`, `table`, `math`, `utf8`, `coroutine`. **No** `io`, `os`, `package`,
`debug`, `dofile`, `loadfile` (and precompiled chunks are rejected). Files go through `fs`, code through `require`.

### `load(text [, chunkname [, mode [, env]]])` -> function | nil, err
Compiles a string of Lua source at runtime. Text chunks only: precompiled bytecode is always refused (whatever `mode` says),
reader functions are not accepted, and the chunk must be 64 KB or less. If `env` is given (even `nil`) it becomes the
chunk's `_ENV`, so `load(src, "=x", "t", {})` runs `src` with no access to `print`, `fs` and the rest. Every failure (syntax
error, too large, heap budget exhausted while compiling) is a plain `nil, err`; it never aborts the app. Unlike
`require`d modules, loaded chunks keep their debug info, so error messages carry line numbers. Remember the compile
needs transient RAM: check `system.heap()` before loading anything near the limit.
`print(...)` goes to the serial/SD log (tag `LUA`).

Memory: each app gets a hard heap cap computed at launch (free RAM − 40 KB, clamped 24–160 KB; ≈96 KB on a freshly booted X4; the collector starts a cycle at 130 % of live data),
plus a device guard: no allocation may leave less than 40 KB of free RAM. Exceeding either raises a normal catchable `not enough memory` error.
**After a successful `wifi.connect()` the device guard drops to 12 KB** (the radio then owns ~57 KB and only ~44 KB are free; a 40 KB floor would leave Lua about 1 KB). Measured on the X4: any floor above ~16 KB makes reads fail mid-stream because TCP buffering alone dips free heap to ~16.7 KB during a 64 KB burst. The drop lasts for the rest of the app (apps that used WiFi restart the device on exit).
Speed on the X4: roughly 435k simple VM loop iterations per second. Script size limit: 64 KB.

**Debug info is stripped** from every loaded script (line tables and local-variable names are ~1/3 of a compiled script's RAM;
Study went from 70 KB to 48 KB). Errors then read `?:-1: attempt to index a nil value` instead of `app:store.lua:20: ... (local 't')`.
While developing, create a file `data:debug.flag` (any content) to keep the full info; delete it when you ship.

Scripts are preemptible: a count hook yields to the firmware every ~10k VM instructions, so a busy loop
cannot freeze the device, drop the power button, or block sleep.

## gfx — drawing (screen coordinates, origin top-left; size follows device orientation)
| call | notes |
|---|---|
| `gfx.size()` → w, h | |
| `gfx.clear([black])` | white by default; `true` = black |
| `gfx.pixel(x, y [, black=true])` | |
| `gfx.line(x0, y0, x1, y1 [, black=true])` | |
| `gfx.rect(x, y, w, h [, filled=false [, black=true]])` | |
| `gfx.rounded_rect(x, y, w, h, radius [, filled=false [, black=true]])` | a rectangle with rounded corners (cards, pills, bubbles) |
| `gfx.qr(text, x, y, side)` → true \| false | draws a QR code fitted into a `side` x `side` box in the CURRENT frame (`false` when the text does not fit a code); call `gfx.present()` afterwards |
| `gfx.text(x, y, str [, font="ui" [, flags]])` | `y` is the top of the line. `flags` string: `b` bold, `i` italic, `w` white text, `c` centre on x, `r` right-align to x |
| `gfx.text_width(str [, font [, flags]])` → px | |
| `gfx.line_height([font])` → px | |
| `gfx.wrap(text, max_width [, font [, flags]])` → `{ "line1", … }` | word-wraps `text` to `max_width` px (1..10000) in the given font, using the real font metrics. Explicit `\n` are line breaks, runs of spaces collapse to one, and a single word wider than `max_width` is hard-broken char-by-char (correct for proportional fonts). Empty text → `{}`. 1-based table |
| `gfx.present([mode])` | pushes the frame to the panel. `"fast"` (default), `"half"`, `"full"` (clears ghosting, slow) |
| `gfx.image(path, x, y [, box_w, box_h])` → drawn_w, drawn_h \| nil, err | PNG/JPEG/BMP (`.png .jpg .jpeg .bmp`) from `app:`/`data:`/`sd:` (`sd:` needs `library`; hidden paths refused). Decoded row by row by the firmware (RAM does not scale with the source; sources up to 8 MP / 6 MB), dithered to black/white into the current frame. The box defaults to x,y..screen edge and is clipped to the screen; the image is **fitted into the box, never upscaled, and centred**; the return values are the size actually drawn. Errors are values: `no such file`, `unsupported image type (png, jpg, bmp)`, `cannot read the image header`, `not enough free RAM to decode`, `decode failed`. RAM: **BMP needs only ~16 KB** (uncompressed 1/2/4/8/24/32-bit up to 2048x3072, read row by row, dithered, scaled to the box), JPEG ~24 KB, PNG ~62 KB (the decoder object is 59.5 KB). On a tight heap prefer BMP or JPEG; an app with a big Lua heap can get `not enough free RAM to decode`. Call `gfx.present()` afterwards. |
| `gfx.save_bmp(path)` → `true` \| `nil, err` | saves the CURRENT drawing buffer (draw first; `gfx.present` is not needed) as a 1-bit BMP in the panel's portrait orientation (480x800 on the X4, 48,062 bytes), using the firmware's own screenshot writer. Same write rules as `fs.write`: `data:` always, `sd:` only with a write grant, never `app:` or `*.bin`; the name must end in `.bmp` (any case); missing folders are created. Streams one row at a time (no heap) and takes about 240 ms on the X4. Verified: reloading the file with `gfx.image` gives a pixel-identical screen; 20 saves leak nothing. Handy for bug reports, sharing a result, or tests |

Fonts: `ui`, `ui12`, `small`, `sans12`, `sans14`, `sans16`, `sans18` (CrossPoint's built-in fonts, same as the rest of the UI).
Nothing reaches the panel until `gfx.present()`. Coordinates may be floats (truncated).

## input
| call | notes |
|---|---|
| `input.wait([timeout_ms])` → name \| nil | yields to the firmware until a button is released or the timeout passes (`nil`). No timeout = wait forever. **Prefer this over polling** — the device idles/sleeps normally. |
| `input.poll()` → name \| nil | non-blocking. Button event names: a press returns the bare name (`back` `confirm` `left` `right` `up` `down`); holding a button >500 ms returns `<name>_hold` (`confirm_hold` `left_hold` `right_hold` `up_hold` `down_hold`) instead of the press. `back` has no hold — holding Back ~1 s force-quits the app (the escape hatch). A press is either a tap *or* a hold, never both |
| `input.key()` → `{char, key, code, ctrl, shift, alt, gui}` \| nil | details of the `"key"` event `poll`/`wait` returned last (a Bluetooth keyboard press, see `ble`); `nil` after any other event. A printable key has `char` (one ASCII character); a special key has `key` = `enter backspace tab escape delete left right up down home end pageup pagedown`; `code` is the raw HID usage id; the modifier flags are true for either hand's key |

Event names: `back confirm left right up down`, plus `<name>_hold` for every button but Back (see above), `key` while a Bluetooth keyboard is connected, and `press long tap release` on touch boards. A press event is delivered on button *release*; a `<name>_hold` is delivered the moment the hold crosses 500 ms (its release is then suppressed). Holding Back ≥ 1 s quits the app and is never delivered.

## app
`app.sleep(ms)` (timer only — buttons stay queued) · `app.exit()` · `app.name()` · `app.dir()` (e.g. `/plugins/hello_lua`)

`app.entry()` → the script this VM was started from (`"main.lua"` unless `app.restart` chose another).

`app.restart([entry="main.lua"])` → `false, err` | never returns. The app quits and starts again from `entry` (a `.lua`
file in the app's own folder, subfolders allowed: `"tests/net.lua"`) in a **fresh VM**: a new heap
budget, no leftover globals or modules, WiFi radio switched off. Nothing else is carried over, so pass state through `data:`
files. Use it to give a heavy sub-app a lean start (a launcher that holds a menu, then restarts into a worker script). Errors
are values (`entry must be a plain .lua file name...`, `no such entry script`); on success the call never returns.

## system
`system.millis()` (31-bit, wraps ~24 days — compare with subtraction) · `system.heap()` → free, min_free, largest free block (device RAM) ·
`system.lua_mem()` → used, peak, budget (this app's Lua heap) · `system.battery()` → percent · `system.language()` → the UI language's native display name (`"English"`, `"Français"`, …) · `system.battery_info()` → `{percent, millivolts, charging, external_power}` (unknown fields omitted; `charging` reflects the charger IC, `external_power` stays true on a full battery; `nil, "no battery on this device"` when the board has none) · `system.last_wake()` → `"timer" | "button" | "power-on" | "other"` — what woke the previous cycle
(`"power-on"` = a real reset; the wake is a fresh boot, so an app that schedules work on a timer checks this first) ·
`system.sleep(seconds)` → `true` \| `nil, err` — **deep-sleeps the device** for 1..604800 s (a week): arms the timer and the
power button, then enters the same sleep flow as the power button (sleep screen, plugin events, rails off). The call never
returns; the wake is a fresh boot and `last_wake()` says `"timer"`. No permission: the power button always wakes the device.
Verified on the X4: sleep 12 s → the device woke itself and the relaunched app reported `"timer"`.

## fs — sandboxed files
An app never sees the whole SD card. Every path has a scope prefix:

| prefix | maps to | access |
|---|---|---|
| `app:` (or no prefix) | the app's own folder, e.g. `/plugins/foo/` | read-only |
| `data:` | `/.crosslua/data/<app>/` — created on first write | read/write |
| `lib:` | `/.crosslua/lib/` — shared Lua libraries | read-only |

The part after the prefix must be a clean relative path: no `..`, `.`, empty parts (`a//b`), leading `/`, backslashes or `:`.
Anything else is rejected, so `fs.read("../../x")` cannot escape. Errors are returned, not thrown: `nil, "message"`.

| call | returns |
|---|---|
| `fs.read(path [, offset [, len]])` | contents \| nil, err. Whole file (max 128 KB), or just the byte range `offset`, `len` (clipped at the end; max 128 KB per call). Use ranges for files too big to hold in memory: a 600 KB deck is read in 4 KB pieces |
| `fs.write(path, data)` | true \| nil, err. **Atomic** (temp file + rename): a power cut keeps the old file. Parent folders are created. Max 256 KB |
| `fs.append(path, data)` | true \| nil, err |
| `fs.write_at(path, offset, data)` | true \| nil, err. **In place, NOT atomic** (`data:` only; the file must exist; `offset` ≤ size; data ≤ 16 KB). For small fixed-size records in big files (a power cut can tear that one record, never the whole file) |
| `fs.exists(path)` | bool |
| `fs.size(path)` | bytes \| nil, err |
| `fs.list(path [, {detail, offset, limit}])` | sorted array of names, folders end in `/` \| nil, err (`fs.list("data:")` lists your save folder). **With an options table** it also returns the total entry count and only the window `offset`..`offset+limit` (limit 1..512, default all). **`detail=true`** returns tables `{name, dir, size, mtime}` instead (`name` has no trailing `/`; limit 1..64, **default 32**: a table per entry is ~100 bytes of the ~96 KB Lua heap, so page through big folders with `offset`; `size` costs one card lookup per returned entry only). Unknown options, wrong types and out-of-range values are refused with an error value, never ignored |
| `fs.stat(path)` | `{size, dir, mtime}` \| nil, `"no such file"`. `size` is 0 for a folder. `mtime` is the file's FAT stamp as seconds since 1970 **read as local wall-clock time** (FAT stores no zone, so it is not comparable with `time.now()` across zones) and is missing when the card has no valid stamp. **Lua numbers here are 32-bit**: sizes above 2 GiB read as 2147483647, and a stamp past 2038-01-19 (FAT allows 2107) is reported as missing rather than as a wrong date. **Files created on the device itself currently all carry the same constant default stamp (2026-01-01 00:00:00): the firmware sets no FAT clock yet**, so `mtime` is only meaningful for files that came from a computer |
| `fs.mkdir(path)` / `fs.remove(path)` | true \| nil, err (`data:` only; remove works on files and *empty* folders) |
| `fs.rmdir(path)` → true \| nil, err | recursive directory delete (removes everything under it — `fs.remove` refuses a non-empty folder). Refuses the `data:` root and anything that is not a directory |
| `fs.rename(from, to)` → true \| nil, err | both paths must be in `data:`; no overwrite (`to` must not exist), so an atomic replace is `fs.remove(to)` then `fs.rename` |
| `fs.volume()` → `{total, used, free}` \| nil, `"no storage mounted"` | SD card capacity in **bytes** (free = total − used, computed exactly before the float conversion). On the X4 the values are 32-bit floats, so byte counts above ~16 MB lose sub-kilobyte precision — fine for free-space display, not for exact hashes/offsets |

## require
`require("name")` loads `name.lua` (or `name/init.lua`) from the app folder, then from `/.crosslua/lib/`. Dots are folder
separators: `require("util.strings")` → `util/strings.lua`. Modules are cached and may yield (e.g. call `input.wait`) while loading.
Circular requires and missing modules raise a clear error listing the places searched. Module names may only use letters, digits, `_` and `.`.

## time
| call | returns |
|---|---|
| `time.now()` | UTC epoch seconds, or `nil` if the device clock is not trustworthy (never synced, no RTC). The X4 has no RTC: the clock is restored from flash and re-synced (SNTP) whenever WiFi connects — use File Transfer or the Clock settings once. Fits a 32-bit integer until 2038 |
| `time.date([epoch])` | `{year, month, day, hour, min, sec, wday, yday}` in the **local** time zone (`wday` 1 = Sunday), or `nil` without a clock. Default epoch = now |
| `time.sync([timeout_s])` → true \| false, err | SNTP over the current WiFi connection (needs `network` and a connected `wifi.connect()`); the system also syncs by itself whenever WiFi connects |
| `time.set(epoch)` → true | sets the wall clock by hand (UTC epoch seconds); only for when SNTP is not an option |

For day-granular scheduling use the local calendar date, not `now() // 86400` (that rolls over at UTC midnight).
`study_lua/main.lua` has a `days_from_civil(y, m, d)` helper.

## sd: scope, zip, app.open_book — the user's library (needs the `library` permission)
```json
{"title": "My library app", "permissions": ["library"]}
```
`sd:` is the SD card outside your sandbox: `fs.list("sd:")`, `fs.list("sd:Books")`, `fs.read("sd:Books/x.txt")` (also ranges), `fs.size`, `fs.exists`.
**Read-only** (every write/remove/mkdir/write_at refuses), and **hidden paths do not exist**: any component starting with `.`
(`.crosspoint` = settings and WiFi credentials, `.crosslua` = other apps' data) is refused, `fs.exists` says `false`, and
`fs.list` omits dot-names. Without the permission every `sd:` call fails with `library access not permitted`. Clean relative
paths only (no `..`, no leading `/`).

| call | notes |
|---|---|
| `zip.list(path [, max=64])` → `{ {name, size}… }, total` \| nil, err | `path` is any fs path (`sd:Books/a.epub`, `data:x.zip`). `max` 1…128; `total` is the real entry count; `size` is the uncompressed size |
| `zip.read(path, entry [, max_bytes=32768])` → string \| nil, err | inflates one entry. Refuses entries over `max_bytes` (hard cap 65536) and when free RAM is short (inflate needs ~48 KB transient, so call it with a small Lua heap) |
| `zip.inflate(bytes [, zlib [, max_out]])` → string \| nil, err | decompresses a raw DEFLATE stream (gzip member bodies, StarDict `.dict.dz` chunks) or, with `zlib=true`, a zlib-wrapped one. Input 1..65536 bytes, output at most 96 KB; one call at a time like `zip.read`. `max_out` (optional, 1..98304) stops decompression at that many output bytes and returns them even when the stream is not cleanly finished — pass a `.dict.dz` chunk's known uncompressed size and prefix the chunk, instead of erroring on a partial deflate stream |
| `zip.zstd(frame [, dict])` → string \| nil, err | **Zstandard** decompression (what the Wikipedia/xkcd/trivia packs store their blocks as). `frame` 1..65536 bytes; `dict` (optional) is the pack's pre-shared dictionary. **Host-verified but unusable on the X4 today**: zstd builds a ~96 KB decompression context that exceeds the per-app ~82-94 KB heap, so the call returns `nil, "out of memory"` / `"zstd decompression failed"` — a memory constraint, not a bug |
| `app.open_book(path)` → false, err \| (never returns) | `sd:` or `data:` file only. Parks the app, frees its memory and opens the file in the reader, replacing the app — save your state first |

Typical EPUB metadata read (2 small entries, no RAM to speak of): `zip.read(p, "META-INF/container.xml")` → `full-path` of the OPF →
`zip.read(p, opf)` → title / author / subjects; the first spine page is the book's title page.

### Storage grants — read or write chosen SD folders without the whole-card `library` permission
`manifest.json`: `"storage": {"read": ["Books"], "write": ["Books/AO3", "Downloads"]}` (`"/"` = the whole card; max 8 entries).
- **Approval:** the first launch shows a native confirmation (Allow / Deny) that lists the folders in plain words. The approval is
  stored in a hidden firmware-owned file the app cannot reach; it is valid only for exactly this request, so an update that changes
  the list asks again. Deny = the app does not start. Until approved, the grants do not exist for the API.
- **What a grant gives you:** `sd:Folder/...` paths work in `fs.*` and `zip.*`, `gfx.image` and `app.open_book` for read grants;
  `fs.write/append/write_at/mkdir/remove/rename` and `http.request{save_to="sd:..."}` also work inside WRITE grants (a write grant
  also reads). A grant covers the folder and everything under it, never a sibling that merely shares the prefix (`Books` does
  not cover `BooksX`). Without `library`, anything outside the grants fails with `library access not permitted: this path is
  outside the folders granted to this app`.
- **Never grantable:** hidden (dot) folders (`.crosspoint` has the WiFi credentials, `.crosslua` other apps' data) and firmware
  images (`*.bin` cannot be written whatever the grant). Grants naming `/` or `plugins` (write access to other apps' code) get a
  louder warning on the confirmation screen. Invalid entries (`..`, hidden names, absolute paths, `:`) are ignored.
- **`library` still means** read-only access to the whole card; grants add write access and narrower read access.

## wifi / http — network (needs a permission)
An app must declare it in `manifest.json`, or every call below fails with a clear error (and `wifi.status()` hides the SSID/IP):
```json
{"title": "My app", "permissions": ["network"]}
```
| call | notes |
|---|---|
| `wifi.connect([{tls=false}])` → true \| false, reason | Parks your script and hands the screen to the system's WiFi flow, which auto-joins the last saved network (usually no UI at all; otherwise the normal network picker/keyboard). **The screen is the system's afterwards: redraw.** Returns immediately with `true` if already connected. Input events do not wake it. **Refuses up front** (`false, "not enough free RAM for WiFi + TLS (free 86K, need 96K)…"`) when less than 96 KB is free: WiFi costs ~57 KB and TLS wants 40 KB on top. **`wifi.connect{tls=false}`** is for apps that only use plain TCP (`net.*`): it needs 80 KB free instead (radio ~57 KB + the 16 KB the socket layer refuses to go below + ~7 KB margin), and `https` then fails at request time with its own "not enough free RAM for TLS" message instead of crashing (verified on the X4 at ~90 KB free). `tls` must be a boolean; the default is `true`. Always show `reason`. |
| `wifi.scan([max])` → `{ {ssid, rssi, encrypted, bssid, channel, auth, hidden}, ... }` \| nil, err | blocking scan, a few seconds; needs `network`. `bssid` is `AA:BB:…`, `auth` → `open`/`wep`/`wpa`/`wpa2`/`wpa2/wpa3`/`wpa3`/`enterprise`, `hidden` = empty-SSID beacon |
| `wifi.status()` → `{connected, ssid, ip, rssi}` | |
| `wifi.softap(ssid [, {password, channel, max_clients}])` → `true, ip` \| `false, reason` | **Starts the device's own WiFi network** (a hotspot) so phones and laptops can join and talk to your `net.listen` server. Needs `"network"` AND `"hotspot"` in the manifest, and the user must approve the request on the permission screen (the line reads `AP`; same stored approval as storage grants and `listen`). `ssid` 1..32 printable ASCII; `password` 8..63 printable ASCII, **omit it for an OPEN network** (anyone nearby can join: use it only for things you would show a stranger); `channel` 1..11 (default 1); `max_clients` 1..4 (default 4). Refused while WiFi is joined as a client (`wifi.off()` first), while a hotspot already runs, and under 80 KB free RAM (measured on the X4: the hotspot itself costs ~60 KB, and `net.listen` needs 16 KB more). There is no internet behind it (`http.*` fails, `wifi.status().connected` stays false); `net.listen/accept/read/write/udp_*` and `net.info()` work over it. `wifi.off()` stops it, and leaving the app does the usual silent reboot. Like `wifi.connect()`, a started hotspot lowers the allocator guard to 12 KB (the radio owns ~60 KB; the usual 40 KB floor would leave Lua nothing). DNS and DHCP: the SDK hands out addresses itself; a captive-portal DNS answer can be written in Lua over `net.udp_open(53)`. Verified on the X4 with a real client (a USB WiFi adapter on the test host): WPA2 join, DHCP lease from the device, a Lua `net.listen` HTTP server answered `GET` requests, `softap_info().clients` = 1. Free heap fell to ~32 KB (low-water) while serving. |
| `wifi.softap_info()` → `{ssid, ip, clients}` \| `nil, "no hotspot running"` | `clients` = stations currently joined. Needs `"network"` only |
| `wifi.off()` | radio off now (frees part of the RAM; the radio leaves the heap fragmented, so ~20 KB only comes back after a reboot). Leaving an app that ever called `wifi.connect()` tears WiFi down and reboots to Home to defragment the heap, even if you called `wifi.off()` first (this survives `app.restart`). |
| `wifi.set_mac(mac)` → true \| nil, err | rotates the runtime **STA MAC** (`mac` = `"AA:BB:CC:DD:EE:FF"` or 6 raw bytes). Needs `network`. Rejects non-unicast and all-zero MACs up front, and refuses while any radio mode is active (connected / hotspot / monitor / tx / espnow). Boots the driver if the radio was off, so the new MAC is programmed before the next `wifi.connect()`. This is the ghost-mode primitive |
| `wifi.get_mac()` → `"AA:BB:CC:DD:EE:FF"` \| nil, `"WiFi is off…"` | the current runtime STA MAC (what `set_mac` last wrote, or the base MAC). `nil,err` when the radio has never been brought up |
| `http.request{url, method, headers, body, save_to, max_body}` → `{status, ok, bytes, body}` \| nil, err | see below |
| `http.get(url [, opts])` | `http.request` with `url` filled in |

`http.request` fields: `url` (`http://` or `https://`, ≤ 600 chars); `method` `"GET"` (default), `"POST"`, `"PUT"`, `"PATCH"` or
`"DELETE"`; `body` (≤ 8 KB, POST/PUT/PATCH only: a GET or DELETE with a body is refused) is sent as **`content_type`** (≤ 100 chars,
needs a body; default `application/x-www-form-urlencoded`), so a JSON service call is
`http.request{url = u, method = "POST", headers = {Authorization = "Bearer " .. token}, body = json.encode(t), content_type = "application/json"}`;
a `Content-Type` header together with a body is refused (use `content_type`). `headers` = `{Name = "value"}` (≤ 12; CR/LF/`:` rejected;
**sent on every method**: POST used to drop them, so no `Authorization` header could reach a service);
**`ca = "app:ca.pem"`** pins the server: the https certificate must chain to that PEM (32..8192 bytes, readable scope), otherwise
`nil, "request failed (no response, or the server certificate does not match ca)"`; `ca` on a plain `http://` url is refused;
**`response_headers = true`** adds `result.headers`, a table with lower-case names (a repeated header such as `Set-Cookie` is joined
with `, `; at most 48 headers, names up to 400 bytes, 4 KB in total). The method/`ca`/`response_headers` options run on the SDK
`SecureHttpClient` (a plain GET and every `save_to` download keep the original downloader; `save_to` only works for GET and cannot be
combined with `ca` or `response_headers`). A response over `max_body` is an error for every method (the old form POST silently cut it).
`max_body` (1…65536, default 16384) caps an **in-memory** response; `save_to = "data:path"` streams the response to a file instead
(no size limit but the card; the result has no `body`; read it back with `fs.read(path, offset, len)`).
A non-2xx status is a result (`ok = false`), not an error. Errors (`nil, msg`): not connected, DNS/connect/TLS failure, response
larger than `max_body`, not enough RAM for TLS, user pressed **Back** (`"cancelled"`), bad arguments.

* **Calls block the device** (like every CrossPoint screen that talks to the network): draw "Loading…" and `gfx.present()` *before*
  calling. **Back cancels** a transfer.
* **HTTPS is encrypted but the server certificate is NOT verified.** CrossPoint's HTTP stack calls `setInsecure()` everywhere
  (the wolfSSL transport has no CA bundle wired up), so a machine on your network path can impersonate the server. Never send
  secrets you would not send over plain HTTP on that network; treat responses as untrusted input. (Planned: optional
  certificate pinning: pass `ca=` (above).) **Without `ca` an https request is encrypted but unauthenticated: never put a token you care
  about (a Home Assistant long-lived token is admin) in a request without `ca`.** TLS needs ≥ 40 KB free RAM **and** a ≥ 20 KB contiguous
  block; otherwise the call fails with `not enough free RAM for TLS (free N, largest M)`. Measured on the X4: right after
  `wifi.connect()` only ~46 KB is free, so **an app can hold only ~5 KB of Lua data when it makes a TLS request**; the handshake
  itself dips to ~4-5 KB free (low-water mark) with a pinned certificate. Drop your tables, `collectgarbage()`, then request (repeating
  requests do not leak: 0 bytes of drift over 5 on the device). `system.heap()` returns `free, min_free, largest_block`.
* After WiFi was used, leaving the app does a **silent reboot** to Home (the same defragmentation every WiFi screen does).
* Redirects, `Content-Length` checks and `.part` staging for downloads are done by CrossPoint's `HttpDownloader`.

## crypto — hashes, HMAC, key derivation, AES, random (mbedtls; hardware SHA/AES on the device)
All byte strings are Lua strings (binary safe). Errors are `nil, err`; a wrong argument TYPE raises.
| call | notes |
|---|---|
| `crypto.sha256(data)` / `crypto.sha1(data)` → 32 / 20 raw bytes (SHA-256 over 100 KB: 2 ms on the X4, hardware accelerated) | data ≤ 64 KB; for more use `crypto.hash` |
| `crypto.md5(data)` → 16 raw bytes | data ≤ 64 KB; for more use `crypto.hash("md5")`. **MD5 is broken as a security hash**: it is here for protocols that mandate it (KOReader sync document ids and passwords, Calibre, legacy checksums), never for new designs |
| `crypto.crc32(data [, previous])` → 4-byte big-endian string | the IEEE 802.3 CRC-32 of zip, PNG and gzip. Returned as bytes because a 32-bit Lua integer cannot hold values above 2^31-1; pass an earlier result as `previous` to continue a running checksum across chunks (data ≤ 64 KB per call); `crypto.hex()` shows the usual 8 hex digits. `crc32("123456789")` is `cbf43926` |
| `crypto.hmac_sha256(key, data)` / `crypto.hmac_sha1(key, data)` → raw bytes | key and data ≤ 64 KB; keys longer than the block size are hashed first |
| `crypto.hash("sha256"\|"sha1"\|"md5")` → `h`; `h:update(chunk)` → `h`; `h:digest()` → raw bytes | incremental: hash a file with `fs.read(path, off, 8192)` in a loop. `digest()` ends the hash (a second call or an `update` after it is `nil, err`) |
| `crypto.pbkdf2_sha256(password, salt, iterations, len)` → raw bytes | iterations 1..20000, len 1..64, and iterations x ceil(len/32) ≤ 20000; blocks the app while it runs: measured on the X4, 4096 iterations take 0.2 s and the 20000 cap about 1 s |
| `crypto.aes_cbc_encrypt(key, iv, data)` / `crypto.aes_cbc_decrypt(key, iv, ciphertext)` | AES-128/192/256 (key 16/24/32 bytes), iv 16 bytes, PKCS#7 padding, data ≤ 32 KB. Measured on the X4: 8 KB encrypts in 4 ms, decrypts in 2 ms. Mind the Lua heap: input, output and your copies all live in it. CBC does **not** authenticate: store `hmac_sha256(mac_key, iv .. ciphertext)` with it, check it with `crypto.equal` **before** decrypting, never reuse an iv with one key. A wrong key usually shows up as `nil, bad padding ...`, but not always: only the MAC is a reliable check |
| `crypto.random(n)` → n raw bytes | n 1..256, the hardware RNG (`esp_fill_random`); WiFi/BT on gives true entropy |
| `crypto.aes_gcm_encrypt(key, nonce, data [, aad])` → `sealed` \| nil, err; `crypto.aes_gcm_decrypt(key, nonce, sealed [, aad])` → `data` \| nil, err | AES-128/192/256 in GCM (authenticated encryption in one blob, no separate MAC unlike CBC). `key` 16/24/32 bytes, `nonce` 12 bytes (generate with `crypto.random(12)`, never reuse with the same key), `data` ≤ 32 KB. `sealed` = ciphertext `..` 16-byte tag. `aad` (associated data) is authenticated but not encrypted (e.g. a header or account id). Decrypt verifies the tag first and returns `nil, "bad tag …"` on any mismatch. Verified against the NIST GCM test vectors |
| `crypto.equal(a, b)` → boolean | constant time for the length of `a`: use it for MACs and PIN hashes, never `==` |
| `crypto.device_key(label)` → 32 raw bytes \| `nil, err` | a key bound to THIS device and THIS app: `HMAC-SHA256(device secret, "crosslua-device-key:v1" 0x00 lower(app folder name) 0x00 label)`. The device secret is the random 32 bytes upstream keeps in NVS (it survives SD swaps and reboots and never touches the card); scripts never see it. A card copied to another device derives different keys, and another app cannot derive this app's keys. `label` 1..64 bytes without NUL (use a different label per purpose). Needs no permission. **Not a vault on its own:** a flash dump of the device recovers the secret, so mix it with a PIN/passphrase (see `vault.lua`). A full flash erase loses the secret, and everything encrypted under it |
| `crypto.hex(s)` / `crypto.unhex(hex)` | lowercase hex; `unhex` accepts either case, rejects odd length / non-hex |
| `crypto.b64encode(s)` / `crypto.b64decode(b64)` | RFC 4648 standard alphabet with padding; decode is strict (no whitespace, `=` only at the end) |

TOTP (RFC 6238) in six lines — what biscuit's authenticator does in C++:
```lua
local function totp(secret, t, digits)             -- secret: raw bytes (base32-decode it first), t: epoch seconds
  local h = crypto.hmac_sha1(secret, string.pack(">I4I4", 0, t // 30))
  local o = h:byte(20) & 15
  local n = ((h:byte(o+1) & 0x7f) << 24) | (h:byte(o+2) << 16) | (h:byte(o+3) << 8) | h:byte(o+4)
  return string.format("%0"..digits.."d", n % math.tointeger(10 ^ digits))
end
```
PIN lock sketch: `salt = crypto.random(16)`; store `salt .. crypto.pbkdf2_sha256(pin, salt, 5000, 32)`; check with `crypto.equal`.

## device / input / system additions for multi-board support
CrossPoint runs on more boards than the X4. Hardware features are gated by the firmware's own `FREEINK_CAP_*` flags and report honestly when the hardware is missing. **Features marked UNTESTED were built and host-tested but never run on the physical hardware (we only own an X4): if you have the board, `devtest_lua` exercises them: please report.**
| call | notes |
|---|---|
| `device.caps()` → `{touch, haptic, frontlight, warmlight, color, audio, ble_keyboard, usb_msc, imu, gyro, rtc, temp_humidity, buzzer, mic, led, tls13, width, height, model}` | booleans except width/height/model. Adapt to the board instead of guessing the model: everything is decided at RUNTIME from the board profile (one firmware image can serve several boards, e.g. X4 and X3), never from the model name. `model` is the board tag (`"x4"`, `"x4pro"`, `"metalio_eink4"`, …) — informational (for display/diagnostics), never for behaviour. `gyro` is false on accelerometer-only IMUs. Flags for hardware that has no Lua API yet (`rtc`, `mic`, `audio`, `color`, `ble_keyboard`, `usb_msc`, `tls13`) only tell you the board has it |
| `device.haptic(ms [, strength])` → `true` \| `false, why` \| `nil, err` | one non-blocking pulse, ms 10..1000, strength 0..255 (default 255). `false` when the board has no motor or the user turned vibration off in Settings. **UNTESTED on hardware** (Metalio E-Ink 4 has the motor; compiles and links in that env) |
| `device.frontlight()` → `on, brightness, warmth` \| nil | reads the frontlight; `nil` on a board without one. `device.frontlight(brightness [, warmth [, on]])` → true \| nil, err sets it (raises `no frontlight on this device` when absent: check `device.caps().frontlight`) |
| `device.motion()` → `{ax, ay, az, gx, gy, gz, gyro}` \| `nil, err` | IMU sample: acceleration in g, angular rate in deg/s (zeros and `gyro=false` on accelerometer-only parts), axes already corrected to a board-independent frame. `nil, "no motion sensor on this device"` without an IMU; `nil, "motion sensor read failed"` can happen transiently (retry). The sensor is woken on first use and put back to sleep when the app ends. **UNTESTED unless your board has an IMU** |
| `device.environment()` → `temp_c, humidity_pct` \| `nil, err` | on-board temperature/humidity sensor (Sticky today). **UNTESTED on hardware** |
| `device.tone(freq_hz [, ms])` → `true` \| `false, why` \| `nil, err`; `device.tone()` stops | piezo buzzer, freq 20..20000, ms 0..10000 (0 = until `device.tone()`); silenced automatically when the app ends. **UNTESTED on hardware** |
| `led.count()` → n; `led.set(i, r, g, b)`; `led.all(r, g, b)`; `led.off()`; `led.brightness(0..255)` | addressable LEDs, `i` is 1..count, colours 0..255. `false, "no LEDs on this device"` without them (`led.count()` is 0); LEDs go dark when the app ends. Blink with `app.sleep`. **UNTESTED on hardware** |
| `system.usb()` → boolean | USB cable connected (a GPIO read on the X4) |
| `system.mac()` → `"AA:BB:CC:DD:EE:FF"` | the device's own WiFi MAC address (not a secret; useful as a device identity in pairing screens) |
| `system.reboot()` → `true` | restarts the whole device (the app ends, the reader boots cold); the return value is moot — the call never really comes back |
| `input.poll()` / `input.wait()` touch events | on touch boards also `"press"` (finger down), `"long"` (held), `"tap"` (quick touch), `"release"` (finger up). **UNTESTED on hardware** (needs a touch board; compiles and links for `x4pro` and `metalio_eink4`) |
| `input.pos()` → `x, y` \| `nil` | screen-pixel position of the touch event `poll`/`wait` returned last; `nil` after a button event or an empty poll. A `"release"` reports where the finger last was |
| `input.text(title [, initial [, max_len [, mode]]])` → `string` \| `nil, "cancelled"` \| `nil, err` | the system on-screen keyboard (touch or buttons, whatever the board offers). `title` ≤ 60 chars, `initial` ≤ 256 bytes and ≤ `max_len`, `max_len` 1..256 (default 128), `mode` `"text"` (default) \| `"password"` (masked) \| `"url"` (URL helper keys). Parks the script while the keyboard is up (like `wifi.connect`), so redraw afterwards; an empty string means the user confirmed an empty field |

## net — raw TCP client sockets + UDP + listen + mDNS (needs the `network` permission and WiFi up)

Plain TCP over the Arduino `NetworkClient` that CrossPoint already links for its web server (no extra network code). Join WiFi first with `wifi.connect()`. Same permission and "WiFi up" rules as `http.*`. TLS client sockets (`{tls=true, ...}`) ride the same handles; see `net.connect`.

| call | |
|---|---|
| `net.info()` -> `{ip, mask, gateway, dns}` \| nil, err | The device's own addressing. (Not `net.local`: `local` is a Lua keyword.) |
| `net.resolve(host)` -> `"a.b.c.d"` \| nil, err | DNS (system timeout, blocks). An IPv4 literal is returned as is with no DNS traffic. Host names: letters, digits, `.` `-` `_`, at most 253 characters. |
| `net.connect(host, port [, {timeout_ms=5000, tls=false, ca=path, insecure=false}])` -> handle \| nil, err | Blocks up to `timeout_ms` (100..15000); **Back cancels** the wait (`nil, "cancelled"`), same as `http`. Handles are small integers 1..8 (TCP and UDP share the table). Refused when 8 are open or under 16 KB free RAM. **`tls=true`** opens a TLS 1.3 client and needs exactly one trust choice, because certificate trust is never guessed: **`ca="app:ca.pem"`** (a PEM of 32..8192 bytes in a readable scope; the server must chain to it, otherwise `nil, "...tls handshake failed..."`: pin your own CA) or **`insecure=true`** (encrypted, but the server is NOT authenticated: anyone on the path can impersonate it). `ca` or `insecure` without `tls=true`, both together, or neither with `tls=true` are refused. The handle then works with `read/write/available/connected/close` like a TCP one. **One TLS socket at a time**; the handshake transiently needs ~39 KB (measured on the X4: heap low-water 7.6 KB during it), so it is refused below 40 KB free or a 20 KB contiguous block (`not enough free RAM for TLS (free N, largest M)`), the same floors as `http.request`. Open it right after `wifi.connect()`, before you build big tables, and close it when done. Back cancels the handshake between its steps. |
| `net.read(h [, max=512])` -> string \| nil, "closed" | Never blocks. `""` means nothing has arrived yet. `max` 1..4096. After the peer closes you still get everything it sent, then `nil, "closed"`. |
| `net.write(h, data)` -> n \| nil, err | `data` at most 16384 bytes per call; **n can be less than `#data`**: loop on the returned count. |
| `net.available(h)` -> n | Bytes waiting (0 when none or closed). |
| `net.connected(h)` -> boolean | False once the peer closed and everything it sent has been read. |
| `net.close(h)` -> true \| nil, err | A handle that is not open (including one already closed) is an error value, not a crash. |

UDP datagrams live in the same socket table as TCP (8 slots total, TCP and UDP together; a handle works with exactly one kind and the other family's calls refuse it):

| call | |
|---|---|
| `net.udp_open(port)` -> handle \| nil, err | Binds a local UDP port (0..65535; 0 = system-assigned). Non-blocking afterwards. Same permission and "WiFi up" rules as `net.connect`. |
| `net.udp_send(h, host, port, data)` -> bytes \| nil, err | Fire-and-forget: no delivery guarantee. `host` may be a name (resolved via DNS, blocks briefly) or an IPv4 literal; `data` at most 16384 bytes and not empty. |
| `net.udp_recv(h [, max=1472])` -> `{data, ip, port}` \| nil \| nil, "closed" | Never blocks. `nil` means nothing has arrived. One datagram per call, truncated to `max` (1..16384). `ip`/`port` are the sender's. |
| `net.udp_close(h)` -> true \| nil, err | A TCP handle is refused with "not a UDP socket". |
| `net.listen(port)` -> handle \\| nil, err | Needs `"network"` AND `"listen"` in the manifest, and the user must approve the listen request on the permission screen (same stored approval as storage grants; a manifest change asks again). Binds a TCP server on `port` (1..65535). Refused when 8 handles are open or under 16 KB free RAM. |
| `net.accept(server)` -> handle \\| nil \\| nil, err | Non-blocking: `nil` (one value) = nothing waiting; `nil, err` = error. Returns a TCP client handle for `net.read`/`write`/`close`. |
| `net.mdns_query(service, proto)` -> `{ {hostname, ip, port, instance_name}, ... }` \\| nil, err | Queries mDNS on the LAN (e.g. `net.mdns_query("http", "tcp")`). `service` may have a leading `_` or not. `proto` is `"tcp"` or `"udp"`. Needs the `"network"` permission and WiFi up. Returns an empty array when nothing is found (not an error). |

Sockets still open when the app ends are closed (the radio is shut down then anyway).

**RAM, measured on the X4 with WiFi up (44.7 KB free):** an open idle socket costs 3.4-3.8 KB (4 idle sockets: 14.3 KB, all returned on close); one after a ping/echo 6.8 KB; one whose receive window is full about 16 KB. Streaming 64 KB with prompt reads dips free heap to ~16.7 KB with a small script (to ~5.8 KB with a 13 KB-larger Lua heap, which still completed with a matching hash) and took 212-856 ms across runs (74-301 KB/s: WiFi and LAN variance). Closed sockets sit in lwIP TIME_WAIT: the first ~40 connect/close cycles cost ~4.6 KB, then the cost plateaus (the next 120 cycles: +212 bytes). **Two or more sockets being flooded at once while the app does not read can exhaust memory**: read promptly, and treat one busy socket as the norm. `net.read` may go down to a 6 KB floor for the single allocation that copies data out of the stack (that relieves the pressure; the floor is restored right after).

`wifi.connect()` itself still needs 96 KB free to start (sized for TLS), so keep `main.lua` small and load bigger code after the radio is up (`load(fs.read("app:tests.lua"))`), as `socktest_lua` does.

## audio — play a WAV through the speaker (needs the `audio` permission AND its approval)

`audio.play(path [, loop])` plays a 16-bit PCM WAV (8-48 kHz; Metalio boards accept 16 kHz only) from `app:`/`data:`/`sd:`
(read scopes like `fs.read`; at most 4 MB). Returns immediately — playback runs in the SDK's own task. `audio.stop()`
ends it, `audio.playing()` reports the state, `audio.volume(0..100)` sets the output volume. Boards without a speaker
(the X4 among them) report `nil, "no audio on this board"` from `play` — absence is a normal result, `device.caps().audio`
tells apps what to expect. **UNTESTED ON HARDWARE** on boards that have a speaker (host-tested + compile-and-link on
metalio_eink4 only).

## mic — record from the microphone (needs the `microphone` permission AND its approval)

`mic.record(path, seconds)` records 1..30 whole seconds of 16 kHz mono 16-bit PCM into a WAV and returns the bytes written
(`nil, err` on failure). It blocks while recording and **Back cancels** (`nil, "cancelled"`, the partial file is removed).
The path follows the `fs.write` rules (`data:` always; `sd:` only inside a folder the app was granted; never `*.bin`) and must
end in `.wav`. Audio is streamed to the card in 512-byte blocks, so a 30 s recording costs no heap. `mic.level([ms = 100])`
listens for `ms` (10..2000) and returns the peak sample 0..32767 without storing anything. The approval screen says
"MICROPHONE" (listed first so a long dialog cannot clip it): a recording device is never enabled silently. Boards without a mic (the X4
among them) report `nil, "no microphone on this board"`. **UNTESTED ON HARDWARE** where a mic exists.

## espnow — raw frames between nearby devices, no router (needs `network` + `espnow` AND the user's approval)
```json
{"title": "My game", "permissions": ["network", "espnow"]}
```
ESP-NOW is connectionless 802.11: devices on the same channel hear each other's frames within radio range, with no access point,
DHCP or pairing. It is what crossplay's "play nearby" games and biscuit's mesh chat use. **The radio is exclusive:** `espnow.start`
refuses while WiFi is joined or a hotspot is up (`wifi.off()` first), and `wifi.connect`/`wifi.softap` refuse while it runs.
Leaving the app tears the radio down and reboots to Home, like every WiFi use. There are no callbacks: the backend keeps a 6-slot
ring filled from the WiFi task and `espnow.recv()` polls it, so no Lua code ever runs from the radio.

| call | notes |
|---|---|
| `espnow.start([{channel=1..13}])` → `true, mac` \| `nil, err` | Default channel 1 (every device in a game must use the same one). Needs 80 KB free RAM; measured on the X4: the radio takes ~55 KB (free 107 -> 52 KB), leaving ~49 KB at the low-water mark while sending and receiving |
| `espnow.send(to, data)` → `true` \| `nil, err` | `to` = `"aa:bb:cc:dd:ee:ff"` (either case), `"broadcast"` or `nil` (also broadcast). `data` is 1..250 bytes, binary-safe. `true` means the frame was handed to the radio: **ESP-NOW has no delivery guarantee**, add sequence numbers and acks in your protocol. A unicast peer is added on first use (the radio keeps at most 20) |
| `espnow.recv()` → `data, mac` \| `nil` | Never blocks. `nil` alone = nothing waiting; `nil, err` = not started. Frames arrive oldest first; when the 6-slot ring is full new frames are dropped and counted |
| `espnow.info()` → `{mac, channel, dropped}` \| `nil, err` | `dropped` = frames lost to a full ring since `start` |
| `espnow.stop()` | Always allowed. `wifi.off()` also stops it |

The approval screen lists permissions as short labels packed onto as few lines as fit, most sensitive first
(`MICROPHONE, ESP-NOW` / `SNIFFER, INJECT, AP` / `SERVER, SPEAKER`), because the native dialog clips after about three lines.

## wifi.monitor — passive 802.11 capture + native PCAP writer (needs `network` + `monitor` AND the user's approval)
```json
{"title": "Sniffer", "permissions": ["network", "monitor"]}
```
Promiscuous capture of management and data frames on one fixed channel. The approval screen labels it `SNIFFER`, because passively
recording everything in radio range is at least as sensitive as a microphone. **The radio is exclusive:** it refuses while WiFi is
joined, a hotspot is up or `espnow` runs (and those refuse while it runs); `wifi.off()` also stops it. Leaving the app tears the radio
down and reboots to Home, like every WiFi use. There are no callbacks: the backend keeps an 8-slot ring filled from the WiFi task
and `wifi.monitor_recv()` polls it, so no Lua code ever runs from the radio. Capture is on one channel (no hopping: `start` again
on another channel after `stop`).

| call | notes |
|---|---|
| `wifi.monitor_start([{channel=1..13, file="data:x.pcap"}])` → `true` \| `nil, err` | Default channel 1. With `file` a PCAP is written natively (same write rules as `mic.record`: `data:` always, `sd:` only inside a granted folder, must end in `.pcap`). Needs 80 KB free RAM, or 48 KB once the radio has already been used in this app (its RAM never fully returns). Measured on the X4: the radio takes ~55 KB (free 105 -> 49 KB) |
| `wifi.monitor_recv()` → `frame, {rssi, channel}` \| `nil` | Never blocks. `nil` alone = nothing waiting; `nil, err` = not started. `frame` is the raw 802.11 frame **truncated to 250 bytes** (the PCAP file records the original length) |
| `wifi.monitor_info()` → `{channel, captured, dropped[, file, bytes]}` \| `nil, err` | `captured` counts every frame seen, `dropped` those lost to a full ring (the PCAP still gets them). `file` is the resolved on-card path and `bytes` what has reached the card so far: the writer buffers 2 KB, so most of a short capture flushes at `stop` |
| `wifi.monitor_channel(n)` → `true` \| `nil, err` | Hops to another channel (1..13) **while running**: the sniffer and the injector follow together (one radio, one channel). Frames captured before the hop stay queued. Requires the monitor or the injector running |
| `wifi.monitor_stop()` → `bytes` | Flushes and closes the PCAP; returns its total size (0 without a file). Always allowed |

The PCAP is standard libpcap 2.4 (microsecond magic `0xa1b2c3d4`, LINKTYPE_IEEE802_11 = 105) that Wireshark/scapy open directly.
Timestamps are microseconds **since boot**, not wall-clock time. Verified on the X4 against an injecting adapter: the file parsed
with scapy, 16 records, inter-frame gaps matching the injection cadence.

## wifi.tx — raw 802.11 frame injection (needs `network` + `tx` AND the user's approval)
```json
{"title": "Recon", "permissions": ["network", "monitor", "tx"]}
```
Sends raw 802.11 frames on one fixed channel (deauth, beacon, custom action frames — biscuit's offense suite). The approval screen
labels it `INJECT`: sending arbitrary frames can disrupt other people's devices, so it is gated harder than the sniffer. The radio
rules are the same as the monitor's (exclusive with WiFi/the hotspot/espnow, `wifi.off()` stops it, leaving the app reboots), with
one exception: **the injector and the sniffer may run at the same time on the same channel** — a start with no channel adopts the
other mode's channel, and an explicit different one is refused. Frames sent are not received back by the device's own sniffer.

| call | notes |
|---|---|
| `wifi.tx_start([{channel=1..13}])` → `true` \| `nil, err` | Default: the monitor's channel when it runs, else 1. Same RAM floors as the monitor (the radio's own RAM is already spent when another radio mode runs, so no extra floor then) |
| `wifi.tx(frame)` → `true` \| `nil, err` | The raw 802.11 frame **without the FCS** (the radio computes and appends it), 24..250 bytes, binary-safe. `true` means the radio accepted the frame: **802.11 has no delivery guarantee**, verify effects on the receiving side. Frames from your own device do not loop back into `wifi.monitor_recv()` |
| `wifi.tx_info()` → `{channel, sent}` \| `nil, err` | `sent` counts frames the radio accepted |
| `wifi.tx_stop()` | Always allowed |

Verified on the X4 with a monitor-mode adapter: frames injected from Lua were captured on the air byte for byte (15/15 accepted
by the radio, 13/15 seen by the host's sniffer in range).

## ble — Bluetooth LE keyboard (needs `bluetooth` AND the user's approval; verified lifecycle on the X4, typing needs a keyboard)
```json
{"title": "Notes", "permissions": ["bluetooth"]}
```
Pairs with a BLE HID keyboard (the SDK's `BleKeyboardHost`: the same NimBLE central, Just-Works bonding and key decoding the page
turner uses). Key presses arrive as `"key"` events from `input.wait`/`input.poll`, with `input.key()` giving the character, special
key and modifiers. The approval screen labels the permission `BLE`. BLE only: the chip has no Bluetooth Classic radio.

| call | notes |
|---|---|
| `ble.start([mode])` → true \| nil, err | brings the stack up. `mode` is `"keyboard"` (the default) or `"raw"` (see below); one mode at a time. **~52 KB of RAM** (measured 51,996 B on the X4); needs the radio floor (80 KB free, 48 KB after a radio was used) and **refuses while WiFi, the hotspot, espnow, the sniffer or the injector holds the radio** (and each of those refuses while Bluetooth is up). Also refuses while the Bluetooth page turner has the stack up |
| `ble.stop()` → true | gives the stack back; always allowed. Leaving the app reboots into a clean heap, like every radio app |
| `ble.scan([ms])` → true \| nil, err | starts a scan that ends by itself after `ms` (500..60000, default 5000); read with `ble.devices()` |
| `ble.scan_stop()` → true | |
| `ble.devices()` → `{ {addr, name, rssi, connectable, hid}, ... }` | what the scan has seen (at most 24; the SDK lists HID devices and named devices, sort by `rssi` yourself) |
| `ble.connect(addr [, addr_type])` → true \| nil, err | starts pairing/connecting (`addr` like `AA:BB:CC:DD:EE:FF`, either case; a bonded keyboard also reconnects on its own after `ble.start()`). Async: poll `ble.state()`. `addr_type` is `0` public (default) or `1` random static — only the gatt mode uses it |
| `ble.disconnect()` → true | drops the link, or **cancels an attempt in flight** (the stack is cycled for that: the SDK has no other way) |
| `ble.state()` → `{running, mode, link, scanning, addr, name, passkey, reason}` | `link` is `idle`, `connecting`, `connected` or `failed`. `passkey` appears only while pairing waits for you to type that number **on the keyboard** (then Enter); `reason` only after a failure |
| `ble.paired()` → `{ {addr, name}, ... }` / `ble.forget(addr)` | the bonded keyboards (kept in NVS) |

```lua
ble.start(); ble.scan(6000); app.sleep(6500)
for _, d in ipairs(ble.devices()) do if d.hid then print(d.addr, d.name, d.rssi) end end
ble.connect(addr)                         -- then wait for ble.state().link == "connected"
while true do
  local e = input.wait()
  if e == "key" then local k = input.key(); text = text .. (k.char or "") elseif e == "back" then break end
end
```

**Raw mode** (`ble.start("raw")`): NimBLE as a bare observer. Every advertisement is handed over as received, to parse yourself. Same
permission (`bluetooth`), same RAM and radio exclusivity as keyboard mode. The keyboard calls (`scan`, `devices`, `connect`, `paired`, `forget`)
refuse in raw mode and the raw calls refuse in keyboard mode, with a message that says which mode they need. Raw mode is the
bare radio (the central, observer and broadcaster roles): you can observe advertisements and broadcast your own at the
same time.

| call | notes |
|---|---|
| `ble.observe([ms [, {active=false}]])` → true \| nil, err | listens for advertisements for `ms` (500..600000, default 5000; **0 = until `ble.observe_stop()`**). Clears the table first. **Passive by default: nothing is transmitted**, so devices that put their name in the scan response show no name. `active=true` sends a scan request to every scannable device it hears (that is how names arrive) |
| `ble.observe_stop()` → true | |
| `ble.adverts()` → `list, dropped` \| nil, err | one entry per device heard since `observe()` started (first heard first, **at most 32**): `{addr, addr_type, rssi, adv_type, connectable, scannable, adv_len, age_ms, data}`. `data` is the advertising data followed by the scan response as raw bytes (at most 31 + 31), `adv_len` says where the scan response starts. `rssi` and `data` are those of the last packet, `age_ms` is the time since it. `addr_type` is NimBLE's: 0 public, 1 random (2 and 3: resolved private addresses). `adv_type`: 0 ADV_IND, 1 ADV_DIRECT_IND, 2 ADV_SCAN_IND, 3 ADV_NONCONN_IND, 4 SCAN_RSP. `dropped` counts **packets** (not devices) ignored because the table was full |
| `ble.state()` | in raw mode `mode = "raw"`, `scanning` tells whether the observer is listening, `link` stays `idle` |

| `ble.advertise(options)` → true \| nil, err | broadcasts **your own** advertisement (a beacon): `options` = `{name = "...", data = "<bytes>", connectable = false, interval_ms = ..., service_uuid = N, service_data = "<bytes>"}`. `name` and `data` (manufacturer data, < 31 bytes) are each optional but at least one of name/data/service_uuid is required; `connectable=true` advertises as connectable, default `false` is a non-connectable beacon; `interval_ms` is 0 (default ≈100 ms) or 20..10000. `service_uuid` (1..65535) + `service_data` (< 27 bytes) emit a service-data AD (e.g. Fast Pair `0xFE2C`); `service_data` requires `service_uuid`. Repeating replaces the advertisement |
| `ble.advertise_stop()` → true | ends the advertisement |
| `ble.advertising()` → boolean | whether you are currently advertising |

Parsing is left to Lua on purpose (a length/type/value walk is ten lines, see `lua_tests_lua/tests/bleraw.lua`). Legacy advertising only: extended
advertisements (coded PHY, long payloads) are not compiled into this build. Verified on the X4: passive and active scans, `observe(0)` + stop, six
start/observe/stop cycles with no heap left behind. What nearby devices reveal (addresses, names, manufacturer data) is exactly what a scan sees:
treat the results as personal data.

```lua
ble.start("raw"); ble.observe(6000, {active = true}); app.sleep(6500)
local list = ble.adverts()
table.sort(list, function(a, b) return a.rssi > b.rssi end)
for _, d in ipairs(list) do print(d.addr, d.rssi, #d.data) end
ble.stop()
```
### GATT mode (`ble.start("gatt")`)

A generic BLE GATT client — bare NimBLE central, no HID host. Connect to any peripheral and read/write its
characteristics or subscribe to its notifications (a GATT browser, a sensor, a remote). Same `bluetooth` permission,
same ~50 KB stack, same exclusivity (one radio at a time). `ble.connect(addr [, addr_type])` links a client (the raw
scan's `addr_type` field tells you whether to pass `1` for a random static address); poll `ble.state().link`
for `connected`, then `ble.services()` triggers discovery.

| call | notes |
|---|---|
| `ble.services()` → list \| nil, err | the discovered characteristics, one table per attribute, in order: `{service, uuid, handle, props}`. UUIDs use the canonical spelling (16-bit short `"2a19"`, 8-hex, or the 128-bit dashed form); `props` is the bitmask (0x01 broadcast, 0x02 read, 0x04 write-no-response, 0x08 write, 0x10 notify, 0x20 indicate, 0x40 signed-write, 0x80 extended). `nil, not connected` when there is no link |
| `ble.read(uuid)` → data \| nil, err | the characteristic's value as a byte string (max 244 bytes) |
| `ble.write(uuid, data [, {no_response=false}])` → true \| nil, err | writes `data` (string, max 244 bytes); `no_response=true` is write-without-response |
| `ble.notify(uuid, on)` → true \| nil, err | subscribes (`true`) or unsubscribes to notifications/indications |
| `ble.notifs()` → `{ {uuid, data}, ... }` | the pending notifications, oldest first (at most 32; each call drains them) |

UUIDs are matched case-insensitively against the cached discovery — call `ble.services()` first. An unknown or missing
characteristic reports `no such characteristic`.

```lua
ble.start("gatt"); local d = nil
for _, x in ipairs(nearby_addrs) do d = x end       -- from a raw scan, or hardcoded
ble.connect(d); for i = 1, 100 do if ble.state().link == "connected" then break end; app.sleep(100) end
for _, c in ipairs(ble.services()) do print(c.service, c.uuid, c.props) end
print(ble.read("2a19"))                              -- e.g. battery level
```

Not yet: acting as a keyboard/device (the HID peripheral role — DuckyScript-style keystroke injection), and a GATT
server (others connecting to us, as opposed to the GATT client above which connects TO others).

## epub — book metadata without opening the book
| call | notes |
|---|---|
| `epub.meta(path)` → `{title = , author = }` \| `nil, err` | title and author from the EPUB's OPF, using the firmware's own metadata-only parse (the one the library indexer runs on books nobody has opened: no cache is built, no pages laid out). `path` must end in `.epub` (any case) and is resolved like `zip.*` (`app:` / `data:` / `sd:` with the `library` permission or a storage grant). Fields are always strings (`author` is `""` when the book has none); results are cut at 199 / 119 bytes on a whole UTF-8 character. Errors: `not an .epub file`, the sandbox's message, `cannot read the book (not an EPUB, corrupt, or no RAM)`, or `not enough free RAM to read the book (free NK, need 64K)`. **RAM (measured on the X4): the parse peaks at about 55 KB of heap and takes ~17 ms**, so call it from an app that has not claimed most of the heap (the call itself leaves no leak: free changed by -224 B, largest block unchanged) |
| `epub.progress(path)` → `percent` (0..100) \| `nil, err` | the saved reading progress for a book (the firmware's own `loadBookProgress`, reading `progress.bin` from the book's cache — never builds reading caches). `path` must end in `.epub` or `.xtc` (any case) and is resolved like `epub.meta`. Errors: `not a .epub or .xtc book`, the sandbox's message, or `no saved progress for this book` (also returned when the file is gone/corrupt — the firmware gives no progress then). Read-only: writing progress (`epub.set_progress`) is out of scope for now. `nil` percent is never returned — a book with no progress is the `nil, "no saved progress…"` case |

## json
`json.encode(value)` → string \| nil, err · `json.decode(string)` → value \| nil, "msg at byte N" · `json.null` (sentinel for JSON null).
Arrays are tables with keys 1..n; everything else encodes as an object (string keys only). Decode never throws; nesting depth limit 24.
Integral numbers that fit int32 decode to integers, others to floats (single precision) — don't round-trip 64-bit ids through JSON.
Memory: the result is built in a few KB of staging chunks; budget roughly 2–3× the document size while encoding/decoding.

## xml
`xml.parse(text)` → node \| nil, err. Parses a well-formed XML document into a tree (expat; firmware-vendored, host uses system libexpat). A `node` (element) is a table `{ tag = name, attrs = {attr = value, ...} }` whose children are appended positionally: a **string** child is text (character data merged with adjacent CDATA), a **table** child is a nested element. Comments and processing instructions are dropped; namespaces are not resolved (tags keep their prefix, `dc:title`). The document's single root element is returned. Limits: input ≤ 64 KB, nesting depth ≤ 32; malformed XML returns `nil, err` (expat's message).

## Writing binding code (C++)
`lua_error`/`luaL_check*` longjmp: never hold objects with destructors (std::string, RAII locks) across them.
Backends: `src/lua/LuaApi.h` (`Backend` interface). Host tests: `test/lua_host/run.sh`.

## Planned (see PLAN.md)
`net` (raw TCP), `ble`/`hid`, `radio`, orientation control, HTTP streaming callbacks.
