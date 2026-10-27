# CrossLua feature matrix — what the other forks need from us

Sources: per-fork surveys in `/root/x4/scratch/features/{crossplay,biscuit,ruby,avesO3,crosspoint-native}.md`
(subagent read-throughs, LOC counts measured) plus a direct read of Grimoire's API doc and its 8 spells + launcher
(72 unique API calls, see `docs/lua/GRIMOIRE.md`). This file deduplicates their "API gaps" lists into ONE runtime
roadmap, ordered by how many features each primitive unblocks and how cheap/safe it is on the X4 (no PSRAM, ~96 KB
Lua heap). Verdicts in the per-fork files; here only the gaps.

## Tier 1 — trivial native bindings, unlock the most (one build)
**Status: every Tier 1 and Tier 2 row below is implemented** (checked against the registered functions in `src/lua/`: wifi.scan, time.sync/set, fs.rename, system.mac/usb, gfx.qr, device.haptic/frontlight, zip.inflate, gfx.image, crypto, input.text, save_bmp, epub.meta, net). Open work is Tier 3, the parked hardware rows (BLE, COLOR gfx model, `device.wake_in`), and app categories.

| primitive | unlocks | notes / where it comes from |
|---|---|---|
| `wifi.scan()` → `{ssid,rssi,enc}` | ~22 biscuit apps, crossplay, AvesO3, Grimoire `ble_client`-style pickers | Arduino `WiFi.scanNetworks`; permission `network`. Passive. |
| `time.sync([server])` + `time.set(epoch)` | clock everywhere: biscuit TOTP/clock/logger, crossplay, AvesO3, Grimoire `time_demo` | X4 has no RTC; NTP over existing WiFi. `configTime`+`getLocalTime`. |
| `fs.rename(from,to)` (+ `fs.mkdir` already recursive) | atomic temp+rename pattern used by crossplay Live/Wallpapers/Study bridge, AvesO3 book swap | SdFat `rename`; `data:`-scoped like `fs.write`. |
| `system.mac()` | Ruby SPECIMEN id, biscuit ghost/hunt | 6-byte eFuse via `esp_read_mac`. |
| `system.usb()` | battery-ish status rows | trivial flag. |
| `gfx.qr(text, x, y [, scale])` | 5 biscuit apps, AvesO3 AO3-page QR | `src/util/QrUtils` already linked; render matrix with `gfx.pixel/rect`. |
| `device.haptic(ms)` | game feedback | `lib/HalHaptics` singleton, ~0 RAM. |
| `device.frontlight(level)` | night reading | `lib/hal/HalFrontlight`; no-op if board lacks it. |
| `zip.inflate(bytes)` | StarDict `.dict.dz` (crossplay dict, AvesO3), general .gz | uzlib (`lib/uzlib/tinflate`) already linked; size cap + streaming-forbidden (whole entry only, ≤64 KB). |

## Tier 2 — moderate, high value

| primitive | unlocks | notes |
|---|---|---|
| `gfx.image(path, x, y [, box_w, box_h])` PNG/BMP/JPEG → 1bpp blit | Grimoire `image.*`/gallery, crossplay wallpapers/xkcd/Study images, AvesO3 covers, Ruby creature art, biscuit BMP viewer | Decoders already linked (`PngToBmpConverter`, `JPEGDEC`, BMP). Stream row-by-row, cap target at ~one screen (48 KB), clip to screen. Biggest single feature win. |
| `net` raw TCP: **client done** (`info/resolve/connect/read/write/available/connected/close`, v0.14, verified on the X4); UDP, listen/accept and mDNS done (verified on the X4, 14 mutants each), Back cancels a blocking connect; TLS client sockets done (verified on the X4, 17 mutants) | Grimoire `net.*` (wifi_server_test, events lib), biscuit host scanner/ports, HTTP-in-Lua experiments | lwIP sockets via BSD API. Server + client; watch heap; yield in loops. See [NET_SOCKETS_PLAN.md](NET_SOCKETS_PLAN.md): survey of what CrossPoint/SecureNet/Grimoire/biscuit already use + built API + on-device RAM/timing measurements |
| `crypto.sha256/hmac_sha1/hmac_sha256/aes_*` | biscuit TOTP×2, PIN lock, SD encryption; Grimoire "pin your own content" pattern | wolfSSL already linked; expose digest + HMAC first, AES-CBC/GCM later. |
| `input.text()` modal keyboard (sub-activity, like the WiFi picker) | search/forms in apps: biscuit password manager, Grimoire settings UI | `KeyboardEntryActivity` exists; same parked-VM pattern as `wifi.connect`. |
| `gfx.save_bmp(path)` (screenshot from inside an app) | tests, bug reports, sharing | **done**: binds `ScreenshotUtil::saveFramebufferAsBmp` (streams, no heap). 240 ms, pixel-identical round trip on the X4, 7 mutants caught. |
| `epub.meta(path)` → `{title, author}` (no layout) | AvesO3 library, "about this book" apps | **done**: binds the firmware's `Epub::loadMetadata` (metadata-only OPF parse, no cache). Language is not exposed (that parse path does not return it). Measured on the X4: ~17 ms, ~55 KB heap peak, no leak; 10 mutants caught. |

