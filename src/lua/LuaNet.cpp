// wifi.* and http.* — see docs/lua/API.md. Requires "permissions": ["network"] in the app's manifest.json.
//
// RULE (see LuaApi.h): no C++ object with a destructor lives across a call that can raise a Lua error. Arguments are
// parsed into plain pointers/arrays first (pointing into Lua strings that stay anchored on the stack), the backend
// call works on POD structs, and the response is pushed from inside lua_pcall so an out-of-memory error can never
// skip the free() of the (malloc'd, non-Lua) response buffer.
#include <cstdlib>
#include <cstring>

#include "LuaInternal.h"
#include "LuaVm.h"

namespace crosslua {
namespace {

// WiFi radio ~56 KB + TLS floor 40 KB (see HttpDownloader::MIN_TLS_FREE_HEAP), measured on hardware.
constexpr size_t NET_MIN_FREE_BYTES = 96 * 1024;  // WiFi (~57 KB measured) + the 40 KB a TLS session wants
// wifi.connect{tls=false}: apps that only use plain TCP/UDP never open a TLS session. Radio ~57 KB + the 16 KB the socket layer
// refuses to go below (SOCK_MIN_FREE_BYTES in LuaSock.cpp) + ~7 KB margin. https then fails at request time with its own message.
constexpr size_t NET_MIN_FREE_BYTES_PLAIN = 80 * 1024;
constexpr size_t MAX_URL = 600;
constexpr int MAX_HEADERS = 12;
constexpr size_t MAX_HEADER_LEN = 400;
constexpr size_t MAX_CONTENT_TYPE_LEN = 100;
constexpr int MAX_RESPONSE_HEADERS = 48;  // distinct headers kept from a response (the backend already caps the block at 4 KB)
constexpr size_t MAX_POST_BODY = 8 * 1024;
constexpr size_t DEFAULT_MAX_BODY = 16 * 1024;
constexpr size_t HARD_MAX_BODY = 64 * 1024;

int pushFail(lua_State* L, const char* msg) {
  lua_pushnil(L);
  lua_pushstring(L, msg);
  return 2;
}

bool allowed(lua_State* L) { return be(L).netAllowed(); }
constexpr const char* DENIED = NET_DENIED;

// ---- wifi -----------------------------------------------------------------
int pushNo(lua_State* L, const char* why) {  // wifi.connect() failures: false, reason
  lua_pushboolean(L, 0);
  lua_pushstring(L, why);
  return 2;
}

int wifi_connect_k(lua_State* L, int, lua_KContext) {
  const char* ev = lua_tostring(L, -1);  // what the host resumed us with
  if (ev && strcmp(ev, "wifi:ok") == 0) {
    lua_pushboolean(L, 1);
    return 1;
  }
  return pushNo(L, "not connected (no network joined)");
}

// wifi.connect([{tls = false}]) -> true | false, reason. Parks the script while the system's WiFi screen (usually just an auto-join
// of the saved network) runs; the screen is then the system's, so the app must redraw afterwards. The default demands enough RAM
// for https; {tls=false} (plain TCP/UDP apps) demands less and leaves https to fail cleanly at request time.
int wifi_connect(lua_State* L) {
  bool needTls = true;
  if (!lua_isnoneornil(L, 1)) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_getfield(L, 1, "tls");
    if (!lua_isnil(L, -1)) {
      if (!lua_isboolean(L, -1)) return luaL_argerror(L, 1, "tls must be a boolean");
      needTls = lua_toboolean(L, -1) != 0;
    }
    lua_pop(L, 1);
  }
  if (!allowed(L)) return pushNo(L, DENIED);
  if (be(L).wifiConnected()) {
    lua_pushboolean(L, 1);
    return 1;
  }
  if (be(L).bleRunning()) return pushNo(L, "bluetooth is running: call ble.stop() before joining WiFi");
  if (be(L).espnowRunning()) return pushNo(L, "espnow is running: call espnow.stop() before joining WiFi");
  if (be(L).monitorRunning()) return pushNo(L, "the WiFi sniffer is running: call wifi.monitor_stop() first");
  if (be(L).txRunning()) return pushNo(L, "the injector is running: call wifi.tx_stop() first");
  // Measured on the X4: bringing WiFi up costs ~56 KB of RAM and a TLS session wants >= 40 KB free on top of that.
  // Fail NOW with a clear reason rather than half-way through a request.
  const size_t freeNow = be(L).freeHeap();
  const size_t need = needTls ? NET_MIN_FREE_BYTES : NET_MIN_FREE_BYTES_PLAIN;
  if (freeNow < need) {
    char msg[160];
    snprintf(msg, sizeof(msg), "not enough free RAM for WiFi%s (free %uK, need %uK): this app is too big for network use",
             needTls ? " + TLS" : "", static_cast<unsigned>(freeNow / 1024), static_cast<unsigned>(need / 1024));
    return pushNo(L, msg);
  }
  be(L).wifiRequestConnect();
  lua_pushinteger(L, -1);   // no timeout...
  lua_pushboolean(L, 0);    // ...and input events do not wake it: only the host's resume does
  return lua_yieldk(L, 2, 0, wifi_connect_k);
}

int wifi_status(lua_State* L) {
  char ssid[40], ip[20];
  int rssi = 0;
  // The SSID/IP say where the user is: only apps that may use the network get to see them.
  const bool up = allowed(L) && be(L).wifiInfo(ssid, sizeof(ssid), ip, sizeof(ip), &rssi);
  lua_createtable(L, 0, 4);
  lua_pushboolean(L, up);
  lua_setfield(L, -2, "connected");
  if (up) {
    lua_pushstring(L, ssid);
    lua_setfield(L, -2, "ssid");
    lua_pushstring(L, ip);
    lua_setfield(L, -2, "ip");
    lua_pushinteger(L, rssi);
    lua_setfield(L, -2, "rssi");
  }
  return 1;
}

// wifi.scan([max]) -> { {ssid, rssi, encrypted} ... } | nil, err. Blocking, a few seconds (network permission).
int wifi_scan(lua_State* L) {
  if (!allowed(L)) return pushFail(L, DENIED);
  int max = lua_isnoneornil(L, 1) ? 20 : static_cast<int>(luaL_checknumber(L, 1));
  if (max < 1 || max > 50) return pushFail(L, "max must be 1..50");
  if (be(L).bleRunning()) return pushFail(L, "bluetooth is running: call ble.stop() first");
  char err[96] = {0};
  int total = 0;
  static Backend::WifiScanInfo out[50];
  const int n = be(L).wifiScan(out, max, &total, err, sizeof(err));
  if (n < 0) return pushFail(L, err);
  lua_createtable(L, n, 0);
  for (int i = 0; i < n; i++) {
    lua_createtable(L, 0, 3);
    lua_pushstring(L, out[i].ssid);
    lua_setfield(L, -2, "ssid");
    lua_pushinteger(L, out[i].rssi);
    lua_setfield(L, -2, "rssi");
    lua_pushboolean(L, out[i].encrypted);
    lua_setfield(L, -2, "encrypted");
    lua_rawseti(L, -2, i + 1);
  }
  lua_pushinteger(L, total);
  return 2;
}

constexpr size_t SOFTAP_MIN_FREE_BYTES = 80 * 1024;  // measured on the X4: the hotspot costs ~60 KB, and net.listen then needs its own 16 KB floor
constexpr int SOFTAP_MAX_CLIENTS = 4;

bool printableAscii(const char* s, size_t n) {
  for (size_t i = 0; i < n; i++)
    if (static_cast<unsigned char>(s[i]) < 0x20 || static_cast<unsigned char>(s[i]) > 0x7E) return false;
  return true;
}

// wifi.softap(ssid [, {password = "8..63 chars" (omit = OPEN network), channel = 1..11, max_clients = 1..4}]) -> true, ip | false, reason
// Starts this device's own WiFi network (needs "network" + "hotspot" + the user's approval). Not combinable with a joined network.
// net.listen / net.accept / net.udp_* then serve the clients that join; wifi.off() stops the hotspot.
int wifi_softap(lua_State* L) {
  size_t sl = 0;
  const char* ssid = luaL_checklstring(L, 1, &sl);
  const char* password = nullptr;
  lua_Number channel = 1, maxClients = SOFTAP_MAX_CLIENTS;
  if (!lua_isnoneornil(L, 2)) {
    luaL_checktype(L, 2, LUA_TTABLE);
    lua_pushnil(L);
    while (lua_next(L, 2)) {
      if (lua_type(L, -2) != LUA_TSTRING) return pushNo(L, "options must have string keys");
      const char* k = lua_tostring(L, -2);
      if (!strcmp(k, "password")) {
        if (lua_type(L, -1) != LUA_TSTRING) return pushNo(L, "password must be a string");
        password = lua_tostring(L, -1);
      } else if (!strcmp(k, "channel")) {
        if (lua_type(L, -1) != LUA_TNUMBER) return pushNo(L, "channel must be an integer 1..11");
        channel = lua_tonumber(L, -1);
      } else if (!strcmp(k, "max_clients")) {
        if (lua_type(L, -1) != LUA_TNUMBER) return pushNo(L, "max_clients must be an integer 1..4");
        maxClients = lua_tonumber(L, -1);
      } else {
        char msg[64];
        snprintf(msg, sizeof(msg), "unknown option '%.24s'", k);
        return pushNo(L, msg);
      }
      lua_pop(L, 1);
    }
  }
  if (!allowed(L)) return pushNo(L, DENIED);
  if (!be(L).hotspotAllowed()) return pushNo(L, HOTSPOT_DENIED);
  if (sl < 1 || sl > 32 || !printableAscii(ssid, sl)) return pushNo(L, "ssid must be 1..32 printable ASCII characters");
  if (password) {
    const size_t pl = strlen(password);
    if (pl < 8 || pl > 63 || !printableAscii(password, pl))
      return pushNo(L, "password must be 8..63 printable ASCII characters (leave it out for an open network)");
  }
  if (channel < 1 || channel > 11 || channel != static_cast<int>(channel)) return pushNo(L, "channel must be an integer 1..11");
  if (maxClients < 1 || maxClients > SOFTAP_MAX_CLIENTS || maxClients != static_cast<int>(maxClients))
    return pushNo(L, "max_clients must be an integer 1..4");
  char cur[40], curIp[20];
  int clients = 0;
  if (be(L).softApInfo(cur, sizeof(cur), curIp, sizeof(curIp), &clients)) return pushNo(L, "a hotspot is already running (wifi.off() stops it)");
  if (be(L).wifiConnected()) return pushNo(L, "WiFi is joined as a client: call wifi.off() before starting a hotspot");
  if (be(L).bleRunning()) return pushNo(L, "bluetooth is running: call ble.stop() before starting a hotspot");
  if (be(L).espnowRunning()) return pushNo(L, "espnow is running: call espnow.stop() before starting a hotspot");
  if (be(L).monitorRunning()) return pushNo(L, "the WiFi sniffer is running: call wifi.monitor_stop() first");
  if (be(L).txRunning()) return pushNo(L, "the injector is running: call wifi.tx_stop() first");
  const size_t freeNow = be(L).freeHeap();
  if (freeNow < SOFTAP_MIN_FREE_BYTES) {
    char msg[120];
    snprintf(msg, sizeof(msg), "not enough free RAM for a hotspot (free %uK, need %uK)", static_cast<unsigned>(freeNow / 1024),
             static_cast<unsigned>(SOFTAP_MIN_FREE_BYTES / 1024));
    return pushNo(L, msg);
  }
  char ip[20] = {0}, err[96] = {0};
  if (!be(L).softApStart(ssid, password, static_cast<int>(channel), static_cast<int>(maxClients), ip, sizeof(ip), err, sizeof(err)))
    return pushNo(L, err[0] ? err : "cannot start the hotspot");
  lua_pushboolean(L, 1);
  lua_pushstring(L, ip);
  return 2;
}

// wifi.softap_info() -> {ssid, ip, clients} | nil, "no hotspot running"
int wifi_softap_info(lua_State* L) {
  if (!allowed(L)) return pushFail(L, DENIED);
  char ssid[40], ip[20];
  int clients = 0;
  if (!be(L).softApInfo(ssid, sizeof(ssid), ip, sizeof(ip), &clients)) return pushFail(L, "no hotspot running");
  lua_createtable(L, 0, 3);
  lua_pushstring(L, ssid);
  lua_setfield(L, -2, "ssid");
  lua_pushstring(L, ip);
  lua_setfield(L, -2, "ip");
  lua_pushinteger(L, clients);
  lua_setfield(L, -2, "clients");
  return 1;
}

int wifi_off(lua_State* L) {
  be(L).wifiOff();
  return 0;
}

// ---- http -----------------------------------------------------------------
// Pushes the response table. Runs under lua_pcall (see http_request).
struct Push {
  const Backend::HttpResult* res;
  bool saved;
};
int push_response(lua_State* L) {
  const Push* p = static_cast<const Push*>(lua_touserdata(L, 1));
  lua_createtable(L, 0, 4);
  lua_pushinteger(L, p->res->status);
  lua_setfield(L, -2, "status");
  lua_pushinteger(L, static_cast<lua_Integer>(p->res->bytes));
  lua_setfield(L, -2, "bytes");
  if (!p->saved) {
    lua_pushlstring(L, p->res->body ? p->res->body : "", p->res->bodyLen);
    lua_setfield(L, -2, "body");
  }
  lua_pushboolean(L, p->res->status >= 200 && p->res->status < 300);
  lua_setfield(L, -2, "ok");
  if (p->res->headers) {  // response_headers=true: lower-case names, duplicates joined with ", " (RFC 9110 5.3)
    lua_createtable(L, 0, 8);
    const int ht = lua_gettop(L);
    const char* line = p->res->headers;
    const char* end = p->res->headers + p->res->headersLen;
    int count = 0;
    while (line < end && count < MAX_RESPONSE_HEADERS) {
      const char* nl = static_cast<const char*>(memchr(line, '\n', static_cast<size_t>(end - line)));
      const char* lineEnd = nl ? nl : end;
      const char* colon = static_cast<const char*>(memchr(line, ':', static_cast<size_t>(lineEnd - line)));
      if (colon && colon > line && static_cast<size_t>(colon - line) <= MAX_HEADER_LEN) {
        char name[MAX_HEADER_LEN + 1];
        const size_t nlen = static_cast<size_t>(colon - line);
        for (size_t i = 0; i < nlen; i++) name[i] = static_cast<char>(tolower(static_cast<unsigned char>(line[i])));
        name[nlen] = '\0';
        const char* v = colon + 1;
        while (v < lineEnd && (*v == ' ' || *v == '\t')) v++;
        const char* ve = lineEnd;
        while (ve > v && (ve[-1] == '\r' || ve[-1] == ' ' || ve[-1] == '\t')) ve--;
        lua_getfield(L, ht, name);
        if (lua_isstring(L, -1)) {  // a repeated header: join (old, ", ", new)
          lua_pushstring(L, ", ");
          lua_pushlstring(L, v, static_cast<size_t>(ve - v));
          lua_concat(L, 3);
        } else {
          lua_pop(L, 1);
          lua_pushlstring(L, v, static_cast<size_t>(ve - v));
        }
        lua_setfield(L, ht, name);
        count++;
      }
      line = nl ? nl + 1 : end;
    }
    lua_setfield(L, -2, "headers");
  }
  return 1;
}

bool startsWithHttp(const char* u) { return !strncasecmp(u, "http://", 7) || !strncasecmp(u, "https://", 8); }

bool methodOk(const char* m) {
  return !strcmp(m, "GET") || !strcmp(m, "POST") || !strcmp(m, "PUT") || !strcmp(m, "PATCH") || !strcmp(m, "DELETE");
}
bool methodTakesBody(const char* m) { return !strcmp(m, "POST") || !strcmp(m, "PUT") || !strcmp(m, "PATCH"); }

// http.request{ url=, method="GET"|"POST"|"PUT"|"PATCH"|"DELETE", headers={name=value,...}, body=, content_type=, ca=,
//               response_headers=bool, save_to="data:path", max_body=N }
//   -> { status=, ok=, bytes=, body=, headers= } | nil, err      (body is absent in save_to mode; headers only on request)
// body is allowed for POST/PUT/PATCH and is sent as content_type (default application/x-www-form-urlencoded).
// ca = "<PEM file>" verifies the https server against that certificate; without it the server is NOT authenticated.
// A non-2xx status is NOT an error (you get status + body); transport failures, aborts (Back) and size-cap hits are.
int http_request(lua_State* L) {
  if (!allowed(L)) return pushFail(L, DENIED);
  luaL_checktype(L, 1, LUA_TTABLE);

  lua_getfield(L, 1, "url");
  const char* url = luaL_checkstring(L, -1);
  if (strlen(url) > MAX_URL) return pushFail(L, "url too long");
  if (!startsWithHttp(url)) return pushFail(L, "only http:// and https:// urls are allowed");

  lua_getfield(L, 1, "method");
  const char* method = lua_isnil(L, -1) ? "GET" : luaL_checkstring(L, -1);
  if (!methodOk(method)) return pushFail(L, "method must be GET, POST, PUT, PATCH or DELETE");

  lua_getfield(L, 1, "body");
  size_t bodyLen = 0;
  const char* body = lua_isnil(L, -1) ? nullptr : luaL_checklstring(L, -1, &bodyLen);
  if (bodyLen > MAX_POST_BODY) return pushFail(L, "body too large");
  if (body && !methodTakesBody(method)) {
    char msg[48];
    snprintf(msg, sizeof(msg), "a %s request cannot have a body", method);
    return pushFail(L, msg);
  }

  lua_getfield(L, 1, "content_type");
  const char* contentType = nullptr;
  if (!lua_isnil(L, -1)) {
    if (lua_type(L, -1) != LUA_TSTRING) return luaL_argerror(L, 1, "content_type must be a string");
    contentType = lua_tostring(L, -1);
    if (!body) return pushFail(L, "content_type needs a body");
    const size_t cl = strlen(contentType);
    if (cl == 0 || cl > MAX_CONTENT_TYPE_LEN || strpbrk(contentType, "\r\n")) return pushFail(L, "illegal content_type");
  }
  if (body && !contentType) contentType = "application/x-www-form-urlencoded";

  lua_getfield(L, 1, "response_headers");
  if (!lua_isnil(L, -1) && lua_type(L, -1) != LUA_TBOOLEAN) return luaL_argerror(L, 1, "response_headers must be a boolean");
  const bool wantHeaders = lua_toboolean(L, -1) != 0;

  lua_getfield(L, 1, "ca");
  char* caPem = nullptr;
  if (!lua_isnil(L, -1)) {
    if (lua_type(L, -1) != LUA_TSTRING) return luaL_argerror(L, 1, "ca must be a path string");
    if (strncasecmp(url, "https://", 8)) return pushFail(L, "ca only applies to https:// urls");
    if (int r = loadCa(L, lua_tostring(L, -1), &caPem)) return r;
  }

  lua_getfield(L, 1, "max_body");
  const lua_Number mb = lua_isnil(L, -1) ? static_cast<lua_Number>(DEFAULT_MAX_BODY) : luaL_checknumber(L, -1);
  if (mb < 1 || mb > static_cast<lua_Number>(HARD_MAX_BODY)) return pushFail(L, "max_body must be 1..65536 (use save_to for bigger responses)");

  lua_getfield(L, 1, "save_to");
  char savePath[MAX_PATH_LEN + 80];
  const char* savePtr = nullptr;
  if (!lua_isnil(L, -1)) {
    const char* spec = luaL_checkstring(L, -1);
    Scope sc;
    const char* err = nullptr;
    if (!resolvePath(be(L), spec, savePath, sizeof(savePath), &sc, &err)) return pushFail(L, err);
    if (!writeAllowed(be(L), sc, savePath))
      return pushFail(L, be(L).grantCount() > 0 ? "save_to must be a data: path or an sd: folder this app has a write grant for"
                                                 : "save_to must be a data: path");
    if (strcmp(method, "GET")) return pushFail(L, "save_to is only supported for GET");
    if (wantHeaders || caPem) return pushFail(L, "save_to cannot be combined with ca or response_headers yet");
    savePtr = savePath;
  }

  // headers: { ["Name"] = "value", ... }   (pointers stay valid: the table and its strings are anchored on the stack)
  Backend::HttpHeader headers[MAX_HEADERS];
  int nh = 0;
  lua_getfield(L, 1, "headers");
  const int hIdx = lua_gettop(L);
  if (!lua_isnil(L, hIdx)) {
    luaL_checktype(L, hIdx, LUA_TTABLE);
    lua_pushnil(L);
    while (lua_next(L, hIdx)) {
      if (nh >= MAX_HEADERS) return pushFail(L, "too many headers");
      if (lua_type(L, -2) != LUA_TSTRING || lua_type(L, -1) != LUA_TSTRING) return pushFail(L, "headers must be a table of string = string");
      const char* k = lua_tostring(L, -2);
      const char* v = lua_tostring(L, -1);
      if (strlen(k) > MAX_HEADER_LEN || strlen(v) > MAX_HEADER_LEN || strpbrk(k, "\r\n:") || strpbrk(v, "\r\n"))
        return pushFail(L, "illegal header");
      if (body && !strcasecmp(k, "content-type")) return pushFail(L, "set content_type instead of a Content-Type header");
      headers[nh].name = k;
      headers[nh].value = v;
      nh++;
      lua_pop(L, 1);  // keep the key for lua_next; the value string stays anchored by the table
    }
  }

  Backend::HttpRequest rq;
  rq.method = method;
  rq.url = url;
  rq.headers = headers;
  rq.headerCount = nh;
  rq.body = body;
  rq.bodyLen = bodyLen;
  rq.savePath = savePtr;
  rq.maxBody = static_cast<size_t>(mb);
  rq.contentType = contentType;
  rq.caPem = caPem;
  rq.wantHeaders = wantHeaders;

  Backend::HttpResult res;
  const bool got = be(L).httpRequest(rq, res);  // POD in/out: nothing here can be skipped by a longjmp
  if (!got) {
    char msg[sizeof(res.error)];
    snprintf(msg, sizeof(msg), "%s", res.error[0] ? res.error : "request failed");
    free(res.body);
    free(res.headers);
    return pushFail(L, msg);
  }

  Push p{&res, savePtr != nullptr};
  lua_pushcfunction(L, push_response);
  lua_pushlightuserdata(L, &p);
  const int rc = lua_pcall(L, 1, 1, 0);  // an out-of-memory error here is caught, so res.body is always freed below
  free(res.body);
  free(res.headers);
  if (rc != LUA_OK) {
    lua_pop(L, 1);
    return pushFail(L, "not enough memory for the response (use save_to for big downloads)");
  }
  return 1;
}

// http.get(url [, opts]) == http.request{ url = url, ...opts }
int http_get(lua_State* L) {
  const char* url = luaL_checkstring(L, 1);
  lua_newtable(L);
  const int t = lua_gettop(L);
  if (!lua_isnoneornil(L, 2)) {
    luaL_checktype(L, 2, LUA_TTABLE);
    lua_pushnil(L);
    while (lua_next(L, 2)) {  // copy opts (shallow)
      lua_pushvalue(L, -2);
      lua_insert(L, -2);
      lua_settable(L, t);
    }
  }
  lua_pushstring(L, url);
  lua_setfield(L, t, "url");
  lua_pushvalue(L, lua_upvalueindex(1));  // http_request
  lua_pushvalue(L, t);
  lua_call(L, 1, LUA_MULTRET);
  return lua_gettop(L) - t;
}

}  // namespace

void registerNet(lua_State* L, Ctx* c) {
  static const luaL_Reg wifiFns[] = {{"connect", wifi_connect}, {"status", wifi_status}, {"off", wifi_off},
                                   {"scan", wifi_scan}, {"softap", wifi_softap}, {"softap_info", wifi_softap_info}, {nullptr, nullptr}};
  regTable(L, c, "wifi", wifiFns);
  registerWifiMonitor(L, c);  // wifi.monitor_* joins the same lazy table
  registerWifiTx(L, c);       // wifi.tx_* too
  static const luaL_Reg httpFns[] = {{"request", http_request}, {nullptr, nullptr}};
  regTable(L, c, "http", httpFns);
  // http.get needs the request function as its one upvalue.
  lua_getglobal(L, "http");
  lua_getfield(L, -1, "request");
  lua_pushvalue(L, -1);
  lua_pushcclosure(L, http_get, 1);
  lua_setfield(L, -3, "get");  // [http, request, closure] -> http.get = closure
  lua_pop(L, 2);
}

}  // namespace crosslua
