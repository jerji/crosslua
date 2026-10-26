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
# The real mbedtls (same 3.x sources the ESP-IDF build of the firmware uses), compiled with a minimal config.
MBED="${MBEDTLS_DIR:-$HOME/.platformio/packages/framework-espidf/components/mbedtls/mbedtls}"
[ -d "$MBED/library" ] || { echo "mbedtls sources not found at $MBED (set MBEDTLS_DIR)"; exit 1; }
for f in sha1 sha256 md aes platform_util constant_time; do
  [ "$OUT/mbed_$f.o" -nt "$MBED/library/$f.c" ] || gcc -O1 -g -w -I"$MBED/include" -I"$MBED/library" -Itest/lua_host -DMBEDTLS_CONFIG_FILE='"mbedtls_host_config.h"' -c "$MBED/library/$f.c" -o "$OUT/mbed_$f.o"
done
[ "$OUT/tinflate.o" -nt lib/uzlib/src/tinflate.c ] || gcc -O1 -g -Ilib/uzlib/src -w -c lib/uzlib/src/tinflate.c -o "$OUT/tinflate.o"
if ! g++ -std=c++20 -O1 -g -Wall -Wextra -Ilib/lua -I"$MBED/include" -Itest/lua_host -DMBEDTLS_CONFIG_FILE='"mbedtls_host_config.h"' -I. -Ilib -Ilib/InflateReader -Ilib/uzlib/src test/lua_host/test_vm.cpp src/lua/LuaVm.cpp src/lua/LuaApi.cpp src/lua/LuaFs.cpp src/lua/LuaJson.cpp src/lua/LuaNet.cpp src/lua/LuaZip.cpp src/lua/LuaCrypto.cpp lib/InflateReader/InflateReader.cpp "$OUT"/*.o -fsanitize=address,undefined -o "$OUT/test_vm" 2> "$OUT/cc.log"; then
  echo "COMPILE FAILED:"; grep -E "error:" "$OUT/cc.log" | head -20; exit 1
fi
grep -E "warning:" "$OUT/cc.log" | head -5 || true
rc=0
"$OUT/test_vm" || rc=$?
[ $rc -ne 0 ] && echo "TEST BINARY EXIT CODE $rc: a sanitizer (leak/overflow/UB) or a failed check — do not trust 'ALL PASSED' above"
exit $rc
