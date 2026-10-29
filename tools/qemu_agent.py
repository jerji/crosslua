#!/usr/bin/env python3
"""QEMU UART1 agent: owns the dev-serial pty and speaks BOTH protocols on it.

The firmware multiplexes two things over UART1 (dev serial):
  - the dev-serial protocol (CMD:PING/SCREEN/BTN...) driven by the host
  - the virtual-SD VFS protocol (VFS HELLO/EXISTS/READ/...) served by us

Two separate host processes on one pty steal each other's replies (the first
blocking read grabs everything). This agent is the single reader/writer: it
answers VFS requests itself, forwards every other byte to a fresh proxy pty,
and forwards what a client writes on the proxy pty into the device.

Usage:
  python3 tools/qemu_agent.py <uart1-pty> <sd-base> <overlay-dir>
Prints: PROXY <path>   <- point an unmodified x4ctl at it with --port
"""
import os
import select
import sys
import time

GREET = os.environ.get("QEMU_AGENT_GREET", "1") != "0"

try:
    import serial
except ImportError:
    sys.exit("need pyserial: uv run --with pyserial tools/qemu_agent.py ...")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qemu_vfs  # reuse resolve() + the open-handle table

PORT = sys.argv[1] if len(sys.argv) > 1 else "/dev/pts/1"
BASE = sys.argv[2] if len(sys.argv) > 2 else "/root/x4/crosspoint-lua/sd_card_contents"
OVERLAY = sys.argv[3] if len(sys.argv) > 3 else "/tmp/x4-vfs"

os.makedirs(OVERLAY, exist_ok=True)
qemu_vfs.BASE = BASE
qemu_vfs.OVERLAY = OVERLAY


def send_line(s, line):
    s.write(line + b"\n")


