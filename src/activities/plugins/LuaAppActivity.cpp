#include "LuaAppActivity.h"

#include <GfxRenderer.h>
#include <HalMemory.h>
#include <HalPowerManager.h>
#include <HalStorage.h>
#include <Logging.h>
#include <TrustedTime.h>
#include <ArduinoJson.h>
#include <WiFi.h>
#include <ZipFile.h>

#include <algorithm>
#include <cstring>
#include <deque>
#include <vector>

#include "MappedInputManager.h"
#include "SilentRestart.h"
#include "activities/ActivityManager.h"
#include "activities/network/WifiSelectionActivity.h"
#include "fontIds.h"
#include "network/HttpDownloader.h"
#include "network/WifiPowerSaveGuard.h"
#include "lua/LuaApi.h"
#include "lua/LuaVm.h"

namespace {

constexpr const char* TAG = "LUA";

// ---- memory policy ---------------------------------------------------------
// The Lua heap is a hard cap carved out of whatever internal RAM is free when the
// app starts. RESERVE stays untouched for the framework (WiFi, SD buffers, stacks).
// 40 KB = the heap-guard floor below: the guard already refuses any allocation that would leave less, so a bigger
// reserve only wasted 16 KB of the app's budget. (Apps with the network permission check their own, bigger need.)
constexpr size_t LUA_RESERVE_BYTES = 40 * 1024;
constexpr size_t LUA_MIN_BUDGET = 24 * 1024;
constexpr size_t LUA_MAX_BUDGET = 160 * 1024;
// Hard floor of free device RAM that an allocation may never eat into (see LuaVm::setHeapGuard). On-device
// measurement: without it a table-growth stress test drove lifetime min-free heap down to 7 KB.
constexpr size_t LUA_HEAP_FLOOR = 40 * 1024;
constexpr size_t MAX_SCRIPT_BYTES = 64 * 1024;

constexpr uint32_t SLICE_MS = 25;          // max time one loop() pass spends inside Lua
constexpr uint32_t EXIT_HOLD_MS = 1000;    // hold Back this long to force-quit any app
constexpr size_t EVENT_QUEUE_MAX = 16;

}  // namespace

// ---------------------------------------------------------------------------
class LuaAppActivity::Backend final : public crosslua::Backend {
 public:
  Backend(GfxRenderer& r, MappedInputManager& in, std::string name, std::string dir)
      : r_(r), in_(in), name_(std::move(name)), dir_(std::move(dir)), dataDir_("/.crosslua/data/" + name_) {
    loadPermissions();
  }

  std::deque<const char*> events;  // string literals only (see collectInput)
  bool exitRequested = false;
  bool wifiConnectRequested = false;  // set by wifi.connect(); the activity launches the system WiFi UI
  std::string openBookPath;           // set by app.open_book(); the activity hands it to the reader

  int width() override { return r_.getScreenWidth(); }
  int height() override { return r_.getScreenHeight(); }
  void clear(bool white) override { r_.clearScreen(white ? 0xFF : 0x00); }
  void pixel(int x, int y, bool black) override { r_.drawPixel(x, y, black); }
  void line(int x0, int y0, int x1, int y1, bool black) override { r_.drawLine(x0, y0, x1, y1, black); }
  void rect(int x, int y, int w, int h, bool black, bool filled) override {
    if (w <= 0 || h <= 0) return;
    if (filled) r_.fillRect(x, y, w, h, black);
    else r_.drawRect(x, y, w, h, black);
  }
  void text(int font, int x, int y, const char* s, bool black, int style) override {
    r_.drawText(font, x, y, s, black, toStyle(style));
  }
  int textWidth(int font, const char* s, int style) override { return r_.getTextWidth(font, s, toStyle(style)); }
  int lineHeight(int font) override { return r_.getLineHeight(font); }
  int fontId(const char* n) override {
    struct F {
      const char* name;
      int id;
    };
    static const F fonts[] = {{"ui", UI_10_FONT_ID},          {"ui12", UI_12_FONT_ID},
                              {"small", SMALL_FONT_ID},       {"sans12", NOTOSANS_12_FONT_ID},
                              {"sans14", NOTOSANS_14_FONT_ID}, {"sans16", NOTOSANS_16_FONT_ID},
                              {"sans18", NOTOSANS_18_FONT_ID}};
    for (const auto& f : fonts)
      if (!strcmp(f.name, n)) return f.id;
    return 0;  // 0 = unknown (real IDs are hashes and can be negative)
  }
  void present(int mode) override {
    r_.displayBuffer(mode == 2   ? HalDisplay::FULL_REFRESH
                     : mode == 1 ? HalDisplay::HALF_REFRESH
                                 : HalDisplay::FAST_REFRESH);
  }

