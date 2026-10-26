// Host-side tests for the CrossLua VM core + API bindings (no device needed).
// Build/run: test/lua_host/run.sh
#include <algorithm>
#include <cassert>
#include <ctime>
#include <dirent.h>
#include <fstream>
#include <sstream>
#include <functional>
#include <cmath>
extern "C" {
#include "lauxlib.h"
#include "lua.h"
}
#include <cstdio>
#include <cstring>
#include <deque>
#include <map>
#include <set>
#include <string>
#include <vector>

#include <InflateReader.h>

static const char DEFL_RAW[] = "\013\311HU(,\315L\316VH*\312/\317SH\313\257P\310*\315-(V\310/K-R(\001J\347$VU*\244\344\247\353)\204\214*\036U<\252\230\332\212\001";
static const size_t DEFL_RAW_LEN = 55;
static const char DEFL_ZLIB[] = "x\234\253\312\311L\322-/J,(HMQ(H\254\314\311OL\261Rx4gr\325p\227\000\000*vf\275";
static const size_t DEFL_ZLIB_LEN = 37;
static const char DEFL_BAD[] = "\x73\x00\x99\x99";

extern "C" {
// uzlib references these from its gzip/zlib header helpers; InflateReader never calls them (the firmware linker drops them).
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
  void line(int a, int b, int c, int d, bool) override { calls.push_back("line:" + std::to_string(a) + "," + std::to_string(b) + "," + std::to_string(c) + "," + std::to_string(d)); }
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
    // Same names as the firmware backend (LuaAppActivity.cpp). Real font IDs are hashes and often NEGATIVE
    // (SMALL_FONT_ID is), so the mock uses negative ids for half of them; 0 = unknown.
    static const char* const names[] = {"ui", "small", "ui12", "sans12", "sans14", "sans16", "sans18"};
    static const int ids[] = {1, -2, 3, -4, 5, -6, 7};
    for (int i = 0; i < 7; i++)
      if (!strcmp(n, names[i])) return ids[i];
    return 0;
  }
  void present(int m) override { calls.push_back("present:" + std::to_string(m)); }
  const char* popEvent() override {
    if (events.empty()) return nullptr;
    static std::string hold;
    hold = events.front();
    events.pop_front();
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
  void log(const char* m) override { logs.push_back(m); }
  const char* appName() override { return "test"; }
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
  // ---- network mock: scripted responses, records what reached the backend --------------------------------------
  struct FakeResp { int status = 200; std::string body; std::string error; };
  std::map<std::string, FakeResp> routes;  // by full url
  bool net = true, wifiUp = false, wifiAsked = false;
  size_t largest = 100000;
  struct SeenReq { std::string method, url, body, savePath; std::vector<std::pair<std::string, std::string>> headers; size_t maxBody = 0; };
  std::vector<SeenReq> seen;
  bool netAllowed() override { return net; }
  bool wifiConnected() override { return wifiUp; }
  void wifiRequestConnect() override { wifiAsked = true; }
  bool wifiInfo(char* ssid, size_t sc, char* ip, size_t ic, int* rssi) override {
    if (!wifiUp) return false;
    snprintf(ssid, sc, "TestNet"); snprintf(ip, ic, "192.168.1.50"); *rssi = -57;
    return true;
  }
  void wifiOff() override { wifiUp = false; }
  size_t largestFreeBlock() override { return largest; }
  bool httpRequest(const HttpRequest& rq, HttpResult& res) override {
    SeenReq r;
    r.method = rq.method; r.url = rq.url; r.body = std::string(rq.body ? rq.body : "", rq.bodyLen);
    r.savePath = rq.savePath ? rq.savePath : ""; r.maxBody = rq.maxBody;
    for (int i = 0; i < rq.headerCount; i++) r.headers.emplace_back(rq.headers[i].name, rq.headers[i].value);
    seen.push_back(r);
    if (!wifiUp) { snprintf(res.error, sizeof(res.error), "wifi is not connected (call wifi.connect() first)"); return false; }
    auto it = routes.find(rq.url);
    if (it == routes.end()) { snprintf(res.error, sizeof(res.error), "request failed (no response)"); return false; }
    const FakeResp& f = it->second;
    if (!f.error.empty()) { snprintf(res.error, sizeof(res.error), "%s", f.error.c_str()); return false; }
    res.status = f.status;
    if (rq.savePath) {
      if (f.status >= 200 && f.status < 300) { files[rq.savePath] = f.body; res.bytes = f.body.size(); }
      return true;
    }
    if (f.body.size() > rq.maxBody) { snprintf(res.error, sizeof(res.error), "response larger than max_body (%zu bytes): use save_to", rq.maxBody); return false; }
    res.body = (char*)malloc(f.body.size() ? f.body.size() : 1);  // like the firmware: malloc'd, the caller frees
    memcpy(res.body, f.body.data(), f.body.size());
    res.bodyLen = res.bytes = f.body.size();
    return true;
  }
  // ---- library mock: fake zips (path -> entries), sd: permission, open_book ------------------------------------
  bool library = true;
  std::map<std::string, std::vector<std::pair<std::string, std::string>>> zips;
  std::string openedBook;
  bool libraryAllowed() override { return library; }
  int zipList(const char* path, ZipEntryInfo* out, int maxEntries, int* total, char* err, size_t errCap) override {
    auto it = zips.find(path);
    if (it == zips.end()) { snprintf(err, errCap, "cannot open zip (missing, not a zip, or damaged)"); return -1; }
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
  bool zipRead(const char* path, const char* name, size_t maxBytes, char** data, size_t* len, char* err, size_t errCap) override {
    auto it = zips.find(path);
    if (it == zips.end()) { snprintf(err, errCap, "cannot open zip (missing, not a zip, or damaged)"); return false; }
    for (auto& e : it->second) {
      if (e.first != name) continue;
      if (e.second.size() > maxBytes) { snprintf(err, errCap, "entry is %zu bytes, over max_bytes (%zu)", e.second.size(), maxBytes); return false; }
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
  // ---- batch A mock: scan/time/rename/mac/qr/frontlight/inflate/rounded -----------------------------------------
  std::vector<Backend::WifiScanInfo> nets{{"NetA", -40, true}, {"", -60, false}, {"NetC", -75, true}};
  bool syncOk = true;
  std::string mac_ = "AA:BB:CC:DD:EE:FF";
  std::string qrSeen;                      // "text|x|y|side"
  int roundedSeen = 0;
  bool flPresent = true;
  bool flOn = false;
  int flBr = 60, flWarm = 30;
  int wifiScan(WifiScanInfo* out, int maxEntries, int* total, char* err, size_t errCap) override {
    if (nets.empty()) { snprintf(err, errCap, "scan failed"); return -1; }
    *total = (int)nets.size();
    int c = 0;
    for (auto& n : nets) { if (c >= maxEntries) break; out[c++] = n; }
    return c;
  }
  bool timeSync(int, char* err, size_t errCap) override {
    if (!syncOk) { snprintf(err, errCap, "sync failed"); return false; }
    epoch = 1769000000;
    return true;
  }
  bool timeSet(int64_t e) override { epoch = e; return true; }
  bool fsRename(const char* from, const char* to, char* err, size_t errCap) override {
    // deliberately permissive (overwrites): the binding itself must refuse an existing target
    auto it = files.find(from);
    if (it == files.end()) { snprintf(err, errCap, "no such file"); return false; }
    files[to] = it->second;
    files.erase(it);
    return true;
  }
  void mac(char out[18]) override { snprintf(out, 18, "%s", mac_.c_str()); }
  bool drawQr(const char* text, int x, int y, int side) override {
    qrSeen = std::string(text) + "|" + std::to_string(x) + "|" + std::to_string(y) + "|" + std::to_string(side);
    return true;
  }
  bool frontlightGet(bool* on, int* brightness, int* warmth) override {
    if (!flPresent) return false;
    *on = flOn; *brightness = flBr; *warmth = flWarm;
    return true;
  }
  void frontlightSet(int brightness, int warmth, int on) override {
    if (brightness >= 0) flBr = brightness;
    if (warmth >= 0) flWarm = warmth;
    if (on >= 0) flOn = on == 1;
  }
  // The real InflateReader code (same as the firmware) over the generated vectors above.
  bool inflate(const char* data, size_t n, bool zlib, size_t maxOut, char** out, size_t* outLen, char* err, size_t errCap) override {
    *out = nullptr; *outLen = 0;
    if (zlib) { if (n < 3 || (data[0] & 0x0f) != 8) { snprintf(err, errCap, "not a zlib stream"); return false; } data += 2; n -= 2; }
    InflateReader reader;
    if (!reader.init(false)) { snprintf(err, errCap, "out of memory"); return false; }
    reader.setSource(reinterpret_cast<const uint8_t*>(data), n);
    size_t cap = 4096 < maxOut ? 4096 : maxOut;
    uint8_t* buf = (uint8_t*)malloc(cap);
    if (!buf) { snprintf(err, errCap, "out of memory"); return false; }
    size_t have = 0;
    for (;;) {
      size_t produced = 0;
      InflateStatus st = reader.readAtMost(buf + have, cap - have, &produced);
      have += produced;
      if (st == InflateStatus::Done) break;
      if (st == InflateStatus::Error) { free(buf); snprintf(err, errCap, "corrupt deflate stream"); return false; }
      if (cap >= maxOut) { free(buf); snprintf(err, errCap, "inflated data over %zu bytes", maxOut); return false; }
      cap = cap * 2 < maxOut ? cap * 2 : maxOut;
      uint8_t* nb = (uint8_t*)realloc(buf, cap);
      if (!nb) { free(buf); snprintf(err, errCap, "out of memory"); return false; }
      buf = nb;
    }
    *out = (char*)buf; *outLen = have;
    return true;
  }
  void drawRoundedRect(int x, int y, int w, int h, int radius, bool black, bool filled) override {
    (void)x; (void)y; (void)w; (void)h; (void)radius; (void)black; (void)filled; roundedSeen++;
  }
  // ---- image mock: path -> source size; records the last draw so tests can check fit/centre/permissions ---------
  std::map<std::string, std::pair<int, int>> images;
  struct ImageCall { std::string path; int x = 0, y = 0, w = 0, h = 0; };
  std::vector<ImageCall> imageCalls;
  std::string imageErr;  // non-empty = the decoder "fails" with this message
  bool drawImage(const char* absPath, int x, int y, int maxW, int maxH, int* outW, int* outH, char* err, size_t errCap) override {
    if (!imageErr.empty()) { snprintf(err, errCap, "%s", imageErr.c_str()); return false; }
    auto it = images.find(absPath);
    if (it == images.end()) { snprintf(err, errCap, "cannot read the image header (corrupt or unsupported)"); return false; }
    int dw = it->second.first, dh = it->second.second;
    if (dw > maxW || dh > maxH) {
      const double sc = std::min((double)maxW / dw, (double)maxH / dh);
      dw = std::max(1, (int)(dw * sc)); dh = std::max(1, (int)(dh * sc));
    }
    imageCalls.push_back({absPath, x + (maxW - dw) / 2, y + (maxH - dh) / 2, dw, dh});
    *outW = dw; *outH = dh;
    return true;
  }
  // ---- storage grants mock: (relative path, write?) pairs the "user approved" ---------------------------------------
  std::vector<std::pair<std::string, bool>> grants;
  int grantCount() override { return (int)grants.size(); }
  const char* grantPath(int i, bool* write) override { *write = grants[i].second; return grants[i].first.c_str(); }
  // ---- restart mock: records the requested entry script ---------------------------------------------------------
  std::string restartedTo;
  bool requestRestart(const char* entry) override { restartedTo = entry; return true; }
  const char* entryName() override { return "main.lua"; }
  int64_t epoch = 0;  // 0 = clock not trusted
  int64_t epochNow() override { return epoch ? epoch + now / 1000 : 0; }  // epoch = clock at app start; advances with mock millis
  bool localDate(int64_t e, int out[8]) override {
    time_t t = (time_t)e;
    struct tm g;
    gmtime_r(&t, &g);  // mock "local time" = UTC
    out[0] = g.tm_year + 1900; out[1] = g.tm_mon + 1; out[2] = g.tm_mday; out[3] = g.tm_hour;
    out[4] = g.tm_min; out[5] = g.tm_sec; out[6] = g.tm_wday + 1; out[7] = g.tm_yday + 1;
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
};

static int g_fail = 0;
#define CHECK(c)                                                         \
  do {                                                                   \
    if (!(c)) {                                                          \
      printf("  FAIL line %d: %s\n", __LINE__, #c);                      \
      g_fail++;                                                          \
    }                                                                    \
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

static void dump(MockBackend& be) { for (auto& l : be.logs) printf("    log| %s\n", l.c_str()); }
#define TEST(name) printf("[test] %s\n", name)

int main() {
  setvbuf(stdout, nullptr, _IONBF, 0);
  {
    TEST("hello draws and finishes");
    LuaVm vm; MockBackend be;
    setup(vm, be, "gfx.clear() gfx.text(10,20,'hi') gfx.rect(1,2,3,4,true) gfx.present()");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.calls.size() == 4);
    CHECK(be.calls[1] == "text:10,20:hi:f1:s0:b");
    CHECK(be.calls[2] == "rect:1,2,3,4:fill:b");
    CHECK(be.calls[3] == "present:0");
  }
  {
    TEST("text flags: center/right/bold/white, float coords");
    LuaVm vm; MockBackend be;
    setup(vm, be, "gfx.text(400.0/1,10,'abcd','small','bcw') gfx.text(100,0,'ab','ui','r')");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.calls[0] == "text:380,10:abcd:f-2:s1:w");  // 400 - 40/2
    CHECK(be.calls[1] == "text:80,0:ab:f1:s0:b");      // 100 - 20
  }
  {
    TEST("unknown font raises an error with traceback");
    LuaVm vm; MockBackend be;
    setup(vm, be, "gfx.text(0,0,'x','nope')");
    CHECK(run(vm, be) == Status::Error);
    CHECK(vm.error().find("unknown font 'nope'") != std::string::npos);
    CHECK(vm.error().find("stack traceback") != std::string::npos);
  }
  {
    TEST("input.wait: fast path, yield+resume, timeout nil");
    LuaVm vm; MockBackend be;
    be.events = {"left"};
    setup(vm, be,
          "a = input.wait(100)\n"            // queued: fast path
          "b = input.wait(100)\n"            // empty: yields, host feeds 'confirm'
          "c = input.wait(50)\n"             // yields, host times out -> nil
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
    LuaVm vm; MockBackend be;
    setup(vm, be, "app.sleep(250) input.wait()");
    vm.resume();
    CHECK(vm.status() == Status::Waiting && vm.timeoutMs() == 250 && !vm.wakesOnEvent());
    vm.resume(nullptr);
    CHECK(vm.status() == Status::Waiting && vm.timeoutMs() == -1 && vm.wakesOnEvent());
  }
  {
    TEST("app.exit parks and requests exit");
    LuaVm vm; MockBackend be;
    setup(vm, be, "app.exit() error('unreachable')");
    run(vm, be);
    CHECK(be.exitReq);
    CHECK(vm.status() == Status::Waiting);
  }
  {
    TEST("busy loop is preempted, host stays in control");
    LuaVm vm; MockBackend be;
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
    LuaVm vm; MockBackend be;
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
    LuaVm vm; MockBackend be;
    setup(vm, be,
          "print(io, os, package, debug, dofile, loadfile, type(load), type(require), string ~= nil, math ~= nil, utf8 ~= nil, "
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
    LuaVm vm; MockBackend be;
    be.events = {"back"};
    setup(vm, be, "local ok, e = pcall(function() app.sleep(10) return input.wait(10) end) print(ok, e)");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs[0] == "true\tback");
  }
  {
    TEST("system/app API values");
    LuaVm vm; MockBackend be;
    be.now = 5000;
    setup(vm, be,
          "local f,m = system.heap() local u,p,b = system.lua_mem() local w,h = gfx.size()\n"
          "print(system.millis(), f, m, system.battery(), app.name(), app.dir(), w, h, b, u > 0)");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs[0] == "5000\t123456\t100000\t77\ttest\t/plugins/test\t800\t480\t98304\ttrue");
  }
  {
    TEST("error in script surfaces message, VM can still close cleanly");
    LuaVm vm; MockBackend be;
    setup(vm, be, "local t = nil; t.x = 1");
    CHECK(run(vm, be) == Status::Error);
    CHECK(vm.error().find("attempt to index a nil value") != std::string::npos);
    vm.close();
    CHECK(vm.usedBytes() == 0);
  }

  {
    TEST("heap guard: allocations never leave less than the floor free on the (simulated) device");
    LuaVm vm; MockBackend be;
    be.simTotal = 150 * 1024;
    be.simVm = &vm;
    const size_t floor = 40 * 1024;
    CHECK(vm.open(1024 * 1024));  // budget alone would allow far more than the device has
    vm.setHeapGuard([](void* ud) -> size_t { return static_cast<MockBackend*>(ud)->freeHeapQuick(); }, &be, floor);
    registerApi(vm, be);
    const char* src = "local t = {} local ok, e = pcall(function() for i = 1, 1e6 do t[i] = {i} end end) t = nil collectgarbage() print(ok, tostring(e):sub(1, 17)) print(#string.rep('z', 1000))";
    CHECK(vm.load("guard", src, strlen(src)));
    CHECK(run(vm, be, 1000000) == Status::Finished);
    CHECK(be.logs[0] == "false\tnot enough memory");
    CHECK(be.logs[1] == "1000");  // VM still usable after hitting the guard
    CHECK(vm.peakBytes() <= be.simTotal - floor);
    CHECK(vm.peakBytes() > 60 * 1024);  // and it did use most of what was allowed
  }
  {
    TEST("regression: script dying of uncaught OOM is reported, no panic/abort");
    LuaVm vm; MockBackend be;
    setup(vm, be, "local t = {} while true do t[#t + 1] = {} end", 64 * 1024);
    CHECK(run(vm, be, 1000000) == Status::Error);
    CHECK(vm.error().find("not enough memory") != std::string::npos);
    CHECK(LuaVm::panicMessage[0] == '\0');
    vm.close();
    CHECK(vm.usedBytes() == 0);
  }

  // ======================= example apps from sd_card_contents/ =======================
  // Loads sd_card_contents/plugins/<name>/ (including subfolders like decks/) into the mock SD at /plugins/test/.
  std::function<void(MockBackend&, const std::string&, const std::string&, std::string&)> loadDir =
      [&](MockBackend& be, const std::string& dir, const std::string& rel, std::string& mainSrc) {
        DIR* d = opendir(dir.c_str());
        if (!d) return;
        while (dirent* e = readdir(d)) {
          std::string fn = e->d_name;
          if (fn == "." || fn == "..") continue;
          std::string full = dir + "/" + fn;
          if (DIR* sub = opendir(full.c_str())) { closedir(sub); loadDir(be, full, rel + fn + "/", mainSrc); continue; }
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
    loadDir(be, std::string("sd_card_contents/plugins/") + name, "", mainSrc);
    return mainSrc;
  };
  {
    TEST("example app hello_lua: draws, reacts to buttons, quits on back");
    LuaVm vm; MockBackend be;
    std::string src = loadApp(be, "hello_lua");
    CHECK(!src.empty());
    CHECK(vm.open(96 * 1024));
    registerApi(vm, be);
    CHECK(vm.load("hello_lua", src.data(), src.size()));
    CHECK(vm.resume() == Status::Waiting);  // initial draw done, now waiting for input (5 s refresh timeout)
    CHECK(vm.timeoutMs() == 5000);
    size_t presents = 0;
    for (auto& c : be.calls) if (c.rfind("present:", 0) == 0) presents++;
    CHECK(presents == 1);
    CHECK(vm.resume("right") == Status::Waiting);
    CHECK(vm.resume(nullptr) == Status::Waiting);  // timeout refresh
    CHECK(vm.resume("back") == Status::Finished);
  }
  {
    TEST("example app selftest_lua: every on-device check also passes on the host mock");
    LuaVm vm; MockBackend be;
    std::string src = loadApp(be, "selftest_lua");
    CHECK(!src.empty());
    CHECK(vm.open(300 * 1024));
    registerApi(vm, be);
    CHECK(vm.load("selftest_lua", src.data(), src.size()));
    Status st = run(vm, be, 2000000);
    CHECK(st == Status::Waiting);  // finished all checks, parked on input.wait()
    int pass = 0, fail = 0;
    for (auto& l : be.logs) { if (l.rfind("PASS", 0) == 0) pass++; if (l.rfind("FAIL", 0) == 0) { fail++; printf("    %s\n", l.c_str()); } }
    CHECK(fail == 0);
    CHECK(pass == 12);
  }
  {
    TEST("example app counter_lua: require + json + fs persistence across launches");
    std::string saved;
    for (int launch = 1; launch <= 2; launch++) {
      LuaVm vm; MockBackend be;
      std::string src = loadApp(be, "counter_lua");
      if (!saved.empty()) be.files["/.crosslua/data/test/state.json"] = saved;  // app name is "test" in the mock
      CHECK(vm.open(96 * 1024));
      registerApi(vm, be);
      CHECK(vm.load("counter_lua", src.data(), src.size()));
      CHECK(vm.resume() == Status::Waiting);
      be.events = {"confirm", "confirm", "right", "left"};
      CHECK(run(vm, be) == Status::Waiting);  // consumed all four, now idle waiting for input
      for (auto& c : be.calls) CHECK(c.find("failed") == std::string::npos && c.find("error") == std::string::npos);  // nothing alarming is DRAWN
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
    LuaVm vm; MockBackend be;
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
      if (lua_pcall(L, 1, 1, 0) != LUA_OK) { printf("    lua error: %s\n", lua_tostring(L, -1)); bad++; break; }
      std::stringstream got(lua_tostring(L, -1));
      lua_pop(L, 1);
      std::string gotLine;
      while (std::getline(got, gotLine)) {
        steps++;
        const std::string& want = golden[gi++];
        if (gotLine == want) { identical++; continue; }
        // Same integers, floats within 1e-4 relative? (float printing / libm last-digit differences)
        std::istringstream a(gotLine), b(want);
        std::string ta, tb;
        bool ok = true;
        for (int col = 0; col < 11 && ok; col++) {
          a >> ta; b >> tb;
          if (col == 4 || col == 5) {
            double x = atof(ta.c_str()), y = atof(tb.c_str());
            ok = std::fabs(x - y) <= 1e-4 * std::max(1.0, std::fabs(y));
          } else {
            ok = ta == tb;
          }
        }
        if (ok) close++;
        else { if (bad < 5) printf("    scenario %d step mismatch:\n      lua: %s\n      c++: %s\n", sidx, gotLine.c_str(), want.c_str()); bad++; }
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
      while (std::getline(ss, l)) if (!l.empty() && l[0] != '#' && l.find('\t') != std::string::npos) cardLines++;
    }
    auto frame = [&](MockBackend& b) {  // all text drawn since the last clear, "|"-joined
      size_t from = 0;
      for (size_t i = 0; i < b.calls.size(); i++) if (b.calls[i] == "clear:white") from = i;
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
      *state = r[0]; *step = r[1]; *reps = r[2] | r[3] << 8; *lapses = r[4] | r[5] << 8;
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
      CHECK(settle(vm, {"confirm"}) == Status::Waiting);                    // open the deck
      CHECK(has(be, "TCP 21|") && has(be, "Show|") && has(be, "10 new  0 learn  0 due"));
      CHECK(settle(vm, {"confirm"}) == Status::Waiting);                    // reveal
      CHECK(has(be, "FTP (control)|") && has(be, "Again|1m|Good|10m|Hard|6m|Easy|"));
      CHECK(settle(vm, {"confirm"}) == Status::Waiting);                    // Good -> step 2 of [1m,10m]
      CHECK(has(be, "TCP 22|"));
      record(1, &state, &step, &reps, &lapses, &due);
      CHECK(state == 1 && step == 1 && reps == 1 && lapses == 0);          // learning, on the 10 min step
      record(2, &state, &step, &reps, &lapses, &due);
      CHECK(state == 0 && reps == 0);                                       // untouched card stays new
      // nine more new cards, all Easy: graduate immediately (10 new cards/day limit now reached)
      be.calls.clear();
      for (int i = 0; i < 9; i++) { be.events.push_back("confirm"); be.events.push_back("right"); }
      uint32_t t0 = be.now;
      CHECK(run(vm, be, 200000) == Status::Waiting);
      CHECK(be.now - t0 >= 9 * 60 * 1000);                                  // the "next card in N min" wait really ran ~10 min
      CHECK(has(be, "TCP 21|") && has(be, "Show|"));                       // card 1 came back after its 10 min delay
      record(10, &state, &step, &reps, &lapses, &due0);
      CHECK(state == 2 && reps == 1);                                       // easy graduated straight to review
      CHECK(settle(vm, {"confirm", "confirm"}) == Status::Waiting);         // show, Good -> last step done -> review
      CHECK(has(be, "All done for today!|11 cards reviewed|"));
      record(1, &state, &step, &reps, &lapses, &due);
      CHECK(state == 2 && reps == 2);
      std::string meta = be.files["/.crosslua/data/test/study/ports/meta.json"];
      CHECK(meta.find("\"n\":10") != std::string::npos);
      for (auto& c : be.calls) CHECK(c.find("rror") == std::string::npos && c.find("ailed") == std::string::npos);
      printf("    lua mem: used %zu, peak %zu of budget %zu\n", vm.usedBytes(), vm.peakBytes(), vm.budgetBytes());
      CHECK(settle(vm, {"back"}) == Status::Waiting);                       // back to the deck list
      CHECK(has(be, "Study|") && has(be, "ports|"));
      CHECK(settle(vm, {"back"}) == Status::Finished);                      // Back on the list exits the app
    }
    // ---- 40 days later: the 10 cards are due, 10 fresh new cards are allowed again
    be.epoch += 40 * 86400;
    {
      LuaVm vm;
      CHECK(launch(vm) == Status::Waiting);
      CHECK(has(be, ("10 new   0 learn   10 due   (" + std::to_string(cardLines) + " cards)").c_str()));
      CHECK(settle(vm, {"confirm"}) == Status::Waiting);
      CHECK(has(be, "TCP 21|"));                                            // reviews come first, oldest due first
      CHECK(settle(vm, {"confirm", "confirm"}) == Status::Waiting);         // Good
      record(1, &state, &step, &reps, &lapses, &due);
      CHECK(state == 2 && reps == 3 && lapses == 0 && due > 20000 + 40);
      CHECK(has(be, "TCP 22|"));
      CHECK(settle(vm, {"confirm", "back"}) == Status::Waiting);            // Again on a review card = lapse -> relearn
      record(2, &state, &step, &reps, &lapses, &due);
      CHECK(state == 3 && lapses == 1 && reps == 2);
      for (auto& c : be.calls) CHECK(c.find("rror") == std::string::npos && c.find("ailed") == std::string::npos);
    }
  }
  {
    TEST("debug info: stripped by default (smaller, '?' in errors); <dataDir>/debug.flag keeps line numbers");
    size_t usedStripped = 0, usedKept = 0;
    for (int keep = 0; keep < 2; keep++) {
      LuaVm vm; MockBackend be;
      if (keep) be.files["/.crosslua/data/test/debug.flag"] = "1";
      std::string mod = "local M = {}\n";
      for (int i = 0; i < 60; i++) mod += "function M.f" + std::to_string(i) + "(a, b) local x = a + b local y = x * 2 return y, x end\n";
      mod += "function M.boom(t) return t.nope.deeper end\nreturn M\n";
      be.files["/plugins/test/big.lua"] = mod;
      CHECK(vm.open(512 * 1024));
      registerApi(vm, be);
      CHECK(vm.stripDebug() == !keep);
      const char* script = "local m = require('big')\nprint(m.f7(1, 2))\nprint(pcall(m.boom, {}))\nprint(pcall(function() local z = nil; return z.x end))\nprint(select(2, pcall(error, 'plain')))";
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be) == Status::Finished);
      CHECK(be.logs.size() == 4 && be.logs[0] == "6\t3");
      if (keep) {
        CHECK(be.logs[1].find("app:big.lua:") != std::string::npos);            // file:line present
        CHECK(be.logs[2].find("local 'z'") != std::string::npos);               // variable names present
      } else {
        CHECK(be.logs[1].find("false\t?:") == 0 || be.logs[1].find("?:-1:") != std::string::npos);
        CHECK(be.logs[1].find("app:big.lua") == std::string::npos);
        CHECK(be.logs[2].find("local 'z'") == std::string::npos);               // names are gone, message still produced
        CHECK(be.logs[2].find("attempt to index a nil value") != std::string::npos);
      }
      CHECK(be.logs[3] == "plain");
      lua_gc(vm.state(), LUA_GCCOLLECT);
      (keep ? usedKept : usedStripped) = vm.usedBytes();
      printf("    %s: %zu B after require\n", keep ? "debug.flag (kept)" : "stripped", vm.usedBytes());
    }
    CHECK(usedKept - usedStripped >= 2900);  // stripping saves real memory (~4.5 KB on this 5 KB module; baseline VM is ~30 KB of "used")
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
    TEST("game2048_lua rules: slide/merge-once, directions, spawn odds, win, game over, undo, save validation, invariants");
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
        "2 2 0 0 | 8 true", "2 2 0 0 | 4 true", "0 0 0 0 | 0 false", "1 2 3 4 | 0 false", "2 0 0 0 | 4 true",
        "2 2 0 0 | 4 true", "2 2 2 0 | 4 true", "4 3 0 0 | 16 true", "2 0 0 0 | 0 true",
        "right\t1=1,4=3", "down\t1=1,13=3", "left\t1=1,13=3", "up\t1=1,4=3",
        "false\t0\t1=3", "can_move full\tfalse\tfalse", "can_move hole\ttrue", "over after\ttrue\t1",
        "win\t11\ttrue\ttrue\t2048", "undo1\ttrue\t1=1,2=1\t0\t0\tundo2\tfalse",
    };
    for (size_t i = 0; i < sizeof(want) / sizeof(want[0]); i++) {
      CHECK(i < be.logs.size() && be.logs[i] == want[i]);
      if (i < be.logs.size() && be.logs[i] != want[i]) printf("    [%zu] got '%s' want '%s'\n", i, be.logs[i].c_str(), want[i]);
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
      for (size_t i = 0; i < b.calls.size(); i++) if (b.calls[i] == "clear:white") from = i;
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
      CHECK(f0.find("2048|") == 0 && f0.find("Score 0|") != std::string::npos && f0.find("Best 0|") != std::string::npos);
      CHECK(f0.find("Moves 0|") != std::string::npos && f0.find("Menu|Undo|Left|Right|") != std::string::npos);
      for (int i = 0; i < 12; i++) CHECK(send(vm, {"left", "up", "right", "down"}) == Status::Waiting);
      int moves = field("m"), score = field("s");
      CHECK(moves > 8 && score > 0 && field("best") == score);
      CHECK(frameOf(be).find("Moves " + std::to_string(moves) + "|") != std::string::npos);
      CHECK(send(vm, {"confirm"}) == Status::Waiting);                     // undo one move
      CHECK(field("m") == moves - 1);
      CHECK(send(vm, {"back"}) == Status::Waiting);                        // menu
      CHECK(frameOf(be).find("Resume|New game|Exit|") != std::string::npos);
      CHECK(send(vm, {"down", "confirm"}) == Status::Waiting);             // New game
      CHECK(field("m") == 0 && field("s") == 0 && field("best") == score); // best score survives a new game
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
    const char* script = "print(wifi.connect())\nprint(http.get('http://h/a'))\nprint(http.request{url='http://h/a'})\nprint(wifi.status().connected, wifi.status().ssid)";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs.size() == 4);
    CHECK(be.logs[0].find("false\tnetwork not permitted") == 0 && be.logs[0].find("manifest.json") != std::string::npos);  // wifi.connect: false, reason
    for (int i = 1; i < 3; i++) CHECK(be.logs[i].find("nil\tnetwork not permitted") == 0 && be.logs[i].find("manifest.json") != std::string::npos);
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
          "local st = wifi.status()\nprint(st.connected, st.ssid, st.ip, st.rssi)\nwifi.off()\nprint(wifi.status().connected)";
      CHECK(vm.load("t", script, strlen(script)));
      be.events = {"confirm", "back", "left"};
      CHECK(run(vm, be) == Status::Waiting);                       // parked inside wifi.connect()
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
        CHECK(run(vm, be, 1000, false) == Status::Waiting);          // c1 false, then the 2nd connect() parks again
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
      print(http.request{url = "http://h/a", method = "PUT"})
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
        "200\ttrue\t5\thello", "{\"x\":1}", "404\tfalse\tnope", "nil\tconnection reset", "200",
        "nil\trequest failed (no response)", "nil\tresponse larger than max_body (3 bytes): use save_to",
        "nil\tonly http:// and https:// urls are allowed", "nil\tonly http:// and https:// urls are allowed", "nil\turl too long",
        "nil\tmethod must be GET or POST", "nil\ta GET request cannot have a body", "nil\tillegal header", "nil\tillegal header",
        "nil\theaders must be a table of string = string",
        "nil\tmax_body must be 1..65536 (use save_to for bigger responses)", "nil\tmax_body must be 1..65536 (use save_to for bigger responses)",
        "nil\t'.' and '..' are not allowed", "nil\tsave_to must be a data: path", "nil\tabsolute paths are not allowed",
        "nil\tsave_to is only supported for GET", "200\t5\tnil\thello",
    };
    const size_t nWant = sizeof(want) / sizeof(want[0]);
    for (size_t i = 0; i < nWant; i++) {
      CHECK(i < be.logs.size() && be.logs[i] == want[i]);
      if (i < be.logs.size() && be.logs[i] != want[i]) printf("    [%zu] got '%s' want '%s'\n", i, be.logs[i].c_str(), want[i]);
    }
    CHECK(be.logs.size() == nWant + 2);
    if (be.logs.size() == nWant + 2) {
      CHECK(be.logs[nWant].find("false\t") == 0);   // pcall(http.request, "notatable") raised (bad argument)
      CHECK(be.logs[nWant + 1] == "3");              // system.heap() -> free, min, largest block
    }
    // Only well-formed requests ever reached the backend: a, json, 404, err, POST, missing, max_body=3, save_to
    CHECK(be.seen.size() == 8);
    if (be.seen.size() == 8) {
      CHECK(be.seen[0].method == "GET" && be.seen[0].maxBody == 16384 && be.seen[0].savePath.empty() && be.seen[0].headers.empty());
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
    CHECK(vm.open(72 * 1024));
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
        "line:0,44,799,44", "line:0,5,10,5", "line:5,0,5,10", "line:0,0,479,479", "line:10,10,20,20", "pixel:3,4",
        "rect:790,470,10,10:fill:b", "rect:0,0,15,15:fill:b", "rect:10,10,30,20:line:b",
        "line:790,10,799,10", "line:790,29,799,29", "line:790,10,790,29",
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
    CHECK(be.logs.size() == 1 && be.logs[0] == "false\tnot enough free RAM for WiFi + TLS (free 80K, need 96K): this app is too big for network use");
    CHECK(!be.wifiAsked);
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
        for (auto& l : be.logs) CHECK(l.find("hunter2") == std::string::npos && l.find("other app data") == std::string::npos && l.find("secret") == std::string::npos);
        if (!be.logs.empty()) CHECK(be.logs[0] == "nil");     // fs.list("sd:") -> nil, err ... first print shows only the list
        for (auto& l : be.logs) CHECK(l.find("library access not permitted") != std::string::npos || l == "nil" || l == "false" || l.find("read-only") != std::string::npos);
      } else {
        const char* want[] = {
            "Books/,top.txt", "a.epub,b.txt", "hello", "PK", "5",
            "nil\thidden files and folders are not accessible", "nil\thidden files and folders are not accessible",
            "nil\thidden files and folders are not accessible", "nil\thidden files and folders are not accessible",
            "false",   // fs.exists() on a hidden path: plain false, indistinguishable from "missing"
            "nil\tread-only location (write to 'data:...')", "nil\tread-only location (write to 'data:...')", "nil\tread-only location (write to 'data:...')",
            "nil\tread-only location (write to 'data:...')", "nil\tread-only location (write to 'data:...')",
            "nil\t'.' and '..' are not allowed", "nil\tabsolute paths are not allowed",
            "nil\t'.' and '..' are not allowed", "nil\tempty path component",
        };
        const size_t n = sizeof(want) / sizeof(want[0]);
        for (size_t i = 0; i < n; i++) {
          CHECK(i < be.logs.size() && be.logs[i] == want[i]);
          if (i < be.logs.size() && be.logs[i] != want[i]) printf("    [%zu] got '%s' want '%s'\n", i, be.logs[i].c_str(), want[i]);
        }
      }
    }
    // nothing the app did changed the card
    CHECK(be.files["/Books/b.txt"] == "hello" && be.files["/top.txt"] == "t" && !be.files.count("/Books/x.txt"));
  }
  {
    TEST("zip: list/read limits, errors, scopes, and an oversized entry cannot leak or crash (ASAN/LSAN)");
    MockBackend be;
    be.zips["/Books/a.epub"] = {{"mimetype", "application/epub+zip"}, {"META-INF/container.xml", "<container/>"},
                                {"content.opf", std::string(5000, 'o')}, {"big.bin", std::string(70000, 'b')},
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
    CHECK(be.logs.size() == 2 && be.logs[0].find("nil\tlibrary access not permitted") == 0 && be.logs[1] == "from data");
  }
  {
    TEST("app.open_book: sd:/data: files only, permission, parks the app and hands the path to the host");
    const char* cases[] = {"sd:Books/a.epub", "sd:Books/missing.epub", "app:main.lua", "sd:.crosspoint/x.epub", "data:dl/b.epub", "main.lua", "http://x/y.epub"};
    const char* wantLog[] = {"", "false\tno such file", "false\topen_book needs an sd: or data: path", "false\thidden files and folders are not accessible", "", "false\topen_book needs an sd: or data: path", "false\topen_book needs an sd: or data: path"};
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
        CHECK(st == Status::Waiting && vm.timeoutMs() == -1 && !vm.wakesOnEvent() && be.logs.empty());  // parked, 'after' never runs
      } else {
        CHECK(st == Status::Finished && be.logs.size() == 2 && be.logs[0] == wantLog[i] && be.logs[1] == "after");
      }
    }
    MockBackend be;   // permission: sd: path without "library"
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
    TEST("batch A: wifi.scan/time.sync+set/fs.rename/system.mac/gfx.qr/rounded/frontlight");
    MockBackend be;
    be.files["/.crosslua/data/test/a.txt"] = "one";
    be.files["/.crosslua/data/test/b.txt"] = "two";
    be.files["/.crosslua/data/test/dir/x"] = "x";
    be.files["/Books/x.epub"] = "PK";
    be.library = true;
    const char* script = R"LUA(
      local function show(...) print(...) end
      local l, total = wifi.scan(2); show(#l, total, l[1].ssid, l[1].rssi, l[2].ssid, l[2].encrypted)
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
        "nil\tmax must be 1..50", "nil\tmax must be 1..50",
        "true",                        // time.now() == nil before sync
        "true", "true",
        "false\tsync failed",          // (mock syncOk still true; timeout bounds are checked Lua-side)
        "nil\ttimeout must be 1..60 seconds",
        "true",                        // time.set(1769000000)
        "true",                        // time.now() reflects the set
        "nil\tepoch out of the plausible range (2020..2096)",
    };
    (void)want;  // expectations asserted incrementally below to keep the diff readable
    CHECK(be.logs.size() >= 31);
    if (be.logs.size() >= 31) {
      CHECK(be.logs[0] == "2\t3\tNetA\t-40\t\tfalse");
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
    if (getenv("DUMP_LOGS")) { for (size_t i = 0; i < be.logs.size(); i++) printf("   [%zu] %s\n", i, be.logs[i].c_str()); printf("   qr=%s\n", be.qrSeen.c_str()); }
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
    )LUA";
    CHECK(vm.load("t", script, strlen(script)));
    CHECK(run(vm, be, 200000) == Status::Finished);
    if (getenv("DUMP_LOGS")) for (size_t i = 0; i < be.logs.size(); i++) printf("   [z%zu] %s\n", i, be.logs[i].c_str());
    CHECK(be.logs.size() == 8);
    if (be.logs.size() == 8) {
      CHECK(be.logs[0] == "900\tThe quick brown fox");
      CHECK(be.logs[1] == "250\tzlib-wrapped payload:");
      CHECK(be.logs[2] == "nil\tcorrupt deflate stream" && be.logs[3] == "nil\tcorrupt deflate stream");
      CHECK(be.logs[4] == "nil\tinput must be 1..65536 bytes");
      CHECK(be.logs[5] == "nil\tinput must be 1..65536 bytes");
      CHECK(be.logs[6] == "nil\tnot a zlib stream");
      CHECK(be.logs[7] == "true");
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
    CHECK(vm.open(160 * 1024));
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
    if (getenv("DUMP_LOGS")) { for (size_t i = 0; i < be.logs.size(); i++) printf("   [%zu] %s\n", i, be.logs[i].c_str()); }
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
      CHECK(be.logs[11].find("nil\tload: text chunks only") == 0 && be.logs[12].find("nil\tload: text chunks only") == 0);
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
    CHECK(vm.open(160 * 1024));  // the 60 KB source fits (string.rep peaks ~120 KB) but compiling it cannot
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
    if (getenv("DUMP_LOGS")) { printf("   st=%d err=%s\n", (int)st, vm.error().c_str()); for (auto& l : be.logs) printf("   <%s>\n", l.c_str()); }
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
    LuaVm vm; MockBackend be;
    setup(vm, be,
          "assert(fs.write('data:save.txt', 'hello'))\n"
          "assert(fs.append('data:save.txt', ' world'))\n"
          "assert(fs.write('data:sub/deep/x.json', '{}'))\n"          // parents auto-created
          "assert(fs.mkdir('data:emptydir'))\n"
          "print(fs.read('data:save.txt'), fs.size('data:save.txt'), fs.exists('data:save.txt'), fs.exists('data:nope'))\n"
          "local l = fs.list('data:') print(table.concat(l, ','))\n"
          "print(fs.remove('data:save.txt'), fs.exists('data:save.txt'))\n"
          "print(fs.remove('data:sub'))\n"                              // non-empty dir
          "print(fs.remove('data:'))\n"                                // the data root itself
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
    LuaVm vm; MockBackend be;
    std::string big(300 * 1024, 'a');
    for (size_t i = 0; i < big.size(); i++) big[i] = (char)('a' + (i % 26));
    be.files["/plugins/test/big.txt"] = big;
    setup(vm, be,
          "print(fs.read('big.txt', 0, 5), fs.read('big.txt', 26, 3), fs.read('big.txt', 307195, 100))\n"      // clipped at EOF
          "print(#fs.read('big.txt', 1000, 100000), fs.read('big.txt', 307200, 10) == '')\n"                  // at EOF = empty
          "print(fs.read('big.txt', 307201, 1))\n"                                                           // beyond EOF
          "print(fs.read('big.txt', -1, 4))\n"
          "print(fs.read('big.txt', 0, 200000))\n"                                                           // range too large
          "print(fs.read('big.txt'))\n"                                                                      // whole file too large -> hint
          "assert(fs.write('data:rec.bin', string.rep('.', 24)))\n"
          "assert(fs.write_at('data:rec.bin', 8, 'XYZ'))\n"
          "assert(fs.write_at('data:rec.bin', 24, 'END'))\n"                                                 // extend at exact end is ok
          "print(fs.read('data:rec.bin'), fs.size('data:rec.bin'))\n"
          "print(fs.write_at('data:rec.bin', 99, 'x'))\n"                                                    // gap -> refused
          "print(fs.write_at('data:nope.bin', 0, 'x'))\n"                                                   // must exist
          "print(fs.write_at('app:big.txt', 0, 'x'))\n"                                                     // read-only scope
          "print(fs.write_at('data:rec.bin', 0, string.rep('z', 20000)))",                                  // > 16 KB
          2048 * 1024);
    CHECK(run(vm, be, 100000) == Status::Finished);
    CHECK(be.logs.size() == 11);
    CHECK(be.logs[0] == "abcde\tabc\t" + big.substr(307195));
    CHECK(be.logs[1] == "100000\ttrue");
    CHECK(be.logs[2] == "nil\toffset beyond end of file");
    CHECK(be.logs[3] == "nil\tnegative offset/length");
    CHECK(be.logs[4] == "nil\tlength too large");
    CHECK(be.logs[5].find("nil\tfile too large") == 0 && be.logs[5].find("fs.read(path, offset, len)") != std::string::npos);
    CHECK(be.logs[6] == "........XYZ.............END\t27");
    CHECK(be.logs[7] == "nil\toffset beyond end of file");
    CHECK(be.logs[8].find("nil\tno such file") == 0);
    CHECK(be.logs[9].find("nil\tread-only") == 0);
    CHECK(be.logs[10] == "nil\tdata too large for write_at");
  }
  {
    TEST("time.now / time.date: trusted clock, no clock, explicit epoch");
    LuaVm vm; MockBackend be;
    be.epoch = 1782086400 + 3 * 3600 + 25 * 60 + 9;  // 2026-06-22 03:25:09 UTC (a Monday)
    setup(vm, be,
          "local d = time.date()\n"
          "print(time.now(), d.year, d.month, d.day, d.hour, d.min, d.sec, d.wday, d.yday)\n"
          "local e = time.date(0 + 86400 * 365)\n"
          "print(e and e.year, time.date(1))");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs[0] == "1782098709\t2026\t6\t22\t3\t25\t9\t2\t173");
    LuaVm vm2; MockBackend be2; be2.epoch = 0;
    setup(vm2, be2, "print(time.now(), time.date(), time.date(5000))");
    CHECK(run(vm2, be2) == Status::Finished);
    CHECK(be2.logs[0] == "nil\tnil\ttable: 0" || be2.logs[0].find("nil\tnil\t") == 0);
  }
  {
    TEST("fs: sandbox - traversal, absolute, odd paths, read-only scopes");
    LuaVm vm; MockBackend be;
    be.files["/plugins/test/asset.txt"] = "A";
    be.files["/.crosslua/lib/l.txt"] = "L";
    be.files["/secret.txt"] = "S";
    setup(vm, be,
          "local bad = {'../secret.txt', 'data:../../secret.txt', '/secret.txt', 'data:/secret.txt', 'a/../b', "
          "'a//b', './x', 'a\\\\b', 'x:y', 'lib:../x', string.rep('a', 300)}\n"
          "local rej = 0\n"
          "for _, p in ipairs(bad) do local r, e = fs.read(p) if r == nil and e ~= 'no such file' then rej = rej + 1 else print('LEAK', p, r, e) end end\n"
          "print('rejected', rej, #bad)\n"
          "print(fs.read('asset.txt'), fs.read('app:asset.txt'), fs.read('lib:l.txt'))\n"
          "print(fs.write('asset.txt', 'x'))\n"                  // bare = app: read-only
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
    LuaVm vm; MockBackend be;
    be.files["/plugins/test/big.bin"] = std::string(200 * 1024, 'x');
    be.dirs.insert("/plugins/test/d");
    setup(vm, be,
          "print(fs.read('big.bin'))\n"
          "print(fs.write('data:big', string.rep('y', 300*1024)))\n"
          "print(fs.read('d'))\n"
          "print(fs.list('big.bin'))\n"
          "print(fs.list('nope'))\n"
          "print(fs.size('d'))", 2048 * 1024);
    CHECK(run(vm, be, 100000) == Status::Finished);
    CHECK(be.logs[0].find("nil\tfile too large") == 0);
    CHECK(be.logs[1] == "nil\tdata too large");
    CHECK(be.logs[2] == "nil\tis a directory");
    CHECK(be.logs[3] == "nil\tnot a directory");
    CHECK(be.logs[4].find("nil\t") == 0);
    CHECK(be.logs[5] == "nil\tis a directory");
    LuaVm vm2; MockBackend be2; be2.failWrites = true;
    setup(vm2, be2, "print(fs.write('data:a', 'x'))");
    CHECK(run(vm2, be2) == Status::Finished);
    CHECK(be2.logs[0] == "nil\twrite error");
  }
  {
    TEST("fs: reading under a tight budget fails cleanly (no crash), VM frees");
    LuaVm vm; MockBackend be;
    be.files["/plugins/test/f.bin"] = std::string(60 * 1024, 'z');
    setup(vm, be, "local ok, e = pcall(fs.read, 'f.bin') print(ok, tostring(e):sub(1, 17)) print(#string.rep('a', 100))", 32 * 1024);
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs[0] == "false\tnot enough memory");
    CHECK(be.logs[1] == "100");
    vm.close();
    CHECK(vm.usedBytes() == 0);
  }

  // ======================= Phase 2: require =======================
  {
    TEST("require: app module, caching, dotted names, init.lua, lib fallback, app shadows lib");
    LuaVm vm; MockBackend be;
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
      be.library = allowed; be.logs.clear(); be.imageCalls.clear();
      LuaVm vm;
      CHECK(vm.open(256 * 1024));
      registerApi(vm, be);
      CHECK(vm.load("t", script, strlen(script)));
      CHECK(run(vm, be, 100000) == Status::Finished);
      if (getenv("DUMP_LOGS")) { printf("   [allowed=%d]\n", allowed); for (size_t i = 0; i < be.logs.size(); i++) printf("   [%zu] %s\n", i, be.logs[i].c_str()); for (auto& c : be.imageCalls) printf("   call %s x=%d y=%d %dx%d\n", c.path.c_str(), c.x, c.y, c.w, c.h); }
      CHECK(be.logs.size() == 15);
      if (be.logs.size() != 15) continue;
      CHECK(be.logs[2] == "40\t40" && be.logs[3] == "20\t10" && be.logs[4] == "20\t10");   // data:/app: need no permission
      if (allowed) {
        CHECK(be.logs[0] == "240\t480");                    // 1000x2000 into 480x800 -> scale .4
        CHECK(be.logs[1] == "100\t50");                     // small image untouched
        CHECK(be.imageCalls.size() == 6);
        if (be.imageCalls.size() == 6) {
          CHECK(be.imageCalls[1].x == 10 + (300 - 100) / 2 && be.imageCalls[1].y == 20 + (300 - 50) / 2);  // centred in its box
          CHECK(be.imageCalls[0].path == "/Books/cover.PNG");
          CHECK(be.imageCalls[5].path == "/Books/photo.jpg" && be.imageCalls[5].w == 80 && be.imageCalls[5].h == 40 && be.imageCalls[5].y == 380 + (100 - 40) / 2);
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
        CHECK(be.logs[0].find("nil\tlibrary access not permitted") == 0 && be.logs[1].find("nil\tlibrary access not permitted") == 0);
        CHECK(be.imageCalls.size() == 3);                   // only the data:/app: draws happened
        CHECK(be.logs[9].find("nil\tlibrary access not permitted") == 0);
      }
    }
    // a decoder failure is a plain nil,err and never aborts the app
    be.library = true; be.imageErr = "decode failed (corrupt image or not enough RAM)"; be.logs.clear();
    LuaVm vm;
    CHECK(vm.open(64 * 1024));
    registerApi(vm, be);
    const char* s2 = "print(gfx.image('sd:Books/photo.jpg', 0, 0)); print('alive')";
    CHECK(vm.load("t", s2, strlen(s2)));
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs.size() == 2 && be.logs[0] == "nil\tdecode failed (corrupt image or not enough RAM)" && be.logs[1] == "alive");
  }
  {
    TEST("app.restart: plain .lua names in the app folder only, parks the app, hands the entry to the host");
    const char* names[] = {"run.lua", "", "../x.lua", "sub/run.lua", "x.txt", ".hidden.lua", "a..b.lua", "run.LUA", "missing.lua", "with space.lua", "run.lua\\n"};
    const char* wantErr[] = {"", "", "entry must", "entry must", "entry must", "entry must", "entry must", "entry must", "no such entry script", "entry must", "entry must"};
    const char* wantRestart[] = {"run.lua", "main.lua", "", "", "", "", "", "", "", "", ""};
    for (int i = 0; i < 11; i++) {
      MockBackend be;
      be.files["/plugins/test/main.lua"] = "-- main";
      be.files["/plugins/test/run.lua"] = "-- run";
      be.files["/plugins/test/.hidden.lua"] = "x";
      LuaVm vm;
      CHECK(vm.open(128 * 1024));
      registerApi(vm, be);
      std::string script;
      if (i == 1) script = "print(app.restart())\nprint('after')";            // no argument = main.lua
      else script = std::string("print(app.restart('") + names[i] + "'))\nprint('after')";
      if (i == 10) script = "print(app.restart('run.lua\\n'))\nprint('after')";  // a newline inside the name
      CHECK(vm.load("t", script.data(), script.size()));
      Status st = run(vm, be);
      CHECK(be.restartedTo == wantRestart[i]);
      if (wantRestart[i][0]) {
        CHECK(st == Status::Waiting && vm.timeoutMs() == -1 && !vm.wakesOnEvent() && be.logs.empty());  // parked: 'after' never runs
      } else {
        CHECK(st == Status::Finished && be.logs.size() == 2 && be.logs[1] == "after");
        CHECK(be.logs.size() == 2 && be.logs[0].find("false\t") == 0 && be.logs[0].find(wantErr[i]) != std::string::npos);
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
    struct P { const char* in; const char* want; };  // want == nullptr -> rejected
    const P cases[] = {{"Books", "Books"}, {"Books/AO3/", "Books/AO3"}, {"/", ""}, {"a/b/c", "a/b/c"}, {"My Books", "My Books"},
                       {"", nullptr}, {"..", nullptr}, {"../x", nullptr}, {"a/../b", nullptr}, {"a/./b", nullptr},
                       {".hidden", nullptr}, {"a/.b", nullptr}, {"/abs", nullptr}, {"a//b", nullptr}, {"a:b", nullptr},
                       {"a\\b", nullptr}, {"a\tb", nullptr}, {"//", nullptr}, {".", nullptr}, {"sd:Books", nullptr}};
    for (const P& c : cases) {
      char out[120];
      const bool ok = crosslua::parseGrantPath(c.in, out, sizeof(out));
      CHECK(ok == (c.want != nullptr));
      if (c.want) CHECK(ok && !strcmp(out, c.want));
      if (ok != (c.want != nullptr) || (ok && c.want && strcmp(out, c.want))) printf("    parseGrantPath('%s') -> %d '%s'\n", c.in, ok, ok ? out : "");
    }
    char out[120];
    CHECK(!crosslua::parseGrantPath(std::string(101, 'a').c_str(), out, sizeof(out)));
    CHECK(!crosslua::parseGrantPath("Books", out, 3));  // does not fit
    CHECK(crosslua::grantIsDangerous("") && crosslua::grantIsDangerous("plugins") && crosslua::grantIsDangerous("Plugins/x"));
    CHECK(!crosslua::grantIsDangerous("pluginsX") && !crosslua::grantIsDangerous("Books") && !crosslua::grantIsDangerous("Books/plugins"));
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
    const std::string OUTSIDE = "nil\tlibrary access not permitted: this path is outside the folders granted to this app";
    const std::string RO = "nil\tread-only location (the app has no write grant for this folder)";
    const std::string BIN = "nil\tread-only location (firmware images (*.bin) can never be written)";
    const std::string HIDDEN = "nil\thidden files and folders are not accessible";
    const Case cases[] = {
        {"read Books, write Books/AO3 + Downloads, no library", false,
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
         {"PK-a", OUTSIDE, OUTSIDE, OUTSIDE, HIDDEN, RO, "true", BIN, "true", "x", "true", RO, "true", RO, OUTSIDE, "false", BIN}},
        {"library (read everything) + the same grants: writes still only where granted", true,
         {{"Books", false}, {"Books/AO3", true}, {"Downloads", true}},
         R"LUA(
           local function show(...) print(...) end
           show(fs.read("sd:top.txt")); show(fs.write("sd:top.txt", "y")); show(fs.write("sd:Downloads/q.txt", "y"))
           show(fs.read("sd:.crosspoint/wifi.json"))
         )LUA",
         {"t", RO, "true", HIDDEN}},
        {"whole-card write grant: everything but hidden paths and *.bin", false, {{"", true}},
         R"LUA(
           local function show(...) print(...) end
           show(fs.write("sd:top.txt", "y")); show(fs.write("sd:plugins/x/main.lua", "y"))
           show(fs.write("sd:.crosspoint/a", "y")); show(fs.write("sd:fw.bin", "y")); show(fs.read("sd:BooksX/z.txt"))
         )LUA",
         {"true", "true", HIDDEN, BIN, "z"}},
        {"no grants and no library: nothing outside the sandbox", false, {},
         R"LUA(print(fs.read("sd:Books/a.epub")))LUA",
         {"nil\tlibrary access not permitted: add \"library\" to \"permissions\" in manifest.json"}},
        {"library only (no grants): read-only, original message", true, {},
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
        if (be.logs[i] != c.want[i]) printf("    [%s] #%zu got '%s' want '%s'\n", c.name, i + 1, be.logs[i].c_str(), c.want[i].c_str());
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
    const char* s2 = "fs.write('sd:Books/AO3/new.epub', 'N'); fs.write('sd:Downloads/n.txt', 'D'); fs.write('sd:Books/evil.txt', 'E'); "
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
    CHECK(be.files["/Books/AO3/dl.epub"] == "hello" && !be.files.count("/Books/dl.epub") && !be.files.count("/Books/AO3/fw.bin") && !be.files.count("/top.txt"));
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
    CHECK(be.logs.size() == 3 && be.logs[0] == "30\t15" && be.logs[1] == "10\t10" && be.logs[2] == "nil\tunsupported image type (png, jpg, bmp)");
    CHECK(be.imageCalls.size() == 2 && be.imageCalls[0].path == "/Books/pic.bmp" && be.imageCalls[1].x == 5 + (50 - 10) / 2);
  }
  {
    TEST("require: a big module loads in a tight heap (the unstripped copy is dropped before the stripped one loads)");
    std::string mod = "local M = {}\n";
    for (int i = 0; i < 200; i++) {
      char line[160];
      snprintf(line, sizeof(line), "function M.f%d(a, b)\n  local t = {a, b, %d}\n  return t[1] * t[2] + t[3] + #tostring(a)\nend\n", i, i);
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
    // measured on the host: streaming + drop-the-full-copy peaks at ~111 KB; without the streaming ~128 KB; the original
    // load order (source buffer + full + stripped copies together) ~181 KB
    CHECK(peakOk > mod.size() && peakOk < 120000);
    MockBackend be;
    be.files["/plugins/test/big.lua"] = mod;
    LuaVm vm;
    vm.open(120000);  // below both older variants: only streaming + early drop fits
    registerApi(vm, be);
    const char* sc = "local ok, m = pcall(require, 'big'); print(ok, ok and m.f7(3, 4))";
    CHECK(vm.load("t", sc, strlen(sc)));
    CHECK(run(vm, be) == Status::Finished);
    if (getenv("DUMP_LOGS")) for (auto& l : be.logs) printf("   tight: %s\n", l.c_str());
    CHECK(be.logs.size() == 1 && be.logs[0] == "true\t20");
  }
  {
    TEST("require: a module that cannot be read (card error) is a clean error; modules over 1 KB stream correctly");
    MockBackend be;
    std::string big = "local t = {}\n";
    for (int i = 0; i < 300; i++) { char l[64]; snprintf(l, sizeof(l), "t[%d] = 'line number %d'\n", i, i); big += l; }
    big += "return t\n";   // ~8 KB: several 1 KB pieces, with a token split across a piece boundary somewhere
    be.files["/plugins/test/broken.lua"] = "return 1";
    be.files["/plugins/test/long.lua"] = big;
    be.failReadPath = "/plugins/test/broken.lua";
    LuaVm vm;
    CHECK(vm.open(256 * 1024));
    registerApi(vm, be);
    const char* sc = "local ok, e = pcall(require, 'broken'); print(ok, tostring(e):find('module read error', 1, true) ~= nil)\n"
                     "local t = require('long'); print(#t, t[0], t[299])";
    CHECK(vm.load("t", sc, strlen(sc)));
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs.size() == 2 && be.logs[0] == "false\ttrue" && be.logs[1] == "299\tline number 0\tline number 299");
  }
  {
    TEST("require: errors - missing, bad names, syntax error, runtime error, circular, bytecode");
    LuaVm vm; MockBackend be;
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
    LuaVm vm; MockBackend be;
    be.files["/plugins/test/waiter.lua"] = "local e = input.wait(10) return {got = e}";
    be.events = {};
    setup(vm, be, "local m = require('waiter') print(tostring(m.got))");
    be.events.push_back("confirm");
    // run(): first resume hits input.wait with an event queued -> fast path. Use an empty queue instead:
    be.events.clear();
    CHECK(vm.resume() == Status::Waiting);          // yielded from inside the module's top level
    CHECK(vm.timeoutMs() == 10);
    CHECK(vm.resume("left") == Status::Finished);
    CHECK(be.logs[0] == "left");
  }

  // ======================= Phase 2: json =======================
  {
    TEST("json: decode values, types, nesting, unicode");
    LuaVm vm; MockBackend be;
    setup(vm, be,
          "local t = json.decode('{\"a\":[1,2.5,-3,1e2,true,false,null],\"s\":\"x\\\\ny\\\\u00e9\\\\ud83d\\\\ude00\",\"o\":{}}')\n"
          "print(t.a[1], math.type(t.a[1]), t.a[2], math.type(t.a[2]), t.a[3], t.a[4], math.type(t.a[4]), t.a[5], t.a[6], t.a[7] == json.null)\n"
          "print(t.s == 'x\\ny\\xc3\\xa9\\xf0\\x9f\\x98\\x80', next(t.o) == nil, #t.a)\n"
          "print(math.type(json.decode('2147483647')), math.type(json.decode('2147483648')), json.decode(' 42 '), json.decode('\"\"') == '')");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs[0] == "1\tinteger\t2.5\tfloat\t-3\t100.0\tfloat\ttrue\tfalse\ttrue");
    CHECK(be.logs[1] == "true\ttrue\t7");
    CHECK(be.logs[2] == "integer\tfloat\t42\ttrue");
  }
  {
    TEST("json: decode errors return nil,msg (never throw)");
    LuaVm vm; MockBackend be;
    setup(vm, be,
          "local cases = {'', '{', '[1,2', '{\"a\"}', '{a:1}', '[1,]', '01', '1.', '\"abc', '\"\\\\x\"', '\"\\\\ud800\"', "
          "'tru', '[1] x', '\"a\\nb\"', '{\"a\":1,}', string.rep('[', 100)}\n"
          "local bad = 0\n"
          "for i, c in ipairs(cases) do local v, e = json.decode(c) if v == nil and type(e) == 'string' then bad = bad + 1 else print('ACCEPTED', i, c) end end\n"
          "print(bad, #cases)\n"
          "print(json.decode('[1,}'))");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs.size() == 2);
    CHECK(be.logs[0] == "16\t16");
    CHECK(be.logs[1].find("nil\t") == 0 && be.logs[1].find("at byte") != std::string::npos);
  }
  {
    TEST("json: encode scalars, escapes, arrays, objects, null; roundtrip");
    LuaVm vm; MockBackend be;
    setup(vm, be,
          "print(json.encode(nil), json.encode(true), json.encode(42), json.encode(1.5), json.encode('a\"b\\\\c\\n\\1'))\n"
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
    LuaVm vm; MockBackend be;
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
    LuaVm vm; MockBackend be;
    setup(vm, be,
          "local t = {} for i = 1, 300 do t[i] = {id = i, name = 'item' .. i} end\n"
          "local s = json.encode(t) local back = json.decode(s)\n"
          "print(#s > 5000, #back, back[300].name)\n"
          "local ok, e = pcall(function() local big = {} for i = 1, 100000 do big[i] = {i} end return json.encode(big) end)\n"
          "print(ok, tostring(e):sub(1, 17))",
          512 * 1024);  // host pointers are 64-bit: memory numbers here are ~1.6x what the 32-bit C3 uses
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs[0] == "true\t300\titem300");
    CHECK(be.logs[1] == "false\tnot enough memory");
    vm.close();
    CHECK(vm.usedBytes() == 0);
  }
  printf(g_fail ? "\n%d FAILED\n" : "\nALL PASSED\n", g_fail);
  return g_fail ? 1 : 0;
}
