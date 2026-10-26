// zip.* — read entries of a ZIP/EPUB without holding it in RAM. Paths use the normal fs scopes (app:/data:/sd:).
//
// Same discipline as LuaNet.cpp: arguments become plain pointers, the backend works on POD + one malloc'd buffer, and the
// result is pushed from inside lua_pcall so an out-of-memory error can never skip the free().
#include <cctype>
#include <cstdlib>
#include <cstring>

#include "LuaInternal.h"

namespace crosslua {
namespace {

constexpr int DEFAULT_LIST = 64;
constexpr int HARD_LIST = 128;
constexpr size_t DEFAULT_READ = 32 * 1024;
constexpr size_t HARD_READ = 64 * 1024;
constexpr size_t MAX_ENTRY_NAME = 200;

int pushFail(lua_State* L, const char* msg) {
  lua_pushnil(L);
  lua_pushstring(L, msg);
  return 2;
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

struct PushList {
  const Backend::ZipEntryInfo* entries;
  int n;
  int total;
};
int push_list(lua_State* L) {
  const PushList* p = static_cast<const PushList*>(lua_touserdata(L, 1));
  lua_createtable(L, p->n, 0);
  for (int i = 0; i < p->n; i++) {
    lua_createtable(L, 0, 2);
    lua_pushstring(L, p->entries[i].name);
    lua_setfield(L, -2, "name");
    lua_pushinteger(L, static_cast<lua_Integer>(p->entries[i].size));
    lua_setfield(L, -2, "size");
    lua_rawseti(L, -2, i + 1);
  }
  lua_pushinteger(L, p->total);
  return 2;
}

// zip.list(path [, max=64]) -> { {name=, size=}, ... }, total_entries | nil, err
int zip_list(lua_State* L) {
  char path[MAX_PATH_LEN + 80];
  if (!resolveArg(L, 1, path, sizeof(path))) return 2;
  const lua_Number mx = lua_isnoneornil(L, 2) ? DEFAULT_LIST : luaL_checknumber(L, 2);
  if (mx < 1 || mx > HARD_LIST) return pushFail(L, "max must be 1..128");
  const int max = static_cast<int>(mx);
  Backend::ZipEntryInfo* entries = static_cast<Backend::ZipEntryInfo*>(malloc(sizeof(Backend::ZipEntryInfo) * max));
  if (!entries) return pushFail(L, "out of memory");
  int total = 0;
  char err[96] = {0};
  const int n = be(L).zipList(path, entries, max, &total, err, sizeof(err));
  if (n < 0) {
    free(entries);
    return pushFail(L, err[0] ? err : "cannot read zip");
  }
  PushList p{entries, n, total};
  lua_pushcfunction(L, push_list);
  lua_pushlightuserdata(L, &p);
  const int rc = lua_pcall(L, 1, 2, 0);
  free(entries);
  if (rc != LUA_OK) {
    lua_pop(L, 1);
    return pushFail(L, "not enough memory for the entry list (lower max)");
  }
  return 2;
}

struct PushData {
  const char* data;
  size_t len;
};
int push_data(lua_State* L) {
  const PushData* p = static_cast<const PushData*>(lua_touserdata(L, 1));
  lua_pushlstring(L, p->data ? p->data : "", p->len);
  return 1;
}

// zip.read(path, entry [, max_bytes=32768]) -> string | nil, err   (inflated; refuses entries larger than max_bytes)
int zip_read(lua_State* L) {
  char path[MAX_PATH_LEN + 80];
  if (!resolveArg(L, 1, path, sizeof(path))) return 2;
  size_t nameLen = 0;
  const char* name = luaL_checklstring(L, 2, &nameLen);
  if (nameLen == 0 || nameLen > MAX_ENTRY_NAME || strlen(name) != nameLen) return pushFail(L, "bad entry name");
  const lua_Number mb = lua_isnoneornil(L, 3) ? static_cast<lua_Number>(DEFAULT_READ) : luaL_checknumber(L, 3);
  if (mb < 1 || mb > static_cast<lua_Number>(HARD_READ)) return pushFail(L, "max_bytes must be 1..65536");
  char* data = nullptr;
  size_t len = 0;
  char err[96] = {0};
  if (!be(L).zipRead(path, name, static_cast<size_t>(mb), &data, &len, err, sizeof(err))) {
    free(data);
    return pushFail(L, err[0] ? err : "cannot read entry");
  }
  PushData p{data, len};
  lua_pushcfunction(L, push_data);
  lua_pushlightuserdata(L, &p);
  const int rc = lua_pcall(L, 1, 1, 0);
  free(data);
  if (rc != LUA_OK) {
    lua_pop(L, 1);
    return pushFail(L, "not enough memory for the entry");
  }
  return 1;
}

}  // namespace

// zip.inflate(bytes [, zlib]) -> string | nil, err. Decompress a raw DEFLATE stream (gzip member bodies,
// .dict.dz) or a zlib-wrapped one. Input <= 64 KB, output <= 96 KB; one entry at a time, like zip.read.
int zip_inflate(lua_State* L) {
  size_t n = 0;
  const char* data = luaL_checklstring(L, 1, &n);
  const bool zlib = lua_toboolean(L, 2);
  if (n < 1 || n > 64 * 1024) return pushFail(L, "input must be 1..65536 bytes");
  char err[96] = {0};
  char* out = nullptr;
  size_t outLen = 0;
  if (!be(L).inflate(data, n, zlib, 96 * 1024, &out, &outLen, err, sizeof(err))) return pushFail(L, err);
  lua_pushlstring(L, out, outLen);
  free(out);
  return 1;
}

// gfx.image(path, x, y [, box_w, box_h]) -> drawn_w, drawn_h | nil, err
// PNG/JPEG from app:/data:/sd: (sd: needs "library"), decoded row by row into the current frame, fitted into the box
// (default: from x,y to the screen edge), never upscaled, centred in the box, dithered to black/white. Call
// gfx.present() afterwards like for any drawing.
static int gfx_image(lua_State* L) {
  char path[MAX_PATH_LEN + 80];
  if (!resolveArg(L, 1, path, sizeof(path))) return 2;
  const int x = static_cast<int>(luaL_checknumber(L, 2));
  const int y = static_cast<int>(luaL_checknumber(L, 3));
  const int sw = be(L).width(), sh = be(L).height();
  if (x < 0 || y < 0 || x >= sw || y >= sh) return pushFail(L, "x,y must be on the screen");
  int bw = lua_isnoneornil(L, 4) ? sw - x : static_cast<int>(luaL_checknumber(L, 4));
  int bh = lua_isnoneornil(L, 5) ? sh - y : static_cast<int>(luaL_checknumber(L, 5));
  if (bw < 8 || bh < 8) return pushFail(L, "box must be at least 8x8");
  if (x + bw > sw) bw = sw - x;  // clip to the screen
  if (y + bh > sh) bh = sh - y;
  const size_t pl = strlen(path);
  auto endsWith = [&](const char* ext) {
    const size_t el = strlen(ext);
    if (pl < el) return false;
    for (size_t i = 0; i < el; i++)
      if (tolower(static_cast<unsigned char>(path[pl - el + i])) != ext[i]) return false;
    return true;
  };
  if (!endsWith(".png") && !endsWith(".jpg") && !endsWith(".jpeg")) return pushFail(L, "unsupported image type (png, jpg)");
  const int64_t size = be(L).fsSize(path);
  if (size == -1) return pushFail(L, "no such file");
  if (size == -2) return pushFail(L, "is a directory");
  if (size == 0 || size > 6 * 1024 * 1024) return pushFail(L, "image file is empty or over 6 MB");
  int dw = 0, dh = 0;
  char err[96] = {0};
  if (!be(L).drawImage(path, x, y, bw, bh, &dw, &dh, err, sizeof(err))) return pushFail(L, err[0] ? err : "cannot draw image");
  lua_pushinteger(L, dw);
  lua_pushinteger(L, dh);
  return 2;
}

void registerZip(lua_State* L, Ctx* c) {
  static const luaL_Reg fns[] = {{"list", zip_list}, {"read", zip_read}, {"inflate", zip_inflate}, {nullptr, nullptr}};
  regTable(L, c, "zip", fns);
  lua_getglobal(L, "gfx");  // gfx.image lives here because it shares the path sandbox with zip/fs
  if (lua_istable(L, -1)) {
    lua_pushlightuserdata(L, c);
    lua_pushcclosure(L, gfx_image, 1);
    lua_setfield(L, -2, "image");
  }
  lua_pop(L, 1);
}

}  // namespace crosslua
