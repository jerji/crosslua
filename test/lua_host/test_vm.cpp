// Host-side tests for the CrossLua VM core + API bindings (no device needed).
// Build/run: test/lua_host/run.sh
#include <dirent.h>

#include <algorithm>
#include <cassert>
#include <cmath>
#include <ctime>
#include <fstream>
#include <functional>
#include <sstream>
extern "C" {
#include "lauxlib.h"
#include "lua.h"
#include "src/lua/PermText.h"
}
#include <InflateReader.h>

#include <cstdio>
#include <cstring>
#include <deque>
#include <map>
#include <set>
#include <string>
#include <vector>

static const char DEFL_RAW[] =
    "\013\311HU(,\315L\316VH*\312/\317SH\313\257P\310*\315-(V\310/"
    "K-R(\001J\347$VU*\244\344\247\353)\204\214*\036U<\252\230\332\212\001";
static const size_t DEFL_RAW_LEN = 55;
static const char DEFL_ZLIB[] = "x\234\253\312\311L\322-/J,(HMQ(H\254\314\311OL\261Rx4gr\325p\227\000\000*vf\275";
static const size_t DEFL_ZLIB_LEN = 37;
static const char DEFL_BAD[] = "\x73\x00\x99\x99";

extern "C" {
// uzlib references these from its gzip/zlib header helpers; InflateReader never calls them (the
// firmware linker drops them).
unsigned int uzlib_adler32(const void*, unsigned int, unsigned int) { return 0; }
unsigned int uzlib_crc32(const void*, unsigned int, unsigned int) { return 0; }
}

#include "src/lua/LuaApi.h"
#include "src/lua/LuaInternal.h"
#include "src/lua/LuaVm.h"

using namespace crosslua;

struct MockBackend : Backend {
  std::vector<std::string> calls;
  std::deque<std::string> events;
  std::vector<std::string> logs;
  bool exitReq = false;
  uint32_t now = 0;
  int w() { return 800; }
  int width() override { return 800; }
  int height() override { return 480; }
  void clear(bool white) override { calls.push_back(white ? "clear:white" : "clear:black"); }
  void pixel(int x, int y, bool b) override { calls.push_back("pixel:" + std::to_string(x) + "," + std::to_string(y)); }
  void line(int a, int b, int c, int d, bool) override {
    calls.push_back("line:" + std::to_string(a) + "," + std::to_string(b) + "," + std::to_string(c) + "," +
                    std::to_string(d));
  }
  void rect(int x, int y, int ww, int h, bool b, bool f) override {
    calls.push_back("rect:" + std::to_string(x) + "," + std::to_string(y) + "," + std::to_string(ww) + "," +
                    std::to_string(h) + (f ? ":fill" : ":line") + (b ? ":b" : ":w"));
  }
  void text(int font, int x, int y, const char* s, bool b, int st) override {
    calls.push_back("text:" + std::to_string(x) + "," + std::to_string(y) + ":" + s + ":f" + std::to_string(font) +
                    ":s" + std::to_string(st) + (b ? ":b" : ":w"));
  }
  int textWidth(int, const char* s, int) override { return static_cast<int>(strlen(s)) * 10; }
  int lineHeight(int) override { return 20; }
  int fontId(const char* n) override {
    // Same names as the firmware backend (LuaAppActivity.cpp). Real font IDs are hashes and often
    // NEGATIVE (SMALL_FONT_ID is), so the mock uses negative ids for half of them; 0 = unknown.
    static const char* const names[] = {"ui", "small", "ui12", "sans12", "sans14", "sans16", "sans18"};
    static const int ids[] = {1, -2, 3, -4, 5, -6, 7};
    for (int i = 0; i < 7; i++)
      if (!strcmp(n, names[i])) return ids[i];
    return 0;
  }
  void present(int m) override { calls.push_back("present:" + std::to_string(m)); }
  const char* popEvent() override {
    havePos = false;  // an empty poll or a button event has no position
    haveKey = false;  // ...and no key details either
    // an "@ms" token holds every later event back until the mock clock reaches ms (a user who
    // walks away and comes back)
    while (!events.empty() && events.front()[0] == '@') {
      if (now >= static_cast<uint32_t>(std::stoul(events.front().substr(1))))
        events.pop_front();
      else
        return nullptr;
    }
    if (events.empty()) return nullptr;
    static std::string hold;
    hold = events.front();
    events.pop_front();
    if (hold == "key" && !keyQ.empty()) {
      lastKey = keyQ.front();
      keyQ.pop_front();
      haveKey = true;
    }
    if (!evPos.empty()) {
      const auto p = evPos.front();
      evPos.pop_front();
      havePos = p.first >= 0;
      posX = p.first;
      posY = p.second;
    }
    return hold.c_str();
  }
  uint32_t millis() override { return now; }
  size_t freeHeapVal = 123456;
  size_t freeHeap() override { return freeHeapVal; }
  size_t simTotal = 0;  // >0: freeHeapQuick() simulates a device heap of this size minus what Lua holds
  const LuaVm* simVm = nullptr;
  size_t freeHeapQuick() override { return simTotal ? simTotal - simVm->usedBytes() : freeHeap(); }
  size_t minFreeHeap() override { return 100000; }
  int battery() override { return 77; }
  BatteryStatus bat = {};  // fs.volume-style mock: .supported=false -> "no battery on this device"
  BatteryStatus batteryStatus() override { return bat; }
  void log(const char* m) override { logs.push_back(m); }
  std::string appNameVal = "test";
  bool secretOk = true;
  uint8_t secretBytes[32] = {0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15,
                             16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31};
  const char* appName() override { return appNameVal.c_str(); }
  bool deviceKeyMaterial(uint8_t out[32]) override {
    if (!secretOk) return false;
    memcpy(out, secretBytes, 32);
    return true;
  }
  const char* appDir() override { return "/plugins/test"; }
  void requestExit() override { exitReq = true; }
  const char* dataDir() override { return "/.crosslua/data/test"; }
  const char* libDir() override { return "/.crosslua/lib"; }

  // --- in-memory SD card ---
  std::map<std::string, std::string> files;
  std::set<std::string> dirs;
  std::vector<std::string> listing;
  size_t listPos = 0;
  int64_t fsSize(const char* p) override {
    auto f = files.find(p);
    if (f != files.end()) return (int64_t)f->second.size();
    if (dirs.count(p)) return -2;
    std::string pre = std::string(p);  // like FAT: a folder that holds files exists
    if (pre.empty() || pre.back() != '/') pre += "/";
    auto it = files.lower_bound(pre);
    return (it != files.end() && it->first.rfind(pre, 0) == 0) ? -2 : -1;
  }
  std::map<std::string, uint32_t> fatTimes;  // FAT modification stamps (date << 16 | time) by absolute path
  int statCalls = 0;
  std::map<std::string, int64_t> bigSizes;  // sizes a std::string cannot hold (fsStat only)
  std::string statFailPath;  // fsStat of this path fails (an entry that vanished between listing and stat)
  bool fsStat(const char* p, FsStat* out) override {
    statCalls++;
    if (statFailPath == p) return false;
    const int64_t n = fsSize(p);
    if (n == -1) return false;
    out->isDir = n == -2;
    out->size = n == -2 ? 0 : n;
    auto big = bigSizes.find(p);
    if (big != bigSizes.end()) out->size = big->second;
    auto t = fatTimes.find(p);
    out->fatTime = t == fatTimes.end() ? 0 : t->second;
    return true;
  }
  std::string failReadPath;  // reads of this path fail (a card that goes away mid-read)
  bool fsReadInto(const char* p, void* dst, size_t n, size_t offset) override {
    auto f = files.find(p);
    if (f == files.end() || offset + n > f->second.size() || failReadPath == p) return false;
    memcpy(dst, f->second.data() + offset, n);
    return true;
  }
  bool fsWriteAt(const char* p, size_t offset, const void* d, size_t n) override {
    auto f = files.find(p);
    if (failWrites || f == files.end() || offset > f->second.size()) return false;
    if (offset + n > f->second.size()) f->second.resize(offset + n);
    memcpy(&f->second[offset], d, n);
    return true;
  }
  // ---- network mock: scripted responses, records what reached the backend -----------------------
  struct FakeResp {
    int status = 200;
    std::string body;
    std::string error;
    std::string headers; /* raw "Name: value\n" lines */
  };
  std::map<std::string, FakeResp> routes;  // by full url
  bool net = true, wifiUp = false, wifiAsked = false;
  size_t largest = 100000;
  struct SeenReq {
    std::string method, url, body, savePath, contentType, ca;
    bool hasContentType = false, hasCa = false, wantHeaders = false;
    std::vector<std::pair<std::string, std::string>> headers;
    size_t maxBody = 0;
  };
  std::vector<SeenReq> seen;
  bool netAllowed() override { return net; }

  // raw TCP sockets: scripted peers
  struct MockSock {
    bool used = false;
    int kind = 0;
    std::string host;
    int port = 0;
    std::string rx, tx;
    bool peerClosed = false;
  };
  int udpPortCounter = 0;    // ephemeral ports for udp_open(0)
  bool udpSendFail = false;  // udpSend reports an error on demand
  const char* udpPeerIp = "192.0.2.9";
  MockSock socks[Backend::MAX_SOCKETS];
  std::map<std::string, std::string> sockReply,
      dnsMap;  // "host:port" -> bytes the peer sends right after connect; name -> ip
  std::set<std::string> sockRefused, sockClosesAfterReply;
  std::vector<std::string> dnsAsked;
  std::vector<int> connectOpts;  // timeout_ms of every connect that reached the backend
  std::string txLog;             // "host:port<-data" for every write
  int connectCalls = 0;
  bool netReadFail =
      false;  // netRead reports "closed" although bytes were pending (the peer vanished between the two calls)
  const char* connectFailMsg = nullptr;  // when set, netConnect fails with this message (e.g. "cancelled")
  int relaxOn = 0, relaxOff = 0;         // heapRelax(true/false) calls: must always balance
  void heapRelax(bool on) override { (on ? relaxOn : relaxOff)++; }
  size_t writeChunk = 0;  // 0 = accept everything; otherwise at most this many bytes per write (partial writes)
  bool netLocal(char* ip, char* mask, char* gw, char* dns, size_t cap) override {
    if (!wifiUp) return false;
    snprintf(ip, cap, "192.168.1.50");
    snprintf(mask, cap, "255.255.255.0");
    snprintf(gw, cap, "192.168.1.1");
    snprintf(dns, cap, "1.1.1.1");
    return true;
  }
  bool netResolve(const char* host, char* ip, size_t ipCap, char* err, size_t errCap) override {
    dnsAsked.push_back(host);
    auto it = dnsMap.find(host);
    if (it == dnsMap.end()) {
      snprintf(err, errCap, "cannot resolve host (mock)");
      return false;
    }
    snprintf(ip, ipCap, "%s", it->second.c_str());
    return true;
  }
  int netConnect(const char* host, int port, int timeoutMs, char* err, size_t errCap) override {
    connectCalls++;
    connectOpts.push_back(timeoutMs);
    if (connectFailMsg) {
      snprintf(err, errCap, "%s", connectFailMsg);
      return -1;
    }
    const std::string key = std::string(host) + ":" + std::to_string(port);
    if (sockRefused.count(key)) {
      snprintf(err, errCap, "connection refused (mock)");
      return -1;
    }
    for (int i = 0; i < Backend::MAX_SOCKETS; i++) {
      if (socks[i].used) continue;
      socks[i] = MockSock{};
      socks[i].used = true;
      socks[i].kind = 1;
      socks[i].host = host;
      socks[i].port = port;
      auto r = sockReply.find(key);
      if (r != sockReply.end()) socks[i].rx = r->second;
      socks[i].peerClosed = sockClosesAfterReply.count(key) != 0;
      return i;
    }
    snprintf(err, errCap, "no free slot (mock)");
    return -1;
  }
  // --- TLS client mock (kind 4) ---
  int tlsCalls = 0;
  std::string tlsCaSeen = "<none>";  // the PEM the binding handed over, or "<insecure>"
  const char* tlsFailMsg = nullptr;
  int netConnectTls(const char* host, int port, int timeoutMs, const char* caPem, char* err, size_t errCap) override {
    tlsCalls++;
    tlsCaSeen = caPem ? caPem : "<insecure>";
    if (tlsFailMsg) {
      snprintf(err, errCap, "%s", tlsFailMsg);
      return -1;
    }
    const int s = netConnect(host, port, timeoutMs, err, errCap);
    if (s >= 0) socks[s].kind = 4;
    return s;
  }
  bool netIsOpen(int s) override { return s >= 0 && s < Backend::MAX_SOCKETS && socks[s].used; }
  int netKind(int s) override { return netIsOpen(s) ? socks[s].kind : 0; }
  int udpOpen(int port, char* err, size_t errCap) override {
    for (int i = 0; i < Backend::MAX_SOCKETS; i++) {
      if (socks[i].used) continue;
      socks[i] = MockSock{};
      socks[i].used = true;
      socks[i].kind = 2;
      socks[i].port = port != 0 ? port : 50000 + ++udpPortCounter;
      return i;
    }
    snprintf(err, errCap, "no free slot (mock)");
    return -1;
  }
  int udpSend(int s, const char* host, int port, const void* d, size_t n, char* err, size_t errCap) override {
    if (!netIsOpen(s) || socks[s].kind != 2) {
      snprintf(err, errCap, "not a UDP socket (mock)");
      return -1;
    }
    if (udpSendFail) {
      snprintf(err, errCap, "send failed (mock)");
      return -1;
    }
    txLog += std::string(host) + ":" + std::to_string(port) + "<-" + std::string(static_cast<const char*>(d), n);
    auto r = sockReply.find(std::string(host) + ":" + std::to_string(port));
    if (r != sockReply.end()) socks[s].rx += r->second;  // the scripted peer answers
    return static_cast<int>(n);
  }
  int udpRecv(int s, void* buf, size_t max, char* ip, size_t ipCap, int* port) override {
    if (!netIsOpen(s) || socks[s].kind != 2) return -1;
    if (socks[s].rx.empty()) return 0;
    const size_t n = std::min(max, socks[s].rx.size());
    memcpy(buf, socks[s].rx.data(), n);
    socks[s].rx.erase(0, n);
    snprintf(ip, ipCap, "%s", udpPeerIp);
    *port = 9098;
    return static_cast<int>(n);
  }
  int netAvailable(int s) override { return netIsOpen(s) ? static_cast<int>(socks[s].rx.size()) : -1; }
  int netRead(int s, void* buf, size_t max) override {
    if (!netIsOpen(s) || netReadFail) return -1;
    const size_t n = std::min(max, socks[s].rx.size());
    memcpy(buf, socks[s].rx.data(), n);
    socks[s].rx.erase(0, n);
    return static_cast<int>(n);
  }
  int netWrite(int s, const void* d, size_t n) override {
    if (!netIsOpen(s) || (socks[s].peerClosed && socks[s].rx.empty())) return -1;
    if (writeChunk && n > writeChunk) n = writeChunk;
    socks[s].tx.append(static_cast<const char*>(d), n);
    txLog += socks[s].host + ":" + std::to_string(socks[s].port) + "<-" + std::string(static_cast<const char*>(d), n);
    return static_cast<int>(n);
  }
  bool netConnected(int s) override { return netIsOpen(s) && !(socks[s].peerClosed && socks[s].rx.empty()); }
  void netClose(int s) override {
    if (netIsOpen(s)) socks[s] = MockSock{};
  }
  // --- listen / accept mock ---
  bool listenOk = true;                             // false = netListen fails
  bool acceptOk = true;                             // false = netAccept returns error
  std::map<int, std::deque<MockSock>> acceptQueue;  // server slot -> queued clients
  int acceptCount = 0;                              // clients accepted via netAccept so far (for unique slot content)
  int serverPort = 0;                               // last port listened on
  bool listenPermitted = false;                     // manifest declared "listen"
  bool listenApproved =
      true;  // user approved the listen request on the permission screen (default: approved, like grants in the mock)
  int netListen(int port, char* err, size_t errCap) override {
    if (!listenOk) {
      snprintf(err, errCap, "listen failed (mock)");
      return -1;
    }
    for (int i = 0; i < Backend::MAX_SOCKETS; i++) {
      if (socks[i].used) continue;
      socks[i] = MockSock{};
      socks[i].used = true;
      socks[i].kind = 3;
      socks[i].port = port;
      serverPort = port;
      acceptQueue[i] = {};
      return i;
    }
    snprintf(err, errCap, "no free slot (mock)");
    return -1;
  }
  int netAccept(int serverSlot) override {
    if (!acceptOk) return -2;
    auto it = acceptQueue.find(serverSlot);
    if (it == acceptQueue.end() || it->second.empty()) return -1;
    for (int i = 0; i < Backend::MAX_SOCKETS; i++) {
      if (socks[i].used) continue;
      MockSock cl = it->second.front();
      it->second.pop_front();
      socks[i] = cl;
      socks[i].used = true;
      socks[i].kind = 1;
      acceptCount++;
      return i;
    }
    return -2;  // no free slot for the client
  }
  // Pure manifest+approval flags: the binding checks the base network permission separately
  // (gateListen / net_accept).
  bool listenAllowed() override { return listenPermitted && listenApproved; }
  // --- audio mock ---
  bool audioPermitted = false;  // manifest declared "audio"
  bool audioApproved = true;    // user approved (mock default like listen)
  bool audioOk = true;          // false = play fails (mock codec error)
  struct AudioCall {
    std::string path;
    bool loop;
  };
  std::vector<AudioCall> audioPlays;
  int audioStops = 0, audioVolumes = 0, audioVolumeLast = -1;
  bool audioPlayingState = false;
  bool audioAllowed() override { return audioPermitted && audioApproved; }
  bool audioPlay(const char* path, bool loop, char* err, size_t errCap) override {
    if (!audioOk) {
      snprintf(err, errCap, "cannot play (mock codec error)");
      return false;
    }
    audioPlays.push_back({path, loop});
    audioPlayingState = true;
    return true;
  }
  void audioStop() override {
    audioStops++;
    audioPlayingState = false;
  }
  void audioVolume(int pct) override {
    audioVolumes++;
    audioVolumeLast = pct;
  }
  bool audioPlaying() override { return audioPlayingState; }
  // --- microphone mock ---
  bool micPermitted = false, micApproved = true, micOk = true;
  struct MicCall {
    std::string path;
    int seconds;
  };
  std::vector<MicCall> micRecords;
  std::vector<int> micLevels;  // ms of every level() that reached the backend
  int micPeak = 1234;
  bool micAllowed() override { return micPermitted && micApproved; }
  bool micRecord(const char* path, int seconds, int* bytes, char* err, size_t errCap) override {
    if (!micOk) {
      snprintf(err, errCap, "no microphone on this board");
      return false;
    }
    micRecords.push_back({path, seconds});
    files[path] = std::string(44 + seconds * 32000, 'W');  // what the firmware would have written
    *bytes = static_cast<int>(files[path].size());
    return true;
  }
  bool micLevel(int ms, int* peak, char* err, size_t errCap) override {
    if (!micOk) {
      snprintf(err, errCap, "no microphone on this board");
      return false;
    }
    micLevels.push_back(ms);
    *peak = micPeak;
    return true;
  }
  // --- mDNS mock ---
  struct MdnsResult {
    std::string hostname;
    std::string ip;
    int port;
    std::string instanceName;
  };
  std::vector<MdnsResult> mdnsResults;
  bool mdnsQueryCalled = false;
  std::string mdnsLastQuery;
  int mdnsQueryFailCode = 0;  // 0 ok, -1 = failure
  int mdnsQuery(const char* service, const char* proto, char* err, size_t errCap) override {
    mdnsQueryCalled = true;
    mdnsLastQuery = std::string(service) + "::" + proto;
    if (mdnsQueryFailCode < 0) {
      snprintf(err, errCap, "mDNS query failed (mock)");
      return -1;
    }
    return static_cast<int>(mdnsResults.size());
  }
  bool mdnsResult(int i, char* hostname, size_t hnCap, char* ip, size_t ipCap, int* port, char* instanceName,
                  size_t inCap) override {
    if (i < 0 || i >= static_cast<int>(mdnsResults.size())) return false;
    const auto& r = mdnsResults[i];
    snprintf(hostname, hnCap, "%s", r.hostname.c_str());
    snprintf(ip, ipCap, "%s", r.ip.c_str());
    *port = r.port;
    snprintf(instanceName, inCap, "%s", r.instanceName.c_str());
    return true;
  }
  bool wifiConnected() override { return wifiUp; }
  // --- hotspot mock ---
  bool apUp = false, hotspotPermitted = false, hotspotApproved = true, apFail = false;
  struct ApCall {
    std::string ssid, password;
    bool open;
    int channel, maxClients;
  };
  std::vector<ApCall> apCalls;
  int apClients = 0;
  bool netReady() override { return wifiUp || apUp; }
  // --- ESP-NOW mock ---
  bool enPermitted = false, enApproved = true, enUp = false, enFail = false, enSendFail = false;
  int enChannel = 0, enDropped = 0;
  struct EnSent {
    uint8_t mac[6];
    bool broadcast;
    std::string data;
  };
  std::vector<EnSent> enSent;
  struct EnIn {
    uint8_t mac[6];
    std::string data;
  };
  std::vector<EnIn> enInbox;  // scripted frames, delivered oldest first
  size_t radioFloorBytes() override { return radioEverStarted ? 48 * 1024 : 80 * 1024; }
  bool espnowAllowed() override { return net && enPermitted && enApproved; }
  bool espnowRunning() override { return enUp; }
  bool espnowStart(int channel, uint8_t mac[6], char* err, size_t errCap) override {
    if (enFail) {
      snprintf(err, errCap, "esp_now_init failed (mock)");
      return false;
    }
    enUp = true;
    radioEverStarted = true;
    enChannel = channel;
    const uint8_t m[6] = {0x02, 0x00, 0x00, 0x00, 0x00, 0xA1};
    memcpy(mac, m, 6);
    return true;
  }
  void espnowStop() override { enUp = false; }
  bool espnowSend(const uint8_t mac[6], bool broadcast, const void* d, size_t n, char* err, size_t errCap) override {
    if (enSendFail) {
      snprintf(err, errCap, "the radio refused the frame (mock)");
      return false;
    }
    EnSent e;
    memcpy(e.mac, mac, 6);
    e.broadcast = broadcast;
    e.data.assign(static_cast<const char*>(d), n);
    enSent.push_back(e);
    return true;
  }
  int espnowRecv(void* buf, size_t cap, uint8_t mac[6]) override {
    if (enInbox.empty()) return 0;
    EnIn in = enInbox.front();
    enInbox.erase(enInbox.begin());
    const size_t n = std::min(cap, in.data.size());
    memcpy(buf, in.data.data(), n);
    memcpy(mac, in.mac, 6);
    return static_cast<int>(n);
  }
  // --- wifi.monitor mock ---
  bool monPermitted = false, monApproved = true, monUp = false, monFail = false, monParentFail = false;
  bool radioEverStarted = false;
  int monChannel = 0, monCaptured = 0, monDropped = 0;
  uint32_t monFileBytes = 0;
  char monPathOut[160] = {0};
  struct MonIn {
    std::string data;
    int rssi;
    int channel;
  };
  std::vector<MonIn> monInbox;
  // --- wifi.tx mock ---
  bool txPermitted = false, txApproved = true, txUp = false, txFail = false;
  // --- ble mock (keyboard mode) ---
  bool blePermitted = false, bleApproved = true, bleSupportedVal = true, bleUp = false, bleStartFail = false,
       bleScanFail = false, bleConnFail = false;
  bool bleScanned = false, bleScanningNow = false;
  std::vector<BleDevice> bleSeen, bleBonds;
  BleState bleStateVal = {};
  int bleStartCalls = 0, bleStopCalls = 0, bleScanStops = 0, bleDisconnects = 0;
  std::string bleModeStarted, bleConnectedTo;
  std::vector<int> bleScanMsLog;
  std::vector<std::string> bleConnectLog;
  std::vector<int> bleConnectTypeLog;
  std::deque<KeyInfo> keyQ;
  bool haveKey = false;
  KeyInfo lastKey = {};
  void pushKey(char ch, uint8_t special, uint8_t mods, uint8_t code) {
    events.push_back("key");
    keyQ.push_back({ch, special, mods, code});
  }
  static BleDevice mkDev(const char* addr, const char* name, int rssi, bool connectable, bool hid) {
    BleDevice d = {};
    snprintf(d.addr, sizeof(d.addr), "%s", addr);
    snprintf(d.name, sizeof(d.name), "%s", name);
    d.rssi = rssi;
    d.connectable = connectable;
    d.hid = hid;
    return d;
  }
  bool bleSupported() override { return bleSupportedVal; }
  bool bleAllowed() override { return blePermitted && bleApproved; }
  bool bleRunning() override { return bleUp; }
  bool bleStart(const char* mode, char* err, size_t errCap) override {
    bleStartCalls++;
    if (bleStartFail) {
      snprintf(err, errCap, "nimble init failed (mock)");
      return false;
    }
    bleUp = true;
    radioEverStarted = true;
    bleModeStarted = mode;
    bleScanned = false;
    return true;
  }
  void bleStop() override {
    bleStopCalls++;
    bleUp = false;
    bleScanningNow = false;
    bleObservingNow = false;
  }
  // raw mode (the observer): a table the tests fill, observed only after bleObserve() like the
  // real stack
  std::vector<BleAdvert> bleAdvertsSeen;
  bool bleObservingNow = false, bleObserveFail = false, bleObserveFailSilent = false, bleObserveActive = false;
  int bleObserveCalls = 0, bleObserveStops = 0, bleDroppedVal = 0, bleObserveMs = -1;
  int bleMode() override {
    if (!bleUp) return BLE_MODE_NONE;
    if (bleModeStarted == "raw") return BLE_MODE_RAW;
    if (bleModeStarted == "gatt") return BLE_MODE_GATT;
    return BLE_MODE_KEYBOARD;
  }
  bool bleObserve(int ms, bool active, char* err, size_t errCap) override {
    bleObserveCalls++;
    if (bleObserveFail || bleObserveFailSilent) {
      if (!bleObserveFailSilent) snprintf(err, errCap, "observer refused (mock)");
      return false;
    }
    bleObserveMs = ms;
    bleObserveActive = active;
    bleObservingNow = true;
    return true;
  }
  void bleObserveStop() override {
    bleObserveStops++;
    bleObservingNow = false;
  }
  bool bleObserving() override { return bleObservingNow; }
  int bleAdverts(BleAdvert* out, int cap, int* dropped) override {
    if (!bleObservingNow && bleObserveCalls == 0) {
      *dropped = 0;
      return 0;
    }
    *dropped = bleDroppedVal;
    int n = 0;
    for (const BleAdvert& a : bleAdvertsSeen) {
      if (n >= cap) break;
      out[n++] = a;
    }
    return n;
  }
  bool bleScan(int ms, char* err, size_t errCap) override {
    if (bleScanFail) {
      snprintf(err, errCap, "scan refused (mock)");
      return false;
    }
    bleScanMsLog.push_back(ms);
    bleScanned = true;
    bleScanningNow = true;
    return true;
  }
  void bleScanStop() override {
    bleScanStops++;
    bleScanningNow = false;
  }
  int bleDevices(BleDevice* out, int cap) override {
    if (!bleScanned) return 0;
    int n = 0;
    for (const BleDevice& d : bleSeen) {
      if (n >= cap) break;
      out[n++] = d;
    }
    return n;
  }
  bool bleConnect(const char* addr, int addrType, char* err, size_t errCap) override {
    bleConnectLog.push_back(addr);
    bleConnectTypeLog.push_back(addrType);
    if (bleConnFail) {
      snprintf(err, errCap, "pairing refused (mock)");
      return false;
    }
    return true;
  }
  void bleDisconnect() override { bleDisconnects++; }
  void bleState(BleState* s) override {
    *s = bleStateVal;
    s->scanning = bleScanningNow || bleStateVal.scanning;
  }
  int blePaired(BleDevice* out, int cap) override {
    int n = 0;
    for (const BleDevice& d : bleBonds) {
      if (n >= cap) break;
      out[n++] = d;
    }
    return n;
  }
  bool bleForget(const char* addr) override {
    for (size_t i = 0; i < bleBonds.size(); i++)
      if (!strcmp(bleBonds[i].addr, addr)) {
        bleBonds.erase(bleBonds.begin() + i);
        return true;
      }
    return false;
  }
  // --- gatt mock ---
  static std::string lc(const char* s) {
    std::string r(s);
    for (auto& c : r)
      if (c >= 'A' && c <= 'Z') c += 32;
    return r;
  }
  std::vector<BleGattChar> gattChars;
  std::map<std::string, std::string> gattValues;  // lowercased uuid -> stored value
  std::vector<BleGattNotif> gattNotifBuf;
  bool gattConnected = false;
  int gattReadCalls = 0, gattWriteCalls = 0, gattNotifyCalls = 0, gattServicesCalls = 0;
  std::vector<std::pair<std::string, bool>> gattNotifyLog;     // uuid, on
  std::vector<std::pair<std::string, bool>> gattWriteNoRespLog;  // uuid, noResponse
  static BleGattChar mkChar(const char* service, const char* uuid, uint16_t handle, uint8_t props) {
    BleGattChar c = {};
    snprintf(c.service, sizeof(c.service), "%s", service);
    snprintf(c.uuid, sizeof(c.uuid), "%s", uuid);
    c.handle = handle;
    c.props = props;
    return c;
  }
  int bleGattServices(BleGattChar* out, int cap) override {
    gattServicesCalls++;
    if (!gattConnected) return -1;
    int n = 0;
    for (const auto& c : gattChars)
      if (n < cap) out[n++] = c;
    return n;
  }
  bool bleGattRead(const char* uuid, uint8_t* data, size_t* len, size_t maxLen, char* err, size_t errCap) override {
    gattReadCalls++;
    if (!gattConnected) {
      snprintf(err, errCap, "not connected (mock)");
      return false;
    }
    auto it = gattValues.find(lc(uuid));
    if (it == gattValues.end()) {
      snprintf(err, errCap, "no such characteristic (mock)");
      return false;
    }
    if (it->second.size() > maxLen) {
      snprintf(err, errCap, "value too large (mock)");
      return false;
    }
    if (it->second.size()) memcpy(data, it->second.data(), it->second.size());
    *len = it->second.size();
    return true;
  }
  bool bleGattWrite(const char* uuid, const uint8_t* data, size_t len, bool noResponse, char* err,
                    size_t errCap) override {
    gattWriteCalls++;
    if (!gattConnected) {
      snprintf(err, errCap, "not connected (mock)");
      return false;
    }
    auto it = gattValues.find(lc(uuid));
    if (it == gattValues.end()) {
      snprintf(err, errCap, "no such characteristic (mock)");
      return false;
    }
    gattValues[lc(uuid)] = std::string(reinterpret_cast<const char*>(data), len);
    gattWriteNoRespLog.push_back({lc(uuid), noResponse});
    return true;
  }
  bool bleGattNotify(const char* uuid, bool on, char* err, size_t errCap) override {
    gattNotifyCalls++;
    if (!gattConnected) {
      snprintf(err, errCap, "not connected (mock)");
      return false;
    }
    auto it = gattValues.find(lc(uuid));
    if (it == gattValues.end()) {
      snprintf(err, errCap, "no such characteristic (mock)");
      return false;
    }
    gattNotifyLog.push_back({lc(uuid), on});
    return true;
  }
  int bleGattNotifs(BleGattNotif* out, int cap) override {
    int n = 0;
    for (const auto& x : gattNotifBuf)
      if (n < cap) out[n++] = x;
    gattNotifBuf.clear();
    return n;
  }
  // --- advertise mock (raw mode, broadcaster) ---
  bool bleAdvUp = false, bleAdvFail = false;
  int bleAdvCalls = 0, bleAdvStops = 0;
  std::string bleAdvName, bleAdvData;
  uint16_t bleAdvServiceUuid = 0;
  std::string bleAdvServiceData;
  bool bleAdvConnectable = false;
  int bleAdvIntervalMs = 0;
  bool bleAdvertise(const char* name, const uint8_t* data, size_t dataLen, bool connectable, int intervalMs,
                    uint16_t serviceUuid, const uint8_t* serviceData, size_t serviceDataLen, char* err,
                    size_t errCap) override {
    bleAdvCalls++;
    if (bleAdvFail) {
      snprintf(err, errCap, "advertising refused (mock)");
      return false;
    }
    bleAdvName = name ? name : "";
    bleAdvData = std::string(reinterpret_cast<const char*>(data), dataLen);
    bleAdvConnectable = connectable;
    bleAdvIntervalMs = intervalMs;
    bleAdvServiceUuid = serviceUuid;
    bleAdvServiceData = std::string(reinterpret_cast<const char*>(serviceData), serviceDataLen);
    bleAdvUp = true;
    return true;
  }
  void bleAdvertiseStop() override {
    bleAdvStops++;
    bleAdvUp = false;
  }
  bool bleAdvertising() override { return bleAdvUp; }
  bool eventKey(KeyInfo* k) override {
    if (!haveKey) return false;
    *k = lastKey;
    return true;
  }
  // --- deep sleep mock ---
  std::string wakeCauseVal = "power-on";
  int sleepSeconds = -1;
  bool sleepFail = false;
  const char* wakeCause() override { return wakeCauseVal.c_str(); }
  bool systemSleep(int seconds, char* err, size_t errCap) override {
    if (sleepFail) {
      snprintf(err, errCap, "could not arm the timer wake (mock)");
      return false;
    }
    sleepSeconds = seconds;
    return true;  // on the device this never returns
  }
  int txChannelVal = 0, txSent = 0;
  bool txAllowed() override { return net && txPermitted && txApproved; }
  bool txRunning() override { return txUp; }
  bool txStart(int channel, char* err, size_t errCap) override {
    if (txFail) {
      snprintf(err, errCap, "esp_wifi_80211_tx refused (mock)");
      return false;
    }
    txUp = true;
    radioEverStarted = true;
    txChannelVal = channel;
    txSent = 0;
    return true;
  }
  void txStop() override { txUp = false; }
  bool txSend(const void* f, size_t n, char* err, size_t errCap) override {
    (void)f;
    if (n < 24) {
      snprintf(err, errCap, "frame too short (mock)");
      return false;
    }  // catches a strlen truncation in the binding
    if (txFail) {
      snprintf(err, errCap, "the radio refused the frame (mock)");
      return false;
    }
    txSent++;
    return true;
  }
  bool txInfo(int* channel, int* sent) override {
    if (!txUp) return false;
    *channel = txChannelVal;
    *sent = txSent;
    return true;
  }
  bool txChannel(int* channel) override { return txUp ? (*channel = txChannelVal, true) : false; }
  bool monitorChannel(int* channel) override { return monUp ? (*channel = monChannel, true) : false; }
  bool monitorAllowed() override { return net && monPermitted && monApproved; }
  bool monitorRunning() override { return monUp; }
  bool monitorStart(int channel, const char* pcapPath, char* err, size_t errCap) override {
    if (monFail) {
      snprintf(err, errCap, "esp_wifi_set_promiscuous failed (mock)");
      return false;
    }
    monUp = true;
    radioEverStarted = true;
    monChannel = channel;
    monFileBytes = pcapPath ? 24 : 0;  // a PCAP global header
    if (pcapPath)
      snprintf(monPathOut, sizeof(monPathOut), "%s", pcapPath);
    else
      monPathOut[0] = 0;
    return true;
  }
  void monitorStop(uint32_t* pcapBytes) override {
    *pcapBytes = monFileBytes;
    monUp = false;
  }
  int monitorRecv(void* buf, size_t cap, int* rssi, int* channel) override {
    if (monInbox.empty()) {
      monDropped++;  // simulates a frame lost to a full ring, so info().dropped is exercised
      return 0;
    }
    monCaptured++;
    MonIn in = monInbox.front();
    monInbox.erase(monInbox.begin());
    const size_t n = std::min(cap, in.data.size());
    memcpy(buf, in.data.data(), n);
    *rssi = in.rssi;
    *channel = in.channel;
    return static_cast<int>(n);
  }
  bool monSetFail = false;
  bool monitorSetChannel(int channel, char* err, size_t errCap) override {
    if (monSetFail) {
      snprintf(err, errCap, "could not set the channel (mock)");
      return false;
    }
    if (!monUp && !txUp) {
      snprintf(err, errCap, "no radio mode is running (mock)");
      return false;
    }
    monChannel = channel;
    txChannelVal = channel;
    return true;
  }
  bool monitorInfo(int* channel, int* captured, int* dropped, char* path, size_t pathCap,
                   uint32_t* pcapBytes) override {
    if (!monUp) return false;
    *channel = monChannel;
    *captured = monCaptured;
    *dropped = monDropped;
    snprintf(path, pathCap, "%s", monPathOut);
    *pcapBytes = monFileBytes;
    return true;
  }
  bool espnowInfo(uint8_t mac[6], int* channel, int* dropped) override {
    if (!enUp) return false;
    const uint8_t m[6] = {0x02, 0x00, 0x00, 0x00, 0x00, 0xA1};
    memcpy(mac, m, 6);
    *channel = enChannel;
    *dropped = enDropped;
    return true;
  }
  bool hotspotAllowed() override { return net && hotspotPermitted && hotspotApproved; }
  bool softApStart(const char* ssid, const char* password, int channel, int maxClients, char* ip, size_t ipCap,
                   char* err, size_t errCap) override {
    if (apFail) {
      snprintf(err, errCap, "cannot start the hotspot (mock)");
      return false;
    }
    apCalls.push_back({ssid, password ? password : "", password == nullptr, channel, maxClients});
    apUp = true;
    snprintf(ip, ipCap, "192.168.4.1");
    return true;
  }
  bool softApInfo(char* ssid, size_t ssidCap, char* ip, size_t ipCap, int* clients) override {
    if (!apUp) return false;
    snprintf(ssid, ssidCap, "%s", apCalls.empty() ? "?" : apCalls.back().ssid.c_str());
    snprintf(ip, ipCap, "192.168.4.1");
    *clients = apClients;
    return true;
  }
  void wifiRequestConnect() override { wifiAsked = true; }
  bool wifiInfo(char* ssid, size_t sc, char* ip, size_t ic, int* rssi) override {
    if (!wifiUp) return false;
    snprintf(ssid, sc, "TestNet");
    snprintf(ip, ic, "192.168.1.50");
    *rssi = -57;
    return true;
  }
  void wifiOff() override {
    wifiUp = false;
    apUp = false;
    enUp = false;
    monUp = false;
    txUp = false;
  }  // like the firmware: the hotspot and espnow stop too
  size_t largestFreeBlock() override { return largest; }
  bool httpRequest(const HttpRequest& rq, HttpResult& res) override {
    SeenReq r;
    r.method = rq.method;
    r.url = rq.url;
    r.body = std::string(rq.body ? rq.body : "", rq.bodyLen);
    r.savePath = rq.savePath ? rq.savePath : "";
    r.maxBody = rq.maxBody;
    r.hasContentType = rq.contentType != nullptr;
    r.contentType = rq.contentType ? rq.contentType : "";
    r.hasCa = rq.caPem != nullptr;
    r.ca = rq.caPem ? rq.caPem : "";
    r.wantHeaders = rq.wantHeaders;
    for (int i = 0; i < rq.headerCount; i++) r.headers.emplace_back(rq.headers[i].name, rq.headers[i].value);
    seen.push_back(r);
    if (!wifiUp) {
      snprintf(res.error, sizeof(res.error), "wifi is not connected (call wifi.connect() first)");
      return false;
    }
    auto it = routes.find(rq.url);
    if (it == routes.end()) {
      snprintf(res.error, sizeof(res.error), "request failed (no response)");
      return false;
    }
    const FakeResp& f = it->second;
    if (!f.error.empty()) {
      snprintf(res.error, sizeof(res.error), "%s", f.error.c_str());
      return false;
    }
    res.status = f.status;
    if (rq.savePath) {
      if (f.status >= 200 && f.status < 300) {
        files[rq.savePath] = f.body;
        res.bytes = f.body.size();
      }
      return true;
    }
    if (f.body.size() > rq.maxBody) {
      snprintf(res.error, sizeof(res.error), "response larger than max_body (%zu bytes): use save_to", rq.maxBody);
      return false;
    }
    res.body = (char*)malloc(f.body.size() ? f.body.size() : 1);  // like the firmware: malloc'd, the caller frees
    memcpy(res.body, f.body.data(), f.body.size());
    res.bodyLen = res.bytes = f.body.size();
    if (rq.wantHeaders) {
      res.headers = (char*)malloc(f.headers.size() ? f.headers.size() : 1);
      memcpy(res.headers, f.headers.data(), f.headers.size());
      res.headersLen = f.headers.size();
    }
    return true;
  }
  // ---- library mock: fake zips (path -> entries), sd: permission, open_book ---------------------
  bool library = true;
  std::map<std::string, std::vector<std::pair<std::string, std::string>>> zips;
  std::string openedBook;
  bool libraryAllowed() override { return library; }
  std::map<std::string, std::pair<std::string, std::string>> epubs;  // abs path -> {title, author}
  std::vector<std::string> epubAsked;
  bool epubMeta(const char* path, char* title, size_t titleCap, char* author, size_t authorCap, char* err,
                size_t errCap) override {
    epubAsked.push_back(path);
    auto it = epubs.find(path);
    if (it == epubs.end()) {
      snprintf(err, errCap, "mock: no such book");
      return false;
    }
    snprintf(title, titleCap, "%s", it->second.first.c_str());  // truncates like the firmware (may cut mid-character)
    snprintf(author, authorCap, "%s", it->second.second.c_str());
    return true;
  }
  int zipList(const char* path, ZipEntryInfo* out, int maxEntries, int* total, char* err, size_t errCap) override {
    auto it = zips.find(path);
    if (it == zips.end()) {
      snprintf(err, errCap, "cannot open zip (missing, not a zip, or damaged)");
      return -1;
    }
    *total = (int)it->second.size();
    int n = 0;
    for (auto& e : it->second) {
      if (n >= maxEntries) break;
      snprintf(out[n].name, sizeof(out[n].name), "%s", e.first.c_str());
      out[n].size = (uint32_t)e.second.size();
      n++;
    }
    return n;
  }
  bool zipRead(const char* path, const char* name, size_t maxBytes, char** data, size_t* len, char* err,
               size_t errCap) override {
    auto it = zips.find(path);
    if (it == zips.end()) {
      snprintf(err, errCap, "cannot open zip (missing, not a zip, or damaged)");
      return false;
    }
    for (auto& e : it->second) {
      if (e.first != name) continue;
      if (e.second.size() > maxBytes) {
        snprintf(err, errCap, "entry is %zu bytes, over max_bytes (%zu)", e.second.size(), maxBytes);
        return false;
      }
      *data = (char*)malloc(e.second.size() ? e.second.size() : 1);  // malloc'd like the firmware; the binding frees it
      memcpy(*data, e.second.data(), e.second.size());
      *len = e.second.size();
      return true;
    }
    snprintf(err, errCap, "no such entry");
    return false;
  }
  bool openBook(const char* absPath) override {
    if (!files.count(absPath)) return false;
    openedBook = absPath;
    return true;
  }
  // ---- batch A mock: scan/time/rename/mac/qr/frontlight/inflate/rounded -------------------------
  std::vector<Backend::WifiScanInfo> nets{
      {"NetA", -40, true, "AA:BB:CC:DD:EE:01", 6, "wpa2", false},
      {"", -60, false, "AA:BB:CC:DD:EE:02", 11, "open", true},  // hidden network: empty ssid
      {"NetC", -75, true, "AA:BB:CC:DD:EE:03", 1, "wpa2/wpa3", false},
  };
  bool syncOk = true;
  std::string mac_ = "AA:BB:CC:DD:EE:FF";
  std::string qrSeen;  // "text|x|y|side"
  int roundedSeen = 0;
  bool flPresent = true;
  bool flOn = false;
  int flBr = 60, flWarm = 30;
  int wifiScan(WifiScanInfo* out, int maxEntries, int* total, char* err, size_t errCap) override {
    if (nets.empty()) {
      snprintf(err, errCap, "scan failed");
      return -1;
    }
    *total = (int)nets.size();
    int c = 0;
    for (auto& n : nets) {
      if (c >= maxEntries) break;
      out[c++] = n;
    }
    return c;
  }
  bool timeSync(int, char* err, size_t errCap) override {
    if (!syncOk) {
      snprintf(err, errCap, "sync failed");
      return false;
    }
    epoch = 1769000000;
    return true;
  }
  bool timeSet(int64_t e) override {
    epoch = e;
    return true;
  }
  bool fsRename(const char* from, const char* to, char* err, size_t errCap) override {
    // deliberately permissive (overwrites): the binding itself must refuse an existing target
    auto it = files.find(from);
    if (it == files.end()) {
      snprintf(err, errCap, "no such file");
      return false;
    }
    files[to] = it->second;
    files.erase(it);
    return true;
  }
  void mac(char out[18]) override { snprintf(out, 18, "%s", mac_.c_str()); }
  bool rebooted = false;
  void systemReboot() override { rebooted = true; }
  bool drawQr(const char* text, int x, int y, int side) override {
    qrSeen = std::string(text) + "|" + std::to_string(x) + "|" + std::to_string(y) + "|" + std::to_string(side);
    return true;
  }
  bool frontlightGet(bool* on, int* brightness, int* warmth) override {
    if (!flPresent) return false;
    *on = flOn;
    *brightness = flBr;
    *warmth = flWarm;
    return true;
  }
  void frontlightSet(int brightness, int warmth, int on) override {
    if (brightness >= 0) flBr = brightness;
    if (warmth >= 0) flWarm = warmth;
    if (on >= 0) flOn = on == 1;
  }
  // The real InflateReader code (same as the firmware) over the generated vectors above.
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
    uint8_t* buf = (uint8_t*)malloc(cap);
    if (!buf) {
      snprintf(err, errCap, "out of memory");
      return false;
    }
    size_t have = 0;
    for (;;) {
      size_t produced = 0;
      InflateStatus st = reader.readAtMost(buf + have, cap - have, &produced);
      have += produced;
      if (st == InflateStatus::Done) break;
      if (st == InflateStatus::Error) {
        free(buf);
        snprintf(err, errCap, "corrupt deflate stream");
        return false;
      }
      if (stopAtMax && have >= maxOut) break;
      if (cap >= maxOut) {
        free(buf);
        snprintf(err, errCap, "inflated data over %zu bytes", maxOut);
        return false;
      }
      cap = cap * 2 < maxOut ? cap * 2 : maxOut;
      uint8_t* nb = (uint8_t*)realloc(buf, cap);
      if (!nb) {
        free(buf);
        snprintf(err, errCap, "out of memory");
        return false;
      }
      buf = nb;
    }
    *out = (char*)buf;
    *outLen = have;
    return true;
  }
  void drawRoundedRect(int x, int y, int w, int h, int radius, bool black, bool filled) override {
    (void)x;
    (void)y;
    (void)w;
    (void)h;
    (void)radius;
    (void)black;
    (void)filled;
    roundedSeen++;
  }
  // ---- image mock: path -> source size; records the last draw (fit/centre/permissions) ----------
  std::map<std::string, std::pair<int, int>> images;
  struct ImageCall {
    std::string path;
    int x = 0, y = 0, w = 0, h = 0;
  };
  std::vector<ImageCall> imageCalls;
  std::string imageErr;  // non-empty = the decoder "fails" with this message
  bool drawImage(const char* absPath, int x, int y, int maxW, int maxH, int* outW, int* outH, char* err,
                 size_t errCap) override {
    if (!imageErr.empty()) {
      snprintf(err, errCap, "%s", imageErr.c_str());
      return false;
    }
    auto it = images.find(absPath);
    if (it == images.end()) {
      snprintf(err, errCap, "cannot read the image header (corrupt or unsupported)");
      return false;
    }
    int dw = it->second.first, dh = it->second.second;
    if (dw > maxW || dh > maxH) {
      const double sc = std::min((double)maxW / dw, (double)maxH / dh);
      dw = std::max(1, (int)(dw * sc));
      dh = std::max(1, (int)(dh * sc));
    }
    imageCalls.push_back({absPath, x + (maxW - dw) / 2, y + (maxH - dh) / 2, dw, dh});
    *outW = dw;
    *outH = dh;
    return true;
  }
  // ---- storage grants mock: (relative path, write?) pairs the "user approved" -------------------
  std::vector<std::pair<std::string, bool>> grants;
  // device capabilities / usb / haptics / touch positions / text prompt
  Backend::DeviceCaps caps;
  bool usb = false, hapticPresent = false, textAsked = false;
  std::vector<std::pair<int, int>> hapticCalls;
  std::deque<std::pair<int, int>> evPos;  // aligned with `events` (only consulted when non-empty)
  bool havePos = false;
  int posX = 0, posY = 0;
  std::string textTitle, textInitial;
  int textMax = 0, textMode = -1;
  void deviceCaps(Backend::DeviceCaps* out) override { *out = caps; }
  bool usbConnected() override { return usb; }
  bool hapticPulse(int ms, int strength) override {
    if (!hapticPresent) return false;
    hapticCalls.push_back({ms, strength});
    return true;
  }
  bool eventPos(int* x, int* y) override {
    if (!havePos) return false;
    *x = posX;
    *y = posY;
    return true;
  }
  void textRequest(const char* title, const char* initial, int maxLen, int mode) override {
    textAsked = true;
    textTitle = title;
    textInitial = initial;
    textMax = maxLen;
    textMode = mode;
  }
  // sensors / outputs
  bool motionPresent = false, motionGyro = true, motionFail = false, envPresent = false, envFail = false,
       buzzerPresent = false;
  int ledN = 0;
  std::vector<std::string> toneCalls, ledCalls;
  SensorStatus motionRead(Backend::Motion* o) override {
    if (!motionPresent) return SensorStatus::Absent;
    if (motionFail) return SensorStatus::ReadFailed;
    *o = {0.5f,      -0.25f, 1.0f, motionGyro ? 10.0f : 0.0f, motionGyro ? -20.0f : 0.0f, motionGyro ? 30.0f : 0.0f,
          motionGyro};
    return SensorStatus::Ok;
  }
  SensorStatus envRead(float* t, float* h) override {
    if (!envPresent) return SensorStatus::Absent;
    if (envFail) return SensorStatus::ReadFailed;
    *t = 21.5f;
    *h = 40.25f;
    return SensorStatus::Ok;
  }
  bool toneStart(int f, int ms) override {
    if (!buzzerPresent) return false;
    toneCalls.push_back(std::to_string(f) + "," + std::to_string(ms));
    return true;
  }
  bool toneStop() override {
    if (!buzzerPresent) return false;
    toneCalls.push_back("stop");
    return true;
  }
  int ledCount() override { return ledN; }
  void ledSet(int i, int r, int g, int b) override {
    ledCalls.push_back((i < 0 ? std::string("all ") : "set " + std::to_string(i) + " ") + std::to_string(r) + " " +
                       std::to_string(g) + " " + std::to_string(b));
  }
  void ledOff() override { ledCalls.push_back("off"); }
  void ledBrightness(int v) override { ledCalls.push_back("brightness " + std::to_string(v)); }
  uint64_t rng = 0x9e3779b97f4a7c15ull;  // xorshift: deterministic but different on every call
  void randomBytes(uint8_t* out, size_t n) override {
    for (size_t i = 0; i < n; i++) {
      rng ^= rng << 13;
      rng ^= rng >> 7;
      rng ^= rng << 17;
      out[i] = (uint8_t)(rng >> 24);
    }
  }
  int grantCount() override { return (int)grants.size(); }
  const char* grantPath(int i, bool* write) override {
    *write = grants[i].second;
    return grants[i].first.c_str();
  }
  // ---- restart mock: records the requested entry script -----------------------------------------
  std::string restartedTo;
  bool requestRestart(const char* entry) override {
    restartedTo = entry;
    return true;
  }
  const char* entryName() override { return "main.lua"; }
  int64_t epoch = 0;  // 0 = clock not trusted
  int64_t epochNow() override {
    return epoch ? epoch + now / 1000 : 0;
  }  // epoch = clock at app start; advances with mock millis
  bool localDate(int64_t e, int out[8]) override {
    time_t t = (time_t)e;
    struct tm g;
    gmtime_r(&t, &g);  // mock "local time" = UTC
    out[0] = g.tm_year + 1900;
    out[1] = g.tm_mon + 1;
    out[2] = g.tm_mday;
    out[3] = g.tm_hour;
    out[4] = g.tm_min;
    out[5] = g.tm_sec;
    out[6] = g.tm_wday + 1;
    out[7] = g.tm_yday + 1;
    return true;
  }
  bool fsWrite(const char* p, const void* d, size_t n, bool append) override {
    if (failWrites) return false;
    std::string& v = files[p];
    if (!append) v.clear();
    v.append((const char*)d, n);
    return true;
  }
  bool failWrites = false;
  std::vector<std::string> bmpSaved;
  std::string bmpFailPath;
  bool saveScreenBmp(const char* path, char* err, size_t errCap) override {
    if (!bmpFailPath.empty() && bmpFailPath == path) {
      snprintf(err, errCap, "mock: card full");
      return false;
    }
    bmpSaved.push_back(path);
    return true;
  }
  bool fsMkdir(const char* p) override {
    std::string s(p);
    for (size_t i = 1; i <= s.size(); i++)
      if (i == s.size() || s[i] == '/') dirs.insert(s.substr(0, i));
    return true;
  }
  bool fsRemove(const char* p) override {
    if (files.erase(p)) return true;
    for (auto& f : files)
      if (f.first.rfind(std::string(p) + "/", 0) == 0) return false;  // non-empty dir
    return dirs.erase(p) > 0;
  }
  bool fsRmdir(const char* p) override {
    const std::string prefix = std::string(p) + "/";
    for (auto it = files.begin(); it != files.end();) {
      if (it->first.compare(0, prefix.size(), prefix) == 0) it = files.erase(it);
      else ++it;
    }
    for (auto it = dirs.begin(); it != dirs.end();) {
      if (*it == p || it->compare(0, prefix.size(), prefix) == 0) it = dirs.erase(it);
      else ++it;
    }
    return true;
  }
  bool fsListBegin(const char* p) override {
    listing.clear();
    listPos = 0;
    std::string pre = std::string(p);
    if (pre.empty() || pre.back() != '/') pre += "/";
    std::set<std::string> seen;
    for (auto& f : files)
      if (f.first.rfind(pre, 0) == 0) {
        std::string rest = f.first.substr(pre.size());
        size_t sl = rest.find('/');
        std::string e = sl == std::string::npos ? rest : rest.substr(0, sl) + "/";
        if (seen.insert(e).second) listing.push_back(e);
      }
    for (auto& d : dirs)
      if (d.rfind(pre, 0) == 0 && d.find('/', pre.size()) == std::string::npos) {
        std::string e = d.substr(pre.size()) + "/";
        if (seen.insert(e).second) listing.push_back(e);
      }
    std::reverse(listing.begin(), listing.end());  // deliberately unsorted: API must sort
    return true;
  }
  bool fsListNext(char* name, size_t cap, bool* isDir) override {
    if (listPos >= listing.size()) return false;
    std::string e = listing[listPos++];
    *isDir = e.back() == '/';
    if (*isDir) e.pop_back();
    snprintf(name, cap, "%s", e.c_str());
    return true;
  }
  void fsListEnd() override {}
  uint64_t volTotal = 0, volUsed = 0;  // fs.volume mock (total==0 -> "no storage mounted")
  StorageStats storageStats() override {
    StorageStats s;
    s.total = volTotal;
    s.used = volUsed;
    return s;
  }
};

static int g_fail = 0;
#define CHECK(c)                                    \
  do {                                              \
    if (!(c)) {                                     \
      printf("  FAIL line %d: %s\n", __LINE__, #c); \
      g_fail++;                                     \
    }                                               \
  } while (0)

// Drive like the Activity does. Returns final status. Feeds queued events when Waiting.
static Status run(LuaVm& vm, MockBackend& be, int maxSteps = 100000, bool feedEvents = true) {
  for (int i = 0; i < maxSteps; i++) {
    Status s = vm.status();
    if (s == Status::Error) printf("  [lua error] %s\n", vm.error().c_str());
    if (s == Status::Finished || s == Status::Error || be.exitReq) return s;
    if (s == Status::Waiting) {
      if (feedEvents && vm.wakesOnEvent() && !be.events.empty()) {
        std::string e = be.events.front();
        be.events.pop_front();
        vm.resume(e.c_str());
      } else if (vm.timeoutMs() >= 0) {
        be.now += static_cast<uint32_t>(vm.timeoutMs());  // the timeout really elapses on the mock clock
        vm.resume(nullptr);
      } else {
        return s;  // would wait forever
      }
    } else {
      vm.resume();
    }
  }
  return vm.status();
}

static bool setup(LuaVm& vm, MockBackend& be, const char* src, size_t budget = 96 * 1024) {
  CHECK(vm.open(budget));
  registerApi(vm, be);
  return vm.load("test.lua", src, strlen(src));
}

static void dump(MockBackend& be) {
  for (auto& l : be.logs) printf("    log| %s\n", l.c_str());
}
#define TEST(name) printf("[test] %s\n", name)

int ota_version_tests();

int main() {
  setvbuf(stdout, nullptr, _IONBF, 0);
  {
    TEST("hello draws and finishes");
    LuaVm vm;
    MockBackend be;
    setup(vm, be, "gfx.clear() gfx.text(10,20,'hi') gfx.rect(1,2,3,4,true) gfx.present()");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.calls.size() == 4);
    CHECK(be.calls[1] == "text:10,20:hi:f1:s0:b");
    CHECK(be.calls[2] == "rect:1,2,3,4:fill:b");
    CHECK(be.calls[3] == "present:0");
  }
  {
    TEST("text flags: center/right/bold/white, float coords");
    LuaVm vm;
    MockBackend be;
    setup(vm, be, "gfx.text(400.0/1,10,'abcd','small','bcw') gfx.text(100,0,'ab','ui','r')");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.calls[0] == "text:380,10:abcd:f-2:s1:w");  // 400 - 40/2
    CHECK(be.calls[1] == "text:80,0:ab:f1:s0:b");       // 100 - 20
  }
  {
    TEST("unknown font raises an error with traceback");
    LuaVm vm;
    MockBackend be;
    setup(vm, be, "gfx.text(0,0,'x','nope')");
    CHECK(run(vm, be) == Status::Error);
    CHECK(vm.error().find("unknown font 'nope'") != std::string::npos);
    CHECK(vm.error().find("stack traceback") != std::string::npos);
  }
  {
    TEST("input.wait: fast path, yield+resume, timeout nil");
    LuaVm vm;
    MockBackend be;
    be.events = {"left"};
    setup(vm, be,
          "a = input.wait(100)\n"  // queued: fast path
          "b = input.wait(100)\n"  // empty: yields, host feeds 'confirm'
          "c = input.wait(50)\n"   // yields, host times out -> nil
          "print(a, b, tostring(c))");
    CHECK(vm.status() == Status::Preempted);
    Status s = vm.resume();
    CHECK(s == Status::Waiting);
    CHECK(vm.timeoutMs() == 100 && vm.wakesOnEvent());
    be.events.push_back("confirm");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs.size() == 1 && be.logs[0] == "left\tconfirm\tnil");
  }
  {
    TEST("app.sleep is timer-only; input.wait() with no timeout waits forever");
    LuaVm vm;
    MockBackend be;
    setup(vm, be, "app.sleep(250) input.wait()");
    vm.resume();
    CHECK(vm.status() == Status::Waiting && vm.timeoutMs() == 250 && !vm.wakesOnEvent());
    vm.resume(nullptr);
    CHECK(vm.status() == Status::Waiting && vm.timeoutMs() == -1 && vm.wakesOnEvent());
  }
  {
    TEST("app.exit parks and requests exit");
    LuaVm vm;
    MockBackend be;
    setup(vm, be, "app.exit() error('unreachable')");
    run(vm, be);
    CHECK(be.exitReq);
    CHECK(vm.status() == Status::Waiting);
  }
  {
    TEST("busy loop is preempted, host stays in control");
    LuaVm vm;
    MockBackend be;
    setup(vm, be, "local n=0 while true do n=n+1 end");
    vm.setPreemptInterval(1000);
    int yields = 0;
    for (int i = 0; i < 50; i++) {
      if (vm.resume() == Status::Preempted) yields++;
    }
    CHECK(yields == 50);
  }
  {
    TEST("memory budget: allocation failure is a catchable Lua error, VM frees fully");
    LuaVm vm;
    MockBackend be;
    setup(vm, be,
          "local t = {} local ok, err = pcall(function() for i=1,1e6 do t[i] = {i} end end)\n"
          "t = nil\n"
          "print(ok, tostring(err))\n"
          "local s = string.rep('x', 1000) print('alive', #s)",
          64 * 1024);
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs.size() == 2);
    CHECK(be.logs[0].find("false\tnot enough memory") == 0);
    CHECK(be.logs[1] == "alive\t1000");
    CHECK(vm.peakBytes() <= 64 * 1024);
    vm.close();
    CHECK(vm.usedBytes() == 0);
  }
  {
    TEST("sandbox: no io/os/package/debug/dofile; load is text-only; bytecode rejected");
    LuaVm vm;
    MockBackend be;
    setup(vm, be,
          "print(io, os, package, debug, dofile, loadfile, type(load), type(require), string ~= nil, math ~= nil, utf8 "
          "~= nil, "
          "coroutine ~= nil)");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs[0] == "nil\tnil\tnil\tnil\tnil\tnil\tfunction\tfunction\ttrue\ttrue\ttrue\ttrue");
    LuaVm vm2;
    vm2.open(32 * 1024);
    CHECK(!vm2.load("bc", "\x1bLua\x54", 5));
    CHECK(vm2.error().find("precompiled") != std::string::npos);
  }
  {
    TEST("yield across pcall works (coroutine-based wait inside protected call)");
    LuaVm vm;
    MockBackend be;
    be.events = {"back"};
    setup(vm, be, "local ok, e = pcall(function() app.sleep(10) return input.wait(10) end) print(ok, e)");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs[0] == "true\tback");
  }
  {
    TEST("system/app API values");
    LuaVm vm;
    MockBackend be;
    be.now = 5000;
    setup(vm, be,
          "local f,m = system.heap() local u,p,b = system.lua_mem() local w,h = gfx.size()\n"
          "print(system.millis(), f, m, system.battery(), app.name(), app.dir(), w, h, b, u > 0)");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs[0] == "5000\t123456\t100000\t77\ttest\t/plugins/test\t800\t480\t98304\ttrue");
  }
  {
    TEST("system.battery_info: full fields, omission of unknown, no-battery");
    {
      LuaVm vm;
      MockBackend be;
      be.bat.percent = 80;
      be.bat.millivolts = 3850;
      be.bat.charging = 1;
      be.bat.externalPower = 1;
      setup(vm, be, "local b = system.battery_info(); print(b.percent, b.millivolts, b.charging, b.external_power)");
      CHECK(run(vm, be) == Status::Finished);
      CHECK(be.logs.size() == 1);
      if (be.logs.size() == 1) CHECK(be.logs[0] == "80\t3850\ttrue\ttrue");
    }
    {
      LuaVm vm;
      MockBackend be;
      be.bat.percent = 50;      // millivolts + charging unknown -> omitted (nil)
      be.bat.externalPower = 0;
      setup(vm, be, "local b = system.battery_info(); print(b.percent, b.millivolts, b.charging, b.external_power)");
      CHECK(run(vm, be) == Status::Finished);
      CHECK(be.logs.size() == 1);
      if (be.logs.size() == 1) CHECK(be.logs[0] == "50\tnil\tnil\tfalse");
    }
    {
      LuaVm vm;
      MockBackend be;
      be.bat.supported = false;
      setup(vm, be, "print(system.battery_info())");
      CHECK(run(vm, be) == Status::Finished);
      CHECK(be.logs.size() == 1);
      if (be.logs.size() == 1) CHECK(be.logs[0] == "nil\tno battery on this device");
    }
  }
  {
    TEST("error in script surfaces message, VM can still close cleanly");
    LuaVm vm;
    MockBackend be;
    setup(vm, be, "local t = nil; t.x = 1");
    CHECK(run(vm, be) == Status::Error);
    CHECK(vm.error().find("attempt to index a nil value") != std::string::npos);
    vm.close();
    CHECK(vm.usedBytes() == 0);
  }

  {
    TEST("heap guard: allocations never leave less than the floor free on the (simulated) device");
    LuaVm vm;
    MockBackend be;
    be.simTotal = 150 * 1024;
    be.simVm = &vm;
    const size_t floor = 40 * 1024;
    CHECK(vm.open(1024 * 1024));  // budget alone would allow far more than the device has
    vm.setHeapGuard([](void* ud) -> size_t { return static_cast<MockBackend*>(ud)->freeHeapQuick(); }, &be, floor);
    registerApi(vm, be);
    const char* src =
        "local t = {} local ok, e = pcall(function() for i = 1, 1e6 do t[i] = {i} end end) t = nil collectgarbage() "
        "print(ok, tostring(e):sub(1, 17)) print(#string.rep('z', 1000))";
    CHECK(vm.load("guard", src, strlen(src)));
    CHECK(run(vm, be, 1000000) == Status::Finished);
    CHECK(be.logs[0] == "false\tnot enough memory");
    CHECK(be.logs[1] == "1000");  // VM still usable after hitting the guard
    CHECK(vm.peakBytes() <= be.simTotal - floor);
    CHECK(vm.peakBytes() > 60 * 1024);  // and it did use most of what was allowed
  }
  {
    TEST(
        "heap guard: setHeapFloor changes the floor while the app runs (lowered after wifi.connect, as the activity "
        "does)");
    LuaVm vm;
    MockBackend be;
    be.simTotal = 150 * 1024;
    be.simVm = &vm;
    CHECK(vm.open(1024 * 1024));
    vm.setHeapGuard([](void* ud) -> size_t { return static_cast<MockBackend*>(ud)->freeHeapQuick(); }, &be, 40 * 1024);
    vm.setHeapFloor(12 * 1024);  // what LuaAppActivity does once WiFi is up
    registerApi(vm, be);
    const char* src =
        "local t = {} local ok, e = pcall(function() for i = 1, 1e6 do t[i] = {i} end end) t = nil collectgarbage() "
        "print(ok, tostring(e):sub(1, 17)) print(#string.rep('z', 1000))";
    CHECK(vm.load("guard", src, strlen(src)));
    CHECK(run(vm, be, 1000000) == Status::Finished);
    CHECK(be.logs[0] == "false\tnot enough memory");
    CHECK(vm.peakBytes() <= be.simTotal - 12 * 1024);  // the new floor is still enforced...
    CHECK(vm.peakBytes() >
          be.simTotal - 40 * 1024);  // ...and the VM used memory the old 40 KB floor would have refused
  }
  {
    TEST("regression: script dying of uncaught OOM is reported, no panic/abort");
    LuaVm vm;
    MockBackend be;
    setup(vm, be, "local t = {} while true do t[#t + 1] = {} end", 64 * 1024);
    CHECK(run(vm, be, 1000000) == Status::Error);
    CHECK(vm.error().find("not enough memory") != std::string::npos);
    CHECK(LuaVm::panicMessage[0] == '\0');
    vm.close();
    CHECK(vm.usedBytes() == 0);
  }

  // ======================= example apps from sd_card_contents/ =======================
  // Loads sd_card_contents/plugins/<name>/ (including subfolders like decks/) into the mock SD
  // at /plugins/test/.
  std::function<void(MockBackend&, const std::string&, const std::string&, std::string&)> loadDir =
      [&](MockBackend& be, const std::string& dir, const std::string& rel, std::string& mainSrc) {
        DIR* d = opendir(dir.c_str());
        if (!d) return;
        while (dirent* e = readdir(d)) {
          std::string fn = e->d_name;
          if (fn == "." || fn == "..") continue;
          std::string full = dir + "/" + fn;
          if (DIR* sub = opendir(full.c_str())) {
            closedir(sub);
            loadDir(be, full, rel + fn + "/", mainSrc);
            continue;
          }
          std::ifstream in(full, std::ios::binary);
          std::stringstream ss;
          ss << in.rdbuf();
          be.files["/plugins/test/" + rel + fn] = ss.str();  // mock appDir() is /plugins/test
          if (rel.empty() && fn == "main.lua") mainSrc = ss.str();
        }
        closedir(d);
      };
  auto loadApp = [&](MockBackend& be, const char* name) {
    std::string mainSrc;
    const std::string dir =
        name == std::string("selftest_lua")
            ? std::string(
                  "sd_card_contents/plugins/lua_tests_lua")  // selftest files live in the lua_tests_lua plugin dir
            : std::string("sd_card_contents/plugins/") + name;
    loadDir(be, dir, "", mainSrc);
    return mainSrc;
  };
  {
    TEST("example app selftest_lua: every on-device check also passes on the host mock (now in the test hub)");
    LuaVm vm;
    MockBackend be;
    std::string src;
    {
      std::string helper;
      {
        std::ifstream f("sd_card_contents/plugins/lua_tests_lua/helper.lua");
        std::stringstream ss;
        ss << f.rdbuf();
        helper = ss.str();
      }
      be.files["/plugins/test/helper.lua"] = helper;  // the selftest requires "helper" from its app dir
      std::ifstream f("sd_card_contents/plugins/lua_tests_lua/tests/selftest.lua");
      std::stringstream ss;
      ss << f.rdbuf();
      src = ss.str();
    }
    CHECK(!src.empty());
    CHECK(vm.open(300 * 1024));
    registerApi(vm, be);
    CHECK(vm.load("selftest_lua", src.data(), src.size()));
    Status st = run(vm, be, 2000000);
    CHECK(st == Status::Waiting);  // finished all checks, parked on input.wait()
    int pass = 0, fail = 0;
    for (auto& l : be.logs) {
      if (l.rfind("PASS", 0) == 0) pass++;
      if (l.rfind("FAIL", 0) == 0) {
        fail++;
        printf("    %s\n", l.c_str());
      }
    }
    CHECK(fail == 0);
    if (pass != 12) printf("    pass=%d fail=%d\n", pass, fail);
    CHECK(pass == 12);
  }
  {
    TEST("example app counter_lua: require + json + fs persistence across launches");
    std::string saved;
    for (int launch = 1; launch <= 2; launch++) {
      LuaVm vm;
      MockBackend be;
      std::string src = loadApp(be, "counter_lua");
      if (!saved.empty()) be.files["/.crosslua/data/test/state.json"] = saved;  // app name is "test" in the mock
      CHECK(vm.open(96 * 1024));
      registerApi(vm, be);
      CHECK(vm.load("counter_lua", src.data(), src.size()));
      CHECK(vm.resume() == Status::Waiting);
      be.events = {"confirm", "confirm", "right", "left"};
      CHECK(run(vm, be) == Status::Waiting);  // consumed all four, now idle waiting for input
      for (auto& c : be.calls)
        CHECK(c.find("failed") == std::string::npos &&
              c.find("error") == std::string::npos);  // nothing alarming is DRAWN
      saved = be.files["/.crosslua/data/test/state.json"];
      printf("    launch %d saved: %s\n", launch, saved.c_str());
      CHECK(vm.resume("back") == Status::Finished);
    }
    // launch 1: 0 +1 +1 +10 -1 = 11 ; launch 2 starts at 11 -> 22
    CHECK(saved.find("\"count\":22") != std::string::npos);
    CHECK(saved.find("\"launches\":2") != std::string::npos);
  }

  {
    TEST("study_lua scheduler: Lua port == crossplay's C++ FSRS-5 + learning steps (golden, 400 scenarios)");
    LuaVm vm;
    MockBackend be;
    loadApp(be, "study_lua");  // puts fsrs.lua / sched.lua / ... at /plugins/test/
    CHECK(vm.open(2 * 1024 * 1024));
    registerApi(vm, be);
    lua_State* L = vm.state();
    const char* harness = R"LUA(
      local sched = require("sched")
      local sc = sched.new()
      function golden_run(line)
        local card = sched.new_card()
        local clock = 20000 * 1440 + 600
        local out = {}
        for tok in line:gmatch("[^,]+") do
          local rating, adv = tok:match("(%d+):(%d+)")
          rating, adv = tonumber(rating), tonumber(adv)
          clock = clock + adv
          local today, nowMin = clock // 1440, clock % 1440
          if not sched.is_due(card, today, nowMin) then
            clock = card.due * 1440 + ((card.state == 1 or card.state == 3) and card.dueMin or 0)
            today, nowMin = clock // 1440, clock % 1440
          end
          local o = sc.answer(card, rating, today, nowMin)
          card = o.card
          out[#out + 1] = ("%d %d %d %d %.5g %.5g %d %d %d %d %d"):format(card.state, card.step, card.due, card.dueMin,
            card.s, card.d, card.reps, card.lapses, o.delayMinutes, o.intervalDays, o.graduated and 1 or 0)
        end
        return table.concat(out, "\n")
      end
    )LUA";
    bool loaded = luaL_loadstring(L, harness) == LUA_OK && lua_pcall(L, 0, 0, 0) == LUA_OK;
    if (!loaded) printf("    harness error: %s\n", lua_tostring(L, -1));
    CHECK(loaded);
    std::ifstream sin("test/lua_host/golden/scenarios.txt"), gin("test/lua_host/golden/golden.txt");
    CHECK(sin.good() && gin.good());
    std::string scen, gl;
    std::vector<std::string> golden;
    while (std::getline(gin, gl)) golden.push_back(gl);
    size_t gi = 0, steps = 0, identical = 0, close = 0, bad = 0;
    int sidx = 0;
    while (loaded && std::getline(sin, scen)) {
      CHECK(gi < golden.size() && golden[gi] == "S " + std::to_string(sidx));
      gi++;
      lua_getglobal(L, "golden_run");
      lua_pushstring(L, scen.c_str());
      if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        printf("    lua error: %s\n", lua_tostring(L, -1));
        bad++;
        break;
      }
      std::stringstream got(lua_tostring(L, -1));
      lua_pop(L, 1);
      std::string gotLine;
      while (std::getline(got, gotLine)) {
        steps++;
        const std::string& want = golden[gi++];
        if (gotLine == want) {
          identical++;
          continue;
        }
        // Same integers, floats within 1e-4 relative? (float printing / libm
        // last-digit differences)
        std::istringstream a(gotLine), b(want);
        std::string ta, tb;
        bool ok = true;
        for (int col = 0; col < 11 && ok; col++) {
          a >> ta;
          b >> tb;
          if (col == 4 || col == 5) {
            double x = atof(ta.c_str()), y = atof(tb.c_str());
            ok = std::fabs(x - y) <= 1e-4 * std::max(1.0, std::fabs(y));
          } else {
            ok = ta == tb;
          }
        }
        if (ok)
          close++;
        else {
          if (bad < 5)
            printf("    scenario %d step mismatch:\n      lua: %s\n      c++: %s\n", sidx, gotLine.c_str(),
                   want.c_str());
          bad++;
        }
      }
      sidx++;
    }
    printf("    %zu answers: %zu identical text, %zu within 1e-4, %zu mismatched\n", steps, identical, close, bad);
    CHECK(steps == 9179 && bad == 0 && gi == golden.size());
  }

  {
#ifndef STUDY_BUDGET
#define STUDY_BUDGET (120 * 1024)
#endif
    TEST("study_lua app: scripted review session (deck list, learning steps + wait, in-place records, day rollover)");
    MockBackend be;
    be.epoch = 1782086400 + 9 * 3600;  // 2026-06-22 09:00 UTC
    std::string src = loadApp(be, "study_lua");
    CHECK(!src.empty() && be.files.count("/plugins/test/decks/ports.tsv"));
    int cardLines = 0;
    {
      std::stringstream ss(be.files["/plugins/test/decks/ports.tsv"]);
      std::string l;
      while (std::getline(ss, l))
        if (!l.empty() && l[0] != '#' && l.find('\t') != std::string::npos) cardLines++;
    }
    auto frame = [&](MockBackend& b) {  // all text drawn since the last clear, "|"-joined
      size_t from = 0;
      for (size_t i = 0; i < b.calls.size(); i++)
        if (b.calls[i] == "clear:white") from = i;
      std::string out;
      for (size_t i = from; i < b.calls.size(); i++)
        if (b.calls[i].rfind("text:", 0) == 0) {
          size_t a = b.calls[i].find(':', 5), z = b.calls[i].rfind(":f");
          out += b.calls[i].substr(a + 1, z - a - 1) + "|";
        }
      return out;
    };
    auto has = [&](MockBackend& b, const char* what) { return frame(b).find(what) != std::string::npos; };
    auto record = [&](int num, int* state, int* step, int* reps, int* lapses, int* due) {
      const std::string& f = be.files["/.crosslua/data/test/study/ports/cards.bin"];
      const unsigned char* r = (const unsigned char*)f.data() + 12 + (num - 1) * 24;
      *state = r[0];
      *step = r[1];
      *reps = r[2] | r[3] << 8;
      *lapses = r[4] | r[5] << 8;
      *due = (int)(r[6] | r[7] << 8 | r[8] << 16 | (unsigned)r[9] << 24);
    };
    auto settle = [&](LuaVm& vm, std::initializer_list<const char*> evs) {
      be.calls.clear();
      for (auto e : evs) be.events.push_back(e);
      return run(vm, be, 20000);
    };
    auto launch = [&](LuaVm& vm) {
      CHECK(vm.open(STUDY_BUDGET));
      registerApi(vm, be);
      CHECK(vm.load("study_lua", src.data(), src.size()));
      CHECK(vm.resume() == Status::Waiting);
      return run(vm, be, 20000);
    };
    int state, step, reps, lapses, due, due0;
    {
      LuaVm vm;
      CHECK(launch(vm) == Status::Waiting);
      printf("    first frame: %s | status=%d err=%s\n", frame(be).c_str(), (int)vm.status(), vm.error().c_str());
      CHECK(has(be, "Study|") && has(be, "ports|"));
      CHECK(has(be, ("10 new   0 learn   0 due   (" + std::to_string(cardLines) + " cards)").c_str()));
      CHECK(settle(vm, {"confirm"}) == Status::Waiting);  // open the deck
      CHECK(has(be, "TCP 21|") && has(be, "Show|") && has(be, "10 new  0 learn  0 due"));
      CHECK(settle(vm, {"confirm"}) == Status::Waiting);  // reveal
      CHECK(has(be, "FTP (control)|") && has(be, "Again|1m|Good|10m|Hard|6m|Easy|"));
      CHECK(settle(vm, {"confirm"}) == Status::Waiting);  // Good -> step 2 of [1m,10m]
      CHECK(has(be, "TCP 22|"));
      record(1, &state, &step, &reps, &lapses, &due);
      CHECK(state == 1 && step == 1 && reps == 1 && lapses == 0);  // learning, on the 10 min step
      record(2, &state, &step, &reps, &lapses, &due);
      CHECK(state == 0 && reps == 0);  // untouched card stays new
      // nine more new cards, all Easy: graduate immediately (10 new cards/day limit now reached)
      be.calls.clear();
      for (int i = 0; i < 9; i++) {
        be.events.push_back("confirm");
        be.events.push_back("right");
      }
      uint32_t t0 = be.now;
      CHECK(run(vm, be, 200000) == Status::Waiting);
      CHECK(be.now - t0 >= 9 * 60 * 1000);            // the "next card in N min" wait really ran ~10 min
      CHECK(has(be, "TCP 21|") && has(be, "Show|"));  // card 1 came back after its 10 min delay
      record(10, &state, &step, &reps, &lapses, &due0);
      CHECK(state == 2 && reps == 1);                                // easy graduated straight to review
      CHECK(settle(vm, {"confirm", "confirm"}) == Status::Waiting);  // show, Good -> last step done -> review
      CHECK(has(be, "All done for today!|11 cards reviewed|"));
      record(1, &state, &step, &reps, &lapses, &due);
      CHECK(state == 2 && reps == 2);
      std::string meta = be.files["/.crosslua/data/test/study/ports/meta.json"];
      CHECK(meta.find("\"n\":10") != std::string::npos);
      for (auto& c : be.calls) CHECK(c.find("rror") == std::string::npos && c.find("ailed") == std::string::npos);
      printf("    lua mem: used %zu, peak %zu of budget %zu\n", vm.usedBytes(), vm.peakBytes(), vm.budgetBytes());
      CHECK(settle(vm, {"back"}) == Status::Waiting);  // back to the deck list
      CHECK(has(be, "Study|") && has(be, "ports|"));
      CHECK(settle(vm, {"back"}) == Status::Finished);  // Back on the list exits the app
    }
    // ---- 40 days later: the 10 cards are due, 10 fresh new cards are allowed again
    be.epoch += 40 * 86400;
    {
      LuaVm vm;
      CHECK(launch(vm) == Status::Waiting);
      CHECK(has(be, ("10 new   0 learn   10 due   (" + std::to_string(cardLines) + " cards)").c_str()));
      CHECK(settle(vm, {"confirm"}) == Status::Waiting);
      CHECK(has(be, "TCP 21|"));                                     // reviews come first, oldest due first
      CHECK(settle(vm, {"confirm", "confirm"}) == Status::Waiting);  // Good
      record(1, &state, &step, &reps, &lapses, &due);
      CHECK(state == 2 && reps == 3 && lapses == 0 && due > 20000 + 40);
      CHECK(has(be, "TCP 22|"));
      CHECK(settle(vm, {"confirm", "back"}) == Status::Waiting);  // Again on a review card = lapse -> relearn
      record(2, &state, &step, &reps, &lapses, &due);
      CHECK(state == 3 && lapses == 1 && reps == 2);
      for (auto& c : be.calls) CHECK(c.find("rror") == std::string::npos && c.find("ailed") == std::string::npos);
    }
  }
  {
    TEST("debug info: stripped by default (smaller, '?' in errors); <dataDir>/debug.flag keeps line numbers");
    size_t usedStripped = 0, usedKept = 0;
    for (int keep = 0; keep < 2; keep++) {
      LuaVm vm;
      MockBackend be;
      if (keep) be.files["/.crosslua/data/test/debug.flag"] = "1";
      std::string mod = "local M = {}\n";
      for (int i = 0; i < 60; i++)
        mod += "function M.f" + std::to_string(i) + "(a, b) local x = a + b local y = x * 2 return y, x end\n";
      mod += "function M.boom(t) return t.nope.deeper end\nreturn M\n";
      be.files["/plugins/test/big.lua"] = mod;
      CHECK(vm.open(512 * 1024));
      registerApi(vm, be);
      CHECK(vm.stripDebug() == !keep);
      const char* script =
          "local m = require('big')\nprint(m.f7(1, 2))\nprint(pcall(m.boom, {}))\nprint(pcall(function() local z = "
          "nil; return z.x end))\nprint(select(2, pcall(error, 'plain')))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be) == Status::Finished);
      CHECK(be.logs.size() == 4 && be.logs[0] == "6\t3");
      if (keep) {
        CHECK(be.logs[1].find("app:big.lua:") != std::string::npos);  // file:line present
        CHECK(be.logs[2].find("local 'z'") != std::string::npos);     // variable names present
      } else {
        CHECK(be.logs[1].find("false\t?:") == 0 || be.logs[1].find("?:-1:") != std::string::npos);
        CHECK(be.logs[1].find("app:big.lua") == std::string::npos);
        CHECK(be.logs[2].find("local 'z'") == std::string::npos);  // names are gone, message still produced
        CHECK(be.logs[2].find("attempt to index a nil value") != std::string::npos);
      }
      CHECK(be.logs[3] == "plain");
      lua_gc(vm.state(), LUA_GCCOLLECT);
      (keep ? usedKept : usedStripped) = vm.usedBytes();
      printf("    %s: %zu B after require\n", keep ? "debug.flag (kept)" : "stripped", vm.usedBytes());
    }
    CHECK(usedKept - usedStripped >=
          2900);  // stripping saves real memory (~4.5 KB on this 5 KB module; baseline VM is ~30 KB of "used")
  }
  {
    TEST("study_lua store.scan: 3000 overdue cards stay inside a tight memory budget, order + limits exact");
    MockBackend be;
    be.epoch = 1782086400;
    loadApp(be, "study_lua");
    std::string deckText;
    for (int i = 1; i <= 3000; i++) deckText += "front " + std::to_string(i) + "\tback " + std::to_string(i) + "\n";
    be.files["/plugins/test/decks/big.tsv"] = deckText;
    LuaVm vm;
    CHECK(vm.open(100 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      local store = require("store")
      local h = assert(store.open({ name = "big", path = "app:decks/big.tsv" }))
      print("count", h.count)
      -- every card: review state, due = 19990 + (i % 30): with today = 20000 only i % 30 <= 10 are due (1100 cards), the 100 most overdue are i % 30 == 0
      local recs = {}
      local fmt = "<BBHHi4i4Hff"
      assert(fs.write("data:study/big/cards.bin", ("<c4I4I4"):pack("CRD1", h.count, 0)))
      local batch = {}
      for i = 1, h.count do
        batch[#batch + 1] = fmt:pack(2, 0, 3, 0, 19990 + (i % 30), 19900, 0, 10.0, 5.0)
        if #batch == 40 then assert(fs.append("data:study/big/cards.bin", table.concat(batch))) batch = {} end
      end
      if #batch > 0 then assert(fs.append("data:study/big/cards.bin", table.concat(batch))) end
      local q = store.scan(h, 20000, 0, 10, 100)
      local sorted, ok = true, true
      for j = 2, #q.review do if q.review[j] <= q.review[j - 1] then sorted = false end end
      for j, n in ipairs(q.review) do if n ~= j * 30 then ok = false end end
      print("scan", q.counts.review, #q.review, q.review[1], q.review[#q.review], sorted, ok, #q.new, #q.learn)
      local used, peak, budget = system.lua_mem()
      print("mem", peak < budget)
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 2000000) == Status::Finished);
    CHECK(be.logs.size() == 3);
    if (be.logs.size() == 3) {
      CHECK(be.logs[0] == "count\t3000");
      CHECK(be.logs[1] == "scan\t1100\t100\t30\t3000\ttrue\ttrue\t0\t0");
      CHECK(be.logs[2] == "mem\ttrue");
    }
    printf("    peak %zu of %zu\n", vm.peakBytes(), vm.budgetBytes());
    dump(be);
  }
  {
    TEST(
        "game2048_lua rules: slide/merge-once, directions, spawn odds, win, game over, undo, save validation, "
        "invariants");
    MockBackend be;
    loadApp(be, "game2048_lua");
    LuaVm vm;
    CHECK(vm.open(300 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      local G = require("game")
      local function sl(a, b, c, d) local o, gn, ch = G.slide(a, b, c, d); return table.concat(o, " ") .. " | " .. gn .. " " .. tostring(ch) end
      print(sl(1,1,1,1)); print(sl(1,1,2,0)); print(sl(0,0,0,0)); print(sl(1,2,3,4)); print(sl(0,0,1,1))
      print(sl(1,0,1,2)); print(sl(2,1,1,2)); print(sl(3,3,3,0)); print(sl(0,2,0,0))
      -- scripted rng: always the first empty cell, and never the 10% roll -> a "2"
      local function scripted() return function(n) return n == 10 and 5 or 1 end end
      local function fresh(cells)
        local g = G.new(scripted()); for i = 1, 16 do g.b[i] = cells[i] or 0 end; g.score, g.moves, g.over, g.won = 0, 0, false, false; return g
      end
      local function pos(g) local t = {} for i = 1, 16 do if g.b[i] ~= 0 then t[#t + 1] = i .. "=" .. g.b[i] end end return table.concat(t, ",") end
      local g = fresh({ [1] = 3 })
      G.move(g, "right"); print("right", pos(g))               -- 3 slides to cell 4, spawn takes first empty (1)
      g = fresh({ [1] = 3 }); G.move(g, "down"); print("down", pos(g))
      g = fresh({ [16] = 3 }); G.move(g, "left"); print("left", pos(g))
      g = fresh({ [16] = 3 }); G.move(g, "up"); print("up", pos(g))
      -- a move that changes nothing: no spawn, no move counted, returns false
      g = fresh({ [1] = 3 }); print(G.move(g, "left"), g.moves, pos(g))
      -- game over: checkerboard cannot move; one empty cell can
      local chk = {}
      for i = 1, 16 do chk[i] = ((i - 1) // 4 + (i - 1) % 4) % 2 + 1 end
      g = fresh(chk); print("can_move full", G.can_move(g), G.move(g, "left"))
      chk[16] = 0; g = fresh(chk); print("can_move hole", G.can_move(g))
      -- game over is set by the move that fills the board: checkerboard of 2/3, row 0 = [0,2,3,2] slides to [2,3,2,0],
      -- the spawned "2" (exp 1) lands in cell 4 and touches nothing equal
      local almost = {}
      for i = 1, 16 do almost[i] = ((i - 1) // 4 + (i - 1) % 4) % 2 + 2 end
      almost[1] = 0; almost[2] = 2; almost[3] = 3; almost[4] = 2
      g = fresh(almost); G.move(g, "left"); print("over after", g.over, g.moves)
      -- win
      g = fresh({ [1] = 10, [2] = 10 }); G.move(g, "left"); print("win", g.b[1], g.won, g.just_won, g.score)
      -- undo (one level)
      g = fresh({ [1] = 1, [2] = 1 }); G.move(g, "left")
      print("undo1", G.undo(g), pos(g), g.score, g.moves, "undo2", G.undo(g))
      -- spawn odds with the real RNG
      math.randomseed(12345)
      local fours = 0
      for i = 1, 4000 do local gg = G.new(); for j = 1, 16 do if gg.b[j] == 2 then fours = fours + 1 end end end
      print("fours%", fours * 100 // 8000)
      -- save validation
      local ok = G.new()
      local bad = { {}, { b = {} }, { b = { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }, s = 0 },
                    { b = { 18, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, s = 0 },
                    { b = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, s = 0 },
                    { b = { 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, s = -5 },
                    { b = { 1.5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, s = 0 }, "x", 5 }
      local rej = 0
      for _, t in ipairs(bad) do if not G.restore(ok, t) then rej = rej + 1 end end
      print("rejected", rej, #bad, G.restore(ok, { b = { 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3 }, s = 24, m = 7 }), ok.score, ok.moves)
      -- invariants over 3000 random moves from random positions: tile total only grows by the spawned tile; board stays valid
      math.randomseed(777)
      local dirs, violations, moved = { "left", "right", "up", "down" }, 0, 0
      local gg = G.new()
      for step = 1, 3000 do
        if gg.over then gg = G.new() end
        local before = 0; for i = 1, 16 do if gg.b[i] > 0 then before = before + (1 << gg.b[i]) end end
        local changed = G.move(gg, dirs[math.random(4)])
        local after = 0; for i = 1, 16 do if gg.b[i] > 0 then after = after + (1 << gg.b[i]) end if gg.b[i] < 0 or gg.b[i] > 17 then violations = violations + 1 end end
        if changed then moved = moved + 1; local d = after - before; if d ~= 2 and d ~= 4 then violations = violations + 1 end
        elseif after ~= before then violations = violations + 1 end
      end
      print("invariants", violations, moved > 500)
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 3000000) == Status::Finished);
    const char* want[] = {
        "2 2 0 0 | 8 true",
        "2 2 0 0 | 4 true",
        "0 0 0 0 | 0 false",
        "1 2 3 4 | 0 false",
        "2 0 0 0 | 4 true",
        "2 2 0 0 | 4 true",
        "2 2 2 0 | 4 true",
        "4 3 0 0 | 16 true",
        "2 0 0 0 | 0 true",
        "right\t1=1,4=3",
        "down\t1=1,13=3",
        "left\t1=1,13=3",
        "up\t1=1,4=3",
        "false\t0\t1=3",
        "can_move full\tfalse\tfalse",
        "can_move hole\ttrue",
        "over after\ttrue\t1",
        "win\t11\ttrue\ttrue\t2048",
        "undo1\ttrue\t1=1,2=1\t0\t0\tundo2\tfalse",
    };
    for (size_t i = 0; i < sizeof(want) / sizeof(want[0]); i++) {
      CHECK(i < be.logs.size() && be.logs[i] == want[i]);
      if (i < be.logs.size() && be.logs[i] != want[i])
        printf("    [%zu] got '%s' want '%s'\n", i, be.logs[i].c_str(), want[i]);
    }
    CHECK(be.logs.size() == 22);
    if (be.logs.size() == 22) {
      int pct = atoi(be.logs[19].c_str() + strlen("fours%\t"));
      CHECK(pct >= 8 && pct <= 12);
      CHECK(be.logs[20] == "rejected\t9\t9\ttrue\t24\t7");
      CHECK(be.logs[21] == "invariants\t0\ttrue");
    }
    dump(be);
  }
  {
    TEST("game2048_lua app: scripted session (moves, undo, menu, new game, persistence, corrupt save)");
    auto frameOf = [](MockBackend& b) {
      size_t from = 0;
      for (size_t i = 0; i < b.calls.size(); i++)
        if (b.calls[i] == "clear:white") from = i;
      std::string out;
      for (size_t i = from; i < b.calls.size(); i++)
        if (b.calls[i].rfind("text:", 0) == 0) {
          size_t a = b.calls[i].find(':', 5), z = b.calls[i].rfind(":f");
          out += b.calls[i].substr(a + 1, z - a - 1) + "|";
        }
      return out;
    };
    MockBackend be;
    std::string src = loadApp(be, "game2048_lua");
    const std::string STATE = "/.crosslua/data/test/state.json";
    auto launch = [&](LuaVm& vm) {
      CHECK(vm.open(96 * 1024));
      registerApi(vm, be);
      CHECK(vm.load("game2048_lua", src.data(), src.size()));
      CHECK(vm.resume() == Status::Waiting);
      return run(vm, be, 100000);
    };
    auto send = [&](LuaVm& vm, std::initializer_list<const char*> evs) {
      be.calls.clear();
      for (auto e : evs) be.events.push_back(e);
      return run(vm, be, 100000);
    };
    auto field = [&](const char* key) {  // integer after "key": in the saved JSON
      const std::string& f = be.files[STATE];
      size_t k = f.find(std::string("\"") + key + "\":");
      return k == std::string::npos ? -1 : atoi(f.c_str() + k + strlen(key) + 3);
    };
    {
      LuaVm vm;
      CHECK(launch(vm) == Status::Waiting);
      std::string f0 = frameOf(be);
      CHECK(f0.find("2048|") == 0 && f0.find("Score 0|") != std::string::npos &&
            f0.find("Best 0|") != std::string::npos);
      CHECK(f0.find("Moves 0|") != std::string::npos && f0.find("Menu|Undo|Left|Right|") != std::string::npos);
      for (int i = 0; i < 12; i++) CHECK(send(vm, {"left", "up", "right", "down"}) == Status::Waiting);
      int moves = field("m"), score = field("s");
      CHECK(moves > 8 && score > 0 && field("best") == score);
      CHECK(frameOf(be).find("Moves " + std::to_string(moves) + "|") != std::string::npos);
      CHECK(send(vm, {"confirm"}) == Status::Waiting);  // undo one move
      CHECK(field("m") == moves - 1);
      CHECK(send(vm, {"back"}) == Status::Waiting);  // menu
      CHECK(frameOf(be).find("Resume|New game|Exit|") != std::string::npos);
      CHECK(send(vm, {"down", "confirm"}) == Status::Waiting);              // New game
      CHECK(field("m") == 0 && field("s") == 0 && field("best") == score);  // best score survives a new game
      CHECK(frameOf(be).find("Moves 0|") != std::string::npos);
      CHECK(send(vm, {"left", "right"}) == Status::Waiting);
      int movesBefore = field("m");
      CHECK(movesBefore >= 1);
      for (auto& c : be.calls) CHECK(c.find("rror") == std::string::npos);
      CHECK(send(vm, {"back", "down", "down", "confirm"}) == Status::Finished);  // menu -> Exit
    }
    {
      // relaunch resumes exactly where it was
      int m = field("m"), s = field("s");
      LuaVm vm;
      CHECK(launch(vm) == Status::Waiting);
      CHECK(frameOf(be).find("Moves " + std::to_string(m) + "|") != std::string::npos);
      CHECK(frameOf(be).find("Score " + std::to_string(s) + "|") != std::string::npos);
      CHECK(frameOf(be).find("Best ") != std::string::npos);
    }
    {
      // a damaged save file never crashes the game: fresh board, best score kept if readable
      be.files[STATE] = "{\"g\":{\"b\":[1,2,3],\"s\":4},\"best\":999}";
      LuaVm vm;
      CHECK(launch(vm) == Status::Waiting);
      CHECK(frameOf(be).find("Score 0|") != std::string::npos && frameOf(be).find("Best 999|") != std::string::npos);
      be.files[STATE] = "not json at all";
      LuaVm vm2;
      CHECK(launch(vm2) == Status::Waiting);
      CHECK(frameOf(be).find("Score 0|") != std::string::npos);
      be.files.erase(STATE);
      LuaVm vm3;
      CHECK(launch(vm3) == Status::Waiting);
    }
  }
  {
    TEST("net: permission gate (wifi + http + status all refuse without the manifest permission)");
    MockBackend be;
    be.net = false;
    be.wifiUp = true;
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script =
        "print(wifi.connect())\nprint(http.get('http://h/a'))\nprint(http.request{url='http://h/"
        "a'})\nprint(wifi.status().connected, wifi.status().ssid)";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs.size() == 4);
    CHECK(be.logs[0].find("false\tnetwork not permitted") == 0 &&
          be.logs[0].find("manifest.json") != std::string::npos);  // wifi.connect: false, reason
    for (int i = 1; i < 3; i++)
      CHECK(be.logs[i].find("nil\tnetwork not permitted") == 0 &&
            be.logs[i].find("manifest.json") != std::string::npos);
    CHECK(be.logs[3] == "false\tnil");
    CHECK(be.seen.empty() && !be.wifiAsked);
  }
  {
    TEST("net: wifi.connect parks the script (input does not wake it), resumes true/false, status/off");
    for (int outcome = 0; outcome < 2; outcome++) {
      MockBackend be;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script =
          "local ok = wifi.connect()\nprint('c1', ok)\nlocal ok2 = wifi.connect()\nprint('c2', ok2)\n"
          "local st = wifi.status()\nprint(st.connected, st.ssid, st.ip, "
          "st.rssi)\nwifi.off()\nprint(wifi.status().connected)";
      CHECK(vm.load("t", script, strlen(script)));
      be.events = {"confirm", "back", "left"};
      CHECK(run(vm, be) == Status::Waiting);                            // parked inside wifi.connect()
      CHECK(be.wifiAsked && be.events.size() == 3 && be.logs.empty());  // button presses did NOT wake it
      CHECK(vm.timeoutMs() == -1 && !vm.wakesOnEvent());
      if (outcome == 0) {
        be.wifiUp = true;
        CHECK(vm.resume("wifi:ok") != Status::Error);
        CHECK(run(vm, be, 1000, false) == Status::Finished);
        CHECK(be.logs.size() == 4);
        if (be.logs.size() == 4) {
          CHECK(be.logs[0] == "c1\ttrue" && be.logs[1] == "c2\ttrue");  // 2nd connect: already up, no yield
          CHECK(be.logs[2] == "true\tTestNet\t192.168.1.50\t-57" && be.logs[3] == "false");
        }
      } else {
        CHECK(vm.resume("wifi:fail") != Status::Error);
        CHECK(run(vm, be, 1000, false) == Status::Waiting);  // c1 false, then the 2nd connect() parks again
        CHECK(be.logs.size() == 1 && be.logs[0] == "c1\tfalse");
        CHECK(vm.status() == Status::Waiting);
      }
    }
  }
  {
    TEST("net: http.request plumbing, status vs error, validation, save_to sandbox, max_body");
    MockBackend be;
    be.wifiUp = true;
    be.routes["http://h/a"] = {200, "hello", ""};
    be.routes["https://h/json"] = {200, "{\"x\":1}", ""};
    be.routes["http://h/404"] = {404, "nope", ""};
    be.routes["http://h/err"] = {0, "", "connection reset"};
    LuaVm vm;
    CHECK(vm.open(256 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      local r = http.get("http://h/a"); print(r.status, r.ok, r.bytes, r.body)
      r = http.get("https://h/json", {headers = {Accept = "application/json", ["X-Test"] = "1"}}); print(r.body)
      r = http.get("http://h/404"); print(r.status, r.ok, r.body)
      print(http.get("http://h/err"))
      r = http.request{url = "http://h/a", method = "POST", body = "a=1&b=2"}; print(r.status)
      print(http.get("http://h/missing"))
      print(http.get("http://h/a", {max_body = 3}))
      print(http.get("ftp://h/a")); print(http.get("file:///etc/passwd")); print(http.get("http://" .. ("a"):rep(700)))
      print(http.request{url = "http://h/a", method = "TRACE"})
      print(http.request{url = "http://h/a", body = "x"})
      print(http.request{url = "http://h/a", headers = {["X"] = "a\r\nInjected: 1"}})
      print(http.request{url = "http://h/a", headers = {["Bad:Name"] = "v"}})
      print(http.request{url = "http://h/a", headers = {x = 1}})
      print(http.request{url = "http://h/a", max_body = 0}); print(http.request{url = "http://h/a", max_body = 70000})
      print(http.request{url = "http://h/a", save_to = "../x"}); print(http.request{url = "http://h/a", save_to = "app:x"})
      print(http.request{url = "http://h/a", save_to = "/abs"})
      print(http.request{url = "http://h/a", method = "POST", save_to = "data:x"})
      r = http.get("http://h/a", {save_to = "data:dl/a.txt"}); print(r.status, r.bytes, r.body, fs.read("data:dl/a.txt"))
      print(pcall(http.request, "notatable"))
      print(select("#", system.heap()))
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 200000) == Status::Finished);
    const char* want[] = {
        "200\ttrue\t5\thello",
        "{\"x\":1}",
        "404\tfalse\tnope",
        "nil\tconnection reset",
        "200",
        "nil\trequest failed (no response)",
        "nil\tresponse larger than max_body (3 bytes): use save_to",
        "nil\tonly http:// and https:// urls are allowed",
        "nil\tonly http:// and https:// urls are allowed",
        "nil\turl too long",
        "nil\tmethod must be GET, POST, PUT, PATCH or DELETE",
        "nil\ta GET request cannot have a body",
        "nil\tillegal header",
        "nil\tillegal header",
        "nil\theaders must be a table of string = string",
        "nil\tmax_body must be 1..65536 (use save_to for bigger responses)",
        "nil\tmax_body must be 1..65536 (use save_to for bigger responses)",
        "nil\t'.' and '..' are not allowed",
        "nil\tsave_to must be a data: path",
        "nil\tabsolute paths are not allowed",
        "nil\tsave_to is only supported for GET",
        "200\t5\tnil\thello",
    };
    const size_t nWant = sizeof(want) / sizeof(want[0]);
    for (size_t i = 0; i < nWant; i++) {
      CHECK(i < be.logs.size() && be.logs[i] == want[i]);
      if (i < be.logs.size() && be.logs[i] != want[i])
        printf("    [%zu] got '%s' want '%s'\n", i, be.logs[i].c_str(), want[i]);
    }
    CHECK(be.logs.size() == nWant + 2);
    if (be.logs.size() == nWant + 2) {
      CHECK(be.logs[nWant].find("false\t") == 0);  // pcall(http.request, "notatable") raised (bad argument)
      CHECK(be.logs[nWant + 1] == "3");            // system.heap() -> free, min, largest block
    }
    // Only well-formed requests ever reached the backend: a, json, 404, err, POST,
    // missing, max_body=3, save_to
    CHECK(be.seen.size() == 8);
    if (be.seen.size() == 8) {
      CHECK(be.seen[0].method == "GET" && be.seen[0].maxBody == 16384 && be.seen[0].savePath.empty() &&
            be.seen[0].headers.empty());
      CHECK(be.seen[1].url == "https://h/json" && be.seen[1].headers.size() == 2);
      std::map<std::string, std::string> h(be.seen[1].headers.begin(), be.seen[1].headers.end());
      CHECK(h["Accept"] == "application/json" && h["X-Test"] == "1");
      CHECK(be.seen[4].method == "POST" && be.seen[4].body == "a=1&b=2");
      CHECK(be.seen[6].maxBody == 3);
      CHECK(be.seen[7].savePath == "/.crosslua/data/test/dl/a.txt");
    }
    CHECK(be.files["/.crosslua/data/test/dl/a.txt"] == "hello");
  }
  {
    TEST("net: a response too big for the Lua heap is an error, not a leak or a crash (ASAN/LSAN)");
    MockBackend be;
    be.wifiUp = true;
    be.routes["http://h/big"] = {200, std::string(50 * 1024, 'x'), ""};
    LuaVm vm;
    CHECK(vm.open(56 * 1024));
    registerApi(vm, be);
    const char* script = "print(http.get('http://h/big', {max_body = 60000}))\nprint('alive', #string.rep('y', 100))";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs.size() == 2);
    if (be.logs.size() == 2) {
      CHECK(be.logs[0].find("nil\tnot enough memory for the response") == 0);
      CHECK(be.logs[1] == "alive\t100");
    }
  }
  {
    TEST("gfx clipping: drawing past the screen edge clips instead of erroring (mock screen is 800x480)");
    MockBackend be;
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      gfx.line(0, 44, 800, 44)            -- a header rule one pixel too wide
      gfx.line(-10, 5, 10, 5)
      gfx.line(5, -10, 5, 10)
      gfx.line(0, 0, 2000, 2000)          -- diagonal off the far corner
      gfx.line(-50, -50, -10, -10)        -- fully off-screen
      gfx.line(0, 500, 800, 500)          -- below the screen
      gfx.line(10, 10, 20, 20)            -- fully inside: untouched
      gfx.pixel(-1, 0); gfx.pixel(800, 0); gfx.pixel(0, 480); gfx.pixel(3, 4)
      gfx.rect(790, 470, 50, 50, true)    -- filled, clipped to the 10x10 corner
      gfx.rect(-5, -5, 20, 20, true)
      gfx.rect(900, 900, 5, 5, true)      -- fully off
      gfx.rect(10, 10, 30, 20)            -- outline inside: one call
      gfx.rect(790, 10, 30, 20)           -- outline crossing the right edge: left/top/bottom edges only
      gfx.rect(5, 5, 0, 10, true)         -- empty
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be) == Status::Finished);
    const char* want[] = {
        "line:0,44,799,44",          "line:0,5,10,5",         "line:5,0,5,10",
        "line:0,0,479,479",          "line:10,10,20,20",      "pixel:3,4",
        "rect:790,470,10,10:fill:b", "rect:0,0,15,15:fill:b", "rect:10,10,30,20:line:b",
        "line:790,10,799,10",        "line:790,29,799,29",    "line:790,10,790,29",
    };
    const size_t n = sizeof(want) / sizeof(want[0]);
    CHECK(be.calls.size() == n);
    for (size_t i = 0; i < n && i < be.calls.size(); i++) {
      CHECK(be.calls[i] == want[i]);
      if (be.calls[i] != want[i]) printf("    [%zu] got '%s' want '%s'\n", i, be.calls[i].c_str(), want[i]);
    }
  }
  {
    TEST("net: wifi.connect refuses early when the app is too big for WiFi + TLS (96K free needed)");
    MockBackend be;
    be.freeHeapVal = 80 * 1024;
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script = "print(wifi.connect())";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs.size() == 1 &&
          be.logs[0] ==
              "false\tnot enough free RAM for WiFi + TLS (free 80K, need 96K): this app is too big for network use");
    CHECK(!be.wifiAsked);
  }
  {
    TEST(
        "net: wifi.connect{tls=false} needs 80K free instead of 96K (plain TCP apps); the default and tls=true still "
        "need 96K");
    {
      MockBackend be;
      be.freeHeapVal = 90 * 1024;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script =
          "print(wifi.connect())\nprint(wifi.connect{tls = true})\nprint(wifi.connect{})\nprint(pcall(wifi.connect, "
          "5))\nprint(pcall(wifi.connect, {tls = 'no'}))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be) == Status::Finished);
      CHECK(be.logs.size() == 5);
      if (be.logs.size() == 5) {
        const char* refused =
            "false\tnot enough free RAM for WiFi + TLS (free 90K, need 96K): this app is too big for network use";
        CHECK(be.logs[0] == refused && be.logs[1] == refused);
        CHECK(be.logs[2] ==
              "false\tnot enough free RAM for WiFi + TLS (free 90K, need 96K): this app is too big for network use");
        CHECK(be.logs[3].rfind("false", 0) == 0 && be.logs[3].find("table expected") != std::string::npos);
        CHECK(be.logs[4].rfind("false", 0) == 0);
        CHECK(be.logs[4].find("tls must be a boolean") != std::string::npos);
      }
      CHECK(!be.wifiAsked);
    }
    {
      MockBackend be;
      be.freeHeapVal = 90 * 1024;  // enough for plain TCP, not for TLS
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(wifi.connect{tls = false})";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be) == Status::Waiting);  // it passed the gate and parked in the system's WiFi flow
      CHECK(be.wifiAsked);
    }
    {
      MockBackend be;
      be.freeHeapVal = 70 * 1024;  // not even enough for plain TCP
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(wifi.connect{tls = false})";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be) == Status::Finished);
      CHECK(be.logs.size() == 1 &&
            be.logs[0] ==
                "false\tnot enough free RAM for WiFi (free 70K, need 80K): this app is too big for network use");
      CHECK(!be.wifiAsked);
    }
    {
      MockBackend be;
      be.freeHeapVal = 10 * 1024;
      be.wifiUp = true;  // already connected: the RAM gate does not apply and the options are irrelevant
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(wifi.connect{tls = false})\nprint(wifi.connect())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be) == Status::Finished);
      CHECK(be.logs.size() == 2 && be.logs[0] == "true" && be.logs[1] == "true");
    }
  }
  {
    TEST("sd: scope: needs the library permission, read-only, hidden paths do not exist, no escapes");
    MockBackend be;
    be.files["/Books/a.epub"] = "PK-fake";
    be.files["/Books/b.txt"] = "hello";
    be.files["/Books/.hidden/x"] = "secret";
    be.files["/.crosspoint/wifi.json"] = "{\"pw\":\"hunter2\"}";
    be.files["/.crosslua/data/other/secret"] = "other app data";
    be.files["/top.txt"] = "t";
    const char* script = R"LUA(
      local function show(...) print(...) end
      local l = fs.list("sd:"); if l then table.sort(l) end; show(l and table.concat(l, ","))
      l = fs.list("sd:Books"); show(l and table.concat(l, ","))
      show(fs.read("sd:Books/b.txt")); show(fs.read("sd:Books/a.epub", 0, 2)); show(fs.size("sd:Books/b.txt"))
      show(fs.read("sd:.crosspoint/wifi.json")); show(fs.read("sd:Books/.hidden/x"))
      show(fs.list("sd:.crosslua")); show(fs.read("sd:.crosslua/data/other/secret"))
      show(fs.exists("sd:.crosspoint/wifi.json"))
      show(fs.write("sd:Books/x.txt", "a")); show(fs.append("sd:top.txt", "a")); show(fs.remove("sd:Books/b.txt")); show(fs.mkdir("sd:New"))
      show(fs.write_at("sd:top.txt", 0, "z"))
      show(fs.read("sd:../x")); show(fs.read("sd:/etc/passwd")); show(fs.read("sd:Books/../.crosspoint/wifi.json")); show(fs.read("sd:Books//b.txt"))
    )LUA";
    for (int allowed = 0; allowed < 2; allowed++) {
      be.library = allowed;
      be.logs.clear();
      LuaVm vm;
      CHECK(vm.open(256 * 1024));
      registerApi(vm, be);
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      if (!allowed) {
        CHECK(be.logs.size() >= 10);
        for (auto& l : be.logs)
          CHECK(l.find("hunter2") == std::string::npos && l.find("other app data") == std::string::npos &&
                l.find("secret") == std::string::npos);
        if (!be.logs.empty())
          CHECK(be.logs[0] == "nil");  // fs.list("sd:") -> nil, err ... first print shows only the list
        for (auto& l : be.logs)
          CHECK(l.find("library access not permitted") != std::string::npos || l == "nil" || l == "false" ||
                l.find("read-only") != std::string::npos);
      } else {
        const char* want[] = {
            "Books/,top.txt",
            "a.epub,b.txt",
            "hello",
            "PK",
            "5",
            "nil\thidden files and folders are not accessible",
            "nil\thidden files and folders are not accessible",
            "nil\thidden files and folders are not accessible",
            "nil\thidden files and folders are not accessible",
            "false",  // fs.exists() on a hidden path: plain false, indistinguishable from "missing"
            "nil\tread-only location (write to 'data:...')",
            "nil\tread-only location (write to 'data:...')",
            "nil\tread-only location (write to 'data:...')",
            "nil\tread-only location (write to 'data:...')",
            "nil\tread-only location (write to 'data:...')",
            "nil\t'.' and '..' are not allowed",
            "nil\tabsolute paths are not allowed",
            "nil\t'.' and '..' are not allowed",
            "nil\tempty path component",
        };
        const size_t n = sizeof(want) / sizeof(want[0]);
        for (size_t i = 0; i < n; i++) {
          CHECK(i < be.logs.size() && be.logs[i] == want[i]);
          if (i < be.logs.size() && be.logs[i] != want[i])
            printf("    [%zu] got '%s' want '%s'\n", i, be.logs[i].c_str(), want[i]);
        }
      }
    }
    // nothing the app did changed the card
    CHECK(be.files["/Books/b.txt"] == "hello" && be.files["/top.txt"] == "t" && !be.files.count("/Books/x.txt"));
  }
  {
    TEST("zip: list/read limits, errors, scopes, and an oversized entry cannot leak or crash (ASAN/LSAN)");
    MockBackend be;
    be.zips["/Books/a.epub"] = {{"mimetype", "application/epub+zip"},
                                {"META-INF/container.xml", "<container/>"},
                                {"content.opf", std::string(5000, 'o')},
                                {"big.bin", std::string(70000, 'b')},
                                {"mid.bin", std::string(30000, 'm')}};
    be.zips["/.crosslua/data/test/d.zip"] = {{"x.txt", "from data"}};
    be.files["/Books/plain.txt"] = "not a zip";
    LuaVm vm;
    CHECK(vm.open(80 * 1024));  // tight on purpose
    registerApi(vm, be);
    const char* script = R"LUA(
      local l, total = zip.list("sd:Books/a.epub"); print(#l, total, l[1].name, l[1].size, l[3].name, l[3].size)
      l, total = zip.list("sd:Books/a.epub", 2); print(#l, total)
      print(zip.list("sd:Books/a.epub", 0)); print(zip.list("sd:Books/a.epub", 500))
      print(zip.read("sd:Books/a.epub", "mimetype"))
      print(#zip.read("sd:Books/a.epub", "content.opf"))
      print(zip.read("sd:Books/a.epub", "big.bin"))
      print(zip.read("sd:Books/a.epub", "big.bin", 70000))
      print(zip.read("sd:Books/a.epub", "nope.txt"))
      print(zip.read("sd:Books/a.epub", ""))
      print(zip.read("sd:Books/a.epub", ("x"):rep(300)))
      print(zip.read("sd:Books/plain.txt", "x"))
      print(zip.list("sd:Books/missing.epub"))
      print(zip.read("data:d.zip", "x.txt"))
      print(zip.read("sd:.crosspoint/x.zip", "x"))
      print(zip.read("app:../x.zip", "x"))
      print(zip.read("sd:Books/a.epub", "mid.bin", 65536) == nil)   -- 30 KB inflated into an 80 KB heap: must fail cleanly or work, never crash
      print("alive", #string.rep("y", 50))
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 100000) == Status::Finished);
    CHECK(be.logs.size() >= 17);
    if (be.logs.size() >= 17) {
      CHECK(be.logs[0] == "5\t5\tmimetype\t20\tcontent.opf\t5000");
      CHECK(be.logs[1] == "2\t5");
      CHECK(be.logs[2] == "nil\tmax must be 1..128" && be.logs[3] == "nil\tmax must be 1..128");
      CHECK(be.logs[4] == "application/epub+zip");
      CHECK(be.logs[5] == "5000");
      CHECK(be.logs[6] == "nil\tentry is 70000 bytes, over max_bytes (32768)");
      CHECK(be.logs[7] == "nil\tmax_bytes must be 1..65536");
      CHECK(be.logs[8] == "nil\tno such entry");
      CHECK(be.logs[9] == "nil\tbad entry name" && be.logs[10] == "nil\tbad entry name");
      CHECK(be.logs[11].find("nil\tcannot open zip") == 0 && be.logs[12].find("nil\tcannot open zip") == 0);
      CHECK(be.logs[13] == "from data");
      CHECK(be.logs[14].find("nil\thidden") == 0);
      CHECK(be.logs[15].find("nil\t'.' and '..'") == 0);
      CHECK(be.logs[16] == "true" || be.logs[16] == "false");
    }
    CHECK(be.logs.back() == "alive\t50");
    be.library = false;  // sd: zips need the permission; data: ones do not
    LuaVm vm2;
    CHECK(vm2.open(80 * 1024));
    registerApi(vm2, be);
    be.logs.clear();
    const char* s2 = "print(zip.read('sd:Books/a.epub', 'mimetype'))\nprint(zip.read('data:d.zip', 'x.txt'))";
    CHECK(vm2.load("t", s2, strlen(s2)));
    CHECK(run(vm2, be) == Status::Finished);
    CHECK(be.logs.size() == 2 && be.logs[0].find("nil\tlibrary access not permitted") == 0 &&
          be.logs[1] == "from data");
  }
  {
    TEST("app.open_book: sd:/data: files only, permission, parks the app and hands the path to the host");
    const char* cases[] = {"sd:Books/a.epub",       "sd:Books/missing.epub", "app:main.lua",
                           "sd:.crosspoint/x.epub", "data:dl/b.epub",        "main.lua",
                           "http://x/y.epub"};
    const char* wantLog[] = {"",
                             "false\tno such file",
                             "false\topen_book needs an sd: or data: path",
                             "false\thidden files and folders are not accessible",
                             "",
                             "false\topen_book needs an sd: or data: path",
                             "false\topen_book needs an sd: or data: path"};
    const char* wantOpen[] = {"/Books/a.epub", "", "", "", "/.crosslua/data/test/dl/b.epub", "", ""};
    for (int i = 0; i < 7; i++) {
      MockBackend be;
      be.files["/Books/a.epub"] = "PK";
      be.files["/.crosslua/data/test/dl/b.epub"] = "PK";
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      std::string script = std::string("print(app.open_book('") + cases[i] + "'))\nprint('after')";
      CHECK(vm.load("t", script.data(), script.size()));
      Status st = run(vm, be);
      CHECK(be.openedBook == wantOpen[i]);
      if (wantOpen[i][0]) {
        CHECK(st == Status::Waiting && vm.timeoutMs() == -1 && !vm.wakesOnEvent() &&
              be.logs.empty());  // parked, 'after' never runs
      } else {
        CHECK(st == Status::Finished && be.logs.size() == 2 && be.logs[0] == wantLog[i] && be.logs[1] == "after");
      }
    }
    MockBackend be;  // permission: sd: path without "library"
    be.library = false;
    be.files["/Books/a.epub"] = "PK";
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* s3 = "print(app.open_book('sd:Books/a.epub'))";
    CHECK(vm.load("t", s3, strlen(s3)));
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.openedBook.empty() && be.logs.size() == 1 && be.logs[0].find("false\tlibrary access not permitted") == 0);
  }
  {
    TEST("system.reboot: reaches the backend, returns true");
    {
      MockBackend be;
      LuaVm vm;
      CHECK(vm.open(64 * 1024));
      registerApi(vm, be);
      const char* script = "print(system.reboot())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1 && be.logs[0] == "true");
      CHECK(be.rebooted);
    }
    TEST("crypto.aes_gcm: NIST-reference vectors, round-trip, aad, tamper/bad-tag, validation");
    {
      MockBackend be;
      LuaVm vm;
      CHECK(vm.open(256 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        local function H(x) return crypto.hex(x) end
        local Z = crypto.unhex
        local k0 = Z("00000000000000000000000000000000")
        local n0 = Z("000000000000000000000000")
        -- empty pt/aad -> just the 16-byte tag (NIST GCM case 1)
        local s0 = crypto.aes_gcm_encrypt(k0, n0, "")
        print(H(s0), H(crypto.aes_gcm_decrypt(k0, n0, s0)))
        -- 16-byte pt (NIST case 2)
        local p1 = Z("00000000000000000000000000000000")
        local s1 = crypto.aes_gcm_encrypt(k0, n0, p1)
        print(H(s1), H(crypto.aes_gcm_decrypt(k0, n0, s1)))
        -- AES-128 with AAD
        local k2 = Z("feffe9928665731c6d6a8f9467308308")
        local n2 = Z("cafebabefacedbaddecaf888")
        local aad2 = Z("feedfacedeadbeeffeedfacedeadbeefabaddad2")
        local p2 = Z("d9313225f88406e5a55909c5aff5269a")
        local s2 = crypto.aes_gcm_encrypt(k2, n2, p2, aad2)
        print(H(s2), H(crypto.aes_gcm_decrypt(k2, n2, s2, aad2)))
        -- AES-256, empty plaintext + 16-byte aad
        local k3 = Z("0000000000000000000000000000000000000000000000000000000000000000")
        local aad3 = Z("00000000000000000000000000000000")
        print(H(crypto.aes_gcm_encrypt(k3, n0, "", aad3)))
        -- tampering: wrong aad, flipped tag byte, wrong key -> all "bad tag"
        print(crypto.aes_gcm_decrypt(k2, n2, s2, "bad"))
        local bad = s2:sub(1, -2) .. string.char((s2:byte(-1)) ~ 1)
        print(crypto.aes_gcm_decrypt(k2, n2, bad, aad2))
        print(crypto.aes_gcm_decrypt(Z("11111111111111111111111111111111"), n2, s2, aad2))
        -- validation
        print(crypto.aes_gcm_encrypt(k0, "short", "x"))
        print(crypto.aes_gcm_encrypt("short", n0, "x"))
        print(crypto.aes_gcm_decrypt(k0, n0, "short"))
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 20000000) == Status::Finished);
      const char* want[] = {
          "58e2fccefa7e3061367f1d57a4e7455a\t",
          "0388dace60b6a392f328c2b971b2fe78ab6e47d42cec13bdf53a67b21257bddf\t00000000000000000000000000000000",
          "42831ec2217774244b7221b784d0d49cd9f20ea917428bc48f586f2936d0fddf\td9313225f88406e5a55909c5aff5269a",
          "2d45552d8575922b3ca3cc538442fa26",
          "nil\tbad tag (wrong key, nonce or corrupted data)",
          "nil\tbad tag (wrong key, nonce or corrupted data)",
          "nil\tbad tag (wrong key, nonce or corrupted data)",
          "nil\tnonce must be 12 bytes (generate with crypto.random(12), never reuse)",
          "nil\tkey must be 16, 24 or 32 bytes",
          "nil\tsealed data must be at least 16 bytes (ciphertext + tag)",
      };
      for (size_t i = 0; i < sizeof(want) / sizeof(want[0]); i++) {
        CHECK(i < be.logs.size());
        if (i < be.logs.size() && be.logs[i] != want[i])
          printf("    aes_gcm #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
        CHECK(be.logs[i] == want[i]);
      }
    }
    TEST("fs.rmdir: recursive delete vs fs.remove (empty-only), guards");
    {
      MockBackend be;
      be.files["/.crosslua/data/test/nest/a.txt"] = "a";
      be.files["/.crosslua/data/test/nest/deep/b.txt"] = "b";
      be.files["/.crosslua/data/test/keep.txt"] = "keep";
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(fs.exists("data:nest"), fs.exists("data:nest/deep/b.txt"))
        print(fs.remove("data:nest"))                       -- non-empty dir: refused (rmdir is the recursive one)
        print(fs.rmdir("data:nest"))                        -- recursive delete: ok
        print(fs.exists("data:nest"), fs.exists("data:nest/deep/b.txt"), fs.exists("data:keep.txt"))
        print(fs.rmdir("data:keep.txt"))                    -- a file: not a directory
        print(fs.rmdir("data:nope"))                        -- missing
        print(fs.rmdir("data:"))                            -- the data root is off-limits
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 200000) == Status::Finished);
      CHECK(be.logs.size() == 7);
      if (be.logs.size() == 7) {
        CHECK(be.logs[0] == "true\ttrue");
        CHECK(be.logs[1] == "nil\tcannot remove (directories must be empty)");
        CHECK(be.logs[2] == "true");
        CHECK(be.logs[3] == "false\tfalse\ttrue");
        CHECK(be.logs[4] == "nil\tnot a directory (use fs.remove)");
        CHECK(be.logs[5] == "nil\tno such file or directory");
        CHECK(be.logs[6] == "nil\tcannot remove the data root");
      }
    }
    TEST("fs.volume: unmounted -> nil,err");
    {
      MockBackend be;  // volTotal defaults to 0 = no storage
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(fs.volume())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 200000) == Status::Finished);
      CHECK(be.logs.size() == 1);
      if (be.logs.size() == 1) CHECK(be.logs[0] == "nil\tno storage mounted");
    }
    TEST("fs.volume: total/used/free (64-bit, free = total - used)");
    {
      MockBackend be;
      be.volTotal = 64ull * 1024 * 1024;  // 64 MiB
      be.volUsed = 20ull * 1024 * 1024;   // 20 MiB
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        local v = fs.volume()
        print(v.free == v.total - v.used)                                        -- free is exactly total-used
        print(v.total == 67108864 and v.used == 20971520 and v.free == 46137344) -- exact on both 32/64-bit float
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 200000) == Status::Finished);
      CHECK(be.logs.size() == 2);
      if (be.logs.size() == 2) {
        CHECK(be.logs[0] == "true");
        CHECK(be.logs[1] == "true");
      }
    }
    TEST("xml.parse: element tree, text merge, whitespace, malformed/empty/too-deep/too-large");
    {
      MockBackend be;
      LuaVm vm;
      CHECK(vm.open(256 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        local r = xml.parse('<feed><title>My Feed</title><entry id="1"><title>Post</title><link href="http://x"/></entry></feed>')
        print(r.tag, type(r.attrs))
        print(r[1].tag, r[1][1], r[2].tag, r[2].attrs.id)
        print(r[2][1].tag, r[2][1][1], r[2][2].tag, r[2][2].attrs.href)
        local m = xml.parse('<t>a<![CDATA[b]]>c</t>')
        print(m.tag, m[1])
        local w = xml.parse('<t>line 1<b>bold</b>line 2</t>')
        print(w[1], w[2].tag, w[2][1], w[3])
        print(xml.parse('<a><b></a>'))
        print(xml.parse(''))
        print(xml.parse(('<a>'):rep(33)))
        print(xml.parse((' '):rep(65537)))
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 200000) == Status::Finished);
      CHECK(be.logs.size() == 9);
      if (be.logs.size() == 9) {
        CHECK(be.logs[0] == "feed\ttable");
        CHECK(be.logs[1] == "title\tMy Feed\tentry\t1");
        CHECK(be.logs[2] == "title\tPost\tlink\thttp://x");
        CHECK(be.logs[3] == "t\tabc");
        CHECK(be.logs[4] == "line 1\tb\tbold\tline 2");
        CHECK(be.logs[5].find("nil\t") == 0 && be.logs[5].size() > 4);  // malformed: nil + some expat message
        CHECK(be.logs[6] == "nil\tempty XML document");
        CHECK(be.logs[7] == "nil\txml nested deeper than 32 levels");
        CHECK(be.logs[8] == "nil\tXML too large (max 64 KB)");
      }
    }
    TEST("batch A: wifi.scan/time.sync+set/fs.rename/system.mac/gfx.qr/rounded/frontlight");
    MockBackend be;
    be.files["/.crosslua/data/test/a.txt"] = "one";
    be.files["/.crosslua/data/test/b.txt"] = "two";
    be.files["/.crosslua/data/test/dir/x"] = "x";
    be.files["/Books/x.epub"] = "PK";
    be.library = true;
    const char* script = R"LUA(
      local function show(...) print(...) end
      local l, total = wifi.scan(2); show(#l, total, l[1].ssid, l[1].rssi, l[1].bssid, l[1].channel, l[1].auth, l[1].hidden, l[2].ssid, l[2].encrypted, l[2].hidden)
      show(wifi.scan(0)); show(wifi.scan(99))  -- nil, err
      show(time.now() == nil)
      show(time.sync()); show(time.now() > 1700000000)
      show(time.sync(0)); show(time.sync(999))
      show(time.set(1769000000))     -- plausible: accepted
      show(math.abs(time.now() - 1769000000) < 100)  -- the mock clock keeps ticking
      show(time.set(100))            -- below the plausible range
      show(system.mac())
      show(device.frontlight())      -- on, brightness, warmth
      show(device.frontlight(35, 80, true))
      show(device.frontlight())
      local ok = gfx.clear(); show(ok)
      show(gfx.qr("x", 0, 0, 20)); show(gfx.qr("", 0, 0, 100)); show(gfx.qr("x", 100000, 0, 30)); show(gfx.qr("hello", 100, 100, 200))
      gfx.rounded_rect(10, 10, 100, 50, 8); gfx.rounded_rect(10, 10, 100, 50, 8, true, false)
      show(gfx.rounded_rect(10, 10, 50, 50, 30))
      show(fs.rename("data:a.txt", "data:c.txt")); show(fs.read("data:c.txt")); show(fs.read("data:a.txt"))
      show(fs.rename("data:nope.txt", "data:d.txt"))
      show(fs.rename("data:c.txt", "data:b.txt"))   -- target exists
      show(fs.rename("data:dir", "data:e"))          -- directory
      show(fs.rename("sd:Books/x.epub", "data:f.epub"))
      show(fs.rename("data:c.txt", "app:../c.txt"))
      show(fs.rename("data:c.txt", "sd:Books/y.epub")); show(fs.rename("data:c.txt", "app:y.txt"))
    )LUA";
    LuaVm vm;
    CHECK(vm.open(256 * 1024));
    registerApi(vm, be);
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 200000) == Status::Finished);
    const char* want[] = {
        "2\t3\tNetA\t-40\t\tfalse",  // empty SSID prints as empty field
        "nil\tmax must be 1..50",
        "nil\tmax must be 1..50",
        "true",  // time.now() == nil before sync
        "true",
        "true",
        "false\tsync failed",  // (mock syncOk still true; timeout bounds are checked Lua-side)
        "nil\ttimeout must be 1..60 seconds",
        "true",  // time.set(1769000000)
        "true",  // time.now() reflects the set
        "nil\tepoch out of the plausible range (2020..2096)",
    };
    (void)want;  // expectations are asserted incrementally below
    CHECK(be.logs.size() >= 31);
    if (be.logs.size() >= 31) {
      CHECK(be.logs[0] == "2\t3\tNetA\t-40\tAA:BB:CC:DD:EE:01\t6\twpa2\tfalse\t\tfalse\ttrue");
      CHECK(be.logs[1] == "nil\tmax must be 1..50" && be.logs[2] == "nil\tmax must be 1..50");
      CHECK(be.logs[3] == "true");
      CHECK(be.logs[4] == "true" && be.logs[5] == "true");
      CHECK(be.logs[6] == "nil\ttimeout must be 1..60 seconds" && be.logs[7] == "nil\ttimeout must be 1..60 seconds");
      CHECK(be.logs[8] == "true" && be.logs[9] == "true");
      CHECK(be.logs[10] == "nil\tepoch out of the plausible range (2020..2096)");
      CHECK(be.logs[11] == "AA:BB:CC:DD:EE:FF");
      CHECK(be.logs[12] == "false\t60\t30");
      CHECK(be.logs[13] == "true" && be.logs[14] == "true\t35\t80");
      CHECK(be.logs[16] == "nil\tbox does not fit on the screen (need at least 21x21)");  // side 20 < 21
      CHECK(be.logs[17] == "nil\ttext must be 1..1000 bytes");
      CHECK(be.logs[18] == "nil\tbox does not fit on the screen (need at least 21x21)");  // x off screen
      CHECK(be.logs[19] == "true");
      CHECK(be.logs[20] == "nil\tradius must be <= half of width and height");
      CHECK(be.logs[21] == "true" && be.logs[22] == "one" && be.logs[23] == "nil\tno such file");  // a.txt moved away
      CHECK(be.logs[24] == "nil\tno such file");
      CHECK(be.logs[25] == "nil\ttarget already exists" && be.logs[26] == "nil\tis a directory");
      CHECK(be.logs[27].find("read-only") != std::string::npos && be.logs[28].find("'.'") != std::string::npos);
      CHECK(be.logs[29].find("read-only") != std::string::npos && be.logs[30].find("read-only") != std::string::npos);
      CHECK(be.flOn && be.flBr == 35 && be.flWarm == 80);
    }
    CHECK(!be.files.count("/Books/y.epub") && !be.files.count("/.crosslua/data/test/y.txt"));
    if (getenv("DUMP_LOGS")) {
      for (size_t i = 0; i < be.logs.size(); i++) printf("   [%zu] %s\n", i, be.logs[i].c_str());
      printf("   qr=%s\n", be.qrSeen.c_str());
    }
    CHECK(be.qrSeen.find("hello|100|100|200") != std::string::npos);
    CHECK(be.roundedSeen == 2);
    CHECK(be.files["/.crosslua/data/test/c.txt"] == "one");
    CHECK(!be.files.count("/.crosslua/data/test/a.txt"));
    CHECK(be.files["/.crosslua/data/test/b.txt"] == "two");
  }
  {
    TEST("zip.inflate: raw + zlib through the real uzlib code, corrupt/oversize/empty input, output cap");
    MockBackend be;
    LuaVm vm;
    CHECK(vm.open(300 * 1024));
    registerApi(vm, be);
    // the vectors are binary: hand them to Lua through globals
    lua_State* L = vm.state();
    lua_pushlstring(L, DEFL_RAW, DEFL_RAW_LEN);
    lua_setglobal(L, "RAW");
    lua_pushlstring(L, DEFL_ZLIB, DEFL_ZLIB_LEN);
    lua_setglobal(L, "ZLIB");
    lua_pushlstring(L, DEFL_BAD, 4);
    lua_setglobal(L, "BAD");
    const char* script = R"LUA(
      local s = zip.inflate(RAW);        print(#s, s:sub(1, 19))
      local z = zip.inflate(ZLIB, true); print(#z, z:sub(1, 21))
      print(zip.inflate(BAD))
      print(zip.inflate(ZLIB, false))    -- zlib header fed as raw deflate: must fail cleanly, not crash
      print(zip.inflate(""))
      print(zip.inflate(("x"):rep(65537)))
      print(zip.inflate("ab", true))     -- too short to be zlib
      print(#zip.inflate(RAW) == 900)
      -- max_out: stop mid-stream at exactly N bytes (StarDict .dict.dz chunk math), no clean-end required
      print(#zip.inflate(RAW, false, 100))      -- 100 of 900: partial, success (no "over" error, no clean end)
      print(#zip.inflate(RAW, false, 900))      -- exactly the full stream
      print(#zip.inflate(RAW, false, 901))      -- stream Done before the cap: still 900
      local x = zip.inflate(RAW, false, 100)
      print(x == zip.inflate(RAW):sub(1, 100))  -- the first 100 bytes are a faithful prefix
      print(zip.inflate(RAW, false, 0))         -- validation: out of range
      print(zip.inflate(RAW, false, 98305))     -- validation: out of range
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 200000) == Status::Finished);
    if (getenv("DUMP_LOGS"))
      for (size_t i = 0; i < be.logs.size(); i++) printf("   [z%zu] %s\n", i, be.logs[i].c_str());
    CHECK(be.logs.size() == 14);
    if (be.logs.size() == 14) {
      CHECK(be.logs[0] == "900\tThe quick brown fox");
      CHECK(be.logs[1] == "250\tzlib-wrapped payload:");
      CHECK(be.logs[2] == "nil\tcorrupt deflate stream" && be.logs[3] == "nil\tcorrupt deflate stream");
      CHECK(be.logs[4] == "nil\tinput must be 1..65536 bytes");
      CHECK(be.logs[5] == "nil\tinput must be 1..65536 bytes");
      CHECK(be.logs[6] == "nil\tnot a zlib stream");
      CHECK(be.logs[7] == "true");
      CHECK(be.logs[8] == "100" && be.logs[9] == "900" && be.logs[10] == "900" && be.logs[11] == "true");
      CHECK(be.logs[12] == "nil\tmax_out must be an integer 1..98304");
      CHECK(be.logs[13] == "nil\tmax_out must be an integer 1..98304");
    }
  }
  {
    TEST("network-permission gates: wifi.scan and time.sync refuse without the manifest permission");
    MockBackend be;
    be.net = false;
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      print(wifi.scan()); print(time.sync()); print(time.now())
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs.size() == 3);
    if (be.logs.size() == 3) {
      CHECK(be.logs[0].find("nil\tnetwork not permitted") == 0);
      CHECK(be.logs[1].find("nil\tnetwork not permitted") == 0);
      CHECK(be.logs[2] == "nil");  // and the clock was NOT touched
    }
    be.net = true;
    be.logs.clear();
    be.nets.clear();  // scan failure path
    LuaVm vm2;
    CHECK(vm2.open(128 * 1024));
    registerApi(vm2, be);
    const char* s2 = "print(wifi.scan())";
    CHECK(vm2.load("t", s2, strlen(s2)));
    CHECK(run(vm2, be) == Status::Finished);
    CHECK(be.logs.size() == 1 && be.logs[0] == "nil\tscan failed");
  }
  {
    TEST("load: text-only, env honoured, size limit, no bytecode, errors are values not crashes");
    MockBackend be;
    LuaVm vm;
    CHECK(vm.open(192 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      local function show(...) print(...) end
      local f = load("return 1 + 2"); show(f())
      show(load("return x", "=chunk", "t", {x = 42})())               -- env honoured
      local e = {}; load("y = 5", "=c", "t", e)(); show(e.y, y)       -- wrote into env, not globals
      show(load("return print", "=c", "t", {})())                    -- empty env: no print, no fs
      show(load("return ...", "=c")(7, 8))                            -- varargs pass through
      show(load("x = = 1", "=bad"))                                   -- syntax error -> nil, msg
      show(load("error('boom')", "=thrower") ~= nil, pcall(load("error('boom')", "=thrower")))
      show(load(string.dump(function() return 1 end)))                -- bytecode refused
      show(load("\27Lua junk"))                                       -- signature refused
      show(load("return 1", "=c", "b"))                               -- binary-only mode refused
      show(load(function() return nil end))                           -- reader functions refused
      show(load(42)); show(load(nil))
      show(load(("x"):rep(65537)))                                    -- over 64 KB
      show(load(("--"):rep(100) .. "\nreturn 'ok'")())                -- comments fine
      show(load("return _ENV", "=c", "t", nil)())                     -- explicit nil env
      show(dofile, loadfile, loadstring)                              -- still removed
      local g = load("local n = 0; for i = 1, 10 do n = n + i end; return n"); show(g())
      show(load("return (", "@my/file.lua"))                          -- chunk name shows in the error
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 400000) == Status::Finished);
    if (getenv("DUMP_LOGS")) {
      for (size_t i = 0; i < be.logs.size(); i++) printf("   [%zu] %s\n", i, be.logs[i].c_str());
    }
    CHECK(be.logs.size() == 19);
    if (be.logs.size() == 19) {
      CHECK(be.logs[0] == "3");
      CHECK(be.logs[1] == "42");
      CHECK(be.logs[2] == "5\tnil");
      CHECK(be.logs[3] == "nil");
      CHECK(be.logs[4] == "7\t8");
      CHECK(be.logs[5].find("nil\t[string \"bad\"]") == 0 || be.logs[5].find("nil\tbad:1:") == 0);
      CHECK(be.logs[6].find("true\tfalse\t") == 0 && be.logs[6].find("boom") != std::string::npos);
      CHECK(be.logs[7] == "nil\tprecompiled chunks are not allowed");
      CHECK(be.logs[8] == "nil\tprecompiled chunks are not allowed");
      CHECK(be.logs[9].find("nil\tattempt to load a text chunk") == 0);
      CHECK(be.logs[10].find("nil\tload: text chunks only") == 0);
      CHECK(be.logs[11].find("nil\tload: text chunks only") == 0 &&
            be.logs[12].find("nil\tload: text chunks only") == 0);
      CHECK(be.logs[13] == "nil\tchunk too large (max 64 KB)");
      CHECK(be.logs[14] == "ok");
      CHECK(be.logs[15] == "nil");
      CHECK(be.logs[16] == "nil\tnil\tnil");
      CHECK(be.logs[17] == "55");
      CHECK(be.logs[18].find("nil\tmy/file.lua:1:") == 0);
    }
  }
  {
    TEST("load: heap exhaustion while compiling and a yield inside a loaded chunk are both clean");
    MockBackend be;
    LuaVm vm;
    CHECK(vm.open(150 * 1024));  // the 60 KB source fits (string.rep peaks ~120 KB) but compiling it cannot
    registerApi(vm, be);
    const char* script = R"LUA(
      local src = ("x=1\n"):rep(15000)               -- 60000 bytes, ~15000 statements
      local f, err = load(src, "=big")
      print(f == nil, type(err))                       -- clean nil,err (out of memory), never a crash
      src = nil; f = nil; collectgarbage()
      local g = load("local e = input.wait(10); return e")
      print(type(g))
      g()                                              -- yields inside the loaded chunk
      print("after")
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    Status st = run(vm, be, 600000);
    if (getenv("DUMP_LOGS")) {
      printf("   st=%d err=%s\n", (int)st, vm.error().c_str());
      for (auto& l : be.logs) printf("   <%s>\n", l.c_str());
    }
    CHECK(st == Status::Finished);  // input.wait yielded inside the loaded function and the host resumed it past it
    CHECK(be.logs.size() == 3 && be.logs[0] == "true\tstring" && be.logs[1] == "function" && be.logs[2] == "after");
  }
  {
    TEST("study_lua deck.lua: Anki HTML, entities, cloze, comment lines");
    MockBackend be;
    loadApp(be, "study_lua");
    LuaVm vm;
    CHECK(vm.open(512 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      local deck = require("deck")
      local function show(l) local q, a, c = deck.parse_line(l); return tostring(q) .. " || " .. tostring(a) .. " || " .. tostring(c) end
      print(show("What is <b>2+2</b>?<br>Hint&nbsp;here\t<div>Four</div><div>(&lt;4&gt;)</div>"))
      print(show("Kerberos: {{c1::88}} and {{c2::464::kpasswd}}\t"))
      print(show("#separator:tab"))
      print(show("no tab here"))
      print(show("Q\tA\tmore info"))
      print(show("x\tarrow &rarr; dash&ndash;&#65;&#8364;[sound:a.mp3]"))
      local function m(tag) collectgarbage() local u, p = system.lua_mem() print("MEM " .. tag, u, p) end
      m("deck-only") require("fsrs") m("+fsrs") require("sched") m("+sched") require("store") m("+store") require("ui") m("+ui")
      local ds = deck.list()
      print(#ds, ds[1].name, ds[1].path)
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs.size() >= 7);
    CHECK(be.logs[0] == "What is 2+2?\nHint here || Four\n(<4>) || false");
    CHECK(be.logs[1] == "Kerberos: [...] and [kpasswd] || Kerberos: 88 and 464 || true");
    CHECK(be.logs[2] == "nil || nil || nil");
    CHECK(be.logs[3] == "nil || nil || nil");
    CHECK(be.logs[4] == "Q || A\n\nmore info || false");
    CHECK(be.logs[5].find("arrow -> dash-A") == std::string::npos ? true : true);  // exact text below
    CHECK(be.logs[5] == "x || arrow -> dash-A\xE2\x82\xAC || false");

    dump(be);
  }

  // ======================= Phase 2: fs =======================
  {
    TEST("fs: data: roundtrip, append, size, exists, list(sorted, dirs/), remove, mkdir");
    LuaVm vm;
    MockBackend be;
    setup(vm, be,
          "assert(fs.write('data:save.txt', 'hello'))\n"
          "assert(fs.append('data:save.txt', ' world'))\n"
          "assert(fs.write('data:sub/deep/x.json', '{}'))\n"  // parents auto-created
          "assert(fs.mkdir('data:emptydir'))\n"
          "print(fs.read('data:save.txt'), fs.size('data:save.txt'), fs.exists('data:save.txt'), "
          "fs.exists('data:nope'))\n"
          "local l = fs.list('data:') print(table.concat(l, ','))\n"
          "print(fs.remove('data:save.txt'), fs.exists('data:save.txt'))\n"
          "print(fs.remove('data:sub'))\n"  // non-empty dir
          "print(fs.remove('data:'))\n"     // the data root itself
          "print(fs.read('data:missing'))");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs.size() == 6);
    CHECK(be.logs[0] == "hello world\t11\ttrue\tfalse");
    CHECK(be.logs[1] == "emptydir/,save.txt,sub/");
    CHECK(be.logs[2] == "true\tfalse");
    CHECK(be.logs[3].find("nil\tcannot remove") == 0);
    CHECK(be.logs[4] == "nil\tcannot remove the data root");
    CHECK(be.logs[5] == "nil\tno such file");
    CHECK(be.files.count("/.crosslua/data/test/sub/deep/x.json") == 1);
  }
  {
    TEST("fs.read ranges, fs.write_at in-place records");
    LuaVm vm;
    MockBackend be;
    std::string big(300 * 1024, 'a');
    for (size_t i = 0; i < big.size(); i++) big[i] = (char)('a' + (i % 26));
    be.files["/plugins/test/big.txt"] = big;
    setup(vm, be,
          "print(fs.read('big.txt', 0, 5), fs.read('big.txt', 26, 3), fs.read('big.txt', 307195, 100))\n"  // clipped at
                                                                                                           // EOF
          "print(#fs.read('big.txt', 1000, 100000), fs.read('big.txt', 307200, 10) == '')\n"  // at EOF = empty
          "print(fs.read('big.txt', 307201, 1))\n"                                            // beyond EOF
          "print(fs.read('big.txt', -1, 4))\n"
          "print(fs.read('big.txt', 0, 200000))\n"  // range too large
          "print(fs.read('big.txt'))\n"             // whole file too large -> hint
          "assert(fs.write('data:rec.bin', string.rep('.', 24)))\n"
          "assert(fs.write_at('data:rec.bin', 8, 'XYZ'))\n"
          "assert(fs.write_at('data:rec.bin', 24, 'END'))\n"  // extend at exact end is ok
          "print(fs.read('data:rec.bin'), fs.size('data:rec.bin'))\n"
          "print(fs.write_at('data:rec.bin', 99, 'x'))\n"                   // gap -> refused
          "print(fs.write_at('data:nope.bin', 0, 'x'))\n"                   // must exist
          "print(fs.write_at('app:big.txt', 0, 'x'))\n"                     // read-only scope
          "print(fs.write_at('data:rec.bin', 0, string.rep('z', 20000)))",  // > 16 KB
          2048 * 1024);
    CHECK(run(vm, be, 100000) == Status::Finished);
    CHECK(be.logs.size() == 11);
    CHECK(be.logs[0] == "abcde\tabc\t" + big.substr(307195));
    CHECK(be.logs[1] == "100000\ttrue");
    CHECK(be.logs[2] == "nil\toffset beyond end of file");
    CHECK(be.logs[3] == "nil\tnegative offset/length");
    CHECK(be.logs[4] == "nil\tlength too large");
    CHECK(be.logs[5].find("nil\tfile too large") == 0 &&
          be.logs[5].find("fs.read(path, offset, len)") != std::string::npos);
    CHECK(be.logs[6] == "........XYZ.............END\t27");
    CHECK(be.logs[7] == "nil\toffset beyond end of file");
    CHECK(be.logs[8].find("nil\tno such file") == 0);
    CHECK(be.logs[9].find("nil\tread-only") == 0);
    CHECK(be.logs[10] == "nil\tdata too large for write_at");
  }
  {
    TEST("time.now / time.date: trusted clock, no clock, explicit epoch");
    LuaVm vm;
    MockBackend be;
    be.epoch = 1782086400 + 3 * 3600 + 25 * 60 + 9;  // 2026-06-22 03:25:09 UTC (a Monday)
    setup(vm, be,
          "local d = time.date()\n"
          "print(time.now(), d.year, d.month, d.day, d.hour, d.min, d.sec, d.wday, d.yday)\n"
          "local e = time.date(0 + 86400 * 365)\n"
          "print(e and e.year, time.date(1))");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs[0] == "1782098709\t2026\t6\t22\t3\t25\t9\t2\t173");
    LuaVm vm2;
    MockBackend be2;
    be2.epoch = 0;
    setup(vm2, be2, "print(time.now(), time.date(), time.date(5000))");
    CHECK(run(vm2, be2) == Status::Finished);
    CHECK(be2.logs[0] == "nil\tnil\ttable: 0" || be2.logs[0].find("nil\tnil\t") == 0);
  }
  {
    TEST("fs: sandbox - traversal, absolute, odd paths, read-only scopes");
    LuaVm vm;
    MockBackend be;
    be.files["/plugins/test/asset.txt"] = "A";
    be.files["/.crosslua/lib/l.txt"] = "L";
    be.files["/secret.txt"] = "S";
    setup(vm, be,
          "local bad = {'../secret.txt', 'data:../../secret.txt', '/secret.txt', 'data:/secret.txt', 'a/../b', "
          "'a//b', './x', 'a\\\\b', 'x:y', 'lib:../x', string.rep('a', 300)}\n"
          "local rej = 0\n"
          "for _, p in ipairs(bad) do local r, e = fs.read(p) if r == nil and e ~= 'no such file' then rej = rej + 1 "
          "else print('LEAK', p, r, e) end end\n"
          "print('rejected', rej, #bad)\n"
          "print(fs.read('asset.txt'), fs.read('app:asset.txt'), fs.read('lib:l.txt'))\n"
          "print(fs.write('asset.txt', 'x'))\n"  // bare = app: read-only
          "print(fs.write('app:asset.txt', 'x'))\n"
          "print(fs.write('lib:l.txt', 'x'))\n"
          "print(fs.remove('app:asset.txt'))\n"
          "print(fs.exists('../secret.txt'), fs.exists('data:../../secret.txt'))");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs.size() >= 7);
    CHECK(be.logs[0] == "rejected\t11\t11");
    CHECK(be.logs[1] == "A\tA\tL");
    CHECK(be.logs[2].find("nil\tread-only") == 0);
    CHECK(be.logs[3].find("nil\tread-only") == 0);
    CHECK(be.logs[4].find("nil\tread-only") == 0);
    CHECK(be.logs[5].find("nil\tread-only") == 0);
    CHECK(be.logs[6] == "false\tfalse");
    CHECK(be.files["/plugins/test/asset.txt"] == "A" && be.files["/secret.txt"] == "S");
  }
  {
    TEST("fs: limits and failure paths");
    LuaVm vm;
    MockBackend be;
    be.files["/plugins/test/big.bin"] = std::string(200 * 1024, 'x');
    be.dirs.insert("/plugins/test/d");
    setup(vm, be,
          "print(fs.read('big.bin'))\n"
          "print(fs.write('data:big', string.rep('y', 300*1024)))\n"
          "print(fs.read('d'))\n"
          "print(fs.list('big.bin'))\n"
          "print(fs.list('nope'))\n"
          "print(fs.size('d'))",
          2048 * 1024);
    CHECK(run(vm, be, 100000) == Status::Finished);
    CHECK(be.logs[0].find("nil\tfile too large") == 0);
    CHECK(be.logs[1] == "nil\tdata too large");
    CHECK(be.logs[2] == "nil\tis a directory");
    CHECK(be.logs[3] == "nil\tnot a directory");
    CHECK(be.logs[4].find("nil\t") == 0);
    CHECK(be.logs[5] == "nil\tis a directory");
    LuaVm vm2;
    MockBackend be2;
    be2.failWrites = true;
    setup(vm2, be2, "print(fs.write('data:a', 'x'))");
    CHECK(run(vm2, be2) == Status::Finished);
    CHECK(be2.logs[0] == "nil\twrite error");
  }
  {
    TEST("fs: reading under a tight budget fails cleanly (no crash), VM frees");
    LuaVm vm;
    MockBackend be;
    be.files["/plugins/test/f.bin"] = std::string(60 * 1024, 'z');
    setup(vm, be,
          "local ok, e = pcall(fs.read, 'f.bin') print(ok, tostring(e):sub(1, 17)) print(#string.rep('a', 100))",
          32 * 1024);
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs[0] == "false\tnot enough memory");
    CHECK(be.logs[1] == "100");
    vm.close();
    CHECK(vm.usedBytes() == 0);
  }

  // ======================= Phase 2: require =======================
  {
    TEST("require: app module, caching, dotted names, init.lua, lib fallback, app shadows lib");
    LuaVm vm;
    MockBackend be;
    be.files["/plugins/test/counter.lua"] = "LOADS = (LOADS or 0) + 1 return {n = LOADS, name = ...}";
    be.files["/plugins/test/util/strings.lua"] = "return {up = string.upper}";
    be.files["/plugins/test/pkg/init.lua"] = "return 'pkg-init'";
    be.files["/.crosslua/lib/shared.lua"] = "return 'from-lib'";
    be.files["/.crosslua/lib/counter.lua"] = "return 'WRONG: lib should be shadowed'";
    be.files["/plugins/test/noret.lua"] = "X = 1";
    setup(vm, be,
          "local a = require('counter') local b = require('counter')\n"
          "print(a == b, a.n, a.name, LOADS)\n"
          "print(require('util.strings').up('x'), require('pkg'), require('shared'), require('noret'), X)");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs[0] == "true\t1\tcounter\t1");
    CHECK(be.logs[1] == "X\tpkg-init\tfrom-lib\ttrue\t1");
  }
  {
    TEST("gfx.image: scopes+permission, type/size checks, fit/centre/no-upscale, errors are values");
    MockBackend be;
    be.library = true;
    be.files["/Books/cover.PNG"] = "x";
    be.files["/Books/photo.jpg"] = "x";
    be.files["/Books/notes.txt"] = "x";
    be.files["/Books/empty.png"] = "";
    be.files["/Books/dir.png/x"] = "x";
    be.files["/.crosspoint/secret.png"] = "x";
    be.files["/.crosslua/data/test/pic.png"] = "x";
    be.files["/plugins/test/logo.jpeg"] = "x";
    be.images["/Books/cover.PNG"] = {1000, 2000};
    be.images["/Books/photo.jpg"] = {100, 50};
    be.images["/.crosslua/data/test/pic.png"] = {40, 40};
    be.images["/plugins/test/logo.jpeg"] = {20, 10};
    const char* script = R"LUA(
      local function show(...) print(...) end
      local W, H = gfx.size()                                        -- the mock screen is 240x480
      show(gfx.image("sd:Books/cover.PNG", 0, 0))                    -- 1000x2000 fitted to the whole screen, never upscaled
      show(gfx.image("sd:Books/photo.jpg", 10, 20, 300, 300))        -- small: never upscaled, centred
      show(gfx.image("data:pic.png", 0, 0, 100, 100))
      show(gfx.image("app:logo.jpeg", 0, 0, 480, 100))
      show(gfx.image("logo.jpeg", 0, 0, 480, 100))                   -- bare = app:
      show(gfx.image("sd:Books/notes.txt", 0, 0))                    -- type
      show(gfx.image("sd:Books/empty.png", 0, 0))                    -- empty
      show(gfx.image("sd:Books/missing.png", 0, 0))
      show(gfx.image("sd:Books/dir.png", 0, 0))                      -- directory
      show(gfx.image("sd:.crosspoint/secret.png", 0, 0))             -- hidden
      show(gfx.image("sd:../x.png", 0, 0))
      show(gfx.image("sd:Books/photo.jpg", -1, 0)); show(gfx.image("sd:Books/photo.jpg", 0, H)); show(gfx.image("sd:Books/photo.jpg", 0, 0, 4, 4))
      show(gfx.image("sd:Books/photo.jpg", W - 80, H - 100, 500, 500))  -- box clipped to 80x100: 100x50 shrinks to 80x40
    )LUA";
    for (int allowed = 1; allowed >= 0; allowed--) {
      be.library = allowed;
      be.logs.clear();
      be.imageCalls.clear();
      LuaVm vm;
      CHECK(vm.open(256 * 1024));
      registerApi(vm, be);
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      if (getenv("DUMP_LOGS")) {
        printf("   [allowed=%d]\n", allowed);
        for (size_t i = 0; i < be.logs.size(); i++) printf("   [%zu] %s\n", i, be.logs[i].c_str());
        for (auto& c : be.imageCalls) printf("   call %s x=%d y=%d %dx%d\n", c.path.c_str(), c.x, c.y, c.w, c.h);
      }
      CHECK(be.logs.size() == 15);
      if (be.logs.size() != 15) continue;
      CHECK(be.logs[2] == "40\t40" && be.logs[3] == "20\t10" &&
            be.logs[4] == "20\t10");  // data:/app: need no permission
      if (allowed) {
        CHECK(be.logs[0] == "240\t480");  // 1000x2000 into 480x800 -> scale .4
        CHECK(be.logs[1] == "100\t50");   // small image untouched
        CHECK(be.imageCalls.size() == 6);
        if (be.imageCalls.size() == 6) {
          CHECK(be.imageCalls[1].x == 10 + (300 - 100) / 2 &&
                be.imageCalls[1].y == 20 + (300 - 50) / 2);  // centred in its box
          CHECK(be.imageCalls[0].path == "/Books/cover.PNG");
          CHECK(be.imageCalls[5].path == "/Books/photo.jpg" && be.imageCalls[5].w == 80 && be.imageCalls[5].h == 40 &&
                be.imageCalls[5].y == 380 + (100 - 40) / 2);
        }
        CHECK(be.logs[5] == "nil\tunsupported image type (png, jpg, bmp)");
        CHECK(be.logs[6] == "nil\timage file is empty or over 6 MB");
        CHECK(be.logs[7] == "nil\tno such file" && be.logs[8] == "nil\tis a directory");
        CHECK(be.logs[9] == "nil\thidden files and folders are not accessible");
        CHECK(be.logs[10].find("nil\t'.' and '..'") == 0);
        CHECK(be.logs[11] == "nil\tx,y must be on the screen" && be.logs[12] == "nil\tx,y must be on the screen");
        CHECK(be.logs[13] == "nil\tbox must be at least 8x8");
        CHECK(be.logs[14] == "80\t40");
      } else {
        CHECK(be.logs[0].find("nil\tlibrary access not permitted") == 0 &&
              be.logs[1].find("nil\tlibrary access not permitted") == 0);
        CHECK(be.imageCalls.size() == 3);  // only the data:/app: draws happened
        CHECK(be.logs[9].find("nil\tlibrary access not permitted") == 0);
      }
    }
    // a decoder failure is a plain nil,err and never aborts the app
    be.library = true;
    be.imageErr = "decode failed (corrupt image or not enough RAM)";
    be.logs.clear();
    LuaVm vm;
    CHECK(vm.open(64 * 1024));
    registerApi(vm, be);
    const char* s2 = "print(gfx.image('sd:Books/photo.jpg', 0, 0)); print('alive')";
    CHECK(vm.load("t", s2, strlen(s2)));
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs.size() == 2 && be.logs[0] == "nil\tdecode failed (corrupt image or not enough RAM)" &&
          be.logs[1] == "alive");
  }
  {
    TEST("app.restart: plain .lua names in the app folder only, parks the app, hands the entry to the host");
    const char* names[] = {"run.lua",
                           "",
                           "../x.lua",
                           "sub/run.lua",
                           "x.txt",
                           ".hidden.lua",
                           "a..b.lua",
                           "run.LUA",
                           "missing.lua",
                           "with space.lua",
                           "run.lua\n",
                           "a//b.lua",
                           "x.lua/",
                           "/abs.lua",
                           "sub/.hidden.lua",
                           "tests/net.lua",
                           "nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn.lua"};
    const char* wantErr[] = {
        "",           "",           "entry must",           "",           "entry must", "entry must",
        "entry must", "entry must", "no such entry script", "entry must", "entry must", "entry must",
        "entry must", "entry must", "entry must",           "",           "entry must"};
    const char* wantRestart[] = {"run.lua", "main.lua", "", "sub/run.lua",   "", "", "", "", "", "", "", "",
                                 "",        "",         "", "tests/net.lua", ""};
    const int N = sizeof(wantErr) / sizeof(wantErr[0]);
    for (int i = 0; i < N; i++) {
      MockBackend be;
      be.files["/plugins/test/main.lua"] = "-- main";
      be.files["/plugins/test/run.lua"] = "-- run";
      be.files["/plugins/test/.hidden.lua"] = "x";
      be.files["/plugins/test/sub/run.lua"] = "-- sub run";
      be.files["/plugins/test/tests/net.lua"] = "-- net test";
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      std::string script;
      if (i == 1)
        script = "print(app.restart())\nprint('after')";  // no argument = main.lua
      else
        script = std::string("print(app.restart('") + names[i] + "'))\nprint('after')";
      if (i == 10) script = "print(app.restart('run.lua\\n'))\nprint('after')";  // a newline inside the name
      CHECK(vm.load("t", script.data(), script.size()));
      Status st = run(vm, be);
      CHECK(be.restartedTo == wantRestart[i]);
      if (wantRestart[i][0]) {
        CHECK(st == Status::Waiting && vm.timeoutMs() == -1 && !vm.wakesOnEvent() &&
              be.logs.empty());  // parked: 'after' never runs
      } else {
        CHECK(st == Status::Finished && be.logs.size() == 2 && be.logs[1] == "after");
        CHECK(be.logs.size() == 2 && be.logs[0].find("false\t") == 0 &&
              be.logs[0].find(wantErr[i]) != std::string::npos);
        if (be.logs.size() != 2 || be.logs[0].find(wantErr[i]) == std::string::npos)
          printf("    [%d] '%s' -> '%s'\n", i, names[i], be.logs.empty() ? "" : be.logs[0].c_str());
      }
    }
    MockBackend be;
    LuaVm vm;
    CHECK(vm.open(64 * 1024));
    registerApi(vm, be);
    const char* s2 = "print(app.entry(), pcall(app.restart, 42))";
    CHECK(vm.load("t", s2, strlen(s2)));
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs.size() == 1 && be.logs[0].find("main.lua\ttrue\tfalse") == 0 && be.restartedTo.empty());
  }
  {
    TEST("storage grants: parseGrantPath / grantIsDangerous");
    struct P {
      const char* in;
      const char* want;
    };  // want == nullptr -> rejected
    const P cases[] = {{"Books", "Books"}, {"Books/AO3/", "Books/AO3"}, {"/", ""},
                       {"a/b/c", "a/b/c"}, {"My Books", "My Books"},    {"", nullptr},
                       {"..", nullptr},    {"../x", nullptr},           {"a/../b", nullptr},
                       {"a/./b", nullptr}, {".hidden", nullptr},        {"a/.b", nullptr},
                       {"/abs", nullptr},  {"a//b", nullptr},           {"a:b", nullptr},
                       {"a\\b", nullptr},  {"a\tb", nullptr},           {"//", nullptr},
                       {".", nullptr},     {"sd:Books", nullptr}};
    for (const P& c : cases) {
      char out[120];
      const bool ok = crosslua::parseGrantPath(c.in, out, sizeof(out));
      CHECK(ok == (c.want != nullptr));
      if (c.want) CHECK(ok && !strcmp(out, c.want));
      if (ok != (c.want != nullptr) || (ok && c.want && strcmp(out, c.want)))
        printf("    parseGrantPath('%s') -> %d '%s'\n", c.in, ok, ok ? out : "");
    }
    char out[120];
    CHECK(!crosslua::parseGrantPath(std::string(101, 'a').c_str(), out, sizeof(out)));
    CHECK(!crosslua::parseGrantPath("Books", out, 3));  // does not fit
    CHECK(crosslua::grantIsDangerous("") && crosslua::grantIsDangerous("plugins") &&
          crosslua::grantIsDangerous("Plugins/x"));
    CHECK(!crosslua::grantIsDangerous("pluginsX") && !crosslua::grantIsDangerous("Books") &&
          !crosslua::grantIsDangerous("Books/plugins"));
  }
  {
    TEST("storage grants: read/write scope rules, prefix boundary, hidden paths, firmware images, library interplay");
    struct Case {
      const char* name;
      bool library;
      std::vector<std::pair<std::string, bool>> grants;
      const char* script;
      std::vector<std::string> want;
    };
    const std::string OUTSIDE =
        "nil\tlibrary access not permitted: this path is outside the folders granted to this app";
    const std::string RO = "nil\tread-only location (the app has no write grant for this folder)";
    const std::string BIN = "nil\tread-only location (firmware images (*.bin) can never be written)";
    const std::string HIDDEN = "nil\thidden files and folders are not accessible";
    const Case cases[] = {
        {"read Books, write Books/AO3 + Downloads, no library",
         false,
         {{"Books", false}, {"Books/AO3", true}, {"Downloads", true}},
         R"LUA(
           local function show(...) print(...) end
           show(fs.read("sd:Books/a.epub"))
           show(fs.read("sd:BooksX/z.txt")); show(fs.read("sd:top.txt")); show(fs.list("sd:"))
           show(fs.read("sd:.crosspoint/wifi.json"))
           show(fs.write("sd:Books/new.txt", "x"))
           show(fs.write("sd:Books/AO3/new.epub", "x"))
           show(fs.write("sd:Books/AO3/fw.bin", "x"))
           show(fs.write("sd:Downloads/n.txt", "x")); show(fs.read("sd:Downloads/n.txt"))
           show(fs.remove("sd:Books/AO3/old.epub")); show(fs.remove("sd:Books/a.epub"))
           show(fs.rename("sd:Books/AO3/new.epub", "sd:Downloads/m.epub"))
           show(fs.rename("sd:Downloads/m.epub", "sd:Books/m.epub"))
           show(fs.write("sd:plugins/evil/main.lua", "x"))
           show(fs.exists("sd:BooksX/z.txt"))
           show(fs.write("sd:Books/AO3/x.BIN", "x"))
         )LUA",
         {"PK-a", OUTSIDE, OUTSIDE, OUTSIDE, HIDDEN, RO, "true", BIN, "true", "x", "true", RO, "true", RO, OUTSIDE,
          "false", BIN}},
        {"library (read everything) + the same grants: writes still only where granted",
         true,
         {{"Books", false}, {"Books/AO3", true}, {"Downloads", true}},
         R"LUA(
           local function show(...) print(...) end
           show(fs.read("sd:top.txt")); show(fs.write("sd:top.txt", "y")); show(fs.write("sd:Downloads/q.txt", "y"))
           show(fs.read("sd:.crosspoint/wifi.json"))
         )LUA",
         {"t", RO, "true", HIDDEN}},
        {"whole-card write grant: everything but hidden paths and *.bin",
         false,
         {{"", true}},
         R"LUA(
           local function show(...) print(...) end
           show(fs.write("sd:top.txt", "y")); show(fs.write("sd:plugins/x/main.lua", "y"))
           show(fs.write("sd:.crosspoint/a", "y")); show(fs.write("sd:fw.bin", "y")); show(fs.read("sd:BooksX/z.txt"))
         )LUA",
         {"true", "true", HIDDEN, BIN, "z"}},
        {"no grants and no library: nothing outside the sandbox",
         false,
         {},
         R"LUA(print(fs.read("sd:Books/a.epub")))LUA",
         {"nil\tlibrary access not permitted: add \"library\" to \"permissions\" in manifest.json"}},
        {"library only (no grants): read-only, original message",
         true,
         {},
         R"LUA(print(fs.write("sd:top.txt", "y")))LUA",
         {"nil\tread-only location (write to 'data:...')"}},
    };
    for (const Case& c : cases) {
      MockBackend be;
      be.library = c.library;
      be.grants = c.grants;
      be.files["/Books/a.epub"] = "PK-a";
      be.files["/Books/AO3/old.epub"] = "old";
      be.files["/BooksX/z.txt"] = "z";
      be.files["/Downloads/d.txt"] = "d";
      be.files["/plugins/other/main.lua"] = "other app";
      be.files["/.crosspoint/wifi.json"] = "{\"pw\":\"hunter2\"}";
      be.files["/top.txt"] = "t";
      LuaVm vm;
      CHECK(vm.open(256 * 1024));
      registerApi(vm, be);
      CHECK(vm.load("t", c.script, strlen(c.script)));
      CHECK(run(vm, be, 200000) == Status::Finished);
      CHECK(be.logs.size() == c.want.size());
      for (size_t i = 0; i < c.want.size() && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == c.want[i]);
        if (be.logs[i] != c.want[i])
          printf("    [%s] #%zu got '%s' want '%s'\n", c.name, i + 1, be.logs[i].c_str(), c.want[i].c_str());
      }
      for (auto& l : be.logs) CHECK(l.find("hunter2") == std::string::npos && l.find("other app") == std::string::npos);
    }
    // what the app did to the card, for the first case: exactly the granted writes happened
    MockBackend be;
    be.library = false;
    be.grants = {{"Books", false}, {"Books/AO3", true}, {"Downloads", true}};
    be.files["/Books/a.epub"] = "PK-a";
    be.files["/Books/AO3/old.epub"] = "old";
    be.files["/top.txt"] = "t";
    LuaVm vm;
    CHECK(vm.open(256 * 1024));
    registerApi(vm, be);
    const char* s2 =
        "fs.write('sd:Books/AO3/new.epub', 'N'); fs.write('sd:Downloads/n.txt', 'D'); fs.write('sd:Books/evil.txt', "
        "'E'); "
        "fs.write('sd:top.txt', 'T'); fs.remove('sd:Books/a.epub'); fs.remove('sd:Books/AO3/old.epub')";
    CHECK(vm.load("t", s2, strlen(s2)));
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.files["/Books/AO3/new.epub"] == "N" && be.files["/Downloads/n.txt"] == "D");
    CHECK(!be.files.count("/Books/evil.txt") && be.files["/top.txt"] == "t" && be.files["/Books/a.epub"] == "PK-a");
    CHECK(!be.files.count("/Books/AO3/old.epub"));
  }
  {
    TEST("storage grants: http save_to may target a granted sd: folder and nothing else");
    MockBackend be;
    be.wifiUp = true;
    be.library = false;
    be.grants = {{"Books/AO3", true}, {"Books", false}};
    be.routes["http://h/a"] = {200, "hello", ""};
    LuaVm vm;
    CHECK(vm.open(256 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      local r = http.get("http://h/a", {save_to = "sd:Books/AO3/dl.epub"}); print(r.status, r.bytes)
      print(http.get("http://h/a", {save_to = "sd:Books/dl.epub"}))        -- read-only grant
      print(http.get("http://h/a", {save_to = "sd:Books/AO3/fw.bin"}))     -- firmware image
      print(http.get("http://h/a", {save_to = "sd:top.txt"}))              -- outside every grant
      r = http.get("http://h/a", {save_to = "data:ok.txt"}); print(r.status)
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 100000) == Status::Finished);
    const std::string W = "nil\tsave_to must be a data: path or an sd: folder this app has a write grant for";
    CHECK(be.logs.size() == 5);
    if (be.logs.size() == 5) {
      CHECK(be.logs[0] == "200\t5" && be.logs[1] == W && be.logs[2] == W);
      CHECK(be.logs[3].find("nil\tlibrary access not permitted: this path is outside") == 0 && be.logs[4] == "200");
    }
    CHECK(be.files["/Books/AO3/dl.epub"] == "hello" && !be.files.count("/Books/dl.epub") &&
          !be.files.count("/Books/AO3/fw.bin") && !be.files.count("/top.txt"));
  }
  {
    TEST("gfx.image: .bmp (any case) is accepted and fitted like png/jpg; other types still refused");
    MockBackend be;
    be.library = true;
    be.files["/Books/pic.bmp"] = "BM";
    be.files["/Books/UP.BMP"] = "BM";
    be.files["/Books/pic.gif"] = "GIF";
    be.images["/Books/pic.bmp"] = {64, 32};
    be.images["/Books/UP.BMP"] = {10, 10};
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      print(gfx.image("sd:Books/pic.bmp", 0, 0, 30, 30))
      print(gfx.image("sd:Books/UP.BMP", 5, 5, 50, 50))
      print(gfx.image("sd:Books/pic.gif", 0, 0))
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 100000) == Status::Finished);
    CHECK(be.logs.size() == 3 && be.logs[0] == "30\t15" && be.logs[1] == "10\t10" &&
          be.logs[2] == "nil\tunsupported image type (png, jpg, bmp)");
    CHECK(be.imageCalls.size() == 2 && be.imageCalls[0].path == "/Books/pic.bmp" &&
          be.imageCalls[1].x == 5 + (50 - 10) / 2);
  }
  {
    TEST(
        "crypto: md5 and crc32 vs hashlib/zlib vectors (RFC 1321, the CRC-32 check value), chunked == one-shot, "
        "limits");
    MockBackend be;
    LuaVm vm;
    CHECK(vm.open(512 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      for _, s in ipairs({"", "a", "abc", "message digest", "abcdefghijklmnopqrstuvwxyz", ("1234567890"):rep(8)}) do
        print(crypto.hex(crypto.md5(s)))
      end
      print(crypto.hex(crypto.md5(("0123456789abcdef"):rep(4096))))   -- exactly 64 KB: the one-shot limit
      print(crypto.md5(("x"):rep(65537)))                              -- one byte over
      local bin = {}
      for i = 1, 768 do bin[i] = string.char((i - 1) % 256) end
      bin = table.concat(bin)
      print(crypto.hex(crypto.md5(bin)))
      local h = crypto.hash("md5")
      for i = 1, #bin, 100 do h:update(bin:sub(i, i + 99)) end
      local d = h:digest()
      print(#d, crypto.hex(d) == crypto.hex(crypto.md5(bin)))
      print(h:digest())
      print(crypto.hash("whirlpool"))
      for _, s in ipairs({"", "a", "abc", "123456789", "The quick brown fox jumps over the lazy dog"}) do
        print(crypto.hex(crypto.crc32(s)))
      end
      print(#crypto.crc32("x"), crypto.hex(crypto.crc32(bin)))
      local whole = ("hello, crc world"):rep(50)
      local first = crypto.crc32(whole:sub(1, 300))
      print(crypto.hex(first), crypto.hex(crypto.crc32(whole:sub(301), first)), crypto.hex(crypto.crc32(whole)))
      print(crypto.crc32("x", "abc"))
      print(crypto.crc32(("x"):rep(65537)))
      print(select("#", pcall(crypto.md5)), (pcall(crypto.md5)))
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 20000000) == Status::Finished);
    const std::vector<std::string> want = {
        "d41d8cd98f00b204e9800998ecf8427e",
        "0cc175b9c0f1b6a831c399e269772661",
        "900150983cd24fb0d6963f7d28e17f72",
        "f96b697d7cb7938d525a2f31aaf161d0",
        "c3fcd3d76192e4007dfb496cca67e13b",
        "57edf4a22be3c955ac49da2e2107b67a",
        "ea2e4a9d8add947abc90705d59d34a74",
        "nil\tdata must be at most 64 KB (use crypto.hash for more)",
        "e6899eaaf06fd702f3ed3f988eb19362",
        "16\ttrue",
        "nil\thash already finished (digest() was called)",
        "nil\tunknown algorithm (sha1, sha256, md5)",
        "00000000",
        "e8b7be43",
        "352441c2",
        "cbf43926",
        "414fa339",
        "4\tb0c0df2a",
        "fff3c395\t9f9f71b5\t9f9f71b5",
        "nil\tprevious must be a 4-byte crc32 string",
        "nil\tdata must be at most 64 KB (call again with the previous value for more)",
        "2\tfalse",
    };
    CHECK(be.logs == want);
    if (be.logs != want) {
      for (size_t i = 0; i < std::max(be.logs.size(), want.size()); i++)
        printf("  [%zu] got '%s' want '%s'\n", i, i < be.logs.size() ? be.logs[i].c_str() : "<none>",
               i < want.size() ? want[i].c_str() : "<none>");
    }
  }
  {
    TEST(
        "crypto: mbedtls hashes/HMAC/PBKDF2/AES-CBC vs hashlib+openssl vectors, RFC 4231/6238/7914/4648, limits, "
        "errors");
    MockBackend be;
    LuaVm vm;
    CHECK(vm.open(512 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      local function show(...) print(...) end
      show(crypto.hex(crypto.sha256("abc")))
      show(crypto.hex(crypto.sha256("")))
      show(crypto.hex(crypto.sha1("abc")))
      show(crypto.hex(crypto.hmac_sha256("key", "The quick brown fox jumps over the lazy dog")))
      show(crypto.hex(crypto.hmac_sha1("key", "The quick brown fox jumps over the lazy dog")))
      show(crypto.hex(crypto.hmac_sha256(("\11"):rep(20), "Hi There")))
      show(crypto.hex(crypto.hmac_sha256(("k"):rep(131), "long key is hashed first")))
      local function totp(secret, counter, digits)
        local h = crypto.hmac_sha1(secret, string.pack(">I4I4", 0, counter))
        local o = h:byte(20) & 15
        local n = ((h:byte(o + 1) & 0x7f) << 24) | (h:byte(o + 2) << 16) | (h:byte(o + 3) << 8) | h:byte(o + 4)
        return string.format("%0" .. digits .. "d", n % math.tointeger(10 ^ digits))
      end
      show(totp("12345678901234567890", 1, 8))
      show(totp("12345678901234567890", 37037036, 8))
      show((function() local h = crypto.hash("sha256"); h:update("a"):update("bc"); return crypto.hex(h:digest()) end)())
      local hh = crypto.hash("sha1"); hh:update("x"); hh:digest()
      show(hh:digest())
      show(hh:update("y"))
      show(crypto.hash("whirlpool"))
      show((function() local h = crypto.hash("sha256"); local d = ("0123456789"):rep(10000); for i = 1, #d, 7777 do h:update(d:sub(i, i + 7776)) end; return crypto.hex(h:digest()) end)())
      show(crypto.hex(crypto.pbkdf2_sha256("passwd", "salt", 1, 64)))
      show(crypto.hex(crypto.pbkdf2_sha256("password", "salt", 2, 32)))
      show(crypto.hex(crypto.pbkdf2_sha256("password", "salt", 4096, 32)))
      show(crypto.hex(crypto.pbkdf2_sha256("pw", "s", 20000, 32)))
      show(crypto.hex(crypto.pbkdf2_sha256("pw", "s", 10000, 64)))
      show(crypto.pbkdf2_sha256("pw", "s", 0, 32))
      show(crypto.pbkdf2_sha256("pw", "s", 20001, 32))
      show(crypto.pbkdf2_sha256("pw", "s", 1.5, 32))
      show(crypto.pbkdf2_sha256("pw", "s", 10, 0))
      show(crypto.pbkdf2_sha256("pw", "s", 10, 65))
      show(crypto.pbkdf2_sha256("pw", "s", 10001, 64))
      show(crypto.pbkdf2_sha256(("p"):rep(1025), "s", 1, 32))
      show((function() local a, b = crypto.random(16), crypto.random(16); return #a, #b, a ~= b end)())
      show(crypto.random(0))
      show(crypto.random(257))
      show(crypto.random(1.5))
      show((function() local r = crypto.random(256); return #r end)())
      show(crypto.hex("\0\1\255abc"))
      show(crypto.hex(""))
      show(crypto.unhex("0001FFab") == "\0\1\255\171")
      show(crypto.unhex("abc"))
      show(crypto.unhex("zz"))
      show(crypto.b64encode(""))
      show(crypto.b64encode("f"))
      show(crypto.b64encode("fo"))
      show(crypto.b64encode("foo"))
      show(crypto.b64encode("foob"))
      show(crypto.b64encode("fooba"))
      show(crypto.b64encode("foobar"))
      show(crypto.b64decode("Zm9vYmFy") .. "|" .. crypto.b64decode("Zm9vYg==") .. "|" .. crypto.b64decode("Zm9vYmE=") .. "|" .. crypto.b64decode("Zg==") .. "|" .. crypto.b64decode(""))
      show((function() local all = {} for i = 0, 255 do all[#all + 1] = string.char(i) end local s = table.concat(all); return crypto.b64decode(crypto.b64encode(s)) == s end)())
      show(crypto.b64decode("Zg="))
      show(crypto.b64decode("Zg==Zg=="))
      show(crypto.b64decode("Z!=="))
      show(crypto.b64decode("A==="))
      show(crypto.b64decode("Zm9v\n"))
      show(crypto.b64decode("Zm9\n"))
      show(crypto.equal("abc", "abc"), crypto.equal("abc", "abd"), crypto.equal("abc", "ab"), crypto.equal("", ""), crypto.equal("abc", ""), crypto.equal("", "abc"))
      show(crypto.equal("ab", "abab"), crypto.equal("abab", "ab"))
      show(crypto.sha256(("x"):rep(65537)))
      show((function() local ok = pcall(crypto.sha256, {}) return ok end)())
      show((function() local h = crypto.hash("sha256"); local ok = pcall(h.update, {}, "x"); return ok end)())
      show(crypto.hex(crypto.aes_cbc_encrypt("\000\001\002\003\004\005\006\007\008\009\010\011\012\013\014\015\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", "\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", "\084\104\101\032\113\117\105\099\107\032\098\114\111\119\110\032\102\111\120\032\106\117\109\112\115\032\111\118\101\114\032\116\104\101\032\108\097\122\121\032\100\111\103")) == "b746e4f1bce2352d20440b8a2e0eb8fd68c1fcd0d00fcac779ecaadacde7e51a41da205eac66749510362db1c9f3e6d5")
      show(crypto.aes_cbc_decrypt("\000\001\002\003\004\005\006\007\008\009\010\011\012\013\014\015\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", "\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", crypto.unhex("b746e4f1bce2352d20440b8a2e0eb8fd68c1fcd0d00fcac779ecaadacde7e51a41da205eac66749510362db1c9f3e6d5")) == "\084\104\101\032\113\117\105\099\107\032\098\114\111\119\110\032\102\111\120\032\106\117\109\112\115\032\111\118\101\114\032\116\104\101\032\108\097\122\121\032\100\111\103")
      show(crypto.hex(crypto.aes_cbc_encrypt("\100\101\102\103\104\105\106\107\108\109\110\111\112\113\114\115", "\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", "")) == "b47a9582cb53c4f78750542bb26f748d")
      show(crypto.aes_cbc_decrypt("\100\101\102\103\104\105\106\107\108\109\110\111\112\113\114\115", "\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", crypto.unhex("b47a9582cb53c4f78750542bb26f748d")) == "")
      show(crypto.hex(crypto.aes_cbc_encrypt("\050\051\052\053\054\055\056\057\058\059\060\061\062\063\064\065\066\067\068\069\070\071\072\073", "\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", "\120\120\120\120\120\120\120\120\120\120\120\120\120\120\120\120")) == "7414e9dde9efc656b99aa2c799004f84ab90f6844fec4c12ff3e88f9b713167d")
      show(crypto.aes_cbc_decrypt("\050\051\052\053\054\055\056\057\058\059\060\061\062\063\064\065\066\067\068\069\070\071\072\073", "\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", crypto.unhex("7414e9dde9efc656b99aa2c799004f84ab90f6844fec4c12ff3e88f9b713167d")) == "\120\120\120\120\120\120\120\120\120\120\120\120\120\120\120\120")
      show(crypto.hex(crypto.aes_cbc_encrypt("\000\001\002\003\004\005\006\007\008\009\010\011\012\013\014\015\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", "\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", "\121\121\121\121\121\121\121\121\121\121\121\121\121\121\121\121\121")) == "b24c426288a55384b4163857ba5752e4607c835760de94cd2c2882cae71e97c7")
      show(crypto.aes_cbc_decrypt("\000\001\002\003\004\005\006\007\008\009\010\011\012\013\014\015\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", "\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", crypto.unhex("b24c426288a55384b4163857ba5752e4607c835760de94cd2c2882cae71e97c7")) == "\121\121\121\121\121\121\121\121\121\121\121\121\121\121\121\121\121")
      show(crypto.hex(crypto.aes_cbc_encrypt("\100\101\102\103\104\105\106\107\108\109\110\111\112\113\114\115", "\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", "\000\001\002\003\004\005\006\007\008\009\010\011\012\013\014\015\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031\032\033\034\035\036\037\038\039\040\041\042\043\044\045\046\047\048\049\050\051\052\053\054\055\056\057\058\059\060\061\062\063\064\065\066\067\068\069\070\071\072\073\074\075\076\077\078\079\080\081\082\083\084\085\086\087\088\089\090\091\092\093\094\095\096\097\098\099\100\101\102\103\104\105\106\107\108\109\110\111\112\113\114\115\116\117\118\119\120\121\122\123\124\125\126\127\128\129\130\131\132\133\134\135\136\137\138\139\140\141\142\143\144\145\146\147\148\149\150\151\152\153\154\155\156\157\158\159\160\161\162\163\164\165\166\167\168\169\170\171\172\173\174\175\176\177\178\179\180\181\182\183\184\185\186\187\188\189\190\191\192\193\194\195\196\197\198\199\200\201\202\203\204\205\206\207\208\209\210\211\212\213\214\215\216\217\218\219\220\221\222\223\224\225\226\227\228\229\230\231\232\233\234\235\236\237\238\239\240\241\242\243\244\245\246\247\248\249\250\251\252\253\254\255")) == "edf8c35c8098bd6b40e26794154d52dedefe47391afa64ecfb4eb1f998741d81e2acfab7df2f6e41a282506659017c23f77c34ae90465556e61c9be2b3b7616e25101bc421cea7d2e64700b2c4e2dfebf399f2ea7551011efeec6e8602aed4e8689f6956accb5a04fe96f278f0fa6b9b49813b02899644f145b7d5e2c5f62528e5b21786395072297decc3e87cf3a0c337b9df064c3cbd655b6b8a8689bca4ea402abf9cc3bec5b1893d7d7f6b219b97afbe52d8f875a6d89859458041f9f731198031799d381733597bcae4079343e3d3942c5e4d7db00e167d0c26c3e5e7e9ff4aa76961194b7064fb4e7318d7cf42acc1ce312cb451c04f693ed2db66252a28a6615d85d8bade32997685ebf8ecc9")
      show(crypto.aes_cbc_decrypt("\100\101\102\103\104\105\106\107\108\109\110\111\112\113\114\115", "\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", crypto.unhex("edf8c35c8098bd6b40e26794154d52dedefe47391afa64ecfb4eb1f998741d81e2acfab7df2f6e41a282506659017c23f77c34ae90465556e61c9be2b3b7616e25101bc421cea7d2e64700b2c4e2dfebf399f2ea7551011efeec6e8602aed4e8689f6956accb5a04fe96f278f0fa6b9b49813b02899644f145b7d5e2c5f62528e5b21786395072297decc3e87cf3a0c337b9df064c3cbd655b6b8a8689bca4ea402abf9cc3bec5b1893d7d7f6b219b97afbe52d8f875a6d89859458041f9f731198031799d381733597bcae4079343e3d3942c5e4d7db00e167d0c26c3e5e7e9ff4aa76961194b7064fb4e7318d7cf42acc1ce312cb451c04f693ed2db66252a28a6615d85d8bade32997685ebf8ecc9")) == "\000\001\002\003\004\005\006\007\008\009\010\011\012\013\014\015\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031\032\033\034\035\036\037\038\039\040\041\042\043\044\045\046\047\048\049\050\051\052\053\054\055\056\057\058\059\060\061\062\063\064\065\066\067\068\069\070\071\072\073\074\075\076\077\078\079\080\081\082\083\084\085\086\087\088\089\090\091\092\093\094\095\096\097\098\099\100\101\102\103\104\105\106\107\108\109\110\111\112\113\114\115\116\117\118\119\120\121\122\123\124\125\126\127\128\129\130\131\132\133\134\135\136\137\138\139\140\141\142\143\144\145\146\147\148\149\150\151\152\153\154\155\156\157\158\159\160\161\162\163\164\165\166\167\168\169\170\171\172\173\174\175\176\177\178\179\180\181\182\183\184\185\186\187\188\189\190\191\192\193\194\195\196\197\198\199\200\201\202\203\204\205\206\207\208\209\210\211\212\213\214\215\216\217\218\219\220\221\222\223\224\225\226\227\228\229\230\231\232\233\234\235\236\237\238\239\240\241\242\243\244\245\246\247\248\249\250\251\252\253\254\255")
      show(crypto.aes_cbc_encrypt("short", "\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", "x"))
      show(crypto.aes_cbc_encrypt("\000\001\002\003\004\005\006\007\008\009\010\011\012\013\014\015\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", "short", "x"))
      show(crypto.aes_cbc_decrypt("\000\001\002\003\004\005\006\007\008\009\010\011\012\013\014\015\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", "\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", ""))
      show(crypto.aes_cbc_decrypt("\000\001\002\003\004\005\006\007\008\009\010\011\012\013\014\015\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", "\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", ("x"):rep(17)))
      show(crypto.aes_cbc_decrypt("\000\001\002\003\004\005\006\007\008\009\010\011\012\013\014\015\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", "\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", crypto.unhex("b746e4f1bce2352d20440b8a2e0eb8fd68c1fcd0d00fcac779ecaadacde7e51a41da205eac66749510362db1c9f3e6d4")))
      show(crypto.aes_cbc_encrypt("\000\001\002\003\004\005\006\007\008\009\010\011\012\013\014\015\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", "\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031", ("x"):rep(32769)))
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 20000000) == Status::Finished);
    const char* want[] = {
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "a9993e364706816aba3e25717850c26c9cd0d89d",
        "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
        "de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9",
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
        "58c39cb23be2c42a45858a15d8a27efdab8e27605b04b156381425ba728e223e",
        "94287082",
        "07081804",
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "nil\thash already finished (digest() was called)",
        "nil\thash already finished (digest() was called)",
        "nil\tunknown algorithm (sha1, sha256, md5)",
        "aca9e593cc629cbaa94cd5a07dc029424aad93e5129e5d11f8dcd2f139c16cc0",
        "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30b"
        "d509112041d3a19783",
        "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43",
        "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a",
        "eeebc7819be4c9aaf68e56623a98047198c8dae5220986b4ed483510e57f8718",
        "f33af7b585171cd70c33fd304a46fe216a8a4c0e6101cbea5cdb9bd8f361da6f0c4b6897ec2cd60be49b19eefa285ebcc471f58d3561fd"
        "378568093c78e7079f",
        "nil\titerations must be an integer 1..20000",
        "nil\titerations must be an integer 1..20000",
        "nil\titerations must be an integer 1..20000",
        "nil\tlen must be an integer 1..64",
        "nil\tlen must be an integer 1..64",
        "nil\ttoo much work: iterations x ceil(len/32) must be <= 20000",
        "nil\tpassword and salt must be at most 1 KB",
        "16\t16\ttrue",
        "nil\tn must be an integer 1..256",
        "nil\tn must be an integer 1..256",
        "nil\tn must be an integer 1..256",
        "256",
        "0001ff616263",
        "",
        "true",
        "nil\todd number of hex digits",
        "nil\tnot a hex string",
        "",
        "Zg==",
        "Zm8=",
        "Zm9v",
        "Zm9vYg==",
        "Zm9vYmE=",
        "Zm9vYmFy",
        "foobar|foob|fooba|f|",
        "true",
        "nil\tnot valid base64 (length must be a multiple of 4)",
        "nil\tnot valid base64",
        "nil\tnot valid base64",
        "nil\tnot valid base64",
        "nil\tnot valid base64 (length must be a multiple of 4)",
        "nil\tnot valid base64",
        "true\tfalse\tfalse\ttrue\tfalse\tfalse",
        "false\tfalse",
        "nil\tdata must be at most 64 KB (use crypto.hash for more)",
        "false",
        "false",
        "true",
        "true",
        "true",
        "true",
        "true",
        "true",
        "true",
        "true",
        "true",
        "true",
        "nil\tkey must be 16, 24 or 32 bytes",
        "nil\tiv must be 16 bytes",
        "nil\tciphertext length must be a non-zero multiple of 16",
        "nil\tciphertext length must be a non-zero multiple of 16",
        "nil\tbad padding (wrong key, wrong iv or corrupted data)",
        "nil\tdata must be at most 32 KB",
    };
    const size_t N = sizeof(want) / sizeof(want[0]);
    CHECK(be.logs.size() == N);
    for (size_t i = 0; i < N && i < be.logs.size(); i++) {
      CHECK(be.logs[i] == want[i]);
      if (be.logs[i] != want[i]) printf("    crypto #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
    }
  }
  {
    TEST("device.caps / system.usb / device.haptic / input.pos: plumbing, limits, honest 'not on this device'");
    for (int usb = 0; usb < 2; usb++) {
      MockBackend be;
      be.usb = usb == 1;
      be.caps.touch = true;
      be.caps.audio = true;
      be.caps.usbMsc = true;
      be.caps.frontlight = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        local c = device.caps()
        print(c.touch, c.haptic, c.frontlight, c.warmlight, c.color, c.audio, c.ble_keyboard, c.usb_msc, c.width, c.height)
        print(system.usb())
        print(input.pos())
        print(device.haptic(50))
        print(device.haptic(5))
        print(device.haptic(1001))
        print(device.haptic(50, 300))
        print(device.haptic(50.5))
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 8);
      if (be.logs.size() == 8) {
        CHECK(be.logs[0] == "true\tfalse\ttrue\tfalse\tfalse\ttrue\tfalse\ttrue\t800\t480");
        CHECK(be.logs[1] == (usb ? "true" : "false"));
        CHECK(be.logs[2] == "nil");  // no touch event yet
        CHECK(be.logs[3] == "false\tno vibration motor on this device (or vibration is off in settings)");
        CHECK(be.logs[4] == "nil\tms must be an integer 10..1000" &&
              be.logs[5] == "nil\tms must be an integer 10..1000");
        CHECK(be.logs[6] == "nil\tstrength must be an integer 0..255" &&
              be.logs[7] == "nil\tms must be an integer 10..1000");
      }
      CHECK(
          be.hapticCalls.empty());  // nothing reached the motor: absent hardware and every bad argument stopped earlier
    }
    MockBackend be;  // a board WITH a motor
    be.hapticPresent = true;
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script =
        "print(device.haptic(50))\nprint(device.haptic(30, 128))\nprint(device.haptic(10, "
        "0))\nprint(device.haptic(1000))\nprint(device.haptic(5))";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 100000) == Status::Finished);
    CHECK(be.logs.size() == 5 && be.logs[0] == "true" && be.logs[3] == "true" &&
          be.logs[4] == "nil\tms must be an integer 10..1000");
    CHECK(be.hapticCalls.size() == 4);
    if (be.hapticCalls.size() == 4) {
      CHECK(be.hapticCalls[0] == std::make_pair(50, 255) && be.hapticCalls[1] == std::make_pair(30, 128));
      CHECK(be.hapticCalls[2] == std::make_pair(10, 0) && be.hapticCalls[3] == std::make_pair(1000, 255));
    }
  }
  {
    TEST("input: touch events carry a position (input.pos), button events do not");
    MockBackend be;
    be.events = {"tap", "press", "back", "long", "release"};
    be.evPos = {{100, 200}, {7, 8}, {-1, -1}, {40, 50}, {41, 51}};
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      for i = 1, 5 do local e = input.poll(); print(e, input.pos()) end
      print(input.poll(), input.pos())
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 100000) == Status::Finished);
    CHECK(be.logs.size() == 6);
    if (be.logs.size() == 6) {
      CHECK(be.logs[0] == "tap\t100\t200" && be.logs[1] == "press\t7\t8" && be.logs[2] == "back\tnil");
      CHECK(be.logs[3] == "long\t40\t50" && be.logs[4] == "release\t41\t51");
      CHECK(be.logs[5] == "nil\tnil");  // an empty poll clears the position too
    }
  }
  {
    TEST("input.text: parks the script (no wake on input), returns text / nil,cancelled, validates arguments");
    for (int outcome = 0; outcome < 4; outcome++) {
      MockBackend be;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        local s, err = input.text("Name?", "bob", 20, "password")
        print(s, err)
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      be.events = {"confirm", "back"};
      CHECK(run(vm, be) == Status::Waiting);
      CHECK(be.textAsked && be.textTitle == "Name?" && be.textInitial == "bob" && be.textMax == 20 && be.textMode == 1);
      CHECK(be.events.size() == 2 && be.logs.empty());  // button presses did NOT wake it
      CHECK(vm.timeoutMs() == -1 && !vm.wakesOnEvent());
      const char* reply[] = {"text:ok:hello wörld", "text:cancel", "text:ok:", "garbage"};
      CHECK(vm.resume(reply[outcome]) != Status::Error);
      CHECK(run(vm, be, 1000, false) == Status::Finished);
      const char* want[] = {"hello wörld\tnil", "nil\tcancelled", "\tnil", "nil\tcancelled"};
      CHECK(be.logs.size() == 1 && be.logs[0] == want[outcome]);
    }
    {
      MockBackend be;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(input.text("T"))
        print(input.text(("t"):rep(61)))
        print(input.text("T", ("i"):rep(257)))
        print(input.text("T", "", 0))
        print(input.text("T", "", 257))
        print(input.text("T", "", 10, "pin"))
        print(input.text("T", ("i"):rep(30), 10))
        print(pcall(input.text))
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000, false) == Status::Waiting);  // the first call is valid and parks
      CHECK(be.textAsked && be.textMax == 128 && be.textMode == 0 && be.textInitial.empty());  // defaults
      be.textAsked = false;
      CHECK(vm.resume("text:cancel") != Status::Error);
      CHECK(run(vm, be, 100000, false) == Status::Finished);
      CHECK(be.logs.size() == 8);
      if (be.logs.size() == 8) {
        CHECK(be.logs[0] == "nil\tcancelled");
        CHECK(be.logs[1] == "nil\ttitle too long (max 60 characters)");
        CHECK(be.logs[2] == "nil\tinitial text too long (max 256 bytes)");
        CHECK(be.logs[3] == "nil\tmax_len must be an integer 1..256" &&
              be.logs[4] == "nil\tmax_len must be an integer 1..256");
        CHECK(be.logs[5] == "nil\tmode must be text, password or url");
        CHECK(be.logs[6] == "nil\tinitial text is longer than max_len");
        CHECK(be.logs[7].rfind("false\t", 0) == 0);  // missing title raises
      }
      CHECK(!be.textAsked);  // none of the invalid calls reached the host
    }
  }
  {
    TEST("sensors: device.motion / environment / tone, led.*: honest 'not on this device', limits, hardware path");
    for (int hw = 0; hw < 2; hw++) {
      MockBackend be;
      if (hw == 1) {
        be.caps.imu = be.caps.gyro = be.caps.tempHumidity = be.caps.buzzer = be.caps.led = true;
        be.motionPresent = be.envPresent = be.buzzerPresent = true;
        be.ledN = 3;
      }
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        local c = device.caps()
        print(c.imu, c.gyro, c.rtc, c.temp_humidity, c.buzzer, c.mic, c.led, c.tls13)
        local m, err = device.motion()
        if m then print(string.format("%.2f %.2f %.2f %.1f %.1f %.1f %s", m.ax, m.ay, m.az, m.gx, m.gy, m.gz, tostring(m.gyro))) else print(m, err) end
        print(device.environment())
        print(device.tone(440))
        print(device.tone(1000, 250))
        print(device.tone())
        print(device.tone(19))
        print(device.tone(20001))
        print(device.tone(440, -1))
        print(device.tone(440, 10001))
        print(device.tone(440.5))
        print(led.count())
        print(led.set(1, 255, 0, 0))
        print(led.set(0, 1, 2, 3))
        print(led.set(4, 1, 2, 3))
        print(led.set(1, 256, 0, 0))
        print(led.set(1, 0, 1.5, 0))
        print(led.all(1, 2, 3))
        print(led.brightness(128))
        print(led.brightness(300))
        print(led.off())
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 200000) == Status::Finished);
      CHECK(be.logs.size() == 21);
      if (be.logs.size() == 21) {
        if (hw == 0) {
          const char* NO[] = {"false\tfalse\tfalse\tfalse\tfalse\tfalse\tfalse\tfalse",
                              "nil\tno motion sensor on this device",
                              "nil\tno temperature/humidity sensor on this device",
                              "false\tno buzzer on this device",
                              "false\tno buzzer on this device",
                              "false\tno buzzer on this device"};
          for (int i = 0; i < 6; i++) CHECK(be.logs[i] == NO[i]);
          // argument errors are reported before the hardware is asked
          CHECK(be.logs[6] == "nil\tfreq must be an integer 20..20000" &&
                be.logs[7] == "nil\tfreq must be an integer 20..20000");
          CHECK(be.logs[8] == "nil\tms must be an integer 0..10000" &&
                be.logs[9] == "nil\tms must be an integer 0..10000");
          CHECK(be.logs[10] == "nil\tfreq must be an integer 20..20000");
          CHECK(be.logs[11] == "0");
          for (int i = 12; i < 21; i++)
            CHECK(be.logs[i].rfind("false\tno LEDs on this device", 0) == 0 || be.logs[i].rfind("nil\t", 0) == 0);
          CHECK(be.logs[12] == "false\tno LEDs on this device");
          CHECK(be.ledCalls.empty() && be.toneCalls.empty());
        } else {
          CHECK(be.logs[0] == "true\ttrue\tfalse\ttrue\ttrue\tfalse\ttrue\tfalse");
          CHECK(be.logs[1] == "0.50 -0.25 1.00 10.0 -20.0 30.0 true");
          CHECK(be.logs[2] == "21.5\t40.25");
          CHECK(be.logs[3] == "true" && be.logs[4] == "true" && be.logs[5] == "true");
          CHECK(be.logs[6] == "nil\tfreq must be an integer 20..20000" &&
                be.logs[10] == "nil\tfreq must be an integer 20..20000");
          CHECK(be.logs[11] == "3");
          CHECK(be.logs[12] == "true");
          CHECK(be.logs[13] == "nil\tindex must be an integer 1..3" &&
                be.logs[14] == "nil\tindex must be an integer 1..3");
          CHECK(be.logs[15] == "nil\tr, g, b must be integers 0..255" &&
                be.logs[16] == "nil\tr, g, b must be integers 0..255");
          CHECK(be.logs[17] == "true" && be.logs[18] == "true");
          CHECK(be.logs[19] == "nil\tbrightness must be an integer 0..255" && be.logs[20] == "true");
          const std::vector<std::string> wantTone = {"440,0", "1000,250", "stop"};
          CHECK(be.toneCalls == wantTone);
          const std::vector<std::string> wantLed = {"set 0 255 0 0", "all 1 2 3", "brightness 128",
                                                    "off"};  // index is 0-based on the backend
          CHECK(be.ledCalls == wantLed);
        }
      }
    }
    {
      MockBackend be;
      be.caps.imu = true;
      be.motionPresent = true;
      be.motionGyro = false;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script =
          "local m = device.motion()\nprint(string.format('%.2f %.2f %.2f %.1f %.1f %.1f %s', m.ax, m.ay, m.az, m.gx, "
          "m.gy, m.gz, tostring(m.gyro)))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1 &&
            be.logs[0] == "0.50 -0.25 1.00 0.0 0.0 0.0 false");  // gyro fields are zero on accelerometer-only parts
    }
    {
      MockBackend be;
      be.motionPresent = true;
      be.motionFail = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(device.motion())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1 && be.logs[0] == "nil\tmotion sensor read failed");
    }
  }
  {
    TEST("device.caps: each new flag reports its own field (3 variants: flag i = bit k of i, so any swap shows up)");
    const char* names[8] = {"imu", "gyro", "rtc", "temp_humidity", "buzzer", "mic", "led", "tls13"};
    for (int k = 0; k < 3; k++) {
      MockBackend be;
      bool* f[8] = {&be.caps.imu,    &be.caps.gyro, &be.caps.rtc, &be.caps.tempHumidity,
                    &be.caps.buzzer, &be.caps.mic,  &be.caps.led, &be.caps.tls13};
      std::string want;
      for (int i = 0; i < 8; i++) {
        *f[i] = ((i >> k) & 1) != 0;
        want += std::string(i ? "\t" : "") + (*f[i] ? "true" : "false");
      }
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      std::string script = "local c = device.caps()\nprint(";
      for (int i = 0; i < 8; i++) script += std::string(i ? ", " : "") + "c." + names[i];
      script += ")";
      CHECK(vm.load("t", script.c_str(), script.size()));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1 && be.logs[0] == want);
    }
    MockBackend be;
    be.envPresent = true;
    be.envFail = true;
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script = "print(device.environment())";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 100000) == Status::Finished);
    CHECK(be.logs.size() == 1 && be.logs[0] == "nil\ttemperature/humidity sensor read failed");
  }
  {
    TEST("epub.meta: title/author through the path sandbox, .epub only, UTF-8-safe truncation, honest errors");
    MockBackend be;
    be.library = true;
    be.epubs["/Books/a.epub"] = {"A Tale of Two Cities", "Charles Dickens"};
    be.epubs["/Books/anon.epub"] = {"No Author Here", ""};
    std::string longTitle;
    for (int i = 0; i < 150; i++)
      longTitle += "\xC3\xA9";  // 300 bytes of 2-byte characters: the cap lands mid-character
    std::string longAuthor;
    for (int i = 0; i < 100; i++)
      longAuthor += "\xC3\xA9";  // 200 bytes: the 120-byte author cap also lands mid-character
    be.epubs["/Books/long.epub"] = {longTitle, longAuthor};
    be.epubs["/Books/cafe.epub"] = {"Caf\xC3\xA9",
                                    "\xE2\x82\xAC"};  // complete 2- and 3-byte characters at the very end must survive
    be.epubs["/Books/emoji.epub"] = {std::string(197, 'a') + "\xF0\x9F\x98\x80",
                                     "x"};  // a 4-byte character cut by the cap
    be.files["/Books/notes.txt"] = "x";
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      local m = epub.meta("sd:Books/a.epub")
      print(m.title, m.author)
      local n = epub.meta("sd:Books/anon.epub")
      print(n.title, "[" .. n.author .. "]", type(n.author))
      local l = epub.meta("sd:Books/long.epub")
      print(#l.title, l.title:sub(-2) == "\xC3\xA9", #l.author, l.author:sub(-2) == "\xC3\xA9")
      local c = epub.meta("sd:Books/cafe.epub")
      print(#c.title, c.title, #c.author, c.author)
      print(#epub.meta("sd:Books/emoji.epub").title)
      print(epub.meta("sd:Books/notes.txt"))
      print(epub.meta("sd:Books/missing.epub"))
      print(epub.meta("sd:Books/A.EPUB"))
      print(epub.meta("app:../x.epub"))
      print(pcall(epub.meta))
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 200000) == Status::Finished);
    CHECK(be.logs.size() == 10);
    if (be.logs.size() == 10) {
      CHECK(be.logs[0] == "A Tale of Two Cities\tCharles Dickens");
      CHECK(be.logs[1] == "No Author Here\t[]\tstring");
      CHECK(be.logs[2] == "198\ttrue\t118\ttrue");  // title cut at 199 bytes, author at 119: both trimmed back to the
                                                    // last whole character
      CHECK(be.logs[3] == "5\tCaf\xC3\xA9\t3\t\xE2\x82\xAC");  // complete multi-byte tails are NOT trimmed
      CHECK(be.logs[4] == "197");                              // the cut 4-byte character is dropped whole
      CHECK(be.logs[5] == "nil\tnot an .epub file");
      CHECK(be.logs[6] == "nil\tmock: no such book");  // the backend's own message is passed through
      CHECK(be.logs[7] == "nil\tmock: no such book");  // ".EPUB": extension check is case-insensitive
      CHECK(be.logs[8].rfind("nil\t", 0) == 0);        // sandbox: '..' refused before the backend is asked
      CHECK(be.logs[9].rfind("false\t", 0) == 0);
    }
    const std::vector<std::string> asked = {"/Books/a.epub",    "/Books/anon.epub",  "/Books/long.epub",
                                            "/Books/cafe.epub", "/Books/emoji.epub", "/Books/missing.epub",
                                            "/Books/A.EPUB"};
    CHECK(be.epubAsked == asked);  // notes.txt and the '..' path never reached the backend
  }
  {
    TEST("epub.meta: sd: without the library permission or a grant is refused before the backend is asked");
    MockBackend be;
    be.library = false;
    be.epubs["/Books/a.epub"] = {"T", "A"};
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script = "print(epub.meta('sd:Books/a.epub'))";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 100000) == Status::Finished);
    CHECK(be.logs.size() == 1 && be.logs[0].rfind("nil\t", 0) == 0);
    CHECK(be.epubAsked.empty());
  }
  {
    TEST(
        "gfx.save_bmp: same write rules as fs.write (data: yes, sd: needs a grant, app: never, no .bin), .bmp only, "
        "backend errors pass through");
    MockBackend be;
    be.library = true;  // may READ sd: but has no write grant
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      print(gfx.save_bmp("data:shots/a.bmp"))
      print(gfx.save_bmp("data:B.BMP"))
      print(gfx.save_bmp("data:shot.png"))
      print(gfx.save_bmp("sd:Books/x.bmp"))
      print(gfx.save_bmp("app:x.bmp"))
      print(gfx.save_bmp("data:../x.bmp"))
      print(gfx.save_bmp("data:fail.bmp"))
      print(pcall(gfx.save_bmp))
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    be.bmpFailPath = "/.crosslua/data/test/fail.bmp";
    CHECK(run(vm, be, 200000) == Status::Finished);
    CHECK(be.logs.size() == 8);
    if (be.logs.size() == 8) {
      CHECK(be.logs[0] == "true" && be.logs[1] == "true");
      CHECK(be.logs[2] == "nil\tpath must end in .bmp");
      CHECK(be.logs[3] == "nil\tread-only location (write to 'data:...')");
      CHECK(be.logs[4].rfind("nil\t", 0) == 0);
      CHECK(be.logs[5].rfind("nil\t", 0) == 0);
      CHECK(be.logs[6] == "nil\tmock: card full");
      CHECK(be.logs[7].rfind("false\t", 0) == 0);
    }
    const std::vector<std::string> saved = {"/.crosslua/data/test/shots/a.bmp", "/.crosslua/data/test/B.BMP"};
    CHECK(be.bmpSaved ==
          saved);  // only the two good saves; the refused paths never reached the backend, fail.bmp failed
    CHECK(be.dirs.count("/.crosslua/data/test/shots") == 1);  // the parent folder is created like fs.write does
  }
  {
    TEST("net: TCP client sockets: connect/read/write/close, partial reads, peer close, slot reuse, tx recorded");
    MockBackend be;
    be.net = true;
    be.wifiUp = true;
    be.writeChunk = 3;  // the socket takes only 3 bytes per write: net.write must report the real count
    be.sockReply["example.test:80"] = "0123456789ab";
    be.sockReply["closing.test:80"] = "bye";
    be.sockClosesAfterReply.insert("closing.test:80");
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      local h = net.connect("example.test", 80)
      print(h)
      print(net.available(h), net.connected(h))
      print(net.read(h, 4))
      print(net.read(h))
      print("[" .. net.read(h) .. "]", net.connected(h))
      print(net.write(h, "ping"))
      print(net.write(h, ""))
      local g = net.connect("closing.test", 80, {timeout_ms = 250})
      print(g)
      print(net.read(g))
      print(net.read(g))
      print(net.connected(g))
      print(net.close(g))
      print(net.read(g))
      print(net.close(g))
      local g2 = net.connect("example.test", 80)
      print(g2)
      print(net.close(h), net.close(g2))
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 200000) == Status::Finished);
    const char* want[] = {"1",
                          "12\ttrue",
                          "0123",
                          "456789ab",
                          "[]\ttrue",
                          "3",
                          "0",
                          "2",
                          "bye",
                          "nil\tclosed",
                          "false",
                          "true",
                          "nil\tnot an open socket handle",
                          "nil\tnot an open socket handle",
                          "2",
                          "true\ttrue"};
    const size_t N = sizeof(want) / sizeof(want[0]);
    CHECK(be.logs.size() == N);
    for (size_t i = 0; i < N && i < be.logs.size(); i++) {
      CHECK(be.logs[i] == want[i]);
      if (be.logs[i] != want[i]) printf("    net #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
    }
    CHECK(be.socks[0].tx.empty() && !be.socks[0].used);  // closed by the script: the table is clean
    CHECK(be.txLog == "example.test:80<-pin");  // exactly one non-empty write reached the backend (cut to 3 bytes)
    CHECK(be.connectOpts.size() == 3 && be.connectOpts[1] == 250 &&
          be.connectOpts[0] == 5000);  // timeout default and explicit
  }
  {
    TEST("net.udp: open/send/recv/close, two sockets, scripted peer replies, kind checks, exhaustion");
    MockBackend be;
    be.net = true;
    be.wifiUp = true;
    be.sockReply["192.0.2.9:9098"] = "PONG";
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      local h = net.udp_open(0)
      print(h)
      print(net.udp_send(h, "192.0.2.9", 9098, "ping"))
      local p = net.udp_recv(h)
      print(p and (p.data .. "|" .. p.ip .. "|" .. p.port))
      print(net.udp_recv(h))                       -- nothing pending -> nil
      print(net.udp_send(h, "192.0.2.9", 9099, "ECHO " .. ("x"):rep(295)))
      print(net.udp_recv(h))
      local g = net.udp_open(9098)
      print(g ~= h, g)
      print(net.udp_send(g, "192.0.2.9", 9098, "ping") == 4 and net.udp_recv(g).data)
      print(net.udp_close(h))
      print(net.udp_send(h, "192.0.2.9", 9098, "x"))
      print(net.read(g))                           -- a UDP slot is not a TCP socket (net.read on the open one)
      local c = net.connect("example.test", 80)
      print(net.udp_send(c, "192.0.2.9", 9098, "x"))
      print(net.udp_recv(c))
      print(net.udp_close(g))
      print(net.udp_close(c))                      -- a TCP handle is not a UDP handle
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 300000) == Status::Finished);
    const char* want[] = {"1",
                          "4",
                          "PONG|192.0.2.9|9098",
                          "nil",
                          "300",
                          "nil",
                          "true\t2",
                          "PONG",
                          "true",
                          "nil\tnot an open socket handle",
                          "nil\tnot a TCP socket",
                          "nil\tnot a UDP socket",
                          "nil\tnot a UDP socket",
                          "true",
                          "nil\tnot a UDP socket"};  // net.connect prints nothing: c reuses slot 0
    const size_t N = sizeof(want) / sizeof(want[0]);
    CHECK(be.logs.size() == N);
    for (size_t i = 0; i < N && i < be.logs.size(); i++) {
      CHECK(be.logs[i] == want[i]);
      if (be.logs[i] != want[i]) printf("    udp #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
    }
    const std::string wantTx =
        "192.0.2.9:9098<-ping192.0.2.9:9099<-ECHO " + std::string(295, 'x') + "192.0.2.9:9098<-ping";
    if (be.txLog != wantTx) printf("    txLog differs (%zu vs %zu)\n", be.txLog.size(), wantTx.size());
    CHECK(be.txLog == wantTx);
    // slot 0 was reused by the TCP connect (handle 1, still open); slot 1 held g and was closed
    if (be.socks[0].kind != 1 || be.socks[1].kind != 0) printf("    kinds %d %d\n", be.socks[0].kind, be.socks[1].kind);
    CHECK(be.socks[0].kind == 1 && be.socks[1].kind == 0);
  }
  {
    TEST("net.udp: gates, limits, argument validation; nothing invalid reaches the backend");
    MockBackend be;
    be.net = true;
    be.wifiUp = true;
    be.udpSendFail = true;
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      print(net.udp_open(65536))
      print(net.udp_open(-1))
      print(net.udp_open(80.5))
      local h = net.udp_open(0)
      print(h)
      print(net.udp_send(h, "192.0.2.9", 9098, "x"))
      print(net.udp_send(h, "bad host", 9098, "x"))
      print(net.udp_send(h, "192.0.2.9", 0, "x"))
      print(net.udp_send(h, "192.0.2.9", 9098, ""))
      print(net.udp_send(h, "192.0.2.9", 9098, ("y"):rep(16385)))
      print(net.udp_recv(h, 0))
      print(net.udp_recv(h, 16385))
      print(net.udp_close(h))
      local hs = {}
      for i = 1, 7 do hs[i] = net.connect("example.test", 80) end
      print(hs[7])
      print(net.udp_open(0))                      -- the 8th socket still fits
      print(net.udp_open(0))                      -- the 9th is refused
      print(net.close(hs[3]))
      print(net.udp_open(0))                      -- the freed slot is reused
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 400000) == Status::Finished);
    const char* want[] = {"nil\tport must be an integer 0..65535 (0 = system-assigned)",
                          "nil\tport must be an integer 0..65535 (0 = system-assigned)",
                          "nil\tport must be an integer 0..65535 (0 = system-assigned)",
                          "1",
                          "nil\tsend failed (mock)",
                          "nil\tinvalid host name",
                          "nil\tport must be an integer 1..65535",
                          "nil\tdata must not be empty",
                          "nil\tdata too large (max 16384 bytes)",
                          "nil\tmax must be an integer 1..16384",
                          "nil\tmax must be an integer 1..16384",
                          "true",
                          "7",
                          "8",
                          "nil\ttoo many open sockets (max 8)",
                          "true",
                          "3"};
    const size_t N = sizeof(want) / sizeof(want[0]);
    CHECK(be.logs.size() == N);
    for (size_t i = 0; i < N && i < be.logs.size(); i++) {
      CHECK(be.logs[i] == want[i]);
      if (be.logs[i] != want[i]) printf("    udp2 #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
    }
    if (be.logs.size() != N || getenv("DUMP_LOGS"))
      for (size_t i = 0; i < be.logs.size(); i++) printf("    udp2 log[%zu] '%s'\n", i, be.logs[i].c_str());
    // the 8 first handles: h (UDP, handle 1) + 7 TCP = 8 open; the 9th open fails; after closing
    // one TCP, a UDP slot opens
    CHECK(be.txLog.empty());  // udpSendFail: the failed send must not reach the backend log; exactly one send
                              // reached the backend
  }
  {
    TEST("net.udp_open: the RAM floor applies to UDP too");
    MockBackend be;
    be.net = true;
    be.wifiUp = true;
    be.freeHeapVal = 10 * 1024;
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script = "print(net.udp_open(0))";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 100000) == Status::Finished);
    CHECK(be.logs.size() == 1 && be.logs[0] == "nil\tnot enough free RAM for a socket (free 10K, need 16K)");
  }
  {
    TEST("net.udp: permission and WiFi-down gates");
    {
      MockBackend be;  // no network permission
      be.net = false;
      be.wifiUp = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(net.udp_open(0))\nprint(net.udp_send(1, 'h', 1, 'x'))\nprint(net.udp_recv(1))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 3);
      for (size_t i = 0; i < be.logs.size(); i++) CHECK(be.logs[i].rfind("nil\tnetwork not permitted", 0) == 0);
    }
    {
      MockBackend be;  // WiFi down
      be.net = true;
      be.wifiUp = false;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(net.udp_open(0))\nprint(net.udp_send(1, 'h', 1, 'x'))\nprint(net.udp_recv(1))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 3);
      if (be.logs.size() == 3) {
        const char* nc = "nil\tnot connected (no network joined): call wifi.connect() first";
        CHECK(be.logs[0] == nc && be.logs[1] == nc);
        CHECK(be.logs[2] == "nil\tnot an open socket handle");
      }
    }
  }
  {
    TEST(
        "lazy namespaces: nothing is built until touched; every namespace resolves; gfx extras are eager; _G is "
        "protected");
    MockBackend be;
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      local names = { "time", "device", "led", "fs", "json", "wifi", "http", "net", "zip", "epub", "crypto", "coroutine", "utf8" }
      local lazy = 0
      for _, n in ipairs(names) do if rawget(_G, n) == nil then lazy = lazy + 1 end end
      print(lazy)
      print(rawget(_G, "gfx") ~= nil, rawget(_G, "input") ~= nil, rawget(_G, "app") ~= nil, rawget(_G, "system") ~= nil,
            rawget(_G, "print") ~= nil, rawget(_G, "require") ~= nil, rawget(_G, "load") ~= nil)
      print(type(gfx.save_bmp), type(gfx.image))
      local probes = { time = "now", device = "caps", led = "count", fs = "exists", json = "encode", wifi = "status", http = "request",
                       net = "info", zip = "list", epub = "meta", crypto = "sha1", coroutine = "wrap", utf8 = "char" }
      local bad = {}
      for n, f in pairs(probes) do
        local t = _G[n]
        if type(t) ~= "table" or type(t[f]) ~= "function" then bad[#bad + 1] = n end
      end
      print(#bad)
      print(type(http.get), type(wifi.connect), type(epub.meta), type(zip.read))
      local built = 0
      for _, n in ipairs(names) do if rawget(_G, n) ~= nil then built = built + 1 end end
      print(built)
      print(nosuchglobal)
      print(_G[1], _G[true])
      print(getmetatable(_G))
      print(pcall(setmetatable, _G, {}))
      print(rawget(_G, "nosuchglobal"))
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 400000) == Status::Finished);
    const char* want[] = {"13",
                          "true\ttrue\ttrue\ttrue\ttrue\ttrue\ttrue",
                          "function\tfunction",
                          "0",
                          "function\tfunction\tfunction\tfunction",
                          "13",
                          "nil",
                          "nil\tnil",
                          "protected",
                          "false\tcannot change a protected metatable",
                          "nil"};
    const size_t N = sizeof(want) / sizeof(want[0]);
    CHECK(be.logs.size() == N);
    for (size_t i = 0; i < N && i < be.logs.size(); i++) {
      CHECK(be.logs[i] == want[i]);
      if (be.logs[i] != want[i]) printf("    lazy #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
    }
  }
  {
    TEST(
        "lazy namespaces: the first touch costs heap, the second costs nothing; an out-of-memory first touch can be "
        "retried");
    MockBackend be;
    LuaVm vm;
    CHECK(vm.open(24 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      collectgarbage()
      local before = collectgarbage("count")
      local _ = json                                         -- first touch builds the namespace
      collectgarbage()
      local mid = collectgarbage("count")
      local _ = json                                         -- second touch is a plain table read
      collectgarbage()
      print(mid - before > 0.2, math.abs(collectgarbage("count") - mid) < 0.05)
      local junk = {}
      while collectgarbage("count") * 1024 < 24 * 1024 - 450 do junk[#junk + 1] = ("j"):rep(300) .. #junk end
      print(pcall(function() return crypto end))           -- no room to build it: a catchable error
      junk = nil; collectgarbage()
      print(type(crypto), type(crypto.sha1))                -- memory is back: the same access now works
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 400000) == Status::Finished);
    CHECK(be.logs.size() == 3);
    if (be.logs.size() == 3) {
      CHECK(be.logs[0] == "true\ttrue");
      CHECK(be.logs[1] == "false\tnot enough memory");
      CHECK(be.logs[2] == "table\tfunction");
      if (be.logs[1] != "false\tnot enough memory")
        printf("    lazy oom got [%s] [%s] [%s]\n", be.logs[0].c_str(), be.logs[1].c_str(), be.logs[2].c_str());
    }
  }
  {
    TEST(
        "API calls from inside coroutines (nested, wrapped, after a yield) find the context through the inherited "
        "extra space");
    MockBackend be;
    be.net = true;
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      local co = coroutine.wrap(function()
        local w = gfx.size()
        coroutine.yield(type(w), crypto.hex("A"))
        local inner = coroutine.wrap(function() return system.millis() >= 0, fs.exists("data:nope.txt"), json.encode({1}) end)
        return inner()
      end)
      print(co())
      print(co())
      local t = coroutine.create(function() return gfx.size() end)
      print(coroutine.resume(t))
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 200000) == Status::Finished);
    CHECK(be.logs.size() == 3);
    if (be.logs.size() == 3) {
      CHECK(be.logs[0] == "number\t41");
      CHECK(be.logs[1] == "true\tfalse\t[1]");
      CHECK(be.logs[2] == "true\t800\t480");
    }
  }
  {
    TEST(
        "net.read: the heap floor is relaxed for the one allocation that drains the stack and ALWAYS restored (even on "
        "out-of-memory)");
    MockBackend be;
    be.net = true;
    be.wifiUp = true;
    be.sockReply["big.test:80"] = std::string(8192, 'z');
    LuaVm vm;
    CHECK(vm.open(40 * 1024));  // small Lua budget: the junk string below leaves no room for a 4 KB read
    registerApi(vm, be);
    const char* script = R"LUA(
      local h = net.connect("big.test", 80)
      print(#net.read(h, 100))                                -- a normal read
      print(net.read(h, 100) ~= nil, #net.read(h, 100))       -- two more
      local junk = {}                                         -- eat the budget, leaving ~3 KB: a 4 KB read cannot fit
      while collectgarbage("count") * 1024 < 40 * 1024 - 3500 do junk[#junk + 1] = ("j"):rep(400) .. #junk end
      local ok, e = pcall(net.read, h, 4096)                  -- cannot allocate: raises, floor must still be restored
      print(ok, tostring(e):sub(1, 17))
      junk = nil; collectgarbage()
      print(#net.read(h, 100))                                -- and reading works again afterwards
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 400000) == Status::Finished);
    CHECK(be.logs.size() == 4);
    if (be.logs.size() == 4) {
      CHECK(be.logs[0] == "100" && be.logs[1] == "true\t100");
      CHECK(be.logs[2] == "false\tnot enough memory");
      CHECK(be.logs[3] == "100");
    }
    CHECK(be.relaxOn == 5 &&
          be.relaxOff == 5);  // 3 + the failing one + 1 after: every relax(true) has its relax(false)
  }
  {
    TEST(
        "net.read: the peer vanishing between available() and the copy yields nil, closed (two values through the "
        "protected call)");
    MockBackend be;
    be.net = true;
    be.wifiUp = true;
    be.sockReply["example.test:80"] = "abc";
    be.netReadFail = true;
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script =
        "local h = net.connect('example.test', 80)\nprint(net.read(h))\nprint(select('#', net.read(h)))";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 100000) == Status::Finished);
    CHECK(be.logs.size() == 2 && be.logs[0] == "nil\tclosed" && be.logs[1] == "2");
    CHECK(be.relaxOn == 2 && be.relaxOff == 2);
  }
  {
    TEST("net: argument validation, table exhaustion, errors: nothing invalid reaches the backend");
    MockBackend be;
    be.net = true;
    be.wifiUp = true;
    be.sockRefused.insert("closed.test:81");
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      print(net.connect("", 80))
      print(net.connect("bad host", 80))
      print(net.connect(("a"):rep(254), 80))
      print(net.connect("example.test", 0))
      print(net.connect("example.test", 65536))
      print(net.connect("example.test", 80.5))
      print(net.connect("example.test", 80, {timeout_ms = 99}))
      print(net.connect("example.test", 80, {timeout_ms = 15001}))
      print(net.connect("example.test", 80, {timeout_ms = 1.5}))
      print(net.connect("example.test", 80, {tls = true}))
      print(net.connect("example.test", 80, {insecure = true}))
      print((pcall(net.connect, "example.test", 80, 5)))
      print((pcall(net.connect)))
      print(net.connect("closed.test", 81))
      local hs = {}
      for i = 1, 8 do hs[i] = net.connect("example.test", 80) end
      print(hs[1], hs[4], hs[8])
      print(net.connect("example.test", 80))
      print(net.close(hs[2]))
      print(net.connect("example.test", 80))
      print(net.read(hs[1], 0))
      print(net.read(hs[1], 4097))
      print(net.read(hs[1], 1.5))
      print(net.write(hs[1], ("x"):rep(16385)))
      print(net.read(0))
      print(net.read(9))
      print(net.read(1.5))
      print(net.write(10, "x"))
      print(net.available(9))
      print((pcall(net.read)))
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 400000) == Status::Finished);
    const char* want[] = {
        "nil\tinvalid host name",
        "nil\tinvalid host name",
        "nil\tinvalid host name",
        "nil\tport must be an integer 1..65535",
        "nil\tport must be an integer 1..65535",
        "nil\tport must be an integer 1..65535",
        "nil\ttimeout_ms must be an integer 100..15000",
        "nil\ttimeout_ms must be an integer 100..15000",
        "nil\ttimeout_ms must be an integer 100..15000",
        "nil\ttls needs ca=\"<PEM file>\" (verified) or insecure=true (encrypted, server NOT authenticated)",
        "nil\tca and insecure only apply with tls=true",
        "false",
        "false",
        "nil\tconnection refused (mock)",
        "1\t4\t8",
        "nil\ttoo many open sockets (max 8)",
        "true",
        "2",
        "nil\tmax must be an integer 1..4096",
        "nil\tmax must be an integer 1..4096",
        "nil\tmax must be an integer 1..4096",
        "nil\tdata too large (max 16384 per call; loop on the returned count)",
        "nil\tnot an open socket handle",
        "nil\tnot an open socket handle",
        "nil\tnot an open socket handle",
        "nil\tnot an open socket handle",
        "nil\tnot an open socket handle",
        "false"};
    const size_t N = sizeof(want) / sizeof(want[0]);
    CHECK(be.logs.size() == N);
    for (size_t i = 0; i < N && i < be.logs.size(); i++) {
      CHECK(be.logs[i] == want[i]);
      if (be.logs[i] != want[i]) printf("    net #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
    }
    CHECK(be.connectCalls == 10);  // refused one + 8 + the reuse: every invalid call stopped in the binding
    CHECK(be.txLog.empty());
    if (getenv("DUMP_LOGS"))
      for (size_t i = 0; i < be.logs.size(); i++) printf("    net log[%zu] '%s'\n", i, be.logs[i].c_str());
  }
  {
    TEST("net: gates: permission, WiFi up, free RAM; resolve (literal passthrough, DNS) and local()");
    {
      MockBackend be;  // no "network" permission at all
      be.net = false;
      be.wifiUp = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script =
          "print(net.info())\nprint(net.resolve('example.test'))\nprint(net.connect('example.test', "
          "80))\nprint(net.read(1))\nprint(net.write(1, 'x'))\nprint(net.close(1))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 6);
      for (size_t i = 0; i < be.logs.size(); i++) CHECK(be.logs[i].rfind("nil\tnetwork not permitted", 0) == 0);
      CHECK(be.connectCalls == 0 && be.dnsAsked.empty());
    }
    {
      MockBackend be;  // permitted but WiFi is down
      be.net = true;
      be.wifiUp = false;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script =
          "print(net.info())\nprint(net.resolve('example.test'))\nprint(net.connect('example.test', "
          "80))\nprint(net.read(1))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 4);
      if (be.logs.size() == 4) {
        const char* nc = "nil\tnot connected (no network joined): call wifi.connect() first";
        CHECK(be.logs[0] == nc && be.logs[1] == nc && be.logs[2] == nc);
        CHECK(be.logs[3] == "nil\tnot an open socket handle");  // handle ops need no WiFi check
      }
      CHECK(be.connectCalls == 0 && be.dnsAsked.empty());
    }
    {
      MockBackend be;  // WiFi up but the heap is nearly gone
      be.net = true;
      be.wifiUp = true;
      be.freeHeapVal = 10 * 1024;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(net.connect('example.test', 80))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1 && be.logs[0] == "nil\tnot enough free RAM for a socket (free 10K, need 16K)");
      CHECK(be.connectCalls == 0);
    }
    {
      MockBackend be;
      be.net = true;
      be.wifiUp = true;
      be.dnsMap["example.test"] = "93.184.216.34";
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(net.resolve("example.test"))
        print(net.resolve("10.0.0.7"))
        print(net.resolve("999.1.1.1"))
        print(net.resolve("1.2.3"))
        print(net.resolve("nope.test"))
        print(net.resolve("bad host"))
        print(net.resolve(""))
        local l = net.info()
        print(l.ip, l.mask, l.gateway, l.dns)
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      const char* want[] = {"93.184.216.34",
                            "10.0.0.7",
                            "nil\tcannot resolve host (mock)",
                            "nil\tcannot resolve host (mock)",
                            "nil\tcannot resolve host (mock)",
                            "nil\tinvalid host name",
                            "nil\tinvalid host name",
                            "192.168.1.50\t255.255.255.0\t192.168.1.1\t1.1.1.1"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      CHECK(be.logs.size() == N);
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    net #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
      const std::vector<std::string> asked = {"example.test", "999.1.1.1", "1.2.3", "nope.test"};
      CHECK(be.dnsAsked == asked);  // the literal 10.0.0.7 never went to DNS
    }
  }
  {
    TEST("require: a big module loads in a tight heap (the unstripped copy is dropped before the stripped one loads)");
    std::string mod = "local M = {}\n";
    for (int i = 0; i < 200; i++) {
      char line[160];
      snprintf(line, sizeof(line),
               "function M.f%d(a, b)\n  local t = {a, b, %d}\n  return t[1] * t[2] + t[3] + #tostring(a)\nend\n", i, i);
      mod += line;
    }
    mod += "return M\n";
    size_t peakOk = 0;
    {
      MockBackend be;
      be.files["/plugins/test/big.lua"] = mod;
      LuaVm vm;
      vm.open(1024 * 1024);
      registerApi(vm, be);
      const char* sc = "local m = require('big'); print(m.f7(3, 4), collectgarbage('count') > 0)";
      CHECK(vm.load("t", sc, strlen(sc)));
      Status st0 = run(vm, be);
      if (getenv("DUMP_LOGS")) printf("   st0=%d err=%s\n", (int)st0, vm.error().c_str());
      CHECK(st0 == Status::Finished && be.logs.size() == 1 && be.logs[0] == "20\ttrue");
      peakOk = vm.peakBytes();
      if (getenv("DUMP_LOGS")) printf("   module %zu B, peak with a huge budget %zu B\n", mod.size(), peakOk);
    }
    // measured on the host: streaming + drop-the-full-copy peaks at ~111 KB; without the
    // streaming ~128 KB; the original load order (source buffer + full + stripped copies
    // together) ~181 KB
    CHECK(peakOk > mod.size() && peakOk < 120000);
    MockBackend be;
    be.files["/plugins/test/big.lua"] = mod;
    LuaVm vm;
    vm.open(120000);  // below both older variants: only streaming + early drop fits
    registerApi(vm, be);
    const char* sc = "local ok, m = pcall(require, 'big'); print(ok, ok and m.f7(3, 4))";
    CHECK(vm.load("t", sc, strlen(sc)));
    CHECK(run(vm, be) == Status::Finished);
    if (getenv("DUMP_LOGS"))
      for (auto& l : be.logs) printf("   tight: %s\n", l.c_str());
    CHECK(be.logs.size() == 1 && be.logs[0] == "true\t20");
  }
  {
    TEST("require: a module that cannot be read (card error) is a clean error; modules over 1 KB stream correctly");
    MockBackend be;
    std::string big = "local t = {}\n";
    for (int i = 0; i < 300; i++) {
      char l[64];
      snprintf(l, sizeof(l), "t[%d] = 'line number %d'\n", i, i);
      big += l;
    }
    big += "return t\n";  // ~8 KB: several 1 KB pieces, with a token split across a piece boundary somewhere
    be.files["/plugins/test/broken.lua"] = "return 1";
    be.files["/plugins/test/long.lua"] = big;
    be.failReadPath = "/plugins/test/broken.lua";
    LuaVm vm;
    CHECK(vm.open(256 * 1024));
    registerApi(vm, be);
    const char* sc =
        "local ok, e = pcall(require, 'broken'); print(ok, tostring(e):find('module read error', 1, true) ~= nil)\n"
        "local t = require('long'); print(#t, t[0], t[299])";
    CHECK(vm.load("t", sc, strlen(sc)));
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs.size() == 2 && be.logs[0] == "false\ttrue" && be.logs[1] == "299\tline number 0\tline number 299");
  }
  {
    TEST("require: errors - missing, bad names, syntax error, runtime error, circular, bytecode");
    LuaVm vm;
    MockBackend be;
    be.files["/plugins/test/syn.lua"] = "return ((";
    be.files["/plugins/test/boom.lua"] = "error('kaboom')";
    be.files["/plugins/test/ca.lua"] = "return require('cb')";
    be.files["/plugins/test/cb.lua"] = "return require('ca')";
    be.files["/plugins/test/bc.lua"] = std::string("\x1bLua\x54\x00", 6);
    be.files["/secret.lua"] = "return 'ESCAPED'";
    setup(vm, be,
          "local function try(n) local ok, e = pcall(require, n) print(n, ok, tostring(e):gsub('\\n.*', '')) end\n"
          "try('missing') try('../secret') try('a/b') try('') try('syn') try('boom') try('ca') try('bc') try(42)");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs.size() == 9);
    CHECK(be.logs[0].find("missing\tfalse\tmodule 'missing' not found:") == 0);
    CHECK(be.logs[1].find("../secret\tfalse\tbad module name") == 0);
    CHECK(be.logs[2].find("a/b\tfalse\tbad module name") == 0);
    CHECK(be.logs[3].find("\tfalse\tbad module name") != std::string::npos);
    CHECK(be.logs[4].find("syn\tfalse") == 0 && be.logs[4].find("syn.lua") != std::string::npos);
    CHECK(be.logs[5].find("boom\tfalse") == 0 && be.logs[5].find("kaboom") != std::string::npos);
    CHECK(be.logs[6].find("circular require") != std::string::npos);
    CHECK(be.logs[7].find("bc\tfalse") == 0);
    CHECK(be.logs[8].find("must be a string") != std::string::npos);
    for (auto& l : be.logs) CHECK(l.find("ESCAPED") == std::string::npos);
  }
  {
    TEST("require: module top-level may yield (input.wait inside a module)");
    LuaVm vm;
    MockBackend be;
    be.files["/plugins/test/waiter.lua"] = "local e = input.wait(10) return {got = e}";
    be.events = {};
    setup(vm, be, "local m = require('waiter') print(tostring(m.got))");
    be.events.push_back("confirm");
    // run(): first resume hits input.wait with an event queued -> fast path. Use an empty queue
    // instead:
    be.events.clear();
    CHECK(vm.resume() == Status::Waiting);  // yielded from inside the module's top level
    CHECK(vm.timeoutMs() == 10);
    CHECK(vm.resume("left") == Status::Finished);
    CHECK(be.logs[0] == "left");
  }

  // ======================= Phase 2: json =======================
  {
    TEST("json: decode values, types, nesting, unicode");
    LuaVm vm;
    MockBackend be;
    setup(
        vm, be,
        "local t = "
        "json.decode('{\"a\":[1,2.5,-3,1e2,true,false,null],\"s\":\"x\\\\ny\\\\u00e9\\\\ud83d\\\\ude00\",\"o\":{}}')\n"
        "print(t.a[1], math.type(t.a[1]), t.a[2], math.type(t.a[2]), t.a[3], t.a[4], math.type(t.a[4]), t.a[5], "
        "t.a[6], t.a[7] == json.null)\n"
        "print(t.s == 'x\\ny\\xc3\\xa9\\xf0\\x9f\\x98\\x80', next(t.o) == nil, #t.a)\n"
        "print(math.type(json.decode('2147483647')), math.type(json.decode('2147483648')), json.decode(' 42 '), "
        "json.decode('\"\"') == '')");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs[0] == "1\tinteger\t2.5\tfloat\t-3\t100.0\tfloat\ttrue\tfalse\ttrue");
    CHECK(be.logs[1] == "true\ttrue\t7");
    CHECK(be.logs[2] == "integer\tfloat\t42\ttrue");
  }
  {
    TEST("json: decode errors return nil,msg (never throw)");
    LuaVm vm;
    MockBackend be;
    setup(vm, be,
          "local cases = {'', '{', '[1,2', '{\"a\"}', '{a:1}', '[1,]', '01', '1.', '\"abc', '\"\\\\x\"', "
          "'\"\\\\ud800\"', "
          "'tru', '[1] x', '\"a\\nb\"', '{\"a\":1,}', string.rep('[', 100)}\n"
          "local bad = 0\n"
          "for i, c in ipairs(cases) do local v, e = json.decode(c) if v == nil and type(e) == 'string' then bad = bad "
          "+ 1 else print('ACCEPTED', i, c) end end\n"
          "print(bad, #cases)\n"
          "print(json.decode('[1,}'))");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs.size() == 2);
    CHECK(be.logs[0] == "16\t16");
    CHECK(be.logs[1].find("nil\t") == 0 && be.logs[1].find("at byte") != std::string::npos);
  }
  {
    TEST("json: encode scalars, escapes, arrays, objects, null; roundtrip");
    LuaVm vm;
    MockBackend be;
    setup(vm, be,
          "print(json.encode(nil), json.encode(true), json.encode(42), json.encode(1.5), "
          "json.encode('a\"b\\\\c\\n\\1'))\n"
          "print(json.encode({1, 'x', {2}, json.null}), json.encode({}), json.encode({k = {1, 2}}))\n"
          "local src = {name = 'Samson', list = {1, 2, 3}, nested = {ok = true, pi = 3.25}, s = 'caf\\xc3\\xa9'}\n"
          "local back = json.decode(json.encode(src))\n"
          "print(back.name, #back.list, back.nested.ok, back.nested.pi, back.s == src.s)");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs[0] == "null\ttrue\t42\t1.5\t\"a\\\"b\\\\c\\n\\u0001\"");
    CHECK(be.logs[1] == "[1,\"x\",[2],null]\t{}\t{\"k\":[1,2]}");
    CHECK(be.logs[2] == "Samson\t3\ttrue\t3.25\ttrue");
  }
  {
    TEST("json: encode refuses functions, cycles, sparse arrays, non-string keys, NaN");
    LuaVm vm;
    MockBackend be;
    setup(vm, be,
          "local cyc = {} cyc.self = cyc\n"
          "print(json.encode(print))\n"
          "print(json.encode(cyc))\n"
          "print(json.encode({1, 2, nil, 4}))\n"
          "print(json.encode({[1.5] = 'x'}))\n"
          "print(json.encode(0/0))\n"
          "print(json.encode({f = function() end}))");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs.size() == 6);
    for (auto& l : be.logs) CHECK(l.find("nil\t") == 0);
  }
  {
    TEST("json: big documents stay within budget and fail cleanly beyond it");
    LuaVm vm;
    MockBackend be;
    setup(vm, be,
          "local t = {} for i = 1, 300 do t[i] = {id = i, name = 'item' .. i} end\n"
          "local s = json.encode(t) local back = json.decode(s)\n"
          "print(#s > 5000, #back, back[300].name)\n"
          "local ok, e = pcall(function() local big = {} for i = 1, 100000 do big[i] = {i} end return json.encode(big) "
          "end)\n"
          "print(ok, tostring(e):sub(1, 17))",
          512 * 1024);  // host pointers are 64-bit: memory numbers here are ~1.6x what the 32-bit C3 uses
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs[0] == "true\t300\titem300");
    CHECK(be.logs[1] == "false\tnot enough memory");
    vm.close();
    CHECK(vm.usedBytes() == 0);
  }
  {
    TEST("net.connect: backend errors pass through verbatim (Back-cancel reaches Lua as nil, \"cancelled\")");
    MockBackend be;
    be.net = true;
    be.wifiUp = true;
    be.connectFailMsg = "cancelled";
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script = "local h, e = net.connect('blackhole.test', 80, {timeout_ms = 15000}); print(h, e)";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 100000) == Status::Finished);
    CHECK(be.logs.size() == 1);
    CHECK(be.logs[0] == "nil\tcancelled");
    CHECK(be.connectCalls == 1 && be.connectOpts[0] == 15000);
    CHECK(be.socks[0].used == false);  // no slot leaked on the failure path
  }
  {
    TEST("net.listen: basic listen, close, permission and WiFi gates");
    {
      MockBackend be;
      be.net = true;
      be.wifiUp = true;
      be.listenPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(net.listen(8080))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1);
      CHECK(be.logs[0] == "1");
      CHECK(be.serverPort == 8080);
    }
    {
      MockBackend be;  // no listen permission
      be.net = true;
      be.wifiUp = true;
      be.listenPermitted = false;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(net.listen(8080))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1);
      CHECK(be.logs[0].rfind("nil\tlisten not permitted", 0) == 0);
    }
    {
      MockBackend be;  // WiFi down
      be.net = true;
      be.wifiUp = false;
      be.listenPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(net.listen(8080))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1);
      CHECK(be.logs[0].rfind("nil\tnot connected", 0) == 0);
    }
    {
      MockBackend be;  // port validation
      be.net = true;
      be.wifiUp = true;
      be.listenPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(net.listen(0))\nprint(net.listen(65536))\nprint(net.listen(-1))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 3);
      for (size_t i = 0; i < 3; i++) CHECK(be.logs[i].rfind("nil\t", 0) == 0);
    }
    {
      MockBackend be;  // slot exhaustion: 8 connects leave no room for listen
      be.net = true;
      be.wifiUp = true;
      be.listenPermitted = true;
      be.dnsMap["h.test"] = "1.2.3.4";
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script =
          "local hs = {} for i = 1, 8 do hs[i] = net.connect('h.test', 80) end\nprint(net.listen(8080))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1);
      CHECK(be.logs[0].rfind("nil\ttoo many", 0) == 0);
    }
    {
      MockBackend be;  // backend error propagates
      be.net = true;
      be.wifiUp = true;
      be.listenPermitted = true;
      be.listenOk = false;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(net.listen(8080))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1);
      CHECK(be.logs[0] == "nil\tlisten failed (mock)");
    }
    {
      MockBackend be;  // listen declared but NOT approved on the permission screen -> refused
      be.net = true;
      be.wifiUp = true;
      be.listenPermitted = true;
      be.listenApproved = false;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(net.listen(8080))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1);
      CHECK(be.logs[0].rfind("nil\tlisten not permitted", 0) == 0);
      CHECK(be.serverPort == 0);  // nothing reached the backend
    }
    {
      MockBackend be;  // listen declared+approved but the base network permission is missing -> NET_DENIED first
      be.net = false;
      be.wifiUp = true;
      be.listenPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(net.listen(8080))\nprint(net.accept(1))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 2);
      CHECK(be.logs[0].rfind("nil\tnetwork not permitted", 0) == 0);
      CHECK(be.logs[1].rfind("nil\tnot an open socket handle", 0) == 0);  // accept never got a server to open
    }
  }
  {
    TEST("net.accept: accept a queued client, read/write, close");
    MockBackend be;
    be.net = true;
    be.wifiUp = true;
    be.listenPermitted = true;
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    // First run listen to create the server slot
    const char* setupSc = "local s = net.listen(9090); print(s)";
    CHECK(vm.load("t", setupSc, strlen(setupSc)));
    CHECK(run(vm, be, 100000) == Status::Finished);
    CHECK(be.logs.size() == 1 && be.logs[0] == "1");
    // Queue a client on server slot 0 with some data
    MockBackend::MockSock client;
    client.used = true;
    client.kind = 1;
    client.rx = "HELLO from mock\n";
    client.host = "192.168.1.100";
    client.port = 54321;
    be.acceptQueue[0].push_back(client);
    // Now accept it in a fresh VM
    be.logs.clear();
    LuaVm vm2;
    CHECK(vm2.open(128 * 1024));
    registerApi(vm2, be);
    // The server is still open in the mock's slots (slot 0, kind 3)
    // net.accept should find the queued client
    const char* sc =
        "local cl = net.accept(1); print(cl); print(net.read(cl, 20)); print(net.write(cl, 'ok')); "
        "print(net.close(cl))";
    CHECK(vm2.load("t", sc, strlen(sc)));
    CHECK(run(vm2, be, 100000) == Status::Finished);
    CHECK(be.logs.size() == 4);
    if (be.logs.size() == 4) {
      CHECK(be.logs[0] == "2");  // client handle (next free slot)
      CHECK(be.logs[1] == "HELLO from mock\n");
      CHECK(be.logs[2] == "2");     // wrote 2 bytes
      CHECK(be.logs[3] == "true");  // close succeeded
      CHECK(be.acceptCount == 1);
    }
  }
  {
    TEST("net.accept: permission, server handle validation, no pending client returns nil");
    {
      MockBackend be;  // no listen permission
      be.net = true;
      be.wifiUp = true;
      be.listenPermitted = false;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* sc = "print(net.accept(1))";
      CHECK(vm.load("t", sc, strlen(sc)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1);
      CHECK(be.logs[0].rfind("nil\tnot an open socket handle", 0) == 0);
    }
    {
      MockBackend be;  // server with nothing waiting
      be.net = true;
      be.wifiUp = true;
      be.listenPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      // Create the server first
      const char* s1 = "local s = net.listen(9090); print(s)";
      CHECK(vm.load("t", s1, strlen(s1)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs[0] == "1");
      // Now accept - nothing waiting -> nil
      be.logs.clear();
      LuaVm vm2;
      CHECK(vm2.open(128 * 1024));
      registerApi(vm2, be);
      const char* sc = "print(net.accept(1))";
      CHECK(vm2.load("t", sc, strlen(sc)));
      CHECK(run(vm2, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1);
      CHECK(be.logs[0] == "nil");
    }
    {
      MockBackend be;  // listen permission check on accept (server exists but no listen permission)
      be.net = true;
      be.wifiUp = true;
      be.listenPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      CHECK(vm.load("t", "local s = net.listen(9090); print(s)", strlen("local s = net.listen(9090); print(s)")));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs[0] == "1");
      be.logs.clear();
      be.listenPermitted = false;  // revoke permission before accept
      LuaVm vm2;
      CHECK(vm2.open(128 * 1024));
      registerApi(vm2, be);
      const char* sc2 = "print(net.accept(1))";
      CHECK(vm2.load("t", sc2, strlen(sc2)));
      CHECK(run(vm2, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1);
      CHECK(be.logs[0] == "nil\tlisten not permitted: add \"permissions\": [\"listen\"] to this app's manifest.json");
    }
    {
      MockBackend be;  // accept with a live server but the base network permission revoked -> NET_DENIED
      be.net = true;
      be.wifiUp = true;
      be.listenPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      CHECK(vm.load("t", "local s = net.listen(9090); print(s)", strlen("local s = net.listen(9090); print(s)")));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs[0] == "1");
      be.logs.clear();
      be.net = false;  // revoke the base network permission; the listen approval stays
      LuaVm vm2;
      CHECK(vm2.open(128 * 1024));
      registerApi(vm2, be);
      CHECK(vm2.load("t", "print(net.accept(1))", strlen("print(net.accept(1))")));
      CHECK(run(vm2, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1);
      CHECK(be.logs[0].rfind("nil\tnetwork not permitted", 0) == 0);
      CHECK(be.acceptCount == 0);  // nothing was accepted
    }
    {
      MockBackend be;  // accept on a TCP handle (not a server)
      be.net = true;
      be.wifiUp = true;
      be.listenPermitted = true;
      be.dnsMap["h.test"] = "1.2.3.4";
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* sc = "local c = net.connect('h.test', 80); print(net.accept(c))";
      CHECK(vm.load("t", sc, strlen(sc)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1);
      CHECK(be.logs[0] == "nil\tnot a server socket");
    }
    {
      MockBackend be;  // accept backend error
      be.net = true;
      be.wifiUp = true;
      be.listenPermitted = true;
      be.acceptOk = false;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      CHECK(vm.load("t", "local s = net.listen(9090); print(s)", strlen("local s = net.listen(9090); print(s)")));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs[0] == "1");
      be.logs.clear();
      LuaVm vm2;
      CHECK(vm2.open(128 * 1024));
      registerApi(vm2, be);
      CHECK(vm2.load("t", "print(net.accept(1))", strlen("print(net.accept(1))")));
      CHECK(run(vm2, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1);
      CHECK(be.logs[0] == "nil\taccept failed");
    }
  }
  {
    TEST("net.mdns_query: basic query, empty results, permission and WiFi gates");
    {
      MockBackend be;
      be.net = true;
      be.wifiUp = true;
      be.mdnsResults = {
          {"printer", "192.168.1.100", 631, "Office Printer"},
          {"nas", "192.168.1.50", 5000, "My NAS"},
      };
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        local r = net.mdns_query("_ipp", "tcp")
        print(#r)
        print(r[1].hostname, r[1].ip, r[1].port, r[1].instance_name)
        print(r[2].hostname, r[2].ip, r[2].port, r[2].instance_name)
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 3);
      CHECK(be.logs[0] == "2");
      CHECK(be.logs[1] == "printer\t192.168.1.100\t631\tOffice Printer");
      CHECK(be.logs[2] == "nas\t192.168.1.50\t5000\tMy NAS");
      CHECK(be.mdnsQueryCalled);
      CHECK(be.mdnsLastQuery.find("ipp::tcp") != std::string::npos);
    }
    {
      MockBackend be;  // empty results
      be.net = true;
      be.wifiUp = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(#net.mdns_query('_http', 'tcp'))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1);
      CHECK(be.logs[0] == "0");
    }
    {
      MockBackend be;  // no network permission
      be.net = false;
      be.wifiUp = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(net.mdns_query('_http', 'tcp'))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1);
      CHECK(be.logs[0].rfind("nil\tnetwork not permitted", 0) == 0);
    }
    {
      MockBackend be;  // WiFi down
      be.net = true;
      be.wifiUp = false;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(net.mdns_query('_http', 'tcp'))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1);
      CHECK(be.logs[0].rfind("nil\tnot connected", 0) == 0);
    }
    {
      MockBackend be;  // argument validation
      be.net = true;
      be.wifiUp = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script =
          "print(net.mdns_query('', 'tcp'))\nprint(net.mdns_query('http', ''))\nprint(net.mdns_query('http', 'foo'))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 3);
      for (size_t i = 0; i < 3; i++) CHECK(be.logs[i].rfind("nil\t", 0) == 0);
    }
    {
      MockBackend be;  // service type auto-prepends _
      be.net = true;
      be.wifiUp = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(#net.mdns_query('http', 'tcp'))\nprint(#net.mdns_query('_http', 'tcp'))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 2);
      // The mdnsLastQuery should be the same in both cases: _http._tcp
      CHECK(be.mdnsLastQuery == "http::tcp");
    }
    {
      MockBackend be;  // mDNS query failure
      be.net = true;
      be.wifiUp = true;
      be.mdnsQueryFailCode = -1;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "local r, err = net.mdns_query('_http', 'tcp'); print(r, err)";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1);
      CHECK(be.logs[0].find("nil\t") == 0);  // nil + error message
    }
  }
  {
    TEST("audio: play/stop/volume/playing through the mock; permission and approval gates; arg validation");
    {
      MockBackend be;  // happy path
      be.files["/plugins/test/ding.wav"] = std::string(1000, 'R');
      be.audioPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(audio.play("app:ding.wav"))
        print(audio.play("app:ding.wav", true))
        print(audio.playing())
        print(audio.volume(40))
        print(audio.volume(0))
        print(audio.stop())
        print(audio.playing())
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      const char* want[] = {"true", "true", "true", "true", "true", "true", "false"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      CHECK(be.logs.size() == N);
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    audio #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
      CHECK(be.audioPlays.size() == 2);
      if (be.audioPlays.size() == 2) {
        CHECK(be.audioPlays[0].path == "/plugins/test/ding.wav" && !be.audioPlays[0].loop);
        CHECK(be.audioPlays[1].loop);
      }
      CHECK(be.audioStops == 1 && be.audioVolumes == 2 && be.audioVolumeLast == 0);
    }
    {
      MockBackend be;  // permission not declared
      be.files["/plugins/test/ding.wav"] = std::string(1000, 'R');
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script =
          "print(audio.play('app:ding.wav'))\nprint(audio.stop())\nprint(audio.volume(50))\nprint(audio.playing())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 4);
      for (size_t i = 0; i < be.logs.size(); i++) CHECK(be.logs[i].rfind("nil\taudio not permitted", 0) == 0);
      CHECK(be.audioPlays.empty() && be.audioStops == 0 && be.audioVolumes == 0);
    }
    {
      MockBackend be;  // declared but NOT approved
      be.files["/plugins/test/ding.wav"] = std::string(1000, 'R');
      be.audioPermitted = true;
      be.audioApproved = false;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(audio.play('app:ding.wav'))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1 && be.logs[0].rfind("nil\taudio not permitted", 0) == 0);
      CHECK(be.audioPlays.empty());
    }
    {
      MockBackend be;  // backend failure + argument validation: nothing invalid reaches the backend
      be.files["/plugins/test/ding.wav"] = std::string(1000, 'R');
      be.audioPermitted = true;
      be.audioOk = false;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      be.files["/plugins/test/big.wav"] = std::string(4 * 1024 * 1024 + 1, 'R');  // one byte over the cap
      const char* script = R"LUA(
        print(audio.play("app:ding.wav"))
        print(audio.play("app:big.wav"))
        print(audio.play("app:song.mp3"))
        print(audio.play("app:tiny.wav"))
        print(audio.play("app:nope.wav"))
        print(audio.play("data:dir"))
        print(audio.volume(101))
        print(audio.volume(-1))
        print(audio.volume(50.5))
      )LUA";
      be.files["/plugins/test/tiny.wav"] = std::string(10, 'R');
      be.files["/plugins/test/song.mp3"] = std::string(1000, 'R');
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      const char* want[] = {"nil\tcannot play (mock codec error)",
                            "nil\twav is over 4 MB (the SD card read during playback would stutter)",
                            "nil\tnot a .wav file",
                            "nil\tfile is too small to be a WAV",
                            "nil\tno such file",
                            "nil\tnot a .wav file",  // the extension check runs before the size/type checks (data:dir)
                            "nil\tvolume must be an integer 0..100",
                            "nil\tvolume must be an integer 0..100",
                            "nil\tvolume must be an integer 0..100"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      CHECK(be.logs.size() == N);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    audio2 log[%zu] '%s'\n", i, be.logs[i].c_str());
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    audio2 #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
      CHECK(be.audioPlays.empty());  // the failing play never recorded (mock refuses first)
    }
    {
      MockBackend be;            // the mock is permissive about .wav so the BINDING extension check is what is tested:
      be.audioPermitted = true;  // a non-.wav path must be refused BEFORE the backend (mock accepts anything)
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(audio.play('app:notwav'))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1 && be.logs[0] == "nil\tnot a .wav file");
      CHECK(be.audioPlays.empty());
    }
  }
  {
    TEST("mic: record/level through the mock; permission+approval gates; write sandbox; argument validation");
    {
      MockBackend be;  // happy path
      be.micPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(mic.record("data:rec/a.wav", 2))
        print(mic.level())
        print(mic.level(250))
        print(#fs.read("data:rec/a.wav", 0, 8))
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 4);
      if (be.logs.size() == 4) {
        CHECK(be.logs[0] == "64044" && be.logs[1] == "1234" && be.logs[2] == "1234" && be.logs[3] == "8");
      }
      CHECK(be.micRecords.size() == 1 && be.micRecords[0].seconds == 2);
      CHECK(be.micRecords.size() == 1 && be.micRecords[0].path == "/.crosslua/data/test/rec/a.wav");
      CHECK(be.micLevels.size() == 2 && be.micLevels[0] == 100 && be.micLevels[1] == 250);
    }
    {
      MockBackend be;  // permission not declared
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(mic.record('data:a.wav', 1))\nprint(mic.level())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 2);
      for (size_t i = 0; i < be.logs.size(); i++) CHECK(be.logs[i].rfind("nil\tmicrophone not permitted", 0) == 0);
      CHECK(be.micRecords.empty() && be.micLevels.empty());
    }
    {
      MockBackend be;  // declared, not approved
      be.micPermitted = true;
      be.micApproved = false;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(mic.record('data:a.wav', 1))\nprint(mic.level())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 2);
      for (size_t i = 0; i < be.logs.size(); i++) CHECK(be.logs[i].rfind("nil\tmicrophone not permitted", 0) == 0);
      CHECK(be.micRecords.empty() && be.micLevels.empty());
    }
    {
      MockBackend be;  // argument validation + the write sandbox: nothing invalid reaches the backend
      be.micPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(mic.record("data:a.mp3", 1))
        print(mic.record("data:a.wav", 0))
        print(mic.record("data:a.wav", 31))
        print(mic.record("data:a.wav", 1.5))
        print(mic.record("app:a.wav", 1))
        print(mic.record("sd:rec.wav", 1))
        print(mic.level(9))
        print(mic.level(2001))
        print(mic.level(50.5))
        print(fs.mkdir("data:adir.wav"))
        print(mic.record("data:adir.wav", 1))
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      const char* want[] = {"nil\tpath must end in .wav",
                            "nil\tseconds must be an integer 1..30",
                            "nil\tseconds must be an integer 1..30",
                            "nil\tseconds must be an integer 1..30",
                            "nil\tread-only location (write to 'data:...')",
                            "nil\tread-only location (write to 'data:...')",
                            "nil\tms must be an integer 10..2000",
                            "nil\tms must be an integer 10..2000",
                            "nil\tms must be an integer 10..2000",
                            "true",
                            "nil\tis a directory"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      CHECK(be.logs.size() == N);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    mic log[%zu] '%s'\n", i, be.logs[i].c_str());
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    mic #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
      CHECK(be.micRecords.empty() && be.micLevels.empty());
    }
    {
      MockBackend be;  // absent hardware: the backend's own message passes through and nothing is left behind
      be.micPermitted = true;
      be.micOk = false;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(mic.record('data:a.wav', 1))\nprint(mic.level(100))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 2);
      for (size_t i = 0; i < be.logs.size(); i++) CHECK(be.logs[i] == "nil\tno microphone on this board");
    }
  }
  {
    TEST(
        "net: TLS client sockets: trust choice is mandatory, ca PEM is read through the sandbox, one at a time, RAM "
        "floors, kind-4 is TCP");
    const char* PEM =
        "-----BEGIN CERTIFICATE-----\nMIIBFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE\n-----END CERTIFICATE-----\n";
    {
      MockBackend be;
      be.net = true;
      be.wifiUp = true;
      be.files["/plugins/test/ca.pem"] = PEM;
      be.files["/plugins/test/tiny.pem"] = "short";
      be.files["/plugins/test/huge.pem"] = std::string(8193, 'A');
      be.sockReply["secure.test:443"] = "HELLO";
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(net.connect("secure.test", 443, {tls = true}))
        print(net.connect("secure.test", 443, {tls = true, insecure = true, ca = "app:ca.pem"}))
        print(net.connect("secure.test", 443, {ca = "app:ca.pem"}))
        print(net.connect("secure.test", 443, {insecure = true}))
        print(net.connect("secure.test", 443, {tls = true, ca = "app:missing.pem"}))
        print(net.connect("secure.test", 443, {tls = true, ca = "app:tiny.pem"}))
        print(net.connect("secure.test", 443, {tls = true, ca = "app:huge.pem"}))
        print(net.connect("secure.test", 443, {tls = true, ca = "nowhere:x.pem"}))
        print(pcall(net.connect, "secure.test", 443, {tls = true, ca = 5}))
        local a = net.connect("secure.test", 443, {tls = true, ca = "app:ca.pem"})
        print(a)
        print(net.connect("secure.test", 443, {tls = true, insecure = true}))
        print(net.read(a, 5))
        print(net.write(a, "GET"))
        print(net.available(a), net.connected(a))
        print(net.close(a))
        local b = net.connect("secure.test", 443, {tls = true, insecure = true})
        print(b)
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 400000) == Status::Finished);
      const char* want[] = {
          "nil\ttls needs ca=\"<PEM file>\" (verified) or insecure=true (encrypted, server NOT authenticated)",
          "nil\tpass either ca or insecure, not both",
          "nil\tca and insecure only apply with tls=true",
          "nil\tca and insecure only apply with tls=true",
          "nil\tca file not found",
          "nil\tca file must be a PEM of 32..8192 bytes",
          "nil\tca file must be a PEM of 32..8192 bytes",
          "nil\tillegal character in path",
          "false\tbad argument #3 to '?' (ca must be a path string)",
          "1",
          "nil\tonly one TLS socket at a time (it costs ~40 KB of RAM)",
          "HELLO",
          "3",
          "0\ttrue",
          "true",
          "1"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      CHECK(be.logs.size() == N);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    tls log[%zu] '%s'\n", i, be.logs[i].c_str());
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    tls #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
      CHECK(be.tlsCalls == 2);  // every refused call stopped in the binding; the verified one and the reopen
    }
    {
      MockBackend be;  // the PEM the backend sees is exactly the file; insecure hands it nullptr
      be.net = true;
      be.wifiUp = true;
      be.files["/plugins/test/ca.pem"] = PEM;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(net.connect('secure.test', 443, {tls = true, ca = 'app:ca.pem'}))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.tlsCalls == 1 && be.tlsCaSeen == PEM);
    }
    {
      MockBackend be;
      be.net = true;
      be.wifiUp = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(net.connect('secure.test', 443, {tls = true, insecure = true}))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.tlsCalls == 1 && be.tlsCaSeen == "<insecure>");
    }
    {
      MockBackend be;  // RAM floors: free 40000 and largest block 20000 are the minimum (boundary values pass)
      be.net = true;
      be.wifiUp = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(net.connect('secure.test', 443, {tls = true, insecure = true}))";
      be.freeHeapVal = 39999;
      be.largest = 100000;
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1 && be.logs[0] == "nil\tnot enough free RAM for TLS (free 39999, largest 100000)");
      CHECK(be.tlsCalls == 0);
    }
    {
      MockBackend be;
      be.net = true;
      be.wifiUp = true;
      be.largest = 19999;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(net.connect('secure.test', 443, {tls = true, insecure = true}))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1 && be.logs[0].rfind("nil\tnot enough free RAM for TLS", 0) == 0);
      CHECK(be.tlsCalls == 0);
    }
    {
      MockBackend be;  // exactly at the floors: allowed
      be.net = true;
      be.wifiUp = true;
      be.freeHeapVal = 40000;
      be.largest = 20000;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(net.connect('secure.test', 443, {tls = true, insecure = true}))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1 && be.logs[0] == "1" && be.tlsCalls == 1);
    }
    {
      MockBackend be;  // the backend's own failure text (handshake / certificate mismatch / cancelled) passes through
      be.net = true;
      be.wifiUp = true;
      be.tlsFailMsg = "tls handshake failed (certificate does not match the ca)";
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(net.connect('secure.test', 443, {tls = true, insecure = true}))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1 && be.logs[0] == "nil\ttls handshake failed (certificate does not match the ca)");
    }
  }
  {
    TEST(
        "fs.stat / fs.list detail: size, dir, FAT time -> wall-clock epoch (independent reference values), paging, "
        "option validation");
    auto fat = [](int y, int mo, int d, int h, int mi, int sec) -> uint32_t {
      return (static_cast<uint32_t>(((y - 1980) << 9) | (mo << 5) | d) << 16) |
             static_cast<uint32_t>((h << 11) | (mi << 5) | (sec / 2));
    };
    {
      MockBackend be;
      const std::string D = "/.crosslua/data/test/";
      be.files[D + "a.txt"] = "abc";
      be.files[D + "b.txt"] = "hello";
      be.files[D + "c.txt"] = "";
      be.files[D + "sub/x"] = "1";
      be.fatTimes[D + "b.txt"] = fat(2026, 10, 26, 12, 34, 56);  // 1793018096 (python calendar.timegm)
      be.fatTimes[D + "a.txt"] = fat(1980, 1, 1, 0, 0, 0);       // 315532800
      be.files[D + "leap"] = "x";
      be.fatTimes[D + "leap"] = fat(2024, 2, 29, 23, 59, 58);  // 1709251198
      be.files[D + "last"] = "x";
      be.fatTimes[D + "last"] = fat(2107, 12, 31, 23, 59, 58);  // 4354819198: past 32-bit Lua, so unknown
      be.files[D + "y2038"] = "x";
      be.fatTimes[D + "y2038"] = fat(2038, 1, 19, 3, 14, 6);  // 2147483646: the last stamp that fits
      be.files[D + "y2038b"] = "x";
      be.fatTimes[D + "y2038b"] = fat(2038, 1, 19, 3, 14, 8);  // 2147483648: one tick too far -> unknown
      be.files[D + "huge"] = "x";
      be.bigSizes[D + "huge"] = 3000000000LL;  // > 2 GiB: clamps, never negative
      be.files[D + "edge"] = "x";
      be.bigSizes[D + "edge"] = 2147483647LL;
      be.files[D + "jan"] = "x";
      be.fatTimes[D + "jan"] = fat(2025, 1, 31, 0, 0, 0);  // 1738281600
      be.files[D + "mar"] = "x";
      be.fatTimes[D + "mar"] = fat(2025, 3, 1, 0, 0, 0);  // 1740787200
      be.files[D + "badmon"] = "x";
      be.fatTimes[D + "badmon"] = fat(2026, 13, 1, 0, 0, 0);
      be.files[D + "badmon0"] = "x";
      be.fatTimes[D + "badmon0"] = fat(2026, 0, 1, 0, 0, 0);
      be.files[D + "badday"] = "x";
      be.fatTimes[D + "badday"] = fat(2026, 1, 0, 0, 0, 0);
      be.files[D + "badday32"] = "x";
      be.fatTimes[D + "badday32"] = fat(2026, 1, 32 & 31, 0, 0, 0);  // 0 after the mask: same as badday
      be.files[D + "badhour"] = "x";
      be.fatTimes[D + "badhour"] = fat(2026, 1, 1, 24, 0, 0);
      be.files[D + "badmin"] = "x";
      be.fatTimes[D + "badmin"] = fat(2026, 1, 1, 0, 60, 0);
      be.files[D + "badsec"] = "x";
      be.fatTimes[D + "badsec"] = (fat(2026, 1, 1, 0, 0, 0) & 0xFFFF0000u) | 30;  // 30 * 2 = 60 s
      be.files[D + "nodate"] = "x";
      be.fatTimes[D + "nodate"] = 0x00001234;  // a time without a date
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        local function show(st) if not st then return "nil" end
          return ("%d,%s,%s"):format(st.size, tostring(st.dir), tostring(st.mtime)) end
        print(show(fs.stat("data:b.txt")))
        print(show(fs.stat("data:a.txt")))
        print(show(fs.stat("data:c.txt")))
        print(show(fs.stat("data:sub")))
        print(fs.stat("data:nope"))
        print(show(fs.stat("data:leap")))
        print(show(fs.stat("data:last")))
        print(show(fs.stat("data:y2038")))
        print(show(fs.stat("data:y2038b")))
        print(show(fs.stat("data:huge")))
        print(show(fs.stat("data:edge")))
        print(show(fs.stat("data:jan")))
        print(show(fs.stat("data:mar")))
        for _, n in ipairs{"badmon", "badmon0", "badday", "badday32", "badhour", "badmin", "badsec", "nodate"} do
          print(n .. "=" .. tostring(fs.stat("data:" .. n).mtime))
        end
        print(fs.stat("../x"))
        print((pcall(fs.stat)))
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 400000) == Status::Finished);
      const char* want[] = {"5,false,1793018096",
                            "3,false,315532800",
                            "0,false,nil",
                            "0,true,nil",
                            "nil\tno such file",
                            "1,false,1709251198",
                            "1,false,nil",
                            "1,false,2147483646",
                            "1,false,nil",
                            "2147483647,false,nil",
                            "2147483647,false,nil",
                            "1,false,1738281600",
                            "1,false,1740787200",
                            "badmon=nil",
                            "badmon0=nil",
                            "badday=nil",
                            "badday32=nil",
                            "badhour=nil",
                            "badmin=nil",
                            "badsec=nil",
                            "nodate=nil",
                            "nil\t'.' and '..' are not allowed",
                            "false"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      CHECK(be.logs.size() == N);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    stat log[%zu] '%s'\n", i, be.logs[i].c_str());
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    stat #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
    }
    {
      MockBackend be;  // listing: plain unchanged, windows, detail, paging, stat call counts, vanished entries
      const std::string D = "/.crosslua/data/test/";
      be.files[D + "a.txt"] = "abc";
      be.files[D + "b.txt"] = "hello";
      be.files[D + "c.txt"] = "";
      be.files[D + "sub/x"] = "1";
      be.fatTimes[D + "b.txt"] = fat(2026, 10, 26, 12, 34, 56);
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        local function names(t) local o = {} for i, v in ipairs(t) do o[i] = type(v) == "table" and (v.name .. (v.dir and "/" or "")) or v end return table.concat(o, " ") end
        print(select("#", fs.list("data:")))
        print(names(fs.list("data:")))
        local t, total = fs.list("data:", {})
        print(names(t), total)
        t, total = fs.list("data:", {offset = 1, limit = 2})
        print(names(t), total)
        t, total = fs.list("data:", {offset = 4})
        print(#t, total)
        t, total = fs.list("data:", {offset = 3, limit = 5})
        print(names(t), total)
        t, total = fs.list("data:", {detail = true})
        print(names(t), total)
        local b = t[2]
        print(b.name, b.size, b.dir, b.mtime)
        print(t[4].name, t[4].size, t[4].dir, t[4].mtime)
        t, total = fs.list("data:", {detail = true, offset = 1, limit = 2})
        print(names(t), total, #t)
        t, total = fs.list("data:", {detail = false, limit = 1})
        print(names(t), total)
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 400000) == Status::Finished);
      const char* want[] = {"1",
                            "a.txt b.txt c.txt sub/",
                            "a.txt b.txt c.txt sub/\t4",
                            "b.txt c.txt\t4",
                            "0\t4",
                            "sub/\t4",
                            "a.txt b.txt c.txt sub/\t4",
                            "b.txt\t5\tfalse\t1793018096",
                            "sub\t0\ttrue\tnil",
                            "b.txt c.txt\t4\t2",
                            "a.txt\t4"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      CHECK(be.logs.size() == N);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    list log[%zu] '%s'\n", i, be.logs[i].c_str());
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    list #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
      // stat is only asked for the entries inside the window: 4 (full detail) + 2 (the 2-entry
      // window); plain listings ask for none
      CHECK(be.statCalls == 6);
    }
    {
      MockBackend be;  // the default detail window is 32 entries (a table per entry is ~100 bytes of the Lua heap);
                       // names default to all
      for (int i = 0; i < 40; i++) {
        char nm[48];
        snprintf(nm, sizeof(nm), "/.crosslua/data/test/f%02d", i);
        be.files[nm] = "x";
      }
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        local t, total = fs.list("data:", {detail = true})
        print(#t, total, t[1].name, t[32].name)
        t, total = fs.list("data:", {detail = true, offset = 32})
        print(#t, total, t[1].name, t[8].name)
        t, total = fs.list("data:", {})
        print(#t, total)
        t, total = fs.list("data:", {detail = true, limit = 64})
        print(#t, total)
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 200000) == Status::Finished);
      const char* want[] = {"32\t40\tf00\tf31", "8\t40\tf32\tf39", "40\t40", "40\t40"};
      CHECK(be.logs.size() == 4);
      for (size_t i = 0; i < 4 && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    page #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
    }
    {
      MockBackend
          be;  // an entry that vanishes between the listing and the stat keeps its name and type, size 0, no time
      const std::string D = "/.crosslua/data/test/";
      be.files[D + "gone.txt"] = "abc";
      be.files[D + "sub/x"] = "1";
      be.statFailPath = D + "gone.txt";
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        local t = fs.list("data:", {detail = true})
        print(t[1].name, t[1].dir, t[1].size, t[1].mtime)
        print(t[2].name, t[2].dir, t[2].size)
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 2 && be.logs[0] == "gone.txt\tfalse\t0\tnil" && be.logs[1] == "sub\ttrue\t0");
      be.statFailPath = D + "sub";  // a folder that vanishes keeps dir = true
      be.logs.clear();
      LuaVm vm2;
      CHECK(vm2.open(128 * 1024));
      registerApi(vm2, be);
      CHECK(vm2.load("t", script, strlen(script)));
      CHECK(run(vm2, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 2 && be.logs[1] == "sub\ttrue\t0");
    }
    {
      MockBackend be;  // option validation: nothing invalid reaches the backend
      be.files["/.crosslua/data/test/a.txt"] = "abc";
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(fs.list("data:", {detail = "yes"}))
        print(fs.list("data:", {offset = -1}))
        print(fs.list("data:", {offset = 1.5}))
        print(fs.list("data:", {offset = "1"}))
        print(fs.list("data:", {offset = 100001}))
        print(fs.list("data:", {limit = 0}))
        print(fs.list("data:", {limit = 513}))
        print(fs.list("data:", {limit = 1.5}))
        print(fs.list("data:", {limit = "2"}))
        print(fs.list("data:", {detail = true, limit = 65}))
        print(fs.list("data:", {colour = 1}))
        print(fs.list("data:", {"x"}))
        print((pcall(fs.list, "data:", 5)))
        print(#fs.list("data:", {limit = 512}), #fs.list("data:", {detail = true, limit = 64}))
        print(fs.list("data:nope", {limit = 1}))
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      const char* want[] = {"nil\tdetail must be a boolean",
                            "nil\toffset must be an integer >= 0",
                            "nil\toffset must be an integer >= 0",
                            "nil\toffset must be an integer >= 0",
                            "nil\toffset must be an integer >= 0",
                            "nil\tlimit must be an integer 1..512",
                            "nil\tlimit must be an integer 1..512",
                            "nil\tlimit must be an integer 1..512",
                            "nil\tlimit must be an integer",
                            "nil\tlimit must be an integer 1..64",
                            "nil\tunknown option 'colour'",
                            "nil\toptions must have string keys",
                            "false",
                            "1\t1",
                            "nil\tnot a directory"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      CHECK(be.logs.size() == N);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    opt log[%zu] '%s'\n", i, be.logs[i].c_str());
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    opt #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
      CHECK(be.statCalls == 1);  // only the valid detail call at the end asked about its one entry
    }
  }
  {
    TEST(
        "http: REST/JSON: methods, content_type (form default), headers on POST, ca pinning, response headers, strict "
        "validation");
    const char* PEM =
        "-----BEGIN CERTIFICATE-----\nMIIBFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE\n-----END CERTIFICATE-----\n";
    {
      MockBackend be;
      be.wifiUp = true;
      be.files["/plugins/test/ca.pem"] = PEM;
      be.files["/plugins/test/tiny.pem"] = "x";
      be.routes["https://ha/api/services/light/turn_on"] = {
          200, "[]", "",
          "Content-Type: application/json\r\nX-Rate: 5\r\nset-cookie: a=1\r\nSet-Cookie:   b=2  "
          "\r\nNoColonLine\r\n:empty\r\nX-Spaces:\t v \r\n"};
      be.routes["https://ha/api/states/light.x"] = {200, "{}", ""};
      be.routes["http://h/plain"] = {200, "ok", ""};
      LuaVm vm;
      CHECK(vm.open(256 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        local H = {Authorization = "Bearer abc"}
        local r = http.request{url = "https://ha/api/services/light/turn_on", method = "POST", headers = H,
                               body = '{"entity_id":"light.x"}', content_type = "application/json", ca = "app:ca.pem", response_headers = true}
        print(r.status, r.ok, r.body)
        local h = r.headers
        print(h["content-type"], h["x-rate"], h["set-cookie"], h["x-spaces"], h["nocolonline"], h[""], h["authorization"])
        for _, m in ipairs{"PUT", "PATCH"} do print(http.request{url = "http://h/plain", method = m, body = "a=1"}.status) end
        print(http.request{url = "http://h/plain", method = "DELETE"}.status)
        print(http.request{url = "http://h/plain", method = "DELETE", body = "x"})
        print(http.request{url = "http://h/plain", method = "POST"}.status)
        r = http.request{url = "https://ha/api/states/light.x"}
        print(r.status, r.headers)
        r = http.request{url = "https://ha/api/states/light.x", response_headers = false}
        print(r.headers)
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 400000) == Status::Finished);
      const char* want[] = {"200\ttrue\t[]",
                            "application/json\t5\ta=1, b=2\tv\tnil\tnil\tnil",
                            "200",
                            "200",
                            "200",
                            "nil\ta DELETE request cannot have a body",
                            "200",
                            "200\tnil",
                            "nil"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    rest log[%zu] '%s'\n", i, be.logs[i].c_str());
      CHECK(be.logs.size() == N);
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    rest #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
      // what the backend was handed: the POST carries its Authorization header, the JSON content
      // type and the pinned PEM
      CHECK(be.seen.size() == 7);
      if (be.seen.size() == 7) {
        const auto& p = be.seen[0];
        CHECK(p.method == "POST" && p.body == "{\"entity_id\":\"light.x\"}" && p.hasContentType &&
              p.contentType == "application/json");
        CHECK(p.hasCa && p.ca == PEM && p.wantHeaders && p.headers.size() == 1 &&
              p.headers[0].first == "Authorization");
        CHECK(be.seen[1].method == "PUT" && be.seen[1].contentType == "application/x-www-form-urlencoded" &&
              !be.seen[1].hasCa && !be.seen[1].wantHeaders);
        CHECK(be.seen[2].method == "PATCH" && be.seen[2].hasContentType);
        CHECK(be.seen[3].method == "DELETE" && !be.seen[3].hasContentType);  // no body, no content type
        CHECK(be.seen[4].method == "POST" && be.seen[4].body.empty() &&
              !be.seen[4].hasContentType);  // no body, no content type
        CHECK(!be.seen[5].hasCa && !be.seen[5].wantHeaders && !be.seen[5].hasContentType);
        CHECK(!be.seen[6].wantHeaders);
      }
    }
    {
      MockBackend be;  // response header caps: 48 distinct names kept, a name up to 400 bytes is kept, 401 is dropped
      be.wifiUp = true;
      std::string hs;
      for (int i = 0; i < 60; i++) {
        char l[32];
        snprintf(l, sizeof(l), "H%02d: v\n", i);
        hs += l;
      }
      be.routes["http://h/many"] = {200, "x", "", hs};
      be.routes["http://h/names"] = {200, "x", "", std::string(400, 'B') + ": ok\n" + std::string(401, 'C') + ": no\n"};
      LuaVm vm;
      CHECK(vm.open(256 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        local n = 0
        for _ in pairs(http.request{url = "http://h/many", response_headers = true}.headers) do n = n + 1 end
        print(n)
        local h = http.request{url = "http://h/names", response_headers = true}.headers
        print(h[("b"):rep(400)], h[("c"):rep(401)])
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 400000) == Status::Finished);
      CHECK(be.logs.size() == 2 && be.logs[0] == "48" && be.logs[1] == "ok\tnil");
    }
    {
      MockBackend
          be;  // the response-header buffer is freed on every call (300 requests so LeakSanitizer cannot miss a leak)
      be.wifiUp = true;
      be.routes["http://h/leak"] = {200, "body", "", "X-A: 1\nX-B: 2\nX-C: 3\nX-D: 4\nX-E: 5\nX-F: 6\n"};
      LuaVm vm;
      CHECK(vm.open(256 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        local r = http.request{url = "http://h/leak", response_headers = true}  -- warm up: lazy registration, interned strings
        collectgarbage()
        for i = 1, 300 do r = http.request{url = "http://h/leak", response_headers = true} end
        r = nil
        collectgarbage()
        print("done")
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 4000000) == Status::Finished);
      CHECK(be.logs.size() == 1 && be.logs[0] == "done");
      // No byte counter here: ASAN replaces malloc, so mallinfo is blind. 300 requests make a
      // missing free() a wall of LeakSanitizer reports (304 leaked allocations when the free is
      // removed), which the run script turns into exit code 1.
    }
    {
      MockBackend be;  // validation: nothing invalid reaches the backend
      be.wifiUp = true;
      be.files["/plugins/test/ca.pem"] = PEM;
      be.files["/plugins/test/tiny.pem"] = "x";
      be.routes["https://h/a"] = {200, "x", ""};
      be.routes["http://h/a"] = {200, "x", ""};
      LuaVm vm;
      CHECK(vm.open(256 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        local function try(t) local ok, a, b = pcall(http.request, t) print(ok, a, b) end
        try{url = "http://h/a", method = "POST", body = "x", content_type = 5}
        try{url = "http://h/a", method = "POST", body = "x", content_type = ""}
        try{url = "http://h/a", method = "POST", body = "x", content_type = ("a"):rep(101)}
        try{url = "http://h/a", method = "POST", body = "x", content_type = "a\r\nB: c"}
        try{url = "http://h/a", content_type = "application/json"}
        try{url = "http://h/a", method = "POST", body = "x", headers = {["content-TYPE"] = "text/plain"}}
        try{url = "http://h/a", headers = {["Content-Type"] = "text/plain"}}
        try{url = "http://h/a", response_headers = "yes"}
        try{url = "https://h/a", ca = 5}
        try{url = "http://h/a", ca = "app:ca.pem"}
        try{url = "https://h/a", ca = "app:missing.pem"}
        try{url = "https://h/a", ca = "app:tiny.pem"}
        try{url = "https://h/a", ca = "app:ca.pem", save_to = "data:x"}
        try{url = "http://h/a", response_headers = true, save_to = "data:x"}
        try{url = "http://h/a", method = "PUT", body = "x", save_to = "data:x"}
        try{url = "http://h/a", method = "put"}
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 400000) == Status::Finished);
      const char* want[] = {"false\tbad argument #1 to '?' (content_type must be a string)\tnil",
                            "true\tnil\tillegal content_type",
                            "true\tnil\tillegal content_type",
                            "true\tnil\tillegal content_type",
                            "true\tnil\tcontent_type needs a body",
                            "true\tnil\tset content_type instead of a Content-Type header",
                            "true\ttable: ADDR\tnil",  // a Content-Type header on a bodiless GET is allowed
                            "false\tbad argument #1 to '?' (response_headers must be a boolean)\tnil",
                            "false\tbad argument #1 to '?' (ca must be a path string)\tnil",
                            "true\tnil\tca only applies to https:// urls",
                            "true\tnil\tca file not found",
                            "true\tnil\tca file must be a PEM of 32..8192 bytes",
                            "true\tnil\tsave_to cannot be combined with ca or response_headers yet",
                            "true\tnil\tsave_to cannot be combined with ca or response_headers yet",
                            "true\tnil\tsave_to is only supported for GET",
                            "true\tnil\tmethod must be GET, POST, PUT, PATCH or DELETE"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    resterr log[%zu] '%s'\n", i, be.logs[i].c_str());
      CHECK(be.logs.size() == N);
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        std::string got = be.logs[i];
        const size_t a = got.find("table: 0x");
        if (a != std::string::npos) got = got.substr(0, a) + "table: ADDR" + got.substr(got.find('\t', a));
        CHECK(got == want[i]);
        if (got != want[i]) printf("    resterr #%zu got '%s' want '%s'\n", i + 1, got.c_str(), want[i]);
      }
      CHECK(be.seen.size() == 1);  // only the bodiless GET with a Content-Type header got through
    }
  }
  {
    TEST(
        "wifi.softap: hotspot permission + approval, options, state conflicts, RAM floor, net.* works over the "
        "hotspot");
    {
      MockBackend be;
      be.net = true;
      be.hotspotPermitted = true;
      be.listenPermitted = true;  // net.listen has its own permission; the point here is that it works over the hotspot
      be.apClients = 2;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(wifi.softap_info())
        print(wifi.softap("X4-test"))
        local i = wifi.softap_info()
        print(i.ssid, i.ip, i.clients)
        print(wifi.softap("again"))
        local srv = net.listen(8080)
        print(srv)
        print(net.close(srv))
        local u = net.udp_open(0)   -- the other gate (anything that creates traffic) must accept the hotspot too
        print(u ~= nil)
        if u then net.close(u) end
        print(wifi.status().connected)
        wifi.off()
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      const char* want[] = {"nil\tno hotspot running",
                            "true\t192.168.4.1",
                            "X4-test\t192.168.4.1\t2",
                            "false\ta hotspot is already running (wifi.off() stops it)",
                            "1",
                            "true",
                            "true",
                            "false"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    ap log[%zu] '%s'\n", i, be.logs[i].c_str());
      CHECK(be.logs.size() == N);
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    ap #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
      CHECK(be.apCalls.size() == 1 && be.apCalls[0].open && be.apCalls[0].channel == 1 &&
            be.apCalls[0].maxClients == 4);
    }
    {
      MockBackend be;  // options reach the backend unchanged
      be.net = true;
      be.hotspotPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script =
          R"LUA(print(wifi.softap("My Net", {password = "secret123", channel = 11, max_clients = 1})))LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1 && be.logs[0] == "true\t192.168.4.1");
      CHECK(be.apCalls.size() == 1 && !be.apCalls[0].open && be.apCalls[0].password == "secret123" &&
            be.apCalls[0].channel == 11 && be.apCalls[0].maxClients == 1 && be.apCalls[0].ssid == "My Net");
    }
    {
      MockBackend be;  // validation: nothing invalid reaches the backend
      be.net = true;
      be.hotspotPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(wifi.softap(""))
        print(wifi.softap(("a"):rep(33)))
        print(wifi.softap("bad\nname"))
        print(wifi.softap("caf\xc3\xa9"))
        print(wifi.softap("ok", {password = "short"}))
        print(wifi.softap("ok", {password = "1234567"}))
        print(wifi.softap("ok", {password = ("p"):rep(64)}))
        print(wifi.softap("ok", {password = ""}))
        print(wifi.softap("ok", {password = "has\ttab12345"}))
        print(wifi.softap("ok", {password = 12345678}))
        print(wifi.softap("ok", {channel = 0}))
        print(wifi.softap("ok", {channel = 12}))
        print(wifi.softap("ok", {channel = 1.5}))
        print(wifi.softap("ok", {channel = "6"}))
        print(wifi.softap("ok", {max_clients = 0}))
        print(wifi.softap("ok", {max_clients = 5}))
        print(wifi.softap("ok", {max_clients = 2.5}))
        print(wifi.softap("ok", {max_clients = "2"}))
        print(wifi.softap("ok", {colour = 1}))
        print(wifi.softap("ok", {"x"}))
        print((pcall(wifi.softap, "ok", 5)))
        print((pcall(wifi.softap)))
        print(wifi.softap(("a"):rep(32), {password = ("p"):rep(63), channel = 1, max_clients = 4}))
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 200000) == Status::Finished);
      const char* S = "false\tssid must be 1..32 printable ASCII characters";
      const char* P = "false\tpassword must be 8..63 printable ASCII characters (leave it out for an open network)";
      const char* C = "false\tchannel must be an integer 1..11";
      const char* M = "false\tmax_clients must be an integer 1..4";
      const char* want[] = {S,
                            S,
                            S,
                            S,
                            P,
                            P,
                            P,
                            P,
                            P,
                            "false\tpassword must be a string",
                            C,
                            C,
                            C,
                            "false\tchannel must be an integer 1..11",
                            M,
                            M,
                            M,
                            "false\tmax_clients must be an integer 1..4",
                            "false\tunknown option 'colour'",
                            "false\toptions must have string keys",
                            "false",
                            "false",
                            "true\t192.168.4.1"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    aperr log[%zu] '%s'\n", i, be.logs[i].c_str());
      CHECK(be.logs.size() == N);
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    aperr #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
      CHECK(be.apCalls.size() == 1);  // only the last, all-maximum call was valid
    }
    {
      MockBackend be;  // permission layers: network, hotspot, approval
      be.hotspotPermitted = true;
      be.net = false;  // no "network"
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(wifi.softap('x'))\nprint(wifi.softap_info())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 2 && be.logs[0].rfind("false\tnetwork not permitted", 0) == 0 &&
            be.logs[1].rfind("nil\tnetwork not permitted", 0) == 0);
      CHECK(be.apCalls.empty());
    }
    {
      MockBackend be;
      be.net = true;
      be.hotspotPermitted = false;  // network but no "hotspot"
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(wifi.softap('x'))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1 && be.logs[0].rfind("false\thotspot not permitted", 0) == 0 && be.apCalls.empty());
    }
    {
      MockBackend be;
      be.net = true;
      be.hotspotPermitted = true;
      be.hotspotApproved = false;  // declared, not approved
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(wifi.softap('x'))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1 && be.logs[0].rfind("false\thotspot not permitted", 0) == 0 && be.apCalls.empty());
    }
    {
      MockBackend be;  // joined as a client already
      be.net = true;
      be.hotspotPermitted = true;
      be.wifiUp = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(wifi.softap('x'))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1 &&
            be.logs[0] == "false\tWiFi is joined as a client: call wifi.off() before starting a hotspot" &&
            be.apCalls.empty());
    }
    {
      MockBackend be;  // RAM floor: 80 KB (hotspot ~60 KB + the socket layer's 16 KB), boundary values
      be.net = true;
      be.hotspotPermitted = true;
      for (int pass = 0; pass < 2; pass++) {
        be.apCalls.clear();
        be.apUp = false;
        be.logs.clear();
        be.freeHeapVal = pass == 0 ? 80 * 1024 - 1 : 80 * 1024;
        LuaVm vm;
        CHECK(vm.open(128 * 1024));
        registerApi(vm, be);
        const char* script = "print(wifi.softap('x'))";
        CHECK(vm.load("t", script, strlen(script)));
        CHECK(run(vm, be, 100000) == Status::Finished);
        if (pass == 0)
          CHECK(be.logs.size() == 1 && be.logs[0] == "false\tnot enough free RAM for a hotspot (free 79K, need 80K)" &&
                be.apCalls.empty());
        else
          CHECK(be.logs.size() == 1 && be.logs[0] == "true\t192.168.4.1" && be.apCalls.size() == 1);
      }
    }
    {
      MockBackend be;  // the backend's own failure text passes through; nothing is left "up"
      be.net = true;
      be.hotspotPermitted = true;
      be.apFail = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(wifi.softap('x'))\nprint(wifi.softap_info())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 2 && be.logs[0] == "false\tcannot start the hotspot (mock)" &&
            be.logs[1] == "nil\tno hotspot running");
    }
  }
  {
    TEST("espnow: start/send/recv/info/stop, mac parsing, payload limits, permission layers, radio exclusivity");
    {
      MockBackend be;
      be.net = true;
      be.enPermitted = true;
      const uint8_t peer1[6] = {0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01};
      MockBackend::EnIn a;
      memcpy(a.mac, peer1, 6);
      a.data = std::string("hello\0bin", 9);
      MockBackend::EnIn b;
      memcpy(b.mac, peer1, 6);
      b.data = "second";
      be.enInbox = {a, b};
      be.enDropped = 3;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(espnow.info())
        print(espnow.send(nil, "x"))
        print(espnow.recv())
        print(espnow.start())
        local i = espnow.info()
        print(i.mac, i.channel, i.dropped)
        print(espnow.start())
        print(espnow.send(nil, "to everyone"))
        print(espnow.send("broadcast", "also everyone"))
        print(espnow.send("AA:bb:0C:dd:EE:ff", "unicast"))
        print(espnow.send("aa:bb:cc:dd:ee:ff", ("z"):rep(250)))
        local d, m = espnow.recv()
        print(#d, d:byte(6), m)
        d, m = espnow.recv()
        print(d, m)
        print(select("#", espnow.recv()), espnow.recv())
        print(espnow.stop())
        print(espnow.send(nil, "x"))
        print(espnow.recv())
        print(espnow.info())
        print(espnow.stop())
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 200000) == Status::Finished);
      const char* NS = "nil\tespnow is not started (call espnow.start() first)";
      const char* want[] = {NS,
                            NS,
                            NS,
                            "true\t02:00:00:00:00:a1",
                            "02:00:00:00:00:a1\t1\t3",
                            "nil\tespnow is already running (espnow.stop() first)",
                            "true",
                            "true",
                            "true",
                            "true",
                            "9\t0\tde:ad:be:ef:00:01",
                            "second\tde:ad:be:ef:00:01",
                            "1\tnil",
                            "true",
                            NS,
                            NS,
                            NS,
                            "true"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    en log[%zu] '%s'\n", i, be.logs[i].c_str());
      CHECK(be.logs.size() == N);
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    en #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
      CHECK(be.enSent.size() == 4);
      if (be.enSent.size() == 4) {
        const uint8_t bc[6] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
        CHECK(!memcmp(be.enSent[0].mac, bc, 6) && be.enSent[0].broadcast && be.enSent[0].data == "to everyone");
        CHECK(!memcmp(be.enSent[1].mac, bc, 6) && be.enSent[1].broadcast);
        const uint8_t uni[6] = {0xAA, 0xBB, 0x0C, 0xDD, 0xEE, 0xFF};
        CHECK(!memcmp(be.enSent[2].mac, uni, 6) && !be.enSent[2].broadcast && be.enSent[2].data == "unicast");
        CHECK(be.enSent[3].data.size() == 250 && !be.enSent[3].broadcast);
      }
      CHECK(be.enChannel == 1 && !be.enUp);
    }
    {
      MockBackend be;  // channel option
      be.net = true;
      be.enPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(espnow.start{channel = 13})\nprint(espnow.info().channel)";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 2 && be.logs[0] == "true\t02:00:00:00:00:a1" && be.logs[1] == "13" && be.enChannel == 13);
    }
    {
      MockBackend be;  // validation: nothing invalid reaches the backend
      be.net = true;
      be.enPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        local C = "channel must be an integer 1..13"
        print(espnow.start{channel = 0}); print(espnow.start{channel = 14}); print(espnow.start{channel = 1.5})
        print(espnow.start{channel = "6"}); print(espnow.start{colour = 1}); print(espnow.start{"x"})
        print((pcall(espnow.start, 5)))
        print(espnow.start{channel = 1})
        local MAC = "mac must be 'aa:bb:cc:dd:ee:ff' or \"broadcast\""
        print(espnow.send("aa:bb:cc:dd:ee", "x"))
        print(espnow.send("aa:bb:cc:dd:ee:gg", "x"))
        print(espnow.send("aa-bb-cc-dd-ee-ff", "x"))
        print(espnow.send("aa:bb:cc:dd:ee:ff:", "x"))
        print(espnow.send("aabbccddeeff", "x"))
        print(espnow.send("aa:bb:cc:dd:ee:f", "x"))
        print(espnow.send("Broadcast", "x"))
        print(espnow.send(nil, ""))
        print(espnow.send(nil, ("z"):rep(251)))
        print((pcall(espnow.send, nil)))
        print((pcall(espnow.send, {}, "x")))
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 200000) == Status::Finished);
      const char* C = "nil\tchannel must be an integer 1..13";
      const char* M = "nil\tmac must be 'aa:bb:cc:dd:ee:ff' or \"broadcast\"";
      const char* D = "nil\tdata must be 1..250 bytes";
      const char* want[] = {C,
                            C,
                            C,
                            C,
                            "nil\tunknown option 'colour'",
                            "nil\toptions must have string keys",
                            "false",
                            "true\t02:00:00:00:00:a1",
                            M,
                            M,
                            M,
                            M,
                            M,
                            M,
                            M,
                            D,
                            D,
                            "false",
                            "false"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    enerr log[%zu] '%s'\n", i, be.logs[i].c_str());
      CHECK(be.logs.size() == N);
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    enerr #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
      CHECK(be.enSent.empty());
    }
    {
      MockBackend be;  // permission layers
      be.enPermitted = true;
      be.net = false;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script =
          "print(espnow.start())\nprint(espnow.send(nil, "
          "'x'))\nprint(espnow.recv())\nprint(espnow.info())\nprint(espnow.stop())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 5);
      for (int i = 0; i < 4 && i < static_cast<int>(be.logs.size()); i++)
        CHECK(be.logs[i].rfind("nil\tnetwork not permitted", 0) == 0);
      CHECK(be.logs.size() == 5 && be.logs[4] == "true");  // stop is always allowed
      CHECK(!be.enUp);
    }
    for (int variant = 0; variant < 2; variant++) {
      MockBackend be;  // declared without approval / not declared at all
      be.net = true;
      be.enPermitted = variant == 0;
      be.enApproved = false;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script =
          "print(espnow.start())\nprint(espnow.send(nil, 'x'))\nprint(espnow.recv())\nprint(espnow.info())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 4);
      for (size_t i = 0; i < be.logs.size(); i++) CHECK(be.logs[i].rfind("nil\tespnow not permitted", 0) == 0);
      CHECK(!be.enUp && be.enSent.empty());
    }
    {
      MockBackend be;  // radio exclusivity in both directions, RAM floor, backend failure
      be.net = true;
      be.enPermitted = true;
      be.hotspotPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(espnow.start())
        print(wifi.softap("x"))
        print(wifi.connect{tls = false})
        espnow.stop()
        print(wifi.softap("x"))
        print(espnow.start())
        wifi.off()
        print(espnow.start())
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 200000) == Status::Finished);
      const char* want[] = {"true\t02:00:00:00:00:a1",
                            "false\tespnow is running: call espnow.stop() before starting a hotspot",
                            "false\tespnow is running: call espnow.stop() before joining WiFi",
                            "true\t192.168.4.1",
                            "nil\tthe radio is in use by WiFi or the hotspot: call wifi.off() first",
                            "true\t02:00:00:00:00:a1"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    enx log[%zu] '%s'\n", i, be.logs[i].c_str());
      CHECK(be.logs.size() == N);
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    enx #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
    }
    {
      MockBackend be;  // joined as a client: espnow refuses
      be.net = true;
      be.enPermitted = true;
      be.wifiUp = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(espnow.start())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1 &&
            be.logs[0] == "nil\tthe radio is in use by WiFi or the hotspot: call wifi.off() first" && !be.enUp);
    }
    for (int pass = 0; pass < 2; pass++) {
      MockBackend be;  // RAM floor 80 KB, boundary values
      be.net = true;
      be.enPermitted = true;
      be.freeHeapVal = pass == 0 ? 80 * 1024 - 1 : 80 * 1024;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(espnow.start())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      if (pass == 0)
        CHECK(be.logs.size() == 1 && be.logs[0] == "nil\tnot enough free RAM for espnow (free 79K, need 80K)" &&
              !be.enUp);
      else
        CHECK(be.logs.size() == 1 && be.logs[0] == "true\t02:00:00:00:00:a1" && be.enUp);
    }
    {
      MockBackend be;  // backend failures pass through
      be.net = true;
      be.enPermitted = true;
      be.enFail = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(espnow.start())\nprint(espnow.info())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 2 && be.logs[0] == "nil\tesp_now_init failed (mock)" &&
            be.logs[1].rfind("nil\tespnow is not started", 0) == 0);
      be.enFail = false;
      be.enSendFail = true;
      be.logs.clear();
      LuaVm vm2;
      CHECK(vm2.open(128 * 1024));
      registerApi(vm2, be);
      const char* script2 = "print(espnow.start())\nprint(espnow.send(nil, 'x'))";
      CHECK(vm2.load("t", script2, strlen(script2)));
      CHECK(run(vm2, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 2 && be.logs[1] == "nil\tthe radio refused the frame (mock)");
    }
  }
  {
    TEST("permission dialog packing: most sensitive first, <= width per line, nothing dropped or reordered");
    using crosslua::packPermissionLabels;
    CHECK(packPermissionLabels({}, 25) == "");
    CHECK(packPermissionLabels({"MICROPHONE"}, 25) == "MICROPHONE\n");
    CHECK(packPermissionLabels({"MICROPHONE", "ESP-NOW", "HOTSPOT", "SERVER", "SPEAKER"}, 25) ==
          "MICROPHONE, ESP-NOW\nHOTSPOT, SERVER, SPEAKER\n");
    CHECK(packPermissionLabels({"AAAAAAAAAA", "BBBBBBBBBB"}, 22) == "AAAAAAAAAA, BBBBBBBBBB\n");  // exactly full
    CHECK(packPermissionLabels({"AAAAAAAAAA", "BBBBBBBBBB"}, 21) == "AAAAAAAAAA\nBBBBBBBBBB\n");  // one over
    CHECK(packPermissionLabels({"TOOLONGLABELXXXXXXXXXXXXXX", "B", "C"}, 10) == "TOOLONGLABELXXXXXXXXXXXXXX\nB, C\n");
    CHECK(packPermissionLabels({"A", "B", "C"}, 1000) == "A, B, C\n");
    CHECK(packPermissionLabels({"MICROPHONE", "SPEAKER"}, 25) == "MICROPHONE, SPEAKER\n");
  }
  {
    TEST(
        "wifi.monitor: start/recv/info/stop, options validation, permission layers, radio exclusivity, RAM floor, pcap "
        "counters");
    {
      MockBackend be;  // happy path: frames in order, metadata preserved
      be.net = true;
      be.monPermitted = true;
      const uint8_t f1[4] = {0x80, 0x00, 0xAA, 0xBB};
      be.monInbox = {{std::string("\x80\x00\xaa\xbb", 4), -52, 1}, {"second", -71, 13}};
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(wifi.monitor_recv())
        print(wifi.monitor_info())
        print(wifi.monitor_start())
        local i = wifi.monitor_info()
        print(i.channel, i.captured, i.dropped, i.file, i.bytes)
        print(wifi.monitor_start())
        local f, m = wifi.monitor_recv()
        print(#f, f:byte(1), m.rssi, m.channel)
        local g, m2 = wifi.monitor_recv()
        print(g, m2.rssi, m2.channel)
        print(wifi.monitor_recv())
        local i2 = wifi.monitor_info()
        print(i2.captured, i2.dropped)
        print(wifi.monitor_stop())
        print(wifi.monitor_recv())
        print(wifi.monitor_info())
        print(wifi.monitor_stop())
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 200000) == Status::Finished);
      const char* NS = "nil\tmonitor is not running (call wifi.monitor_start() first)";
      const char* want[] = {NS,
                            NS,
                            "true",
                            "1\t0\t0\tnil\tnil",
                            "nil\tmonitor is already running (wifi.monitor_stop() first)",
                            "4\t128\t-52\t1",
                            "second\t-71\t13",
                            "nil",
                            "2\t1",
                            "0",
                            NS,
                            NS,
                            "0"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    mon log[%zu] '%s'\n", i, be.logs[i].c_str());
      CHECK(be.logs.size() == N);
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    mon #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
      CHECK(be.monChannel == 1 && !be.monUp);
    }
    {
      MockBackend be;  // options: channel + file
      be.net = true;
      be.monPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(wifi.monitor_start{channel = 13, file = "data:cap.pcap"})
        local i = wifi.monitor_info()
        print(i.file, i.bytes)
        print(wifi.monitor_stop())
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      // i.file is the resolved on-card path, not the "data:..." spec the app wrote
      CHECK(be.logs.size() == 3 && be.logs[0] == "true" && be.logs[1] == "/.crosslua/data/test/cap.pcap\t24" &&
            be.logs[2] == "24" && be.monChannel == 13);
    }
    {
      MockBackend be;  // validation: nothing invalid reaches the backend
      be.net = true;
      be.monPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        local C = "channel must be an integer 1..13"
        print(wifi.monitor_start{channel = 0}); print(wifi.monitor_start{channel = 14}); print(wifi.monitor_start{channel = 1.5})
        print(wifi.monitor_start{channel = "6"}); print(wifi.monitor_start{hop = 1}); print(wifi.monitor_start{"x"})
        print((pcall(wifi.monitor_start, 5)))
        local F = "file must be a path string ending in .pcap"
        print((pcall(wifi.monitor_start, {file = 3}))); print(wifi.monitor_start{file = "data:cap.bin"}); print(wifi.monitor_start{file = "data:cap"})
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 200000) == Status::Finished);
      const char* C = "nil\tchannel must be an integer 1..13";
      const char* F = "nil\tfile must be a path string ending in .pcap";
      const char* want[] = {C,
                            C,
                            C,
                            C,
                            "nil\tunknown option 'hop'",
                            "nil\toptions must have string keys",
                            "false",
                            "true",
                            "nil\tfile must end in .pcap",
                            "nil\tfile must end in .pcap"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    monerr log[%zu] '%s'\n", i, be.logs[i].c_str());
      CHECK(be.logs.size() == N);
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    monerr #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
      CHECK(!be.monUp);
    }
    {
      MockBackend be;  // permission layers
      be.monPermitted = true;
      be.net = false;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script =
          "print(wifi.monitor_start())\nprint(wifi.monitor_recv())\nprint(wifi.monitor_info())\nprint(wifi.monitor_"
          "stop())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 4);
      for (int i = 0; i < 3 && i < static_cast<int>(be.logs.size()); i++)
        CHECK(be.logs[i].rfind("nil\tnetwork not permitted", 0) == 0);
      CHECK(be.logs.size() == 4 && be.logs[3] == "0");  // stop is always allowed
      CHECK(!be.monUp);
    }
    for (int variant = 0; variant < 2; variant++) {
      MockBackend be;  // declared without approval / not declared at all
      be.net = true;
      be.monPermitted = variant == 0;
      be.monApproved = false;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(wifi.monitor_start())\nprint(wifi.monitor_recv())\nprint(wifi.monitor_info())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 3);
      for (size_t i = 0; i < be.logs.size(); i++) CHECK(be.logs[i].rfind("nil\tmonitor not permitted", 0) == 0);
      CHECK(!be.monUp);
    }
    {
      MockBackend be;  // radio exclusivity in both directions
      be.net = true;
      be.monPermitted = true;
      be.enPermitted = true;
      be.hotspotPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(espnow.start())
        print(wifi.monitor_start())
        espnow.stop()
        print(wifi.monitor_start())
        print(espnow.start())
        print(wifi.connect{tls = false})
        print(wifi.softap("x"))
        wifi.off()
        print(espnow.start())
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 200000) == Status::Finished);
      const char* want[] = {"true\t02:00:00:00:00:a1",
                            "nil\tespnow is running: call espnow.stop() first",
                            "true",
                            "nil\tthe WiFi sniffer is running: call wifi.monitor_stop() first",
                            "false\tthe WiFi sniffer is running: call wifi.monitor_stop() first",
                            "false\tthe WiFi sniffer is running: call wifi.monitor_stop() first",
                            "true\t02:00:00:00:00:a1"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    monx log[%zu] '%s'\n", i, be.logs[i].c_str());
      CHECK(be.logs.size() == N);
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    monx #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
      CHECK(!be.monUp && be.enUp);
    }
    {
      MockBackend be;  // hotspot first, then monitor refused; wifi.off gives the radio back
      be.net = true;
      be.monPermitted = true;
      be.hotspotPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script =
          "print(wifi.softap('x'))\nprint(wifi.monitor_start())\nwifi.off()\nprint(wifi.monitor_start())\nprint(wifi."
          "monitor_stop())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      const char* want[] = {"true\t192.168.4.1",
                            "nil\tthe radio is in use by WiFi or the hotspot: call wifi.off() first", "true", "0"};
      CHECK(be.logs.size() == 4);
      for (size_t i = 0; i < 4 && i < be.logs.size(); i++) CHECK(be.logs[i] == want[i]);
    }
    for (int pass = 0; pass < 2; pass++) {
      MockBackend be;  // RAM floor 80 KB, boundary values
      be.net = true;
      be.monPermitted = true;
      be.freeHeapVal = pass == 0 ? 80 * 1024 - 1 : 80 * 1024;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(wifi.monitor_start())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      if (pass == 0)
        CHECK(be.logs.size() == 1 && be.logs[0] == "nil\tnot enough free RAM for monitor (free 79K, need 80K)" &&
              !be.monUp);
      else
        CHECK(be.logs.size() == 1 && be.logs[0] == "true" && be.monUp);
    }
    {
      MockBackend be;  // backend failure passes through
      be.net = true;
      be.monPermitted = true;
      be.monFail = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(wifi.monitor_start())\nprint(wifi.monitor_info())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 2 && be.logs[0] == "nil\tesp_wifi_set_promiscuous failed (mock)" &&
            be.logs[1].rfind("nil\tmonitor is not running", 0) == 0);
    }
  }
  {
    TEST("wifi.tx: start/send/info/stop, validation, permission layers, radio exclusivity and monitor coexistence");
    {
      MockBackend be;  // happy path
      be.net = true;
      be.txPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(wifi.tx(("d"):rep(26)))
        print(wifi.tx_info())
        print(wifi.tx_start())
        local i = wifi.tx_info()
        print(i.channel, i.sent)
        print(wifi.tx_start())
        print(wifi.tx(("d"):rep(26)))
        print(wifi.tx(("d"):rep(24)))
        local f = ("\xd0\x00") .. ("\x00\x00") .. ("\xff"):rep(6) .. ("\x02\x48\x4f\x53\x54\x01") .. ("\xff"):rep(6) .. "\x00\x00" .. "\x7f" .. ("X4-TX")
        print(wifi.tx(f))
        print(wifi.tx_info().sent)
        print(wifi.tx_stop())
        print(wifi.tx(f))
        print(wifi.tx_info())
        print(wifi.tx_stop())
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 200000) == Status::Finished);
      const char* NS = "nil\tthe injector is not running (call wifi.tx_start() first)";
      const char* want[] = {
          NS,     NS,     "true", "1\t0", "nil\tthe injector is already running (wifi.tx_stop() first)",
          "true", "true", "true", "3",    "true",
          NS,     NS,     "true"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    tx log[%zu] '%s'\n", i, be.logs[i].c_str());
      CHECK(be.logs.size() == N);
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    tx #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
      CHECK(be.txChannelVal == 1 && be.txSent == 3 && !be.txUp);
    }
    {
      MockBackend be;  // validation: nothing invalid reaches the backend
      be.net = true;
      be.txPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(wifi.tx_start{channel = 0}); print(wifi.tx_start{channel = 14}); print(wifi.tx_start{channel = 1.5})
        print(wifi.tx_start{channel = "6"}); print(wifi.tx_start{rate = 1}); print(wifi.tx_start{"x"})
        print((pcall(wifi.tx_start, 5)))
        print(wifi.tx_start{channel = 6})
        print(wifi.tx("short"))
        print(wifi.tx(("d"):rep(23)))
        print(wifi.tx(("d"):rep(251)))
        print((pcall(wifi.tx)))
        print((pcall(wifi.tx, 7)))
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 200000) == Status::Finished);
      const char* C = "nil\tchannel must be an integer 1..13";
      const char* F = "nil\tframe must be 24..250 bytes (without the FCS)";
      const char* want[] = {
          C, C, C,       C,     "nil\tunknown option 'rate'", "nil\toptions must have string keys", "false", "true", F,
          F, F, "false", "true"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    txerr log[%zu] '%s'\n", i, be.logs[i].c_str());
      CHECK(be.logs.size() == N);
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    txerr #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
      CHECK(be.txSent == 0);
    }
    {
      MockBackend be;  // permission layers
      be.txPermitted = true;
      be.net = false;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script =
          "print(wifi.tx_start())\nprint(wifi.tx(('d'):rep(26)))\nprint(wifi.tx_info())\nprint(wifi.tx_stop())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 4);
      for (int i = 0; i < 3 && i < static_cast<int>(be.logs.size()); i++)
        CHECK(be.logs[i].rfind("nil\tnetwork not permitted", 0) == 0);
      CHECK(be.logs.size() == 4 && be.logs[3] == "true");  // stop is always allowed
      CHECK(!be.txUp);
    }
    for (int variant = 0; variant < 2; variant++) {
      MockBackend be;  // declared without approval / not declared at all
      be.net = true;
      be.txPermitted = variant == 0;
      be.txApproved = false;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(wifi.tx_start())\nprint(wifi.tx(('d'):rep(26)))\nprint(wifi.tx_info())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 3);
      for (size_t i = 0; i < be.logs.size(); i++) CHECK(be.logs[i].rfind("nil\ttx not permitted", 0) == 0);
      CHECK(!be.txUp);
    }
    {
      MockBackend
          be;  // exclusivity: WiFi/hotspot/espnow refuse the injector and vice versa; monitor coexists and adopts
      be.net = true;
      be.txPermitted = true;
      be.monPermitted = true;
      be.enPermitted = true;
      be.hotspotPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(espnow.start())
        print(wifi.tx_start())
        espnow.stop()
        print(wifi.tx_start())
        print(espnow.start())
        print(wifi.connect{tls = false})
        print(wifi.softap("x"))
        print(wifi.monitor_start())
        local i = wifi.tx_info()
        print("adopted", i.channel)
        print(wifi.monitor_start{channel = 11})
        print(wifi.tx_stop())
        wifi.off()
        print(wifi.tx_start{channel = 4})
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 200000) == Status::Finished);
      const char* want[] = {"true\t02:00:00:00:00:a1",
                            "nil\tespnow is running: call espnow.stop() first",
                            "true",
                            "nil\tthe injector is running: call wifi.tx_stop() first",
                            "false\tthe injector is running: call wifi.tx_stop() first",
                            "false\tthe injector is running: call wifi.tx_stop() first",
                            "true",
                            "adopted\t1",
                            "nil\tmonitor is already running (wifi.monitor_stop() first)",
                            "true",
                            "true"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    txx log[%zu] '%s'\n", i, be.logs[i].c_str());
      CHECK(be.logs.size() == N);
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    txx #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
      CHECK(be.txChannelVal == 4 && be.txUp && !be.monUp &&
            !be.enUp);  // wifi.off() stopped the monitor; the injector was restarted
    }
    {
      MockBackend be;  // joined as a client: the injector refuses
      be.net = true;
      be.txPermitted = true;
      be.wifiUp = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(wifi.tx_start())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1 &&
            be.logs[0] == "nil\tthe radio is in use by WiFi or the hotspot: call wifi.off() first" && !be.txUp);
    }
    {
      MockBackend be;  // monitor first: the injector adopts the sniffer's channel; an explicit different one is refused
      be.net = true;
      be.txPermitted = true;
      be.monPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(wifi.monitor_start{channel = 6})
        print(wifi.tx_start())
        print(wifi.tx_info().channel)
        wifi.tx_stop()
        print(wifi.tx_start{channel = 5})
        wifi.monitor_stop()
        print(wifi.tx_start{channel = 2})
        print(wifi.monitor_start{channel = 3})
        print(wifi.monitor_start{channel = 2})
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 200000) == Status::Finished);
      const char* want[] = {"true", "true",
                            "6",    "nil\tthe sniffer is on channel 6: use it, or wifi.monitor_stop() first",
                            "true", "nil\tthe injector is on channel 2: use it, or wifi.tx_stop() first",
                            "true"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    txc log[%zu] '%s'\n", i, be.logs[i].c_str());
      CHECK(be.logs.size() == N);
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    txc #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
    }
    for (int pass = 0; pass < 2; pass++) {
      MockBackend be;  // RAM floor: 80 KB fresh, 48 KB once the radio has been used
      be.net = true;
      be.txPermitted = true;
      be.freeHeapVal = pass == 0 ? 80 * 1024 - 1 : 48 * 1024;
      if (pass == 1) be.radioEverStarted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(wifi.tx_start())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      if (pass == 0)
        CHECK(be.logs.size() == 1 && be.logs[0] == "nil\tnot enough free RAM for tx (free 79K, need 80K)" && !be.txUp);
      else
        CHECK(be.logs.size() == 1 && be.logs[0] == "true" && be.txUp);
    }
    {
      MockBackend be;  // backend failures pass through (start, then send)
      be.net = true;
      be.txPermitted = true;
      be.txFail = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(wifi.tx_start())\nprint(wifi.tx_info())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 2 && be.logs[0] == "nil\tesp_wifi_80211_tx refused (mock)" &&
            be.logs[1].rfind("nil\tthe injector is not running", 0) == 0);
      be.txFail = false;
      be.logs.clear();
      LuaVm vm2;
      CHECK(vm2.open(128 * 1024));
      registerApi(vm2, be);
      const char* script2 = "print(wifi.tx_start())";
      CHECK(vm2.load("t", script2, strlen(script2)));
      CHECK(run(vm2, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1 && be.logs[0] == "true");
      be.txFail = true;
      be.logs.clear();
      LuaVm vm3;
      CHECK(vm3.open(128 * 1024));
      registerApi(vm3, be);
      const char* script3 = "print(wifi.tx(('d'):rep(26)))";
      CHECK(vm3.load("t", script3, strlen(script3)));
      CHECK(run(vm3, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1 && be.logs[0] == "nil\tthe radio refused the frame (mock)");
    }
  }
  {
    TEST("wifi.monitor_channel: hop while the sniffer or the injector runs, shared channel, validation");
    {
      MockBackend be;
      be.net = true;
      be.monPermitted = true;
      be.txPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(wifi.monitor_channel(6))
        print(wifi.monitor_start{channel = 1})
        print(wifi.monitor_channel(6))
        print(wifi.monitor_info().channel)
        print(wifi.tx_start())
        print(wifi.tx_info().channel)
        print(wifi.monitor_channel(11))
        print(wifi.tx_info().channel)
        print(wifi.monitor_channel(0))
        print(wifi.monitor_channel(14))
        print(wifi.monitor_channel(1.5))
        print(wifi.monitor_channel("6"))
        print((pcall(wifi.monitor_channel)))
        print(wifi.tx_stop())
        print(wifi.monitor_stop())
        print(wifi.monitor_channel(3))
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 200000) == Status::Finished);
      const char* NS = "nil\tno radio mode is running (wifi.monitor_start() or wifi.tx_start() first)";
      const char* C = "nil\tchannel must be an integer 1..13";
      const char* want[] = {NS, "true", "true", "6", "true", "6", "true", "11", C, C, C, C, "true", "true", "0", NS};
      const size_t N = sizeof(want) / sizeof(want[0]);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    hop log[%zu] '%s'\n", i, be.logs[i].c_str());
      CHECK(be.logs.size() == N);
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    hop #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
      CHECK(be.monChannel == 11);  // the last hop wins
    }
    {
      MockBackend be;  // backend failure and the monitor permission gate
      be.net = true;
      be.monPermitted = true;
      be.txPermitted = true;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(wifi.tx_start())\nprint(wifi.monitor_channel(2))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 2 && be.logs[0] == "true" && be.logs[1] == "true");
      be.monSetFail = true;
      be.logs.clear();
      LuaVm vm2;
      CHECK(vm2.open(128 * 1024));
      registerApi(vm2, be);
      const char* script2 = "print(wifi.tx_start())\nprint(wifi.monitor_channel(2))";
      CHECK(vm2.load("t", script2, strlen(script2)));
      CHECK(run(vm2, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 2 && be.logs[1] == "nil\tcould not set the channel (mock)");
      be.monSetFail = false;
      be.monPermitted = false;
      be.logs.clear();
      LuaVm vm3;
      CHECK(vm3.open(128 * 1024));
      registerApi(vm3, be);
      const char* script3 = "print(wifi.tx_start())\nprint(wifi.monitor_channel(2))";
      CHECK(vm3.load("t", script3, strlen(script3)));
      CHECK(run(vm3, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 2 && be.logs[1].rfind("nil\tmonitor not permitted", 0) == 0);
    }
  }
  {
    TEST("system.sleep / system.last_wake: validation, backend handover, wake cause");
    {
      MockBackend be;
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = R"LUA(
        print(system.last_wake())
        print(system.sleep(0))
        print(system.sleep(-5))
        print(system.sleep(1.5))
        print(system.sleep("60"))
        print(system.sleep(604801))
        print((pcall(system.sleep)))
        print(system.sleep(12))
        print("after sleep")
      )LUA";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      const char* C = "nil\tseconds must be an integer 1..604800 (a week)";
      const char* want[] = {"power-on", C, C, C, C, C, "true", "true", "after sleep"};
      const size_t N = sizeof(want) / sizeof(want[0]);
      if (be.logs.size() != N || getenv("DUMP_LOGS"))
        for (size_t i = 0; i < be.logs.size(); i++) printf("    sleep log[%zu] '%s'\n", i, be.logs[i].c_str());
      CHECK(be.logs.size() == N);
      for (size_t i = 0; i < N && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i]) printf("    sleep #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
      }
      CHECK(be.sleepSeconds == 12);
    }
    {
      MockBackend be;  // wake cause variants + backend failure
      be.wakeCauseVal = "timer";
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      const char* script = "print(system.last_wake())";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 1 && be.logs[0] == "timer");
      be.wakeCauseVal = "button";
      be.sleepFail = true;
      be.logs.clear();
      LuaVm vm2;
      CHECK(vm2.open(128 * 1024));
      registerApi(vm2, be);
      const char* script2 = "print(system.last_wake())\nprint(system.sleep(30))";
      CHECK(vm2.load("t", script2, strlen(script2)));
      CHECK(run(vm2, be, 100000) == Status::Finished);
      CHECK(be.logs.size() == 2 && be.logs[0] == "button" && be.logs[1] == "nil\tcould not arm the timer wake (mock)" &&
            be.sleepSeconds == -1);
    }
  }
  {
    TEST("ble: permission/support gates, start validation + radio exclusivity + RAM floor");
    const std::string DENIED =
        "nil\tbluetooth not permitted: add \"permissions\": [\"bluetooth\"] to this app's manifest.json (and approve "
        "it)";
    auto go = [&](MockBackend& be, const char* script) {
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
    };
    auto expect = [&](MockBackend& be, std::vector<std::string> want, const char* tag) {
      if (be.logs.size() != want.size()) {
        printf("    ble %s: %zu logs, want %zu\n", tag, be.logs.size(), want.size());
        for (auto& l : be.logs) printf("      '%s'\n", l.c_str());
      }
      CHECK(be.logs.size() == want.size());
      for (size_t i = 0; i < want.size() && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i])
          printf("    ble %s #%zu got '%s' want '%s'\n", tag, i + 1, be.logs[i].c_str(), want[i].c_str());
      }
    };
    {
      MockBackend be;  // not permitted: every function says so; stop still lets go
      const char* script = R"LUA(
        print(ble.start())
        print(ble.scan())
        print(ble.scan_stop())
        print(ble.devices())
        print(ble.connect("11:22:33:44:55:66"))
        print(ble.disconnect())
        print(ble.state())
        print(ble.paired())
        print(ble.forget("11:22:33:44:55:66"))
        print(ble.stop())
      )LUA";
      go(be, script);
      expect(be, {DENIED, DENIED, DENIED, DENIED, DENIED, DENIED, DENIED, DENIED, DENIED, "true"}, "denied");
      CHECK(be.bleStartCalls == 0 && be.bleStopCalls == 1 && be.bleScanMsLog.empty() && be.bleConnectLog.empty());
    }
    {
      MockBackend be;  // declared but not approved by the user: the same
      be.blePermitted = true;
      be.bleApproved = false;
      go(be, "print(ble.start())");
      expect(be, {DENIED}, "not approved");
    }
    {
      MockBackend be;  // approved without the manifest asking: the same
      be.bleApproved = true;
      go(be, "print(ble.start())");
      expect(be, {DENIED}, "not declared");
    }
    {
      MockBackend be;  // a build without bluetooth: a plain answer, checked BEFORE the permission
      be.bleSupportedVal = false;
      go(be, "print(ble.start())\nprint(ble.state())");
      expect(be, {"nil\tno bluetooth on this device", "nil\tno bluetooth on this device"}, "unsupported");
      CHECK(be.bleStartCalls == 0);
    }
    {
      MockBackend be;  // start: mode validation, the happy path, a second start
      be.blePermitted = true;
      const char* script = R"LUA(
        print(ble.start(5))
        print(ble.start("foo"))
        print(ble.start("keyboard"))
        print(ble.start())
        print(ble.stop())
        print(ble.start())
      )LUA";
      go(be, script);
      const std::string M = "nil\tmode must be \"keyboard\", \"raw\" or \"gatt\"";
      expect(be, {M, M, "true", "nil\tbluetooth is already running (ble.stop() first)", "true", "true"}, "start");
      CHECK(be.bleStartCalls == 2 && be.bleModeStarted == "keyboard" && be.bleUp);
    }
    {
      MockBackend be;  // the radio is exclusive: each WiFi mode refuses the start, and nothing reaches the backend
      be.blePermitted = true;
      MockBackend* b = &be;
      const char* script = "print(ble.start())";
      b->enUp = true;
      go(be, script);
      b->enUp = false;
      b->monUp = true;
      go(be, script);
      b->monUp = false;
      b->txUp = true;
      go(be, script);
      b->txUp = false;
      b->wifiUp = true;
      go(be, script);
      b->wifiUp = false;
      b->apUp = true;
      go(be, script);
      expect(be,
             {"nil\tespnow is running: call espnow.stop() first",
              "nil\tthe WiFi sniffer is running: call wifi.monitor_stop() first",
              "nil\tthe injector is running: call wifi.tx_stop() first",
              "nil\tthe radio is in use by WiFi or the hotspot: call wifi.off() first",
              "nil\tthe radio is in use by WiFi or the hotspot: call wifi.off() first"},
             "exclusive");
      CHECK(be.bleStartCalls == 0 && !be.bleUp);
    }
    {
      MockBackend be;  // RAM floor: 80K cold, 48K once a radio has been started, the boundary itself passes
      be.blePermitted = true;
      be.freeHeapVal = 80 * 1024 - 1;
      go(be, "print(ble.start())");
      be.freeHeapVal = 80 * 1024;
      go(be, "print(ble.start())");
      be.bleUp = false;
      be.freeHeapVal = 48 * 1024 - 1;  // radioEverStarted is now true
      go(be, "print(ble.start())");
      be.freeHeapVal = 48 * 1024;
      go(be, "print(ble.start())");
      expect(be,
             {"nil\tnot enough free RAM for bluetooth (free 79K, need 80K)", "true",
              "nil\tnot enough free RAM for bluetooth (free 47K, need 48K)", "true"},
             "floor");
    }
    {
      MockBackend be;  // the stack refuses: its own message comes back and nothing is left running
      be.blePermitted = true;
      be.bleStartFail = true;
      go(be, "print(ble.start())");
      expect(be, {"nil\tnimble init failed (mock)"}, "start fail");
      CHECK(!be.bleUp);
    }
  }
  {
    TEST("ble: scan validation, devices, connect/disconnect, state, paired/forget, stop");
    auto go = [&](MockBackend& be, const char* script) {
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
    };
    auto expect = [&](MockBackend& be, std::vector<std::string> want, const char* tag) {
      if (be.logs.size() != want.size()) {
        printf("    ble %s: %zu logs, want %zu\n", tag, be.logs.size(), want.size());
        for (auto& l : be.logs) printf("      '%s'\n", l.c_str());
      }
      CHECK(be.logs.size() == want.size());
      for (size_t i = 0; i < want.size() && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i])
          printf("    ble %s #%zu got '%s' want '%s'\n", tag, i + 1, be.logs[i].c_str(), want[i].c_str());
      }
    };
    const std::string NR = "nil\tbluetooth is not running (call ble.start() first)";
    const std::string MS = "nil\tms must be an integer 500..60000";
    {
      MockBackend be;  // scan: needs the stack, validates the duration, default 5000
      be.blePermitted = true;
      const char* script = R"LUA(
        print(ble.scan())
        ble.start()
        print(ble.scan())
        print(ble.scan(1234))
        print(ble.scan(499))
        print(ble.scan(60001))
        print(ble.scan(1000.5))
        print(ble.scan("5000"))
        print(ble.scan(500))
        print(ble.scan(60000))
      )LUA";
      go(be, script);
      expect(be, {NR, "true", "true", MS, MS, MS, MS, "true", "true"}, "scan");
      CHECK(be.bleScanMsLog == (std::vector<int>{5000, 1234, 500, 60000}));
    }
    {
      MockBackend be;  // the stack refuses to scan: its message; scan_stop only reaches a running stack
      be.blePermitted = true;
      be.bleScanFail = true;
      go(be, "print(ble.scan_stop())\nble.start()\nprint(ble.scan())\nprint(ble.scan_stop())");
      expect(be, {"true", "nil\tscan refused (mock)", "true"}, "scan fail");
      CHECK(be.bleScanStops == 1);
    }
    {
      MockBackend be;  // devices: empty before a scan, capped at 24, fields intact
      be.blePermitted = true;
      be.bleSeen.push_back(MockBackend::mkDev("11:22:33:44:55:66", "Keychron K3", -48, true, true));
      be.bleSeen.push_back(MockBackend::mkDev("AA:BB:CC:DD:EE:FF", "Beacon", -80, true, false));
      for (int i = 0; i < 28; i++)
        be.bleSeen.push_back(MockBackend::mkDev("00:00:00:00:00:01", "filler", -90, true, false));
      const char* script = R"LUA(
        print(ble.devices())
        ble.start()
        print(#ble.devices())
        ble.scan()
        local d = ble.devices()
        print(#d)
        print(d[1].addr, d[1].name, d[1].rssi, d[1].connectable, d[1].hid)
        print(d[2].addr, d[2].name, d[2].rssi, d[2].connectable, d[2].hid)
      )LUA";
      go(be, script);
      expect(be,
             {NR, "0", "24", "11:22:33:44:55:66\tKeychron K3\t-48\ttrue\ttrue",
              "AA:BB:CC:DD:EE:FF\tBeacon\t-80\ttrue\tfalse"},
             "devices");
    }
    {
      MockBackend be;  // connect: the address is checked in full before the stack is asked
      be.blePermitted = true;
      const char* script = R"LUA(
        print(ble.connect("11:22:33:44:55:66"))
        ble.start()
        local A = "addr must look like AA:BB:CC:DD:EE:FF"
        print(ble.connect("11:22:33:44:55"))
        print(ble.connect("11-22-33-44-55-66"))
        print(ble.connect("1122.3344.5566.77"))
        print(ble.connect("11:22:33:44:55:6G"))
        print(ble.connect("11:22:33:44:55:66:"))
        print(ble.connect("11:22:33:44:55:66\0"))
        print(ble.connect(""))
        print(ble.connect("aa:bb:cc:dd:ee:ff"))
        print(ble.connect("11:22:33:44:55:66"))
        print((pcall(ble.connect)))
        print(ble.disconnect())
      )LUA";
      go(be, script);
      const std::string A = "nil\taddr must look like AA:BB:CC:DD:EE:FF";
      expect(be, {NR, A, A, A, A, A, A, A, "true", "true", "true", "true"}, "connect");
      CHECK(be.bleConnectLog == (std::vector<std::string>{"aa:bb:cc:dd:ee:ff", "11:22:33:44:55:66"}));
      CHECK(be.bleConnectTypeLog == (std::vector<int>{0, 0}));
      CHECK(be.bleDisconnects == 1);
    }
    {
      MockBackend be;  // a refused connect says why; disconnect with the stack down reaches nothing
      be.blePermitted = true;
      be.bleConnFail = true;
      go(be, "print(ble.disconnect())\nble.start()\nprint(ble.connect(\"11:22:33:44:55:66\"))");
      expect(be, {"true", "nil\tpairing refused (mock)"}, "connect fail");
      CHECK(be.bleDisconnects == 0);
    }
    {
      MockBackend be;  // state: stopped / idle
      be.blePermitted = true;
      const char* script = R"LUA(
        local function show(s) print(s.running, s.link, s.scanning, s.mode, s.addr, s.name, s.passkey, s.reason) end
        show(ble.state())
        ble.start()
        show(ble.state())
      )LUA";
      go(be, script);
      expect(be, {"false\tidle\tfalse\tnil\tnil\tnil\tnil\tnil", "true\tidle\tfalse\tkeyboard\tnil\tnil\tnil\tnil"},
             "state idle");
    }
    {
      MockBackend be;  // connecting with a passkey waiting, connected, failed (reason shown only then)
      be.blePermitted = true;
      be.bleUp = true;
      const char* script = R"LUA(
        local s = ble.state()
        print(s.link, s.addr, s.name, s.passkey, s.reason, s.scanning)
      )LUA";
      be.bleStateVal = {};
      be.bleStateVal.link = crosslua::Backend::BLE_CONNECTING;
      snprintf(be.bleStateVal.addr, sizeof(be.bleStateVal.addr), "11:22:33:44:55:66");
      snprintf(be.bleStateVal.name, sizeof(be.bleStateVal.name), "Keychron K3");
      be.bleStateVal.hasPasskey = true;
      be.bleStateVal.passkey = 123456;
      snprintf(be.bleStateVal.reason, sizeof(be.bleStateVal.reason), "stale reason");
      go(be, script);
      be.bleStateVal.hasPasskey = false;
      be.bleStateVal.passkey = 777;  // ignored without hasPasskey
      be.bleStateVal.link = crosslua::Backend::BLE_CONNECTED;
      be.bleStateVal.scanning = true;
      go(be, script);
      be.bleStateVal.link = crosslua::Backend::BLE_FAILED;
      be.bleStateVal.addr[0] = 0;
      be.bleStateVal.scanning = false;
      snprintf(be.bleStateVal.reason, sizeof(be.bleStateVal.reason), "pairing timed out");
      go(be, script);
      expect(be,
             {"connecting\t11:22:33:44:55:66\tKeychron K3\t123456\tnil\tfalse",
              "connected\t11:22:33:44:55:66\tKeychron K3\tnil\tnil\ttrue",
              "failed\tnil\tnil\tnil\tpairing timed out\tfalse"},
             "state");
    }
    {
      MockBackend be;  // paired / forget
      be.blePermitted = true;
      be.bleBonds.push_back(MockBackend::mkDev("11:22:33:44:55:66", "Keychron K3", 0, true, true));
      be.bleBonds.push_back(MockBackend::mkDev("22:33:44:55:66:77", "Remote", 0, true, true));
      const char* script = R"LUA(
        print(ble.paired())
        print(ble.forget("11:22:33:44:55:66"))
        ble.start()
        local p = ble.paired()
        print(#p, p[1].addr, p[1].name, p[2].addr, p[2].name)
        print(ble.forget("12:34"))
        print(ble.forget("DE:AD:BE:EF:00:01"))
        print(ble.forget("11:22:33:44:55:66"))
        print(#ble.paired())
        print((pcall(ble.forget)))
      )LUA";
      go(be, script);
      expect(be,
             {NR, NR, "2\t11:22:33:44:55:66\tKeychron K3\t22:33:44:55:66:77\tRemote",
              "nil\taddr must look like AA:BB:CC:DD:EE:FF", "nil\tthat device is not paired", "true", "1", "false"},
             "paired");
    }
    {
      MockBackend be;  // stop gives the stack back; calling it twice is harmless
      be.blePermitted = true;
      go(be, "ble.start()\nprint(ble.stop())\nprint(ble.stop())\nprint(ble.state().running)");
      expect(be, {"true", "true", "false"}, "stop");
      CHECK(!be.bleUp && be.bleStopCalls == 2);
    }
  }
  {
    TEST("input.key: key events carry the character / special key / modifiers; other events carry none");
    MockBackend be;
    be.pushKey('a', 0, 0x02, 0x04);  // left shift + a
    be.events.push_back("confirm");  // a button between the keys
    be.pushKey(0, 1, 0, 0x28);       // enter
    be.pushKey(0, 13, 0x14, 0x4E);   // page down with right ctrl + left alt
    be.pushKey(0, 200, 0, 0x99);     // a special index this firmware does not know: no `key` field
    for (uint8_t m : {0x01, 0x10, 0x02, 0x20, 0x04, 0x40, 0x08, 0x80}) be.pushKey('x', 0, m, 0x1B);
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      print(input.key())
      for i = 1, 5 do
        local e = input.poll()
        local k = input.key()
        if k then print(e, k.char, k.key, k.code, k.ctrl, k.shift, k.alt, k.gui) else print(e, "nokey") end
      end
      for i = 1, 8 do
        input.poll()
        local k = input.key()
        print((k.ctrl and "c" or "-") .. (k.shift and "s" or "-") .. (k.alt and "a" or "-") .. (k.gui and "g" or "-"))
      end
      print(input.poll(), input.key())
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 100000) == Status::Finished);
    const char* want[] = {"nil",
                          "key\ta\tnil\t4\tfalse\ttrue\tfalse\tfalse",
                          "confirm\tnokey",
                          "key\tnil\tenter\t40\tfalse\tfalse\tfalse\tfalse",
                          "key\tnil\tpagedown\t78\ttrue\tfalse\ttrue\tfalse",
                          "key\tnil\tnil\t153\tfalse\tfalse\tfalse\tfalse",
                          "c---",
                          "c---",
                          "-s--",
                          "-s--",
                          "--a-",
                          "--a-",
                          "---g",
                          "---g",
                          "nil\tnil"};
    const size_t N = sizeof(want) / sizeof(want[0]);
    if (be.logs.size() != N)
      for (auto& l : be.logs) printf("    key log '%s'\n", l.c_str());
    CHECK(be.logs.size() == N);
    for (size_t i = 0; i < N && i < be.logs.size(); i++) {
      CHECK(be.logs[i] == want[i]);
      if (be.logs[i] != want[i]) printf("    key #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
    }
  }
  {
    TEST("ble: every WiFi mode refuses to start while bluetooth is running");
    MockBackend be;
    be.blePermitted = true;
    be.hotspotPermitted = true;
    be.enPermitted = true;
    be.monPermitted = true;
    be.txPermitted = true;
    LuaVm vm;
    CHECK(vm.open(128 * 1024));
    registerApi(vm, be);
    const char* script = R"LUA(
      ble.start()
      print(wifi.connect())
      print(wifi.softap("host-ap"))
      print(wifi.scan())
      print(espnow.start())
      print(wifi.monitor_start())
      print(wifi.tx_start())
      print(ble.stop())
      print(wifi.scan() ~= nil)
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 100000) == Status::Finished);
    const char* want[] = {"false\tbluetooth is running: call ble.stop() before joining WiFi",
                          "false\tbluetooth is running: call ble.stop() before starting a hotspot",
                          "nil\tbluetooth is running: call ble.stop() first",
                          "nil\tbluetooth is running: call ble.stop() first",
                          "nil\tbluetooth is running: call ble.stop() first",
                          "nil\tbluetooth is running: call ble.stop() first",
                          "true",
                          "true"};
    const size_t N = sizeof(want) / sizeof(want[0]);
    if (be.logs.size() != N)
      for (auto& l : be.logs) printf("    wifi-side log '%s'\n", l.c_str());
    CHECK(be.logs.size() == N);
    for (size_t i = 0; i < N && i < be.logs.size(); i++) {
      CHECK(be.logs[i] == want[i]);
      if (be.logs[i] != want[i]) printf("    wifi-side #%zu got '%s' want '%s'\n", i + 1, be.logs[i].c_str(), want[i]);
    }
    CHECK(!be.apUp && !be.enUp && !be.monUp && !be.txUp && !be.wifiUp);
  }
  {
    TEST(
        "crypto.device_key: per-app per-label HMAC of the device secret (vectors from python hmac), validation, no "
        "secret = clean error");
    auto go = [&](MockBackend& be, const char* script) {
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
    };
    auto expect = [&](MockBackend& be, std::vector<std::string> want, const char* tag) {
      if (be.logs.size() != want.size()) {
        printf("    devkey %s: %zu logs, want %zu\n", tag, be.logs.size(), want.size());
        for (auto& l : be.logs) printf("      '%s'\n", l.c_str());
      }
      CHECK(be.logs.size() == want.size());
      for (size_t i = 0; i < want.size() && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i])
          printf("    devkey %s #%zu got '%s' want '%s'\n", tag, i + 1, be.logs[i].c_str(), want[i].c_str());
      }
    };
    const std::string V_TEST_VAULT =
        "c08ad8310a9ea74608eab2b302a362638dc2c614014ecc5fe68cc371102d547b";  // hmac(secret=00..1f,
                                                                             // "crosslua-device-key:v1\0test\0vault")
    const std::string V_TEST_OTHER = "323a2c241e4433cb50bc7cf2611d7c1eee357d65148fac55cd7a218ec657b514";
    const std::string V_NOTES_VAULT =
        "122c871a70f675c58e0a4808e46f0db25324015248f7ace702da550783dfadc6";  // app "Notes_Lua" is lower-cased
    const std::string V_OTHERAPP_VAULT = "5deed0b4c3793805b7bc455ed3b2532bb56a617e1ef326c7b9a42f0fd01ca53e";
    {
      MockBackend be;
      const char* script = R"LUA(
        print(crypto.hex(crypto.device_key("vault")))
        print(crypto.hex(crypto.device_key("other")))
        print(#crypto.device_key("vault"))
        print(crypto.device_key("vault") == crypto.device_key("vault"))
        print(crypto.device_key("vault") == crypto.device_key("other"))
      )LUA";
      go(be, script);
      expect(be, {V_TEST_VAULT, V_TEST_OTHER, "32", "true", "false"}, "vectors");
    }
    {
      MockBackend be;  // the app name is part of the key and is case-folded (FAT ignores case)
      be.appNameVal = "Notes_Lua";
      go(be, "print(crypto.hex(crypto.device_key(\"vault\")))");
      be.appNameVal = "notes_lua";
      go(be, "print(crypto.hex(crypto.device_key(\"vault\")))");
      be.appNameVal = "other";
      go(be, "print(crypto.hex(crypto.device_key(\"vault\")))");
      expect(be, {V_NOTES_VAULT, V_NOTES_VAULT, V_OTHERAPP_VAULT}, "app name");
    }
    {
      MockBackend
          be;  // a different device secret gives a different key (a card copied to another device cannot derive it)
      be.secretBytes[0] ^= 1;
      go(be, "print(crypto.hex(crypto.device_key(\"vault\")))");
      CHECK(be.logs.size() == 1 && be.logs[0] != V_TEST_VAULT && be.logs[0].size() == 64);
    }
    {
      MockBackend be;  // label validation
      const char* script = R"LUA(
        local E = "label must be 1..64 bytes without NUL"
        local k, e = crypto.device_key("")
        print(k, e)
        k, e = crypto.device_key(("x"):rep(65))
        print(k, e)
        print(#crypto.device_key(("x"):rep(64)))
        print(#crypto.device_key("a"))
        k, e = crypto.device_key("a\0b")
        print(k, e)
        print((pcall(crypto.device_key)))
        print((pcall(crypto.device_key, {})))
      )LUA";
      go(be, script);
      const std::string E = "nil\tlabel must be 1..64 bytes without NUL";
      expect(be, {E, E, "32", "32", E, "false", "false"}, "label");
    }
    {
      MockBackend be;  // no device secret: a clean error, never a key derived from zeros
      be.secretOk = false;
      go(be, "print(crypto.device_key(\"vault\"))");
      expect(be, {"nil\tno device secret available (the key storage could not be read)"}, "no secret");
    }
    {
      MockBackend be;  // an unusable app name
      be.appNameVal = std::string(101, 'a');
      go(be, "print(crypto.device_key(\"vault\"))");
      be.appNameVal = std::string(100, 'a');
      go(be, "print(#crypto.device_key(\"vault\"))");
      be.appNameVal = "";
      go(be, "print(crypto.device_key(\"vault\"))");
      expect(be,
             {"nil\tthis app's folder name is too long to derive a key from", "32",
              "nil\tthis app's folder name is too long to derive a key from"},
             "app name length");
    }
  }
  {
    TEST(
        "vault.lua: matches an independent implementation (python hmac/pbkdf2 + openssl AES), roundtrip, PIN change, "
        "validation, tampering, device binding");
    // python: dk = hmac(secret 00..1f, "crosslua-device-key:v1\0test\0vault-v1"); pre = hmac(dk,
    // "1234"); master = pbkdf2(pre, salt a0..af, 1000, 32); enc/mac = hmac(master,
    // "vault-enc\1"/"vault-mac\1"); AES-256-CBC (openssl) over "hello vault\n"*3; HMAC over
    // header+ciphertext.
    const std::string HEX =
        "58564c5401000003e8a0a1a2a3a4a5a6a7a8a9aaabacadaeafc0c1c2c3c4c5c6c7c8c9cacbcccdcecfa67e0b8c8c6eb4e897edd3aa08f1"
        "a6c33426e692fac06a50271cc718"
        "3ca42ca02936bc7bc0a6bf8680ba8501918a7dbcdbbb253d0274c99c0f3a76fdec6a2c591bbfcae528508018fe1ccc5291ae1a8c";
    auto go = [&](MockBackend& be, const std::string& script) {
      loadApp(be, "totp_lua");  // /plugins/test/vault.lua
      LuaVm vm;
      CHECK(vm.open(768 * 1024));
      registerApi(vm, be);
      CHECK(vm.load("t", script.data(), script.size()));
      CHECK(run(vm, be, 2000000) == Status::Finished);
    };
    auto expect = [&](MockBackend& be, std::vector<std::string> want, const char* tag) {
      if (be.logs.size() != want.size()) {
        printf("    vault %s: %zu logs, want %zu\n", tag, be.logs.size(), want.size());
        for (auto& l : be.logs) printf("      '%s'\n", l.c_str());
      }
      CHECK(be.logs.size() == want.size());
      for (size_t i = 0; i < want.size() && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i])
          printf("    vault %s #%zu got '%s' want '%s'\n", tag, i + 1, be.logs[i].c_str(), want[i].c_str());
      }
    };
    const std::string BAD = "nil\twrong PIN or damaged vault";
    const std::string PINMSG = "nil\tthe PIN must be 4..64 characters";
    const std::string ITER = "nil\titerations must be 1000..20000";
    {
      MockBackend
          be;  // reference vector: byte-identical to the independent implementation, and the python-made file opens
      go(be, "local EXPECTED = '" + HEX + R"LUA('
        local vault = require("vault")
        local salt = crypto.unhex("a0a1a2a3a4a5a6a7a8a9aaabacadaeaf")
        local iv = crypto.unhex("c0c1c2c3c4c5c6c7c8c9cacbcccdcecf")
        local pt = ("hello vault\n"):rep(3)
        print(crypto.hex(vault._seal_for_test("1234", salt, iv, 1000, pt)) == EXPECTED)
        fs.write("data:ref.bin", crypto.unhex(EXPECTED))
        local v, e = vault.unlock("data:ref.bin", "1234")
        print(v and v.data == pt, e)
        print(vault.unlock("data:ref.bin", "1235"))
        print(vault.unlock("data:ref.bin", 1234))
      )LUA");
      expect(be, {"true", "true\tnil", BAD, BAD}, "reference");
    }
    {
      MockBackend be;  // roundtrip: fresh IV per save (same salt), new salt on a PIN change, the old PIN stops working,
                       // lock() is final
      go(be, R"LUA(
        local vault = require("vault")
        local v, e = vault.create("data:v.bin", "4321", "secret one", 1000)
        print(v ~= nil, e)
        local blob1 = fs.read("data:v.bin")
        print(#blob1 == 41 + 16 + 32, blob1:sub(1, 4))  -- header + one padded AES block + mac
        local v2 = vault.create("data:v2.bin", "4321", "secret one", 1000)  -- same PIN and text: salt and IV still differ
        local b2 = fs.read("data:v2.bin")
        print(b2:sub(10, 25) ~= blob1:sub(10, 25), b2:sub(26, 41) ~= blob1:sub(26, 41))
        v.data = "secret two"
        print(v:save())
        local blob2 = fs.read("data:v.bin")
        print(blob1:sub(10, 25) == blob2:sub(10, 25), blob1:sub(26, 41) ~= blob2:sub(26, 41))
        local u = vault.unlock("data:v.bin", "4321")
        print(u.data)
        print(u:change_pin("12"))
        print(vault.unlock("data:v.bin", "4321") ~= nil)
        print(u:change_pin("9876"))
        local blob3 = fs.read("data:v.bin")
        print(blob3:sub(10, 25) ~= blob2:sub(10, 25))
        print(vault.unlock("data:v.bin", "4321"))
        local w = vault.unlock("data:v.bin", "9876")
        print(w.data)
        print(w:lock(), w:is_locked(), w.data, w:save(), w:change_pin("1111"))
        print(w:save())
        print(vault.create("data:v.bin", "4321", "x", 1000))
        print(vault.exists("data:v.bin"), vault.exists("data:none.bin"))
      )LUA");
      expect(be,
             {"true\tnil", "true\tXVLT", "true\ttrue", "true", "true\ttrue", "secret two", PINMSG, "true", "true",
              "true", BAD, "secret two", "true\ttrue\tnil\tnil\tnil\tthe vault is locked", "nil\tthe vault is locked",
              "nil\ta vault already exists there", "true\tfalse"},
             "roundtrip");
    }
    {
      MockBackend be;  // argument validation and the shapes of unreadable files
      go(be, R"LUA(
        local vault = require("vault")
        print(vault.create("data:a.bin", "123", "x", 1000))
        print(vault.create("data:a.bin", ("p"):rep(65), "x", 1000))
        print(vault.create("data:a.bin", 1234, "x", 1000))
        print(vault.create("data:a.bin", "1234", "x", 999))
        print(vault.create("data:a.bin", "1234", "x", 20001))
        print(vault.create("data:a.bin", "1234", "x", 1500.5))
        print(vault.create("data:a.bin", "1234", ("x"):rep(24 * 1024 + 1), 1000))
        print(vault.exists("data:a.bin"))
        local ok = vault.create("data:a.bin", ("p"):rep(64), ("x"):rep(24 * 1024), 1000)
        print(ok ~= nil)
        local ok2 = vault.create("data:b.bin", "1234", "", 1000)
        print(ok2 ~= nil, ok2.data == "")
        print(vault.unlock("data:missing.bin", "1234"))
        fs.write("data:junk.bin", "short")
        print(vault.unlock("data:junk.bin", "1234"))
      )LUA");
      expect(be,
             {PINMSG, PINMSG, PINMSG, ITER, ITER, ITER, "nil\tthe vault holds at most 24 KB", "false", "true",
              "true\ttrue", "nil\tno vault", "nil\tnot a vault file"},
             "validation");
    }
    {
      MockBackend be;  // tampering: every byte of the file is authenticated, the header checks run before any key work
      go(be, "local EXPECTED = '" + HEX + R"LUA('
        local vault = require("vault")
        local good = crypto.unhex(EXPECTED)
        local function try(name, bytes) fs.write("data:" .. name, bytes); return vault.unlock("data:" .. name, "1234") end
        local function flip(s, i) return s:sub(1, i - 1) .. string.char(s:byte(i) ~ 1) .. s:sub(i + 1) end
        print((try("ok.bin", good)) ~= nil)
        print(try("mac.bin", flip(good, #good)))
        print(try("ct.bin", flip(good, 45)))
        print(try("salt.bin", flip(good, 12)))
        print(try("iv.bin", flip(good, 30)))
        print(try("iter.bin", good:sub(1, 5) .. string.pack(">I4", 1001) .. good:sub(10)))
        print(try("trunc.bin", good:sub(1, #good - 1)))
        print(try("magic.bin", flip(good, 1)))
        print(try("ver.bin", good:sub(1, 4) .. "\2" .. good:sub(6)))
        print(try("iterlo.bin", good:sub(1, 5) .. string.pack(">I4", 999) .. good:sub(10)))
        print(try("iterhi.bin", good:sub(1, 5) .. string.pack(">I4", 20001) .. good:sub(10)))
        print(try("short.bin", good:sub(1, 88)))
      )LUA");
      expect(be,
             {"true", BAD, BAD, BAD, BAD, BAD, BAD, "nil\tnot a vault file", "nil\tunsupported vault version",
              "nil\tunsupported vault settings", "nil\tunsupported vault settings", "nil\tnot a vault file"},
             "tamper");
    }
    {
      MockBackend
          be;  // device binding: the same file under another device secret does not open; no secret is an honest error
      go(be, "local vault = require('vault'); print(vault.create('data:d.bin', '4321', 'bound', 1000) ~= nil)");
      be.secretBytes[0] ^= 1;
      go(be, "local vault = require('vault'); print(vault.unlock('data:d.bin', '4321'))");
      be.secretBytes[0] ^= 1;
      go(be, "local vault = require('vault'); local v = vault.unlock('data:d.bin', '4321'); print(v and v.data)");
      be.secretOk = false;
      go(be,
         "local vault = require('vault'); print(vault.unlock('data:d.bin', '4321'))\nprint(vault.create('data:e.bin', "
         "'4321', 'x', 1000))");
      const std::string NOSEC = "nil\tno device secret available (the key storage could not be read)";
      expect(be, {"true", BAD, "bound", NOSEC, NOSEC}, "device binding");
    }
  }
  {
    TEST(
        "totp.lua: RFC 6238 vectors + python-generated codes (digits/period/SHA1/SHA256), base32, validation, "
        "otpauth:// parsing");
    auto go = [&](MockBackend& be, const std::string& script) {
      loadApp(be, "totp_lua");
      LuaVm vm;
      CHECK(vm.open(512 * 1024));
      registerApi(vm, be);
      CHECK(vm.load("t", script.data(), script.size()));
      CHECK(run(vm, be, 2000000) == Status::Finished);
    };
    auto expect = [&](MockBackend& be, std::vector<std::string> want, const char* tag) {
      if (be.logs.size() != want.size()) {
        printf("    totp %s: %zu logs, want %zu\n", tag, be.logs.size(), want.size());
        for (auto& l : be.logs) printf("      '%s'\n", l.c_str());
      }
      CHECK(be.logs.size() == want.size());
      for (size_t i = 0; i < want.size() && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i])
          printf("    totp %s #%zu got '%s' want '%s'\n", tag, i + 1, be.logs[i].c_str(), want[i].c_str());
      }
    };
    {
      MockBackend be;  // RFC 6238 appendix B (8 digits; the 20000000000 row needs a 64-bit time, so it is not used)
      go(be, R"LUA(
        local totp = require("totp")
        local s1, s256 = "12345678901234567890", "12345678901234567890123456789012"
        for _, t in ipairs{59, 1111111109, 1111111111, 1234567890, 2000000000} do
          print(t, totp.code(s1, t, {digits = 8}), totp.code(s256, t, {digits = 8, alg = "SHA256"}))
        end
      )LUA");
      expect(be,
             {"59\t94287082\t46119246", "1111111109\t07081804\t68084774", "1111111111\t14050471\t67062674",
              "1234567890\t89005924\t91819424", "2000000000\t69279037\t90698825"},
             "rfc");
    }
    {
      MockBackend be;  // codes from an independent python implementation (hmac + struct), incl. a leading zero and a 45
                       // s period
      go(be, R"LUA(
        local totp = require("totp")
        local sec = totp.b32decode("JBSWY3DPEHPK3PXP")
        print(crypto.hex(sec))
        print(totp.code(sec, 1700000000))
        for _, c in ipairs{{6, 30, "SHA1"}, {7, 30, "SHA1"}, {8, 30, "SHA1"}, {6, 60, "SHA1"}, {6, 30, "SHA256"}, {8, 45, "SHA256"}} do
          local o = {digits = c[1], period = c[2], alg = c[3]}
          print(c[1], c[2], c[3], totp.code(sec, 1700000000, o), totp.code(sec, 1700000029, o), totp.code(sec, 1700000030, o))
        end
      )LUA");
      expect(be,
             {"48656c6c6f21deadbeef", "324550", "6\t30\tSHA1\t324550\t367665\t367665",
              "7\t30\tSHA1\t2324550\t2367665\t2367665", "8\t30\tSHA1\t02324550\t02367665\t02367665",
              "6\t60\tSHA1\t508648\t508648\t508648", "6\t30\tSHA256\t049486\t315597\t315597",
              "8\t45\tSHA256\t64158300\t59961940\t59961940"},
             "python");
    }
    {
      MockBackend be;  // base32: case, separators, padding, bad input
      go(be, R"LUA(
        local totp = require("totp")
        print(crypto.hex(totp.b32decode("jbsw y3dp-ehpk 3pxp")))
        print(totp.b32decode("MZXW6==="), totp.b32decode("MZXW6"))
        print(totp.b32decode("MZXW6YQ="))
        print(totp.b32decode("A"))
        print(totp.b32decode("AB1D"))
        print(totp.b32decode(""))
        print(totp.b32decode("===="))
        print(totp.b32decode(5))
      )LUA");
      expect(be,
             {"48656c6c6f21deadbeef", "foo\tfoo", "foob", "nil\tnot base32", "nil\tnot base32", "nil\tempty secret",
              "nil\tempty secret", "nil\tnot base32"},
             "base32");
    }
    {
      MockBackend be;  // code() validation and remaining()
      go(be, R"LUA(
        local totp = require("totp")
        local s = "12345678901234567890"
        print(totp.code(s, 59, {digits = 5}))
        print(totp.code(s, 59, {digits = 9}))
        print(totp.code(s, 59, {period = 0}))
        print(totp.code(s, 59, {period = 301}))
        print(totp.code(s, 59, {period = 30.5}))
        print(totp.code(s, 59, {alg = "SHA512"}))
        print(totp.code(s, -1))
        print(totp.code(s, 59.5))
        print(totp.code("", 59))
        print(totp.code(5, 59))
        print(totp.code(s, 59, {alg = "sha256"}) ~= nil)
        print(totp.code(s, 59, {period = 300}) ~= nil, totp.code(s, 59, {period = 1}) ~= nil)
        print(totp.remaining(1700000000, 30), totp.remaining(60, 30), totp.remaining(59, 30), totp.remaining(7), totp.remaining(10, 45))
      )LUA");
      const std::string D = "nil\tdigits must be 6, 7 or 8", P = "nil\tperiod must be 1..300 seconds",
                        T = "nil\ttime must be a non-negative integer";
      expect(be,
             {D, D, P, P, P, "nil\tunsupported algorithm (SHA1 and SHA256 only)", T, T, "nil\tempty secret",
              "nil\tempty secret", "true", "true\ttrue", "10\t30\t1\t23\t35"},
             "validation");
    }
    {
      MockBackend be;  // otpauth:// links
      go(be, R"LUA(
        local totp = require("totp")
        local function show(u)
          local r, e = totp.parse_uri(u)
          if r then print(r.name, r.issuer, r.secret, r.digits, r.period, r.alg) else print(nil, e) end
        end
        show("otpauth://totp/Example%3Aalice%40example.com?secret=jbsw%20y3dp-ehpk-3pxp&issuer=Example&algorithm=sha256&digits=8&period=45")
        show("otpauth://totp/GitHub:bob?secret=JBSWY3DPEHPK3PXP")
        show("otpauth://totp/plainlabel?secret=JBSWY3DPEHPK3PXP&issuer=Acme+Corp")
        show("otpauth://totp/Old:me?secret=JBSWY3DPEHPK3PXP&issuer=New")
        show("  otpauth://totp/x?secret=JBSWY3DPEHPK3PXP\n")
        show("otpauth://totp/?secret=JBSWY3DPEHPK3PXP&issuer=Zed")
        show("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP")
        show("otpauth://totp/x?issuer=Zed")
        show("otpauth://totp/x?secret=0189")
        show("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&digits=5")
        show("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&period=500")
        show("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&algorithm=SHA512")
        show(42)
      )LUA");
      expect(
          be,
          {"alice@example.com\tExample\tJBSWY3DPEHPK3PXP\t8\t45\tSHA256", "bob\tGitHub\tJBSWY3DPEHPK3PXP\t6\t30\tSHA1",
           "plainlabel\tAcme Corp\tJBSWY3DPEHPK3PXP\t6\t30\tSHA1", "me\tNew\tJBSWY3DPEHPK3PXP\t6\t30\tSHA1",
           "x\t\tJBSWY3DPEHPK3PXP\t6\t30\tSHA1", "Zed\tZed\tJBSWY3DPEHPK3PXP\t6\t30\tSHA1",
           "nil\tnot an otpauth://totp/ link", "nil\tno secret in the link", "nil\tnot base32",
           "nil\tdigits must be 6, 7 or 8", "nil\tperiod must be 1..300 seconds",
           "nil\tunsupported algorithm (SHA1 and SHA256 only)", "nil\tnot an otpauth://totp/ link"},
          "uri");
    }
  }
  {
    TEST(
        "totp_lua app: digit-wheel PIN, setup, wrong PIN, add, import, delete, change PIN, lock, idle lock, no clock "
        "(the real main.lua, scripted keys and typed text)");
    struct Drive {
      std::vector<std::string> titles;
      std::vector<int> modes;
      bool finished = false;
      size_t textsLeft = 0, eventsLeft = 0;
    };
    // keys that enter a numeric PIN on the wheel: up x digit, right to lock it in, confirm after
    // the last one
    auto PIN = [](const std::string& d) {
      std::vector<std::string> k;
      for (size_t i = 0; i < d.size(); i++) {
        for (int j = 0; j < d[i] - '0'; j++) k.push_back("up");
        k.push_back(i + 1 < d.size() ? "right" : "confirm");
      }
      return k;
    };
    auto KEYS = [](std::initializer_list<std::vector<std::string>> parts) {
      std::deque<std::string> out;
      for (auto& p : parts)
        for (auto& e : p) out.push_back(e);
      return out;
    };
    // an "@ms" token waits (on the mock clock, through the app's own timeouts) until ms have
    // passed; a screen that waits for a key with no timeout drops the token, like a user who
    // walks away and comes back
    auto drive = [&](MockBackend& be, std::deque<std::string> texts, std::deque<std::string> keys) {
      Drive d;
      std::string src = loadApp(be, "totp_lua");
      be.calls.clear();
      be.exitReq = false;
      be.now = 0;  // every run starts at the same instant: the clock is 20 s into a 30 s window
      be.events = keys;
      LuaVm vm;
      CHECK(vm.open(768 * 1024));
      registerApi(vm, be);
      CHECK(vm.load("totp", src.data(), src.size()));
      for (int i = 0; i < 20000; i++) {
        Status s = vm.status();
        if (s == Status::Error) {
          printf("  [lua error] %s\n", vm.error().c_str());
          break;
        }
        if (s == Status::Finished || be.exitReq) {
          d.finished = true;
          break;
        }
        if (s == Status::Waiting) {
          if (be.textAsked) {
            be.textAsked = false;
            d.titles.push_back(be.textTitle);
            d.modes.push_back(be.textMode);
            if (texts.empty()) {
              vm.resume("text:cancel");
            } else {
              std::string r = "text:ok:" + texts.front();
              texts.pop_front();
              vm.resume(r.c_str());
            }
          } else if (!be.events.empty() && be.events.front()[0] == '@') {
            const uint32_t target = static_cast<uint32_t>(std::stoul(be.events.front().substr(1)));
            if (be.now < target && vm.timeoutMs() >= 0) {
              be.now += static_cast<uint32_t>(vm.timeoutMs());
              vm.resume(nullptr);
            } else
              be.events.pop_front();
          } else if (vm.wakesOnEvent() && !be.events.empty()) {
            std::string e = be.events.front();
            be.events.pop_front();
            vm.resume(e.c_str());
          } else if (vm.timeoutMs() >= 0) {
            be.now += static_cast<uint32_t>(vm.timeoutMs());
            vm.resume(nullptr);
          } else
            break;  // would wait forever
        } else
          vm.resume();
      }
      d.textsLeft = texts.size();
      d.eventsLeft = be.events.size();
      return d;
    };
    auto shown = [&](MockBackend& be, const std::string& s) {
      for (auto& c : be.calls)
        if (c.find(s) != std::string::npos) return true;
      return false;
    };
    auto lastAt = [&](MockBackend& be, const std::string& s) {
      for (int i = static_cast<int>(be.calls.size()) - 1; i >= 0; i--)
        if (be.calls[i].find(s) != std::string::npos) return i;
      return -1;
    };
    auto lua = [&](MockBackend& be, const std::string& script) {
      loadApp(be, "totp_lua");
      be.logs.clear();
      be.exitReq = false;  // the previous app run ended with app.exit()
      LuaVm vm;
      CHECK(vm.open(512 * 1024));
      registerApi(vm, be);
      CHECK(vm.load("t", script.data(), script.size()));
      CHECK(run(vm, be, 2000000) == Status::Finished);
    };
    auto vec = [](std::vector<std::string> v) { return v; };
    MockBackend be;
    be.epoch = 1700000000;  // clock: 20 s into a 30 s window (python: 324550 now, 367665 after the boundary)
    {
      // A. first start: intro, PIN twice on the wheel, add one account by typing
      Drive d = drive(be, {"GitHub", "", "JBSWY3DPEHPK3PXP"},
                      KEYS({{"confirm"}, PIN("1234"), PIN("1234"), {"confirm", "confirm", "confirm", "back"}}));
      CHECK(d.finished && d.textsLeft == 0 && d.eventsLeft == 0);
      CHECK(d.titles == vec({"Account name", "Issuer (optional)", "Secret (base32)"}) && d.modes[0] == 0);
      CHECK(shown(be, ":GitHub:") && shown(be, ":324 550:") && shown(be, ":10 s:"));
      lua(be,
          "local vault = require('vault'); local v = vault.unlock('data:vault.bin', '1234'); local db = "
          "json.decode(v.data); print(#db.accounts, db.accounts[1].name, db.accounts[1].secret, db.accounts[1].digits, "
          "db.accounts[1].period, db.accounts[1].alg)");
      CHECK(be.logs.size() == 1 && be.logs[0] == "1\tGitHub\tJBSWY3DPEHPK3PXP\t6\t30\tSHA1");
    }
    {
      // B. next start: wrong PIN, message, right PIN, the list shows the account
      Drive d = drive(be, {}, KEYS({PIN("0000"), {"confirm"}, PIN("1234"), {"back"}}));
      CHECK(d.finished && d.textsLeft == 0 && d.eventsLeft == 0 && d.titles.empty());
      CHECK(shown(be, "Wrong PIN") && shown(be, ":GitHub:"));
      CHECK(shown(be, "Spin each digit") && shown(be, ":*:"));  // the wheel was drawn and locked digits are masked
    }
    {
      // C. back on the wheel leaves the app; left on the first digit offers the keyboard (a
      // passphrase is the same string)
      Drive c = drive(be, {}, {"back"});
      CHECK(c.finished && c.eventsLeft == 0 && !shown(be, ":GitHub:"));
      Drive k = drive(be, {"1234"}, {"left", "back"});
      CHECK(k.finished && k.eventsLeft == 0 && k.titles == vec({"Enter PIN (passphrase)"}) && k.modes[0] == 1 &&
            shown(be, ":GitHub:"));
    }
    {
      // D. import: two bad lines are skipped, the file is deleted, the account is stored
      lua(be,
          "fs.write('data:import.txt', 'otpauth://totp/Acme:bob?secret=JBSWY3DPEHPK3PXP&issuer=Acme\\nhello\\n  "
          "\t\\notpauth://hotp/x?secret=JBSWY3DPEHPK3PXP\\n')");
      Drive d = drive(be, {}, KEYS({PIN("1234"), {"confirm", "down", "confirm", "confirm", "back"}}));
      CHECK(d.finished && d.eventsLeft == 0);
      CHECK(shown(be, ":Added 1, skipped 2.:") && shown(be, ":import.txt was deleted from the card.:"));
      lua(be,
          "print(fs.exists('data:import.txt')); local vault = require('vault'); local db = "
          "json.decode(vault.unlock('data:vault.bin', '1234').data); print(#db.accounts, db.accounts[2].name, "
          "db.accounts[2].issuer)");
      CHECK(be.logs.size() == 2 && be.logs[0] == "false" && be.logs[1] == "2\tbob\tAcme");
      // importing again with no file explains where to put it; importing the same
      // link again adds nothing
      Drive d2 = drive(be, {}, KEYS({PIN("1234"), {"confirm", "down", "confirm", "confirm", "back"}}));
      CHECK(d2.finished && d2.eventsLeft == 0 && shown(be, "import.txt"));
      lua(be, "fs.write('data:import.txt', 'otpauth://totp/Acme:bob?secret=JBSWY3DPEHPK3PXP&issuer=Acme\\n')");
      Drive d3 = drive(be, {}, KEYS({PIN("1234"), {"confirm", "down", "confirm", "confirm", "back"}}));
      CHECK(d3.finished && d3.eventsLeft == 0 && shown(be, ":Added 0, skipped 1.:"));
    }
    {
      // E. delete: "Keep it" changes nothing, "Delete it" removes the selected account (the last
      // row, however often down is pressed)
      Drive keep = drive(be, {}, KEYS({PIN("1234"), {"confirm", "down", "down", "confirm", "confirm", "back"}}));
      CHECK(keep.finished && keep.eventsLeft == 0);
      lua(be,
          "local vault = require('vault'); print(#json.decode(vault.unlock('data:vault.bin', '1234').data).accounts)");
      CHECK(be.logs.size() == 1 && be.logs[0] == "2");
      Drive del =
          drive(be, {},
                KEYS({PIN("1234"),
                      {"down", "down", "down", "confirm", "down", "down", "confirm", "down", "confirm", "back"}}));
      CHECK(del.finished && del.eventsLeft == 0);
      lua(be,
          "local vault = require('vault'); local db = json.decode(vault.unlock('data:vault.bin', '1234').data); "
          "print(#db.accounts, db.accounts[1].name)");
      CHECK(be.logs.size() == 1 && be.logs[0] == "1\tGitHub");
    }
    {
      // F. change PIN: a short passphrase and a mismatch are refused (vault unchanged), then it
      // works and the old PIN stops working
      const std::vector<std::string> TO_CHANGE = {"confirm", "down", "down", "down", "confirm"};
      Drive d1 = drive(be, {"12"}, KEYS({PIN("1234"), TO_CHANGE, {"left", "confirm", "back"}}));
      CHECK(d1.finished && d1.eventsLeft == 0 && d1.titles == vec({"New PIN (passphrase)"}) &&
            shown(be, "PIN too short"));
      Drive d2 = drive(be, {}, KEYS({PIN("1234"), TO_CHANGE, PIN("5678"), PIN("5679"), {"confirm", "back"}}));
      CHECK(d2.finished && d2.eventsLeft == 0 && shown(be, "PINs differ"));
      lua(be, "local vault = require('vault'); print(vault.unlock('data:vault.bin', '1234') ~= nil)");
      CHECK(be.logs.size() == 1 && be.logs[0] == "true");
      Drive d3 = drive(be, {}, KEYS({PIN("1234"), TO_CHANGE, PIN("5678"), PIN("5678"), {"confirm", "back"}}));
      CHECK(d3.finished && d3.eventsLeft == 0 && shown(be, "PIN changed"));
      lua(be,
          "local vault = require('vault'); print(vault.unlock('data:vault.bin', '1234')); local v = "
          "vault.unlock('data:vault.bin', '5678'); print(#json.decode(v.data).accounts)");
      CHECK(be.logs.size() == 2 && be.logs[0] == "nil\twrong PIN or damaged vault" && be.logs[1] == "1");
    }
    {
      // G. "Lock now" asks for the PIN again; H. an idle app locks itself after two minutes
      // and the code changes at the window boundary
      Drive g = drive(
          be, {}, KEYS({PIN("5678"), {"confirm", "down", "down", "down", "down", "confirm"}, PIN("5678"), {"back"}}));
      CHECK(g.finished && g.eventsLeft == 0);
      Drive h = drive(be, {}, KEYS({PIN("5678"), {"@125000", "back"}}));
      CHECK(h.finished && h.eventsLeft == 0);
      CHECK(shown(be, ":324 550:") && shown(be, ":367 665:"));  // before and after the first boundary (python values)
      CHECK(be.now >= 120000 && lastAt(be, ":Enter PIN:") >
                                    lastAt(be, ":GitHub:"));  // the PIN wheel is on screen after the list: it locked
    }
    {
      // I. without a trusted clock the list says so and shows no codes
      be.epoch = 0;
      Drive d = drive(be, {}, KEYS({PIN("5678"), {"back"}}));
      CHECK(d.finished && d.eventsLeft == 0 && shown(be, "The clock is not set") && shown(be, ":GitHub:") &&
            !shown(be, ":324 550:"));
      be.epoch = 1700000000;
    }
    {
      // J. typed input: a bad secret, a duplicate, and a lower-case secret with spaces (normalised)
      Drive bad = drive(be, {"Bad", "", "not base32!"}, KEYS({PIN("5678"), {"confirm", "confirm", "confirm", "back"}}));
      CHECK(bad.finished && bad.eventsLeft == 0 && shown(be, "Bad secret"));
      Drive dup =
          drive(be, {"GitHub", "", "JBSWY3DPEHPK3PXP"}, KEYS({PIN("5678"), {"confirm", "confirm", "confirm", "back"}}));
      CHECK(dup.finished && dup.eventsLeft == 0 && shown(be, "Not added") && shown(be, ":already there:"));
      Drive ok = drive(be, {"Mail", "Fastmail", "jbsw y3dp ehpk 3pxp"},
                       KEYS({PIN("5678"), {"confirm", "confirm", "confirm", "back"}}));
      CHECK(ok.finished && ok.eventsLeft == 0 && shown(be, ":Added:"));
      lua(be,
          "local vault = require('vault'); local db = json.decode(vault.unlock('data:vault.bin', '5678').data); "
          "print(#db.accounts, db.accounts[2].name, db.accounts[2].issuer, db.accounts[2].secret)");
      CHECK(be.logs.size() == 1 && be.logs[0] == "2\tMail\tFastmail\tJBSWY3DPEHPK3PXP");
    }
    {
      // K. no device secret, a damaged file and unreadable contents all end in a clear message,
      // never in a crash
      be.secretOk = false;
      Drive nos = drive(be, {}, KEYS({PIN("5678"), {"confirm"}}));
      CHECK(nos.finished && nos.eventsLeft == 0 && shown(be, "Cannot open the vault") && shown(be, "device secret"));
      be.secretOk = true;
      lua(be,
          "local b = fs.read('data:vault.bin'); fs.write('data:vault.bak', b); fs.write('data:vault.bin', b:sub(1, #b "
          "- 1) .. string.char(b:byte(#b) ~ 1))");
      Drive dmg = drive(be, {}, KEYS({PIN("5678"), {"confirm", "back"}}));
      CHECK(dmg.finished && dmg.eventsLeft == 0 && shown(be, "Wrong PIN"));
      lua(be, "fs.write('data:vault.bin', fs.read('data:vault.bak'))");
      lua(be,
          "local vault = require('vault'); local v = vault.unlock('data:vault.bin', '5678'); v.data = '[[[['; "
          "print(v:save())");
      Drive junk = drive(be, {}, KEYS({PIN("5678"), {"confirm"}}));
      CHECK(junk.finished && junk.eventsLeft == 0 && shown(be, "Vault unreadable"));
    }
    {
      // L. a vault whose JSON has no accounts is "unreadable" too
      lua(be,
          "local vault = require('vault'); local v = vault.unlock('data:vault.bin', '5678'); v.data = '{\"foo\":1}'; "
          "print(v:save())");
      Drive nojson = drive(be, {}, KEYS({PIN("5678"), {"confirm"}}));
      CHECK(nojson.finished && nojson.eventsLeft == 0 && shown(be, "Vault unreadable") &&
            !shown(be, "Authenticator error"));
      lua(be,
          "local vault = require('vault'); local v = vault.unlock('data:vault.bin', '5678'); v.data = "
          "json.encode({accounts = {{name = 'GitHub', issuer = '', secret = 'JBSWY3DPEHPK3PXP', digits = 6, period = "
          "30, alg = 'SHA1'}, {name = 'Mail', issuer = 'Fastmail', secret = 'JBSWY3DPEHPK3PXP', digits = 6, period = "
          "30, alg = 'SHA1'}}}); print(v:save())");
    }
    {
      // M. the account cap (50) and an 8-digit account in the list
      lua(be,
          "local t = {'otpauth://totp/n1?secret=JBSWY3DPEHPK3PXP&digits=8&issuer=Big'}; for i = 2, 60 do t[#t + 1] = "
          "'otpauth://totp/n' .. i .. '?secret=JBSWY3DPEHPK3PXP' end; fs.write('data:import.txt', table.concat(t, "
          "'\\n'))");
      Drive d = drive(be, {}, KEYS({PIN("5678"), {"confirm", "down", "confirm", "confirm", "back"}}));
      CHECK(d.finished && d.eventsLeft == 0 && shown(be, ":Added 48, skipped 12.:"));
      CHECK(shown(be, ":0232 4550:"));  // python: 8-digit SHA1 code at t=1700000000 is 02324550
      lua(be,
          "local vault = require('vault'); print(#json.decode(vault.unlock('data:vault.bin', '5678').data).accounts)");
      CHECK(be.logs.size() == 1 && be.logs[0] == "50");
    }
    {
      // S. first start on a fresh card: the wheel refuses fewer than 4 digits, a short passphrase
      // and a mismatch are refused too
      MockBackend fresh;
      fresh.epoch = 1700000000;
      Drive d = drive(fresh, {"12"},
                      KEYS({{"confirm"},
                            {"confirm"},
                            {"left"},
                            {"confirm"},
                            PIN("1234"),
                            PIN("9999"),
                            {"confirm"},
                            PIN("5555"),
                            PIN("5555"),
                            {"back"}}));
      CHECK(d.finished && d.eventsLeft == 0 && d.textsLeft == 0 && d.titles == vec({"Choose a PIN (passphrase)"}));
      CHECK(shown(fresh, "At least 4 digits.") && shown(fresh, "PIN too short") && shown(fresh, "PINs differ"));
      lua(fresh,
          "local vault = require('vault'); print(vault.unlock('data:vault.bin', '5555') ~= nil, "
          "vault.unlock('data:vault.bin', '1234'))");
      CHECK(fresh.logs.size() == 1 && fresh.logs[0] == "true\tnil\twrong PIN or damaged vault");
    }
    {
      // W. wheel mechanics: down wraps 0 -> 9, left puts the erased digit back on the wheel,
      // confirm takes the digit being spun
      MockBackend fresh;
      fresh.epoch = 1700000000;
      const std::vector<std::string> W9120 = {"down",  "right", "up", "right", "up",
                                              "right", "left",  "up", "right", "confirm"};
      // walk: down wraps 0 to 9 and locks it; 1 and 1 follow; left takes the second 1 back
      // onto the wheel, up makes it 2, lock; confirm adds the digit being spun (0): 9, 1, 2, 0
      Drive d = drive(fresh, {}, KEYS({{"confirm"}, W9120, W9120, {"back"}}));
      CHECK(d.finished && d.eventsLeft == 0);
      lua(fresh,
          "local vault = require('vault'); print(vault.unlock('data:vault.bin', '9120') ~= nil, "
          "vault.unlock('data:vault.bin', '9111') ~= nil, vault.unlock('data:vault.bin', '9100') ~= nil)");
      CHECK(fresh.logs.size() == 1 && fresh.logs[0] == "true\tfalse\tfalse");
    }
    {
      // X. twelve digits is the maximum: further "right" presses do nothing and confirm submits
      // what is there
      MockBackend fresh;
      fresh.epoch = 1700000000;
      std::vector<std::string> twelve(13, "right");  // 12 locked zeros, the 13th press is ignored
      twelve.push_back("confirm");
      Drive d = drive(fresh, {}, KEYS({{"confirm"}, twelve, twelve, {"back"}}));
      CHECK(d.finished && d.eventsLeft == 0);
      lua(fresh,
          "local vault = require('vault'); print(vault.unlock('data:vault.bin', ('0'):rep(12)) ~= nil, "
          "vault.unlock('data:vault.bin', ('0'):rep(13)) ~= nil)");
      CHECK(fresh.logs.size() == 1 && fresh.logs[0] == "true\tfalse");
    }
    {
      // Y. up wraps 9 -> 0: ten presses are a full turn, so four of them make the PIN 0000
      MockBackend fresh;
      fresh.epoch = 1700000000;
      std::vector<std::string> turns;
      for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 10; j++) turns.push_back("up");
        turns.push_back(i < 3 ? "right" : "confirm");
      }
      Drive d = drive(fresh, {}, KEYS({{"confirm"}, turns, turns, {"back"}}));
      CHECK(d.finished && d.eventsLeft == 0);
      lua(fresh, "local vault = require('vault'); print(vault.unlock('data:vault.bin', '0000') ~= nil)");
      CHECK(fresh.logs.size() == 1 && fresh.logs[0] == "true");
    }
  }
  {
    TEST("vault.lua: the test hub's copy is identical to the Authenticator's (one source of truth)");
    auto slurp = [](const char* path) {
      std::ifstream f(path, std::ios::binary);
      std::stringstream ss;
      ss << f.rdbuf();
      return ss.str();
    };
    const std::string a = slurp("sd_card_contents/plugins/totp_lua/vault.lua"),
                      b = slurp("sd_card_contents/plugins/lua_tests_lua/vault.lua");
    CHECK(!a.empty() && a == b);
  }
  {
    TEST(
        "ble raw mode: ble.start(\"raw\"), observe / adverts / observe_stop, mode exclusivity with the keyboard calls, "
        "gates and validation");
    const std::string DENIED =
        "nil\tbluetooth not permitted: add \"permissions\": [\"bluetooth\"] to this app's manifest.json (and approve "
        "it)";
    const std::string NOTRUN = "nil\tbluetooth is not running (call ble.start() first)";
    const std::string NEEDKB = "nil\tthis needs ble.start(\"keyboard\") (bluetooth is running in raw mode)";
    const std::string NEEDCONNECT =
        "nil\tthis needs ble.start(\"keyboard\") or ble.start(\"gatt\") (bluetooth is running in raw mode)";
    const std::string NEEDRAW = "nil\tthis needs ble.start(\"raw\") (bluetooth is running in keyboard mode)";
    const std::string RANGE = "nil\tms must be 0 or an integer 500..600000";
    auto go = [&](MockBackend& be, const char* script) {
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
    };
    auto expect = [&](MockBackend& be, std::vector<std::string> want, const char* tag) {
      if (be.logs.size() != want.size()) {
        printf("    raw %s: %zu logs, want %zu\n", tag, be.logs.size(), want.size());
        for (auto& l : be.logs) printf("      '%s'\n", l.c_str());
      }
      CHECK(be.logs.size() == want.size());
      for (size_t i = 0; i < want.size() && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i])
          printf("    raw %s #%zu got '%s' want '%s'\n", tag, i + 1, be.logs[i].c_str(), want[i].c_str());
      }
    };
    {
      MockBackend be;  // the keyboard calls are refused in raw mode, and nothing reaches the backend
      be.blePermitted = true;
      go(be, R"LUA(
        print(ble.start("raw"))
        local s = ble.state()
        print(s.running, s.mode, s.link, s.scanning)
        print(ble.scan())
        print(ble.devices())
        print(ble.connect("AA:BB:CC:DD:EE:FF"))
        print(ble.paired())
        print(ble.forget("AA:BB:CC:DD:EE:FF"))
        print(ble.scan_stop())
        print(ble.disconnect())
      )LUA");
      expect(be, {"true", "true\traw\tidle\tfalse", NEEDKB, NEEDKB, NEEDCONNECT, NEEDKB, NEEDKB, "true", "true"},
             "keyboard calls in raw mode");
      CHECK(be.bleModeStarted == "raw" && be.bleScanMsLog.empty() && be.bleConnectLog.empty() && be.bleScanStops == 0 &&
            be.bleDisconnects == 0);
    }
    {
      MockBackend be;  // and the raw calls are refused in keyboard mode, or when nothing runs
      be.blePermitted = true;
      go(be, R"LUA(
        print(ble.observe())
        print(ble.adverts())
        print(ble.start())
        print(ble.observe())
        print(ble.adverts())
        print(ble.observe_stop())
      )LUA");
      expect(be, {NOTRUN, NOTRUN, "true", NEEDRAW, NEEDRAW, "true"}, "raw calls in keyboard mode");
      CHECK(be.bleObserveCalls == 0 && be.bleObserveStops == 0);
    }
    {
      MockBackend be;  // observe(): argument validation never reaches the backend; the defaults are 5000 ms and passive
      be.blePermitted = true;
      go(be, R"LUA(
        print(ble.start("raw"))
        print(ble.observe("1000"))
        print(ble.observe(1000.5))
        print(ble.observe(499))
        print(ble.observe(600001))
        print(ble.observe(1.5))
        print(ble.observe(-1))
        print(ble.observe(5000, 7))
        print(ble.observe(5000, {active = 1}))
      )LUA");
      expect(be,
             {"true", RANGE, RANGE, RANGE, RANGE, RANGE, RANGE, "nil\toptions must be a table like {active=true}",
              "nil\tactive must be a boolean"},
             "validation");
      CHECK(be.bleObserveCalls == 0);
      be.logs.clear();
      go(be, "print(ble.observe(0)); print(ble.observe(500)); print(ble.observe(600000)); print(ble.observe())");
      expect(be, {"true", "true", "true", "true"}, "accepted values");
      CHECK(be.bleObserveCalls == 4 && be.bleObserveMs == 5000 && !be.bleObserveActive);
      be.logs.clear();
      go(be, "print(ble.observe(1000, {active = true}))");
      CHECK(be.bleObserveMs == 1000 && be.bleObserveActive);
      be.logs.clear();
      go(be, "print(ble.observe(1000, {active = false, junk = 1}))");
      CHECK(be.bleObserveMs == 1000 && !be.bleObserveActive);
    }
    {
      MockBackend be;  // a backend failure surfaces its own text; a silent one gets the generic text
      be.blePermitted = true;
      be.bleObserveFail = true;
      go(be, "print(ble.start('raw')); print(ble.observe())");
      expect(be, {"true", "nil\tobserver refused (mock)"}, "backend failure");
      be.logs.clear();
      be.bleObserveFailSilent = true;
      go(be, "print(ble.observe())");
      expect(be, {"nil\tcannot observe"}, "silent failure");
    }
    {
      MockBackend be;  // the advertisement table: shape, order, binary-safe data, the drop count, the observing flag
      be.blePermitted = true;
      auto mk = [](const char* addr, uint8_t type, int rssi, uint8_t advType, bool conn, bool scan, uint8_t advLen,
                   uint32_t age, std::vector<uint8_t> data) {
        crosslua::Backend::BleAdvert a;
        memset(&a, 0, sizeof(a));
        snprintf(a.addr, sizeof(a.addr), "%s", addr);
        a.addrType = type;
        a.rssi = rssi;
        a.advType = advType;
        a.connectable = conn;
        a.scannable = scan;
        a.advLen = advLen;
        a.ageMs = age;
        a.len = static_cast<uint8_t>(data.size());
        if (!data.empty()) memcpy(a.data, data.data(), data.size());
        return a;
      };
      std::vector<uint8_t> big(62);
      for (size_t i = 0; i < big.size(); i++) big[i] = static_cast<uint8_t>(i * 3 + 1);
      be.bleAdvertsSeen = {
          mk("AA:BB:CC:00:11:22", 1, -62, 0, true, true, 4, 1234, {0x02, 0x01, 0x06, 0x00, 0xFF, 0x80, 0x00}),
          mk("11:22:33:44:55:66", 0, -90, 3, false, false, 31, 0, big),
          mk("FE:ED:00:00:00:01", 3, 0, 2, false, true, 0, 99999, {})};
      be.bleDroppedVal = 7;
      go(be, R"LUA(
        print(ble.start("raw"))
        local l, dr = ble.adverts()
        print(#l, dr)
        print(ble.observe(2000, {active = true}))
        print(ble.state().scanning)
        l, dr = ble.adverts()
        print(#l, dr)
        local a, b, c = l[1], l[2], l[3]
        print(a.addr, a.addr_type, a.rssi, a.adv_type, a.connectable, a.scannable, a.adv_len, a.age_ms, #a.data, crypto.hex(a.data))
        print(b.addr, b.addr_type, b.rssi, b.adv_type, b.connectable, b.scannable, b.adv_len, b.age_ms, #b.data, b.data:byte(1), b.data:byte(-1))
        print(c.addr, c.addr_type, c.rssi, c.adv_type, c.connectable, c.scannable, c.adv_len, c.age_ms, #c.data, c.data == "")
        print(ble.observe_stop())
        print(ble.state().scanning)
        print(ble.stop())
        print(ble.adverts())
      )LUA");
      expect(be,
             {"true", "0\t0", "true", "true", "3\t7",
              "AA:BB:CC:00:11:22\t1\t-62\t0\ttrue\ttrue\t4\t1234\t7\t02010600ff8000",
              "11:22:33:44:55:66\t0\t-90\t3\tfalse\tfalse\t31\t0\t62\t1\t184",
              "FE:ED:00:00:00:01\t3\t0\t2\tfalse\ttrue\t0\t99999\t0\ttrue", "true", "false", "true", NOTRUN},
             "adverts");
      CHECK(be.bleObserveStops == 1 && be.bleStopCalls == 1 && be.bleObserveMs == 2000 && be.bleObserveActive);
    }
    {
      MockBackend be;  // at most 32 entries come back however many the backend holds
      be.blePermitted = true;
      crosslua::Backend::BleAdvert a;
      memset(&a, 0, sizeof(a));
      for (int i = 0; i < 40; i++) {
        snprintf(a.addr, sizeof(a.addr), "00:00:00:00:00:%02X", i);
        be.bleAdvertsSeen.push_back(a);
      }
      go(be, "print(ble.start('raw')); print(ble.observe()); local l = ble.adverts(); print(#l, l[32].addr, l[33])");
      expect(be, {"true", "true", "32\t00:00:00:00:00:1F\tnil"}, "cap");
    }
    {
      MockBackend be;  // gates: not permitted, no bluetooth in this firmware: every raw call says so, nothing reaches
                       // the backend
      be.blePermitted = false;
      const char* script = "print(ble.observe()); print(ble.adverts()); print(ble.observe_stop())";
      go(be, script);
      expect(be, {DENIED, DENIED, DENIED}, "denied");
      be.logs.clear();
      be.blePermitted = true;
      be.bleSupportedVal = false;
      go(be, script);
      expect(
          be,
          {"nil\tno bluetooth on this device", "nil\tno bluetooth on this device", "nil\tno bluetooth on this device"},
          "unsupported");
      CHECK(be.bleObserveCalls == 0 && be.bleObserveStops == 0);
    }
  }
  TEST("ble gatt mode: services / read / write / notify / notifs, gates, mode gating, validation");
  {
    auto go = [](MockBackend& be, const char* script) {
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
    };
    auto expect = [](MockBackend& be, std::vector<std::string> want, const char* tag) {
      if (be.logs.size() != want.size())
        printf("    gatt %s: %zu logs, want %zu\n", tag, be.logs.size(), want.size());
      CHECK(be.logs.size() == want.size());
      for (size_t i = 0; i < want.size() && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i])
          printf("    gatt %s #%zu got '%s' want '%s'\n", tag, i + 1, be.logs[i].c_str(), want[i].c_str());
      }
    };
    const std::string DENIED =
        "nil\tbluetooth not permitted: add \"permissions\": [\"bluetooth\"] to this app's manifest.json (and approve "
        "it)";
    const std::string NOTRUN = "nil\tbluetooth is not running (call ble.start() first)";
    const std::string NEEDGATT = "nil\tthis needs ble.start(\"gatt\")";
    const std::string NOTCONN =
        "nil\tnot connected (ble.connect then wait for ble.state().link == \"connected\")";
    // a connected GATT device with two characteristics
    auto setUp = [](MockBackend& be) {
      be.blePermitted = true;
      be.gattConnected = true;
      be.gattChars = {MockBackend::mkChar("180a", "2a29", 3, 0x02 /* read */),
                      MockBackend::mkChar("180f", "2a19", 5, 0x1A /* read|write|notify */)};
      be.gattValues["2a29"] = std::string("Acme Corp");
      be.gattValues["2a19"] = std::string("\x64\x00", 2);  // battery 100%
    };
    {
      MockBackend be;  // every GATT call gates on permission, then on gatt mode
      const char* calls = "print(ble.services()); print(ble.read(\"2a19\")); print(ble.notifs())";
      go(be, calls);
      expect(be, {DENIED, DENIED, DENIED}, "denied");
      be.blePermitted = true;
      be.logs.clear();
      go(be, calls);
      expect(be, {NOTRUN, NOTRUN, NOTRUN}, "not running");
      be.logs.clear();
      go(be, "print(ble.start(\"raw\"))");
      be.logs.clear();
      go(be, calls);
      expect(be, {NEEDGATT, NEEDGATT, NEEDGATT}, "raw mode");
    }
    {
      MockBackend be;  // not connected: services returns the not-connected error, read/write/notify refuse
      setUp(be);
      be.gattConnected = false;
      go(be, "print(ble.start(\"gatt\")); print(ble.services()); print(ble.read(\"2a19\")); "
             "print(ble.write(\"2a19\", \"x\")); print(ble.notify(\"2a19\", true))");
      expect(be, {"true", NOTCONN, "nil\tnot connected (mock)", "nil\tnot connected (mock)",
                  "nil\tnot connected (mock)"}, "not connected");
      CHECK(be.gattReadCalls == 1 && be.gattWriteCalls == 1 && be.gattNotifyCalls == 1 && be.gattServicesCalls == 1);
    }
    {
      MockBackend be;  // connect: addr_type flows to the backend (public default, random explicit, bad values rejected)
      be.blePermitted = true;
      go(be, R"LUA(
        print(ble.start("gatt"))
        print(ble.connect("11:22:33:44:55:66"))
        print(ble.connect("11:22:33:44:55:66", 1))
        print(ble.connect("11:22:33:44:55:66", 2))
        print(ble.connect("11:22:33:44:55:66", "x"))
      )LUA");
      expect(be, {"true", "true", "true", "nil\taddr_type must be 0 (public) or 1 (random)",
                  "nil\taddr_type must be 0 (public) or 1 (random)"}, "connect type");
      CHECK(be.bleConnectTypeLog == (std::vector<int>{0, 1}));
    }
    {
      MockBackend be;  // services: the discovered characteristics, in order, with service/uuid/handle/props
      setUp(be);
      go(be, R"LUA(
        print(ble.start("gatt"))
        local s = ble.services()
        print(#s)
        print(s[1].service, s[1].uuid, s[1].handle, s[1].props)
        print(s[2].service, s[2].uuid, s[2].handle, s[2].props)
      )LUA");
      expect(be, {"true", "2", "180a\t2a29\t3\t2", "180f\t2a19\t5\t26"}, "services");
      CHECK(be.gattServicesCalls == 1);
    }
    {
      MockBackend be;  // read: bytes round-trip, an unknown uuid reports cleanly, case-insensitive
      setUp(be);
      go(be, R"LUA(
        print(ble.start("gatt"))
        local v = ble.read("2a29")
        print(v, #v)
        local b = ble.read("2A19")
        print(b:byte(1), b:byte(2), #b)
        print(ble.read("ffff"))
      )LUA");
      expect(be, {"true", "Acme Corp\t9", "100\t0\t2",
                  "nil\tno such characteristic (mock)"}, "read");
      CHECK(be.gattReadCalls == 3);
    }
    {
      MockBackend be;  // write: the value lands and reads back, no_response reaches the backend, 244-byte cap
      setUp(be);
      go(be, R"LUA(
        print(ble.start("gatt"))
        print(ble.write("2a19", "\x50\x00"))
        local v = ble.read("2a19")
        print(v:byte(1), v:byte(2), #v)
        print(ble.write("2a19", "\x01", {no_response = true}))
        print(ble.write("2a19", string.rep("x", 245)))
        print(ble.write("2a19", "y", 7))
      )LUA");
      expect(be, {"true", "true", "80\t0\t2", "true", "nil\tvalue too long (max 244 bytes)",
                  "nil\toptions must be a boolean or {no_response=true}"}, "write");
      CHECK(be.gattWriteCalls == 2 && be.gattWriteNoRespLog.size() == 2 && !be.gattWriteNoRespLog[0].second &&
            be.gattWriteNoRespLog[1].second);
    }
    {
      MockBackend be;  // notify: subscribe + unsubscribe flag reaches the backend; notifs drain the buffer
      setUp(be);
      go(be, R"LUA(
        print(ble.start("gatt"))
        print(ble.notify("2a19", true))
        print(ble.notify("2a19", false))
        print(ble.notify("2a19", 1))
      )LUA");
      expect(be, {"true", "true", "true", "nil\ton must be a boolean"}, "notify");
      CHECK(be.gattNotifyCalls == 2 && be.gattNotifyLog.size() == 2 && be.gattNotifyLog[0].second &&
            !be.gattNotifyLog[1].second);
      // notifications arrive as {uuid, data} and are drained oldest-first
      crosslua::Backend::BleGattNotif n;
      memset(&n, 0, sizeof(n));
      snprintf(n.uuid, sizeof(n.uuid), "%s", "2a19");
      n.len = 2;
      n.data[0] = 0x64;
      n.data[1] = 0x00;
      be.gattNotifBuf.push_back(n);
      n.data[0] = 0x50;
      be.gattNotifBuf.push_back(n);
      be.logs.clear();
      go(be, "local l = ble.notifs(); print(#l); print(l[1].uuid, l[1].data:byte(1), l[1].data:byte(2)); "
             "print(l[2].uuid, l[2].data:byte(1)); print(#ble.notifs())");
      expect(be, {"2", "2a19\t100\t0", "2a19\t80", "0"}, "notifs");
    }
    {
      MockBackend be;  // argument validation never reaches the backend
      setUp(be);
      go(be, R"LUA(
        print(ble.start("gatt"))
        print(ble.read(""))
        print(ble.read(7))
        print(ble.write("2a19", 5))
        print(ble.notify("2a19", "yes"))
      )LUA");
      expect(be, {"true", "nil\tuuid must be a 1..36 character string", "nil\tuuid must be a string",
                  "nil\tdata must be a string", "nil\ton must be a boolean"}, "validation");
      CHECK(be.gattReadCalls == 0 && be.gattWriteCalls == 0 && be.gattNotifyCalls == 0);
    }
  }
  TEST("ble advertise: name/data broadcast in raw mode, validation, mode gating");
  {
    auto go = [](MockBackend& be, const char* script) {
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
    };
    auto expect = [](MockBackend& be, std::vector<std::string> want, const char* tag) {
      if (be.logs.size() != want.size()) printf("    adv %s: %zu logs, want %zu\n", tag, be.logs.size(), want.size());
      CHECK(be.logs.size() == want.size());
      for (size_t i = 0; i < want.size() && i < be.logs.size(); i++) {
        CHECK(be.logs[i] == want[i]);
        if (be.logs[i] != want[i])
          printf("    adv %s #%zu got '%s' want '%s'\n", tag, i + 1, be.logs[i].c_str(), want[i].c_str());
      }
    };
    const std::string DENIED =
        "nil\tbluetooth not permitted: add \"permissions\": [\"bluetooth\"] to this app's manifest.json (and approve "
        "it)";
    const std::string NOTRUN = "nil\tbluetooth is not running (call ble.start() first)";
    const std::string NEEDRAW = "nil\tthis needs ble.start(\"raw\") (bluetooth is running in keyboard mode)";
    {
      MockBackend be;  // permission, then running, then raw mode
      const char* script = "print(ble.advertise({name=\"x\"})); print(ble.advertising())";
      go(be, script);
      expect(be, {DENIED, DENIED}, "denied");
      be.blePermitted = true;
      be.logs.clear();
      go(be, script);
      expect(be, {NOTRUN, NOTRUN}, "not running");
      be.logs.clear();
      go(be, "print(ble.start(\"keyboard\"))");
      be.logs.clear();
      go(be, script);
      expect(be, {NEEDRAW, NEEDRAW}, "keyboard mode");
      CHECK(be.bleAdvCalls == 0);
    }
    {
      MockBackend be;  // argument validation never reaches the backend
      be.blePermitted = true;
      go(be, R"LUA(
        print(ble.start("raw"))
        print(ble.advertise("x"))
        print(ble.advertise({name = 5}))
        print(ble.advertise({data = 5}))
        print(ble.advertise({}))
        print(ble.advertise({data = string.rep("x", 32)}))
        print(ble.advertise({name = "x", interval_ms = 19}))
        print(ble.advertise({name = "x", interval_ms = "a"}))
        print(ble.advertise({service_uuid = "a"}))
        print(ble.advertise({service_uuid = 0}))
        print(ble.advertise({service_uuid = 70000}))
        print(ble.advertise({service_data = "\x01"}))
        print(ble.advertise({service_uuid = 0xFE2C, service_data = string.rep("x", 28)}))
      )LUA");
      expect(be,
             {"true", "nil\toptions must be a table like {name=\"...\", data=\"...\"}", "nil\tname must be a string",
              "nil\tdata must be a string", "nil\tadvertise a name, data, service_data, or a combination",
              "nil\tdata must be at most 31 bytes", "nil\tinterval_ms must be 0 or 20..10000",
              "nil\tinterval_ms must be 0 or 20..10000", "nil\tservice_uuid must be an integer 1..65535",
              "nil\tservice_uuid must be an integer 1..65535", "nil\tservice_uuid must be an integer 1..65535",
              "nil\tservice_data needs a service_uuid", "nil\tservice_data must be at most 27 bytes"},
             "validation");
      CHECK(be.bleAdvCalls == 0);
    }
    {
      MockBackend be;  // the fields reach the backend; stop clears it; advertise while advertising restarts it
      be.blePermitted = true;
      go(be, R"LUA(
        print(ble.start("raw"))
        print(ble.advertising())
        print(ble.advertise({name = "CrossLua Beacon", data = "\x01\x02\x03"}))
        print(ble.advertising())
        print(ble.advertise({name = "b", connectable = true, interval_ms = 100}))
        print(ble.advertise_stop())
        print(ble.advertising())
      )LUA");
      expect(be, {"true", "false", "true", "true", "true", "true", "false"}, "flow");
      CHECK(be.bleAdvCalls == 2 && be.bleAdvStops == 1 && be.bleAdvName == "b" && be.bleAdvData == "" &&
            be.bleAdvConnectable && be.bleAdvIntervalMs == 100);
    }
    {
      MockBackend be;  // the stack's own refusal surfaces its message
      be.blePermitted = true;
      be.bleAdvFail = true;
      go(be, "print(ble.start(\"raw\")); print(ble.advertise({name=\"x\"}))");
      expect(be, {"true", "nil\tadvertising refused (mock)"}, "backend failure");
    }
    {
      MockBackend be;  // service_uuid + service_data reach the backend as a service-data AD
      be.blePermitted = true;
      go(be, "print(ble.start(\"raw\")); print(ble.advertise({service_uuid=0xFE2C, service_data=\"\\x03\\x00\\x80\"}))");
      expect(be, {"true", "true"}, "service data");
      CHECK(be.bleAdvServiceUuid == 0xFE2C && be.bleAdvServiceData == std::string("\x03\x00\x80", 3));
    }
  }
  if (ota_version_tests())
    ++g_fail;  // defined in test_ota.cpp: a separate TU, so OtaVersion.h changes do not rebuild this file
  printf(g_fail ? "\n%d FAILED\n" : "\nALL PASSED\n", g_fail);
  return g_fail ? 1 : 0;
}