  const char* popEvent() override {
    if (events.empty()) return nullptr;
    const char* e = events.front();
    events.pop_front();
    return e;
  }

  uint32_t millis() override { return ::millis(); }
  size_t freeHeap() override { return HalMemory::getInternalHeap().freeBytes; }
  size_t freeHeapQuick() override { return ESP.getFreeHeap(); }  // O(1); getInternalHeap() also walks for the largest block
  size_t minFreeHeap() override { return HalMemory::getInternalHeap().minFreeBytes; }
  int battery() override { return powerManager.getBatteryPercentage(); }
  int64_t epochNow() override { return trustedtime::trustedNow(); }
  bool localDate(int64_t epoch, int out[8]) override {
    const time_t t = static_cast<time_t>(epoch);
    struct tm lt;
    if (!localtime_r(&t, &lt)) return false;
    out[0] = lt.tm_year + 1900;
    out[1] = lt.tm_mon + 1;
    out[2] = lt.tm_mday;
    out[3] = lt.tm_hour;
    out[4] = lt.tm_min;
    out[5] = lt.tm_sec;
    out[6] = lt.tm_wday + 1;
    out[7] = lt.tm_yday + 1;
    return true;
  }
  void log(const char* msg) override { LOG_INF(TAG, "[%s] %s", name_.c_str(), msg); }
  const char* appName() override { return name_.c_str(); }
  const char* appDir() override { return dir_.c_str(); }
  const char* dataDir() override { return dataDir_.c_str(); }
  const char* libDir() override { return "/.crosslua/lib"; }
  void requestExit() override { exitRequested = true; }

  // --- network ------------------------------------------------------------------------------------------------
  // An app may only use the network if its manifest.json says so: {"permissions": ["network"]}.
  bool netAllowed() override { return net_; }
  bool wifiConnected() override { return WiFi.status() == WL_CONNECTED; }
  void wifiRequestConnect() override { wifiConnectRequested = true; }
  bool wifiInfo(char* ssid, size_t ssidCap, char* ip, size_t ipCap, int* rssi) override {
    if (WiFi.status() != WL_CONNECTED) return false;
    snprintf(ssid, ssidCap, "%s", WiFi.SSID().c_str());
    snprintf(ip, ipCap, "%s", WiFi.localIP().toString().c_str());
    *rssi = WiFi.RSSI();
    return true;
  }
  void wifiOff() override {
    WiFi.disconnect(false);
    WiFi.mode(WIFI_OFF);
  }
  size_t largestFreeBlock() override { return HalMemory::getInternalHeap().largestBlockBytes; }

