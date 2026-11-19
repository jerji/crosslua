# X4 Pro — does grid mode need vertical cursor movement? (t_1671da06)

**Verdict:** Yes. Grid apps that move a 2D cursor need `up`/`down`, but in grid mode the physical
buttons never produce them. The only vertical path is a touch tap in the top or bottom third of the
screen. Physical vertical navigation is simply absent in grid mode.

Static check only (source reading + grep over the app folders). No device was used, per Sunny's rules.

## What grid mode delivers (firmware source)

`src/activities/plugins/LuaAppActivity.cpp`, event pump:

| Input | nav mode (default) | grid mode |
|---|---|---|
| physical Up | `up` | `left` |
| physical Down | `down` | `right` |
| physical Left / Right | `left` / `right` | `left` / `right` |
| touch tap, top third of screen | `confirm` | `up` (with x,y) |
| touch tap, middle third | `confirm` | `confirm` |
| touch tap, bottom third | `confirm` | `down` (with x,y) |

Grid mode therefore has no button that emits `up` or `down`. A vertical axis exists only through touch
zones, which are not a cursor. A tap jumps one step rather than moving a highlight, and it cannot be
used on hardware with no touchscreen.

## What the grid apps need

I ran a scan over the 38 plugin `main.lua` files that call `device.input_mode("grid")`, counting
handlers for `"up"`/`"down"` versus `"left"`/`"right"`. Examples:

- **Genuinely 2D boards** (need up and down for the row cursor): `games/sudoku_lua` (`curR` up/down),
  `games/chess_lua` (menus and board), `games/go_lua`, `games/minesweeper_lua`, `games/hex_lua`,
  `games/checkers_lua`, `games/yahtzee_lua`, `games/picross_lua`, `games/seasalt_lua`,
  `games/murdle_lua`, `games/dungeon_lua`, `games/guesswho_lua`, `games/wavelength_lua`,
  `games/wordle_lua`. These handle both axes.
- **Horizontal-only cursor** (correct as-is): `games/connectfour_lua`, which the parent verification
  already covers. `security/totp_lua`, `security/medical_id_lua`, `security/quick_wipe_lua` have no
  left/right handlers and are list/menu apps.
- **Vertical-only lists in grid mode** were already fixed by moving them to nav mode (commits such as
  `b91e8277 xkcd`, `2e2c7e87 trivia`, `982323ed hackernews`, `a11f38b7 notes`, `8b1d7623 opds`,
  `c9eeedcf koreader_sync`, `736a4fb8 txt_reader`). Those apps have no horizontal cursor.

## Requirements for vertical navigation

1. **A 2D grid app cannot use physical buttons vertically in grid mode.** Up/Down in grid mode produce
   `left`/`right`, so the cursor moves sideways, not up or down.
2. **Options for a 2D board app:**
   - (a) Keep grid mode and rely on top/bottom-third taps for row moves. This works on touch hardware
     only and is coarse.
   - (b) Use nav mode, where Left/Right still produce `left`/`right` and Up/Down produce `up`/`down`.
     This gives full 2D control with the two physical nav buttons plus touch. Apps that need only
     horizontal movement (the connectfour case) gain nothing from switching, so grid mode stays for
     them.
   - (c) Use a wrap or cycle over one linear index (as `go`/`chess` menus do) so left/right alone can
     reach every cell. Fine for small boards, awkward for large ones.
3. **Recommendation:** boards with two axes (sudoku, go, minesweeper, hex, checkers, yahtzee, picross,
   seasalt, murdle, dungeon, guesswho) should move to nav mode with `up`/`down` and touch for
   confirm. Grid mode is only worth its cost in strictly horizontal apps. This is a design call for
   Angel, so I have not changed any app.

## Documentation discrepancy (fixed)

`docs/lua/API.md` said "a tap always fires `confirm`". Firmware shows that in grid mode the top and
bottom thirds fire `up`/`down` instead. I corrected that line in API.md.

## Open for the device (Samson)

- Confirm physical Up → `left` and Down → `right` in grid mode on X4 Pro.
- Confirm the top/bottom third taps fire `up`/`down` with the right coordinates.
- Side observation, not verified: the `hasTouch()` block calls `wasScreenTapped` a second time after
  the grid-zone block already consumed the tap. The `tap` event may therefore never fire on touch
  boards. Worth a look by Samson, since API.md documents `tap`.
