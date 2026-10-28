# Grimoire shim tests (headless, no device)

```
test/lua_shim/run.sh
```

`run.sh` needs a Lua 5.4 interpreter (`SHIM_LUA=/path/to/lua5.4`, or `LUA_SRC=<Lua 5.4 source tree>` to build one at
`/tmp/lua5.4`) and a Grimoire checkout (`GRIMOIRE_DIR=<checkout>`; the spells are Grimoire's and are not bundled). It then runs
`run_shim_tests.lua` with the real interpreter. That script:

1. loads `fake_crosslua.lua` — a pure-Lua fake of the CrossLua API (gfx logs
   every call; input pops a scripted queue; fs is backed by real files under
   `$TMPDIR/grimoire_shim_test` with sd:/data:/app:/lib: scopes; wifi/http/
   zip/time return plausible data; `load` = real text-only load; the env
   handed to app code has **no io/os/package/debug/dofile/loadfile**, while
   the harness itself uses them freely);
2. builds a fake SD image: the **real** Grimoire spells + `lib/*.lua` copied
   from `$GRIMOIRE_DIR/sd_card_contents/spells/`, an `/os/config.lua`
   fixture, dummy `images/test.png`, and three harness-only fixture spells
   (`z_fs_write_test.lua`, `z_input_test.lua`, `z_wifi_creds_test.lua`,
   `z_gfx_stress.lua`) that can't ship — they're generated inside the harness;
3. loads the **real** `main.lua` + `shim.lua` from the plugin folder and runs
   every spell with a scripted input queue and a `debug.sethook` instruction
   budget (an infinite idle loop aborts deterministically and is recorded as
   "reached idle loop = OK");
4. drives the real launcher end-to-end twice (error-screen path, navigation
   path); and
5. runs the assertions below, plus **two mutation checks**: the shim is
   temporarily broken **in memory** (a string-mutated copy, never the shipped
   file) — (M1) forwarding wifi credentials, (M2) mapping fs writes onto
   `sd:` — and the suite proves the normal assertions catch both.

Assertions: (a) `example_spell.lua` / `library_demo.lua` draw and exit
cleanly on a scripted confirm; (b) `time_demo.lua` runs `time.sync` through
the shim; (c) `http_request_test.lua` reaches `wifi.request` (all 4
requests); (d) `gallery.lua`, `ble_*.lua`, `wifi_server_test.lua` fail
gracefully with a message containing "not supported on CrossLua" — never
"attempt to call a nil value"; (e) every coordinate passed to `gfx.*` is a
finite number (never nil/NaN); (f) a spell writing `/os/x.cfg` creates
`data:os/x.cfg` and never touches `sd:` (plus the read-back shadowing check);
(g) `wifi.connect` with credentials never forwards them — the fake records
the CrossLua-level call and asserts **zero arguments**, with the fixture
passing `("EvilCorp-WiFi", "hunter2secret")`.

`run.sh` prints a per-spell status table and `ALL SHIM TESTS PASSED` only if
every assertion held (exit 0; exit 1 otherwise). Current result: **53
assertions, 0 failures.**
