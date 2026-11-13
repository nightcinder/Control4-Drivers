#!/usr/bin/env python3
"""Pre-flight checks for a Control4 driver source folder and its built package in c4z/.

Usage:
  python3 tools/check_c4z.py <driver-folder> [<driver-folder> ...]
  python3 tools/check_c4z.py --all [--no-version-check]

A driver folder is a path, or a name under drivers/. Each problem prints one line,
"FAIL <driver> [<check>] <reason>" (warnings start with "WARN"). The exit status is 1
when any check fails. The checks a-j are described in docs/composer-update-notes.md
("Pre-flight"). --no-version-check skips the version ordering in check b; the integer
check still runs.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DRIVERS = os.path.join(ROOT, "drivers")
DIST = os.path.join(ROOT, "c4z")
COMMON = "drivers-common-public/"
BOM = b"\xef\xbb\xbf"
DRIVER_CONST_RE = re.compile(r'^\s*(?:local\s+)?(?:DRIVER_VERSION|VERSION)\s*=\s*["\']([^"\']*)["\']', re.M)
DRIVER_SET_RE = re.compile(r'(?:UpdateProperty|setProp)\s*\(\s*["\']Driver Version["\']')
ONINIT_RE = re.compile(r'function\s+OnDriverInit\s*\(|OnDriverInit\s*=\s*function')
EXEC_RE = re.compile(r'function\s+ExecuteCommand\s*\(')
SCRIPT_RE = re.compile(r'<script\s+file="([^"]+)"')
PROPERTIES_WRITE_RE = re.compile(r'Properties\[[^\]]+\]\s*=[^=]')


def package_names():
    # build_c4z imports this module, so the import is done lazily to avoid a load-time cycle.
    import build_c4z
    return build_c4z.PACKAGE_NAMES


def strip_bom(data):
    return data[3:] if data.startswith(BOM) else data


def script_name(xml_bytes):
    m = SCRIPT_RE.search(xml_bytes.decode("utf-8", "replace"))
    return m.group(1) if m else "driver.lua"


def is_excluded(rel):
    # Same rule as build_c4z.py: markdown, build.sh and top-level tools/ are not packaged.
    return rel.endswith(".md") or rel == "build.sh" or rel.startswith("tools/")


def pick_names(names):
    """(xml, lua) top-level names, using build_c4z's rule. None unless there is exactly one of each."""
    top = [n for n in names if "/" not in n]
    xmls = [n for n in top if n.endswith("_driver.xml")] or [n for n in top if n == "driver.xml"]
    luas = [n for n in top if n.endswith("_driver.lua")] or [n for n in top if n == "driver.lua"]
    if len(xmls) != 1 or len(luas) != 1:
        return None
    return xmls[0], luas[0]


def has_driver_files(names):
    return any(n == "driver.xml" or n == "driver.lua" or n.endswith("_driver.xml") or n.endswith("_driver.lua")
               for n in names if "/" not in n)


def read_tree(path):
    files = {}
    for dirpath, _, names in os.walk(path):
        for f in names:
            full = os.path.join(dirpath, f)
            rel = os.path.relpath(full, path).replace(os.sep, "/")
            with open(full, "rb") as fh:
                files[rel] = fh.read()
    return files


def load_source(path):
    """Return (names, files): names is (xml_rel, lua_rel) or None, files maps rel path -> bytes."""
    files = read_tree(path)
    return pick_names(list(files)), files


def layout(files, xml_rel, lua_rel, xml_bytes=None):
    """Map each packed file to its name inside the .c4z, the way build_c4z.py writes it."""
    xml = files[xml_rel] if xml_bytes is None else xml_bytes
    script = script_name(xml)
    out = {"driver.xml": xml, script: files[lua_rel]}
    for rel, data in files.items():
        if rel not in (xml_rel, lua_rel) and not is_excluded(rel):
            out[rel] = data
    return out


def canonical_xml(data):
    root = ET.fromstring(data)
    for child in list(root):
        if child.tag in ("version", "modified"):
            root.remove(child)
    return ET.tostring(root, encoding="unicode")


