"""Regression tests for dls_presence.py hardening (P1-P3, S1-S4). No network, no hardware.

Run:  python tools\\dls-presence\\test_dls_presence_1.py
"""
import asyncio
import json
import os
import socket
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dls_presence as dp  # noqa: E402  (aioesphomeapi is never imported by these tests)
import test_dls_presence as base  # noqa: E402

FakeEsp = base.FakeEsp
FakeRobot = base.FakeRobot
Harness = base.Harness
TOK = base.TOK
cfg = base.cfg


def cfg_esp(key, sources=("esp", "robot"), stuck=240, robot=("Kitchen",)):
    """Like cfg but with a configured ESPHome device: P1 only holds a room whose esp is configured."""
    return dp.RoomCfg(key, list(sources), stuck, [{"host": "esp-test", "key": "", "entity": "occ", "pir": ""}], list(robot))


class P1EspUnknownWithRobotTests(unittest.TestCase):
    def test_p1_esp_none_robot_false_holds_then_unknown(self):
        for dock, rob_room in ((True, "Kitchen"), (False, "Laundry")):
            with self.subTest(dock=dock, rob_room=rob_room):
                h = Harness(
                    {"Kitchen": cfg_esp("Kitchen", sources=("esp", "robot"))},
                    robot=FakeRobot(room=rob_room, dock=dock),
                )
                h.esp.set("Kitchen", True)
                h.tick()
                self.assertEqual(h.srv.occ()[-1], f"OCC Kitchen 1 esp {TOK}")

                h.esp.set("Kitchen", None)
                h.tick()
                self.assertEqual(h.srv.occ()[-1], f"OCC Kitchen 1 esp {TOK}")
                h.advance(179)
                h.tick()
                self.assertEqual(h.srv.occ()[-1], f"OCC Kitchen 1 esp {TOK}")
                self.assertNotIn(f"OCC Kitchen 0 dock {TOK}", h.srv.occ())
                self.assertNotIn(f"OCC Kitchen 0 clear {TOK}", h.srv.occ())
                self.assertNotIn(f"OCC Kitchen 0 unknown {TOK}", h.srv.occ())

                h.advance(1)
                h.tick()
                self.assertEqual(h.srv.occ()[-1], f"OCC Kitchen 0 unknown {TOK}")

    def test_p1_default_sources_without_esp_device_not_held(self):
        # a room that lists esp (the default) but has no ESPHome device configured must keep the old robot-only result
        h = Harness({"Kitchen": cfg("Kitchen", sources=("esp", "robot"))}, robot=FakeRobot(room="Laundry", dock=True))
        h.tick()
        self.assertEqual(h.srv.occ()[-1], f"OCC Kitchen 0 dock {TOK}")

    def test_p1_esp_none_robot_true_occupied_by_robot(self):
        h = Harness(
            {"Kitchen": cfg_esp("Kitchen", sources=("esp", "robot"))},
            robot=FakeRobot(room="Kitchen", dock=False),
        )
        h.esp.set("Kitchen", None)
        h.tick()
        self.assertEqual(h.srv.occ()[-1], f"OCC Kitchen 1 robot {TOK}")
        h.advance(200)
        h.tick()
        self.assertEqual(h.srv.occ()[-1], f"OCC Kitchen 1 robot {TOK}")

    def test_p1_esp_false_robot_false_unchanged(self):
        h_dock = Harness(
            {"Kitchen": cfg_esp("Kitchen", sources=("esp", "robot"))},
            robot=FakeRobot(room="Kitchen", dock=True),
        )
        h_dock.esp.set("Kitchen", False)
        h_dock.tick()
        self.assertEqual(h_dock.srv.occ()[-1], f"OCC Kitchen 0 dock {TOK}")

        h_clear = Harness(
            {"Kitchen": cfg_esp("Kitchen", sources=("esp", "robot"))},
            robot=FakeRobot(room="Laundry", dock=False),
        )
        h_clear.esp.set("Kitchen", False)
        h_clear.tick()
        self.assertEqual(h_clear.srv.occ()[-1], f"OCC Kitchen 0 clear {TOK}")

    def test_p1_robot_only_room_unchanged(self):
        r = dp.RobotSource(started=100000.0)
        h = Harness({"Laundry": cfg("Laundry", sources=("robot",), robot=("Laundry",))}, robot=r)
        h.tick()
        self.assertEqual(h.srv.occ()[-1], f"OCC Laundry 0 unknown {TOK}")

        r.observe(100005.0, "cleaning", "Laundry")
        h.advance(5)
        h.tick()
        self.assertEqual(h.srv.occ()[-1], f"OCC Laundry 1 robot {TOK}")

        r.observe(100010.0, "docked", "Laundry")
        h.advance(5)
        h.tick()
        self.assertEqual(h.srv.occ()[-1], f"OCC Laundry 0 dock {TOK}")

        r.observe(100015.0, "cleaning", "Kitchen")
        h.advance(5)
        h.tick()
        self.assertEqual(h.srv.occ()[-1], f"OCC Laundry 0 clear {TOK}")

        r2 = dp.RobotSource(started=100000.0)
        h2 = Harness({"Laundry": cfg("Laundry", sources=("robot",), robot=("Laundry",))}, robot=r2)
        h2.tick()
        h2.advance(179)
        h2.tick()
        self.assertEqual(h2.srv.occ()[-1], f"OCC Laundry 0 unknown {TOK}")
        h2.advance(1)
        h2.tick()
        self.assertEqual(h2.srv.occ()[-1], f"OCC Laundry 0 dock {TOK}")

        tr = dp.RoomTracker(cfg("Laundry", sources=("robot",), robot=("Laundry",)))
        self.assertEqual(tr.evaluate(100.0, None, None, True, False)["src"], "robot")
        hold = tr.evaluate(101.0, None, None, None, False)
        self.assertEqual((hold["state"], hold["src"]), (1, "robot"))
        hold2 = tr.evaluate(280.0, None, None, None, False)
        self.assertEqual((hold2["state"], hold2["src"]), (1, "robot"))
        unk = tr.evaluate(281.0, None, None, None, False)
        self.assertEqual((unk["state"], unk["src"]), (0, "unknown"))

    def test_p1_tripped_stuck_with_robot_false_unchanged(self):
        h = Harness(
            {"Kitchen": cfg_esp("Kitchen", sources=("esp", "robot"), stuck=1)},
            robot=FakeRobot(room="Kitchen", dock=True),
        )
        h.esp.set("Kitchen", True, pir=False)
        h.tick()
        h.advance(60)
        h.tick()
        self.assertEqual(h.srv.occ()[-1], f"OCC Kitchen 0 stuck {TOK}")


