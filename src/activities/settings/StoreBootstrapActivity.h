#pragma once

#include "activities/CatalogActivity.h"

// CrossLua App Store bootstrap: download the store app (a normal Lua plugin) straight from the fork's repo when no
// plugin is installed, so the picker can NEVER be left without a way to install apps. Same staged-download +
// atomic-swap pattern as PluginHubInstallActivity (upstream), but the source is raw.githubusercontent.com of this
// fork (the OTA release repo) and the payload is the App Store app's own files. Once present, the store app itself
// downloads and installs the full apps bundle from the release.
class StoreBootstrapActivity final : public CatalogActivity {
 public:
  explicit StoreBootstrapActivity(GfxRenderer& renderer, MappedInputManager& mappedInput);

  // True when the store app is already on the card (nothing to bootstrap).
  static bool isAvailable();

  void onEnter() override;

 private:
  int listCount() const override { return 0; }
  bool hasSearch() const override { return false; }
  void activateIndex(int) override {}
  void buildScreen(UiScreen& screen) override;
  bool handleCustomInput() override;
  void onBackButton() override;
  void startBrowse() override;
  void retryBrowse() override { startBrowse(); }
  void performSearch(const std::string&) override {}
  void downloadFinished(bool cancelled) override;
  void wifiSelectionCancelled() override;

  HttpDownloader::DownloadError installStoreApp();
  static void cleanupStagedFiles();
};