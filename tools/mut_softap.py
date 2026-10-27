#!/usr/bin/env python3
import atexit, os, shutil, subprocess
os.chdir('/root/x4/crosspoint-lua')
FILES = ['src/lua/LuaNet.cpp', 'src/lua/LuaSock.cpp']
for i, f in enumerate(FILES): shutil.copy(f, '/tmp/orig26_%d' % i)
def restore():
    for i, f in enumerate(FILES): shutil.copy('/tmp/orig26_%d' % i, f)
atexit.register(restore)
def run():
    r = subprocess.run('test/lua_host/run.sh 2>&1 | grep -E "FAILED|EXIT CODE|ALL PASSED|COMPILE" | head -2', shell=True, capture_output=True, text=True)
    return r.stdout.strip().replace('\n', ' | ')
N = 'src/lua/LuaNet.cpp'; S = 'src/lua/LuaSock.cpp'
GATE = '  if (!allowed(L)) return pushNo(L, DENIED);\n  if (!be(L).hotspotAllowed()) return pushNo(L, HOTSPOT_DENIED);'
M = [
 ('SA1 hotspot permission not checked', '  if (!be(L).hotspotAllowed()) return pushNo(L, HOTSPOT_DENIED);', '', N),
 ('SA2 network permission not checked', GATE, '  if (!be(L).hotspotAllowed()) return pushNo(L, HOTSPOT_DENIED);', N),
 ('SA3 ssid max 33', 'sl > 32 ||', 'sl > 33 ||', N),
 ('SA4 empty ssid allowed', 'if (sl < 1 || sl > 32', 'if (sl > 32', N),
 ('SA5 ssid printable check removed', 'sl > 32 || !printableAscii(ssid, sl))', 'sl > 32)', N),
 ('SA6 password min 7', 'if (pl < 8 ||', 'if (pl < 7 ||', N),
 ('SA7 password max 64', 'pl > 63 ||', 'pl > 64 ||', N),
 ('SA8 password printable check removed', ' || !printableAscii(password, pl))', ')', N),
 ('SA9 channel 0 allowed', 'if (channel < 1 || channel > 11', 'if (channel < 0 || channel > 11', N),
 ('SA10 channel 12 allowed', 'channel > 11 ||', 'channel > 12 ||', N),
 ('SA11 fractional channel allowed', 'channel > 11 || channel != static_cast<int>(channel))', 'channel > 11)', N),
 ('SA12 max_clients 0 allowed', 'if (maxClients < 1 ||', 'if (maxClients < 0 ||', N),
 ('SA13 max_clients 5 allowed', 'maxClients > SOFTAP_MAX_CLIENTS ||', 'maxClients > SOFTAP_MAX_CLIENTS + 1 ||', N),
 ('SA14 fractional max_clients allowed', 'maxClients > SOFTAP_MAX_CLIENTS || maxClients != static_cast<int>(maxClients))', 'maxClients > SOFTAP_MAX_CLIENTS)', N),
 ('SA15 already-running check removed', 'if (be(L).softApInfo(cur, sizeof(cur), curIp, sizeof(curIp), &clients)) return pushNo(L, "a hotspot is already running (wifi.off() stops it)");', '', N),
 ('SA16 joined-as-client check removed', 'if (be(L).wifiConnected()) return pushNo(L, "WiFi is joined as a client', 'if (false) return pushNo(L, "WiFi is joined as a client', N),
 ('SA17 RAM floor off by one (<=)', 'if (freeNow < SOFTAP_MIN_FREE_BYTES) {', 'if (freeNow <= SOFTAP_MIN_FREE_BYTES) {', N),
 ('SA18 RAM floor lowered', 'SOFTAP_MIN_FREE_BYTES = 80 * 1024;', 'SOFTAP_MIN_FREE_BYTES = 40 * 1024;', N),
 ('SA19 unknown option accepted', '''      } else {
        char msg[64];
        snprintf(msg, sizeof(msg), "unknown option '%.24s'", k);
        return pushNo(L, msg);
      }
      lua_pop(L, 1);
    }
  }
  if (!allowed(L)) return pushNo(L, DENIED);
  if (!be(L).hotspotAllowed())''', '''      }
      lua_pop(L, 1);
    }
  }
  if (!allowed(L)) return pushNo(L, DENIED);
  if (!be(L).hotspotAllowed())''', N),
 ('SA20 password type unchecked', 'if (lua_type(L, -1) != LUA_TSTRING) return pushNo(L, "password must be a string");', '', N),
 ('SA21 channel type unchecked', 'if (lua_type(L, -1) != LUA_TNUMBER) return pushNo(L, "channel must be an integer 1..11");', '', N),
 ('SA22 ip not returned', 'lua_pushboolean(L, 1);\n  lua_pushstring(L, ip);\n  return 2;', 'lua_pushboolean(L, 1);\n  return 1;', N),
 ('SA23 softap_info ignores the network permission', 'int wifi_softap_info(lua_State* L) {\n  if (!allowed(L)) return pushFail(L, DENIED);', 'int wifi_softap_info(lua_State* L) {', N),
 ('SA24 default channel wrong', 'lua_Number channel = 1,', 'lua_Number channel = 2,', N),
 ('SA25 default max_clients wrong', 'maxClients = SOFTAP_MAX_CLIENTS;', 'maxClients = 3;', N),
 ('SA26 clients count not reported', 'lua_pushinteger(L, clients);', 'lua_pushinteger(L, 0);', N),
 ('SA27 net.* ignores the hotspot (gateOnline)', '  return be(L).netReady() ? 0 : pushFail(L, NOT_CONNECTED);', '  return be(L).wifiConnected() ? 0 : pushFail(L, NOT_CONNECTED);', S),
 ('SA28 net.listen ignores the hotspot (gateListen)', '  if (!be(L).netReady()) return pushFail(L, NOT_CONNECTED);\n  return 0;\n}\n\n// net.listen(port)', '  if (!be(L).wifiConnected()) return pushFail(L, NOT_CONNECTED);\n  return 0;\n}\n\n// net.listen(port)', S),
]
print('== baseline', run(), flush=True)
for name, a, b, f in M:
    s = open(f).read()
    if a not in s: print('!! anchor missing', name); continue
    open(f, 'w').write(s.replace(a, b, 1))
    print('==', name, '->', run(), flush=True)
    restore()
print('== restored ->', run(), flush=True); print('ALLDONE', flush=True)