def handle_vfs(dev, req):
    """One VFS request. Mirrors tools/qemu_vfs.py's handler chain."""
    parts = req.decode("utf-8", "replace").split(" ")
    # The wire format is "VFS <op> <args...>": drop the prefix so that
    # parts[1..] below are the op's arguments.
    if len(parts) > 1 and parts[0] == "VFS":
        parts = parts[1:]
    op = parts[0]
    arg = " ".join(parts[1:])[:60]
    print(f"[vfs] {op} {arg}", flush=True)
    if op == "HELLO":
        send_line(dev, b"VFS OK 1")
    elif op == "EXISTS" and len(parts) >= 2:
        send_line(dev, b"VFS OK 1" if qemu_vfs.resolve(parts[1]) else b"VFS OK 0")
    elif op == "SIZE" and len(parts) >= 2:
        p = qemu_vfs.resolve(parts[1])
        if p and os.path.isfile(p):
            send_line(dev, f"VFS OK {os.path.getsize(p)}".encode())
        else:
            send_line(dev, b"VFS ERR")
    elif op == "STAT" and len(parts) >= 2:
        p = qemu_vfs.resolve(parts[1])
        if p and os.path.isfile(p):
            mt = int(os.path.getmtime(p) or 0)
            send_line(dev, f"VFS OK {os.path.getsize(p)} {mt}".encode())
        else:
            send_line(dev, b"VFS ERR")
    elif op == "LIST" and len(parts) >= 2:
        p = qemu_vfs.resolve(parts[1])
        if p and os.path.isdir(p):
            names = sorted(os.listdir(p))
            send_line(dev, f"VFS OK {len(names)}".encode())
            for n in names:
                send_line(dev, n.encode("utf-8", "replace"))
        else:
            send_line(dev, b"VFS OK 0")
    elif op == "READ" and len(parts) >= 4:
        p = qemu_vfs.resolve(parts[1])
        off, maxlen = int(parts[2]), int(parts[3])
        if p and os.path.isfile(p):
            with open(p, "rb") as f:
                f.seek(off)
                data = f.read(maxlen)
            send_line(dev, f"VFS OK {len(data)}".encode())
            dev.write(data)
        else:
            send_line(dev, b"VFS ERR")
    elif op == "WRITE":
        # Needs the trailing payload from the line buffer; handled by the caller.
        pass
    elif op == "MKDIR" and len(parts) >= 2:
        p = os.path.join(OVERLAY, parts[1].lstrip("/"))
        os.makedirs(p, exist_ok=True)
        send_line(dev, b"VFS OK 1")
    elif op == "REMOVE" and len(parts) >= 2:
        p = qemu_vfs.resolve(parts[1], for_write=True)
        if p and os.path.isfile(p):
            os.remove(p)
            send_line(dev, b"VFS OK 1")
        else:
            send_line(dev, b"VFS ERR")
    elif op == "OPEN" and len(parts) >= 2:
        p = qemu_vfs.resolve(parts[1])
        if p and (os.path.isfile(p) or os.path.isdir(p)):
            hid = qemu_vfs._next_id[0]
            qemu_vfs._next_id[0] += 1
            qemu_vfs._handles[hid] = {"path": p, "pos": 0}
            isdir = 1 if os.path.isdir(p) else 0
            print(f"[vfs] -> OPEN {parts[1]} = {hid} {isdir}", flush=True)
            send_line(dev, f"VFS OK {hid} {isdir}".encode())
        else:
            print(f"[vfs] -> OPEN {parts[1]} ERR", flush=True)
            send_line(dev, b"VFS ERR")
    elif op == "FREAD" and len(parts) >= 3:
        hid, n = int(parts[1]), int(parts[2])
        h = qemu_vfs._handles.get(hid)
        if h:
            with open(h["path"], "rb") as f:
                f.seek(h["pos"])
                data = f.read(n)
            h["pos"] += len(data)
            send_line(dev, f"VFS OK {len(data)}".encode())
            dev.write(data)
        else:
            send_line(dev, b"VFS ERR")
    elif op == "FSEEK" and len(parts) >= 3:
        h = qemu_vfs._handles.get(int(parts[1]))
        if h:
            h["pos"] = int(parts[2])
            send_line(dev, b"VFS OK 1")
        else:
            send_line(dev, b"VFS ERR")
    elif op == "FTELL" and len(parts) >= 2:
        h = qemu_vfs._handles.get(int(parts[1]))
        send_line(dev, (f"VFS OK {h['pos']}" if h else "VFS ERR").encode())
    elif op == "FSIZE" and len(parts) >= 2:
        h = qemu_vfs._handles.get(int(parts[1]))
        if h:
            send_line(dev, f"VFS OK {os.path.getsize(h['path'])}".encode())
        else:
            send_line(dev, b"VFS ERR")
    elif op == "FNEXT" and len(parts) >= 2:
        h = qemu_vfs._handles.get(int(parts[1]))
        if h:
            it = h.get("it")
            if it is None:
                p = h["path"]
                it = iter(sorted(os.listdir(p))) if os.path.isdir(p) else iter(())
                h["it"] = it
            name = next(it, None)
            if name is None:
                send_line(dev, b"VFS OK END")
            else:
                send_line(dev, b"VFS OK " + name.encode("utf-8", "replace"))
        else:
            send_line(dev, b"VFS ERR")
    elif op == "FCLOSE" and len(parts) >= 2:
        qemu_vfs._handles.pop(int(parts[1]), None)
        send_line(dev, b"VFS OK 1")
    else:
        send_line(dev, b"VFS ERR")


