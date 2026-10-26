// Host-side tests for the CrossLua VM core + API bindings (no device needed).
// Build/run: test/lua_host/run.sh
#include <algorithm>
#include <cassert>
#include <dirent.h>
#include <fstream>
#include <sstream>
#include <cstdio>
#include <cstring>
#include <deque>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "src/lua/LuaApi.h"
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
  void line(int a, int b, int c, int d, bool) override { calls.push_back("line"); }
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
    // Same names as the firmware backend (LuaAppActivity.cpp). "ui"=1 and "small"=2 are asserted by tests.
    static const char* const names[] = {"ui", "small", "ui12", "sans12", "sans14", "sans16", "sans18"};
    for (int i = 0; i < 7; i++)
      if (!strcmp(n, names[i])) return i + 1;
    return -1;
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
  size_t freeHeap() override { return 123456; }
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
    return dirs.count(p) ? -2 : -1;
  }
  bool fsReadInto(const char* p, void* dst, size_t n) override {
    auto f = files.find(p);
    if (f == files.end() || f->second.size() != n) return false;
    memcpy(dst, f->second.data(), n);
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
    std::string pre = std::string(p) + "/";
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
        vm.resume(nullptr);  // pretend timeout elapsed
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
    CHECK(be.calls[0] == "text:380,10:abcd:f2:s1:w");  // 400 - 40/2
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
    TEST("sandbox: no io/os/package/debug/dofile/load; bytecode rejected");
    LuaVm vm; MockBackend be;
    setup(vm, be,
          "print(io, os, package, debug, dofile, loadfile, load, type(require), string ~= nil, math ~= nil, utf8 ~= nil, "
          "coroutine ~= nil)");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs[0] == "nil\tnil\tnil\tnil\tnil\tnil\tnil\tfunction\ttrue\ttrue\ttrue\ttrue");
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
  auto loadApp = [](MockBackend& be, const char* name) {
    std::string dir = std::string("sd_card_contents/plugins/") + name;
    DIR* d = opendir(dir.c_str());
    if (!d) return std::string();
    std::string mainSrc;
    while (dirent* e = readdir(d)) {
      std::string fn = e->d_name;
      if (fn == "." || fn == "..") continue;
      std::ifstream in(dir + "/" + fn, std::ios::binary);
      std::stringstream ss;
      ss << in.rdbuf();
      be.files["/plugins/test/" + fn] = ss.str();  // mock appDir() is /plugins/test
      if (fn == "main.lua") mainSrc = ss.str();
    }
    closedir(d);
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
      saved = be.files["/.crosslua/data/test/state.json"];
      printf("    launch %d saved: %s\n", launch, saved.c_str());
      CHECK(vm.resume("back") == Status::Finished);
    }
    // launch 1: 0 +1 +1 +10 -1 = 11 ; launch 2 starts at 11 -> 22
    CHECK(saved.find("\"count\":22") != std::string::npos);
    CHECK(saved.find("\"launches\":2") != std::string::npos);
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
    CHECK(be.logs.size() == 7);
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
    CHECK(be.logs[0] == "nil\tfile too large");
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
