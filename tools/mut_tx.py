#!/usr/bin/env python3
import atexit, os, shutil, subprocess
os.chdir('/root/x4/crosspoint-lua')
FILES = ['src/lua/LuaTx.cpp', 'src/lua/LuaMonitor.cpp', 'src/lua/LuaNet.cpp', 'src/lua/LuaEspNow.cpp']
for i, f in enumerate(FILES): shutil.copy(f, '/tmp/orig30_%d' % i)
def restore():
    for i, f in enumerate(FILES): shutil.copy('/tmp/orig30_%d' % i, f)
atexit.register(restore)
def run():
    r = subprocess.run('test/lua_host/run.sh 2>&1 | grep -E "FAILED|EXIT CODE|ALL PASSED|COMPILE" | head -2', shell=True, capture_output=True, text=True)
    return r.stdout.strip().replace('\n', ' | ')
T = 'src/lua/LuaTx.cpp'; M = 'src/lua/LuaMonitor.cpp'; N = 'src/lua/LuaNet.cpp'; E = 'src/lua/LuaEspNow.cpp'
L = [
 ('TX1 network permission not checked', '  if (!be(L).netAllowed()) return pushFail(L, NET_DENIED);', '', T),
 ('TX2 tx permission not checked', '  if (!be(L).txAllowed()) return pushFail(L, TX_DENIED);', '', T),
 ('TX3 explicit channel 0 allowed', 'if (channelGiven && (channel < 1 || channel > TX_CHANNELS', 'if (channelGiven && (channel < 0 || channel > TX_CHANNELS', T),
 ('TX4 channel 14 allowed', 'channel > TX_CHANNELS ||', 'channel > TX_CHANNELS + 1 ||', T),
 ('TX5 fractional channel allowed', 'channel > TX_CHANNELS || channel != static_cast<int>(channel))', 'channel > TX_CHANNELS)', T),
 ('TX6 channel type unchecked', 'if (lua_type(L, -1) != LUA_TNUMBER) return pushFail(L, "channel must be an integer 1..13");', '', T),
 ('TX7 unknown option accepted', '''      } else {
        char msg[64];
        snprintf(msg, sizeof(msg), "unknown option '%.24s'", k);
        return pushFail(L, msg);
      }''', '      }', T),
 ('TX8 double start allowed', '  if (be(L).txRunning()) return pushFail(L, "the injector is already running (wifi.tx_stop() first)");', '', T),
 ('TX9 start while espnow runs allowed', '  if (be(L).espnowRunning()) return pushFail(L, "espnow is running: call espnow.stop() first");', '', T),
 ('TX10 start while WiFi/hotspot up allowed', '  if (be(L).netReady()) return pushFail(L, "the radio is in use by WiFi or the hotspot: call wifi.off() first");', '', T),
 ('TX11 monitor channel mismatch allowed', 'if (channelGiven && static_cast<int>(channel) != adopted) {', 'if (false) {', T),
 ('TX12 adoption ignores the sniffer', 'channel = adopted;  // inject on the channel the sniffer already listens to', '', T),
 ('TX13 RAM floor off by one (<=)', 'if (freeNow < floor) {', 'if (freeNow <= floor) {', T),
 ('TX14 minimum frame length dropped', 'if (n < TX_MIN_LEN || n > static_cast<size_t>(TX_MAX_LEN))', 'if (n > static_cast<size_t>(TX_MAX_LEN))', T),
 ('TX15 251-byte frame allowed', 'n > static_cast<size_t>(TX_MAX_LEN))', 'n > static_cast<size_t>(TX_MAX_LEN) + 1)', T),
 ('TX16 send before start allowed', '  if (!be(L).txRunning()) return pushFail(L, "the injector is not running (call wifi.tx_start() first)");\n  char err[96] = {0};\n  if (!be(L).txSend', '  char err[96] = {0};\n  if (!be(L).txSend', T),
 ('TX17 info before start returns plain nil', '''  if (!be(L).txInfo(&channel, &sent)) return pushFail(L, "the injector is not running (call wifi.tx_start() first)");''',
  '''  if (!be(L).txInfo(&channel, &sent)) { lua_pushnil(L); return 1; }''', T),
 ('TX18 info channel wrong', '''  lua_pushinteger(L, channel);
  lua_setfield(L, -2, "channel");''', '''  lua_pushinteger(L, 1);
  lua_setfield(L, -2, "channel");''', T),
 ('TX19 info loses the sent counter', '''  lua_pushinteger(L, sent);
  lua_setfield(L, -2, "sent");''', '''  lua_pushinteger(L, 0);
  lua_setfield(L, -2, "sent");''', T),
 ('TX20 stop needs the permission', 'int tx_stop(lua_State* L) {\n', 'int tx_stop(lua_State* L) {\n  if (int r = gateTx(L)) return r;\n', T),
 ('TX21 binary frame truncated at NUL', 'if (!be(L).txSend(frame, n, err, sizeof(err)))', 'if (!be(L).txSend(frame, strlen(frame), err, sizeof(err)))', T),
 ('TX22 wifi.connect allowed while the injector runs', 'call espnow.stop() before joining WiFi");\n  if (be(L).monitorRunning()) return pushNo(L, "the WiFi sniffer is running: call wifi.monitor_stop() first");\n  if (be(L).txRunning()) return pushNo(L, "the injector is running: call wifi.tx_stop() first");', 'call espnow.stop() before joining WiFi");', N),
 ('TX23 softap allowed while the injector runs', 'call espnow.stop() before starting a hotspot");\n  if (be(L).monitorRunning()) return pushNo(L, "the WiFi sniffer is running: call wifi.monitor_stop() first");\n  if (be(L).txRunning()) return pushNo(L, "the injector is running: call wifi.tx_stop() first");', 'call espnow.stop() before starting a hotspot");', N),
 ('TX24 espnow.start allowed while the injector runs', '  if (be(L).txRunning()) return pushFail(L, "the injector is running: call wifi.tx_stop() first");', '', E),
 ('TX25 monitor allowed on a different injector channel', '''    if (channelGiven && static_cast<int>(channel) != adopted) {
      char msg[96];
      snprintf(msg, sizeof(msg), "the injector is on channel %d: use it, or wifi.tx_stop() first", adopted);
      return pushFail(L, msg);
    }
    if (!channelGiven) channel = adopted;''', '', M),
]
print('== baseline', run(), flush=True)
for name, a, b, f in L:
    s = open(f).read()
    if a not in s: print('!! anchor missing', name); continue
    open(f, 'w').write(s.replace(a, b, 1))
    print('==', name, '->', run(), flush=True)
    restore()
print('== restored ->', run(), flush=True); print('ALLDONE', flush=True)
