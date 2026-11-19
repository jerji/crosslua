# X4 Pro: touch tap in grid mode (static audit, t_326b3a0e)

Scope: headless only. No device, no flashing. Source read from the working tree
of `src/activities/plugins/LuaAppActivity.cpp` (has uncommitted changes from
another session) and `freeink-sdk/libs/hardware/InputManager`.

## What the code does

`LuaAppActivity::collectInput()` runs once per frame and calls
`mappedInput.wasScreenTapped(x, y)` **twice**:

1. Tap block (all boards). Grid mode (working tree): top third -> `up`,
   bottom third -> `down`, middle third -> `confirm`, each with `input.pos()`.
   Nav mode: always `confirm`.
2. `#if FREEINK_CAP_TOUCH` block (touch boards only, X4 Pro is one):
   `push("tap", x, y)` plus `press`/`long`/`release`.

## Finding: a single tap can produce two events

`InputManager::wasTouchTap()` is a `const` read of `touchReleasedEvent`.
That flag is cleared only in `InputManager::update()` (once per frame). Both
calls in `collectInput()` run in the same frame, so both return true for the
same physical tap. On a touch build one tap therefore queues:

| mode | events queued for one tap in the middle third | top / bottom third |
|------|-----------------------------------------------|--------------------|
| nav  | `confirm`, `tap`, `release`                   | n/a (`confirm`, `tap`, `release`) |
| grid (working tree) | `confirm`, `tap`, `release`    | `up`, `tap`, `release` / `down`, `tap`, `release` |

Effect on apps:
- Apps that only read `confirm` / `up` / `down` see one action per tap. Fine.
- Apps that read `tap` as well as one of those will act twice per tap.
  No shipped app reads `"tap"` (grep of `sd_card_contents/plugins`, only the
  lua_tests fixture mentions it), so nothing shipped is affected today.
- `docs/lua/API.md` says "press long tap release" are events on touch boards but
  does not say that `tap` is delivered alongside `confirm`/`up`/`down`. It should.

The `up`/`down` zoning is the one already flagged to Samson in HANDOFF
(uncommitted, not in HEAD). This finding is separate: the duplicate `tap`
exists in HEAD too, because HEAD also calls `wasScreenTapped` in both places.

## Headless checks run

- `lua5.4 docs/lua/audit/totp_grid_touch_harness.lua sd_card_contents/plugins/security/totp_lua head` -> FAILS: 0
- `... zoned` -> FAILS: 0 (grid taps select rows; top/bottom third step)
- `lua5.4 docs/lua/audit/grid_cursor_harness.lua sd_card_contents/plugins/games/connectfour_lua` -> ALL PASS

These harnesses model one tap as one event. They do not model the duplicate
`tap`, so they pass while the device would see two events. They cannot prove
the tap "registers" on hardware.

## Not verified (needs the device, Samson)

- That a tap in the top/bottom third really selects the on-screen element
  (acceptance criterion of t_326b3a0e: "tap registers without errors").
- Whether the duplicate `tap` causes visible double action in any app.

## Decision needed (Samson)

Either drop the `tap` push for taps already reported as `confirm`/`up`/`down`
(one event per tap), or document the duplicate in API.md. Sunny does not
change core.
