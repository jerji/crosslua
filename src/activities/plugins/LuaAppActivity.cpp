#include "LuaAppActivity.h"

#include <GfxRenderer.h>
#include <HalMemory.h>
#include <HalPowerManager.h>
#include <HalStorage.h>
#include <Logging.h>

#include <algorithm>
#include <cstring>
#include <deque>
#include <vector>

#include "fontIds.h"
#include "lua/LuaApi.h"
#include "lua/LuaVm.h"

namespace {

constexpr const char* TAG = "LUA";

// ---- memory policy ---------------------------------------------------------
// The Lua heap is a hard cap carved out of whatever internal RAM is free when the
// app starts. RESERVE stays untouched for the framework (WiFi, SD buffers, stacks).
constexpr size_t LUA_RESERVE_BYTES = 56 * 1024;
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
  Backend(GfxRenderer& r, std::string name, std::string dir)
      : r_(r), name_(std::move(name)), dir_(std::move(dir)), dataDir_("/.crosslua/data/" + name_) {}

  std::deque<const char*> events;  // string literals only (see collectInput)
  bool exitRequested = false;

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
  void log(const char* msg) override { LOG_INF(TAG, "[%s] %s", name_.c_str(), msg); }
  const char* appName() override { return name_.c_str(); }
  const char* appDir() override { return dir_.c_str(); }
  const char* dataDir() override { return dataDir_.c_str(); }
  const char* libDir() override { return "/.crosslua/lib"; }
  void requestExit() override { exitRequested = true; }

  // --- storage. Paths arrive pre-sandboxed (app:/data:/lib: scopes) from the API layer. ---
  int64_t fsSize(const char* path) override {
    HalFile f = Storage.open(path);
    if (!f) return -1;
    if (f.isDirectory()) return -2;
    return static_cast<int64_t>(f.fileSize());
  }
  bool fsReadInto(const char* path, void* dst, size_t n) override {
    HalFile f;
    if (!Storage.openFileForRead(TAG, path, f)) return false;
    return f.read(dst, n) == static_cast<int>(n);
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

  backend_.reset(new (std::nothrow) Backend(renderer, appName_, appDir_));
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
  auto armWait = [&]() {
    if (vm_->status() == Status::Waiting) {
      waitDeadline_ = vm_->timeoutMs() >= 0 ? millis() + static_cast<uint32_t>(vm_->timeoutMs()) : 0;
    }
  };
  while (millis() - start < SLICE_MS) {
    if (backend_->exitRequested) return leave();
    switch (vm_->status()) {
      case Status::Preempted:
        vm_->resume();
        armWait();
        break;
      case Status::Waiting: {
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
