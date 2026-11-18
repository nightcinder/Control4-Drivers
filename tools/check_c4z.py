#!/usr/bin/env python3
"""Pre-flight checks for a Control4 driver source folder and its built package in c4z/.

Usage:
  python3 tools/check_c4z.py <driver-folder> [<driver-folder> ...]
  python3 tools/check_c4z.py --all [--no-version-check]

A driver folder is a path, or a name under drivers/. Each problem prints one line,
"FAIL <driver> [<check>] <reason>" (warnings start with "WARN"). The exit status is 1
when any check fails. The check IDs are described in docs/composer-update-notes.md
("Pre-flight"). --no-version-check skips the version ordering in check b; the integer
check still runs.
"""
import argparse
import difflib
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from io import BytesIO

from check_public import is_text, scan_text

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DRIVERS = os.path.join(ROOT, "drivers")
DIST = os.path.join(ROOT, "c4z")
COMMON = "drivers-common-public/"
BOM = b"\xef\xbb\xbf"
DRIVER_CONST_RE = re.compile(r'^\s*(?:local\s+)?(?:DRIVER_VERSION|VERSION)\s*=\s*["\']([^"\']*)["\']', re.M)
DRIVER_SET_RE = re.compile(r'(?:UpdateProperty|setProp)\s*\(\s*["\']Driver Version["\']')
ONINIT_RE = re.compile(r'function\s+OnDriverInit\s*\(|OnDriverInit\s*=\s*function')
EXEC_RE = re.compile(r'function\s+ExecuteCommand\s*\(')
COMMON_HANDLERS_RE = re.compile(r"\brequire\s*\(?\s*['\"]drivers-common-public\.global\.handlers['\"]")
SCRIPT_RE = re.compile(r'<script\s+file="([^"]+)"')
PROPERTIES_WRITE_RE = re.compile(r'\bProperties\s*\[[^\]]*\]\s*=(?!=)')
# Check g: version labels that must equal DRIVER_VERSION. Lines that look like history are skipped.
LUA_HEADER_VERSION_RE = re.compile(r'^\s*Version:\s*v?(\d+\.\d+\.\d+)', re.M | re.I)
LABEL_VERSION_RE = re.compile(r'\bversion\b[^\n<]{0,20}?v?(\d+\.\d+\.\d+)', re.I)
HISTORY_LINE_RE = re.compile(r'changelog|history|previous|since|\badds?\b|\bfixed\b|\b(?:19|20)\d\d\b', re.I)


def package_names():
    # build_c4z imports this module, so the import is done lazily to avoid a load-time cycle.
    import build_c4z
    return build_c4z.PACKAGE_NAMES


def strip_bom(data):
    return data[3:] if data.startswith(BOM) else data


def script_name(xml_bytes):
    m = SCRIPT_RE.search(xml_bytes.decode("utf-8", "replace"))
    return m.group(1) if m else "driver.lua"


def lua_code_lines(text):
    """Lua source split into lines, with comments and string contents blanked out (line numbers kept)."""
    out = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if text.startswith("--", i):
            m = re.match(r"--\[(=*)\[", text[i:])
            if m:
                close = "]" + m.group(1) + "]"
                end = text.find(close, i)
                end = n if end < 0 else end + len(close)
            else:
                end = text.find("\n", i)
                end = n if end < 0 else end
            out.append(re.sub(r"[^\n]", " ", text[i:end]))
            i = end
        elif ch in "\"'":
            j = i + 1
            while j < n and text[j] not in (ch, "\n"):
                j += 2 if text[j] == "\\" else 1
            j = min(j, n)
            closed = j < n and text[j] == ch
            out.append(ch + re.sub(r"[^\n]", " ", text[i + 1:j]) + (ch if closed else ""))
            i = j + 1 if closed else j
        else:
            out.append(ch)
            i += 1
    return "".join(out).splitlines()


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


def find_container(root, tag):
    """The first <tag> container in the XML: driver.xml puts it at the root or under <config>."""
    if root is None:
        return None
    if root.tag == tag:
        return root
    return next(root.iter(tag), None)


def commands_container(root):
    return find_container(root, "commands")


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


def package_layout_bytes(data):
    try:
        zf = zipfile.ZipFile(BytesIO(data))
    except zipfile.BadZipFile:
        return None
    with zf:
        files = {n: zf.read(n) for n in zf.namelist() if not n.endswith("/")}
    if "driver.xml" not in files:
        return None
    script = script_name(files["driver.xml"])
    if script not in files:
        return None
    return layout(files, "driver.xml", script)


def package_layout(pkg_path):
    with open(pkg_path, "rb") as fh:
        return package_layout_bytes(fh.read())


def head_package_layout(expected):
    """Package layout of c4z/<expected> at git HEAD, or None when it is not committed."""
    data = git_bytes(["show", "HEAD:c4z/" + expected])
    return package_layout_bytes(data) if data else None