## Principle: touch upstream as little as possible
New features live in CrossLua-owned files (`src/lua/`, `src/activities/plugins/LuaAppActivity.*`, `lib/lua/`) and call existing SDK/firmware APIs
read-only. An edit to an upstream-owned file needs a reason that cannot be met inside our files, is `#ifdef`-gated when it is dev-only, and is
logged in `UPSTREAM_TOUCHPOINTS.md`. Rejected on this basis: setting the FAT clock (`HalStorage`) just to make `fs.stat().mtime` real.

## Principle: CrossPoint is not only the X4
Build the feature for every board the firmware supports, even when the X4 (our only test device) lacks the hardware.
- Hardware features are gated by the firmware's own `FREEINK_CAP_*` flags and report honestly when absent: `nil/false, "no <thing> on this device"`, never a crash.
- Apps discover what exists with **`device.caps()`** (below) instead of guessing the model.
- Features we cannot exercise on the X4 are marked **UNTESTED ON HARDWARE** in `API.md` until someone with the device confirms them. Host tests cover the plumbing (arguments, limits, events, caps gating) with a mock backend; they do not prove the physical behaviour.

| item | status | notes |
|---|---|---|
| `device.caps()` | to do | table: `touch`, `haptic`, `frontlight`, `warmlight`, `color`, `audio`, `ble_keyboard`, `usb_msc`, `width`, `height` from `FREEINK_CAP_*` + `BoardConfig` |
| `device.haptic(ms [, strength])` | to do | `HapticManager` (Metalio E-Ink 4): single pulse, honours the user's vibration setting; `false, "no vibration motor on this device"` elsewhere. **UNTESTED ON HARDWARE** |
| touch input events | to do | `input.wait()` also returns `"tap"`, `"press"`, `"release"`, `"long"`; `input.pos()` -> x, y in screen pixels of the last touch event. Only fires when `caps().touch` |
| `system.usb()` | to do | `HalGPIO::isUsbConnected()`; works on the X4 |
| `device.motion()` (IMU) | to do | **done** (UNTESTED unless your board has an IMU) |
| `device.caps()` sensor flags | to do | **done** |
| frontlight warmth | done | `device.frontlight` already takes warmth; `caps().warmlight` says whether it does anything |

