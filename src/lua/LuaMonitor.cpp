// wifi.monitor — promiscuous 802.11 capture on a fixed channel, with an optional native PCAP writer.
// Needs "network" + "monitor" in the manifest and the user's approval (the dialog label is "SNIFFER": passive capture of
// everything in radio range is at least as sensitive as a microphone). The radio is exclusive: it cannot run next to a joined
// WiFi network, a hotspot or espnow. Frames arrive in a small ring filled from the WiFi task; Lua polls it, so no Lua code ever
// runs in the callback. Frames are truncated at 250 bytes in the ring; the PCAP file records the original length so a reader
// knows what was cut. Arguments are validated before the backend is touched.
#include <cstring>

#include "LuaInternal.h"

namespace crosslua {
namespace {

constexpr int MON_MAX_DATA = 250;
constexpr int MON_CHANNELS = 13;

int pushFail(lua_State* L, const char* msg) {
  lua_pushnil(L);
  lua_pushstring(L, msg);
  return 2;
}

int gateMonitor(lua_State* L) {
  if (!be(L).netAllowed()) return pushFail(L, NET_DENIED);
  if (!be(L).monitorAllowed()) return pushFail(L, MONITOR_DENIED);
  return 0;
}

int pushNotRunning(lua_State* L) {
  return pushFail(L, "monitor is not running (call wifi.monitor_start() first)");
}

// wifi.monitor_start([{channel=1..13, file="data:....pcap"}]) -> true | nil, err.
// With `file`, a PCAP (LINKTYPE_IEEE802_11) is written natively, streamed, no heap: the same write rules as mic.record.
int monitor_start(lua_State* L) {
  lua_Number channel = 1;
  bool channelGiven = false;
  char path[MAX_PATH_LEN + 80] = {0};
  bool hasFile = false;
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
      } else if (!strcmp(k, "file")) {
        if (lua_type(L, -1) != LUA_TSTRING) return pushFail(L, "file must be a path string ending in .pcap");
        if (!writePathArg(L, -1, path, sizeof(path))) return 2;  // pathArg already pushed nil, err
        const size_t n = strlen(path);
        if (n < 5 || strcasecmp(path + n - 5, ".pcap") != 0) return pushFail(L, "file must end in .pcap");
        hasFile = true;
      } else {
        char msg[64];
        snprintf(msg, sizeof(msg), "unknown option '%.24s'", k);
        return pushFail(L, msg);
      }
      lua_pop(L, 1);
    }
  }
  if (int r = gateMonitor(L)) return r;
  if (channel < 1 || channel > MON_CHANNELS || channel != static_cast<int>(channel)) return pushFail(L, "channel must be an integer 1..13");
  if (be(L).monitorRunning()) return pushFail(L, "monitor is already running (wifi.monitor_stop() first)");
  if (be(L).espnowRunning()) return pushFail(L, "espnow is running: call espnow.stop() first");
  if (be(L).netReady()) return pushFail(L, "the radio is in use by WiFi or the hotspot: call wifi.off() first");
  if (be(L).txRunning()) {
    int adopted = 0;
    if (!be(L).txChannel(&adopted)) return pushFail(L, "cannot read the injector's channel");
    if (channelGiven && static_cast<int>(channel) != adopted) {
      char msg[96];
      snprintf(msg, sizeof(msg), "the injector is on channel %d: use it, or wifi.tx_stop() first", adopted);
      return pushFail(L, msg);
    }
    if (!channelGiven) channel = adopted;
  }
  if (hasFile && be(L).fsSize(path) == -2) return pushFail(L, "is a directory");
  if (hasFile && !ensureParentDir(be(L), path)) return pushFail(L, "cannot create directory");
  // When another radio mode is already running the radio's RAM is spent either way (the rings/buffers are static), so the
  // start floor only applies to a cold radio.
  const size_t floor = (be(L).monitorRunning() || be(L).txRunning() || be(L).espnowRunning()) ? 0 : be(L).radioFloorBytes();
  const size_t freeNow = be(L).freeHeap();
  if (freeNow < floor) {
    char msg[96];
    snprintf(msg, sizeof(msg), "not enough free RAM for monitor (free %uK, need %uK)", static_cast<unsigned>(freeNow / 1024),
             static_cast<unsigned>(floor / 1024));
    return pushFail(L, msg);
  }
  char err[96] = {0};
  if (!be(L).monitorStart(static_cast<int>(channel), hasFile ? path : nullptr, err, sizeof(err))) return pushFail(L, err[0] ? err : "cannot start the monitor");
  lua_pushboolean(L, 1);
  return 1;
}

