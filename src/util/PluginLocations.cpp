#include "PluginLocations.h"

#include <HalStorage.h>

#include <algorithm>

#include "CrossPointSettings.h"

namespace PluginLocations {

namespace {
// The marker files a CrossPoint/CrossLua plugin folder can carry. Returns true when the folder is a plugin.
bool classifyMarkers(const std::string& dir, Entry& e) {
  e.hasPluginJs = Storage.exists((dir + "/plugin.js").c_str());
  e.hasDevice = Storage.exists((dir + "/device.json").c_str());
  e.hasManifest = Storage.exists((dir + "/manifest.json").c_str());
  e.hasLua = Storage.exists((dir + "/main.lua").c_str());
  return e.hasPluginJs || e.hasDevice || e.hasManifest || e.hasLua;
}
}  // namespace

// Plugins are either a direct child of a root (flat, "uncategorized") or one level deeper under a category folder.
// A direct child with no plugin markers is a category: its direct children that carry markers are its apps.
std::vector<Entry> scanPluginsOnDisk() {
  std::vector<Entry> plugins;
  plugins.reserve(16);
  std::vector<std::string> seen;  // "<category>/<name>" — earlier roots win on collisions
  seen.reserve(16);
  for (size_t r = 0; r < ROOT_COUNT; r++) {
    HalFile root = Storage.open(ROOTS[r]);
#ifdef QEMU_SIM
    LOG_ERR("ACTSIM", "scan root %s: open=%d isDir=%d", ROOTS[r], root.isOpen() ? 1 : 0,
            root.isDirectory() ? 1 : 0);
#endif
    if (!root || !root.isDirectory()) continue;
    for (HalFile entry = root.openNextFile(); entry; entry = root.openNextFile()) {
      if (!entry.isDirectory()) continue;
      char name[128];
      if (entry.getName(name, sizeof(name)) == 0 || name[0] == '.') continue;
      const std::string childDir = std::string(ROOTS[r]) + "/" + name;

      Entry flat;
      flat.name = name;
      flat.dir = childDir;
      if (classifyMarkers(childDir, flat)) {
        if (std::find(seen.begin(), seen.end(), "/" + std::string(name)) != seen.end()) continue;
        seen.emplace_back("/" + std::string(name));
        plugins.push_back(std::move(flat));
        continue;
      }

      // No markers -> a category folder. Its direct children that carry markers are its apps.
      HalFile cat = Storage.open(childDir.c_str());
      if (!cat || !cat.isDirectory()) continue;
      for (HalFile sub = cat.openNextFile(); sub; sub = cat.openNextFile()) {
        if (!sub.isDirectory()) continue;
        char subname[128];
        if (sub.getName(subname, sizeof(subname)) == 0 || subname[0] == '.') continue;
        Entry e;
        e.name = subname;
        e.dir = childDir + "/" + subname;
        if (!classifyMarkers(e.dir, e)) continue;
        const std::string key = name + std::string("/") + subname;
        if (std::find(seen.begin(), seen.end(), key) != seen.end()) continue;
        seen.emplace_back(key);
        e.category = name;
        plugins.push_back(std::move(e));
      }
    }
  }
  return plugins;
}

std::vector<Entry> scanPlugins() {
#ifndef QEMU_SIM
  if (!SETTINGS.pluginsEnabled) return {};
#else
  // The sim's settings object never loads settings.json, so pluginsEnabled
  // stays at its (disabled) default and the picker would show an empty list.
  // Gate the sim off: the device's user switch still applies on hardware.
#endif
  auto plugins = scanPluginsOnDisk();
  plugins.erase(std::remove_if(plugins.begin(), plugins.end(),
                               [](const Entry& entry) {
                                 return !isDiscoverableEntry(isPluginQuarantined(entry.dir), entry.hasPluginJs,
                                                             entry.hasDevice, entry.hasManifest, entry.hasLua);
                               }),
                plugins.end());
  return plugins;
}

bool anyPluginInstalledOnDisk() {
  for (size_t r = 0; r < ROOT_COUNT; r++) {
    HalFile root = Storage.open(ROOTS[r]);
    if (!root || !root.isDirectory()) continue;
    for (HalFile entry = root.openNextFile(); entry; entry = root.openNextFile()) {
      if (!entry.isDirectory()) continue;
      char name[128];
      if (entry.getName(name, sizeof(name)) == 0 || name[0] == '.') continue;
      const std::string childDir = std::string(ROOTS[r]) + "/" + name;
      Entry e;
      if (classifyMarkers(childDir, e)) return true;
      // Category folder? Check its direct children.
      HalFile cat = Storage.open(childDir.c_str());
      if (!cat || !cat.isDirectory()) continue;
      for (HalFile sub = cat.openNextFile(); sub; sub = cat.openNextFile()) {
        if (!sub.isDirectory()) continue;
        char subname[128];
        if (sub.getName(subname, sizeof(subname)) == 0 || subname[0] == '.') continue;
        Entry se;
        if (classifyMarkers(childDir + "/" + subname, se)) return true;
      }
    }
  }
  return false;
}

std::string findPluginDirOnDisk(const char* name) {
  // Flat (uncategorized) first, so an app directly under a root wins over a same-named one in a category.
  for (size_t i = 0; i < ROOT_COUNT; i++) {
    std::string dir = std::string(ROOTS[i]) + "/" + name;
    if (Storage.exists(dir.c_str())) return dir;
  }
  // Then one level deeper under any category folder.
  for (size_t i = 0; i < ROOT_COUNT; i++) {
    HalFile root = Storage.open(ROOTS[i]);
    if (!root || !root.isDirectory()) continue;
    for (HalFile cat = root.openNextFile(); cat; cat = root.openNextFile()) {
      if (!cat.isDirectory()) continue;
      char cname[128];
      if (cat.getName(cname, sizeof(cname)) == 0 || cname[0] == '.') continue;
      std::string dir = std::string(ROOTS[i]) + "/" + cname + "/" + name;
      if (Storage.exists(dir.c_str())) return dir;
    }
  }
  return {};
}

bool isPluginQuarantined(const std::string& dir) { return Storage.exists((dir + "/" + INSTALL_MARKER).c_str()); }

std::string findPluginDir(const char* name) {
  if (!SETTINGS.pluginsEnabled) return {};
  const std::string dir = findPluginDirOnDisk(name);
  if (dir.empty() || isPluginQuarantined(dir)) return {};
  return dir;
}

}  // namespace PluginLocations
