"""Regression checks for the c4sim hook in tools/build_c4z.py.

Each case copies tools/ and one small driver into a temp repo, so no real driver file or c4z/ output is touched.
Run: python tools/c4sim/test_build_hook.py -v   (needs git on PATH for the pre-flight check; lua for the first three cases)
"""
import glob
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
DRIVER = "unifi-outlet"
BROKEN_SYNTAX = "\nlocal = = 1\n"
BROKEN_LOAD = "\nerror('probe boom')\n"


def make_repo(tmp):
    shutil.copytree(os.path.join(REPO, "tools"), os.path.join(tmp, "tools"),
                    ignore=shutil.ignore_patterns("__pycache__"))
    os.makedirs(os.path.join(tmp, "c4z"))
    # The build hook runs the whole c4sim suite, so every driver the tests load must exist.
    shutil.copytree(os.path.join(REPO, "drivers"), os.path.join(tmp, "drivers"))
    return tmp


def driver_lua(tmp):
    return glob.glob(os.path.join(tmp, "drivers", DRIVER, "*_driver.lua"))[0]


def build(tmp, env=None, code=None):
    script = os.path.join(tmp, "tools", "build_c4z.py")
    if code is None:
        cmd = [sys.executable, script, DRIVER]
    else:
        cmd = [sys.executable, "-c", code]
    return subprocess.run(cmd, cwd=tmp, capture_output=True, text=True, env=env)


class BuildHookTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="c4hook_")
        make_repo(self.tmp)
        self.c4z = os.path.join(self.tmp, "c4z", "UniFi_Outlet.c4z")
        with open(driver_lua(self.tmp), "rb") as fh:
            self.orig = fh.read()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _mutate(self, extra):
        with open(driver_lua(self.tmp), "wb") as fh:
            fh.write(self.orig + extra.encode("utf-8"))

    def test_clean_driver_builds(self):
        r = build(self.tmp)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("c4sim smoke: ok", r.stdout)
        self.assertTrue(os.path.isfile(self.c4z))

    def test_syntax_error_refused_and_no_c4z(self):
        self._mutate(BROKEN_SYNTAX)
        r = build(self.tmp)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("REFUSED", r.stdout)
        self.assertFalse(os.path.exists(self.c4z))

    def test_load_error_refused_and_existing_c4z_kept(self):
        self.assertEqual(build(self.tmp).returncode, 0)  # a real, valid prior c4z
        with open(self.c4z, "rb") as fh:
            prior = fh.read()
        self._mutate(BROKEN_LOAD)
        r = build(self.tmp)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("c4sim check failed", r.stdout)
        with open(self.c4z, "rb") as fh:
            self.assertEqual(fh.read(), prior)

    def test_no_lua_skips_smoke_and_still_builds(self):
        git_dir = os.path.dirname(shutil.which("git") or "")
        path = os.pathsep.join(p for p in (git_dir, os.path.dirname(sys.executable),
                                           os.environ.get("SystemRoot", r"C:\Windows") + r"\System32") if p)
        if shutil.which("lua", path=path):
            self.skipTest("a lua is reachable from the stripped PATH")
        env = dict(os.environ, PATH=path)
        code = ("import sys; sys.path[:0] = [r'%s', r'%s']; import run; run.LUA_WIN = r'C:\\__none__\\lua.exe'; "
                "import build_c4z as b; sys.exit(0 if b.build('%s') else 1)"
                % (os.path.join(self.tmp, "tools"), os.path.join(self.tmp, "tools", "c4sim"), DRIVER))
        r = build(self.tmp, env=env, code=code)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("c4sim skipped: lua not found", r.stdout)
        self.assertTrue(os.path.isfile(self.c4z))


if __name__ == "__main__":
    unittest.main()
