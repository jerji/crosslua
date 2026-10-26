// json.encode / json.decode. Pure C-style code: no C++ objects live across a possible lua_error.
// Numbers: integral values that fit int32 decode to Lua integers, everything else to (32-bit) floats.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "LuaInternal.h"

namespace crosslua {
namespace {

constexpr int MAX_DEPTH = 24;

// ------------------------------- decode --------------------------------------
struct Parser {
  lua_State* L;
  const char* p;
  const char* end;
  const char* err;
  int depth;
};

void skipWs(Parser& ps) {
  while (ps.p < ps.end && (*ps.p == ' ' || *ps.p == '\t' || *ps.p == '\n' || *ps.p == '\r')) ps.p++;
}
bool fail(Parser& ps, const char* msg) {
  if (!ps.err) ps.err = msg;
  return false;
}

int hexVal(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}
bool read4(Parser& ps, unsigned* out) {
  if (ps.end - ps.p < 4) return false;
  unsigned v = 0;
  for (int i = 0; i < 4; i++) {
    const int h = hexVal(ps.p[i]);
    if (h < 0) return false;
    v = (v << 4) | static_cast<unsigned>(h);
  }
  ps.p += 4;
  *out = v;
  return true;
}
int putUtf8(unsigned cp, char* o) {
  if (cp < 0x80) { o[0] = static_cast<char>(cp); return 1; }
  if (cp < 0x800) { o[0] = static_cast<char>(0xC0 | (cp >> 6)); o[1] = static_cast<char>(0x80 | (cp & 0x3F)); return 2; }
  if (cp < 0x10000) {
    o[0] = static_cast<char>(0xE0 | (cp >> 12)); o[1] = static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
    o[2] = static_cast<char>(0x80 | (cp & 0x3F)); return 3;
  }
  o[0] = static_cast<char>(0xF0 | (cp >> 18)); o[1] = static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
  o[2] = static_cast<char>(0x80 | ((cp >> 6) & 0x3F)); o[3] = static_cast<char>(0x80 | (cp & 0x3F)); return 4;
}

// Parses a string starting after the opening quote; pushes it. Unescaped runs are copied in bulk.
bool parseString(Parser& ps) {
  // Strings are assembled in a Lua-managed userdata-free way: first measure, then build in a small stack buffer
  // chunk-wise using luaL_Buffer is unsafe with nested stack use, so decode into a malloc-free two-pass:
  // pass 1 computes the exact decoded length; pass 2 writes into a lua_newuserdatauv block.
  const char* start = ps.p;
  size_t outLen = 0;
  for (const char* q = ps.p;; q++) {
    if (q >= ps.end) return fail(ps, "unterminated string");
    const unsigned char c = static_cast<unsigned char>(*q);
    if (c == '"') break;
    if (c < 0x20) return fail(ps, "control character in string");
    if (c == '\\') {
      q++;
      if (q >= ps.end) return fail(ps, "unterminated string");
      outLen += (*q == 'u') ? 4 : 1;  // upper bound for \uXXXX (<= 3 bytes, surrogate pair 4 for 12 chars)
      if (*q == 'u') q += 4;
    } else {
      outLen++;
    }
  }
  char* out = static_cast<char*>(lua_newuserdatauv(ps.L, outLen + 1, 0));
  size_t n = 0;
  const char* q = start;
  while (*q != '"') {
    if (*q != '\\') {
      out[n++] = *q++;
      continue;
    }
    q++;
    switch (*q) {
      case '"': out[n++] = '"'; q++; break;
      case '\\': out[n++] = '\\'; q++; break;
      case '/': out[n++] = '/'; q++; break;
      case 'b': out[n++] = '\b'; q++; break;
      case 'f': out[n++] = '\f'; q++; break;
      case 'n': out[n++] = '\n'; q++; break;
      case 'r': out[n++] = '\r'; q++; break;
      case 't': out[n++] = '\t'; q++; break;
      case 'u': {
        ps.p = q + 1;
        unsigned cp;
        if (!read4(ps, &cp)) { lua_pop(ps.L, 1); return fail(ps, "bad \\u escape"); }
        if (cp >= 0xD800 && cp < 0xDC00) {  // high surrogate: need a low one
          unsigned lo;
          if (ps.end - ps.p >= 6 && ps.p[0] == '\\' && ps.p[1] == 'u') {
            ps.p += 2;
            if (!read4(ps, &lo) || lo < 0xDC00 || lo > 0xDFFF) { lua_pop(ps.L, 1); return fail(ps, "bad surrogate pair"); }
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
          } else {
            lua_pop(ps.L, 1);
            return fail(ps, "lone surrogate");
          }
        } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
          lua_pop(ps.L, 1);
          return fail(ps, "lone surrogate");
        }
        n += static_cast<size_t>(putUtf8(cp, out + n));
        q = ps.p;
        break;
      }
      default: lua_pop(ps.L, 1); return fail(ps, "bad escape");
    }
  }
  ps.p = q + 1;
  lua_pushlstring(ps.L, out, n);
  lua_remove(ps.L, -2);  // drop the scratch userdata
  return true;
}

bool parseValue(Parser& ps);

bool parseNumber(Parser& ps) {
  const char* s = ps.p;
  const char* q = s;
  if (q < ps.end && *q == '-') q++;
  if (q >= ps.end || *q < '0' || *q > '9') return fail(ps, "bad number");
  if (*q == '0' && q + 1 < ps.end && q[1] >= '0' && q[1] <= '9') return fail(ps, "leading zero in number");
  bool isInt = true;
  while (q < ps.end && *q >= '0' && *q <= '9') q++;
  if (q < ps.end && *q == '.') {
    isInt = false;
    q++;
    if (q >= ps.end || *q < '0' || *q > '9') return fail(ps, "bad number");
    while (q < ps.end && *q >= '0' && *q <= '9') q++;
  }
  if (q < ps.end && (*q == 'e' || *q == 'E')) {
    isInt = false;
    q++;
    if (q < ps.end && (*q == '+' || *q == '-')) q++;
    if (q >= ps.end || *q < '0' || *q > '9') return fail(ps, "bad number");
    while (q < ps.end && *q >= '0' && *q <= '9') q++;
  }
  char tmp[40];
  const size_t len = static_cast<size_t>(q - s);
  if (len >= sizeof(tmp)) return fail(ps, "number too long");
  memcpy(tmp, s, len);
  tmp[len] = '\0';
  ps.p = q;
  if (isInt) {
    const long long v = strtoll(tmp, nullptr, 10);
    if (v >= INT32_MIN && v <= INT32_MAX) {
      lua_pushinteger(ps.L, static_cast<lua_Integer>(v));
      return true;
    }
  }
  lua_pushnumber(ps.L, static_cast<lua_Number>(strtod(tmp, nullptr)));
  return true;
}

bool parseValue(Parser& ps) {
  skipWs(ps);
  if (ps.p >= ps.end) return fail(ps, "unexpected end of input");
  if (!lua_checkstack(ps.L, 8)) return fail(ps, "too deeply nested");
  const char c = *ps.p;
  if (c == '"') {
    ps.p++;
    return parseString(ps);
  }
  if (c == '{' || c == '[') {
    if (++ps.depth > MAX_DEPTH) return fail(ps, "too deeply nested");
    ps.p++;
    lua_newtable(ps.L);
    const char close = c == '{' ? '}' : ']';
    skipWs(ps);
    if (ps.p < ps.end && *ps.p == close) {
      ps.p++;
      ps.depth--;
      return true;
    }
    lua_Integer idx = 1;
    for (;;) {
      skipWs(ps);
      if (c == '{') {
        if (ps.p >= ps.end || *ps.p != '"') return fail(ps, "expected string key");
        ps.p++;
        if (!parseString(ps)) return false;
        skipWs(ps);
        if (ps.p >= ps.end || *ps.p != ':') return fail(ps, "expected ':'");
        ps.p++;
        if (!parseValue(ps)) return false;
        lua_rawset(ps.L, -3);
      } else {
        if (!parseValue(ps)) return false;
        lua_rawseti(ps.L, -2, idx++);
      }
      skipWs(ps);
      if (ps.p >= ps.end) return fail(ps, "unexpected end of input");
      if (*ps.p == ',') {
        ps.p++;
        continue;
      }
      if (*ps.p == close) {
        ps.p++;
        ps.depth--;
        return true;
      }
      return fail(ps, c == '{' ? "expected ',' or '}'" : "expected ',' or ']'");
    }
  }
  if (c == '-' || (c >= '0' && c <= '9')) return parseNumber(ps);
  if (ps.end - ps.p >= 4 && !memcmp(ps.p, "true", 4)) { ps.p += 4; lua_pushboolean(ps.L, 1); return true; }
  if (ps.end - ps.p >= 5 && !memcmp(ps.p, "false", 5)) { ps.p += 5; lua_pushboolean(ps.L, 0); return true; }
  if (ps.end - ps.p >= 4 && !memcmp(ps.p, "null", 4)) {
    ps.p += 4;
    lua_getfield(ps.L, LUA_REGISTRYINDEX, "crosslua.json.null");
    return true;
  }
  return fail(ps, "unexpected character");
}

// json.decode(str) -> value | nil, "msg at byte N"
int json_decode(lua_State* L) {
  size_t len;
  const char* s = luaL_checklstring(L, 1, &len);
  Parser ps{L, s, s + len, nullptr, 0};
  const int base = lua_gettop(L);
  if (parseValue(ps)) {
    skipWs(ps);
    if (ps.p != ps.end) fail(ps, "trailing characters");
  }
  if (ps.err) {
    lua_settop(L, base);
    lua_pushnil(L);
    lua_pushfstring(L, "%s at byte %d", ps.err, static_cast<int>(ps.p - s) + 1);
    return 2;
  }
  return 1;
}

// ------------------------------- encode --------------------------------------
// Output is staged in a small C buffer and flushed into a Lua table of chunks only when full, then the
// chunks are joined once at the end. (One Lua string per token costs ~30 bytes of overhead each, which
// would blow a 96 KB app budget on a few KB of JSON.) Everything is Lua-managed, so an out-of-memory
// error mid-way just lets the GC reclaim it.
struct Enc {
  lua_State* L;
  int tbl;
  int n;
  const char* err;
  size_t blen;
  char buf[512];
};

void flushBuf(Enc& e) {
  if (e.blen == 0) return;
  lua_pushlstring(e.L, e.buf, e.blen);
  lua_rawseti(e.L, e.tbl, ++e.n);
  e.blen = 0;
}

void addPiece(Enc& e, const char* s, size_t len) {
  while (len > 0) {
    if (e.blen == sizeof(e.buf)) flushBuf(e);
    size_t room = sizeof(e.buf) - e.blen;
    const size_t c = len < room ? len : room;
    memcpy(e.buf + e.blen, s, c);
    e.blen += c;
    s += c;
    len -= c;
  }
}

void addString(Enc& e, const char* s, size_t len) {
  addPiece(e, "\"", 1);
  size_t runStart = 0;
  for (size_t i = 0; i < len; i++) {
    const unsigned char ch = static_cast<unsigned char>(s[i]);
    char esc[8];
    size_t en = 0;
    switch (ch) {
      case '"': esc[0] = '\\'; esc[1] = '"'; en = 2; break;
      case '\\': esc[0] = '\\'; esc[1] = '\\'; en = 2; break;
      case '\n': esc[0] = '\\'; esc[1] = 'n'; en = 2; break;
      case '\r': esc[0] = '\\'; esc[1] = 'r'; en = 2; break;
      case '\t': esc[0] = '\\'; esc[1] = 't'; en = 2; break;
      case '\b': esc[0] = '\\'; esc[1] = 'b'; en = 2; break;
      case '\f': esc[0] = '\\'; esc[1] = 'f'; en = 2; break;
      default:
        if (ch < 0x20) en = static_cast<size_t>(snprintf(esc, sizeof(esc), "\\u%04x", ch));
    }
    if (en) {
      addPiece(e, s + runStart, i - runStart);
      addPiece(e, esc, en);
      runStart = i + 1;
    }
  }
  addPiece(e, s + runStart, len - runStart);
  addPiece(e, "\"", 1);
}

bool isNull(lua_State* L, int idx) {
  lua_getfield(L, LUA_REGISTRYINDEX, "crosslua.json.null");
  const bool r = lua_rawequal(L, idx < 0 ? idx - 1 : idx, -1);
  lua_pop(L, 1);
  return r;
}

// Array iff keys are exactly 1..n (n>0). Returns n, or 0 for object (including empty).
lua_Integer arrayLength(lua_State* L, int idx) {
  lua_Integer n = 0, count = 0;
  lua_pushnil(L);
  while (lua_next(L, idx < 0 ? idx - 1 : idx)) {
    lua_pop(L, 1);
    if (!lua_isinteger(L, -1)) { lua_pop(L, 1); return 0; }
    const lua_Integer k = lua_tointeger(L, -1);
    if (k < 1) { lua_pop(L, 1); return 0; }
    if (k > n) n = k;
    count++;
  }
  return count == n ? n : 0;
}

bool encodeValue(Enc& e, int idx, int depth) {
  lua_State* L = e.L;
  if (depth > MAX_DEPTH) { e.err = "too deeply nested (or circular)"; return false; }
  luaL_checkstack(L, 8, "json");
  switch (lua_type(L, idx)) {
    case LUA_TNIL: addPiece(e, "null", 4); return true;
    case LUA_TBOOLEAN:
      if (lua_toboolean(L, idx)) addPiece(e, "true", 4); else addPiece(e, "false", 5);
      return true;
    case LUA_TNUMBER: {
      char buf[48];
      int n;
      if (lua_isinteger(L, idx)) {
        n = snprintf(buf, sizeof(buf), "%d", static_cast<int>(lua_tointeger(L, idx)));
      } else {
        const double v = lua_tonumber(L, idx);
        if (std::isnan(v) || std::isinf(v)) { e.err = "cannot encode NaN/Infinity"; return false; }
        n = snprintf(buf, sizeof(buf), "%.7g", v);
      }
      addPiece(e, buf, static_cast<size_t>(n));
      return true;
    }
    case LUA_TSTRING: {
      size_t len;
      const char* s = lua_tolstring(L, idx, &len);
      addString(e, s, len);
      return true;
    }
    case LUA_TLIGHTUSERDATA:
      if (isNull(L, idx)) { addPiece(e, "null", 4); return true; }
      e.err = "cannot encode userdata";
      return false;
    case LUA_TTABLE: {
      const int abs = lua_absindex(L, idx);
      const lua_Integer alen = arrayLength(L, abs);
      if (alen > 0) {
        addPiece(e, "[", 1);
        for (lua_Integer i = 1; i <= alen; i++) {
          if (i > 1) addPiece(e, ",", 1);
          lua_rawgeti(L, abs, i);
          const bool ok = encodeValue(e, -1, depth + 1);
          lua_pop(L, 1);
          if (!ok) return false;
        }
        addPiece(e, "]", 1);
        return true;
      }
      addPiece(e, "{", 1);
      bool first = true;
      lua_pushnil(L);
      while (lua_next(L, abs)) {
        // key at -2, value at -1
        if (lua_type(L, -2) != LUA_TSTRING) {
          lua_pop(L, 2);
          e.err = "object keys must be strings (arrays must be sequences without holes)";
          return false;
        }
        if (!first) addPiece(e, ",", 1);
        first = false;
        size_t kl;
        const char* k = lua_tolstring(L, -2, &kl);
        addString(e, k, kl);
        addPiece(e, ":", 1);
        if (!encodeValue(e, -1, depth + 1)) {
          lua_pop(L, 2);
          return false;
        }
        lua_pop(L, 1);  // keep key for next iteration
      }
      addPiece(e, "}", 1);
      return true;
    }
    default:
      e.err = "cannot encode this type";
      return false;
  }
}

// json.encode(value) -> string | nil, errmsg
int json_encode(lua_State* L) {
  luaL_checkany(L, 1);
  lua_settop(L, 1);
  lua_newtable(L);
  Enc e;
  e.L = L;
  e.tbl = 2;
  e.n = 0;
  e.err = nullptr;
  e.blen = 0;
  if (!encodeValue(e, 1, 0)) {
    lua_pushnil(L);
    lua_pushstring(L, e.err ? e.err : "encode error");
    return 2;
  }
  flushBuf(e);
  // Join pieces: luaL_Buffer with no other stack use inside the loop except balanced get/pop.
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  for (int i = 1; i <= e.n; i++) {
    lua_rawgeti(L, 2, i);
    luaL_addvalue(&b);
  }
  luaL_pushresult(&b);
  return 1;
}

}  // namespace

void registerJson(lua_State* L, Ctx* c) {
  // json.null sentinel: a unique light userdata kept in the registry.
  (void)c;
  static const char nullTag = 0;
  lua_pushlightuserdata(L, const_cast<char*>(&nullTag));  // identity only, never dereferenced
  lua_setfield(L, LUA_REGISTRYINDEX, "crosslua.json.null");
  static const luaL_Reg json[] = {{"encode", json_encode}, {"decode", json_decode}, {nullptr, nullptr}};
  regTable(L, c, "json", json);
  lua_getglobal(L, "json");
  lua_getfield(L, LUA_REGISTRYINDEX, "crosslua.json.null");
  lua_setfield(L, -2, "null");
  lua_pop(L, 1);
}

}  // namespace crosslua
