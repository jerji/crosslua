#!/bin/sh
# run.sh — build the Lua 5.4 interpreter if needed, then run the headless
# Grimoire-on-CrossLua shim test suite.
#
# Prints 'ALL SHIM TESTS PASSED' (and exits 0) only if every assertion held;
# exits 1 otherwise.
set -e

cd "$(dirname "$0")"

LUA_BIN="${SHIM_LUA:-/tmp/lua5.4}"
LUA_SRC=/root/x4/lua-5.4.7

if [ ! -x "$LUA_BIN" ]; then
    echo ">> building $LUA_BIN from $LUA_SRC ..."
    if [ ! -d "$LUA_SRC" ]; then
        echo "ERROR: $LUA_SRC not found (set SHIM_LUA to a lua 5.4 binary)" >&2
        exit 1
    fi
    SRCS=$(cd "$LUA_SRC" && ls src/*.c | grep -v luac)
    (cd "$LUA_SRC" && gcc -O1 -DLUA_USE_POSIX -o "$LUA_BIN" $SRCS -lm -ldl)
    "$LUA_BIN" -v
fi

"$LUA_BIN" run_shim_tests.lua