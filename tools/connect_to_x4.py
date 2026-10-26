#!/usr/bin/env python3
"""Connects to an X4 listen-test server on ip:port, exchanges a known payload.

Usage:
    python3 connect_to_x4.py <ip> <port>

Sends "SAMSON_PING\n", expects "X4_PONG\n" back, then closes. Prints PASS/FAIL.
Timeout: 5 seconds.
"""
import socket
import sys
import time

def main():
    if len(sys.argv) < 3:
        print("Usage: connect_to_x4.py <ip> <port>")
        sys.exit(1)
    ip, port_str = sys.argv[1], sys.argv[2]
    port = int(port_str)

    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5.0)
        s.connect((ip, port))

        # Send known payload
        s.sendall(b"SAMSON_PING\n")

        # Expect response within 3 seconds
        s.settimeout(3.0)
        data = s.recv(32)
        expected = b"X4_PONG\n"

        if data == expected:
            print(f"PASS: received {data!r}")
            s.close()
            sys.exit(0)
        else:
            print(f"FAIL: expected {expected!r}, got {data!r}")
            s.close()
            sys.exit(1)
    except socket.timeout:
        print(f"FAIL: timeout connecting to {ip}:{port} or waiting for reply")
        sys.exit(1)
    except Exception as e:
        print(f"FAIL: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()