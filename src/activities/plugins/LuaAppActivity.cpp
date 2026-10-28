#include "LuaAppActivity.h"

#include <AudioManager.h>
#include <BleKeyboardHost.h>
#include <BoardConfig.h>
#include <Buzzer.h>
#include <DevCapture.h>
#include <EnvironmentSensor.h>
#include <Epub.h>
#include <GfxRenderer.h>
#include <HalMemory.h>
#include <HalPowerManager.h>
#include <Imu.h>
#include <LedManager.h>
#include <Microphone.h>
#include <SecureClient.h>
#include <SecureHttpClient.h>
#include <arpa/inet.h>
#include <esp_now.h>
#include <esp_sleep.h>
#include <esp_timer.h>
#include <esp_wifi.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>

#include <atomic>
#include <cerrno>
#include <functional>
#if FREEINK_CAP_BLE_HID_HOST
#include <NimBLEDevice.h>  // raw mode: the observer talks to NimBLE itself (the library the SDK host already links)
#endif
#include <ArduinoJson.h>
#include <Bitmap.h>
#include <DeviceSecret.h>
#include <ESPmDNS.h>
#include <HalFrontlight.h>
#include <HalStorage.h>
#include <SDCardManager.h>
#include <InflateReader.h>
#include <Logging.h>
#include <Memory.h>
#include <TrustedTime.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <ZipFile.h>
#include <esp_mac.h>
#include <esp_random.h>
#include <sys/time.h>

#include <algorithm>
#include <cstring>
#include <deque>
#include <vector>

#include "CrossPointSettings.h"
#include "Epub/converters/ImageDecoderFactory.h"
#include "MappedInputManager.h"
#include "SilentRestart.h"
#include "activities/ActivityManager.h"
#include "activities/network/WifiSelectionActivity.h"
#include "activities/plugins/LuaBluetoothHold.h"
#include "activities/util/ConfirmationActivity.h"
#include "activities/util/KeyboardEntryActivity.h"
#include "components/themes/BaseTheme.h"
#include "fontIds.h"
#include "lua/LuaApi.h"
#include "lua/LuaInternal.h"
#include "lua/LuaVm.h"
#include "lua/PermText.h"
#include "network/HttpDownloader.h"
#include "network/WifiPowerSaveGuard.h"
#include "util/QrUtils.h"
#include "util/ScreenshotUtil.h"

static bool g_inDeepSleepCall = false;  // true while system.sleep() is inside upstream enterDeepSleep()

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
// Once wifi.connect() has succeeded the radio owns ~57 KB and only ~44 KB remain free, so the 40 KB floor would leave
// Lua about 1 KB. Measured on the device with the dev_floor knob: any floor above ~16 KB makes
// ordinary reads fail mid-stream because TCP buffering alone drives free heap down to ~16.7 KB during a 64 KB burst;
// 16, 12 and 8 KB all completed with a matching hash. 12 KB leaves Lua ~32 KB to work with. One-way for the app's
// lifetime: apps that touched WiFi restart the device on exit (heap defrag), so the framework is not left starved.
constexpr size_t LUA_HEAP_FLOOR_ONLINE = 12 * 1024;
// Characters per line the native confirmation dialog shows before it wraps (measured on the device with upper-case
// labels: "HOTSPOT, SERVER," fit, "HOTSPOT, SERVER, SPEAKER" wrapped; 22 keeps our line count equal to the real one).
constexpr size_t PERMISSION_LINE_WIDTH = 22;
// net.read may go this low for the single allocation that copies data OUT of the network stack (which relieves the
// pressure).
constexpr size_t LUA_HEAP_FLOOR_DRAIN = 6 * 1024;
// True once any app in this activity session asked for WiFi. wifi.off() sets the WiFi mode back to NULL, but the radio
// has already fragmented the heap (measured: ~20 KB never comes back until a reboot), so the exit-time defrag restart
// must not depend on the CURRENT mode. Cleared when the activity is entered; survives app.restart on purpose (same
// heap).
bool g_radioUsedThisSession = false;
std::atomic<bool> g_bluetoothHeld{
    false};  // a Lua app's Bluetooth session owns the shared stack (read through luabt::held())
constexpr size_t MAX_SCRIPT_BYTES = 64 * 1024;

constexpr uint32_t SLICE_MS = 25;        // max time one loop() pass spends inside Lua
constexpr uint32_t EXIT_HOLD_MS = 1000;    // hold Back this long to force-quit any app
constexpr uint32_t BUTTON_HOLD_MS = 500;  // hold a nav button this long -> "<name>_hold" (Back reserved for force-quit)
constexpr size_t EVENT_QUEUE_MAX = 16;

// Human-readable auth mode for a scan row; empty/unsupported modes fall back to "unknown".
const char* wifiAuthName(wifi_auth_mode_t m) {
  switch (m) {
    case WIFI_AUTH_OPEN:
      return "open";
    case WIFI_AUTH_WEP:
      return "wep";
    case WIFI_AUTH_WPA_PSK:
      return "wpa";
    case WIFI_AUTH_WPA2_PSK:
      return "wpa2";
    case WIFI_AUTH_WPA_WPA2_PSK:
      return "wpa/wpa2";
    case WIFI_AUTH_WPA2_ENTERPRISE:
      return "enterprise";
    case WIFI_AUTH_WPA3_PSK:
      return "wpa3";
    case WIFI_AUTH_WPA2_WPA3_PSK:
      return "wpa2/wpa3";
    case WIFI_AUTH_WAPI_PSK:
      return "wapi";
    default:
      return "unknown";
  }
}

}  // namespace

// ---------------------------------------------------------------------------
#if FREEINK_CAP_BLE_HID_HOST
// ble.start("raw"): one table of advertisers, filled on NimBLE's host task and copied out by the script's thread under
// a spinlock. NimBLE itself keeps nothing (setMaxResults(0) erases a device once its callback ran), so its memory stays
// flat in a crowd.
class RawObserver final : public NimBLEScanCallbacks {
 public:
  bool alloc() {
    if (tab_) return true;
    tab_ = static_cast<crosslua::Backend::BleAdvert*>(
        calloc(crosslua::Backend::BLE_MAX_ADVERTS, sizeof(crosslua::Backend::BleAdvert)));
    return tab_ != nullptr;
  }
  void clear() {
    portENTER_CRITICAL(&mux_);
    count_ = 0;
    dropped_ = 0;
    portEXIT_CRITICAL(&mux_);
  }
  void release() {
    portENTER_CRITICAL(&mux_);
    crosslua::Backend::BleAdvert* t = tab_;
    tab_ = nullptr;
    count_ = 0;
    dropped_ = 0;
    portEXIT_CRITICAL(&mux_);
    free(t);
  }
  int snapshot(crosslua::Backend::BleAdvert* out, int cap, int* dropped) {
    portENTER_CRITICAL(&mux_);
    const int n = count_ < cap ? count_ : cap;
    if (tab_ && n > 0) memcpy(out, tab_, n * sizeof(crosslua::Backend::BleAdvert));
    const uint32_t now = millis();
    for (int i = 0; i < n; i++) out[i].ageMs = now - seenAt_[i];
    *dropped = dropped_;
    portEXIT_CRITICAL(&mux_);
    return tab_ ? n : 0;
  }
  void onResult(const NimBLEAdvertisedDevice* d) override {
    crosslua::Backend::BleAdvert e;
    memset(&e, 0, sizeof(e));
    const std::string a = d->getAddress().toString();
    for (size_t i = 0; i < a.size() && i < sizeof(e.addr) - 1; i++)
      e.addr[i] = static_cast<char>(toupper(static_cast<unsigned char>(a[i])));
    e.addrType = d->getAddressType();
    e.rssi = d->getRSSI();
    e.advType = d->getAdvType();
    e.connectable = d->isConnectable();
    e.scannable = d->isScannable();
    const std::vector<uint8_t>& pl = d->getPayload();
    e.len = static_cast<uint8_t>(pl.size() < sizeof(e.data) ? pl.size() : sizeof(e.data));
    if (e.len) memcpy(e.data, pl.data(), e.len);
    const uint16_t al = d->getAdvLength();
    e.advLen = static_cast<uint8_t>(al < e.len ? al : e.len);
    portENTER_CRITICAL(&mux_);
    if (tab_) {
      int i = 0;
      while (i < count_ && strcmp(tab_[i].addr, e.addr) != 0) i++;
      if (i == count_ && count_ >= crosslua::Backend::BLE_MAX_ADVERTS) {
        dropped_++;  // packets from devices that did not fit, not a count of devices
      } else {
        if (i == count_) count_++;
        tab_[i] = e;
        seenAt_[i] = millis();
      }
    }
    portEXIT_CRITICAL(&mux_);
  }

 private:
  portMUX_TYPE mux_ = portMUX_INITIALIZER_UNLOCKED;
  crosslua::Backend::BleAdvert* tab_ = nullptr;
  uint32_t seenAt_[crosslua::Backend::BLE_MAX_ADVERTS] = {};
  int count_ = 0, dropped_ = 0;
};

// Canonical UUID spelling that round-trips through NimBLEUUID's string constructor: the 16-bit short form "2a19",
// the 32-bit "xxxxxxxx", or the 128-bit "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx". NimBLE's toString() prefixes the
// short forms with "0x", which its own parser (length 6) rejects, so strip that.
static void bleUuidStr(const NimBLEUUID& u, char* out, size_t cap) {
  std::string s = u.toString();
  size_t i = (s.size() >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) ? 2 : 0;
  size_t n = s.size() - i;
  if (n > cap - 1) n = cap - 1;
  memcpy(out, s.c_str() + i, n);
  out[n] = 0;
}

// ble.start("gatt") notifications: a small ring the notify callback fills on NimBLE's host task, drained by the
// script's thread with ble.notifs(). Dropped notifications (a full ring) are counted but not surfaced per-entry.
class GattNotifier {
 public:
  void push(const char* uuid, const uint8_t* data, size_t len) {
    if (len > 244) len = 244;
    portENTER_CRITICAL(&mux_);
    if (count_ < crosslua::Backend::BLE_MAX_GATT_NOTIFS) {
      crosslua::Backend::BleGattNotif& n = ring_[(head_ + count_) % crosslua::Backend::BLE_MAX_GATT_NOTIFS];
      snprintf(n.uuid, sizeof(n.uuid), "%s", uuid);
      n.len = static_cast<uint8_t>(len);
      if (len) memcpy(n.data, data, len);
      count_++;
    } else {
      dropped_++;
    }
    portEXIT_CRITICAL(&mux_);
  }
  int snapshot(crosslua::Backend::BleGattNotif* out, int cap) {
    portENTER_CRITICAL(&mux_);
    const int n = count_ < cap ? count_ : cap;
    for (int i = 0; i < n; i++) out[i] = ring_[(head_ + i) % crosslua::Backend::BLE_MAX_GATT_NOTIFS];
    head_ = (head_ + n) % crosslua::Backend::BLE_MAX_GATT_NOTIFS;
    count_ -= n;
    portEXIT_CRITICAL(&mux_);
    return n;
  }
  void clear() {
    portENTER_CRITICAL(&mux_);
    head_ = 0;
    count_ = 0;
    dropped_ = 0;
    portEXIT_CRITICAL(&mux_);
  }

 private:
  portMUX_TYPE mux_ = portMUX_INITIALIZER_UNLOCKED;
  crosslua::Backend::BleGattNotif ring_[crosslua::Backend::BLE_MAX_GATT_NOTIFS];
  int head_ = 0, count_ = 0, dropped_ = 0;
};

// Tracks the GATT link state (connected/connecting/failed) for ble.state(). NimBLE runs these on its own task, so
// they are atomics; ble.state() reads them from the script's thread.
class GattLinkCb final : public NimBLEClientCallbacks {
 public:
  void onConnect(NimBLEClient* c) override {
    (void)c;
    connecting = false;
    connected = true;
  }
  void onConnectFail(NimBLEClient* c, int reason) override {
    (void)c;
    (void)reason;
    connecting = false;
    failed = true;
  }
  void onDisconnect(NimBLEClient* c, int reason) override {
    (void)c;
    (void)reason;
    connecting = false;
    connected = false;
    failed = true;
  }
  void reset() {
    connecting = false;
    connected = false;
    failed = false;
  }
  std::atomic<bool> connecting{false}, connected{false}, failed{false};
};
#endif

