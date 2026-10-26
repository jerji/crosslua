#include "LuaAppActivity.h"

#include <BoardConfig.h>
#include <Buzzer.h>
#include <EnvironmentSensor.h>
#include <Epub.h>
#include <GfxRenderer.h>
#include <Imu.h>
#include <LedManager.h>
#include <HalMemory.h>
#include <HalPowerManager.h>
#include <HalStorage.h>
#include <Logging.h>
#include <TrustedTime.h>
#include <esp_mac.h>
#include <esp_random.h>
#include <sys/time.h>
#include <InflateReader.h>
#include <ArduinoJson.h>
#include <WiFi.h>
#include <ZipFile.h>

#include <algorithm>
#include <cstring>
#include <deque>
#include <vector>

#include <Memory.h>

#include <Bitmap.h>

#include "Epub/converters/ImageDecoderFactory.h"
#include "activities/util/ConfirmationActivity.h"
#include "MappedInputManager.h"
#include "SilentRestart.h"
#include "activities/ActivityManager.h"
#include "activities/network/WifiSelectionActivity.h"
#include "fontIds.h"
#include "network/HttpDownloader.h"
#include "network/WifiPowerSaveGuard.h"
#include "util/QrUtils.h"
#include "util/ScreenshotUtil.h"
#include "CrossPointSettings.h"
#include "activities/util/KeyboardEntryActivity.h"
#include "components/themes/BaseTheme.h"
#include <HalFrontlight.h>
#include "lua/LuaApi.h"
#include "lua/LuaInternal.h"
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
  Backend(GfxRenderer& r, MappedInputManager& in, std::string name, std::string dir, std::string entry)
      : r_(r), in_(in), name_(std::move(name)), dir_(std::move(dir)), dataDir_("/.crosslua/data/" + name_),
        entry_(std::move(entry)) {
    loadPermissions();
  }

  std::deque<const char*> events;  // string literals only (see collectInput)
  bool exitRequested = false;
  bool wifiConnectRequested = false;  // set by wifi.connect(); the activity launches the system WiFi UI
  bool textRequested = false;         // set by input.text(); the activity launches the system keyboard
  std::string textTitle, textInitial;
  int textMax = 128, textMode = 0;
  std::deque<std::pair<int, int>> evPos;  // parallel to `events`: touch position, or (-1,-1) for button events
  bool havePos = false;
  int posX = 0, posY = 0;                 // position of the event popEvent() returned last
  int touchX = 0, touchY = 0;             // last finger position seen (a release has no coordinates of its own)
  std::string openBookPath;           // set by app.open_book(); the activity hands it to the reader
  std::string restartEntry;          // set by app.restart(); the activity starts a fresh VM from this script

  // ---- storage grants ("storage": {"read": [...], "write": [...]} in manifest.json) ------------------------------
  // Parsed from the manifest but INVISIBLE to the API (grantCount() == 0) until the user approved exactly this request.
  bool hasGrantRequest() const { return !requested_.empty(); }
  // Canonical text of the request; an approval is valid only for an identical request (any change asks again).
  std::string grantCanonical() const {
    std::vector<std::string> v;
    for (const Grant& g : requested_) v.push_back(std::string(g.write ? "w:" : "r:") + g.rel);
    std::sort(v.begin(), v.end());
    std::string s;
    for (const std::string& x : v) s += x + "\n";
    return s;
  }
  std::string grantFile() const { return "/.crosslua/grants/" + name_ + ".txt"; }
  bool grantsApprovedOnDisk() {
    const std::string f = grantFile();
    const int64_t n = fsSize(f.c_str());
    const std::string want = grantCanonical();
    if (n != static_cast<int64_t>(want.size())) return false;
    std::string have(want.size(), '\0');
    return fsReadInto(f.c_str(), &have[0], have.size(), 0) && have == want;
  }
  void storeApproval() {
    fsMkdir("/.crosslua/grants");
    const std::string want = grantCanonical();
    fsWrite(grantFile().c_str(), want.data(), want.size(), false);
  }
  void approveGrants() { approved_ = true; }
  // Plain-words description for the confirmation screen; *danger = it reaches the whole card or other apps' code.
  std::string grantSummary(bool* danger) const {
    std::string rd, wr;
    *danger = false;
    for (const Grant& g : requested_) {
      std::string& dst = g.write ? wr : rd;
      if (!dst.empty()) dst += ", ";
      dst += g.rel.empty() ? "the whole SD card" : g.rel;
      if (g.write && crosslua::grantIsDangerous(g.rel.c_str())) *danger = true;
    }
    std::string s;
    if (!rd.empty()) s += "READ: " + rd + "\n";
    if (!wr.empty()) s += "WRITE: " + wr + "\n";
    if (*danger) s += "\nWARNING: this includes the whole card or the plugins folder, i.e. other apps' code.";
    else s += "\nIt can never touch hidden folders (WiFi passwords, other apps' data) or firmware images.";
    return s;
  }
  void randomBytes(uint8_t* out, size_t n) override { esp_fill_random(out, n); }
  int grantCount() override { return approved_ ? static_cast<int>(requested_.size()) : 0; }
  const char* grantPath(int i, bool* write) override {
    *write = requested_[i].write;
    return requested_[i].rel.c_str();
  }

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
    havePos = false;
    if (events.empty()) return nullptr;
    const char* e = events.front();
    events.pop_front();
    if (!evPos.empty()) {
      const auto p = evPos.front();
      evPos.pop_front();
      havePos = p.first >= 0;
      posX = p.first;
      posY = p.second;
    }
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

  // --- device capabilities (CrossPoint runs on many boards; the FREEINK_CAP_* flags say what this build has) -----------
  void deviceCaps(DeviceCaps* c) override {
#if FREEINK_CAP_TOUCH
    c->touch = gpio.hasTouch();  // e.g. X4 vs X4 Pro: decided at runtime
#endif
    c->haptic = FREEINK_CAP_HAPTIC && BoardConfig::hasHaptics();
    bool on = false;
    int b = 0, w = 0;
    c->frontlight = frontlightGet(&on, &b, &w);
    c->warmlight = c->frontlight && FREEINK_CAP_WARMLIGHT;
    c->color = FREEINK_CAP_COLOR;
    c->audio = BoardConfig::hasAudio();
    c->bleKeyboard = FREEINK_CAP_BLE_KEYBOARD;
    c->usbMsc = FREEINK_CAP_USB_MSC;
    c->imu = BoardConfig::hasImu();
    c->gyro = c->imu && BoardConfig::ACTIVE.sensors.imuType != BoardConfig::ImuType::Sc7a20h;  // SC7A20H is accelerometer-only
    c->rtc = BoardConfig::hasRtc();
    c->tempHumidity = BoardConfig::hasTempHumidity();
    c->buzzer = BoardConfig::hasBuzzer();
    c->mic = BoardConfig::hasMic();
    c->led = BoardConfig::hasLeds();
    c->tls13 = FREEINK_CAP_NET_TLS13;
  }
  bool usbConnected() override { return gpio.isUsbConnected(); }

  // --- sensors / outputs. Each SDK lib is begun on first use and put back to rest when the app ends (see ~Backend). ---
  freeink::Imu imu_;
  freeink::EnvironmentSensor env_;
  freeink::Buzzer buzzer_;
  freeink::LedManager led_;
  bool imuTried_ = false, envTried_ = false, buzzerTried_ = false, ledTried_ = false;
  ~Backend() override {
    if (buzzer_.present()) {
      buzzer_.noTone();
      buzzer_.end();
    }
    if (led_.begun()) led_.clear();
    if (imu_.present()) imu_.sleep();  // the tilt page-turner wakes it again when it needs it
  }
  SensorStatus motionRead(Motion* o) override {
    if (!BoardConfig::hasImu()) return SensorStatus::Absent;
    if (!imuTried_) {
      imuTried_ = true;
      imu_.begin();
    }
    if (!imu_.present()) return SensorStatus::Absent;
    freeink::Imu::Sample s{};
    if (!imu_.read(s)) return SensorStatus::ReadFailed;  // accelerometer-only parts can also say "no new sample yet"
    *o = {s.ax, s.ay, s.az, s.gx, s.gy, s.gz, imu_.hasGyroscope()};
    return SensorStatus::Ok;
  }
  SensorStatus envRead(float* t, float* h) override {
    if (!BoardConfig::hasTempHumidity()) return SensorStatus::Absent;
    if (!envTried_) {
      envTried_ = true;
      env_.begin();
    }
    if (!env_.present()) return SensorStatus::Absent;
    return env_.read(*t, *h) ? SensorStatus::Ok : SensorStatus::ReadFailed;
  }
  bool buzzerReady() {
    if (!BoardConfig::hasBuzzer()) return false;
    if (!buzzerTried_) {
      buzzerTried_ = true;
      buzzer_.begin();
    }
    return buzzer_.present();
  }
  bool toneStart(int f, int ms) override {
    if (!buzzerReady()) return false;
    buzzer_.tone(static_cast<uint32_t>(f), static_cast<uint32_t>(ms));
    return true;
  }
  bool toneStop() override {
    if (!buzzerReady()) return false;
    buzzer_.noTone();
    return true;
  }
  int ledCount() override {
    if (!BoardConfig::hasLeds()) return 0;
    if (!ledTried_) {
      ledTried_ = true;
      led_.begin();
    }
    return led_.begun() ? led_.count() : 0;
  }
  void ledSet(int i, int r, int g, int b) override {
    if (!led_.begun()) return;
    const freeink::LedColor c = freeink::LedColor::rgb(static_cast<uint8_t>(r), static_cast<uint8_t>(g), static_cast<uint8_t>(b));
    if (i < 0) led_.setAll(c);
    else led_.setColor(static_cast<uint8_t>(i), c);
    led_.show();
  }
  void ledOff() override {
    if (led_.begun()) led_.clear();
  }
  void ledBrightness(int v) override {
    if (!led_.begun()) return;
    led_.setBrightness(static_cast<uint8_t>(v));
    led_.show();
  }
  bool hapticPulse(int ms, int strength) override {
    return HalHaptics::pulse(SETTINGS.vibration != CrossPointSettings::VIBRATION_OFF, static_cast<uint16_t>(ms),
                             static_cast<uint8_t>(strength));
  }
  bool eventPos(int* x, int* y) override {
    if (!havePos) return false;
    *x = posX;
    *y = posY;
    return true;
  }
  void textRequest(const char* title, const char* initial, int maxLen, int mode) override {
    textTitle = title;
    textInitial = initial;
    textMax = maxLen;
    textMode = mode;
    textRequested = true;
  }
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
  // Contiguous block each decoder allocates in one piece (PNGdec's PNG object is ~44 KB, JPEGDEC ~20 KB, see the
  // *_DECODER_APPROX_SIZE constants in lib/Epub/Epub/converters) plus a little slack for its line buffers.
  static constexpr size_t PNG_MIN_BLOCK = 62 * 1024;  // sizeof(PNG) = 59.5 KB: PNGdec 45.7 KB + the build raises PNG_MAX_BUFFERED_PIXELS to 16416
  static constexpr size_t JPEG_MIN_BLOCK = 24 * 1024;
  static constexpr size_t EPUB_META_MIN_FREE = 64 * 1024;  // measured on the X4: the metadata parse peaks at ~55 KB (epubtest_lua PEAK line)
  static constexpr size_t BMP_MIN_BLOCK = 16 * 1024;  // Bitmap row buffers (<= 2048 px wide) + dither state
  bool saveScreenBmp(const char* path, char* err, size_t errCap) override {
    // The firmware's own screenshot writer: rotates to the panel's portrait orientation while streaming rows (68-byte buffer).
    const uint8_t* fb = r_.getFrameBuffer();
    if (!fb) {
      snprintf(err, errCap, "no frame buffer");
      return false;
    }
    if (!ScreenshotUtil::saveFramebufferAsBmp(path, fb, r_.getDisplayWidth(), r_.getDisplayHeight())) {
      snprintf(err, errCap, "could not write the BMP (SD card full or not writable)");
      return false;
    }
    return true;
  }
  bool epubMeta(const char* path, char* title, size_t titleCap, char* author, size_t authorCap, char* err,
                size_t errCap) override {
    // The same metadata-only parse the library indexer uses for books nobody has opened (no cache is built).
    const auto h = HalMemory::getInternalHeap();
    if (h.freeBytes < EPUB_META_MIN_FREE) {
      snprintf(err, errCap, "not enough free RAM to read the book (free %uK, need %uK)",
               static_cast<unsigned>(h.freeBytes / 1024), static_cast<unsigned>(EPUB_META_MIN_FREE / 1024));
      return false;
    }
    Epub epub(path, "/.crosspoint");
    std::string t, a;
    if (!epub.loadMetadata(t, a)) {
      snprintf(err, errCap, "cannot read the book (not an EPUB, corrupt, or no RAM)");
      return false;
    }
    snprintf(title, titleCap, "%s", t.c_str());
    snprintf(author, authorCap, "%s", a.c_str());
    return true;
  }
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
  bool requestRestart(const char* entry) override {
    restartEntry = entry;
    return true;
  }
  const char* entryName() override { return entry_.c_str(); }
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
      evPos.clear();
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

  // --- batch A additions: scan / clock / rename / mac / qr / frontlight / inflate / rounded rect -----------------
  int wifiScan(WifiScanInfo* out, int maxEntries, int* total, char* err, size_t errCap) override {
    if (WiFi.getMode() == WIFI_MODE_NULL) WiFi.mode(WIFI_STA);  // scanning needs the radio up
    const int n = WiFi.scanNetworks();
    *total = n > 0 ? n : 0;
    if (n < 0) {
      snprintf(err, errCap, "scan failed");
      return -1;
    }
    int c = 0;
    for (int i = 0; i < n && c < maxEntries; i++) {
      const String s = WiFi.SSID(i);
      strncpy(out[c].ssid, s.c_str(), sizeof(out[c].ssid) - 1);
      out[c].ssid[sizeof(out[c].ssid) - 1] = '\0';
      out[c].rssi = WiFi.RSSI(i);
      out[c].encrypted = WiFi.encryptionType(i) != WIFI_AUTH_OPEN;
      c++;
    }
    WiFi.scanDelete();
    return c;
  }
  bool timeSync(int timeoutMs, char* err, size_t errCap) override {
    if (WiFi.status() != WL_CONNECTED) {
      snprintf(err, errCap, "not connected to WiFi");
      return false;
    }
    if (!trustedtime::syncNow(static_cast<uint32_t>(timeoutMs))) {
      snprintf(err, errCap, "sync failed");
      return false;
    }
    trustedtime::note();
    return true;
  }
  bool timeSet(int64_t epoch) override {
    const struct timeval tv = {epoch, 0};
    if (settimeofday(&tv, nullptr) != 0) return false;
    trustedtime::note();
    return true;
  }
  bool fsRename(const char* from, const char* to, char* err, size_t errCap) override {
    if (Storage.exists(to)) {
      snprintf(err, errCap, "target already exists");
      return false;
    }
    if (!Storage.rename(from, to)) {
      snprintf(err, errCap, "rename failed");
      return false;
    }
    return true;
  }
  void mac(char out[18]) override {
    uint8_t m[6];
    esp_read_mac(m, ESP_MAC_WIFI_STA);
    snprintf(out, 18, "%02X:%02X:%02X:%02X:%02X:%02X", m[0], m[1], m[2], m[3], m[4], m[5]);
  }
  bool drawQr(const char* text, int x, int y, int side) override {
    QrUtils::drawQrCode(r_, Rect(x, y, side, side), text);
    return true;
  }
  static bool endsWithCI(const char* s, const char* ext) {  // ext lower-case, e.g. ".bmp"
    const size_t n = strlen(s), e = strlen(ext);
    if (n < e) return false;
    for (size_t i = 0; i < e; i++)
      if (tolower(static_cast<unsigned char>(s[n - e + i])) != ext[i]) return false;
    return true;
  }
  // Fit, never upscale, centre in the box.
  static void fitInBox(int srcW, int srcH, int x, int y, int maxW, int maxH, int* ox, int* oy, int* dw, int* dh) {
    int w = srcW, h = srcH;
    if (w > maxW || h > maxH) {
      const float sc = std::min(static_cast<float>(maxW) / w, static_cast<float>(maxH) / h);
      w = std::max(1, static_cast<int>(w * sc));
      h = std::max(1, static_cast<int>(h * sc));
    }
    *dw = w;
    *dh = h;
    *ox = x + (maxW - w) / 2;
    *oy = y + (maxH - h) / 2;
  }
  bool drawImage(const char* absPath, int x, int y, int maxW, int maxH, int* outW, int* outH, char* err,
                 size_t errCap) override {
    const auto h = HalMemory::getInternalHeap();
    if (endsWithCI(absPath, ".bmp")) {
      // BMP: no decoder object, just a row buffer (Bitmap reads row by row), so it works in a tight heap.
      if (h.largestBlockBytes < BMP_MIN_BLOCK) {
        snprintf(err, errCap, "not enough free RAM to draw (largest block %uK, need %uK)",
                 static_cast<unsigned>(h.largestBlockBytes / 1024), static_cast<unsigned>(BMP_MIN_BLOCK / 1024));
        return false;
      }
      HalFile file;
      if (!Storage.openFileForRead(TAG, absPath, file)) {
        snprintf(err, errCap, "cannot open the file");
        return false;
      }
      Bitmap bitmap(file, true, false);
      const BmpReaderError be = bitmap.parseHeaders();
      if (be != BmpReaderError::Ok) {
        snprintf(err, errCap, "cannot read the BMP: %s", Bitmap::errorToString(be));
        return false;
      }
      int ox, oy, dw, dh;
      fitInBox(bitmap.getWidth(), bitmap.getHeight(), x, y, maxW, maxH, &ox, &oy, &dw, &dh);
      if (!r_.drawBitmap(bitmap, ox, oy, dw, dh)) {
        snprintf(err, errCap, "BMP draw failed (corrupt file or not enough RAM)");
        return false;
      }
      *outW = dw;
      *outH = dh;
      return true;
    }
    ImageToFramebufferDecoder* dec = ImageDecoderFactory::getDecoder(absPath);
    if (!dec) {
      snprintf(err, errCap, "no decoder for this image type");
      return false;
    }
    // The decoders stream (RAM never scales with the source) but need working buffers of their own.
    const size_t need = endsWithCI(absPath, ".png") ? PNG_MIN_BLOCK : JPEG_MIN_BLOCK;
    if (h.largestBlockBytes < need) {
      snprintf(err, errCap, "not enough free RAM to decode (largest block %uK, need %uK)",
               static_cast<unsigned>(h.largestBlockBytes / 1024), static_cast<unsigned>(need / 1024));
      return false;
    }
    ImageDimensions d{};
    if (!dec->getDimensions(absPath, d) || d.width <= 0 || d.height <= 0) {
      snprintf(err, errCap, "cannot read the image header (corrupt, unsupported, or no RAM: largest block %uK)",
               static_cast<unsigned>(HalMemory::getInternalHeap().largestBlockBytes / 1024));
      return false;
    }
    RenderConfig cfg;
    int dw, dh;
    fitInBox(d.width, d.height, x, y, maxW, maxH, &cfg.x, &cfg.y, &dw, &dh);
    cfg.maxWidth = dw;
    cfg.maxHeight = dh;
    cfg.useGrayscale = false;
    cfg.useDithering = true;
    cfg.performanceMode = false;
    cfg.useExactDimensions = true;
    if (!dec->decodeToFramebuffer(absPath, r_, cfg)) {
      snprintf(err, errCap, "decode failed (corrupt image or not enough RAM)");
      return false;
    }
    *outW = dw;
    *outH = dh;
    return true;
  }
  bool frontlightGet(bool* on, int* brightness, int* warmth) override {
    if (!Frontlight.present()) return false;
    *on = Frontlight.isOn();
    *brightness = Frontlight.brightness();
    *warmth = Frontlight.warmth();
    return true;
  }
  void frontlightSet(int brightness, int warmth, int on) override {
    if (brightness >= 0) Frontlight.setBrightness(static_cast<uint8_t>(brightness));
    if (warmth >= 0 && Frontlight.hasColorTemperature()) Frontlight.setWarmth(static_cast<uint8_t>(warmth));
    if (on >= 0) Frontlight.setOn(on == 1);
  }
  bool inflate(const char* data, size_t n, bool zlib, size_t maxOut, char** out, size_t* outLen, char* err,
               size_t errCap) override {
    *out = nullptr;
    *outLen = 0;
    if (zlib) {
      if (n < 3 || (data[0] & 0x0f) != 8) {
        snprintf(err, errCap, "not a zlib stream");
        return false;
      }
      data += 2;
      n -= 2;
    }
    InflateReader reader;
    if (!reader.init(false)) {
      snprintf(err, errCap, "out of memory");
      return false;
    }
    reader.setSource(reinterpret_cast<const uint8_t*>(data), n);
    size_t cap = 4096 < maxOut ? 4096 : maxOut;
    uint8_t* buf = static_cast<uint8_t*>(malloc(cap));
    if (!buf) {
      snprintf(err, errCap, "out of memory");
      return false;
    }
    size_t have = 0;
    for (;;) {
      size_t produced = 0;
      const InflateStatus st = reader.readAtMost(buf + have, cap - have, &produced);
      have += produced;
      if (st == InflateStatus::Done) break;
      if (st == InflateStatus::Error) {
        free(buf);
        snprintf(err, errCap, "corrupt deflate stream");
        return false;
      }
      if (cap >= maxOut) {
        free(buf);
        snprintf(err, errCap, "inflated data over %u bytes", (unsigned)maxOut);
        return false;
      }
      cap = cap * 2 < maxOut ? cap * 2 : maxOut;
      uint8_t* nb = static_cast<uint8_t*>(realloc(buf, cap));
      if (!nb) {
        free(buf);
        snprintf(err, errCap, "out of memory");
        return false;
      }
      buf = nb;
    }
    *out = reinterpret_cast<char*>(buf);
    *outLen = have;
    return true;
  }
  void drawRoundedRect(int x, int y, int w, int h, int radius, bool black, bool filled) override {
    r_.drawRoundedRect(x, y, w, h, 1, radius, black);
    if (filled) r_.fillRect(x + radius, y + 1, w - 2 * radius, h - 2, black);  // inside the rounded ends
  }

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
    for (int w = 0; w < 2; w++)
      for (JsonVariantConst v : doc["storage"][w ? "write" : "read"].as<JsonArrayConst>()) {
        char rel[104];
        if (requested_.size() < 8 && v.is<const char*>() && crosslua::parseGrantPath(v.as<const char*>(), rel, sizeof(rel)))
          requested_.push_back({rel, w == 1});
      }
  }

  MappedInputManager& in_;
  bool net_ = false;
  bool lib_ = false;
  struct Grant {
    std::string rel;
    bool write;
  };
  std::vector<Grant> requested_;
  bool approved_ = false;
  std::string dir_;
  std::string dataDir_;
  std::string entry_;
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
  startApp();
}

