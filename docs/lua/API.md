# CrossLua app API (v0.8)

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
| `gfx.text(x, y, str [, font="ui" [, flags]])` | `y` is the top of the line. `flags` string: `b` bold, `i` italic, `w` white text, `c` centre on x, `r` right-align to x |
| `gfx.text_width(str [, font [, flags]])` → px | |
| `gfx.line_height([font])` → px | |
| `gfx.present([mode])` | pushes the frame to the panel. `"fast"` (default), `"half"`, `"full"` (clears ghosting, slow) |
| `gfx.image(path, x, y [, box_w, box_h])` → drawn_w, drawn_h \| nil, err | PNG/JPEG (`.png .jpg .jpeg`) from `app:`/`data:`/`sd:` (`sd:` needs `library`; hidden paths refused). Decoded row by row by the firmware (RAM does not scale with the source; sources up to 8 MP / 6 MB), dithered to black/white into the current frame. The box defaults to x,y..screen edge and is clipped to the screen; the image is **fitted into the box, never upscaled, and centred**; the return values are the size actually drawn. Errors are values: `no such file`, `unsupported image type`, `cannot read the image header`, `not enough free RAM to decode`, `decode failed`. Needs a free contiguous block of ~60 KB, so an app with a huge Lua heap can get the RAM error. Call `gfx.present()` afterwards. |

