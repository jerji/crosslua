# Minesweeper (CrossLua port)

8x10 with ten mines — a port of crossplay's Minesweeper to the CrossLua runtime.

- `game.lua` — the rules, a pure-Lua port of `MinesweeperCore.h` (no device
  calls): first dig always safe and always floods (mines laid after it,
  excluding the cell and its eight neighbours), flags stop the flood and are
  never torn off by it, chording via `dig()`, wrong flags detonate, an
  unsatisfied chord does nothing. The xorshift32 RNG is bit-exact with the
  C++ (verified against a compiled reference for seeds 1-8).
- `main.lua` — menu + how-to + board + result screens, and the buttons.
- `manifest.json` — no permissions; a pure game.

## Controls (7-button board, no touch, no right button)

| Button | Action |
|---|---|
| Left / Right / Up / Down | move the cursor (wraps) |
| Confirm | covered cell: **dig** (or plant/lift a flag in FLAG tool); satisfied number: **chord**; revealed ground: switch DIG ↔ FLAG |
| Back | board → menu; menu → exit |
| Hold Back ≥ 1 s | force-quit (firmware) |

## Why flagging is a tool here

The design doc's touch answer to "no right button" is *hold to flag*. That
cannot exist in Lua on this device: the X4 has no touchscreen, and button
events are delivered on release — a press-and-hold is indistinguishable from a
tap, and `input.wait`/`poll` never expose a held button. (The C++'s own
`swallowCurrentTouch` + 400 ms hold is a touch-input feature.) There are six
usable button events (up/down/left/right/confirm/back) with no spare button
for a dedicated flag key, so this port uses a two-tool cursor instead:

- DIG is the default tool, so the dangerous verb is one confirm away.
- FLAG is reached by confirming on revealed ground (nothing to dig there),
  shown in the strip capsule right under the grid — the indicator sits at the
  action, which is the design critic's exact fix for the old mode.
- FLAG mode never chords, matching the C++ rule that the flag tool cannot end
  the game; a wrong flag under a right count detonates through the same
  `chord()` → `reveal()` path the taps would take.
- Deviations from the C++ flow: Back-from-board always returns to the menu
  (the Flow's rule) and never flags; the tool is the only other verb.