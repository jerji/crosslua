#!/usr/bin/env python3
import atexit, os, shutil, subprocess
os.chdir('/root/x4/crosspoint-lua')
F = 'src/lua/LuaSock.cpp'
shutil.copy(F, '/tmp/orig23_LuaSock.cpp')
def restore(): shutil.copy('/tmp/orig23_LuaSock.cpp', F)
atexit.register(restore)
def run():
    r = subprocess.run('test/lua_host/run.sh 2>&1 | grep -E "FAILED|EXIT CODE|ALL PASSED|COMPILE" | head -2', shell=True, capture_output=True, text=True)
    return r.stdout.strip().replace('\n', ' | ')
M = [
 ('TL1 tls without ca/insecure allowed', 'if (wantTls && !insecure && !caSpec)', 'if (false)'),
 ('TL2 ca and insecure together allowed', 'if (wantTls && insecure && caSpec)', 'if (false)'),
 ('TL3 ca/insecure without tls allowed', 'if (!wantTls && (insecure || caSpec))', 'if (false)'),
 ('TL4 ca alone without tls allowed (insecure only)', 'if (!wantTls && (insecure || caSpec))', 'if (!wantTls && insecure)'),
 ('TL5 one-TLS-at-a-time removed', 'if (wantTls && be(L).netKind(i) == 4)', 'if (false)'),
 ('TL6 free floor off by one (<=)', 'if (freeNow < TLS_MIN_FREE_BYTES ||', 'if (freeNow <= TLS_MIN_FREE_BYTES ||'),
 ('TL7 block floor off by one (<=)', 'largest < TLS_MIN_BLOCK_BYTES)', 'largest <= TLS_MIN_BLOCK_BYTES)'),
 ('TL8 block floor removed', '|| largest < TLS_MIN_BLOCK_BYTES)', ')'),
 ('TL9 free floor removed', 'if (freeNow < TLS_MIN_FREE_BYTES ||', 'if ('),
 ('TL10 missing ca file not reported', 'if (sz == -1) return pushFail(L, "ca file not found");', ''),
 ('TL11 ca max grows by one', 'CA_MAX_BYTES = 8192', 'CA_MAX_BYTES = 8193'),
 ('TL12 ca min shrinks', 'CA_MIN_BYTES = 32', 'CA_MIN_BYTES = 1'),
 ('TL13 ca not NUL terminated', "pem[sz] = '\\0';", ''),
 ('TL14 kind 4 not accepted as TCP', '(kind == 1 && k == 4)', '(false)'),
 ('TL15 ca type check removed', 'if (lua_type(L, -1) != LUA_TSTRING) return luaL_argerror(L, 3, "ca must be a path string");', ''),
 ('TL16 ca not passed to the backend', 'be(L).netConnectTls(host, static_cast<int>(port), static_cast<int>(timeout), pem,', 'be(L).netConnectTls(host, static_cast<int>(port), static_cast<int>(timeout), nullptr,'),
 ('TL17 tls ignored (plain connect used)', 'if (!wantTls) {\n    slot =', 'if (true) {\n    slot ='),
]
print('== baseline', run(), flush=True)
for name, a, b in M:
    s = open(F).read()
    if a not in s: print('!! anchor missing', name); continue
    open(F, 'w').write(s.replace(a, b, 1))
    print('==', name, '->', run(), flush=True)
    restore()
print('== restored ->', run(), flush=True); print('ALLDONE', flush=True)
