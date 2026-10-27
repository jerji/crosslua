#!/usr/bin/env python3
import atexit, os, shutil, subprocess
os.chdir('/root/x4/crosspoint-lua')
FILES = ['src/lua/LuaMonitor.cpp', 'src/lua/LuaNet.cpp', 'src/lua/LuaEspNow.cpp']
for i, f in enumerate(FILES): shutil.copy(f, '/tmp/orig29_%d' % i)
def restore():
    for i, f in enumerate(FILES): shutil.copy('/tmp/orig29_%d' % i, f)
atexit.register(restore)
def run():
    r = subprocess.run('test/lua_host/run.sh 2>&1 | grep -E "FAILED|EXIT CODE|ALL PASSED|COMPILE" | head -2', shell=True, capture_output=True, text=True)
    return r.stdout.strip().replace('\n', ' | ')
M = 'src/lua/LuaMonitor.cpp'; N = 'src/lua/LuaNet.cpp'; E = 'src/lua/LuaEspNow.cpp'
L = [
 ('MN1 network permission not checked', '  if (!be(L).netAllowed()) return pushFail(L, NET_DENIED);', '', M),
 ('MN2 monitor permission not checked', '  if (!be(L).monitorAllowed()) return pushFail(L, MONITOR_DENIED);', '', M),
 ('MN3 channel 0 allowed', 'channel < 1 || channel > MON_CHANNELS', 'channel < 0 || channel > MON_CHANNELS', M),
 ('MN4 channel 14 allowed', 'channel > MON_CHANNELS ||', 'channel > MON_CHANNELS + 1 ||', M),
 ('MN5 fractional channel allowed', 'channel > MON_CHANNELS || channel != static_cast<int>(channel))', 'channel > MON_CHANNELS)', M),
 ('MN6 channel type unchecked', 'if (lua_type(L, -1) != LUA_TNUMBER) return pushFail(L, "channel must be an integer 1..13");', '', M),
 ('MN7 unknown option accepted', '''      } else {
        char msg[64];
        snprintf(msg, sizeof(msg), "unknown option '%.24s'", k);
        return pushFail(L, msg);
      }''', '      }', M),
 ('MN8 double start allowed', '  if (be(L).monitorRunning()) return pushFail(L, "monitor is already running (wifi.monitor_stop() first)");', '', M),
 ('MN9 start while espnow runs allowed', '  if (be(L).espnowRunning()) return pushFail(L, "espnow is running: call espnow.stop() first");', '', M),
 ('MN10 start while WiFi/hotspot up allowed', '  if (be(L).netReady()) return pushFail(L, "the radio is in use by WiFi or the hotspot: call wifi.off() first");', '', M),
 ('MN11 RAM floor off by one (<=)', 'if (freeNow < MONITOR_MIN_FREE_BYTES) {', 'if (freeNow <= MONITOR_MIN_FREE_BYTES) {', M),
 ('MN12 RAM floor lowered', 'MONITOR_MIN_FREE_BYTES = 80 * 1024;', 'MONITOR_MIN_FREE_BYTES = 40 * 1024;', M),
 ('MN13 .pcap suffix not checked', 'if (n < 5 || strcasecmp(path + n - 5, ".pcap") != 0) return pushFail(L, "file must end in .pcap");', '', M),
 ('MN15 recv before start allowed', '''int monitor_recv(lua_State* L) {
  if (int r = gateMonitor(L)) return r;
  if (!be(L).monitorRunning()) return pushNotRunning(L);''', '''int monitor_recv(lua_State* L) {
  if (int r = gateMonitor(L)) return r;''', M),
 ('MN16 info before start returns plain nil', '''  if (!be(L).monitorInfo(&channel, &captured, &dropped, path, sizeof(path), &bytes)) return pushNotRunning(L);''', '''  if (!be(L).monitorInfo(&channel, &captured, &dropped, path, sizeof(path), &bytes)) { lua_pushnil(L); return 1; }''', M),
 ('MN17 recv of nothing returns an empty string', '''  const int n = be(L).monitorRecv(buf, sizeof(buf), &rssi, &channel);
  if (n <= 0) {''', '''  const int n = be(L).monitorRecv(buf, sizeof(buf), &rssi, &channel);
  if (n < 0) {''', M),
 ('MN18 rssi zeroed', '  lua_pushinteger(L, rssi);', '  lua_pushinteger(L, 0);', M),
 ('MN19 meta channel wrong', '''  lua_pushinteger(L, channel);
  lua_setfield(L, -2, "channel");''', '''  lua_pushinteger(L, 1);
  lua_setfield(L, -2, "channel");''', M),
 ('MN20 stop needs the permission', 'int monitor_stop(lua_State* L) {\n', 'int monitor_stop(lua_State* L) {\n  if (int r = gateMonitor(L)) return r;\n', M),
 ('MN21 stop loses the byte count', '''  be(L).monitorStop(&bytes);
  lua_pushinteger(L, static_cast<lua_Integer>(bytes));''', '''  be(L).monitorStop(&bytes);
  lua_pushinteger(L, 0);''', M),
 ('MN22 frame truncated at NUL', '  lua_pushlstring(L, reinterpret_cast<const char*>(buf), static_cast<size_t>(n));', '  lua_pushstring(L, reinterpret_cast<const char*>(buf));', M),
 ('MN23 info drops the dropped counter', '''  lua_pushinteger(L, dropped);
  lua_setfield(L, -2, "dropped");''', '''  lua_pushinteger(L, 0);
  lua_setfield(L, -2, "dropped");''', M),
 ('MN24 info drops the captured counter', '''  lua_pushinteger(L, captured);
  lua_setfield(L, -2, "captured");''', '''  lua_pushinteger(L, 0);
  lua_setfield(L, -2, "captured");''', M),
 ('MN25 info drops the file/bytes', '  if (path[0]) {', '  if (false) {', M),
 ('MN26 espnow.start allowed while monitor runs', '  if (be(L).monitorRunning()) return pushFail(L, "the WiFi sniffer is running: call wifi.monitor_stop() first");', '', E),
 ('MN27 wifi.connect allowed while monitor runs', 'call espnow.stop() before joining WiFi");\n  if (be(L).monitorRunning()) return pushNo(L, "the WiFi sniffer is running: call wifi.monitor_stop() first");', 'call espnow.stop() before joining WiFi");', N),
 ('MN28 softap allowed while monitor runs', 'call espnow.stop() before starting a hotspot");\n  if (be(L).monitorRunning()) return pushNo(L, "the WiFi sniffer is running: call wifi.monitor_stop() first");', 'call espnow.stop() before starting a hotspot");', N),
]
print('== baseline', run(), flush=True)
for name, a, b, f in L:
    s = open(f).read()
    if a not in s: print('!! anchor missing', name); continue
    open(f, 'w').write(s.replace(a, b, 1))
    print('==', name, '->', run(), flush=True)
    restore()
print('== restored ->', run(), flush=True); print('ALLDONE', flush=True)
