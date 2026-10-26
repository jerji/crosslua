#pragma once
// Runs an SD-card Lua app (<plugin dir>/main.lua) as an Activity.
// See docs/lua/PLAN.md. The VM lives only while this activity does: leaving
// the app frees every byte it used.

#include <memory>
#include <string>

#include "activities/Activity.h"

namespace crosslua {
class LuaVm;
}

class LuaAppActivity final : public Activity {
 public:
  LuaAppActivity(GfxRenderer& renderer, MappedInputManager& mappedInput, std::string appName, std::string appDir);
  ~LuaAppActivity() override;

  void onEnter() override;
  void onExit() override;
  void loop() override;
  // Apps own the screen; the framework's render task has nothing to draw.
  void render(RenderLock&&) override {}
  bool skipLoopDelay() override { return false; }

 private:
  class Backend;  // firmware implementation of crosslua::Backend (in the .cpp)

  void startApp();
  void collectInput();
  void step();
  void showError(const std::string& title, const std::string& detail);
  void leave();
  void logMemory(const char* when) const;
  void launchWifi();
  void armWait();

  std::string appName_;
  std::string appDir_;
  std::string entry_ = "main.lua";
  std::unique_ptr<Backend> backend_;
  std::unique_ptr<crosslua::LuaVm> vm_;
  uint32_t waitDeadline_ = 0;
  uint32_t lastGcMs_ = 0;
  bool errorShown_ = false;
  bool leaving_ = false;
};
