# CrossLua feature matrix — what the other forks need from us

Sources: per-fork surveys of crossplay, biscuit, Ruby, AvesO3 and CrossPoint itself
(subagent read-throughs, LOC counts measured) plus a direct read of Grimoire's API doc and its 8 spells + launcher
(72 unique API calls, see `docs/lua/GRIMOIRE.md`). A second audit pass over the same firmwares (2026-10-28, findings checked against `src/lua`) is merged in the "Next up" section below. This file deduplicates their "API gaps" lists into ONE runtime
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
| `crypto.device_key(label)` + `vault.lua` + the Authenticator app | biscuit TOTP, "pin your own content" | **done** (verified on the X4: ~1 s per derivation, key survives a deep-sleep reboot). Per-app HMAC of the upstream NVS device secret; vault = PIN-wheel/passphrase + PBKDF2 + AES-256-CBC + HMAC. No attempt counter by design. See `docs/lua/VAULT.md` |
| `input.text()` modal keyboard (sub-activity, like the WiFi picker) | search/forms in apps: biscuit password manager, Grimoire settings UI | `KeyboardEntryActivity` exists; same parked-VM pattern as `wifi.connect`. |
| `gfx.save_bmp(path)` (screenshot from inside an app) | tests, bug reports, sharing | **done**: binds `ScreenshotUtil::saveFramebufferAsBmp` (streams, no heap). 240 ms, pixel-identical round trip on the X4, 7 mutants caught. |
| `epub.meta(path)` → `{title, author}` (no layout) | AvesO3 library, "about this book" apps | **done**: binds the firmware's `Epub::loadMetadata` (metadata-only OPF parse, no cache). Language is not exposed (that parse path does not return it). Measured on the X4: ~17 ms, ~55 KB heap peak, no leak; 10 mutants caught. |

## Next up — ordered build list (second-pass audit, 2026-10-28)

Eight read-through audits of the same five firmwares (a second look, challenging the first pass) produced about 340 findings, which collapse to
the ~29 primitives and the app batches below. **✔ = the claim was checked against `src/lua`** (registered functions, signatures); the rest is the audit's
word. Order = leverage per effort, cheapest first. Everything here is NOT built yet unless it says so.

### Primitives