class LuaAppActivity::Backend final : public crosslua::Backend {
 public:
  Backend(GfxRenderer& r, MappedInputManager& in, std::string name, std::string dir, std::string entry)
      : r_(r),
        in_(in),
        name_(std::move(name)),
        dir_(std::move(dir)),
        dataDir_("/.crosslua/data/" + name_),
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
  int posX = 0, posY = 0;                                         // position of the event popEvent() returned last
  std::deque<std::pair<bool, crosslua::Backend::KeyInfo>> evKey;  // parallel to `events`: (is a key event, its details)
  bool haveKey = false;  // the event popEvent() returned last was a Bluetooth key press
  crosslua::Backend::KeyInfo lastKey = {};
  bool bleUp_ = false;  // the Bluetooth stack (the SDK's BleKeyboardHost, or NimBLE itself in raw mode) is up
  int bleMode_ = 0;     // crosslua::Backend::BleMode of the running stack
#if FREEINK_CAP_BLE_HID_HOST
  RawObserver rawObs_;
  NimBLEClient* gattClient_ = nullptr;  // ble.start("gatt"): the GATT client (bare NimBLE, no HID host)
  GattNotifier gattNotifs_;
  GattLinkCb gattLinkCb_;
  char gattTarget_[18] = {0};  // the address a connect was started for (ble.state() reports it while connecting)
#endif
  int touchX = 0, touchY = 0;  // last finger position seen (a release has no coordinates of its own)
  std::string openBookPath;    // set by app.open_book(); the activity hands it to the reader
  std::string restartEntry;    // set by app.restart(); the activity starts a fresh VM from this script

