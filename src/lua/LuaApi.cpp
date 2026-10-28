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
        case 'b':
          o.style |= 1;
          break;
        case 'i':
          o.style |= 2;
          break;
        case 'w':
          o.black = false;
          break;
        case 'c':
          o.align = 'c';
          break;
        case 'r':
          o.align = 'r';
          break;
        default:
          break;
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
    if (!(c0 | c1)) return true;  // both inside
    if (c0 & c1) return false;    // both on the same outside side
    const int out = c0 ? c0 : c1;
    int64_t x = 0, y = 0;
    const int64_t dx = x1 - x0, dy = y1 - y0;
    if (out & 8) {
      y = h - 1;
      x = x0 + dx * (y - y0) / dy;
    } else if (out & 4) {
      y = 0;
      x = x0 + dx * (y - y0) / dy;
    } else if (out & 2) {
      x = w - 1;
      y = y0 + dy * (x - x0) / dx;
    } else {
      x = 0;
      y = y0 + dy * (x - x0) / dx;
    }
    if (out == c0) {
      x0 = static_cast<int>(x);
      y0 = static_cast<int>(y);
      c0 = code(x0, y0);
    } else {
      x1 = static_cast<int>(x);
      y1 = static_cast<int>(y);
      c1 = code(x1, y1);
    }
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
    const int x1 = std::min<int64_t>(static_cast<int64_t>(x) + w, W),
              y1 = std::min<int64_t>(static_cast<int64_t>(y) + h, H);
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
    if (!strcmp(m, "half"))
      mode = 1;
    else if (!strcmp(m, "full"))
      mode = 2;
    else if (strcmp(m, "fast"))
      return luaL_error(L, "present mode must be fast|half|full");
  }
  be(L).present(mode);
  return 0;
}

// ---- input ----------------------------------------------------------------
// input.poll() -> event name or nil (never blocks)
int input_poll(lua_State* L) {
  const char* e = be(L).popEvent();
  if (e)
    lua_pushstring(L, e);
  else
    lua_pushnil(L);
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
  lua_pushinteger(L, -1);  // park forever: the host switches to the reader and tears this VM down
  lua_pushboolean(L, 0);
  return lua_yield(L, 2);
}
// app.restart([entry="main.lua"]) -> false, err | (never returns). The app quits and is started again from `entry`
// (a .lua file in the app's own folder, subfolders allowed: "tests/net.lua") in a FRESH VM: a fresh heap budget, no
// leftover globals, WiFi radio switched off. Pass state across with data: files. Use it to give a heavy sub-app a lean
// start. The path sandbox still applies: the entry is resolved as "app:<entry>" (no "..", no hidden or odd segments).
int app_restart(lua_State* L) {
  const char* entry = luaL_optstring(L, 1, "main.lua");
  const size_t n = strlen(entry);
  // A plain name or a subfolder path ("tests/net.lua"). No leading or doubled slashes, no "..", no segment that starts
  // with '.' (hidden) or ' ' (odd); resolvePath re-checks against the app: sandbox anyway.
  bool ok = n >= 5 && n <= 48 && strcmp(entry + n - 4, ".lua") == 0 && entry[0] != '/' && entry[0] != '.';
  bool segStart = true;  // entry[0] was checked; this tracks whether the next character starts a new segment
  for (size_t i = 0; ok && i < n; i++) {
    const char c = entry[i];
    if (c == '/') {
      if (segStart) ok = false;
      segStart = true;
      continue;
    }
    if (segStart && (c == '.' || c == ' ')) ok = false;
    ok = ok && ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' ||
                c == '.');
    segStart = false;
  }
  if (!ok || strstr(entry, "..") || strstr(entry, "//")) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "entry must be a plain .lua file name in the app folder");
    return 2;
  }
  char spec[64], path[MAX_PATH_LEN + 80];
  snprintf(spec, sizeof(spec), "app:%s", entry);
  Scope sc;
  const char* err = nullptr;
  if (!resolvePath(be(L), spec, path, sizeof(path), &sc, &err) || be(L).fsSize(path) < 0 ||
      !be(L).requestRestart(entry)) {
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
  if (w < 0 || h < 0 || r < 0 || r * 2 > w || r * 2 > h)
    return pushErr2(L, "radius must be <= half of width and height");
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

// device.caps() -> { touch, haptic, frontlight, warmlight, color, audio, ble_keyboard, usb_msc, width, height }
int dev_caps(lua_State* L) {
  Backend::DeviceCaps c;
  be(L).deviceCaps(&c);
  lua_createtable(L, 0, 18);
  const struct {
    const char* k;
    bool v;
  } flags[] = {{"touch", c.touch},
               {"haptic", c.haptic},
               {"frontlight", c.frontlight},
               {"warmlight", c.warmlight},
               {"color", c.color},
               {"audio", c.audio},
               {"ble_keyboard", c.bleKeyboard},
               {"usb_msc", c.usbMsc},
               {"imu", c.imu},
               {"gyro", c.gyro},
               {"rtc", c.rtc},
               {"temp_humidity", c.tempHumidity},
               {"buzzer", c.buzzer},
               {"mic", c.mic},
               {"led", c.led},
               {"tls13", c.tls13}};
  for (const auto& f : flags) {
    lua_pushboolean(L, f.v);
    lua_setfield(L, -2, f.k);
  }
  lua_pushinteger(L, be(L).width());
  lua_setfield(L, -2, "width");
  lua_pushinteger(L, be(L).height());
  lua_setfield(L, -2, "height");
  return 1;
}
// device.haptic(ms [, strength 0..255]) -> true | false, reason | nil, err (bad arguments). One non-blocking pulse.
int dev_haptic(lua_State* L) {
  const lua_Number ms = luaL_checknumber(L, 1);
  const lua_Number st = lua_isnoneornil(L, 2) ? 255 : luaL_checknumber(L, 2);
  if (ms < 10 || ms > 1000 || ms != static_cast<int>(ms)) {
    lua_pushnil(L);
    lua_pushstring(L, "ms must be an integer 10..1000");
    return 2;
  }
  if (st < 0 || st > 255 || st != static_cast<int>(st)) {
    lua_pushnil(L);
    lua_pushstring(L, "strength must be an integer 0..255");
    return 2;
  }
  if (!be(L).hapticPulse(static_cast<int>(ms), static_cast<int>(st))) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "no vibration motor on this device (or vibration is off in settings)");
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}
// system.usb() -> boolean (cable connected)
// system.sleep(seconds) -> true | nil, err. Arms a timer wake and enters the SAME deep-sleep flow the power button uses
// (sleep screen, plugin events, rails off; the power button also wakes). The call never returns on the device: the wake
// is a fresh boot. No permission: the power button always wakes the device, so nothing is locked away.
namespace {
int pushFail(lua_State* L, const char* msg) {
  lua_pushnil(L);
  lua_pushstring(L, msg);
  return 2;
}
}  // namespace

