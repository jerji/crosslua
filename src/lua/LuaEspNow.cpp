// espnow.* — ESP-NOW: connectionless 802.11 vendor frames between nearby devices (no access point, no router, no DHCP). Needs
// "network" + "espnow" in the manifest and the user's approval. The radio is exclusive: it cannot run next to a joined WiFi network
// or a hotspot (the same chip, one channel). Receiving is polled from a small ring the backend fills from the WiFi task, so no Lua
// code ever runs in a callback. Arguments are validated into plain values before the backend is touched.
#include <cstring>

#include "LuaInternal.h"

namespace crosslua {
namespace {

constexpr int ESPNOW_MAX_DATA = 250;  // ESP-NOW v1 payload limit
constexpr int ESPNOW_CHANNELS = 13;

int pushFail(lua_State* L, const char* msg) {
  lua_pushnil(L);
  lua_pushstring(L, msg);
  return 2;
}

int gateEspNow(lua_State* L) {
  if (!be(L).netAllowed()) return pushFail(L, NET_DENIED);
  if (!be(L).espnowAllowed()) return pushFail(L, ESPNOW_DENIED);
  return 0;
}

void macToString(const uint8_t mac[6], char out[18]) {
  snprintf(out, 18, "%02x:%02x:%02x:%02x:%02x:%02x", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

int hexVal(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

// "aa:bb:cc:dd:ee:ff" (either case) -> 6 bytes
bool parseMac(const char* s, uint8_t out[6]) {
  if (strlen(s) != 17) return false;
  for (int i = 0; i < 6; i++) {
    const char* p = s + i * 3;
    const int hi = hexVal(p[0]), lo = hexVal(p[1]);
    if (hi < 0 || lo < 0) return false;
    if (i < 5 && p[2] != ':') return false;
    out[i] = static_cast<uint8_t>(hi * 16 + lo);
  }
  return true;
}

// espnow.start([{channel = 1..13}]) -> true, mac | nil, err. Takes over the radio (WiFi must be off).
int espnow_start(lua_State* L) {
  lua_Number channel = 1;
  if (!lua_isnoneornil(L, 1)) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_pushnil(L);
    while (lua_next(L, 1)) {
      if (lua_type(L, -2) != LUA_TSTRING) return pushFail(L, "options must have string keys");
      const char* k = lua_tostring(L, -2);
      if (!strcmp(k, "channel")) {
        if (lua_type(L, -1) != LUA_TNUMBER) return pushFail(L, "channel must be an integer 1..13");
        channel = lua_tonumber(L, -1);
      } else {
        char msg[64];
        snprintf(msg, sizeof(msg), "unknown option '%.24s'", k);
        return pushFail(L, msg);
      }
      lua_pop(L, 1);
    }
  }
  if (int r = gateEspNow(L)) return r;
  if (channel < 1 || channel > ESPNOW_CHANNELS || channel != static_cast<int>(channel)) return pushFail(L, "channel must be an integer 1..13");
  if (be(L).espnowRunning()) return pushFail(L, "espnow is already running (espnow.stop() first)");
  if (be(L).monitorRunning()) return pushFail(L, "the WiFi sniffer is running: call wifi.monitor_stop() first");
  if (be(L).netReady()) return pushFail(L, "the radio is in use by WiFi or the hotspot: call wifi.off() first");
  const size_t floor = be(L).radioFloorBytes();
  const size_t freeNow = be(L).freeHeap();
  if (freeNow < floor) {
    char msg[96];
    snprintf(msg, sizeof(msg), "not enough free RAM for espnow (free %uK, need %uK)", static_cast<unsigned>(freeNow / 1024),
             static_cast<unsigned>(floor / 1024));
    return pushFail(L, msg);
  }
  uint8_t mac[6] = {0};
  char err[96] = {0};
  if (!be(L).espnowStart(static_cast<int>(channel), mac, err, sizeof(err))) return pushFail(L, err[0] ? err : "cannot start espnow");
  char ms[18];
  macToString(mac, ms);
  lua_pushboolean(L, 1);
  lua_pushstring(L, ms);
  return 2;
}

// espnow.send(to, data) -> true | nil, err. `to` = "aa:bb:cc:dd:ee:ff" or "broadcast" (or nil). data 1..250 bytes.
// true means the frame was handed to the radio; ESP-NOW has no delivery guarantee (retransmit in your protocol).
int espnow_send(lua_State* L) {
  const bool broadcast = lua_isnoneornil(L, 1);
  const char* to = broadcast ? nullptr : luaL_checkstring(L, 1);
  size_t n = 0;
  const char* data = luaL_checklstring(L, 2, &n);
  if (int r = gateEspNow(L)) return r;
  uint8_t mac[6];
  bool bc = broadcast;
  if (!broadcast) {
    if (!strcmp(to, "broadcast")) bc = true;
    else if (!parseMac(to, mac)) return pushFail(L, "mac must be 'aa:bb:cc:dd:ee:ff' or \"broadcast\"");
  }
  if (bc) memset(mac, 0xFF, sizeof(mac));
  if (n < 1 || n > static_cast<size_t>(ESPNOW_MAX_DATA)) return pushFail(L, "data must be 1..250 bytes");
  if (!be(L).espnowRunning()) return pushFail(L, "espnow is not started (call espnow.start() first)");
  char err[96] = {0};
  if (!be(L).espnowSend(mac, bc, data, n, err, sizeof(err))) return pushFail(L, err[0] ? err : "send failed");
  lua_pushboolean(L, 1);
  return 1;
}

// espnow.recv() -> data, mac | nil (nothing waiting) | nil, err (not started). Never blocks.
int espnow_recv(lua_State* L) {
  if (int r = gateEspNow(L)) return r;
  if (!be(L).espnowRunning()) return pushFail(L, "espnow is not started (call espnow.start() first)");
  uint8_t buf[ESPNOW_MAX_DATA];
  uint8_t mac[6];
  const int n = be(L).espnowRecv(buf, sizeof(buf), mac);
  if (n <= 0) {
    lua_pushnil(L);
    return 1;
  }
  char ms[18];
  macToString(mac, ms);
  lua_pushlstring(L, reinterpret_cast<const char*>(buf), static_cast<size_t>(n));
  lua_pushstring(L, ms);
  return 2;
}

// espnow.info() -> {mac, channel, dropped} | nil, err. `dropped` counts frames lost because the receive ring was full.
int espnow_info(lua_State* L) {
  if (int r = gateEspNow(L)) return r;
  uint8_t mac[6];
  int channel = 0, dropped = 0;
  if (!be(L).espnowInfo(mac, &channel, &dropped)) return pushFail(L, "espnow is not started (call espnow.start() first)");
  char ms[18];
  macToString(mac, ms);
  lua_createtable(L, 0, 3);
  lua_pushstring(L, ms);
  lua_setfield(L, -2, "mac");
  lua_pushinteger(L, channel);
  lua_setfield(L, -2, "channel");
  lua_pushinteger(L, dropped);
  lua_setfield(L, -2, "dropped");
  return 1;
}

// espnow.stop() -> true. Gives the radio back. Always allowed.
int espnow_stop(lua_State* L) {
  be(L).espnowStop();
  lua_pushboolean(L, 1);
  return 1;
}

}  // namespace

void registerEspNow(lua_State* L, Ctx* c) {
  static const luaL_Reg fns[] = {{"start", espnow_start}, {"send", espnow_send}, {"recv", espnow_recv},
                                 {"info", espnow_info},   {"stop", espnow_stop},  {nullptr, nullptr}};
  regTable(L, c, "espnow", fns);
}

}  // namespace crosslua