  // ---- storage grants ("storage": {"read": [...], "write": [...]} in manifest.json) ------------------------------
  // Parsed from the manifest but INVISIBLE to the API (grantCount() == 0) until the user approved exactly this request.
  bool hasGrantRequest() const {
    return !requested_.empty() || listenReq_ || hotspotReq_ || espnowReq_ || monitorReq_ || txReq_ || audioReq_ ||
           micReq_ || bleReq_;
  }
  // Canonical text of the request; an approval is valid only for an identical request (any change asks again).
  std::string grantCanonical() const {
    std::vector<std::string> v;
    for (const Grant& g : requested_) v.push_back(std::string(g.write ? "w:" : "r:") + g.rel);
    if (espnowReq_) v.push_back("p:espnow");    // raw frames to anyone in radio range
    if (monitorReq_) v.push_back("p:monitor");  // passive capture of everything in radio range
    if (txReq_) v.push_back("p:tx");            // sending arbitrary frames: can deauthenticate other people's devices
    if (bleReq_)
      v.push_back("p:bluetooth");  // a keyboard is a typing channel into the app; a BLE scan sees everyone nearby
    if (hotspotReq_) v.push_back("p:hotspot");  // starting a WiFi network that others can join
    if (listenReq_) v.push_back("p:listen");   // accepting connections from the LAN is part of the approved request too
    if (micReq_) v.push_back("p:microphone");  // a recording device: consented to explicitly, never silently
    if (audioReq_) v.push_back("p:audio");  // playing sounds is consented to for the same reason (a device that talks)
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
    // One short label per permission, packed into as few lines as fit (the dialog clips after ~3 lines of ~25
    // characters), the most sensitive first so a recording device can never be the part that is cut off. Packing is
    // host-tested (PermText.h).
    {
      std::vector<const char*> labels;
      if (micReq_) labels.push_back("MICROPHONE");
      if (espnowReq_) labels.push_back("ESP-NOW");
      if (monitorReq_) labels.push_back("SNIFFER");
      if (txReq_) labels.push_back("INJECT");
      if (hotspotReq_) labels.push_back("AP");  // the only abbreviation that lets seven permissions fit on three lines
      if (listenReq_) labels.push_back("SERVER");
      if (audioReq_) labels.push_back("SPEAKER");
      if (bleReq_) labels.push_back("BLE");  // fits the third line: "SERVER, SPEAKER, BLE" is 20 characters
      s += crosslua::packPermissionLabels(labels, PERMISSION_LINE_WIDTH);
    }
    if (!rd.empty()) s += "READ: " + rd + "\n";
    if (!wr.empty()) s += "WRITE: " + wr + "\n";
    if (*danger)
      s += "\nWARNING: this includes the whole card or the plugins folder, i.e. other apps' code.";
    else if (!rd.empty() || !wr.empty())
      s += "\nIt can never touch hidden folders (WiFi passwords, other apps' data) or firmware images.";
    return s;
  }
  // Title of the confirmation screen: says what is being asked for.
  std::string grantTitle(const std::string& app) const {
    const bool files = !requested_.empty();
    const int n = (listenReq_ ? 1 : 0) + (hotspotReq_ ? 1 : 0) + (espnowReq_ ? 1 : 0) + (audioReq_ ? 1 : 0) +
                  (micReq_ ? 1 : 0) + (monitorReq_ ? 1 : 0) + (txReq_ ? 1 : 0) + (bleReq_ ? 1 : 0) + (files ? 1 : 0);
    if (n > 1) return app + " wants access to your device";
    if (micReq_) return app + " wants to use the microphone";
    if (txReq_) return app + " wants to inject WiFi frames";
    if (monitorReq_) return app + " wants to capture nearby WiFi traffic";
    if (espnowReq_) return app + " wants to use the radio directly";
    if (hotspotReq_) return app + " wants to start a hotspot";
    if (listenReq_) return app + " wants to accept connections";
    if (audioReq_) return app + " wants to play sounds";
    if (bleReq_) return app + " wants to use Bluetooth";
    return app + " wants access to your files";
  }
  void randomBytes(uint8_t* out, size_t n) override { esp_fill_random(out, n); }
  bool deviceKeyMaterial(uint8_t out[32]) override {
    return ::deviceSecret(*reinterpret_cast<uint8_t (*)[32]>(out));
  }  // upstream's NVS secret
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
    if (filled)
      r_.fillRect(x, y, w, h, black);
    else
      r_.drawRect(x, y, w, h, black);
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
    static const F fonts[] = {{"ui", UI_10_FONT_ID},           {"ui12", UI_12_FONT_ID},
                              {"small", SMALL_FONT_ID},        {"sans12", NOTOSANS_12_FONT_ID},
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
    haveKey = false;
    if (events.empty()) return nullptr;
    const char* e = events.front();
    events.pop_front();
    if (!evKey.empty()) {
      const auto k = evKey.front();
      evKey.pop_front();
      haveKey = k.first;
      lastKey = k.second;
    }
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
  size_t radioFloorBytes() override { return radioEverStarted_ ? 48 * 1024 : 80 * 1024; }
  const char* wakeCause() override {
    switch (esp_sleep_get_wakeup_cause()) {
      case ESP_SLEEP_WAKEUP_TIMER:
        return "timer";
      case ESP_SLEEP_WAKEUP_EXT0:
      case ESP_SLEEP_WAKEUP_EXT1:
      case ESP_SLEEP_WAKEUP_GPIO:
        return "button";
      case ESP_SLEEP_WAKEUP_UNDEFINED:
        return "power-on";
      default:
        return "other";
    }
  }
  bool systemSleep(int seconds, char* err, size_t errCap) override {
    // Arm the timer wake, then hand over to upstream's own sleep flow (sleep screen, plugin events, WiFi teardown, rail
    // power-down, power-button wake): ONE code path for every sleep, ours just also wakes on time. Read-only use of the
    // existing main.cpp entry point; the call never returns on the device.
    g_radioUsedThisSession = true;  // the wake reboot is the same defragmenting reboot every radio app gets
    if (esp_sleep_enable_timer_wakeup(static_cast<uint64_t>(seconds) * 1000000ULL) != ESP_OK) {
      snprintf(err, errCap, "could not arm the timer wake");
      return false;
    }
    extern void enterDeepSleep(bool fromTimeout);
    g_inDeepSleepCall =
        true;  // goToSleep() pumps loop() right here: it must not resume the VM that is blocked in this very call
    enterDeepSleep(false);
    g_inDeepSleepCall = false;
    snprintf(err, errCap, "the device refused to enter deep sleep");
    return false;
  }
  size_t freeHeap() override { return HalMemory::getInternalHeap().freeBytes; }
  size_t freeHeapQuick() override {
    return ESP.getFreeHeap();
  }  // O(1); getInternalHeap() also walks for the largest block
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
  // --- hotspot: Arduino WiFi.softAP, the same calls File Transfer's access-point mode makes (nothing upstream is
  // touched) ---
  bool apRunning() { return (WiFi.getMode() & WIFI_MODE_AP) != 0 && WiFi.softAPIP() != IPAddress(0, 0, 0, 0); }
  bool netReady() override { return wifiConnected() || apRunning(); }
  bool hotspotAllowed() override { return net_ && hotspotReq_ && approved_; }
  bool softApStart(const char* ssid, const char* password, int channel, int maxClients, char* ip, size_t ipCap,
                   char* err, size_t errCap) override {
    g_radioUsedThisSession = true;  // leaving the app reboots into a clean heap, like every WiFi screen
    WiFi.mode(WIFI_AP);
    delay(100);
    if (!WiFi.softAP(ssid, password, channel, false, maxClients)) {  // password nullptr = open network
      WiFi.mode(WIFI_OFF);
      snprintf(err, errCap, "cannot start the hotspot");
      return false;
    }
    delay(100);  // the AP needs a moment before its address is valid (same wait as the upstream screen)
    fmtIp(ip, ipCap, WiFi.softAPIP());
    // Same as after a successful wifi.connect(): the radio now owns ~60 KB, so the 40 KB allocator floor would leave
    // Lua nothing (measured: a client joining made the app die with "not enough memory"). Sockets keep their own 16 KB
    // check.
    if (setFloorFn) setFloorFn(LUA_HEAP_FLOOR_ONLINE);
    return true;
  }
  bool softApInfo(char* ssid, size_t ssidCap, char* ip, size_t ipCap, int* clients) override {
    if (!apRunning()) return false;
    snprintf(ssid, ssidCap, "%s", WiFi.softAPSSID().c_str());
    fmtIp(ip, ipCap, WiFi.softAPIP());
    *clients = WiFi.softAPgetStationNum();
    return true;
  }
  // --- ESP-NOW (same call sequence as crossplay's LinkRadio / biscuit's MeshChat: STA mode, fixed channel, broadcast
  // peer). The receive callback runs in the WiFi task, so it only copies into a single-producer/single-consumer ring;
  // Lua polls it. ---
  static constexpr int ESPNOW_RING = 6;
  struct EnPacket {
    uint8_t mac[6];
    uint8_t len;
    uint8_t data[250];
  };
  EnPacket enRing_[ESPNOW_RING] = {};
  std::atomic<uint8_t> enHead_{0}, enTail_{0};  // head: consumer (Lua poll) owns; tail: producer (callback) owns
  std::atomic<int> enDropped_{0};
  bool espnowUp_ = false;
  int espnowChannel_ = 1;
  uint8_t espnowMac_[6] = {0};
  inline static Backend* espnowSelf_ = nullptr;
  static void onEspNowRecv(const esp_now_recv_info_t* info, const uint8_t* data, int len) {
    Backend* b = espnowSelf_;
    if (!b || !info || !data || len <= 0 || len > 250) return;
    const uint8_t tail = b->enTail_.load(std::memory_order_relaxed);
    const uint8_t next = static_cast<uint8_t>((tail + 1) % ESPNOW_RING);
    if (next == b->enHead_.load(std::memory_order_acquire)) {
      b->enDropped_.fetch_add(1, std::memory_order_relaxed);
      return;
    }
    EnPacket& p = b->enRing_[tail];
    memcpy(p.mac, info->src_addr, 6);
    memcpy(p.data, data, static_cast<size_t>(len));
    p.len = static_cast<uint8_t>(len);
    b->enTail_.store(next, std::memory_order_release);
  }
  bool espnowAllowed() override { return net_ && espnowReq_ && approved_; }
  bool espnowRunning() override { return espnowUp_; }
  bool espnowStart(int channel, uint8_t mac[6], char* err, size_t errCap) override {
    g_radioUsedThisSession = true;
    radioEverStarted_ = true;  // leaving the app reboots into a clean heap, like every WiFi screen
    WiFi.persistent(false);
    WiFi.mode(WIFI_STA);
    WiFi.setAutoReconnect(false);
    WiFi.disconnect(false);
    auto fail = [&](const char* msg) {
      snprintf(err, errCap, "%s", msg);
      espnowStop();
      return false;
    };
    if (monUp_) {
      snprintf(err, errCap, "the WiFi sniffer is running: call wifi.monitor_stop() first");
      return false;
    }
    if (esp_wifi_set_channel(static_cast<uint8_t>(channel), WIFI_SECOND_CHAN_NONE) != ESP_OK)
      return fail("could not set the channel");
    if (esp_now_init() != ESP_OK) return fail("esp_now_init failed");
    espnowUp_ = true;
    enHead_.store(0);
    enTail_.store(0);
    enDropped_.store(0);
    espnowSelf_ = this;
    if (esp_now_register_recv_cb(&Backend::onEspNowRecv) != ESP_OK)
      return fail("could not register the receive callback");
    esp_now_peer_info_t peer = {};
    memset(peer.peer_addr, 0xFF, 6);
    peer.channel = static_cast<uint8_t>(channel);
    peer.ifidx = WIFI_IF_STA;
    peer.encrypt = false;
    const esp_err_t added = esp_now_add_peer(&peer);
    if (added != ESP_OK && added != ESP_ERR_ESPNOW_EXIST) return fail("could not add the broadcast peer");
    if (esp_wifi_get_mac(WIFI_IF_STA, espnowMac_) != ESP_OK) return fail("could not read the MAC address");
    espnowChannel_ = channel;
    memcpy(mac, espnowMac_, 6);
    if (setFloorFn)
      setFloorFn(LUA_HEAP_FLOOR_ONLINE);  // the radio owns its RAM now (same as after wifi.connect / a hotspot)
    return true;
  }
  void espnowStop() override {
    if (espnowUp_) {
      esp_now_unregister_recv_cb();
      esp_now_deinit();
      espnowUp_ = false;
    }
    if (espnowSelf_ == this) espnowSelf_ = nullptr;
    if ((WiFi.getMode() & WIFI_MODE_STA) && !wifiConnected()) WiFi.mode(WIFI_OFF);
  }
  bool espnowSend(const uint8_t mac[6], bool broadcast, const void* data, size_t n, char* err, size_t errCap) override {
    (void)broadcast;  // the broadcast address is simply FF:FF:FF:FF:FF:FF (a peer added at start)
    if (!esp_now_is_peer_exist(mac)) {
      esp_now_peer_info_t peer = {};
      memcpy(peer.peer_addr, mac, 6);
      peer.channel = static_cast<uint8_t>(espnowChannel_);
      peer.ifidx = WIFI_IF_STA;
      peer.encrypt = false;
      const esp_err_t added = esp_now_add_peer(&peer);
      if (added != ESP_OK && added != ESP_ERR_ESPNOW_EXIST) {
        snprintf(err, errCap, added == ESP_ERR_ESPNOW_FULL ? "too many peers (max 20)" : "could not add the peer");
        return false;
      }
    }
    if (esp_now_send(mac, static_cast<const uint8_t*>(data), n) != ESP_OK) {
      snprintf(err, errCap, "the radio refused the frame");
      return false;
    }
    return true;
  }
  int espnowRecv(void* buf, size_t cap, uint8_t mac[6]) override {
    const uint8_t head = enHead_.load(std::memory_order_relaxed);
    if (head == enTail_.load(std::memory_order_acquire)) return 0;
    const EnPacket& p = enRing_[head];
    const size_t n = std::min<size_t>(p.len, cap);
    memcpy(buf, p.data, n);
    memcpy(mac, p.mac, 6);
    enHead_.store(static_cast<uint8_t>((head + 1) % ESPNOW_RING), std::memory_order_release);
    return static_cast<int>(n);
  }
  bool espnowInfo(uint8_t mac[6], int* channel, int* dropped) override {
    if (!espnowUp_) return false;
    memcpy(mac, espnowMac_, 6);
    *channel = espnowChannel_;
    *dropped = enDropped_.load(std::memory_order_relaxed);
    return true;
  }
  // --- wifi.monitor (promiscuous 802.11 capture; the PCAP writer streams through a 2 KB buffer, no heap; biscuit's
  // PacketMonitorActivity does the same callback-to-file trick). Frames are truncated at 250 bytes in the ring; the
  // PCAP record keeps the original length so readers know what was cut. Timestamps are us since boot, not wall clock.
  // ---
  static constexpr int MON_RING = 8;
  static constexpr size_t MON_PCAP_BUFFER = 2048;
  struct MonPkt {
    uint16_t len;
    int8_t rssi;
    uint8_t data[250];
  };
  MonPkt monRing_[MON_RING] = {};
  std::atomic<uint8_t> monHead_{0}, monTail_{0};
  std::atomic<int> monCaptured_{0}, monDropped_{0};
  bool monUp_ = false;
  bool radioEverStarted_ = false;  // the radio's RAM does not come back without a reboot (see wifi.off docs)
  int monChannel_ = 1;
  HalFile monFile_;
  char monPath_[160] = {0};
  uint32_t monBytes_ = 0;
  uint8_t monBuf_[MON_PCAP_BUFFER] = {};
  size_t monBufLen_ = 0;
  inline static Backend* monSelf_ = nullptr;
  static void onPromiscuous(void* cbBuf, wifi_promiscuous_pkt_type_t type) {
    Backend* b = monSelf_;
    if (!b || !cbBuf || (type != WIFI_PKT_MGMT && type != WIFI_PKT_DATA)) return;
    const wifi_promiscuous_pkt_t* pkt = static_cast<const wifi_promiscuous_pkt_t*>(cbBuf);
    const int len = pkt->rx_ctrl.sig_len;
    if (len <= 0) return;
    b->monCaptured_.fetch_add(1, std::memory_order_relaxed);
    if (b->monFile_) b->pcapAppend(pkt->payload, static_cast<size_t>(len), pkt->rx_ctrl.rssi);
    const uint8_t tail = b->monTail_.load(std::memory_order_relaxed);
    const uint8_t next = static_cast<uint8_t>((tail + 1) % MON_RING);
    if (next == b->monHead_.load(std::memory_order_acquire)) {
      b->monDropped_.fetch_add(1, std::memory_order_relaxed);
      return;
    }
    MonPkt& p = b->monRing_[tail];
    p.len = static_cast<uint16_t>(len < 250 ? len : 250);
    memcpy(p.data, pkt->payload, p.len);
    p.rssi = static_cast<int8_t>(pkt->rx_ctrl.rssi);
    b->monTail_.store(next, std::memory_order_release);
  }
  // Appends one PCAP record (16-byte header + packet) to the buffer, flushing whole buffer-loads to the card.
  void pcapAppend(const uint8_t* pkt, size_t len, int rssi) {
    (void)rssi;
    const size_t stored = len < 250 ? len : 250;
    if (monBufLen_ + 16 + stored > sizeof(monBuf_)) {
      if (monBufLen_ && monFile_.write(monBuf_, monBufLen_) == monBufLen_) monBytes_ += monBufLen_;
      monBufLen_ = 0;
    }
    if (16 + stored > sizeof(monBuf_)) return;  // cannot happen (stored <= 250)
    const int64_t us = esp_timer_get_time();
    uint8_t rec[16];
    const uint32_t sec = static_cast<uint32_t>(us / 1000000), usec = static_cast<uint32_t>(us % 1000000);
    memcpy(rec + 0, &sec, 4);
    memcpy(rec + 4, &usec, 4);
    memcpy(rec + 8, &stored, 4);
    memcpy(rec + 12, &len, 4);
    memcpy(monBuf_ + monBufLen_, rec, 16);
    monBufLen_ += 16;
    memcpy(monBuf_ + monBufLen_, pkt, stored);
    monBufLen_ += stored;
  }
  bool monitorAllowed() override { return net_ && monitorReq_ && approved_; }
  bool monitorRunning() override { return monUp_; }
  bool monitorStart(int channel, const char* pcapPath, char* err, size_t errCap) override {
    g_radioUsedThisSession = true;  // leaving the app reboots into a clean heap, like every WiFi screen
    auto fail = [&](const char* msg) {
      snprintf(err, errCap, "%s", msg);
      uint32_t dummy = 0;
      monitorStop(&dummy);
      return false;
    };
    WiFi.persistent(false);
    // Like biscuit's PacketMonitorActivity: keep the driver running as a (disconnected) STA and enable promiscuous on
    // top. Arduino's WiFi.mode(WIFI_MODE_NULL) never boots the driver and NULL mode broke reception on the X4.
    WiFi.mode(WIFI_MODE_STA);
    WiFi.disconnect(false);
    if (esp_wifi_set_channel(static_cast<uint8_t>(channel), WIFI_SECOND_CHAN_NONE) != ESP_OK)
      return fail("could not set the channel");
    radioEverStarted_ = true;
    wifi_promiscuous_filter_t filter = {.filter_mask = WIFI_PROMIS_FILTER_MASK_MGMT | WIFI_PROMIS_FILTER_MASK_DATA};
    if (esp_wifi_set_promiscuous_filter(&filter) != ESP_OK) return fail("could not set the capture filter");
    monHead_.store(0);
    monTail_.store(0);
    monCaptured_.store(0);
    monDropped_.store(0);
    monBufLen_ = 0;
    monBytes_ = 0;
    monPath_[0] = 0;
    if (pcapPath) {
      monFile_ = Storage.open(pcapPath, O_WRONLY | O_CREAT | O_TRUNC);
      if (!monFile_) return fail("cannot open the file for writing");
      snprintf(monPath_, sizeof(monPath_), "%s", pcapPath);
      // PCAP global header: little-endian MICROSECOND magic 0xa1b2c3d4 (0xa1b23c4d would mean nanoseconds),
      // version 2.4, snaplen 65535, LINKTYPE_IEEE802_11 (105)
      static const uint8_t pcapHeader[24] = {0xd4, 0xc3, 0xb2, 0xa1, 0x02, 0x00, 0x04, 0x00, 0,    0,    0,    0,
                                             0,    0,    0,    0,    0xff, 0xff, 0x00, 0x00, 0x69, 0x00, 0x00, 0x00};
      memcpy(monBuf_, pcapHeader, sizeof(pcapHeader));
      monBufLen_ = sizeof(pcapHeader);
    }
    monSelf_ = this;
    monUp_ = true;
    monChannel_ = channel;
    if (esp_wifi_set_promiscuous_rx_cb(&Backend::onPromiscuous) != ESP_OK)
      return fail("could not register the capture callback");
    if (esp_wifi_set_promiscuous(true) != ESP_OK) return fail("could not start promiscuous mode");
    if (setFloorFn)
      setFloorFn(LUA_HEAP_FLOOR_ONLINE);  // the radio owns its RAM now (same as after wifi.connect / a hotspot)
    return true;
  }
  void monitorStop(uint32_t* pcapBytes) override {
    if (monUp_) {
      monUp_ = false;
      esp_wifi_set_promiscuous(false);
      esp_wifi_set_promiscuous_rx_cb(nullptr);
      if (monSelf_ == this) monSelf_ = nullptr;
    }
    if (monFile_) {
      if (monBufLen_ && monFile_.write(monBuf_, monBufLen_) == monBufLen_) monBytes_ += monBufLen_;
      monBufLen_ = 0;
      monFile_.close();
    }
    *pcapBytes = monBytes_;
    if (!txUp_ && !wifiConnected() &&
        !WiFi.softAPIP()) {  // give the radio back entirely (promiscuous leaves it started)
      WiFi.mode(WIFI_OFF);
    }
  }
  int monitorRecv(void* buf, size_t cap, int* rssi, int* channel) override {
    const uint8_t head = monHead_.load(std::memory_order_relaxed);
    if (head == monTail_.load(std::memory_order_acquire)) return 0;
    const MonPkt& p = monRing_[head];
    const size_t n = std::min<size_t>(p.len, cap);
    memcpy(buf, p.data, n);
    *rssi = p.rssi;
    *channel = monChannel_;
    monHead_.store(static_cast<uint8_t>((head + 1) % MON_RING), std::memory_order_release);
    return static_cast<int>(n);
  }
  bool monitorSetChannel(int channel, char* err, size_t errCap) override {
    if (!monUp_ && !txUp_) {
      snprintf(err, errCap, "no radio mode is running");
      return false;
    }
    if (esp_wifi_set_channel(static_cast<uint8_t>(channel), WIFI_SECOND_CHAN_NONE) != ESP_OK) {
      snprintf(err, errCap, "could not set the channel");
      return false;
    }
    monChannel_ = channel;  // one radio, one channel: the sniffer and the injector always follow together
    return true;
  }
  bool monitorInfo(int* channel, int* captured, int* dropped, char* path, size_t pathCap,
                   uint32_t* pcapBytes) override {
    if (!monUp_) return false;
    *channel = monChannel_;
    *captured = monCaptured_.load(std::memory_order_relaxed);
    *dropped = monDropped_.load(std::memory_order_relaxed);
    snprintf(path, pathCap, "%s", monPath_);
    *pcapBytes = monBytes_;
    return true;
  }
  // --- wifi.tx (esp_wifi_80211_tx; the radio stays a disconnected STA with promiscuous enabled, like the monitor, and
  // the FCS is computed by the driver). Coexists with the monitor on one channel: whoever stops last turns the radio
  // off. ---
  bool txUp_ = false;
  int txChannel_ = 1, txSent_ = 0;
  bool txAllowed() override { return net_ && txReq_ && approved_; }
  bool txRunning() override { return txUp_; }
  bool txStart(int channel, char* err, size_t errCap) override {
    g_radioUsedThisSession = true;
    radioEverStarted_ = true;
    auto fail = [&](const char* msg) {
      snprintf(err, errCap, "%s", msg);
      txStop();
      return false;
    };
    WiFi.mode(WIFI_MODE_STA);  // same boot dance as the monitor (Arduino never boots the driver in NULL mode)
    WiFi.disconnect(false);
    if (esp_wifi_set_channel(static_cast<uint8_t>(channel), WIFI_SECOND_CHAN_NONE) != ESP_OK)
      return fail("could not set the channel");
    if (esp_wifi_set_promiscuous(true) != ESP_OK) return fail("could not enable raw sending");
    txUp_ = true;
    txChannel_ = channel;
    txSent_ = 0;
    return true;
  }
  void txStop() override {
    if (txUp_) {
      txUp_ = false;
      if (!monUp_) {  // the monitor needs the radio (and its promiscuous mode) too
        esp_wifi_set_promiscuous(false);
        if (!wifiConnected() && !WiFi.softAPIP()) WiFi.mode(WIFI_OFF);
      }
    }
  }
  bool txSend(const void* frame, size_t n, char* err, size_t errCap) override {
    if (esp_wifi_80211_tx(WIFI_IF_STA, static_cast<const uint8_t*>(frame), static_cast<int>(n), false) != ESP_OK) {
      snprintf(err, errCap, "the radio refused the frame");
      return false;
    }
    txSent_++;
    return true;
  }
  bool txInfo(int* channel, int* sent) override {
    if (!txUp_) return false;
    *channel = txChannel_;
    *sent = txSent_;
    return true;
  }
  void wifiRequestConnect() override {
    g_radioUsedThisSession = true;
    wifiConnectRequested = true;
  }

  // --- device capabilities (CrossPoint runs on many boards; the FREEINK_CAP_* flags say what this build has)
  // -----------
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
    c->gyro = c->imu &&
              BoardConfig::ACTIVE.sensors.imuType != BoardConfig::ImuType::Sc7a20h;  // SC7A20H is accelerometer-only
    c->rtc = BoardConfig::hasRtc();
    c->tempHumidity = BoardConfig::hasTempHumidity();
    c->buzzer = BoardConfig::hasBuzzer();
    c->mic = BoardConfig::hasMic();
    c->led = BoardConfig::hasLeds();
    c->tls13 = FREEINK_CAP_NET_TLS13;
  }
  bool usbConnected() override { return gpio.isUsbConnected(); }
  std::function<void(size_t)> setFloorFn;  // set by the Activity: applies a new heap-guard floor to the VM
  std::function<size_t()> getFloorFn;
  size_t savedFloor_ = 0;
  bool devSetFloor(size_t bytes) override {
#ifdef CROSSLUA_DEV
    if (!setFloorFn) return false;
    setFloorFn(bytes);
    return true;
#else
    (void)bytes;
    return false;
#endif
  }
  void heapRelax(bool on) override {
    if (!setFloorFn || !getFloorFn) return;
    if (on) {
      savedFloor_ = getFloorFn();
      if (savedFloor_ > LUA_HEAP_FLOOR_DRAIN) setFloorFn(LUA_HEAP_FLOOR_DRAIN);
    } else if (savedFloor_) {
      setFloorFn(savedFloor_);
      savedFloor_ = 0;
    }
  }

