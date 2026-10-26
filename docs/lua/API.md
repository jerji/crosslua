# CrossLua app API (v0.14)

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
| `gfx.text(x, y, str [, font="ui" [, flags]])` | `y` is the top of the line. `flags` string: `b` bold, `i` italic, `w` white text, `c` centre on x, `r` right-align to x |
| `gfx.text_width(str [, font [, flags]])` → px | |
| `gfx.line_height([font])` → px | |
| `gfx.present([mode])` | pushes the frame to the panel. `"fast"` (default), `"half"`, `"full"` (clears ghosting, slow) |
| `gfx.image(path, x, y [, box_w, box_h])` → drawn_w, drawn_h \| nil, err | PNG/JPEG/BMP (`.png .jpg .jpeg .bmp`) from `app:`/`data:`/`sd:` (`sd:` needs `library`; hidden paths refused). Decoded row by row by the firmware (RAM does not scale with the source; sources up to 8 MP / 6 MB), dithered to black/white into the current frame. The box defaults to x,y..screen edge and is clipped to the screen; the image is **fitted into the box, never upscaled, and centred**; the return values are the size actually drawn. Errors are values: `no such file`, `unsupported image type (png, jpg, bmp)`, `cannot read the image header`, `not enough free RAM to decode`, `decode failed`. RAM: **BMP needs only ~16 KB** (uncompressed 1/2/4/8/24/32-bit up to 2048x3072, read row by row, dithered, scaled to the box), JPEG ~24 KB, PNG ~62 KB (the decoder object is 59.5 KB). On a tight heap prefer BMP or JPEG; an app with a big Lua heap can get `not enough free RAM to decode`. Call `gfx.present()` afterwards. |
| `gfx.save_bmp(path)` → `true` \| `nil, err` | saves the CURRENT drawing buffer (draw first; `gfx.present` is not needed) as a 1-bit BMP in the panel's portrait orientation (480x800 on the X4, 48,062 bytes), using the firmware's own screenshot writer. Same write rules as `fs.write`: `data:` always, `sd:` only with a write grant, never `app:` or `*.bin`; the name must end in `.bmp` (any case); missing folders are created. Streams one row at a time (no heap) and takes about 240 ms on the X4. Verified: reloading the file with `gfx.image` gives a pixel-identical screen; 20 saves leak nothing. Handy for bug reports, sharing a result, or tests |

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

