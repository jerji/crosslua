#!/usr/bin/env python3
"""Package sd_card_contents/ into the zips attached to a CrossLua release.

    python3 scripts/package_sd_card.py <version> <outdir>

Produces, in <outdir>:
  crosslua-apps-<version>.zip   the apps users install (unzip into the SD card's root: it creates /plugins/<app>/)
  crosslua-tests-<version>.zip  the on-device test suites (lua_tests_lua, grants_lua), for developers

The same script runs in CI on every push, so the zip a pull request builds is the zip a release ships. It fails (exit 1)
when a plugin is malformed or when a shipped file leaks a host path or a LAN address.
Deterministic: sorted entries and fixed timestamps, so the same tree always gives the same bytes.
"""
import os
import re
import shutil
import subprocess
import sys
import zipfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SRC = os.path.join(ROOT, "sd_card_contents")
TEST_APPS = {"lua_tests_lua", "grants_lua"}  # developer suites: not part of the apps zip
MAX_LUA_BYTES = 64 * 1024                    # the runtime refuses bigger scripts
STAMP = (2026, 1, 1, 0, 0, 0)                # fixed zip timestamp (FAT cannot store anything earlier than 1980)
LEAK = re.compile(rb"/root/|/home/[a-z]|192\.168\.\d+\.\d+|C:\\\\Users")
LUAC = shutil.which("luac5.4") or shutil.which("luac")  # parse-only Lua syntax check (nil when absent)
INSTALL = """CrossLua apps {version}

Unzip this archive into the ROOT of the SD card. It creates /plugins/<category>/<app>/ for every app.
Then, on the device: Home -> Plugins (turn plugins on under Settings -> Connectivity if the entry is missing).

Apps ask for their permissions the first time they run; each app's folder has a manifest.json that lists them.
Firmware updates come from Settings -> Check for update (this fork's own releases) or from the firmware-*.bin assets.
"""


def plugin_dirs():
    """Apps sit one level under a category: plugins/<category>/<app>."""
    base = os.path.join(SRC, "plugins")
    apps = []
    for cat in sorted(os.listdir(base)):
        cat_path = os.path.join(base, cat)
        if not os.path.isdir(cat_path):
            continue
        for app in sorted(os.listdir(cat_path)):
            if os.path.isdir(os.path.join(cat_path, app)):
                apps.append(os.path.join(cat, app))
    return sorted(apps)


def files_of(app):
    top = os.path.join(SRC, "plugins", app)
    for dirpath, dirnames, filenames in os.walk(top):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            yield full, os.path.relpath(full, SRC).replace(os.sep, "/")


def validate(app, problems):
    top = os.path.join(SRC, "plugins", app)
    for need in ("main.lua", "manifest.json"):
        if not os.path.isfile(os.path.join(top, need)):
            problems.append(f"{app}: missing {need}")
    for full, rel in files_of(app):
        data = open(full, "rb").read()
        if rel.endswith(".lua") and len(data) > MAX_LUA_BYTES:
            problems.append(f"{rel}: {len(data)} bytes is over the {MAX_LUA_BYTES}-byte script limit")
        m = LEAK.search(data)
        if m:
            problems.append(f"{rel}: host-specific text {m.group(0)!r}")
        if ".." in rel.split("/"):
            problems.append(f"{rel}: path escapes the card")
        if rel.endswith(".lua") and LUAC:
            r = subprocess.run([LUAC, "-p", full], capture_output=True, text=True)
            if r.returncode != 0:
                err = (r.stderr or "").strip().splitlines()
                problems.append(f"{rel}: Lua syntax error: {err[-1] if err else 'parse failed'}")


def write_zip(path, apps, extra=None):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        entries = []
        for app in apps:
            entries.extend(files_of(app))
        if extra:
            for name, text in extra.items():
                info = zipfile.ZipInfo(name, STAMP)
                info.external_attr = 0o644 << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                z.writestr(info, text)
        for full, rel in sorted(entries, key=lambda e: e[1]):
            info = zipfile.ZipInfo(rel, STAMP)
            info.external_attr = 0o644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with open(full, "rb") as f:
                z.writestr(info, f.read())


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    version, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    apps = plugin_dirs()
    problems = []
    for app in apps:
        validate(app, problems)
    if problems:
        print("PACKAGING FAILED:")
        for p in problems:
            print("  -", p)
        return 1
    user_apps = [a for a in apps if os.path.basename(a) not in TEST_APPS]
    test_apps = [a for a in apps if os.path.basename(a) in TEST_APPS]
    if not user_apps or not test_apps:
        print(f"PACKAGING FAILED: expected both user apps and test apps, got {user_apps} / {test_apps}")
        return 1
    apps_zip = os.path.join(outdir, f"crosslua-apps-{version}.zip")
    tests_zip = os.path.join(outdir, f"crosslua-tests-{version}.zip")
    write_zip(apps_zip, user_apps, {"CROSSLUA-INSTALL.txt": INSTALL.format(version=version)})
    write_zip(tests_zip, test_apps)
    # read both back: every entry must be intact and under plugins/
    for path in (apps_zip, tests_zip):
        with zipfile.ZipFile(path) as z:
            bad = z.testzip()
            names = [n for n in z.namelist() if n != "CROSSLUA-INSTALL.txt"]
            if bad or not names or any(not n.startswith("plugins/") for n in names):
                print(f"PACKAGING FAILED: {path} is not a clean plugins/ archive (first bad: {bad})")
                return 1
        print(f"{os.path.basename(path)}: {os.path.getsize(path)} bytes, {len(names)} files")
    print("apps:", ", ".join(user_apps))
    print("tests:", ", ".join(test_apps))
    return 0


if __name__ == "__main__":
    sys.exit(main())
