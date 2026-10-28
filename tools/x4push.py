#!/usr/bin/env python3
"""x4push — copy a local folder (e.g. an app) onto the X4's SD card over WiFi (CrossPoint file-transfer server).

  python3 tools/x4push.py sd_card_contents/plugins/demo_lua /plugins/demo_lua [--host <ip shown on the device's File Transfer screen>]
  python3 tools/x4push.py --ls /plugins [--host ...]
  python3 tools/x4push.py --rm /plugins/demo_lua [--host ...]

On the device: Home -> File Transfer -> Join a Network (shows the IP). Pure stdlib, no dependencies.
"""
import argparse, json, mimetypes, os, sys, urllib.parse, urllib.request, uuid


def post_form(host, path, fields):
    data = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(f"http://{host}{path}", data=data)
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.status, r.read().decode(errors="replace")


def upload(host, local, remote_dir):
    # The server answers 400 "File already exists" instead of overwriting (despite its docs): delete first.
    try:
        post_form(host, "/delete", {"path": remote_dir.rstrip("/") + "/" + os.path.basename(local)})
    except urllib.error.HTTPError:
        pass  # not there yet
    boundary = uuid.uuid4().hex
    name = os.path.basename(local)
    with open(local, "rb") as f:
        body = f.read()
    ctype = mimetypes.guess_type(name)[0] or "application/octet-stream"
    payload = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\n"
               f"Content-Type: {ctype}\r\n\r\n").encode() + body + f"\r\n--{boundary}--\r\n".encode()
    q = urllib.parse.urlencode({"path": remote_dir})
    req = urllib.request.Request(f"http://{host}/upload?{q}", data=payload,
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.status, r.read().decode(errors="replace").strip()


def ensure_dir(host, remote_dir):
    parts = [p for p in remote_dir.split("/") if p]
    cur = "/"
    for p in parts:
        try:
            post_form(host, "/mkdir", {"name": p, "path": cur})
        except urllib.error.HTTPError as e:  # already exists -> 4xx/5xx is fine, verified by the upload
            pass
        cur = (cur.rstrip("/") + "/" + p)


def listing(host, path):
    q = urllib.parse.urlencode({"path": path})
    with urllib.request.urlopen(f"http://{host}/api/files?{q}", timeout=20) as r:
        return json.load(r)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default=os.environ.get("X4_HOST"), help="device IP (shown on its File Transfer screen); or set X4_HOST")
    ap.add_argument("--ls")
    ap.add_argument("--rm")
    ap.add_argument("local", nargs="?")
    ap.add_argument("remote", nargs="?")
    a = ap.parse_args()
    if not a.host:
        ap.error("no device IP: pass --host <ip> (shown on the device's File Transfer screen) or set X4_HOST")
    if a.ls:
        for e in listing(a.host, a.ls):
            print(("d " if e.get("isDirectory") else "f ") + e.get("name", "?") + (f"  {e['size']}" if "size" in e else ""))
        return 0
    if a.rm:
        s, b = post_form(a.host, "/delete", {"path": a.rm})
        print(s, b.strip())
        return 0
    if not (a.local and a.remote):
        ap.error("need <local> <remote>")
    ensure_dir(a.host, a.remote)
    n = 0
    for root, dirs, files in os.walk(a.local):
        rel = os.path.relpath(root, a.local)
        rdir = a.remote if rel == "." else a.remote.rstrip("/") + "/" + rel.replace(os.sep, "/")
        if rel != ".":
            ensure_dir(a.host, rdir)
        for fn in sorted(files):
            s, b = upload(a.host, os.path.join(root, fn), rdir)
            print(f"{s} {rdir}/{fn}: {b}")
            n += 1
    print(f"{n} file(s) uploaded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
