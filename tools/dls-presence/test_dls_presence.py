"""Unit tests for the per-room OCC poller (spec section 12, poller cases 25-35). No network, no hardware.

Run:  python test_dls_presence.py      (or: python -m unittest -v test_dls_presence)
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dls_presence as dp  # noqa: E402  (aioesphomeapi is never imported by these tests)

TOK = "tok"


class FakeClock:
    def __init__(self, t=100000.0):
        self.t = t

    def __call__(self):
        return self.t


class FakeEsp:
    def __init__(self):
        self.r = {}

    def set(self, key, esp, pir=None):
        self.r[key] = (esp, pir)

    def readings(self):
        return dict(self.r)


class FakeRobot:
    def __init__(self, room=None, dock=False):
        self.room, self.dock = room, dock

    def room_value(self, now, names):
        if self.dock:
            return False
        return bool(self.room) and self.room.lower() in {n.lower() for n in names}

    def docked(self, now):
        return self.dock


class Server:
    """Fake DLS. Records every batch; `script` returns replies for a batch (default: OK for every line)."""

    def __init__(self):
        self.batches = []
        self.script = None

    def __call__(self, lines):
        self.batches.append(list(lines))
        if self.script is not None:
            return self.script(lines)
        return ["OK"] * len(lines)

    def occ(self):
        return [line for b in self.batches for line in b if line.startswith("OCC ")]


def cfg(key, sources=("esp", "robot"), stuck=240, robot=("Kitchen",)):
    return dp.RoomCfg(key, list(sources), stuck, [], list(robot))


class Harness:
    def __init__(self, rooms, esp=None, robot=None, presence="HOME"):
        self.clock = FakeClock()
        self.esp = esp if esp is not None else FakeEsp()
        self.srv = Server()
        self.notes, self.logs = [], []
        def _notify(subject, body):
            self.notes.append(subject)
            return True

        self.poller = dp.Poller(rooms, token=TOK, transport=self.srv,
                                notify=_notify, log=self.logs.append,
                                clock=self.clock, esp=self.esp, robot=robot)
        if presence:
            self.poller.set_presence(presence)

    def advance(self, sec):
        self.clock.t += sec

    def tick(self):
        self.poller.tick(self.clock.t)


class PollerCases(unittest.TestCase):
    def test_25_esp_only_line(self):
        h = Harness({"Kitchen": cfg("Kitchen")})
        h.esp.set("Kitchen", True)
        h.tick()
        self.assertIn(f"OCC Kitchen 1 esp {TOK}", h.srv.occ())

    def test_26_src_names_in_priority_order(self):
        h = Harness({"Kitchen": cfg("Kitchen")}, robot=FakeRobot(room="Kitchen"))
        h.esp.set("Kitchen", True)
        h.tick()
        self.assertIn(f"OCC Kitchen 1 esp,robot {TOK}", h.srv.occ())

        h2 = Harness({"Kitchen": cfg("Kitchen", sources=("robot", "esp"))}, robot=FakeRobot(room="Kitchen"))
        h2.esp.set("Kitchen", True)
        h2.tick()
        self.assertIn(f"OCC Kitchen 1 robot,esp {TOK}", h2.srv.occ())

    def test_27_robot_docked_forces_vacant_dock(self):
        h = Harness({"Kitchen": cfg("Kitchen")}, robot=FakeRobot(room="Kitchen", dock=True))
        h.esp.set("Kitchen", False)
        h.tick()
        self.assertIn(f"OCC Kitchen 0 dock {TOK}", h.srv.occ())

    def test_28_unknown_after_180s_and_held_before(self):
        h = Harness({"Kitchen": cfg("Kitchen", sources=("esp",))})
        h.esp.set("Kitchen", True)
        h.tick()
        h.esp.set("Kitchen", None)
        h.tick()  # first unknown tick: state held at 1
        h.advance(179)
        h.tick()
        self.assertNotIn(f"OCC Kitchen 0 unknown {TOK}", h.srv.occ())
        self.assertNotIn(f"OCC Kitchen 0 clear {TOK}", h.srv.occ())
        h.advance(1)
        h.tick()
        self.assertIn(f"OCC Kitchen 0 unknown {TOK}", h.srv.occ())

    def test_29_stuck_timeout_and_pir_evidence(self):
        h = Harness({"Kitchen": cfg("Kitchen", sources=("esp",))})
        h.esp.set("Kitchen", True, pir=False)
        h.tick()
        for _ in range(239):
            h.advance(60)
            h.tick()
        self.assertNotIn(f"OCC Kitchen 0 stuck {TOK}", h.srv.occ())
        h.advance(60)
        h.tick()
        self.assertIn(f"OCC Kitchen 0 stuck {TOK}", h.srv.occ())
        self.assertEqual(len(h.notes), 1)
        h.esp.set("Kitchen", False, pir=False)
        h.tick()
        h.esp.set("Kitchen", True, pir=False)
        h.tick()
        self.assertEqual(h.srv.occ()[-1], f"OCC Kitchen 1 esp {TOK}")

    def test_29b_pir_edge_resets_stuck_timer(self):
        h = Harness({"Kitchen": cfg("Kitchen", sources=("esp",))})
        h.esp.set("Kitchen", True, pir=False)
        h.tick()
        for _ in range(200):
            h.advance(60)
            h.tick()
        h.esp.set("Kitchen", True, pir=True)  # PIR rising edge at 200 min
        h.tick()
        for _ in range(239):  # up to 439 min: no trip yet
            h.advance(60)
            h.tick()
        self.assertNotIn(f"OCC Kitchen 0 stuck {TOK}", h.srv.occ())
        h.advance(60)
        h.tick()  # 440 min
        self.assertIn(f"OCC Kitchen 0 stuck {TOK}", h.srv.occ())

    def test_29c_stuck_disabled_with_zero(self):
        h = Harness({"Kitchen": cfg("Kitchen", sources=("esp",), stuck=0)})
        h.esp.set("Kitchen", True, pir=False)
        h.tick()
        for _ in range(400):
            h.advance(60)
            h.tick()
        self.assertNotIn(f"OCC Kitchen 0 stuck {TOK}", h.srv.occ())

    def test_30_heartbeat_snapshot_every_60s(self):
        rooms = {"Kitchen": cfg("Kitchen", sources=("esp",)), "Laundry": cfg("Laundry", sources=("esp",))}
        h = Harness(rooms)
        h.esp.set("Kitchen", False)
        h.esp.set("Laundry", False)
        h.tick()
        h.advance(60)
        h.tick()
        self.assertEqual(len(h.srv.batches), 2)
        second = h.srv.batches[1]
        self.assertEqual(second[0], f"PRESENCE HOME {TOK}")
        self.assertTrue(second[1].startswith("HELLO "))
        self.assertEqual(second[1], f"HELLO {h.poller.boot_id} 2 {TOK}")
        self.assertEqual(sum(1 for line in second if line.startswith("OCC ")), 2)

    def test_31_short_reply_forces_snapshot_after_5s(self):
        rooms = {k: cfg(k, sources=("esp",)) for k in ("Kitchen", "Laundry", "Office")}
        h = Harness(rooms)
        for k in rooms:
            h.esp.set(k, False)
        h.tick()  # snapshot: PRESENCE + HELLO + 3 OCC = 5 lines, all OK
        for k in rooms:
            h.esp.set(k, True)
        h.srv.script = lambda lines: ["OK", "OK"]  # server closes after 2 of 3 changes
        h.tick()
        self.assertEqual(len(h.srv.batches), 2)
        h.srv.script = None
        h.advance(1)
        h.tick()
        self.assertEqual(len(h.srv.batches), 2)  # still backing off
        h.advance(4)
        h.tick()
        self.assertEqual(len(h.srv.batches), 3)
        self.assertTrue(h.srv.batches[2][1].startswith("HELLO "))

    def test_32_resync_sends_snapshot_at_once(self):
        h = Harness({"Kitchen": cfg("Kitchen", sources=("esp",))})
        h.esp.set("Kitchen", False)
        h.tick()  # snapshot OK
        h.esp.set("Kitchen", True)
        calls = []

        def script(lines):
            calls.append(lines)
            return ["OK RESYNC"] if len(calls) == 1 else ["OK"] * len(lines)

        h.srv.script = script
        h.tick()
        self.assertEqual(len(h.srv.batches), 3)  # snapshot, change, immediate snapshot
        self.assertTrue(h.srv.batches[2][1].startswith("HELLO "))

    def test_33_plain_err_to_occ_logged_once_presence_still_sent(self):
        h = Harness({"Kitchen": cfg("Kitchen", sources=("esp",))})
        h.esp.set("Kitchen", False)
        h.tick()
        h.srv.script = lambda lines: ["OK" if l.startswith("PRESENCE") else "ERR" for l in lines]
        h.poller.set_presence("AWAY")
        h.esp.set("Kitchen", True)
        h.tick()
        self.assertEqual(h.srv.batches[-1][0], f"PRESENCE AWAY {TOK}")
        h.esp.set("Kitchen", False)
        h.advance(1)
        h.tick()
        self.assertEqual(sum(1 for m in h.logs if "too old" in m), 1)

    def test_34_no_rooms_sends_presence_only(self):
        h = Harness({})
        h.tick()
        self.assertEqual(h.srv.batches, [[f"PRESENCE HOME {TOK}"]])
        h.advance(120)
        h.tick()
        self.assertEqual(len(h.srv.batches), 1)  # no HELLO, no heartbeat without rooms
        h.poller.set_presence("AWAY")
        h.tick()
        self.assertEqual(h.srv.batches[-1], [f"PRESENCE AWAY {TOK}"])

    def test_35_single_change_sent_at_once(self):
        h = Harness({"Kitchen": cfg("Kitchen", sources=("esp",))})
        h.esp.set("Kitchen", False)
        h.tick()
        h.esp.set("Kitchen", True)
        h.advance(0.5)
        h.tick()
        self.assertEqual(h.srv.batches[-1], [f"OCC Kitchen 1 esp {TOK}"])


class ExtraCases(unittest.TestCase):
    def test_link_down_alerts_once_then_recovers(self):
        old = dp.DLS_ALERT_AFTER
        dp.DLS_ALERT_AFTER = 60.0
        try:
            h = Harness({"Kitchen": cfg("Kitchen", sources=("esp",))})
            h.esp.set("Kitchen", True)
            h.tick()                               # one good snapshot
            self.assertEqual(h.notes, [])

            def refuse(lines):
                raise ConnectionRefusedError()

            h.poller.transport = refuse
            h.advance(60)                          # next heartbeat snapshot is the first failure
            h.tick()
            h.advance(30)
            h.tick()
            self.assertEqual(h.notes, [])          # 30 s in: quiet
            h.advance(30)
            h.tick()
            self.assertEqual(h.notes, ["DLS presence: link down"])
            for _ in range(20):                    # still down: no repeat inside 6 h
                h.advance(60)
                h.tick()
            self.assertEqual(h.notes, ["DLS presence: link down"])

            h.poller.transport = h.srv
            h.advance(60)
            h.tick()
            self.assertEqual(h.notes, ["DLS presence: link down", "DLS presence: link recovered"])
        finally:
            dp.DLS_ALERT_AFTER = old

    def test_link_down_repeats_after_six_hours(self):
        old = dp.DLS_ALERT_AFTER
        dp.DLS_ALERT_AFTER = 60.0
        try:
            h = Harness({"Kitchen": cfg("Kitchen", sources=("esp",), stuck=0)})
            h.esp.set("Kitchen", True)
            h.tick()

            def refuse(lines):
                raise ConnectionRefusedError()

            h.poller.transport = refuse
            for _ in range(6 * 60):                # 6 h in 60 s steps
                h.advance(60)
                h.tick()
            self.assertEqual(h.notes, ["DLS presence: link down"])
            for _ in range(10):
                h.advance(60)
                h.tick()
            self.assertEqual(h.notes, ["DLS presence: link down"] * 2)
        finally:
            dp.DLS_ALERT_AFTER = old

    def test_auth_error_retries_every_60s_and_alerts_after_30min(self):
        h = Harness({"Kitchen": cfg("Kitchen", sources=("esp",))})
        h.srv.script = lambda lines: ["ERR AUTH"] * len(lines)
        h.esp.set("Kitchen", True)
        h.tick()
        self.assertEqual(len(h.srv.batches), 1)
        h.advance(59)
        h.tick()
        self.assertEqual(len(h.srv.batches), 1)
        for _ in range(30):
            h.advance(60)
            h.tick()
        self.assertGreaterEqual(len(h.srv.batches), 30)
        self.assertEqual(h.notes, ["DLS presence: token rejected"])

    def test_robot_in_room_and_dock_timeout(self):
        r = dp.RobotSource(started=0.0)
        self.assertIsNone(r.room_value(10.0, ["Kitchen"]))  # no poll yet, within 180 s
        self.assertFalse(r.room_value(181.0, ["Kitchen"]))  # never polled for 180 s = docked
        r.observe(200.0, "cleaning", "Kitchen")
        self.assertTrue(r.room_value(201.0, ["Kitchen"]))
        self.assertFalse(r.room_value(201.0, ["Laundry"]))
        r.observe(202.0, "charging", "Kitchen")
        self.assertFalse(r.room_value(203.0, ["Kitchen"]))
        self.assertTrue(r.docked(203.0))

    def test_load_rooms_validation(self):
        doc = {"rooms": {
            "Kitchen": {"sources": ["esp", "robot"], "stuckOnMin": 240, "esp": [{"host": "a", "entity": "occ"}]},
            "bad key!": {},
            "kitchen": {},
            "Laundry": {"sources": ["wifi"]},
            "Office": {"stuckOnMin": "x"},
        }}
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "rooms.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump(doc, f)
            logs = []
            rooms = dp.load_rooms(path, log=logs.append)
        self.assertEqual(sorted(rooms), ["Kitchen", "Laundry", "Office"])
        self.assertEqual(rooms["Laundry"].sources, ["esp", "robot"])
        self.assertEqual(rooms["Office"].stuck_min, dp.STUCK_ON_MIN)
        self.assertEqual(len(rooms["Kitchen"].esp), 1)
        self.assertEqual(dp.load_rooms(os.path.join(tempfile.gettempdir(), "no-such-file.json")), {})


class EspWatcherCases(unittest.TestCase):
    def test_device_loop_with_real_api_shape(self):
        import asyncio
        import types
        from unittest import mock
        seen = {}

        class BinarySensorInfo:
            def __init__(self, key, object_id):
                self.key, self.object_id, self.name = key, object_id, object_id

        class BinarySensorState:
            def __init__(self, key, state, missing_state=False):
                self.key, self.state, self.missing_state = key, state, missing_state

        class APIClient:  # signatures copied from the aioesphomeapi docs
            def __init__(self, address, port, password=None, *, noise_psk=None, **kw):
                seen["init"] = (address, port, password, noise_psk)
                self.is_connected = False

            async def connect(self, on_stop=None, login=False, log_errors=True):
                self.is_connected = True

            async def list_entities_services(self):
                return [BinarySensorInfo(11, "occupancy"), BinarySensorInfo(12, "pir")], []

            def subscribe_states(self, on_state):  # sync, returns None
                on_state(BinarySensorState(11, True))
                on_state(BinarySensorState(12, False, missing_state=True))

            async def disconnect(self, force=False):
                self.is_connected = False

        fake = types.ModuleType("aioesphomeapi")
        fake.APIClient = APIClient
        logs = []
        w = dp.EsphomeWatcher({"Kitchen": [{"host": "h", "key": "", "entity": "occupancy", "pir": "pir"}]},
                              log=logs.append)

        async def run():
            try:
                await asyncio.wait_for(w._device_loop("h", w.devs["h"]), 0.3)
            except asyncio.TimeoutError:
                pass

        with mock.patch.dict(sys.modules, {"aioesphomeapi": fake}):
            asyncio.run(run())
        dp._extra_health.pop("esp:h", None)
        self.assertEqual(seen["init"], ("h", dp.ESPHOME_PORT, "", None))
        self.assertEqual(w.readings(), {"Kitchen": (True, None)})
        self.assertEqual(logs, [])


class RobotCases(unittest.TestCase):
    def test_robot_bridge_payload(self):
        body = {"state": "segment_cleaning", "battery": 80, "error": "none", "last_error": None,
                "rooms": [{"id": 16, "name": "Living room"}], "last_success_age_s": 4.2,
                "current_room": {"id": 16, "name": "Living room"},
                "room_progress_pct": None, "run_progress_pct": None}
        self.assertEqual(dp.parse_robot_state(body), ("segment_cleaning", "Living room"))
        self.assertEqual(dp.parse_robot_state(dict(body, current_room=None))[1], None)
        for bad in (dict(body, last_success_age_s=None), dict(body, last_success_age_s=400.0), dict(body, state=None)):
            self.assertRaises(ValueError, dp.parse_robot_state, bad)
        with self.assertRaises(ValueError) as cm:
            dp.parse_robot_state(dict(body, state=None, last_success_age_s=None))
        self.assertIn("state=None last_success_age_s=None", str(cm.exception))
        with self.assertRaises(ValueError) as cm:
            dp.parse_robot_state(["x" * 500])
        self.assertLess(len(str(cm.exception)), 260)
        self.assertRaises(ValueError, dp.parse_robot_state, None)
        self.assertRaises(ValueError, dp.parse_robot_state, dict(body, last_success_age_s=True))
        for u in ("http://liesa:8788", "http://liesa:8788/", "http://liesa:8788/state", "http://liesa:8788/state/"):
            self.assertEqual(dp.robot_state_url(u), "http://liesa:8788/state")
        r = dp.RobotSource(started=0.0)
        r.observe(10.0, "charger_disconnected", "Kitchen")
        self.assertTrue(r.docked(11.0))
        r.observe(12.0, "emptying_the_bin", "Kitchen")
        self.assertTrue(r.docked(13.0))
        r.observe(14.0, "segment_cleaning", "Kitchen")
        self.assertFalse(r.docked(15.0))
        r.observe(16.0, "paused", "Kitchen")  # deliberately not an occupant
        self.assertTrue(r.docked(17.0))

    def test_robot_watcher_startup_race_backoff_and_single_log(self):
        responses = [
            {"state": None, "last_success_age_s": None},
            {"state": None, "last_success_age_s": None},
            {"state": "charging", "last_success_age_s": 0.4, "current_room": None},
            RuntimeError("bridge down"),
        ]
        sleeps = []
        logs = []
        robot = dp.RobotSource(started=0.0)

        class _Stop(Exception):
            pass

        def fake_fetch():
            item = responses.pop(0)
            if isinstance(item, Exception):
                raise item
            return item

        def fake_sleep(sec):
            sleeps.append(sec)
            if not responses:
                raise _Stop()

        from unittest import mock
        w = dp.RobotWatcher("http://example/state", 15.0, robot, log=logs.append,
                            fetch=fake_fetch, sleep=fake_sleep)
        with mock.patch.object(dp, "set_health"):
            with self.assertRaises(_Stop):
                w._loop()

        self.assertEqual(sleeps, [1.0, 2.0, 15.0, 15.0])
        self.assertEqual(len(logs), 2)
        self.assertIn("waiting for first poll: ValueError", logs[0])
        self.assertIn("state=None last_success_age_s=None", logs[0])
        self.assertNotIn("Traceback", logs[0])
        self.assertIn("RuntimeError", logs[1])
        self.assertNotIn("waiting for first poll", logs[1])
        self.assertEqual(robot.state, "charging")


class StatusViewTest(unittest.TestCase):
    """GET /status and /status.json (read-only HTML view of presence state)."""

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False, newline="")
        self.tmp.close()
        self._old_log = dp.EVENT_LOG
        self._old_state = dp._last_state
        self._old_force = dp._force_home_until
        dp.EVENT_LOG = self.tmp.name
        dp._last_state = "AWAY"
        dp._force_home_until = 0.0
        dp.record("state", value="AWAY")
        dp.record("source", person="nick", source="unifi", value="false")
        self.srv = dp.ThreadingHTTPServer(("127.0.0.1", 0), dp._FreshHandler)
        import threading
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.srv.server_address[1]}"

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        dp.EVENT_LOG = self._old_log
        dp._last_state = self._old_state
        dp._force_home_until = self._old_force
        os.unlink(self.tmp.name)

    def _get(self, path):
        import urllib.request
        with urllib.request.urlopen(self.base + path, timeout=5) as r:
            return r.status, r.read().decode()

    def test_snapshot_carries_state_and_events(self):
        snap = dp._status_snapshot()
        self.assertEqual(snap["state"], "AWAY")
        self.assertEqual(snap["events"][0]["source"], "unifi")
        self.assertIn("sources", snap)

    def test_status_html_renders_state(self):
        code, body = self._get("/status")
        self.assertEqual(code, 200)
        self.assertIn("AWAY", body)
        self.assertIn("Recent events", body)
        self.assertIn("unifi", body)

    def test_status_json(self):
        code, body = self._get("/status.json")
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body)["state"], "AWAY")


if __name__ == "__main__":
    unittest.main(verbosity=2)
