#!/usr/bin/env python3
"""QEMU virtual SD: serves the repo's sd_card_contents tree to the emulated firmware over UART1.

The esp32c3 QEMU machine has no SD model, so under QEMU_SIM the firmware routes every
HalStorage call over the dev serial (UART1) to this helper. Lines in, lines + binary out:

    VFS HELLO                      -> VFS OK 1
    VFS EXISTS <path>              -> VFS OK 1|0
    VFS SIZE  <path>               -> VFS OK <n>|VFS ERR
    VFS LIST  <path>               -> VFS OK <count> then <name>\n per entry
    VFS READ  <path> <off> <max>   -> VFS OK <len>\n<bytes>|VFS ERR
    VFS WRITE <path> <len>\n<data> -> VFS OK 1|VFS ERR      (overwrite whole file)
    VFS MKDIR <path>               -> VFS OK 1|VFS ERR
    VFS REMOVE <path>              -> VFS OK 1|VFS ERR
    VFS STAT <path>                -> VFS OK <size> <mtime>|VFS ERR
    VFS OPEN <path>                -> VFS OK <id>|VFS ERR
    VFS FREAD <id> <n>             -> VFS OK <len>\n<bytes>|VFS ERR
    VFS FSEEK <id> <pos>           -> VFS OK 1|VFS ERR
    VFS FTELL <id>                 -> VFS OK <pos>
    VFS FSIZE <id>                 -> VFS OK <n>
    VFS FNEXT <id>                 -> VFS OK <name>|VFS OK END|VFS ERR
    VFS FCLOSE <id>                -> VFS OK 1

Reads resolve: <overlay>/<path> first, then <base>/<path>. Writes go to the overlay so
the repo tree stays pristine. Paths are rooted at "/" (firmware absolute paths).
"""
import os
import sys
import threading
import time

PORT = sys.argv[1] if len(sys.argv) > 1 else "/dev/pts/1"
BASE = sys.argv[2] if len(sys.argv) > 2 else "/root/x4/crosspoint-lua/sd_card_contents"
OVERLAY = sys.argv[3] if len(sys.argv) > 3 else "/tmp/x4-vfs"

try:
    import serial
except ImportError:
    sys.exit("need pyserial: uv run --with pyserial --with pillow tools/qemu_vfs.py ...")

os.makedirs(OVERLAY, exist_ok=True)
_next_id = [1]  # host hal file ids
_handles = {}   # id -> {"path": abs, "pos": int}

BUF = b""


def resolve(path, for_write=False):
    rel = path.lstrip("/")
    base = OVERLAY if for_write else None
    for root in ([OVERLAY, BASE] if base is None else [OVERLAY]):
        p = os.path.join(root, rel)
        # prevent escaping
        if not os.path.realpath(p).startswith(os.path.realpath(root)):
            return None
        try:
            if os.path.exists(p):
                return p
        except OSError:
            pass
    return None


def send_line(s, line):
    s.write(line + b"\n")


