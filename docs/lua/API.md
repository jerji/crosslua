# CrossLua app API (v0 — Phase 1)

An app is a plugin folder containing `main.lua`, in any plugin root
(`/plugins`, `/.plugins`, `/.crosspoint/plugins`):

```
/plugins/hello_lua/
    main.lua        required — the app
    manifest.json   optional — {"title": "...", "description": "..."} (shown in Home → Plugins)
    README.md       optional
```
Enable **Settings → Connectivity → Plugins**, then open **Home → Plugins**. Lua apps are listed
with a `>` and a "Lua app" subtitle unless the manifest gives a description.

**Quit:** `return` from the main chunk, call `app.exit()`, or *hold Back for 1 s* (always works,
even if the app is stuck in a loop). A runtime error shows an on-screen error + traceback; Back returns.

## Language / sandbox
Lua 5.4.7, **32-bit** build: integers are `int32`, floats are single precision. Use `//` for integer division.
Libraries: base, `string`, `table`, `math`, `utf8`, `coroutine`. **No** `io`, `os`, `package`/`require`,
`debug`, `dofile`, `loadfile`, `load` (and precompiled chunks are rejected). Files/network come in later phases.
`print(...)` goes to the serial/SD log (tag `LUA`).

Memory: each app gets a hard heap cap computed at launch (free RAM − 56 KB, clamped 24–160 KB).
Exceeding it raises a normal catchable `not enough memory` error. Script size limit: 64 KB.

Scripts are preemptible: a count hook yields to the firmware every ~10k VM instructions, so a busy loop
cannot freeze the device, drop the power button, or block sleep.

## gfx — drawing (screen coordinates, origin top-left; size follows device orientation)
| call | notes |
|---|---|
| `gfx.size()` → w, h | |
| `gfx.clear([black])` | white by default; `true` = black |
| `gfx.pixel(x, y [, black=true])` | |
| `gfx.line(x0, y0, x1, y1 [, black=true])` | |
| `gfx.rect(x, y, w, h [, filled=false [, black=true]])` | |
| `gfx.text(x, y, str [, font="ui" [, flags]])` | `y` is the top of the line. `flags` string: `b` bold, `i` italic, `w` white text, `c` centre on x, `r` right-align to x |
| `gfx.text_width(str [, font [, flags]])` → px | |
| `gfx.line_height([font])` → px | |
| `gfx.present([mode])` | pushes the frame to the panel. `"fast"` (default), `"half"`, `"full"` (clears ghosting, slow) |

Fonts: `ui`, `ui12`, `small`, `sans12`, `sans14`, `sans16`, `sans18` (CrossPoint's built-in fonts, same as the rest of the UI).
Nothing reaches the panel until `gfx.present()`. Coordinates may be floats (truncated).

## input
| call | notes |
|---|---|
| `input.wait([timeout_ms])` → name \| nil | yields to the firmware until a button is released or the timeout passes (`nil`). No timeout = wait forever. **Prefer this over polling** — the device idles/sleeps normally. |
| `input.poll()` → name \| nil | non-blocking |

Event names: `back confirm left right up down`. Events are delivered on button *release*. Holding Back ≥ 1 s quits the app and is never delivered.

## app
`app.sleep(ms)` (timer only — buttons stay queued) · `app.exit()` · `app.name()` · `app.dir()` (e.g. `/plugins/hello_lua`)

## system
`system.millis()` (31-bit, wraps ~24 days — compare with subtraction) · `system.heap()` → free, min_free (device RAM) ·
`system.lua_mem()` → used, peak, budget (this app's Lua heap) · `system.battery()` → percent

## Writing binding code (C++)
`lua_error`/`luaL_check*` longjmp: never hold objects with destructors (std::string, RAII locks) across them.
Backends: `src/lua/LuaApi.h` (`Backend` interface). Host tests: `test/lua_host/run.sh`.

## Planned (see PLAN.md)
`fs`, sandboxed `require` from the app folder, `json`, `zip`, `wifi`/`http`/`net`, `ble`/`hid`, `radio`, orientation control.