  // --- library: sd: scope, zip, open_book --------------------------------------------------------------------------
  // "permissions": ["library"] = read-only access to the SD card outside the app folder (never hidden paths).
  bool libraryAllowed() override { return lib_; }
  // Inflating needs ~45 KB transient (ZipFile's own docs warn about it): refuse instead of aborting mid-way.
  static constexpr size_t ZIP_RESERVE = 48 * 1024;
  int zipList(const char* path, crosslua::Backend::ZipEntryInfo* out, int maxEntries, int* total, char* err,
              size_t errCap) override {
    const std::string p(path);
    ZipFile zip(p);
    int n = 0;
    *total = 0;
    const bool ok = zip.enumerateFileEntries([&](std::string_view name, uint32_t, uint32_t) {
      (*total)++;
      if (n < maxEntries && name.size() < sizeof(out[0].name)) {
        memcpy(out[n].name, name.data(), name.size());
        out[n].name[name.size()] = '\0';
        out[n].size = 0;
        n++;
      }
    });
    if (!ok) {
      snprintf(err, errCap, "cannot open zip (missing, not a zip, or damaged)");
      return -1;
    }
    if (zip.open()) {
      for (int i = 0; i < n; i++) {
        size_t sz = 0;
        if (zip.getInflatedFileSize(out[i].name, &sz)) out[i].size = static_cast<uint32_t>(sz);
      }
      zip.close();
    }
    return n;
  }
  bool zipRead(const char* path, const char* name, size_t maxBytes, char** data, size_t* len, char* err,
               size_t errCap) override {
    *data = nullptr;
    *len = 0;
    const std::string p(path);
    ZipFile zip(p);
    size_t sz = 0;
    if (!zip.open()) {
      snprintf(err, errCap, "cannot open zip (missing, not a zip, or damaged)");
      return false;
    }
    const bool found = zip.getInflatedFileSize(name, &sz);
    zip.close();
    if (!found) {
      snprintf(err, errCap, "no such entry");
      return false;
    }
    if (sz > maxBytes) {
      snprintf(err, errCap, "entry is %u bytes, over max_bytes (%u)", (unsigned)sz, (unsigned)maxBytes);
      return false;
    }
    const auto h = HalMemory::getInternalHeap();
    if (h.freeBytes < sz + ZIP_RESERVE || h.largestBlockBytes < sz + 4096) {
      snprintf(err, errCap, "not enough free RAM to unzip (free %uK, need %uK)", (unsigned)(h.freeBytes / 1024),
               (unsigned)((sz + ZIP_RESERVE) / 1024));
      return false;
    }
    size_t got = 0;
    uint8_t* d = zip.readFileToMemory(name, &got, false);
    if (!d) {
      snprintf(err, errCap, "cannot read entry (unsupported compression or damaged)");
      return false;
    }
    *data = reinterpret_cast<char*>(d);  // malloc'd by ZipFile; the binding free()s it
    *len = got;
    return true;
  }
  bool openBook(const char* absPath) override {
    if (!Storage.exists(absPath)) return false;
    openBookPath = absPath;
    return true;
  }

