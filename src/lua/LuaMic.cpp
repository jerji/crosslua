// mic.* — record from the board's microphone. Needs the "microphone" manifest permission AND the user's approval
// (the permission screen says "MICROPHONE: record sound": a recording device is never enabled silently). Boards without
// a microphone (the X4 among them) report "no microphone on this board". Arguments are validated before the backend is
// touched.
#include <cstring>

#include "LuaInternal.h"

namespace crosslua {
namespace {

constexpr int MAX_RECORD_SECONDS = 30;  // 16 kHz * 2 bytes * 30 s = 960 KB of WAV; streamed to the card, no heap
constexpr int MIN_LEVEL_MS = 10, MAX_LEVEL_MS = 2000, DEFAULT_LEVEL_MS = 100;

int pushFail(lua_State* L, const char* msg) {
  lua_pushnil(L);
  lua_pushstring(L, msg);
  return 2;
}

int gateMic(lua_State* L) { return be(L).micAllowed() ? 0 : pushFail(L, MIC_DENIED); }

// mic.record(path, seconds) -> bytes written | nil, err. Blocking; Back cancels (nil, "cancelled"). The result is a 16
// kHz mono 16-bit PCM WAV (<= 30 s). Same write rules as fs.write (data: always, sd: only with a write grant).
int mic_record(lua_State* L) {
  char path[MAX_PATH_LEN + 80];
  if (!writePathArg(L, 1, path, sizeof(path))) return 2;
  const lua_Number sec = luaL_checknumber(L, 2);
  if (int r = gateMic(L)) return r;
  const size_t n = strlen(path);
  if (n < 4 || strcasecmp(path + n - 4, ".wav") != 0) return pushFail(L, "path must end in .wav");
  if (sec < 1 || sec > MAX_RECORD_SECONDS || sec != static_cast<int>(sec))
    return pushFail(L, "seconds must be an integer 1..30");
  if (be(L).fsSize(path) == -2) return pushFail(L, "is a directory");
  if (!ensureParentDir(be(L), path)) return pushFail(L, "cannot create directory");
  int bytes = 0;
  char err[96] = {0};
  if (!be(L).micRecord(path, static_cast<int>(sec), &bytes, err, sizeof(err)))
    return pushFail(L, err[0] ? err : "recording failed");
  lua_pushinteger(L, bytes);
  return 1;
}

// mic.level([ms = 100]) -> peak (0..32767) | nil, err. Listens for `ms` (10..2000) and keeps nothing.
int mic_level(lua_State* L) {
  const lua_Number ms = lua_isnoneornil(L, 1) ? DEFAULT_LEVEL_MS : luaL_checknumber(L, 1);
  if (int r = gateMic(L)) return r;
  if (ms < MIN_LEVEL_MS || ms > MAX_LEVEL_MS || ms != static_cast<int>(ms))
    return pushFail(L, "ms must be an integer 10..2000");
  int peak = 0;
  char err[96] = {0};
  if (!be(L).micLevel(static_cast<int>(ms), &peak, err, sizeof(err)))
    return pushFail(L, err[0] ? err : "cannot read the microphone");
  lua_pushinteger(L, peak);
  return 1;
}

}  // namespace

void registerMic(lua_State* L, Ctx* c) {
  static const luaL_Reg fns[] = {{"record", mic_record}, {"level", mic_level}, {nullptr, nullptr}};
  regTable(L, c, "mic", fns);
}

}  // namespace crosslua
