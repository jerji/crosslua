#include "HalStorage.h"

#include <FS.h>  // need to be included before SdFat.h for compatibility with FS.h's File class
#include <Logging.h>
#include <SDCardManager.h>
#include <esp_heap_caps.h>
#if FREEINK_CAP_USB_MSC
#include <UsbMassStorage.h>
#endif

#include <cassert>

#ifdef QEMU_SIM
#include "QemuVfs.h"
#include <algorithm>
#endif

#define SDCard SDCardManager::getInstance()

namespace {
#if FREEINK_CAP_USB_MSC
freeink::UsbMassStorage usbMassStorage;
#endif
}  // namespace

HalStorage HalStorage::instance;

HalStorage::HalStorage() {
  // Recursive so the same task can re-enter StorageLock without self-deadlock.
  // openFileForRead/Write take the lock and then assign to a HalFile&
  // out-param; if that out-param already held an Impl, its destructor takes
  // the lock again to close the prior FsFile under serialization (see
  // HalFile::Impl::~Impl below). Priority inheritance still applies to
  // recursive mutexes.
  storageMutex = xSemaphoreCreateRecursiveMutex();
  assert(storageMutex != nullptr);
}

// begin() and ready() are only called from setup, no need to acquire mutex for them

bool HalStorage::begin() {
#ifdef QEMU_SIM
  // No SD controller exists under QEMU: the virtual FS lives on the host (see
  // tools/qemu_vfs.py + lib/hal/QemuVfs.cpp). The handshake blocks until the
  // host helper answers on UART1 (it may attach a moment after boot).
  return qemuvfs::hello();
#endif
  return SDCard.begin();
}

bool HalStorage::ready() const {
#ifdef QEMU_SIM
  return true;  // begin() handshake implies the virtual FS is up
#endif
  return SDCard.ready();
}

// For the rest of the methods, we acquire the mutex to ensure thread safety

class HalStorage::StorageLock {
 public:
  StorageLock() { xSemaphoreTakeRecursive(HalStorage::getInstance().storageMutex, portMAX_DELAY); }
  ~StorageLock() { xSemaphoreGiveRecursive(HalStorage::getInstance().storageMutex); }
};

void HalStorage::prepareForDeepSleep() {
  StorageLock lock;
  SDCard.shutdown();
}

bool HalStorage::beginUsbDrive() {
#if FREEINK_CAP_USB_MSC
  StorageLock lock;
  auto* const blockDevice = SDCard.detachFilesystemForRawAccess();
  if (!blockDevice) {
    LOG_ERR("USB", "USB Drive requires a mounted SD filesystem");
    return false;
  }

  if (!usbMassStorage.begin(blockDevice)) {
    LOG_ERR("USB", "USB Drive MSC initialization failed");
    if (!SDCard.begin()) {
      LOG_ERR("USB", "Unable to remount SD card after USB Drive startup failure");
    }
    return false;
  }
  return true;
#else
  return false;
#endif
}

bool HalStorage::disconnectUsbDriveHost() {
#if FREEINK_CAP_USB_MSC
  StorageLock lock;
  return usbMassStorage.disconnectHost();
#else
  return false;
#endif
}

bool HalStorage::usbDriveHostSuspended() const {
#if FREEINK_CAP_USB_MSC
  StorageLock lock;
  return usbMassStorage.hostSuspended();
#else
  return false;
#endif
}

void HalStorage::endUsbDrive() {
#if FREEINK_CAP_USB_MSC
  StorageLock lock;
  usbMassStorage.end();
#endif
}

UsbDriveState HalStorage::usbDriveState() const {
#if FREEINK_CAP_USB_MSC
  StorageLock lock;
  switch (usbMassStorage.state()) {
    case freeink::UsbMassStorageState::WaitingForHost:
      return UsbDriveState::WaitingForHost;
    case freeink::UsbMassStorageState::Connected:
    case freeink::UsbMassStorageState::Accessed:
      return UsbDriveState::Connected;
    case freeink::UsbMassStorageState::Ejected:
      return UsbDriveState::Ejected;
    case freeink::UsbMassStorageState::Disconnected:
      return UsbDriveState::Disconnected;
    case freeink::UsbMassStorageState::IoError:
      return UsbDriveState::IoError;
    case freeink::UsbMassStorageState::Idle:
      break;
  }
#endif
  return UsbDriveState::Unsupported;
}