def existing_package(name):
    """Path of c4z/<expected>.c4z when that exact file exists (case-sensitive), else None."""
    expected = package_names().get(name, name) + ".c4z"
    present = os.listdir(DIST) if os.path.isdir(DIST) else []
    return os.path.join(DIST, expected) if expected in present else None


def norm(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())


def luac_error(data, label, compiler="luac"):
    with tempfile.TemporaryDirectory() as td:
        p = os.path.join(td, "check.lua")
        with open(p, "wb") as fh:
            fh.write(strip_bom(data))
        try:
            r = subprocess.run([compiler, "-p", p], capture_output=True, text=True)
        except FileNotFoundError:
            return f"{compiler} is not on PATH, so the Lua syntax check could not run"
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

    # S001. the repository is public: no private addresses, personal paths or credentials in a driver folder.
    for rel, data in files.items():
        if not is_text(rel, data):
            continue
        for lineno, kind, text in scan_text(data.decode("utf-8", "replace")):
            fail("S001", f"{rel}:{lineno} {kind} ({text})")

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
                # Composer resolves c4z images relative to www/, so icons/x.png is packed as www/icons/x.png.
                packed = ref if ref.startswith("www/") else "www/" + ref
                if packed not in pkg_lay:
                    warn("h", f"c4z/{expected} lacks icon {ref} referenced by driver.xml (expected at {packed})")

    # i. the committed package must match the committed source. Compared at HEAD (not the working tree) so an
    # uncommitted edit can still be checked and built; a commit that changes the source without rebuilding fails.
    if xml_override is None and head is not None:
        head_pkg = head_package_layout(expected)
        if head_pkg is not None:
            if sig(head) != sig(head_pkg):
                fail("i", f"c4z/{expected} at HEAD does not match drivers/{name} at HEAD; rebuild and commit the package")
            src_v = xml_facts(head["driver.xml"])[1]
            pkg_v = xml_facts(head_pkg["driver.xml"])[1]
            if src_v is not None and pkg_v is not None and src_v != pkg_v:
                fail("i", f"c4z/{expected} at HEAD has <version> {pkg_v} but the source at HEAD has {src_v}; rebuild it")

    # h (source folder contents, and icon references)
    refs = image_refs(root)
    for rel in cur:
        if rel in ("driver.xml", script) or rel.startswith(("www/", COMMON)) or rel in refs:
            continue
        fail("h", f"{rel} would be packed but is not driver.xml, driver.lua, www/ or a referenced icon")
    for ref in refs:
        # Composer resolves c4z images relative to www/, so icons/x.png is satisfied by <folder>/www/icons/x.png.
        packed = ref if ref.startswith("www/") else "www/" + ref
        if packed in cur:
            continue
        if ref in cur:
            warn("h", f"image {ref} is packed at its own path, not under www/; Composer looks under www/")
        else:
            warn("h", f"driver.xml references image {ref}, which is missing from the driver folder (expected at {packed})")

    # d. Lua syntax: 5.4 for the shared toolchain, and 5.1 for the controller runtime when it is installed.
    lua_bytes = files[lua_rel]
    if lua_bytes.startswith(BOM):
        fail("d", f"{lua_rel} starts with a UTF-8 BOM; the controller's Lua 5.1 loader does not skip it")
    for compiler, required in (("luac", True), ("luac5.1", False)):
        err = luac_error(lua_bytes, lua_rel, compiler)
        if err and "is not on PATH" in err:
            if required:
                warn("d", err + "; Lua syntax was not checked")
        elif err:
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
    if commands and not (EXEC_RE.search(lua_text) or COMMON_HANDLERS_RE.search(lua_text)):
        warn("e", "driver.xml defines actions but the Lua defines no ExecuteCommand")
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
        elif not default:
            warn("f", f"Driver Version <default> is empty; set it to '{m.group(1)}' so Composer shows the version")
        elif m.group(1).strip() != default:
            fail("f", f"Driver Version <default> '{default}' differs from Lua constant '{m.group(1)}'")
        if not DRIVER_SET_RE.search(lua_text):
            fail("f", "Lua never sets the Driver Version property (no UpdateProperty/setProp call for it)")

    # g. Version labels agree with DRIVER_VERSION: the Lua "Version:" header comment, the XML <description>
    # (and <templatedescription>) and bundled www HTML. Lines that read as history are skipped.
    const = DRIVER_CONST_RE.search(lua_text)
    if const:
        expected_v = const.group(1).strip()

        def label_fail(where, found):
            fail("g", f"{where} says version {found} but DRIVER_VERSION is '{expected_v}' (found {found!r}, expected {expected_v!r})")

        for hm in LUA_HEADER_VERSION_RE.finditer(lua_text[:4000]):
            if hm.group(1) != expected_v:
                label_fail(f"{lua_rel} header comment", hm.group(1))
        if root is not None:
            for tag in ("description", "templatedescription"):
                for el in root.iter(tag):
                    for line in (el.text or "").splitlines():
                        if HISTORY_LINE_RE.search(line):
                            continue
                        for lm in LABEL_VERSION_RE.finditer(line):
                            if lm.group(1) != expected_v:
                                label_fail(f"{xml_rel} <{tag}>", lm.group(1))
        for rel, data in files.items():
            if rel.lower().endswith((".html", ".htm")):
                for line in data.decode("utf-8", "replace").splitlines():
                    if HISTORY_LINE_RE.search(line):
                        continue
                    for lm in LABEL_VERSION_RE.finditer(line):
                        if lm.group(1) != expected_v:
                            label_fail(rel, lm.group(1))

    # j. Writes to the Properties table do not update the property shown in Composer
    for lineno, line in enumerate(lua_code_lines(lua_text), 1):
        if PROPERTIES_WRITE_RE.search(line):
            fail("j", f"{lua_rel}:{lineno} assigns to Properties[...]; use C4:UpdateProperty(name, value) instead")
            break

    run_extra_checks(xml_rel, lua_rel, root, files, lua_text, fail, warn)

    return problems, warnings


