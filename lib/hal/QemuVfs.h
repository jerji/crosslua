#pragma once

// QEMU_SIM virtual SD client: routes HalStorage calls over Serial1 (UART1) to
// tools/qemu_vfs.py on the host, which serves the repo's sd_card_contents tree
// (+ a writable overlay). The esp32c3 QEMU machine models no SD controller, so
// the firmware must NOT touch SDCard when emulated.
//
// Protocol (see tools/qemu_vfs.py): line requests "VFS <OP> ..." and binary
// payload after the OK line where noted.

#include <cstddef>
#include <cstdint>
#include <vector>

class String;

namespace qemuvfs {

bool enabled();  // true when this build is QEMU_SIM

// Blocking handshake used by HalStorage::begin(); true when the host helper
// answered HELLO (waits up to ~20 s so the helper can attach to the pty).
bool hello();

bool exists(const char* path);
bool sizeOf(const char* path, size_t& sizeOut);
bool list(const char* path, std::vector<String>& names);
bool read(const char* path, size_t offset, void* out, size_t maxLen, size_t& gotLen);
bool write(const char* path, const void* data, size_t len);
bool mkdir(const char* path);

// HalFile handles (host-side, seekable).
int openRead(const char* path, bool* isDirOut = nullptr);  // -1 on failure
int fileRead(int id, void* out, size_t n);  // bytes read, -1 on error
bool fileSeek(int id, size_t pos);
bool fileTell(int id, size_t& pos);
bool fileSize(int id, size_t& sizeOut);
bool fileNext(int id, String& name);  // false + empty name = end of dir
void fileClose(int id);

}  // namespace qemuvfs