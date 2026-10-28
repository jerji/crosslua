// OTA version-comparison tests (see src/network/OtaVersion.h). Deliberately a separate translation unit from test_vm.cpp:
// test_vm.cpp takes ~110 s to compile under the sanitizers, and mutation runs edit OtaVersion.h once per mutant. The fixtures
// use synthetic versions (9.9.9, 0.0.0) on purpose: nothing here reads the firmware's real version, so releases never
// require test changes.
#include "src/network/OtaVersion.h"

#include <cstdio>
#include <cstring>

static int fails = 0;
#define CHECK(c) \
    do { \
      if (!(c)) { \
        printf("  OTA FAIL line %d: %s\n", __LINE__, #c); \
        ++fails; \
      } \
    } while (0)

int ota_version_tests() {
  using ota_version::isNewer;
  using ota_version::parse;
  CHECK(!isNewer("9.9.9-crosslua.5", "9.9.9-crosslua.5"));  // identical
  CHECK(isNewer("9.9.9-crosslua.5", "9.9.9"));              // CrossLua is newer than the bare upstream base
  CHECK(!isNewer("9.9.9", "9.9.9-crosslua.5"));             // ...and never the other way round
  CHECK(isNewer("9.9.9-crosslua.6", "9.9.9-crosslua.5"));
  CHECK(!isNewer("9.9.9-crosslua.5", "9.9.9-crosslua.6"));
  CHECK(isNewer("9.9.9-crosslua.10", "9.9.9-crosslua.9"));  // numeric, not lexical
  CHECK(!isNewer("9.9.9-crosslua.9", "9.9.9-crosslua.10"));
  CHECK(isNewer("2.1.0-crosslua.1", "2.0.5-crosslua.9"));   // the base dominates the revision
  CHECK(!isNewer("2.0.0-crosslua.9", "2.1.0-crosslua.1"));
  CHECK(isNewer("3.0.0-crosslua.1", "2.9.9-crosslua.99"));
  CHECK(isNewer("2.0.1", "2.0.0-crosslua.5"));
  CHECK(!isNewer("9.9.9-crosslua.5", "9.9.9-crosslua.5-dev-lua-runtime-abc1234"));  // a dev build of rev 5 is not outdated by rev 5
  CHECK(isNewer("9.9.9-crosslua.6", "9.9.9-crosslua.5-dev-lua-runtime-abc1234"));
  CHECK(isNewer("9.9.9-crosslua.5", "9.9.9-crosslua.5-rc+abc1234"));  // upstream rule: an rc build takes the release
  CHECK(!isNewer("9.9.9-crosslua.5", "9.9.9-crosslua.6-rc+abc1234"));
  // "-crosslua" must be followed by ".<digits>" to count: without the dot the suffix is not a revision.
  CHECK(!isNewer("9.9.9-crossluaX1", "9.9.9-crosslua.0"));
  CHECK(parse("9.9.9-crossluaX1").rev == 0);
  CHECK(parse("9.9.9-crosslua.1").rev == 1);
  CHECK(!isNewer("9.9.9-crosslua.5-rc+abc", "9.9.9-crosslua.5-rc+abc"));  // an rc build does not reinstall itself
  CHECK(!isNewer("", "0.0.0-rc+deadbeef"));  // an empty latest string is never an update, not even over an rc build
  CHECK(!isNewer("", "9.9.9"));
  CHECK(!isNewer(nullptr, "9.9.9"));
  CHECK(!isNewer("9.9.9", nullptr));
  const auto p1 = parse("9.9.9-crosslua.12-dev-x");
  CHECK(p1.major == 9 && p1.minor == 9 && p1.patch == 9 && p1.rev == 12);
  const auto p2 = parse("7.8.9");
  CHECK(p2.major == 7 && p2.minor == 8 && p2.patch == 9 && p2.rev == 0);
  // a leading "v" on a tag is ignored (assets are named without it)
  CHECK(parse("v9.9.9-crosslua.7").rev == 7 && parse("v9.9.9-crosslua.7").major == 9);
  CHECK(isNewer("v9.9.9-crosslua.6", "9.9.9-crosslua.5"));
  CHECK(parse("V9.9.9-crosslua.2").major == 9 && parse("V9.9.9-crosslua.2").rev == 2);
  CHECK(!isNewer("v9.9.9-crosslua.5", "9.9.9-crosslua.5"));
  CHECK(std::strcmp(ota_version::skipV("v1.2.3"), "1.2.3") == 0 && std::strcmp(ota_version::skipV("1.2.3"), "1.2.3") == 0);
  CHECK(ota_version::skipV(nullptr) == nullptr);
  CHECK(parse("garbage").major == 0 && parse(nullptr).rev == 0);
  if (fails) printf("OTA version tests: %d FAILED\n", fails);
  return fails;
}