#define HAL_STORAGE_WRAPPED_CALL(method, ...) \
  HalStorage::StorageLock lock;               \
  return SDCard.method(__VA_ARGS__);

std::vector<String> HalStorage::listFiles(const char* path, int maxFiles) {
#ifdef QEMU_SIM
  std::vector<String> names;
  if (qemuvfs::list(path, names)) {
    if (maxFiles > 0 && static_cast<int>(names.size()) > maxFiles) names.resize(static_cast<size_t>(maxFiles));
    return names;
  }
  return {};
#endif
  HAL_STORAGE_WRAPPED_CALL(listFiles, path, maxFiles);
}

String HalStorage::readFile(const char* path) {
#ifdef QEMU_SIM
  size_t size = 0;
  if (qemuvfs::sizeOf(path, size) && size <= 256 * 1024) {
    String out;
    out.reserve(size);
    char buf[512];
    size_t off = 0, got = 0;
    while (off < size) {
      const size_t want = std::min(size - off, sizeof(buf));
      if (!qemuvfs::read(path, off, buf, want, got) || got == 0) return String();
      out.concat(buf, static_cast<unsigned>(got));
      off += got;
    }
    return out;
  }
  return String();
#endif
  HAL_STORAGE_WRAPPED_CALL(readFile, path);
}

bool HalStorage::readFileToStream(const char* path, Print& out, size_t chunkSize) {
#ifdef QEMU_SIM
  if (chunkSize == 0) chunkSize = 256;
  size_t size = 0;
  if (!qemuvfs::sizeOf(path, size)) return false;
  std::vector<char> buf(chunkSize);
  size_t off = 0, got = 0;
  while (off < size) {
    const size_t want = std::min(size - off, chunkSize);
    if (!qemuvfs::read(path, off, buf.data(), want, got) || got == 0) return false;
    out.write(buf.data(), got);
    off += got;
  }
  return true;
#endif
  HAL_STORAGE_WRAPPED_CALL(readFileToStream, path, out, chunkSize);
}

size_t HalStorage::readFileToBuffer(const char* path, char* buffer, size_t bufferSize, size_t maxBytes) {
#ifdef QEMU_SIM
  if (bufferSize == 0) return 0;
  const size_t want = std::min(maxBytes > 0 ? maxBytes : bufferSize - 1, bufferSize - 1);
  size_t got = 0;
  if (!qemuvfs::read(path, 0, buffer, want, got)) return 0;
  buffer[got] = '\0';
  return got;
#endif
  HAL_STORAGE_WRAPPED_CALL(readFileToBuffer, path, buffer, bufferSize, maxBytes);
}

// Composed of already-locked HalStorage/HalFile operations; needs no
// StorageLock of its own.
bool HalStorage::readFileToString(const char* moduleName, const std::string& path, size_t cap, std::string& out) {
  out.clear();
  HalFile file;
  if (!openFileForRead(moduleName, path, file)) return false;
  if (file.isDirectory()) return false;
  const size_t size = file.fileSize();
  if (size == 0 || size > cap) return false;
  // string growth is a bare allocation under -fno-exceptions; probe first so
  // a large file on a fragmented heap fails soft instead of abort()ing.
  if (heap_caps_get_largest_free_block(MALLOC_CAP_8BIT) < size + 512) {
    LOG_ERR(moduleName, "readFileToString OOM: %u bytes for %s", static_cast<unsigned>(size), path.c_str());
    return false;
  }
  out.resize(size);
  return file.read(out.data(), size) == static_cast<int>(size);
}

bool HalStorage::writeFile(const char* path, const String& content) {
#ifdef QEMU_SIM
  return qemuvfs::write(path, content.c_str(), content.length());
#endif
  HAL_STORAGE_WRAPPED_CALL(writeFile, path, content);
}

bool HalStorage::ensureDirectoryExists(const char* path) {
#ifdef QEMU_SIM
  return qemuvfs::mkdir(path);
#endif
  HAL_STORAGE_WRAPPED_CALL(ensureDirectoryExists, path);
}

