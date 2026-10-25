#pragma once
// Lua-facing API (gfx, input, app, system, print). Talks to the world only via
// Backend, so the same bindings run on the device (FirmwareBackend) and in
// host tests (mock backend).
//
// RULE for binding code: lua_error()/luaL_check*() longjmp. Never hold an
// object with a destructor (std::string, vector, RAII locks) across them.

#include <cstddef>
#include <cstdint>

namespace crosslua {

class LuaVm;

class Backend {
 public:
  virtual ~Backend() = default;

  // --- display -------------------------------------------------------------
  virtual int width() = 0;
  virtual int height() = 0;
  virtual void clear(bool white) = 0;
  virtual void pixel(int x, int y, bool black) = 0;
  virtual void line(int x0, int y0, int x1, int y1, bool black) = 0;
  virtual void rect(int x, int y, int w, int h, bool black, bool filled) = 0;
  // `font` comes from fontId(); style bit0 = bold, bit1 = italic.
  virtual void text(int font, int x, int y, const char* s, bool black, int style) = 0;
  virtual int textWidth(int font, const char* s, int style) = 0;
  virtual int lineHeight(int font) = 0;
  // Resolve a font name ("ui", "ui12", "small", "sans12".."sans18"); -1 if unknown.
  virtual int fontId(const char* name) = 0;
  // mode: 0 = fast, 1 = half, 2 = full (clears ghosting).
  virtual void present(int mode) = 0;

  // --- input ---------------------------------------------------------------
  // Next queued button event ("back","confirm","left","right","up","down","power"),
  // or nullptr when empty.
  virtual const char* popEvent() = 0;

  // --- system --------------------------------------------------------------
  virtual uint32_t millis() = 0;
  virtual size_t freeHeap() = 0;
  virtual size_t minFreeHeap() = 0;
  virtual int battery() = 0;  // percent, or -1
  virtual void log(const char* msg) = 0;

  // --- app -----------------------------------------------------------------
  virtual const char* appName() = 0;
  virtual const char* appDir() = 0;
  virtual void requestExit() = 0;
};

// Registers print + gfx/input/app/system tables into vm.state(). Call after open(), before load().
void registerApi(LuaVm& vm, Backend& backend);

}  // namespace crosslua
