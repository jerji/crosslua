#pragma once
// Shared helpers for the API translation units. Not part of the public surface.
#include "LuaApi.h"

extern "C" {
#include "lauxlib.h"
#include "lua.h"
}

namespace crosslua {

class LuaVm;

struct Ctx {
  Backend* be;
  LuaVm* vm;
};
inline Ctx* ctx(lua_State* L) { return static_cast<Ctx*>(lua_touserdata(L, lua_upvalueindex(1))); }
inline Backend& be(lua_State* L) { return *ctx(L)->be; }

// Registers a global table of C functions that all share the Ctx upvalue.
void regTable(lua_State* L, Ctx* c, const char* name, const luaL_Reg* funcs);

constexpr size_t MAX_PATH_LEN = 200;
constexpr size_t MAX_READ_BYTES = 128 * 1024;
constexpr size_t MAX_WRITE_BYTES = 256 * 1024;
constexpr size_t MAX_WRITE_AT_BYTES = 16 * 1024;
constexpr size_t MAX_MODULE_BYTES = 64 * 1024;

enum class Scope { App, Data, Lib, Sd };  // Sd = the SD card outside the sandbox: read-only, needs "library", no hidden paths

// Path sandbox. Accepts "app:rel", "data:rel", "lib:rel" or bare "rel" (= app:). rel must be a clean
// relative path: no "..", ".", empty parts, leading '/', backslashes, ':' or control chars.
// On success writes the absolute SD path to out and returns true; otherwise sets *err.
bool resolvePath(Backend& be, const char* spec, char* out, size_t cap, Scope* scope, const char** err);
// Same, for an already-split scope + relative path.
bool resolveIn(Backend& be, Scope scope, const char* rel, char* out, size_t cap, const char** err);

// ---- storage grants (see LuaApi.h) ----
// Normalises a manifest grant ("Books", "Books/AO3/", "/" = whole card) into out ("Books", "Books/AO3", ""). false for
// anything unsafe: "..", ".", hidden (dot) components, ':' or '\\', control chars, empty components, too long.
bool parseGrantPath(const char* in, char* out, size_t cap);
// A grant that reaches other apps' code or the whole card (write): shown with a louder warning.
bool grantIsDangerous(const char* rel);
// Does an approved grant cover rel (relative, no leading '/')? write=true needs a WRITE grant.
bool sdCovered(Backend& b, const char* rel, bool write);
// May this app WRITE absPath ("/Books/x.epub") in scope sc? data: always; sd: only under a write grant, never *.bin.
bool writeAllowed(Backend& b, Scope sc, const char* absPath);

void registerFs(lua_State* L, Ctx* c);
void registerJson(lua_State* L, Ctx* c);
void registerRequire(lua_State* L, Ctx* c);
void registerNet(lua_State* L, Ctx* c);
void registerZip(lua_State* L, Ctx* c);

}  // namespace crosslua