def main():
    s = serial.Serial(PORT, 921600, timeout=0.2)
    s.reset_input_buffer()
    print(f"vfs serving {BASE} (+overlay {OVERLAY}) on {PORT}", flush=True)
    line = b""
    while True:
        try:
            d = s.read(4096)
        except serial.SerialException:
            time.sleep(0.2)
            continue
        if not d:
            continue
        line += d
        while b"\n" in line:
            req, line = line.split(b"\n", 1)
            if not req:
                continue
            print("[rx] " + req.decode("utf-8", "replace")[:100], flush=True)
            if not req.startswith(b"VFS "):
                # Firmware log/CMD response on the shared channel: surface it
                # (the pty owner is the only reader, so without this the
                # responses vanish).
                print("[fw] " + req.decode("utf-8", "replace"), flush=True)
                continue
            parts = req.decode("utf-8", "replace").split(" ")
            op = parts[0]
            if len(parts) > 1 and parts[0] == "VFS":
                parts = parts[1:]  # wire format: "VFS <op> <args...>"
                op = parts[0]
            try:
                if op == "HELLO":
                    send_line(s, b"VFS OK 1")
                elif op == "EXISTS" and len(parts) >= 2:
                    send_line(s, b"VFS OK 1" if resolve(parts[1]) else b"VFS OK 0")
                elif op == "SIZE" and len(parts) >= 2:
                    p = resolve(parts[1])
                    if p and os.path.isfile(p):
                        send_line(s, f"VFS OK {os.path.getsize(p)}".encode())
                    else:
                        send_line(s, b"VFS ERR")
                elif op == "STAT" and len(parts) >= 2:
                    p = resolve(parts[1])
                    if p and os.path.isfile(p):
                        mt = int(os.path.getmtime(p) or 0)
                        send_line(s, f"VFS OK {os.path.getsize(p)} {mt}".encode())
                    else:
                        send_line(s, b"VFS ERR")
                elif op == "LIST" and len(parts) >= 2:
                    p = resolve(parts[1])
                    if p and os.path.isdir(p):
                        names = sorted(os.listdir(p))
                        send_line(s, f"VFS OK {len(names)}".encode())
                        for n in names:
                            send_line(s, n.encode("utf-8", "replace"))
                    else:
                        send_line(s, b"VFS OK 0")
                elif op == "READ" and len(parts) >= 4:
                    p = resolve(parts[1])
                    off, maxlen = int(parts[2]), int(parts[3])
                    if p and os.path.isfile(p):
                        with open(p, "rb") as f:
                            f.seek(off)
                            data = f.read(maxlen)
                        send_line(s, f"VFS OK {len(data)}".encode())
                        s.write(data)
                    else:
                        send_line(s, b"VFS ERR")
                elif op == "WRITE" and len(parts) >= 3:
                    plen = int(parts[2])
                    payload = line  # bytes already buffered after the request line
                    line = b""
                    while len(payload) < plen:
                        payload += s.read(plen - len(payload))
                    payload = payload[:plen]
                    p = resolve(parts[1], for_write=True)
                    if not p:
                        p = os.path.join(OVERLAY, parts[1].lstrip("/"))
                        os.makedirs(os.path.dirname(p), exist_ok=True)
                    with open(p, "wb") as f:
                        f.write(payload)
                    send_line(s, b"VFS OK 1")
                elif op == "MKDIR" and len(parts) >= 2:
                    p = os.path.join(OVERLAY, parts[1].lstrip("/"))
                    os.makedirs(p, exist_ok=True)
                    send_line(s, b"VFS OK 1")
                elif op == "REMOVE" and len(parts) >= 2:
                    p = resolve(parts[1], for_write=True)
                    if p and os.path.isfile(p):
                        os.remove(p)
                        send_line(s, b"VFS OK 1")
                    else:
                        send_line(s, b"VFS ERR")
                elif op == "OPEN" and len(parts) >= 2:
                    p = resolve(parts[1])
                    if p and (os.path.isfile(p) or os.path.isdir(p)):
                        hid = _next_id[0]
                        _next_id[0] += 1
                        _handles[hid] = {"path": p, "pos": 0}
                        isdir = 1 if os.path.isdir(p) else 0
                        send_line(s, f"VFS OK {hid} {isdir}".encode())
                    else:
                        send_line(s, b"VFS ERR")
                elif op == "FREAD" and len(parts) >= 3:
                    hid, n = int(parts[1]), int(parts[2])
                    h = _handles.get(hid)
                    if h:
                        with open(h["path"], "rb") as f:
                            f.seek(h["pos"])
                            data = f.read(n)
                        h["pos"] += len(data)
                        send_line(s, f"VFS OK {len(data)}".encode())
                        s.write(data)
                    else:
                        send_line(s, b"VFS ERR")
                elif op == "FSEEK" and len(parts) >= 3:
                    h = _handles.get(int(parts[1]))
                    if h:
                        h["pos"] = int(parts[2])
                        send_line(s, b"VFS OK 1")
                    else:
                        send_line(s, b"VFS ERR")
                elif op == "FTELL" and len(parts) >= 2:
                    h = _handles.get(int(parts[1]))
                    send_line(s, (f"VFS OK {h['pos']}" if h else "VFS ERR").encode())
                elif op == "FSIZE" and len(parts) >= 2:
                    h = _handles.get(int(parts[1]))
                    if h:
                        send_line(s, f"VFS OK {os.path.getsize(h['path'])}".encode())
                    else:
                        send_line(s, b"VFS ERR")
                elif op == "FNEXT" and len(parts) >= 2:
                    h = _handles.get(int(parts[1]))
                    if h:
                        it = h.get("it")
                        if it is None:
                            p = h["path"]
                            it = iter(sorted(os.listdir(p))) if os.path.isdir(p) else iter(())
                            h["it"] = it
                        name = next(it, None)
                        if name is None:
                            send_line(s, b"VFS OK END")
                        else:
                            send_line(s, b"VFS OK " + name.encode("utf-8", "replace"))
                    else:
                        send_line(s, b"VFS ERR")
                elif op == "FCLOSE" and len(parts) >= 2:
                    _handles.pop(int(parts[1]), None)
                    send_line(s, b"VFS OK 1")
                else:
                    send_line(s, b"VFS ERR")
            except Exception as e:  # never let one bad op wedge the bus
                print("vfs error:", req, e, flush=True)
                send_line(s, b"VFS ERR")


if __name__ == "__main__":
    main()