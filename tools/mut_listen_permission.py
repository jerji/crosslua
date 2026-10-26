#!/usr/bin/env python3
import atexit, os, shutil, subprocess
os.chdir('/root/x4/crosspoint-lua')
F = 'src/lua/LuaSock.cpp'
shutil.copy(F, '/tmp/orig20_LuaSock.cpp')
def restore(): shutil.copy('/tmp/orig20_LuaSock.cpp', F)
atexit.register(restore)
def run():
    r = subprocess.run('test/lua_host/run.sh 2>&1 | grep -E "FAILED|EXIT CODE|ALL PASSED|COMPILE" | head -2', shell=True, capture_output=True, text=True)
    return r.stdout.strip().replace('\n', ' | ')

GL_NET = '  if (!be(L).netAllowed()) return pushFail(L, NET_DENIED);\n  if (!be(L).listenAllowed()) return pushFail(L, LISTEN_DENIED);'

M = [
 ('LP1 gateListen skips the network-permission layer',
  'int gateListen(lua_State* L) {\n' + GL_NET,
  'int gateListen(lua_State* L) {\n  if (!be(L).listenAllowed()) return pushFail(L, LISTEN_DENIED);'),
 ('LP2 accept skips the network-permission layer',
  '  if (int r = checkKind(L, slot, 3, "server")) return r;\n  if (!be(L).netAllowed()) return pushFail(L, NET_DENIED);\n  if (!be(L).listenAllowed()) return pushFail(L, LISTEN_DENIED);\n  const int clientSlot',
  '  if (int r = checkKind(L, slot, 3, "server")) return r;\n  if (!be(L).listenAllowed()) return pushFail(L, LISTEN_DENIED);\n  const int clientSlot'),
]
print('== baseline', run(), flush=True)
for name, a, b in M:
    s = open(F).read(); assert a in s, 'anchor missing: ' + name
    open(F, 'w').write(s.replace(a, b, 1))
    print('==', name, '->', run(), flush=True)
    restore()
print('== restored ->', run(), flush=True); print('ALLDONE', flush=True)