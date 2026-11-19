# X4 Pro — TOTP touch-tap selection in grid mode (headless, no device)

Task: t_87400549. No physical device used (Sunny rules). Harness:
`docs/lua/audit/totp_grid_touch_harness.lua`, run as

    lua5.4 docs/lua/audit/totp_grid_touch_harness.lua sd_card_contents/plugins/security/totp_lua head
    lua5.4 docs/lua/audit/totp_grid_touch_harness.lua sd_card_contents/plugins/security/totp_lua zoned

The harness runs the real `totp_lua/main.lua` unmodified. It mocks `gfx`, `input`, `device`, `time`, `system`,
`crypto` (HMAC stub, codes not checked) and the `vault` module (unlocked, three accounts). Selection is read from
the list's selection bar (rect at x=0, w=8). The Menu is detected from its header text.

The tap→event mapping comes from `src/activities/plugins/LuaAppActivity.cpp`. There are two variants because the
source is split:

- `head` = committed HEAD (e40b7ac8 / f14d5071): every tap pushes `confirm`, in nav mode and grid mode.
- `zoned` = uncommitted working tree in the same file: in grid mode the top third pushes `up`, the bottom third
  pushes `down`, and the middle third pushes `confirm`.

## Results

| Check | head | zoned |
|---|---|---|
| nav: tap on row 3 → selection | row 1 (no change) | row 1 (no change) |
| nav: tap on row 3 → Menu | opens | opens |
| grid: 2× tap bottom third → selection | row 1 | **row 3** |
| grid: bottom, bottom, top taps → selection | row 1 | **row 2** |
| grid: physical Down (= `right`) → list moves? | no | no |
| grid: middle-third tap → Menu, row kept | yes | yes |

All checks pass for both variants (0 failing).

## Findings

1. **Touch does not select a row by position.** `totp_lua` never reads `input.pos()`. A tap only produces a
   confirm (opens the Menu) or an up/down step, so you cannot tap a specific account to select it. Nothing in
   any mode does that. A tap on the row-3 centre still acts on the current selection. Grid mode doesn't change
   this. If direct tap-select is wanted, the app needs `input.pos()` hit-testing against row bounds, and that is
   a new app feature, not a runtime change.
2. **The grid-mode touch zoning described in API.md is not in committed HEAD.** `API.md` (the `device.input_mode`
   row) states that in grid mode the top/bottom third fire `up`/`down`. In HEAD, `LuaAppActivity.cpp` still
   pushes `confirm` for every tap. The zoning exists only in the uncommitted working tree of
   `src/activities/plugins/LuaAppActivity.cpp`, which another session owns. This is a doc/code mismatch until
   that change is committed. I did not touch the file. Flagged as a hotspot.
3. **Grid mode is not set by totp_lua itself**, by design (see X4PRO_TOTP_GRID_NOTES.md). The task asked for
   TOTP "in grid mode". The harness forces grid mode to test that case. On a device, the firmware resets to nav
   mode on each app start, so the user only ends up in grid mode if the app enables it. In that case physical
   Up/Down become left/right and the list stops responding to buttons (scenario 3b). Only taps then move the list.
4. **Vertical selection in grid mode works only through the top and bottom thirds of the screen.** Each tap
   moves one row. The list has no page step, so a long account list takes many taps.

## Not verified

- On-device touch coordinates, tap thresholds, and the real `tapY` scale. The harness assumes the 480×800
  portrait layout used by the app.
- The vault crypto path (PBKDF2/AES/HMAC) and real codes. The vault is mocked.
- Samson's on-device confirmation is still needed.

## Recommendation

Keep `totp_lua` in nav mode. Use taps for confirm and, if wanted, add tap-to-select via `input.pos()` in
a later app change. Samson should commit or revert the `LuaAppActivity.cpp` zoning before API.md is trusted on
this point.
