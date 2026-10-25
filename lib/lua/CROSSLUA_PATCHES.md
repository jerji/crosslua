# Vendored Lua 5.4.7 — local changes

Source: https://www.lua.org/ftp/lua-5.4.7.tar.gz
sha256: 9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30

- Removed `lua.c`, `luac.c`, `Makefile` (we embed; Arduino owns main).
- `luaconf.h`: `LUA_32BITS` 0 -> 1 (32-bit int + float). Halves TValue (16 -> 8 bytes)
  which roughly halves stack/table memory; C3 has no FPU so double buys no speed.
  Consequences for apps: integers wrap at 2^31, floats have ~7 digits.
  Use `system.millis()` wrap-safe diffs; no 64-bit timestamps in Lua.
- `library.json`: PlatformIO lib manifest (LUA_USE_C89 avoids long long / locale deps).
