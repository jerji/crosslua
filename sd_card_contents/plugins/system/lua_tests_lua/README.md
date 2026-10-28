# Lua test hub

On-device test runner for CrossLua on the Xteink X4 e-ink reader. Every `.lua` file under `tests/` appears as a menu item; selecting one runs it in a fresh Lua VM and returns to the menu when it finishes.

## Using it

Open Home > Plugins > Lua tests. Up/Down to choose a test, Confirm to run, Back to exit to Home. Tests that bring WiFi up reboot the device after leaving (the firmware restarts to defragment the heap); reopen the hub afterwards — the menu remembers the last selection.

## Tests

- **crypto** — Known-answer vectors and timings for sha256, sha1, hmac_sha256, hmac_sha1, AES-256-CBC, PBKDF2, TOTP, base64, constant-time compare, and random bytes. No requirements.
- **device** — Interactive hardware-capability explorer: touch, haptic, frontlight, motion, environment, tone, LED, USB state, on-screen text input. Safe on boards that lack hardware. No requirements.
- **epub** — `epub.meta` metadata parsing (OPF), error handling for corrupt/missing/wrong-type files, leak check over 120 calls. Needs `assets/book.epub` and `assets/bad.epub` (bundled). No WiFi, no SD.
- **gate** — Confirms the WiFi plain-TCP gate (~80K free heap) and the TLS gate (~96K), connects plain TCP to the host-side test server, verifies that HTTPS fails cleanly when heap is below the TLS gate. Needs the echo server on port 9099 (the host IP goes in `data:server.txt`). Uses WiFi.
- **image** — `gfx.image` decode and display: PNG from SD (fits screen, keeps aspect), missing/refused/off-screen cases, scaled box, 1-bit BMP, 24-bit BMP scaled, heap-leak check. Needs `/spells/images/test.png` on the SD card. No WiFi.
- **image_position** — Visual experiment: draws an image at y=310 and y=0 using both `fast` and `full` presentation modes. Needs `/spells/images/test.png` on the SD card. No WiFi.
- **library** — sd: scope sandboxing, `zip.list`, `zip.read`, OPF parsing from a real EPUB, `app.open_book` to launch the reader. Needs `/crosslua_test/sample.epub` on the SD card. No WiFi.
- **loadtest** — Sandboxed `load()` function: correctness, environment isolation, syntax errors, bytecode rejection, heap leak check, yield inside loaded chunk. No requirements.
- **luamem** — Lua heap baseline just after VM start, then after touching every built-in namespace (fs, json, crypto, time, device, led, net, zip, epub, wifi, http, coroutine, utf8). Regression-check across firmware builds. No requirements.
- **memprobe** — Heap cost of idle open sockets and one active echo conversation. Development build only (`system.dev_floor`). Needs the echo server on port 9099 (the host IP goes in `data:server.txt`). Uses WiFi.
- **net** — End-to-end network diagnostics: WiFi connect, HTTP and HTTPS GET, download a large file to data:, a cancel-before-finish test, and an AO3 (Cloudflare) EPUB fetch. Uses WiFi.
- **radiocost** — RAM cost of WiFi init and one 64 KB TCP transfer, with SHA-256 verification. Needs the echo server on port 9099 (the host IP goes in `data:server.txt`). Uses WiFi.
- **savebmp** — `gfx.save_bmp`: draws a test pattern, verifies the BMP header (480x800 1-bit), checks error cases (wrong extension, read-only scope, missing grant), leak check over 20 saves. Confirm redraws the saved file. No requirements.
- **selftest** — CrossLua self-test: fs write/read/append/atomic-overwrite/remove, sandbox path rejection, json roundtrip with unicode, require from app dir, all fonts resolve, OOM is catchable, preempted loops, sleep timing, coroutines, string/utf8/math libs, speed benchmark. No requirements.
- **socktest** — Comprehensive net.* test: DNS, TCP connect/greeting/echo/write-count, 64 KB streamed with hash, slow sender, peer-close handling, refused-port timeout, blackhole timeout, 4-socket table limit, heap-recovery-after-close, 160-cycle leak plateau. Needs the echo server on port 9099 (the host IP goes in `data:server.txt`). Uses WiFi.

## Adding a test

Drop a `.lua` file in `tests/`. Wrap the body with the same header/footer as any existing test - the footer catches errors with `pcall` and always calls `app.restart("main.lua")` to return to the menu. If the test uses WiFi, end with `app.exit()` instead so the firmware reboots to defragment the heap.

`grants_lua` is deliberately not in this hub: it tests the manifest-level storage-grant approval flow, which a shared manifest would hide.

## Why tests restart instead of load()

Each test runs via `app.restart("tests/<name>.lua")`, launching a fresh Lua VM. This guarantees a clean heap with no leftover state from the menu or a previous test, and gives accurate RAM measurements. The alternative (`load()` within the same VM) would leave residual tables, closures, and fragments that skew memory-sensitive tests.