## Hardware coverage: every `FREEINK_CAP_*` flag, mapped to Lua (goal: support most CrossPoint hardware where possible)
Source of truth: `freeink-sdk/libs/hardware/BoardConfig` (16 flags) and the libs behind them. Each feature follows the same recipe: a `device.caps()` flag, a Backend method that wraps the SDK lib (stubs link on boards without the hardware), host tests with a mock, honest `nil/false, "no X on this device"` results, a line in `devtest_lua`, and a build of an env that has the hardware to prove it compiles. Status key: **done**, **todo**, **permission** (needs a manifest permission + user approval, like network/grants), **park** (needs design or a volunteer with the board).
| flag / hardware | SDK lib | Lua surface | status |
|---|---|---|---|
| `TOUCH` | MappedInputManager | `input` events `tap/press/long/release` + `input.pos()` | **done** (UNTESTED on hardware) |
| `HAPTIC` | HapticManager | `device.haptic(ms, strength)` | **done** (UNTESTED on hardware) |
| `FRONTLIGHT` / `WARMLIGHT` | FrontlightManager | `device.frontlight(...)` | **done** |
| `USB_MSC` | UsbMassStorage | caps flag only; Lua gets NO control (it would expose the SD card to a host) | caps **done** |
| `IMU` | Imu (LSM6DS3 / QMI8658 / SC7A20H) | `device.motion()` -> ax,ay,az (g), gx,gy,gz (deg/s), `gyro` flag | **done** (host-tested, 21 mutants; absence path verified on the X4; hardware path UNTESTED) |
| `TEMP_HUMIDITY` | EnvironmentSensor | `device.environment()` -> temp_c, humidity_pct | **done** (host-tested, 21 mutants; absence path verified on the X4; hardware path UNTESTED) |
| `BUZZER` | Buzzer | `device.tone(freq_hz [, ms])`, `device.tone()` stops | **done** (host-tested, 21 mutants; absence path verified on the X4; hardware path UNTESTED) |
| `LED` | LedManager | `led.count()`, `led.set(i, r, g, b)`, `led.all(r, g, b)`, `led.flash(r, g, b, n)`, `led.off()` | **done** (host-tested, 21 mutants; absence path verified on the X4; hardware path UNTESTED) |
| `RTC` | Rtc | caps flag; `time.*` already uses the trusted clock; later `device.wake_in(seconds)` (RTC wake timer for alarm-clock apps) | caps flag **done**; wake_in park |
| `AUDIO` | AudioManager | `audio.play(path [, loop])` (WAV from the SD card, same path rules as `fs`), `audio.stop()`, `audio.volume(pct)`, `audio.playing()` | **done** (host-tested, 9 mutants; absence path verified on the X4; hardware path UNTESTED — needs a board with a speaker) |
| `MIC` | Microphone | `mic.record(path, seconds)` (streamed WAV, Back cancels) / `mic.level([ms])`; a recording device must be consented to: `"microphone"` permission with an approval screen, never silent | **done** (host-tested, 12 mutants; absence path on the X4; hardware path UNTESTED, needs a board with a mic) |
| `BLE_KEYBOARD` / `BLE_HID_HOST` | BlePageTurner / HID host | key events into `input.wait` + caps; behind a `"ble"` permission | park |
| `COLOR` | display / gfx | needs a colour `gfx` model (RGB565 palette, `gfx.color(r,g,b)`); caps flag first | caps flag **done**; rest park |
| `NET_TLS13` | network | caps flag `tls13` so apps know what `http` can talk to | caps flag **done** |
Order of work: (1) caps flags for everything + `device.motion` + `device.environment` + `device.tone` + `led.*` (one pattern, small, no permissions); (2) `audio.*` and `mic.*` with the permission flow; (3) BLE keyboard and colour once someone can test them.

## Required for apps: Home Assistant control and other REST/JSON services (features first, apps after)
Target: a CrossLua app that reads and controls Home Assistant (`GET /api/states/<id>`, `POST /api/services/<domain>/<service>`
with a `Bearer` token). Audit of what `http.request` could do before this work: HTTPS, custom headers (GET only!), `json.encode/decode`,
`time.sync`, mDNS discovery. Gaps found by reading the code (not assumed):

