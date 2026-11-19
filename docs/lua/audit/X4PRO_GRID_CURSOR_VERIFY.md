# X4 Pro — grid-mode cursor verification (headless, no device)

Task: t_406e7f9f. Acceptance: after `device.input_mode("grid")`, left input moves the cursor left,
right moves it right, and no vertical movement occurs.

**Scope and limits.** No physical device was used (Sunny rules). This is a headless run of the real
`main.lua` against mocked `device`/`gfx`/`input`/`app`/`system`. The on-device confirmation is still
open for Samson.

## Subject app

`sd_card_contents/plugins/games/connectfour_lua` — it calls `device.input_mode("grid")` on line 9 and
uses left/right as its drop-column cursor (`sel`, 1..7). Its lip-disc position is the observable cursor.

## Harness

`docs/lua/audit/grid_cursor_harness.lua` — run from the app folder:

    lua5.4 docs/lua/audit/grid_cursor_harness.lua sd_card_contents/plugins/games/connectfour_lua

It loads the app with mocked host APIs, feeds a scripted event queue through `input.wait`, and reads
the cursor back from the lip disc drawn on each frame (`gfx.present`).

## Results (real run)

| check | result |
|---|---|
| `device.input_mode('grid')` is called | PASS |
| board opens with cursor on column 4 | PASS |
| left moves cursor left (4→3→2→1) | PASS |
| left at column 1 wraps to 7 | PASS (app's modular wrap) |
| right moves cursor right (7→1→2→3) | PASS |
| lip row never moves vertically (one lip row per frame) | PASS |
| up/down events leave the cursor on column 4 | PASS |

`RESULT: ALL PASS (0 failing)`, exit 0.

**Harness is not vacuous:** with the left/right direction swapped in a copy of the app, the harness
reports `FAILURES (7 failing)`, exit 1.

## Caveat for the device

On X4 Pro, grid mode never delivers `up`/`down` from the buttons (physical Up→`left`, Down→`right`).
The up/down check here proves the app ignores vertical events, which is the correct inert behaviour.
It does not prove the button mapping, which only the device can confirm.
