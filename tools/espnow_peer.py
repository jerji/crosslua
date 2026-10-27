#!/usr/bin/env python3
"""Host-side ESP-NOW peer for the on-device espnow.lua test: a monitor-mode WiFi adapter on channel 1.

  python3 tools/espnow_peer.py [--iface wlx...] [--channel 1] [--secs 30] [--inject-every 1.5] [--no-inject]

Captures every ESP-NOW frame in the air (802.11 action frame, category 127, OUI 18:fe:34, vendor element type 4) and prints the
payload; unless --no-inject it also broadcasts its own frames "HOST-FRAME-nnn" so the X4's espnow.recv() has something to receive.
Needs root and scapy (uv run --with scapy). Puts the adapter back into managed mode when done.
"""
import argparse
import os
import subprocess
import sys
import threading
import time

from scapy.all import Dot11, RadioTap, Raw, conf, sendp, sniff  # noqa: E402

OUI = b'\x18\xfe\x34'


def sh(*a):
    subprocess.run(a, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def espnow_frame(src, payload, dst='ff:ff:ff:ff:ff:ff'):
    body = bytes([0x7F]) + OUI + os.urandom(4) + bytes([0xDD, len(payload) + 5]) + OUI + bytes([0x04, 0x01]) + payload
    # 1 Mbps (radiotap rate is in 500 kbps units), like a stock ESP32 ESP-NOW send
    return RadioTap(present='Rate', Rate=2) / Dot11(type=0, subtype=13, addr1=dst, addr2=src, addr3='ff:ff:ff:ff:ff:ff') / Raw(body)


def parse(pkt):
    """-> (src_mac, payload) for an ESP-NOW frame, else None."""
    if not pkt.haslayer(Dot11) or pkt[Dot11].type != 0 or pkt[Dot11].subtype != 13:
        return None
    b = bytes(pkt[Dot11].payload)  # scapy dissects action frames into its own layer, so read the raw bytes under the header
    if len(b) < 15 or b[0] != 0x7F or b[1:4] != OUI:
        return None
    i = 8  # category(1) + OUI(3) + random(4)
    if b[i] != 0xDD or b[i + 2:i + 5] != OUI or b[i + 5] != 0x04:
        return None
    n = b[i + 1] - 5
    return pkt[Dot11].addr2, b[i + 7:i + 7 + n]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--iface', default='wlx04421a527590')
    ap.add_argument('--channel', type=int, default=1)
    ap.add_argument('--secs', type=float, default=30)
    ap.add_argument('--inject-every', type=float, default=1.5)
    ap.add_argument('--no-inject', action='store_true')
    ap.add_argument('--src', default='02:48:4f:53:54:01', help='MAC the injected frames claim to come from')
    a = ap.parse_args()
    sh('ip', 'link', 'set', a.iface, 'down')
    sh('iw', 'dev', a.iface, 'set', 'type', 'monitor')
    sh('ip', 'link', 'set', a.iface, 'up')
    sh('iw', 'dev', a.iface, 'set', 'channel', str(a.channel))
    conf.iface = a.iface
    stop = threading.Event()
    seen = {}
    injected = [0]

    def inject():
        n = 0
        while not stop.is_set():
            n += 1
            sendp(espnow_frame(a.src, ('HOST-FRAME-%03d' % n).encode()), iface=a.iface, verbose=False)
            injected[0] = n
            stop.wait(a.inject_every)

    if not a.no_inject:
        threading.Thread(target=inject, daemon=True).start()
    t0 = time.time()
    print('monitoring %s on channel %d for %.0f s' % (a.iface, a.channel, a.secs), flush=True)

    def handle(pkt):
        r = parse(pkt)
        if r and r[0].lower() != a.src:  # not our own injected frames
            src, payload = r
            seen.setdefault(src, []).append(payload)
            print('%6.1fs  ESPNOW from %s: %r' % (time.time() - t0, src, payload), flush=True)

    try:
        sniff(iface=a.iface, prn=handle, store=False, timeout=a.secs)
    finally:
        stop.set()
        time.sleep(0.2)
        try:
            sh('ip', 'link', 'set', a.iface, 'down')
            sh('iw', 'dev', a.iface, 'set', 'type', 'managed')
            sh('ip', 'link', 'set', a.iface, 'up')
        except Exception:
            pass
    print('SUMMARY injected=%d' % injected[0] + ''.join(' captured_from_%s=%d' % (k, len(v)) for k, v in seen.items()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