class P2PresencePendingRaceTests(unittest.TestCase):
    def test_p2_set_presence_during_inflight_send_not_lost(self):
        h = Harness({"Kitchen": cfg("Kitchen", sources=("esp",))}, presence="HOME")
        h.esp.set("Kitchen", False)
        flipped = False

        def script(lines):
            nonlocal flipped
            if not flipped and any(line.startswith("PRESENCE HOME ") for line in lines):
                flipped = True
                h.poller.set_presence("AWAY")
            return ["OK"] * len(lines)

        h.srv.script = script
        h.tick()
        self.assertTrue(flipped)
        self.assertEqual(h.poller.presence, "AWAY")
        self.assertTrue(h.poller.presence_pending)

        h.advance(1)
        h.tick()
        self.assertIn(f"PRESENCE AWAY {TOK}", h.srv.batches[-1])
        self.assertFalse(h.poller.presence_pending)

    def test_p2_set_presence_during_inflight_no_rooms_not_lost(self):
        h = Harness({}, presence="HOME")
        flipped = False

        def script(lines):
            nonlocal flipped
            if not flipped and lines == [f"PRESENCE HOME {TOK}"]:
                flipped = True
                h.poller.set_presence("AWAY")
            return ["OK"] * len(lines)

        h.srv.script = script
        h.tick()
        self.assertTrue(flipped)
        self.assertEqual(h.poller.presence, "AWAY")
        self.assertTrue(h.poller.presence_pending)

        h.advance(1)
        h.tick()
        self.assertEqual(h.srv.batches[-1], [f"PRESENCE AWAY {TOK}"])
        self.assertFalse(h.poller.presence_pending)