## crypto — hashes, HMAC, key derivation, AES, random (mbedtls; hardware SHA/AES on the device)
All byte strings are Lua strings (binary safe). Errors are `nil, err`; a wrong argument TYPE raises.
| call | notes |
|---|---|
| `crypto.sha256(data)` / `crypto.sha1(data)` → 32 / 20 raw bytes (SHA-256 over 100 KB: 2 ms on the X4, hardware accelerated) | data ≤ 64 KB; for more use `crypto.hash` |
| `crypto.hmac_sha256(key, data)` / `crypto.hmac_sha1(key, data)` → raw bytes | key and data ≤ 64 KB; keys longer than the block size are hashed first |
| `crypto.hash("sha256"\|"sha1")` → `h`; `h:update(chunk)` → `h`; `h:digest()` → raw bytes | incremental: hash a file with `fs.read(path, off, 8192)` in a loop. `digest()` ends the hash (a second call or an `update` after it is `nil, err`) |
| `crypto.pbkdf2_sha256(password, salt, iterations, len)` → raw bytes | iterations 1..20000, len 1..64, and iterations x ceil(len/32) ≤ 20000; blocks the app while it runs: measured on the X4, 4096 iterations take 0.2 s and the 20000 cap about 1 s |
| `crypto.aes_cbc_encrypt(key, iv, data)` / `crypto.aes_cbc_decrypt(key, iv, ciphertext)` | AES-128/192/256 (key 16/24/32 bytes), iv 16 bytes, PKCS#7 padding, data ≤ 32 KB. Measured on the X4: 8 KB encrypts in 4 ms, decrypts in 2 ms. Mind the Lua heap: input, output and your copies all live in it. CBC does **not** authenticate: store `hmac_sha256(mac_key, iv .. ciphertext)` with it, check it with `crypto.equal` **before** decrypting, never reuse an iv with one key. A wrong key usually shows up as `nil, bad padding ...`, but not always: only the MAC is a reliable check |
| `crypto.random(n)` → n raw bytes | n 1..256, the hardware RNG (`esp_fill_random`); WiFi/BT on gives true entropy |
| `crypto.equal(a, b)` → boolean | constant time for the length of `a`: use it for MACs and PIN hashes, never `==` |
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
| `device.caps()` → `{touch, haptic, frontlight, warmlight, color, audio, ble_keyboard, usb_msc, imu, gyro, rtc, temp_humidity, buzzer, mic, led, tls13, width, height}` | booleans except width/height. Adapt to the board instead of guessing the model. Everything is decided at RUNTIME from the board profile (one firmware image can serve several boards, e.g. X4 and X3), never from the model name. `gyro` is false on accelerometer-only IMUs. Flags for hardware that has no Lua API yet (`rtc`, `mic`, `audio`, `color`, `ble_keyboard`, `usb_msc`, `tls13`) only tell you the board has it |
| `device.haptic(ms [, strength])` → `true` \| `false, why` \| `nil, err` | one non-blocking pulse, ms 10..1000, strength 0..255 (default 255). `false` when the board has no motor or the user turned vibration off in Settings. **UNTESTED on hardware** (Metalio E-Ink 4 has the motor; compiles and links in that env) |
| `device.motion()` → `{ax, ay, az, gx, gy, gz, gyro}` \| `nil, err` | IMU sample: acceleration in g, angular rate in deg/s (zeros and `gyro=false` on accelerometer-only parts), axes already corrected to a board-independent frame. `nil, "no motion sensor on this device"` without an IMU; `nil, "motion sensor read failed"` can happen transiently (retry). The sensor is woken on first use and put back to sleep when the app ends. **UNTESTED unless your board has an IMU** |
| `device.environment()` → `temp_c, humidity_pct` \| `nil, err` | on-board temperature/humidity sensor (Sticky today). **UNTESTED on hardware** |
| `device.tone(freq_hz [, ms])` → `true` \| `false, why` \| `nil, err`; `device.tone()` stops | piezo buzzer, freq 20..20000, ms 0..10000 (0 = until `device.tone()`); silenced automatically when the app ends. **UNTESTED on hardware** |
| `led.count()` → n; `led.set(i, r, g, b)`; `led.all(r, g, b)`; `led.off()`; `led.brightness(0..255)` | addressable LEDs, `i` is 1..count, colours 0..255. `false, "no LEDs on this device"` without them (`led.count()` is 0); LEDs go dark when the app ends. Blink with `app.sleep`. **UNTESTED on hardware** |
| `system.usb()` → boolean | USB cable connected (a GPIO read on the X4) |
| `input.poll()` / `input.wait()` touch events | on touch boards also `"press"` (finger down), `"long"` (held), `"tap"` (quick touch), `"release"` (finger up). **UNTESTED on hardware** (needs a touch board; compiles and links for `x4pro` and `metalio_eink4`) |
| `input.pos()` → `x, y` \| `nil` | screen-pixel position of the touch event `poll`/`wait` returned last; `nil` after a button event or an empty poll. A `"release"` reports where the finger last was |
| `input.text(title [, initial [, max_len [, mode]]])` → `string` \| `nil, "cancelled"` \| `nil, err` | the system on-screen keyboard (touch or buttons, whatever the board offers). `title` ≤ 60 chars, `initial` ≤ 256 bytes and ≤ `max_len`, `max_len` 1..256 (default 128), `mode` `"text"` (default) \| `"password"` (masked) \| `"url"` (URL helper keys). Parks the script while the keyboard is up (like `wifi.connect`), so redraw afterwards; an empty string means the user confirmed an empty field |

