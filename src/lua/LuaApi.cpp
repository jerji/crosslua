#include "LuaApi.h"

#include <algorithm>
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
    if (f == 0) luaL_error(L, "unknown font '%s'", lua_tostring(L, fontArg));
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
// ---- clipping: apps may draw past the edge (e.g. a line to x = width); that must clip, never log errors or wrap.
// Cohen-Sutherland on 64-bit intermediates. Returns false when nothing of the line is on screen.
bool clipLine(int w, int h, int& x0, int& y0, int& x1, int& y1) {
  auto code = [&](int x, int y) { return (x < 0 ? 1 : 0) | (x >= w ? 2 : 0) | (y < 0 ? 4 : 0) | (y >= h ? 8 : 0); };
  int c0 = code(x0, y0), c1 = code(x1, y1);
  for (int guard = 0; guard < 8; guard++) {
    if (!(c0 | c1)) return true;   // both inside
    if (c0 & c1) return false;     // both on the same outside side
    const int out = c0 ? c0 : c1;
    int64_t x = 0, y = 0;
    const int64_t dx = x1 - x0, dy = y1 - y0;
    if (out & 8) { y = h - 1; x = x0 + dx * (y - y0) / dy; }
    else if (out & 4) { y = 0; x = x0 + dx * (y - y0) / dy; }
    else if (out & 2) { x = w - 1; y = y0 + dy * (x - x0) / dx; }
    else { x = 0; y = y0 + dy * (x - x0) / dx; }
    if (out == c0) { x0 = static_cast<int>(x); y0 = static_cast<int>(y); c0 = code(x0, y0); }
    else { x1 = static_cast<int>(x); y1 = static_cast<int>(y); c1 = code(x1, y1); }
  }
  return false;
}

void drawLineClipped(lua_State* L, int x0, int y0, int x1, int y1, bool black) {
  if (clipLine(be(L).width(), be(L).height(), x0, y0, x1, y1)) be(L).line(x0, y0, x1, y1, black);
}