  bool httpRequest(const crosslua::Backend::HttpRequest& rq, crosslua::Backend::HttpResult& rs) override {
    auto fail = [&](const char* fmt, auto... a) {
      snprintf(rs.error, sizeof(rs.error), fmt, a...);
      return false;
    };
    if (WiFi.status() != WL_CONNECTED) return fail("wifi is not connected (call wifi.connect() first)");
    const bool tls = !strncasecmp(rq.url, "https://", 8);
    if (tls) {  // the TLS session + ~17 KB record buffer need real, contiguous RAM (see HttpDownloader.h)
      const auto h = HalMemory::getInternalHeap();
      if (h.freeBytes < HttpDownloader::MIN_TLS_FREE_HEAP || h.largestBlockBytes < HttpDownloader::MIN_TLS_MAX_ALLOC)
        return fail("not enough free RAM for TLS (free %u, largest %u): free memory first", (unsigned)h.freeBytes,
                    (unsigned)h.largestBlockBytes);
    }
    std::vector<HttpDownloader::Header> hdrs;
    for (int i = 0; i < rq.headerCount; i++) hdrs.emplace_back(rq.headers[i].name, rq.headers[i].value);

    bool cancelled = false;
    auto pollCancel = [&]() {  // the Lua app is blocked in this call, so pump the buttons ourselves: Back cancels
      in_.update(true);
      if (in_.wasPressed(MappedInputManager::Button::Back) || in_.isPressed(MappedInputManager::Button::Back)) cancelled = true;  // a quick tap counts
      return cancelled;
    };
    auto finishCancel = [&]() {
      for (int i = 0; i < 200 && in_.isPressed(MappedInputManager::Button::Back); i++) {  // swallow the release so the
        delay(10);                                                                          // app never sees this Back
        in_.update(true);
      }
      events.clear();
      return fail("cancelled");
    };

    WifiPowerSaveGuard psGuard;
    const std::string url(rq.url);
    if (!strcmp(rq.method, "POST")) {
      std::string out;
      int st = 0;
      const bool ok = HttpDownloader::postForm(url, std::string(rq.body ? rq.body : "", rq.bodyLen), out, &st);
      (void)ok;
      rs.status = st;
      if (st == 0) return fail("request failed (no response)");
      rs.bodyLen = std::min(out.size(), rq.maxBody);
      rs.bytes = rs.bodyLen;
      rs.body = static_cast<char*>(malloc(rs.bodyLen ? rs.bodyLen : 1));
      if (!rs.body) return fail("out of memory");
      memcpy(rs.body, out.data(), rs.bodyLen);
      return true;
    }
    if (rq.savePath) {
      std::string dest(rq.savePath);
      const size_t slash = dest.rfind('/');
      if (slash != std::string::npos && slash > 0) Storage.ensureDirectoryExists(dest.substr(0, slash).c_str());
      const auto err = HttpDownloader::downloadToFile(
          url, dest, [&](size_t done, size_t) { rs.bytes = done; pollCancel(); }, &cancelled, "", "", hdrs, false);
      rs.status = HttpDownloader::lastStatus();
      if (cancelled) return finishCancel();
      switch (err) {
        case HttpDownloader::OK:
          return true;
        case HttpDownloader::UNAUTHORIZED:
          return true;  // a real response (401/403): status says so, nothing was saved
        case HttpDownloader::FILE_ERROR:
          return fail("cannot write the file (SD card full or not writable)");
        case HttpDownloader::ABORTED:
          return fail("aborted");
        default:
          if (rs.status > 0) return true;  // non-2xx answer: nothing saved
          return fail("download failed (no response)");
      }
    }
    // in-memory GET
    HttpDownloader::FetchOptions opt;
    opt.headers = hdrs;
    int st = 0;
    opt.statusOut = &st;
    char* buf = nullptr;
    size_t n = 0, cap = 0;
    bool tooBig = false, oom = false;
    HttpDownloader::fetchUrl(
        url,
        [&](const uint8_t* d, size_t len) {
          if (pollCancel()) return false;
          if (n + len > rq.maxBody) {
            tooBig = true;
            return false;
          }
          if (n + len > cap) {
            size_t nc = cap ? cap * 2 : 2048;
            while (nc < n + len) nc *= 2;
            if (nc > rq.maxBody) nc = rq.maxBody;
            char* nb = static_cast<char*>(realloc(buf, nc));
            if (!nb) {
              oom = true;
              return false;
            }
            buf = nb;
            cap = nc;
          }
          memcpy(buf + n, d, len);
          n += len;
          return true;
        },
        opt);
    rs.status = st;
    if (cancelled) {
      free(buf);
      return finishCancel();
    }
    if (tooBig) {
      free(buf);
      return fail("response larger than max_body (%u bytes): use save_to", (unsigned)rq.maxBody);
    }
    if (oom) {
      free(buf);
      return fail("out of memory while reading the response");
    }
    if (st == 0) {
      free(buf);
      return fail("request failed (no response)");
    }
    rs.body = buf;
    rs.bodyLen = rs.bytes = n;
    return true;
  }

