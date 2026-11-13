#!/usr/bin/env python3
"""Package each driver folder under drivers/ into c4z/<package>.c4z (a .c4z is a zip).

Each driver folder holds <Name>_driver.xml + <Name>_driver.lua (stable names) plus optional www/ (icons, docs).
The XML's <script file="..."> says what Composer expects the Lua file to be called inside the package; this script
renames on the way in, so the repo filenames never have to change.

Before a driver is built, its pre-flight checks run (tools/check_c4z.py). If any fail, that driver is not built.
If the driver's source differs from the existing c4z/<name>.c4z (ignoring <version> and <modified>), <version> is
bumped to max(XML version, version at git HEAD, version in the c4z) + 1 and <modified> is set to the local time,
in the same format the file already uses. Unchanged source is not bumped.

Moen Smart Shower also needs a few files from Control4's public Lua library, drivers-common-public. They are not
stored in this repo (see README). Point C4_COMMON_PUBLIC at a clone of that library and they are copied in:

    git clone https://github.com/snap-one/drivers-common-public ~/drivers-common-public
    C4_COMMON_PUBLIC=~/drivers-common-public python3 tools/build_c4z.py

Usage:  python3 tools/build_c4z.py [--dry-run] [driver-folder ...]   (no arguments = build everything)
--dry-run runs the bump plan and all checks and reports what would be bumped and built, writing nothing.
"""
import argparse
import os
import re
import sys
import zipfile
from datetime import datetime

from check_c4z import (
    check_folder, head_layout, has_driver_files, layout, load_source, package_layout, script_name, sig, xml_facts,
)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DRIVERS = os.path.join(ROOT, "drivers")
DIST = os.path.join(ROOT, "c4z")
COMMON = os.environ.get("C4_COMMON_PUBLIC")
COMMON_FILES = [
    "global/handlers.lua", "global/lib.lua", "global/timer.lua", "global/url.lua",
    "module/json.lua", "module/metrics.lua", "module/websocket.lua",
]
# Some drivers were first installed in Composer under a different .c4z name than their folder. Composer matches an
# update to the installed driver by package name (and the XML icon paths use it), so build those under the original name.
PACKAGE_NAMES = {
    "haiku-senseme-fan": "Haiku_SenseME_Fan",
    "haiku-senseme-light": "Haiku_SenseME_Light",
    "intellifire": "IntelliFire_driver",
    "lifx-lan": "lifx_lan",
    "moen-smart-shower": "Moen_Smart_Shower_Standalone_driver_v200",
    "yale-assure-lock-2": "Yale_AssureLock2",
    "daylight-lighting-scheduler": "daylight_lighting_scheduler",
    "media-remote-bridge-untested": "MediaRemoteBridge",
    "unifi-controller": "UniFi_PDU_Controls",
    "unifi-outlet": "UniFi_Outlet",
}
REQUIRE_COMMON = re.compile(r"^\s*(?:\w+\s*=\s*)?require\s*\(?\s*['\"]drivers-common-public", re.M)


def format_modified(existing, now):
    """Format <modified> the way the file already does (zero-padded or not hour), e.g. 11/12/2026 08:30 PM."""
    m = re.match(r"\d{2}/\d{2}/\d{4} (\d{1,2}):", existing or "")
    pad = not m or len(m.group(1)) == 2
    hour = now.hour % 12 or 12
    hs = f"{hour:02d}" if pad else str(hour)
    return f"{now:%m/%d/%Y} {hs}:{now:%M} {'AM' if now.hour < 12 else 'PM'}"


def set_tag(text, tag, value):
    new, n = re.subn(rf"<{tag}>[^<]*</{tag}>", f"<{tag}>{value}</{tag}>", text, count=1)
    if n == 0 and tag == "modified":
        new, n = re.subn(r"(</version>)", rf"\1\n\t<modified>{value}</modified>", text, count=1)
    if n == 0:
        raise ValueError(f"no <{tag}> element to update")
    return new