int gfx_pixel(lua_State* L) {
  const int x = ci(L, 1), y = ci(L, 2);
  if (x >= 0 && y >= 0 && x < be(L).width() && y < be(L).height())
    be(L).pixel(x, y, !lua_isboolean(L, 3) || lua_toboolean(L, 3));
  return 0;
}
int gfx_line(lua_State* L) {
  drawLineClipped(L, ci(L, 1), ci(L, 2), ci(L, 3), ci(L, 4), !lua_isboolean(L, 5) || lua_toboolean(L, 5));
  return 0;
}
// gfx.rect(x, y, w, h [, filled [, black]])
int gfx_rect(lua_State* L) {
  int x = ci(L, 1), y = ci(L, 2), w = ci(L, 3), h = ci(L, 4);
  const bool black = !lua_isboolean(L, 6) || lua_toboolean(L, 6);
  const bool filled = lua_toboolean(L, 5);
  if (w <= 0 || h <= 0) return 0;
  const int W = be(L).width(), H = be(L).height();
  if (filled) {
    const int x1 = std::min<int64_t>(static_cast<int64_t>(x) + w, W), y1 = std::min<int64_t>(static_cast<int64_t>(y) + h, H);
    x = std::max(x, 0);
    y = std::max(y, 0);
    if (x1 > x && y1 > y) be(L).rect(x, y, x1 - x, y1 - y, black, true);
  } else if (x >= 0 && y >= 0 && static_cast<int64_t>(x) + w <= W && static_cast<int64_t>(y) + h <= H) {
    be(L).rect(x, y, w, h, black, false);
  } else {  // partly off-screen outline: draw only the edges that are visible
    const int x1 = x + w - 1, y1 = y + h - 1;
    drawLineClipped(L, x, y, x1, y, black);
    drawLineClipped(L, x, y1, x1, y1, black);
    drawLineClipped(L, x, y, x, y1, black);
    drawLineClipped(L, x1, y, x1, y1, black);
  }
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
// app.open_book(path) -> false, err | (never returns). Hands the file to the reader, which replaces this app.
// Only sd: / data: paths (the app's own folder is code, not a book).
int app_open_book(lua_State* L) {
  const char* spec = luaL_checkstring(L, 1);
  if (strncmp(spec, "sd:", 3) != 0 && strncmp(spec, "data:", 5) != 0) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "open_book needs an sd: or data: path");
    return 2;
  }
  char path[MAX_PATH_LEN + 80];
  Scope sc;
  const char* err = nullptr;
  if (!resolvePath(be(L), spec, path, sizeof(path), &sc, &err)) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, err);
    return 2;
  }
  if (be(L).fsSize(path) < 0 || !be(L).openBook(path)) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "no such file");
    return 2;
  }
  lua_pushinteger(L, -1);   // park forever: the host switches to the reader and tears this VM down
  lua_pushboolean(L, 0);
  return lua_yield(L, 2);
}
// app.restart([entry="main.lua"]) -> false, err | (never returns). The app quits and is started again from `entry`
// (a plain .lua file name in the app's own folder) in a FRESH VM: a fresh heap budget, no leftover globals, WiFi
// radio switched off. Pass state across with data: files. Use it to give a heavy sub-app a lean start.
int app_restart(lua_State* L) {
  const char* entry = luaL_optstring(L, 1, "main.lua");
  const size_t n = strlen(entry);
  bool ok = n >= 5 && n <= 48 && strcmp(entry + n - 4, ".lua") == 0 && entry[0] != '.';
  for (size_t i = 0; ok && i < n; i++) {
    const char c = entry[i];
    ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.';
  }
  if (!ok || strstr(entry, "..")) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "entry must be a plain .lua file name in the app folder");
    return 2;
  }
  char spec[64], path[MAX_PATH_LEN + 80];
  snprintf(spec, sizeof(spec), "app:%s", entry);
  Scope sc;
  const char* err = nullptr;
  if (!resolvePath(be(L), spec, path, sizeof(path), &sc, &err) || be(L).fsSize(path) < 0 || !be(L).requestRestart(entry)) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, err ? err : "no such entry script");
    return 2;
  }
  lua_pushinteger(L, -1);  // park forever: the host swaps in the fresh VM
  lua_pushboolean(L, 0);
  return lua_yield(L, 2);
}
int app_entry(lua_State* L) {
  lua_pushstring(L, be(L).entryName());
  return 1;
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
  lua_pushinteger(L, static_cast<lua_Integer>(be(L).largestFreeBlock()));
  return 3;
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

// Pushes nil, err (the "errors are returned, not thrown" convention).
static int pushErr2(lua_State* L, const char* msg) {
  lua_pushnil(L);
  lua_pushstring(L, msg);
  return 2;
}

// gfx.qr(text, x, y, side) -> true | false. Draws a QR code fitted into a side x side box in the CURRENT frame.
int gfx_qr(lua_State* L) {
  size_t len = 0;
  const char* text = luaL_checklstring(L, 1, &len);
  if (len == 0 || len > 1000) return pushErr2(L, "text must be 1..1000 bytes");
  const int x = static_cast<int>(luaL_checknumber(L, 2));
  const int y = static_cast<int>(luaL_checknumber(L, 3));
  int side = static_cast<int>(luaL_optnumber(L, 4, 0));
  int w, h;
  w = be(L).width();
  h = be(L).height();
  if (side == 0) side = std::min(w - x, h - y);
  if (side < 21 || x < 0 || y < 0 || x + side > w || y + side > h)
    return pushErr2(L, "box does not fit on the screen (need at least 21x21)");
  if (!be(L).drawQr(text, x, y, side)) return pushErr2(L, "QR does not fit the box");
  lua_pushboolean(L, 1);
  return 1;
}
// gfx.rounded_rect(x, y, w, h, radius [, filled=false [, black=true]])
int gfx_rounded_rect(lua_State* L) {
  const int x = static_cast<int>(luaL_checknumber(L, 1)), y = static_cast<int>(luaL_checknumber(L, 2));
  const int w = static_cast<int>(luaL_checknumber(L, 3)), h = static_cast<int>(luaL_checknumber(L, 4));
  const int r = static_cast<int>(luaL_checknumber(L, 5));
  const bool filled = lua_toboolean(L, 6);
  const bool black = lua_isnoneornil(L, 7) ? true : lua_toboolean(L, 7);
  if (w < 0 || h < 0 || r < 0 || r * 2 > w || r * 2 > h) return pushErr2(L, "radius must be <= half of width and height");
  be(L).drawRoundedRect(x, y, w, h, r, black, filled);
  return 0;
}

// ---- device ---------------------------------------------------------------
// device.frontlight() -> on, brightness, warmth | nil (board without a frontlight)
// device.frontlight(brightness [, warmth [, on]]) -> true | nil, err
int dev_frontlight(lua_State* L) {
  if (lua_gettop(L) == 0) {
    bool on = false;
    int br = 0, warm = 0;
    if (!be(L).frontlightGet(&on, &br, &warm)) {
      lua_pushnil(L);
      return 1;
    }
    lua_pushboolean(L, on);
    lua_pushinteger(L, br);
    lua_pushinteger(L, warm);
    return 3;
  }
  const int br = static_cast<int>(luaL_checknumber(L, 1));
  const int warm = lua_isnoneornil(L, 2) ? -1 : static_cast<int>(luaL_checknumber(L, 2));
  const int on = lua_isnoneornil(L, 3) ? -1 : (lua_toboolean(L, 3) ? 1 : 0);
  if (br < 0 || br > 100) return luaL_error(L, "brightness must be 0..100");
  if (warm != -1 && (warm < 0 || warm > 100)) return luaL_error(L, "warmth must be 0..100");
  bool dummy = false;
  int b2 = 0, w2 = 0;
  if (!be(L).frontlightGet(&dummy, &b2, &w2)) return luaL_error(L, "no frontlight on this device");
  be(L).frontlightSet(br, warm, on);
  lua_pushboolean(L, 1);
  return 1;
}

// ---- time -----------------------------------------------------------------
// time.now() -> epoch seconds (UTC) | nil when the device clock is not trustworthy (never synced, no RTC).
// Epoch seconds fit a 32-bit Lua integer until 2038.
int time_now(lua_State* L) {
  const int64_t e = be(L).epochNow();
  if (e <= 0) lua_pushnil(L);
  else lua_pushinteger(L, static_cast<lua_Integer>(e));
  return 1;
}
// time.date([epoch]) -> {year, month, day, hour, min, sec, wday (1 = Sunday), yday} in local time | nil if no clock
int time_date(lua_State* L) {
  int64_t e = lua_isnoneornil(L, 1) ? be(L).epochNow() : static_cast<int64_t>(luaL_checknumber(L, 1));
  int f[8];
  if (e <= 0 || !be(L).localDate(e, f)) {
    lua_pushnil(L);
    return 1;
  }
  static const char* const names[8] = {"year", "month", "day", "hour", "min", "sec", "wday", "yday"};
  lua_createtable(L, 0, 8);
  for (int i = 0; i < 8; i++) {
    lua_pushinteger(L, f[i]);
    lua_setfield(L, -2, names[i]);
  }
  return 1;
}

// time.sync([timeout_s]) -> true | false, err. SNTP over the current WiFi connection (network permission).
int time_sync(lua_State* L) {
  if (!be(L).netAllowed()) return pushErr2(L, "network not permitted: add \"permissions\": [\"network\"] to this app's manifest.json");
  const int secs = lua_isnoneornil(L, 1) ? 5 : static_cast<int>(luaL_checknumber(L, 1));
  if (secs < 1 || secs > 60) return pushErr2(L, "timeout must be 1..60 seconds");
  char err[96] = {0};
  if (!be(L).timeSync(secs * 1000, err, sizeof(err))) return pushErr2(L, err);
  lua_pushboolean(L, 1);
  return 1;
}
// time.set(epoch) -> true. Manual wall-clock set (UTC epoch seconds); use only when SNTP is not an option.
int time_set(lua_State* L) {
  const lua_Number e = luaL_checknumber(L, 1);
  if (e < 1600000000 || e > 4000000000) return pushErr2(L, "epoch out of the plausible range (2020..2096)");
  if (!be(L).timeSet(static_cast<int64_t>(e))) return pushErr2(L, "clock set failed");
  lua_pushboolean(L, 1);
  return 1;
}

// ---- system additions ------------------------------------------------------
// system.mac() -> "AA:BB:CC:DD:EE:FF" (the device's own WiFi MAC; fine to show, it is not a secret)
int sys_mac(lua_State* L) {
  char m[18];
  be(L).mac(m);
  lua_pushstring(L, m);
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
                                 {"qr", gfx_qr}, {"rounded_rect", gfx_rounded_rect},
                                 {"text_width", gfx_text_width}, {"line_height", gfx_line_height},
                                 {"present", gfx_present}, {nullptr, nullptr}};
  static const luaL_Reg input[] = {{"poll", input_poll}, {"wait", input_wait}, {nullptr, nullptr}};
  static const luaL_Reg app[] = {{"sleep", app_sleep}, {"exit", app_exit}, {"name", app_name},
                                 {"dir", app_dir},     {"open_book", app_open_book},
                                 {"restart", app_restart}, {"entry", app_entry}, {nullptr, nullptr}};
  static const luaL_Reg sys[] = {{"millis", sys_millis}, {"heap", sys_heap},       {"lua_mem", sys_lua_mem},
                                 {"battery", sys_battery}, {"mac", sys_mac}, {nullptr, nullptr}};
  regTable(L, c, "gfx", gfx);
  regTable(L, c, "input", input);
  regTable(L, c, "app", app);
  {  // keep debug info (readable tracebacks) only when the developer asks: <dataDir>/debug.flag
    char flag[MAX_PATH_LEN + 40];
    snprintf(flag, sizeof(flag), "%s/debug.flag", backend.dataDir());
    vm.setStripDebug(backend.fsSize(flag) < 0);
  }
  regTable(L, c, "system", sys);
  static const luaL_Reg timeFns[] = {{"now", time_now}, {"date", time_date}, {"sync", time_sync}, {"set", time_set},
                                    {nullptr, nullptr}};
  static const luaL_Reg devFns[] = {{"frontlight", dev_frontlight}, {nullptr, nullptr}};
  regTable(L, c, "time", timeFns);
  regTable(L, c, "device", devFns);
  registerFs(L, c);
  registerJson(L, c);
  registerNet(L, c);
  registerZip(L, c);
  registerRequire(L, c);

  lua_pushlightuserdata(L, c);
  lua_pushcclosure(L, api_print, 1);
  lua_setglobal(L, "print");
}

}  // namespace crosslua