  // --- storage. Paths arrive pre-sandboxed (app:/data:/lib: scopes) from the API layer. ---
  int64_t fsSize(const char* path) override {
    HalFile f = Storage.open(path);
    if (!f) return -1;
    if (f.isDirectory()) return -2;
    return static_cast<int64_t>(f.fileSize());
  }
  bool fsReadInto(const char* path, void* dst, size_t n, size_t offset) override {
    HalFile f;
    if (!Storage.openFileForRead(TAG, path, f)) return false;
    if (offset && !f.seek(offset)) return false;
    return f.read(dst, n) == static_cast<int>(n);
  }
  bool fsWriteAt(const char* path, size_t offset, const void* data, size_t n) override {
    HalFile f = Storage.open(path, O_RDWR);
    if (!f) return false;
    if (!f.seek(offset)) return false;
    const bool ok = n == 0 || f.write(data, n) == n;
    f.flush();
    return ok;
  }
  bool fsWrite(const char* path, const void* data, size_t n, bool append) override {
    if (append) {
      HalFile f = Storage.open(path, O_WRONLY | O_CREAT | O_APPEND);
      if (!f) return false;
      const bool ok = f.write(data, n) == n;
      f.flush();
      return ok;
    }
    // Atomic replace: a power cut mid-save leaves the previous file intact.
    std::string tmp = std::string(path) + ".~tmp";
    {
      HalFile f = Storage.open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC);
      if (!f) return false;
      const bool ok = n == 0 || f.write(data, n) == n;
      f.flush();
      if (!ok) {
        f.close();
        Storage.remove(tmp.c_str());
        return false;
      }
    }
    if (Storage.replaceFile(tmp.c_str(), path)) return true;
    Storage.remove(tmp.c_str());
    return false;
  }
  bool fsMkdir(const char* path) override { return Storage.exists(path) ? fsSize(path) == -2 : Storage.mkdir(path, true); }
  bool fsRemove(const char* path) override { return fsSize(path) == -2 ? Storage.rmdir(path) : Storage.remove(path); }
  bool fsListBegin(const char* path) override {
    listDir_ = Storage.open(path);
    return listDir_ && listDir_.isDirectory();
  }
  bool fsListNext(char* name, size_t cap, bool* isDir) override {
    for (;;) {
      HalFile e = listDir_.openNextFile();
      if (!e) return false;
      if (e.getName(name, cap) == 0) continue;
      if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) continue;
      const size_t len = strlen(name);
      if (len > 5 && !strcmp(name + len - 5, ".~tmp")) continue;  // half-written atomic save; hide it
      *isDir = e.isDirectory();
      return true;
    }
  }
  void fsListEnd() override { listDir_.close(); }

 private:
  static EpdFontFamily::Style toStyle(int s) {
    return s == 3 ? EpdFontFamily::BOLD_ITALIC : s == 1 ? EpdFontFamily::BOLD
                                                 : s == 2 ? EpdFontFamily::ITALIC : EpdFontFamily::REGULAR;
  }
  GfxRenderer& r_;
  std::string name_;
  void loadPermissions() {
    std::string json;
    if (!Storage.readFileToString(TAG, dir_ + "/manifest.json", 4096, json)) return;
    JsonDocument doc;
    if (deserializeJson(doc, json) != DeserializationError::Ok) return;
    for (JsonVariantConst p : doc["permissions"].as<JsonArrayConst>())
      if (p.is<const char*>() && !strcmp(p.as<const char*>(), "network")) net_ = true;
      else if (p.is<const char*>() && !strcmp(p.as<const char*>(), "library")) lib_ = true;
  }

  MappedInputManager& in_;
  bool net_ = false;
  bool lib_ = false;
  std::string dir_;
  std::string dataDir_;
  HalFile listDir_;
};

// ---------------------------------------------------------------------------
LuaAppActivity::LuaAppActivity(GfxRenderer& renderer, MappedInputManager& mappedInput, std::string appName,
                               std::string appDir)
    : Activity("LuaApp", renderer, mappedInput), appName_(std::move(appName)), appDir_(std::move(appDir)) {}

LuaAppActivity::~LuaAppActivity() = default;

void LuaAppActivity::logMemory(const char* when) const {
  const auto h = HalMemory::getInternalHeap();
  LOG_INF(TAG, "%s: lua used=%u peak=%u budget=%u | heap free=%u min=%u largest=%u", when,
          vm_ ? static_cast<unsigned>(vm_->usedBytes()) : 0u, vm_ ? static_cast<unsigned>(vm_->peakBytes()) : 0u,
          vm_ ? static_cast<unsigned>(vm_->budgetBytes()) : 0u, static_cast<unsigned>(h.freeBytes),
          static_cast<unsigned>(h.minFreeBytes), static_cast<unsigned>(h.largestBlockBytes));
}

