#!/usr/bin/env python3
"""x4ctl — drive a CrossLua dev build over USB serial (flash, buttons, screenshots, logs).

Needs a dev firmware (env:default: CROSSLUA_DEV) on the device. Run with:
  uv run --with pyserial --with pillow tools/x4ctl.py <command> ...

Commands
  ports                       list serial ports
  ping                        round-trip check; prints the current screen/activity name
  btn <name[:holdMs]>...      press PHYSICAL buttons: back confirm left right up down (0.4 s apart; --gap to change).
                              e.g. `btn right right confirm`, `btn back:1300` (1.3 s hold = long press)
  shot [out.png] [--landscape]  grab the screen (default shot.png, portrait like CrossPoint's default orientation)
  log [seconds] [--grep RE]   print device log lines for N seconds (default 5)
  expect <regex> [seconds]    wait until a log line matches; exit 1 on timeout
  flash <firmware.bin>        write app0 (0x10000) and erase otadata so the bootloader picks app0. Leaves app1 (the
                              previous firmware), bootloader, partition table and NVS settings untouched.
  restore-stock <backup.bin>  put back the otadata from a full-flash backup -> boots the original firmware in app1

Global: --port /dev/ttyACM0 (default: auto-detect Espressif 303a:*), --baud 115200
"""
import argparse
import glob
import io
import os
import re
import subprocess
import sys
import time

try:
    import serial
    from serial.tools import list_ports
except ImportError:  # pragma: no cover
    sys.exit("pyserial missing: uv run --with pyserial --with pillow tools/x4ctl.py ...")

W, H = 800, 480
BUTTONS = ("back", "confirm", "left", "right", "up", "down")


def find_port():
    for p in list_ports.comports():
        if p.vid == 0x303A:  # Espressif
            return p.device
    cands = sorted(glob.glob("/dev/ttyACM*") + glob.glob("/dev/ttyUSB*"))
    return cands[0] if cands else None


class Device:
    def __init__(self, port, baud=115200, timeout=0.2):
        # Do NOT touch DTR/RTS. The kernel raises both together on open (= "run"); clearing DTR while RTS is still
        # high is the esptool reset pattern and reboots the C3's USB-Serial/JTAG.
        self.ser = serial.Serial()
        self.ser.port, self.ser.baudrate, self.ser.timeout = port, baud, timeout
        self.ser.open()

    def send(self, cmd):
        self.ser.write(f"CMD:{cmd}\n".encode())
        self.ser.flush()

    def _record(self, line):
        # Every line any command sees is appended here, so `grep LUA /root/x4/serial.log` works after the fact.
        path = os.environ.get("X4_LOG", "/root/x4/serial.log")
        if path:
            try:
                with open(path, "a", errors="replace") as f:
                    f.write(line + "\n")
            except OSError:
                pass

    def lines(self, seconds):
        """Yield decoded log lines for `seconds`."""
        end = time.time() + seconds
        while time.time() < end:
            raw = self.ser.readline()
            if raw:
                line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
                if not line.startswith("SCREENSHOT_"):
                    self._record(line)
                yield line

    def wait_for(self, regex, seconds):
        rx = re.compile(regex)
        for line in self.lines(seconds):
            if rx.search(line):
                return line
        return None

    def ping(self, seconds=3.0):
        self.send("PING")
        line = self.wait_for(r"^PONG:\d+:", seconds)
        if not line:
            return None
        _, ms, name = line.split(":", 2)
        return int(ms), name

    def press(self, names, gap=0.4):
        for n in names:
            base, _, hold = n.partition(":")
            if base not in BUTTONS or (hold and not hold.isdigit()):
                raise SystemExit(f"unknown button {n!r}; use one of {BUTTONS}, optionally name:holdMs")
            self.send(f"BTN:{n}")
            line = self.wait_for(r"^BTN_(OK|ERR):", 2.0)
            if not line or line.startswith("BTN_ERR"):
                raise SystemExit(f"button {n!r} not acknowledged (dev firmware flashed?)")
            for _ in self.lines(gap + (int(hold) / 1000.0 if hold else 0.12)):  # keep logging while we wait
                pass

    def screenshot_raw(self, seconds=10.0):
        """Returns the raw 1bpp 800x480 framebuffer (48000 bytes) or None."""
        self.ser.reset_input_buffer()
        self.send("SCREENSHOT")
        end = time.time() + seconds
        size = None
        while time.time() < end and size is None:
            raw = self.ser.readline()
            m = re.match(rb"SCREENSHOT_START:(\d+)", raw.strip())
            if m:
                size = int(m.group(1))
        if size is None:
            return None
        data = b""
        while len(data) < size and time.time() < end:
            data += self.ser.read(size - len(data))
        return data if len(data) == size else None


