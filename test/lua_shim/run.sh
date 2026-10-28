#!/bin/sh
# run.sh — build the Lua 5.4 interpreter if needed, then run the headless
# Grimoire-on-CrossLua shim test suite.
#
# Prints 'ALL SHIM TESTS PASSED' (and exits 0) only if every assertion held;
# exits 1 otherwise.
set -e

cd "$(dirname "$0")"

LUA_BIN="${SHIM_LUA:-/tmp/lua5.4}"
LUA_SRC="${LUA_SRC:-}"
# The spells under test are Grimoire's own and are not bundled here: point GRIMOIRE_DIR at a checkout of the Grimoire project.
if [ -z "${GRIMOIRE_DIR:-}" ] || [ ! -d "$GRIMOIRE_DIR/sd_card_contents/spells" ]; then
    echo "ERROR: set GRIMOIRE_DIR to a Grimoire checkout (the directory that contains sd_card_contents/spells)" >&2
    exit 1
fi
export GRIMOIRE_DIR

if [ ! -x "$LUA_BIN" ]; then
    echo ">> building $LUA_BIN from $LUA_SRC ..."
    if [ -z "$LUA_SRC" ] || [ ! -d "$LUA_SRC" ]; then
        echo "ERROR: no Lua 5.4 interpreter: set SHIM_LUA to a lua 5.4 binary, or LUA_SRC to a Lua 5.4 source tree" >&2
        exit 1
    fi
    SRCS=$(cd "$LUA_SRC" && ls src/*.c | grep -v luac)
    (cd "$LUA_SRC" && gcc -O1 -DLUA_USE_POSIX -o "$LUA_BIN" $SRCS -lm -ldl)
    "$LUA_BIN" -v
fi

"$LUA_BIN" run_shim_tests.lua