class P3EsphomeMissingEntityHealthTests(unittest.TestCase):
    def _run_device_once(self, entities, room_cfg):
        class BinarySensorInfo:
            def __init__(self, key, object_id):
                self.key, self.object_id, self.name = key, object_id, object_id

        class APIClient:
            def __init__(self, address, port, password=None, *, noise_psk=None, **kw):
                self.is_connected = False

            async def connect(self, on_stop=None, login=False, log_errors=True):
                self.is_connected = True

            async def list_entities_services(self):
                return [BinarySensorInfo(k, oid) for k, oid in entities], []

            def subscribe_states(self, on_state):
                return None

            async def disconnect(self, force=False):
                self.is_connected = False

        fake = types.ModuleType("aioesphomeapi")
        fake.APIClient = APIClient
        logs = []
        w = dp.EsphomeWatcher({"Kitchen": [room_cfg]}, log=logs.append)

        async def fake_sleep(delay):
            if delay == 1:
                raise asyncio.CancelledError()

        async def run():
            try:
                await w._device_loop(room_cfg["host"], w.devs[room_cfg["host"]])
            except asyncio.CancelledError:
                pass

        with mock.patch.dict(sys.modules, {"aioesphomeapi": fake}), mock.patch.object(asyncio, "sleep", fake_sleep):
            asyncio.run(run())
        return logs

    def test_p3_missing_entity_marks_health_unhealthy_with_reason(self):
        room_cfg = {"host": "ep-test", "key": "", "entity": "occupancy", "pir": "pir"}
        for present, missing_oid in (([(11, "occupancy")], "pir"), ([(12, "pir")], "occupancy")):
            with self.subTest(missing=missing_oid):
                try:
                    self._run_device_once(present, room_cfg)
                    health = dp._extra_health.get("esp:ep-test", {})
                    self.assertFalse(health.get("ok"))
                    fresh = dp.freshness()["esp:ep-test"]
                    self.assertTrue(fresh["stale"])
                    self.assertIn("reason", fresh)
                    self.assertIn("ep-test", fresh["reason"])
                    self.assertIn(missing_oid, fresh["reason"])
                finally:
                    dp._extra_health.pop("esp:ep-test", None)

    def test_p3_all_entities_present_marks_health_healthy(self):
        room_cfg = {"host": "ep-test", "key": "", "entity": "occupancy", "pir": "pir"}
        try:
            logs = self._run_device_once([(11, "occupancy"), (12, "pir")], room_cfg)
            self.assertEqual(logs, [])
            health = dp._extra_health.get("esp:ep-test", {})
            self.assertTrue(health.get("ok"))
            fresh = dp.freshness()["esp:ep-test"]
            self.assertFalse(fresh["stale"])
            self.assertNotIn("reason", fresh)
        finally:
            dp._extra_health.pop("esp:ep-test", None)


class FakeSocket:
    def __init__(self, chunks):
        self._chunks = list(chunks)
        self.sent = []

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def sendall(self, data):
        self.sent.append(data)

    def settimeout(self, timeout):
        pass

    def recv(self, n):
        item = self._chunks.pop(0)
        if isinstance(item, BaseException):
            raise item
        return item


class S1Ea1BatchTests(unittest.TestCase):
    def test_s1_complete_reply_returns_lines(self):
        sock = FakeSocket([b"OK\r\nOK ", b"RESYNC\r\n", b""])
        with mock.patch.object(dp.socket, "create_connection", return_value=sock):
            res = dp.ea1_batch(["PRESENCE HOME tok", "HELLO 1 0 tok"])
        self.assertEqual(res, ["OK", "OK RESYNC"])

    def test_s1_truncated_and_short_reply_raises_oserror(self):
        cases = (
            (["L1", "L2"], [b"OK\r\nOK RE", b""]),
            (["L1", "L2"], [b"OK\r\n", b""]),
            (["L1"], [b""]),
        )
        for lines, chunks in cases:
            with self.subTest(lines=lines, chunks=chunks):
                sock = FakeSocket(chunks)
                with mock.patch.object(dp.socket, "create_connection", return_value=sock):
                    with self.assertRaises(OSError):
                        dp.ea1_batch(lines)

    def test_s1_complete_reply_then_timeout_is_accepted(self):
        sock = FakeSocket([b"OK\r\n", socket.timeout("timed out")])
        with mock.patch.object(dp.socket, "create_connection", return_value=sock):
            self.assertEqual(dp.ea1_batch(["L1"]), ["OK"])

    def test_s1_timeout_raises_oserror(self):
        cases = (
            (["L1", "L2"], [b"OK\r\n", socket.timeout("timed out")]),
            (["L1"], [socket.timeout("timed out")]),
        )
        for lines, chunks in cases:
            with self.subTest(lines=lines, chunks=chunks):
                sock = FakeSocket(chunks)
                with mock.patch.object(dp.socket, "create_connection", return_value=sock):
                    with self.assertRaises(OSError):
                        dp.ea1_batch(lines)