int sys_sleep(lua_State* L) {
  if (lua_type(L, 1) != LUA_TNUMBER) return pushFail(L, "seconds must be an integer 1..604800 (a week)");
  const lua_Number sec = luaL_checknumber(L, 1);
  if (sec < 1 || sec > 604800 || sec != static_cast<int>(sec))
    return pushFail(L, "seconds must be an integer 1..604800 (a week)");
  char err[96] = {0};
  if (!be(L).systemSleep(static_cast<int>(sec), err, sizeof(err))) return pushFail(L, err[0] ? err : "sleep failed");
  lua_pushboolean(L, 1);  // unreachable on the device; the host mock ends the script here
  return 1;
}

// system.last_wake() -> "timer" | "button" | "power-on" | "other". What woke the previous cycle ("power-on" = a real
// reset).
int sys_last_wake(lua_State* L) {
  lua_pushstring(L, be(L).wakeCause());
  return 1;
}

int sys_usb(lua_State* L) {
  lua_pushboolean(L, be(L).usbConnected());
  return 1;
}
// input.pos() -> x, y of the touch event input.poll()/input.wait() returned last | nil (button event / nothing)
int input_pos(lua_State* L) {
  int x = 0, y = 0;
  if (!be(L).eventPos(&x, &y)) {
    lua_pushnil(L);
    return 1;
  }
  lua_pushinteger(L, x);
  lua_pushinteger(L, y);
  return 2;
}
// input.key() -> {char = "a" | nil, key = "enter" | nil, code, ctrl, shift, alt, gui} for the "key" event
// input.poll()/input.wait() returned last (a Bluetooth keyboard press); nil for any other event. A printable key has
// `char`, a special key has `key`.
int input_key(lua_State* L) {
  static const char* const SPECIAL[] = {nullptr, "enter", "backspace", "tab",  "escape", "delete", "left",
                                        "right", "up",    "down",      "home", "end",    "pageup", "pagedown"};
  Backend::KeyInfo k;
  memset(&k, 0, sizeof(k));
  if (!be(L).eventKey(&k)) {
    lua_pushnil(L);
    return 1;
  }
  lua_createtable(L, 0, 7);
  if (k.ch) {
    const char c[2] = {k.ch, 0};
    lua_pushstring(L, c);
    lua_setfield(L, -2, "char");
  }
  if (k.special > 0 && k.special < sizeof(SPECIAL) / sizeof(SPECIAL[0])) {
    lua_pushstring(L, SPECIAL[k.special]);
    lua_setfield(L, -2, "key");
  }
  lua_pushinteger(L, k.code);
  lua_setfield(L, -2, "code");
  lua_pushboolean(L, (k.mods & 0x11) != 0);
  lua_setfield(L, -2, "ctrl");
  lua_pushboolean(L, (k.mods & 0x22) != 0);
  lua_setfield(L, -2, "shift");
  lua_pushboolean(L, (k.mods & 0x44) != 0);
  lua_setfield(L, -2, "alt");
  lua_pushboolean(L, (k.mods & 0x88) != 0);
  lua_setfield(L, -2, "gui");
  return 1;
}
// input.text(title [, initial [, max_len [, mode]]]) -> string | nil, "cancelled" | nil, err.
// Parks the script while the system keyboard runs (like wifi.connect): the screen is then the system's, redraw after.
constexpr size_t TEXT_MAX_TITLE = 60, TEXT_MAX_INITIAL = 256;
int text_k(lua_State* L, int, lua_KContext) {
  const char* ev = lua_tostring(L, -1);  // what the host resumed us with
  if (ev && strncmp(ev, "text:ok:", 8) == 0) {
    lua_pushstring(L, ev + 8);
    return 1;
  }
  lua_pushnil(L);
  lua_pushstring(L, "cancelled");
  return 2;
}
int input_text(lua_State* L) {
  size_t tl, il = 0;
  const char* title = luaL_checklstring(L, 1, &tl);
  const char* initial = lua_isnoneornil(L, 2) ? "" : luaL_checklstring(L, 2, &il);
  const lua_Number maxLen = lua_isnoneornil(L, 3) ? 128 : luaL_checknumber(L, 3);
  const char* mode = lua_isnoneornil(L, 4) ? "text" : luaL_checkstring(L, 4);
  auto fail = [&](const char* msg) {
    lua_pushnil(L);
    lua_pushstring(L, msg);
    return 2;
  };
  if (tl > TEXT_MAX_TITLE) return fail("title too long (max 60 characters)");
  if (il > TEXT_MAX_INITIAL) return fail("initial text too long (max 256 bytes)");
  if (maxLen < 1 || maxLen > 256 || maxLen != static_cast<int>(maxLen))
    return fail("max_len must be an integer 1..256");
  int m = -1;
  if (!strcmp(mode, "text"))
    m = 0;
  else if (!strcmp(mode, "password"))
    m = 1;
  else if (!strcmp(mode, "url"))
    m = 2;
  if (m < 0) return fail("mode must be text, password or url");
  if (il > static_cast<size_t>(maxLen)) return fail("initial text is longer than max_len");
  be(L).textRequest(title, initial, static_cast<int>(maxLen), m);
  lua_pushinteger(L, -1);  // no timeout...
  lua_pushboolean(L, 0);   // ...and button events do not wake it: only the host's resume does
  return lua_yieldk(L, 2, 0, text_k);
}