# ---------------------------------------------------------------------------
# Extra checks. P = property XML, U = uniqueness, X = cross-references, L = Lua vs XML,
# H = referenced web pages, B = binding sanity. Each function reports through fail(id, msg) or warn(id, msg).
# ---------------------------------------------------------------------------
KNOWN_PROPERTY_TYPES = {
    "STRING", "INTEGER", "LONG", "FLOAT", "DOUBLE", "BOOL", "RANGED_INTEGER", "RANGED_FLOAT", "PASSWORD",
    "LIST", "DEVICE_SELECTOR", "COLOR_SELECTOR", "TRACK", "LABEL", "CUSTOM_SELECT",
}
NUMERIC_TYPES = {"INTEGER", "LONG", "FLOAT", "DOUBLE"}
NUMERIC_WRITE_TYPES = NUMERIC_TYPES | {"RANGED_INTEGER", "RANGED_FLOAT"}
LUA_BLOCK_COMMENT_RE = re.compile(r"--\[(=*)\[.*?\]\1\]", re.S)
PROP_READ_RE = re.compile(r"\bProperties\s*\[\s*([\"'])([^\"'\n]+)\1\s*\](?!\s*=(?!=))")
PROP_DOT_READ_RE = re.compile(r"\bProperties\.([A-Za-z_]\w*)\b(?!\s*=(?!=))")
PROP_DOT_WRITE_RE = re.compile(r"\bProperties\.([A-Za-z_]\w*)\s*=(?!=)")
UPDATE_PROP_RE = re.compile(r"C4:UpdateProperty\s*\(\s*(['\"])([^'\"\n]+)\1")
UPDATE_PROP_STRING_RE = re.compile(r"C4:UpdateProperty\s*\(\s*(['\"])([^'\"\n]+)\1\s*,\s*(['\"])([^'\"]*)\3")
UPDATE_PROP_TOSTRING_RE = re.compile(r"C4:UpdateProperty\s*\(\s*(['\"])([^'\"\n]+)\1\s*,\s*tostring\s*\(")
UPDATE_PROP_LIST_RE = re.compile(r"C4:UpdatePropertyList\s*\(\s*(['\"])([^'\"\n]+)\1")
UPDATE_PROP_LIST_TABLE_RE = re.compile(r"C4:UpdatePropertyList\s*\(\s*(['\"])([^'\"\n]+)\1\s*,\s*\{")
FIRE_EVENT_RE = re.compile(r"C4:FireEvent\s*\(\s*(['\"])([^'\"\n]+)\1")
LOCAL_HANDLER_RE = re.compile(
    r"\blocal\s+function\s+(ExecuteCommand|OnPropertyChanged|OnDriverLateInit|OnDriverInit|OnTimerExpired)\b"
    r"|\blocal\s+(ExecuteCommand|OnPropertyChanged|OnDriverLateInit|OnDriverInit|OnTimerExpired)\s*="
)
HTML_REF_RE = re.compile(r"(?<![\w:/.\\-])([\w\-./]+\.html?)\b", re.I)


def lua_no_comments(text):
    """Lua source with comments removed and string contents kept (line numbers kept)."""
    text = LUA_BLOCK_COMMENT_RE.sub(lambda m: "\n" * m.group(0).count("\n"), text)
    return "\n".join(re.sub(r"--(?!\[=*\[).*$", "", line) for line in text.splitlines())


def _child_text(el, tag):
    c = el.find(tag)
    return None if c is None else (c.text or "").strip()


