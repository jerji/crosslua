// net.* — raw TCP client sockets. See docs/lua/NET_SOCKETS_PLAN.md and docs/lua/API.md. Needs "permissions": ["network"]
// in the app's manifest and WiFi up (wifi.connect()), exactly like http.*. The backend wraps the Arduino NetworkClient
// that CrossPoint already links (no new network code); this file only validates arguments and shapes results.
//
// Same rule as LuaNet.cpp: no C++ object with a destructor lives across a call that can raise a Lua error.
#include <cstdlib>
#include <cstring>

#include "LuaInternal.h"

namespace crosslua {
namespace {

// The WiFi radio itself (~57 KB) is already up when a socket is opened. Measured on the X4 (WiFi up, 44.7 KB free): an open
// idle socket costs 3.4-3.8 KB, one after a ping/echo 6.8 KB, one with a full receive window ~16 KB, and a 64 KB burst dips
// free heap to ~16.7 KB. Refuse a new connection below 16 KB free rather than starve the stack.
constexpr size_t SOCK_MIN_FREE_BYTES = 16 * 1024;
constexpr int DEFAULT_CONNECT_MS = 5000, MIN_CONNECT_MS = 100, MAX_CONNECT_MS = 15000;
constexpr size_t MAX_HOST = 253;
constexpr lua_Number DEFAULT_READ = 512, MAX_READ = 4096;
constexpr size_t MAX_WRITE = 16 * 1024;
const char* const NOT_CONNECTED = "not connected (no network joined): call wifi.connect() first";
const char* const BAD_HANDLE = "not an open socket handle";
const char* const BAD_HOST = "invalid host name";



int pushFail(lua_State* L, const char* msg) {
  lua_pushnil(L);
  lua_pushstring(L, msg);
  return 2;
}

// The handle operations are kind-checked: net.read on a UDP slot would silently do the wrong thing.
// kind: 1 TCP (read/write/available/connected), 2 UDP (udp_send/udp_recv). Returns 0 when ok, else pushes nil,err.
int checkKind(lua_State* L, int slot, int kind, const char* what) {
  if (be(L).netKind(slot) == kind) return 0;
  char msg[64];
  snprintf(msg, sizeof(msg), "not a %s socket", what);
  return pushFail(L, msg);
}

// Permission only (reads, writes and closes of an already-open handle must still work if WiFi dropped).
int gatePermission(lua_State* L) { return be(L).netAllowed() ? 0 : pushFail(L, NET_DENIED); }
// Permission + WiFi up (anything that creates traffic).
int gateOnline(lua_State* L) {
  if (int r = gatePermission(L)) return r;
  return be(L).wifiConnected() ? 0 : pushFail(L, NOT_CONNECTED);
}

// Host names and IPv4 literals only: letters, digits, '.', '-', '_'.
bool hostOk(const char* h, size_t n) {
  if (n == 0 || n > MAX_HOST) return false;
  for (size_t i = 0; i < n; i++) {
    const char c = h[i];
    const bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_';
    if (!ok) return false;
  }
  return true;
}

// Dotted-quad IPv4 literal ("10.0.0.7"): four decimal parts, each 0..255.
bool isIpv4Literal(const char* s, size_t n) {
  int parts = 0;
  size_t i = 0;
  while (i < n) {
    size_t digits = 0;
    int v = 0;
    while (i < n && s[i] >= '0' && s[i] <= '9') {
      v = v * 10 + (s[i] - '0');
      digits++;
      i++;
      if (digits > 3 || v > 255) return false;
    }
    if (digits == 0) return false;
    parts++;
    if (i == n) break;
    if (s[i] != '.') return false;
    i++;
    if (i == n) return false;  // trailing dot
  }
  return parts == 4;
}

// Validates a handle argument. 0 = ok (slot set); else pushes nil,err and returns 2.
int slotArg(lua_State* L, int i, int* slot) {
  const lua_Number h = luaL_checknumber(L, i);
  if (h < 1 || h > Backend::MAX_SOCKETS || h != static_cast<int>(h) || !be(L).netIsOpen(static_cast<int>(h) - 1))
    return pushFail(L, BAD_HANDLE);
  *slot = static_cast<int>(h) - 1;
  return 0;
}

// net.info() -> { ip, mask, gateway, dns } | nil, err   ("local" is a Lua keyword: net.local() would not parse)
int net_info(lua_State* L) {
  if (int r = gateOnline(L)) return r;
  char ip[16] = {0}, mask[16] = {0}, gw[16] = {0}, dns[16] = {0};
  if (!be(L).netLocal(ip, mask, gw, dns, sizeof(ip))) return pushFail(L, NOT_CONNECTED);
  lua_createtable(L, 0, 4);
  lua_pushstring(L, ip);
  lua_setfield(L, -2, "ip");
  lua_pushstring(L, mask);
  lua_setfield(L, -2, "mask");
  lua_pushstring(L, gw);
  lua_setfield(L, -2, "gateway");
  lua_pushstring(L, dns);
  lua_setfield(L, -2, "dns");
  return 1;
}

// net.resolve(host) -> "a.b.c.d" | nil, err. An IPv4 literal is returned as is (no DNS traffic). Uses the system DNS timeout.
int net_resolve(lua_State* L) {
  size_t n = 0;
  const char* host = luaL_checklstring(L, 1, &n);
  if (int r = gateOnline(L)) return r;
  if (!hostOk(host, n)) return pushFail(L, BAD_HOST);
  if (isIpv4Literal(host, n)) {
    lua_pushvalue(L, 1);
    return 1;
  }
  char ip[16] = {0}, err[96] = {0};
  if (!be(L).netResolve(host, ip, sizeof(ip), err, sizeof(err))) return pushFail(L, err[0] ? err : "cannot resolve host");
  lua_pushstring(L, ip);
  return 1;
}

// net.connect(host, port [, {timeout_ms = 5000}]) -> handle | nil, err. Blocks up to timeout_ms (100..15000).
// Reserved option keys: tls, insecure (not implemented yet: refused with a clear message, never silently ignored).
int net_connect(lua_State* L) {
  size_t n = 0;
  const char* host = luaL_checklstring(L, 1, &n);
  const lua_Number port = luaL_checknumber(L, 2);
  lua_Number timeout = DEFAULT_CONNECT_MS;
  bool wantTls = false;
  if (!lua_isnoneornil(L, 3)) {
    luaL_checktype(L, 3, LUA_TTABLE);
    lua_getfield(L, 3, "timeout_ms");
    if (!lua_isnil(L, -1)) timeout = luaL_checknumber(L, -1);
    lua_pop(L, 1);
    lua_getfield(L, 3, "tls");
    wantTls = lua_toboolean(L, -1) != 0;
    lua_pop(L, 1);
    lua_getfield(L, 3, "insecure");
    wantTls = wantTls || lua_toboolean(L, -1) != 0;
    lua_pop(L, 1);
  }
  if (int r = gateOnline(L)) return r;
  if (!hostOk(host, n)) return pushFail(L, BAD_HOST);
  if (port < 1 || port > 65535 || port != static_cast<int>(port)) return pushFail(L, "port must be an integer 1..65535");
  if (timeout < MIN_CONNECT_MS || timeout > MAX_CONNECT_MS || timeout != static_cast<int>(timeout))
    return pushFail(L, "timeout_ms must be an integer 100..15000");
  if (wantTls) return pushFail(L, "tls sockets are not implemented yet (plain TCP only)");
  bool free = false;
  for (int i = 0; i < Backend::MAX_SOCKETS; i++) free = free || !be(L).netIsOpen(i);
  if (!free) return pushFail(L, "too many open sockets (max 8)");
  const size_t freeNow = be(L).freeHeap();
  if (freeNow < SOCK_MIN_FREE_BYTES) {
    char msg[96];
    snprintf(msg, sizeof(msg), "not enough free RAM for a socket (free %uK, need %uK)", static_cast<unsigned>(freeNow / 1024),
             static_cast<unsigned>(SOCK_MIN_FREE_BYTES / 1024));
    return pushFail(L, msg);
  }
  char err[96] = {0};
  const int slot = be(L).netConnect(host, static_cast<int>(port), static_cast<int>(timeout), err, sizeof(err));
  if (slot < 0) return pushFail(L, err[0] ? err : "cannot connect");
  lua_pushinteger(L, slot + 1);
  return 1;
}

struct ReadReq {
  Backend* be;
  int slot;
  size_t want;
};
// Runs under lua_pcall (see net_read): allocate the result buffer, copy the bytes out of the stack, push the string.
int read_body(lua_State* L) {
  ReadReq* r = static_cast<ReadReq*>(lua_touserdata(L, 1));
  luaL_Buffer b;
  char* p = luaL_buffinitsize(L, &b, r->want);  // may raise out-of-memory: nothing to release yet
  const int got = r->be->netRead(r->slot, p, r->want);
  if (got < 0) return pushFail(L, "closed");
  luaL_pushresultsize(&b, static_cast<size_t>(got));
  return 1;
}

// net.read(h [, max = 512 (1..4096)]) -> string | nil, "closed". Never blocks: "" means nothing has arrived yet.
int net_read(lua_State* L) {
  if (int r = gatePermission(L)) return r;
  int slot = 0;
  if (int r = slotArg(L, 1, &slot)) return r;
  const lua_Number max = lua_isnoneornil(L, 2) ? DEFAULT_READ : luaL_checknumber(L, 2);
  if (int r = checkKind(L, slot, 1, "TCP")) return r;
  if (max < 1 || max > MAX_READ || max != static_cast<int>(max)) return pushFail(L, "max must be an integer 1..4096");
  const int avail = be(L).netAvailable(slot);
  if (avail < 0) return pushFail(L, "closed");
  if (avail == 0) {
    if (!be(L).netConnected(slot)) return pushFail(L, "closed");
    lua_pushliteral(L, "");  // nothing yet: no buffer is allocated
    return 1;
  }
  ReadReq req{&be(L), slot, static_cast<size_t>(avail) < static_cast<size_t>(max) ? static_cast<size_t>(avail) : static_cast<size_t>(max)};
  // The data waiting in the stack IS the memory pressure: copying it into a Lua string releases at least as much as it needs, so
  // refusing it because free heap is under the Lua floor would make things worse. Relax the floor for this one allocation and
  // restore it right after, inside a protected call so an out-of-memory error cannot skip the restore.
  const int base = lua_gettop(L);
  req.be->heapRelax(true);
  lua_pushcfunction(L, read_body);
  lua_pushlightuserdata(L, &req);
  const int rc = lua_pcall(L, 1, LUA_MULTRET, 0);
  req.be->heapRelax(false);
  if (rc != LUA_OK) return lua_error(L);  // rethrow (e.g. "not enough memory") now that the floor is back
  return lua_gettop(L) - base;
}

// net.write(h, data) -> bytes written | nil, err. data <= 16384 bytes per call: loop on the returned count.
int net_write(lua_State* L) {
  if (int r = gatePermission(L)) return r;
  int slot = 0;
  if (int r = slotArg(L, 1, &slot)) return r;
  if (int r = checkKind(L, slot, 1, "TCP")) return r;
  size_t len = 0;
  const char* data = luaL_checklstring(L, 2, &len);
  if (len > MAX_WRITE) return pushFail(L, "data too large (max 16384 per call; loop on the returned count)");
  if (len == 0) {
    lua_pushinteger(L, 0);
    return 1;
  }
  const int w = be(L).netWrite(slot, data, len);
  if (w < 0) return pushFail(L, "write failed (socket closed)");
  lua_pushinteger(L, w);
  return 1;
}

// net.available(h) -> bytes waiting (0 when none or closed)
int net_available(lua_State* L) {
  if (int r = gatePermission(L)) return r;
  int slot = 0;
  if (int r = slotArg(L, 1, &slot)) return r;
  if (int r = checkKind(L, slot, 1, "TCP")) return r;
  const int a = be(L).netAvailable(slot);
  lua_pushinteger(L, a < 0 ? 0 : a);
  return 1;
}

// net.connected(h) -> boolean (false once the peer closed and everything it sent has been read)
int net_connected(lua_State* L) {
  if (int r = gatePermission(L)) return r;
  int slot = 0;
  if (int r = slotArg(L, 1, &slot)) return r;
  if (int r = checkKind(L, slot, 1, "TCP")) return r;
  lua_pushboolean(L, be(L).netConnected(slot));
  return 1;
}

// net.udp_open(port) -> handle | nil, err. Binds a local UDP port (0 = system-assigned). Non-blocking afterwards:
// net.udp_recv polls. Handles share the socket table with TCP (8 slots total).
int net_udp_open(lua_State* L) {
  const lua_Number port = luaL_checknumber(L, 1);
  if (int r = gateOnline(L)) return r;
  if (port < 0 || port > 65535 || port != static_cast<int>(port)) return pushFail(L, "port must be an integer 0..65535 (0 = system-assigned)");
  bool free = false;
  for (int i = 0; i < Backend::MAX_SOCKETS; i++) free = free || !be(L).netIsOpen(i);
  if (!free) return pushFail(L, "too many open sockets (max 8)");
  const size_t freeNow = be(L).freeHeap();
  if (freeNow < SOCK_MIN_FREE_BYTES) {
    char msg[96];
    snprintf(msg, sizeof(msg), "not enough free RAM for a socket (free %uK, need %uK)", static_cast<unsigned>(freeNow / 1024),
             static_cast<unsigned>(SOCK_MIN_FREE_BYTES / 1024));
    return pushFail(L, msg);
  }
  char err[96] = {0};
  const int slot = be(L).udpOpen(static_cast<int>(port), err, sizeof(err));
  if (slot < 0) return pushFail(L, err[0] ? err : "cannot open UDP socket");
  lua_pushinteger(L, slot + 1);
  return 1;
}

// net.udp_send(h, host, port, data) -> bytes | nil, err. Fire-and-forget: no delivery guarantee. data <= 16384 bytes.
// `host` may be a name (resolved via DNS, blocks briefly) or an IPv4 literal.
int net_udp_send(lua_State* L) {
  size_t n = 0;
  const char* host = luaL_checklstring(L, 2, &n);
  const lua_Number port = luaL_checknumber(L, 3);
  size_t len = 0;
  const char* data = luaL_checklstring(L, 4, &len);
  if (int r = gateOnline(L)) return r;
  int slot = 0;
  if (int r = slotArg(L, 1, &slot)) return r;
  if (int r = checkKind(L, slot, 2, "UDP")) return r;
  if (!hostOk(host, n)) return pushFail(L, BAD_HOST);
  if (port < 1 || port > 65535 || port != static_cast<int>(port)) return pushFail(L, "port must be an integer 1..65535");
  if (len > MAX_WRITE) return pushFail(L, "data too large (max 16384 bytes)");
  if (len == 0) return pushFail(L, "data must not be empty");
  char err[96] = {0};
  const int w = be(L).udpSend(slot, host, static_cast<int>(port), data, len, err, sizeof(err));
  if (w < 0) return pushFail(L, err[0] ? err : "send failed");
  lua_pushinteger(L, w);
  return 1;
}

// net.udp_recv(h [, max = 1472 (1..16384)]) -> {data = ..., ip = ..., port = ...} | nil | nil, "closed".
// Never blocks: nil means nothing has arrived. One datagram per call; larger datagrams are truncated to max.
int net_udp_recv(lua_State* L) {
  if (int r = gatePermission(L)) return r;
  int slot = 0;
  if (int r = slotArg(L, 1, &slot)) return r;
  if (int r = checkKind(L, slot, 2, "UDP")) return r;
  const lua_Number max = lua_isnoneornil(L, 2) ? 1472 : luaL_checknumber(L, 2);
  if (max < 1 || max > 16384 || max != static_cast<int>(max)) return pushFail(L, "max must be an integer 1..16384");
  char ip[16] = {0};
  int port = 0;
  void* buf = malloc(static_cast<size_t>(max));
  if (!buf) return pushFail(L, "not enough memory");
  const int n = be(L).udpRecv(slot, buf, static_cast<size_t>(max), ip, sizeof(ip), &port);
  if (n <= 0) {
    free(buf);
    if (n < 0) return pushFail(L, "closed");
    lua_pushnil(L);
    return 1;
  }
  lua_pushlstring(L, static_cast<const char*>(buf), static_cast<size_t>(n));
  free(buf);  // the string is on the stack now; a later raise (table OOM) cannot leak the buffer
  lua_createtable(L, 0, 3);
  lua_insert(L, -2);
  lua_setfield(L, -2, "data");
  lua_pushstring(L, ip);
  lua_setfield(L, -2, "ip");
  lua_pushinteger(L, port);
  lua_setfield(L, -2, "port");
  return 1;
}

// net.udp_close(h) -> true | nil, err (a handle that is not open, or a TCP handle)
int net_udp_close(lua_State* L) {
  if (int r = gatePermission(L)) return r;
  int slot = 0;
  if (int r = slotArg(L, 1, &slot)) return r;
  if (int r = checkKind(L, slot, 2, "UDP")) return r;
  be(L).netClose(slot);
  lua_pushboolean(L, 1);
  return 1;
}

// net.close(h) -> true | nil, err (a handle that is not open, including one already closed)
int net_close(lua_State* L) {
  if (int r = gatePermission(L)) return r;
  int slot = 0;
  if (int r = slotArg(L, 1, &slot)) return r;
  be(L).netClose(slot);
  lua_pushboolean(L, 1);
  return 1;
}

// ---- listen sockets (server on a TCP port) ----------------------------------------------

// Permission + WiFi up gate for listen sockets (asks for "listen" permission on top of "network").
int gateListen(lua_State* L) {
  if (!be(L).listenAllowed()) return pushFail(L, LISTEN_DENIED);
  if (!be(L).wifiConnected()) return pushFail(L, NOT_CONNECTED);
  return 0;
}

// net.listen(port) -> handle | nil, err. Binds a TCP server on `port` (1..65535).
// Needs "listen" permission in the app's manifest (on top of "network").
int net_listen(lua_State* L) {
  const lua_Number port = luaL_checknumber(L, 1);
  if (int r = gateListen(L)) return r;
  if (port < 1 || port > 65535 || port != static_cast<int>(port)) return pushFail(L, "port must be an integer 1..65535");
  bool free = false;
  for (int i = 0; i < Backend::MAX_SOCKETS; i++) free = free || !be(L).netIsOpen(i);
  if (!free) return pushFail(L, "too many open sockets (max 8)");
  const size_t freeNow = be(L).freeHeap();
  if (freeNow < SOCK_MIN_FREE_BYTES) {
    char msg[96];
    snprintf(msg, sizeof(msg), "not enough free RAM for a socket (free %uK, need %uK)", static_cast<unsigned>(freeNow / 1024),
             static_cast<unsigned>(SOCK_MIN_FREE_BYTES / 1024));
    return pushFail(L, msg);
  }
  char err[96] = {0};
  const int slot = be(L).netListen(static_cast<int>(port), err, sizeof(err));
  if (slot < 0) return pushFail(L, err[0] ? err : "cannot listen on port");
  lua_pushinteger(L, slot + 1);
  return 1;
}

// net.accept(server) -> handle | nil | nil, err. Non-blocking: nil = nothing waiting yet.
// Returns a TCP client handle (kind 1) that can be used with net.read/write/close.
int net_accept(lua_State* L) {
  int slot = 0;
  if (int r = slotArg(L, 1, &slot)) return r;
  if (int r = checkKind(L, slot, 3, "server")) return r;
  if (!be(L).listenAllowed()) return pushFail(L, LISTEN_DENIED);
  const int clientSlot = be(L).netAccept(slot);
  if (clientSlot == -2) return pushFail(L, "accept failed");
  if (clientSlot < 0) {
    lua_pushnil(L);  // nothing waiting, no error
    return 1;
  }
  lua_pushinteger(L, clientSlot + 1);
  return 1;
}

// ---- mDNS query -------------------------------------------------------------------------

// net.mdns_query(service, proto) -> { {hostname, ip, port, instance_name}, ... } | nil, err
// `service` e.g. "_http" or "http"; `proto` "tcp" or "udp". Needs WiFi up.
int net_mdns_query(lua_State* L) {
  const char* service = luaL_checkstring(L, 1);
  const char* proto = luaL_checkstring(L, 2);
  if (int r = gateOnline(L)) return r;
  if (strlen(service) == 0 || strlen(service) > 60) return pushFail(L, "invalid service type");
  if (strcmp(proto, "tcp") != 0 && strcmp(proto, "udp") != 0) return pushFail(L, "proto must be \"tcp\" or \"udp\"");
  // Strip leading underscore from service if present (ESPmDNS expects the bare name)
  const char* cleanSvc = (service[0] == '_') ? service + 1 : service;
  char err[96] = {0};
  const int n = be(L).mdnsQuery(cleanSvc, proto, err, sizeof(err));
  if (n < 0) return pushFail(L, err[0] ? err : "mDNS query failed");
  lua_createtable(L, n, 0);
  for (int i = 0; i < n; i++) {
    char hostname[64], ip[16], instanceName[64];
    int port = 0;
    if (!be(L).mdnsResult(i, hostname, sizeof(hostname), ip, sizeof(ip), &port, instanceName, sizeof(instanceName)))
      break;
    lua_createtable(L, 0, 4);
    lua_pushstring(L, hostname);
    lua_setfield(L, -2, "hostname");
    lua_pushstring(L, ip);
    lua_setfield(L, -2, "ip");
    lua_pushinteger(L, port);
    lua_setfield(L, -2, "port");
    lua_pushstring(L, instanceName);
    lua_setfield(L, -2, "instance_name");
    lua_rawseti(L, -2, i + 1);
  }
  return 1;
}

}  // namespace

void registerSock(lua_State* L, Ctx* c) {
  static const luaL_Reg fns[] = {{"info", net_info},           {"resolve", net_resolve}, {"connect", net_connect},
                                 {"read", net_read},           {"write", net_write},     {"available", net_available},
                                 {"connected", net_connected}, {"close", net_close},
                                 {"udp_open", net_udp_open},   {"udp_send", net_udp_send}, {"udp_recv", net_udp_recv},
                                 {"udp_close", net_udp_close},
                                 {"listen", net_listen},       {"accept", net_accept},
                                 {"mdns_query", net_mdns_query},
                                 {nullptr, nullptr}};
  regTable(L, c, "net", fns);
}

}  // namespace crosslua
