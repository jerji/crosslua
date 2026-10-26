#!/usr/bin/env python3
"""TLS test server for the on-device tls.lua hub test.

  python3 tools/tls_test_server.py --ip <this host's LAN IP> [--dir /tmp/x4tls] [--port 8443]

First run generates a throwaway CA, a server certificate (IP SAN = --ip) and an unrelated "wrong" CA in --dir, plus
tls_target.txt. Copy these three files onto the X4 into /plugins/lua_tests_lua/ (File Transfer):
    tls_target.txt   tls_ca.pem   tls_wrongca.pem
then run `tls` from the Lua tests hub. The server answers every TLS client with 'TLS_PONG <first line>' and logs each
handshake outcome (a rejected certificate shows up here as an 'unknown ca' alert from the X4).
Needs openssl on the PATH. Nothing here is a secret: the keys only ever sign this test's throwaway certificate.
"""
import argparse
import os
import socket
import ssl
import subprocess
import sys
import time


def sh(*a):
    subprocess.run(a, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def make_certs(d, ip):
    os.makedirs(d, exist_ok=True)
    p = lambda n: os.path.join(d, n)
    if not os.path.exists(p('ca.pem')):
        sh('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', p('ca.key'), '-out', p('ca.pem'), '-days', '30',
           '-subj', '/CN=X4 test CA', '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign')
        sh('openssl', 'req', '-newkey', 'rsa:2048', '-nodes', '-keyout', p('srv.key'), '-out', p('srv.csr'), '-subj', '/CN=' + ip)
        open(p('ext.cnf'), 'w').write('subjectAltName=IP:%s,DNS:tls.test\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\n'
                                      'extendedKeyUsage=serverAuth\n' % ip)
        sh('openssl', 'x509', '-req', '-in', p('srv.csr'), '-CA', p('ca.pem'), '-CAkey', p('ca.key'), '-CAcreateserial', '-out',
           p('srv.pem'), '-days', '30', '-extfile', p('ext.cnf'))
        sh('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', p('wrong.key'), '-out', p('wrongca.pem'), '-days', '30',
           '-subj', '/CN=Some other CA', '-addext', 'basicConstraints=critical,CA:TRUE')
        open(p('chain.pem'), 'w').write(open(p('srv.pem')).read() + open(p('ca.pem')).read())
    open(p('tls_target.txt'), 'w').write(ip)
    # the device test reads these names from the plugin folder
    for src, dst in (('ca.pem', 'tls_ca.pem'), ('wrongca.pem', 'tls_wrongca.pem')):
        open(p(dst), 'w').write(open(p(src)).read())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ip', required=True)
    ap.add_argument('--dir', default='/tmp/x4tls')
    ap.add_argument('--port', type=int, default=8443)
    a = ap.parse_args()
    make_certs(a.dir, a.ip)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(os.path.join(a.dir, 'chain.pem'), os.path.join(a.dir, 'srv.key'))
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('0.0.0.0', a.port))
    srv.listen(4)
    print('files for the X4 are in %s: tls_target.txt tls_ca.pem tls_wrongca.pem' % a.dir)
    print('listening on %d' % a.port, flush=True)
    while True:
        c, addr = srv.accept()
        c.settimeout(8)
        try:
            t = ctx.wrap_socket(c, server_side=True)
            print(time.strftime('%H:%M:%S'), addr[0], 'HANDSHAKE OK', t.version(), (t.cipher() or ('?',))[0], flush=True)
            line = b''
            while not line.endswith(b'\n'):
                d = t.recv(64)
                if not d:
                    break
                line += d
            t.sendall(b'TLS_PONG ' + line)
            print(time.strftime('%H:%M:%S'), addr[0], 'got', line, flush=True)
            t.close()
        except Exception as e:  # a rejected certificate lands here
            print(time.strftime('%H:%M:%S'), addr[0], 'HANDSHAKE/IO FAIL', type(e).__name__, e, flush=True)
            c.close()


if __name__ == '__main__':
    sys.exit(main())
