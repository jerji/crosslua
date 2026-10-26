#!/usr/bin/env python3
import atexit, os, shutil, subprocess
os.chdir('/root/x4/crosspoint-lua')
F = 'src/lua/LuaFs.cpp'
shutil.copy(F, '/tmp/orig24_LuaFs.cpp')
def restore(): shutil.copy('/tmp/orig24_LuaFs.cpp', F)
atexit.register(restore)
def run():
    r = subprocess.run('test/lua_host/run.sh 2>&1 | grep -E "FAILED|EXIT CODE|ALL PASSED|COMPILE" | head -2', shell=True, capture_output=True, text=True)
    return r.stdout.strip().replace('\n', ' | ')
M = [
 ('FS1 negative offset allowed', 'if (offset < 0 || offset > 100000 ||', 'if (offset > 100000 ||'),
 ('FS2 fractional offset allowed', 'offset > 100000 || offset != static_cast<int>(offset))', 'offset > 100000)'),
 ('FS3 offset ceiling raised', 'offset > 100000', 'offset > 200000'),
 ('FS4 detail limit ceiling raised', 'LIST_MAX_DETAIL = 64', 'LIST_MAX_DETAIL = 65'),
 ('FS5 names limit ceiling raised', 'LIST_MAX_NAMES = 512', 'LIST_MAX_NAMES = 513'),
 ('FS6 default detail window grows', 'LIST_DEFAULT_DETAIL = 32', 'LIST_DEFAULT_DETAIL = 33'),
 ('FS7 unknown option accepted', '''      } else {
        char msg[64];
        snprintf(msg, sizeof(msg), "unknown option '%.24s'", k);
        return pushFail(L, msg);
      }''', '      }'),
 ('FS8 detail type unchecked', 'if (lua_type(L, -1) != LUA_TBOOLEAN) return pushFail(L, "detail must be a boolean");', ''),
 ('FS9 limit zero allowed', 'limit < 1 || limit > maxLimit', 'limit < 0 || limit > maxLimit'),
 ('FS10 limit fraction allowed', '|| limit != static_cast<int>(limit)) {', ') {'),
 ('FS11 vanished folder loses dir flag', '      st.isDir = dir;\n', ''),
 ('FS12 trailing slash kept in detail names', "if (dir) entry[el - 1] = '\\0';", ''),
 ('FS13 total not returned', 'lua_pushinteger(L, n);\n  return 2;', 'return 1;'),
 ('FS14 Feb counted in the wrong year (leap)', '(mon <= 2 ? 1 : 0)', '(mon <= 1 ? 1 : 0)'),
 ('FS15 month 13 accepted', 'mon > 12', 'mon > 13'),
 ('FS16 hour 24 accepted', 'hour > 23', 'hour > 24'),
 ('FS17 minute 60 accepted', 'min > 59', 'min > 60'),
 ('FS18 second 60 accepted', 'sec > 59', 'sec > 60'),
 ('FS19 day 0 accepted', 'day < 1', 'day < 0'),
 ('FS20 month 0 accepted', 'mon < 1', 'mon < 0'),
 ('FS21 times past 2038 wrap instead of unknown', 'if (m != 0 && m <= LUA_INT_MAX) {', 'if (m != 0) {'),
 ('FS22 sizes above 2 GiB not clamped', 'static_cast<lua_Integer>(std::min(st.size, LUA_INT_MAX))', 'static_cast<lua_Integer>(st.size)'),
 ('FS23 window end off by one', 'std::min(n, first + static_cast<int>(limit))', 'std::min(n, first + static_cast<int>(limit) + 1)'),
 ('FS24 window start off by one', 'for (int i = first + 1; i <= last; i++)', 'for (int i = first; i <= last; i++)'),
 ('FS25 dir size reported', 'lua_pushboolean(L, st.isDir);', 'lua_pushboolean(L, !st.isDir);'),
 ('FS26 stat of a missing path succeeds', 'if (!be(L).fsStat(path, &st)) return pushFail(L, "no such file");', ''),
]
print('== baseline', run(), flush=True)
for name, a, b in M:
    s = open(F).read()
    if a not in s: print('!! anchor missing', name); continue
    open(F, 'w').write(s.replace(a, b, 1))
    print('==', name, '->', run(), flush=True)
    restore()
print('== restored ->', run(), flush=True); print('ALLDONE', flush=True)
