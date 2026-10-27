#!/usr/bin/env python3
import atexit, os, shutil, subprocess
os.chdir('/root/x4/crosspoint-lua')
F = 'src/lua/LuaNet.cpp'
shutil.copy(F, '/tmp/orig25_LuaNet.cpp')
def restore(): shutil.copy('/tmp/orig25_LuaNet.cpp', F)
atexit.register(restore)
def run():
    r = subprocess.run('test/lua_host/run.sh 2>&1 | grep -E "FAILED|EXIT CODE|ALL PASSED|COMPILE" | head -2', shell=True, capture_output=True, text=True)
    return r.stdout.strip().replace('\n', ' | ')
M = [
 ('HT1 no default content type on a body', 'if (body && !contentType) contentType = "application/x-www-form-urlencoded";', ''),
 ('HT2 DELETE may carry a body', '|| !strcmp(m, "PATCH");', '|| !strcmp(m, "PATCH") || !strcmp(m, "DELETE");'),
 ('HT3 PUT refused', '|| !strcmp(m, "PUT")', ''),
 ('HT4 PATCH refused as a method', '|| !strcmp(m, "PATCH") || !strcmp(m, "DELETE");', '|| !strcmp(m, "DELETE");'),
 ('HT5 DELETE refused as a method', '|| !strcmp(m, "PATCH") || !strcmp(m, "DELETE");', '|| !strcmp(m, "PATCH");'),
 ('HT6 content_type without a body allowed', 'if (!body) return pushFail(L, "content_type needs a body");', ''),
 ('HT7 empty content_type allowed', 'if (cl == 0 || cl > MAX_CONTENT_TYPE_LEN', 'if (cl > MAX_CONTENT_TYPE_LEN'),
 ('HT8 content_type length cap raised', 'cl > MAX_CONTENT_TYPE_LEN', 'cl > MAX_CONTENT_TYPE_LEN * 10'),
 ('HT9 CR/LF in content_type allowed', ' || strpbrk(contentType, "\\r\\n")) return pushFail(L, "illegal content_type");', ') return pushFail(L, "illegal content_type");'),
 ('HT10 Content-Type header with a body allowed', 'if (body && !strcasecmp(k, "content-type"))', 'if (false)'),
 ('HT11 Content-Type header check is case sensitive', 'strcasecmp(k, "content-type")', 'strcmp(k, "Content-Type")'),
 ('HT12 response_headers type unchecked', 'if (!lua_isnil(L, -1) && lua_type(L, -1) != LUA_TBOOLEAN) return luaL_argerror(L, 1, "response_headers must be a boolean");', ''),
 ('HT13 ca on plain http allowed', 'if (strncasecmp(url, "https://", 8)) return pushFail(L, "ca only applies to https:// urls");', ''),
 ('HT14 ca type unchecked', 'if (lua_type(L, -1) != LUA_TSTRING) return luaL_argerror(L, 1, "ca must be a path string");', ''),
 ('HT15 save_to combined with ca/headers allowed', 'if (wantHeaders || caPem) return pushFail(L, "save_to cannot be combined with ca or response_headers yet");', ''),
 ('HT16 save_to allowed for PUT', 'if (strcmp(method, "GET")) return pushFail(L, "save_to is only supported for GET");', 'if (!strcmp(method, "POST")) return pushFail(L, "save_to is only supported for GET");'),
 ('HT17 response names not lower-cased', 'static_cast<char>(tolower(static_cast<unsigned char>(line[i])))', 'line[i]'),
 ('HT18 repeated headers overwrite instead of join', 'lua_pushstring(L, ", ");', 'lua_pushstring(L, "; ");'),
 ('HT19 leading value whitespace kept', "while (v < lineEnd && (*v == ' ' || *v == '\\t')) v++;", ''),
 ('HT20 trailing CR kept', "while (ve > v && (ve[-1] == '\\r' ||", "while (ve > v && (false ||"),
 ('HT21 empty header name accepted', 'if (colon && colon > line && static_cast', 'if (colon && static_cast'),
 ('HT22 header count cap raised', 'count < MAX_RESPONSE_HEADERS', 'count < MAX_RESPONSE_HEADERS + 1'),
 ('HT23 header name length cap raised', '<= MAX_HEADER_LEN) {', '<= MAX_HEADER_LEN + 1) {'),
 ('HT24 response headers leaked on success', '  free(res.body);\n  free(res.headers);\n  if (rc != LUA_OK) {', '  free(res.body);\n  if (rc != LUA_OK) {'),
 ('HT25 body allowed on a GET again', 'if (body && !methodTakesBody(method)) {', 'if (false) {'),
 ('HT26 content type passed even without a body', 'if (body && !contentType) contentType', 'if (!contentType) contentType'),
]
print('== baseline', run(), flush=True)
for name, a, b in M:
    s = open(F).read()
    if a not in s: print('!! anchor missing', name); continue
    open(F, 'w').write(s.replace(a, b, 1))
    print('==', name, '->', run(), flush=True)
    restore()
print('== restored ->', run(), flush=True); print('ALLDONE', flush=True)
