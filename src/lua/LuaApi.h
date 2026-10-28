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
  // RAM floor for starting a radio mode; lower after the first radio use in this app (the radio's RAM never fully
  // returns).
  virtual size_t radioFloorBytes() { return 80 * 1024; }
  // --- deep sleep: system.sleep(seconds) arms a timer wake (plus the power button) and enters the SAME upstream sleep
  // flow (sleep screen, plugin events, rail power-down); the call never returns and the device reboots on wake.
  // system.last_wake() reports what woke the previous cycle. No permission: the power button always wakes the device.
  // ---
  virtual const char* wakeCause() { return "power-on"; }  // "timer" | "button" | "power-on" | "other"
  virtual bool systemSleep(int seconds, char* err,
                           size_t errCap) = 0;  // true = armed and entering sleep (never returns on device)
  virtual size_t freeHeap() = 0;
  // Cheap free-RAM read for the allocator guard (runs on every growing allocation); defaults to freeHeap().
  virtual size_t freeHeapQuick() { return freeHeap(); }
  virtual size_t minFreeHeap() = 0;
  virtual int battery() = 0;  // percent, or -1
  // Wall clock. epochNow() = UTC seconds, or 0 when the clock is not trustworthy (never synced / no RTC).
  virtual int64_t epochNow() = 0;
  // Local broken-down time for `epoch` -> out[0..7] = year, month(1-12), day(1-31), hour, min, sec, wday(1=Sunday),
  // yday(1-366).
  virtual bool localDate(int64_t epoch, int out[8]) = 0;
  virtual void log(const char* msg) = 0;

  // --- storage ---------------------------------------------------------------
  // Absolute SD paths only. Sandboxing/validation happens in the API layer, never here.
  // Rule: no callbacks into Lua from these (a lua_error would longjmp over backend frames).
  virtual int64_t fsSize(const char* path) = 0;  // bytes; -1 = missing; -2 = directory
  struct FsStat {
    bool isDir = false;
    int64_t size = 0;      // bytes; 0 for a folder
    uint32_t fatTime = 0;  // FAT modification stamp packed as (date << 16) | time; 0 = unknown
  };
  virtual bool fsStat(const char* path, FsStat* out) = 0;                               // false: missing
  virtual bool fsReadInto(const char* path, void* dst, size_t n, size_t offset) = 0;    // exactly n bytes from offset
  virtual bool fsWrite(const char* path, const void* data, size_t n, bool append) = 0;  // atomic unless append
  // In-place write at `offset` (<= file size; may extend the file). NOT atomic: meant for small fixed-size records.
  virtual bool fsWriteAt(const char* path, size_t offset, const void* data, size_t n) = 0;
  // Writes the CURRENT drawing buffer as a 1-bit BMP (the firmware's own screenshot writer: streams rows, no heap).
  virtual bool saveScreenBmp(const char* absPath, char* err, size_t errCap) = 0;
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
    const char* method;  // "GET", "POST", "PUT", "PATCH" or "DELETE"
    const char* url;
    const HttpHeader* headers;
    int headerCount;
    const char* body;
    size_t bodyLen;
    const char* savePath;               // absolute SD path to stream the response to, or nullptr = return it in memory
    size_t maxBody;                     // in-memory response cap (bytes)
    const char* contentType = nullptr;  // Content-Type of the body (set whenever a body is sent), else nullptr
    const char* caPem = nullptr;        // verify the https server against this PEM; nullptr = unverified (the default)
    bool wantHeaders = false;           // return the response headers in HttpResult::headers
  };
  struct HttpResult {
    int status = 0;        // final HTTP status, 0 when no response arrived
    char* body = nullptr;  // malloc'd by the backend, freed by the caller; null in save mode
    size_t bodyLen = 0;
    size_t bytes = 0;         // bytes received (save mode: bytes written)
    char error[96] = {0};     // set when the call failed (no/aborted response)
    char* headers = nullptr;  // malloc'd "Name: value\n" lines (<= 4 KB), freed by the caller; only when wantHeaders
    size_t headersLen = 0;
  };
  virtual bool netAllowed() = 0;  // the app's manifest declares "network"

  // --- raw TCP client sockets (net.*): a fixed table of MAX_SOCKETS slots; handles seen by Lua are slot + 1
  // -------------
  static constexpr int MAX_SOCKETS = 8;
  // Slot kinds (netKind): 0 free, 1 TCP (net.connect), 2 UDP (net.udp_open), 3 server (net.listen). Handles seen by Lua
  // are slot + 1.
  virtual bool netLocal(char* ip, char* mask, char* gateway, char* dns, size_t cap) = 0;  // false: WiFi is down
  virtual bool netResolve(const char* host, char* ip, size_t ipCap, char* err, size_t errCap) = 0;
  virtual int netConnect(const char* host, int port, int timeoutMs, char* err, size_t errCap) = 0;  // slot, or -1 + err
  // TLS client (slot kind 4, at most one open: the session costs ~40 KB). caPem != nullptr verifies the server against
  // that PEM (the connection fails when it does not match); nullptr = encrypted but UNVERIFIED (the app asked for
  // insecure).
  virtual int netConnectTls(const char* host, int port, int timeoutMs, const char* caPem, char* err, size_t errCap) = 0;
  virtual bool netIsOpen(int slot) = 0;                            // the handle is allocated (even if the peer closed)
  virtual int netKind(int slot) = 0;                               // 0 free, 1 TCP, 2 UDP
  virtual int netAvailable(int slot) = 0;                          // bytes waiting; -1 when the slot is not open
  virtual int netRead(int slot, void* buf, size_t max) = 0;        // > 0 bytes; 0 nothing now; -1 closed
  virtual int netWrite(int slot, const void* data, size_t n) = 0;  // bytes written; -1 error / closed
  virtual bool netConnected(int slot) = 0;  // false once the peer closed and nothing is left to read
  virtual void netClose(int slot) = 0;

  // UDP on the same slot table: non-blocking receive, one datagram per call.
  virtual int udpOpen(int port, char* err, size_t errCap) = 0;  // slot, or -1 + err (port 0 = system-assigned)
  virtual int udpSend(int slot, const char* host, int port, const void* data, size_t n, char* err,
                      size_t errCap) = 0;  // bytes, or -1
  virtual int udpRecv(int slot, void* buf, size_t max, char* ip, size_t ipCap,
                      int* port) = 0;  // n bytes; 0 nothing waiting; -1 closed

  // --- listen (server) sockets: kind 3 on the same slot table ---
  virtual int netListen(int port, char* err, size_t errCap) = 0;  // server slot, or -1 + err
  virtual int netAccept(int serverSlot) = 0;  // client slot (kind 1), or -1 (nothing waiting), or -2 (error)
  virtual bool listenAllowed() = 0;           // the app's manifest declares "listen" AND the user approved it
  // --- audio output (boards with the AUDIO cap; others report "no audio on this board") ---
  virtual bool audioAllowed() = 0;  // "audio" manifest permission AND the user approved it
  virtual bool audioPlay(const char* path, bool loop, char* err, size_t errCap) = 0;
  virtual void audioStop() = 0;
  virtual void audioVolume(int pct) = 0;  // 0..100
  virtual bool audioPlaying() = 0;
  // --- microphone (boards with the MIC cap; others report "no microphone on this board") ---
  virtual bool micAllowed() = 0;  // "microphone" manifest permission AND the user approved it
  // Blocking capture of `seconds` of 16 kHz mono 16-bit PCM into a WAV at `path`; Back cancels (err "cancelled",
  // partial file removed).
  virtual bool micRecord(const char* path, int seconds, int* bytes, char* err, size_t errCap) = 0;
  // Peak absolute sample (0..32767) over `ms` of capture, nothing stored.
  virtual bool micLevel(int ms, int* peak, char* err, size_t errCap) = 0;

  // --- mDNS query (ESPmDNS, like biscuit MdnsBrowserActivity) ---
  virtual int mdnsQuery(const char* service, const char* proto, char* err, size_t errCap) = 0;  // >= 0 count, -1 error
  virtual bool mdnsResult(int i, char* hostname, size_t hnCap, char* ip, size_t ipCap, int* port, char* instanceName,
                          size_t inCap) = 0;

  virtual bool wifiConnected() = 0;
  // The network layer can carry traffic: WiFi joined as a client OR this device's own hotspot is up. net.* gates on
  // this; http.* (which needs the internet) keeps asking wifiConnected().
  virtual bool netReady() { return wifiConnected(); }
  // --- hotspot (access point): the app starts its own WiFi network; needs "network" + "hotspot" and the user's
  // approval ---
  virtual bool hotspotAllowed() = 0;
  // password == nullptr: an OPEN network. ip receives the hotspot's address. false + err on failure.
  virtual bool softApStart(const char* ssid, const char* password, int channel, int maxClients, char* ip, size_t ipCap,
                           char* err, size_t errCap) = 0;
  virtual bool softApInfo(char* ssid, size_t ssidCap, char* ip, size_t ipCap,
                          int* clients) = 0;  // false: no hotspot running
  // --- ESP-NOW (connectionless frames between nearby devices); needs "network" + "espnow" and the user's approval. The
  // radio is exclusive with WiFi and the hotspot. Receiving fills a small ring from the WiFi task; Lua only ever polls
  // it. ---
  virtual bool espnowAllowed() = 0;
  virtual bool espnowRunning() { return false; }
  virtual bool espnowStart(int channel, uint8_t mac[6], char* err, size_t errCap) = 0;
  virtual void espnowStop() = 0;
  virtual bool espnowSend(const uint8_t mac[6], bool broadcast, const void* data, size_t n, char* err,
                          size_t errCap) = 0;
  virtual int espnowRecv(void* buf, size_t cap, uint8_t mac[6]) = 0;        // bytes (> 0), or 0 when nothing is waiting
  virtual bool espnowInfo(uint8_t mac[6], int* channel, int* dropped) = 0;  // false: not started
  // --- wifi.monitor (promiscuous 802.11 capture + optional native PCAP writer); needs "network" + "monitor" and
  // approval. The radio is exclusive with WiFi/the hotspot/espnow. The callback fills a small ring from the WiFi task;
  // Lua only polls it. ---
  virtual bool monitorAllowed() = 0;
  virtual bool monitorRunning() { return false; }
  virtual bool monitorChannel(int* channel) { return monitorRunning() ? (*channel = 1, true) : false; }
  virtual bool txChannel(int* channel) { return txRunning() ? (*channel = 1, true) : false; }
  virtual bool monitorStart(int channel, const char* pcapPath, char* err,
                            size_t errCap) = 0;  // pcapPath: nullptr = no file
  virtual void monitorStop(uint32_t* pcapBytes) = 0;
  virtual int monitorRecv(void* buf, size_t cap, int* rssi,
                          int* channel) = 0;  // bytes (> 0), or 0 when nothing is waiting
  virtual bool monitorSetChannel(int channel, char* err,
                                 size_t errCap) = 0;  // hop live; needs the monitor or the injector running
  virtual bool monitorInfo(int* channel, int* captured, int* dropped, char* path, size_t pathCap,
                           uint32_t* pcapBytes) = 0;
  // --- wifi.tx (raw 802.11 injection); needs "network" + "tx" and the user's approval. Exclusive with
  // WiFi/hotspot/espnow but COEXISTS with the monitor on the same channel (a start without a channel adopts the other
  // mode's channel). ---
  virtual bool txAllowed() = 0;
  virtual bool txRunning() { return false; }
  virtual bool txStart(int channel, char* err, size_t errCap) = 0;
  virtual void txStop() = 0;
  virtual bool txSend(const void* frame, size_t n, char* err, size_t errCap) = 0;  // frame without the FCS
  virtual bool txInfo(int* channel, int* sent) = 0;                                // false: not running
  // --- ble: Bluetooth LE central. Mode "keyboard": scan for / pair with a BLE HID keyboard; its key presses arrive as
  // "key" events (input.key() has the details). Needs the "bluetooth" permission and the user's approval. ONE stack at
  // a time (~50 KB of RAM), EXCLUSIVE with every WiFi mode. Everything is polled: the stack's tasks fill small buffers
  // and Lua reads them. ---
  struct BleDevice {
    char addr[18];  // "AA:BB:CC:DD:EE:FF"
    char name[32];  // falls back to the address when none was advertised
    int rssi;
    bool connectable;
    bool hid;  // advertises the HID service: a keyboard, a remote, a page turner
  };
  static constexpr int BLE_MAX_DEVICES = 24;
  enum BleLink { BLE_IDLE = 0, BLE_CONNECTING = 1, BLE_CONNECTED = 2, BLE_FAILED = 3 };
  struct BleState {
    int link;  // BleLink
    bool scanning;
    char addr[18];  // the peer while connecting / connected, "" otherwise
    char name[32];
    bool hasPasskey;  // pairing is waiting for the passkey to be typed on the keyboard
    uint32_t passkey;
    char reason[64];  // why the last connect failed
  };
  struct KeyInfo {
    char ch;          // printable ASCII, or 0 for a special key
    uint8_t special;  // 0 = none, else the index into the binding's key-name table (SpecialKey order)
    uint8_t
        mods;  // HID modifier bitmask (bit0 lctrl, bit1 lshift, bit2 lalt, bit3 lgui, bits 4..7 the right-hand ones)
    uint8_t code;  // raw HID usage id
  };
  virtual bool bleSupported() { return false; }  // compiled into this firmware (FREEINK_CAP_BLE_HID_HOST)
  virtual bool bleAllowed() = 0;
  virtual bool bleRunning() { return false; }
  virtual bool bleStart(const char* mode, char* err, size_t errCap) = 0;
  virtual void bleStop() = 0;
  virtual bool bleScan(int ms, char* err, size_t errCap) = 0;  // async: the stack scans on its own task
  virtual void bleScanStop() = 0;
  virtual int bleDevices(BleDevice* out, int cap) = 0;  // snapshot of what the scan has seen, at most `cap`
  virtual bool bleConnect(const char* addr, int addrType, char* err, size_t errCap) = 0;  // async: ble.state() reports
  virtual void bleDisconnect() = 0;
  virtual void bleState(BleState* s) = 0;
  virtual int blePaired(BleDevice* out, int cap) = 0;  // bonded peers (kept in NVS), at most `cap`
  virtual bool bleForget(const char* addr) = 0;
  // Mode "raw": the NimBLE observer straight (no HID host). ble.start("raw") brings the stack up; scripts read every
  // advertisement (advertising data followed by the scan response, as received) and parse it themselves. EXCLUSIVE with
  // mode "keyboard".
  enum BleMode { BLE_MODE_NONE = 0, BLE_MODE_KEYBOARD = 1, BLE_MODE_RAW = 2, BLE_MODE_GATT = 3 };
  struct BleAdvert {
    char addr[18];     // "AA:BB:CC:DD:EE:FF"
    uint8_t addrType;  // 0 public, 1 random (NimBLE's own numbering: 2 and 3 are "RPA resolved to public/random")
    int rssi;          // dBm of the last packet
    uint8_t advType;   // the legacy advertising event type: 0 ADV_IND, 1 ADV_DIRECT_IND, 2 ADV_SCAN_IND, 3
                       // ADV_NONCONN_IND, 4 SCAN_RSP
    bool connectable, scannable;
    uint8_t advLen;    // bytes of `data` that came in the advertisement itself (the rest is the scan response)
    uint8_t len;       // bytes in `data`
    uint8_t data[62];  // advertisement (<= 31) followed by the scan response (<= 31)
    uint32_t ageMs;    // milliseconds since the last packet from it
  };
  static constexpr int BLE_MAX_ADVERTS = 32;
  virtual int bleMode() { return BLE_MODE_NONE; }
  virtual bool bleObserve(int ms, bool active, char* err, size_t errCap) {
    (void)ms;
    (void)active;
    if (errCap) err[0] = 0;
    return false;
  }
  virtual void bleObserveStop() {}
  virtual bool bleObserving() { return false; }
  // Snapshot of the table (first seen first), at most `cap`; *dropped = devices that did not fit since the observer
  // started.
  virtual int bleAdverts(BleAdvert* out, int cap, int* dropped) {
    (void)out;
    (void)cap;
    *dropped = 0;
    return 0;
  }
  // Mode "gatt": a generic BLE GATT client (the bare NimBLE central, no HID host). ble.connect(addr) links a
  // NimBLEClient; ble.state().link reports it; ble.services() lists the discovered characteristics; ble.read/write/
  // notify act on them by characteristic UUID; subscribed notifications arrive in a small buffer read with
  // ble.notifs(). UUIDs are the 16-bit short form (4 hex digits, e.g. "2a19") or the full 128-bit
  // "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" string, either case. One characteristic at a time for read/write/notify.
  struct BleGattChar {
    char service[37];  // the parent service's UUID, same spelling as `uuid`
    char uuid[37];     // the characteristic's UUID
    uint16_t handle;   // attribute handle (informational)
    uint8_t props;     // property bitmask: 0x01 broadcast, 0x02 read, 0x04 write-no-response, 0x08 write,
                       // 0x10 notify, 0x20 indicate, 0x40 auth-signed-write, 0x80 extended
  };
  static constexpr int BLE_MAX_GATT_CHARS = 64;
  struct BleGattNotif {
    char uuid[37];
    uint8_t len;
    uint8_t data[244];  // one ATT payload
  };
  static constexpr int BLE_MAX_GATT_NOTIFS = 32;
  // Fills up to `cap` discovered characteristics; returns the count, or -1 when not connected (call ble.connect and
  // wait for ble.state().link == "connected" first).
  virtual int bleGattServices(BleGattChar* out, int cap) {
    (void)out;
    (void)cap;
    return -1;
  }
  virtual bool bleGattRead(const char* uuid, uint8_t* data, size_t* len, size_t maxLen, char* err, size_t errCap) {
    (void)uuid;
    (void)data;
    (void)len;
    (void)maxLen;
    if (errCap) err[0] = 0;
    return false;
  }
  virtual bool bleGattWrite(const char* uuid, const uint8_t* data, size_t len, bool noResponse, char* err,
                            size_t errCap) {
    (void)uuid;
    (void)data;
    (void)len;
    (void)noResponse;
    if (errCap) err[0] = 0;
    return false;
  }
  virtual bool bleGattNotify(const char* uuid, bool on, char* err, size_t errCap) {
    (void)uuid;
    (void)on;
    if (errCap) err[0] = 0;
    return false;
  }
  // Snapshot of the pending notifications (oldest first), at most `cap`; returns the count.
  virtual int bleGattNotifs(BleGattNotif* out, int cap) {
    (void)out;
    (void)cap;
    return 0;
  }
  // Advertising (raw mode, the broadcaster role): ble.advertise() broadcasts a name and/or manufacturer data as an
  // advertisement (a beacon). The observer and the broadcaster share the one stack, so you can scan while you
  // advertise. name/data are optional (at most one may be empty, not both). data <= 31 bytes.
  virtual bool bleAdvertise(const char* name, const uint8_t* data, size_t dataLen, bool connectable, int intervalMs,
                            char* err, size_t errCap) {
    (void)name;
    (void)data;
    (void)dataLen;
    (void)connectable;
    (void)intervalMs;
    if (errCap) err[0] = 0;
    return false;
  }
  virtual void bleAdvertiseStop() {}
  virtual bool bleAdvertising() { return false; }
  // Details of the "key" event popEvent() returned last; false for any other event.
  virtual bool eventKey(KeyInfo* k) {
    (void)k;
    return false;
  }
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
  // EPUB title/author via the firmware's own metadata-only OPF parse (Epub::loadMetadata). Strings may be cut at the
  // cap.
  virtual bool epubMeta(const char* path, char* title, size_t titleCap, char* author, size_t authorCap, char* err,
                        size_t errCap) = 0;
  virtual int zipList(const char* path, ZipEntryInfo* out, int maxEntries, int* total, char* err, size_t errCap) = 0;
  // Inflates one entry into a malloc'd buffer (caller free()s). Refuses entries over maxBytes.
  virtual bool zipRead(const char* path, const char* name, size_t maxBytes, char** data, size_t* len, char* err,
                       size_t errCap) = 0;
  // Ask the host to open `absPath` in the reader (replaces the app). false = no such file.
  virtual bool openBook(const char* absPath) = 0;
  // app.restart(entry): ask the host to tear this VM down and start `entry` (a .lua file in the app folder) in a fresh
  // one.
  // --- storage grants: manifest "storage": {"read": [...], "write": [...]}. Only grants the user APPROVED are visible
  // here (an unapproved request reads as zero grants). Paths are normalised, relative, never hidden; "" = the whole
  // card.
  virtual void randomBytes(uint8_t* out, size_t n) = 0;  // hardware RNG
  // The device's random 32-byte secret (upstream's deviceSecret(): kept in NVS, survives SD swaps, never on the card).
  // It never reaches a script: crypto.device_key() derives a per-app, per-label key from it. false when the key storage
  // is unreadable.
  virtual bool deviceKeyMaterial(uint8_t out[32]) = 0;
  // DEV BUILDS ONLY (CROSSLUA_DEV): change the heap-guard floor at runtime to MEASURE a safe value. Release builds:
  // false.
  virtual bool devSetFloor(size_t bytes) {
    (void)bytes;
    return false;
  }
  // net.read copies data OUT of the network stack's buffers, which is what relieves memory pressure: for that one
  // allocation the host lowers the heap-guard floor (on=true) and restores it right after (on=false), even if the
  // allocation failed.
  virtual void heapRelax(bool on) { (void)on; }

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

  // --- sensors / outputs (each is a no-op or `false` on boards without the hardware)
  // -----------------------------------
  struct Motion {
    float ax, ay, az;  // acceleration, g
    float gx, gy, gz;  // angular rate, deg/s (zero on accelerometer-only parts)
    bool gyro;
  };
  enum class SensorStatus : uint8_t { Ok, Absent, ReadFailed };
  virtual SensorStatus motionRead(Motion* out) = 0;
  virtual SensorStatus envRead(float* tempC, float* humidityPct) = 0;
  virtual bool toneStart(int freqHz, int ms) = 0;            // false: no buzzer
  virtual bool toneStop() = 0;                               // false: no buzzer
  virtual int ledCount() = 0;                                // 0: no LEDs
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
