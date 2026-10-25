// Host-side tests for the CrossLua VM core + API bindings (no device needed).
// Build/run: test/lua_host/run.sh
#include <cassert>
#include <cstdio>
#include <cstring>
#include <deque>
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
  int fontId(const char* n) override { return !strcmp(n, "ui") ? 1 : !strcmp(n, "small") ? 2 : -1; }
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

#define TEST(name) printf("[test] %s\n", name)

int main() {
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
          "print(io, os, package, debug, dofile, loadfile, load, require, string ~= nil, math ~= nil, utf8 ~= nil, "
          "coroutine ~= nil)");
    CHECK(run(vm, be) == Status::Finished);
    CHECK(be.logs[0] == "nil\tnil\tnil\tnil\tnil\tnil\tnil\tnil\ttrue\ttrue\ttrue\ttrue");
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
  printf(g_fail ? "\n%d FAILED\n" : "\nALL PASSED\n", g_fail);
  return g_fail ? 1 : 0;
}
