// xml.* — a small XML parser for feeds/OPF/TOC data. See docs/lua/API.md.
// Expat is vendored at lib/expat (v2.7.3) and already linked by the firmware (the SDK's XmlSax.cpp does
// `#include <expat.h>`). The host tests link the system libexpat — identical SAX API and well-formedness,
// deterministic output shape.
//
// Representation (a "node"): an element is a table
//   { tag = "<name>", attrs = { key = value, ... } }
// with its children appended positionally — a STRING child is text (character data + CDATA, adjacent runs
// merged), a TABLE child is a nested element. Comments and processing instructions are dropped; namespaces are
// not resolved (raw tag names like "dc:title" are kept). The document's single root element is returned.
#include <expat.h>

#include <cstdio>  // snprintf
#include <cstring>
#include <vector>

#include "LuaInternal.h"

namespace crosslua {
namespace {

int pushFail(lua_State* L, const char* msg) {
  lua_pushnil(L);
  lua_pushstring(L, msg);
  return 2;
}

constexpr size_t MAX_XML = 64 * 1024;  // one-shot input cap (matches the other parsers)
constexpr int MAX_DEPTH = 32;          // nesting depth cap (device Lua heap is only ~96 KB)

struct XmlBuild {
  lua_State* L;
  int rootRef = LUA_NOREF;
  std::vector<int> open;  // registry refs of open elements, innermost last (includes the root)
  std::vector<int> kids;  // parallel: child count per open element
  bool bad = false;
  char err[96] = {0};
};

void XMLCALL onStart(void* ud, const XML_Char* name, const XML_Char** atts) {
  auto& b = *static_cast<XmlBuild*>(ud);
  if (b.bad) return;
  lua_State* L = b.L;
  if ((int)b.open.size() >= MAX_DEPTH) {
    snprintf(b.err, sizeof(b.err), "xml nested deeper than %d levels", MAX_DEPTH);
    b.bad = true;
    return;
  }
  // Build the element table with tag + attrs.
  lua_createtable(L, 0, 2);
  lua_pushstring(L, name);
  lua_setfield(L, -2, "tag");
  lua_createtable(L, 0, 0);
  for (int i = 0; atts && atts[i]; i += 2) {
    lua_pushstring(L, atts[i + 1]);
    lua_setfield(L, -2, atts[i]);
  }
  lua_setfield(L, -2, "attrs");
  // Reference the element, then link it into the tree.
  if (b.open.empty()) {                            // first element: the document root
    const int r = luaL_ref(L, LUA_REGISTRYINDEX);  // ref #1 → open
    b.open.push_back(r);
    lua_rawgeti(L, LUA_REGISTRYINDEX, r);
    b.rootRef = luaL_ref(L, LUA_REGISTRYINDEX);  // ref #2 → owned by rootRef
  } else {
    const int r = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_rawgeti(L, LUA_REGISTRYINDEX, b.open.back());  // parent
    lua_rawgeti(L, LUA_REGISTRYINDEX, r);              // element
    lua_rawseti(L, -2, ++b.kids.back());               // parent[kid] = element
    lua_pop(L, 1);
    b.open.push_back(r);
  }
  b.kids.push_back(0);
}

void XMLCALL onText(void* ud, const XML_Char* s, int len) {
  auto& b = *static_cast<XmlBuild*>(ud);
  if (b.bad || b.open.empty() || len <= 0) return;
  lua_State* L = b.L;
  lua_rawgeti(L, LUA_REGISTRYINDEX, b.open.back());  // [parent]
  int& kid = b.kids.back();
  if (kid > 0) {              // merge into the previous sibling when it is also text
    lua_rawgeti(L, -1, kid);  // [parent, last]
    if (lua_type(L, -1) == LUA_TSTRING) {
      lua_pushlstring(L, s, static_cast<size_t>(len));  // [parent, last, txt]
      lua_concat(L, 2);                                 // [parent, merged]
      lua_rawseti(L, -2, kid);                          // parent[kid] = merged
      lua_pop(L, 1);
      return;
    }
    lua_pop(L, 1);  // not text: drop it
  }
  lua_pushlstring(L, s, static_cast<size_t>(len));  // [parent, txt]
  lua_rawseti(L, -2, ++kid);                        // parent[kid] = txt
  lua_pop(L, 1);
}

void XMLCALL onEnd(void* ud, const XML_Char*) {
  auto& b = *static_cast<XmlBuild*>(ud);
  if (b.bad) return;
  if (b.open.empty()) return;
  luaL_unref(b.L, LUA_REGISTRYINDEX, b.open.back());  // the root's second ref lives on in rootRef
  b.open.pop_back();
  b.kids.pop_back();
}

void cleanup(XmlBuild& b) {
  lua_State* L = b.L;
  for (int ref : b.open) luaL_unref(L, LUA_REGISTRYINDEX, ref);
  if (b.rootRef != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, b.rootRef);
}

}  // namespace

// xml.parse(text) -> node | nil, err. Parse a well-formed XML document into the tree described above.
int xml_parse(lua_State* L) {
  size_t n = 0;
  const char* s = luaL_checklstring(L, 1, &n);
  if (n == 0) return pushFail(L, "empty XML document");
  if (n > MAX_XML) return pushFail(L, "XML too large (max 64 KB)");

  XmlBuild b;
  b.L = L;
  XML_Parser p = XML_ParserCreate(nullptr);
  if (!p) return pushFail(L, "out of memory");
  XML_SetUserData(p, &b);
  XML_SetElementHandler(p, onStart, onEnd);
  XML_SetCharacterDataHandler(p, onText);

  if (XML_Parse(p, s, static_cast<int>(n), 1) == XML_STATUS_ERROR) {
    const XML_Error e = XML_GetErrorCode(p);
    const char* msg = XML_ErrorString(e);
    if (!msg) msg = "XML parse error";
    // Prefer the depth message when we tripped that gate mid-parse.
    if (b.bad) {
      XML_ParserFree(p);
      cleanup(b);
      return pushFail(L, b.err);
    }
    XML_ParserFree(p);
    cleanup(b);
    return pushFail(L, msg);
  }
  XML_ParserFree(p);
  if (b.bad) {
    cleanup(b);
    return pushFail(L, b.err);
  }
  if (b.rootRef == LUA_NOREF) return pushFail(L, "no root element");
  lua_rawgeti(L, LUA_REGISTRYINDEX, b.rootRef);
  luaL_unref(L, LUA_REGISTRYINDEX, b.rootRef);
  return 1;
}

void registerXml(lua_State* L, Ctx* c) {
  static const luaL_Reg fns[] = {{"parse", xml_parse}, {nullptr, nullptr}};
  regTable(L, c, "xml", fns);
}

}  // namespace crosslua