  // --- Bluetooth LE central: the SDK's BleKeyboardHost (the same NimBLE central, Just-Works bonding and HID decoding
  // the page turner uses). One stack: it refuses while the page turner or any WiFi mode holds the radio, and the
  // activity holds the CPU clock steady (skipLoopDelay) while it is up. Bonds persist in NVS and reconnect on their own
  // through poll(). ---
  bool bleSupported() override { return FREEINK_CAP_BLE_HID_HOST != 0; }
  bool bleAllowed() override { return bleReq_ && approved_; }
  bool bleRunning() override { return bleUp_; }
  void bleClearLink() {
    bleFailed_ = false;
    bleHasPasskey_ = false;
    bleReason_[0] = 0;
    bleTarget_[0] = 0;
  }
  bool bleStart(const char* mode, char* err, size_t errCap) override {
    const bool raw = mode && strcmp(mode, "raw") == 0;
    const bool gatt = mode && strcmp(mode, "gatt") == 0;
    if (BleHid.isStopping()) {
      snprintf(err, errCap, "bluetooth is still shutting down: try again in a moment");
      return false;
    }
    if (BleHid.isRunning()) {
      snprintf(err, errCap, "the Bluetooth page turner holds the radio");
      return false;
    }
    if (WiFi.getMode() != WIFI_MODE_NULL) {
      snprintf(err, errCap, "the radio is in use by WiFi: call wifi.off() first");
      return false;
    }
    g_radioUsedThisSession = true;  // leaving the app reboots into a clean heap, like every WiFi screen
    radioEverStarted_ = true;
    powerManager.setPowerSaving(false);  // begin() and end() must run at the normal CPU frequency; while the stack is
                                         // up LuaAppActivity::skipLoopDelay() keeps the main loop from clocking down
    if (raw) {
#if FREEINK_CAP_BLE_HID_HOST
      if (!NimBLEDevice::init("CrossLua")) {
        snprintf(err, errCap, "the Bluetooth stack did not start");
        return false;
      }
      bleMode_ = crosslua::Backend::BLE_MODE_RAW;
#endif
    } else if (gatt) {
#if FREEINK_CAP_BLE_HID_HOST
      if (!NimBLEDevice::init("CrossLua")) {
        snprintf(err, errCap, "the Bluetooth stack did not start");
        return false;
      }
      gattClient_ = NimBLEDevice::createClient();
      if (!gattClient_) {
        NimBLEDevice::deinit(true);
        snprintf(err, errCap, "the Bluetooth client did not start");
        return false;
      }
      gattClient_->setClientCallbacks(&gattLinkCb_, false);
      gattLinkCb_.reset();
      gattNotifs_.clear();
      bleMode_ = crosslua::Backend::BLE_MODE_GATT;
#endif
    } else {
      if (!BleHid.begin("CrossLua")) {
        snprintf(err, errCap, "the Bluetooth stack did not start");
        return false;
      }
      bleMode_ = crosslua::Backend::BLE_MODE_KEYBOARD;
    }
    bleUp_ = true;
    g_bluetoothHeld.store(true);
    bleClearLink();
    if (setFloorFn)
      setFloorFn(LUA_HEAP_FLOOR_ONLINE);  // the stack owns its RAM now (same as after wifi.connect / a hotspot)
    return true;
  }
  void bleStop() override {
    if (!bleUp_) return;
    if (bleMode_ == crosslua::Backend::BLE_MODE_RAW) {
#if FREEINK_CAP_BLE_HID_HOST
      NimBLEDevice::getScan()->stop();
      NimBLEDevice::getScan()->clearResults();
      NimBLEDevice::deinit(true);  // the NimBLE host + controller RAM goes back to the heap
      rawObs_.release();
#endif
    } else if (bleMode_ == crosslua::Backend::BLE_MODE_GATT) {
#if FREEINK_CAP_BLE_HID_HOST
      if (gattClient_) {
        gattClient_->disconnect();
        NimBLEDevice::deleteClient(gattClient_);
        gattClient_ = nullptr;
      }
      gattNotifs_.clear();
      gattLinkCb_.reset();
      NimBLEDevice::deinit(true);
#endif
    } else {
      for (int i = 0; i < 4 && !BleHid.end(1000); i++) {
      }  // each call waits at most 1 s; a later call carries on where the last stopped
    }
    bleMode_ = crosslua::Backend::BLE_MODE_NONE;
    bleUp_ = false;
    g_bluetoothHeld.store(false);
    evKey.clear();
    bleClearLink();
  }
  bool bleScan(int ms, char* err, size_t errCap) override {
    if (BleHid.isConnecting()) {
      snprintf(err, errCap, "a connection is in progress");
      return false;
    }
    BleHid.startScan(static_cast<uint32_t>(ms));
    if (!BleHid.isScanning()) {
      snprintf(err, errCap, "the scan did not start");
      return false;
    }
    return true;
  }
  void bleScanStop() override { BleHid.stopScan(); }
  static void bleCopy(crosslua::Backend::BleDevice* o, const char* addr, const char* name, int rssi, bool conn,
                      bool hid) {
    snprintf(o->addr, sizeof(o->addr), "%s", addr);
    snprintf(o->name, sizeof(o->name), "%s", name);
    o->rssi = rssi;
    o->connectable = conn;
    o->hid = hid;
  }
  int bleDevices(crosslua::Backend::BleDevice* out, int cap) override {
    int n = 0;
    for (uint8_t i = 0; i < BleHid.deviceCount() && n < cap; i++) {
      const freeink::DiscoveredDevice& d = BleHid.device(i);
      bleCopy(&out[n++], d.addr, d.name, d.rssi, d.connectable, d.hid);
    }
    return n;
  }
  // The SDK compares addresses with strncmp; use ITS spelling of a known device so the case the app typed cannot
  // matter.
  const char* bleKnownSpelling(const char* addr) {
    for (uint8_t i = 0; i < BleHid.deviceCount(); i++)
      if (!strcasecmp(BleHid.device(i).addr, addr)) return BleHid.device(i).addr;
    for (uint8_t i = 0; i < BleHid.pairedCount(); i++)
      if (!strcasecmp(BleHid.paired(i).addr, addr)) return BleHid.paired(i).addr;
    return addr;
  }
  bool bleConnect(const char* addr, int addrType, char* err, size_t errCap) override {
    if (bleMode_ == crosslua::Backend::BLE_MODE_GATT) {
#if FREEINK_CAP_BLE_HID_HOST
      if (!gattClient_) {
        snprintf(err, errCap, "the Bluetooth client is not up");
        return false;
      }
      if (gattClient_->isConnected()) gattClient_->disconnect();
      gattLinkCb_.reset();
      snprintf(gattTarget_, sizeof(gattTarget_), "%s", addr);
      // Async connect: returns at once; ble.state().link reports "connecting" then "connected"/"failed".
      if (!gattClient_->connect(NimBLEAddress(std::string(addr), addrType ? BLE_ADDR_RANDOM : BLE_ADDR_PUBLIC),
                                true, true, true)) {
        gattTarget_[0] = 0;
        snprintf(err, errCap, "the connection attempt did not start");
        return false;
      }
      gattLinkCb_.connecting = true;
      return true;
#else
      (void)addr;
      (void)addrType;
      snprintf(err, errCap, "no bluetooth on this device");
      return false;
#endif
    }
    BleHid.stopScan();  // a scan and a connect share the one radio task
    bleClearLink();
    const char* spelled = bleKnownSpelling(addr);
    snprintf(bleTarget_, sizeof(bleTarget_), "%s", spelled);
    if (!BleHid.connect(spelled)) {
      bleTarget_[0] = 0;
      snprintf(err, errCap,
               BleHid.isRunning() ? "a connection attempt is already running"
                                  : "the Bluetooth stack went down (ble.stop() then ble.start())");
      return false;
    }
    return true;
  }
  void bleDisconnect() override {
    if (bleMode_ == crosslua::Backend::BLE_MODE_GATT) {
#if FREEINK_CAP_BLE_HID_HOST
      if (gattClient_) {
        gattClient_->disconnect();
        gattLinkCb_.reset();
        gattTarget_[0] = 0;
      }
#endif
      return;
    }
    if (BleHid.isConnecting() && !BleHid.isConnected()) {
      // The SDK cannot cancel an attempt in flight from outside (disconnect() only drops an established link, and a
      // connect to a device that is not there runs for tens of seconds): end() is its supported way to abandon one, so
      // take the stack down and bring it back, keeping the session alive. Bonds live in NVS and are untouched.
      for (int i = 0; i < 4 && !BleHid.end(1000); i++) {
      }
      if (!BleHid.begin("CrossLua")) {  // could not come back: the session is over, say so honestly
        bleUp_ = false;
        g_bluetoothHeld.store(false);
        evKey.clear();
      }
    } else {
      BleHid.disconnect();
    }
    bleClearLink();
  }
  void bleState(crosslua::Backend::BleState* s) override {
    if (bleMode_ == crosslua::Backend::BLE_MODE_GATT) {
#if FREEINK_CAP_BLE_HID_HOST
      if (gattClient_ && gattClient_->isConnected()) {
        s->link = crosslua::Backend::BLE_CONNECTED;
        const std::string a = gattClient_->getPeerAddress().toString();
        snprintf(s->addr, sizeof(s->addr), "%s", a.c_str());
        s->name[0] = 0;  // the name is not carried on a connected client; the script saw it while scanning
        return;
      }
      if (gattLinkCb_.connecting) {
        s->link = crosslua::Backend::BLE_CONNECTING;
        snprintf(s->addr, sizeof(s->addr), "%s", gattTarget_);
        return;
      }
      if (gattLinkCb_.failed) {
        s->link = crosslua::Backend::BLE_FAILED;
        snprintf(s->reason, sizeof(s->reason), "the connection failed");
        snprintf(s->addr, sizeof(s->addr), "%s", gattTarget_);
        return;
      }
      s->link = crosslua::Backend::BLE_IDLE;
      return;
#else
      s->link = crosslua::Backend::BLE_IDLE;
      return;
#endif
    }
    s->scanning = BleHid.isScanning();
    uint32_t pk = 0;
    if (BleHid.takePairingPasskey(pk)) {  // the keyboard shows no number: the user types THIS one on it, then Enter
      blePasskey_ = pk;
      bleHasPasskey_ = true;
    }
    if (BleHid.isConnected()) {
      s->link = crosslua::Backend::BLE_CONNECTED;
      snprintf(s->addr, sizeof(s->addr), "%s", BleHid.connectedAddr());
      snprintf(s->name, sizeof(s->name), "%s", BleHid.connectedName());
      bleHasPasskey_ = false;
      bleFailed_ = false;
      return;
    }
    if (BleHid.isConnecting()) {
      s->link = crosslua::Backend::BLE_CONNECTING;
      snprintf(s->addr, sizeof(s->addr), "%s", bleTarget_);
      for (uint8_t i = 0; i < BleHid.deviceCount(); i++)
        if (!strcasecmp(BleHid.device(i).addr, bleTarget_))
          snprintf(s->name, sizeof(s->name), "%s", BleHid.device(i).name);
      s->hasPasskey = bleHasPasskey_;
      s->passkey = blePasskey_;
      return;
    }
    char why[64] = {0};
    if (BleHid.takeConnectFailure(why, sizeof(why))) {
      bleFailed_ = true;
      snprintf(bleReason_, sizeof(bleReason_), "%s", why[0] ? why : "the connection failed");
      bleHasPasskey_ = false;
    }
    s->link = bleFailed_ ? crosslua::Backend::BLE_FAILED : crosslua::Backend::BLE_IDLE;
    if (bleFailed_) {
      snprintf(s->reason, sizeof(s->reason), "%s", bleReason_);
      snprintf(s->addr, sizeof(s->addr), "%s", bleTarget_);
    }
  }
  int blePaired(crosslua::Backend::BleDevice* out, int cap) override {
    int n = 0;
    for (uint8_t i = 0; i < BleHid.pairedCount() && n < cap; i++) {
      const freeink::PairedHidDevice& p = BleHid.paired(i);
      bleCopy(&out[n++], p.addr, p.name, 0, true, true);
    }
    return n;
  }
  bool bleForget(const char* addr) override {
    for (uint8_t i = 0; i < BleHid.pairedCount(); i++)
      if (!strcasecmp(BleHid.paired(i).addr, addr)) {
        char spelled[18];
        snprintf(spelled, sizeof(spelled), "%s", BleHid.paired(i).addr);  // forget() edits the list this points into
        BleHid.forget(spelled);
        return true;
      }
    return false;
  }
  // --- raw mode: the observer ---
  int bleMode() override { return bleUp_ ? bleMode_ : crosslua::Backend::BLE_MODE_NONE; }
  bool bleObserve(int ms, bool active, char* err, size_t errCap) override {
#if FREEINK_CAP_BLE_HID_HOST
    if (!bleUp_ || bleMode_ != crosslua::Backend::BLE_MODE_RAW) {
      snprintf(err, errCap, "bluetooth is not running in raw mode");
      return false;
    }
    NimBLEScan* sc = NimBLEDevice::getScan();
    if (sc->isScanning()) sc->stop();
    if (!rawObs_.alloc()) {
      snprintf(err, errCap, "not enough memory for the observer");
      return false;
    }
    rawObs_.clear();
    sc->setScanCallbacks(&rawObs_, true);  // true: every packet, so the signal strength and the data stay current
    sc->setMaxResults(0);                  // NimBLE keeps nothing: our table is the only copy
    sc->setActiveScan(active);
    sc->setInterval(100);
    sc->setWindow(90);
    sc->setScanResponseTimeout(
        500);  // an active scan reports a scannable device when its response arrives, or after this
    if (!sc->start(static_cast<uint32_t>(ms))) {
      snprintf(err, errCap, "the scan did not start");
      return false;
    }
    return true;
#else
    (void)ms;
    (void)active;
    snprintf(err, errCap, "no bluetooth on this device");
    return false;
#endif
  }
  void bleObserveStop() override {
#if FREEINK_CAP_BLE_HID_HOST
    if (bleUp_ && bleMode_ == crosslua::Backend::BLE_MODE_RAW) NimBLEDevice::getScan()->stop();
#endif
  }
  bool bleObserving() override {
#if FREEINK_CAP_BLE_HID_HOST
    return bleUp_ && bleMode_ == crosslua::Backend::BLE_MODE_RAW && NimBLEDevice::getScan()->isScanning();
#else
    return false;
#endif
  }
  int bleAdverts(BleAdvert* out, int cap, int* dropped) override {
#if FREEINK_CAP_BLE_HID_HOST
    return rawObs_.snapshot(out, cap, dropped);
#else
    (void)out;
    (void)cap;
    *dropped = 0;
    return 0;
#endif
  }
  // --- gatt mode ---
  // Resolves a characteristic UUID against the cached discovery (run ble.services() first). nullptr when absent.
  NimBLERemoteCharacteristic* gattFind(const char* uuid) {
#if FREEINK_CAP_BLE_HID_HOST
    if (!gattClient_) return nullptr;
    NimBLEUUID want(uuid);
    for (auto* s : gattClient_->getServices(false))
      for (auto* ch : s->getCharacteristics(false))
        if (ch->getUUID() == want) return ch;
#endif
    return nullptr;
  }
  int bleGattServices(crosslua::Backend::BleGattChar* out, int cap) override {
#if FREEINK_CAP_BLE_HID_HOST
    if (!gattClient_ || !gattClient_->isConnected()) return -1;
    int n = 0;
    for (auto* s : gattClient_->getServices(true)) {
      for (auto* ch : s->getCharacteristics(true)) {
        if (n >= cap) return n;
        bleUuidStr(s->getUUID(), out[n].service, sizeof(out[n].service));
        bleUuidStr(ch->getUUID(), out[n].uuid, sizeof(out[n].uuid));
        out[n].handle = ch->getHandle();
        uint8_t props = 0;
        if (ch->canBroadcast()) props |= 0x01;
        if (ch->canRead()) props |= 0x02;
        if (ch->canWriteNoResponse()) props |= 0x04;
        if (ch->canWrite()) props |= 0x08;
        if (ch->canNotify()) props |= 0x10;
        if (ch->canIndicate()) props |= 0x20;
        if (ch->canWriteSigned()) props |= 0x40;
        if (ch->hasExtendedProps()) props |= 0x80;
        out[n].props = props;
        n++;
      }
    }
    return n;
#else
    (void)out;
    (void)cap;
    return -1;
#endif
  }
  bool bleGattRead(const char* uuid, uint8_t* data, size_t* len, size_t maxLen, char* err, size_t errCap) override {
#if FREEINK_CAP_BLE_HID_HOST
    if (!gattClient_ || !gattClient_->isConnected()) {
      snprintf(err, errCap, "not connected (ble.connect then wait for ble.state().link)");
      return false;
    }
    NimBLERemoteCharacteristic* ch = gattFind(uuid);
    if (!ch) {
      snprintf(err, errCap, "no such characteristic (call ble.services() first)");
      return false;
    }
    NimBLEAttValue v = ch->readValue();
    if (v.size() > maxLen) {
      snprintf(err, errCap, "value is %u bytes, larger than the %u-byte limit", static_cast<unsigned>(v.size()),
               static_cast<unsigned>(maxLen));
      return false;
    }
    if (v.size()) memcpy(data, v.data(), v.size());
    *len = v.size();
    return true;
#else
    (void)uuid;
    (void)data;
    (void)len;
    (void)maxLen;
    if (errCap) err[0] = 0;
    return false;
#endif
  }
  bool bleGattWrite(const char* uuid, const uint8_t* data, size_t len, bool noResponse, char* err,
                    size_t errCap) override {
#if FREEINK_CAP_BLE_HID_HOST
    if (!gattClient_ || !gattClient_->isConnected()) {
      snprintf(err, errCap, "not connected (ble.connect then wait for ble.state().link)");
      return false;
    }
    NimBLERemoteCharacteristic* ch = gattFind(uuid);
    if (!ch) {
      snprintf(err, errCap, "no such characteristic (call ble.services() first)");
      return false;
    }
    if (!ch->writeValue(data, len, !noResponse)) {
      snprintf(err, errCap, "the write was refused");
      return false;
    }
    return true;
#else
    (void)uuid;
    (void)data;
    (void)len;
    (void)noResponse;
    if (errCap) err[0] = 0;
    return false;
#endif
  }
  bool bleGattNotify(const char* uuid, bool on, char* err, size_t errCap) override {
#if FREEINK_CAP_BLE_HID_HOST
    if (!gattClient_ || !gattClient_->isConnected()) {
      snprintf(err, errCap, "not connected (ble.connect then wait for ble.state().link)");
      return false;
    }
    NimBLERemoteCharacteristic* ch = gattFind(uuid);
    if (!ch) {
      snprintf(err, errCap, "no such characteristic (call ble.services() first)");
      return false;
    }
    if (on) {
      if (!ch->subscribe(true, [this](NimBLERemoteCharacteristic* c, uint8_t* d, size_t l, bool) {
            char buf[37];
            bleUuidStr(c->getUUID(), buf, sizeof(buf));
            gattNotifs_.push(buf, d, l);
          })) {
        snprintf(err, errCap, "the subscription was refused (characteristic may not notify)");
        return false;
      }
    } else {
      if (!ch->unsubscribe()) {
        snprintf(err, errCap, "the unsubscribe was refused");
        return false;
      }
    }
    return true;
#else
    (void)uuid;
    (void)on;
    if (errCap) err[0] = 0;
    return false;
#endif
  }
  int bleGattNotifs(crosslua::Backend::BleGattNotif* out, int cap) override {
#if FREEINK_CAP_BLE_HID_HOST
    return gattNotifs_.snapshot(out, cap);
#else
    (void)out;
    (void)cap;
    return 0;
#endif
  }
  bool bleAdvertise(const char* name, const uint8_t* data, size_t dataLen, bool connectable, int intervalMs,
                    uint16_t serviceUuid, const uint8_t* serviceData, size_t serviceDataLen, char* err,
                    size_t errCap) override {
#if FREEINK_CAP_BLE_HID_HOST
    if (!bleUp_ || bleMode_ != crosslua::Backend::BLE_MODE_RAW) {
      snprintf(err, errCap, "bluetooth is not running in raw mode");
      return false;
    }
    NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
    adv->stop();
    adv->setConnectableMode(connectable ? BLE_GAP_CONN_MODE_UND : BLE_GAP_CONN_MODE_NON);
    if (name && name[0]) adv->setName(name);
    if (dataLen) adv->setManufacturerData(data, dataLen);
    if (serviceUuid)
      adv->setServiceData(NimBLEUUID(serviceUuid),
                          std::string(reinterpret_cast<const char*>(serviceData), serviceDataLen));
    if (intervalMs > 0) {  // NimBLE takes 0.625 ms units: 20..10000 ms -> 32..16000
      const uint16_t u = static_cast<uint16_t>(intervalMs * 8 / 5);
      adv->setMinInterval(u);
      adv->setMaxInterval(u);
    }
    if (!adv->start(0)) {
      snprintf(err, errCap, "advertising did not start");
      return false;
    }
    return true;
#else
    (void)name;
    (void)data;
    (void)dataLen;
    (void)connectable;
    (void)intervalMs;
    (void)serviceUuid;
    (void)serviceData;
    (void)serviceDataLen;
    if (errCap) err[0] = 0;
    return false;
#endif
  }
  void bleAdvertiseStop() override {
#if FREEINK_CAP_BLE_HID_HOST
    if (bleUp_ && bleMode_ == crosslua::Backend::BLE_MODE_RAW) NimBLEDevice::getAdvertising()->stop();
#endif
  }
  bool bleAdvertising() override {
#if FREEINK_CAP_BLE_HID_HOST
    return bleUp_ && bleMode_ == crosslua::Backend::BLE_MODE_RAW && NimBLEDevice::getAdvertising()->isAdvertising();
#else
    return false;
#endif
  }
  bool eventKey(crosslua::Backend::KeyInfo* k) override {
    if (!haveKey) return false;
    *k = lastKey;
    return true;
  }
  // --- sensors / outputs. Each SDK lib is begun on first use and put back to rest when the app ends (see ~Backend).
  // ---
  freeink::Imu imu_;
  freeink::EnvironmentSensor env_;
  freeink::Buzzer buzzer_;
  freeink::LedManager led_;
  bool imuTried_ = false, envTried_ = false, buzzerTried_ = false, ledTried_ = false;
  ~Backend() override {
    bleStop();  // BleKeyboardHost::end(): the stack, its task and its RAM go; bonds stay in NVS
    for (int i = 0; i < crosslua::Backend::MAX_SOCKETS; i++)
      if (sockUsed_[i])
        netClose(i);  // an app that exits with sockets open must not leak them (TCP, UDP, listen server, TLS session)
    if (buzzer_.present()) {
      buzzer_.noTone();
      buzzer_.end();
    }
    if (led_.begun()) led_.clear();
    if (imu_.present()) imu_.sleep();  // the tilt page-turner wakes it again when it needs it
    txStop();
    {
      uint32_t monBytes = 0;
      monitorStop(&monBytes);  // the capture callback points into this object; flush and close the PCAP
    }
    espnowStop();                    // the receive callback points into this object
    audio_.stop();                   // waits for the playback task, so the WAV callbacks die with us
    if (mic_.present()) mic_.end();  // powers the mic rail down
    if (audioFile_) audioFile_.close();
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
    const freeink::LedColor c =
        freeink::LedColor::rgb(static_cast<uint8_t>(r), static_cast<uint8_t>(g), static_cast<uint8_t>(b));
    if (i < 0)
      led_.setAll(c);
    else
      led_.setColor(static_cast<uint8_t>(i), c);
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
    txStop();
    uint32_t monBytes = 0;
    monitorStop(&monBytes);
    espnowStop();
    WiFi.softAPdisconnect(true);
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
  static constexpr size_t PNG_MIN_BLOCK =
      62 * 1024;  // sizeof(PNG) = 59.5 KB: PNGdec 45.7 KB + the build raises PNG_MAX_BUFFERED_PIXELS to 16416
  static constexpr size_t JPEG_MIN_BLOCK = 24 * 1024;
  static constexpr size_t EPUB_META_MIN_FREE = 64 * 1024;  // the metadata parse peaks at ~55 KB
  static constexpr size_t BMP_MIN_BLOCK = 16 * 1024;       // Bitmap row buffers (<= 2048 px wide) + dither state
  // --- raw TCP client sockets (net.*): Arduino WiFiClient (NetworkClient over lwIP), already linked for the web server
  // ---
  WiFiClient socks_[crosslua::Backend::MAX_SOCKETS];
  WiFiUDP udps_[crosslua::Backend::MAX_SOCKETS];
  bool sockUsed_[crosslua::Backend::MAX_SOCKETS] = {};
  int sockKind_[crosslua::Backend::MAX_SOCKETS] = {};             // 0 free, 1 TCP, 2 UDP, 3 server
  WiFiServer* sockServers_[crosslua::Backend::MAX_SOCKETS] = {};  // non-null for kind-3 slots
  // One TLS client at a time (kind 4): the wolfSSL session + record buffers cost ~40 KB, so it is heap-allocated only
  // while open.
  freeink::SecureClient* tls_ = nullptr;
  std::string tlsCa_;  // the pinned PEM; SecureClient keeps the pointer, so it must outlive the session
  Client& sockCli(int s) {
    return sockKind_[s] == 4 && tls_ ? static_cast<Client&>(*tls_) : static_cast<Client&>(socks_[s]);
  }
  static void fmtIp(char* out, size_t cap, const IPAddress& ip) {
    snprintf(out, cap, "%u.%u.%u.%u", ip[0], ip[1], ip[2], ip[3]);
  }
  bool netLocal(char* ip, char* mask, char* gw, char* dns, size_t cap) override {
    if (WiFi.status() != WL_CONNECTED) {
      if (!apRunning()) return false;  // our own hotspot: we are the gateway and the DNS, clients live in the same /24
      fmtIp(ip, cap, WiFi.softAPIP());
      fmtIp(mask, cap, WiFi.softAPSubnetMask());
      fmtIp(gw, cap, WiFi.softAPIP());
      fmtIp(dns, cap, WiFi.softAPIP());
      return true;
    }
    fmtIp(ip, cap, WiFi.localIP());
    fmtIp(mask, cap, WiFi.subnetMask());
    fmtIp(gw, cap, WiFi.gatewayIP());
    fmtIp(dns, cap, WiFi.dnsIP());
    return true;
  }
  bool netResolve(const char* host, char* ip, size_t ipCap, char* err, size_t errCap) override {
    IPAddress a;
    if (WiFi.hostByName(host, a) != 1) {
      snprintf(err, errCap, "cannot resolve '%s' (no such host or DNS unreachable)", host);
      return false;
    }
    fmtIp(ip, ipCap, a);
    return true;
  }
  // Back-cancellable connect. The Arduino connect() blocks in one select() call with no way in, so do the same
  // non-blocking connect + select it does internally, but in 40 ms slices that pump the buttons: Back cancels
  // (same shape as the http transfer cancel). DNS still uses the system timeout (a few hundred ms, not interruptible).
  int netConnect(const char* host, int port, int timeoutMs, char* err, size_t errCap) override {
    int slot = -1;
    for (int i = 0; i < crosslua::Backend::MAX_SOCKETS && slot < 0; i++)
      if (!sockUsed_[i]) slot = i;
    if (slot < 0) {
      snprintf(err, errCap, "too many open sockets (max 4)");
      return -1;
    }
    IPAddress ip;
    if (WiFi.hostByName(host, ip) != 1) {
      snprintf(err, errCap, "cannot resolve '%s' (no such host or DNS unreachable)", host);
      return -1;
    }
    const int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
      snprintf(err, errCap, "cannot create socket");
      return -1;
    }
    sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = static_cast<uint32_t>(ip);
    addr.sin_port = htons(static_cast<uint16_t>(port));
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    int rc = connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
    if (rc < 0 && errno != EINPROGRESS) {
      close(fd);
      snprintf(err, errCap, "cannot connect to %s:%d (refused)", host, port);
      return -1;
    }
    int soErr = 0;
    while (rc < 0) {  // EINPROGRESS: wait for writability in slices, Back cancels
      fd_set wset;
      FD_ZERO(&wset);
      FD_SET(fd, &wset);
      timeval tv = {0, 40 * 1000};
      const int sel = select(fd + 1, nullptr, &wset, nullptr, &tv);
      devcapture::pollSerial();  // serial-injected buttons stay alive while the loop is blocked here
      in_.update(true);
      if (in_.wasPressed(MappedInputManager::Button::Back) || in_.isPressed(MappedInputManager::Button::Back)) {
        for (int i = 0; i < 200 && in_.isPressed(MappedInputManager::Button::Back);
             i++) {  // swallow the release like http
          delay(10);
          in_.update(true);
        }
        events.clear();
        evPos.clear();
        evKey.clear();
        close(fd);
        snprintf(err, errCap, "cancelled");
        return -1;
      }
      if (sel > 0) {
        socklen_t len = sizeof(soErr);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len);
        rc = soErr == 0 ? 0 : -1;  // writable: the connect finished (either way)
        break;
      }
      timeoutMs -= 40;
      if (timeoutMs <= 0) {
        close(fd);
        snprintf(err, errCap, "cannot connect to %s:%d (timed out)", host, port);
        return -1;
      }
    }
    if (rc < 0) {
      close(fd);
      snprintf(err, errCap, "cannot connect to %s:%d (refused, unreachable or timed out)", host, port);
      return -1;
    }
    socks_[slot] = WiFiClient(fd);  // adopt the connected socket (the fd constructor wires handle + rx buffer)
    socks_[slot].setNoDelay(true);
    sockUsed_[slot] = true;
    sockKind_[slot] = 1;
    return slot;
  }
  // TLS client. The handshake polls the abort callback between its steps, so Back cancels (the longest uninterruptible
  // stretch is one TCP connect window). caPem != nullptr verifies the server against it; nullptr = unverified (app
  // asked).
  int netConnectTls(const char* host, int port, int timeoutMs, const char* caPem, char* err, size_t errCap) override {
    int slot = -1;
    for (int i = 0; i < crosslua::Backend::MAX_SOCKETS && slot < 0; i++)
      if (!sockUsed_[i]) slot = i;
    if (slot < 0 || tls_) {
      snprintf(err, errCap, slot < 0 ? "too many open sockets (max 8)" : "only one TLS socket at a time");
      return -1;
    }
    auto* c = new (std::nothrow) freeink::SecureClient();
    if (!c) {
      snprintf(err, errCap, "out of memory for TLS");
      return -1;
    }
    if (caPem) {
      tlsCa_ = caPem;
      c->setCACert(tlsCa_.c_str());
    } else {
      c->setInsecure();
    }
    c->setTimeout(static_cast<uint32_t>(timeoutMs));
    c->setAbortCallback([this]() { return backCancelRequested(); });
    const int ok = c->connect(host, static_cast<uint16_t>(port));
    if (!ok) {
      const bool cancelled = c->aborted();
      delete c;
      tlsCa_.clear();
      tlsCa_.shrink_to_fit();
      if (cancelled)
        snprintf(err, errCap, "cancelled");
      else if (caPem)
        snprintf(err, errCap,
                 "cannot connect to %s:%d (tls handshake failed: unreachable, or the certificate does not match ca)",
                 host, port);
      else
        snprintf(err, errCap, "cannot connect to %s:%d (tls handshake failed or unreachable)", host, port);
      return -1;
    }
    c->setAbortCallback(nullptr);  // the lambda captures `this`; the session outlives the connect call
    tls_ = c;
    sockUsed_[slot] = true;
    sockKind_[slot] = 4;
    return slot;
  }
  int netKind(int s) override { return s >= 0 && s < crosslua::Backend::MAX_SOCKETS ? sockKind_[s] : 0; }
  int udpOpen(int port, char* err, size_t errCap) override {
    int slot = -1;
    for (int i = 0; i < crosslua::Backend::MAX_SOCKETS && slot < 0; i++)
      if (!sockUsed_[i]) slot = i;
    if (slot < 0) {
      snprintf(err, errCap, "too many open sockets (max 8)");
      return -1;
    }
    if (!udps_[slot].begin(static_cast<uint16_t>(port))) {
      snprintf(err, errCap, "cannot bind UDP port %d", port);
      return -1;
    }
    sockUsed_[slot] = true;
    sockKind_[slot] = 2;
    return slot;
  }
  int udpSend(int s, const char* host, int port, const void* d, size_t n, char* err, size_t errCap) override {
    if (!netIsOpen(s) || sockKind_[s] != 2) {
      snprintf(err, errCap, "not a UDP socket");
      return -1;
    }
    IPAddress a;
    if (WiFi.hostByName(host, a) != 1) {
      snprintf(err, errCap, "cannot resolve '%s' (no such host or DNS unreachable)", host);
      return -1;
    }
    if (udps_[s].beginPacket(a, static_cast<uint16_t>(port)) != 1 ||
        udps_[s].write(static_cast<const uint8_t*>(d), n) != n || udps_[s].endPacket() != 1) {
      snprintf(err, errCap, "UDP send to %s:%d failed", host, port);
      return -1;
    }
    return static_cast<int>(n);
  }
  int udpRecv(int s, void* buf, size_t max, char* ip, size_t ipCap, int* port) override {
    if (!netIsOpen(s) || sockKind_[s] != 2) return -1;
    const int size = udps_[s].parsePacket();
    if (size <= 0) return 0;  // nothing waiting (parsePacket also clears the previous remote address)
    fmtIp(ip, ipCap, udps_[s].remoteIP());
    *port = udps_[s].remotePort();
    return udps_[s].read(static_cast<uint8_t*>(buf), std::min(max, static_cast<size_t>(size)));
  }
  bool netIsOpen(int s) override { return s >= 0 && s < crosslua::Backend::MAX_SOCKETS && sockUsed_[s]; }
  // Arduino's NetworkClient::connected() does not notice a graceful close (FIN) until a later read, so ask the socket
  // directly: a non-destructive peek returns 0 on an orderly shutdown, > 0 if data waits, and -1/EWOULDBLOCK when
  // simply idle.
  bool peerAlive(int s) {
    if (sockKind_[s] == 4) return tls_ && tls_->connected();
    const int fd = socks_[s].fd();
    if (fd < 0) return false;
    uint8_t b;
    const int r = recv(fd, &b, 1, MSG_PEEK | MSG_DONTWAIT);
    if (r == 0) return false;
    if (r < 0 && errno != EWOULDBLOCK && errno != EAGAIN) return false;
    return true;
  }
  int netAvailable(int s) override { return netIsOpen(s) ? sockCli(s).available() : -1; }
  int netRead(int s, void* buf, size_t max) override {
    if (!netIsOpen(s)) return -1;
    const int a = sockCli(s).available();
    if (a <= 0) return peerAlive(s) ? 0 : -1;
    return sockCli(s).read(static_cast<uint8_t*>(buf), std::min(max, static_cast<size_t>(a)));
  }
  int netWrite(int s, const void* d, size_t n) override {
    if (!netIsOpen(s) || (sockCli(s).available() == 0 && !peerAlive(s))) return -1;
    const size_t w = sockCli(s).write(static_cast<const uint8_t*>(d), n);
    return (w == 0 && n > 0) ? -1 : static_cast<int>(w);
  }
  bool netConnected(int s) override { return netIsOpen(s) && (sockCli(s).available() > 0 || peerAlive(s)); }
  void netClose(int s) override {
    if (!netIsOpen(s)) return;
    if (sockKind_[s] == 2)
      udps_[s].stop();
    else if (sockKind_[s] == 3) {
      if (sockServers_[s]) {
        delete sockServers_[s];
        sockServers_[s] = nullptr;
      }
    } else if (sockKind_[s] == 4) {
      if (tls_) {
        tls_->stop();
        delete tls_;
        tls_ = nullptr;
      }
      tlsCa_.clear();
      tlsCa_.shrink_to_fit();
    } else
      socks_[s].stop();
    sockUsed_[s] = false;
    sockKind_[s] = 0;
  }
  bool saveScreenBmp(const char* path, char* err, size_t errCap) override {
    // The firmware's own screenshot writer: rotates to the panel's portrait orientation while streaming rows (68-byte
    // buffer).
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
      if (in_.wasPressed(MappedInputManager::Button::Back) || in_.isPressed(MappedInputManager::Button::Back))
        cancelled = true;  // a quick tap counts
      return cancelled;
    };
    auto finishCancel = [&]() {
      for (int i = 0; i < 200 && in_.isPressed(MappedInputManager::Button::Back); i++) {  // swallow the release so the
        delay(10);                                                                        // app never sees this Back
        in_.update(true);
      }
      events.clear();
      evPos.clear();
      evKey.clear();
      return fail("cancelled");
    };

    WifiPowerSaveGuard psGuard;
    const std::string url(rq.url);
    // Everything but a plain GET goes through SecureHttpClient: it sends ANY method with the caller's headers (the old
    // form-POST helper dropped them, so no Authorization header could ever reach a service), can pin a certificate, and
    // keeps the response headers. A plain GET (and every save_to download) keeps the long-verified HttpDownloader path.
    if (strcmp(rq.method, "GET") != 0 || rq.caPem || rq.wantHeaders) {
      freeink::SecureHttpClient http;
      http.setUserAgent("CrossPoint");
      std::string ca;  // SecureHttpClient keeps the pointer: it must outlive the request
      if (rq.caPem) {
        ca = rq.caPem;
        http.setCACert(ca.c_str());
      } else {
        http.setInsecure();  // the documented default: encrypted, server not authenticated
      }
      http.setTimeout(30000);
      if (!http.begin(url)) return fail("cannot parse the url");
      for (int i = 0; i < rq.headerCount; i++) http.addHeader(rq.headers[i].name, rq.headers[i].value);
      if (rq.contentType) http.addHeader("Content-Type", rq.contentType);
      if (!strcmp(rq.method, "GET"))
        http.setFollowRedirects(3);  // like the plain GET path; other methods return the 3xx as is
      char* buf = nullptr;
      size_t n = 0, cap = 0;
      bool tooBig = false, oom = false;
      const int st = http.sendRequest(
          rq.method, reinterpret_cast<const uint8_t*>(rq.body ? rq.body : ""), rq.bodyLen,
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
          [&]() { return pollCancel(); });
      rs.status = st > 0 ? st : 0;
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
      if (st <= 0 || !http.responseComplete()) {
        free(buf);
        return fail(rq.caPem ? "request failed (no response, or the server certificate does not match ca)"
                             : "request failed (no response)");
      }
      rs.body = buf;
      rs.bodyLen = rs.bytes = n;
      if (rq.wantHeaders) {  // "Name: value\n" lines, capped at 4 KB (the binding parses and lower-cases them)
        std::string block;
        for (const auto& h : http.getHeaders()) {
          if (block.size() + h.first.size() + h.second.size() + 3 > 4096) break;
          block += h.first;
          block += ": ";
          block += h.second;
          block += '\n';
        }
        rs.headers = static_cast<char*>(malloc(block.size() ? block.size() : 1));
        if (!rs.headers) return fail("out of memory while reading the response headers");
        memcpy(rs.headers, block.data(), block.size());
        rs.headersLen = block.size();
      }
      return true;
    }
    if (rq.savePath) {
      std::string dest(rq.savePath);
      const size_t slash = dest.rfind('/');
      if (slash != std::string::npos && slash > 0) Storage.ensureDirectoryExists(dest.substr(0, slash).c_str());
      const auto err = HttpDownloader::downloadToFile(
          url, dest,
          [&](size_t done, size_t) {
            rs.bytes = done;
            pollCancel();
          },
          &cancelled, "", "", hdrs, false);
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
  bool fsStat(const char* path, FsStat* out) override {
    HalFile f = Storage.open(path);
    if (!f) return false;
    out->isDir = f.isDirectory();
    out->size = out->isDir ? 0 : static_cast<int64_t>(f.fileSize());
    out->fatTime = f.modificationTime();
    return true;
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
  bool fsMkdir(const char* path) override {
    return Storage.exists(path) ? fsSize(path) == -2 : Storage.mkdir(path, true);
  }
  bool fsRemove(const char* path) override { return fsSize(path) == -2 ? Storage.rmdir(path) : Storage.remove(path); }
  bool fsRmdir(const char* path) override {
    // Recursive delete: remove every entry under `path`, then the (now-empty) directory itself. Mirrors the
    // fsListNext iteration (skip . and ..), but keeps hidden/temp files — a recursive delete is a full wipe.
    std::function<bool(const std::string&)> wipe = [&](const std::string& p) -> bool {
      HalFile dir = Storage.open(p.c_str());
      if (!dir || !dir.isDirectory()) return false;
      for (;;) {
        HalFile e = dir.openNextFile();
        if (!e) break;
        char name[crosslua::MAX_PATH_LEN + 1];
        if (e.getName(name, sizeof(name)) == 0) continue;
        if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'))) continue;
        const std::string child = p + "/" + name;
        if (e.isDirectory()) {
          if (!wipe(child)) return false;
        } else if (!Storage.remove(child.c_str())) {
          return false;
        }
      }
      dir.close();
      return Storage.rmdir(p.c_str());
    };
    return wipe(path);
  }
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
  StorageStats storageStats() override {
    StorageStats s;
    if (!Storage.ready()) return s;  // card not mounted -> total==0
    s.total = SDCardManager::getInstance().sdTotalBytes();
    s.used = SDCardManager::getInstance().sdUsedBytes();
    return s;
  }

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
      out[c].hidden = s.length() == 0;  // a hidden network's beacon carries no SSID
      const String b = WiFi.BSSIDstr(i);
      strncpy(out[c].bssid, b.c_str(), sizeof(out[c].bssid) - 1);
      out[c].bssid[sizeof(out[c].bssid) - 1] = '\0';
      out[c].channel = WiFi.channel(i);
      strncpy(out[c].auth, wifiAuthName(WiFi.encryptionType(i)), sizeof(out[c].auth) - 1);
      out[c].auth[sizeof(out[c].auth) - 1] = '\0';
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
  void systemReboot() override { esp_restart(); }
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
  bool inflate(const char* data, size_t n, bool zlib, size_t maxOut, bool stopAtMax, char** out, size_t* outLen,
               char* err, size_t errCap) override {
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
      if (stopAtMax && have >= maxOut) break;  // caller asked for exactly this many: stop mid-stream, success
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
    return s == 3   ? EpdFontFamily::BOLD_ITALIC
           : s == 1 ? EpdFontFamily::BOLD
           : s == 2 ? EpdFontFamily::ITALIC
                    : EpdFontFamily::REGULAR;
  }
  GfxRenderer& r_;
  std::string name_;
  void loadPermissions() {
    std::string json;
    if (!Storage.readFileToString(TAG, dir_ + "/manifest.json", 4096, json)) return;
    JsonDocument doc;
    if (deserializeJson(doc, json) != DeserializationError::Ok) return;
    for (JsonVariantConst p : doc["permissions"].as<JsonArrayConst>())
      if (p.is<const char*>() && !strcmp(p.as<const char*>(), "network"))
        net_ = true;
      else if (p.is<const char*>() && !strcmp(p.as<const char*>(), "library"))
        lib_ = true;
      else if (p.is<const char*>() && !strcmp(p.as<const char*>(), "listen"))
        listenReq_ = true;
      else if (p.is<const char*>() && !strcmp(p.as<const char*>(), "audio"))
        audioReq_ = true;
      else if (p.is<const char*>() && !strcmp(p.as<const char*>(), "microphone"))
        micReq_ = true;
      else if (p.is<const char*>() && !strcmp(p.as<const char*>(), "hotspot"))
        hotspotReq_ = true;
      else if (p.is<const char*>() && !strcmp(p.as<const char*>(), "espnow"))
        espnowReq_ = true;
      else if (p.is<const char*>() && !strcmp(p.as<const char*>(), "monitor"))
        monitorReq_ = true;
      else if (p.is<const char*>() && !strcmp(p.as<const char*>(), "tx"))
        txReq_ = true;
      else if (p.is<const char*>() && !strcmp(p.as<const char*>(), "bluetooth"))
        bleReq_ = true;
    for (int w = 0; w < 2; w++)
      for (JsonVariantConst v : doc["storage"][w ? "write" : "read"].as<JsonArrayConst>()) {
        char rel[104];
        if (requested_.size() < 8 && v.is<const char*>() &&
            crosslua::parseGrantPath(v.as<const char*>(), rel, sizeof(rel)))
          requested_.push_back({rel, w == 1});
      }
  }

  // --- listen sockets ---
  int netListen(int port, char* err, size_t errCap) override {
    WiFiServer* srv = new WiFiServer(port);
    if (!srv) {
      snprintf(err, errCap, "out of memory for server");
      return -1;
    }
    srv->begin();
    for (int i = 0; i < Backend::MAX_SOCKETS; i++) {
      if (sockUsed_[i]) continue;
      sockUsed_[i] = true;
      sockKind_[i] = 3;
      sockServers_[i] = srv;
      return i;
    }
    delete srv;
    snprintf(err, errCap, "no free slot");
    return -1;
  }
  int netAccept(int serverSlot) override {
    if (!sockUsed_[serverSlot] || sockKind_[serverSlot] != 3 || !sockServers_[serverSlot]) return -2;
    WiFiClient cl = sockServers_[serverSlot]->available();
    if (!cl) return -1;
    for (int i = 0; i < Backend::MAX_SOCKETS; i++) {
      if (sockUsed_[i]) continue;
      sockUsed_[i] = true;
      sockKind_[i] = 1;
      socks_[i] = cl;
      return i;
    }
    cl.stop();
    return -2;
  }
  // "permissions": ["network", "listen"]: the device may accept connections from the LAN. Needs the user's approval
  // (same screen
  // and stored record as the storage grants), so an app that merely declares it still reads as "not permitted".
  bool listenAllowed() override { return net_ && listenReq_ && approved_; }
  // --- audio (boards with the AUDIO cap; the SDK stub links elsewhere and begin() reports absence) ---
  AudioManager audio_;
  bool audioBegun_ = false;
  HalFile audioFile_;  // open while the playback task streams from the SD card
  bool audioAllowed() override { return audioReq_ && approved_; }
  bool audioPlay(const char* path, bool loop, char* err, size_t errCap) override {
    if (!audioBegun_) {
      if (!audio_.begin()) {
        snprintf(err, errCap, "no audio on this board");
        return false;
      }
      audioBegun_ = true;
    }
    if (audio_.isPlaying()) audio_.stop();
    if (!Storage.openFileForRead(TAG, path, audioFile_)) {
      snprintf(err, errCap, "cannot open the file");
      return false;
    }
    AudioManager::WavSource src;
    src.read = [this](uint8_t* dst, size_t len) -> int { return audioFile_ ? audioFile_.read(dst, len) : -1; };
    src.seek = [this](size_t pos) -> bool { return audioFile_ && audioFile_.seek(pos); };
    if (!audio_.play(src, loop)) {
      audioFile_.close();
      snprintf(err, errCap, "cannot play (not a 16-bit PCM WAV, or the codec refused it)");
      return false;
    }
    return true;
  }
  void audioStop() override {
    audio_.stop();
    if (audioFile_) audioFile_.close();
  }
  void audioVolume(int pct) override {
    if (!audioBegun_ && !audio_.begin()) return;
    audio_.setVolume(static_cast<uint8_t>(pct));
  }
  bool audioPlaying() override { return audioBegun_ && audio_.isPlaying(); }
  // --- microphone: begun on first use, released in ~Backend. 16 kHz mono PCM; the WAV is streamed to the card in
  // 512-byte blocks (no heap buffer), the header sizes are patched at the end. Back (physical or serial-injected)
  // cancels.
  freeink::Microphone mic_;
  bool micAllowed() override { return micReq_ && approved_; }
  bool micBegin(char* err, size_t errCap) {
    if (mic_.present()) return true;
    if (!BoardConfig::hasMic() || !mic_.begin(16000)) {
      snprintf(err, errCap, "no microphone on this board");
      return false;
    }
    return true;
  }
  bool backCancelRequested() {
    devcapture::pollSerial();
    in_.update(true);
    if (!(in_.wasPressed(MappedInputManager::Button::Back) || in_.isPressed(MappedInputManager::Button::Back)))
      return false;
    for (int i = 0; i < 200 && in_.isPressed(MappedInputManager::Button::Back);
         i++) {  // swallow the release like http/connect
      delay(10);
      in_.update(true);
    }
    events.clear();
    evPos.clear();
    evKey.clear();
    return true;
  }
  static void le32(uint8_t* p, uint32_t v) {
    p[0] = v;
    p[1] = v >> 8;
    p[2] = v >> 16;
    p[3] = v >> 24;
  }
  static void wavHeader(uint8_t h[44], uint32_t dataBytes) {
    memcpy(h, "RIFF\0\0\0\0WAVEfmt \x10\0\0\0\x01\0\x01\0", 24);  // up to and including the channel count
    le32(h + 4, 36 + dataBytes);
    le32(h + 24, 16000);      // sample rate
    le32(h + 28, 16000 * 2);  // byte rate
    h[32] = 2;
    h[33] = 0;  // block align
    h[34] = 16;
    h[35] = 0;  // bits per sample
    memcpy(h + 36, "data", 4);
    le32(h + 40, dataBytes);
  }
  bool micRecord(const char* path, int seconds, int* bytes, char* err, size_t errCap) override {
    if (!micBegin(err, errCap)) return false;
    HalFile f = Storage.open(path, O_WRONLY | O_CREAT | O_TRUNC);
    if (!f) {
      snprintf(err, errCap, "cannot open the file for writing");
      return false;
    }
    uint8_t hdr[44];
    wavHeader(hdr, 0);
    if (f.write(hdr, sizeof(hdr)) != sizeof(hdr)) {
      f.close();
      Storage.remove(path);
      snprintf(err, errCap, "write error");
      return false;
    }
    const uint32_t wantBytes = static_cast<uint32_t>(seconds) * 16000u * 2u;
    uint32_t got = 0;
    int16_t buf[256];
    uint32_t lastData = millis();
    while (got < wantBytes) {
      if (backCancelRequested()) {
        f.close();
        Storage.remove(path);
        snprintf(err, errCap, "cancelled");
        return false;
      }
      const size_t room = std::min<size_t>(256, (wantBytes - got) / 2);
      const int n = mic_.read(buf, room, 100);
      if (n < 0) {
        f.close();
        Storage.remove(path);
        snprintf(err, errCap, "microphone read failed");
        return false;
      }
      if (n == 0) {
        if (millis() - lastData > 2000) {
          f.close();
          Storage.remove(path);
          snprintf(err, errCap, "microphone stopped delivering data");
          return false;
        }
        continue;
      }
      lastData = millis();
      if (f.write(reinterpret_cast<uint8_t*>(buf), n * 2) != static_cast<size_t>(n) * 2) {
        f.close();
        Storage.remove(path);
        snprintf(err, errCap, "write error (card full?)");
        return false;
      }
      got += static_cast<uint32_t>(n) * 2;
    }
    wavHeader(hdr, got);
    const bool patched = f.seek(0) && f.write(hdr, sizeof(hdr)) == sizeof(hdr);
    f.close();
    if (!patched) {
      Storage.remove(path);
      snprintf(err, errCap, "write error");
      return false;
    }
    *bytes = static_cast<int>(got + 44);
    return true;
  }
  bool micLevel(int ms, int* peak, char* err, size_t errCap) override {
    if (!micBegin(err, errCap)) return false;
    int16_t buf[256];
    int p = 0;
    const uint32_t t0 = millis();
    while (millis() - t0 < static_cast<uint32_t>(ms)) {
      if (backCancelRequested()) {
        snprintf(err, errCap, "cancelled");
        return false;
      }
      const int n = mic_.read(buf, 256, 50);
      if (n < 0) {
        snprintf(err, errCap, "microphone read failed");
        return false;
      }
      for (int i = 0; i < n; i++) {
        const int a = buf[i] < 0 ? -static_cast<int>(buf[i]) : buf[i];
        if (a > p) p = a;
      }
    }
    *peak = p > 32767 ? 32767 : p;
    return true;
  }

  // --- mDNS ---
  // ESPmDNS needs begin() (responder + query machinery) before queryService works; without it the
  // query returns 0 in microseconds. Track it globally: the radio teardown / reboot resets it.
  bool mdnsBegun_ = false;
  int mdnsQuery(const char* service, const char* proto, char* err, size_t errCap) override {
    if (!mdnsBegun_) {
      if (!MDNS.begin("crosspoint")) {
        snprintf(err, errCap, "mDNS could not start");
        return -1;
      }
      mdnsBegun_ = true;
    }
    int n = MDNS.queryService(service, proto);
    if (n < 0) {
      snprintf(err, errCap, "mDNS query failed");
      return -1;
    }
    return n;
  }
  bool mdnsResult(int i, char* hostname, size_t hnCap, char* ip, size_t ipCap, int* port, char* instanceName,
                  size_t inCap) override {
    if (i < 0) return false;
    auto addr = MDNS.address(i);
    if (!addr) return false;
    snprintf(ip, ipCap, "%s", addr.toString().c_str());
    snprintf(hostname, hnCap, "%s", MDNS.hostname(i).c_str());
    *port = MDNS.port(i);
    snprintf(instanceName, inCap, "%s", MDNS.instanceName(i).c_str());
    return true;
  }

  MappedInputManager& in_;
  bool net_ = false;
  bool lib_ = false;
  bool listenReq_ = false;   // manifest asked for "listen" (effective only after approval)
  bool audioReq_ = false;    // manifest asked for "audio" (effective only after approval)
  bool micReq_ = false;      // manifest asked for "microphone" (effective only after approval)
  bool hotspotReq_ = false;  // manifest asked for "hotspot" (effective only after approval)
  bool espnowReq_ = false;   // manifest asked for "espnow" (effective only after approval)
  bool monitorReq_ = false;  // manifest asked for "monitor" (effective only after approval)
  bool txReq_ = false;       // manifest asked for "tx" (effective only after approval)
  bool bleReq_ = false;      // manifest asked for "bluetooth" (effective only after approval)
  bool bleFailed_ = false;   // the last connect failed (reason in bleReason_)
  bool bleHasPasskey_ = false;
  uint32_t blePasskey_ = 0;
  char bleReason_[64] = {0};
  char bleTarget_[18] = {0};  // the address a connect was asked for
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

namespace luabt {
bool held() { return g_bluetoothHeld.load(); }
}  // namespace luabt

// While the Bluetooth stack is up the controller needs a steady CPU clock: asking for "no loop delay" makes the main
// loop run at full speed instead of clocking down after a quiet spell (the same request the web-server screens make).
bool LuaAppActivity::skipLoopDelay() { return backend_ && backend_->bleUp_; }

void LuaAppActivity::logMemory(const char* when) const {
  const auto h = HalMemory::getInternalHeap();
  LOG_INF(TAG, "%s: lua used=%u peak=%u budget=%u | heap free=%u min=%u largest=%u", when,
          vm_ ? static_cast<unsigned>(vm_->usedBytes()) : 0u, vm_ ? static_cast<unsigned>(vm_->peakBytes()) : 0u,
          vm_ ? static_cast<unsigned>(vm_->budgetBytes()) : 0u, static_cast<unsigned>(h.freeBytes),
          static_cast<unsigned>(h.minFreeBytes), static_cast<unsigned>(h.largestBlockBytes));
}

void LuaAppActivity::onEnter() {
  Activity::onEnter();
  g_radioUsedThisSession = false;
  startApp();
}

// (Re)starts the app from entry_ in a fresh VM. Also used by app.restart().
void LuaAppActivity::startApp() {
  errorShown_ = false;
  waitDeadline_ = 0;

  // Start from a quiet radio. Screens earlier in the same menu (the Plugin Hub, a book sync...) can leave WiFi up,
  // which holds ~56 KB and would make every Lua app fail to start with "free RAM too low". An app that wants WiFi asks
  // for it.
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
    if (backend_->grantsApprovedOnDisk())
      backend_->approveGrants();
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
    showError("Not enough memory",
              "Free RAM too low to start a Lua app (" + std::to_string(heap.freeBytes) + " bytes free).");
    return;
  }
  const size_t budget = std::clamp(heap.freeBytes - LUA_RESERVE_BYTES, LUA_MIN_BUDGET, LUA_MAX_BUDGET);

  const std::string path = appDir_ + "/" + entry_;
  std::string src;
  if (!Storage.readFileToString(TAG, path, MAX_SCRIPT_BYTES, src)) {
    showError("Cannot load app",
              path + " is missing, empty, or larger than " + std::to_string(MAX_SCRIPT_BYTES) + " bytes.");
    return;
  }
  if (!vm_->open(budget)) {
    showError("Out of memory", "Could not create the Lua state.");
    return;
  }
  vm_->setHeapGuard([](void* ud) -> size_t { return static_cast<Backend*>(ud)->freeHeapQuick(); }, backend_.get(),
                    LUA_HEAP_FLOOR);
  backend_->setFloorFn = [this](size_t b) {
    if (vm_) vm_->setHeapFloor(b);
  };
  backend_->getFloorFn = [this]() -> size_t { return vm_ ? vm_->heapFloor() : 0; };
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
  if (g_radioUsedThisSession || WiFi.getMode() != WIFI_MODE_NULL) {
    LOG_INF(TAG, "wifi was used: silent restart to defragment the heap");
    WiFi.disconnect(false);
    delay(30);
    silentRestart();
  }
}

void LuaAppActivity::askGrants() {
  bool danger = false;
  const std::string body = backend_->grantSummary(&danger);
  auto confirmation = makeUniqueNoThrow<ConfirmationActivity>(renderer, mappedInput, backend_->grantTitle(appName_),
                                                              body, "Deny", "Allow");
  if (!confirmation) {
    showError("Out of memory", "Could not show the permission screen.");
    return;
  }
  startActivityForResult(std::move(confirmation), [this](const ActivityResult& r) {
    if (r.isCancelled || !backend_) {
      LOG_INF(TAG, "permission request denied: the app does not start");
      leave();
      return;
    }
    backend_->storeApproval();
    backend_->approveGrants();
    LOG_INF(TAG, "permission request approved");
    startVm();
  });
}

void LuaAppActivity::launchWifi() {
  WiFi.mode(WIFI_STA);
  startActivityForResult(std::make_unique<WifiSelectionActivity>(renderer, mappedInput),
                         [this](const ActivityResult& r) {
                           const bool ok = !r.isCancelled;
                           LOG_INF(TAG, "wifi.connect -> %s", ok ? "connected" : "not connected");
                           if (ok && vm_) vm_->setHeapFloor(LUA_HEAP_FLOOR_ONLINE);
                           renderer.clearScreen();
                           if (vm_ && vm_->status() == crosslua::Status::Waiting) {
                             vm_->resume(ok ? "wifi:ok" : "wifi:fail");
                             armWait();
                           }
                         });
}

void LuaAppActivity::launchKeyboard() {
  const InputType type = backend_->textMode == 1   ? InputType::Password
                         : backend_->textMode == 2 ? InputType::Url
                                                   : InputType::Text;
  startActivityForResult(
      std::make_unique<KeyboardEntryActivity>(renderer, mappedInput, backend_->textTitle, backend_->textInitial,
                                              static_cast<size_t>(backend_->textMax), type),
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
  auto push = [&](const char* name, int x = -1, int y = -1, const crosslua::Backend::KeyInfo* key = nullptr) {
    if (backend_ && backend_->events.size() < EVENT_QUEUE_MAX) {
      backend_->events.push_back(name);
      backend_->evPos.push_back({x, y});
      backend_->evKey.push_back({key != nullptr, key ? *key : crosslua::Backend::KeyInfo{}});
    }
  };
  // Force-quit gesture first: it suppresses the matching release so Back never reaches the app.
  if (mappedInput.wasLongPressed(B::Back, EXIT_HOLD_MS)) {
    LOG_INF(TAG, "force quit (Back held)");
    leave();
    return;
  }
  if (backend_ &&
      backend_->bleUp_) {  // Bluetooth keyboard: drive the stack's reconnect/repeat timers, then queue what was typed
    BleHid.poll();
    freeink::KeyEvent ev;
    while (BleHid.popKey(ev)) {
      const crosslua::Backend::KeyInfo k = {ev.ch, static_cast<uint8_t>(ev.special), ev.mods, ev.keycode};
      push("key", -1, -1, &k);
    }
  }
  if (mappedInput.wasLongPressed(B::Confirm, BUTTON_HOLD_MS)) push("confirm_hold");
  if (mappedInput.wasLongPressed(B::Left, BUTTON_HOLD_MS)) push("left_hold");
  if (mappedInput.wasLongPressed(B::Right, BUTTON_HOLD_MS)) push("right_hold");
  if (mappedInput.wasLongPressed(B::Up, BUTTON_HOLD_MS)) push("up_hold");
  if (mappedInput.wasLongPressed(B::Down, BUTTON_HOLD_MS)) push("down_hold");
  // Back has no "<name>_hold": holding Back past EXIT_HOLD_MS is the force-quit escape, not an app gesture.
  if (mappedInput.wasReleased(B::Back)) push("back");
  if (mappedInput.wasReleased(B::Confirm)) push("confirm");
  if (mappedInput.wasReleased(B::Left)) push("left");
  if (mappedInput.wasReleased(B::Right)) push("right");
  if (mappedInput.wasReleased(B::Up)) push("up");
  if (mappedInput.wasReleased(B::Down)) push("down");
#if FREEINK_CAP_TOUCH
  if (mappedInput
          .hasTouch()) {  // touch boards: "press" (finger down), "long", "tap", "release" with input.pos() = x, y
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
  if (leaving_ || g_inDeepSleepCall) return;
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
