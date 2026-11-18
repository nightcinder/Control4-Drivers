#!/usr/bin/env python3
"""c4sim runner.

  python tools/c4sim/run.py smoke [dir|all]
  python tools/c4sim/run.py commands [dir|all]
  python tools/c4sim/run.py props [dir|all]
  python tools/c4sim/run.py test [name|all]
"""
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
LUA_WIN = os.path.expanduser(r"~\AppData\Local\Microsoft\WinGet\Links\lua.exe")


def find_lua():
    override = os.environ.get("C4SIM_LUA")
    if override:
        return override
    p = shutil.which("lua") or (LUA_WIN if os.path.exists(LUA_WIN) else None)
    if not p:
        sys.exit("ERR lua interpreter not found")
    return p


def lua_env():
    env = dict(os.environ)
    path = os.path.join(HERE, "?.lua") + ";;"
    env["LUA_PATH"] = path
    env["LUA_PATH_5_4"] = path
    return env


def pick_lua(dpath, dname, luas):
    for cand in (dname + ".lua", "driver.lua", "main.lua"):
        if cand in luas:
            return luas[cand]
    if len(luas) == 1:
        return list(luas.values())[0]
    return None


def drivers(which):
    base = os.path.join(ROOT, "drivers")
    specs, missing = [], []
    for dname in sorted(os.listdir(base)):
        dpath = os.path.join(base, dname)
        if not os.path.isdir(dpath):
            continue
        if which != "all" and dname != which:
            continue
        luas = {}
        for f in glob.glob(os.path.join(dpath, "*.lua")):
            b = os.path.basename(f)
            if "test" not in b.lower():
                luas[b] = f
        xmls = sorted(glob.glob(os.path.join(dpath, "*driver.xml")))
        lua = pick_lua(dpath, dname, luas)
        if lua is None or not xmls:
            if which != "all":
                missing.append(dname)
            continue
        specs.append("%s|%s|%s" % (dname, lua, xmls[0]))
    return specs, missing