void LuaAppActivity::onEnter() {
  Activity::onEnter();
  RenderLock lock;

  // Start from a quiet radio. Screens earlier in the same menu (the Plugin Hub, a book sync...) can leave WiFi up, which
  // holds ~56 KB and would make every Lua app fail to start with "free RAM too low". An app that wants WiFi asks for it.
  if (WiFi.getMode() != WIFI_MODE_NULL) {
    LOG_INF(TAG, "radio was left on: switching it off before the app starts");
    WiFi.disconnect(false);
    WiFi.mode(WIFI_OFF);
    delay(30);
  }
  backend_.reset(new (std::nothrow) Backend(renderer, mappedInput, appName_, appDir_));
  vm_.reset(new (std::nothrow) crosslua::LuaVm());
  if (!backend_ || !vm_) {
    showError("Out of memory", "Could not start the Lua runtime.");
    return;
  }

  const auto heap = HalMemory::getInternalHeap();
  logMemory("start");
  if (heap.freeBytes < LUA_RESERVE_BYTES + LUA_MIN_BUDGET) {
    showError("Not enough memory", "Free RAM too low to start a Lua app (" + std::to_string(heap.freeBytes) +
                                       " bytes free).");
    return;
  }
  const size_t budget = std::clamp(heap.freeBytes - LUA_RESERVE_BYTES, LUA_MIN_BUDGET, LUA_MAX_BUDGET);

  const std::string path = appDir_ + "/main.lua";
  std::string src;
  if (!Storage.readFileToString(TAG, path, MAX_SCRIPT_BYTES, src)) {
    showError("Cannot load app", path + " is missing, empty, or larger than " + std::to_string(MAX_SCRIPT_BYTES) +
                                     " bytes.");
    return;
  }
  if (!vm_->open(budget)) {
    showError("Out of memory", "Could not create the Lua state.");
    return;
  }
  vm_->setHeapGuard([](void* ud) -> size_t { return static_cast<Backend*>(ud)->freeHeapQuick(); }, backend_.get(),
                    LUA_HEAP_FLOOR);
  crosslua::registerApi(*vm_, *backend_);
  if (!vm_->load(path.c_str(), src.data(), src.size())) {
    showError("Script error", vm_->error());
    return;
  }
  // Compiled; the source text is no longer needed. Release it before the app runs.
  std::string().swap(src);
  vm_->gc();
  logMemory("loaded");
  renderer.clearScreen();
  lastGcMs_ = millis();
}

void LuaAppActivity::onExit() {
  logMemory("exit");
  vm_.reset();  // lua_close: frees the entire Lua heap
  backend_.reset();
  logMemory("freed");
  // Hand the picker underneath a clean waveform after an app scribbled on the panel.
  renderer.promoteNextRefresh(HalDisplay::HALF_REFRESH);
  Activity::onExit();
  // Same rule as every other WiFi screen: after the radio (and possibly TLS) ran, the heap is fragmented, so drop the
  // connection and reboot silently into Home on a pristine heap. Apps that never touched WiFi are unaffected.
  if (WiFi.getMode() != WIFI_MODE_NULL) {
    LOG_INF(TAG, "wifi was used: silent restart to defragment the heap");
    WiFi.disconnect(false);
    delay(30);
    silentRestart();
  }
}

void LuaAppActivity::launchWifi() {
  WiFi.mode(WIFI_STA);
  startActivityForResult(std::make_unique<WifiSelectionActivity>(renderer, mappedInput), [this](const ActivityResult& r) {
    const bool ok = !r.isCancelled;
    LOG_INF(TAG, "wifi.connect -> %s", ok ? "connected" : "not connected");
    renderer.clearScreen();
    if (vm_ && vm_->status() == crosslua::Status::Waiting) {
      vm_->resume(ok ? "wifi:ok" : "wifi:fail");
      armWait();
    }
  });
}

void LuaAppActivity::armWait() {
  if (vm_ && vm_->status() == crosslua::Status::Waiting)
    waitDeadline_ = vm_->timeoutMs() >= 0 ? millis() + static_cast<uint32_t>(vm_->timeoutMs()) : 0;
}

void LuaAppActivity::leave() {
  if (leaving_) return;
  leaving_ = true;
  finish();
}

