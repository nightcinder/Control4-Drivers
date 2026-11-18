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

from check_c4z import (  # noqa: E402
    check_c4_methods, check_command_descriptions, check_command_handlers, check_destroy, check_duplicate_functions,
    check_lua51, check_lua_sandbox, check_lua_vs_xml, check_params, check_timers, check_unique,
)


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


def nested(*items_xml):
    """A driver.xml with its containers under <config>, the layout newer drivers use."""
    body = "".join(items_xml)
    return f"<devicedata><config>{body}</config></devicedata>"


def commands(*items):
    return "<commands>" + "".join(items) + "</commands>"


class NestedContainerTests(unittest.TestCase):
    """The <commands> container is at the root in older drivers and under <config> in newer ones."""

    def test_nested_command_description_is_checked(self):
        root = ET.fromstring(nested(commands(command("Off", "Turn it off"))))
        fails = []
        check_command_descriptions(root, "driver.xml", lambda c, m: fails.append(m))
        self.assertEqual(len(fails), 1)
        self.assertIn("uses NAME 0 times", fails[0])

    def test_nested_duplicate_command_name_fails(self):
        root = ET.fromstring(nested(commands(command("Off", "Turn NAME off"), command("Off", "Switch NAME off"))))
        fails = []
        check_unique(root, "driver.xml", lambda c, m: fails.append(m))
        self.assertIn("2 command names with value 'Off'", fails[0])

    def test_nested_commands_need_execute_command(self):
        root = ET.fromstring(nested(commands(command("Off", "Turn NAME off"))))
        fails = []
        check_lua_vs_xml(root, "driver.xml", "driver.lua", "local x = 1", lambda c, m: fails.append(m), lambda c, m: None)
        self.assertEqual(len(fails), 1)
        self.assertIn("defines commands", fails[0])

    def test_common_handlers_supply_execute_command(self):
        root = ET.fromstring(nested(commands(command("Off", "Turn NAME off"))))
        lua = "require ('drivers-common-public.global.handlers')"
        fails = []
        check_lua_vs_xml(root, "driver.xml", "driver.lua", lua, lambda c, m: fails.append(m), lambda c, m: None)
        self.assertEqual(fails, [])


class Lua51Tests(unittest.TestCase):
    def fails(self, text):
        out = []
        check_lua51("driver.lua", text, lambda c, m: out.append(m))
        return out

    def test_lua52_and_later_constructs_fail(self):
        self.assertIn("integer division", self.fails("local x = 4 // 2")[0])
        self.assertIn("goto", self.fails("goto done")[0])
        self.assertIn("bitwise operator", self.fails("local x = a & b")[0])
        self.assertTrue(self.fails("local x = table.unpack(t)"))

    def test_lua51_code_passes(self):
        self.assertEqual(self.fails("local x = 4 / 2\nlocal y = a ~= b\nlocal s = 'a // b'\n-- goto done"), [])


class LuaSandboxTests(unittest.TestCase):
    def fails(self, text):
        out = []
        check_lua_sandbox("driver.lua", text, lambda c, m: out.append(m))
        return out

    def test_host_apis_fail(self):
        self.assertTrue(self.fails('os.execute("rm -rf /")'))
        self.assertTrue(self.fails("local f = io.open('x')"))
        self.assertTrue(self.fails("local f = loadstring('x')"))

    def test_require_outside_public_library_fails(self):
        self.assertTrue(self.fails("require('socket')"))
        self.assertEqual(self.fails("require('drivers-common-public.global.url')"), [])
        self.assertEqual(self.fails("local s = \"io.open\" -- os.execute"), [])


class DuplicateFunctionTests(unittest.TestCase):
    def fails(self, text):
        out = []
        check_duplicate_functions("driver.lua", text, lambda c, m: out.append(m))
        return out

    def test_duplicate_global_fails(self):
        fails = self.fails("function ExecuteCommand(a)\nend\nfunction ExecuteCommand(b)\nend")
        self.assertEqual(len(fails), 1)
        self.assertIn("ExecuteCommand 2 times", fails[0])

    def test_local_and_table_functions_pass(self):
        self.assertEqual(self.fails("local function f() end\nlocal function f() end"), [])
        self.assertEqual(self.fails("local t = {\n  parse = function() end,\n}\nlocal u = {\n  parse = function() end,\n}"), [])


