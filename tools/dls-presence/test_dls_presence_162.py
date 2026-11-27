"""v1.6.2 tests: tracking counts as motion evidence; night stuck rule; no alert for a night trip."""
import os, sys, time, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dls_presence as dp


def local_ts(h, m):
    lt = time.localtime()
    return time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, h, m, 0, 0, 0, -1))


def cfg(night=(23 * 60, 7 * 60, 10)):
    return dp.RoomCfg("LivingRoom", ["esp"], 240, [{"host": "h", "entity": "occupancy"}], [], night)


class T(unittest.TestCase):
    def test_static_only_at_night_goes_vacant_after_10_min(self):
        tr = dp.RoomTracker(cfg())
        t0 = local_ts(23, 30)
        self.assertEqual(tr.evaluate(t0, True, True, None, False)["state"], 1)
        r = tr.evaluate(t0 + 9 * 60, True, False, None, False)
        self.assertEqual(r["state"], 1)
        r = tr.evaluate(t0 + 11 * 60, True, False, None, False)
        self.assertEqual((r["state"], r["src"], r["stuck"], r["night"]), (0, "stuck", True, True))

    def test_motion_restores_then_trips_again(self):
        tr = dp.RoomTracker(cfg())
        t0 = local_ts(0, 30)
        tr.evaluate(t0, True, False, None, False)
        self.assertEqual(tr.evaluate(t0 + 11 * 60, True, False, None, False)["state"], 0)
        self.assertEqual(tr.evaluate(t0 + 60 * 60, True, True, None, False)["state"], 1)   # cat / person moves
        self.assertEqual(tr.evaluate(t0 + 71 * 60, True, False, None, False)["state"], 0)

    def test_continuous_tracking_keeps_room_occupied(self):
        tr = dp.RoomTracker(cfg())
        t0 = local_ts(23, 10)
        for i in range(0, 40 * 60, 60):
            r = tr.evaluate(t0 + i, True, True, None, False)
        self.assertEqual(r["state"], 1)

    def test_daytime_uses_long_limit(self):
        tr = dp.RoomTracker(cfg())
        t0 = local_ts(12, 0)
        tr.evaluate(t0, True, False, None, False)
        self.assertEqual(tr.evaluate(t0 + 60 * 60, True, False, None, False)["state"], 1)

    def test_load_rooms_night_and_track(self):
        import json, tempfile
        doc = {"rooms": {"LivingRoom": {"sources": ["esp"], "night": {"from": "23:00", "to": "07:00", "stuckOnMin": 10},
                                        "esp": [{"host": "h", "entity": "occupancy", "pir": "motion", "track": "tracking_presence"}]}}}
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(doc, f)
        rooms = dp.load_rooms(f.name, log=lambda *_: None)
        os.unlink(f.name)
        self.assertEqual(rooms["LivingRoom"].night, (1380, 420, 10.0))
        w = dp.EsphomeWatcher({"LivingRoom": rooms["LivingRoom"].esp}, log=lambda *_: None)
        w.state[("h", "occupancy")] = True
        w.state[("h", "motion")] = False
        w.state[("h", "tracking_presence")] = True
        self.assertEqual(w.readings()["LivingRoom"], (True, True))


if __name__ == "__main__":
    unittest.main()