| # | primitive | unlocks | effort | notes |
|---|---|---|---|---|
| 1 | `crypto.md5` (+ `crc32`) | KOReader sync (document id + `x-auth-key`), Calibre | S | **done**: `crypto.md5`, `crypto.hash("md5")`, `crypto.crc32` (host-tested against hashlib/zlib vectors) |
| 2 | `wifi.join(ssid, password)` or `wifi.connect{ssid=, password=}` | network pickers, provisioning apps | S | ✔ `wifi.connect` only takes `{tls}` and auto-joins the saved network |
| 3 | button hold: `input.held_ms()` or hold events | games (flag/hold-to-delete), long-press menus | S | ✔ button events are release-only; only touch has `"long"` |
| 4 | `led.flash(r, g, b [, n [, on_ms [, off_ms]]])` | notification patterns | S | ✔ was listed as done by mistake; `LedManager::flash` exists |
| 5 | `system.battery()` detail: charging, millivolts, mA | power screens | S | percent only today |
| 6 | `fs.volume()` (SD free/total), `fs.rmdir` (recursive) | disk-full warnings, cache clearing, archive/restore | S | `fs.remove` only removes empty folders |
| 7 | `wifi.scan` fields: BSSID, channel, auth mode, hidden | scanners, pickers, heat maps | S | ✔ rows are `{ssid, rssi, encrypted}` today |
| 8 | `net.mdns_advertise` (+ the UDP discovery companions use) | Calibre/transfer discovery | S | ✔ only `mdns_query` exists |
| 9 | small getters: `system.reboot`, `system.language`, `system.mem`, `device.caps().model`, `time.tz`, `system.panic_info` | diagnostics, localisation | S | |
| 10 | `wifi.set_mac` | MAC rotation | S | |
| 11 | `gfx.wrap` / `gfx.char_width` / hyphenation helper | every text app hand-rolls line breaking | S | |
| 12 | `crypto.aes_gcm` (+ `x25519`, `hkdf`) | encrypted logs, app-to-app crypto | S-M | mbedtls GCM is linked |
| 13 | `decimal.*` (decNumber) | exact Calculator (Lua floats are 32-bit) | S | |
| 14 | **`xml.parse` (expat, already linked)** | OPDS/RSS/Atom, EPUB NCX/nav, TOC, AO3 niceties | M | **requested by 6 of the 8 audits: the most wanted primitive** |
| 15 | BLE generic GATT client (+ a "remote" page-turner mode) | GATT browser, sensors, remotes | M | central role works with the current sdkconfig, one connection, small MTU; advertising/peripheral needs an sdkconfig change |
| 16 | **firmware-state bridge**: read-only `epub.progress`, recent books, reading stats, library index | AO3, reading stats, shelves, Ruby-style apps | M | **design decision**: apps cannot see the firmware's hidden folders by design, and this wall blocks the most app ideas after xml |
| 17 | settings API: `system.setting(name [, value])` over an allowlist (sleep-screen mode, sleep timeout, orientation) | sleep-screen designer, "Live" photo, settings hub | M | needs an upstream hook; decide together with #16 |
| 18 | `gfx.load_font(path)` (`.cpfont` everywhere, TTF only on PSRAM boards) | custom/CJK/serif fonts | M | ✔ 7 fixed fonts today |
| 19 | dictionary: native `dict.lookup` **or** a Lua StarDict | reference apps | M | ✔ `zip.inflate` (64 KB in / 96 KB out) already covers `.dict.dz` chunks, so the Lua route works today |
| 20 | `epub.toc`, more `epub.meta` (language, series, isbn), `xtc.meta` | library-grade apps | M | the TOC is XML: after #14 |
| 21 | input gestures: swipe/pinch, capacitive home key, slide switch | touch boards | M | UNTESTED hardware |
| 22 | `device.orientation` + rotated text | landscape apps | M | |
| 23 | `audio.play_data` (PCM from memory) | chimes, synth | M | |
| 24 | `zip.create` / deflate compress, `zstd.decompress` | backups, gzip from a Lua HTTP server | M | inflate only today |
| 25 | `wifi.softap` and ESP-NOW at the same time | biscuit's SOS beacon | M | today they refuse each other (radio arbitration) |
| 26 | `gfx.image` GIF (first frame) | | S | |
| 27 | 4-level grayscale `gfx` model | X3 panel, 2-bit XTCH pages, anti-aliased text | L | X3-class boards only |
| 28 | RTC alarm wake (`device.wake_in`) | alarm clock | L | needs upstream wake-source plumbing |
| 29 | sleep-enter hook / retained frame | background sync | M | upstream hook |

### Apps that need no new native code (each gets a spec before it is written)