def _num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def check_property_xml(root, xml_rel, fail, warn):
    """P001: name and known type. P002: the children each type needs, and a default that fits them."""
    for p in root.iter("property"):
        pname = _child_text(p, "name")
        if not pname:
            fail("P001", f"{xml_rel} has a <property> with no <name>")
            continue
        where = f"{xml_rel} property '{pname}'"
        ptype = _child_text(p, "type")
        if not ptype:
            fail("P001", f"{where} has no <type>")
            continue
        if ptype not in KNOWN_PROPERTY_TYPES:
            warn("P001", f"{where} has unknown <type> {ptype}")
            continue
        items = [(i.text or "").strip() for i in p.findall("items/item")]
        items = [i for i in items if i]
        default = _child_text(p, "default") or ""
        if ptype == "LIST":
            if not items:
                fail("P002", f"{where} is a LIST with no <items>/<item>")
            elif default and default not in items:
                fail("P002", f"{where} default '{default}' is not one of its <items>")
        elif ptype == "DEVICE_SELECTOR":
            if not items:
                fail("P002", f"{where} is a DEVICE_SELECTOR with no <items>/<item> "
                             "(Composer reports 'Error creating property')")
            for it in items:
                if not it.endswith(".c4i"):
                    fail("P002", f"{where} item '{it}' does not end in .c4i")
            multi = (_child_text(p, "multiselect") or "").lower()
            if multi not in ("true", "false"):
                fail("P002", f"{where} needs <multiselect> true or false, found '{multi or 'none'}'")
        elif ptype in NUMERIC_TYPES and (_child_text(p, "minimum") is None or _child_text(p, "maximum") is None):
            fail("P003", f"{where} is a plain {ptype} with no <minimum>/<maximum>; Composer can fail with "
                         "'Error creating property'. Use RANGED_INTEGER (integers) or RANGED_FLOAT (decimals) "
                         "with <minimum> and <maximum>")
        elif ptype in ("RANGED_INTEGER", "RANGED_FLOAT"):
            lo = _num(_child_text(p, "minimum"))
            hi = _num(_child_text(p, "maximum"))
            if lo is None or hi is None:
                fail("P002", f"{where} needs numeric <minimum> and <maximum>")
            elif lo > hi:
                fail("P002", f"{where} has <minimum> {lo:g} above <maximum> {hi:g}")
            if default:
                dv = _num(default)
                if dv is None:
                    fail("P002", f"{where} default '{default}' is not a number")
                elif lo is not None and hi is not None and not lo <= dv <= hi:
                    fail("P002", f"{where} default {default} is outside {lo:g}..{hi:g}")
        elif ptype in NUMERIC_TYPES and default and _num(default) is None:
            fail("P002", f"{where} default '{default}' is not a number")


def check_unique(root, xml_rel, fail):
    """U001: names and ids must be unique within the driver."""
    commands = commands_container(root)
    events = find_container(root, "events")
    groups = {
        "property name": [_child_text(p, "name") for p in root.iter("property")],
        "command name": [_child_text(c, "name") for c in (commands.findall("command") if commands is not None else [])],
        "command id": [_child_text(c, "id") for c in (commands.findall("command") if commands is not None else [])],
        "event name": [_child_text(e, "name") for e in (events.findall("event") if events is not None else [])],
        "event id": [_child_text(e, "id") for e in (events.findall("event") if events is not None else [])],
        "action name": [_child_text(a, "name") for a in root.findall("actions/action")],
        "connection id": [_child_text(c, "id") for c in root.iter("connection")],
        "connection name": [_child_text(c, "connectionname") for c in root.iter("connection")],
        "proxy binding id": [p.get("proxybindingid") for p in root.iter("proxy")],
    }
    for what, values in groups.items():
        counts = {}
        for v in values:
            if v:
                counts[v] = counts.get(v, 0) + 1
        for v, n in counts.items():
            if n > 1:
                fail("U001", f"{xml_rel} has {n} {what}s with value '{v}'")


def check_cross_refs(root, xml_rel, lua_text, fail):
    """X001: proxy bindings need a type-2 connection. X002: connection type 1-7. X003: classname present.
    X004: C4:FireEvent names must be events in the XML."""
    conns = {}
    for c in root.iter("connection"):
        cid = _child_text(c, "id")
        conns.setdefault(cid, c)
        cname = _child_text(c, "connectionname") or cid
        ctype = _child_text(c, "type")
        if ctype is None or not ctype.isdigit() or not 1 <= int(ctype) <= 7:
            fail("X002", f"{xml_rel} connection '{cname}' has <type> '{ctype or ''}'; it must be a number 1-7")
        for cl in c.findall("classes/class"):
            if not _child_text(cl, "classname"):
                fail("X003", f"{xml_rel} connection '{cname}' has a <class> with no <classname>")
    for p in root.iter("proxy"):
        pid = p.get("proxybindingid")
        c = conns.get(pid)
        if c is None or _child_text(c, "type") != "2":
            fail("X001", f"{xml_rel} <proxy proxybindingid='{pid}'> has no connection with <id> {pid} and <type> 2")
    events = {_child_text(e, "name") for e in root.findall("events/event")}
    for lineno, line in enumerate(lua_no_comments(lua_text).splitlines(), 1):
        for m in FIRE_EVENT_RE.finditer(line):
            if m.group(2) not in events:
                fail("X004", f"Lua line {lineno} fires event '{m.group(2)}', which is not an <event> in {xml_rel}")