def main():
    dev = serial.Serial(PORT, 921600, timeout=0.05)

    # The firmware's storage handshake ("VFS HELLO" + the 20 s wait) can start
    # before we attach. An unsolicited "VFS OK 1" satisfies it: hello() consumes
    # the first line on RX, request or not. Repeat it briefly through the attach
    # window in case the firmware's exchange is mid-retry. Do NOT reset the
    # input buffer: any early HELLO request bytes already queued would be
    # dropped, and the boot never retries requests it has already sent.
    if GREET:
        for _ in range(4):
            time.sleep(0.25)
            dev.write(b"VFS OK 1\n")
        print("agent: sent boot HELLO greetings", flush=True)
    else:
        print("agent: greetings disabled (mid-session attach)", flush=True)

    master, slave = os.openpty()
    os.set_blocking(master, False)
    print(f"agent: UART1={PORT} base={BASE} overlay={OVERLAY}", flush=True)
    print(f"PROXY {os.ttyname(slave)}", flush=True)
    print(f"agent: keeping slave open for the x4ctl client ({os.ttyname(slave)})", flush=True)

    # Keep the slave fd alive for the lifetime of the agent.
    slave_holder = os.fdopen(slave, "rb", buffering=0)

    buf = b""  # partial line(s) from the device, awaiting a '\n'

    def feed(chunk):
        # Process raw device bytes through the VFS/dev splitter. Returns the
        # leftover partial buffer.
        nonlocal buf
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if line.startswith(b"VFS "):
                parts = line.decode("utf-8", "replace").split(" ")
                if len(parts) > 1 and parts[0] == "VFS":
                    parts = parts[1:]
                if parts[0] == "WRITE" and len(parts) >= 3:
                    # The payload follows the request line. Consume exactly plen
                    # bytes (buffered + more reads) so the bus stays aligned,
                    # then answer like qemu_vfs.py does.
                    plen = int(parts[2])
                    while len(buf) < plen:
                        more = dev.read(plen - len(buf))
                        if not more:
                            time.sleep(0.01)
                            continue
                        buf += more
                    payload = buf[:plen]
                    buf = buf[plen:]
                    p = qemu_vfs.resolve(parts[1], for_write=True)
                    if not p:
                        p = os.path.join(OVERLAY, parts[1].lstrip("/"))
                        os.makedirs(os.path.dirname(p), exist_ok=True)
                    with open(p, "wb") as f:
                        f.write(payload)
                    print(f"[vfs] WRITE {parts[1]} {plen}", flush=True)
                    send_line(dev, b"VFS OK 1")
                else:
                    try:
                        handle_vfs(dev, line)
                    except Exception as e:  # never wedge the bus
                        print("vfs error:", line, e, flush=True)
                        send_line(dev, b"VFS ERR")
            else:
                tee("<", line + b"\n")
                os.write(master, line + b"\n")
        if buf:  # partial line or binary middle: forward non-VFS bytes now
            if buf.startswith(b"VFS "):
                return  # a VFS request is still arriving; don't split it
            tee("<", buf)
            os.write(master, buf)
            buf = b""

    # Drain whatever the boot already sent while we were attaching (HELLOs,
    # boot logs) and answer it; without this the 20 s storage handshake is a
    # coin flip on attach latency.
    dev.timeout = 0.2
    for _ in range(20):
        chunk = dev.read(4096)
        if not chunk:
            break
        try:
            feed(chunk)
        except Exception as e:
            print("drain err:", e, flush=True)

    def tee(tag, data):
        for ln in data.split(b"\n"):
            if ln:
                print(f"[{tag}] {ln.decode('utf-8', 'replace')[:180]}", flush=True)

    while True:
        try:
            r, _, _ = select.select([master, dev], [], [], 0.5)
        except OSError:
            time.sleep(0.2)
            continue

        if master in r:
            try:
                chunk = os.read(master, 4096)
            except OSError:
                chunk = b""
            if chunk:
                dev.write(chunk)  # client (x4ctl) command -> device
                tee("->", chunk)

        if dev in r:
            try:
                chunk = dev.read(4096)
            except serial.SerialException:
                time.sleep(0.2)
                continue
            if not chunk:
                continue
            try:
                feed(chunk)
            except Exception as e:  # never let one bad op wedge the bus
                print("loop err:", e, flush=True)


if __name__ == "__main__":
    main()