class HalFile::Impl {
 public:
  Impl(FsFile&& fsFile) : file(std::move(fsFile)) {}
#ifdef QEMU_SIM
  Impl() = default;
  int hostId = -1;
  size_t vfsSize = 0;
  size_t vfsPos = 0;
  size_t vfsEntryHalf = 0;  // unused dir-iteration slot
  bool vfsIsDir = false;    // the OPEN response's is-dir flag
  std::string vfsPath;      // the path this handle was opened for (dir iteration)
#endif
  // SdFat is not thread-safe; FsFile::close() touches SD/SPI and must run
  // under StorageLock or it races SdSpiCard::m_spiActive across tasks and
  // trips FreeRTOS's xTaskPriorityDisinherit assert. The FsFile member
  // destructor (DESTRUCTOR_CLOSES_FILE=1) will close() again after the lock
  // releases, but close() on an already-closed FsFile is a no-op. See SdFat
  // issue #518 and the HAL note in CLAUDE.md.
  ~Impl() {
#ifdef QEMU_SIM
    if (hostId >= 0) qemuvfs::fileClose(hostId);
#endif
    HalStorage::StorageLock lock;
    file.close();
  }
  FsFile file;
};

HalFile::HalFile() = default;
HalFile::HalFile(std::unique_ptr<Impl> impl) : impl(std::move(impl)) {}
HalFile::~HalFile() = default;
HalFile::HalFile(HalFile&&) = default;
HalFile& HalFile::operator=(HalFile&&) = default;

HalFile HalStorage::open(const char* path, const oflag_t oflag) {
  StorageLock lock;  // ensure thread safety for the duration of this function
#ifdef QEMU_SIM
  if (qemuvfs::enabled()) {
    auto impl = std::make_unique<HalFile::Impl>();
    impl->hostId = qemuvfs::openRead(path, &impl->vfsIsDir);
    if (impl->hostId >= 0) {
      qemuvfs::fileSize(impl->hostId, impl->vfsSize);
      impl->vfsPath = path;
      return HalFile(std::move(impl));
    }
    return HalFile();
  }
#endif
  return HalFile(std::make_unique<HalFile::Impl>(SDCard.open(path, oflag)));
}

bool HalStorage::exists(const char* path) {
#ifdef QEMU_SIM
  return qemuvfs::exists(path);
#endif
  HAL_STORAGE_WRAPPED_CALL(exists, path);
}

bool HalStorage::mkdir(const char* path, const bool pFlag) {
#ifdef QEMU_SIM
  return qemuvfs::mkdir(path);
#endif
  HAL_STORAGE_WRAPPED_CALL(mkdir, path, pFlag);
}

bool HalStorage::remove(const char* path) {
#ifdef QEMU_SIM
  (void)path;
  return false;  // destructive ops unsupported by the sim VFS for now
#endif
  HAL_STORAGE_WRAPPED_CALL(remove, path);
}
bool HalStorage::rename(const char* oldPath, const char* newPath) {
#ifdef QEMU_SIM
  return false;
#endif
  HAL_STORAGE_WRAPPED_CALL(rename, oldPath, newPath);
}

bool HalStorage::replaceFile(const char* tmpPath, const char* path) {
#ifdef QEMU_SIM
  return false;
#endif
  HAL_STORAGE_WRAPPED_CALL(replaceFile, tmpPath, path);
}

bool HalStorage::rmdir(const char* path) {
#ifdef QEMU_SIM
  return false;
#endif
  HAL_STORAGE_WRAPPED_CALL(rmdir, path);
}

bool HalStorage::openFileForRead(const char* moduleName, const char* path, HalFile& file) {
  StorageLock lock;  // ensure thread safety for the duration of this function
#ifdef QEMU_SIM
  if (qemuvfs::enabled()) {
    auto impl = std::make_unique<HalFile::Impl>();
    impl->hostId = qemuvfs::openRead(path, &impl->vfsIsDir);
    if (impl->hostId >= 0) {
      qemuvfs::fileSize(impl->hostId, impl->vfsSize);
      impl->vfsPath = path;
      file = HalFile(std::move(impl));
      return true;
    }
    return false;
  }
#endif
  FsFile fsFile;
  bool ok = SDCard.openFileForRead(moduleName, path, fsFile);
  file = HalFile(std::make_unique<HalFile::Impl>(std::move(fsFile)));
  return ok;
}

