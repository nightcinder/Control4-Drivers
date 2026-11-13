#!/usr/bin/env python3
"""c4sim runner.

  python tools/c4sim/run.py smoke [dir|all]
  python tools/c4sim/run.py test [name|all]
"""
import glob
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
LUA_WIN = r"C:\Users\Nick\AppData\Local\Microsoft\WinGet\Links\lua.exe"


def find_lua():
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


def main(argv):
    if len(argv) != 2 or argv[0] not in ("smoke", "test"):
        print("usage: run.py smoke [dir|all] | test [name|all]")
        return 2
    if argv[0] == "smoke":
        return run_smoke(argv[1])
    return run_tests(argv[1])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