// device.motion() -> { ax, ay, az (g), gx, gy, gz (deg/s), gyro = boolean } | nil, err. One sample, board-independent
// axes.
int dev_motion(lua_State* L) {
  Backend::Motion m;
  switch (be(L).motionRead(&m)) {
    case Backend::SensorStatus::Absent:
      lua_pushnil(L);
      lua_pushstring(L, "no motion sensor on this device");
      return 2;
    case Backend::SensorStatus::ReadFailed:
      lua_pushnil(L);
      lua_pushstring(L, "motion sensor read failed");
      return 2;
    case Backend::SensorStatus::Ok:
      break;
  }
  lua_createtable(L, 0, 7);
  const struct {
    const char* k;
    float v;
  } f[] = {{"ax", m.ax}, {"ay", m.ay}, {"az", m.az}, {"gx", m.gx}, {"gy", m.gy}, {"gz", m.gz}};
  for (const auto& e : f) {
    lua_pushnumber(L, e.v);
    lua_setfield(L, -2, e.k);
  }
  lua_pushboolean(L, m.gyro);
  lua_setfield(L, -2, "gyro");
  return 1;
}
// device.environment() -> temp_c, humidity_pct | nil, err
int dev_environment(lua_State* L) {
  float t = 0, h = 0;
  switch (be(L).envRead(&t, &h)) {
    case Backend::SensorStatus::Absent:
      lua_pushnil(L);
      lua_pushstring(L, "no temperature/humidity sensor on this device");
      return 2;
    case Backend::SensorStatus::ReadFailed:
      lua_pushnil(L);
      lua_pushstring(L, "temperature/humidity sensor read failed");
      return 2;
    case Backend::SensorStatus::Ok:
      break;
  }
  lua_pushnumber(L, t);
  lua_pushnumber(L, h);
  return 2;
}
// device.tone(freq_hz [, ms]) -> true | false, why | nil, err ; device.tone() stops it. ms 0 (default) = until stopped.
int dev_tone(lua_State* L) {
  const char* NO_BUZZER = "no buzzer on this device";
  if (lua_gettop(L) == 0) {
    if (!be(L).toneStop()) {
      lua_pushboolean(L, 0);
      lua_pushstring(L, NO_BUZZER);
      return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
  }
  const lua_Number f = luaL_checknumber(L, 1);
  const lua_Number ms = lua_isnoneornil(L, 2) ? 0 : luaL_checknumber(L, 2);
  if (f < 20 || f > 20000 || f != static_cast<int>(f)) {
    lua_pushnil(L);
    lua_pushstring(L, "freq must be an integer 20..20000");
    return 2;
  }
  if (ms < 0 || ms > 10000 || ms != static_cast<int>(ms)) {
    lua_pushnil(L);
    lua_pushstring(L, "ms must be an integer 0..10000");
    return 2;
  }
  if (!be(L).toneStart(static_cast<int>(f), static_cast<int>(ms))) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, NO_BUZZER);
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}

