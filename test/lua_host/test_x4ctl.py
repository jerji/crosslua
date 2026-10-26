#!/usr/bin/env python3
"""Protocol test for tools/x4ctl.py against a fake X4 on a pty (no hardware).
Run: uv run --with pyserial --with pillow test/lua_host/test_x4ctl.py"""
import os, pty, sys, threading, time, io
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "tools"))
import x4ctl
from PIL import Image

W, H = 800, 480
# Fake framebuffer: white (0xFF = bit 1 = white), with a black 100x60 rectangle at native (x=10..110, y=20..80)
fb = bytearray(b"\xff" * (W * H // 8))
for y in range(20, 80):
    for x in range(10, 110):
        fb[y * (W // 8) + x // 8] &= ~(0x80 >> (x % 8))

master, slave = pty.openpty()
slave_name = os.ttyname(slave)
pressed = []
stop = False

def fake_device():
    buf = b""
    os.write(master, b"[123] [INF] [MEM] boot noise\r\n")
    while not stop:
        try:
            chunk = os.read(master, 256)
        except OSError:
            return
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            line = line.decode().strip()
            if line == "CMD:PING":
                os.write(master, b"PONG:4242:LuaApp\n")
            elif line.startswith("CMD:BTN:"):
                n = line[8:]
                ok = n in x4ctl.BUTTONS
                if ok: pressed.append(n)
                os.write(master, f"BTN_{'OK' if ok else 'ERR'}:{n}\n".encode())
            elif line == "CMD:SCREEN":
                os.write(master, (
                    "SCREEN_START:7:Home:480x800\n"
                    "T 24 120 100 Browse Files\nT 24 180 100 Library\nT 24 240 100 Plugins\nT 24 240 100 Plugins\n"
                    "T 300 180 7 sub-title\n"
                    "R 10 170 460 56 5\nR 0 700 480 60 16\nR 10 112 460 56 1\nSCREEN_END\n").encode())
            elif line == "CMD:SCREENSHOT":
                os.write(master, f"SCREENSHOT_START:{len(fb)}\n".encode())
                for i in range(0, len(fb), 1024):  # chunked like a real USB-CDC stream
                    os.write(master, bytes(fb[i:i+1024])); time.sleep(0.001)
                os.write(master, b"SCREENSHOT_END\n")

t = threading.Thread(target=fake_device, daemon=True); t.start()
fails = 0
def check(name, cond):
    global fails
    print(("ok   " if cond else "FAIL ") + name)
    fails += 0 if cond else 1

dev = x4ctl.Device(slave_name)
r = dev.ping()
check("ping returns uptime + activity name", r == (4242, "LuaApp"))
dev.press(["confirm", "left", "down"], gap=0.01)
check("btn sequence delivered in order", pressed == ["confirm", "left", "down"])
try:
    dev.press(["bogus"], gap=0.01); check("unknown button rejected client-side", False)
except SystemExit:
    check("unknown button rejected client-side", True)
raw = dev.screenshot_raw(5)
check("screenshot returns 48000 bytes", raw is not None and len(raw) == 48000)
portrait = Image.open(io.BytesIO(x4ctl.raw_to_png(raw)))
landscape = Image.open(io.BytesIO(x4ctl.raw_to_png(raw, landscape=True)))
check("portrait is 480x800, landscape 800x480", portrait.size == (480, 800) and landscape.size == (800, 480))
check("landscape: black rect where drawn, white elsewhere", landscape.getpixel((50, 50)) == 0 and landscape.getpixel((300, 300)) == 255)
# PIL ROTATE_270 = 90 deg clockwise: native (x, y) -> portrait (H-1-y, x); same transform as scripts/debugging_monitor.py
check("portrait rotation: native (50,50) -> (H-1-50, 50), and the rect's corner moves with it",
      portrait.getpixel((H - 1 - 50, 50)) == 0 and portrait.getpixel((H - 1 - 19, 50)) == 255 and portrait.getpixel((300, 300)) == 255)
scr = dev.screen()
check("screen: parsed, activity + size", scr and scr["activity"] == "Home" and (scr["w"], scr["h"]) == (480, 800))
check("screen: repeated identical draw deduped", scr and sum(1 for t in scr["texts"] if t[3] == "Plugins") == 1)
txt = x4ctl.render_screen(scr)
print(txt)
check("screen: gray rect behind 'Library' marks it selected (and only it)",
      "> y=180  Library  |  sub-title" in txt and "> y=120" not in txt and "> y=240" not in txt)
check("screen: black button-bar rect / white rect do not mark selection", "y=700" not in txt)
stop = True
print("ALL PASSED" if not fails else f"{fails} FAILED")
sys.exit(1 if fails else 0)
