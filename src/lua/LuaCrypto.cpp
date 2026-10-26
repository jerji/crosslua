// crypto.* — hashes, HMAC, PBKDF2, random bytes, hex/base64, constant-time compare. See docs/lua/API.md.
// Everything is mbedtls (the library the firmware already links for OTA hashing, and that biscuit's TOTP / PIN / SD-
// encryption apps call; on the ESP32-C3 SHA and AES run on the hardware accelerators). The host tests compile the SAME
// mbedtls 3.x sources (test/lua_host/run.sh). Only random bytes come from the Backend (esp_fill_random on the device).
#include <mbedtls/aes.h>
#include <mbedtls/md.h>
#include <mbedtls/sha1.h>
#include <mbedtls/sha256.h>

#include <cstdlib>
#include <cstring>

#include "LuaInternal.h"

namespace crosslua {
namespace {

constexpr size_t MAX_DATA = 64 * 1024;   // one-shot input / hash:update() chunk
constexpr size_t MAX_KEYISH = 1024;      // pbkdf2 password and salt
constexpr size_t MAX_HEX_IN = 16 * 1024; // crypto.hex input -> 32 KB string
constexpr size_t MAX_B64_IN = 24 * 1024;
constexpr uint32_t MAX_PBKDF2_WORK = 20000;  // iterations x 32-byte output blocks (blocking: about a second or two)
const char* const HASH_MT = "crosslua.hash";

int pushFail(lua_State* L, const char* msg) {
  lua_pushnil(L);
  lua_pushstring(L, msg);
  return 2;
}

const uint8_t* dataArg(lua_State* L, int i, size_t* n) { return reinterpret_cast<const uint8_t*>(luaL_checklstring(L, i, n)); }

// ---- one-shot hashes -----------------------------------------------------------------------------------------------
constexpr size_t DIGEST256 = 32, DIGEST1 = 20;
int pushDigest(lua_State* L, int rc, const uint8_t* out, size_t n) {
  if (rc != 0) return pushFail(L, "hash failed");
  lua_pushlstring(L, reinterpret_cast<const char*>(out), n);
  return 1;
}
int cr_sha256(lua_State* L) {
  size_t n;
  const uint8_t* d = dataArg(L, 1, &n);
  if (n > MAX_DATA) return pushFail(L, "data must be at most 64 KB (use crypto.hash for more)");
  uint8_t out[DIGEST256];
  return pushDigest(L, mbedtls_sha256(d, n, out, 0), out, sizeof(out));
}
int cr_sha1(lua_State* L) {
  size_t n;
  const uint8_t* d = dataArg(L, 1, &n);
  if (n > MAX_DATA) return pushFail(L, "data must be at most 64 KB (use crypto.hash for more)");
  uint8_t out[DIGEST1];
  return pushDigest(L, mbedtls_sha1(d, n, out), out, sizeof(out));
}
int hmacWith(lua_State* L, mbedtls_md_type_t type, size_t digestLen) {
  size_t kl, n;
  const uint8_t* k = dataArg(L, 1, &kl);
  const uint8_t* d = dataArg(L, 2, &n);
  if (kl > MAX_DATA || n > MAX_DATA) return pushFail(L, "key and data must be at most 64 KB");
  uint8_t out[DIGEST256];
  return pushDigest(L, mbedtls_md_hmac(mbedtls_md_info_from_type(type), k, kl, d, n, out), out, digestLen);
}
int cr_hmac_sha256(lua_State* L) { return hmacWith(L, MBEDTLS_MD_SHA256, DIGEST256); }
int cr_hmac_sha1(lua_State* L) { return hmacWith(L, MBEDTLS_MD_SHA1, DIGEST1); }

// ---- incremental hash object: crypto.hash("sha256"|"sha1") -> h; h:update(s) -> h; h:digest() -> bytes -------------
struct HashObj {
  uint8_t alg;  // 1 = sha1, 2 = sha256
  bool done;
  union {
    mbedtls_sha1_context s1;
    mbedtls_sha256_context s256;
  };
};
HashObj* hashArg(lua_State* L) { return static_cast<HashObj*>(luaL_checkudata(L, 1, HASH_MT)); }
int cr_hash(lua_State* L) {
  const char* alg = luaL_checkstring(L, 1);
  const bool s1 = !strcmp(alg, "sha1"), s256 = !strcmp(alg, "sha256");
  if (!s1 && !s256) return pushFail(L, "unknown algorithm (sha1, sha256)");
  HashObj* h = static_cast<HashObj*>(lua_newuserdatauv(L, sizeof(HashObj), 0));
  memset(h, 0, sizeof(*h));
  h->alg = s1 ? 1 : 2;
  luaL_setmetatable(L, HASH_MT);  // set first: __gc must see a valid object even if starts() fails
  int rc;
  if (s1) {
    mbedtls_sha1_init(&h->s1);
    rc = mbedtls_sha1_starts(&h->s1);
  } else {
    mbedtls_sha256_init(&h->s256);
    rc = mbedtls_sha256_starts(&h->s256, 0);
  }
  if (rc != 0) {
    h->done = true;
    return pushFail(L, "hash failed");
  }
  return 1;
}
int hash_update(lua_State* L) {
  HashObj* h = hashArg(L);
  size_t n;
  const uint8_t* d = dataArg(L, 2, &n);
  if (h->done) return pushFail(L, "hash already finished (digest() was called)");
  if (n > MAX_DATA) return pushFail(L, "chunk must be at most 64 KB");
  const int rc = h->alg == 1 ? mbedtls_sha1_update(&h->s1, d, n) : mbedtls_sha256_update(&h->s256, d, n);
  if (rc != 0) return pushFail(L, "hash failed");
  lua_settop(L, 1);  // return the object so calls chain
  return 1;
}
int hash_digest(lua_State* L) {
  HashObj* h = hashArg(L);
  if (h->done) return pushFail(L, "hash already finished (digest() was called)");
  h->done = true;
  uint8_t out[DIGEST256];
  const int rc = h->alg == 1 ? mbedtls_sha1_finish(&h->s1, out) : mbedtls_sha256_finish(&h->s256, out);
  return pushDigest(L, rc, out, h->alg == 1 ? DIGEST1 : DIGEST256);
}
int hash_gc(lua_State* L) {  // wipes the context (mbedtls_*_free zeroizes)
  HashObj* h = static_cast<HashObj*>(lua_touserdata(L, 1));
  if (h && h->alg == 1) mbedtls_sha1_free(&h->s1);
  else if (h && h->alg == 2) mbedtls_sha256_free(&h->s256);
  return 0;
}

// ---- pbkdf2 / random -------------------------------------------------------------------------------------------------
// RFC 8018 PBKDF2-HMAC-SHA256 as a loop over mbedtls HMAC (what mbedtls_pkcs5_pbkdf2_hmac does, without needing the
// PKCS5 module linked into the firmware image).
bool pbkdf2(const uint8_t* pw, size_t pl, const uint8_t* salt, size_t sl, uint32_t iterations, uint8_t* out, size_t outLen) {
  mbedtls_md_context_t ctx;
  mbedtls_md_init(&ctx);
  const mbedtls_md_info_t* info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  bool ok = info && mbedtls_md_setup(&ctx, info, 1) == 0 && mbedtls_md_hmac_starts(&ctx, pw, pl) == 0;
  for (uint32_t block = 1; ok && outLen > 0; block++) {
    uint8_t u[32], t[32];
    const uint8_t idx[4] = {uint8_t(block >> 24), uint8_t(block >> 16), uint8_t(block >> 8), uint8_t(block)};
    ok = mbedtls_md_hmac_reset(&ctx) == 0 && mbedtls_md_hmac_update(&ctx, salt, sl) == 0 &&
         mbedtls_md_hmac_update(&ctx, idx, 4) == 0 && mbedtls_md_hmac_finish(&ctx, u) == 0;
    memcpy(t, u, 32);
    for (uint32_t i = 1; ok && i < iterations; i++) {
      ok = mbedtls_md_hmac_reset(&ctx) == 0 && mbedtls_md_hmac_update(&ctx, u, 32) == 0 && mbedtls_md_hmac_finish(&ctx, u) == 0;
      for (int j = 0; j < 32; j++) t[j] ^= u[j];
    }
    const size_t take = outLen < 32 ? outLen : 32;
    memcpy(out, t, take);
    out += take;
    outLen -= take;
  }
  mbedtls_md_free(&ctx);
  return ok;
}
// crypto.pbkdf2_sha256(password, salt, iterations, len) -> bytes | nil, err. Blocking: iterations x ceil(len/32) <= 20000.
int cr_pbkdf2(lua_State* L) {
  size_t pl, sl;
  const uint8_t* pw = dataArg(L, 1, &pl);
  const uint8_t* salt = dataArg(L, 2, &sl);
  const lua_Number it = luaL_checknumber(L, 3), len = luaL_checknumber(L, 4);
  if (pl > MAX_KEYISH || sl > MAX_KEYISH) return pushFail(L, "password and salt must be at most 1 KB");
  if (it < 1 || it > MAX_PBKDF2_WORK || it != static_cast<uint32_t>(it)) return pushFail(L, "iterations must be an integer 1..20000");
  if (len < 1 || len > 64 || len != static_cast<size_t>(len)) return pushFail(L, "len must be an integer 1..64");
  const uint32_t blocks = (static_cast<uint32_t>(len) + 31) / 32;
  if (static_cast<uint32_t>(it) * blocks > MAX_PBKDF2_WORK) return pushFail(L, "too much work: iterations x ceil(len/32) must be <= 20000");
  uint8_t out[64];
  if (!pbkdf2(pw, pl, salt, sl, static_cast<uint32_t>(it), out, static_cast<size_t>(len))) return pushFail(L, "pbkdf2 failed");
  lua_pushlstring(L, reinterpret_cast<const char*>(out), static_cast<size_t>(len));
  return 1;
}
int cr_random(lua_State* L) {
  const lua_Number n = luaL_checknumber(L, 1);
  if (n < 1 || n > 256 || n != static_cast<int>(n)) return pushFail(L, "n must be an integer 1..256");
  uint8_t buf[256];
  be(L).randomBytes(buf, static_cast<size_t>(n));
  lua_pushlstring(L, reinterpret_cast<const char*>(buf), static_cast<size_t>(n));
  return 1;
}

// ---- hex / base64 / constant-time compare ------------------------------------------------------------------------------
int cr_hex(lua_State* L) {
  size_t n;
  const uint8_t* d = dataArg(L, 1, &n);
  if (n > MAX_HEX_IN) return pushFail(L, "input must be at most 16 KB");
  static const char H[] = "0123456789abcdef";
  luaL_Buffer b;
  char* p = luaL_buffinitsize(L, &b, n * 2 + 1);
  for (size_t i = 0; i < n; i++) {
    p[i * 2] = H[d[i] >> 4];
    p[i * 2 + 1] = H[d[i] & 15];
  }
  luaL_pushresultsize(&b, n * 2);
  return 1;
}
int hexVal(int c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}
int cr_unhex(lua_State* L) {
  size_t n;
  const uint8_t* d = dataArg(L, 1, &n);
  if (n > MAX_HEX_IN * 2) return pushFail(L, "input must be at most 32 KB");
  if (n % 2) return pushFail(L, "odd number of hex digits");
  luaL_Buffer b;
  char* p = luaL_buffinitsize(L, &b, n / 2 + 1);
  for (size_t i = 0; i < n / 2; i++) {
    const int hi = hexVal(d[i * 2]), lo = hexVal(d[i * 2 + 1]);
    if (hi < 0 || lo < 0) {
      lua_pushnil(L);  // (the half-built buffer is just garbage on the stack: drop it)
      lua_pushstring(L, "not a hex string");
      return 2;
    }
    p[i] = static_cast<char>(hi * 16 + lo);
  }
  luaL_pushresultsize(&b, n / 2);
  return 1;
}
const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
int cr_b64encode(lua_State* L) {
  size_t n;
  const uint8_t* d = dataArg(L, 1, &n);
  if (n > MAX_B64_IN) return pushFail(L, "input must be at most 24 KB");
  const size_t outLen = (n + 2) / 3 * 4;
  luaL_Buffer b;
  char* p = luaL_buffinitsize(L, &b, outLen + 1);
  size_t o = 0;
  for (size_t i = 0; i < n; i += 3) {
    const uint32_t v = (uint32_t(d[i]) << 16) | (i + 1 < n ? uint32_t(d[i + 1]) << 8 : 0) | (i + 2 < n ? d[i + 2] : 0);
    p[o++] = B64[(v >> 18) & 63];
    p[o++] = B64[(v >> 12) & 63];
    p[o++] = i + 1 < n ? B64[(v >> 6) & 63] : '=';
    p[o++] = i + 2 < n ? B64[v & 63] : '=';
  }
  luaL_pushresultsize(&b, outLen);
  return 1;
}
int b64Val(int c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  return -1;
}
// Strict RFC 4648: standard alphabet, length multiple of 4, '=' only as 1-2 trailing pad characters, no whitespace.
int cr_b64decode(lua_State* L) {
  size_t n;
  const uint8_t* d = dataArg(L, 1, &n);
  if (n > MAX_B64_IN * 2) return pushFail(L, "input must be at most 48 KB");
  if (n % 4) return pushFail(L, "not valid base64 (length must be a multiple of 4)");
  size_t pad = 0;
  if (n && d[n - 1] == '=') pad = (n >= 2 && d[n - 2] == '=') ? 2 : 1;
  luaL_Buffer b;
  char* p = luaL_buffinitsize(L, &b, n / 4 * 3 + 1);
  size_t o = 0;
  for (size_t i = 0; i < n; i += 4) {
    int v[4];
    for (int j = 0; j < 4; j++) {
      const bool isPad = (i + j >= n - pad);
      v[j] = isPad ? 0 : b64Val(d[i + j]);
      if (!isPad && v[j] < 0) return pushFail(L, "not valid base64");
    }
    const uint32_t x = (uint32_t(v[0]) << 18) | (uint32_t(v[1]) << 12) | (uint32_t(v[2]) << 6) | uint32_t(v[3]);
    p[o++] = static_cast<char>(x >> 16);
    p[o++] = static_cast<char>(x >> 8);
    p[o++] = static_cast<char>(x);
  }
  luaL_pushresultsize(&b, n / 4 * 3 - pad);  // the pad characters stood for zero bits: trim the surplus bytes
  return 1;
}
// crypto.equal(a, b) -> boolean. The comparison time depends only on #a, never on where the strings first differ.
int cr_equal(lua_State* L) {
  size_t la, lb;
  const uint8_t* a = dataArg(L, 1, &la);
  const uint8_t* b = dataArg(L, 2, &lb);
  uint8_t diff = static_cast<uint8_t>(la != lb);
  for (size_t i = 0; i < la; i++) diff |= static_cast<uint8_t>(a[i] ^ (lb ? b[i % lb] : 0));
  lua_pushboolean(L, diff == 0);
  return 1;
}

// ---- AES-CBC with PKCS#7 padding ---------------------------------------------------------------------------------------
// crypto.aes_cbc_encrypt(key, iv, data) / crypto.aes_cbc_decrypt(key, iv, ciphertext) -> bytes | nil, err
// key = 16/24/32 bytes, iv = 16 bytes (use crypto.random(16), never reuse an iv with one key). CBC does NOT authenticate:
// store hmac_sha256(mac_key, iv .. ciphertext) next to the ciphertext and check it with crypto.equal BEFORE decrypting.
constexpr size_t MAX_AES = 32 * 1024;
int aesCbc(lua_State* L, bool encrypt) {
  size_t kl, il, dl;
  const uint8_t* key = dataArg(L, 1, &kl);
  const uint8_t* iv = dataArg(L, 2, &il);
  const uint8_t* d = dataArg(L, 3, &dl);
  if (kl != 16 && kl != 24 && kl != 32) return pushFail(L, "key must be 16, 24 or 32 bytes");
  if (il != 16) return pushFail(L, "iv must be 16 bytes");
  if (dl > MAX_AES) return pushFail(L, "data must be at most 32 KB");
  if (!encrypt && (dl == 0 || dl % 16)) return pushFail(L, "ciphertext length must be a non-zero multiple of 16");
  const size_t total = encrypt ? dl + (16 - dl % 16) : dl;
  luaL_Buffer b;
  uint8_t* buf = reinterpret_cast<uint8_t*>(luaL_buffinitsize(L, &b, total));  // may raise out-of-memory: nothing to leak yet
  uint8_t ivCopy[16];
  memcpy(ivCopy, iv, 16);
  if (encrypt) {
    memcpy(buf, d, dl);
    memset(buf + dl, static_cast<int>(16 - dl % 16), 16 - dl % 16);
  }
  mbedtls_aes_context aes;
  mbedtls_aes_init(&aes);
  int rc = encrypt ? mbedtls_aes_setkey_enc(&aes, key, static_cast<unsigned>(kl * 8)) : mbedtls_aes_setkey_dec(&aes, key, static_cast<unsigned>(kl * 8));
  if (rc == 0) rc = mbedtls_aes_crypt_cbc(&aes, encrypt ? MBEDTLS_AES_ENCRYPT : MBEDTLS_AES_DECRYPT, total, ivCopy, encrypt ? buf : d, buf);
  mbedtls_aes_free(&aes);  // zeroizes the key schedule
  if (rc != 0) return pushFail(L, "aes failed");
  size_t outLen = total;
  if (!encrypt) {  // strip PKCS#7 padding (all pad bytes checked, no early exit on the first bad byte)
    const uint8_t pad = buf[total - 1];
    uint8_t bad = static_cast<uint8_t>(pad == 0 || pad > 16);
    for (size_t i = 0; i < 16 && i < total; i++) bad |= static_cast<uint8_t>((i < pad) & (buf[total - 1 - i] != pad));
    if (bad) return pushFail(L, "bad padding (wrong key, wrong iv or corrupted data)");
    outLen = total - pad;
  }
  luaL_pushresultsize(&b, outLen);
  return 1;
}
int cr_aes_cbc_encrypt(lua_State* L) { return aesCbc(L, true); }
int cr_aes_cbc_decrypt(lua_State* L) { return aesCbc(L, false); }

}  // namespace

void registerCrypto(lua_State* L, Ctx* c) {
  static const luaL_Reg fns[] = {{"sha1", cr_sha1},         {"sha256", cr_sha256},     {"hmac_sha1", cr_hmac_sha1},
                                 {"hmac_sha256", cr_hmac_sha256}, {"hash", cr_hash},   {"pbkdf2_sha256", cr_pbkdf2},
                                 {"random", cr_random},     {"hex", cr_hex},           {"unhex", cr_unhex},
                                 {"b64encode", cr_b64encode}, {"b64decode", cr_b64decode}, {"equal", cr_equal},
                                 {"aes_cbc_encrypt", cr_aes_cbc_encrypt}, {"aes_cbc_decrypt", cr_aes_cbc_decrypt},
                                 {nullptr, nullptr}};
  regTable(L, c, "crypto", fns);
  if (luaL_newmetatable(L, HASH_MT)) {
    static const luaL_Reg methods[] = {{"update", hash_update}, {"digest", hash_digest}, {nullptr, nullptr}};
    lua_newtable(L);
    luaL_setfuncs(L, methods, 0);
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, hash_gc);
    lua_setfield(L, -2, "__gc");
  }
  lua_pop(L, 1);
}

}  // namespace crosslua
