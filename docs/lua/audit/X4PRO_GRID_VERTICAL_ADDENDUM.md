# X4 Pro grid mode — vertical cursor addendum (t_453576a6)

Companion to `X4PRO_GRID_VERTICAL_NEEDS.md`. Static source reading only; no device used, per Sunny's rules.
Nothing here changes an app. It adds two facts the earlier report left open.

## 1. The `tap` event is NOT suppressed by the grid-zone block

The earlier report asked whether the grid-zone block consumes the tap so that `tap` never fires.
It does not:

- `src/activities/plugins/LuaAppActivity.cpp` (event pump) calls `mappedInput.wasScreenTapped(...)` once in
  the grid-zone block and again in the `hasTouch()` block that pushes `"tap"`.
- `src/MappedInputManager.cpp` `wasScreenTapped` forwards to `gpio.wasTouchTap`, which is a `const` query.
- `freeink-sdk/libs/hardware/InputManager/src/InputManager.cpp` `wasTouchTap` returns true whenever
  `touchReleasedEvent` is set and the tap is not suppressed or moved. It does not clear the flag.

So both calls return true for the same release. A tap therefore emits two events in the same frame:

| tap location (grid mode, touch board) | events emitted, in order |
|---|---|
| top third | `up` (x,y), then `tap` (x,y) |
| middle third | `confirm` (x,y), then `tap` (x,y) |
| bottom third | `down` (x,y), then `tap` (x,y) |

Nav mode behaves the same way for the middle case (`confirm` then `tap`).

Consequence for app authors: a grid app that handles `tap` as well as `up`/`down`/`confirm` will act twice
for one touch. None of the 30 grid-mode plugins listens to `tap` or `press` today, so nothing double-fires now.

Caveat: this is a static trace. It has not been confirmed on hardware.

## 2. No vertical swipe event exists

The event pump pushes only: `key`, `*_hold`, `confirm`, `back`, `left`, `right`, `up`, `down`, and touch
`press`/`long`/`tap`/`release`. Edge swipe is folded into `back`. There is no swipe-up or swipe-down event,
so a vertical drag cannot move a grid cursor. Touch vertical control is limited to the top and bottom
thirds (one step per tap).

## 3. Touch targets in the top or bottom third

In grid mode a tap in the top or bottom third fires `up`/`down` and not `confirm`. An on-screen button placed
in those thirds of a grid-mode app will not fire `confirm`. Such a button must be handled from `tap` plus
`input.pos()`, or the app should use nav mode.

## Suggested follow-ups (for Samson, not done here)

- Decide whether a `tap` should be suppressed when it has already been turned into a zone event, or
  whether apps should simply not listen to `tap` in grid mode. Either way the API.md `tap` description
  needs a note.
- Confirm on the X4 Pro that top/bottom taps produce `up`/`down` with the right coordinates.