def sig(lay):
    """Comparable form of a package layout, ignoring <version>/<modified> and the shared common library."""
    out = {}
    for rel, data in lay.items():
        if rel.startswith(COMMON):
            continue
        if rel == "driver.xml":
            try:
                out[rel] = canonical_xml(data)
            except ET.ParseError:
                out[rel] = data
        else:
            # Git may check text files out with CRLF; line endings are not a source change. Applied to both sides.
            out[rel] = strip_bom(data).replace(b"\r\n", b"\n")
    return out


def xml_facts(data):
    """(root, version as int or None, modified text or None). root is None when the XML does not parse."""
    try:
        root = ET.fromstring(data)
    except ET.ParseError:
        return None, None, None
    v = (root.findtext("version") or "").strip()
    m = (root.findtext("modified") or "").strip() or None
    return root, (int(v) if re.fullmatch(r"\d+", v) else None), m


def image_refs(root):
    """Package-relative icon paths that the XML pulls from the package (image_source="c4z")."""
    refs = []
    for el in root.iter():
        if el.get("image_source") != "c4z":
            continue
        cands = [el.text or ""] if el.tag in ("small", "large") else []
        cands += [el.get("small_image") or "", el.get("large_image") or ""]
        for c in cands:
            c = c.strip()
            if c and c not in refs:
                refs.append(c)
    return refs


def git_bytes(args):
    r = subprocess.run(["git", *args], cwd=ROOT, capture_output=True)
    return r.stdout if r.returncode == 0 else None


def rel_folder(path):
    return os.path.relpath(os.path.normpath(path), ROOT).replace(os.sep, "/")


def head_layout(path):
    """Package layout of the driver folder at git HEAD, or None when it is not in git."""
    prefix = rel_folder(path) + "/"
    listing = git_bytes(["ls-tree", "-r", "--name-only", "HEAD", prefix])
    if not listing:
        return None
    files = {}
    for full in listing.decode("utf-8").splitlines():
        if full.startswith(prefix):
            files[full[len(prefix):]] = git_bytes(["show", "HEAD:" + full]) or b""
    names = pick_names(list(files))
    if names is None:
        return None
    return layout(files, names[0], names[1])


def package_layout(pkg_path):
    with zipfile.ZipFile(pkg_path) as zf:
        files = {n: zf.read(n) for n in zf.namelist() if not n.endswith("/")}
    if "driver.xml" not in files:
        return None
    script = script_name(files["driver.xml"])
    if script not in files:
        return None
    return layout(files, "driver.xml", script)


def existing_package(name):
    """Path of c4z/<expected>.c4z when that exact file exists (case-sensitive), else None."""
    expected = package_names().get(name, name) + ".c4z"
    present = os.listdir(DIST) if os.path.isdir(DIST) else []
    return os.path.join(DIST, expected) if expected in present else None


def norm(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())


def luac_error(data, label):
    with tempfile.TemporaryDirectory() as td:
        p = os.path.join(td, "check.lua")
        with open(p, "wb") as fh:
            fh.write(strip_bom(data))
        try:
            r = subprocess.run(["luac", "-p", p], capture_output=True, text=True)
        except FileNotFoundError:
            return "luac is not on PATH, so the Lua syntax check could not run"
    if r.returncode == 0:
        return None
    text = (r.stderr or r.stdout or "luac -p failed").strip().splitlines()[0]
    return f"{label}: " + text.replace(p, label)


