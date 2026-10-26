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

enum class Scope { App, Data, Lib };

// Path sandbox. Accepts "app:rel", "data:rel", "lib:rel" or bare "rel" (= app:). rel must be a clean
// relative path: no "..", ".", empty parts, leading '/', backslashes, ':' or control chars.
// On success writes the absolute SD path to out and returns true; otherwise sets *err.
bool resolvePath(Backend& be, const char* spec, char* out, size_t cap, Scope* scope, const char** err);
// Same, for an already-split scope + relative path.
bool resolveIn(Backend& be, Scope scope, const char* rel, char* out, size_t cap, const char** err);

void registerFs(lua_State* L, Ctx* c);
void registerJson(lua_State* L, Ctx* c);
void registerRequire(lua_State* L, Ctx* c);
void registerNet(lua_State* L, Ctx* c);

}  // namespace crosslua
