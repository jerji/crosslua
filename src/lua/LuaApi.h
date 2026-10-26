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

  // --- library: sd: scope, zip, open_book (see LuaZip.cpp / LuaFs.cpp) ------------------------------------------
  virtual bool libraryAllowed() = 0;  // the app's manifest declares "library" (read-only access to the SD card)
  struct ZipEntryInfo {
    char name[96];
    uint32_t size;  // uncompressed bytes
  };
  // Fills up to maxEntries entries; *total = entries in the archive. Returns the number filled, or -1 with err set.
  // EPUB title/author via the firmware's own metadata-only OPF parse (Epub::loadMetadata). Strings may be cut at the cap.
  virtual bool epubMeta(const char* path, char* title, size_t titleCap, char* author, size_t authorCap, char* err,
                        size_t errCap) = 0;
  virtual int zipList(const char* path, ZipEntryInfo* out, int maxEntries, int* total, char* err, size_t errCap) = 0;
  // Inflates one entry into a malloc'd buffer (caller free()s). Refuses entries over maxBytes.
  virtual bool zipRead(const char* path, const char* name, size_t maxBytes, char** data, size_t* len, char* err,
                       size_t errCap) = 0;
  // Ask the host to open `absPath` in the reader (replaces the app). false = no such file.
  virtual bool openBook(const char* absPath) = 0;
  // app.restart(entry): ask the host to tear this VM down and start `entry` (a .lua file in the app folder) in a fresh one.
  // --- storage grants: manifest "storage": {"read": [...], "write": [...]}. Only grants the user APPROVED are visible
  // here (an unapproved request reads as zero grants). Paths are normalised, relative, never hidden; "" = the whole card.
  virtual void randomBytes(uint8_t* out, size_t n) = 0;  // hardware RNG

  // --- what this board has (CrossPoint runs on many boards: apps adapt, they do not guess the model) ---------------
  struct DeviceCaps {
    bool touch = false, haptic = false, frontlight = false, warmlight = false, color = false, audio = false,
         bleKeyboard = false, usbMsc = false, imu = false, gyro = false, rtc = false, tempHumidity = false,
         buzzer = false, mic = false, led = false, tls13 = false;
  };
  virtual void deviceCaps(DeviceCaps* out) = 0;
  virtual bool usbConnected() = 0;
  // One vibration pulse. false: no motor on this board, or the user turned vibration off.
  virtual bool hapticPulse(int ms, int strength) = 0;
  // Position (screen pixels) of the touch event the last popEvent() returned; false for button events / empty polls.
  virtual bool eventPos(int* x, int* y) = 0;
  // input.text(): ask the host to show the system keyboard. The script is parked; the host resumes it with
  // "text:ok:<text>" or "text:cancel". mode: 0 text, 1 password, 2 url.
  virtual void textRequest(const char* title, const char* initial, int maxLen, int mode) = 0;

  // --- sensors / outputs (each is a no-op or `false` on boards without the hardware) -----------------------------------
  struct Motion {
    float ax, ay, az;  // acceleration, g
    float gx, gy, gz;  // angular rate, deg/s (zero on accelerometer-only parts)
    bool gyro;
  };
  enum class SensorStatus : uint8_t { Ok, Absent, ReadFailed };
  virtual SensorStatus motionRead(Motion* out) = 0;
  virtual SensorStatus envRead(float* tempC, float* humidityPct) = 0;
  virtual bool toneStart(int freqHz, int ms) = 0;  // false: no buzzer
  virtual bool toneStop() = 0;                     // false: no buzzer
  virtual int ledCount() = 0;                      // 0: no LEDs
  virtual void ledSet(int index0, int r, int g, int b) = 0;  // index0 -1 = every LED; shown immediately
  virtual void ledOff() = 0;
  virtual void ledBrightness(int v) = 0;
  virtual int grantCount() = 0;
  virtual const char* grantPath(int i, bool* write) = 0;
  virtual bool requestRestart(const char* entry) = 0;
  virtual const char* entryName() = 0;  // the script this VM was started from ("main.lua" by default)

  // --- small device/network/time extensions (docs/lua/API.md v0.6) ----------------------------------------------
  struct WifiScanInfo {
    char ssid[33];
    int rssi;
    bool encrypted;
  };
  // Blocking scan (a few seconds). Fills up to max entries, *total = networks found. -1 with err on failure.
  virtual int wifiScan(WifiScanInfo* out, int maxEntries, int* total, char* err, size_t errCap) = 0;
  // Blocking SNTP over the current WiFi connection. false + err when it fails or no network is up.
  virtual bool timeSync(int timeoutMs, char* err, size_t errCap) = 0;
  // Force the device wall clock to a UTC epoch (a manual fallback when SNTP is not an option).
  virtual bool timeSet(int64_t epoch) = 0;
  // Rename/move within the app's data: scope (LuaFs resolves and scopes; paths arrive absolute).
  virtual bool fsRename(const char* from, const char* to, char* err, size_t errCap) = 0;
  virtual void mac(char out[18]) = 0;  // "AA:BB:CC:DD:EE:FF"
  // Draws a QR code for `text` into the current frame, fitted into a side x side box. false when it cannot fit.
  virtual bool drawQr(const char* text, int x, int y, int side) = 0;
  // Frontlight. get() false when the board has none. On set, -1 means "leave unchanged".
  virtual bool frontlightGet(bool* on, int* brightness, int* warmth) = 0;
  virtual void frontlightSet(int brightness, int warmth, int on) = 0;
  // Raw DEFLATE (zlib=false) or zlib-wrapped (zlib=true) inflate into a malloc'd buffer the caller free()s.
  // Input up to 64 KB, output capped at maxOut bytes; refuses anything bigger.
  virtual bool inflate(const char* data, size_t n, bool zlib, size_t maxOut, char** out, size_t* outLen, char* err,
                       size_t errCap) = 0;
  // Outline (filled=false) or filled rounded rectangle.
  virtual void drawRoundedRect(int x, int y, int w, int h, int radius, bool black, bool filled) = 0;
  // Decode a PNG/JPEG (absolute SD path) into the CURRENT frame, fitted (never upscaled) and centred in the box
  // x,y,maxW,maxH. Reports the drawn size. false + err on failure (missing/corrupt/too big/not enough RAM).
  virtual bool drawImage(const char* absPath, int x, int y, int maxW, int maxH, int* outW, int* outH, char* err,
                         size_t errCap) = 0;
};

// Registers print + gfx/input/app/system tables into vm.state(). Call after open(), before load().
void registerApi(LuaVm& vm, Backend& backend);

}  // namespace crosslua
