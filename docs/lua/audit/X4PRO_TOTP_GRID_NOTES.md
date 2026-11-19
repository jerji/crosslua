# X4 Pro — TOTP module load + grid-mode cursor check (headless, no device)

Task: t_26d50ab7. No physical device was used (Sunny rules). Everything below is static reading of the firmware
source plus headless runs of the real Lua files against mocked host APIs.

## 1. TOTP module loads

- `sd_card_contents/plugins/security/totp_lua/` (`main.lua`, `totp.lua`, `vault.lua`): all three files load
  (`loadfile` succeeds for each). Note: `luac5.4 -p` with several files on the command line aborts with a
  double-free in this sandbox; per-file checks were used instead.
- RFC 6238 SHA-1 vectors through `totp.code` with a host `crypto.hmac_sha1` shim (HMAC via python3):
  T=59 → `287082`, T=1111111109 → `081804`, T=1234567890 → `005924`. All PASS.
  The base32 decode of the RFC key `GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ` round-trips. The shim only stands in for
  `crypto.hmac_sha1`; the on-device `crypto` namespace is not exercised here.
- The vault path (`vault.lua`: pbkdf2, AES-CBC, HMAC, `crypto.device_key`) was NOT run headless.

## 2. `device.input_mode("grid")` in totp_lua — do NOT call it

`totp_lua/main.lua` deliberately has no `device.input_mode("grid")` (header comment says so). Its account list and
menus navigate with `up`/`down`. In grid mode the physical Up button produces `left` and Down produces `right`
(`src/activities/plugins/LuaAppActivity.cpp`, grid branch), so the list selection would stop responding to the
buttons. Recommendation: keep totp_lua in nav mode. Grid mode is only for apps that use left/right as a cursor.

## 3. Grid-mode left/right cursor — verified headlessly on a grid app

The existing harness `docs/lua/audit/grid_cursor_harness.lua` was run against `games/connectfour_lua`
(which calls `device.input_mode("grid")`):

    lua5.4 docs/lua/audit/grid_cursor_harness.lua sd_card_contents/plugins/games/connectfour_lua
    RESULT: ALL PASS (0 failing)   — left moves 4→3→2→1, wraps to 7; right moves 7→1→2→3; no vertical movement.

This matches the firmware mapping: grid mode turns physical Left/Right into `left`/`right`, and the app moves its
cursor on those events. The on-device confirmation is still open for Samson.

## 4. Vertical movement in grid mode

- Physical buttons: no vertical events in grid mode (Up→`left`, Down→`right`). A grid app has no vertical button axis.
- Touch: grid mode zones the screen on taps. A tap in the top third fires `up`, the bottom third fires `down`, and
  the middle third fires `confirm` (`LuaAppActivity.cpp`, touch-tap block). So vertical cursor control IS supported,
  but only by touch. Apps that need vertical movement on a button-only path should stay in nav mode.
- Only the tap is zoned. Swipes do not produce `up`/`down` in grid mode (no code path found).

## Issues found

1. totp_lua must not enter grid mode (see §2). The task text asked for it, and I did not do that, since it would
   break account navigation.
2. Grid mode has no vertical button axis; only touch thirds provide up/down. Apps that rely on vertical input
   should be nav-mode apps or accept touch-only vertical control.
3. Harness is headless only. The on-device left/right and touch-zone checks still need Samson.
