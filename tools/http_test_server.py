#!/usr/bin/env python3
"""HTTP(S) echo server for the on-device http_rest.lua hub test.

  python3 tools/http_test_server.py --ip <this host's LAN IP> [--dir /tmp/x4tls] [--https-port 8444] [--http-port 8081]

Reuses the throwaway CA/server certificate that tools/tls_test_server.py generates in --dir (run that once, or just this: it
generates them too). Every request is answered with a JSON echo {"method","path","headers","body"} (header names lower-cased),
plus response headers X-Echo and two Set-Cookie lines so the device test can check response_headers.
Copy tls_target.txt, tls_ca.pem and tls_wrongca.pem from --dir onto the X4 into /plugins/lua_tests_lua/.
"""
import argparse
import json
import os
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tls_test_server import make_certs  # noqa: E402


class Echo(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'

    def _echo(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n).decode('utf-8', 'replace') if n else ''
        out = json.dumps({'method': self.command, 'path': self.path,
                          'headers': {k.lower(): v for k, v in self.headers.items()}, 'body': body}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(out)))
        self.send_header('X-Echo', '1')
        self.send_header('Set-Cookie', 'a=1')
        self.send_header('Set-Cookie', 'b=2')
        self.end_headers()
        self.wfile.write(out)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = _echo

    def log_message(self, format, *args):  # noqa: A002
        print('%s %s %s' % (self.address_string(), self.command, self.path), flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ip', required=True)
    ap.add_argument('--dir', default='/tmp/x4tls')
    ap.add_argument('--https-port', type=int, default=8444)
    ap.add_argument('--http-port', type=int, default=8081)
    a = ap.parse_args()
    make_certs(a.dir, a.ip)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(os.path.join(a.dir, 'chain.pem'), os.path.join(a.dir, 'srv.key'))
    https = ThreadingHTTPServer(('0.0.0.0', a.https_port), Echo)
    https.socket = ctx.wrap_socket(https.socket, server_side=True)
    http = ThreadingHTTPServer(('0.0.0.0', a.http_port), Echo)
    threading.Thread(target=http.serve_forever, daemon=True).start()
    print('files for the X4 are in %s: tls_target.txt tls_ca.pem tls_wrongca.pem' % a.dir)
    print('https on %d, http on %d' % (a.https_port, a.http_port), flush=True)
    https.serve_forever()


if __name__ == '__main__':
    sys.exit(main())