// ---- led (boards with addressable LEDs)
// ------------------------------------------------------------------------------
const char* const NO_LEDS = "no LEDs on this device";
bool colorByte(lua_State* L, int i, int* out) {
  const lua_Number v = luaL_checknumber(L, i);
  if (v < 0 || v > 255 || v != static_cast<int>(v)) return false;
  *out = static_cast<int>(v);
  return true;
}
int ledFail(lua_State* L, const char* msg) {
  lua_pushnil(L);
  lua_pushstring(L, msg);
  return 2;
}
// led.count() -> number of LEDs (0 when the board has none)
int led_count(lua_State* L) {
  lua_pushinteger(L, be(L).ledCount());
  return 1;
}
// led.set(index 1..count, r, g, b) -> true | false, why | nil, err
int led_set(lua_State* L) {
  const lua_Number idx = luaL_checknumber(L, 1);
  int r, g, b;
  const bool ok = colorByte(L, 2, &r) & colorByte(L, 3, &g) & colorByte(L, 4, &b);
  const int n = be(L).ledCount();
  if (n == 0) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, NO_LEDS);
    return 2;
  }
  if (idx < 1 || idx > n || idx != static_cast<int>(idx)) {
    char msg[48];
    snprintf(msg, sizeof(msg), "index must be an integer 1..%d", n);
    return ledFail(L, msg);
  }
  if (!ok) return ledFail(L, "r, g, b must be integers 0..255");
  be(L).ledSet(static_cast<int>(idx) - 1, r, g, b);
  lua_pushboolean(L, 1);
  return 1;
}
// led.all(r, g, b) -> true | false, why | nil, err
int led_all(lua_State* L) {
  int r, g, b;
  const bool ok = colorByte(L, 1, &r) & colorByte(L, 2, &g) & colorByte(L, 3, &b);
  if (be(L).ledCount() == 0) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, NO_LEDS);
    return 2;
  }
  if (!ok) return ledFail(L, "r, g, b must be integers 0..255");
  be(L).ledSet(-1, r, g, b);
  lua_pushboolean(L, 1);
  return 1;
}
// led.off() -> true | false, why
int led_off(lua_State* L) {
  if (be(L).ledCount() == 0) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, NO_LEDS);
    return 2;
  }
  be(L).ledOff();
  lua_pushboolean(L, 1);
  return 1;
}
// led.brightness(0..255) -> true | false, why | nil, err   (scales every colour; 255 = as set)
int led_brightness(lua_State* L) {
  int v;
  const bool ok = colorByte(L, 1, &v);
  if (be(L).ledCount() == 0) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, NO_LEDS);
    return 2;
  }
  if (!ok) return ledFail(L, "brightness must be an integer 0..255");
  be(L).ledBrightness(v);
  lua_pushboolean(L, 1);
  return 1;
}

