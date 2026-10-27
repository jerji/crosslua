#!/usr/bin/env python3
import atexit, os, shutil, subprocess
os.chdir('/root/x4/crosspoint-lua')
FILES = ['src/lua/LuaEspNow.cpp', 'src/lua/LuaNet.cpp']
for i, f in enumerate(FILES): shutil.copy(f, '/tmp/orig27_%d' % i)
def restore():
    for i, f in enumerate(FILES): shutil.copy('/tmp/orig27_%d' % i, f)
atexit.register(restore)
def run():
    r = subprocess.run('test/lua_host/run.sh 2>&1 | grep -E "FAILED|EXIT CODE|ALL PASSED|COMPILE" | head -2', shell=True, capture_output=True, text=True)
    return r.stdout.strip().replace('\n', ' | ')
E = 'src/lua/LuaEspNow.cpp'; N = 'src/lua/LuaNet.cpp'
M = [
 ('EN1 espnow permission not checked', '  if (!be(L).espnowAllowed()) return pushFail(L, ESPNOW_DENIED);', '', E),
 ('EN2 network permission not checked', '  if (!be(L).netAllowed()) return pushFail(L, NET_DENIED);', '', E),
 ('EN3 channel 0 allowed', 'channel < 1 || channel > ESPNOW_CHANNELS', 'channel < 0 || channel > ESPNOW_CHANNELS', E),
 ('EN4 channel 14 allowed', 'channel > ESPNOW_CHANNELS ||', 'channel > ESPNOW_CHANNELS + 1 ||', E),
 ('EN5 fractional channel allowed', 'channel > ESPNOW_CHANNELS || channel != static_cast<int>(channel))', 'channel > ESPNOW_CHANNELS)', E),
 ('EN6 channel type unchecked', 'if (lua_type(L, -1) != LUA_TNUMBER) return pushFail(L, "channel must be an integer 1..13");', '', E),
 ('EN7 unknown option accepted', '''      } else {
        char msg[64];
        snprintf(msg, sizeof(msg), "unknown option '%.24s'", k);
        return pushFail(L, msg);
      }''', '      }', E),
 ('EN8 double start allowed', '  if (be(L).espnowRunning()) return pushFail(L, "espnow is already running (espnow.stop() first)");', '', E),
 ('EN9 start while WiFi/hotspot is up allowed', '  if (be(L).netReady()) return pushFail(L, "the radio is in use by WiFi or the hotspot: call wifi.off() first");', '', E),
 ('EN10 RAM floor off by one (<=)', 'if (freeNow < ESPNOW_MIN_FREE_BYTES) {', 'if (freeNow <= ESPNOW_MIN_FREE_BYTES) {', E),
 ('EN11 RAM floor lowered', 'ESPNOW_MIN_FREE_BYTES = 80 * 1024;', 'ESPNOW_MIN_FREE_BYTES = 40 * 1024;', E),
 ('EN12 18-char mac accepted', 'if (strlen(s) != 17) return false;', 'if (strlen(s) < 17) return false;', E),
 ('EN13 separator not checked', 'if (i < 5 && p[2] != \':\') return false;', '', E),
 ('EN14 hex digit g accepted', "if (c >= 'a' && c <= 'f') return", "if (c >= 'a' && c <= 'g') return", E),
 ('EN15 upper-case hex refused', "if (c >= 'A' && c <= 'F') return c - 'A' + 10;", '', E),
 ('EN16 "broadcast" keyword removed', 'if (!strcmp(to, "broadcast")) bc = true;\n    else if', 'if (false) bc = true;\n    else if', E),
 ('EN17 empty data allowed', 'if (n < 1 || n > static_cast<size_t>(ESPNOW_MAX_DATA))', 'if (n > static_cast<size_t>(ESPNOW_MAX_DATA))', E),
 ('EN18 251 bytes allowed', 'n > static_cast<size_t>(ESPNOW_MAX_DATA))', 'n > static_cast<size_t>(ESPNOW_MAX_DATA) + 1)', E),
 ('EN19 send before start allowed', '  if (!be(L).espnowRunning()) return pushFail(L, "espnow is not started (call espnow.start() first)");\n  char err[96] = {0};\n  if (!be(L).espnowSend', '  char err[96] = {0};\n  if (!be(L).espnowSend', E),
 ('EN20 recv before start allowed', '  if (!be(L).espnowRunning()) return pushFail(L, "espnow is not started (call espnow.start() first)");\n  uint8_t buf', '  uint8_t buf', E),
 ('EN21 mac printed upper-case', '"%02x:%02x:%02x:%02x:%02x:%02x"', '"%02X:%02X:%02X:%02X:%02X:%02X"', E),
 ('EN22 recv of nothing returns an empty string', 'if (n <= 0) {', 'if (n < 0) {', E),
 ('EN23 binary payload truncated at NUL', 'lua_pushlstring(L, reinterpret_cast<const char*>(buf), static_cast<size_t>(n));', 'lua_pushstring(L, reinterpret_cast<const char*>(buf));', E),
 ('EN24 info drops the dropped counter', 'lua_pushinteger(L, dropped);', 'lua_pushinteger(L, 0);', E),
 ('EN25 info channel wrong', 'lua_pushinteger(L, channel);', 'lua_pushinteger(L, 1);', E),
 ('EN26 stop needs the permission', 'int espnow_stop(lua_State* L) {\n', 'int espnow_stop(lua_State* L) {\n  if (int r = gateEspNow(L)) return r;\n', E),
 ('EN27 hotspot allowed while espnow runs', '  if (be(L).espnowRunning()) return pushNo(L, "espnow is running: call espnow.stop() before starting a hotspot");', '', N),
 ('EN28 wifi.connect allowed while espnow runs', '  if (be(L).espnowRunning()) return pushNo(L, "espnow is running: call espnow.stop() before joining WiFi");', '', N),
 ('EN29 start result drops the mac', 'lua_pushboolean(L, 1);\n  lua_pushstring(L, ms);\n  return 2;', 'lua_pushboolean(L, 1);\n  return 1;', E),
]
print('== baseline', run(), flush=True)
for name, a, b, f in M:
    s = open(f).read()
    if a not in s: print('!! anchor missing', name); continue
    open(f, 'w').write(s.replace(a, b, 1))
    print('==', name, '->', run(), flush=True)
    restore()
print('== restored ->', run(), flush=True); print('ALLDONE', flush=True)
