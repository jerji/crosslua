// audio.* — play a WAV file through the board's speaker. Boards without the AUDIO cap report absence
// ("no audio on this board"), never crash. Needs the "audio" manifest permission AND the user's approval
// (the permission screen, like storage grants and listen).
//
// Same rule as LuaNet.cpp/LuaSock.cpp: arguments are validated into plain values before the backend is
// touched, and errors return nil, err instead of raising.
#include <cstring>

#include "LuaInternal.h"

namespace crosslua {
namespace {

int pushFail(lua_State* L, const char* msg) {
  lua_pushnil(L);
  lua_pushstring(L, msg);
  return 2;
}

// Permission gate: the manifest must ask for "audio" and the user must have approved the request.
int gateAudio(lua_State* L) {
  if (!be(L).audioAllowed()) return pushFail(L, AUDIO_DENIED);
  return 0;
}

bool resolveArg(lua_State* L, int i, char* out, size_t cap) {
  const char* spec = luaL_checkstring(L, i);
  Scope sc;
  const char* err = nullptr;
  if (!resolvePath(be(L), spec, out, cap, &sc, &err)) {
    pushFail(L, err);
    return false;
  }
  return true;
}

// audio.play(path [, loop]) -> true | nil, err. 16-bit PCM WAV, 8-48 kHz (Metalio: 16 kHz). Returns
// immediately: playback runs in the SDK's own task, audio.stop() ends it.
int audio_play(lua_State* L) {
  char path[MAX_PATH_LEN + 80];
  if (!resolveArg(L, 1, path, sizeof(path))) return 2;
  const bool loop = lua_toboolean(L, 2);
  if (int r = gateAudio(L)) return r;
  const size_t n = strlen(path);
  if (n < 4 || strcasecmp(path + n - 4, ".wav") != 0) return pushFail(L, "not a .wav file");
  const int64_t size = be(L).fsSize(path);
  if (size == -1) return pushFail(L, "no such file");
  if (size == -2) return pushFail(L, "is a directory");
  if (size < 44) return pushFail(L, "file is too small to be a WAV");
  if (size > 4 * 1024 * 1024) return pushFail(L, "wav is over 4 MB (the SD card read during playback would stutter)");
  char err[96] = {0};
  if (!be(L).audioPlay(path, loop, err, sizeof(err))) return pushFail(L, err[0] ? err : "cannot play the file");
  lua_pushboolean(L, 1);
  return 1;
}

// audio.stop() -> true
int audio_stop(lua_State* L) {
  if (int r = gateAudio(L)) return r;
  be(L).audioStop();
  lua_pushboolean(L, 1);
  return 1;
}

// audio.volume(pct 0..100) -> true | nil, err
int audio_volume(lua_State* L) {
  const lua_Number v = luaL_checknumber(L, 1);
  if (int r = gateAudio(L)) return r;
  if (v < 0 || v > 100 || v != static_cast<int>(v)) return pushFail(L, "volume must be an integer 0..100");
  be(L).audioVolume(static_cast<int>(v));
  lua_pushboolean(L, 1);
  return 1;
}

// audio.playing() -> boolean
int audio_playing(lua_State* L) {
  if (int r = gateAudio(L)) return r;
  lua_pushboolean(L, be(L).audioPlaying());
  return 1;
}

}  // namespace

void registerAudio(lua_State* L, Ctx* c) {
  static const luaL_Reg fns[] = {{"play", audio_play}, {"stop", audio_stop}, {"volume", audio_volume},
                                 {"playing", audio_playing}, {nullptr, nullptr}};
  regTable(L, c, "audio", fns);
}

}  // namespace crosslua