def plan_bump(path):
    """Return ((new_xml_bytes, old_version, new_version, new_modified), None) when the source differs from the
    existing c4z, else (None, reason)."""
    names, files = load_source(path)
    xml_rel, lua_rel = names
    name = os.path.basename(os.path.normpath(path))
    cur_xml = files[xml_rel]
    pkg_file = os.path.join(DIST, PACKAGE_NAMES.get(name, name) + ".c4z")
    if not os.path.isfile(pkg_file):
        return None, "no existing c4z to compare against"
    pkg_lay = package_layout(pkg_file)
    if pkg_lay is None:
        raise ValueError(f"c4z/{os.path.basename(pkg_file)} is not a readable package")
    if sig(layout(files, xml_rel, lua_rel)) == sig(pkg_lay):
        return None, f"source unchanged since c4z/{os.path.basename(pkg_file)}"
    _, cur_v, old_mod = xml_facts(cur_xml)
    if cur_v is None:
        raise ValueError("<version> is not an integer, so it cannot be bumped")
    _, pkg_v, _ = xml_facts(pkg_lay["driver.xml"])
    head = head_layout(path)
    head_v = xml_facts(head["driver.xml"])[1] if head else None
    new_v = max(v for v in (cur_v, head_v, pkg_v) if v is not None) + 1
    new_mod = format_modified(old_mod, datetime.now())
    text = cur_xml.decode("utf-8")
    text = set_tag(text, "version", new_v)
    text = set_tag(text, "modified", new_mod)
    return (text.encode("utf-8"), cur_v, new_v, new_mod), None


def build(folder, dry_run=False):
    path = folder if os.path.isdir(folder) else os.path.join(DRIVERS, folder)
    name = os.path.basename(os.path.normpath(path))
    if not os.path.isdir(path):
        print(f"skip {folder}: no such folder")
        return False
    names, files = load_source(path)
    if names is None:
        if not has_driver_files(list(files)):
            print(f"skip {name}: no driver files")
            return True
        print(f"FAIL {name} [file] expected one *_driver.xml and one *_driver.lua (or driver.xml and driver.lua)")
        return False
    xml_rel, lua_rel = names
    xml_path, lua_path = os.path.join(path, xml_rel), os.path.join(path, lua_rel)
    lua_text = files[lua_rel].decode("utf-8-sig", "replace")
    needs_common = bool(REQUIRE_COMMON.search(lua_text))
    if needs_common and not COMMON:
        print(f"skip {name}: needs drivers-common-public. Set C4_COMMON_PUBLIC (see this script's header).")
        return False

    # Auto-bump. In a dry run the bumped XML is only handed to the checks in memory.
    try:
        bump, why = plan_bump(path)
    except ValueError as e:
        print(f"FAIL {name} [b] {e}")
        return False
    xml_override = None
    if bump:
        new_bytes, old_v, new_v, new_mod = bump
        if dry_run:
            print(f"would bump {name}: <version> {old_v} -> {new_v}, <modified> {new_mod}")
            xml_override = new_bytes
        else:
            with open(xml_path, "wb") as fh:
                fh.write(new_bytes)
            print(f"bumped {name}: <version> {old_v} -> {new_v}, <modified> {new_mod}")
    else:
        print(f"no bump {name}: {why}")

    problems, warnings = check_folder(path, xml_override=xml_override)
    for line in warnings:
        print(line)
    if problems:
        for line in problems:
            print(line)
        note = " (the XML was already bumped on disk)" if bump and not dry_run else ""
        print(f"refusing to build {name}{note}")
        return False

    out = os.path.join(DIST, PACKAGE_NAMES.get(name, name) + ".c4z")
    if dry_run:
        print(f"would build {os.path.relpath(out, ROOT)}")
        return True

    # Re-read the XML from disk: it may have just been bumped.
    with open(xml_path, "rb") as fh:
        script_in_pkg = script_name(fh.read())
    os.makedirs(DIST, exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(xml_path, "driver.xml")
        z.write(lua_path, script_in_pkg)
        for dirpath, _, fnames in os.walk(path):
            for f in fnames:
                full = os.path.join(dirpath, f)
                rel = os.path.relpath(full, path).replace(os.sep, "/")
                if full in (xml_path, lua_path) or rel.endswith(".md"):
                    continue
                # Helper scripts that live beside the driver (top-level tools/ and build.sh) are not part of the package.
                if rel == "build.sh" or rel.startswith("tools/"):
                    continue
                z.write(full, rel)
        if needs_common:
            for rel in COMMON_FILES:
                src = os.path.join(COMMON, *rel.split("/"))
                if not os.path.exists(src):
                    print(f"warning {name}: {src} not found")
                    continue
                z.write(src, "drivers-common-public/" + rel)
    print(f"built {out}")
    return True


def main():
    ap = argparse.ArgumentParser(description="Build Control4 driver packages into c4z/ after pre-flight checks.")
    ap.add_argument("folders", nargs="*", help="driver names (default: every driver)")
    ap.add_argument("--dry-run", action="store_true", help="run the checks and report bumps and builds; write nothing")
    args = ap.parse_args()
    names = args.folders or sorted(d for d in os.listdir(DRIVERS) if os.path.isdir(os.path.join(DRIVERS, d)))
    ok = [build(n, args.dry_run) for n in names]
    sys.exit(0 if all(ok) else 1)


if __name__ == "__main__":
    main()
