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
        return bool(self.room) and self.room in names

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
        self.poller = dp.Poller(rooms, token=TOK, transport=self.srv,
                                notify=lambda s, b: self.notes.append(s), log=self.logs.append,
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