// (Re)starts the app from entry_ in a fresh VM. Also used by app.restart().
void LuaAppActivity::startApp() {
  errorShown_ = false;
  waitDeadline_ = 0;

  // Start from a quiet radio. Screens earlier in the same menu (the Plugin Hub, a book sync...) can leave WiFi up, which
  // holds ~56 KB and would make every Lua app fail to start with "free RAM too low". An app that wants WiFi asks for it.
  if (WiFi.getMode() != WIFI_MODE_NULL) {
    LOG_INF(TAG, "radio was left on: switching it off before the app starts");
    WiFi.disconnect(false);
    WiFi.mode(WIFI_OFF);
    delay(30);
  }
  backend_.reset(new (std::nothrow) Backend(renderer, mappedInput, appName_, appDir_, entry_));
  vm_.reset(new (std::nothrow) crosslua::LuaVm());
  if (!backend_ || !vm_) {
    showError("Out of memory", "Could not start the Lua runtime.");
    return;
  }

  if (backend_->hasGrantRequest()) {
    if (backend_->grantsApprovedOnDisk()) backend_->approveGrants();
    else {  // ask first (from loop(): sub-activities cannot be started from onEnter)
      pendingGrantPrompt_ = true;
      return;
    }
  }
  startVm();
}

// Second half of the start: size the Lua heap, load the entry script, register the API.
void LuaAppActivity::startVm() {
  RenderLock lock;
  const auto heap = HalMemory::getInternalHeap();
  logMemory("start");
  if (heap.freeBytes < LUA_RESERVE_BYTES + LUA_MIN_BUDGET) {
    showError("Not enough memory", "Free RAM too low to start a Lua app (" + std::to_string(heap.freeBytes) +
                                       " bytes free).");
    return;
  }
  const size_t budget = std::clamp(heap.freeBytes - LUA_RESERVE_BYTES, LUA_MIN_BUDGET, LUA_MAX_BUDGET);

  const std::string path = appDir_ + "/" + entry_;
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

void LuaAppActivity::askGrants() {
  bool danger = false;
  const std::string body = backend_->grantSummary(&danger);
  auto confirmation = makeUniqueNoThrow<ConfirmationActivity>(renderer, mappedInput, appName_ + " wants access to your files",
                                                              body, "Deny", "Allow");
  if (!confirmation) {
    showError("Out of memory", "Could not show the permission screen.");
    return;
  }
  startActivityForResult(std::move(confirmation), [this](const ActivityResult& r) {
    if (r.isCancelled || !backend_) {
      LOG_INF(TAG, "storage grants denied: the app does not start");
      leave();
      return;
    }
    backend_->storeApproval();
    backend_->approveGrants();
    LOG_INF(TAG, "storage grants approved");
    startVm();
  });
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

void LuaAppActivity::launchKeyboard() {
  const InputType type = backend_->textMode == 1 ? InputType::Password : backend_->textMode == 2 ? InputType::Url : InputType::Text;
  startActivityForResult(std::make_unique<KeyboardEntryActivity>(renderer, mappedInput, backend_->textTitle,
                                                                 backend_->textInitial, static_cast<size_t>(backend_->textMax), type),
                         [this](const ActivityResult& r) {
                           renderer.clearScreen();
                           if (!vm_ || vm_->status() != crosslua::Status::Waiting) return;
                           if (r.isCancelled) {
                             vm_->resume("text:cancel");
                           } else {
                             const std::string reply = "text:ok:" + std::get<KeyboardResult>(r.data).text;
                             vm_->resume(reply.c_str());
                           }
                           armWait();
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
  auto push = [&](const char* name, int x = -1, int y = -1) {
    if (backend_ && backend_->events.size() < EVENT_QUEUE_MAX) {
      backend_->events.push_back(name);
      backend_->evPos.push_back({x, y});
    }
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
#if FREEINK_CAP_TOUCH
  if (mappedInput.hasTouch()) {  // touch boards: "press" (finger down), "long", "tap", "release" with input.pos() = x, y
    int x = 0, y = 0;
    if (mappedInput.wasScreenTouchDown(x, y)) {
      backend_->touchX = x;
      backend_->touchY = y;
      push("press", x, y);
    }
    if (mappedInput.isScreenTouchHeld(x, y)) {
      backend_->touchX = x;
      backend_->touchY = y;
    }
    if (mappedInput.wasScreenLongPress(x, y)) push("long", x, y);
    if (mappedInput.wasScreenTapped(x, y)) push("tap", x, y);
    if (mappedInput.wasScreenTouchReleased()) push("release", backend_->touchX, backend_->touchY);
  }
#endif
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
    if (!backend_->restartEntry.empty()) {  // app.restart(): fresh VM (and quiet radio) from another script of this app
      entry_ = std::move(backend_->restartEntry);
      LOG_INF(TAG, "restart: %s", entry_.c_str());
      vm_.reset();
      backend_.reset();
      startApp();
      return;
    }
    if (backend_->exitRequested) return leave();
    switch (vm_->status()) {
      case Status::Preempted:
        vm_->resume();
        armWait();
        break;
      case Status::Waiting: {
        if (backend_->textRequested) {  // input.text(): hand the screen to the system keyboard
          backend_->textRequested = false;
          return launchKeyboard();
        }
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
  if (pendingGrantPrompt_) {
    pendingGrantPrompt_ = false;
    askGrants();
    return;
  }
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
