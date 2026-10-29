#include "StoreBootstrapActivity.h"

#include <HalStorage.h>
#include <Logging.h>
#include <Memory.h>
#include <WiFi.h>

#include <algorithm>
#include <utility>

#include "activities/util/ConfirmationActivity.h"
#include "components/CatalogScreens.h"
#include "util/PluginLocations.h"

namespace {
// The store app lives in the fork repo (the same repository the OTA release check uses); raw.githubusercontent serves
// the default branch's tip. A fork overrides the repository with -DCROSSLUA_RELEASE_REPO="owner/name" exactly like
// OtaUpdater. The path is the app's folder inside sd_card_contents.
#ifndef CROSSLUA_RELEASE_REPO
#define CROSSLUA_RELEASE_REPO "jerji/crosslua"
#endif
constexpr const char* STORE_BASE_URL = "https://raw.githubusercontent.com/" CROSSLUA_RELEASE_REPO
                                       "/lua-runtime/sd_card_contents/plugins/tools/"
                                       "app_store_lua/";
constexpr const char* STORE_DIR = "/plugins/tools/app_store_lua";
constexpr const char* STORE_INSTALL_MARKER = "/plugins/tools/app_store_lua/.installing";
// The minimum a store needs to become a listed app: manifest for discovery/title, main.lua to run.
constexpr const char* STORE_FILES[] = {"manifest.json", "main.lua"};

std::string storePath(const char* filename) { return std::string(STORE_DIR) + "/" + filename; }
}  // namespace

StoreBootstrapActivity::StoreBootstrapActivity(GfxRenderer& renderer, MappedInputManager& mappedInput)
    : CatalogActivity("StoreBootstrap", renderer, mappedInput) {}

bool StoreBootstrapActivity::isAvailable() {
  // The store can live flat or under the tools category.  findPluginDirOnDisk uses flat-first, but a stale empty
  // stub (files wiped, empty dir) from a plugin clean-up would return the flat stub with no main.lua.  Check the
  // actual marker file on both paths instead.
  static constexpr const char* PATHS[] = {"/plugins/app_store_lua/main.lua", "/plugins/tools/app_store_lua/main.lua"};
  return std::any_of(std::begin(PATHS), std::end(PATHS), [](const char* p) { return Storage.exists(p); });
}

void StoreBootstrapActivity::onEnter() {
  CatalogActivity::onEnter();

  auto confirmation = makeUniqueNoThrow<ConfirmationActivity>(renderer, mappedInput, "Get the Lua App Store",
                                                              "Downloads the Lua App Store app (no plugins yet). "
                                                              "It installs Lua apps from the release bundle.",
                                                              "Cancel", "Download");
  if (!confirmation) {
    LOG_ERR("STORE", "OOM: store bootstrap confirmation");
    fail(StrId::STR_MEMORY_ERROR);
    return;
  }

  startActivityForResult(std::move(confirmation), [this](const ActivityResult& result) {
    if (result.isCancelled) {
      finish();
      return;
    }
    state = State::CHECK_WIFI;
    statusMessage = "Checking WiFi...";
    requestUpdate();
    checkAndConnectWifi();
  });
}

void StoreBootstrapActivity::startBrowse() {
  beginDownload("Downloading the Lua App Store...");
  requestUpdateAndWait();
  finishDownload(installStoreApp());
}

HttpDownloader::DownloadError StoreBootstrapActivity::installStoreApp() {
  const std::string toolsDir = "/plugins/tools";
  if ((!Storage.exists("/plugins") && !Storage.mkdir("/plugins")) ||
      (!Storage.exists(toolsDir.c_str()) && !Storage.mkdir(toolsDir.c_str()))) {
    LOG_ERR("STORE", "Unable to create plugin root");
    return HttpDownloader::FILE_ERROR;
  }

  const bool installDirExisted = Storage.exists(STORE_DIR);
  if (!installDirExisted && !Storage.mkdir(STORE_DIR)) {
    LOG_ERR("STORE", "Unable to create %s", STORE_DIR);
    return HttpDownloader::FILE_ERROR;
  }

  cleanupStagedFiles();

  for (const char* filename : STORE_FILES) {
    const std::string dest = storePath(filename);
    const std::string staged = dest + ".new";
    const std::string url = std::string(STORE_BASE_URL) + filename;
    const auto result = downloadFile(url, staged);
    if (result != HttpDownloader::OK) {
      cleanupStagedFiles();
      if (!installDirExisted) Storage.rmdir(STORE_DIR);
      return result;
    }
  }

  if (!Storage.writeFile(STORE_INSTALL_MARKER, String("installing"))) {
    cleanupStagedFiles();
    return HttpDownloader::FILE_ERROR;
  }

  for (const char* filename : STORE_FILES) {
    const std::string dest = storePath(filename);
    const std::string staged = dest + ".new";
    if (!Storage.replaceFile(staged.c_str(), dest.c_str())) {
      LOG_ERR("STORE", "Install swap failed: %s", dest.c_str());
      cleanupStagedFiles();
      return HttpDownloader::FILE_ERROR;
    }
  }

  if (!Storage.remove(STORE_INSTALL_MARKER)) {
    LOG_ERR("STORE", "Unable to clear install marker");
    return HttpDownloader::FILE_ERROR;
  }
  return HttpDownloader::OK;
}

void StoreBootstrapActivity::cleanupStagedFiles() {
  for (const char* filename : STORE_FILES) {
    const std::string staged = storePath(filename) + ".new";
    Storage.remove(staged.c_str());
  }
}

void StoreBootstrapActivity::wifiSelectionCancelled() {
  WiFi.disconnect(true);
  WiFi.mode(WIFI_OFF);
  ActivityResult result;
  result.isCancelled = true;
  setResult(std::move(result));
  finish();
}

void StoreBootstrapActivity::downloadFinished(const bool cancelled) {
  if (cancelled) {
    finish();
    return;
  }
  state = State::DONE;
  requestUpdate();
}

bool StoreBootstrapActivity::handleCustomInput() {
  if (CatalogActivity::handleCustomInput()) return true;
  if (state != State::DONE) return false;

  int x = 0, y = 0;
  if (mappedInput.wasReleased(MappedInputManager::Button::Back) ||
      mappedInput.wasReleased(MappedInputManager::Button::Confirm) || mappedInput.wasScreenTapped(x, y)) {
    finish();
  }
  return true;
}

void StoreBootstrapActivity::onBackButton() { finish(); }

void StoreBootstrapActivity::buildScreen(UiScreen& screen) {
  screenHeader(screen, "Get the Lua App Store");
  if (buildStatusScreen(screen, true, true)) return;

  if (state == State::DONE) {
    catalogCenteredBlock(screen, {{"Lua App Store downloaded", true}, {"Open Home -> Plugins to run it"}});
  }
}