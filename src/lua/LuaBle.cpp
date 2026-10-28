// ble.* — Bluetooth LE central. Mode "keyboard": scan for a BLE HID keyboard, pair with it (bonds are kept in NVS and
// reconnect on their own), and its key presses arrive as "key" events from input.wait()/input.poll(), with input.key()
// giving the details. Mode "raw": the observer itself: ble.observe() + ble.adverts() hand the scripts every
// advertisement as received (advertising data then scan response, up to 62 bytes) for them to parse. One mode at a
// time; the stack is the same ~50 KB either way. Needs "bluetooth" in the manifest and the user's approval (a keyboard
// is a typing channel into the app). ONE stack at a time (~50 KB of RAM) and EXCLUSIVE with every WiFi mode: start
// refuses while WiFi, the hotspot, espnow, the sniffer or the injector holds the radio, and each of those refuses while
// Bluetooth is up. Everything is polled: the stack's tasks fill small buffers, Lua reads them (no callbacks). Arguments
// are validated into plain values before the backend is touched.
#include <cstring>

#include "LuaInternal.h"

namespace crosslua {
namespace {

constexpr int BLE_SCAN_MIN_MS = 500;
constexpr int BLE_SCAN_MAX_MS = 60000;
constexpr int BLE_SCAN_DEFAULT_MS = 5000;
constexpr int BLE_OBSERVE_MIN_MS = 500;
constexpr int BLE_OBSERVE_MAX_MS = 600000;  // 0 means "until ble.observe_stop()"

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

// The keyboard calls only make sense in keyboard mode; the raw calls only in raw mode. 0 = fine, else the nil, err
// pair.
int needMode(lua_State* L, int mode) {
  if (!be(L).bleRunning()) return pushFail(L, "bluetooth is not running (call ble.start() first)");
  if (be(L).bleMode() == mode) return 0;
  return pushFail(L, mode == Backend::BLE_MODE_KEYBOARD
                         ? "this needs ble.start(\"keyboard\") (bluetooth is running in raw mode)"
                         : "this needs ble.start(\"raw\") (bluetooth is running in keyboard mode)");
}

// The connection calls work in keyboard mode (the HID host) and gatt mode (the GATT client), but never raw mode.
int needClientMode(lua_State* L) {
  if (!be(L).bleRunning()) return pushFail(L, "bluetooth is not running (call ble.start() first)");
  const int m = be(L).bleMode();
  if (m == Backend::BLE_MODE_KEYBOARD || m == Backend::BLE_MODE_GATT) return 0;
  return pushFail(L, "this needs ble.start(\"keyboard\") or ble.start(\"gatt\") (bluetooth is running in raw mode)");
}

const char* modeName(int mode) {
  switch (mode) {
    case Backend::BLE_MODE_RAW:
      return "raw";
    case Backend::BLE_MODE_GATT:
      return "gatt";
    case Backend::BLE_MODE_KEYBOARD:
      return "keyboard";
    default:
      return "none";
  }
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
    case Backend::BLE_CONNECTING:
      return "connecting";
    case Backend::BLE_CONNECTED:
      return "connected";
    case Backend::BLE_FAILED:
      return "failed";
    default:
      return "idle";
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

// ble.start([mode]) -> true | nil, err. mode is "keyboard" (the default), "raw" or "gatt".
int ble_start(lua_State* L) {
  const char* mode = "keyboard";
  if (!lua_isnoneornil(L, 1)) {
    if (lua_type(L, 1) != LUA_TSTRING) return pushFail(L, "mode must be \"keyboard\", \"raw\" or \"gatt\"");
    mode = lua_tostring(L, 1);
    if (strcmp(mode, "keyboard") != 0 && strcmp(mode, "raw") != 0 && strcmp(mode, "gatt") != 0)
      return pushFail(L, "mode must be \"keyboard\", \"raw\" or \"gatt\"");
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
    snprintf(msg, sizeof(msg), "not enough free RAM for bluetooth (free %uK, need %uK)",
             static_cast<unsigned>(freeNow / 1024), static_cast<unsigned>(floor / 1024));
    return pushFail(L, msg);
  }
  char err[96] = {0};
  if (!be(L).bleStart(mode, err, sizeof(err))) return pushFail(L, err[0] ? err : "cannot start bluetooth");
  lua_pushboolean(L, 1);
  return 1;
}

// ble.stop() -> true. Gives the stack and its RAM back. Always allowed (a script must be able to let go).
int ble_stop(lua_State* L) {
  be(L).bleStop();
  lua_pushboolean(L, 1);
  return 1;
}

// ble.scan([ms]) -> true | nil, err. Starts a scan that ends by itself after `ms` (500..60000, default 5000); read it
// with ble.devices().
int ble_scan(lua_State* L) {
  lua_Number ms = BLE_SCAN_DEFAULT_MS;
  if (!lua_isnoneornil(L, 1)) {
    if (lua_type(L, 1) != LUA_TNUMBER) return pushFail(L, "ms must be an integer 500..60000");
    ms = lua_tonumber(L, 1);
  }
  if (int r = gateBle(L)) return r;
  if (ms < BLE_SCAN_MIN_MS || ms > BLE_SCAN_MAX_MS || ms != static_cast<int>(ms))
    return pushFail(L, "ms must be an integer 500..60000");
  if (int r = needMode(L, Backend::BLE_MODE_KEYBOARD)) return r;
  char err[96] = {0};
  if (!be(L).bleScan(static_cast<int>(ms), err, sizeof(err))) return pushFail(L, err[0] ? err : "cannot scan");
  lua_pushboolean(L, 1);
  return 1;
}

int ble_scan_stop(lua_State* L) {
  if (int r = gateBle(L)) return r;
  if (be(L).bleRunning() && be(L).bleMode() == Backend::BLE_MODE_KEYBOARD) be(L).bleScanStop();
  lua_pushboolean(L, 1);
  return 1;
}

// ble.devices() -> { {addr, name, rssi, connectable, hid}, ... } (strongest first is NOT promised: sort in Lua). nil,
// err when stopped.
int ble_devices(lua_State* L) {
  if (int r = gateBle(L)) return r;
  if (int r = needMode(L, Backend::BLE_MODE_KEYBOARD)) return r;
  Backend::BleDevice d[Backend::BLE_MAX_DEVICES];
  const int n = be(L).bleDevices(d, Backend::BLE_MAX_DEVICES);
  lua_createtable(L, n > 0 ? n : 0, 0);
  for (int i = 0; i < n && i < Backend::BLE_MAX_DEVICES; i++) {
    pushDevice(L, d[i]);
    lua_rawseti(L, -2, i + 1);
  }
  return 1;
}

// ble.connect(addr [, addr_type]) -> true | nil, err. Starts pairing/connecting; ble.state() reports how it went
// (bonded peers reconnect alone). addr_type is 0 (public, default) or 1 (random static) — only the gatt mode uses it
// (the scan's `addr_type` field).
int ble_connect(lua_State* L) {
  size_t n = 0;
  const char* addr = lua_tolstring(L, 1, &n);
  if (lua_type(L, 1) != LUA_TSTRING) return pushFail(L, "addr must look like AA:BB:CC:DD:EE:FF");
  int addrType = 0;
  if (!lua_isnoneornil(L, 2)) {
    if (lua_type(L, 2) != LUA_TNUMBER) return pushFail(L, "addr_type must be 0 (public) or 1 (random)");
    addrType = static_cast<int>(lua_tointeger(L, 2));
    if (addrType < 0 || addrType > 1) return pushFail(L, "addr_type must be 0 (public) or 1 (random)");
  }
  if (int r = gateBle(L)) return r;
  if (!validAddr(addr, n)) return pushFail(L, "addr must look like AA:BB:CC:DD:EE:FF");
  if (int r = needClientMode(L)) return r;
  char err[96] = {0};
  if (!be(L).bleConnect(addr, addrType, err, sizeof(err))) return pushFail(L, err[0] ? err : "cannot connect");
  lua_pushboolean(L, 1);
  return 1;
}

int ble_disconnect(lua_State* L) {
  if (int r = gateBle(L)) return r;
  if (be(L).bleRunning()) {
    const int m = be(L).bleMode();
    if (m == Backend::BLE_MODE_KEYBOARD || m == Backend::BLE_MODE_GATT) be(L).bleDisconnect();
  }
  lua_pushboolean(L, 1);
  return 1;
}

// ble.state() -> {running, mode, link = "idle"|"connecting"|"connected"|"failed", scanning, addr, name, passkey,
// reason}. `passkey` is set only while pairing waits for it to be typed on the keyboard (then Enter); `reason` only
// after a failure.
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
  const int mode = be(L).bleMode();
  const bool raw = mode == Backend::BLE_MODE_RAW;
  if (raw)
    s.scanning = be(L).bleObserving();
  else
    be(L).bleState(&s);
  lua_pushstring(L, modeName(mode));
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
  if (int r = needMode(L, Backend::BLE_MODE_KEYBOARD)) return r;
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
  if (int r = needMode(L, Backend::BLE_MODE_KEYBOARD)) return r;
  if (!be(L).bleForget(addr)) return pushFail(L, "that device is not paired");
  lua_pushboolean(L, 1);
  return 1;
}

// ble.observe([ms [, {active=false}]]) -> true | nil, err. Raw mode. Listens for advertisements for `ms` (500..600000,
// default 5000; 0 = until ble.observe_stop()). Passive by default: it sends nothing, so devices that put their name in
// the scan response show no name; active=true asks them for it (a scan request goes out for every scannable device it
// hears). Starting again clears the table.
int ble_observe(lua_State* L) {
  lua_Number ms = BLE_SCAN_DEFAULT_MS;
  bool active = false;
  if (!lua_isnoneornil(L, 1)) {
    if (lua_type(L, 1) != LUA_TNUMBER) return pushFail(L, "ms must be 0 or an integer 500..600000");
    ms = lua_tonumber(L, 1);
  }
  if (!lua_isnoneornil(L, 2)) {
    if (lua_type(L, 2) != LUA_TTABLE) return pushFail(L, "options must be a table like {active=true}");
    lua_getfield(L, 2, "active");
    if (!lua_isnil(L, -1)) {
      if (lua_type(L, -1) != LUA_TBOOLEAN) {
        lua_pop(L, 1);
        return pushFail(L, "active must be a boolean");
      }
      active = lua_toboolean(L, -1) != 0;
    }
    lua_pop(L, 1);
  }
  if (int r = gateBle(L)) return r;
  if (ms != static_cast<int>(ms) || (ms != 0 && (ms < BLE_OBSERVE_MIN_MS || ms > BLE_OBSERVE_MAX_MS)))
    return pushFail(L, "ms must be 0 or an integer 500..600000");
  if (int r = needMode(L, Backend::BLE_MODE_RAW)) return r;
  char err[96] = {0};
  if (!be(L).bleObserve(static_cast<int>(ms), active, err, sizeof(err)))
    return pushFail(L, err[0] ? err : "cannot observe");
  lua_pushboolean(L, 1);
  return 1;
}

int ble_observe_stop(lua_State* L) {
  if (int r = gateBle(L)) return r;
  if (be(L).bleRunning() && be(L).bleMode() == Backend::BLE_MODE_RAW) be(L).bleObserveStop();
  lua_pushboolean(L, 1);
  return 1;
}

// ble.adverts() -> list, dropped | nil, err. One entry per device heard since ble.observe() started, first heard first:
// {addr, addr_type, rssi, adv_type, connectable, scannable, adv_len, age_ms, data}. `data` is the advertising data
// followed by the scan response as raw bytes (parse the length/type/value structures yourself); `dropped` counts
// devices that did not fit (32).
int ble_adverts(lua_State* L) {
  if (int r = gateBle(L)) return r;
  if (int r = needMode(L, Backend::BLE_MODE_RAW)) return r;
  Backend::BleAdvert a[Backend::BLE_MAX_ADVERTS];
  int dropped = 0;
  const int n = be(L).bleAdverts(a, Backend::BLE_MAX_ADVERTS, &dropped);
  lua_createtable(L, n > 0 ? n : 0, 0);
  for (int i = 0; i < n && i < Backend::BLE_MAX_ADVERTS; i++) {
    lua_createtable(L, 0, 9);
    lua_pushstring(L, a[i].addr);
    lua_setfield(L, -2, "addr");
    lua_pushinteger(L, a[i].addrType);
    lua_setfield(L, -2, "addr_type");
    lua_pushinteger(L, a[i].rssi);
    lua_setfield(L, -2, "rssi");
    lua_pushinteger(L, a[i].advType);
    lua_setfield(L, -2, "adv_type");
    lua_pushboolean(L, a[i].connectable);
    lua_setfield(L, -2, "connectable");
    lua_pushboolean(L, a[i].scannable);
    lua_setfield(L, -2, "scannable");
    lua_pushinteger(L, a[i].advLen);
    lua_setfield(L, -2, "adv_len");
    lua_pushinteger(L, static_cast<lua_Integer>(a[i].ageMs));
    lua_setfield(L, -2, "age_ms");
    lua_pushlstring(L, reinterpret_cast<const char*>(a[i].data),
                    a[i].len > sizeof(a[i].data) ? sizeof(a[i].data) : a[i].len);
    lua_setfield(L, -2, "data");
    lua_rawseti(L, -2, i + 1);
  }
  lua_pushinteger(L, dropped);
  return 2;
}

// --- gatt mode: a generic GATT client ---------------------------------------------------------

int needGatt(lua_State* L) {
  if (!be(L).bleRunning()) return pushFail(L, "bluetooth is not running (call ble.start() first)");
  if (be(L).bleMode() == Backend::BLE_MODE_GATT) return 0;
  return pushFail(L, "this needs ble.start(\"gatt\")");
}

// A characteristic UUID as the scan lists it: the 16-bit short form ("2a19") or the full 128-bit
// "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" / 32-hex-digit form, either case. Light check only (1..36 chars, no NUL):
// the backend (NimBLE) does the real parse and reports an unknown UUID.
bool okUuid(const char* s, size_t n) { return n >= 1 && n <= 36; }

// ble.services() -> { {service, uuid, handle, props}, ... } | nil, err. The discovered characteristics, in
// attribute order. props is the bitmask (0x02 read, 0x04 write-no-response, 0x08 write, 0x10 notify, 0x20 indicate).
int ble_services(lua_State* L) {
  if (int r = gateBle(L)) return r;
  if (int r = needGatt(L)) return r;
  Backend::BleGattChar c[Backend::BLE_MAX_GATT_CHARS];
  const int n = be(L).bleGattServices(c, Backend::BLE_MAX_GATT_CHARS);
  if (n < 0) return pushFail(L, "not connected (ble.connect then wait for ble.state().link == \"connected\")");
  lua_createtable(L, n > 0 ? n : 0, 0);
  for (int i = 0; i < n && i < Backend::BLE_MAX_GATT_CHARS; i++) {
    lua_createtable(L, 0, 4);
    lua_pushstring(L, c[i].service);
    lua_setfield(L, -2, "service");
    lua_pushstring(L, c[i].uuid);
    lua_setfield(L, -2, "uuid");
    lua_pushinteger(L, c[i].handle);
    lua_setfield(L, -2, "handle");
    lua_pushinteger(L, c[i].props);
    lua_setfield(L, -2, "props");
    lua_rawseti(L, -2, i + 1);
  }
  return 1;
}

// ble.read(uuid) -> data, err | nil, err. Reads the characteristic's value as a byte string.
int ble_read(lua_State* L) {
  if (lua_type(L, 1) != LUA_TSTRING) return pushFail(L, "uuid must be a string");
  size_t un = 0;
  const char* uuid = lua_tolstring(L, 1, &un);
  if (int r = gateBle(L)) return r;
  if (!okUuid(uuid, un)) return pushFail(L, "uuid must be a 1..36 character string");
  if (int r = needGatt(L)) return r;
  uint8_t buf[244];
  size_t len = 0;
  char err[96] = {0};
  if (!be(L).bleGattRead(uuid, buf, &len, sizeof(buf), err, sizeof(err)))
    return pushFail(L, err[0] ? err : "cannot read");
  lua_pushlstring(L, reinterpret_cast<const char*>(buf), len);
  return 1;
}

// ble.write(uuid, data [, {no_response=false}]) -> true | nil, err. Writes the value (string, max 244 bytes).
int ble_write(lua_State* L) {
  if (lua_type(L, 1) != LUA_TSTRING) return pushFail(L, "uuid must be a string");
  if (lua_type(L, 2) != LUA_TSTRING) return pushFail(L, "data must be a string");
  size_t un = 0;
  const char* uuid = lua_tolstring(L, 1, &un);
  size_t dlen = 0;
  const char* data = lua_tolstring(L, 2, &dlen);
  bool noResponse = false;
  if (!lua_isnoneornil(L, 3)) {
    if (lua_type(L, 3) == LUA_TBOOLEAN) {
      noResponse = lua_toboolean(L, 3) != 0;
    } else if (lua_type(L, 3) == LUA_TTABLE) {
      lua_getfield(L, 3, "no_response");
      if (!lua_isnil(L, -1)) {
        if (lua_type(L, -1) != LUA_TBOOLEAN) {
          lua_pop(L, 1);
          return pushFail(L, "no_response must be a boolean");
        }
        noResponse = lua_toboolean(L, -1) != 0;
      }
      lua_pop(L, 1);
    } else {
      return pushFail(L, "options must be a boolean or {no_response=true}");
    }
  }
  if (int r = gateBle(L)) return r;
  if (!okUuid(uuid, un)) return pushFail(L, "uuid must be a 1..36 character string");
  if (dlen > 244) return pushFail(L, "value too long (max 244 bytes)");
  if (int r = needGatt(L)) return r;
  char err[96] = {0};
  if (!be(L).bleGattWrite(uuid, reinterpret_cast<const uint8_t*>(data), dlen, noResponse, err, sizeof(err)))
    return pushFail(L, err[0] ? err : "cannot write");
  lua_pushboolean(L, 1);
  return 1;
}

// ble.notify(uuid, on) -> true | nil, err. Subscribes (on=true) or unsubscribes (on=false) to notifications /
// indications on that characteristic; they then arrive via ble.notifs().
int ble_notify(lua_State* L) {
  if (lua_type(L, 1) != LUA_TSTRING) return pushFail(L, "uuid must be a string");
  if (lua_type(L, 2) != LUA_TBOOLEAN) return pushFail(L, "on must be a boolean");
  size_t un = 0;
  const char* uuid = lua_tolstring(L, 1, &un);
  const bool on = lua_toboolean(L, 2) != 0;
  if (int r = gateBle(L)) return r;
  if (!okUuid(uuid, un)) return pushFail(L, "uuid must be a 1..36 character string");
  if (int r = needGatt(L)) return r;
  char err[96] = {0};
  if (!be(L).bleGattNotify(uuid, on, err, sizeof(err)))
    return pushFail(L, err[0] ? err : "cannot change notify");
  lua_pushboolean(L, 1);
  return 1;
}

// ble.notifs() -> { {uuid, data}, ... } the pending notifications, oldest first (at most 32; drain often).
int ble_notifs(lua_State* L) {
  if (int r = gateBle(L)) return r;
  if (int r = needGatt(L)) return r;
  Backend::BleGattNotif n[Backend::BLE_MAX_GATT_NOTIFS];
  const int cnt = be(L).bleGattNotifs(n, Backend::BLE_MAX_GATT_NOTIFS);
  lua_createtable(L, cnt > 0 ? cnt : 0, 0);
  for (int i = 0; i < cnt && i < Backend::BLE_MAX_GATT_NOTIFS; i++) {
    lua_createtable(L, 0, 2);
    lua_pushstring(L, n[i].uuid);
    lua_setfield(L, -2, "uuid");
    lua_pushlstring(L, reinterpret_cast<const char*>(n[i].data), n[i].len);
    lua_setfield(L, -2, "data");
    lua_rawseti(L, -2, i + 1);
  }
  return 1;
}

}  // namespace

int ble_advertise(lua_State* L);
int ble_advertise_stop(lua_State* L);
int ble_advertising(lua_State* L);

void registerBle(lua_State* L, Ctx* c) {
  static const luaL_Reg fns[] = {
      {"start", ble_start},           {"stop", ble_stop},       {"scan", ble_scan},
      {"scan_stop", ble_scan_stop},   {"devices", ble_devices}, {"connect", ble_connect},
      {"disconnect", ble_disconnect}, {"state", ble_state},     {"paired", ble_paired},
      {"forget", ble_forget},         {"observe", ble_observe}, {"observe_stop", ble_observe_stop},
      {"adverts", ble_adverts},       {"services", ble_services}, {"read", ble_read},
      {"write", ble_write},           {"notify", ble_notify},   {"notifs", ble_notifs},
      {"advertise", ble_advertise},   {"advertise_stop", ble_advertise_stop}, {"advertising", ble_advertising},
      {nullptr, nullptr}};
  regTable(L, c, "ble", fns);
}

// ble.advertise({name=..., data=..., connectable=false, interval_ms=...}) -> true | nil, err (raw mode). Broadcasts
// a name and/or manufacturer data as an advertisement (a beacon by default). The observer and the broadcaster share
// the one stack, so you can keep scanning while you advertise.
int ble_advertise(lua_State* L) {
  if (lua_type(L, 1) != LUA_TTABLE) return pushFail(L, "options must be a table like {name=\"...\", data=\"...\"}");
  const char* name = "";
  const char* data = "";
  size_t dataLen = 0;
  bool connectable = false;
  int intervalMs = 0;
  uint16_t serviceUuid = 0;
  const char* serviceData = "";
  size_t serviceDataLen = 0;
  lua_getfield(L, 1, "name");
  if (!lua_isnil(L, -1)) {
    if (lua_type(L, -1) != LUA_TSTRING) {
      lua_pop(L, 1);
      return pushFail(L, "name must be a string");
    }
    name = lua_tostring(L, -1);
  }
  lua_pop(L, 1);
  lua_getfield(L, 1, "data");
  if (!lua_isnil(L, -1)) {
    if (lua_type(L, -1) != LUA_TSTRING) {
      lua_pop(L, 1);
      return pushFail(L, "data must be a string");
    }
    data = lua_tolstring(L, -1, &dataLen);
  }
  lua_pop(L, 1);
  lua_getfield(L, 1, "connectable");
  if (!lua_isnil(L, -1)) {
    if (lua_type(L, -1) != LUA_TBOOLEAN) {
      lua_pop(L, 1);
      return pushFail(L, "connectable must be a boolean");
    }
    connectable = lua_toboolean(L, -1) != 0;
  }
  lua_pop(L, 1);
  lua_getfield(L, 1, "interval_ms");
  if (!lua_isnil(L, -1)) {
    if (lua_type(L, -1) != LUA_TNUMBER) {
      lua_pop(L, 1);
      return pushFail(L, "interval_ms must be 0 or 20..10000");
    }
    intervalMs = static_cast<int>(lua_tointeger(L, -1));
    if (intervalMs < 0 || (intervalMs > 0 && (intervalMs < 20 || intervalMs > 10000))) {
      lua_pop(L, 1);
      return pushFail(L, "interval_ms must be 0 or 20..10000");
    }
  }
  lua_pop(L, 1);
  lua_getfield(L, 1, "service_uuid");
  if (!lua_isnil(L, -1)) {
    if (lua_type(L, -1) != LUA_TNUMBER) {
      lua_pop(L, 1);
      return pushFail(L, "service_uuid must be an integer 1..65535");
    }
    const lua_Integer su = lua_tointeger(L, -1);
    if (su < 1 || su > 65535) {
      lua_pop(L, 1);
      return pushFail(L, "service_uuid must be an integer 1..65535");
    }
    serviceUuid = static_cast<uint16_t>(su);
  }
  lua_pop(L, 1);
  lua_getfield(L, 1, "service_data");
  if (!lua_isnil(L, -1)) {
    if (lua_type(L, -1) != LUA_TSTRING) {
      lua_pop(L, 1);
      return pushFail(L, "service_data must be a string");
    }
    serviceData = lua_tolstring(L, -1, &serviceDataLen);
    if (serviceDataLen > 27) {
      lua_pop(L, 1);
      return pushFail(L, "service_data must be at most 27 bytes");
    }
    if (serviceUuid == 0) {
      lua_pop(L, 1);
      return pushFail(L, "service_data needs a service_uuid");
    }
  }
  lua_pop(L, 1);
  if (name[0] == 0 && dataLen == 0 && serviceUuid == 0)
    return pushFail(L, "advertise a name, data, service_data, or a combination");
  if (dataLen > 31) return pushFail(L, "data must be at most 31 bytes");
  if (int r = gateBle(L)) return r;
  if (int r = needMode(L, Backend::BLE_MODE_RAW)) return r;
  char err[96] = {0};
  if (!be(L).bleAdvertise(name, reinterpret_cast<const uint8_t*>(data), dataLen, connectable, intervalMs, serviceUuid,
                          reinterpret_cast<const uint8_t*>(serviceData), serviceDataLen, err, sizeof(err)))
    return pushFail(L, err[0] ? err : "cannot advertise");
  lua_pushboolean(L, 1);
  return 1;
}

int ble_advertise_stop(lua_State* L) {
  if (int r = gateBle(L)) return r;
  if (be(L).bleRunning() && be(L).bleMode() == Backend::BLE_MODE_RAW) be(L).bleAdvertiseStop();
  lua_pushboolean(L, 1);
  return 1;
}

// ble.advertising() -> boolean (raw mode). Whether the broadcaster is currently advertising.
int ble_advertising(lua_State* L) {
  if (int r = gateBle(L)) return r;
  if (int r = needMode(L, Backend::BLE_MODE_RAW)) return r;
  lua_pushboolean(L, be(L).bleAdvertising());
  return 1;
}

}  // namespace crosslua
