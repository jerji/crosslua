# X4 Pro — "back" via left-edge swipe, all games (static, pre-hardware)

Task: t_00e3db8e. Scope: the games under `sd_card_contents/plugins/games/`. The card said 21 games; the folder has
**23** Lua apps and all 23 were checked. **No device was used** (per the rules). On-device confirmation is still required.

## 1. Firmware path (verified in source)

- `MappedInputManager::wasBackGesture()` returns `wasEdgeSwipe(ScreenEdge::Left)`: a left-to-right swipe anchored at the
  left edge, folded into `Button::Back`.
- `LuaAppActivity` pump: `if (mappedInput.wasReleased(B::Back)) push("back");`. The swipe therefore delivers `"back"` to
  `input.wait()` / `input.poll()`.
- The swipe does **not** emit `left`/`right` (those come only from the physical buttons), and no game handles
  `press`/`release`/`tap` (grep: zero hits in `games/`). A back swipe cannot also trigger a game action.
- Mode-independent: the back path is the same in nav and grid mode (`device.input_mode("grid")` only remaps Up/Down).
- Holding Back ≥ 1 s force-quits (escape hatch), and that is not delivered to the app.

**Result: PASS (static).** Every game receives `"back"` from a left-edge swipe.

## 2. Per-app behaviour, stub-host probe

`docs/lua/audit/back_probe.lua` runs one app's `main.lua` in a coroutine against stubbed `gfx`/`input`/`app`/`device`
APIs. It feeds scripted events, then `back`s, and reports whether the app exits, how many backs it took, and whether any
back changed nothing on screen (a draw-hash proxy). It is a coarse host probe, not a renderer.

Usage: `cd <app_dir> && lua5.4 back_probe.lua . <seed> <prefix_len> <back_budget> [confirm]`

Runs: 4 random-nav seeds with no prefix, plus a `confirm`×1 and ×2 prefix (enter a sub-screen, then Back).

| app | Back from top level exits | ignored backs (no exit, no screen change) | Back after 1 confirm | notes |
|---|---|---|---|---|
| checkers | yes (1) | 0 | exit after 2 | |
| chess | yes (1) | 0 | exit after 2 | `menuScreen` returns `"exit"` on Back |
| connectfour | yes (1) | 0 | exit after 2 | |
| dungeon | yes (1) | 0 | exit after 1 | probe did not reach the sub-screen; check on device |
| forehead | yes (1) | 0 | exit after 1 | |
| game2048 | **no: Back opens the in-game menu** | 0 | n/a | by design: Back = menu toggle, Quit lives in the menu. See §3 |
| go | yes (1) | 0 | **no exit within 12 backs** | by design: Back in a game = PAUSED menu, which says "Back also continues". See §3 |
| grimoire | yes (1) | 0 | exits on the first confirm (empty-spell-list screen: "press any key") | the fs stub returns an empty spell list, so this is the no-spells screen |
| guesswho | yes (1) | 0 | exit after 1 | |
| hearts | yes (1) | 0 | exit after 2 | |
| hex | yes (1) | 0 | no exit within 12 backs after confirm #1; exit after 1 after confirm #2 | confirm #1 opens a screen whose Back returns to the menu: needs an on-device check |
| jaipur | yes (1) | 0 | exit after 1 | |
| knucklebones | yes (1) | 0 | exit after 2 | |
| minesweeper | yes (1) | 0 | exit after 2 | |
| murdle | yes (1) | 0 | exit after 2 | |
| picross | yes (1) | 0 | exit after 1 | |
| play_nearby_ttt | yes (1) | 0 | exit after 1 | |
| seasalt | yes (1) | 0 | exit after 2 | |
| sudoku | yes (1) | 0 | exit after 1 | |
| underhand | yes (1) | 0 | exit after 1 | |
| wavelength | yes (1) | 0 | exit after 1 | |
| wordle | yes (1) | 0 | exit after 1 | |
| yahtzee | yes (1) | 0 | exit after 1–2 | |

Across all runs: **0 ignored Back events** in any app. Every Back either exits the app or changes what is drawn.

## 3. Things to decide or check on hardware

1. **game2048 and go: Back does not leave the game.** Back toggles the in-game menu (2048) or the pause menu (Go).
   Both are deliberate in the source. The acceptance wording "navigate back correctly" can mean "one level back"
   (current behaviour) or "back to the game list". Samson or Angel should decide. The bold pick: keep it, since both
   apps' own hint bars and pause text say "Back: menu" / "Back also continues".
2. **Probe coverage is coarse.** The host stubs return 0 for unknown calls, so the probe confirms that Back is consumed
   and exits from the top level, but it cannot prove that each nested screen returns to its parent. Nearby/link screens
   (`linkedPlay`, `wire.lua`, `nearby.lua`) were not exercised; they need live radios.
3. **On-device Back check** (still required, rule: Samson runs it): from the top menu, inside each game board, in
   each sub-screen, and inside a Nearby link, swipe from the left edge and confirm the expected parent screen appears.
4. The unrelated uncommitted edits under `sd_card_contents/plugins/security/` and `tools/counter_lua` were not touched by
   this audit.

## 4. Verdict

- Firmware back path: PASS (static).
- All 23 games: PASS on the top-level exit and on "no ignored Back" in the host probe. Back never does nothing.
- Nested-screen correctness per game: NOT verifiable without the device. Listed in §3.
