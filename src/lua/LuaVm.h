#pragma once
// CrossLua VM core. Platform-independent: only needs Lua + libc, so it builds
// on the host for tests (test/lua_host) and on the device unchanged.
//
// Execution model: the app script runs as a coroutine. The host (an Activity)
// calls resume() once per loop pass; the script runs until it yields:
//   - Waiting:   the script called input.wait(ms)/app.sleep(ms); timeoutMs() says how long
//   - Preempted: the instruction-count hook yielded so a busy script can't starve the device
//   - Finished / Error
// Memory is capped by a counting allocator; hitting the cap makes Lua raise a
// normal "not enough memory" error instead of taking the device down.

#include <cstddef>
#include <cstdint>
#include <string>

struct lua_State;

namespace crosslua {

enum class Status : uint8_t { Idle, Preempted, Waiting, Finished, Error };

class LuaVm {
 public:
  LuaVm() = default;
  ~LuaVm() { close(); }
  LuaVm(const LuaVm&) = delete;
  LuaVm& operator=(const LuaVm&) = delete;

  // Create the state with a hard heap budget. Opens only the sandboxed libs.
  bool open(size_t budgetBytes);
  void close();
  bool isOpen() const { return L_ != nullptr; }

  // Raw state so API modules can register themselves (call between open() and load()).
  lua_State* state() const { return L_; }

  // Compile a chunk (source text or precompiled bytecode is REJECTED: text only,
  // so a hostile .luac can't bypass the bytecode verifier Lua doesn't have).
  // The chunk becomes the main coroutine body. Returns false + error() on failure.
  bool load(const char* chunkName, const char* src, size_t len);

  // Run/continue the script. `eventName` is delivered as the return value of the
  // pending wait (nullptr = timeout/nil). Ignored unless the script was Waiting.
  Status resume(const char* eventName = nullptr);

  Status status() const { return status_; }
  // Valid when status()==Waiting: requested timeout in ms, or -1 for "until an event".
  int32_t timeoutMs() const { return waitMs_; }
  // Valid when Waiting: true if an input event should wake the script early
  // (input.wait), false for a pure timer (app.sleep).
  bool wakesOnEvent() const { return waitEvents_; }
  const std::string& error() const { return error_; }

  size_t usedBytes() const { return alloc_.used; }
  size_t peakBytes() const { return alloc_.peak; }
  size_t budgetBytes() const { return alloc_.budget; }
  // Collect garbage now (apps may call collectgarbage too; host does it on idle).
  void gc();

  // Instructions between preemption yields. Lower = more responsive, higher = faster scripts.
  void setPreemptInterval(int instructions);

 private:
  struct Alloc {
    size_t used = 0;
    size_t peak = 0;
    size_t budget = 0;
  };
  static void* allocFn(void* ud, void* ptr, size_t osize, size_t nsize);
  static void hookFn(lua_State* L, void* ar);

  lua_State* L_ = nullptr;   // main state (owns allocator)
  lua_State* co_ = nullptr;  // script coroutine
  Alloc alloc_;
  Status status_ = Status::Idle;
  int32_t waitMs_ = -1;
  bool waitEvents_ = true;
  int preempt_ = 10000;
  std::string error_;
};

}  // namespace crosslua
