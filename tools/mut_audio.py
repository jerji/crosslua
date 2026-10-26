#!/usr/bin/env python3
import atexit, os, shutil, subprocess
os.chdir('/root/x4/crosspoint-lua')
F = 'src/lua/LuaAudio.cpp'
shutil.copy(F, '/tmp/orig21_LuaAudio.cpp')
def restore(): shutil.copy('/tmp/orig21_LuaAudio.cpp', F)
atexit.register(restore)
def run():
    r = subprocess.run('test/lua_host/run.sh 2>&1 | grep -E "FAILED|EXIT CODE|ALL PASSED|COMPILE" | head -2', shell=True, capture_output=True, text=True)
    return r.stdout.strip().replace('\n', ' | ')

GATE = '  if (int r = gateAudio(L)) return r;'

M = [
 ('AU1 play skips the permission gate',
  'int audio_play(lua_State* L) {\n  char path[MAX_PATH_LEN + 80];\n  if (!resolveArg(L, 1, path, sizeof(path))) return 2;\n  const bool loop = lua_toboolean(L, 2);\n' + GATE,
  'int audio_play(lua_State* L) {\n  char path[MAX_PATH_LEN + 80];\n  if (!resolveArg(L, 1, path, sizeof(path))) return 2;\n  const bool loop = lua_toboolean(L, 2);'),
 ('AU2 play skips the .wav extension check',
  '  if (n < 4 || strcasecmp(path + n - 4, ".wav") != 0) return pushFail(L, "not a .wav file");',
  '  if (false) return pushFail(L, "not a .wav file");'),
 ('AU3 play skips the 4 MB size cap',
  '  if (size > 4 * 1024 * 1024) return pushFail(L, "wav is over 4 MB',
  '  if (false) return pushFail(L, "wav is over 4 MB'),
 ('AU4 play skips the too-small floor',
  '  if (size < 44) return pushFail(L, "file is too small to be a WAV");',
  '  if (false) return pushFail(L, "file is too small to be a WAV");'),
 ('AU5 volume upper bound removed',
  '  if (v < 0 || v > 100 || v != static_cast<int>(v)) return pushFail(L, "volume must be an integer 0..100");',
  '  if (v < 0 || v > 1000 || v != static_cast<int>(v)) return pushFail(L, "volume must be an integer 0..100");'),
 ('AU6 volume lower bound removed',
  '  if (v < 0 || v > 100 || v != static_cast<int>(v)) return pushFail(L, "volume must be an integer 0..100");',
  '  if (v < -100 || v > 100 || v != static_cast<int>(v)) return pushFail(L, "volume must be an integer 0..100");'),
 ('AU7 volume skips the permission gate',
  'int audio_volume(lua_State* L) {\n  const lua_Number v = luaL_checknumber(L, 1);\n' + GATE,
  'int audio_volume(lua_State* L) {\n  const lua_Number v = luaL_checknumber(L, 1);'),
 ('AU8 stop skips the permission gate',
  'int audio_stop(lua_State* L) {\n' + GATE,
  'int audio_stop(lua_State* L) {'),
 ('AU9 playing skips the permission gate',
  'int audio_playing(lua_State* L) {\n' + GATE,
  'int audio_playing(lua_State* L) {'),
]
print('== baseline', run(), flush=True)
for name, a, b in M:
    s = open(F).read(); assert a in s, 'anchor missing: ' + name
    open(F, 'w').write(s.replace(a, b, 1))
    print('==', name, '->', run(), flush=True)
    restore()
print('== restored ->', run(), flush=True); print('ALLDONE', flush=True)