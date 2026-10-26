#!/bin/sh
# Host-side CrossLua VM tests. Needs gcc/g++ and make (ccache optional). Usage: test/lua_host/run.sh
# Incremental (see test/lua_host/Makefile): the first build is slow, later runs only recompile what changed.
set -e
cd "$(dirname "$0")/../.."
OUT=${TMPDIR:-/tmp}/crosslua-host
export OUT
MBED="${MBEDTLS_DIR:-$HOME/.platformio/packages/framework-espidf/components/mbedtls/mbedtls}"
[ -d "$MBED/library" ] || { echo "mbedtls sources not found at $MBED (set MBEDTLS_DIR)"; exit 1; }
export MBED
mkdir -p "$OUT"
if ! make -s -f test/lua_host/Makefile -j"$(nproc)" > "$OUT/cc.log" 2>&1; then
  echo "COMPILE FAILED:"; grep -E "error:|Error " "$OUT/cc.log" | head -20; exit 1
fi
grep -E "warning:" "$OUT/cc.log" | head -5 || true
rc=0
"$OUT/test_vm" || rc=$?
[ $rc -ne 0 ] && echo "TEST BINARY EXIT CODE $rc: a sanitizer (leak/overflow/UB) or a failed check — do not trust 'ALL PASSED' above"
exit $rc