void LuaAppActivity::showError(const std::string& title, const std::string& detail) {
  LOG_ERR(TAG, "%s: %s", title.c_str(), detail.c_str());
  errorShown_ = true;
  vm_.reset();  // the app is dead; release its memory before drawing
  renderer.clearScreen();
  const int fh = renderer.getLineHeight(UI_10_FONT_ID);
  const int sh = renderer.getLineHeight(SMALL_FONT_ID);
  const int w = renderer.getScreenWidth() - 40;
  renderer.drawText(UI_12_FONT_ID, 20, 20, title.c_str(), true, EpdFontFamily::BOLD);
  int y = 20 + fh + 24;
  renderer.drawText(SMALL_FONT_ID, 20, y, appName_.c_str(), true);
  y += sh + 8;
  // Hard-wrap the detail (error text + traceback) to the screen; ASCII-safe cut points only.
  std::string line;
  auto flush = [&]() {
    if (y + sh < renderer.getScreenHeight() - 40) renderer.drawText(SMALL_FONT_ID, 20, y, line.c_str(), true);
    y += sh;
    line.clear();
  };
  for (char c : detail) {
    if (c == '\n') {
      flush();
      continue;
    }
    if (c == '\t') c = ' ';
    const bool contByte = (static_cast<unsigned char>(c) & 0xC0) == 0x80;
    if (!contByte && !line.empty() && renderer.getTextWidth(SMALL_FONT_ID, (line + c).c_str()) > w) flush();
    line += c;
  }
  if (!line.empty()) flush();
  renderer.drawText(SMALL_FONT_ID, 20, renderer.getScreenHeight() - sh - 10, "Back: return", true);
  renderer.displayBuffer(HalDisplay::HALF_REFRESH);
}

void LuaAppActivity::collectInput() {
  using B = MappedInputManager::Button;
  auto push = [&](const char* name) {
    if (backend_ && backend_->events.size() < EVENT_QUEUE_MAX) backend_->events.push_back(name);
  };
  // Force-quit gesture first: it suppresses the matching release so Back never reaches the app.
  if (mappedInput.wasLongPressed(B::Back, EXIT_HOLD_MS)) {
    LOG_INF(TAG, "force quit (Back held)");
    leave();
    return;
  }
  if (mappedInput.wasReleased(B::Back)) push("back");
  if (mappedInput.wasReleased(B::Confirm)) push("confirm");
  if (mappedInput.wasReleased(B::Left)) push("left");
  if (mappedInput.wasReleased(B::Right)) push("right");
  if (mappedInput.wasReleased(B::Up)) push("up");
  if (mappedInput.wasReleased(B::Down)) push("down");
}

void LuaAppActivity::step() {
  using crosslua::Status;
  const uint32_t start = millis();
  while (millis() - start < SLICE_MS) {
    if (!backend_->openBookPath.empty()) {  // app.open_book(): the reader replaces this app (like Home's "open recent")
      std::string path = std::move(backend_->openBookPath);
      LOG_INF(TAG, "open_book: %s", path.c_str());
      leaving_ = true;
      activityManager.goToReader(std::move(path));
      return;
    }
    if (backend_->exitRequested) return leave();
    switch (vm_->status()) {
      case Status::Preempted:
        vm_->resume();
        armWait();
        break;
      case Status::Waiting: {
        if (backend_->wifiConnectRequested) {  // wifi.connect(): hand the screen to the system's WiFi flow
          backend_->wifiConnectRequested = false;
          return launchWifi();
        }
        if (vm_->wakesOnEvent()) {
          if (const char* e = backend_->popEvent()) {
            vm_->resume(e);
            armWait();
            break;
          }
        }
        if (vm_->timeoutMs() >= 0 && static_cast<int32_t>(millis() - waitDeadline_) >= 0) {
          vm_->resume(nullptr);
          armWait();
          break;
        }
        // Genuinely idle: tidy the Lua heap now and then, then give the CPU back.
        if (millis() - lastGcMs_ > 2000) {
          vm_->gc();
          lastGcMs_ = millis();
        }
        return;
      }
      case Status::Finished:
        return leave();
      case Status::Error:
        return showError("Script error", vm_->error());
      case Status::Idle:
        return;
    }
  }
}

void LuaAppActivity::loop() {
  Activity::loop();
  if (leaving_) return;
  if (errorShown_) {
    if (mappedInput.wasReleased(MappedInputManager::Button::Back) ||
        mappedInput.wasReleased(MappedInputManager::Button::Confirm))
      leave();
    return;
  }
  if (!vm_ || !backend_) return leave();
  collectInput();
  if (leaving_) return;
  step();
}
