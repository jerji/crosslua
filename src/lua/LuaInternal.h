#pragma once
// Shared helpers for the API translation units. Not part of the public surface.
#include "LuaApi.h"

extern "C" {
#include "lauxlib.h"
#include "lua.h"
}

namespace crosslua {

class LuaVm;

struct Ctx {
  Backend* be;
  LuaVm* vm;
};
// The context lives in the state's extra space (copied into every coroutine at creation), so every binding is a LIGHT C
// function: no closure object and no upvalue on the heap (saves ~32 bytes per function).
inline Ctx* ctx(lua_State* L) { return *static_cast<Ctx**>(lua_getextraspace(L)); }
inline Backend& be(lua_State* L) { return *ctx(L)->be; }

// Registers a global table of light C functions (they find the Ctx through the state's extra space).
void regTable(lua_State* L, Ctx* c, const char* name, const luaL_Reg* funcs);

constexpr size_t MAX_PATH_LEN = 200;
constexpr size_t MAX_READ_BYTES = 128 * 1024;
constexpr size_t MAX_WRITE_BYTES = 256 * 1024;
constexpr size_t MAX_WRITE_AT_BYTES = 16 * 1024;
constexpr size_t MAX_MODULE_BYTES = 64 * 1024;

enum class Scope {
  App,
  Data,
  Lib,
  Sd
};  // Sd = the SD card outside the sandbox: read-only, needs "library", no hidden paths

// Path sandbox. Accepts "app:rel", "data:rel", "lib:rel" or bare "rel" (= app:). rel must be a clean
// relative path: no "..", ".", empty parts, leading '/', backslashes, ':' or control chars.
// On success writes the absolute SD path to out and returns true; otherwise sets *err.
bool resolvePath(Backend& be, const char* spec, char* out, size_t cap, Scope* scope, const char** err);
// Same, for an already-split scope + relative path.
bool resolveIn(Backend& be, Scope scope, const char* rel, char* out, size_t cap, const char** err);

// ---- storage grants (see LuaApi.h) ----
// Normalises a manifest grant ("Books", "Books/AO3/", "/" = whole card) into out ("Books", "Books/AO3", ""). false for
// anything unsafe: "..", ".", hidden (dot) components, ':' or '\\', control chars, empty components, too long.
bool parseGrantPath(const char* in, char* out, size_t cap);
// A grant that reaches other apps' code or the whole card (write): shown with a louder warning.
bool grantIsDangerous(const char* rel);
// Does an approved grant cover rel (relative, no leading '/')? write=true needs a WRITE grant.
bool sdCovered(Backend& b, const char* rel, bool write);
// May this app WRITE absPath ("/Books/x.epub") in scope sc? data: always; sd: only under a write grant, never *.bin.
bool writeAllowed(Backend& b, Scope sc, const char* absPath);

void registerFs(lua_State* L, Ctx* c);
void registerJson(lua_State* L, Ctx* c);
void registerRequire(lua_State* L, Ctx* c);
void registerNet(lua_State* L, Ctx* c);
void registerZip(lua_State* L, Ctx* c);
void registerCrypto(lua_State* L, Ctx* c);
void registerXml(lua_State* L, Ctx* c);
void registerSock(lua_State* L, Ctx* c);
void registerAudio(lua_State* L, Ctx* c);
void registerMic(lua_State* L, Ctx* c);
void registerEspNow(lua_State* L, Ctx* c);
void registerWifiMonitor(lua_State* L, Ctx* c);
void registerWifiTx(lua_State* L, Ctx* c);
void registerBle(lua_State* L, Ctx* c);
// Same write rules as fs.write (data: always, sd: only with a write grant, never *.bin) for bindings outside LuaFs.cpp.
// On failure pushes nil,msg and returns false. ensureParentDir creates the parent folder (recursive) when missing.
bool writePathArg(lua_State* L, int i, char* out, size_t cap);
bool ensureParentDir(Backend& b, const char* path);
// Loads a PEM trust anchor (`ca=` option of net.connect{tls=true} and http.request) through the read sandbox into a
// Lua-heap userdata that stays on the stack. 0 = ok (*pem is NUL-terminated); otherwise pushes nil,msg and returns 2.
int loadCa(lua_State* L, const char* spec, char** pem);
void registerGfxSaveBmp(
    lua_State* L);  // adds gfx.save_bmp / gfx.image to the eager gfx table (they must not wait for fs/zip)
void registerGfxImage(lua_State* L);

// Shared by wifi.*, http.* and net.*: what an app sees when its manifest lacks the permission.
inline constexpr const char* NET_DENIED =
    "network not permitted: add \"permissions\": [\"network\"] to this app's manifest.json";
// For net.listen and net.accept (exposes the device to the LAN): an extra permission beyond the base network
// permission.
inline constexpr const char* TX_DENIED =
    "tx not permitted: add \"permissions\": [\"network\", \"tx\"] to this app's manifest.json (and approve it)";
inline constexpr const char* MONITOR_DENIED =
    "monitor not permitted: add \"permissions\": [\"network\", \"monitor\"] to this app's manifest.json (and approve "
    "it)";
inline constexpr const char* ESPNOW_DENIED =
    "espnow not permitted: add \"permissions\": [\"network\", \"espnow\"] to this app's manifest.json (and approve it)";
inline constexpr const char* HOTSPOT_DENIED =
    "hotspot not permitted: add \"permissions\": [\"network\", \"hotspot\"] to this app's manifest.json (and approve "
    "it)";
inline constexpr const char* MIC_DENIED =
    "microphone not permitted: add \"permissions\": [\"microphone\"] to this app's manifest.json (and approve it)";
inline constexpr const char* AUDIO_DENIED =
    "audio not permitted: add \"permissions\": [\"audio\"] to this app's manifest.json (and approve it)";
inline constexpr const char* BLE_DENIED =
    "bluetooth not permitted: add \"permissions\": [\"bluetooth\"] to this app's manifest.json (and approve it)";
inline constexpr const char* LISTEN_DENIED =
    "listen not permitted: add \"permissions\": [\"listen\"] to this app's manifest.json";

}  // namespace crosslua