bool HalStorage::openFileForRead(const char* moduleName, const std::string& path, HalFile& file) {
  return openFileForRead(moduleName, path.c_str(), file);
}

bool HalStorage::openFileForRead(const char* moduleName, const String& path, HalFile& file) {
  return openFileForRead(moduleName, path.c_str(), file);
}

bool HalStorage::openFileForWrite(const char* moduleName, const char* path, HalFile& file) {
  StorageLock lock;  // ensure thread safety for the duration of this function
  FsFile fsFile;
  bool ok = SDCard.openFileForWrite(moduleName, path, fsFile);
  file = HalFile(std::make_unique<HalFile::Impl>(std::move(fsFile)));
  return ok;
}

bool HalStorage::openFileForWrite(const char* moduleName, const std::string& path, HalFile& file) {
  return openFileForWrite(moduleName, path.c_str(), file);
}

bool HalStorage::openFileForWrite(const char* moduleName, const String& path, HalFile& file) {
  return openFileForWrite(moduleName, path.c_str(), file);
}

bool HalStorage::removeDir(const char* path) {
#ifdef QEMU_SIM
  return false;
#endif
  HAL_STORAGE_WRAPPED_CALL(removeDir, path);
}

// HalFile implementation
// Allow doing file operations while ensuring thread safety via HalStorage's mutex.
// Please keep the list below in sync with the HalFile.h header

#define HAL_FILE_WRAPPED_CALL(method, ...) \
  HalStorage::StorageLock lock;            \
  assert(impl != nullptr);                 \
  return impl->file.method(__VA_ARGS__);

#define HAL_FILE_FORWARD_CALL(method, ...) \
  assert(impl != nullptr);                 \
  return impl->file.method(__VA_ARGS__);

