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
sd_card_contents/plugins/  reference apps: <name>/{main.lua,manifest.json,...}; shared libs go to /.crosslua/lib/ on the card
tools/                   fetch_lua.py, luac size checks, SD packer
```

## Toolchain

**GOTCHA — pin the pioarduino core.** Stock PlatformIO 6.2.0 breaks the build: the platform pins
tool-scons 4.8.1, core 6.2.0 wants 4.11.1, they reinstall over each other and the build dies with
`No module named 'SCons.Tool.FortranCommon'` (upstream: pioarduino/platform-espressif32#529). Fix, as
in upstream CI:
```
uv tool install "pioarduino-core @ https://github.com/pioarduino/platformio-core/archive/refs/tags/v6.1.19.zip"
pio pkg install -e default
uv pip install --python ~/.platformio/penv/bin/python "pioarduino==6.1.19"   # nested core
```

- pioarduino-core 6.1.19, installed via `uv tool install` (see above) (`/root/.local/bin/pio`;
  add to PATH). Platform: pioarduino espressif32 55.03.311 (pulled by platformio.ini),
  board `esp32-c3-devkitm-1`, Arduino framework, 16MB flash.
- Build: `pio run -e default` (X3/X4). Output: `.pio/build/default/firmware.bin`.
  Size: `pio run -e default -t size`.
- Host: 6 cores, 8GB RAM. Cold build 10m30s with `pio run -e default -j 6`; warm rebuilds are incremental; use
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

## Driving a real device from the Hermes box (`tools/x4ctl.py`)

With the X4 attached (USB passthrough to the VM) and a dev firmware (`env:default`) flashed:
```
uv run --with pyserial --with pillow tools/x4ctl.py ping                 # PONG uptime screen-name
uv run --with pyserial --with pillow tools/x4ctl.py btn right confirm    # press buttons
uv run --with pyserial --with pillow tools/x4ctl.py screen                 # screen as TEXT, selected row marked '>'  (preferred)
uv run --with pyserial --with pillow tools/x4ctl.py open "Plugins"          # move highlight to the matching row, Confirm, print new screen
uv run --with pyserial --with pillow tools/x4ctl.py expect-screen "regex" 10  # poll until the screen text matches
uv run --with pyserial --with pillow tools/x4ctl.py shot out.png         # PNG screenshot (only when real pixels matter)
uv run --with pyserial --with pillow tools/x4ctl.py log 10 --grep LUA    # heap / app logs
uv run --with pyserial --with pillow tools/x4ctl.py flash firmware.bin   # app0 + erase otadata; app1 (previous fw) untouched
uv run --with pyserial --with pillow tools/x4ctl.py restore-stock /root/x4/backup/x4-original-full-16MB.bin   # boot the original fw again
```
Serial protocol (dev builds): `CMD:SCREENSHOT` (upstream), `CMD:BTN:<back|confirm|left|right|up|down>[:holdMs]` (physical buttons; hold >=1000 = long press) -> `BTN_OK:<name>`,
`CMD:PING` -> `PONG:<ms>:<activity>`, `CMD:SCREEN` -> text dump of the last displayed frame (`lib/GfxRenderer/DevCapture.*`: T/R records; ~9 KB RAM, dev builds only).
All lines `x4ctl` reads are appended to `/root/x4/serial.log` (grep it for `[LUA]` heap lines). `tools/x4push.py` pushes apps over WiFi (deletes first: the server refuses overwrites). Never set DTR/RTS after opening: clearing DTR while RTS is high is the esptool reset pattern and reboots the C3.
**Device state (Angel's X4, MAC f8:5b:1b:5b:a6:a8):** original firmware = CrossPoint 5.5.2-729-g87912cd in app1; full 16 MB backup in `/root/x4/backup/`. otadata originally selected app1 (seq 6).
Apps and data reach the SD card over WiFi (CrossPoint's file-transfer web UI / WebDAV) or by moving the card.
Protocol/decoder test without hardware: `uv run --with pyserial --with pillow test/lua_host/test_x4ctl.py` (fake device on a pty).

## Host-side tests (no hardware)

`test/lua_host/run.sh` (needs only gcc/g++; ASAN+UBSAN) builds Lua + `src/lua/` against a mock `Backend` with an
in-memory SD card and runs ~25 scenarios: sandbox, memory cap, preemption, fs/require/json incl. attack paths, and the real
example apps from `sd_card_contents/` (so a typo in an example app fails CI). Host pointers are 64-bit, so memory
numbers there are ~1.6x the 32-bit C3's. Upstream's own tests: `cmake -S test -B build && cmake --build build` (needs tool-cmake from ~/.platformio).

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