| need | status | notes |
|---|---|---|
| POST with a JSON body | **done** (host-tested; verified on the X4) | `http.request` POST is hard-wired to `application/x-www-form-urlencoded`. Add `content_type`; a `Content-Type` header together with a body is refused (use the option) |
| custom headers on POST | **done** (was a bug; verified on the X4: the server saw `Authorization` on a POST) | the POST path (`HttpDownloader::postForm`) silently DROPS the caller's headers, so no `Authorization` header can reach a service call. Route POST through `SecureHttpClient`, which sends them |
| methods PUT / PATCH / DELETE | **done** (verified on the X4) | HA and most REST APIs use them; `SecureHttpClient::sendRequest` takes any method |
| certificate pinning for `http.request` (`ca=`) | **done** (verified on the X4: pinned CA accepted, wrong CA refused) | same `ca=` PEM rule as `net.connect{tls=true}`. An HA token is effectively admin, so the default "encrypted but unauthenticated" is a real risk. Default stays unverified for compatibility; documented |
| response headers (`response_headers=true`) | **done** (verified on the X4) | opt-in table (lower-case names; duplicates joined with `, `): rate limits, `Location`, `ETag`, `Retry-After` |
| `save_to` with POST / `ca=` / response headers | parked | the file path keeps the existing GET-only downloader; combining is refused with a clear message |
| secret store for tokens | parked | `data:` is already private per app; an encrypted-at-rest store needs a device key and a native approval flow: later |
| WebSocket client (HA push events), MQTT client | parked (library, not native) | doable in Lua over `net.connect{tls=true}` (handshake needs SHA-1 + base64: check `crypto`/`json` first). Plain polling covers a control panel |
| RAM headroom while a TLS request runs | **constraint, already studied** (see [MEMORY.md](MEMORY.md)) | Measured on the DEV build: ~46 KB free after `wifi.connect()` vs the 40 KB a TLS session needs, so ~5 KB of Lua data per request (the pinned handshake dips to ~4-5 KB free). A release build has ~9 KB more (no DevCapture buffers): ~14 KB. Tried and reverted with no gain: trimmed WiFi init, `HAVE_MAX_FRAGMENT`. Remaining levers: restart network apps into a lean state (+~40 KB, inside `LuaAppActivity`, larger design change) and parking the render task (needs upstream `ActivityManager` edits: rejected by the least-upstream rule). Not started; apps just drop their tables and `collectgarbage()` before a request |
| long-lived polling / background tasks | not planned | a request blocks the device and a TLS handshake peaks near 39 KB of RAM: a control panel is tap-driven, not a dashboard that refreshes every few seconds |

## Tier 3 — later / niche / heavy