class C4MethodTests(unittest.TestCase):
    def run_check(self, text):
        fails, warns = [], []
        check_c4_methods("driver.lua", text, lambda c, m: fails.append(m), lambda c, m: warns.append(m))
        return fails, warns

    def test_typo_fails_with_suggestion(self):
        fails, _ = self.run_check('C4:UpdatePropery("X", 1)')
        self.assertEqual(len(fails), 1)
        self.assertIn("did you mean C4:UpdateProperty", fails[0])

    def test_unknown_method_warns(self):
        fails, warns = self.run_check("C4:Frobnicate()")
        self.assertEqual(fails, [])
        self.assertIn("not in the known DriverWorks method list", warns[0])

    def test_known_method_passes(self):
        self.assertEqual(self.run_check('C4:UpdateProperty("X", 1)\nC4:url()'), ([], []))

    def test_string_is_not_a_call(self):
        self.assertEqual(self.run_check('local s = "C4:UpdatePropery"'), ([], []))


class DestroyTests(unittest.TestCase):
    def fails(self, text):
        out = []
        check_destroy("driver.lua", text, lambda c, m: out.append(m))
        return out

    def test_timer_without_destroy_fails(self):
        self.assertTrue(self.fails("C4:SetTimer(1000, function() end)"))
        self.assertTrue(self.fails("C4:CreateServer(1234, 'TCP')"))

    def test_destroy_handler_passes(self):
        text = "C4:SetTimer(1000, function() end)\nfunction OnDriverDestroyed() end"
        self.assertEqual(self.fails(text), [])

    def test_url_only_driver_does_not_need_destroy(self):
        self.assertEqual(self.fails("C4:urlGet('http://x', {}, false, function() end)"), [])


class TimerApiTests(unittest.TestCase):
    def fails(self, text):
        out = []
        check_timers("driver.lua", text, lambda c, m: out.append(m))
        return out

    def test_fourth_argument_fails(self):
        fails = self.fails('C4:AddTimer(60, "SECONDS", true, "OnPollTimer")')
        self.assertTrue(any("4th argument" in f for f in fails), fails)

    def test_missing_on_timer_expired_fails(self):
        fails = self.fails('C4:AddTimer(60, "SECONDS", true)')
        self.assertTrue(any("OnTimerExpired" in f for f in fails), fails)

    def test_correct_usage_passes(self):
        text = 'C4:AddTimer(60, "SECONDS", true)\nfunction OnTimerExpired(id) end\nfunction OnDriverDestroyed() end'
        self.assertEqual(self.fails(text), [])


class NetworkTeardownTests(unittest.TestCase):
    def fails(self, text):
        out = []
        check_destroy("driver.lua", text, lambda c, m: out.append(m))
        return out

    def test_netconnect_without_disconnect_fails(self):
        fails = self.fails('C4:NetConnect(6001, 1234, "TCP")\nfunction OnDriverDestroyed() end')
        self.assertTrue(any("NetDisconnect" in f for f in fails), fails)

    def test_create_server_without_destroy_fails(self):
        fails = self.fails("C4:CreateServer(8730)\nfunction OnDriverDestroyed() end")
        self.assertTrue(any("DestroyServer" in f for f in fails), fails)

    def test_teardown_passes(self):
        text = ('C4:NetConnect(6001, 1234, "TCP")\nC4:CreateServer(8730)\n'
                'function OnDriverDestroyed() C4:NetDisconnect(6001, 1234) C4:DestroyServer() end')
        self.assertEqual(self.fails(text), [])