class S2EsphomeDisconnectBeforeBackoffTests(unittest.TestCase):
    def test_s2_disconnect_runs_before_backoff_sleep(self):
        events = []
        state_at_sleep = {}

        class BinarySensorInfo:
            def __init__(self, key, object_id):
                self.key, self.object_id, self.name = key, object_id, object_id

        class BinarySensorState:
            def __init__(self, key, state):
                self.key, self.state, self.missing_state = key, state, False

        clients = []

        class APIClient:
            def __init__(self, address, port, password=None, *, noise_psk=None, **kw):
                self.is_connected = False
                clients.append(self)

            async def connect(self, on_stop=None, login=False, log_errors=True):
                self.is_connected = True

            async def list_entities_services(self):
                return [BinarySensorInfo(11, "occupancy")], []

            def subscribe_states(self, on_state):
                on_state(BinarySensorState(11, True))
                raise RuntimeError("boom")

            async def disconnect(self, force=False):
                events.append("disconnect")
                self.is_connected = False

        fake = types.ModuleType("aioesphomeapi")
        fake.APIClient = APIClient
        logs = []
        w = dp.EsphomeWatcher({"Kitchen": [{"host": "h", "key": "", "entity": "occupancy"}]}, log=logs.append)

        async def fake_sleep(delay):
            events.append(("sleep", delay))
            state_at_sleep["connected"] = clients[-1].is_connected
            state_at_sleep["readings"] = w.readings()
            if delay >= 5:
                raise asyncio.CancelledError()

        async def run():
            try:
                await w._device_loop("h", w.devs["h"])
            except asyncio.CancelledError:
                pass

        try:
            with mock.patch.dict(sys.modules, {"aioesphomeapi": fake}), mock.patch.object(asyncio, "sleep", fake_sleep):
                asyncio.run(run())
        finally:
            dp._extra_health.pop("esp:h", None)

        self.assertEqual(events, ["disconnect", ("sleep", 5)])
        self.assertFalse(state_at_sleep.get("connected"))
        self.assertEqual(state_at_sleep.get("readings"), {"Kitchen": (None, None)})


class S3LoadRoomsValidationTests(unittest.TestCase):
    def _load(self, doc):
        logs = []
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "rooms.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump(doc, f)
            rooms = dp.load_rooms(path, log=logs.append)
        return rooms, logs

    def test_s3_bare_string_robot_rejected_not_split(self):
        rooms, logs = self._load({
            "rooms": {
                "Bad": {"sources": ["robot"], "robot": "Kitchen"},
                "Partial": {
                    "sources": ["esp", "robot"],
                    "esp": [{"host": "a", "entity": "occ"}],
                    "robot": "Kitchen",
                },
            }
        })
        self.assertNotIn("Bad", rooms)
        self.assertIn("Partial", rooms)
        self.assertEqual(rooms["Partial"].robot, [])
        self.assertGreaterEqual(len(logs), 2)

    def test_s3_bad_robot_non_list_and_non_string_items(self):
        rooms, logs = self._load({
            "rooms": {
                "IntRobot": {"sources": ["robot"], "robot": 123},
                "MixedRobot": {"sources": ["robot"], "robot": ["Kitchen", 42]},
                "Good": {"sources": ["robot"], "robot": ["Kitchen"]},
            }
        })
        self.assertEqual(list(rooms.keys()), ["Good"])
        self.assertEqual(rooms["Good"].robot, ["Kitchen"])
        self.assertGreaterEqual(len(logs), 2)

    def test_s3_bad_esp_types_rejected(self):
        rooms, logs = self._load({
            "rooms": {
                "StrEsp": {"esp": "ep.lan"},
                "IntEsp": {"esp": 123},
                "DictEsp": {"esp": {"host": "a", "entity": "occ"}},
                "BadItems": {"esp": ["x", {"host": 1, "entity": "occ"}, {"host": "a"}]},
                "Good": {"esp": [{"host": "a", "entity": "occ"}]},
            }
        })
        self.assertEqual(list(rooms.keys()), ["Good"])
        self.assertGreaterEqual(len(logs), 4)

    def test_s3_bad_sources_unhashable_and_empty(self):
        rooms, logs = self._load({
            "rooms": {
                "Unhashable": {"sources": [{"a": 1}], "esp": [{"host": "a", "entity": "occ"}]},
                "Unhashable2": {"sources": ["esp", ["robot"]], "esp": [{"host": "a", "entity": "occ"}]},
                "EmptySrc": {"sources": [], "esp": [{"host": "a", "entity": "occ"}]},
            }
        })
        self.assertEqual(sorted(rooms.keys()), ["Unhashable", "Unhashable2"])
        self.assertEqual(rooms["Unhashable"].sources, ["esp", "robot"])
        self.assertEqual(rooms["Unhashable2"].sources, ["esp", "robot"])
        self.assertNotIn("EmptySrc", rooms)
        self.assertGreaterEqual(len(logs), 3)

    def test_s3_non_dict_doc_rooms_and_entries(self):
        rooms_list_doc, logs_doc = self._load(["bad"])
        self.assertEqual(rooms_list_doc, {})
        self.assertTrue(logs_doc)

        rooms_list_rooms, logs_rooms = self._load({"rooms": ["bad"]})
        self.assertEqual(rooms_list_rooms, {})
        self.assertTrue(logs_rooms)

        rooms_entries, logs_entries = self._load({
            "rooms": {
                "Str": "bad",
                "List": [],
                "Null": None,
                "Good": {"esp": [{"host": "a", "entity": "occ"}]},
            }
        })
        self.assertEqual(list(rooms_entries.keys()), ["Good"])
        self.assertGreaterEqual(len(logs_entries), 3)

    def test_s3_example_file_loads_identically(self):
        example_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rooms.example.json")
        logs = []
        rooms = dp.load_rooms(example_path, log=logs.append)
        self.assertEqual(logs, [])
        self.assertEqual(list(rooms.keys()), ["Kitchen", "Laundry", "LivingRoom"])
        self.assertEqual(rooms["Kitchen"].sources, ["esp", "robot"])
        self.assertEqual(rooms["Kitchen"].stuck_min, 240.0)
        self.assertEqual(rooms["Kitchen"].robot, ["Kitchen"])
        self.assertEqual(rooms["Kitchen"].esp[0]["pir"], "pir")
        self.assertEqual(rooms["Laundry"].sources, ["esp", "robot"])
        self.assertEqual(rooms["Laundry"].stuck_min, dp.STUCK_ON_MIN)
        self.assertEqual(rooms["Laundry"].robot, ["Laundry"])
        self.assertEqual(rooms["LivingRoom"].robot, ["Living room"])