Fonts: `ui`, `ui12`, `small`, `sans12`, `sans14`, `sans16`, `sans18` (CrossPoint's built-in fonts, same as the rest of the UI).
Nothing reaches the panel until `gfx.present()`. Coordinates may be floats (truncated).

## input
| call | notes |
|---|---|
| `input.wait([timeout_ms])` → name \| nil | yields to the firmware until a button is released or the timeout passes (`nil`). No timeout = wait forever. **Prefer this over polling** — the device idles/sleeps normally. |
| `input.poll()` → name \| nil | non-blocking |

Event names: `back confirm left right up down`. Events are delivered on button *release*. Holding Back ≥ 1 s quits the app and is never delivered.

## app
`app.sleep(ms)` (timer only — buttons stay queued) · `app.exit()` · `app.name()` · `app.dir()` (e.g. `/plugins/hello_lua`)

`app.entry()` → the script this VM was started from (`"main.lua"` unless `app.restart` chose another).

`app.restart([entry="main.lua"])` → `false, err` | never returns. The app quits and starts again from `entry` (a plain
`.lua` file name in the app's own folder: letters, digits, `_ - .`, no slashes, no leading dot) in a **fresh VM**: a new heap
budget, no leftover globals or modules, WiFi radio switched off. Nothing else is carried over, so pass state through `data:`
files. Use it to give a heavy sub-app a lean start (a launcher that holds a menu, then restarts into a worker script). Errors
are values (`entry must be a plain .lua file name...`, `no such entry script`); on success the call never returns.

## system
`system.millis()` (31-bit, wraps ~24 days — compare with subtraction) · `system.heap()` → free, min_free, largest free block (device RAM) ·
`system.lua_mem()` → used, peak, budget (this app's Lua heap) · `system.battery()` → percent

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
| `fs.list(path)` | sorted array of names, folders end in `/` \| nil, err (`fs.list("data:")` lists your save folder) |
| `fs.mkdir(path)` / `fs.remove(path)` | true \| nil, err (`data:` only; remove works on files and *empty* folders) |

## require
`require("name")` loads `name.lua` (or `name/init.lua`) from the app folder, then from `/.crosslua/lib/`. Dots are folder
separators: `require("util.strings")` → `util/strings.lua`. Modules are cached and may yield (e.g. call `input.wait`) while loading.
Circular requires and missing modules raise a clear error listing the places searched. Module names may only use letters, digits, `_` and `.`.

## time
| call | returns |
|---|---|
| `time.now()` | UTC epoch seconds, or `nil` if the device clock is not trustworthy (never synced, no RTC). The X4 has no RTC: the clock is restored from flash and re-synced (SNTP) whenever WiFi connects — use File Transfer or the Clock settings once. Fits a 32-bit integer until 2038 |
| `time.date([epoch])` | `{year, month, day, hour, min, sec, wday, yday}` in the **local** time zone (`wday` 1 = Sunday), or `nil` without a clock. Default epoch = now |

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
| `wifi.connect()` → true \| false, reason | Parks your script and hands the screen to the system's WiFi flow, which auto-joins the last saved network (usually no UI at all; otherwise the normal network picker/keyboard). **The screen is the system's afterwards: redraw.** Returns immediately with `true` if already connected. Input events do not wake it. **Refuses up front** (`false, "not enough free RAM for WiFi + TLS (free 86K, need 96K)…"`) when less than 96 KB is free: WiFi costs ~56 KB and TLS wants 40 KB on top. Always show `reason`. |
| `wifi.status()` → `{connected, ssid, ip, rssi}` | |
| `wifi.off()` | radio off now (frees RAM). Leaving the app always tears WiFi down anyway. |
| `http.request{url, method, headers, body, save_to, max_body}` → `{status, ok, bytes, body}` \| nil, err | see below |
| `http.get(url [, opts])` | `http.request` with `url` filled in |

`http.request` fields: `url` (`http://` or `https://`, ≤ 600 chars); `method` `"GET"` (default) or `"POST"` (body is sent as
`application/x-www-form-urlencoded`, ≤ 8 KB, response ≤ a few KB); `headers` = `{Name = "value"}` (≤ 12; CR/LF/`:` rejected);
`max_body` (1…65536, default 16384) caps an **in-memory** response; `save_to = "data:path"` streams the response to a file instead
(no size limit but the card; the result has no `body`; read it back with `fs.read(path, offset, len)`).
A non-2xx status is a result (`ok = false`), not an error. Errors (`nil, msg`): not connected, DNS/connect/TLS failure, response
larger than `max_body`, not enough RAM for TLS, user pressed **Back** (`"cancelled"`), bad arguments.

* **Calls block the device** (like every CrossPoint screen that talks to the network): draw "Loading…" and `gfx.present()` *before*
  calling. **Back cancels** a transfer.
* **HTTPS is encrypted but the server certificate is NOT verified.** CrossPoint's HTTP stack calls `setInsecure()` everywhere
  (the wolfSSL transport has no CA bundle wired up), so a machine on your network path can impersonate the server. Never send
  secrets you would not send over plain HTTP on that network; treat responses as untrusted input. (Planned: optional
  certificate pinning via a PEM shipped with the app, using `SecureHttpClient::setCACert`.) TLS needs ≥ 40 KB free RAM **and** a ≥ 20 KB contiguous block; otherwise the
  call fails with `not enough free RAM for TLS (free N, largest M)`. `system.heap()` returns `free, min_free, largest_block`;
  keep your Lua heap small in network apps (`collectgarbage()` first).
* After WiFi was used, leaving the app does a **silent reboot** to Home (the same defragmentation every WiFi screen does).
* Redirects, `Content-Length` checks and `.part` staging for downloads are done by CrossPoint's `HttpDownloader`.

## json
`json.encode(value)` → string \| nil, err · `json.decode(string)` → value \| nil, "msg at byte N" · `json.null` (sentinel for JSON null).
Arrays are tables with keys 1..n; everything else encodes as an object (string keys only). Decode never throws; nesting depth limit 24.
Integral numbers that fit int32 decode to integers, others to floats (single precision) — don't round-trip 64-bit ids through JSON.
Memory: the result is built in a few KB of staging chunks; budget roughly 2–3× the document size while encoding/decoding.

## Writing binding code (C++)
`lua_error`/`luaL_check*` longjmp: never hold objects with destructors (std::string, RAII locks) across them.
Backends: `src/lua/LuaApi.h` (`Backend` interface). Host tests: `test/lua_host/run.sh`.

## Planned (see PLAN.md)
`net` (raw TCP), `ble`/`hid`, `radio`, orientation control, HTTP streaming callbacks.
