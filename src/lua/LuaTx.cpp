// wifi.tx_* — raw 802.11 frame injection. Needs "network" + "tx" in the manifest and the user's approval (the dialog label is
// "INJECT": sending arbitrary frames can deauthenticate other people's devices, so it is gated harder than the sniffer).
// The radio is exclusive with WiFi/the hotspot/espnow, but it COEXISTS with wifi.monitor on the same channel: a start with no
// channel adopts the other mode's channel, and an explicit different channel is refused, so a script can sniff and inject at once.
// Frames are validated into plain values before the backend is touched.
#include <cstring>

#include "LuaInternal.h"

namespace crosslua {
namespace {

constexpr int TX_MIN_LEN = 24;   // a frame control + addresses + sequence control: shorter cannot be a real 802.11 frame
constexpr int TX_MAX_LEN = 250;  // bounded like the receive ring; beacons and deauths fit
constexpr int TX_CHANNELS = 13;

int pushFail(lua_State* L, const char* msg) {
  lua_pushnil(L);
  lua_pushstring(L, msg);
  return 2;
}

int gateTx(lua_State* L) {
  if (!be(L).netAllowed()) return pushFail(L, NET_DENIED);
  if (!be(L).txAllowed()) return pushFail(L, TX_DENIED);
  return 0;
}

// wifi.tx_start([{channel=1..13}]) -> true | nil, err. The radio is exclusive, except wifi.monitor may keep running: then the
// channel is adopted (and an explicit different channel is refused, because the two modes share one radio).
int tx_start(lua_State* L) {
  lua_Number channel = 1;
  bool channelGiven = false;  // absent = adopt the sniffer's channel when one is running
  if (!lua_isnoneornil(L, 1)) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_pushnil(L);
    while (lua_next(L, 1)) {
      if (lua_type(L, -2) != LUA_TSTRING) return pushFail(L, "options must have string keys");
      const char* k = lua_tostring(L, -2);
      if (!strcmp(k, "channel")) {
        if (lua_type(L, -1) != LUA_TNUMBER) return pushFail(L, "channel must be an integer 1..13");
        channel = lua_tonumber(L, -1);
        channelGiven = true;
      } else {
        char msg[64];
        snprintf(msg, sizeof(msg), "unknown option '%.24s'", k);
        return pushFail(L, msg);
      }
      lua_pop(L, 1);
    }
  }
  if (int r = gateTx(L)) return r;
  if (channelGiven && (channel < 1 || channel > TX_CHANNELS || channel != static_cast<int>(channel))) return pushFail(L, "channel must be an integer 1..13");
  if (be(L).txRunning()) return pushFail(L, "the injector is already running (wifi.tx_stop() first)");
  if (be(L).espnowRunning()) return pushFail(L, "espnow is running: call espnow.stop() first");
  if (be(L).netReady()) return pushFail(L, "the radio is in use by WiFi or the hotspot: call wifi.off() first");
  int adopted = 0;
  if (be(L).monitorRunning() && !be(L).monitorChannel(&adopted)) return pushFail(L, "cannot read the sniffer's channel");
  if (be(L).monitorRunning()) {
    if (channelGiven && static_cast<int>(channel) != adopted) {
      char msg[96];
      snprintf(msg, sizeof(msg), "the sniffer is on channel %d: use it, or wifi.monitor_stop() first", adopted);
      return pushFail(L, msg);
    }
    channel = adopted;  // inject on the channel the sniffer already listens to
  }
  // When another radio mode is already running the radio's RAM is spent either way (the rings/buffers are static), so the
  // start floor only applies to a cold radio.
  const size_t floor = (be(L).monitorRunning() || be(L).txRunning() || be(L).espnowRunning()) ? 0 : be(L).radioFloorBytes();
  const size_t freeNow = be(L).freeHeap();
  if (freeNow < floor) {
    char msg[96];
    snprintf(msg, sizeof(msg), "not enough free RAM for tx (free %uK, need %uK)", static_cast<unsigned>(freeNow / 1024),
             static_cast<unsigned>(floor / 1024));
    return pushFail(L, msg);
  }
  char err[96] = {0};
  if (!be(L).txStart(static_cast<int>(channel), err, sizeof(err))) return pushFail(L, err[0] ? err : "cannot start the injector");
  lua_pushboolean(L, 1);
  return 1;
}

// wifi.tx(frame) -> true | nil, err. `frame` is the raw 802.11 frame WITHOUT the FCS (the radio computes and appends it), 24..250
// bytes. true means the radio accepted it; like everything in 802.11 there is no delivery guarantee.
int tx_send(lua_State* L) {
  size_t n = 0;
  const char* frame = luaL_checklstring(L, 1, &n);
  if (int r = gateTx(L)) return r;
  if (n < TX_MIN_LEN || n > static_cast<size_t>(TX_MAX_LEN)) return pushFail(L, "frame must be 24..250 bytes (without the FCS)");
  if (!be(L).txRunning()) return pushFail(L, "the injector is not running (call wifi.tx_start() first)");
  char err[96] = {0};
  if (!be(L).txSend(frame, n, err, sizeof(err))) return pushFail(L, err[0] ? err : "the radio refused the frame");
  lua_pushboolean(L, 1);
  return 1;
}

// wifi.tx_info() -> {channel, sent} | nil, err.
int tx_info(lua_State* L) {
  if (int r = gateTx(L)) return r;
  int channel = 0, sent = 0;
  if (!be(L).txInfo(&channel, &sent)) return pushFail(L, "the injector is not running (call wifi.tx_start() first)");
  lua_createtable(L, 0, 2);
  lua_pushinteger(L, channel);
  lua_setfield(L, -2, "channel");
  lua_pushinteger(L, sent);
  lua_setfield(L, -2, "sent");
  return 1;
}

// wifi.tx_stop() -> true. Gives the radio back (only when the monitor is not keeping it, either). Always allowed.
int tx_stop(lua_State* L) {
  be(L).txStop();
  lua_pushboolean(L, 1);
  return 1;
}

}  // namespace

void registerWifiTx(lua_State* L, Ctx* c) {
  (void)c;
  static const luaL_Reg fns[] = {{"tx_start", tx_start}, {"tx", tx_send}, {"tx_info", tx_info}, {"tx_stop", tx_stop},
                                 {nullptr, nullptr}};
  lua_getglobal(L, "wifi");
  luaL_setfuncs(L, fns, 0);
  lua_pop(L, 1);
}

}  // namespace crosslua
