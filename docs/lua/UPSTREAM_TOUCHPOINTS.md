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
| `src/activities/plugins/LuaAppActivity.cpp` | uses `lib/TrustedTime` (`trustedtime::trustedNow()`) for `time.now()` — read-only use of an existing API |
| `lib/hal/HalGPIO.{h,cpp}`, `src/main.cpp` | `#ifdef CROSSLUA_DEV`: `injectButton(idx, hold, delay)` / `CMD:BTN:<name>:<hold>:<delay>` arms a press for later so tests can reach a blocked main loop |
| `src/activities/plugins/LuaAppActivity.cpp` | uses `WifiSelectionActivity`, `HttpDownloader`, `WifiPowerSaveGuard`, `silentRestart()` — all existing APIs, none modified |
| `src/activities/plugins/LuaAppActivity.cpp` | also uses `ZipFile` (read-only) and `activityManager.goToReader()` — existing APIs |

| `lib/hal/HalHaptics.h` | **edited**: new `HalHaptics::pulse(enabled, ms, strength)` (one non-blocking pulse, `false` without a motor); the existing `feedback()`/`longPress()` are untouched. Backs Lua `device.haptic`. Compiles to `return false` unless `FREEINK_CAP_HAPTIC` |
| `src/activities/plugins/LuaAppActivity.cpp` | also uses `KeyboardEntryActivity` + `KeyboardResult` (`input.text`), `MappedInputManager` touch getters `wasScreenTouchDown/LongPress/Tapped/TouchReleased/isScreenTouchHeld` (touch events), `HalGPIO::isUsbConnected()/hasTouch()`, `SETTINGS.vibration`, the `FREEINK_CAP_*` flags, `esp_fill_random` — all existing APIs, none modified |
| `src/lua/LuaCrypto.cpp` | uses ESP-IDF's mbedtls (`md`, `sha1`, `sha256`, `aes`) — already linked for OTA hashing; the host tests compile the same mbedtls sources from the PlatformIO `framework-espidf` package (`test/lua_host/mbedtls_host_config.h`, override the location with `MBEDTLS_DIR`) |
| `platformio.ini` | **edited**: `[base]` `lib_deps` gains `Buzzer`, `LedManager`, `EnvironmentSensor` (same `symlink://freeink-sdk/...` form as their neighbours) so the Lua `device.tone` / `led.*` / `device.environment` backends link; the libs already ship stub bodies for boards without the hardware |
| `src/activities/plugins/LuaAppActivity.cpp` | also uses `freeink::Imu`, `Buzzer`, `LedManager`, `EnvironmentSensor` and the `BoardConfig::has*()` runtime queries — existing APIs, none modified |
