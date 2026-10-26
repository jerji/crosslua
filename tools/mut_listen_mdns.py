#!/usr/bin/env python3
import atexit, os, shutil, subprocess
os.chdir('/root/x4/crosspoint-lua')
F = 'src/lua/LuaSock.cpp'
shutil.copy(F, '/tmp/orig19_LuaSock.cpp')
def restore(): shutil.copy('/tmp/orig19_LuaSock.cpp', F)
atexit.register(restore)
def run():
    r = subprocess.run('test/lua_host/run.sh 2>&1 | grep -E "FAILED|EXIT CODE|ALL PASSED|COMPILE" | head -2', shell=True, capture_output=True, text=True)
    return r.stdout.strip().replace('\n', ' | ')

GATE_LISTEN = '  if (int r = gateListen(L)) return r;'
SLOT_ARG = '  if (int r = slotArg(L, 1, &slot)) return r;'
CHECK_KIND_SERVER = '  if (int r = checkKind(L, slot, 3, "server")) return r;'
LISTEN_PERM = '  if (!be(L).listenAllowed()) return pushFail(L, LISTEN_DENIED);'
GATE_ONLINE = '  if (int r = gateOnline(L)) return r;'

M = [
 # --- net.listen gate mutations ---
 ('L1 listen skips the permission+WiFi gate',
  'int net_listen(lua_State* L) {\n  const lua_Number port = luaL_checknumber(L, 1);\n' + GATE_LISTEN,
  'int net_listen(lua_State* L) {\n  const lua_Number port = luaL_checknumber(L, 1);'),
 ('L2 listen accepts port 0',
  'if (port < 1 || port > 65535 || port != static_cast<int>(port)) return pushFail(L, "port must be an integer 1..65535");',
  'if (port < 0 || port > 65535 || port != static_cast<int>(port)) return pushFail(L, "port must be an integer 1..65535");'),
 ('L3 listen accepts port 65536',
  'if (port < 1 || port > 65535 || port != static_cast<int>(port)) return pushFail(L, "port must be an integer 1..65535");',
  'if (port < 1 || port > 70000 || port != static_cast<int>(port)) return pushFail(L, "port must be an integer 1..65535");'),
 ('L4 listen skips the RAM check',
  '  const size_t freeNow = be(L).freeHeap();\n  if (freeNow < SOCK_MIN_FREE_BYTES) {\n    char msg[96];\n    snprintf(msg, sizeof(msg), "not enough free RAM for a socket (free %uK, need %uK)", static_cast<unsigned>(freeNow / 1024),\n             static_cast<unsigned>(SOCK_MIN_FREE_BYTES / 1024));\n    return pushFail(L, msg);\n  }',
  '  // RAM check skipped'),
 ('L5 listen skips the free-slot check',
  'bool free = false;\n  for (int i = 0; i < Backend::MAX_SOCKETS; i++) free = free || !be(L).netIsOpen(i);\n  if (!free) return pushFail(L, "too many open sockets (max 8)");',
  '// free slot check skipped\n'),
 ('L6 listen error becomes generic',
  '  if (slot < 0) return pushFail(L, err[0] ? err : "cannot listen on port");',
  '  if (slot < 0) return pushFail(L, "cannot listen on port");'),

 # --- net.accept gate mutations ---
 ('A1 accept skips slot arg check',
  'if (int r = slotArg(L, 1, &slot)) return r;\n' + CHECK_KIND_SERVER,
  '\n' + CHECK_KIND_SERVER),
 ('A2 accept skips kind check',
  CHECK_KIND_SERVER + '\n' + LISTEN_PERM,
  '\n' + LISTEN_PERM),
 ('A3 accept skips listen permission check',
  LISTEN_PERM + '\n  const int clientSlot = be(L).netAccept(slot);',
  '\n  const int clientSlot = be(L).netAccept(slot);'),
 ('A4 accept error becomes no-pending',
  '  if (clientSlot == -2) return pushFail(L, "accept failed");\n  if (clientSlot < 0) {',
  '  if (clientSlot < 0) {'),

 # --- net.mdns_query gate mutations ---
 ('M1 mdns skips permission+WiFi gate',
  'int net_mdns_query(lua_State* L) {\n  const char* service = luaL_checkstring(L, 1);\n  const char* proto = luaL_checkstring(L, 2);\n' + GATE_ONLINE,
  'int net_mdns_query(lua_State* L) {\n  const char* service = luaL_checkstring(L, 1);\n  const char* proto = luaL_checkstring(L, 2);'),
 ('M2 mdns accepts empty service',
  'if (strlen(service) == 0 || strlen(service) > 60) return pushFail(L, "invalid service type");',
  'if (false) return pushFail(L, "invalid service type");'),
 ('M3 mdns accepts any proto',
  'if (strcmp(proto, "tcp") != 0 && strcmp(proto, "udp") != 0) return pushFail(L, "proto must be \\"tcp\\" or \\"udp\\"");',
  'if (false) return pushFail(L, "proto must be \\"tcp\\" or \\"udp\\"");'),
 ('M4 mdns query failure is hidden',
  '  if (n < 0) return pushFail(L, err[0] ? err : "mDNS query failed");',
  '  if (false) return pushFail(L, err[0] ? err : "mDNS query failed");'),
]

print('== baseline', run(), flush=True)
for name, a, b in M:
    s = open(F).read(); assert a in s, 'anchor missing: ' + name
    open(F, 'w').write(s.replace(a, b, 1))
    print('==', name, '->', run(), flush=True)
    restore()
print('== restored ->', run(), flush=True); print('ALLDONE', flush=True)