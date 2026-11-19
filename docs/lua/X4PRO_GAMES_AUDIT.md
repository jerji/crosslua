# X4 Pro — games apps input audit (static, pre-hardware)

Scope: the 23 folders under `sd_card_contents/plugins/games/` (the kanban card said 21; the folder count is 23).
Method: `luac5.4 -p` on all 72 Lua files, then a grep of every event handler against the firmware's real input path
(`src/activities/plugins/LuaAppActivity.cpp` event pump, `src/lua/LuaApi.cpp` `dev_input_mode`,
`src/MappedInputManager.cpp` `wasBackGesture`). **No device was used.** On-device confirmation is still required.

## What the firmware actually emits (verified in source)

| input | nav mode (default) | grid mode (`device.input_mode("grid")`) |
|---|---|---|
| physical Up button | `up` | `left` |
| physical Down button | `down` | `right` |
| physical Left / Right (B::Left/B::Right) | `left` / `right` | `left` / `right` (still emitted) |
| hold Up / Down (>500 ms) | `up_hold` / `down_hold` | `up_hold` / `down_hold` (mode-independent, no app uses them) |
| Confirm (power / touch tap) | `confirm` | `confirm` |
| Back | `back` (swipe from left edge, see below) | same |

- Touch: a tap pushes `confirm` (plus `tap`/`press`/`release` on touch boards). No game reads `input.pos()`, so a tap cannot target a cell.
- Back via left-edge swipe: `MappedInputManager::wasBackGesture()` returns `wasEdgeSwipe(Left)`, folded into `Button::Back`. Apps get `back` from it. Hold-Back ≥1 s force-quits.
- `_hold` events: `left_hold`/`right_hold`/`confirm_hold` are never pushed by an X4 Pro gesture that a game should rely on; none of the 23 games reference any `_hold` name (grep count 0).

## Finding 1 (blocker for grid games): there is no vertical axis in grid mode

Grid mode turns the two physical nav buttons into left/right only. `up`/`down` never arrive. Every game
that calls `device.input_mode("grid")` (21 of 23) and has up/down-only handlers therefore cannot move a cursor
or pick a menu row vertically with the buttons. Touch cannot substitute (no `input.pos()`).

Affected (up/down-only handlers present; vertical movement unreachable on X4 Pro):
checkers, chess, dungeon, go, guesswho, hex, minesweeper, murdle, picross, play_nearby_ttt, sudoku,
wavelength, wordle (letter cycling), yahtzee, seasalt, hearts (menu rows), jaipur (menu rows), knucklebones (one handler),
connectfour (`up`/`down` handler at line ~429; check which state), game2048 (`up`/`down` move aliases; check
whether a move is reachable with left/right only).

Apps with no grid mode and only up/down navigation are unaffected: forehead, grimoire (nav mode, 1 up/down pair),
underhand (left/right handlers also accept up/down).

Options (decision for Angel / Samson, not made here):
1. **Use the hold channel for vertical in grid mode.** `up_hold`/`down_hold` already fire on the physical Up/Down buttons
   without any core change. Cost: one 500 ms hold per row step; no auto-repeat. Works everywhere immediately.
2. Core: let grid mode emit both axes, e.g. `left`/`right` for the row and an `up`/`down` on a second press, or a
   real two-axis mode. Needs a firmware change (Samson).
3. Per-app: a "cycle" scheme (left/right walks a flat index with wrap, confirm picks). Simplest for menus,
   weakest for boards.

Bold pick: option 1 now (no core work, unblocks all 15+ apps), option 2 as the follow-up. Not applied yet.

## Finding 2: API docs were missing `device.input_mode`

The binding exists in firmware but was absent from `docs/lua/API.md`. Added in this pass (verified against source).

## Per-app table

Legend: grid = calls `device.input_mode("grid")`; V-only = up/down handlers present (unreachable in grid mode).

| app | grid | V-only handlers | X4 Pro note |
|---|---|---|---|
| checkers_lua | yes | menu (189), board (336) | vertical dead; menu + board |
| chess_lua | yes | menu (719, 781), board (814), 1073 | vertical dead |
| connectfour_lua | yes | 429 | check which state; column select is left/right |
| dungeon_lua | yes | grid (348, 461), menu (373, 471) | vertical dead |
| forehead_lua | no | got/pass (116-117), menu (137) | nav mode, OK |
| game2048_lua | yes | aliases (119) | check that a move is reachable with left/right |
| go_lua | yes | menu (221), board (327, 576) | vertical dead |
| grimoire_lua | no | 175-178 | nav mode, OK; shim maps left/right, not on X4 Pro |
| guesswho_lua | yes | board (135-143), menu (155) | vertical dead |
| hearts_lua | yes | menu (753-756) | rows reachable with left/right (740) |
| hex_lua | yes | menu (245), board (319, 499) | vertical dead |
| jaipur_lua | yes | menu (889-891), cursor 723-724 | cursor left/right OK; menu vertical dead |
| knucklebones_lua | yes | 313 | left/right handlers exist |
| minesweeper_lua | yes | board and menu (449-547) | vertical dead |
| murdle_lua | yes | board and menu (142-181) | vertical dead |
| picross_lua | yes | cell (202-205), list (244-245) | vertical dead |
| play_nearby_ttt_lua | yes | cursor (137-138) | vertical dead on 3x3 |
| seasalt_lua | yes | menus (844-894), 1050 | vertical dead |
| sudoku_lua | yes | cursor (525-526), menus (571, 615) | vertical dead |
| underhand_lua | yes | 661-665 (aliased) | OK (up/down aliased to left/right) |
| wavelength_lua | yes | mode (132-133), guess dial (146-147) | ±1 dial vertical only; left/right ±5 |
| wordle_lua | yes | 153-159 | letter cycling vertical only |
| yahtzee_lua | yes | category (801-807), menus (873-949) | vertical dead |

## Checks not done here (need hardware)

- Confirm via power button and touch tap on every screen.
- Back swipe from the left edge in each game state (menus, nested screens, the nearby link).
- Visual check of the grid cursor on the 480x800 panel (touch-only apps especially).
- Lua heap at load for the largest games (sudoku, chess, seasalt) on the X4 Pro's 8 MB PSRAM build.
