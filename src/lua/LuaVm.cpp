#include "LuaVm.h"

#include <cstdlib>
#include <cstring>

extern "C" {
#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"
}

namespace crosslua {

void* LuaVm::allocFn(void* ud, void* ptr, size_t osize, size_t nsize) {
  auto* st = static_cast<Alloc*>(ud);
  if (nsize == 0) {
    if (ptr) {
      free(ptr);
      st->used -= osize;
    }
    return nullptr;
  }
  // When ptr==nullptr, osize encodes the object type, not a size (Lua manual).
  const size_t old = ptr ? osize : 0;
  if (nsize > old && st->used + (nsize - old) > st->budget) return nullptr;  // Lua raises "not enough memory"
  void* np = realloc(ptr, nsize);
  if (!np) return nullptr;
  st->used = st->used - old + nsize;
  if (st->used > st->peak) st->peak = st->used;
  return np;
}

void LuaVm::hookFn(lua_State* L, void* /*ar*/) {
  // Count hook: hand control back to the host. Hooks may only yield 0 values.
  lua_yield(L, 0);
}

static void openSandbox(lua_State* L) {
  // Deliberately NOT luaL_openlibs: no io/os/package/debug. Files go through fs.*.
  static const luaL_Reg libs[] = {{LUA_GNAME, luaopen_base},     {LUA_TABLIBNAME, luaopen_table},
                                  {LUA_STRLIBNAME, luaopen_string}, {LUA_MATHLIBNAME, luaopen_math},
                                  {LUA_UTF8LIBNAME, luaopen_utf8},  {LUA_COLIBNAME, luaopen_coroutine},
                                  {nullptr, nullptr}};
  for (const luaL_Reg* l = libs; l->func; l++) {
    luaL_requiref(L, l->name, l->func, 1);
    lua_pop(L, 1);
  }
  // Base functions that read the filesystem via fopen() or can load binary chunks.
  static const char* const removed[] = {"dofile", "loadfile", "load", "loadstring", nullptr};
  for (const char* const* n = removed; *n; n++) {
    lua_pushnil(L);
    lua_setglobal(L, *n);
  }
}

bool LuaVm::open(size_t budgetBytes) {
  close();
  alloc_ = Alloc{};
  alloc_.budget = budgetBytes;
  L_ = lua_newstate(&LuaVm::allocFn, &alloc_);
  if (!L_) return false;
  lua_atpanic(L_, [](lua_State* L) -> int {
    // Unprotected error (should not happen: everything runs inside a coroutine).
    // Returning aborts the process; the message is the best we can leave behind.
    (void)L;
    return 0;
  });
  openSandbox(L_);
  return true;
}

void LuaVm::close() {
  if (L_) lua_close(L_);  // frees every Lua object -> usedBytes()==0
  L_ = nullptr;
  co_ = nullptr;
  status_ = Status::Idle;
}

bool LuaVm::load(const char* chunkName, const char* src, size_t len) {
  error_.clear();
  if (!L_) {
    error_ = "vm not open";
    return false;
  }
  if (len > 0 && src[0] == LUA_SIGNATURE[0]) {  // "\x1bLua": precompiled chunk
    error_ = "precompiled chunks are not allowed";
    return false;
  }
  co_ = lua_newthread(L_);  // anchored on L_'s stack
  if (!co_) {
    error_ = "out of memory";
    return false;
  }
  lua_setfield(L_, LUA_REGISTRYINDEX, "crosslua.main");  // keep it alive
  if (luaL_loadbufferx(co_, src, len, chunkName, "t") != LUA_OK) {
    error_ = lua_tostring(co_, -1) ? lua_tostring(co_, -1) : "load error";
    status_ = Status::Error;
    return false;
  }
  lua_sethook(co_, reinterpret_cast<lua_Hook>(&LuaVm::hookFn), LUA_MASKCOUNT, preempt_);
  status_ = Status::Preempted;  // runnable
  return true;
}

void LuaVm::setPreemptInterval(int instructions) {
  preempt_ = instructions < 100 ? 100 : instructions;
  if (co_) lua_sethook(co_, reinterpret_cast<lua_Hook>(&LuaVm::hookFn), LUA_MASKCOUNT, preempt_);
}

Status LuaVm::resume(const char* eventName) {
  if (!co_ || (status_ != Status::Preempted && status_ != Status::Waiting)) return status_;

  int nargs = 0;
  if (status_ == Status::Waiting) {
    if (eventName) lua_pushstring(co_, eventName);
    else lua_pushnil(co_);
    nargs = 1;
  }  // first run and hook yields: no arguments

  int nres = 0;
  const int rc = lua_resume(co_, L_, nargs, &nres);
  if (rc == LUA_YIELD) {
    if (nres == 0) {
      status_ = Status::Preempted;  // hook yield
    } else {
      // Wait request: first yielded value is the timeout in ms (<0 = no timeout).
      waitMs_ = lua_isinteger(co_, -nres) ? static_cast<int32_t>(lua_tointeger(co_, -nres)) : -1;
      // Optional second value: false = timer only (events must not wake it).
      waitEvents_ = !(nres >= 2 && lua_isboolean(co_, -nres + 1) && !lua_toboolean(co_, -nres + 1));
      lua_pop(co_, nres);
      status_ = Status::Waiting;
    }
  } else if (rc == LUA_OK) {
    lua_pop(co_, nres);
    status_ = Status::Finished;
  } else {
    const char* msg = lua_tostring(co_, -1);
    error_ = msg ? msg : "(non-string error)";
    luaL_traceback(L_, co_, nullptr, 0);  // traceback of the dead coroutine onto L_
    if (const char* tb = lua_tostring(L_, -1)) {
      error_ += "\n";
      error_ += tb;
    }
    lua_pop(L_, 1);
    status_ = Status::Error;
  }
  return status_;
}

void LuaVm::gc() {
  if (L_) lua_gc(L_, LUA_GCCOLLECT);
}

}  // namespace crosslua