// ---- time -----------------------------------------------------------------
// time.now() -> epoch seconds (UTC) | nil when the device clock is not trustworthy (never synced, no RTC).
// Epoch seconds fit a 32-bit Lua integer until 2038.
int time_now(lua_State* L) {
  const int64_t e = be(L).epochNow();
  if (e <= 0)
    lua_pushnil(L);
  else
    lua_pushinteger(L, static_cast<lua_Integer>(e));
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
  if (!be(L).netAllowed())
    return pushErr2(L, "network not permitted: add \"permissions\": [\"network\"] to this app's manifest.json");
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
// system.dev_floor(kb) -> true | nil, err   (development builds only: the heap-guard floor in KB, 8..64)
int sys_dev_floor(lua_State* L) {
  const lua_Number kb = luaL_checknumber(L, 1);
  if (kb < 8 || kb > 64 || kb != static_cast<int>(kb)) {
    lua_pushnil(L);
    lua_pushstring(L, "kb must be an integer 8..64");
    return 2;
  }
  if (!be(L).devSetFloor(static_cast<size_t>(kb) * 1024)) {
    lua_pushnil(L);
    lua_pushstring(L, "not available (development builds only)");
    return 2;
  }
  lua_pushboolean(L, 1);
  return 1;
}
// system.mac() -> "AA:BB:CC:DD:EE:FF" (the device's own WiFi MAC; fine to show, it is not a secret)
int sys_mac(lua_State* L) {
  char m[18];
  be(L).mac(m);
  lua_pushstring(L, m);
  return 1;
}

// system.reboot() -> true. Restarts the whole device (the app ends, the reader boots cold).
int sys_reboot(lua_State* L) {
  be(L).systemReboot();
  lua_pushboolean(L, 1);
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
  (void)c;
  lua_newtable(L);
  luaL_setfuncs(L, funcs, 0);
  lua_setglobal(L, name);
}

namespace {
// ---- Lazy namespaces
// Registering every namespace at start costs ~8 KB of Lua heap. Only gfx/input/app/system/print/require/load are
// always present; the rest are built the first time a script reads the global. The globals table gets a protected
// metatable whose __index does that. Consequences: pairs(_G) does not list namespaces nobody has touched yet, and a
// script cannot install its own metatable on _G ("cannot change a protected metatable").
void loadTime(lua_State* L, Ctx* c) {
  static const luaL_Reg timeFns[] = {
      {"now", time_now}, {"date", time_date}, {"sync", time_sync}, {"set", time_set}, {nullptr, nullptr}};
  regTable(L, c, "time", timeFns);
}
void loadDevice(lua_State* L, Ctx* c) {
  static const luaL_Reg devFns[] = {
      {"frontlight", dev_frontlight},   {"caps", dev_caps}, {"haptic", dev_haptic}, {"motion", dev_motion},
      {"environment", dev_environment}, {"tone", dev_tone}, {nullptr, nullptr}};
  regTable(L, c, "device", devFns);
}
void loadLed(lua_State* L, Ctx* c) {
  static const luaL_Reg ledFns[] = {
      {"count", led_count},           {"set", led_set},  {"all", led_all}, {"off", led_off},
      {"brightness", led_brightness}, {nullptr, nullptr}};
  regTable(L, c, "led", ledFns);
}
void loadCoroutine(lua_State* L, Ctx*) {
  luaL_requiref(L, LUA_COLIBNAME, luaopen_coroutine, 1);
  lua_pop(L, 1);
}
void loadUtf8(lua_State* L, Ctx*) {
  luaL_requiref(L, LUA_UTF8LIBNAME, luaopen_utf8, 1);
  lua_pop(L, 1);
}

struct LazyNs {
  const char* name;
  void (*load)(lua_State*, Ctx*);
};
// Several names share a loader (wifi+http, zip+epub): the loader defines all of its globals at once.
const LazyNs LAZY[] = {{"time", loadTime},           {"device", loadDevice},     {"led", loadLed},
                       {"fs", registerFs},           {"json", registerJson},     {"wifi", registerNet},
                       {"http", registerNet},        {"net", registerSock},      {"zip", registerZip},
                       {"epub", registerZip},        {"crypto", registerCrypto}, {"audio", registerAudio},
                       {"mic", registerMic},         {"espnow", registerEspNow}, {"ble", registerBle},
                       {"coroutine", loadCoroutine}, {"utf8", loadUtf8}};

// _G.__index(G, key): runs only for globals that do not exist yet.
int lazy_index(lua_State* L) {
  if (lua_type(L, 2) == LUA_TSTRING) {
    const char* k = lua_tostring(L, 2);
    for (const LazyNs& ns : LAZY) {
      if (strcmp(ns.name, k) != 0) continue;
      ns.load(L, ctx(L));
      lua_pushvalue(L, 2);
      lua_rawget(L, 1);  // the loader defined it (raw: no metamethod loop if it somehow did not)
      return 1;
    }
  }
  lua_pushnil(L);
  return 1;
}

void installLazy(lua_State* L) {
  lua_pushglobaltable(L);
  lua_createtable(L, 0, 2);
  lua_pushcfunction(L, lazy_index);
  lua_setfield(L, -2, "__index");
  lua_pushliteral(L, "protected");
  lua_setfield(L, -2, "__metatable");
  lua_setmetatable(L, -2);
  lua_pop(L, 1);
}

}  // namespace

void registerApi(LuaVm& vm, Backend& backend) {
  lua_State* L = vm.state();
  // Ctx must outlive the VM; it's a tiny allocation owned by the Lua state as a userdata.
  Ctx* c = static_cast<Ctx*>(lua_newuserdatauv(L, sizeof(Ctx), 0));
  c->be = &backend;
  c->vm = &vm;
  lua_setfield(L, LUA_REGISTRYINDEX, "crosslua.ctx");  // keeps the Ctx alive for the life of the state
  // cppcheck-suppress dangerousTypeCast // lua_getextraspace() is Lua's own macro, its C cast is not ours
  *static_cast<Ctx**>(lua_getextraspace(L)) = c;  // where ctx(L) finds it (also inherited by coroutines)

  static const luaL_Reg gfx[] = {{"size", gfx_size},
                                 {"clear", gfx_clear},
                                 {"pixel", gfx_pixel},
                                 {"line", gfx_line},
                                 {"rect", gfx_rect},
                                 {"text", gfx_text},
                                 {"qr", gfx_qr},
                                 {"rounded_rect", gfx_rounded_rect},
                                 {"text_width", gfx_text_width},
                                 {"line_height", gfx_line_height},
                                 {"present", gfx_present},
                                 {nullptr, nullptr}};
  static const luaL_Reg input[] = {{"poll", input_poll}, {"wait", input_wait}, {"pos", input_pos},
                                   {"key", input_key},   {"text", input_text}, {nullptr, nullptr}};
  static const luaL_Reg app[] = {
      {"sleep", app_sleep},         {"exit", app_exit},       {"name", app_name},   {"dir", app_dir},
      {"open_book", app_open_book}, {"restart", app_restart}, {"entry", app_entry}, {nullptr, nullptr}};
  static const luaL_Reg sys[] = {{"millis", sys_millis},
                                 {"heap", sys_heap},
                                 {"lua_mem", sys_lua_mem},
                                 {"battery", sys_battery},
                                 {"mac", sys_mac},
                                 {"usb", sys_usb},
                                 {"dev_floor", sys_dev_floor},
                                 {"sleep", sys_sleep},
                                 {"last_wake", sys_last_wake},
                                 {"reboot", sys_reboot},
                                 {nullptr, nullptr}};
  regTable(L, c, "gfx", gfx);
  regTable(L, c, "input", input);
  regTable(L, c, "app", app);
  {  // keep debug info (readable tracebacks) only when the developer asks: <dataDir>/debug.flag
    char flag[MAX_PATH_LEN + 40];
    snprintf(flag, sizeof(flag), "%s/debug.flag", backend.dataDir());
    vm.setStripDebug(backend.fsSize(flag) < 0);
  }
  regTable(L, c, "system", sys);
  registerGfxSaveBmp(L);
  registerGfxImage(L);
  registerRequire(L, c);
  installLazy(L);

  lua_pushcfunction(L, api_print);
  lua_setglobal(L, "print");
}

}  // namespace crosslua
