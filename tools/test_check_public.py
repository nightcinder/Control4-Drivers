"""Regression tests for tools/check_public.py.

Run: python tools/test_check_public.py -v
"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from check_public import scan_text  # noqa: E402


def kinds(text):
    return [kind for _, kind, _ in scan_text(text)]


class PublicDataTests(unittest.TestCase):
    def test_private_ipv4_fails(self):
        # Split literals so this test file does not itself trip the repo scan.
        self.assertIn("private IPv4 address", kinds("host 192.168." + "1.20"))
        self.assertIn("private IPv4 address", kinds("host 10.1." + "2.3"))
        self.assertIn("private IPv4 address", kinds("host 172.20." + "0.9"))

    def test_documentation_and_loopback_pass(self):
        self.assertEqual(kinds("host 192.0.2.10"), [])
        self.assertEqual(kinds("host 198.51.100.20"), [])
        self.assertEqual(kinds("host 127.0.0.1"), [])
        self.assertEqual(kinds("network 10.0.0.0/8"), [])

    def test_personal_paths_fail(self):
        self.assertIn("personal home path", kinds("/home/" + "alice/config.json"))
        self.assertIn("personal Windows home path", kinds(r"C:\Users" + r"\Alice\file.txt"))

    def test_placeholder_paths_pass(self):
        self.assertEqual(kinds("/home/user/config.json"), [])
        self.assertEqual(kinds("/home/$USER/config.json"), [])
        self.assertEqual(kinds(r"C:\Users\<user>\file.txt"), [])
        self.assertEqual(kinds(r"C:\Users\Public\file.txt"), [])

    def test_credentials_fail(self):
        self.assertIn("credential-like token", kinds("token ghp_" + "a" * 30))
        self.assertIn("credential-like token", kinds("AKIA" + "A" * 16))
        self.assertIn("credential-like token", kinds("-----BEGIN " + "RSA PRIVATE KEY-----"))

    def test_normal_text_passes(self):
        self.assertEqual(kinds("The bridge listens on port 8788 and returns JSON."), [])


if __name__ == "__main__":
    unittest.main()
