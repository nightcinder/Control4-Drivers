"""Regression tests for dls_presence.py v1.6.1 (B9): an empty UniFi exporter is unknown, not away. No network.

Run:  python tools\\dls-presence\\test_dls_presence_161.py
"""
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dls_presence as dp  # noqa: E402


def fake_prom(total, phone_hit):
    def prom(q):
        if q == "count(unpoller_client_uptime_seconds)":
            return [] if total is None else [{"value": [0, str(total)]}]
        return [{"value": [0, "1"]}] if phone_hit else []
    return prom


class B9UnifiEmptyExporter(unittest.TestCase):
    def setUp(self):
        dp._last_ok["unifi"] = None

    def test_b9_no_client_series_is_unknown_and_not_fresh(self):
        with mock.patch.object(dp, "prom", fake_prom(None, False)):
            self.assertIsNone(dp.unifi_present("Pixel"))
        self.assertIsNone(dp._last_ok["unifi"], "_last_ok not stamped without data")
        with mock.patch.object(dp, "people", lambda: [{"name": "n", "unifi": "Pixel"}]), \
             mock.patch.object(dp, "_started", 0.0):
            self.assertTrue(dp.freshness()["unifi"]["stale"], "/health goes stale")

    def test_b9_zero_count_is_unknown(self):
        with mock.patch.object(dp, "prom", fake_prom(0, False)):
            self.assertIsNone(dp.unifi_present("Pixel"))
        self.assertIsNone(dp._last_ok["unifi"])

    def test_b9_exporter_up_phone_absent_is_away_and_stamped(self):
        with mock.patch.object(dp, "prom", fake_prom(12, False)):
            self.assertIs(dp.unifi_present("Pixel"), False)
        self.assertIsNotNone(dp._last_ok["unifi"])

    def test_b9_exporter_up_phone_present(self):
        with mock.patch.object(dp, "prom", fake_prom(12, True)):
            self.assertIs(dp.unifi_present("Pixel"), True)

    def test_b9_household_unknown_keeps_last_state(self):
        with mock.patch.object(dp, "prom", fake_prom(None, False)), \
             mock.patch.object(dp, "people", lambda: [{"name": "n", "unifi": "Pixel"}]):
            st, _ = dp.household()
        self.assertIsNone(st, "no AWAY from a dead exporter")

    def test_b9_version(self):
        self.assertEqual(dp.VERSION, "1.6.1")


if __name__ == "__main__":
    unittest.main()
