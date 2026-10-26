# Where the RAM goes, and what was tried (X4, ESP32-C3, no PSRAM)

Measured on the device with the dev-build boot probes (`MEMPROBE` in `src/main.cpp`, `CROSSLUA_DEV` only).
Total internal heap: **247,176 B**. Static data/BSS (not in the heap): 74,976 B of 327,680 B.

## Boot profile (free heap after each stage)
| stage | free | cost |
|---|---|---|
| `setup()` entry (FreeRTOS, ESP-IDF, loop-task stack, drivers) | ~208 K | ~39 K already gone |
| storage, settings, stores, theme, BLE page turner (setting off) | ~204 K | ~4 K |
| `display.begin` (800x480 1-bit frame buffer) | 155 K | **49 K** |
| `activityManager.begin` (render task: 8 K stack + objects) | 146 K | **9 K** |
| fonts | 145.5 K | <1 K |
| Home / plugin picker / Lua activity + VM + backend | ~137 K at app start, ~104 K with a script loaded | 8 K + ~29 K |

So ~100 K of the 247 K is structural (frame buffer, task stacks, RTOS/IDF). There is no pile of idle services to put to sleep:
BLE is initialised only if the page-turner setting is on (0.2 K when off); the NimBLE host's 11 K is static data and cannot be freed.
Upstream already did a heap-reclamation pass (see `[firmware_tuned]` in `platformio.ini`: task stacks sized from measured
high-water marks, WiFi IRAM optimisation off, unused Arduino modules removed, BLE sized for one HID remote).

## Lua budget
`LUA_RESERVE_BYTES` was 56 K; it is now 40 K (the heap-guard floor in the allocator already refuses anything that would leave
less). Budget = free - 40 K: **96,012 B** at app start (was ~81 K). Apps with the `network` permission still need >=96 K *free*
to start WiFi, so they keep the Lua heap small (~20-30 K).

## WiFi cost, measured
`esp_wifi_init` alone costs **~31 K**; the whole radio (lwIP, supplicant, tasks, connect) costs **~56 K** (104 K -> 48.7 K in a Lua
app; File Transfer, which restarts first, goes 145 K -> 86.5 K).

## Tried and reverted (no measurable gain)
- **Trimmed WiFi init** (`--wrap=esp_wifi_init`: AMPDU off, 10 dynamic RX, 8 dynamic TX, 8 mgmt): the SDK already ships
  `static_rx=4`; free heap with WiFi up stayed **48.7 K**. Costs throughput for nothing. Reverted.
- **`HAVE_MAX_FRAGMENT`** (wolfSSL max_fragment_length; `SecureClient.cpp` requests 2 KB records under this macro but nothing
  defines it, so it is compiled out upstream): compiled in and tested against example.com and gutenberg.org: TLS dip 24 K vs 25 K,
  download low 11 K vs 6 K (noise). Those servers do not honour it. Reverted, since it changes the ClientHello for every TLS feature.

## Still open
| idea | gain | risk |
|---|---|---|
| Release build (no DevCapture, no probes) | +9 K | none (automatic) |
| Park/delete the render task while a Lua app runs | +9 K | needs ActivityManager changes; the task is required again for any sub-activity (WiFi picker, popups) |
| Slimmer Lua baseline (lazy-load stdlib tables, share API tables) | a few K | low; measure with `scratch/protomem.cpp` first |
| Run network apps after a SilentRestart into a lean state (like File Transfer does) | ~+40 K for network apps | larger design change |
