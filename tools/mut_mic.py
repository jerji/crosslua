#!/usr/bin/env python3
import atexit, os, shutil, subprocess
os.chdir('/root/x4/crosspoint-lua')
F = 'src/lua/LuaMic.cpp'
shutil.copy(F, '/tmp/orig22_LuaMic.cpp')
def restore(): shutil.copy('/tmp/orig22_LuaMic.cpp', F)
atexit.register(restore)
def run():
    r = subprocess.run('test/lua_host/run.sh 2>&1 | grep -E "FAILED|EXIT CODE|ALL PASSED|COMPILE" | head -2', shell=True, capture_output=True, text=True)
    return r.stdout.strip().replace('\n', ' | ')
G = '  if (int r = gateMic(L)) return r;'
M = [
 ('MC1 record skips the permission gate', '  const lua_Number sec = luaL_checknumber(L, 2);\n' + G, '  const lua_Number sec = luaL_checknumber(L, 2);'),
 ('MC2 level skips the permission gate', '  const lua_Number ms = lua_isnoneornil(L, 1) ? DEFAULT_LEVEL_MS : luaL_checknumber(L, 1);\n' + G, '  const lua_Number ms = lua_isnoneornil(L, 1) ? DEFAULT_LEVEL_MS : luaL_checknumber(L, 1);'),
 ('MC3 record skips the .wav check', 'if (n < 4 || strcasecmp(path + n - 4, ".wav") != 0) return pushFail(L, "path must end in .wav");', 'if (false) return pushFail(L, "path must end in .wav");'),
 ('MC4 seconds lower bound removed', 'if (sec < 1 || sec > MAX_RECORD_SECONDS', 'if (sec < 0 || sec > MAX_RECORD_SECONDS'),
 ('MC5 seconds upper bound removed', 'if (sec < 1 || sec > MAX_RECORD_SECONDS', 'if (sec < 1 || sec > MAX_RECORD_SECONDS + 5'),
 ('MC6 seconds fraction accepted', '|| sec != static_cast<int>(sec)) return pushFail(L, "seconds', ') return pushFail(L, "seconds'),
 ('MC7 level lower bound removed', 'if (ms < MIN_LEVEL_MS ||', 'if (ms < 0 ||'),
 ('MC8 level upper bound removed', '|| ms > MAX_LEVEL_MS ||', '|| ms > MAX_LEVEL_MS * 4 ||'),
 ('MC9 level default is wrong', 'DEFAULT_LEVEL_MS = 100;', 'DEFAULT_LEVEL_MS = 101;'),
 ('MC10 write sandbox skipped (wrapper checks read scope only)', 'return pathArg(L, i, true, out, cap, &sc);', 'return pathArg(L, i, false, out, cap, &sc);', 'src/lua/LuaFs.cpp'),
 ('MC11 directory target allowed', 'if (be(L).fsSize(path) == -2) return pushFail(L, "is a directory");', ''),
 ('MC12 backend failure text replaced', 'err[0] ? err : "recording failed"', '"recording failed"'),
]
print('== baseline', run(), flush=True)
for ent in M:
    name, a, b = ent[:3]
    tgt = ent[3] if len(ent) > 3 else F
    shutil.copy(tgt, '/tmp/orig22_tgt')
    s = open(tgt).read()
    if a not in s: print('!! anchor missing', name); continue
    open(tgt, 'w').write(s.replace(a, b, 1))
    print('==', name, '->', run(), flush=True)
    shutil.copy('/tmp/orig22_tgt', tgt)
    restore()
print('== restored ->', run(), flush=True); print('ALLDONE', flush=True)
