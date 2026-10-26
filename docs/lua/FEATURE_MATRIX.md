# CrossLua feature matrix — what the other forks need from us

Sources: per-fork surveys in `/root/x4/scratch/features/{crossplay,biscuit,ruby,avesO3,crosspoint-native}.md`
(subagent read-throughs, LOC counts measured) plus a direct read of Grimoire's API doc and its 8 spells + launcher
(72 unique API calls, see `docs/lua/GRIMOIRE.md`). This file deduplicates their "API gaps" lists into ONE runtime
roadmap, ordered by how many features each primitive unblocks and how cheap/safe it is on the X4 (no PSRAM, ~96 KB
Lua heap). Verdicts in the per-fork files; here only the gaps.

## Tier 1 — trivial native bindings, unlock the most (one build)

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
| `net` raw TCP (connect/read/write/close, + `listen/accept`) | Grimoire `net.*` (wifi_server_test, events lib), biscuit host scanner/ports, HTTP-in-Lua experiments | lwIP sockets via BSD API. Server + client; watch heap; yield in loops. |
| `crypto.sha256/hmac_sha1/hmac_sha256/aes_*` | biscuit TOTP×2, PIN lock, SD encryption; Grimoire "pin your own content" pattern | wolfSSL already linked; expose digest + HMAC first, AES-CBC/GCM later. |
| `input.text()` modal keyboard (sub-activity, like the WiFi picker) | search/forms in apps: biscuit password manager, Grimoire settings UI | `KeyboardEntryActivity` exists; same parked-VM pattern as `wifi.connect`. |
| `gfx.rounded_rect`, `gfx.snapshot()`/`gfx.save_bmp(path)` | Ruby chrome, screenshots (3 forks) | snapshot = framebuffer readout via DevCapture-style capture or Bitmap copy; save_bmp is ~50 lines of Lua once snapshot exists. |
| `epub.meta(path)` → title/author/language (no layout) | AvesO3 library, "about this book" apps | Container/OPF parse already in lib/Epub; stream, don't cache. |

## Tier 3 — later / niche / heavy

| primitive | unlocks | why later |
|---|---|---|
| BLE `scan`/`central`/`peripheral`/`hid` (Grimoire `ble.*`, `hid.*`) | ~12 biscuit apps, Grimoire BLE spells, AvesO3 receive | Radio arbitration + NimBLE RAM; planned native radio-hooks milestone first. |
| `wifi.monitor` promiscuous + native PCAP writer, `wifi.tx` raw | biscuit recon/offense suite, Ruby sniffer | Native ring-buffer engine first (planned); Lua polls. |
| `espnow.send/recv` | crossplay PLAY NEARBY (11 games) | Radio conflict with WiFi; after BLE milestone. |
| `wifi.softap` + captive DNS, `http.server` | biscuit dead-drop/bulletin/portal, crossplay web apps | Heap-heavy; File Transfer shows the pattern works natively. |
| `xml.parse` (expat binding) | OPDS feeds, OPF/NCX niceties | String-pattern scraping suffices for AO3/M2; revisit for OPDS. |
| `gfx.load_font(path)` TTF | custom fonts | Hard; FreeInkFont subsystem is deep. |
| deep sleep with wake-timers/retained frame | sleep screens, alarms | Firmware power flow is invasive. |
| decimal arithmetic for Calculator | biscuit/crossplay Calculator | Lua can do string-based decimal add/sub; only worth it if the Calculator gets ported. |

## Requested by Angel
- **Per-folder storage grants** (IMPLEMENTED: host-tested + mutation-checked; on-device approval screen test pending; see API.md "Storage grants"): manifest
  `"storage": {"read": ["Books"], "write": ["Books/AO3","Downloads"]}` (`"/"` allowed for file managers). First launch shows a NATIVE
  confirmation listing the grants in plain words; approval stored in a hidden firmware-owned file (re-prompt when an
  update widens the grants). Hidden/dot paths and firmware images are NEVER grantable; `/plugins` (other apps' code) needs a
  separate louder warning. Enables `sd:` writes + `http save_to sd:Books/..`, `fs.rename/remove` inside grants, `app.open(path)`
  (reader today; text/image viewers later). File-browser apps additionally need `fs.stat` / detailed `fs.list` (size, type, mtime).

## Requested by Angel: app folders / categories
- **Problem:** with many apps, one flat Plugins list becomes impossible to browse.
- **Plan (launcher side, native):**
  - Manifest gains an optional `"category": "Games"` (free text, case-insensitive match; missing = "Other").
  - Home -> Plugins shows categories first, each with an app count; confirm opens it, back returns. A single-category install skips the extra level.
  - Plain sub-folders also work: `/plugins/games/chess_lua/` shows up under "games" without any manifest change. Manifest category wins if both are given.
  - Extras: a "Recent" pseudo-category (last 5 launched, stored in the firmware-owned hidden state file) and a "Favorites" pin (long-press confirm).
  - Needs: recursive plugin discovery one level deep (bounded, so the scan stays cheap), a category-list activity, and the manifest field. Pure launcher work; no Lua API change.
  - Test: host-test the discovery/grouping logic (folder vs manifest precedence, empty categories hidden, sort order, 100+ apps).

## Also requested by Angel, scheduled for later
- **`app.restart(entry)` (implemented, host-tested; on-device test pending)** — the app quits itself and is relaunched immediately with a different entry script (`main.lua` by
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
