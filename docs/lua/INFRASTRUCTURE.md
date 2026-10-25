# CrossLua — Infrastructure

## Repos / layout (on Hermes box, `/root/x4/`)

- `crosspoint-lua/` — THE fork (GitHub: jerji/crosslua = `origin`). Branch `lua-runtime`; remote `upstream` =
  crosspoint-reader/crosspoint-reader.
  Submodule: `freeink-sdk` (shallow).
- Reference clones (read-only, scratch): `Grimoire/ crossplay/ biscuit/ AvesO3/ Ruby/`
- `baseline-build.log` — Phase 0 build output.

New code goes here (planned):
```
lib/lua/                 vendored Lua 5.4.7 (pure C)
src/lua/                 LuaHost (VM+allocator), LuaAppActivity, bindings/
  bindings/gfx.cpp input.cpp fs.cpp ... wifi.cpp ble.cpp radio.cpp
docs/lua/                PLAN.md, INFRASTRUCTURE.md, API.md (later)
sd_card_contents/apps/   reference SD layout: apps/lib, apps/<name>/{app.json,main.lua}
tools/                   fetch_lua.py, luac size checks, SD packer
```

## Toolchain

- PlatformIO Core 6.2.0, installed via `uv tool install platformio` (`/root/.local/bin/pio`;
  add to PATH). Platform: pioarduino espressif32 55.03.311 (pulled by platformio.ini),
  board `esp32-c3-devkitm-1`, Arduino framework, 16MB flash.
- Build: `pio run -e default` (X3/X4). Output: `.pio/build/default/firmware.bin`.
  Size: `pio run -e default -t size`.
- Host: 2 cores, 4GB RAM, 29GB free. Full builds are slow (~10-20 min cold); use
  `build_cache_dir = .cache` (already configured) and background with nohup.
- Lint: `pio check` (cppcheck) used by upstream CI; clang-format config in repo.

## Flashing / testing on the real X4

The Hermes box has no X4 attached. Workflow:
1. Build here -> `firmware.bin`.
2. Angel flashes via USB (esptool / web flasher) from their machine, OR uses
   CrossPoint's own OTA/SD update path. Hermes serves the bin (copy to OMV share
   or send via Telegram).
3. Serial logs: Angel runs `pio device monitor` (115200) and pastes output, or
   we add file logging to SD (`/crosslua.log`) so logs ride the card.

Recovery: `docs/fix-bricked-xteink.md` in repo. Keep a stock firmware.bin handy.
Partition table is unchanged from upstream, so stock OTA/flash tools stay compatible.

## Host-side tests (no hardware)

Plan: build the Lua host + pure-logic bindings under a native PlatformIO env
(`env:native` / host g++) with a mock gfx/fs so app scripts can run in CI and
here. Crossplay's sim approach (`platformio.sim.ini`, em++) is prior art.
Lua apps themselves are testable with plain `lua5.4` + mock API tables.

## Git workflow

- `lua-runtime` is the integration branch; small commits per step.
- Pull upstream: `git fetch upstream && git merge upstream/master`
  (or `main`; check `git branch -r`).
- Keep upstream-file edits tiny and listed in `docs/lua/UPSTREAM_TOUCHPOINTS.md` (to create
  in Phase 1) so merges stay predictable.

## Open infra items

- [ ] CI on jerji/crosslua (build + native tests)
- [ ] Decide where release artifacts live
- [ ] Serial-log capture path
