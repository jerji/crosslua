# X4 Pro — TOTP left-edge swipe back navigation (static trace, headless, no device)

Task: t_6a33b0df. No physical device used (Sunny rules). Everything here is static reading of the firmware
source (`src/`, `freeink-sdk/`) plus a pure-logic replica of the edge-swipe classifier. Not verified on hardware.

## Verdict

A left-edge swipe produces the Lua `"back"` event in grid mode and in nav mode. The firmware path does not depend on
`device.input_mode`. In totp_lua the event is handled as follows:

- Account list (root screen): `back` returns `"exit"`, so the app exits. There is no previous screen to return to.
- Menu (`choose`, opened with confirm): `back` returns nil and cancels back to the codes list.

## Trace

1. Touch release → `MappedInputManager::wasReleased(Button::Back)` → `wasBackGesture()` (`src/MappedInputManager.cpp`).
2. `wasBackGesture()` → `wasEdgeSwipe(fui::ScreenEdge::Left)` → `fui::edgeSwipe(Left, …)` in
   `freeink-sdk/libs/ui/FreeInkUI/include/FreeInkUICore.h`:
   - start `sx <= screenW * EDGE_SWIPE_SIDE_FRAC (0.25)`
   - `dx > 0` (rightward)
   - `|dx| > |dy|` (horizontal dominant)
3. `LuaAppActivity::collectInput()` (`src/activities/plugins/LuaAppActivity.cpp`, ~line 3359):
   `if (mappedInput.wasReleased(B::Back)) push("back");`
4. `totp_lua/main.lua` `main_loop` → `"back"` → `return "exit"`; `choose()` → `return nil`.

Grid mode touches only two things. Physical Up/Down are remapped to left/right (lines 3363–3364), and touch taps are
zoned into thirds (lines 3343–3355). Neither touches the Back-gesture path, so the swipe is unaffected.

Ordering: the tap-zone block runs before the `wasReleased(B::Back)` check. A swipe is not a tap, so it does not
interfere with confirm. The `"release"` event also fires for the swipe end. totp_lua ignores it.

## Replica check (logic only)

`scratch/edge_swipe_check.py` mirrors `swipeDirection` and `edgeSwipe(Left)` (480×800 assumed):

| swipe | direction | back |
|---|---|---|
| (10,400)→(200,400) | Right | yes |
| (110,400)→(300,410) — inside 25% band | Right | yes |
| (150,400)→(350,400) — outside band | Right | no |
| (10,400)→(120,700) — mostly vertical | Down | no |
| (10,400)→(−50,400) — leftward | Left | no |
| (200,400)→(400,400) — mid-screen | Right | no |

## Issues and notes

1. **Grid mode is not needed for TOTP.** The task asked to test TOTP "in grid mode". totp_lua stays in nav mode on
   purpose (see X4PRO_TOTP_GRID_NOTES.md §2). In grid mode its up/down list navigation would become left/right. Back
   via swipe works in either mode, so the test result does not depend on the mode.
2. **Back on the root list exits the app.** There is no previous screen, so this is correct. A user who expects a
   back-to-menu from the list will be surprised. Worth a note in the app's hint text, but no change is required.
3. **Edge band depends on screen width.** The start band is 25% of width (about 120 px at 480 px). The X4 Pro logical
   width was not confirmed in this check, so this is an assumption.
4. **Not verified on device.** The replica covers only the classifier math. The real touch sampling, debounce, and
   the `LuaAppActivity` event pump need an on-device swipe check by Samson.
5. **Working tree is dirty from other sessions.** `src/activities/plugins/LuaAppActivity.cpp` and `lib/hal/*` have
   uncommitted changes, and `docs/lua/audit/totp_grid_touch_harness.lua` is untracked. This task did not touch them.

## Follow-up for Samson (on-device)

- Swipe from x ≈ 20 to x ≈ 250 at mid-height on the TOTP account list → app should exit.
- Open the menu (confirm), then swipe the same way → menu should close back to the codes list.
- Repeat both with `device.input_mode("grid")` active in a grid app (e.g. connectfour_lua) to confirm back still fires.