def raw_to_png(raw, landscape=False):
    from PIL import Image

    img = Image.frombytes("1", (W, H), raw)
    if not landscape:
        img = img.transpose(Image.Transpose.ROTATE_270)  # panel is native-landscape; CrossPoint default is portrait
    buf = io.BytesIO()
    img.convert("L").save(buf, "PNG")
    return buf.getvalue()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--gap", type=float, default=0.4)
    ap.add_argument("--landscape", action="store_true")
    ap.add_argument("--grep")
    ap.add_argument("cmd")
    ap.add_argument("args", nargs="*")
    a = ap.parse_args(argv)

    if a.cmd == "ports":
        for p in list_ports.comports():
            print(f"{p.device}\t{p.vid and hex(p.vid)}:{p.pid and hex(p.pid)}\t{p.description}")
        return 0

    if a.cmd == "flash":
        if not a.args:
            raise SystemExit("flash <firmware.bin>")
        port = a.port or find_port()
        if not port:
            raise SystemExit("no serial port found")
        base = ["esptool", "--chip", "esp32c3", "--port", port, "--baud", "460800"]
        # otadata decides which app slot boots; a device whose last OTA landed in app1 would ignore a plain
        # write to app0. Erased otadata = bootloader falls back to app0.
        for cmd in (base + ["erase-region", "0xe000", "0x2000"], base + ["write-flash", "0x10000", a.args[0]]):
            print("+", " ".join(cmd))
            rc = subprocess.call(cmd)
            if rc:
                return rc
        return 0
    if a.cmd == "restore-stock":
        if not a.args:
            raise SystemExit("restore-stock <full-flash-backup.bin>")
        port = a.port or find_port()
        if not port:
            raise SystemExit("no serial port found")
        with open(a.args[0], "rb") as f:
            f.seek(0xE000)
            ota = f.read(0x2000)
        import tempfile
        with tempfile.NamedTemporaryFile(suffix=".bin") as t:
            t.write(ota)
            t.flush()
            cmd = ["esptool", "--chip", "esp32c3", "--port", port, "--baud", "460800", "write-flash", "0xe000", t.name]
            print("+", " ".join(cmd))
            return subprocess.call(cmd)

    port = a.port or find_port()
    if not port:
        raise SystemExit("no serial port found (is the X4 attached/passed through?)")
    dev = Device(port, a.baud)

    if a.cmd == "ping":
        r = dev.ping()
        print(f"PONG uptime={r[0]}ms screen={r[1]}" if r else "no reply")
        return 0 if r else 1
    if a.cmd == "btn":
        dev.press(a.args, a.gap)
        return 0
    if a.cmd == "shot":
        out = a.args[0] if a.args else "shot.png"
        raw = dev.screenshot_raw()
        if not raw:
            print("screenshot failed")
            return 1
        with open(out, "wb") as f:
            f.write(raw_to_png(raw, a.landscape))
        print(out)
        return 0
    if a.cmd == "log":
        secs = float(a.args[0]) if a.args else 5.0
        rx = re.compile(a.grep) if a.grep else None
        for line in dev.lines(secs):
            if not rx or rx.search(line):
                print(line)
        return 0
    if a.cmd == "expect":
        line = dev.wait_for(a.args[0], float(a.args[1]) if len(a.args) > 1 else 10.0)
        print(line or "TIMEOUT")
        return 0 if line else 1
    raise SystemExit(f"unknown command {a.cmd!r}")


if __name__ == "__main__":
    sys.exit(main())