void HalFile::flush() { HAL_FILE_WRAPPED_CALL(flush, ); }
size_t HalFile::getName(char* name, size_t len) {
#ifdef QEMU_SIM
  // Directory entries are opened by path (see openNextFile), so the leaf of
  // vfsPath is the entry name. Without this the scan's getName()==0 check
  // skips every discovered folder.
  if (qemuvfs::enabled() && impl && !impl->vfsPath.empty()) {
    const std::string& p = impl->vfsPath;
    const size_t slash = p.find_last_of('/');
    const std::string leaf = slash == std::string::npos ? p : p.substr(slash + 1);
    const size_t n = std::min(len - 1, leaf.size());
    memcpy(name, leaf.data(), n);
    name[n] = '\0';
    return n;
  }
#endif
  HAL_FILE_WRAPPED_CALL(getName, name, len);
}
size_t HalFile::size() {
#ifdef QEMU_SIM
  if (qemuvfs::enabled() && impl) return impl->vfsSize;
#endif
  HAL_FILE_FORWARD_CALL(size, );
}
size_t HalFile::fileSize() {
#ifdef QEMU_SIM
  if (qemuvfs::enabled() && impl) return impl->vfsSize;
#endif
  HAL_FILE_FORWARD_CALL(fileSize, );
}
uint64_t HalFile::fileSize64() {
#ifdef QEMU_SIM
  if (qemuvfs::enabled() && impl) return static_cast<uint64_t>(impl->vfsSize);
#endif
  HAL_FILE_FORWARD_CALL(fileSize, );
}
uint32_t HalFile::modificationTime() {
#ifdef QEMU_SIM
  if (qemuvfs::enabled()) return 0;
#endif
  HalStorage::StorageLock lock;
  uint16_t date = 0;
  uint16_t time = 0;
  if (!impl || !impl->file.getModifyDateTime(&date, &time) || date == 0) return 0;
  return (static_cast<uint32_t>(date) << 16) | time;
}
bool HalFile::seek(size_t pos) {
#ifdef QEMU_SIM
  if (qemuvfs::enabled() && impl && qemuvfs::fileSeek(impl->hostId, pos)) {
    impl->vfsPos = pos;
    return true;
  }
#endif
  HAL_FILE_WRAPPED_CALL(seekSet, pos);
}
bool HalFile::seek64(uint64_t pos) { HAL_FILE_WRAPPED_CALL(seekSet, pos); }
bool HalFile::seekCur(int64_t offset) { HAL_FILE_WRAPPED_CALL(seekCur, offset); }
bool HalFile::seekSet(size_t offset) { HAL_FILE_WRAPPED_CALL(seekSet, offset); }
bool HalFile::truncate(const uint64_t length) { HAL_FILE_WRAPPED_CALL(truncate, length); }
int HalFile::available() const {
#ifdef QEMU_SIM
  if (qemuvfs::enabled() && impl) return static_cast<int>(impl->vfsSize - impl->vfsPos);
#endif
  HAL_FILE_WRAPPED_CALL(available, );
}
size_t HalFile::position() const {
#ifdef QEMU_SIM
  if (qemuvfs::enabled() && impl) return impl->vfsPos;
#endif
  HAL_FILE_WRAPPED_CALL(position, );
}
int HalFile::read(void* buf, size_t count) {
#ifdef QEMU_SIM
  if (qemuvfs::enabled() && impl) {
    const int n = qemuvfs::fileRead(impl->hostId, buf, count);
    if (n >= 0) impl->vfsPos += static_cast<size_t>(n);
    return n;
  }
#endif
  HAL_FILE_WRAPPED_CALL(read, buf, count);
}
int HalFile::read() {
#ifdef QEMU_SIM
  if (qemuvfs::enabled() && impl) {
    uint8_t b;
    const int n = qemuvfs::fileRead(impl->hostId, &b, 1);
    if (n > 0) impl->vfsPos += 1;
    return n > 0 ? b : -1;
  }
#endif
  HAL_FILE_WRAPPED_CALL(read, );
}
size_t HalFile::write(const uint8_t* buf, size_t count) { HAL_FILE_WRAPPED_CALL(write, buf, count); }
size_t HalFile::write(const void* buf, size_t count) { HAL_FILE_WRAPPED_CALL(write, buf, count); }
size_t HalFile::write(uint8_t b) { HAL_FILE_WRAPPED_CALL(write, b); }
bool HalFile::rename(const char* newPath) { HAL_FILE_WRAPPED_CALL(rename, newPath); }
bool HalFile::isDirectory() const {
#ifdef QEMU_SIM
  // The host VFS reports the is-dir flag on OPEN; the root/entry handles for
  // directory scans need it, and file handles must read as files.
  if (impl) return impl->vfsIsDir;
  return false;
#endif
  HAL_FILE_FORWARD_CALL(isDirectory, );
}  // already thread-safe, no need to wrap
void HalFile::rewindDirectory() { HAL_FILE_WRAPPED_CALL(rewindDirectory, ); }
bool HalFile::close() {
#ifdef QEMU_SIM
  if (qemuvfs::enabled() && impl) {
    if (impl->hostId >= 0) qemuvfs::fileClose(impl->hostId);
    impl->hostId = -1;
    return true;
  }
#endif
  HAL_FILE_WRAPPED_CALL(close, );
}
HalFile HalFile::openNextFile() {
  HalStorage::StorageLock lock;
#ifdef QEMU_SIM
  if (qemuvfs::enabled()) {
    // Directory iteration over the host VFS: FNEXT on this handle, then open
    // the child by path so its is-dir flag and size are populated.
    if (!impl || impl->hostId < 0 || !impl->vfsIsDir) return HalFile();
    String name;
    if (!qemuvfs::fileNext(impl->hostId, name) || name.isEmpty()) return HalFile();
    const std::string child = impl->vfsPath + "/" + name.c_str();
    auto childImpl = std::make_unique<HalFile::Impl>();
    childImpl->hostId = qemuvfs::openRead(child.c_str(), &childImpl->vfsIsDir);
    if (childImpl->hostId < 0) return HalFile();
    qemuvfs::fileSize(childImpl->hostId, childImpl->vfsSize);
    childImpl->vfsPath = child;
    return HalFile(std::move(childImpl));
  }
#endif
  assert(impl != nullptr);
  return HalFile(std::make_unique<Impl>(impl->file.openNextFile()));
}
bool HalFile::isOpen() const {
#ifdef QEMU_SIM
  if (qemuvfs::enabled()) return impl != nullptr && impl->hostId >= 0;
#endif
  return impl != nullptr && impl->file.isOpen();  // already thread-safe, no need to wrap
}
HalFile::operator bool() const { return isOpen(); }
