# X4 Pro: left-edge swipe triggers Lua `back` in grid mode (static + headless)

Task: t_1d5cdeae. No device used (per Sunny rules). Hardware confirmation is still open for Samson.

## Firmware path (committed HEAD, `src/`)

1. `MappedInputManager::wasBackGesture()` returns `wasEdgeSwipe(ScreenEdge::Left)`, which is a
   left-to-right swipe starting at the left edge. Edge classification comes from the SDK (`fui::edgeSwipe`).
2. `MappedInputManager::wasReleased(Button::Back)` and `wasPressed(Button::Back)` both return true when
   `wasBackGesture()` is true.
3. `LuaAppActivity::collectInput()` runs `if (mappedInput.wasReleased(B::Back)) push("back");`.
   That line is not gated by `g_inputGridMode`, so grid mode does not change Back.
4. A header-back tap also maps to Back (`HeaderBackTapTarget`), and `wasScreenTapped` excludes that
   target so it is not delivered as a tap.

Result: a left-edge swipe delivers the bare `back` event in both nav and grid mode.

## Lua side (headless)

Ran `docs/lua/audit/back_probe.lua` against `sd_card_contents/plugins/games/connectfour_lua`
(which calls `device.input_mode("grid")`):

```
seed 1, prefix 20, back budget 3 -> RESULT exit=true err=nil backsSent=2 ignoredBacks=0 backsToExit=2 modes=grid
seed 2, prefix 20, back budget 3 -> RESULT exit=true err=nil backsSent=1 ignoredBacks=0 backsToExit=1 modes=grid
seed 3, prefix 20, back budget 3 -> RESULT exit=true err=nil backsSent=2 ignoredBacks=0 backsToExit=2 modes=grid
seed 7, prefix 0,  back budget 2 -> RESULT exit=true err=nil backsSent=1 ignoredBacks=0 backsToExit=1 modes=grid
```

Every `back` after a grid-mode navigation prefix exits the app, with no errors and no ignored backs.

## Caveats

- The working tree has uncommitted edits to `src/activities/plugins/LuaAppActivity.cpp` (grid-mode
  touch thirds emitting up/down). They do not touch the Back path, so this verification still holds for them.
- Physical confirmation on X4 Pro (swipe from the left edge while a grid app is running) is still open for Samson.