class S4EsphomeClientInitInsideTryTests(unittest.TestCase):
    def test_s4_apiclient_init_error_caught_and_retried(self):
        sleep_calls = []

        class BinarySensorInfo:
            def __init__(self, key, object_id):
                self.key, self.object_id, self.name = key, object_id, object_id

        class BinarySensorState:
            def __init__(self, key, state):
                self.key, self.state, self.missing_state = key, state, False

        init_calls = 0

        class APIClient:
            def __init__(self, address, port, password=None, *, noise_psk=None, **kw):
                nonlocal init_calls
                init_calls += 1
                if init_calls == 1:
                    raise ValueError("bad psk")
                self.is_connected = False

            async def connect(self, on_stop=None, login=False, log_errors=True):
                self.is_connected = True

            async def list_entities_services(self):
                return [BinarySensorInfo(11, "occupancy")], []

            def subscribe_states(self, on_state):
                on_state(BinarySensorState(11, True))

            async def disconnect(self, force=False):
                self.is_connected = False

        fake = types.ModuleType("aioesphomeapi")
        fake.APIClient = APIClient
        logs = []
        w = dp.EsphomeWatcher({"Kitchen": [{"host": "h", "key": "", "entity": "occupancy"}]}, log=logs.append)

        async def fake_sleep(delay):
            if delay >= 5:
                sleep_calls.append(("backoff", delay))
                return
            if delay == 1:
                raise asyncio.CancelledError()

        async def run():
            try:
                await w._device_loop("h", w.devs["h"])
            except asyncio.CancelledError:
                pass

        try:
            with mock.patch.dict(sys.modules, {"aioesphomeapi": fake}), mock.patch.object(asyncio, "sleep", fake_sleep):
                asyncio.run(run())
            self.assertEqual(init_calls, 2)
            self.assertEqual(sleep_calls, [("backoff", 5)])
            self.assertTrue(any("ValueError" in m for m in logs))
            self.assertEqual(w.readings(), {"Kitchen": (True, None)})
            self.assertTrue(dp._extra_health["esp:h"]["ok"])
        finally:
            dp._extra_health.pop("esp:h", None)


if __name__ == "__main__":
    unittest.main(verbosity=2)