def check_lua_vs_xml(root, xml_rel, lua_rel, lua_text, fail, warn):
    """L001: Properties assignments are errors. L002: Properties reads and L003: UpdateProperty names must be
    XML properties. L004: handlers that the XML needs. L005: handlers defined as local."""
    code = lua_no_comments(lua_text)
    props = {_child_text(p, "name") for p in root.iter("property")}
    props.discard(None)
    prop_types = {_child_text(p, "name"): (_child_text(p, "type") or "").upper() for p in root.iter("property")}
    lines = code.splitlines()
    for lineno, line in enumerate(lines, 1):
        for m in PROP_DOT_WRITE_RE.finditer(line):
            fail("L001", f"{lua_rel}:{lineno} assigns Properties.{m.group(1)}; use C4:UpdateProperty instead")
        for m in PROP_READ_RE.finditer(line):
            if m.group(2) not in props:
                fail("L002", f"{lua_rel}:{lineno} reads Properties['{m.group(2)}'], which is not a property in {xml_rel}")
        for m in PROP_DOT_READ_RE.finditer(line):
            if m.group(1) not in props:
                fail("L002", f"{lua_rel}:{lineno} reads Properties.{m.group(1)}, which is not a property in {xml_rel}")
        for m in UPDATE_PROP_RE.finditer(line):
            if m.group(2) not in props:
                fail("L003", f"{lua_rel}:{lineno} calls C4:UpdateProperty('{m.group(2)}'), "
                             f"which is not a property in {xml_rel}")
        for m in UPDATE_PROP_STRING_RE.finditer(line):
            if prop_types.get(m.group(2)) in NUMERIC_WRITE_TYPES:
                fail("L012", f"{lua_rel}:{lineno} writes the string {m.group(4)!r} to numeric property "
                             f"'{m.group(2)}' ({prop_types[m.group(2)]}); write a number")
        for m in UPDATE_PROP_TOSTRING_RE.finditer(line):
            if prop_types.get(m.group(2)) in NUMERIC_WRITE_TYPES:
                fail("L012", f"{lua_rel}:{lineno} writes tostring(...) to numeric property '{m.group(2)}' "
                             f"({prop_types[m.group(2)]}); write a number")
        for m in UPDATE_PROP_LIST_RE.finditer(line):
            if m.group(2) not in props:
                fail("L003", f"{lua_rel}:{lineno} calls C4:UpdatePropertyList('{m.group(2)}'), "
                             f"which is not a property in {xml_rel}")
        for m in UPDATE_PROP_LIST_TABLE_RE.finditer(line):
            fail("L011", f"{lua_rel}:{lineno} passes a table to C4:UpdatePropertyList('{m.group(2)}'); "
                         "the controller requires a comma-separated string")

    def defined(fn):
        return re.search(r"\bfunction\s+%s\s*\(|\b%s\s*=\s*function\b" % (fn, fn), code) is not None

    # The public common library supplies the entry points when a driver requires its handlers module.
    common_handlers = COMMON_HANDLERS_RE.search(code) is not None
    commands = commands_container(root)
    if commands is not None and commands.findall("command") and not (defined("ExecuteCommand") or common_handlers):
        fail("L004", f"{xml_rel} defines commands but {lua_rel} defines no ExecuteCommand")
    if props and not (defined("OnPropertyChanged") or defined("OnDriverLateInit") or common_handlers):
        fail("L004", f"{xml_rel} defines properties but {lua_rel} defines neither OnPropertyChanged nor OnDriverLateInit")
    for m in LOCAL_HANDLER_RE.finditer(code):
        fn = m.group(1) or m.group(2)
        warn("L005", f"{lua_rel} defines {fn} as local; Composer calls it as a global, so make it global")


def check_html_refs(root, xml_rel, lua_rel, lua_text, files, fail):
    """H001: an .html page named in driver.xml or the Lua must be in the package (at the path or under www/)."""
    sources = [(xml_rel, files[xml_rel].decode("utf-8", "replace")), (lua_rel, lua_no_comments(lua_text))]
    for src, text in sources:
        for m in HTML_REF_RE.finditer(text):
            ref = m.group(1).lstrip("./")
            if ref.lower().startswith("www/"):
                ref = ref[4:]
            if ref in files or ("www/" + ref) in files:
                continue
            fail("H001", f"{src} references page '{ref}', which is not in the driver folder (expected at www/{ref})")


def check_binding(root, xml_rel, warn):
    """B001: a dimmer's LIGHT_V2 is a proxy binding. A consumer LIGHT_V2 connection of type 1 is probably a mistake."""
    for c in root.iter("connection"):
        if (_child_text(c, "consumer") or "").lower() != "true" or _child_text(c, "type") != "1":
            continue
        classes = [_child_text(cl, "classname") for cl in c.findall("classes/class")]
        if "LIGHT_V2" in classes:
            cname = _child_text(c, "connectionname") or _child_text(c, "id")
            warn("B001", f"{xml_rel} connection '{cname}' is a consumer of LIGHT_V2 with <type>1>; "
                         "a dimmer exposes LIGHT_V2 as a proxy binding, or use a DEVICE_SELECTOR property")


