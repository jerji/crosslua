// ble.* — Bluetooth LE central. Mode "keyboard": scan for a BLE HID keyboard, pair with it (bonds are kept in NVS and reconnect on
// their own), and its key presses arrive as "key" events from input.wait()/input.poll(), with input.key() giving the details.
// Needs "bluetooth" in the manifest and the user's approval (a keyboard is a typing channel into the app).
// ONE stack at a time (~50 KB of RAM) and EXCLUSIVE with every WiFi mode: start refuses while WiFi, the hotspot, espnow, the
// sniffer or the injector holds the radio, and each of those refuses while Bluetooth is up. Everything is polled: the stack's
// tasks fill small buffers, Lua reads them (no callbacks). Arguments are validated into plain values before the backend is touched.
#include <cstring>

#include "LuaInternal.h"

namespace crosslua {
namespace {

constexpr int BLE_SCAN_MIN_MS = 500;
constexpr int BLE_SCAN_MAX_MS = 60000;
constexpr int BLE_SCAN_DEFAULT_MS = 5000;

int pushFail(lua_State* L, const char* msg) {
  lua_pushnil(L);
  lua_pushstring(L, msg);
  return 2;
}

int gateBle(lua_State* L) {
  if (!be(L).bleSupported()) return pushFail(L, "no bluetooth on this device");
  if (!be(L).bleAllowed()) return pushFail(L, BLE_DENIED);
  return 0;
}

// "AA:BB:CC:DD:EE:FF" (hex digits, either case): the form the scan reports. Anything else never reaches the stack.
bool validAddr(const char* s, size_t n) {
  if (n != 17) return false;
  for (size_t i = 0; i < 17; i++) {
    const char c = s[i];
    if (i % 3 == 2) {
      if (c != ':') return false;
    } else if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) {
      return false;
    }
  }
  return true;
}

const char* linkName(int link) {
  switch (link) {
    case Backend::BLE_CONNECTING: return "connecting";
    case Backend::BLE_CONNECTED: return "connected";
    case Backend::BLE_FAILED: return "failed";
    default: return "idle";
  }
}

void pushDevice(lua_State* L, const Backend::BleDevice& d) {
  lua_createtable(L, 0, 5);
  lua_pushstring(L, d.addr);
  lua_setfield(L, -2, "addr");
  lua_pushstring(L, d.name);
  lua_setfield(L, -2, "name");
  lua_pushinteger(L, d.rssi);
  lua_setfield(L, -2, "rssi");
  lua_pushboolean(L, d.connectable);
  lua_setfield(L, -2, "connectable");
  lua_pushboolean(L, d.hid);
  lua_setfield(L, -2, "hid");
}

// ble.start([mode]) -> true | nil, err. mode is "keyboard" (the default and, for now, the only one).
int ble_start(lua_State* L) {
  if (!lua_isnoneornil(L, 1)) {
    if (lua_type(L, 1) != LUA_TSTRING || strcmp(lua_tostring(L, 1), "keyboard") != 0) return pushFail(L, "mode must be \"keyboard\"");
  }
  if (int r = gateBle(L)) return r;
  if (be(L).bleRunning()) return pushFail(L, "bluetooth is already running (ble.stop() first)");
  if (be(L).espnowRunning()) return pushFail(L, "espnow is running: call espnow.stop() first");
  if (be(L).monitorRunning()) return pushFail(L, "the WiFi sniffer is running: call wifi.monitor_stop() first");
  if (be(L).txRunning()) return pushFail(L, "the injector is running: call wifi.tx_stop() first");
  if (be(L).netReady()) return pushFail(L, "the radio is in use by WiFi or the hotspot: call wifi.off() first");
  const size_t floor = be(L).radioFloorBytes();
  const size_t freeNow = be(L).freeHeap();
  if (freeNow < floor) {
    char msg[96];
    snprintf(msg, sizeof(msg), "not enough free RAM for bluetooth (free %uK, need %uK)", static_cast<unsigned>(freeNow / 1024),
             static_cast<unsigned>(floor / 1024));
    return pushFail(L, msg);
  }
  char err[96] = {0};
  if (!be(L).bleStart("keyboard", err, sizeof(err))) return pushFail(L, err[0] ? err : "cannot start bluetooth");
  lua_pushboolean(L, 1);
  return 1;
}

// ble.stop() -> true. Gives the stack and its RAM back. Always allowed (a script must be able to let go).
int ble_stop(lua_State* L) {
  be(L).bleStop();
  lua_pushboolean(L, 1);
  return 1;
}

// ble.scan([ms]) -> true | nil, err. Starts a scan that ends by itself after `ms` (500..60000, default 5000); read it with ble.devices().
int ble_scan(lua_State* L) {
  lua_Number ms = BLE_SCAN_DEFAULT_MS;
  if (!lua_isnoneornil(L, 1)) {
    if (lua_type(L, 1) != LUA_TNUMBER) return pushFail(L, "ms must be an integer 500..60000");
    ms = lua_tonumber(L, 1);
  }
  if (int r = gateBle(L)) return r;
  if (ms < BLE_SCAN_MIN_MS || ms > BLE_SCAN_MAX_MS || ms != static_cast<int>(ms)) return pushFail(L, "ms must be an integer 500..60000");
  if (!be(L).bleRunning()) return pushFail(L, "bluetooth is not running (call ble.start() first)");
  char err[96] = {0};
  if (!be(L).bleScan(static_cast<int>(ms), err, sizeof(err))) return pushFail(L, err[0] ? err : "cannot scan");
  lua_pushboolean(L, 1);
  return 1;
}

int ble_scan_stop(lua_State* L) {
  if (int r = gateBle(L)) return r;
  if (be(L).bleRunning()) be(L).bleScanStop();
  lua_pushboolean(L, 1);
  return 1;
}

// ble.devices() -> { {addr, name, rssi, connectable, hid}, ... } (strongest first is NOT promised: sort in Lua). nil, err when stopped.
int ble_devices(lua_State* L) {
  if (int r = gateBle(L)) return r;
  if (!be(L).bleRunning()) return pushFail(L, "bluetooth is not running (call ble.start() first)");
  Backend::BleDevice d[Backend::BLE_MAX_DEVICES];
  const int n = be(L).bleDevices(d, Backend::BLE_MAX_DEVICES);
  lua_createtable(L, n > 0 ? n : 0, 0);
  for (int i = 0; i < n && i < Backend::BLE_MAX_DEVICES; i++) {
    pushDevice(L, d[i]);
    lua_rawseti(L, -2, i + 1);
  }
  return 1;
}

// ble.connect(addr) -> true | nil, err. Starts pairing/connecting; ble.state() reports how it went (bonded peers reconnect alone).
int ble_connect(lua_State* L) {
  size_t n = 0;
  const char* addr = luaL_checklstring(L, 1, &n);
  if (int r = gateBle(L)) return r;
  if (!validAddr(addr, n)) return pushFail(L, "addr must look like AA:BB:CC:DD:EE:FF");
  if (!be(L).bleRunning()) return pushFail(L, "bluetooth is not running (call ble.start() first)");
  char err[96] = {0};
  if (!be(L).bleConnect(addr, err, sizeof(err))) return pushFail(L, err[0] ? err : "cannot connect");
  lua_pushboolean(L, 1);
  return 1;
}

int ble_disconnect(lua_State* L) {
  if (int r = gateBle(L)) return r;
  if (be(L).bleRunning()) be(L).bleDisconnect();
  lua_pushboolean(L, 1);
  return 1;
}

// ble.state() -> {running, mode, link = "idle"|"connecting"|"connected"|"failed", scanning, addr, name, passkey, reason}.
// `passkey` is set only while pairing waits for it to be typed on the keyboard (then Enter); `reason` only after a failure.
int ble_state(lua_State* L) {
  if (int r = gateBle(L)) return r;
  const bool running = be(L).bleRunning();
  lua_createtable(L, 0, 8);
  lua_pushboolean(L, running);
  lua_setfield(L, -2, "running");
  if (!running) {
    lua_pushstring(L, "idle");
    lua_setfield(L, -2, "link");
    lua_pushboolean(L, 0);
    lua_setfield(L, -2, "scanning");
    return 1;
  }
  Backend::BleState s;
  memset(&s, 0, sizeof(s));
  be(L).bleState(&s);
  lua_pushstring(L, "keyboard");
  lua_setfield(L, -2, "mode");
  lua_pushstring(L, linkName(s.link));
  lua_setfield(L, -2, "link");
  lua_pushboolean(L, s.scanning);
  lua_setfield(L, -2, "scanning");
  if (s.addr[0]) {
    lua_pushstring(L, s.addr);
    lua_setfield(L, -2, "addr");
    lua_pushstring(L, s.name);
    lua_setfield(L, -2, "name");
  }
  if (s.hasPasskey) {
    lua_pushinteger(L, static_cast<lua_Integer>(s.passkey));
    lua_setfield(L, -2, "passkey");
  }
  if (s.link == Backend::BLE_FAILED && s.reason[0]) {
    lua_pushstring(L, s.reason);
    lua_setfield(L, -2, "reason");
  }
  return 1;
}

// ble.paired() -> { {addr, name}, ... } the bonded peers (read through the running stack, so it needs ble.start()).
int ble_paired(lua_State* L) {
  if (int r = gateBle(L)) return r;
  if (!be(L).bleRunning()) return pushFail(L, "bluetooth is not running (call ble.start() first)");
  Backend::BleDevice d[Backend::BLE_MAX_DEVICES];
  const int n = be(L).blePaired(d, Backend::BLE_MAX_DEVICES);
  lua_createtable(L, n > 0 ? n : 0, 0);
  for (int i = 0; i < n && i < Backend::BLE_MAX_DEVICES; i++) {
    lua_createtable(L, 0, 2);
    lua_pushstring(L, d[i].addr);
    lua_setfield(L, -2, "addr");
    lua_pushstring(L, d[i].name);
    lua_setfield(L, -2, "name");
    lua_rawseti(L, -2, i + 1);
  }
  return 1;
}

// ble.forget(addr) -> true | nil, err. Removes the bond (the keyboard has to be paired again).
int ble_forget(lua_State* L) {
  size_t n = 0;
  const char* addr = luaL_checklstring(L, 1, &n);
  if (int r = gateBle(L)) return r;
  if (!validAddr(addr, n)) return pushFail(L, "addr must look like AA:BB:CC:DD:EE:FF");
  if (!be(L).bleRunning()) return pushFail(L, "bluetooth is not running (call ble.start() first)");
  if (!be(L).bleForget(addr)) return pushFail(L, "that device is not paired");
  lua_pushboolean(L, 1);
  return 1;
}

}  // namespace

void registerBle(lua_State* L, Ctx* c) {
  static const luaL_Reg fns[] = {{"start", ble_start},     {"stop", ble_stop},       {"scan", ble_scan},     {"scan_stop", ble_scan_stop},
                                 {"devices", ble_devices}, {"connect", ble_connect}, {"disconnect", ble_disconnect},
                                 {"state", ble_state},     {"paired", ble_paired},   {"forget", ble_forget}, {nullptr, nullptr}};
  regTable(L, c, "ble", fns);
}

}  // namespace crosslua
