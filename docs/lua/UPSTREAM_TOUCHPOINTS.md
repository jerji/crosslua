# Upstream touchpoints

Everything CrossLua adds lives in new files (`lib/lua/`, `src/lua/`, `src/activities/plugins/LuaAppActivity.*`,
`docs/lua/`, `test/lua_host/`, `sd_card_contents/`). These are the *only* edits to upstream-owned files;
re-check them first when merging `upstream/master`.

| file | change |
|---|---|
| `src/util/PluginLocations.h` | `DeviceKind::Lua`, `PickerAction::Lua`; `Entry::hasLua`; `isDiscoverableEntry(..., hasLua = false)` (defaulted so existing callers/tests compile); `pickerAction` returns Lua for Lua kind |
| `src/util/PluginLocations.cpp` | detect `main.lua`; count it as a discoverable marker (scan, `anyPluginInstalledOnDisk`) |
| `src/activities/plugins/PluginCatalogActivity.cpp` | `#include "LuaAppActivity.h"`; mark Lua apps in `discoverPlugins()`; row for `DeviceKind::Lua`; launch in `activateIndex()` |
| `test/plugin_manifest_classification/...Test.cpp` | +2 tests for the Lua kind |
| `platformio.ini` | `env:default` only: `-DCROSSLUA_DEV=1` (serial test channel; absent from every release env) |
| `lib/hal/HalGPIO.{h,cpp}` | `#ifdef CROSSLUA_DEV`: `injectButton(idx, holdMs)` simulates a physical press+release (pressed/released edges, `isPressed`, `getHeldTime`), so button remapping, ButtonNavigator and long-press logic all run for real |
| `src/main.cpp` | `#ifdef CROSSLUA_DEV`: `CMD:BTN:<name>[:holdMs]` and `CMD:PING` next to upstream's `CMD:SCREENSHOT` |
| `src/activities/ActivityManager.{h,cpp}` | `#ifdef CROSSLUA_DEV`: `currentName()` for `CMD:PING` |
| `lib/GfxRenderer/GfxRenderer.cpp` | `#ifdef CROSSLUA_DEV` hooks into `drawText`, `fillRect`, `fillRectDither`, `fillRoundedRect`, `clearScreen`, `displayBuffer(Async)` feeding `DevCapture` (text dump for `CMD:SCREEN`) |
| `src/main.cpp` | also `CMD:SCREEN` |

