# CrossLua app API (v0.2 — Phase 1+2)

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
Libraries: base, `string`, `table`, `math`, `utf8`, `coroutine`. **No** `io`, `os`, `package`,
`debug`, `dofile`, `loadfile`, `load` (and precompiled chunks are rejected). Files go through `fs`, code through `require`.
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

## fs — sandboxed files
An app never sees the whole SD card. Every path has a scope prefix:

| prefix | maps to | access |
|---|---|---|
| `app:` (or no prefix) | the app's own folder, e.g. `/plugins/foo/` | read-only |
| `data:` | `/.crosslua/data/<app>/` — created on first write | read/write |
| `lib:` | `/.crosslua/lib/` — shared Lua libraries | read-only |

The part after the prefix must be a clean relative path: no `..`, `.`, empty parts (`a//b`), leading `/`, backslashes or `:`.
Anything else is rejected, so `fs.read("../../x")` cannot escape. Errors are returned, not thrown: `nil, "message"`.

| call | returns |
|---|---|
| `fs.read(path)` | contents \| nil, err (max 128 KB per file) |
| `fs.write(path, data)` | true \| nil, err. **Atomic** (temp file + rename): a power cut keeps the old file. Parent folders are created. Max 256 KB |
| `fs.append(path, data)` | true \| nil, err |
| `fs.exists(path)` | bool |
| `fs.size(path)` | bytes \| nil, err |
| `fs.list(path)` | sorted array of names, folders end in `/` \| nil, err (`fs.list("data:")` lists your save folder) |
| `fs.mkdir(path)` / `fs.remove(path)` | true \| nil, err (`data:` only; remove works on files and *empty* folders) |

## require
`require("name")` loads `name.lua` (or `name/init.lua`) from the app folder, then from `/.crosslua/lib/`. Dots are folder
separators: `require("util.strings")` → `util/strings.lua`. Modules are cached and may yield (e.g. call `input.wait`) while loading.
Circular requires and missing modules raise a clear error listing the places searched. Module names may only use letters, digits, `_` and `.`.

## json
`json.encode(value)` → string \| nil, err · `json.decode(string)` → value \| nil, "msg at byte N" · `json.null` (sentinel for JSON null).
Arrays are tables with keys 1..n; everything else encodes as an object (string keys only). Decode never throws; nesting depth limit 24.
Integral numbers that fit int32 decode to integers, others to floats (single precision) — don't round-trip 64-bit ids through JSON.
Memory: the result is built in a few KB of staging chunks; budget roughly 2–3× the document size while encoding/decoding.

## Writing binding code (C++)
`lua_error`/`luaL_check*` longjmp: never hold objects with destructors (std::string, RAII locks) across them.
Backends: `src/lua/LuaApi.h` (`Backend` interface). Host tests: `test/lua_host/run.sh`.

## Planned (see PLAN.md)
`zip`, `wifi`/`http`/`net`, `ble`/`hid`, `radio`, orientation control, wall-clock `time`.
