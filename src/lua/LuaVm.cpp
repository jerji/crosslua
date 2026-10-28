#include "LuaVm.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

extern "C" {
#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"
}

namespace crosslua {

char LuaVm::panicMessage[128] = {0};

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
  if (nsize > old) {
    if (st->used + (nsize - old) > st->budget) return nullptr;  // Lua raises "not enough memory"
    // Real device RAM: the new block must fit while the old one still exists, and leave the floor free.
    if (st->guardFn && st->guardFn(st->guardUd) < nsize + st->floor) return nullptr;
  }
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
  static const luaL_Reg libs[] = {{LUA_GNAME, luaopen_base},
                                  {LUA_TABLIBNAME, luaopen_table},
                                  {LUA_STRLIBNAME, luaopen_string},
                                  {LUA_MATHLIBNAME, luaopen_math},
                                  {nullptr, nullptr}};  // coroutine and utf8 are lazy (see installLazy in LuaApi.cpp)
  for (const luaL_Reg* l = libs; l->func; l++) {
    luaL_requiref(L, l->name, l->func, 1);
    lua_pop(L, 1);
  }
  // Base functions that read the filesystem via fopen(). (`load` is re-added by registerRequire as a text-only
  // version.)
  static const char* const removed[] = {"dofile", "loadfile", "loadstring", nullptr};
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
    // Unprotected error (should not happen: everything runs inside a coroutine). Returning aborts the
    // process; leave the message where a debugger/serial log can find it.
    const char* m = lua_tostring(L, -1);
    snprintf(panicMessage, sizeof(panicMessage), "%s", m ? m : "(non-string)");
#ifndef ARDUINO
    fprintf(stderr, "LUA PANIC: %s\n", panicMessage);
#endif
    return 0;
  });
  // Lua's default (collect when the heap has doubled) is far too lazy for an ~88 KB budget: garbage would eat a
  // third of it. Start a cycle at 130% of the live size instead; the collector runs in small slices inside normal
  // allocation, so this costs a little CPU, not pauses.
  lua_gc(L_, LUA_GCINC, 130, 200, 13);
  openSandbox(L_);
  return true;
}

void LuaVm::close() {
  if (L_) lua_close(L_);  // frees every Lua object -> usedBytes()==0
  L_ = nullptr;
  co_ = nullptr;
  status_ = Status::Idle;
}

namespace {
struct DumpBuf {
  char* p = nullptr;
  size_t n = 0, cap = 0;
  bool failed = false;
};
int dumpWriter(lua_State*, const void* data, size_t sz, void* ud) {
  DumpBuf* b = static_cast<DumpBuf*>(ud);
  if (b->failed) return 1;
  if (b->n + sz > b->cap) {
    size_t nc = b->cap ? b->cap * 2 : 4096;
    while (nc < b->n + sz) nc *= 2;
    char* np = static_cast<char*>(realloc(b->p, nc));
    if (!np) {
      b->failed = true;
      return 1;
    }
    b->p = np;
    b->cap = nc;
  }
  memcpy(b->p + b->n, data, sz);
  b->n += sz;
  return 0;
}
}  // namespace

// Compile, then (optionally) round-trip through lua_dump(strip) to drop line tables, local names and upvalue names.
// No Lua error can be raised between the malloc and the free below (lua_dump never allocates through Lua and
// lua_load is protected), so the C buffer can't leak. It is a transient of one chunk's size.
int LuaVm::loadText(lua_State* L, const char* buf, size_t n, const char* chunkName) {
  return finishLoad(L, luaL_loadbufferx(L, buf, n, chunkName, "t"), chunkName);
}

int LuaVm::loadReader(lua_State* L, const char* (*reader)(lua_State*, void*, size_t*), void* ud,
                      const char* chunkName) {
  return finishLoad(L, lua_load(L, reader, ud, chunkName, "t"), chunkName);  // "t": bytecode is refused by the parser
}

// Tail shared by both loaders: `rc` is the compile status, the function (or the error message) is on top of L.
int LuaVm::finishLoad(lua_State* L, int rc, const char* chunkName) {
  if (rc != LUA_OK || !stripDebug_) return rc;
  DumpBuf d;
  if (lua_dump(L, dumpWriter, &d, 1) != 0 || d.failed) {
    free(d.p);
    return LUA_OK;  // couldn't strip: keep the unstripped function that is already on the stack
  }
  // Peak-memory matters here: the full function (debug info is ~1/3 of it), the stripped copy and the caller's source
  // buffer used to coexist. Drop the original and collect BEFORE loading the stripped copy (the dump lives in a
  // malloc'd buffer, outside the Lua budget), so a big module needs source + max(full, stripped), not source + both.
  lua_pop(L, 1);  // [orig] -> []
  lua_gc(L, LUA_GCCOLLECT);
  rc = luaL_loadbufferx(L, d.p, d.n, chunkName, "b");  // our own dump, never user bytecode
  free(d.p);
  return rc;  // [stripped] or [err]
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
  if (loadText(co_, src, len, chunkName) != LUA_OK) {
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
    if (eventName)
      lua_pushstring(co_, eventName);
    else
      lua_pushnil(co_);
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
    // Traceback of the dead coroutine, built inside a PROTECTED call on the main state: when the script
    // died of "not enough memory", building the traceback can fail too, and an unprotected failure here
    // would reach the panic handler and abort the whole process.
    lua_pushcfunction(L_, [](lua_State* L) -> int {
      luaL_traceback(L, static_cast<lua_State*>(lua_touserdata(L, 1)), nullptr, 0);
      return 1;
    });
    lua_pushlightuserdata(L_, co_);
    if (lua_pcall(L_, 1, 1, 0) == LUA_OK) {
      if (const char* tb = lua_tostring(L_, -1)) {
        error_ += "\n";
        error_ += tb;
      }
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
