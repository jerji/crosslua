#include "QemuVfs.h"

#ifdef QEMU_SIM
#include <Arduino.h>
#include <Logging.h>

#include <cstring>

namespace qemuvfs {

namespace {
constexpr unsigned long RX_TIMEOUT_MS = 500;
constexpr unsigned long HELLO_TIMEOUT_MS = 120000;

bool readLine(String& out) {
  out = "";
  unsigned long start = millis();
  while (millis() - start < RX_TIMEOUT_MS) {
    while (Serial1.available() > 0) {
      const char c = static_cast<char>(Serial1.read());
      if (c == '\n') return true;
      out += c;
    }
    delay(2);
  }
  return false;
}

// Read exactly n payload bytes (called after the OK line). Returns false on timeout.
bool readPayload(void* out, size_t n) {
  auto* dst = static_cast<uint8_t*>(out);
  size_t have = 0;
  unsigned long start = millis();
  while (have < n) {
    while (Serial1.available() > 0) {
      dst[have++] = static_cast<uint8_t>(Serial1.read());
      if (have >= n) return true;
    }
    if (millis() - start > RX_TIMEOUT_MS * 4) return false;
    delay(2);
  }
  return true;
}

// Send "VFS OP args\n" and read the response line. Returns:
//   1 = "VFS OK <rest>", 0 = "VFS OK" (no extra), -1 = "VFS ERR"/timeout.
// On success the response word after OK is copied into `value` (unparsed).
int exchange(const char* op, const char* arg1, const char* arg2, const char* arg3, String& value) {
  String req = "VFS ";
  req += op;
  if (arg1) { req += " "; req += arg1; }
  if (arg2) { req += " "; req += arg2; }
  if (arg3) { req += " "; req += arg3; }
  req += "\n";

  // A misaligned bus (a stale line from a previous timed-out exchange) makes
  // the first reply garbage. Drain it and retry instead of failing the call:
  // exchanges are strictly request/response, so any non-VFS line is orphaned
  // and safe to drop.
  for (int attempt = 0; attempt < 3; ++attempt) {
    Serial1.print(req);
    String line;
    if (!readLine(line)) {
      // Timeout: let the peer catch up and try again.
      delay(10);
      continue;
    }
    if (line.startsWith("VFS ERR")) return -1;
    if (line.startsWith("VFS OK")) {
      String rest = line.substring(6);
      rest.trim();
      value = rest;
      return rest.isEmpty() ? 0 : 1;
    }
    // Garbage (leftover or mirrored line): consume and retry the request.
    LOG_ERR("VFS", "exchange %s got stray line, resyncing (attempt %d)", op, attempt + 1);
  }
  return -1;
}

bool parseSize(const String& s, size_t& out) {
  if (s.length() == 0) return false;
  out = static_cast<size_t>(s.toInt());
  return true;
}

}  // namespace

bool enabled() { return true; }

bool hello() {
  Serial1.flush();
  // Drain anything stale first.
  while (Serial1.available()) Serial1.read();
  const unsigned long start = millis();
  int attempts = 0;
  while (millis() - start < HELLO_TIMEOUT_MS) {
    String value;
    const int r = exchange("HELLO", nullptr, nullptr, nullptr, value);
    LOG_ERR("VFS", "hello attempt %d -> %d (%s) at %lu", ++attempts, r, value.c_str(), millis());
    if (r >= 0) return true;
    delay(250);
  }
  return false;
}

bool exists(const char* path) {
  String value;
  const int r = exchange("EXISTS", path, nullptr, nullptr, value);
  return r >= 0 && value == "1";
}

bool sizeOf(const char* path, size_t& sizeOut) {
  String value;
  if (exchange("SIZE", path, nullptr, nullptr, value) != 1) return false;
  return parseSize(value, sizeOut);
}

bool list(const char* path, std::vector<String>& names) {
  String value;
  const int r = exchange("LIST", path, nullptr, nullptr, value);
  if (r != 1) return false;
  const int count = value.toInt();
  if (count < 0) return false;
  names.clear();
  names.reserve(static_cast<size_t>(count));
  for (int i = 0; i < count; ++i) {
    String line;
    if (!readLine(line)) return false;
    names.emplace_back(line);
  }
  return true;
}

bool read(const char* path, size_t offset, void* out, size_t maxLen, size_t& gotLen) {
  char off[24];
  char max[24];
  snprintf(off, sizeof(off), "%u", static_cast<unsigned>(offset));
  snprintf(max, sizeof(max), "%u", static_cast<unsigned>(maxLen));
  String value;
  const int r = exchange("READ", path, off, max, value);
  if (r != 1) return false;
  size_t len = 0;
  if (!parseSize(value, len)) return false;
  if (len > maxLen) return false;
  if (len > 0 && !readPayload(out, len)) return false;
  gotLen = len;
  return true;
}

bool write(const char* path, const void* data, size_t len) {
  char lenStr[24];
  snprintf(lenStr, sizeof(lenStr), "%u", static_cast<unsigned>(len));
  String req = "VFS WRITE ";
  req += path;
  req += " ";
  req += lenStr;
  req += "\n";
  Serial1.print(req);
  if (len > 0) Serial1.write(static_cast<const uint8_t*>(data), len);

  String value;
  return readLine(value);  // consume the response line (no new request!)
}

bool mkdir(const char* path) {
  String value;
  return exchange("MKDIR", path, nullptr, nullptr, value) >= 0;
}

int openRead(const char* path, bool* isDirOut) {
  String value;
  const int r = exchange("OPEN", path, nullptr, nullptr, value);
  if (r != 1) return -1;
  // Response: "<id> <isdir:0|1>"
  const int space = value.indexOf(' ');
  if (isDirOut) *isDirOut = space > 0 ? value.substring(space + 1) == "1" : false;
  const String idStr = space > 0 ? value.substring(0, space) : value;
  return idStr.toInt();
}

int fileRead(int id, void* out, size_t n) {
  char idStr[24], nStr[24];
  snprintf(idStr, sizeof(idStr), "%d", id);
  snprintf(nStr, sizeof(nStr), "%u", static_cast<unsigned>(n));
  String value;
  const int r = exchange("FREAD", idStr, nStr, nullptr, value);
  if (r != 1) return -1;
  size_t len = static_cast<size_t>(value.toInt());
  if (len > n) return -1;
  if (len > 0 && !readPayload(out, len)) return -1;
  return static_cast<int>(len);
}

bool fileSeek(int id, size_t pos) {
  char idStr[24], posStr[24];
  snprintf(idStr, sizeof(idStr), "%d", id);
  snprintf(posStr, sizeof(posStr), "%u", static_cast<unsigned>(pos));
  String value;
  return exchange("FSEEK", idStr, posStr, nullptr, value) >= 0;
}

bool fileTell(int id, size_t& pos) {
  char idStr[24];
  snprintf(idStr, sizeof(idStr), "%d", id);
  String value;
  if (exchange("FTELL", idStr, nullptr, nullptr, value) != 1) return false;
  return parseSize(value, pos);
}

bool fileSize(int id, size_t& sizeOut) {
  char idStr[24];
  snprintf(idStr, sizeof(idStr), "%d", id);
  String value;
  if (exchange("FSIZE", idStr, nullptr, nullptr, value) != 1) return false;
  return parseSize(value, sizeOut);
}

bool fileNext(int id, String& name) {
  char idStr[24];
  snprintf(idStr, sizeof(idStr), "%d", id);
  String value;
  const int r = exchange("FNEXT", idStr, nullptr, nullptr, value);
  if (r != 1) return false;
  if (value == "END") {
    name = "";
    return false;
  }
  name = value;
  return true;
}

void fileClose(int id) {
  char idStr[24];
  snprintf(idStr, sizeof(idStr), "%d", id);
  String value;
  exchange("FCLOSE", idStr, nullptr, nullptr, value);
}

}  // namespace qemuvfs
#endif  // QEMU_SIM