// wifi.monitor_recv() -> frame, {rssi, channel} | nil (nothing waiting) | nil, err (not started). Never blocks.
int monitor_recv(lua_State* L) {
  if (int r = gateMonitor(L)) return r;
  if (!be(L).monitorRunning()) return pushNotRunning(L);
  uint8_t buf[MON_MAX_DATA];
  int rssi = 0, channel = 0;
  const int n = be(L).monitorRecv(buf, sizeof(buf), &rssi, &channel);
  if (n <= 0) {
    lua_pushnil(L);
    return 1;
  }
  lua_createtable(L, 0, 2);
  lua_pushinteger(L, rssi);
  lua_setfield(L, -2, "rssi");
  lua_pushinteger(L, channel);
  lua_setfield(L, -2, "channel");
  lua_pushlstring(L, reinterpret_cast<const char*>(buf), static_cast<size_t>(n));
  lua_insert(L, -2);  // frame first, meta second
  return 2;
}

// wifi.monitor_info() -> {channel, captured, dropped, file, bytes} | nil, err.
int monitor_info(lua_State* L) {
  if (int r = gateMonitor(L)) return r;
  int channel = 0, captured = 0, dropped = 0;
  uint32_t bytes = 0;
  char path[MAX_PATH_LEN + 80] = {0};
  if (!be(L).monitorInfo(&channel, &captured, &dropped, path, sizeof(path), &bytes)) return pushNotRunning(L);
  lua_createtable(L, 0, 5);
  lua_pushinteger(L, channel);
  lua_setfield(L, -2, "channel");
  lua_pushinteger(L, captured);
  lua_setfield(L, -2, "captured");
  lua_pushinteger(L, dropped);
  lua_setfield(L, -2, "dropped");
  if (path[0]) {
    lua_pushstring(L, path);
    lua_setfield(L, -2, "file");
    lua_pushinteger(L, static_cast<lua_Integer>(bytes));
    lua_setfield(L, -2, "bytes");
  }
  return 1;
}

// wifi.monitor_channel(n) -> true | nil, err. Hops the radio to another channel (1..13) while the sniffer and/or the injector
// run; both follow (one radio, one channel). Frames captured before the hop stay queued in the ring.
int monitor_channel(lua_State* L) {
  if (lua_type(L, 1) != LUA_TNUMBER) return pushFail(L, "channel must be an integer 1..13");
  const lua_Number n = luaL_checknumber(L, 1);
  if (int r = gateMonitor(L)) return r;
  if (n < 1 || n > MON_CHANNELS || n != static_cast<int>(n)) return pushFail(L, "channel must be an integer 1..13");
  if (!be(L).monitorRunning() && !be(L).txRunning()) return pushFail(L, "no radio mode is running (wifi.monitor_start() or wifi.tx_start() first)");
  char err[96] = {0};
  if (!be(L).monitorSetChannel(static_cast<int>(n), err, sizeof(err))) return pushFail(L, err[0] ? err : "could not set the channel");
  lua_pushboolean(L, 1);
  return 1;
}

// wifi.monitor_stop() -> bytes written to the PCAP (0 without a file). Always allowed.
int monitor_stop(lua_State* L) {
  uint32_t bytes = 0;
  be(L).monitorStop(&bytes);
  lua_pushinteger(L, static_cast<lua_Integer>(bytes));
  return 1;
}

}  // namespace

// Merges into the existing (lazy) wifi table; called from registerNet after the rest of wifi.* is in place.
void registerWifiMonitor(lua_State* L, Ctx* c) {
  (void)c;
  static const luaL_Reg fns[] = {{"monitor_start", monitor_start}, {"monitor_recv", monitor_recv}, {"monitor_info", monitor_info},
                                 {"monitor_stop", monitor_stop},   {"monitor_channel", monitor_channel}, {nullptr, nullptr}};
  lua_getglobal(L, "wifi");
  luaL_setfuncs(L, fns, 0);
  lua_pop(L, 1);
}

}  // namespace crosslua
