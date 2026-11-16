"""Regression checks for the command-description rule (CD001) in tools/check_c4z.py.

Each case writes a small inline driver.xml into a temp dir and runs check_command_descriptions on it.
No driver under drivers/ is read.
Run: python tools/test_check_c4z.py -v
"""
import os
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from check_c4z import check_command_descriptions  # noqa: E402


def command(name, description, nparams=0, desc_xml=None):
    params = "".join("<param><name>p%d</name></param>" % (i + 1) for i in range(nparams))
    params_xml = f"<params>{params}</params>" if nparams else ""
    if desc_xml is None:
        desc_xml = f"<description>{description}</description>"
    return f"<command><name>{name}</name>{desc_xml}{params_xml}</command>"


def devicedata(*commands):
    if not commands:
        return "<devicedata><version>1</version></devicedata>"
    return f"<devicedata><commands>{''.join(commands)}</commands></devicedata>"


def run_check(xml_text):
    """Write driver.xml to a temp dir, parse it, run the check, return the failure lines."""
    with tempfile.TemporaryDirectory(prefix="c4cd_") as tmp:
        path = os.path.join(tmp, "driver.xml")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(xml_text)
        root = ET.parse(path).getroot()
    fails = []

    def fail(c, msg):
        fails.append(f"FAIL drv [{c}] {msg}")

    check_command_descriptions(root, "driver.xml", fail)
    return fails


class CommandDescriptionTests(unittest.TestCase):
    def assertFailsWith(self, fails, *fragments):
        self.assertEqual(len(fails), 1, fails)
        for frag in fragments:
            self.assertIn(frag, fails[0])

    def test_good_command_with_params_passes(self):
        xml = devicedata(command("Clean", "Clean rooms PARAM1 on NAME with cleaning mode PARAM2", 2))
        self.assertEqual(run_check(xml), [])

    def test_good_command_without_params_passes(self):
        xml = devicedata(command("Off", "Turn NAME off"))
        self.assertEqual(run_check(xml), [])

    def test_missing_name_fails(self):
        xml = devicedata(command("Off", "Turn it off"))
        self.assertFailsWith(run_check(xml), "command 'Off'", "uses NAME 0 times")

    def test_name_twice_fails(self):
        xml = devicedata(command("On", "Turn NAME on, then NAME again"))
        self.assertFailsWith(run_check(xml), "command 'On'", "uses NAME 2 times")

    def test_missing_param2_fails(self):
        xml = devicedata(command("Clean", "Clean rooms PARAM1 on NAME", 2))
        self.assertFailsWith(run_check(xml), "command 'Clean'", "missing PARAM2")

    def test_param3_with_two_params_fails(self):
        xml = devicedata(command("Clean", "PARAM1 PARAM2 PARAM3 on NAME", 2))
        self.assertFailsWith(run_check(xml), "command 'Clean'", "unexpected PARAM3")

    def test_repeated_param1_fails(self):
        xml = devicedata(command("Clean", "PARAM1 and PARAM1 on NAME", 2))
        fails = run_check(xml)
        self.assertFailsWith(fails, "repeated PARAM1", "missing PARAM2")

    def test_glued_param_token_fails_with_clear_message(self):
        xml = devicedata(command("Set", "Set NAME to PARAM1F", 1))
        fails = run_check(xml)
        self.assertEqual(len(fails), 2, fails)
        self.assertIn("command 'Set'", fails[0])
        self.assertIn("PARAMn and NAME must be separate words", fails[0])
        self.assertIn("missing PARAM1", fails[1])

    def test_empty_description_fails(self):
        xml = devicedata(command("Off", "", desc_xml="<description></description>"))
        self.assertFailsWith(run_check(xml), "command 'Off'", "no <description>, or it is empty")

    def test_missing_description_fails(self):
        xml = devicedata(command("Off", "", desc_xml=""))
        self.assertFailsWith(run_check(xml), "command 'Off'", "no <description>")

    def test_driver_without_commands_passes(self):
        self.assertEqual(run_check(devicedata()), [])
        self.assertEqual(run_check("<devicedata><commands></commands></devicedata>"), [])


if __name__ == "__main__":
    unittest.main()
