#!/bin/sh
# Host-side CrossLua VM tests. Needs only gcc/g++. Usage: test/lua_host/run.sh
set -e
cd "$(dirname "$0")/../.."
OUT=${TMPDIR:-/tmp}/crosslua-host
mkdir -p "$OUT"
CFLAGS="-O1 -g -DLUA_USE_C89 -Ilib/lua -w"
for f in lib/lua/*.c; do
  o="$OUT/$(basename "$f" .c).o"
  [ "$o" -nt "$f" ] || gcc $CFLAGS -c "$f" -o "$o"
done
g++ -std=c++20 -O1 -g -Wall -Wextra -Ilib/lua -I. test/lua_host/test_vm.cpp src/lua/LuaVm.cpp src/lua/LuaApi.cpp "$OUT"/*.o -fsanitize=address,undefined -o "$OUT/test_vm" 2>&1 | grep -v "^$" || true
"$OUT/test_vm"