class CommandHandlerTests(unittest.TestCase):
    def fails(self, xml_text, lua_text):
        root = ET.fromstring(xml_text)
        out = []
        check_command_handlers(root, "driver.xml", "driver.lua", lua_text, lambda c, m: out.append(m))
        return out

    def test_command_present_passes(self):
        xml = nested(commands(command("Play/Pause", "Pause NAME")))
        self.assertEqual(self.fails(xml, 'if key == "PLAYPAUSE" then end'), [])

    def test_command_missing_fails(self):
        xml = nested(commands(command("Set Level", "Set NAME to PARAM1", 1)))
        fails = self.fails(xml, "function ExecuteCommand() end")
        self.assertEqual(len(fails), 1)
        self.assertIn("nothing handles", fails[0])

    def test_common_handlers_are_exempt(self):
        xml = nested(commands(command("Set Level", "Set NAME to PARAM1", 1)))
        lua = "require ('drivers-common-public.global.handlers')"
        self.assertEqual(self.fails(xml, lua), [])


class UpdatePropertyListTests(unittest.TestCase):
    def run_check(self, lua):
        root = ET.fromstring(
            "<devicedata><properties><property><name>P</name><type>STRING</type></property></properties></devicedata>")
        fails = []
        check_lua_vs_xml(root, "driver.xml", "driver.lua", lua,
                         lambda c, m: fails.append(m), lambda c, m: None)
        return fails

    def test_table_literal_fails(self):
        fails = self.run_check('function OnPropertyChanged() end\nC4:UpdatePropertyList("P", {"a", "b"})')
        self.assertTrue(any("comma-separated string" in f for f in fails), fails)

    def test_string_passes(self):
        self.assertEqual(self.run_check('function OnPropertyChanged() end\nC4:UpdatePropertyList("P", "a,b")'), [])

    def test_unknown_property_name_fails(self):
        fails = self.run_check('function OnPropertyChanged() end\nC4:UpdatePropertyList("Q", "a")')
        self.assertTrue(any("not a property" in f for f in fails), fails)


class NumericPropertyWriteTests(unittest.TestCase):
    def run_check(self, lua):
        root = ET.fromstring(
            "<devicedata><properties><property><name>Level</name><type>RANGED_INTEGER</type>"
            "<minimum>1</minimum><maximum>10</maximum><default>5</default></property></properties></devicedata>")
        fails = []
        check_lua_vs_xml(root, "driver.xml", "driver.lua", "function OnPropertyChanged() end\n" + lua,
                         lambda c, m: fails.append(m), lambda c, m: None)
        return fails

    def test_string_to_numeric_fails(self):
        fails = self.run_check('C4:UpdateProperty("Level", "7")')
        self.assertTrue(any("write a number" in f for f in fails), fails)

    def test_tostring_to_numeric_fails(self):
        fails = self.run_check('C4:UpdateProperty("Level", tostring(7))')
        self.assertTrue(any("write a number" in f for f in fails), fails)

    def test_number_passes(self):
        self.assertEqual(self.run_check('C4:UpdateProperty("Level", 7)'), [])


class ParamTests(unittest.TestCase):
    def run_check(self, xml_text):
        root = ET.fromstring(xml_text)
        fails, warns = [], []
        check_params(root, "driver.xml", lambda c, m: fails.append(m), lambda c, m: warns.append(m))
        return fails, warns

    def test_missing_type_fails(self):
        fails, _ = self.run_check(nested(commands(
            "<command><name>Set</name><params><param><name>LEVEL</name></param></params></command>")))
        self.assertEqual(len(fails), 1)
        self.assertIn("has no <type>", fails[0])

    def test_duplicate_param_name_fails(self):
        fails, _ = self.run_check(nested(commands(
            "<command><name>Set</name><params>"
            "<param><name>LEVEL</name><type>STRING</type></param>"
            "<param><name>LEVEL</name><type>STRING</type></param>"
            "</params></command>")))
        self.assertIn("two params named 'LEVEL'", fails[0])

    def test_valid_params_pass(self):
        self.assertEqual(self.run_check(nested(commands(
            "<command><name>Set</name><params>"
            "<param><name>LEVEL</name><type>RANGED_INTEGER</type></param>"
            "</params></command>"))), ([], []))


if __name__ == "__main__":
    unittest.main()