NAME_TOKEN_RE = re.compile(r"\bNAME\b")
PARAM_TOKEN_RE = re.compile(r"\bPARAM(\d+)\b")
GLUED_TOKEN_RE = re.compile(r"[A-Za-z0-9_](?:NAME|PARAM\d+)|(?:NAME|PARAM\d+)[A-Za-z0-9_]")


def check_command_descriptions(root, xml_rel, fail):
    """CD001: every <command> under <commands> needs a <description> that uses NAME exactly once and
    PARAM1..PARAMn exactly once each (n = number of <param> elements). Composer fills these in the programming line."""
    commands = commands_container(root)
    if commands is None:
        return
    for cmd in commands.findall("command"):
        cname = (cmd.findtext("name") or "").strip() or "(no name)"
        where = f"{xml_rel} command '{cname}'"
        desc = (cmd.findtext("description") or "").strip()
        if not desc:
            fail("CD001", f"{where} has no <description>, or it is empty")
            continue
        glued = sorted(set(GLUED_TOKEN_RE.findall(desc)))
        if glued:
            fail("CD001", f"{where} glues a token to other text ({', '.join(repr(g) for g in glued)}); "
                          "PARAMn and NAME must be separate words")
        name_count = len(NAME_TOKEN_RE.findall(desc))
        if name_count != 1:
            fail("CD001", f"{where} uses NAME {name_count} times; it must use NAME exactly once")
        nparams = len(cmd.findall("params/param"))
        found = {}
        for tok in PARAM_TOKEN_RE.findall(desc):
            found[tok] = found.get(tok, 0) + 1
        expected = [str(k) for k in range(1, nparams + 1)]
        missing = [f"PARAM{k}" for k in expected if k not in found]
        repeated = [f"PARAM{k}" for k, v in found.items() if v > 1]
        extra = [f"PARAM{k}" for k in found if k not in expected]
        if not (missing or repeated or extra):
            continue
        if nparams:
            span = "PARAM1" if nparams == 1 else f"PARAM1..PARAM{nparams}"
            rule = f"has {nparams} param(s), so {span} must each appear once in the description"
        else:
            rule = "has no params, so the description must not use any PARAM token"
        detail = []
        if missing:
            detail.append("missing " + ", ".join(missing))
        if repeated:
            detail.append("repeated " + ", ".join(repeated))
        if extra:
            detail.append("unexpected " + ", ".join(extra))
        fail("CD001", f"{where} {rule}; " + "; ".join(detail))


LUA51_RULES = [
    ("goto", re.compile(r"\bgoto\b"), "goto is Lua 5.2+"),
    ("a ::label::", re.compile(r"::[A-Za-z_]\w*::"), "labels are Lua 5.2+"),
    ("//", re.compile(r"(?<![/*])//(?![/*])"), "integer division is Lua 5.3+"),
    ("a bitwise operator", re.compile(r"(?<![&])&(?![&])|(?<![|])\|(?![|])|(?<![~])~(?!=)|<<|>>"),
     "bitwise operators are Lua 5.3+"),
    ("table.unpack", re.compile(r"\btable\.unpack\b"), "table.unpack is Lua 5.2+; use unpack"),
    ("math.type or math.tointeger", re.compile(r"\bmath\.(?:type|tointeger)\b"), "these are Lua 5.3+"),
    ("utf8.*", re.compile(r"\butf8\s*\."), "the utf8 library is Lua 5.3+"),
    ("_ENV", re.compile(r"\b_ENV\b"), "_ENV is Lua 5.2+"),
    ("rawlen", re.compile(r"\brawlen\b"), "rawlen is Lua 5.2+"),
]
LUA_SANDBOX_RULES = [
    ("io.*", re.compile(r"\bio\s*\.")),
    ("os.execute/exit/remove/rename/tmpname/setlocale",
     re.compile(r"\bos\s*\.\s*(?:execute|exit|remove|rename|tmpname|setlocale)\b")),
    ("dofile", re.compile(r"\bdofile\b")),
    ("loadfile", re.compile(r"\bloadfile\b")),
    ("loadstring", re.compile(r"\bloadstring\b")),
    ("load()", re.compile(r"(?<![\w.])load\s*\(")),
    ("debug.*", re.compile(r"\bdebug\s*\.")),
    ("package.*", re.compile(r"\bpackage\s*\.")),
]
REQUIRE_MODULE_RE = re.compile(r"\brequire\s*\(?\s*['\"]([^'\"\n]+)['\"]")
GLOBAL_FUNC_RE = re.compile(r"^\s*function\s+([A-Za-z_]\w*)\s*\(", re.M)
C4_CALL_RE = re.compile(r"\bC4\s*[:.]\s*([A-Za-z_]\w*)")
LUA_TIMER_RE = re.compile(
    r"\bC4\s*[:.]\s*(?:SetTimer|AddTimer|CreateServer|CreateNetworkConnection|CreateTCPClient|NetConnect)\b")
