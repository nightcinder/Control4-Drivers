#!/usr/bin/env python3
"""Package each driver folder under drivers/ into dist/<folder>.c4z (a .c4z is a zip).

Each driver folder holds <Name>_driver.xml + <Name>_driver.lua (stable names) plus optional www/ (icons, docs).
The XML's <script file="..."> says what Composer expects the Lua file to be called inside the package; this script
renames on the way in, so the repo filenames never have to change.

Moen Smart Shower also needs a few files from Control4's public Lua library, drivers-common-public. They are not
stored in this repo (see README). Point C4_COMMON_PUBLIC at a clone of that library and they are copied in:

    git clone https://github.com/snap-one/drivers-common-public ~/drivers-common-public
    C4_COMMON_PUBLIC=~/drivers-common-public python3 tools/build_c4z.py

Usage:  python3 tools/build_c4z.py [driver-folder ...]      (no arguments = build everything)
"""
import glob
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DRIVERS = os.path.join(ROOT, "drivers")
DIST = os.path.join(ROOT, "dist")
COMMON = os.environ.get("C4_COMMON_PUBLIC")
COMMON_FILES = [
    "global/handlers.lua", "global/lib.lua", "global/timer.lua", "global/url.lua",
    "module/json.lua", "module/metrics.lua", "module/websocket.lua",
]
REQUIRE_COMMON = re.compile(r"^\s*(?:\w+\s*=\s*)?require\s*\(?\s*['\"]drivers-common-public", re.M)


def build(folder):
    path = os.path.join(DRIVERS, folder)
    xmls = glob.glob(os.path.join(path, "*_driver.xml"))
    luas = glob.glob(os.path.join(path, "*_driver.lua"))
    if len(xmls) != 1 or len(luas) != 1:
        print(f"skip {folder}: expected one *_driver.xml and one *_driver.lua")
        return False
    xml_path, lua_path = xmls[0], luas[0]
    xml_text = open(xml_path, encoding="utf-8-sig").read()
    m = re.search(r'<script\s+file="([^"]+)"', xml_text)
    script_name = m.group(1) if m else "driver.lua"
    lua_text = open(lua_path, encoding="utf-8-sig", errors="replace").read()
    needs_common = bool(REQUIRE_COMMON.search(lua_text))
    if needs_common and not COMMON:
        print(f"skip {folder}: needs drivers-common-public. Set C4_COMMON_PUBLIC (see this script's header).")
        return False

    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, folder + ".c4z")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(xml_path, "driver.xml")
        z.write(lua_path, script_name)
        for dirpath, _, files in os.walk(path):
            for f in files:
                full = os.path.join(dirpath, f)
                rel = os.path.relpath(full, path).replace(os.sep, "/")
                if full in (xml_path, lua_path) or rel.endswith(".md"):
                    continue
                z.write(full, rel)
        if needs_common:
            for rel in COMMON_FILES:
                src = os.path.join(COMMON, *rel.split("/"))
                if not os.path.exists(src):
                    print(f"warning {folder}: {src} not found")
                    continue
                z.write(src, "drivers-common-public/" + rel)
    print(f"built {out}")
    return True


def main():
    names = sys.argv[1:] or sorted(d for d in os.listdir(DRIVERS) if os.path.isdir(os.path.join(DRIVERS, d)))
    ok = [build(n) for n in names]
    sys.exit(0 if all(ok) else 1)


if __name__ == "__main__":
    main()
