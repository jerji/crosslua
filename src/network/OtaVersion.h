#pragma once

#include <cstdio>
#include <cstring>

// Version comparison for OTA updates, split out of OtaUpdater so the host tests can exercise it.
//
// Versions look like  <major>.<minor>.<patch>[-crosslua.<rev>][-rc...][-dev-...]
//   "2.0.0"                      upstream CrossPoint
//   "2.0.0-crosslua.3"           CrossLua release: upstream base 2.0.0, CrossLua revision 3
//   "2.0.0-crosslua.1-dev-x-abc" a development build of revision 1
// The base is compared first, then the CrossLua revision (a missing suffix counts as revision 0, so a CrossLua build is
// newer than the bare upstream version it is based on), then the upstream "-rc builds always update" rule.
namespace ota_version {

struct Parsed {
  int major = 0;
  int minor = 0;
  int patch = 0;
  int rev = 0;  // CrossLua revision; 0 when the string has no "-crosslua.N"
};

// "v2.0.0-crosslua.1" and "2.0.0-crosslua.1" are the same version: the release workflow names assets without the "v".
inline const char* skipV(const char* v) { return (v != nullptr && (v[0] == 'v' || v[0] == 'V')) ? v + 1 : v; }

inline Parsed parse(const char* v) {
  Parsed p;
  v = skipV(v);
  if (v == nullptr) return p;
  sscanf(v, "%d.%d.%d", &p.major, &p.minor, &p.patch);
  const char* tag = strstr(v, "-crosslua.");
  if (tag != nullptr) sscanf(tag + strlen("-crosslua."), "%d", &p.rev);
  return p;
}

// true when `latest` should replace `current`.
inline bool isNewer(const char* latest, const char* current) {
  if (latest == nullptr || current == nullptr || latest[0] == '\0' || strcmp(latest, current) == 0) return false;
  const Parsed l = parse(latest);
  const Parsed c = parse(current);
  if (l.major != c.major) return l.major > c.major;
  if (l.minor != c.minor) return l.minor > c.minor;
  if (l.patch != c.patch) return l.patch > c.patch;
  if (l.rev != c.rev) return l.rev > c.rev;
  // All numbers equal. On a release-candidate build the latest release counts as newer (upstream rule).
  return strstr(current, "-rc") != nullptr;
}

}  // namespace ota_version
