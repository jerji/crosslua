# CrossLua — Plan

A fork of [CrossPoint Reader](https://github.com/crosspoint-reader/crosspoint-reader)
that adds an on-device **Lua 5.4 app runtime**. Apps are `.lua` files on the SD
card; the firmware only carries the VM and a set of bindings. Features that other
forks compile into firmware (games, AO3 library, RF scanners, ...) become Lua apps.

Branch: `lua-runtime`. Remote `upstream` = crosspoint-reader. Target: Xteink X4
(ESP32-C3, 380KB SRAM, no PSRAM, 16MB flash, 800x480 1-bit-ish e-ink).

## Why

Every fork competes for the same ~6.25MB app slot. Moving features to SD-card Lua
makes flash cost per app zero, keeps the fork diff small (new files, few hooks),
and means users pick features by copying files rather than choosing a fork.

Prior art we build on:
- **Grimoire** (SynnBunn/Grimoire): Lua 5.4.7 on X4, API tables `display input fs zip
  time system wifi ble hid net image`. We port its binding *ideas/code* onto
  CrossPoint's subsystems instead of its GxEPD2 stack.
- **CrossPoint SD plugins** (`docs/sd-plugins.md`): JSON + browser-side JS only; no
  on-device code. Our apps live beside them in the same plugin roots and picker.
- Feature sources to port: crossplay (games/flashcards), AvesO3 (AO3 library),
  biscuit (WiFi/BLE recon, tools), Ruby (passive RF logger).

## Decisions

1. **No partition-table change.** Stock x3-x4 release is ~5.59MB of a 6.55MB slot
   (~960KB free). VM + bindings must fit in that. OTA keeps working. (Verify with
   real build — see Phase 0.)
2. **One app at a time, suspend model.** Launching a Lua app is an Activity; the
   reader state is torn down, the VM gets a heap budget sized at launch, and exit
   frees it all. No background Lua.
3. **Apps draw through `GfxRenderer`** (CrossPoint fonts/themes), not raw pixels,
   with a raw-pixel/bitmap escape hatch.
4. **Radio features: Lua API, C++ core.** WiFi/BLE bindings are normal Lua calls.
   Promiscuous/sniff capture uses a C++ ring buffer that Lua polls — never a per-frame
   Lua callback (C3 is single-core 160MHz).
5. **Mostly new files.** Everything under `src/lua/` + `lib/lua/`; touch upstream
   files only for hooks (plugin picker, settings, platformio.ini). Keeps rebases cheap.
6. **Sandbox**: only `base math string table coroutine utf8` opened. No `io`/`os`/`package`.
   File access via `fs.*` restricted to SD, with protected paths (reuse `ProtectedPaths.h`).

## Phases

### Phase 0 — Baseline (in progress)
- [x] Clone + submodules, branch `lua-runtime`, upstream remote
- [x] PlatformIO build of `env:default` (upstream b2b1e15, 2.0.0): **5,571,712 B firmware.bin = 85.0%
  of the 6,553,600 B slot, 981,888 B (~959KB) free.** Static RAM 66,488 B of 327,680 B (20.3%) —
  heap left at runtime is NOT yet measured (needs the device; see Phase 1 `system.heap()` logging).
  Cold build 10m30s on 6 cores. Hypothesis "VM+bindings fit with no partition change" holds so far.
- [ ] Decide LUA heap budget from measured on-device free heap (reader + WiFi active)
- [x] Commit docs

### Phase 1 — VM in firmware  (**code complete, awaiting on-device test**)
Done: `src/lua/LuaVm` (budgeted allocator, coroutine runner, count-hook preemption, sandbox, bytecode rejected),
`src/lua/LuaApi` (gfx/input/app/system/print over an abstract `Backend`), `LuaAppActivity` (+ firmware Backend),
plugin-picker integration (Lua app = plugin folder with `main.lua`), `sd_card_contents/plugins/hello_lua`.
Verified: 12 host tests (ASAN+UBSAN, incl. mutation-checked memory cap), upstream plugin tests 13/13, device build OK.
**Measured: whole runtime = +134.5 KB flash (5,571,712 -> 5,709,440 B; 87.1% of slot, 844 KB free); static RAM unchanged.**
Not yet verified: behaviour on the real device (heap numbers, refresh feel, input mapping, orientation).
Original scope (kept for reference):
- Vendor Lua 5.4.7 into `lib/lua/` (fetch script like Grimoire's `tools/fetch_lua.py`, or vendored)
- Custom allocator with hard budget (`lua_newstate` + counting alloc); OOM => Lua error, not reboot
- `LuaAppActivity`: loads `/apps/<name>/main.lua`, runs as coroutine stepped from `loop()`
  so the activity manager/watchdog/sleep keep working; `return` or Back-hold exits
- Hello-world app from SD card renders text and exits on Back
- Measure flash delta and heap cost; compare with Phase 0 baseline

### Phase 2 — Core API  (**fs / require / json done; zip, time, ui helpers remaining**)
Done: `fs` (app:/data:/lib: sandbox, atomic writes), `require` (written in Lua so modules can yield), `json`,
example app `counter_lua`, dev serial channel + `tools/x4ctl.py`. Cost: +~10 KB flash over Phase 1.
Bugs found by the host tests along the way: unprotected `luaL_traceback` after an OOM death aborted the process
(fixed: protected call, regression test); per-token JSON pieces cost ~30 B each (fixed: staged chunks).
Original scope:
`gfx` (text/rect/line/bitmap/refresh, via GfxRenderer), `input` (MappedInputManager),
`fs` (SdFat, path-guarded), `zip`, `time`, `system` (battery, heap, version), `json`,
`ui` helpers (list/menu/dialog/keyboard in Lua over gfx, mirroring theme).
Shared libs in `/apps/lib/`. Manifest: `app.json` {title, description, version, min_api}.
Apps appear in Home → Plugins picker.

### Phase 3 — Network API
`wifi` (scan/connect via existing WifiCredentialStore + selection activity, AP mode),
`http` (HTTPS client over wolfSSL already in tree), `net` (TCP). Memory-aware: radio
on costs 40-60KB, runtime reports `system.heap()` so apps can check.

### Phase 4 — BLE + radio
`ble` over NimBLE (already linked for page turner): scan, connect, characteristics.
`hid` keyboard. `radio` (promiscuous ring buffer, channel hop, frame filter) — native
core, Lua-polled. Active TX features (deauth etc.) explicitly out of scope until
asked for; Ruby documents deauth non-functional on this hardware anyway.

### Phase 5 — Port features as apps (ordered by ROI/risk)
1. Example apps: hello, flashcards (SR), todo
2. AvesO3 AO3 library browser (data logic over fs/http)
3. crossplay games: Sudoku/2048/solitaire first, chess (Lua engine, depth-limited) later
4. biscuit Recon apps: WiFi scanner, BLE scanner, vendor lookup (OUI db on SD), wardriving
5. Ruby: passive logger with encrypted log (needs AES binding — mbedtls/wolfSSL already linked)

### Phase 6 — Ecosystem
App manifest/versioning, install via existing web file-transfer UI, docs, example repo.

## Risks
- **RAM**: biggest. Mitigation: suspend model, measured budget, `system.heap()`, test with WiFi on.
- **Flash**: upstream main (2.0.0) may be larger than 1.6.5. Measured in Phase 0.
- **Upstream churn**: keep hooks minimal; periodic `git merge upstream/master`.
- **Lua speed** on 160MHz C3: fine for turn-based; chess depth limited. Hot paths
  (e.g. crypto, inflate) stay native.
- **Scope policy**: CrossPoint's SCOPE.md is reading-focused; this is a personal fork,
  not an upstream PR target (a generic runtime *might* be upstreamable later — ask first).
- **Legal/ethics** of RF apps: passive/own-network testing only; documented in app READMEs.

## Open questions
- ~~Run VM on the main loop task vs own FreeRTOS task~~ -> main loop, coroutine-stepped with a 25 ms slice per pass (decided in Phase 1)
- ~~Coroutine-stepped vs blocking `input.wait()`~~ -> `input.wait()` yields the coroutine (works across pcall)
- Orientation: apps currently get whatever orientation CrossPoint is set to; add `app.orientation()`?
- Whether to bundle a minimal `/apps/` into releases or keep fully separate repo
