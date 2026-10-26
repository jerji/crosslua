// fs.* and the module loader behind require(). Sandboxed to app:/data:/lib: scopes.
#include <algorithm>
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
  if (scope == Scope::Sd) {
    // The user's SD card outside the app sandbox: read-only (callers enforce), permission-gated, and never anything hidden
    // (.crosspoint = settings/credentials, .crosslua = other apps' data, any dot-name).
    if (!b.libraryAllowed()) {
      *err = "library access not permitted: add \"library\" to \"permissions\" in manifest.json";
      return false;
    }
    if (rel[0] == '\0') {
      snprintf(out, cap, "/");
      return true;
    }
    if (!validRel(rel, err)) return false;
    for (const char* p = rel;;) {
      if (*p == '.') {
        *err = "hidden files and folders are not accessible";
        return false;
      }
      const char* slash = strchr(p, '/');
      if (!slash) break;
      p = slash + 1;
    }
    const int n = snprintf(out, cap, "/%s", rel);
    if (n < 0 || static_cast<size_t>(n) >= cap) {
      *err = "path too long";
      return false;
    }
    return true;
  }
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
  } else if (!strncmp(spec, "sd:", 3)) {
    sc = Scope::Sd;
    spec += 3;
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

// fs.read(path [, offset [, len]]) -> string | nil, err
// Without offset/len: the whole file (max 128 KB). With them: that byte range (len max 128 KB; a range that runs past
// the end is clipped, an offset past the end is an error). Use ranges for files too big to hold in memory.
int fs_read(lua_State* L) {
  char path[MAX_PATH_LEN + 80];
  Scope sc;
  if (!pathArg(L, 1, false, path, sizeof(path), &sc)) return 2;
  const bool ranged = !lua_isnoneornil(L, 2) || !lua_isnoneornil(L, 3);
  const lua_Number offN = lua_isnoneornil(L, 2) ? 0 : luaL_checknumber(L, 2);
  const lua_Number lenN = lua_isnoneornil(L, 3) ? -1 : luaL_checknumber(L, 3);
  if (offN < 0 || (lenN < 0 && !lua_isnoneornil(L, 3))) return pushFail(L, "negative offset/length");
  const int64_t size = be(L).fsSize(path);
  if (size == -1) return pushFail(L, "no such file");
  if (size == -2) return pushFail(L, "is a directory");
  const size_t off = static_cast<size_t>(offN);
  if (off > static_cast<size_t>(size)) return pushFail(L, "offset beyond end of file");
  size_t want = static_cast<size_t>(size) - off;
  if (lenN >= 0 && static_cast<size_t>(lenN) < want) want = static_cast<size_t>(lenN);
  if (want > MAX_READ_BYTES) return pushFail(L, ranged ? "length too large" : "file too large (read it in ranges: fs.read(path, offset, len))");
  if (want == 0) {
    lua_pushliteral(L, "");
    return 1;
  }
  // Read straight into a Lua-managed buffer: counted against the app's memory budget, and
  // reclaimed by the GC if an allocation error unwinds us. (No C++ objects live here.)
  void* buf = lua_newuserdatauv(L, want, 0);
  if (!be(L).fsReadInto(path, buf, want, off)) {
    lua_pop(L, 1);
    return pushFail(L, "read error");
  }
  lua_pushlstring(L, static_cast<const char*>(buf), want);
  lua_remove(L, -2);
  return 1;
}

// fs.write_at(path, offset, data) -> true | nil, err   (data: scope only; the file must exist)
// In-place and NOT atomic: for small fixed-size records (a power cut mid-write can tear that record, never the file).
int fs_write_at(lua_State* L) {
  char path[MAX_PATH_LEN + 80];
  Scope sc;
  if (!pathArg(L, 1, true, path, sizeof(path), &sc)) return 2;
  const lua_Number offN = luaL_checknumber(L, 2);
  size_t len = 0;
  const char* data = luaL_checklstring(L, 3, &len);
  if (offN < 0) return pushFail(L, "negative offset");
  if (len > MAX_WRITE_AT_BYTES) return pushFail(L, "data too large for write_at");
  const int64_t size = be(L).fsSize(path);
  if (size == -1) return pushFail(L, "no such file (create it with fs.write first)");
  if (size == -2) return pushFail(L, "is a directory");
  if (static_cast<size_t>(offN) > static_cast<size_t>(size)) return pushFail(L, "offset beyond end of file");
  if (!be(L).fsWriteAt(path, static_cast<size_t>(offN), data, len)) return pushFail(L, "write error");
  lua_pushboolean(L, 1);
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
    if (sc == Scope::Sd && name[0] == '.') continue;  // hidden entries do not exist as far as an app can tell
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
// Feeds the Lua parser from the SD card, MOD_PIECE bytes at a time (the piece buffer lives in the same userdata).
constexpr size_t MOD_PIECE = 1024;
struct ModReader {
  Backend* be;
  const char* path;
  size_t size, off;
  bool ioError;
  char piece[MOD_PIECE];
};
const char* modReaderFn(lua_State*, void* ud, size_t* sz) {
  ModReader* r = static_cast<ModReader*>(ud);
  const size_t n = std::min(MOD_PIECE, r->size - r->off);
  *sz = 0;
  if (n == 0) return nullptr;
  if (!r->be->fsReadInto(r->path, r->piece, n, r->off)) {
    r->ioError = true;
    return nullptr;
  }
  r->off += n;
  *sz = n;
  return r->piece;
}

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
      // Stream the file through the parser in small pieces: the source text never sits in the Lua heap next to the
      // compiled function, which is what used to push a 18 KB module past a ~80 KB budget.
      auto* rd = static_cast<ModReader*>(lua_newuserdatauv(L, sizeof(ModReader), 0));
      rd->be = &be(L);
      rd->path = path;
      rd->size = static_cast<size_t>(size);
      rd->off = 0;
      rd->ioError = false;
      char chunk[MAX_PATH_LEN + 16];
      snprintf(chunk, sizeof(chunk), "@%s:%s", t.scName, relFile);
      const int rc = ctx(L)->vm->loadReader(L, modReaderFn, rd, chunk);
      if (rd->ioError) return pushFail(L, "module read error");
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

// ---- load(text [, chunkname [, mode [, env]]]) -> function | nil, err -------------------------------------------------
// Text chunks ONLY: precompiled bytecode is a classic VM-escape/crash vector, so it is always refused (whatever `mode`
// says). No reader functions (they could yield/allocate mid-parse), no files (fs scopes stay the only way to read).
// `env`, when given (even nil), becomes the chunk's _ENV exactly like standard Lua. Failure is a plain nil,err (a
// parse error, a chunk over 64 KB, or the VM heap budget running out while compiling) and never aborts the app.
static constexpr size_t MAX_LOAD_BYTES = 64 * 1024;
static int lua_load_text(lua_State* L) {
  if (lua_type(L, 1) != LUA_TSTRING) return pushFail(L, "load: text chunks only (a string is required)");
  size_t len = 0;
  const char* src = lua_tolstring(L, 1, &len);
  const char* name = luaL_optstring(L, 2, nullptr);
  const char* mode = luaL_optstring(L, 3, "t");
  if (!strchr(mode, 't')) return pushFail(L, "attempt to load a text chunk (mode is not 't')");
  if (len > MAX_LOAD_BYTES) return pushFail(L, "chunk too large (max 64 KB)");
  if (len > 0 && src[0] == LUA_SIGNATURE[0]) return pushFail(L, "precompiled chunks are not allowed");
  char chunk[64];
  if (name) snprintf(chunk, sizeof(chunk), "%s", name);
  else snprintf(chunk, sizeof(chunk), "=(load)");
  if (luaL_loadbufferx(L, src, len, chunk, "t") != LUA_OK) {  // [.., err]
    lua_pushnil(L);
    lua_insert(L, -2);
    return 2;
  }
  if (!lua_isnone(L, 4)) {  // env argument present: first upvalue of a main chunk is _ENV
    lua_pushvalue(L, 4);
    if (!lua_setupvalue(L, -2, 1)) lua_pop(L, 1);
  }
  return 1;
}

// fs.rename(from, to) -> true | nil, err. Both paths must be in data:. No overwrite: `to` must not exist.
int fs_rename(lua_State* L) {
  char from[MAX_PATH_LEN + 80], to[MAX_PATH_LEN + 80];
  Scope sf, st;
  if (!pathArg(L, 1, true, from, sizeof(from), &sf)) return 2;
  if (!pathArg(L, 2, true, to, sizeof(to), &st)) return 2;
  const int64_t size = be(L).fsSize(from);
  if (size == -1) return pushFail(L, "no such file");
  if (size == -2) return pushFail(L, "is a directory");
  if (be(L).fsSize(to) != -1) return pushFail(L, "target already exists");
  char err[96] = {0};
  if (!be(L).fsRename(from, to, err, sizeof(err))) return pushFail(L, err[0] ? err : "rename failed");
  lua_pushboolean(L, 1);
  return 1;
}

void registerFs(lua_State* L, Ctx* c) {
  static const luaL_Reg fs[] = {{"read", fs_read},     {"write", fs_write}, {"write_at", fs_write_at}, {"append", fs_append},
                                {"exists", fs_exists}, {"size", fs_size},   {"mkdir", fs_mkdir},
                                {"remove", fs_remove}, {"list", fs_list},   {"rename", fs_rename}, {nullptr, nullptr}};
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
  lua_pushcfunction(L, lua_load_text);
  lua_setglobal(L, "load");
}

}  // namespace crosslua