| batch | uses | blocked by |
|---|---|---|
| **PLAY NEARBY**: 11 games over ESP-NOW (link protocol first, then one game each) | `espnow.*` (verified) | #3 for hold-based games |
| passive WiFi sniffer (channel hop, EAPOL lock, classify) | `wifi.monitor_*` | none |
| recon suite: probe sniffer, deauth detector, crowd density, network monitor | `wifi.monitor_*`, `wifi.tx_*` | #7 for richer scans |
| comms suite: mesh chat, dead drop, bulletin board, captive portal | `espnow`, `wifi.softap`, `net.listen`, UDP | none |
| security suite: password manager, PIN, SD encryption, quick-wipe | `crypto`, vault.lua (**TOTP done**) | none |
| reader-adjacent: TXT/MD reader, file browser + viewers, event logger, library shelf with covers | `fs`, `epub.meta`, `gfx.image` | #16 for real progress |
| KOReader sync, Instapaper | `http.request{ca=}`, `gfx.qr`, `json` | #1 (md5) |
| StarDict dictionary | `zip.inflate`, `fs` range reads | none |
| AO3 (plan exists) | `zip.*`, `http.request` | #16 |
| sleep-screen designer / wallpapers / "Live" photo | `gfx.save_bmp`, `system.sleep` | root write grant, #17 |
| BLE scanner (raw observer + AD parser) | `ble.observe/adverts` | none (GATT browser: #15) |
| creature/dashboard, tilt gestures, screenshot action | `device.motion`, `gfx.save_bmp` | none |

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
| `LED` | LedManager (its `flash()` pattern is NOT bound yet: second-pass audit) | `led.count()`, `led.set(i, r, g, b)`, `led.all(r, g, b)`, `led.off()` | **done** (host-tested, 21 mutants; absence path verified on the X4; hardware path UNTESTED) |
| `RTC` | Rtc | caps flag; `time.*` already uses the trusted clock; later `device.wake_in(seconds)` (RTC wake timer for alarm-clock apps) | caps flag **done**; wake_in park |
| `AUDIO` | AudioManager | `audio.play(path [, loop])` (WAV from the SD card, same path rules as `fs`), `audio.stop()`, `audio.volume(pct)`, `audio.playing()` | **done** (host-tested, 9 mutants; absence path verified on the X4; hardware path UNTESTED — needs a board with a speaker) |
| `MIC` | Microphone | `mic.record(path, seconds)` (streamed WAV, Back cancels) / `mic.level([ms])`; a recording device must be consented to: `"microphone"` permission with an approval screen, never silent | **done** (host-tested, 12 mutants; absence path on the X4; hardware path UNTESTED, needs a board with a mic) |
| `BLE_KEYBOARD` / `BLE_HID_HOST` | BlePageTurner / HID host | **done** as `ble.*` keyboard mode + `input.key()` (see Tier 3); a page-turner-style remote is the same path (its presses arrive as `"key"` events) | done |
| BLE observer (raw advertisements) | biscuit BLE scanner/tracker apps, crossplay | **done** as `ble.start("raw")` + `ble.observe/adverts/observe_stop` (verified on the X4, 33 mutants). Observer only: peripheral/broadcaster roles are off in the build, so no advertising, beacons or acting as a keyboard without an sdkconfig change. Generic GATT client (central role, one connection): next |
| OTA updates from this fork's releases | upstream updater, repointed | **verified on the X4**: a `2.0.0-crosslua.0` build found `2.0.0-crosslua.1` in this repository's release by itself, downloaded and installed it; the active OTA slot afterwards was byte-identical to the published `x3-x4` asset (SHA-256 match). `src/network/OtaVersion.h` (base + `-crosslua.N` revision compare, a leading `v` ignored, mutation-checked) and `-DCROSSLUA_RELEASE_REPO` |
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

Open items first (ordered build list above), finished or mostly-finished rows below the rule.

| primitive | unlocks | why later |
|---|---|---|
| `xml.parse` (expat binding) | OPDS feeds, OPF/NCX niceties | **Now #14 in "Next up"**: the most requested primitive of the second-pass audit. String-pattern scraping was enough for AO3, not for OPDS/RSS/TOC. |
| `gfx.load_font(path)` TTF | custom fonts | Hard; FreeInkFont subsystem is deep. |
| deep sleep with wake-timers/retained frame | sleep screens, alarms | **`system.sleep(seconds)` + `system.last_wake()` done and verified** (arms the timer, enters upstream's own sleep flow read-only; the power button also wakes; a timer wake is a fresh boot, `last_wake()` reports it; no permission needed). Retained frame not exposed. |
| decimal arithmetic for Calculator | biscuit/crossplay Calculator | Lua can do string-based decimal add/sub; only worth it if the Calculator gets ported. |
| App categories / launcher for Lua apps (**parked, undecided**) | a flat Plugins list will not scale past a few dozen apps | Options discussed, no decision yet. **Mechanism is settled:** category = manifest `"category"` field only (not sub-folders: the Plugin Hub and `x4push` install flat at `/plugins/<name>`, data dirs are keyed by app name, `app.dir()` would change). **A.** native "Lua apps" screen (C++): fast, no VM RAM, but more C++ UI + one upstream entry point, not replaceable. **B (recommended).** a launcher that is itself a Lua app (`apps_lua`): zero upstream UI edits, replaceable, Recent/Favorites in plain Lua; needs new `app.list()` + `app.launch(name)` behind a `"launcher"` permission with an approval screen, costs ~15-20 KB RAM while browsing, one extra step; the flat list stays unless a tiny optional filter hides Lua apps (`"listed": false`). **C.** edit `PluginCatalogActivity` in place: one list, but risky (paging/index/uninstall-return logic in a 1,740-line upstream file, merge pain). Optional later: `/.crosslua/categories.json` override so users can re-sort without editing manifests. |
| **done or mostly done** | | |
| BLE `scan`/`central`/`peripheral`/`hid` (Grimoire `ble.*`, `hid.*`) | ~12 biscuit apps, Grimoire BLE spells | **Keyboard mode done** (`ble.start/stop/scan/devices/connect/disconnect/state/paired/forget` + `input.key()`, `"bluetooth"` permission with approval label `BLE`): scan, connect-cancel, WiFi exclusivity and start/stop cycles verified on the X4 (stack 52 KB, no per-cycle leak); host tests with 55 mutants; **typing from a real keyboard is the one unverified piece**. **Not done:** a generic GATT client (read/write/notify) and everything that advertises (beacons, acting as a keyboard, contact exchange, phone tether): those need the NimBLE peripheral/broadcaster roles, which `[ble_page_turner]` in `platformio.ini` compiles out for every firmware env: enabling them is an upstream sdkconfig change, so it needs Angel's go. **Raw mode also done** (`ble.start("raw")` + `observe/adverts/observe_stop`, verified on the X4). **Still open:** generic GATT client (#15), advertising / peripheral / acting as a keyboard (needs an sdkconfig change: the build has the central and observer roles only). |
| `wifi.monitor` promiscuous + native PCAP writer, `wifi.tx` raw | biscuit recon/offense suite, Ruby sniffer | **`wifi.monitor_*` done and verified** (`"monitor"` permission with approval, polled 8-slot ring, native PCAP writer verified with scapy; radio exclusive with WiFi/hotspot/espnow; nothing upstream touched). `wifi.tx_*` **done and verified** (`"tx"` permission with approval, dialog label `INJECT`; coexists with the monitor on one channel; frames captured on the air byte for byte from Lua-injected frames). |
| `espnow.send/recv` | crossplay PLAY NEARBY (11 games), biscuit mesh chat/SOS | **done** (`espnow.start/send/recv/info/stop`, `"espnow"` permission with approval; polled 6-slot ring, radio exclusive with WiFi/hotspot, nothing upstream touched). |
| `wifi.softap` + captive DNS, `http.server` | biscuit dead-drop/bulletin/portal, crossplay web apps | **softap done and verified with a real client** (`wifi.softap`, `wifi.softap_info`, `"hotspot"` permission with approval; `net.*` works over it; WPA2 + DHCP + HTTP from a laptop-class client). The HTTP server and the captive-portal DNS are Lua libraries over `net.listen`/`net.udp_*`, not native code (nothing upstream touched). |

## Tier 4 — developer tooling (requested)

| primitive | unlocks | notes |
|---|---|---|
| **Run the real firmware on a PC (desktop simulator), Lua plugins included** | write and debug Lua apps without an X4; share/review apps; run every plugin in CI | **Do not build a second runtime: reuse what crossplay already does.** CrossPoint publishes [`crosspoint-simulator`](https://github.com/crosspoint-reader/crosspoint-simulator) (PlatformIO `platform = native` + SDL2): it replaces `lib/hal` with host shims (display window, keyboard as the buttons, the SD card as a folder, host sockets) and compiles the WHOLE firmware, so `LuaAppActivity`, the permission/approval screens, Plugins list and File Transfer all run unchanged. crossplay's `platformio.sim.ini` (`[env:simulator]`, pinned to a full 40-char commit, plus `sim-stubs/` for headers the simulator lacks) shows the recipe, and `tools_local/wasm/` compiles the same thing with Emscripten into the browser build served at `site/emulator`. **Plan for us:** (1) spike: add `env:simulator` to `platformio.ini` extending that recipe and see how far the tree compiles; (2) fence the radio code in `LuaAppActivity.cpp` (esp_wifi / esp_now / NimBLE / deep sleep) behind `#ifndef SIMULATOR` with stub bodies that return the same "no radio on this device" results the real code uses on boards without hardware (all in our own file); (3) map `/plugins`, `/.crosslua` to a host folder so `sd_card_contents/plugins/*` run as-is; (4) later, the WASM build for a no-install page. Costs/gaps: radios and audio are stubs, e-ink refresh timing/ghosting is not modelled, and the simulator tracks upstream `develop`, so it needs the pin and the stub headers kept current. Keep the on-device test hub as the final check. |

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
- **AvesO3:** library/dashboard portable after `epub.meta`+`image`+`fs.rename`; parser spec captured in the AvesO3 survey (§4) (239-byte index record, `progress.bin` layout, sort/filter semantics).
- **Ruby:** passive RF analyzer — needs the native `capture.*` service; screens port after Tier-2 gfx.
- **Grimoire:** spells are Lua scripts against a polled API; a thin Lua shim covers `display/input/fs/zip/time/system/wifi/http` (≈80 % of calls). Missing: `image.*`, `ble.*`, `hid.*`, `net.*`, AP mode, `fs.dofile`, `zip.inflate`, `time.sync`.
