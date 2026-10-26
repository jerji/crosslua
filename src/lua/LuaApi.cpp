#include "LuaApi.h"

#include <cstdio>
#include <cstring>

#include "LuaInternal.h"
#include "LuaVm.h"

extern "C" {
#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"
}

namespace crosslua {
namespace {


// Coordinates may arrive as floats (x/2); accept any number.
inline int ci(lua_State* L, int i) { return static_cast<int>(luaL_checknumber(L, i)); }

struct TextOpts {
  int font;
  bool black;
  int style;
  char align;  // 'l' 'c' 'r'
};

TextOpts parseTextOpts(lua_State* L, int fontArg) {
  TextOpts o{be(L).fontId("ui"), true, 0, 'l'};
  if (lua_isstring(L, fontArg)) {
    const int f = be(L).fontId(lua_tostring(L, fontArg));
    if (f < 0) luaL_error(L, "unknown font '%s'", lua_tostring(L, fontArg));
    o.font = f;
  }
  if (lua_isstring(L, fontArg + 1)) {
    for (const char* p = lua_tostring(L, fontArg + 1); *p; p++) {
      switch (*p) {
        case 'b': o.style |= 1; break;
        case 'i': o.style |= 2; break;
        case 'w': o.black = false; break;
        case 'c': o.align = 'c'; break;
        case 'r': o.align = 'r'; break;
        default: break;
      }
    }
  }
  return o;
}

// ---- gfx ------------------------------------------------------------------
int gfx_size(lua_State* L) {
  lua_pushinteger(L, be(L).width());
  lua_pushinteger(L, be(L).height());
  return 2;
}
int gfx_clear(lua_State* L) {
  be(L).clear(!lua_toboolean(L, 1));  // gfx.clear() = white; gfx.clear(true) = black
  return 0;
}
int gfx_pixel(lua_State* L) {
  be(L).pixel(ci(L, 1), ci(L, 2), !lua_isboolean(L, 3) || lua_toboolean(L, 3));
  return 0;
}
int gfx_line(lua_State* L) {
  be(L).line(ci(L, 1), ci(L, 2), ci(L, 3), ci(L, 4), !lua_isboolean(L, 5) || lua_toboolean(L, 5));
  return 0;
}
// gfx.rect(x, y, w, h [, filled [, black]])
int gfx_rect(lua_State* L) {
  be(L).rect(ci(L, 1), ci(L, 2), ci(L, 3), ci(L, 4), !lua_isboolean(L, 6) || lua_toboolean(L, 6),
             lua_toboolean(L, 5));
  return 0;
}
// gfx.text(x, y, str [, font [, flags]])   flags: b bold, i italic, w white, c center, r right
int gfx_text(lua_State* L) {
  const int x = ci(L, 1), y = ci(L, 2);
  const char* s = luaL_checkstring(L, 3);
  const TextOpts o = parseTextOpts(L, 4);
  int dx = x;
  if (o.align != 'l') {
    const int w = be(L).textWidth(o.font, s, o.style);
    dx = o.align == 'c' ? x - w / 2 : x - w;
  }
  be(L).text(o.font, dx, y, s, o.black, o.style);
  return 0;
}
// gfx.text_width(str [, font [, flags]]) -> px
int gfx_text_width(lua_State* L) {
  const char* s = luaL_checkstring(L, 1);
  const TextOpts o = parseTextOpts(L, 2);
  lua_pushinteger(L, be(L).textWidth(o.font, s, o.style));
  return 1;
}
int gfx_line_height(lua_State* L) {
  const TextOpts o = parseTextOpts(L, 1);
  lua_pushinteger(L, be(L).lineHeight(o.font));
  return 1;
}
// gfx.present([mode])  mode: "fast" (default) | "half" | "full"
int gfx_present(lua_State* L) {
  int mode = 0;
  if (lua_isstring(L, 1)) {
    const char* m = lua_tostring(L, 1);
    if (!strcmp(m, "half")) mode = 1;
    else if (!strcmp(m, "full")) mode = 2;
    else if (strcmp(m, "fast")) return luaL_error(L, "present mode must be fast|half|full");
  }
  be(L).present(mode);
  return 0;
}

// ---- input ----------------------------------------------------------------
// input.poll() -> event name or nil (never blocks)
int input_poll(lua_State* L) {
  const char* e = be(L).popEvent();
  if (e) lua_pushstring(L, e);
  else lua_pushnil(L);
  return 1;
}
// input.wait([timeout_ms]) -> event name, or nil on timeout. Without timeout waits forever.
int input_wait(lua_State* L) {
  if (const char* e = be(L).popEvent()) {  // fast path: no yield round trip
    lua_pushstring(L, e);
    return 1;
  }
  const lua_Integer ms = lua_isnumber(L, 1) ? static_cast<lua_Integer>(lua_tonumber(L, 1)) : -1;
  lua_pushinteger(L, ms);
  return lua_yield(L, 1);  // host resumes with the event name / nil
}

// ---- app ------------------------------------------------------------------
// app.sleep(ms): timer only, input events stay queued.
int app_sleep(lua_State* L) {
  lua_Integer ms = static_cast<lua_Integer>(luaL_checknumber(L, 1));
  if (ms < 0) ms = 0;
  lua_pushinteger(L, ms);
  lua_pushboolean(L, 0);
  return lua_yield(L, 2);
}
int app_exit(lua_State* L) {
  be(L).requestExit();
  lua_pushinteger(L, -1);
  lua_pushboolean(L, 0);
  return lua_yield(L, 2);  // park forever; host tears the VM down
}
int app_name(lua_State* L) {
  lua_pushstring(L, be(L).appName());
  return 1;
}
int app_dir(lua_State* L) {
  lua_pushstring(L, be(L).appDir());
  return 1;
}

// ---- system ---------------------------------------------------------------
int sys_millis(lua_State* L) {
  lua_pushinteger(L, static_cast<lua_Integer>(be(L).millis() & 0x7fffffff));  // 31-bit, wraps ~24d; diff safely
  return 1;
}
int sys_heap(lua_State* L) {
  lua_pushinteger(L, static_cast<lua_Integer>(be(L).freeHeap()));
  lua_pushinteger(L, static_cast<lua_Integer>(be(L).minFreeHeap()));
  return 2;
}
int sys_lua_mem(lua_State* L) {
  const LuaVm* vm = ctx(L)->vm;
  lua_pushinteger(L, static_cast<lua_Integer>(vm->usedBytes()));
  lua_pushinteger(L, static_cast<lua_Integer>(vm->peakBytes()));
  lua_pushinteger(L, static_cast<lua_Integer>(vm->budgetBytes()));
  return 3;
}
int sys_battery(lua_State* L) {
  lua_pushinteger(L, be(L).battery());
  return 1;
}

// print(...) -> device log (tabs between args, like stock print)
int api_print(lua_State* L) {
  char buf[256];
  size_t n = 0;
  const int top = lua_gettop(L);
  for (int i = 1; i <= top && n < sizeof(buf) - 1; i++) {
    size_t len = 0;
    const char* s = luaL_tolstring(L, i, &len);
    if (i > 1 && n < sizeof(buf) - 1) buf[n++] = '\t';
    const size_t room = sizeof(buf) - 1 - n;
    const size_t c = len < room ? len : room;
    memcpy(buf + n, s, c);
    n += c;
    lua_pop(L, 1);
  }
  buf[n] = '\0';
  be(L).log(buf);
  return 0;
}

}  // namespace

void regTable(lua_State* L, Ctx* c, const char* name, const luaL_Reg* funcs) {
  lua_newtable(L);
  lua_pushlightuserdata(L, c);
  luaL_setfuncs(L, funcs, 1);
  lua_setglobal(L, name);
}

void registerApi(LuaVm& vm, Backend& backend) {
  lua_State* L = vm.state();
  // Ctx must outlive the VM; it's a tiny allocation owned by the Lua state as a userdata.
  Ctx* c = static_cast<Ctx*>(lua_newuserdatauv(L, sizeof(Ctx), 0));
  c->be = &backend;
  c->vm = &vm;
  lua_setfield(L, LUA_REGISTRYINDEX, "crosslua.ctx");

  static const luaL_Reg gfx[] = {{"size", gfx_size},     {"clear", gfx_clear},   {"pixel", gfx_pixel},
                                 {"line", gfx_line},     {"rect", gfx_rect},     {"text", gfx_text},
                                 {"text_width", gfx_text_width}, {"line_height", gfx_line_height},
                                 {"present", gfx_present}, {nullptr, nullptr}};
  static const luaL_Reg input[] = {{"poll", input_poll}, {"wait", input_wait}, {nullptr, nullptr}};
  static const luaL_Reg app[] = {{"sleep", app_sleep}, {"exit", app_exit}, {"name", app_name},
                                 {"dir", app_dir},     {nullptr, nullptr}};
  static const luaL_Reg sys[] = {{"millis", sys_millis}, {"heap", sys_heap},       {"lua_mem", sys_lua_mem},
                                 {"battery", sys_battery}, {nullptr, nullptr}};
  regTable(L, c, "gfx", gfx);
  regTable(L, c, "input", input);
  regTable(L, c, "app", app);
  regTable(L, c, "system", sys);
  registerFs(L, c);
  registerJson(L, c);
  registerRequire(L, c);

  lua_pushlightuserdata(L, c);
  lua_pushcclosure(L, api_print, 1);
  lua_setglobal(L, "print");
}

}  // namespace crosslua
