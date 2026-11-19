# X4 Pro: hold-gesture absence during tap/swipe tests (t_e8c5dfc7)

No device used (per Sunny rules). Static source reading plus the headless harnesses from t_1d5cdeae and t_326b3a0e.

## Verdict

**Not verified on hardware. Hold absence is only shown statically, and it is not guaranteed.**
The headless harnesses cannot emit hold events (they feed only press events), so "no holds in the test
sequence" is trivially true for them and is not evidence about the device.

## Where hold events come from (firmware)

`src/activities/plugins/LuaAppActivity.cpp` `collectInput()`:

| Event | Trigger | Gated by grid mode? |
|---|---|---|
| `confirm_hold` | `wasLongPressed(Confirm, 500 ms)` | no |
| `left_hold` / `right_hold` / `up_hold` / `down_hold` | `wasLongPressed(<nav>, 500 ms)` | no |
| `back_hold` | never pushed. Back long-press past `EXIT_HOLD_MS` is force-quit and suppresses the release. | n/a |

- Back-swipe and tap do not produce holds: `wasBackGesture()` is a left-edge swipe, and tap uses
  `wasScreenTapped()`. Neither is a `wasLongPressed` call.
- **Risk:** `Button::Confirm` maps to the user-configured front button (`frontButtonConfirm`). When
  `shortPwrBtn == PWR_CONFIRM` on a touch board, the power button is also Confirm
  (`MappedInputManager.cpp` ~L443-483). A power-button hold therefore may send `confirm_hold`, and the
  same hold may also trigger system power behaviour. Not verified on device.
- Touch long-press (finger held on screen) is not routed to Confirm in the code I read. Not verified.

## Lua side

- No shipped app relies on `confirm_hold`/`back_hold` except `sd_card_contents/plugins/reading/ao3_lua/grid.lua`,
  which treats `confirm_hold` as "return to hub". Its test is `ao3_lua/tests/host_test.lua`.
- `security/ap_picker` (t_4a0c15c3) matches only press events and never matches hold names.

## Vertical cursor observation (grid mode)

Confirmed from `X4PRO_GRID_VERTICAL_NEEDS.md`: in grid mode physical Up/Down emit `left`/`right`.
Only top/bottom-third taps emit `up`/`down`. 2D grid apps (sudoku, go, chess, minesweeper, hex, checkers,
yahtzee, picross, seasalt, murdle, dungeon, guesswho, wavelength, wordle) cannot move vertically with buttons
in grid mode. Recommendation: move 2D boards to nav mode. Design call for Angel.

## Open for Samson (on-device)

1. Hold the power button (PWR_CONFIRM) past 500 ms in a grid app. Does `confirm_hold` arrive, and does the
   power-off/home action also fire?
2. Long-press a nav button in grid mode. Confirm `left_hold`/`right_hold` arrive (ungated).
3. Long-press a touch point in a grid app. Confirm no `confirm_hold`.
4. Swipe from the left edge and check no hold event appears alongside `back`.
