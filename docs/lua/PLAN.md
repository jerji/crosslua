# CrossLua — Plan

A fork of [CrossPoint Reader](https://github.com/crosspoint-reader/crosspoint-reader) that adds an on-device
**Lua 5.4 app runtime**. Apps are plain `.lua` files in plugin folders on the SD card; the firmware only carries the
VM and a set of bindings. Features other forks compile into firmware (games, AO3 library, RF scanners, ...) become
Lua apps instead.

Fork: <https://github.com/jerji/crosslua> (branch `lua-runtime`, remote `upstream` = crosspoint-reader).
Target: Xteink X4 (ESP32-C3, no PSRAM, 16 MB flash, 800x480 e-ink). Last updated after on-device bring-up.

Companion docs: [API.md](API.md) (what apps can call) · [INFRASTRUCTURE.md](INFRASTRUCTURE.md) (toolchain, device
workflow, tests) · [UPSTREAM_TOUCHPOINTS.md](UPSTREAM_TOUCHPOINTS.md) (every edit to upstream-owned files).

## Status at a glance

| Phase | State |
|---|---|
| 0 Baseline | **done** — stock build measured, toolchain fixed |
| 1 VM in firmware | **done and verified on the real X4** |
| 2 Core API | **mostly done** — gfx, input, app, system, fs (+ range reads, in-place records), require, json, time. Remaining: `zip`, shared `ui` lib in `/.crosslua/lib/`, orientation |
| 3 Network (wifi/http/net) | not started |
| 4 BLE + radio | not started |
| 5 Port features as apps | **started**: Study (flashcards, FSRS-5) done and verified on the X4. Next: 2048 (quick), AO3 library (needs Phase 3), the rest |
| 6 Ecosystem | not started |

## Why

Every fork competes for the same ~6.25 MB app slot. Apps on the SD card cost zero flash each, keep the fork diff
small (new files, a few hooks), and let users pick features by copying folders instead of choosing a fork.

Prior art: **Grimoire** (Lua on X4; ideas reused: budgeted allocator, count-hook preemption, sentinel-error exit),
**CrossPoint SD plugins** (JSON + browser-side JS only; our Lua apps live in the same plugin roots and picker),
and the feature sources to port: **crossplay** (games/flashcards), **AvesO3** (AO3 library), **biscuit** (WiFi/BLE
recon), **Ruby** (passive RF logger).

## Decisions (as built)

1. **No partition-table change.** The whole runtime costs ~134 KB of flash on a 6.55 MB slot; OTA keeps working.
2. **One app at a time.** A Lua app is an Activity. The VM is created on launch with a heap budget sized from free
   RAM and destroyed on exit (verified: memory is returned). No background Lua.
3. **Cooperative execution.** The script runs as a coroutine stepped from `Activity::loop()` in 25 ms slices;
   `input.wait()`/`app.sleep()` yield; a VM count hook preempts busy loops. Sleep, power button and the watchdog keep
   working; **hold Back 1 s force-quits any app**.
4. **Apps are plugin folders.** A folder containing `main.lua` under `/plugins`, `/.plugins` or `/.crosspoint/plugins`
   shows up in Home -> Plugins (needs Settings -> Connectivity -> Plugins enabled). Optional `manifest.json` gives the title.
5. **Apps draw through `GfxRenderer`** (CrossPoint fonts/themes, 7 named fonts) and push with `gfx.present()`.
6. **Sandbox.** Libraries: base, string, table, math, utf8, coroutine. No io/os/package/debug/load; bytecode is
   rejected. Files only via `fs` with scopes: `app:` (read-only), `data:` (`/.crosslua/data/<app>/`, read/write,
   atomic), `lib:` (`/.crosslua/lib/`, read-only). Paths with `..`, absolute paths etc. are rejected.
7. **Memory safety is two layers:** a per-app budget (free RAM − 56 KB, 24–160 KB) **and** a device guard that
   refuses any allocation that would leave < 40 KB free. Out-of-memory is a catchable Lua error, never a reboot.
8. **32-bit Lua** (`LUA_32BITS`): ints are int32, floats single precision; halves value size. Don't round-trip
   64-bit ids through Lua/JSON.
9. **Radio features: Lua API, C++ core.** Promiscuous capture will be a C++ ring buffer that Lua polls — never a
   per-frame Lua callback.
10. **Mostly new files**; upstream edits are listed in UPSTREAM_TOUCHPOINTS.md.

## Phase 0 — Baseline (done)
Stock CrossPoint (upstream b2b1e15, 2.0.0, `env:default`): firmware 5,571,712 B = 85.0 % of the 6,553,600 B slot
(959 KB free), static RAM 66,488 B. Cold build 10m30s on 6 cores. Toolchain gotcha: must use **pioarduino-core 6.1.19**
(stock PlatformIO 6.2.0 fights the platform over `tool-scons`).

## Phase 1 — VM in firmware (done, verified on hardware)
`src/lua/LuaVm` (budgeted allocator + device heap guard, coroutine runner, preemption, sandbox, protected traceback),
`src/lua/LuaApi` (talks to an abstract `Backend`, so identical code runs on device and in host tests),
`src/activities/plugins/LuaAppActivity` (firmware Backend + launcher + error screen), plugin-picker hook.
Flash cost of Phase 1: +137.7 KB (5,709,440 B, 87.1 %).

## Phase 2 — Core API (mostly done)
Done: `fs`, `require` (written in Lua so modules may yield), `json` (staged output, depth-limited, never throws on
decode), example apps `hello_lua`, `counter_lua`, `selftest_lua`. Cost: ~+10 KB flash.
Remaining: `zip` (EPUB/CBZ access via ROM miniz), wall-clock `time`, a Lua `ui` helper library (list/menu/dialog/
keyboard over `gfx`), `app.orientation()`, images/bitmaps.

## Measured on the real X4 (Angel's device, dev build) — authoritative
- Free internal RAM at app launch ≈ **144 KB** (WiFi off, on Home). Dev builds carry ~9 KB of screen-capture buffers,
  so the budget shows 82–88 KB there.
- hello_lua: Lua 14 KB used / 16 KB peak, device free 123 KB. After exit free heap rises back (+23 KB, `lua used=0`).
- **Speed ≈ 435k simple VM loop iterations/s** (300k iterations = 690 ms). Fine for UI and turn-based apps;
  chess-class search must be depth-limited.
- Min free heap under a table-growth stress: 7 KB before the heap guard, **39 KB after**.
- On-device self-test (`selftest_lua`, 12 checks: fs, atomic write, sandbox, json, require, fonts, OOM, preemption,
  sleep timing, coroutines): **12/12**. `counter_lua` persistence across restarts verified (13 -> 24 -> 35).
- Force-quit (hold Back 1.4 s) verified in the log. Leaving WiFi/File Transfer causes CrossPoint's normal silent restart.
- Bugs only hardware could show: negative font IDs misread as "unknown font" (0 is the sentinel); realloc transient
  needing old+new bytes; compiled script code ~2.2x its source, mostly debug info (-32 % when stripped). A bug only the draw-text checks showed: Lua's `ok and nil or x` trap in an example app.

## Dev & test workflow (all proven end-to-end)
- Host: `test/lua_host/run.sh` — ~28 scenarios under ASAN+UBSAN against a mock Backend with an in-memory SD card,
  incl. attack paths and the real example apps (and checks on what they *draw*).
- Device (dev build, `CROSSLUA_DEV` only in `env:default`): `tools/x4ctl.py` — flash (app0, leaves the original
  firmware in app1), physical button injection incl. long press, **text screen dump (`screen`, `open`, `expect-screen`;
  preferred over screenshots)**, PNG screenshots, log capture to `/root/x4/serial.log`, `restore-stock`.
  `tools/x4push.py` copies apps over WiFi. A full 16 MB flash backup of the device is in `/root/x4/backup/`.
- Skill `crosslua-x4-device-testing` records the workflow and pitfalls.

## Phase 3 — Network API (not started)
`wifi` (connect via the existing saved-credential store and selection activity; AP mode), `http` (HTTPS over the
wolfSSL already in the firmware), `net` (TCP). Radio-on costs 40–60 KB RAM, so apps must check `system.heap()`; the
40 KB guard floor will need re-measuring with WiFi up. Needed by the AO3 port and any sync app.

## Phase 4 — BLE + radio (not started)
`ble` over NimBLE (already linked for the page turner), `hid` keyboard, `radio` (promiscuous ring buffer, channel hop,
filter) as a native core polled from Lua. Active TX (deauth etc.) stays out of scope unless asked; passive/own-network
testing only.

## Phase 5 — Port features as apps (in progress)
**Done: Study** (`sd_card_contents/plugins/study_lua`, port of crossplay's Study, lean). FSRS-5 + Anki learning steps,
TSV/Anki-export decks with HTML cleaning and cloze, 24-byte/card progress file updated in place (nothing per-card in
RAM; 65,535 cards max), 10 new/100 review per day. The scheduler is verified against crossplay's C++ on 9,179 answers
(golden test). On the X4: Lua heap 48 KB after load, 65 KB peak over a full session (budget 81 KB), device free RAM
never below 52.9 KB. What the port forced into the core: `time`, `fs.read` ranges, `fs.write_at`, debug-info stripping,
a tighter GC pause (130 %), and the `string.pack('l')` portability trap (use `i4`, never `l`: host 8 bytes, device 4).
Not done in Study: undo, per-deck options, parameter optimisation, `.apkg` import, images/audio.

Remaining order:
Order by value/risk: (1) 2048 (quick; exercises `gfx` heavily); (2) todo; (3) AvesO3 AO3 library browser (fs/json/http); (4) crossplay games — Sudoku/solitaire first, chess last
(depth-limited Lua engine); (5) biscuit recon apps (WiFi/BLE scanners, OUI lookup); (6) Ruby passive logger (needs an
AES binding; mbedtls/wolfSSL are already linked).

## Phase 6 — Ecosystem
App manifest/versioning (`min_api`), install via the existing file-transfer UI, shared `lib:` modules, docs, example repo.

## Risks
- **RAM** remains the main constraint (Study already uses ~65 of 81 KB; a release build, without the 9 KB capture buffers, gives ~9 KB more): WiFi/BLE apps will have far less headroom than the ~144 KB measured with the radio off.
- **Upstream churn**: hooks are few and listed; merge `upstream/master` periodically and re-check the touchpoints.
- **Dev firmware** has a serial control channel and screen capture; it is gated by `CROSSLUA_DEV` (only `env:default`)
  and must never ship in a release env.
- **Scope policy**: CrossPoint's SCOPE.md is reading-focused; this is a personal fork, not an upstream PR target
  (a generic runtime might be upstreamable later — ask Angel first).
- **RF apps**: passive / own-network testing only, documented in each app's README.

## Open questions
- Orientation: apps get whatever orientation CrossPoint is set to (portrait 480x800 by default). Add `app.orientation()`?
- Ship a minimal `plugins/` + `lib/` bundle with releases, or keep apps in a separate repo?
- How should `zip`/image APIs expose large buffers under a ~90 KB Lua budget (streaming readers vs whole-file reads)?
