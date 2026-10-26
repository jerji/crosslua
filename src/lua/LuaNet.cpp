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
constexpr size_t NET_MIN_FREE_BYTES = 96 * 1024;
constexpr size_t MAX_URL = 600;
constexpr int MAX_HEADERS = 12;
constexpr size_t MAX_HEADER_LEN = 400;
constexpr size_t MAX_POST_BODY = 8 * 1024;
constexpr size_t DEFAULT_MAX_BODY = 16 * 1024;
constexpr size_t HARD_MAX_BODY = 64 * 1024;

int pushFail(lua_State* L, const char* msg) {
  lua_pushnil(L);
  lua_pushstring(L, msg);
  return 2;
}

bool allowed(lua_State* L) { return be(L).netAllowed(); }
constexpr const char* DENIED = "network not permitted: add \"permissions\": [\"network\"] to this app's manifest.json";

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

// wifi.connect() -> true | false, reason. Parks the script while the system's WiFi screen (usually just an auto-join of the
// saved network) runs; the screen is then the system's, so the app must redraw afterwards.
int wifi_connect(lua_State* L) {
  if (!allowed(L)) return pushNo(L, DENIED);
  if (be(L).wifiConnected()) {
    lua_pushboolean(L, 1);
    return 1;
  }
  // Measured on the X4: bringing WiFi up costs ~56 KB of RAM and a TLS session wants >= 40 KB free on top of that.
  // Fail NOW with a clear reason rather than half-way through a request.
  const size_t freeNow = be(L).freeHeap();
  if (freeNow < NET_MIN_FREE_BYTES) {
    char msg[160];
    snprintf(msg, sizeof(msg), "not enough free RAM for WiFi + TLS (free %uK, need %uK): this app is too big for network use",
             static_cast<unsigned>(freeNow / 1024), static_cast<unsigned>(NET_MIN_FREE_BYTES / 1024));
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
  return 1;
}

bool startsWithHttp(const char* u) { return !strncasecmp(u, "http://", 7) || !strncasecmp(u, "https://", 8); }

// http.request{ url=, method="GET"|"POST", headers={name=value,...}, body=, save_to="data:path", max_body=N }
//   -> { status=, ok=, bytes=, body= } | nil, err      (body is absent in save_to mode)
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
  if (strcmp(method, "GET") && strcmp(method, "POST")) return pushFail(L, "method must be GET or POST");

  lua_getfield(L, 1, "body");
  size_t bodyLen = 0;
  const char* body = lua_isnil(L, -1) ? nullptr : luaL_checklstring(L, -1, &bodyLen);
  if (bodyLen > MAX_POST_BODY) return pushFail(L, "body too large");
  if (body && !strcmp(method, "GET")) return pushFail(L, "a GET request cannot have a body");

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
    if (sc != Scope::Data) return pushFail(L, "save_to must be a data: path");
    if (!strcmp(method, "POST")) return pushFail(L, "save_to is only supported for GET");
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

  Backend::HttpResult res;
  const bool got = be(L).httpRequest(rq, res);  // POD in/out: nothing here can be skipped by a longjmp
  if (!got) {
    char msg[sizeof(res.error)];
    snprintf(msg, sizeof(msg), "%s", res.error[0] ? res.error : "request failed");
    free(res.body);
    return pushFail(L, msg);
  }

  Push p{&res, savePtr != nullptr};
  lua_pushcfunction(L, push_response);
  lua_pushlightuserdata(L, &p);
  const int rc = lua_pcall(L, 1, 1, 0);  // an out-of-memory error here is caught, so res.body is always freed below
  free(res.body);
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
  lua_pushvalue(L, lua_upvalueindex(2));  // http_request closure
  lua_pushvalue(L, t);
  lua_call(L, 1, LUA_MULTRET);
  return lua_gettop(L) - t;
}

}  // namespace

void registerNet(lua_State* L, Ctx* c) {
  static const luaL_Reg wifiFns[] = {{"connect", wifi_connect}, {"status", wifi_status}, {"off", wifi_off},
                                   {"scan", wifi_scan}, {nullptr, nullptr}};
  regTable(L, c, "wifi", wifiFns);
  static const luaL_Reg httpFns[] = {{"request", http_request}, {nullptr, nullptr}};
  regTable(L, c, "http", httpFns);
  // http.get needs the request function as a second upvalue.
  lua_getglobal(L, "http");
  lua_getfield(L, -1, "request");
  lua_pushlightuserdata(L, c);
  lua_pushvalue(L, -2);
  lua_pushcclosure(L, http_get, 2);
  lua_setfield(L, -3, "get");  // [http, request, closure] -> http.get = closure
  lua_pop(L, 2);
}

}  // namespace crosslua