def check_folder(path, xml_override=None, version_check=True):
    """Run checks a-j on one driver folder. xml_override replaces the on-disk driver.xml (dry-run bump).
    Returns (problems, warnings), both lists of one-line strings."""
    path = os.path.normpath(path)
    name = os.path.basename(path)
    problems, warnings = [], []

    def fail(c, msg):
        problems.append(f"FAIL {name} [{c}] {msg}")

    def warn(c, msg):
        warnings.append(f"WARN {name} [{c}] {msg}")

    names, files = load_source(path)
    if names is None:
        fail("file", "expected one *_driver.xml and one *_driver.lua (or driver.xml and driver.lua) at the top level")
        return problems, warnings
    xml_rel, lua_rel = names
    raw = files[xml_rel]

    # a. driver.xml starts directly with <devicedata>, no BOM, declaration or comment; it parses.
    if raw.startswith(BOM):
        fail("a", "driver.xml starts with a UTF-8 BOM")
    elif raw.startswith(b"<?xml"):
        fail("a", "driver.xml starts with an <?xml?> declaration; it must start with <devicedata>")
    elif not raw.startswith(b"<devicedata"):
        fail("a", f"driver.xml must start directly with <devicedata>, found {raw[:20]!r}")
    xml_bytes = raw if xml_override is None else xml_override
    root, version, modified = xml_facts(xml_bytes)
    if root is None:
        fail("a", "driver.xml does not parse as XML")
        return problems, warnings
    if root.tag != "devicedata":
        fail("a", f"root element is <{root.tag}>, expected <devicedata>")

    # b (integer part). The ordering part runs below.
    raw_version = (root.findtext("version") or "").strip()
    if version is None:
        fail("b", f"<version> is not an integer: {raw_version!r}")

    # c (presence part)
    if not modified:
        fail("c", "<modified> is missing or empty")

    script = script_name(xml_bytes)
    cur = layout(files, xml_rel, lua_rel, xml_bytes=xml_bytes)
    cur_sig = sig(cur)

    # b and c against git HEAD
    head = head_layout(path)
    if head is not None:
        _, head_v, head_mod = xml_facts(head["driver.xml"])
        changed_head = cur_sig != sig(head)
        if version_check and changed_head and version is not None and head_v is not None and version <= head_v:
            fail("b", f"source changed since HEAD, so <version> {version} must be greater than HEAD's {head_v}")
        if changed_head and modified and modified == head_mod:
            fail("c", f"source changed since HEAD but <modified> is still {modified}")

    # g. package file name
    expected = package_names().get(name, name) + ".c4z"
    present = sorted(os.listdir(DIST)) if os.path.isdir(DIST) else []
    pkg = None
    if expected in present:
        pkg = os.path.join(DIST, expected)
    else:
        ci = [p for p in present if p.lower() == expected.lower()]
        if ci:
            fail("g", f"package name is {expected} but c4z/ has {ci[0]}; Composer matches names case-sensitively")
        else:
            same = [p for p in present if norm(p[:-4]) == norm(name)]
            if same and name not in package_names():
                warn("g", f"no PACKAGE_NAMES entry for {name}, but c4z/{same[0]} exists for this driver; "
                          "add a mapping or Composer may see a second driver")
            elif same:
                warn("g", f"PACKAGE_NAMES expects {expected}, but c4z/{same[0]} is the existing package")

    # b (ordering against the built package), h (package contents)
    if pkg is not None:
        pkg_lay = package_layout(pkg)
        if pkg_lay is None:
            fail("h", f"c4z/{expected} is not a readable package (no driver.xml or script file)")
        else:
            _, pkg_v, _ = xml_facts(pkg_lay["driver.xml"])
            if version_check and version is not None and pkg_v is not None and cur_sig != sig(pkg_lay) and version <= pkg_v:
                fail("b", f"source differs from c4z/{expected} (version {pkg_v}), so <version> {version} must be greater")
            pkg_script = script_name(pkg_lay["driver.xml"])
            pkg_refs = image_refs(xml_facts(pkg_lay["driver.xml"])[0])
            for rel in pkg_lay:
                if rel in ("driver.xml", pkg_script) or rel.startswith(("www/", COMMON)) or rel in pkg_refs:
                    continue
                fail("h", f"c4z/{expected} contains {rel}, which is not driver.xml, driver.lua, www/ or a referenced icon")
            for ref in pkg_refs:
                if ref not in pkg_lay:
                    fail("h", f"c4z/{expected} lacks icon {ref} referenced by driver.xml")

    # h (source folder contents, and icon references)
    refs = image_refs(root)
    for rel in cur:
        if rel in ("driver.xml", script) or rel.startswith(("www/", COMMON)) or rel in refs:
            continue
        fail("h", f"{rel} would be packed but is not driver.xml, driver.lua, www/ or a referenced icon")
    for ref in refs:
        if ref not in cur:
            if "www/" + ref in cur:
                fail("h", f"driver.xml references image {ref}, but the file is packed as www/{ref}; fix the reference")
            else:
                fail("h", f"driver.xml references image {ref}, which is missing from the driver folder")
        elif not ref.startswith("www/"):
            warn("h", f"image {ref} is packed at its own path, not under www/")

    # d. Lua syntax
    lua_bytes = files[lua_rel]
    err = luac_error(lua_bytes, lua_rel)
    if err:
        fail("d", err)
    lua_text = strip_bom(lua_bytes).decode("utf-8", "replace")

    # e. OnDriverInit, and every action command handled in Lua
    if not ONINIT_RE.search(lua_text):
        fail("e", "Lua does not define OnDriverInit")
    commands = []
    for act in root.iter("action"):
        c = act.find("command")
        text = "".join(c.itertext()).strip() if c is not None else ""
        if not text:
            warn("e", "an <action> has no <command>")
        elif text not in commands:
            commands.append(text)
    if commands and not EXEC_RE.search(lua_text):
        fail("e", "driver.xml defines actions but the Lua defines no ExecuteCommand")
    for cmd in commands:
        if cmd == "LUA_ACTION":
            continue
        # Accept a quoted string or a bare identifier (e.g. a table key such as EC.ACTION_DISCOVER); a name that
        # appears nowhere in the Lua is reported.
        if not re.search(r'["\']' + re.escape(cmd) + r'["\']|\b' + re.escape(cmd) + r'\b', lua_text):
            fail("e", f"action command '{cmd}' never appears in the Lua (not handled in ExecuteCommand)")

    # f. Driver Version property matches the Lua constant and is written from Lua
    props = [p for p in root.iter("property") if (p.findtext("name") or "").strip() == "Driver Version"]
    if props:
        default = (props[0].findtext("default") or "").strip()
        m = DRIVER_CONST_RE.search(lua_text)
        if not m:
            fail("f", "Driver Version property exists but the Lua has no DRIVER_VERSION or VERSION string constant")
        elif m.group(1).strip() != default:
            fail("f", f"Driver Version <default> '{default}' differs from Lua constant '{m.group(1)}'")
        if not DRIVER_SET_RE.search(lua_text):
            fail("f", "Lua never sets the Driver Version property (no UpdateProperty/setProp call for it)")

    # j. Writes to the Properties table do not update the property shown in Composer
    for lineno, line in enumerate(lua_text.splitlines(), 1):
        if PROPERTIES_WRITE_RE.search(line):
            fail("j", f"{lua_rel}:{lineno} assigns to Properties[...]; use C4:UpdateProperty(name, value) instead")
            break

    return problems, warnings


