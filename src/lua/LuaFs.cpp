// fs.* and the module loader behind require(). Sandboxed to app:/data:/lib: scopes.
#include <cstdio>
#include <cstring>

#include "LuaInternal.h"
#include "LuaVm.h"

namespace crosslua {

namespace {
bool validRel(const char* rel, const char** err) {
  const size_t n = strlen(rel);
  if (n == 0) {
    *err = "empty path";
    return false;
  }
  if (n > MAX_PATH_LEN) {
    *err = "path too long";
    return false;
  }
  if (rel[0] == '/') {
    *err = "absolute paths are not allowed";
    return false;
  }
  const char* part = rel;
  for (const char* p = rel;; p++) {
    const unsigned char c = static_cast<unsigned char>(*p);
    if (c == '\\' || c == ':' || (c != 0 && c < 0x20)) {
      *err = "illegal character in path";
      return false;
    }
    if (c == '/' || c == 0) {
      const size_t len = static_cast<size_t>(p - part);
      if (len == 0) {
        *err = "empty path component";
        return false;
      }
      if ((len == 1 && part[0] == '.') || (len == 2 && part[0] == '.' && part[1] == '.')) {
        *err = "'.' and '..' are not allowed";
        return false;
      }
      if (c == 0) break;
      part = p + 1;
    }
  }
  return true;
}
}  // namespace

bool resolveIn(Backend& b, Scope scope, const char* rel, char* out, size_t cap, const char** err) {
  const char* root = scope == Scope::App ? b.appDir() : scope == Scope::Data ? b.dataDir() : b.libDir();
  if (rel[0] == '\0') {  // the scope root itself ("data:"): listable, never writable/removable as a file
    const int n = snprintf(out, cap, "%s", root);
    if (n < 0 || static_cast<size_t>(n) >= cap) {
      *err = "path too long";
      return false;
    }
    return true;
  }
  if (!validRel(rel, err)) return false;
  const int n = snprintf(out, cap, "%s/%s", root, rel);
  if (n < 0 || static_cast<size_t>(n) >= cap) {
    *err = "path too long";
    return false;
  }
  return true;
}

bool resolvePath(Backend& b, const char* spec, char* out, size_t cap, Scope* scope, const char** err) {
  Scope sc = Scope::App;
  if (!strncmp(spec, "data:", 5)) {
    sc = Scope::Data;
    spec += 5;
  } else if (!strncmp(spec, "app:", 4)) {
    spec += 4;
  } else if (!strncmp(spec, "lib:", 4)) {
    sc = Scope::Lib;
    spec += 4;
  }
  if (scope) *scope = sc;
  return resolveIn(b, sc, spec, out, cap, err);
}

namespace {

// Returns false (and pushes nil,msg) so callers can `return pushFail(...)`.
int pushFail(lua_State* L, const char* msg) {
  lua_pushnil(L);
  lua_pushstring(L, msg);
  return 2;
}

// Resolve arg `i`; on failure pushes nil,msg and returns false.
bool pathArg(lua_State* L, int i, bool needWrite, char* out, size_t cap, Scope* sc) {
  const char* spec = luaL_checkstring(L, i);
  const char* err = nullptr;
  if (!resolvePath(be(L), spec, out, cap, sc, &err)) {
    pushFail(L, err);
    return false;
  }
  if (needWrite && *sc != Scope::Data) {
    pushFail(L, "read-only location (write to 'data:...')");
    return false;
  }
  return true;
}

void parentOf(char* path) {
  char* slash = strrchr(path, '/');
  if (slash && slash != path) *slash = '\0';
}

// Create the parent directory of `path` (recursive) when missing.
bool ensureParent(Backend& b, const char* path) {
  char parent[MAX_PATH_LEN + 80];
  snprintf(parent, sizeof(parent), "%s", path);
  parentOf(parent);
  if (b.fsSize(parent) == -2) return true;
  return b.fsMkdir(parent);
}

int fs_read(lua_State* L) {
  char path[MAX_PATH_LEN + 80];
  Scope sc;
  if (!pathArg(L, 1, false, path, sizeof(path), &sc)) return 2;
  const int64_t size = be(L).fsSize(path);
  if (size == -1) return pushFail(L, "no such file");
  if (size == -2) return pushFail(L, "is a directory");
  if (static_cast<size_t>(size) > MAX_READ_BYTES) return pushFail(L, "file too large");
  if (size == 0) {
    lua_pushliteral(L, "");
    return 1;
  }
  // Read straight into a Lua-managed buffer: counted against the app's memory budget, and
  // reclaimed by the GC if an allocation error unwinds us. (No C++ objects live here.)
  void* buf = lua_newuserdatauv(L, static_cast<size_t>(size), 0);
  if (!be(L).fsReadInto(path, buf, static_cast<size_t>(size))) {
    lua_pop(L, 1);
    return pushFail(L, "read error");
  }
  lua_pushlstring(L, static_cast<const char*>(buf), static_cast<size_t>(size));
  lua_remove(L, -2);
  return 1;
}

int writeImpl(lua_State* L, bool append) {
  char path[MAX_PATH_LEN + 80];
  Scope sc;
  if (!pathArg(L, 1, true, path, sizeof(path), &sc)) return 2;
  size_t len = 0;
  const char* data = luaL_checklstring(L, 2, &len);
  if (len > MAX_WRITE_BYTES) return pushFail(L, "data too large");
  if (be(L).fsSize(path) == -2) return pushFail(L, "is a directory");
  if (!ensureParent(be(L), path)) return pushFail(L, "cannot create directory");
  if (!be(L).fsWrite(path, data, len, append)) return pushFail(L, "write error");
  lua_pushboolean(L, 1);
  return 1;
}
int fs_write(lua_State* L) { return writeImpl(L, false); }
int fs_append(lua_State* L) { return writeImpl(L, true); }

int fs_exists(lua_State* L) {
  char path[MAX_PATH_LEN + 80];
  Scope sc;
  const char* spec = luaL_checkstring(L, 1);
  const char* err;
  if (!resolvePath(be(L), spec, path, sizeof(path), &sc, &err)) {
    lua_pushboolean(L, 0);
    return 1;
  }
  lua_pushboolean(L, be(L).fsSize(path) != -1);
  return 1;
}
// fs.size(path) -> bytes | nil,err   (directories: nil,"is a directory")
int fs_size(lua_State* L) {
  char path[MAX_PATH_LEN + 80];
  Scope sc;
  if (!pathArg(L, 1, false, path, sizeof(path), &sc)) return 2;
  const int64_t n = be(L).fsSize(path);
  if (n == -1) return pushFail(L, "no such file");
  if (n == -2) return pushFail(L, "is a directory");
  lua_pushinteger(L, static_cast<lua_Integer>(n));
  return 1;
}
int fs_mkdir(lua_State* L) {
  char path[MAX_PATH_LEN + 80];
  Scope sc;
  if (!pathArg(L, 1, true, path, sizeof(path), &sc)) return 2;
  if (!be(L).fsMkdir(path)) return pushFail(L, "cannot create directory");
  lua_pushboolean(L, 1);
  return 1;
}
int fs_remove(lua_State* L) {
  char path[MAX_PATH_LEN + 80];
  Scope sc;
  if (!pathArg(L, 1, true, path, sizeof(path), &sc)) return 2;
  if (!strcmp(path, be(L).dataDir())) return pushFail(L, "cannot remove the data root");
  if (be(L).fsSize(path) == -1) return pushFail(L, "no such file");
  if (!be(L).fsRemove(path)) return pushFail(L, "cannot remove (directories must be empty)");
  lua_pushboolean(L, 1);
  return 1;
}
// fs.list(path) -> { "a.txt", "sub/", ... } (directories get a trailing slash), sorted
int fs_list(lua_State* L) {
  char path[MAX_PATH_LEN + 80];
  Scope sc;
  if (!pathArg(L, 1, false, path, sizeof(path), &sc)) return 2;
  if (be(L).fsSize(path) != -2) return pushFail(L, "not a directory");
  if (!be(L).fsListBegin(path)) return pushFail(L, "cannot open directory");
  lua_newtable(L);  // a lua error below (OOM) leaves the backend iterator open; the next Begin/close resets it
  int n = 0;
  char name[130];
  bool isDir = false;
  while (be(L).fsListNext(name, sizeof(name) - 1, &isDir)) {
    if (n >= 512) break;  // sanity cap
    if (isDir) strcat(name, "/");
    lua_pushstring(L, name);
    lua_rawseti(L, -2, ++n);
  }
  be(L).fsListEnd();
  // Sort for stable ordering across FAT implementations: table.sort via Lua.
  lua_getglobal(L, "table");
  lua_getfield(L, -1, "sort");
  lua_remove(L, -2);
  lua_pushvalue(L, -2);
  lua_call(L, 1, 0);
  return 1;
}

// ---- require support ---------------------------------------------------------
// __find(name) -> compiled chunk, chunkname | nil, errmsg. Search: app:, then lib:; <rel>.lua then <rel>/init.lua.
int mod_find(lua_State* L) {
  const char* name = luaL_checkstring(L, 1);
  const size_t nl = strlen(name);
  if (nl == 0 || nl > 100) return pushFail(L, "bad module name");
  char rel[128];
  for (size_t i = 0; i <= nl; i++) {
    const char c = name[i];
    const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' ||
                    c == '.' || c == '\0';
    if (!ok) return pushFail(L, "bad module name (allowed: letters, digits, '_' and '.')");
    rel[i] = (c == '.') ? '/' : c;
  }
  struct Try {
    Scope sc;
    const char* scName;
    const char* suffix;
  };
  static const Try tries[] = {{Scope::App, "app", ".lua"},      {Scope::App, "app", "/init.lua"},
                              {Scope::Lib, "lib", ".lua"},      {Scope::Lib, "lib", "/init.lua"}};
  char relFile[160];
  char path[MAX_PATH_LEN + 80];
  char tried[640];  // the "tried" list for the error message (a plain buffer: no luaL_Buffer while we push values)
  size_t triedLen = 0;
  tried[0] = '\0';
  for (const Try& t : tries) {
    snprintf(relFile, sizeof(relFile), "%s%s", rel, t.suffix);
    const char* err;
    if (!resolveIn(be(L), t.sc, relFile, path, sizeof(path), &err)) continue;
    const int64_t size = be(L).fsSize(path);
    if (size >= 0 && static_cast<size_t>(size) <= MAX_MODULE_BYTES) {
      void* buf = lua_newuserdatauv(L, static_cast<size_t>(size) + 1, 0);
      if (!be(L).fsReadInto(path, buf, static_cast<size_t>(size))) return pushFail(L, "module read error");
      char chunk[MAX_PATH_LEN + 16];
      snprintf(chunk, sizeof(chunk), "@%s:%s", t.scName, relFile);
      const int rc = luaL_loadbufferx(L, static_cast<const char*>(buf), static_cast<size_t>(size), chunk, "t");
      if (rc != LUA_OK) {
        // error message is on top; return nil,msg
        lua_pushnil(L);
        lua_insert(L, -2);
        return 2;
      }
      lua_pushstring(L, chunk + 1);
      return 2;
    }
    if (triedLen < sizeof(tried) - 1) {
      const int w = snprintf(tried + triedLen, sizeof(tried) - triedLen, "\n\tno file '%s:%s'", t.scName, relFile);
      if (w > 0) triedLen += static_cast<size_t>(w);
      if (triedLen >= sizeof(tried)) triedLen = sizeof(tried) - 1;
    }
  }
  lua_pushnil(L);
  lua_pushfstring(L, "module '%s' not found:%s", name, tried);
  return 2;
}

const char* const REQUIRE_PRELUDE = R"LUA(
local find = ...
local loaded, loading = {}, {}
local function require(name)
  if type(name) ~= "string" then error("module name must be a string", 2) end
  local m = loaded[name]
  if m ~= nil then return m end
  if loading[name] then error("circular require of '" .. name .. "'", 2) end
  local f, where = find(name)
  if not f then error(where, 2) end
  loading[name] = true
  local ok, r = pcall(f, name, where)
  loading[name] = nil
  if not ok then error(r, 0) end
  if r == nil then r = true end
  loaded[name] = r
  return r
end
return require
)LUA";

}  // namespace

void registerFs(lua_State* L, Ctx* c) {
  static const luaL_Reg fs[] = {{"read", fs_read},     {"write", fs_write}, {"append", fs_append},
                                {"exists", fs_exists}, {"size", fs_size},   {"mkdir", fs_mkdir},
                                {"remove", fs_remove}, {"list", fs_list},   {nullptr, nullptr}};
  regTable(L, c, "fs", fs);
}

void registerRequire(lua_State* L, Ctx* c) {
  // Loader written in Lua so a module's top-level code may yield (input.wait etc.).
  if (luaL_loadbufferx(L, REQUIRE_PRELUDE, strlen(REQUIRE_PRELUDE), "=require", "t") != LUA_OK) {
    lua_pop(L, 1);
    return;
  }
  lua_pushlightuserdata(L, c);
  lua_pushcclosure(L, mod_find, 1);
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    lua_pop(L, 1);
    return;
  }
  lua_setglobal(L, "require");
}

}  // namespace crosslua