DESTROY_RE = re.compile(r"\bfunction\s+OnDriverDestroyed\s*\(|\bOnDriverDestroyed\s*=\s*function\b")
ADD_TIMER_4ARG_RE = re.compile(r"\bC4\s*[:.]\s*AddTimer\s*\([^)\n]*,\s*(['\"])[^'\"\n]+\1\s*\)")
ON_TIMER_EXPIRED_RE = re.compile(r"\bfunction\s+OnTimerExpired\s*\(|\bOnTimerExpired\s*=\s*function\b")
NET_CLIENT_RE = re.compile(r"\bC4\s*[:.]\s*(?:CreateNetworkConnection|NetConnect)\b")
NET_DISCONNECT_RE = re.compile(r"\bC4\s*[:.]\s*NetDisconnect\b")
SERVER_CREATE_RE = re.compile(r"\bC4\s*[:.]\s*CreateServer\b")
SERVER_DESTROY_RE = re.compile(r"\bC4\s*[:.]\s*DestroyServer\b")
# DriverWorks methods a driver may call. An unknown name warns; a near-miss of a known name fails as a typo.
KNOWN_C4_METHODS = {
    "AddDevice", "AddTimer", "AddVariable", "Base64Decode", "Base64Encode", "Bind", "CreateNetworkConnection",
    "CreateServer", "CreateTCPClient", "DebugLog", "DestroyServer", "ErrorLog", "FireEvent", "FireEventByID",
    "GetBoundConsumerDevices", "GetBoundProviderDevice", "GetControllerNetworkAddress", "GetDeviceDisplayName",
    "GetDeviceID", "GetDeviceVariable", "GetDeviceVariables", "GetDevices", "GetDevicesByC4iName", "GetTime",
    "JsonDecode", "JsonEncode", "KillAllTimers", "KillTimer", "NetConnect", "NetDisconnect", "ParseXml",
    "PersistGetValue", "PersistSetValue", "RegisterVariableListener", "RoomGetId", "SendDataToUI", "SendToDevice",
    "SendToNetwork", "SendToProxy", "ServerCloseClient", "ServerSend", "SetTimer", "SetVariable",
    "UnregisterVariableListener", "UpdateProperty", "UpdatePropertyList", "url", "urlDo", "urlGet", "urlPost",
    "urlPut", "urlSetTimeout",
}
PARAM_TYPES = {
    "STRING", "NUMBER", "BOOL", "BOOLEAN", "INTEGER", "FLOAT", "DOUBLE", "LONG", "RANGED_INTEGER",
    "RANGED_FLOAT", "LIST", "DEVICE_SELECTOR", "COLOR_SELECTOR",
}


def check_lua51(lua_rel, lua_text, fail):
    """L006: constructs the Lua 5.4 interpreter accepts but a Control4 driver's Lua 5.1 runtime does not."""
    lines = lua_code_lines(lua_text)
    for label, rx, why in LUA51_RULES:
        for lineno, line in enumerate(lines, 1):
            if rx.search(line):
                fail("L006", f"{lua_rel}:{lineno} uses {label}; {why}, and drivers run on Lua 5.1")
                break


def check_lua_sandbox(lua_rel, lua_text, fail):
    """L007: host APIs the DriverWorks sandbox does not provide, and requires outside the public library."""
    code_lines = lua_code_lines(lua_text)
    for label, rx in LUA_SANDBOX_RULES:
        for lineno, line in enumerate(code_lines, 1):
            if rx.search(line):
                fail("L007", f"{lua_rel}:{lineno} uses {label}, which is not available in the Control4 driver sandbox")
                break
    # Requires keep their module name in a string, so this pass removes comments but not strings.
    for lineno, line in enumerate(lua_no_comments(lua_text).splitlines(), 1):
        for m in REQUIRE_MODULE_RE.finditer(line):
            module = m.group(1)
            if not module.startswith("drivers-common-public."):
                fail("L007", f"{lua_rel}:{lineno} requires '{module}'; only drivers-common-public modules are available")


def check_duplicate_functions(lua_rel, lua_text, fail):
    """L008: a second global definition silently replaces the first."""
    code = "\n".join(lua_code_lines(lua_text))
    found = {}
    for m in GLOBAL_FUNC_RE.finditer(code):
        found.setdefault(m.group(1), []).append(code[:m.start()].count("\n") + 1)
    for name, linenos in found.items():
        if len(linenos) > 1:
            where = ", ".join(str(n) for n in linenos)
            fail("L008", f"{lua_rel} defines global function {name} {len(linenos)} times (lines {where}); "
                         "the last definition wins silently")