## net — raw TCP client sockets (needs the `network` permission and WiFi up)

Plain TCP over the Arduino `NetworkClient` that CrossPoint already links for its web server (no extra network code). Join WiFi first with `wifi.connect()`. Same permission and "WiFi up" rules as `http.*`. Not implemented yet: TLS sockets (`{tls=true}` is refused, never silently ignored), UDP, mDNS, listening/accepting.

| call | |
|---|---|
| `net.info()` -> `{ip, mask, gateway, dns}` \| nil, err | The device's own addressing. (Not `net.local`: `local` is a Lua keyword.) |
| `net.resolve(host)` -> `"a.b.c.d"` \| nil, err | DNS (system timeout, blocks). An IPv4 literal is returned as is with no DNS traffic. Host names: letters, digits, `.` `-` `_`, at most 253 characters. |
| `net.connect(host, port [, {timeout_ms=5000}])` -> handle \| nil, err | Blocks up to `timeout_ms` (100..15000); Back does not interrupt it. Handles are small integers 1..4. Refused when 4 are open or under 16 KB free RAM. |
| `net.read(h [, max=512])` -> string \| nil, "closed" | Never blocks. `""` means nothing has arrived yet. `max` 1..4096. After the peer closes you still get everything it sent, then `nil, "closed"`. |
| `net.write(h, data)` -> n \| nil, err | `data` at most 16384 bytes per call; **n can be less than `#data`**: loop on the returned count. |
| `net.available(h)` -> n | Bytes waiting (0 when none or closed). |
| `net.connected(h)` -> boolean | False once the peer closed and everything it sent has been read. |
| `net.close(h)` -> true \| nil, err | A handle that is not open (including one already closed) is an error value, not a crash. |

Sockets still open when the app ends are closed (the radio is shut down then anyway).

**RAM, measured on the X4 with WiFi up (44.7 KB free):** an open idle socket costs 3.4-3.8 KB (4 idle sockets: 14.3 KB, all returned on close); one after a ping/echo 6.8 KB; one whose receive window is full about 16 KB. Streaming 64 KB with prompt reads dips free heap to ~16.7 KB with a small script (to ~5.8 KB with a 13 KB-larger Lua heap, which still completed with a matching hash) and took 212-856 ms across runs (74-301 KB/s: WiFi and LAN variance). Closed sockets sit in lwIP TIME_WAIT: the first ~40 connect/close cycles cost ~4.6 KB, then the cost plateaus (the next 120 cycles: +212 bytes). **Two or more sockets being flooded at once while the app does not read can exhaust memory**: read promptly, and treat one busy socket as the norm. `net.read` may go down to a 6 KB floor for the single allocation that copies data out of the stack (that relieves the pressure; the floor is restored right after).

`wifi.connect()` itself still needs 96 KB free to start (sized for TLS), so keep `main.lua` small and load bigger code after the radio is up (`load(fs.read("app:tests.lua"))`), as `socktest_lua` does.

## epub — book metadata without opening the book
| call | notes |
|---|---|
| `epub.meta(path)` → `{title = , author = }` \| `nil, err` | title and author from the EPUB's OPF, using the firmware's own metadata-only parse (the one the library indexer runs on books nobody has opened: no cache is built, no pages laid out). `path` must end in `.epub` (any case) and is resolved like `zip.*` (`app:` / `data:` / `sd:` with the `library` permission or a storage grant). Fields are always strings (`author` is `""` when the book has none); results are cut at 199 / 119 bytes on a whole UTF-8 character. Errors: `not an .epub file`, the sandbox's message, `cannot read the book (not an EPUB, corrupt, or no RAM)`, or `not enough free RAM to read the book (free NK, need 64K)`. **RAM (measured on the X4): the parse peaks at about 55 KB of heap and takes ~17 ms**, so call it from an app that has not claimed most of the heap (the call itself leaves no leak: free changed by -224 B, largest block unchanged) |

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
