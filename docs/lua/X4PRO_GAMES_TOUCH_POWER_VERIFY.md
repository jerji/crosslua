# X4 Pro — games: touch and power confirm verification (static harness, no device)

Card: t_ee7bf8ff "Verify touch/power confirmation on all games". Scope: the 23 folders under
`sd_card_contents/plugins/games/` (the card said 21). Companion to `X4PRO_GAMES_AUDIT.md` (input-path audit).
**No device was used.** Everything below is from running each app's `main.lua` under a stub harness with scripted
input (`lua5.4`, stubs for gfx/input/device/app/fs/json/system/crypto/espnow/wifi/net/settings). On-device confirmation
is still required (core session).

## What the firmware sends (source of truth: `src/activities/plugins/LuaAppActivity.cpp` `collectInput`)

- Power button (Confirm) release -> `confirm`.
- Touch tap -> `confirm` **with** `input.pos()` set (plus `tap`/`press`/`release` on touch boards).
- In grid mode the two physical nav buttons send `left` / `right` only; `up` / `down` are never produced.

## Method

For each app:
1. **Power path**: `confirm x4`, then `back`. Must exit cleanly, no `err:` screen.
2. **Touch path**: `tapconfirm x4` (confirm + position 240,400), then `back`. Compared to (1) by a hash of the full draw trace.
3. **Reachability** (depth <= 3, every sequence over the tokens the device can really produce in that layout):
   grid apps use `confirm, tapconfirm, left, right`; nav apps use `confirm, tapconfirm, up, down`. Screen = hash of the
   last presented frame.
4. **Dead-axis count**: screens reached only when the unavailable axis (`up/down` in grid mode) is also allowed.
   Non-zero means the game has states the buttons cannot reach on X4 Pro.

The stub harness was a throwaway test aid and is not shipped or committed. A search for it under `/root/.hermes`
found no copy, so these results cannot be re-run from the repo as-is. Re-running needs the harness rebuilt.
Syntax was re-checked for all 23 `main.lua` files with `luac5.4 -p` (zero errors). No game reads `input.pos()`.

## Results

| app | layout | power `confirm` | touch `tapconfirm` | touch trace == power | dead-axis screens (depth<=3) | verdict |
|---|---|---|---|---|---|---|
| checkers_lua | grid | exits clean | exits clean | yes | 0 | PASS (harness) |
| chess_lua | grid | exits clean | exits clean | yes | 0 | PASS (harness) |
| connectfour_lua | grid | exits clean | exits clean | yes | 0 | PASS (harness) |
| dungeon_lua | grid | exits clean | exits clean | yes | 0 | PASS (harness) |
| forehead_lua | nav | exits clean | exits clean | yes | 0 | PASS (harness) |
| game2048_lua | grid | returns clean (quit via `return`) | same | yes | **1** (up/down slide) | **FAIL: up/down slides unreachable** |
| go_lua | grid | exits clean (AI move ~1.8 s host Lua) | same | yes | 0 | PASS (harness); watch AI speed on device |
| grimoire_lua | nav | returns clean | same | yes | 0 | PASS (harness) |
| guesswho_lua | grid | exits clean | exits clean | yes | 0 | PASS (harness) |
| hearts_lua | grid | exits clean | exits clean | yes | 0 | PASS (harness) |
| hex_lua | grid | exits clean | exits clean | yes | 0 | PASS (harness) |
| jaipur_lua | grid | exits clean | exits clean | yes | 0 | PASS (harness) |
| knucklebones_lua | grid | exits clean | exits clean | yes | 0 | PASS (harness) |
| minesweeper_lua | grid | exits clean | exits clean | yes | 0 | PASS (harness) |
| murdle_lua | grid | exits clean | exits clean | yes | 0 | PASS (harness) |
| picross_lua | grid | exits clean | exits clean | yes | 0 | PASS (harness) |
| play_nearby_ttt_lua | grid | exits clean | exits clean | yes | **3** (cursor row-locked) | **FAIL: only row 1 reachable** |
| seasalt_lua | grid | exits clean | exits clean | yes | 0 | PASS (harness) |
| sudoku_lua | grid | exits clean | exits clean | yes | **4** (row cursor up/down only) | **FAIL: rows 2+ unreachable** |
| underhand_lua | grid | `err: App data missing` | same | yes | 0 | **BLOCKED (rights)**: needs user-supplied `gods.json` / `cards.json` |
| wavelength_lua | grid | exits clean | exits clean | yes | 0 | PASS (harness) |
| wordle_lua | grid | exits clean | exits clean | yes | 0 | PASS (harness) |
| yahtzee_lua | grid | exits clean | exits clean | yes | 0 | PASS (harness) |

Notes on the table:
- "PASS (harness)" means the power and touch paths work and no reachable state at depth <= 3 is lost. It is not an
  on-device pass.
- `touch trace == power` is true for all 23: a tap is delivered as `confirm`, and no game reads `input.pos()`. So touch
  behaves exactly like the power button everywhere. That is the only touch behaviour the games have today.
- Depth 3 is shallow. The static audit (`X4PRO_GAMES_AUDIT.md`) lists more up/down-only handlers (menus in yahtzee,
  jaipur, seasalt, checkers, chess and others). Most of those menus also accept left/right, so they are not dead ends.
  Deeper states still need a depth-5+ run or a device pass.

## Findings

1. **Confirm (power and tap) works in all 22 apps that can run with their data.** Same trace for both paths, no crash.
2. **Three apps have unreachable board states on X4 Pro** (grid mode, no `up`/`down`):
   - `sudoku_lua`: the cursor row changes only on `up`/`down`. Left/right only move the column, so rows 2+ cannot
     be reached. Playable on the top row only.
   - `play_nearby_ttt_lua`: the 3x3 cursor moves left/right inside its row only. Only row 1 is reachable.
   - `game2048_lua`: slides up and down are unreachable. Left/right slides and undo still work.
3. **Tap-to-select does not exist in any game.** No game reads `input.pos()`, so a tap cannot pick a row or cell. A tap
   confirms whatever the cursor already highlights. The card's "tap to select" example is therefore unmet for every
   game. The wifi and calculator apps show the fix pattern (`input.pos()` row mapping), but it is per-app work.
4. **`underhand_lua` depends on user-supplied data files** (`Underhand/gods.json`, `cards.json`), per
   `/root/x4/internal-docs/app-diff/batch2.md`. Without them it shows the "App data missing" error screen. This is a
   rights-gated design; it needs Angel's decision, not a code fix.

## Decisions needed (not made here)

- **Grid-mode 2-D cursor** (sudoku, ttt, 2048; also the board games in the audit). Options from `X4PRO_GAMES_AUDIT.md`:
  (1) `up_hold`/`down_hold` as the vertical axis: works with no core change, but the X4 Pro skill says to avoid `_hold`
  events; (2) core change to add a real two-axis grid mode (Samson); (3) per-app flat index (fine for lists, weak for boards).
  **Recommendation: (2) for boards, (3) for lists.**
- **Positional tap-to-select**: approve per-app `input.pos()` row/cell mapping for the games that need it, or accept
  "tap = confirm" as the touch model for these apps.
- **underhand_lua data**: leave as is (data supplied by the user), or ship a content-free path.

## Not verified here (need hardware)

- Real touch-tap zones and the GT911 coordinate mapping.
- Power button `PWR_CONFIRM` setting behaviour.
- Lua heap at load on the 8 MB PSRAM build for the largest games (sudoku, chess, seasalt).
- Go AI move time on the ESP32-S3 (about 1.8 s of host Lua per move in the harness; device speed is unknown).