| primitive | unlocks | why later |
|---|---|---|
| BLE `scan`/`central`/`peripheral`/`hid` (Grimoire `ble.*`, `hid.*`) | ~12 biscuit apps, Grimoire BLE spells, AvesO3 receive | Radio arbitration + NimBLE RAM; planned native radio-hooks milestone first. |
| `wifi.monitor` promiscuous + native PCAP writer, `wifi.tx` raw | biscuit recon/offense suite, Ruby sniffer | **`wifi.monitor_*` done and verified** (`"monitor"` permission with approval, polled 8-slot ring, native PCAP writer verified with scapy; radio exclusive with WiFi/hotspot/espnow; nothing upstream touched). `wifi.tx_*` **done and verified** (`"tx"` permission with approval, dialog label `INJECT`; coexists with the monitor on one channel; frames captured on the air byte for byte from Lua-injected frames). |
| `espnow.send/recv` | crossplay PLAY NEARBY (11 games), biscuit mesh chat/SOS | **done** (`espnow.start/send/recv/info/stop`, `"espnow"` permission with approval; polled 6-slot ring, radio exclusive with WiFi/hotspot, nothing upstream touched). |
| `wifi.softap` + captive DNS, `http.server` | biscuit dead-drop/bulletin/portal, crossplay web apps | **softap done and verified with a real client** (`wifi.softap`, `wifi.softap_info`, `"hotspot"` permission with approval; `net.*` works over it; WPA2 + DHCP + HTTP from a laptop-class client). The HTTP server and the captive-portal DNS are Lua libraries over `net.listen`/`net.udp_*`, not native code (nothing upstream touched). |
| `xml.parse` (expat binding) | OPDS feeds, OPF/NCX niceties | String-pattern scraping suffices for AO3/M2; revisit for OPDS. |
| `gfx.load_font(path)` TTF | custom fonts | Hard; FreeInkFont subsystem is deep. |
| deep sleep with wake-timers/retained frame | sleep screens, alarms | **`system.sleep(seconds)` + `system.last_wake()` done and verified** (arms the timer, enters upstream's own sleep flow read-only; the power button also wakes; a timer wake is a fresh boot, `last_wake()` reports it; no permission needed). Retained frame not exposed. |
| decimal arithmetic for Calculator | biscuit/crossplay Calculator | Lua can do string-based decimal add/sub; only worth it if the Calculator gets ported. |
| App categories / launcher for Lua apps (**parked, undecided**) | a flat Plugins list will not scale past a few dozen apps | Options discussed, no decision yet. **Mechanism is settled:** category = manifest `"category"` field only (not sub-folders: the Plugin Hub and `x4push` install flat at `/plugins/<name>`, data dirs are keyed by app name, `app.dir()` would change). **A.** native "Lua apps" screen (C++): fast, no VM RAM, but more C++ UI + one upstream entry point, not replaceable. **B (recommended).** a launcher that is itself a Lua app (`apps_lua`): zero upstream UI edits, replaceable, Recent/Favorites in plain Lua; needs new `app.list()` + `app.launch(name)` behind a `"launcher"` permission with an approval screen, costs ~15-20 KB RAM while browsing, one extra step; the flat list stays unless a tiny optional filter hides Lua apps (`"listed": false`). **C.** edit `PluginCatalogActivity` in place: one list, but risky (paging/index/uninstall-return logic in a 1,740-line upstream file, merge pain). Optional later: `/.crosslua/categories.json` override so users can re-sort without editing manifests. |

## Requested
- **Per-folder storage grants** (IMPLEMENTED, host-tested, 10 mutants, verified on the X4: native approval screen, Deny keeps the app from starting, approval persists, grants_lua 14/14; see API.md "Storage grants"): manifest
  `"storage": {"read": ["Books"], "write": ["Books/AO3","Downloads"]}` (`"/"` allowed for file managers). First launch shows a NATIVE
  confirmation listing the grants in plain words; approval stored in a hidden firmware-owned file (re-prompt when an
  update widens the grants). Hidden/dot paths and firmware images are NEVER grantable; `/plugins` (other apps' code) needs a
  separate louder warning. Enables `sd:` writes + `http save_to sd:Books/..`, `fs.rename/remove` inside grants, `app.open(path)`
  (reader today; text/image viewers later). File-browser apps additionally needed `fs.stat` / detailed `fs.list` (size, type, mtime): **done** (`fs.stat`, `fs.list{detail,offset,limit}`; host-tested, 26 mutants; verified on the X4). Not planned (not planned): a FAT clock, so device-created files keep one default stamp.

## Also requested, scheduled for later
- **`app.restart(entry)` (implemented, host-tested, 6 mutants; verified on the X4 via the Grimoire launcher -> run.lua -> launcher round trip)** — the app quits itself and is relaunched immediately with a different entry script (`main.lua` by
  default), giving a fresh VM and a fresh budget while still being ONE plugin entry. Use case: a menu shell (browse /
  update / about) whose network sub-app needs a lean start. Needs a small `LuaAppActivity` change (re-enter with a new
  entry name; WiFi radio torn down first). Alternative/complement: manifest `"apps": [...]` listing several entry
  points under one folder. Until then: one plugin, `main.lua` is a menu that `require`s modules (same VM).
  Measured reason it matters: the Grimoire launcher+shim+spell share one VM (49 KB Lua), leaving a 37 KB largest block, which is
  below the 60 KB the PNG decoder needs, so `image.draw` cannot run in-VM; a fresh VM per spell (launcher stores the choice in
  `data:` then `app.restart`) frees ~15-20 KB.

## Stays native (never Lua)
EPUB/XTC layout engine (exposed via `app.open_book`), OTA/flash, USB MSC/HID, web server internals, deep-sleep
sequencing, panic capture, high-rate promiscuous streaming.

## Cross-fork portability verdicts (headline numbers)
- **crossplay:** ~20 features portable now; 25 games' logic portable; images/`radio` are the blockers for the rest.
- **biscuit:** ~48 portable now, ~60 need APIs (mostly wifi.scan/BLE/monitor/softap), ~12 native-only.
- **AvesO3:** library/dashboard portable after `epub.meta`+`image`+`fs.rename`; parser spec captured in `scratch/features/avesO3.md` §4 (239-byte index record, `progress.bin` layout, sort/filter semantics).
- **Ruby:** passive RF analyzer — needs the native `capture.*` service; screens port after Tier-2 gfx.
- **Grimoire:** spells are Lua scripts against a polled API; a thin Lua shim covers `display/input/fs/zip/time/system/wifi/http` (≈80 % of calls). Missing: `image.*`, `ble.*`, `hid.*`, `net.*`, AP mode, `fs.dofile`, `zip.inflate`, `time.sync`.
