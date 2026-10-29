#!/usr/bin/env python3
"""Merge the PlatformIO build outputs into a 16 MB flash image for QEMU.

ESP32-S3 second-stage bootloader sits at 0x0 (ROM loads it from there), partition
table at 0x8000, app0 at 0x10000. Pad to the X4's 16 MB so QEMU's flash model
matches the real part.

    python3 scripts/make_qemu_flash.py <build_dir> <out.bin> [mib]

    python3 scripts/make_qemu_flash.py .pio/build/default /tmp/x4-flash.bin
"""
import os
import sys

OFFSETS = [
    (0x0, "bootloader.bin"),
    (0x8000, "partitions.bin"),
    (0xe000, "boot_app0.bin"),
    (0x10000, "firmware.bin"),
]


def main():
    if len(sys.argv) not in (3, 4):
        print(__doc__)
        return 2
    build_dir, out = sys.argv[1], sys.argv[2]
    size_mib = int(sys.argv[3]) if len(sys.argv) == 4 else 16
    img = bytearray(size_mib * 1024 * 1024)
    for off, name in OFFSETS:
        path = os.path.join(build_dir, name)
        if not os.path.isfile(path):
            if name == "boot_app0.bin":
                print(f"{name}: absent, skipping (OTA-only, not needed for QEMU boot)")
                continue
            print(f"missing {path}")
            return 1
        data = open(path, "rb").read()
        img[off:off + len(data)] = data
        print(f"{name}: {len(data)} bytes @ 0x{off:x}")
    with open(out, "wb") as f:
        f.write(img)
    print(f"wrote {out} ({size_mib} MiB, {len(img)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())