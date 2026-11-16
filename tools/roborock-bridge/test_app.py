"""Unit tests for roborock-bridge (0.2.3): command parsing, state names, per-run mode and restore.

Run: python -m unittest discover -s tools/roborock-bridge -p "test_*.py"
python-roborock is not needed: the library calls are replaced by fakes.
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

# Stand-in for roborock.roborock_typing so the tests run without the library installed.
_typing = types.ModuleType("roborock.roborock_typing")
_typing.RoborockCommand = SimpleNamespace(
    APP_START="app_start", APP_STOP="app_stop", APP_PAUSE="app_pause", APP_CHARGE="app_charge",
    APP_SEGMENT_CLEAN="app_segment_clean", SET_CLEAN_MOTOR_MODE="set_clean_motor_mode",
    SET_CUSTOM_MODE="set_custom_mode", SET_WATER_BOX_CUSTOM_MODE="set_water_box_custom_mode",
    SET_MOP_MODE="set_mop_mode")
_pkg = types.ModuleType("roborock")
_pkg.roborock_typing = _typing
sys.modules["roborock"] = _pkg
sys.modules["roborock.roborock_typing"] = _typing

import app  # noqa: E402

# Library defaults per mode (python-roborock 7.22.0, a vacuum with route settings).
DEFAULTS = {
    "vacuum": {"fan_power": 102, "water_box_mode": 200, "mop_mode": 300},
    "vac_and_mop": {"fan_power": 102, "water_box_mode": 202, "mop_mode": 300},
    "mop": {"fan_power": 105, "water_box_mode": 202, "mop_mode": 300},
}


def fake_defaults(_props, mode):
    if mode not in DEFAULTS:
        raise app.ModeUnsupported(mode)
    return dict(DEFAULTS[mode])


class FakeStatus(SimpleNamespace):
    async def refresh(self):
        self.refreshes = getattr(self, "refreshes", 0) + 1


class FakeProps:
    """Records every command. set_clean_motor_mode updates the fake status like the vacuum would."""

    def __init__(self, fan=104, water=203, route=301, fail=()):
        self.status = FakeStatus(state=SimpleNamespace(name="charging"), battery=100, error_code=None,
                                 fan_power=fan, water_box_mode=water, mop_mode=route)
        self.sent = []
        self.fail = set(fail)
        self.command = SimpleNamespace(send=self.send)

    async def send(self, command, params=None):
        self.sent.append((command, params))
        if command in self.fail:
            raise RuntimeError("refused")
        if command == "set_clean_motor_mode":
            for key, value in params[0].items():
                setattr(self.status, key, value)


def run(coro):
    return asyncio.run(coro)


class ParseCommandTests(unittest.TestCase):
    def test_old_bodies_still_parse(self):
        self.assertEqual(app.parse_command(b'{"action":"start"}'), ("start", [], None))
        self.assertEqual(app.parse_command(b'{"action":"clean_rooms","rooms":[16,17]}'),
                         ("clean_rooms", [16, 17], None))

    def test_mode_is_accepted_for_start_and_rooms(self):
        self.assertEqual(app.parse_command(b'{"action":"start","mode":"vacuum"}'), ("start", [], "vacuum"))
        self.assertEqual(app.parse_command(b'{"action":"clean_rooms","rooms":[21],"mode":"vac_and_mop"}'),
                         ("clean_rooms", [21], "vac_and_mop"))

    def test_mode_is_dropped_for_other_actions(self):
        self.assertEqual(app.parse_command(b'{"action":"dock","mode":"mop"}'), ("dock", [], None))

    def test_bad_input_is_rejected(self):
        for body in (b'{"action":"start","mode":"wet"}', b'{"action":"set_mode"}', b'{"action":"fly"}',
                     b'{"action":"clean_rooms","rooms":[]}', b'{"action":"clean_rooms","rooms":["16"]}', b'[1]'):
            with self.assertRaises(ValueError, msg=body):
                app.parse_command(body)

    def test_set_mode(self):
        self.assertEqual(app.parse_command(b'{"action":"set_mode","mode":"mop"}'), ("set_mode", [], "mop"))


class StateNameTests(unittest.TestCase):
    def test_cleaning_names(self):
        for s in ("cleaning", "segment_cleaning", "zoned_cleaning", "spot_cleaning", "Segment Cleaning",
                  "segment_mopping", "robot_status_mopping", "clean_mop_cleaning"):
            self.assertTrue(app._is_cleaning(s), s)
        for s in ("charging", "charging_complete", "returning_home", "idle", "paused", "error", None, ""):
            self.assertFalse(app._is_cleaning(s), s)

    def test_busy_covers_returning_home(self):
        for s in ("returning_home", "docking", "emptying_the_bin", "washing_the_mop", "segment_cleaning"):
            self.assertTrue(app._is_busy(s), s)
        for s in ("charging", "charging_complete", "idle", "paused", None):
            self.assertFalse(app._is_busy(s), s)


class SnapshotTests(unittest.TestCase):
    def test_extras_are_read_and_missing_ones_are_none(self):
        st = SimpleNamespace(state=SimpleNamespace(name="segment_cleaning"), battery=87, error_code=None,
                             clean_time=754, clean_area=12340000, clean_percent=41, in_cleaning=3,
                             current_cleaning_mode_name="vac_and_mop", water_mode_name="medium",
                             fan_speed_name="balanced", mop_route_name="standard",
                             cleaning_mode_options=[SimpleNamespace(value="vacuum"), SimpleNamespace(value="mop")])
        snap = app.status_snapshot(st)
        self.assertEqual(snap["state"], "segment_cleaning")
        self.assertEqual(snap["clean_area_m2"], 12.34)
        self.assertEqual(snap["clean_time_s"], 754)
        self.assertEqual(snap["clean_percent"], 41)
        self.assertEqual(snap["in_cleaning"], 3)
        self.assertEqual(snap["cleaning_mode"], "vac_and_mop")
        self.assertEqual(snap["cleaning_modes"], ["vacuum", "mop"])
        bare = app.status_snapshot(SimpleNamespace(state=None, battery=None))
        self.assertIsNone(bare["clean_percent"])
        self.assertIsNone(bare["clean_area_m2"])
        self.assertIsNone(bare["cleaning_mode"])
        self.assertEqual(bare["cleaning_modes"], [])
        json.dumps(snap)

    def test_state_name_is_normalized(self):
        for raw, want in (("Segment Cleaning", "segment_cleaning"), ("returning-home", "returning_home"),
                          ("CHARGING", "charging"), ("washing_the_mop_2", "washing_the_mop_2")):
            st = SimpleNamespace(state=SimpleNamespace(name=raw), battery=50)
            self.assertEqual(app.status_snapshot(st)["state"], want)
        self.assertIsNone(app.status_snapshot(SimpleNamespace(state=None, battery=None))["state"])

    def test_every_library_state_is_classified(self):
        # RoborockStateCode names in python-roborock 7.22.0.
        cleaning = {"cleaning", "spot_cleaning", "zoned_cleaning", "segment_cleaning", "robot_status_mopping",
                    "clean_mop_cleaning", "clean_mop_mopping", "segment_mopping", "segment_clean_mop_cleaning",
                    "segment_clean_mop_mopping", "zoned_mopping", "zoned_clean_mop_cleaning",
                    "zoned_clean_mop_mopping"}
        busy_not_cleaning = {"returning_home", "docking", "going_to_wash_the_mop", "back_to_dock_washing_duster",
                             "emptying_the_bin", "washing_the_mop", "washing_the_mop_2", "attaching_the_mop",
                             "detaching_the_mop"}
        resting = {"unknown", "starting", "charger_disconnected", "idle", "remote_control_active", "manual_mode",
                   "charging", "charging_problem", "paused", "error", "shutting_down", "updating",
                   "going_to_target", "in_call", "mapping", "egg_attack", "patrol", "charging_complete",
                   "device_offline", "locked", "air_drying_stopping"}
        for s in cleaning:
            self.assertTrue(app._is_cleaning(s) and app._is_busy(s), s)
        for s in busy_not_cleaning:
            self.assertTrue(app._is_busy(s) and not app._is_cleaning(s), s)
        for s in resting:
            self.assertFalse(app._is_busy(s) or app._is_cleaning(s), s)

    def test_out_of_range_percent_is_dropped(self):
        st = SimpleNamespace(state=None, battery=None, clean_percent=250)
        self.assertIsNone(app.status_snapshot(st)["clean_percent"])

    def test_state_payload_progress_fields(self):
        with patch.object(app, "load_saved", return_value={"x": 1}), \
                patch.dict(app.STATE, {"clean_percent": 41, "last_success": None}), \
                patch.dict(app.RESTORE, {"pending": None}):
            code, body = app.state_payload()
        self.assertEqual(code, 200)
        self.assertEqual(body["run_progress_pct"], 41)
        self.assertEqual(body["run_progress_source"], "device")
        self.assertIsNone(body["room_progress_pct"])
        self.assertEqual(body["bridge_version"], app.VERSION)
        self.assertFalse(body["mode_restore_pending"])
        with patch.object(app, "load_saved", return_value={"x": 1}), \
                patch.dict(app.STATE, {"clean_percent": None, "last_success": None}):
            _, body = app.state_payload()
        self.assertIsNone(body["run_progress_pct"])
        self.assertIsNone(body["run_progress_source"])


class MergeTests(unittest.TestCase):
    def test_vacuum_keeps_suction_and_turns_water_off(self):
        out = app.merge_mode_params("vacuum", DEFAULTS["vacuum"], {"fan_power": 104, "water_box_mode": 203, "mop_mode": 301})
        self.assertEqual(out, {"fan_power": 104, "water_box_mode": 200, "mop_mode": 301})

    def test_vac_and_mop_keeps_water_level_when_one_is_set(self):
        out = app.merge_mode_params("vac_and_mop", DEFAULTS["vac_and_mop"], {"fan_power": 103, "water_box_mode": 203, "mop_mode": 300})
        self.assertEqual(out["water_box_mode"], 203)
        out = app.merge_mode_params("vac_and_mop", DEFAULTS["vac_and_mop"], {"fan_power": 103, "water_box_mode": 200, "mop_mode": 300})
        self.assertEqual(out["water_box_mode"], 202)

    def test_mop_uses_the_library_fan_code(self):
        out = app.merge_mode_params("mop", DEFAULTS["mop"], {"fan_power": 104, "water_box_mode": 201, "mop_mode": 300})
        self.assertEqual(out["fan_power"], 105)
        self.assertEqual(out["water_box_mode"], 201)

    def test_custom_and_smart_codes_are_not_kept(self):
        out = app.merge_mode_params("vac_and_mop", DEFAULTS["vac_and_mop"], {"fan_power": 106, "water_box_mode": 204, "mop_mode": 302})
        self.assertEqual(out, DEFAULTS["vac_and_mop"])

    def test_no_route_key_when_the_library_gives_none(self):
        out = app.merge_mode_params("vacuum", {"fan_power": 102, "water_box_mode": 200}, {"fan_power": 101, "mop_mode": 301})
        self.assertEqual(out, {"fan_power": 101, "water_box_mode": 200})


class RestoreDueTests(unittest.TestCase):
    def test_rules(self):
        now = 10000.0
        fresh = {"at": now - 30, "seen_active": False}
        seen = {"at": now - 30, "seen_active": True}
        self.assertFalse(app.restore_due(fresh, "charging", 0, now), "job has not started yet")
        self.assertTrue(app.restore_due(seen, "charging", 0, now))
        self.assertTrue(app.restore_due(seen, "charging_complete", None, now))
        self.assertTrue(app.restore_due(seen, "idle", 0, now))
        self.assertFalse(app.restore_due(seen, "charging", 3, now), "recharging in the middle of a job")
        self.assertFalse(app.restore_due(seen, "returning_home", 0, now))
        self.assertFalse(app.restore_due(seen, "paused", 0, now))
        self.assertTrue(app.restore_due({"at": now - 200, "seen_active": False}, "charging", 0, now), "grace passed")
        old = {"at": now - app.RESTORE_MAX_AGE - 1, "seen_active": True}
        self.assertTrue(app.restore_due(old, "error", 3, now), "too old")
        self.assertFalse(app.restore_due(old, "segment_cleaning", 3, now), "never while cleaning")


class ModeFlowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.restore_file = os.path.join(self.tmp.name, "mode_restore.json")
        for p in (patch.object(app, "RESTORE_FILE", self.restore_file),
                  patch.object(app, "default_mode_params", fake_defaults),
                  patch.object(app.asyncio, "sleep", AsyncMock()),
                  patch.dict(app.RESTORE, {"pending": None}),
                  patch.dict(app.RUNTIME, {"props": None, "wake": None}),
                  patch.dict(app.STATE, {"state": "charging"})):
            p.start()
            self.addCleanup(p.stop)

    def use(self, props):
        app.RUNTIME["props"] = props
        return props

    def test_per_run_mode_sets_the_mode_then_starts_and_saves_the_old_codes(self):
        props = self.use(FakeProps(fan=104, water=203, route=301))
        run(app.run_command("clean_rooms", [21], "vacuum"))
        self.assertEqual(props.sent, [
            ("set_clean_motor_mode", [{"fan_power": 104, "water_box_mode": 200, "mop_mode": 301}]),
            ("app_segment_clean", [{"segments": [21], "repeat": 1}]),
        ])
        pending = app.RESTORE["pending"]
        self.assertEqual(pending["prev"], {"fan_power": 104, "water_box_mode": 203, "mop_mode": 301})
        with open(self.restore_file, encoding="utf-8") as f:
            self.assertEqual(json.load(f)["prev"], pending["prev"])

    def test_only_the_changed_settings_are_saved(self):
        props = self.use(FakeProps(fan=104, water=203, route=301))
        with patch.object(app, "default_mode_params", return_value={"fan_power": 102, "water_box_mode": 200}):
            run(app.run_command("start", [], "vacuum"))
        self.assertEqual(app.RESTORE["pending"]["prev"], {"fan_power": 104, "water_box_mode": 203})

    def test_restore_after_the_job_was_seen_and_has_ended(self):
        props = self.use(FakeProps(fan=104, water=203, route=301))
        run(app.run_command("start", [], "vacuum"))
        props.sent.clear()
        run(app.maybe_restore(props, {"state": "charging", "in_cleaning": 0}))
        self.assertEqual(props.sent, [], "not restored before the job was seen running")
        run(app.maybe_restore(props, {"state": "cleaning", "in_cleaning": 1}))
        self.assertTrue(app.RESTORE["pending"]["seen_active"])
        run(app.maybe_restore(props, {"state": "returning_home", "in_cleaning": 0}))
        self.assertEqual(props.sent, [])
        run(app.maybe_restore(props, {"state": "charging", "in_cleaning": 0}))
        self.assertEqual(props.sent, [("set_clean_motor_mode", [{"fan_power": 104, "water_box_mode": 203, "mop_mode": 301}])])
        self.assertIsNone(app.RESTORE["pending"])
        self.assertFalse(os.path.exists(self.restore_file))

    def test_no_change_and_no_restore_when_the_mode_already_matches(self):
        props = self.use(FakeProps(fan=103, water=200, route=300))
        run(app.run_command("start", [], "vacuum"))
        self.assertEqual(props.sent, [("app_start", None)])
        self.assertIsNone(app.RESTORE["pending"])

    def test_second_per_run_job_keeps_the_first_saved_codes(self):
        props = self.use(FakeProps(fan=104, water=203, route=301))
        run(app.run_command("start", [], "vacuum"))
        run(app.run_command("clean_rooms", [18], "vac_and_mop"))
        self.assertEqual(app.RESTORE["pending"]["prev"], {"fan_power": 104, "water_box_mode": 203, "mop_mode": 301})
        self.assertEqual(app.RESTORE["pending"]["mode"], "vac_and_mop")

    def test_failed_start_puts_the_mode_back_at_once(self):
        props = self.use(FakeProps(fan=104, water=203, route=301, fail={"app_start"}))
        with self.assertRaises(RuntimeError):
            run(app.run_command("start", [], "vacuum"))
        self.assertEqual(props.sent[-1], ("set_clean_motor_mode", [{"fan_power": 104, "water_box_mode": 203, "mop_mode": 301}]))
        self.assertIsNone(app.RESTORE["pending"])

    def test_failed_restore_is_kept_for_a_retry(self):
        props = self.use(FakeProps(fan=104, water=203, route=301))
        run(app.run_command("start", [], "vacuum"))
        props.fail = {"set_clean_motor_mode", "set_custom_mode"}
        run(app.maybe_restore(props, {"state": "cleaning", "in_cleaning": 1}))
        run(app.maybe_restore(props, {"state": "charging", "in_cleaning": 0}))
        self.assertIsNotNone(app.RESTORE["pending"])
        props.fail = set()
        run(app.maybe_restore(props, {"state": "charging", "in_cleaning": 0}))
        self.assertIsNone(app.RESTORE["pending"])

    def test_single_setting_commands_are_used_when_the_combined_one_is_refused(self):
        props = self.use(FakeProps(fan=104, water=203, route=301, fail={"set_clean_motor_mode"}))
        run(app.run_command("set_mode", [], "vacuum"))
        self.assertEqual(props.sent[1:], [("set_custom_mode", [104]), ("set_water_box_custom_mode", [200]),
                                          ("set_mop_mode", [301])])

    def test_set_mode_is_lasting_and_drops_a_waiting_restore(self):
        props = self.use(FakeProps(fan=104, water=203, route=301))
        run(app.run_command("start", [], "vacuum"))
        run(app.run_command("set_mode", [], "vac_and_mop"))
        self.assertIsNone(app.RESTORE["pending"])
        self.assertEqual(props.sent[-1][0], "set_clean_motor_mode")

    def test_plain_start_restores_a_waiting_mode_first(self):
        props = self.use(FakeProps(fan=104, water=203, route=301))
        run(app.run_command("start", [], "vacuum"))
        props.sent.clear()
        run(app.run_command("start", [], None))
        self.assertEqual([c for c, _ in props.sent], ["set_clean_motor_mode", "app_start"])
        self.assertIsNone(app.RESTORE["pending"])

    def test_plain_start_while_paused_resumes_without_a_restore(self):
        props = self.use(FakeProps(fan=104, water=203, route=301))
        run(app.run_command("start", [], "vacuum"))
        props.sent.clear()
        app.STATE["state"] = "paused"
        run(app.run_command("start", [], None))
        self.assertEqual(props.sent, [("app_start", None)])
        self.assertIsNotNone(app.RESTORE["pending"])

    def test_unsupported_mode_changes_nothing(self):
        props = self.use(FakeProps())
        with patch.object(app, "default_mode_params", side_effect=app.ModeUnsupported("mop")):
            with self.assertRaises(app.ModeUnsupported):
                run(app.run_command("start", [], "mop"))
        self.assertEqual(props.sent, [])

    def test_unknown_current_mode_refuses_a_per_run_change(self):
        props = self.use(FakeProps(fan=None, water=None, route=None))
        with self.assertRaises(RuntimeError):
            run(app.run_command("start", [], "vacuum"))
        self.assertEqual(props.sent, [])

    def test_commands_without_mode_are_unchanged(self):
        props = self.use(FakeProps())
        for action, cmd in (("stop", "app_stop"), ("pause", "app_pause"), ("dock", "app_charge")):
            run(app.run_command(action, []))
            self.assertEqual(props.sent[-1], (cmd, None))


if __name__ == "__main__":
    unittest.main()