def run_smoke(which):
    specs, missing = drivers(which)
    for m in missing:
        print("ERR %s: no driver lua or driver.xml found" % m)
    if not specs and not missing:
        print("ERR no drivers matched '%s'" % which)
        return 1
    if not specs:
        return 1
    r = subprocess.run([find_lua(), os.path.join(HERE, "smoke.lua")] + specs,
                       cwd=ROOT, env=lua_env(), capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    if r.returncode != 0 and r.stderr.strip():
        print("ERR smoke runner: " + r.stderr.strip().splitlines()[0])
    return 1 if (missing or r.returncode != 0) else 0


def run_tests(which):
    files = sorted(glob.glob(os.path.join(HERE, "tests", "*_test.lua")))
    if which != "all":
        files = [f for f in files if os.path.basename(f) == which + "_test.lua"]
    if not files:
        print("ERR no tests matched '%s'" % which)
        return 1
    rc = 0
    lua = find_lua()
    for f in files:
        r = subprocess.run([lua, f], cwd=ROOT, env=lua_env(),
                           capture_output=True, text=True)
        sys.stdout.write(r.stdout)
        if r.returncode != 0:
            rc = 1
            err = (r.stderr or "").strip().splitlines()
            if err and not r.stdout.strip():
                print("ERR %s: %s" % (os.path.basename(f), err[0]))
    return rc


NUMERIC_PARAM_TYPES = {
    "NUMBER", "INTEGER", "LONG", "FLOAT", "DOUBLE", "RANGED_INTEGER", "RANGED_FLOAT",
}


def command_specs(xmlpath):
    """(name, [Lua argument literals]) for every command in driver.xml, in either XML layout."""
    try:
        root = ET.parse(xmlpath).getroot()
    except (ET.ParseError, OSError):
        return []
    container = root if root.tag == "commands" else next(root.iter("commands"), None)
    if container is None:
        return []
    out = []
    for cmd in container.findall("command"):
        name = (cmd.findtext("name") or "").strip()
        if not name or name == "LUA_ACTION":
            continue
        args = []
        for prm in cmd.findall("params/param") or cmd.findall("param"):
            ptype = (prm.findtext("type") or "STRING").strip().upper()
            if ptype in NUMERIC_PARAM_TYPES:
                args.append("1")
            elif ptype in ("BOOL", "BOOLEAN"):
                args.append("true")
            else:
                args.append('"x"')
        out.append((name, args))
    return out


def command_script(name, luapath, xmlpath, commands):
    lines = [
        'local sim = require("c4sim")',
        'sim.load_driver(%s, {xml = %s})' % (json.dumps(luapath), json.dumps(xmlpath)),
        'if type(sim.env.ExecuteCommand) ~= "function" then',
        '  print("skip %s: ExecuteCommand is supplied by the common library")' % name,
        '  os.exit(0)',
        'end',
        'if #sim.errors > 0 then print("ERR %s load: " .. sim.errors[1]); os.exit(1) end' % name,
    ]
    for cname, args in commands:
        lines.append('sim.exec(%s, {%s})' % (json.dumps(cname), ", ".join(args)))
        lines.append('if #sim.errors > 0 then print("ERR %s " .. %s .. ": " .. sim.errors[#sim.errors]); '
                     'os.exit(1) end' % (name, json.dumps(cname)))
    lines.append('print("ok %s %d")' % (name, len(commands)))
    return "\n".join(lines)


def run_commands(which):
    """Call every command defined in driver.xml with typed dummy parameters; fail on an uncaught error."""
    specs, missing = drivers(which)
    for m in missing:
        print("ERR %s: no driver lua or driver.xml found" % m)
    if not specs and not missing:
        print("ERR no drivers matched '%s'" % which)
        return 1
    if not specs:
        return 1
    lua = find_lua()
    rc = 0
    for spec in specs:
        dname, luapath, xmlpath = spec.split("|", 2)
        commands = command_specs(xmlpath)
        if not commands:
            print("ok %s 0 commands" % dname)
            continue
        script = command_script(dname, luapath, xmlpath, commands)
        fd, path = tempfile.mkstemp(prefix="c4cmd_", suffix=".lua")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(script)
            r = subprocess.run([lua, path], cwd=ROOT, env=lua_env(), capture_output=True, text=True)
        finally:
            os.unlink(path)
        out = (r.stdout or "").strip().splitlines()
        print(out[-1] if out else "ERR %s: no output" % dname)
        if r.returncode != 0 or not out or not out[-1].startswith(("ok ", "skip ")):
            rc = 1
    return rc


def property_specs(xmlpath, mode):
    """(name, Lua literal) for each property, using an alternate or empty string value."""
    try:
        root = ET.parse(xmlpath).getroot()
    except (ET.ParseError, OSError):
        return []
    out = []
    for prop in root.iter("property"):
        name = (prop.findtext("name") or "").strip()
        ptype = (prop.findtext("type") or "STRING").strip().upper()
        default = (prop.findtext("default") or "").strip()
        if not name or name == "Driver Version":
            continue
        value = None
        if ptype in ("STRING", "PASSWORD"):
            value = '""' if mode == "empty" else json.dumps("x" if default != "x" else "y")
        elif ptype == "LIST":
            items = [(i.text or "").strip() for i in prop.findall("items/item")]
            items = [i for i in items if i]
            if items:
                value = json.dumps(items[1] if len(items) > 1 else items[0])
        elif ptype in NUMERIC_PARAM_TYPES:
            lo = prop.findtext("minimum")
            hi = prop.findtext("maximum")
            if lo is not None and (default == "" or float(lo) != float(default)):
                value = str(int(float(lo))) if ptype not in ("RANGED_FLOAT", "FLOAT", "DOUBLE") \
                    else str(float(lo))
            elif hi is not None:
                value = str(int(float(hi))) if ptype not in ("RANGED_FLOAT", "FLOAT", "DOUBLE") \
                    else str(float(hi))
            elif ptype in ("RANGED_FLOAT", "FLOAT", "DOUBLE"):
                value = "1.5"
            else:
                value = "1"
        elif ptype in ("BOOL", "BOOLEAN"):
            value = '"false"' if default.lower() in ("true", "yes", "on") else '"true"'
        if value is not None:
            out.append((name, value))
    return out


def property_script(name, luapath, xmlpath, specs, mode):
    lines = [
        'local sim = require("c4sim")',
        'sim.load_driver(%s, {xml = %s})' % (json.dumps(luapath), json.dumps(xmlpath)),
        'if #sim.errors > 0 then print("ERR %s load: " .. sim.errors[1]); os.exit(1) end' % name,
    ]
    for pname, value in specs:
        lines.append('sim.Properties[%s] = %s' % (json.dumps(pname), value))
        lines.append('sim.call("OnPropertyChanged", %s)' % json.dumps(pname))
        lines.append('if #sim.errors > 0 then print("ERR %s %s [%s]: " .. sim.errors[#sim.errors]); '
                     'os.exit(1) end' % (name, pname, mode))
    lines.append('print("ok %s %s")' % (name, mode))
    return "\n".join(lines)


def run_props(which):
    """Change every property once (alternate value, then empty string) and run OnPropertyChanged."""
    specs, missing = drivers(which)
    for m in missing:
        print("ERR %s: no driver lua or driver.xml found" % m)
    if not specs and not missing:
        print("ERR no drivers matched '%s'" % which)
        return 1
    if not specs:
        return 1
    lua = find_lua()
    rc = 0
    for spec in specs:
        dname, luapath, xmlpath = spec.split("|", 2)
        driver_ok = True
        for mode in ("alternate", "empty"):
            props = property_specs(xmlpath, mode)
            if not props:
                continue
            script = property_script(dname, luapath, xmlpath, props, mode)
            fd, path = tempfile.mkstemp(prefix="c4prop_", suffix=".lua")
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    fh.write(script)
                r = subprocess.run([lua, path], cwd=ROOT, env=lua_env(), capture_output=True, text=True)
            finally:
                os.unlink(path)
            out = (r.stdout or "").strip().splitlines()
            if r.returncode != 0 or not out or not out[-1].startswith("ok "):
                print(out[-1] if out else "ERR %s props [%s]: no output" % (dname, mode))
                driver_ok = False
                rc = 1
        if driver_ok:
            print("ok %s properties" % dname)
    return rc


def main(argv):
    if len(argv) != 2 or argv[0] not in ("smoke", "commands", "props", "test"):
        print("usage: run.py smoke [dir|all] | commands [dir|all] | props [dir|all] | test [name|all]")
        return 2
    if argv[0] == "smoke":
        return run_smoke(argv[1])
    if argv[0] == "commands":
        return run_commands(argv[1])
    if argv[0] == "props":
        return run_props(argv[1])
    return run_tests(argv[1])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
