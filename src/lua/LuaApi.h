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
  // Resolve a font name ("ui", "ui12", "small", "sans12".."sans18"). Returns 0 if unknown: font IDs are
  // hashes and may be NEGATIVE, so only 0 (CrossPoint's own "not found" sentinel) means failure.
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
  // Cheap free-RAM read for the allocator guard (runs on every growing allocation); defaults to freeHeap().
  virtual size_t freeHeapQuick() { return freeHeap(); }
  virtual size_t minFreeHeap() = 0;
  virtual int battery() = 0;  // percent, or -1
  // Wall clock. epochNow() = UTC seconds, or 0 when the clock is not trustworthy (never synced / no RTC).
  virtual int64_t epochNow() = 0;
  // Local broken-down time for `epoch` -> out[0..7] = year, month(1-12), day(1-31), hour, min, sec, wday(1=Sunday), yday(1-366).
  virtual bool localDate(int64_t epoch, int out[8]) = 0;
  virtual void log(const char* msg) = 0;

  // --- storage ---------------------------------------------------------------
  // Absolute SD paths only. Sandboxing/validation happens in the API layer, never here.
  // Rule: no callbacks into Lua from these (a lua_error would longjmp over backend frames).
  virtual int64_t fsSize(const char* path) = 0;  // bytes; -1 = missing; -2 = directory
  virtual bool fsReadInto(const char* path, void* dst, size_t n, size_t offset) = 0;  // exactly n bytes from offset
  virtual bool fsWrite(const char* path, const void* data, size_t n, bool append) = 0;  // atomic unless append
  // In-place write at `offset` (<= file size; may extend the file). NOT atomic: meant for small fixed-size records.
  virtual bool fsWriteAt(const char* path, size_t offset, const void* data, size_t n) = 0;
  virtual bool fsMkdir(const char* path) = 0;   // recursive; ok if it exists
  virtual bool fsRemove(const char* path) = 0;  // file or empty directory
  // One iterator at a time; fsListBegin() closes any previous one.
  virtual bool fsListBegin(const char* path) = 0;
  virtual bool fsListNext(char* name, size_t cap, bool* isDir) = 0;  // false at end
  virtual void fsListEnd() = 0;

  // --- app -----------------------------------------------------------------
  virtual const char* appName() = 0;
  virtual const char* appDir() = 0;   // read-only app files, e.g. /plugins/foo
  virtual const char* dataDir() = 0;  // read/write saves, e.g. /.crosslua/data/foo
  virtual const char* libDir() = 0;   // shared read-only Lua libraries, e.g. /.crosslua/lib
  virtual void requestExit() = 0;

  // --- network (see LuaNet.cpp) --------------------------------------------
  // All plain-old-data on purpose: bindings must not hold C++ objects across a Lua error.
  struct HttpHeader {
    const char* name;
    const char* value;
  };
  struct HttpRequest {
    const char* method;  // "GET" or "POST" (POST = application/x-www-form-urlencoded body)
    const char* url;
    const HttpHeader* headers;
    int headerCount;
    const char* body;
    size_t bodyLen;
    const char* savePath;  // absolute SD path to stream the response to, or nullptr = return it in memory
    size_t maxBody;        // in-memory response cap (bytes)
  };
  struct HttpResult {
    int status = 0;            // final HTTP status, 0 when no response arrived
    char* body = nullptr;      // malloc'd by the backend, freed by the caller; null in save mode
    size_t bodyLen = 0;
    size_t bytes = 0;          // bytes received (save mode: bytes written)
    char error[96] = {0};      // set when the call failed (no/aborted response)
  };
  virtual bool netAllowed() = 0;  // the app's manifest declares "network"
  virtual bool wifiConnected() = 0;
  // Ask the system to bring WiFi up (it may show its own network picker). Non-blocking: the script is parked and
  // resumed with "wifi:ok" / "wifi:fail" once the system UI has finished.
  virtual void wifiRequestConnect() = 0;
  virtual bool wifiInfo(char* ssid, size_t ssidCap, char* ip, size_t ipCap, int* rssi) = 0;  // false when not connected
  virtual void wifiOff() = 0;
  // Blocking (the device's own screens do the same). true = a response arrived (res.status set), false = res.error set.
  virtual bool httpRequest(const HttpRequest& req, HttpResult& res) = 0;
  virtual size_t largestFreeBlock() = 0;
};

// Registers print + gfx/input/app/system tables into vm.state(). Call after open(), before load().
void registerApi(LuaVm& vm, Backend& backend);

}  // namespace crosslua