def driver_path(arg):
    return arg if os.path.isdir(arg) else os.path.join(DRIVERS, arg)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Pre-flight checks for Control4 driver folders and their c4z packages.")
    ap.add_argument("folders", nargs="*", help="driver folder (path or name under drivers/)")
    ap.add_argument("--all", action="store_true", help="check every driver under drivers/")
    ap.add_argument("--no-version-check", action="store_true", help="skip the version ordering in check b")
    args = ap.parse_args(argv)
    if args.all:
        folders = sorted(d for d in os.listdir(DRIVERS) if os.path.isdir(os.path.join(DRIVERS, d)))
    else:
        folders = args.folders
    if not folders:
        ap.error("give a driver folder or --all")

    checked = failed = 0
    for arg in folders:
        path = driver_path(arg)
        name = os.path.basename(os.path.normpath(path))
        if not os.path.isdir(path):
            print(f"FAIL {arg} [file] no such driver folder")
            failed += 1
            continue
        _, files = load_source(path)
        if not has_driver_files(list(files)):
            print(f"skip {name}: no driver files")
            continue
        problems, warnings = check_folder(path, version_check=not args.no_version_check)
        checked += 1
        for line in warnings:
            print(line)
        if problems:
            failed += 1
            for line in problems:
                print(line)
        else:
            print(f"ok {name}")
    print(f"{checked} checked, {failed} with failures")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