def check_c4_methods(lua_rel, lua_text, fail, warn):
    """L009: typo detection for C4:<method> calls. A near-miss of a known method is an error; anything else warns."""
    warned = set()
    for lineno, line in enumerate(lua_code_lines(lua_text), 1):
        for m in C4_CALL_RE.finditer(line):
            name = m.group(1)
            if name in KNOWN_C4_METHODS:
                continue
            close = difflib.get_close_matches(name, KNOWN_C4_METHODS, n=1, cutoff=0.8)
            if close:
                fail("L009", f"{lua_rel}:{lineno} calls C4:{name}, which is not a DriverWorks method "
                             f"(did you mean C4:{close[0]}?)")
            elif name not in warned:
                warned.add(name)
                warn("L009", f"{lua_rel}:{lineno} calls C4:{name}, which is not in the known DriverWorks method list")


def check_destroy(lua_rel, lua_text, fail):
    """L010: a driver that starts timers or network connections must cancel them in OnDriverDestroyed."""
    code = "\n".join(lua_code_lines(lua_text))
    if LUA_TIMER_RE.search(code) and not DESTROY_RE.search(code):
        fail("L010", f"{lua_rel} starts timers or network connections but defines no OnDriverDestroyed to stop them")
    if NET_CLIENT_RE.search(code) and not NET_DISCONNECT_RE.search(code):
        fail("L016", f"{lua_rel} opens a network connection but never calls C4:NetDisconnect")
    if SERVER_CREATE_RE.search(code) and not SERVER_DESTROY_RE.search(code):
        fail("L016", f"{lua_rel} creates a server but never calls C4:DestroyServer")


def check_timers(lua_rel, lua_text, fail):
    """L014: C4:AddTimer takes (interval, units, repeating), not a handler name.
    L015: AddTimer fires the global OnTimerExpired(id), so it must exist."""
    code = "\n".join(lua_code_lines(lua_text))
    m = ADD_TIMER_4ARG_RE.search(code)
    if m:
        fail("L014", f"{lua_rel} passes a 4th argument to C4:AddTimer; Control4 ignores it and calls "
                     "OnTimerExpired(id) instead")
    if re.search(r"\bC4\s*[:.]\s*AddTimer\b", code) and not ON_TIMER_EXPIRED_RE.search(code):
        fail("L015", f"{lua_rel} uses C4:AddTimer but defines no OnTimerExpired, so its timers never run")


def command_key(name):
    """Command names are matched after removing punctuation and case; Composer and drivers do the same."""
    return re.sub(r"[^A-Za-z0-9]", "", name).upper()


def check_command_handlers(root, xml_rel, lua_rel, lua_text, fail):
    """E002: every command in driver.xml must appear in the Lua, or nothing handles it."""
    commands = commands_container(root)
    if commands is None:
        return
    code = lua_no_comments(lua_text)
    if COMMON_HANDLERS_RE.search(code):
        return
    normalized = command_key(code)
    for cmd in commands.findall("command"):
        name = (cmd.findtext("name") or "").strip()
        if not name or name == "LUA_ACTION":
            continue
        key = command_key(name)
        if key and key not in normalized:
            fail("E002", f"{xml_rel} command '{name}' does not appear in {lua_rel}; Composer would send a command "
                         "nothing handles")


def check_params(root, xml_rel, fail, warn):
    """E001: every command and event parameter has a name, a type, and a name that is unique in its parent."""
    for container_tag, item_tag in (("commands", "command"), ("events", "event")):
        container = find_container(root, container_tag)
        if container is None:
            continue
        for item in container.findall(item_tag):
            iname = _child_text(item, "name") or "(no name)"
            where = f"{xml_rel} {item_tag} '{iname}'"
            params = item.findall("params/param") or item.findall("param")
            seen = set()
            for prm in params:
                pname = _child_text(prm, "name")
                ptype = _child_text(prm, "type")
                if not pname:
                    fail("E001", f"{where} has a <param> with no <name>")
                elif pname in seen:
                    fail("E001", f"{where} has two params named '{pname}'")
                else:
                    seen.add(pname)
                if not ptype:
                    fail("E001", f"{where} param '{pname or '?'}' has no <type>; Composer cannot render it")
                elif ptype.upper() not in PARAM_TYPES:
                    warn("E001", f"{where} param '{pname or '?'}' has unknown <type> {ptype}")


def run_extra_checks(xml_rel, lua_rel, root, files, lua_text, fail, warn):
    check_property_xml(root, xml_rel, fail, warn)
    check_command_descriptions(root, xml_rel, fail)
    check_unique(root, xml_rel, fail)
    check_cross_refs(root, xml_rel, lua_text, fail)
    check_lua_vs_xml(root, xml_rel, lua_rel, lua_text, fail, warn)
    check_html_refs(root, xml_rel, lua_rel, lua_text, files, fail)
    check_binding(root, xml_rel, warn)
    check_params(root, xml_rel, fail, warn)
    check_command_handlers(root, xml_rel, lua_rel, lua_text, fail)
    check_lua51(lua_rel, lua_text, fail)
    check_lua_sandbox(lua_rel, lua_text, fail)
    check_duplicate_functions(lua_rel, lua_text, fail)
    check_c4_methods(lua_rel, lua_text, fail, warn)
    check_destroy(lua_rel, lua_text, fail)
    check_timers(lua_rel, lua_text, fail)


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
